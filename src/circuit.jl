# Copyright 2015, 2016, 2017 Martin Holters
# See accompanying license file.

export Circuit, add!, connect!

const Net = Vector{Tuple{Int,Int}} # each net is a list of branch/polarity pairs

#struct Circuit
@struct Circuit begin
    elements :: Vector{Element}
    nets :: Vector{Net}
    net_names :: Dict{Symbol, Net}
    Circuit() = new([], [], Dict{Symbol, Net}())
end

for n in [:nb; :nx; :nq; :nu; :nl; :ny; :nn]
    @eval ($n)(c::Circuit) = sum([$n(elem) for elem in c.elements])
end

for mat in [:mv; :mi; :mx; :mxd; :mq; :mu; :pv; :pi; :px; :pxd; :pq]
    # blkdiag() does not work, so include an empty matrix of desired type in
    # case c.elements is empty
    # as blkdiag for unknown number of arguments cannot be inferred properly,
    # add type-assertion
    @eval ($mat)(c::Circuit) =
         blkdiag(spzeros(Rational{BigInt}, 0, 0),
                 [convert(SparseMatrixCSC{Rational{BigInt}}, elem.$mat)
                  for elem in c.elements]...
                )::SparseMatrixCSC{Rational{BigInt},Int}
end

u0(c::Circuit) = vcat([elem.u0 for elem in c.elements]...)

function incidence(c::Circuit)
    i = sizehint!(Int[], 2nb(c))
    j = sizehint!(Int[], 2nb(c))
    v = sizehint!(Int[], 2nb(c))
    for (row, pins) in enumerate(c.nets), (branch, polarity) in pins
        push!(i, row)
        push!(j, branch)
        push!(v, polarity)
    end
    # ensure zeros due to short-circuited branches are removed, hence the
    # additional sparse(findnz(...))
    sparse(findnz(sparse(i,j,v))..., length(c.nets), nb(c))
end

function nonlinear_eq(c::Circuit, elem_idxs=1:length(c.elements))
    # construct a block expression containing all element's expressions after
    # offsetting their indexes into q, J and res

    row_offset = 0
    col_offset = 0
    nl_expr = Expr(:block)
    for elem in c.elements[elem_idxs]
        index_offsets = Dict( :q => (col_offset,),
                              :J => (row_offset, col_offset),
                              :res => (row_offset,) )

        function offset_indexes(expr::Expr)
            ret = Expr(expr.head)
            ret.typ = expr.typ
            if expr.head == :ref && haskey(index_offsets, expr.args[1])
                push!(ret.args, expr.args[1])
                offsets = index_offsets[expr.args[1]]
                length(expr.args) == length(offsets) + 1 ||
                    throw(ArgumentError(string(expr.args[1], " must be indexed with exactly ", length(offsets), " index(es)")))
                for i in 1:length(offsets)
                    push!(ret.args,
                          :($(offsets[i]) + $(offset_indexes(expr.args[i+1]))))
                end
            else
                append!(ret.args, map(offset_indexes, expr.args))
            end
            ret
        end

        function offset_indexes(s::Symbol)
            haskey(index_offsets, s) && throw(ArgumentError(string(s, " used without indexing expression")))
            s
        end

        offset_indexes(x::Any) = x

        # wrap into a let to keep variables local
        push!(nl_expr.args, :( let; $(offset_indexes(elem.nonlinear_eq)) end))

        row_offset += nn(elem)
        col_offset += nq(elem)
    end
    nl_expr
end

function add!(c::Circuit, elem::Element)
    elem ∈ c.elements && return
    b_offset = nb(c)
    push!(c.elements, elem)
    for branch_pols in values(elem.pins)
        push!(c.nets, [(b_offset + b, pol) for (b, pol) in branch_pols])
    end
    nothing
end

add!(c::Circuit, elems::Element...) = for elem in elems add!(c, elem) end

function branch_offset(c::Circuit, elem::Element)
    offset = 0
    for el in c.elements
        el == elem && return offset
        offset += nb(el)
    end
    throw(ArgumentError("Element not found in circuit"))
end

function netfor!(c::Circuit, p::Pin)
    element = p[1]
    add!(c, element)
    b_offset = branch_offset(c, element)
    for (branch, pol) in p[2], net in c.nets
        (branch + b_offset, pol) ∈ net && return net
    end
end

function netfor!(c::Circuit, name::Symbol)
    haskey(c.net_names, name) || push!(c.nets, get!(c.net_names, name, []))
    c.net_names[name]
end

function connect!(c::Circuit, pins::Union{Pin,Symbol}...)
    nets = unique([netfor!(c, pin) for pin in pins])
    for net in nets[2:end]
        append!(nets[1], net)
        deleteat!(c.nets, findfirst(n -> n == net, c.nets))
        for (name, named_net) in c.net_names
            if named_net == net
                c.net_names[name] = nets[1]
            end
        end
    end
end

# lines marked with !SV avoid creation of SparseVector by indexing with Ranges
# instead of Ints; a better way for cross-julia-version compatibilty would be
# nice; maybe Compat helps in the future...
@pfunction topomat!(incidence::SparseMatrixCSC{T}) [T<:Integer] begin
    @assert all(x -> abs(x) == 1, nonzeros(incidence))
    @assert all(sum(incidence, 1) .== 0)

    t = falses(size(incidence)[2]);

    row = 1;
    for col = 1:size(incidence)[2]
        rows = filter(r -> r ≥ row, find(!iszero, incidence[:, col]))
        @assert length(rows) ≤ 2

        isempty(rows) && continue
        t[col] = true;

        if rows[1] ≠ row
            incidence[[rows[1], row], :] = incidence[[row, rows[1]], :]
        end
        if length(rows) == 2
            @assert incidence[row, col] + incidence[rows[2], col] == 0
            incidence[rows[2],:] = incidence[rows[2],:] + incidence[row,:]
        end
        if incidence[row, col] < 0
            cols = find(!iszero, incidence[row, :])
            incidence[row,cols] = -incidence[row,cols]
        end
        rows = find(incidence[1:row-1, col] .== 1)
        incidence[rows, :] .-= incidence[row:row, :] # !SV
        rows = find(incidence[1:row-1, col] .== -1)
        incidence[rows, :] .+= incidence[row:row, :] # !SV
        row += 1
    end

    ti = incidence[1:row-1, :]

    dl = ti[:, broadcast(!, t)]
    tv = spzeros(T, size(dl, 2), size(incidence, 2))
    tv[:, t] = -dl.'
    tv[:, broadcast(!, t)] = speye(T, size(dl, 2))

    tv, ti
end

@pfunction topomat(incidence::SparseMatrixCSC{T}) [T<:Integer] begin
    topomat!(copy(incidence))
 end
topomat(c::Circuit) = topomat!(incidence(c))