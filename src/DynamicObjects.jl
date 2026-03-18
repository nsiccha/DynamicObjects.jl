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
- [`fetchindex`](@ref): Non-blocking access to `ThreadsafeDict`-backed properties with `(rv, status)` callback.
- [`getstatus`](@ref): Read the status object for an in-flight computation.
"""
module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached, @cache_path, @clear_cache!, remake, fetchindex, getstatus, PropertyComputationError, unwrap_error#, @persist

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
Base.get!(f::Function, c::PropertyCache, key) = get!((_...) -> f(), c.cache, key)
Base.get!(f::Function, ::PropertyCache, key, indices...; kwargs...) = f()
Base.setindex!(c::PropertyCache, args...) = setindex!(c.cache, args...)
Base.show(io::IO, pc::PropertyCache) = print(io, "PropertyCache(", length(pc.cache), " properties)")
struct IndexableProperty{N,O,D<:AbstractDict}
    o::O
    cache::D
    IndexableProperty(N,o,cache=Dict()) = new{N,typeof(o),typeof(cache)}(o, cache)
end
name(::IndexableProperty{N}) where {N} = N
Base.show(io::IO, ip::IndexableProperty{N}) where {N} = print(io, "IndexableProperty :", N, " (", ip.cache, ")")
Base.getindex((;o, cache)::IndexableProperty{name}, indices...; fetch=fetch, kwargs...) where {name} = get!(cache, (indices, (;kwargs...))) do
    getorcomputeproperty(o, name, indices...; kwargs...)
end
(ip::IndexableProperty)(indices...; kwargs...) = begin
    rv = getindex(ip, indices...; kwargs...)
    maybepop!(ip.cache, (indices, (;kwargs...)))
    rv
end
struct ThreadsafeDict{K,V} <: AbstractDict{K,V}
    lock::ReentrantLock
    cache::Dict{K,V}
    tasks::Dict{K,Task}
    status::Dict{K,Any}
    ThreadsafeDict{K,V}(c) where {K,V} = new{K,V}(ReentrantLock(), Dict{K,V}(c), Dict{K,Task}(), Dict{K,Any}())
    ThreadsafeDict() = new{Any,Any}(ReentrantLock(), Dict{Any,Any}(), Dict{Any,Task}(), Dict{Any,Any}())
end
Base.length(c::ThreadsafeDict) = lock(c.lock) do; length(c.cache); end
Base.iterate(c::ThreadsafeDict) = lock(c.lock) do; iterate(c.cache); end
Base.iterate(c::ThreadsafeDict, state) = lock(c.lock) do; iterate(c.cache, state); end
n_running(c::ThreadsafeDict) = lock(c.lock) do; length(c.tasks); end
Base.show(io::IO, c::ThreadsafeDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeDict{", K, ",", V, "}(", length(c.cache), " cached, ", length(c.tasks), " running)")
end
Base.getindex((;o, cache)::IndexableProperty{name,<:Any,<:ThreadsafeDict}, indices...; fetch=fetch, kwargs...) where {name} = begin
    substatus_f = if name != :__substatus__ && name != :__status__ && haskey(meta(typeof(o)), :__substatus__)
        () -> begin
            root = hasproperty(o, :__status__) ? o.__status__ : nothing
            compute_property(o, Val(:__substatus__), name, indices...; __status__=root, kwargs...)
        end
    else
        nothing
    end
    get!(cache, (indices, (;kwargs...)); fetch, substatus=substatus_f) do s
        getorcomputeproperty(o, name, indices...; __status__=s, kwargs...)
    end
end
Base.get!(f::Function, c::ThreadsafeDict, key; fetch=fetch, substatus=nothing) = begin
    rv = lock(c.lock) do
        get(c.cache, key) do
            # Clean up failed tasks so they can be retried
            if haskey(c.tasks, key) && istaskdone(c.tasks[key]) && istaskfailed(c.tasks[key])
                pop!(c.tasks, key)
                haskey(c.status, key) && pop!(c.status, key)
            end
            get!(c.tasks, key) do
                s = isnothing(substatus) ? nothing : substatus()
                !isnothing(s) && (c.status[key] = s)
                Threads.@spawn begin
                    tmp = f(s)
                    lock(c.lock) do
                        c.cache[key] = tmp
                        pop!(c.tasks, key)
                        haskey(c.status, key) && pop!(c.status, key)
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
        haskey(c.status, key) && pop!(c.status, key)
        pop!(c.cache, key)
    end
end

"""
    getstatus(ip::IndexableProperty, indices...; kwargs...)

