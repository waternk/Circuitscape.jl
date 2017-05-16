function single_ground_all_pair_resistances{T}(a::SparseMatrixCSC, g::Graph, c::Vector{T}, cfg; 
                                                    exclude = Tuple{Int,Int}[], 
                                                    nodemap = Matrix{Float64}(), 
                                                    orig_pts = Vector{Int}(), 
                                                    polymap = Matrix{Float64}(),
                                                    hbmeta = RasterMeta())
    numpoints = size(c, 1)
    cc = connected_components(g)
    debug("Graph has $(size(a,1)) nodes, $numpoints focal points and $(length(cc)) connected components")
    resistances = -1 * ones(numpoints, numpoints) 

    cond = laplacian(a)

    volt = Vector{Float64}(size(g, 1))
    total = Int(numpoints * (numpoints-1) / 2)
    cond_pruned = sprand(1,1,0.1)
    d = 0
    M = 1
    pt1 = 1
    rcc = 0
    subsets = getindex.([cond], cc, cc)
    z = zeros.(cc)
    volt = zeros.(size.(cc))
    
    p = 0 
    for i = 1:numpoints
        if c[i] != 0
            rcc = rightcc(cc, c[i])
            cond_pruned = subsets[rcc]
            pt1 = ingraph(cc[rcc], c[i])
            d = cond_pruned[pt1, pt1]
            cond_pruned[pt1, pt1] = 0
            M = aspreconditioner(SmoothedAggregationSolver(cond_pruned))
        end
        for j = i+1:numpoints
            if (i,j) in exclude
                continue
            end
            if c[i] == 0
                resistances[i,j] = resistances[j,i] = -1
                continue
            end
            pt2 = ingraph(cc[rcc], c[j])
            if pt2 == 0
                continue
            end
            debug("pt1 = $pt1, pt2 = $pt2")
            p +=1
            curr = z[rcc]
            v = volt[rcc]
            if pt1 != pt2
                curr[pt1] = -1
                curr[pt2] = 1
                cg!(v, cond_pruned, curr, M; tol = 1e-6, maxiter = 100000)
                curr[:] = 0
            end
            postprocess(v, c, i, j, resistances, pt1, pt2, cond_pruned, cc[rcc], cfg; 
                                            nodemap = nodemap, 
                                            orig_pts = orig_pts,
                                            polymap = polymap,
                                            hbmeta = hbmeta)
            v[:] = 0
        end
        cond_pruned[pt1,pt1] = d
    end
    debug("solved $p equations")
    for i = 1:size(resistances,1)
        resistances[i,i] = 0
    end
    resistances
end

@inline function rightcc{T}(cc::Vector{Vector{T}}, c::T)
    for i in eachindex(cc)
        if c in cc[i]
            return i
        end
    end
end

@inline function ingraph{T}(cc::Vector{T}, c::T)
    findfirst(cc, c)
end

function laplacian(G::SparseMatrixCSC)
    G = G - spdiagm(diag(G))
    G = -G + spdiagm(vec(sum(G, 1)))
end

function postprocess(volt, cond, i, j, resistances, pt1, pt2, cond_pruned, cc, cfg; 
                                            nodemap = Matrix{Float64}(), 
                                            orig_pts = Vector{Int}(), 
                                            polymap = Vector{Float64}(),
                                            hbmeta = hbmeta)

    r = resistances[i, j] = resistances[j, i] = volt[pt2] - volt[pt1]
    name = "$(cond[i])_$(cond[j])"
    if cfg["data_type"] == "raster"
        name = "$(Int(orig_pts[i]))_$(Int(orig_pts[j]))"
    end

    if cfg["write_volt_maps"] == "True"
        local_nodemap = zeros(Int, nodemap)
        idx = findin(nodemap, cc)
        local_nodemap[idx] = nodemap[idx]
        if isempty(polymap)
            idx = find(local_nodemap)
            local_nodemap[idx] = 1:length(idx)
        else
            local_polymap = zeros(local_nodemap)
            local_polymap[idx] = polymap[idx]
            local_nodemap = construct_node_map(local_nodemap, local_polymap)
        end
        write_volt_maps(name, volt, cc, local_nodemap, cfg, hbmeta)
    end

    if cfg["write_cur_maps"] == "True"
        local_nodemap = zeros(Int, nodemap)
        idx = findin(nodemap, cc)
        local_nodemap[idx] = nodemap[idx]
        if isempty(polymap)
            idx = find(local_nodemap)
            local_nodemap[idx] = 1:length(idx)
        else
            local_polymap = zeros(local_nodemap)
            local_polymap[idx] = polymap[idx]
            local_nodemap = construct_node_map(local_nodemap, local_polymap)
        end
        write_cur_maps(cond_pruned, volt, [-9999.], cc, name, cfg; 
                                    nodemap = local_nodemap, 
                                    hbmeta = hbmeta)
    end
end

function compute_network(a)

    network_file = a["habitat_file"]
    point_file = a["point_file"]
    A = read_graph(a, network_file)
    g = Graph(A)
    scenario = a["scenario"]

    if scenario == "pairwise"

        fp = read_focal_points(point_file)
        resistances = single_ground_all_pair_resistances(A, g, fp, a)
        resistances_3col = compute_3col(resistances, fp)
        return resistances

    elseif scenario == "advanced"

        source_file = a["source_file"]
        ground_file = a["ground_file"]
        source_map = read_point_strengths(source_file)
        ground_map = read_point_strengths(ground_file)
        cc = connected_components(g)
        debug("There are $(size(A, 1)) points and $(length(cc)) connected components")
        voltages = advanced(a, A, g, source_map, ground_map, cc)
        return voltages

    end
