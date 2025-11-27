module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached

serialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")
deserialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")
persistent_hash(args...; kwargs...) = error("Hashing requires loading e.g. SHA.jl")
iscached(o, ::Val) = false
compute_property(o, ::Val{:hash_fields}) = ntuple(Base.Fix1(getfield, o), fieldcount(typeof(o))-1)
compute_property(o, ::Val{:hash}) = persistent_hash((typeof(o), o.hash_fields))
compute_property(o, ::Val{:cache_base}) = "cache"
compute_property(o, ::Val{:cache_path}) = joinpath(o.cache_base, o.hash)

struct PropertyCache{D<:AbstractDict{Symbol,Any}}
    cache::D
    PropertyCache(D, c::NamedTuple) = new{D{Symbol,Any}}(D{Symbol,Any}(pairs(c)))
end
Base.get!(f::Function, c::PropertyCache, key) = get!(f, c.cache, key)
Base.get!(f::Function, ::PropertyCache, key, indices...) = f()
struct IndexableProperty{N,O,D<:AbstractDict}
    o::O
    cache::D
    IndexableProperty(N,o,cache=Dict()) = new{N,typeof(o),typeof(cache)}(o, cache)
end
name(::IndexableProperty{N}) where {N} = N
Base.getindex((;o, cache)::IndexableProperty{name}, indices...) where {name} = get!(cache, indices) do
    getorcomputeproperty(o, name, indices...)
end
struct ThreadsafeDict{K,V} <: AbstractDict{K,V}
    lock::ReentrantLock
    cache::Dict{K,V}
    tasks::Dict{K,Task}
    ThreadsafeDict{K,V}(c) where {K,V} = new{K,V}(ReentrantLock(), Dict{K,V}(c), Dict{K,Task}())
    ThreadsafeDict() = new{Any,Any}(ReentrantLock(), Dict{Any,Any}(), Dict{Any,Task}())
end
Base.get!(f::Function, c::ThreadsafeDict, key) = begin
    rv = lock(c.lock) do
        get(c.cache, key) do 
            get!(c.tasks, key) do
                Threads.@spawn begin 
                    tmp = f()
                    lock(c.lock) do 
                        c.cache[key] = tmp
                    end
                    tmp
                end 
            end
        end
    end
    fetch(rv)
end
subcache(::PropertyCache{<:Dict}) = Dict()
subcache(::PropertyCache{<:ThreadsafeDict}) = ThreadsafeDict()

getorcomputeproperty(o, name, indices...) = if hasfield(typeof(o), name)
    @assert length(indices) == 0
    getfield(o, name)
else
    get!(getfield(o, :cache), name, indices...) do 
        vname = Val(name)
        if iscached(o, vname, indices...)
            cache_path = get_cache_path(o, name, indices...)
            mkpath(dirname(cache_path))
            cache_status = get_cache_status(cache_path)
            rv = if cache_status == :ready
                deserialize(cache_path) 
            elseif cache_status == :started
                @warn "Cache file $cache_path exists but has size 0.\nAssuming a previous run failed."
            else
                touch(cache_path)
                nothing
            end
            if cache_status != :ready || resumes(o, vname, indices...)
                @debug "Generating $cache_path..."
                rv = compute_property(o, vname, indices...; (name=>rv, )...)
                serialize(cache_path, rv)
            end
            rv
        else
            compute_property(o, vname, indices...)
        end
    end
end
get_cache_path(o, args...) = joinpath(o.cache_path, join(args, "_") * ".sjl")
get_cache_status(o, args...) = get_cache_status(get_cache_path(o, args...)) 
get_cache_status(cache_path::AbstractString) = begin
    !isfile(cache_path) && return :unstarted
    filesize(cache_path) == 0 && return :started
    return :ready
end
cache_status_expr(x) = begin
    x, indices = if Meta.isexpr(x, :ref)
        x.args[1], x.args[2:end]
    else
        x, []
    end
    @assert Meta.isexpr(x, :.)
    o, name = x.args
    :($get_cache_status($(esc(o)), $(name), $(indices...)))
end
macro cache_status(x)
    cache_status_expr(x)
end
macro is_cached(x) 
    :($(cache_status_expr(x)) == :ready)
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
dynamicstruct(expr) = begin 
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
            [info.lhs for (name,info) in oproperties if isfixed(info)]..., :(cache::DynamicObjects.PropertyCache),
            :($type(args...; cache_type=:serial, kwargs...) = new(
                args..., 
                DynamicObjects.PropertyCache(
                    get((;serial=Dict, parallel=DynamicObjects.ThreadsafeDict), cache_type, cache_type),
                    (;kwargs...)
                )
            ))
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
                DynamicObjects.compute_property(o::$type, ::Val{$(Meta.quot(name))}) = DynamicObjects.IndexableProperty($(Meta.quot(name)), o, DynamicObjects.subcache(o.cache))
            end
            for (name, info) in properties if length(info.indices) > 0
        ]...,
    ))
end

macro dynamicstruct(expr)
    dynamicstruct(expr)
end


end