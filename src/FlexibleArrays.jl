module FlexibleArrays

# using Base.Cartesian

export AbstractFlexArray
abstract AbstractFlexArray{T,N} <: DenseArray{T,N}

# eltype, ndims are provided by DenseArray

export lbnd, ubnd
import Base: size

size{n}(arr::AbstractFlexArray, ::Type{Val{n}}) =
    max(0, ubnd(arr, Val{n}) - lbnd(arr, Val{n}) + 1)
size{T <: AbstractFlexArray, n}(arr::Type{T}, ::Type{Val{n}}) =
    max(0, ubnd(T, Val{n}) - lbnd(T, Val{n}) + 1)

lbnd(arr::AbstractFlexArray, n::Int) = lbnd(arr, Val{n})
ubnd(arr::AbstractFlexArray, n::Int) = ubnd(arr, Val{n})
size(arr::AbstractFlexArray, n::Int) = size(arr, Val{n})

lbnd{T <: AbstractFlexArray}(arr::Type{T}, n::Int) = lbnd(T, Val{n})
ubnd{T <: AbstractFlexArray}(arr::Type{T}, n::Int) = ubnd(T, Val{n})
size{T <: AbstractFlexArray}(arr::Type{T}, n::Int) = size(T, Val{n})

# Note: Use ntuple instead of generated functions once the closure in ntuple is
# efficient
# lbnd{T,N}(arr::AbstractFlexArray{T,N}) = ntuple(n->lbnd(arr, Val{n}), N)
@generated function lbnd(arr::AbstractFlexArray)
    Expr(:tuple, [:(lbnd(arr, Val{$n})) for n in 1:ndims(arr)]...)
end
# The Base.Cartesian macros expect literals, not parameters
# function lbnd{T,N}(arr::AbstractFlexArray{T,N})
#     @ntuple N n->lbnd(arr, Val{n})
# end
@generated function ubnd(arr::AbstractFlexArray)
    Expr(:tuple, [:(ubnd(arr, Val{$n})) for n in 1:ndims(arr)]...)
end
@generated function size(arr::AbstractFlexArray)
    Expr(:tuple, [:(size(arr, Val{$n})) for n in 1:ndims(arr)]...)
end

@generated function lbnd{T <: AbstractFlexArray}(::Type{T})
    Expr(:tuple, [:(lbnd(T, Val{$n})) for n in 1:ndims(T)]...)
end
@generated function ubnd{T <: AbstractFlexArray}(::Type{T})
    Expr(:tuple, [:(ubnd(T, Val{$n})) for n in 1:ndims(T)]...)
end
@generated function size{T <: AbstractFlexArray}(::Type{T})
    Expr(:tuple, [:(size(T, Val{$n})) for n in 1:ndims(T)]...)
end



import Base: show
@generated function show(io::IO, arr::AbstractFlexArray)
    inds = [symbol(:i,n) for n in 1:ndims(arr)]
    elt = Expr(:call, :getindex, :arr, inds...)
    stmt = :(print(io, $elt, " "))
    for n in ndims(arr):-1:1
        stmt = quote
            print(io, "[")
            for $(symbol(:i,n)) in lbnd(arr,$n):ubnd(arr,$n)
                $stmt
            end
            println(io, "]")
        end
    end
    stmt
end
# function show{T,N}(io::IO, arr::AbstractFlexArray{T,N})
#     bnds(n) = lbnd(arr,n):ubnd(arr,n)
#     pre(n) = print(io, "[")
#     post(n) = print(io, "[")
#     body(n) =
#     @nloops N i bnds pre post begin
#         print(io, (@nref N arr i), " ")
#     end
# end



import Base: convert, getindex, length, setindex!
export checkindices, linearindex



typealias BndSpec NTuple{2, Bool}

