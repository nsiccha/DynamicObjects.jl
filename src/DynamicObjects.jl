"""
    DynamicObjects

Provides the `@dynamicstruct` macro for defining structs with lazily computed,
optionally disk-cached properties.

# Exports
- [`@dynamicstruct`](@ref): Define a struct with computed/cached properties.
- [`@cache_status`](@ref): Get the disk-cache status of a property (`:unstarted`, `:started`, `:ready`).
- [`@is_cached`](@ref): Check whether a property's disk cache is ready.
- [`@cache_path`](@ref): Get the file path used for a property's disk cache.
- [`remake`](@ref): Create a new instance of a `@dynamicstruct` type with some fields changed.
"""
module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached, @cache_path, remake#, @persist

import SHA, Serialization

# serialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")
# deserialize(args...; kwargs...) = error("Serialization requires loading e.g. Serialization.jl")
persistent_hash(x) = begin
    b = IOBuffer()
    Serialization.serialize(b, x)
    bytes2hex(SHA.sha1(take!(b)))
end
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
Base.get!(f::Function, ::PropertyCache, key, indices...; kwargs...) = f()
Base.setindex!(c::PropertyCache, args...) = setindex!(c.cache, args...)
struct IndexableProperty{N,O,D<:AbstractDict}
    o::O
    cache::D
    IndexableProperty(N,o,cache=Dict()) = new{N,typeof(o),typeof(cache)}(o, cache)
end
name(::IndexableProperty{N}) where {N} = N
Base.getindex((;o, cache)::IndexableProperty{name}, indices...; fetch=fetch, kwargs...) where {name} = get!(cache, (indices, kwargs)) do
    getorcomputeproperty(o, name, indices...; kwargs...)
end
(ip::IndexableProperty)(indices...; kwargs...) = begin 
    rv = getindex(ip, indices...; kwargs...)
    maybepop!(ip.cache, (indices, kwargs))
    rv 
end
struct ThreadsafeDict{K,V} <: AbstractDict{K,V}
    lock::ReentrantLock
    cache::Dict{K,V}
    tasks::Dict{K,Task}
    ThreadsafeDict{K,V}(c) where {K,V} = new{K,V}(ReentrantLock(), Dict{K,V}(c), Dict{K,Task}())
    ThreadsafeDict() = new{Any,Any}(ReentrantLock(), Dict{Any,Any}(), Dict{Any,Task}())
end
Base.getindex((;o, cache)::IndexableProperty{name,<:Any,<:ThreadsafeDict}, indices...; fetch=fetch, kwargs...) where {name} = get!(cache, (indices, kwargs); fetch) do
    getorcomputeproperty(o, name, indices...; kwargs...)
end
Base.get!(f::Function, c::ThreadsafeDict, key; fetch=fetch) = begin
    rv = lock(c.lock) do
        get(c.cache, key) do 
            get!(c.tasks, key) do
                Threads.@spawn begin 
                    tmp = f()
                    lock(c.lock) do 
                        c.cache[key] = tmp
                        pop!(c.tasks, key)
                    end
                    tmp
                end 
            end
        end
    end
    fetch(rv)
end
Base.pop!(c::ThreadsafeDict, key) = begin 
    lock(c.lock) do 
        pop!(c.cache, key)
    end
end
maybepop!(c::AbstractDict, key) = key in keys(c) && pop!(c, key)
maybepop!(c::ThreadsafeDict, key) = begin 
    lock(c.lock) do 
        maybepop!(c.cache, key)
    end
end
subcache(::PropertyCache{<:Dict}) = Dict()
subcache(::PropertyCache{<:ThreadsafeDict}) = ThreadsafeDict()

getorcomputeproperty(o, name, indices...; kwargs...) = if hasfield(typeof(o), name)
    @assert length(indices) == length(kwargs) == 0
    getfield(o, name)
else
    get!(getfield(o, :cache), name, indices...; kwargs...) do 
        vname = Val(name)
        if iscached(o, vname, indices...; kwargs...)
            cache_path = get_cache_path(o, name, indices...; kwargs...)
            mkpath(dirname(cache_path))
            cache_status = get_cache_status(cache_path)
            rv = if cache_status == :ready
                Serialization.deserialize(cache_path) 
            elseif cache_status == :started
                @warn "Cache file $cache_path exists but has size 0.\nAssuming a previous run failed."
            else
                touch(cache_path)
                nothing
            end
            if cache_status != :ready || resumes(o, vname, indices...; kwargs...)
                @debug "Generating $cache_path..."
                rv = compute_property(o, vname, indices...; (name=>rv, )..., kwargs...)
                Serialization.serialize(cache_path, rv)
            end
            rv
        else
            compute_property(o, vname, indices...; kwargs...)
        end
    end