Return the status object associated with an in-flight computation for the given
key, or `nothing` if no status exists (computation not started, already finished,
or no `__substatus__` defined).

Only meaningful for `IndexableProperty` backed by a `ThreadsafeDict`.
"""
getstatus(ip::IndexableProperty{name,<:Any,<:ThreadsafeDict}, indices...; kwargs...) where {name} = begin
    lock(ip.cache.lock) do
        get(ip.cache.status, (indices, (;kwargs...)), nothing)
    end
end
getstatus(::IndexableProperty, indices...; kwargs...) = nothing

"""
    fetchindex(fetch, ip, indices...; kwargs...)

Call `getindex(ip, indices...; kwargs...)` with a custom `fetch` function.

For `IndexableProperty` backed by a `ThreadsafeDict`, `getindex` spawns a `Task`
for the computation. The `fetch` callback receives `(rv, status)` where `rv` is
the `Task` (still running) or the computed result (done), and `status` is the
substatus object (from `__substatus__`) or `nothing`.

# Example
```julia
fetchindex(app.results, key) do rv, status
    if rv isa Task
        # still computing — status is the progress node
        render_progress(status)
    else
        # done — render result
        render(rv)
    end
end
```
"""
function fetchindex(fetch, ip::IndexableProperty{name,<:Any,<:ThreadsafeDict}, indices...; kwargs...) where {name}
    rv = getindex(ip, indices...; fetch=identity, kwargs...)
    status = getstatus(ip, indices...; kwargs...)
    fetch(rv, status)
end
# Fallback for non-ThreadsafeDict IPs (1-arg callback, no status)
fetchindex(fetch, args...; kwargs...) = getindex(args...; fetch, kwargs...)
maybepop!(c::AbstractDict, key) = key in keys(c) && pop!(c, key)
maybepop!(c::ThreadsafeDict, key) = begin
    lock(c.lock) do
        haskey(c.status, key) && pop!(c.status, key)
        maybepop!(c.cache, key)
    end
end
subcache(::PropertyCache{<:Dict}) = Dict()
subcache(::PropertyCache{<:ThreadsafeDict}) = ThreadsafeDict()

getorcomputeproperty(o, name, indices...; __status__=nothing, kwargs...) = if hasfield(typeof(o), name)
    @assert length(indices) == length(kwargs) == 0
    getfield(o, name)
else
    get!(getfield(o, :cache), name, indices...; kwargs...) do
        vname = Val(name)
        # When called with no indices on an indexed property, return an
        # IndexableProperty wrapper instead of calling compute_property.
        # This avoids generating a zero-arg compute_property method that
        # would conflict with indexed properties whose indices all have defaults.
        if isempty(indices) && isempty(kwargs)
            m = meta(typeof(o))
            if haskey(m, name) && !isempty(m[name].indices)
                return IndexableProperty(name, o, subcache(getfield(o, :cache)))
            end
        end
        # Only pass __status__ to properties that accept it (generated properties
        # in meta). Base properties (cache_path, hash, etc.) don't have it.
        _status_kw = haskey(meta(typeof(o)), name) ? (; __status__) : (;)
        try
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
                    rv = compute_property(o, vname, indices...; _status_kw..., (name=>rv, )..., kwargs...)
                    Serialization.serialize(cache_path, rv)
                end
                rv
            else
                compute_property(o, vname, indices...; _status_kw..., kwargs...)
            end
        catch e
            e isa PropertyComputationError && rethrow()
            kw_tuple = isempty(kwargs) ? () : Tuple(pairs(kwargs))
            bt = catch_backtrace()
            throw(PropertyComputationError(
                string(typeof(o).name.name),
                name,
                indices,
                kw_tuple,
                (e, bt),  # store exception + backtrace from the actual throw site
            ))
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
    if Meta.isexpr(x, :$)
        # Interpolated property name: @is_cached $prop[indices...]
        name_expr = x.args[1]
        :($f(__self__, $name_expr, $(indices...))) |> fixcall
    else
        @assert Meta.isexpr(x, :.)
        o, name = x.args
        :($f($o, $(name), $(indices...))) |> fixcall
    end
end
"""
    @cache_status o.prop
    @cache_status o.prop[indices...]