@generated function genFlexArray{T}(::Type{Val{T}})
    @assert isa(T, Tuple)
    N = length(T)
    @assert isa(T, NTuple{N, BndSpec})

    rank = N
    bndspecs = T

    fixed_lbnd = Bool[bndspecs[n][1] for n in 1:rank]
    fixed_ubnd = Bool[bndspecs[n][2] for n in 1:rank]
    fixed_stride = Vector{Bool}(rank+1)
    fixed_stride[1] = true
    for n in 2:rank+1
        fixed_stride[n] =
            fixed_stride[n-1] && fixed_lbnd[n-1] && fixed_ubnd[n-1]
    end
    fixed_length = fixed_stride[rank+1]
    fixed_offset = rank == 0 || fixed_stride[rank] && fixed_lbnd[rank]

    lbnd = [symbol(:lbnd,n) for n in 1:rank]
    ubnd = [symbol(:ubnd,n) for n in 1:rank]
    stride = [symbol(:stride,n) for n in 1:rank+1]

    decls = []

    # Type declaration

    # typename = gensym(:FlexArray)
    typename = symbol(prod(
        let
            names = ["FlexArrayImpl"]
            for n in 1:rank
                push!(names, string(Int(fixed_lbnd[n])))
                push!(names, string(Int(fixed_ubnd[n])))
            end
            names
        end))

    typeparams = []
    for n in 1:rank
        fixed_lbnd[n] && push!(typeparams, lbnd[n])
        fixed_ubnd[n] && push!(typeparams, ubnd[n])
        # push!(typeparams, fixed_lbnd[n] ? lbnd[n] : symbol(lbnd[n], "_dummy"))
        # push!(typeparams, fixed_ubnd[n] ? ubnd[n] : symbol(ubnd[n], "_dummy"))
    end
    push!(typeparams, :T)

    # Type name with parameters
    typenameparams = Expr(:curly, typename, typeparams...)

    push!(decls, Expr(:type, true #=mutable=#,
        Expr(:<:, typenameparams, :(AbstractFlexArray{T,$rank})),
        let
            body = []
            for n in 1:rank
                !fixed_lbnd[n] && push!(body, :($(lbnd[n])::Int))
                !fixed_ubnd[n] && push!(body, :($(ubnd[n])::Int))
                !fixed_stride[n] && push!(body, :($(stride[n])::Int))
            end
            !fixed_length && push!(body, :(length::Int))
            !fixed_offset && push!(body, :(offset::Int))
            # TODO: use a more low-level array representation
            push!(body, :(data::Vector{T}))
            push!(body, Expr(:(=),
                let
                    args = []
                    # Add a dummy Void argument to ensure that this constructor
                    # is not called accidentally
                    push!(args, :(::Void))
                    for n in 1:rank
                        !fixed_lbnd[n] && push!(args, :($(lbnd[n])::Int))
                        !fixed_ubnd[n] && push!(args, :($(ubnd[n])::Int))
                    end
                    Expr(:call, typename, args...)
                end,
                let
                    stmts = []
                    push!(stmts, :($(stride[1]) = 1))
                    for n in 2:rank+1
                        push!(stmts,
                            :($(stride[n]) =
                                $(stride[n-1]) *
                                max(0, $(ubnd[n-1]) - $(lbnd[n-1]) + 1)))
                    end
                    push!(stmts, :(length = $(stride[rank+1])))
                    if !fixed_offset
                        push!(stmts,
                            :(offset =
                                $(Expr(:call, :+, 0,
                                    [:($(stride[n]) * $(lbnd[n]))
                                        for n in 1:rank]...))))
                    end
                    push!(stmts,
                        let
                            args = []
                            for n in 1:rank
                                !fixed_lbnd[n] && push!(args, lbnd[n])
                                !fixed_ubnd[n] && push!(args, ubnd[n])
                                !fixed_stride[n] && push!(args, stride[n])
                            end
                            !fixed_length && push!(args, :length)
                            !fixed_offset && push!(args, :offset)
                            push!(args, :(Vector{T}(length)))
                            Expr(:call, :new, args...)
                        end)
                    Expr(:block, stmts...)
                end))
            Expr(:block, body...)
        end))

    # Constructor

    push!(decls, Expr(:(=),
        Expr(:call, Expr(:curly, :convert, typeparams...),
            :(::Type{$typenameparams}),
            let
                args = []
                for n in 1:rank
                    if fixed_lbnd[n]
                        if fixed_ubnd[n]
                            push!(args, :(::Colon))
                        else
                            push!(args, :($(ubnd[n])::Int))
                        end
                    else
                        if fixed_ubnd[n]
                            push!(args, :($(lbnd[n])::Tuple{Integer}))
                        else
                            push!(args, :($(symbol(:bnds,n))::UnitRange{Int}))
                        end
                    end
                end
                args
            end...),
        Expr(:call, typenameparams,
            let
                args = []
                push!(args, :nothing)
                for n in 1:rank
                    if fixed_lbnd[n]
                        if fixed_ubnd[n]
                        else
                            push!(args, ubnd[n])
                        end
                    else
                        if fixed_ubnd[n]
                            push!(args, :($(lbnd[n])[1]))
                        else
                            push!(args, :($(symbol(:bnds,n)).start))
                            push!(args, :($(symbol(:bnds,n)).stop))
                        end
                    end
                end
                args
            end...)))

    # Lower bound, upper bound, stride, length, offset

    for n in 1:rank
        if fixed_lbnd[n]
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :lbnd, typeparams...),
                    :(::$typenameparams), :(::Type{Val{$n}})),
                lbnd[n]))
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :lbnd, typeparams...),
                    :(::Type{$typenameparams}), :(::Type{Val{$n}})),
                lbnd[n]))
        else
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :lbnd, typeparams...),
                    :(arr::$typenameparams), :(::Type{Val{$n}})),
                :(arr.$(lbnd[n]))))
        end
    end

    for n in 1:rank
        if fixed_ubnd[n]
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :ubnd, typeparams...),
                    :(::$typenameparams), :(::Type{Val{$n}})),
                ubnd[n]))
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :ubnd, typeparams...),
                    :(::Type{$typenameparams}), :(::Type{Val{$n}})),
                ubnd[n]))
        else
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :ubnd, typeparams...),
                    :(arr::$typenameparams), :(::Type{Val{$n}})),
                :(arr.$(ubnd[n]))))
        end
    end

    for n in 1:rank
        if fixed_stride[n]
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :stride, typeparams...),
                    :(::$typenameparams), :(::Type{Val{$n}})),
                Expr(:block,
                    Expr(:meta, :inline),
                    Expr(:call, :*, 1,
                        [:(max(0, $(ubnd[m]) - $(lbnd[m]) + 1))
                            for m in 1:(n-1)]...))))
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :stride, typeparams...),
                    :(::Type{$typenameparams}), :(::Type{Val{$n}})),
                Expr(:block,
                    Expr(:meta, :inline),
                    Expr(:call, :*, 1,
                        [:(max(0, $(ubnd[m]) - $(lbnd[m]) + 1))
                            for m in 1:(n-1)]...))))
        else
            push!(decls, Expr(:(=),
                Expr(:call, Expr(:curly, :stride, typeparams...),
                    :(arr::$typenameparams), :(::Type{Val{$n}})),
                :(arr.$(stride[n]))))
        end
    end

    if fixed_length
        push!(decls, Expr(:(=),
            Expr(:call, Expr(:curly, :length, typeparams...),
                :(::$typenameparams)),
            Expr(:block,
                Expr(:meta, :inline),
                Expr(:call, :*, 1,
                    [:(max(0, $(ubnd[n]) - $(lbnd[n]) + 1))
                        for n in 1:rank]...))))
        push!(decls, Expr(:(=),
            Expr(:call, Expr(:curly, :length, typeparams...),
                :(::Type{$typenameparams})),
            Expr(:block,
                Expr(:meta, :inline),
                Expr(:call, :*, 1,
                    [:(max(0, $(ubnd[n]) - $(lbnd[n]) + 1))
                        for n in 1:rank]...))))
    else
        push!(decls, Expr(:(=),
            Expr(:call, Expr(:curly, :length, typeparams...),
                :(arr::$typenameparams)),
            :(arr.length)))
    end

    if fixed_offset
        push!(decls, Expr(:(=),
            Expr(:call, Expr(:curly, :offset, typeparams...),
                :(::$typenameparams)),
            Expr(:block,
                Expr(:meta, :inline),
                [Expr(:(=), stride[n],
                    n == 1 ?
                    1 :
                    :($(stride[n-1]) * max(0, $(ubnd[n-1]) - $(lbnd[n-1]) + 1)))
                    for n in 1:rank]...,
                Expr(:call, :+, 0,
                    [:($(stride[n]) * $(lbnd[n])) for n in 1:rank]...))))
        push!(decls, Expr(:(=),
            Expr(:call, Expr(:curly, :offset, typeparams...),
                :(::Type{$typenameparams})),
            Expr(:block,
                Expr(:meta, :inline),
                [Expr(:(=), stride[n],
                    n == 1 ?
                    1 :
                    :($(stride[n-1]) * max(0, $(ubnd[n-1]) - $(lbnd[n-1]) + 1)))
                    for n in 1:rank]...,
                Expr(:call, :+, 0,
                    [:($(stride[n]) * $(lbnd[n])) for n in 1:rank]...))))
    else
        push!(decls, Expr(:(=),
            Expr(:call, Expr(:curly, :offset, typeparams...),
                :(arr::$typenameparams)),
            :(arr.offset)))
    end

    # Array indexing

    # TODO: Define this as generated function once variable-length argument
    # lists are handled efficiently
    push!(decls, Expr(:(=),
        Expr(:call,
            Expr(:curly, :checkindices, typeparams...),
            :(arr::$typenameparams),
            [:($(symbol(:ind,n))::Int) for n in 1:rank]...),
        Expr(:call, :&,
            [:(lbnd(arr, Val{$n}) <= $(symbol(:ind,n)) <= ubnd(arr, Val{$n}))
                for n in 1:rank]...)))

    push!(decls, Expr(:(=),
        Expr(:call,
            Expr(:curly, :linearindex, typeparams...),
            :(arr::$typenameparams),
            [:($(symbol(:ind,n))::Int) for n in 1:rank]...),
        Expr(:block,
            Expr(:meta, :inline),
            Expr(:call, :+,
                [:($(symbol(:ind,n)) * stride(arr, Val{$n}))
                    for n in 1:rank]...,
                :(- offset(arr))))))

    push!(decls, Expr(:(=),
        Expr(:call,
            Expr(:curly, :getindex, typeparams...),
            :(arr::$typenameparams),
            [:($(symbol(:ind,n))::Int) for n in 1:rank]...),
        Expr(:block,
            Expr(:meta, :inline),
            Expr(:boundscheck, false),
            :(val = arr.data[$(Expr(:call, :linearindex, :arr,
                [symbol(:ind,n) for n in 1:rank]...)) + 1]),
            Expr(:boundscheck, :pop),
            :val)))

    push!(decls, Expr(:(=),
        Expr(:call,
            Expr(:curly, :setindex!, typeparams...),
            :(arr::$typenameparams),
            :val,
            [:($(symbol(:ind,n))::Int) for n in 1:rank]...),
        Expr(:block,
            Expr(:meta, :inline),
            :(arr.data[$(Expr(:call, :linearindex, :arr,
                [symbol(:ind,n) for n in 1:rank]...)) + 1] = val))))

    eval(Expr(:block, decls...))

    typename