end
maybehash(x::Number) = x
maybehash(x::Symbol) = x
maybehash(x) = persistent_hash(x)
get_cache_path(o, args...; kwargs...) = joinpath(o.cache_path, join(map(
    maybehash, length(kwargs) == 0 ? args : (args..., sort(collect(kwargs); by=first))
), "_") * ".sjl")
get_cache_status(o, args...; kwargs...) = get_cache_status(get_cache_path(o, args...; kwargs...)) 
get_cache_status(cache_path::AbstractString) = begin
    !isfile(cache_path) && return :unstarted
    filesize(cache_path) == 0 && return :started
    return :ready
end
cache_f_expr(x; f) = begin
    x, indices = if Meta.isexpr(x, (:ref, :call))
        x.args[1], x.args[2:end]
    else
        x, []
    end
    @assert Meta.isexpr(x, :.)
    o, name = x.args
    :($f($o, $(name), $(indices...))) |> fixcall
end
"""
    @cache_status o.prop
    @cache_status o.prop[indices...]

Return the disk-cache status of a `@cached` property as a `Symbol`:
- `:unstarted` — no cache file exists yet.
- `:started`   — an empty placeholder file exists (previous run may have crashed).
- `:ready`     — a complete cache file exists and can be deserialized.

```julia
@cache_status e.result          # :unstarted (before first access)
e.result
@cache_status e.result          # :ready
@cache_status e.ci[2]           # for indexable properties
```
"""
macro cache_status(x)
    cache_f_expr(x; f=get_cache_status) |> esc
end

"""
    @is_cached o.prop
    @is_cached o.prop[indices...]

Return `true` if the disk cache for `o.prop` (or `o.prop[indices...]`) is
`:ready`, i.e. the cached value can be loaded from disk without recomputation.

```julia
@is_cached e.result   # false before first access, true afterwards
```
"""
macro is_cached(x)
    :($(cache_f_expr(x; f=get_cache_status)) == :ready) |> esc
end

"""
    @cache_path o.prop
    @cache_path o.prop[indices...]

Return the file path where the disk-cached value of `o.prop` (or
`o.prop[indices...]`) is (or would be) stored.

```julia
@cache_path e.result          # e.g. "cache/<hash>/result.sjl"
@cache_path e.ci[2]           # "cache/<hash>/2.sjl"
```
"""
macro cache_path(x)
    cache_f_expr(x; f=get_cache_path) |> esc
end
macro persist(x)
    x, indices = if Meta.isexpr(x, (:ref, :call))
        x.args[1], x.args[2:end]
    else
        x, []
    end
    @assert Meta.isexpr(x, :.)
    o, name = x.args
    :($persist($x, $o, $(name), $(indices...))) |> fixcall |> esc
end
persist(v, args...; kwargs...) = begin
    Serialization.serialize(
        get_cache_path(args...; kwargs...),
        v
    )
end

isfixed(kv::Pair) = isfixed(kv[2])
isfixed(info::NamedTuple) = isnothing(info.rhs)
walk_rhs(e; kwargs...) = e
walk_rhs(e::Expr; locals, properties) = if e.head == :let
    # locals = properties[dependent].locals
    ls = Set{Symbol}()
    !Meta.isexpr(e.args[1], :block) && (e.args[1] = Expr(:block, e.args[1]))
    map!(e.args[1].args, e.args[1].args) do arg 
        isa(arg, Symbol) && (arg = Expr(:(=), arg, arg))
        @assert Meta.isexpr(arg, :(=))
        name, rhs = arg.args[1], walk_rhs(arg.args[2]; locals, properties)
        name in locals || push!(ls, name)
        push!(locals, name)
        Expr(:(=), name, rhs)
    end
    e.args[2] = walk_rhs(e.args[2]; locals, properties)
    for l in ls
        delete!(locals, l)
    end
    e
elseif e.head == :kw
    Expr(e.head, e.args[1], walk_rhs.(e.args[2:end]; locals, properties)...)
else
    Expr(e.head, walk_rhs.(e.args; locals, properties)...)
end
walk_rhs(e::Symbol; locals, properties) = if e in keys(properties) && !(e in locals)
    # isfixed(properties[e]) || push!(properties[dependent].dependson, e)
    :(__self__.$e)
else
    # e == dependent && push!(properties[dependent].dependson, e)
    e
end
function compute_property end
function iscached end
function resumes end
function meta end
extractnames(x::Vector) = mapreduce(extractnames, union, x; init=Set())
extractnames(x::Symbol) = Set((x,))
extractnames(x::Expr) = if Meta.isexpr(x, :(::))
    extractnames(length(x.args) == 1 ? Symbol("") : x.args[1])
elseif Meta.isexpr(x, :kw)
    @assert length(x.args) == 2
    extractnames(x.args[1])
