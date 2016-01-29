# Copyright 2016 Martin Holters
# See accompanying license file.

type KDTree{Tcv<:AbstractVector,Tp<:AbstractMatrix}
    cut_dim::Vector{Int}
    cut_val::Tcv
    ps_idx::Vector{Int}
    ps::Tp
end

function KDTree(p::AbstractMatrix)
    if size(p)[2] == 0
        return KDTree{Vector{eltype(p)},typeof(p)}([], [], [], p)
    end

    depth = ceil(Int, log2(size(p)[2]))
    min_idx = zeros(Int, 2^depth-1)
    max_idx = zeros(Int, 2^depth-1)
    cut_idx = zeros(Int, 2^depth-1)
    cut_dim = zeros(Int, 2^depth-1)
    cut_val = zeros(eltype(p), 2^depth-1)

    if depth == 0
        return KDTree{typeof(cut_val),typeof(p)}(cut_dim, cut_val, [1], p)
    end

    dim = indmax(var(p,2))
    p_idx = sortperm(vec(p[dim,:]))

    min_idx[1] = 1
    max_idx[1] = size(p)[2]
    cut_idx[1] = div(size(p)[2]+1, 2)
    cut_dim[1] = dim
    cut_val[1] = p[dim, p_idx[cut_idx[1]]]

    for n in 2:2^depth-1
        parent_n = div(n, 2)
        if mod(n, 2) == 0
            min_idx[n] = min_idx[parent_n]
            max_idx[n] = cut_idx[parent_n]
        else
            min_idx[n] = cut_idx[parent_n]+1
            max_idx[n] = max_idx[parent_n]
        end
        dim = indmax(var(p[:,p_idx[min_idx[n]:max_idx[n]]],2))
        idx = sortperm(vec(p[dim,p_idx[min_idx[n]:max_idx[n]]]))
        p_idx[min_idx[n]:max_idx[n]] = p_idx[idx + min_idx[n] - 1]
        cut_idx[n] = div(min_idx[n]+max_idx[n], 2)
        cut_dim[n] = dim
        cut_val[n] = p[dim, p_idx[cut_idx[n]]]
    end

    p_idx_final = zeros(Int, 1, 2^depth)
    for n in 1:2^depth
        parent_n = div(n+2^depth-1, 2);
        if mod(n,2) == 1
            p_idx_final[n] = p_idx[min_idx[parent_n]]
        else
            p_idx_final[n] = p_idx[max_idx[parent_n]]
        end
    end

    return KDTree{typeof(cut_val),typeof(p)}(cut_dim, cut_val, vec(p_idx_final), p)
end

type Alts{T}
    idx::Vector{Int}
    delta::Vector{Vector{T}}
    delta_norms::Vector{T}
    best_dist::T
    best_pidx::Int
end

Alts{T}(p::Vector{T}) =
    Alts([1], [zeros(T, length(p)) for i in 1], zeros(T, 1), typemax(T), 0)

find_best_pos(alts) = indmin(alts.delta_norms)

function deletepos!(alts, pos)
    last_idx = length(alts.idx)
    alts.idx[pos] = alts.idx[last_idx]
    deleteat!(alts.idx, last_idx)
    alts.delta_norms[pos] = alts.delta_norms[last_idx]
    deleteat!(alts.delta_norms, last_idx)
    alts.delta[pos] = alts.delta[last_idx]
    deleteat!(alts.delta, last_idx)
end

function push_alt!(alts, new_idx, new_delta, new_delta_norm=sumabs2(new_delta))
    if new_delta_norm < alts.best_dist
        push!(alts.idx, new_idx)
        push!(alts.delta_norms, new_delta_norm)
        push!(alts.delta, new_delta)
    end
end

function update_best_dist!(alts, dist, p_idx)
    if dist < alts.best_dist
        alts.best_dist = dist
        alts.best_pidx = p_idx
        i = length(alts.delta_norms)
        while i > 0
            if alts.delta_norms[i] .≥ alts.best_dist
                last_idx = length(alts.delta_norms)
                if last_idx ≠ i
                    alts.idx[i] = alts.idx[last_idx]
                    alts.delta_norms[i] = alts.delta_norms[last_idx]
                    alts.delta[i] = alts.delta[last_idx]
                end
                deleteat!(alts.idx, last_idx)
                deleteat!(alts.delta_norms, last_idx)
                deleteat!(alts.delta, last_idx)
            end
            i -= 1
        end
    end
end

indnearest(tree::KDTree, p::AbstractVector, alt = Alts(p)) =
    indnearest(tree, p, typemax(Int), alt)

function indnearest(tree::KDTree, p::AbstractVector, max_leaves::Int,
                    alt = Alts(p))
    depth = round(Int, log2(length(tree.cut_dim)+1))

    l = 0
    p_idx = 0
    while l < max_leaves && ~isempty(alt.idx)
        best_pos = find_best_pos(alt)
        idx = alt.idx[best_pos]
        delta = alt.delta[best_pos]
        delta_norm = alt.delta_norms[best_pos]
        deletepos!(alt, best_pos)

        start_depth = floor(Int, log2(idx)) + 1

        for d in 1:depth - start_depth + 1
            dim = tree.cut_dim[idx]
            new_alt_delta_norm = delta_norm - delta[dim]^2 + (p[dim] - tree.cut_val[idx])^2
            if new_alt_delta_norm < alt.best_dist
                new_alt_delta = copy(delta)
                new_alt_delta[dim] = p[dim] - tree.cut_val[idx]
                if p[dim] ≤ tree.cut_val[idx]
                    push_alt!(alt, 2idx+1, new_alt_delta, new_alt_delta_norm)
                else
                    push_alt!(alt, 2idx, new_alt_delta, new_alt_delta_norm)
                end
            end
            if p[dim] ≤ tree.cut_val[idx]
                idx *= 2
            else
                idx = 2idx + 1
            end
        end
        idx -= 2^depth - 1

        p_idx = tree.ps_idx[idx]
        dist = 0.
        for i in 1:length(p)
            dist += (p[i] - tree.ps[i, p_idx])^2
        end
        update_best_dist!(alt, dist, p_idx)

        l += 1
    end

    return alt.best_pidx, alt
end