end



@generated function genFlexArray(dimspecs...)
    @assert isa(dimspecs, Tuple)
    rank = length(dimspecs)
    bndspec = ntuple(rank) do n
        dimspec = dimspecs[n]
        if dimspec <: Union{Colon, Tuple{Void, Void}}
            (false, false)
        elseif dimspec <: Union{Integer, Tuple{Integer, Void}}
            (true, false)
        elseif dimspec <: Union{UnitRange, Tuple{Integer, Integer}}
            (true, true)
        elseif dimspec <: Tuple{Void, Integer}
            (false, true)
        else
            @assert false
        end
    end
    :(genFlexArray(Val{$bndspec}))
end



export FlexArray
@inline function FlexArray(dimspecs...)
    @assert isa(dimspecs, Tuple)
    rank = length(dimspecs)
    dims = []
    for n in 1:rank
        dimspec = dimspecs[n]
        if isa(dimspec, Colon) || isa(dimspec, Tuple{Void, Void})
            # push!(dims, Void)
            # push!(dims, Void)
        elseif isa(dimspec, Integer)
            push!(dims, Int(dimspec))
            # push!(dims, Void)
        elseif isa(dimspec, Tuple{Integer, Void})
            push!(dims, Int(dimspec[1]))
            # push!(dims, Void)
        elseif isa(dimspec, UnitRange)
            push!(dims, Int(dimspec.start))
            push!(dims, Int(dimspec.stop))
        elseif isa(dimspec, Tuple{Integer, Integer})
            push!(dims, Int(dimspec[1]))
            push!(dims, Int(dimspec[2]))
        elseif isa(dimspec, Tuple{Void, Integer})
            push!(dims, Int(dimspec[2]))
        else
            @assert false
        end
    end
    genFlexArray(dimspecs...){dims...}
end

end