end

function advanced(cfg, a::SparseMatrixCSC, g::Graph, source_map, ground_map, cc; 
                    nodemap = Array{Float64,2}(), policy = :keepall, check_node = -1)

    mode = cfg["data_type"]
    if mode == "raster"
        (i1, j1, v1) = findnz(source_map)
        (i2, j2, v2) = findnz(ground_map)
        sources = zeros(size(a, 1))
        grounds = zeros(size(a, 1))
        for i = 1:size(i1, 1)
            v = Int(nodemap[i1[i], j1[i]])
            if v != 0
                sources[v] += v1[i]
            end
        end
        for i = 1:size(i2, 1)
            v = Int(nodemap[i2[i], j2[i]])
            if v != 0
                grounds[v] += v2[i]
            end
        end
        sources, grounds, finitegrounds = resolve_conflicts(sources, grounds, policy)
        volt = zeros(size(nodemap))
        ind = find(nodemap)
        f_local = Float64[]
        solver_called = false
        for c in cc
            if check_node != -1 && !(check_node in c)
                continue
            end
            a_local = laplacian(a[c, c])
            s_local = sources[c]
            g_local = grounds[c]
            if sum(s_local) == 0 || sum(g_local) == 0
                continue
            end
            if finitegrounds != [-9999.]
                f_local = finitegrounds[c]
            else
                f_local = finitegrounds
            end
            voltages = multiple_solver(a_local, g, s_local, g_local, f_local)
            solver_called = true
            for i in eachindex(volt)
                if i in ind
                    val = Int(nodemap[i])
                    if val in c
                        idx = findfirst(x -> x == val, c)
                        volt[i] = voltages[idx] 
                    end
                end
            end
        end
        scenario = cfg["scenario"]
        if !solver_called
            return [-1.]
        end
        if scenario == "one-to-all" 
            idx = find(source_map)
            val = volt[idx] / source_map[idx]
            if val[1] ≈ 0
                return [-1.]
            else
                return val
            end
        elseif scenario == "all-to-one"
            return [0.]
        end
        return volt
    else
        a = laplacian(a)
        v = zeros(size(a, 1))
        ground_vals = ground_map[:,2]
        ind_zeros = find(x -> x == 0, ground_map[:,2]) 
        ind_nzeros = find(x -> x != 0, ground_map[:,2]) 
        finitegrounds = zeros(1)
        if length(ind_nzeros) == 0
            finitegrounds = [-9999.]
        end
        is_res = cfg["ground_file_is_resistances"]
        if is_res == "True"
            ground_vals = 1 ./ ground_vals
        end
        for i in eachindex(ground_vals)
            if ground_vals[i] == Inf
                ground_vals[i] = 0
            end
        end
        if finitegrounds[1] != -9999
            a = a + spdiagm(ground_vals, 0, size(a, 1), size(a, 1))
        end
        for i in ind_zeros
            a = del_row_col(a, Int(ground_map[i,1]))
        end
        M = aspreconditioner(SmoothedAggregationSolver(a))
        curr = zeros(size(a, 1))
        curr_indices = Int.(source_map[:,1])
        curr[curr_indices] = source_map[:,2]
        volt = cg(a, curr, M; tol = 1e-6, maxiter = 100000)
        ground_indices = ground_map[:,1]
        k = 1
        ground_zeros = ground_indices[ind_zeros]
        for i = 1:size(v, 1)
            if i in ground_zeros
                continue
            else
                v[i] = volt[1][k]
                k += 1
            end
        end
        return v
    end
end

function del_row_col(a, n::Int)
    l = size(a, 1)
    ind = union(1:n-1, n+1:l)
    a[ind, ind]
end

function resolve_conflicts(sources, grounds, policy)

    finitegrounds = similar(sources)
    l = size(sources, 1)

    finitegrounds = map(x -> x < Inf ? x : 0., grounds)
    if count(x -> x != 0, finitegrounds) == 0
        finitegrounds = [-9999.]
    end

    conflicts = falses(l)
    for i = 1:l
        conflicts[i] = sources[i] != 0 && grounds[i] != 0
    end

    if any(conflicts)
        if policy == :rmvsrc
            sources[find(conflicts)] = 0
        elseif policy == :rmvgnd
            grounds[find(conflicts)] = 0    
        elseif policy == :rmvall
            sources[find(conflicts)] = 0    
        end
    end

    infgrounds = map(x -> x == Inf, grounds)
    infconflicts = map((x,y) -> x > 0 && y > 0, infgrounds, sources)
    grounds[infconflicts] = 0


    sources, grounds, finitegrounds
end


function multiple_solver(a, g, sources, grounds, finitegrounds)

    asolve = deepcopy(a)
    if finitegrounds[1] != -9999
        asolve = a + spdiagm(finitegrounds, 0, size(a, 1), size(a, 1))
    end

    infgrounds = find(x -> x == Inf, grounds)
    deleteat!(sources, infgrounds)
    dst_del = Int[]
    append!(dst_del, infgrounds)
    r = collect(1:size(a, 1))
    deleteat!(r, dst_del)
    asolve = asolve[r, r]

    M = aspreconditioner(SmoothedAggregationSolver(asolve))
    volt = cg(asolve, sources, M; tol = 1e-6, maxiter = 100000)

    # Replace the inf with 0
    voltages = zeros(length(volt[1]) + length(infgrounds))
    k = 1
    for i = 1:size(voltages, 1)
        if i in infgrounds
            voltages[i] = 0
        else
            voltages[i] = volt[1][k]
            k += 1
        end
    end
    voltages
end