Return the disk-cache status of a `@cached` property as a `Symbol`:
- `:unstarted` — no cache file exists yet.
- `:started`   — an empty placeholder file exists (previous run may have crashed).
- `:ready`     — a complete cache file exists and can be deserialized.

Can be used both outside and inside a `@dynamicstruct` body. Inside a struct
definition, omit the object prefix — just use the property name:

```julia
# Outside the struct:
@cache_status e.result          # :unstarted (before first access)
e.result
@cache_status e.result          # :ready
@cache_status e.ci[2]           # for indexable properties

# Inside the struct body:
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    status(key) = @cache_status result[key]   # :unstarted, :started, or :ready
end
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

Can be used both outside and inside a `@dynamicstruct` body. Inside a struct
definition, omit the object prefix — just use the property name:

```julia
# Outside the struct:
@is_cached e.result   # false before first access, true afterwards

# Inside the struct body:
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    summary(key) = if @is_cached result[key]
        "cached: \$(result[key])"
    else
        "not yet computed"
    end
end
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

"""
    @clear_cache! o.prop
    @clear_cache! o.prop[indices...]

Clear the disk cache (and in-memory cache) for a `@cached` property.

Without indices, clears **all** cached entries for the property (both the
in-memory value and all `.sjl` files for that property on disk).
With indices, clears only the specific entry.

```julia
@clear_cache! e.result        # clear all cached entries for `result`
@clear_cache! e.ci[3]         # clear only the ci[3] entry
```
"""
clear_cache!(o, name::Symbol, indices...; kwargs...) = begin
    cache = getfield(o, :cache).cache
    if isempty(indices) && isempty(kwargs)
        # Clear in-memory (whole property, including IndexableProperty wrapper)
        delete!(cache, name)
        # Clear all disk cache files for this property
        cp = try; o.cache_path; catch; nothing; end
        if !isnothing(cp) && isdir(cp)
            prefix = string(name)
            for f in readdir(cp)
                if endswith(f, ".sjl") && (f == prefix * ".sjl" || startswith(f, prefix * "_"))
                    rm(joinpath(cp, f))
                end
            end
        end
    else
        # Clear specific indexed entry from in-memory cache
        if haskey(cache, name)
            v = cache[name]
            if v isa IndexableProperty
                maybepop!(v.cache, (indices, (;kwargs...)))
            end
        end
        # Clear specific disk cache file
        path = get_cache_path(o, name, indices...; kwargs...)
        isfile(path) && rm(path)
    end
    nothing
