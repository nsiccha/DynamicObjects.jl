module DynamicObjects
export @dynamicstruct
import Serialization

mutable struct Cache
    cache::NamedTuple
end
Base.hasproperty(c::Cache, name::Symbol) = hasproperty(getfield(c, :cache), name)
Base.getproperty(c::Cache, name::Symbol) = getfield(getfield(c, :cache), name)
Base.setproperty!(c::Cache, name::Symbol, x) = setfield!(c, :cache, merge(getfield(c, :cache), (;name=>x)))
getorcomputeproperty(o, name) = if hasfield(typeof(o), name)
    getfield(o, name)
elseif hasproperty(getfield(o, :cache), name)
    getproperty(getfield(o, :cache), name)
else
    vname = Val(name)
    rv = if iscached(o, vname)
        cache_path = joinpath(o.cache_path, "$name.sjl")
        mkpath(dirname(cache_path))
        if isfile(cache_path)
            Serialization.deserialize(cache_path)
        else
            println("Generating $cache_path...")
            rv = compute_property(o, vname) 
            Serialization.serialize(cache_path, rv)
            rv
        end
    else
        compute_property(o, vname)
    end
    setproperty!(getfield(o, :cache), name, rv)
    rv
end
# replace_properties(e; properties) = e
replace_properties(e::Symbol; properties) = e in properties ? :(o.$e) : e
replace_properties(e::Expr; properties) = Expr(e.head, replace_properties.(e.args; properties)...)
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
else
    Expr(e.head, walk_rhs.(e.args; dependent, properties)...)
end
walk_rhs(e::Symbol; dependent, properties) = if e in keys(properties) && !(e in properties[dependent].locals)
    isfixed(properties[e]) || push!(properties[dependent].dependson, e)
    :(o.$e)
else
    e
end
function compute_property end
iscached(o, v) = error()
function utime end
function isuptodate end
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
        while Meta.isexpr(arg, :macrocall)
            push!(macros, arg.args[1])
            arg = arg.args[end]
        end
        if Meta.isexpr(arg, :(=))
            arg, rhs = arg.args
            dependson = Set{Symbol}()
            locals = Set{Symbol}()
        end
        name = if Meta.isexpr(arg, :(::))
            arg.args[1]
        else
            arg
        end
        @assert !isnothing(rhs) || length(macros) == 0
        name=>(;lhs=arg, macros, rhs, lnn, dependson, locals)
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
            Base.getproperty(o::$type, name::Symbol) = DynamicObjects.getorcomputeproperty(o, name)
            # Base.show(io::IO, o::$type) = 
        end,
        [
            quote
                # DynamicObjects.isuptodate(o::$type, ::Val{$(Meta.quot(name))}) = true
                # DynamicObjects.utime(o::$type, ::Val{$(Meta.quot(name))}) = 0
            end
            for (name, info) in properties if isfixed(info)
        ]...,
        [
            quote
                DynamicObjects.compute_property(o::$type, ::Val{$(Meta.quot(name))}) = $(info.rhs)
                DynamicObjects.iscached(o::$type, ::Val{$(Meta.quot(name))}) = $(Symbol("@cached") in info.macros)
                # DynamicObjects.utime(o::$type, ::Val{$(Meta.quot(name))}) = max($([
                #     :(DynamicObjects.utime(o, Val($(Meta.quot(dep))))) for dep in info.dependson
                # ]...))
            end
            for (name, info) in properties if !isfixed(info)
        ]...,
    ))
end
end