elseif Meta.isexpr(x, (:tuple, :parameters, :(...)))
    extractnames(x.args)
else
    dump(x)
    error("Don't know how to handle $x")
end
fixcall(x) = x
fixcall(x::Expr) = if Meta.isexpr(x, :call)
    # args = fixcall.(x.args)
    f = x.args[1]
    pargs = []
    args = []
    for arg in fixcall.(x.args[2:end])
        if Meta.isexpr(arg, :parameters)
            append!(pargs, arg.args)
        else
            push!(args, arg)
        end
    end
    Expr(x.head, f, Expr(:parameters, pargs...), args...)
else
    Expr(x.head, fixcall.(x.args)...)
end
dynamicstruct(expr; docstring=nothing, cache_type=:serial) = begin 
    @assert expr.head == :struct
    mut, head, body = expr.args
    type = head
    Meta.isexpr(type, :(<:)) && (type = type.args[1])
    Meta.isexpr(type, :(curly)) && (type = type.args[1])
    @assert body.head == :block
    lnn = nothing
    doc = nothing
    docs = []
    oproperties = map(body.args) do arg
        if isa(arg, LineNumberNode)
            lnn = arg
            return
        end
        if isa(arg, String)
            doc = arg
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
        if Meta.isexpr(arg, (:ref, :call))
            arg, indices... = arg.args
            union!(locals, extractnames(indices))
        end
        name = if Meta.isexpr(arg, :(::))
            arg.args[1]
        else
            arg
        end
        @assert isa(name, Symbol) dump(name)
        push!(docs, (name=>(doc, !isnothing(rhs))))
        doc = nothing
        !isnothing(locals) && push!(locals, name)
        @assert !isnothing(rhs) || length(macros) == 0
        name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices)
    end |> filter(!isnothing)
    properties = Dict(oproperties)
    properties_with_indices = Set(first.(filter(((name, info),)->length(info.indices) > 0, oproperties)))
    # for (dependent, info) in properties
    #     isfixed(info) && continue
    #     properties[dependent] = merge(info, (;rhs=walk_rhs(info.rhs; dependent, properties)))
    # end

    docstring = something(docstring, "DynamicStruct `$type`.") * "\n\n" * join([
        "* " * (isnothing(doc) ? "" : "$doc: ") * "`$name" * (hasrhs ? " = ..." : "") * "`"
        for (name, (doc, hasrhs)) in docs
    ], "\n")

    struct_expr = Expr(:struct, mut, head, Expr(:block, 
        [info.lhs for (name,info) in oproperties if isfixed(info)]..., :(cache::$PropertyCache),
        :($type(args...; cache_type=$(Meta.quot(cache_type)), kwargs...) = new(
            args..., 
            $PropertyCache(
                $get((;serial=$Dict, parallel=$ThreadsafeDict), cache_type, cache_type),
                (;kwargs...)
            )
        ))
    ))
    esc(Expr(:block, 
        :(@doc $docstring $struct_expr),
        quote
            $Base.hasproperty(__self__::$type, name::Symbol) = name in $(keys(properties))
            $Base.getproperty(__self__::$type, name::Symbol) = $getorcomputeproperty(__self__, name)
            $Base.setproperty!(__self__::$type, name::Symbol, value) = getfield(__self__, :cache)[name] = value
            $DynamicObjects.meta(::Type{$type}) = $properties
        end,
        [
            quote
                $DynamicObjects.compute_property(__self__::$type, ::Val{$(Meta.quot(name))}, $(info.indices...); $(name)=$(length(info.indices) > 0 ? :(__self__.$name) : nothing)) = $(walk_rhs(info.rhs; info.locals, properties))
                $DynamicObjects.iscached(__self__::$type, ::Val{$(Meta.quot(name))}, $(info.indices...)) = $(Symbol("@cached") in info.macros)
                $DynamicObjects.resumes(__self__::$type, ::Val{$(Meta.quot(name))}, $(info.indices...)) = false#$(name in info.dependson)
            end |> fixcall |> setlnn(info.lnn)
            for (name, info) in oproperties if !isfixed(info)
        ]...,
        [
            quote
                $DynamicObjects.compute_property(__self__::$type, ::Val{$(Meta.quot(name))}) = $IndexableProperty($(Meta.quot(name)), __self__, $subcache(__self__.cache))
                $DynamicObjects.iscached(__self__::$type, ::Val{$(Meta.quot(name))}) = false
            end |> setlnn(properties[name].lnn)
            for name in properties_with_indices
        ]...,
    ))
end