end
macro clear_cache!(x)
    cache_f_expr(x; f=clear_cache!) |> esc
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
elseif e.head == :(->)
    # Lambda: first arg is parameter(s), second is body.
    # Add lambda params to locals so they are not rewritten.
    params = e.args[1]
    ls = extractnames(isa(params, Expr) && Meta.isexpr(params, :tuple) ? params.args : [params])
    new_locals = union(locals, ls)
    Expr(e.head, e.args[1], walk_rhs(e.args[2]; locals=new_locals, properties))
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
    oproperties = Pair[]
    for arg in body.args
        if isa(arg, LineNumberNode)
            lnn = arg
            continue
        end
        if isa(arg, String)
            doc = arg
            continue
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
        # Multi-lhs: a, b = expr or (;a, b) = expr → hidden group property + individual extractors
        if Meta.isexpr(arg, :tuple)
            # Detect named destructuring: (;a, b) parses as Expr(:tuple, Expr(:parameters, :a, :b))
            named = length(arg.args) == 1 && Meta.isexpr(arg.args[1], :parameters)
            raw_args = named ? arg.args[1].args : arg.args
            # Build list of (property_name, extract_expr_builder) pairs
            # extract_expr_builder takes the group_name and returns the RHS expression
            members = Pair{Symbol, Any}[]  # name => source_field_or_index
            if named
                for a in raw_args
                    if isa(a, Symbol)
                        # (;a) → property a, extracts .a
                        push!(members, a => a)
                    elseif Meta.isexpr(a, :call) && a.args[1] == :(<=)
                        target, source = a.args[2], a.args[3]
                        if isa(source, Symbol)
                            # (;x_val<=val) → property x_val, extracts .val
                            push!(members, target => source)
                        elseif Meta.isexpr(source, :tuple)
                            # (;x_ <= (val, grad)) → properties x_val, x_grad
                            prefix = string(target)
                            for s in source.args
                                push!(members, Symbol(prefix, s) => s)
                            end
                        end
                    end
                end
            else
                for (i, a) in enumerate(raw_args)
                    n = Meta.isexpr(a, :(::)) ? a.args[1] : a
                    push!(members, n => i)
                end
            end
            prop_names = first.(members)
            group_name = Symbol("_tuple_", join(prop_names, "_"))
            # Group property: computes the full tuple/NamedTuple
            group_locals = Set{Symbol}(prop_names)
            push!(group_locals, group_name)
            push!(oproperties, group_name=>(;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple()))
            push!(docs, (group_name=>(doc, true)))
            doc = nothing
            # Individual properties: extract from the group
            for (prop_name, source) in members
                extract_rhs = if source isa Symbol
                    Expr(:., group_name, QuoteNode(source))
                else
                    :($group_name[$source])
                end
                push!(oproperties, prop_name=>(;lhs=prop_name, macros=Set{Symbol}(), rhs=extract_rhs, lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([prop_name]), indices=tuple()))
                push!(docs, (prop_name=>(nothing, true)))
            end
            continue
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
        !isnothing(locals) && push!(locals, :__status__)
        @assert !isnothing(rhs) || length(macros) == 0
        push!(oproperties, name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices))
    end
    properties = Dict(oproperties)
    # for (dependent, info) in properties
    #     isfixed(info) && continue
    #     properties[dependent] = merge(info, (;rhs=walk_rhs(info.rhs; dependent, properties)))
    # end

    docstring = something(docstring, "DynamicStruct `$type`.") * "\n\n" * join([
        "* " * (isnothing(doc) ? "" : "$doc: ") * "`$name" * (hasrhs ? " = ..." : "") * "`"
        for (name, (doc, hasrhs)) in docs
    ], "\n")

    fixed_fields = [(name, info.lhs) for (name, info) in oproperties if isfixed(info)]
    fixed_names = [n for (n, _) in fixed_fields]
    fixed_lhs = [lhs for (_, lhs) in fixed_fields]
    struct_expr = Expr(:struct, mut, head, Expr(:block,
        fixed_lhs..., :(cache::$PropertyCache),
        :($type($(fixed_lhs...); cache_type=$(Meta.quot(cache_type)), kwargs...) = new(
            $(fixed_names...),
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
            $Base.show(io::IO, __self__::$type) = begin
                print(io, $(string(type)), "(")
                $([let sep = i == 1 ? :() : :(print(io, ", "))
                    quote; $sep; print(io, $(string(fn)), "="); show(io, getfield(__self__, $(QuoteNode(fn)))); end
                end for (i, fn) in enumerate(fixed_names)]...)
                $(isempty(fixed_names) ? :() : :(print(io, "; ")))
                show(io, getfield(__self__, :cache))
                print(io, ")")
            end
        end,
        [
            begin
                cp_kwargs = [Expr(:kw, name, length(info.indices) > 0 ? :(__self__.$name) : nothing)]
                name != :__status__ && push!(cp_kwargs, Expr(:kw, :__status__, :nothing))
                # NOTE: Do NOT use replacelnn here — it clobbers internal LNNs in the body,
                # making all stacktrace frames point to the definition line.
                # The outer setlnn(info.lnn) on the quote block handles Revise tracking.
                cp_expr = :(
                    $DynamicObjects.compute_property(__self__::$type, ::Val{$(Meta.quot(name))}, $(info.indices...); $(cp_kwargs...)) = $(walk_rhs(info.rhs; info.locals, properties))
                ) |> fixcall
                quote
                    $cp_expr
                    $DynamicObjects.iscached(__self__::$type, ::Val{$(Meta.quot(name))}, $(info.indices...)) = $(Symbol("@cached") in info.macros)
                    $DynamicObjects.resumes(__self__::$type, ::Val{$(Meta.quot(name))}, $(info.indices...)) = false#$(name in info.dependson)
                end |> fixcall |> setlnn(info.lnn)
            end
            for (name, info) in oproperties if !isfixed(info)
        ]...,
        # IndexableProperty wrappers for indexed properties are now created
        # directly in getorcomputeproperty (via meta check), so no zero-arg
        # compute_property methods are needed here.
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
        prop(idx) = expr          # indexable property (fresh each call)
        prop(args...; kw...) = expr  # indexable property (fresh each call)
        @cached prop(idx) = expr  # indexable + disk-cached property (cached per index)
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
    matches(query) = filter(x -> occursin(query, x), items)   # call: fresh each time
    search(query) = filter(x -> occursin(query, x), items)   # call: fresh each time
    top(query; n=1) = first(search(query), n)                # call with kwargs
end

ds = DataSet()
ds.matches["an"]        # ["banana"] — cached per query
ds.search("an")         # ["banana"] — fresh each call
ds.top("a"; n=2)        # ["apple", "banana"] — kwargs supported
```

# Async progress with `__status__` and `__substatus__`

With `cache_type=:parallel`, indexed properties spawn background `Task`s.
Define `__status__` (root progress node) and `__substatus__` (per-computation
factory) to automatically wire progress into spawned tasks:

```julia
@dynamicstruct struct MyApp
    __status__ = initialize_progress!(:state; description="MyApp")
    __substatus__(name, args...; kwargs...) =
        initialize_progress!(__status__; description="\$name[\$(join(args, ","))]")
    results[key] = expensive_computation(__status__)  # __status__ is the substatus
end
app = MyApp(; cache_type=:parallel)

# Non-blocking access with progress:
fetchindex(app.results, key) do rv, status
    rv isa Task ? render_progress(status) : render_result(rv)
end
```

`__substatus__(name, args...; kwargs...)` is called before each Task spawn.
`name` is the property symbol, `args`/`kwargs` are the indices. The returned
object is stored in `ThreadsafeDict.status` (accessible via `getstatus`) and
passed to the computation body as the local `__status__`.

`__substatus__` only fires on ThreadsafeDict `getindex` (bracket access).
Call syntax and scalar property access do not trigger it.
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

# --- Error display for property computations ---

struct PropertyComputationError <: Exception
    type_name::String
    property::Symbol
    indices::Tuple
    kwargs::Tuple  # tuple of pairs
    cause::Any
end

"""Recursively unwrap TaskFailedException / CompositeException to find the root cause."""
unwrap_error(e::Base.TaskFailedException) = unwrap_error(e.task.exception)
unwrap_error(e::CompositeException) = unwrap_error(first(e.exceptions))
unwrap_error(e::PropertyComputationError) = unwrap_error(_cause_error(e))
unwrap_error(e) = e

# Extract the exception from cause (which may be a (exception, backtrace) tuple)
_cause_error(e::PropertyComputationError) = e.cause isa Tuple ? first(e.cause) : e.cause
_cause_backtrace(e::PropertyComputationError) = e.cause isa Tuple ? last(e.cause) : []

_filter_bt(bt) = filter(bt) do frame
    file = string(frame.file)
    !any(p -> occursin(p, file), (
        "DynamicObjects.jl/src", "HTMXObjects.jl/src",
        "/Oxygen/", "/HTTP/", "task.jl", "lock.jl",
        "essentials.jl", "dict.jl",
    ))
end

function _format_property_key(name, indices, kwargs)
    s = string(name)
    parts = String[]
    !isempty(indices) && append!(parts, repr.(indices))
    for (k, v) in kwargs
        push!(parts, "$k=$(repr(v))")
    end
    isempty(parts) ? s : s * "[" * join(parts, ", ") * "]"
end

function _format_frame(frame)
    if frame.linfo isa Core.MethodInstance
        sig = frame.linfo.specTypes
        params = fieldtypes(sig)
        fname = string(frame.func)
        arg_strs = ["::$(p)" for p in params[2:end]]
        return fname * "(" * join(arg_strs, ", ") * ")"
    end
    return string(frame.func)
end

function Base.showerror(io::IO, e::PropertyComputationError)
    key = _format_property_key(e.property, e.indices, e.kwargs)
    root = unwrap_error(e)
    print(io, "PropertyComputationError: computing `$key` on $(e.type_name)\n")
    print(io, "  Caused by: ")
    showerror(io, root)
    # Show filtered backtrace from the original throw site
    orig_bt = _cause_backtrace(e)
    if !isempty(orig_bt)
        frames = Base.stacktrace(orig_bt)
        filtered = _filter_bt(frames)
        if !isempty(filtered)
            println(io, "\n\n  Stacktrace (user code):")
            for (i, frame) in enumerate(filtered)
                println(io, "   [$i] $(_format_frame(frame)) at $(frame.file):$(frame.line)")
            end
        end
    end
end

# 3-arg method: suppress Oxygen's backtrace since we show our own filtered one above
Base.showerror(io::IO, e::PropertyComputationError, ::Any) = showerror(io, e)

end