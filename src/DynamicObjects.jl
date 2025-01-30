module DynamicObjects
export @dynamicstruct, @staticstruct

serialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")
deserialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")

mutable struct Cache
    cache::NamedTuple
end
Base.hasproperty(c::Cache, name::Symbol) = hasproperty(getfield(c, :cache), name)
Base.getproperty(c::Cache, name::Symbol) = getfield(getfield(c, :cache), name)
Base.setproperty!(c::Cache, name::Symbol, x) = setfield!(c, :cache, merge(getfield(c, :cache), (;name=>x)))
getorcomputeproperty(o, name; force=false) = if hasfield(typeof(o), name)
    getfield(o, name)
elseif hasproperty(getfield(o, :cache), name) && !force
    getproperty(getfield(o, :cache), name)
else
    vname = Val(name)
    rv = if iscached(o, vname)
        cache_path = joinpath(o.cache_path, "$name.sjl")
        mkpath(dirname(cache_path))
        if isfile(cache_path)
            rv = deserialize(cache_path)
            if resumes(o, vname) || force
                rv = compute_property(o, vname, rv)
                serialize(cache_path, rv)
                rv
            else
                rv
            end
        else
            println("Generating $cache_path...")
            rv = compute_property(o, vname) 
            serialize(cache_path, rv)
            rv
        end
    else
        compute_property(o, vname)
    end
    setproperty!(getfield(o, :cache), name, rv)
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
function utime end
function isuptodate end
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
        !isnothing(locals) && push!(locals, name)
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
            Base.hasproperty(o::$type, name::Symbol) = name in $(keys(properties))
            Base.getproperty(o::$type, name::Symbol) = DynamicObjects.getorcomputeproperty(o, name)
            DynamicObjects.meta(::Type{$type}) = $properties
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
                DynamicObjects.compute_property(o::$type, ::Val{$(Meta.quot(name))}, $(name)=nothing) = $(info.rhs)
                DynamicObjects.iscached(o::$type, ::Val{$(Meta.quot(name))}) = $(Symbol("@cached") in info.macros)
                DynamicObjects.resumes(o::$type, ::Val{$(Meta.quot(name))}) = $(name in info.dependson)
                # DynamicObjects.utime(o::$type, ::Val{$(Meta.quot(name))}) = max($([
                #     :(DynamicObjects.utime(o, Val($(Meta.quot(dep))))) for dep in info.dependson
                # ]...))
            end
            for (name, info) in properties if !isfixed(info)
        ]...,
    ))
end

ereplace(e::Expr; d) = e in keys(d) ? d[e] : Expr(e.head, ereplace.(e.args; d)...)
ereplace(e; d) = e in keys(d) ? d[e] : e
const self_symbol = gensym("self")
const T_symbol = gensym("T")
macro staticstruct(expr)
    @assert expr.head == :struct
    mut, head, body = expr.args
    type, T = if Meta.isexpr(head, :(curly))
        head.args[1], head.args[2:end]
    else
        @assert isa(head, Symbol)
        head, []
    end
    @assert body.head == :block
    names = []
    sig = []
    d = Dict{Symbol,Any}(:self=>self_symbol)
    funcs = []
    for i in eachindex(body.args)
        arg = body.args[i]
        isa(arg, LineNumberNode) && continue
        lhs, rhs = if Meta.isexpr(arg, :(=))
            arg.args
        else
            arg, nothing
        end
        if Meta.isexpr(lhs, :call)
            insert!(lhs.args, 2, Expr(:(::), self_symbol, type))
            push!(funcs, Expr(
                :(=), 
                lhs, 
                ereplace(rhs; d)
            ))
            body.args[i] = nothing 
            continue
        end
        name, typei = if Meta.isexpr(lhs, :(::))
            lhs.args
        else
            push!(T, Symbol(T_symbol, i))
            lhs, T[end]
        end
        body.args[i] = Expr(:(::), name, typei)
        sigi = if isnothing(rhs)
            body.args[i]
        else
            Expr(:kw, body.args[i], rhs)
        end
        push!(names, name)
        d[name] = :($self_symbol.$name)
        push!(sig, sigi)
    end
    push!(body.args, :($type($(sig...)) where {$(T...)} = new{$(T...)}($(names...))))
    esc(Expr(:block, Expr(:struct, mut, Expr(:curly, type, T...), body), funcs...))
end

end
