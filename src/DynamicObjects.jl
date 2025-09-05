module DynamicObjects
export @dynamicstruct

serialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")
deserialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")

mutable struct Cache
    cache::NamedTuple
end
Base.hasproperty(c::Cache, name::Symbol) = hasproperty(getfield(c, :cache), name)
Base.getproperty(c::Cache, name::Symbol) = getfield(getfield(c, :cache), name)
Base.setproperty!(c::Cache, name::Symbol, x) = setfield!(c, :cache, merge(getfield(c, :cache), (;name=>x)))
struct IndexableProperty{N,O}
    o::O
    cache::Dict
    IndexableProperty(N,o,cache=Dict()) = new{N,typeof(o)}(o, cache)
end
Base.getindex((;o, cache)::IndexableProperty{name}, indices...) where {name} = get!(cache, indices) do
    getorcomputeproperty(o, name, indices...)
end
getorcomputeproperty(o, name, indices...; force=false) = if hasfield(typeof(o), name)
    @assert length(indices) == 0
    getfield(o, name)
elseif length(indices) == 0 && hasproperty(getfield(o, :cache), name) && !force
    getproperty(getfield(o, :cache), name)
else
    vname = Val(name)
    rv = if iscached(o, vname, indices...)
        cache_path = joinpath(o.cache_path, join((name, indices...), "_") * ".sjl")
        mkpath(dirname(cache_path))
        if isfile(cache_path)
            rv = deserialize(cache_path)
            if resumes(o, vname, indices...) || force
                rv = compute_property(o, vname, indices...; (name=>rv, )...)
                serialize(cache_path, rv)
                rv
            else
                rv
            end
        else
            @debug "Generating $cache_path..."
            rv = compute_property(o, vname, indices...) 
            serialize(cache_path, rv)
            rv
        end
    else
        compute_property(o, vname, indices...)
    end
    length(indices) == 0 && setproperty!(getfield(o, :cache), name, rv)
    rv
end
isfixed(kv::Pair) = isfixed(kv[2])
isfixed(info::NamedTuple) = isnothing(info.rhs)
walk_rhs(e; kwargs...) = e
walk_rhs(e::Expr; dependent, properties) = if e.head == :let
    locals = properties[dependent].locals
    ls = Set{Symbol}()
    !Meta.isexpr(e.args[1], :block) && (e.args[1] = Expr(:block, e.args[1]))
    map!(e.args[1].args, e.args[1].args) do arg 
        isa(arg, Symbol) && (arg = Expr(:(=), arg, arg))
        @assert Meta.isexpr(arg, :(=))
        name, rhs = arg.args[1], walk_rhs(arg.args[2]; dependent, properties)
        name in locals || push!(ls, name)
        push!(locals, name)
        Expr(:(=), name, rhs)
    end
    e.args[2] = walk_rhs(e.args[2]; dependent, properties)
    for l in ls
        delete!(locals, l)
    end
    e
elseif e.head == :kw
    Expr(e.head, e.args[1], walk_rhs.(e.args[2:end]; dependent, properties)...)
else
    Expr(e.head, walk_rhs.(e.args; dependent, properties)...)
end
walk_rhs(e::Symbol; dependent, properties) = if e in keys(properties) && !(e in properties[dependent].locals)
    isfixed(properties[e]) || push!(properties[dependent].dependson, e)
    :(o.$e)
else
    e == dependent && push!(properties[dependent].dependson, e)
    e
end
function compute_property end
function iscached end
function resumes end
function meta end
macro dynamicstruct(expr)
    @assert expr.head == :struct
    mut, head, body = expr.args
    type = head
    Meta.isexpr(type, :(<:)) && (type = type.args[1])
    Meta.isexpr(type, :(curly)) && (type = type.args[1])
    @assert body.head == :block
    lnn = nothing
    oproperties = map(body.args) do arg
        if isa(arg, LineNumberNode)
            lnn = arg
            return
        end
        macros = Set{Symbol}()
        rhs = nothing
        dependson = nothing
        locals = nothing
        indices = tuple()
        while Meta.isexpr(arg, :macrocall)
            push!(macros, arg.args[1])
            arg = arg.args[end]
        end
        if Meta.isexpr(arg, :(=))
            arg, rhs = arg.args
            dependson = Set{Symbol}()
            locals = Set{Symbol}()
        end
        if Meta.isexpr(arg, :ref)
            arg, indices... = arg.args
            union!(locals, indices)
        end
        name = if Meta.isexpr(arg, :(::))
            arg.args[1]
        else
            arg
        end
        @assert isa(name, Symbol)
        !isnothing(locals) && push!(locals, name)
        @assert !isnothing(rhs) || length(macros) == 0
        name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices)
    end |> filter(!isnothing)
    properties = Dict(oproperties)
    for (dependent, info) in properties
        isfixed(info) && continue
        properties[dependent] = merge(info, (;rhs=walk_rhs(info.rhs; dependent, properties)))
    end
    esc(Expr(:block, 
        Expr(:struct, mut, head, Expr(:block, 
            [info.lhs for (name,info) in oproperties if isfixed(info)]..., :(cache::DynamicObjects.Cache),
            :($type(args...; kwargs...) = new(args..., DynamicObjects.Cache((;kwargs...))))
        )),
        quote
            Base.hasproperty(o::$type, name::Symbol) = name in $(keys(properties))
            Base.getproperty(o::$type, name::Symbol) = DynamicObjects.getorcomputeproperty(o, name)
            DynamicObjects.meta(::Type{$type}) = $properties
        end,
        [
            quote
                DynamicObjects.compute_property(o::$type, ::Val{$(Meta.quot(name))}, $(info.indices...); $(name)=nothing) = $(info.rhs)
                DynamicObjects.iscached(o::$type, ::Val{$(Meta.quot(name))}, $(info.indices...)) = $(Symbol("@cached") in info.macros)
                DynamicObjects.resumes(o::$type, ::Val{$(Meta.quot(name))}, $(info.indices...)) = $(name in info.dependson)
            end
            for (name, info) in properties if !isfixed(info)
        ]...,
        [
            quote
                DynamicObjects.iscached(o::$type, ::Val{$(Meta.quot(name))}) = false
                DynamicObjects.compute_property(o::$type, ::Val{$(Meta.quot(name))}) = DynamicObjects.IndexableProperty($(Meta.quot(name)), o)
            end
            for (name, info) in properties if length(info.indices) > 0
        ]...,
    ))
end

end