replacelnn(;lnn::LineNumberNode) = x->replacelnn(x;lnn)
replacelnn(x::Expr; lnn::LineNumberNode) = Expr(x.head, replacelnn.(x.args; lnn)...)
replacelnn(::LineNumberNode; lnn::LineNumberNode) = lnn
replacelnn(x; lnn::LineNumberNode) = x

# Replace only the top-level LineNumberNodes in a block, leaving nested ones intact.
# This gives Revise the source-location metadata it needs to track method changes,
# without clobbering the internal LineNumberNodes that make stack traces useful.
function setlnn(lnn::Union{LineNumberNode,Nothing})
    function(expr::Expr)
        isnothing(lnn) && return expr
        @assert expr.head == :block
        Expr(:block, map(x -> isa(x, LineNumberNode) ? lnn : x, expr.args)...)
    end
end

"""
    @dynamicstruct [docstring] [cache_type] struct Name
        field                     # fixed field (constructor argument)
        prop = expr               # lazily computed property
        @cached prop = expr       # lazily computed + disk-cached property
        prop[idx] = expr          # indexable property (cached per index)
        prop(args...; kw...) = expr  # indexable property (fresh each call)
        @cached prop[idx] = expr  # indexable + disk-cached property
    end

Define a struct whose *fixed fields* are set at construction time and whose
*derived properties* are computed lazily on first access and then stored in an
in-memory cache.

Derived properties may reference any other field or property by name; the
reference is automatically rewritten to `__self__.<name>`.  Order of definition
does not matter — cycles will result in a stack overflow at runtime.

`cache_type` controls the in-memory cache backend:
- `:serial` (default) — plain `Dict`, single-threaded safe.
- `:parallel` — `ThreadsafeDict`, safe to access from multiple tasks
  simultaneously; duplicate work is avoided by sharing in-flight `Task`s.

Properties marked `@cached` are additionally persisted to disk under
`__self__.cache_path` (which itself defaults to
`joinpath(__self__.cache_base, __self__.hash)`).

Keyword arguments passed to the constructor pre-populate the cache, so they act
as overrides for any computed property.

# Examples
```julia
using DynamicObjects

@dynamicstruct struct Point
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
end

p = Point(3.0, 4.0)
p.r      # 5.0
p.theta  # atan(4, 3)
```

```julia
# Disk-cached expensive computation.
# cache_path defaults to joinpath("cache", hash(n)), so two Experiment(n)
# instances with the same n share the same cache directory.
@dynamicstruct struct Experiment
    n::Int
    @cached result = sum(rand(n))   # computed once, then loaded from disk
end

e = Experiment(1_000_000)
e.result   # computed on first access, cached to disk
e2 = Experiment(1_000_000)
e2.result  # loaded from disk (same n → same hash → same cache path)
```

```julia
# Indexed properties with bracket and call syntax.
# Properties reference each other by bare name (auto-rewritten to __self__.<name>).
@dynamicstruct struct DataSet
    items = ["apple", "banana", "cherry"]
    matches[query] = filter(x -> occursin(query, x), items)  # bracket: cached per query
    search(query) = filter(x -> occursin(query, x), items)   # call: fresh each time
    top(query; n=1) = first(search(query), n)                # call with kwargs
end

ds = DataSet()
ds.matches["an"]        # ["banana"] — cached per query
ds.search("an")         # ["banana"] — fresh each call
ds.top("a"; n=2)        # ["apple", "banana"] — kwargs supported
```
"""
macro dynamicstruct(expr)
    dynamicstruct(expr)
end
macro dynamicstruct(docstring, expr)
    dynamicstruct(expr; docstring)
end
macro dynamicstruct(docstring, cache_type, expr)
    dynamicstruct(expr; docstring, cache_type)
end

"""
    remake(obj; kwargs...)

Create a new instance of the same `@dynamicstruct` type as `obj`, copying all
fixed fields from `obj` and overriding any specified via keyword arguments.

Keyword arguments that correspond to fixed fields replace those field values in
the new instance. Any remaining keyword arguments are forwarded to the
constructor as cache pre-population overrides.

# Example
```julia
@dynamicstruct struct Config
    n::Int
    scale::Float64
    result = scale * sum(rand(n))
end

c  = Config(100, 2.0)
c2 = remake(c; n=200)       # n=200, scale=2.0, result recomputed fresh
c3 = remake(c; scale=3.0)   # n=100, scale=3.0, result recomputed fresh
c4 = remake(c; result=0.0)  # n=100, scale=2.0, result pre-set to 0.0
```
"""
function remake(obj; kwargs...)
    T = typeof(obj)
    fixed_names = fieldnames(T)[1:end-1]  # all fields except :cache
    args = [get(kwargs, name, getfield(obj, name)) for name in fixed_names]
    cache_kwargs = filter(p -> !(first(p) in fixed_names), kwargs)
    T(args...; cache_kwargs...)
end


end