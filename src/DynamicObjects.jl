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
- [`@clear_cache!`](@ref): Clear the disk and in-memory cache for a property.
- [`@persist`](@ref): Manually persist a property value to disk cache.
- [`PropertyComputationError`](@ref): Exception wrapper for errors during property computation.
- [`unwrap_error`](@ref): Dig through exception wrappers to find the root cause.
- [`entries`](@ref): List all entries in a `ThreadsafeDict`-backed property with state info.
- [`cached_entries`](@ref): Iterate completed (non-Task) entries of an indexed property.
- [`clear_all_caches!`](@ref): Clear all `@cached` properties on a `@dynamicstruct` instance.
- [`PersistentSet`](@ref): Thread-safe, disk-persisted `Set`.
- [`KeyTracker`](@ref): Abstract type for pluggable accessed-keys persistence strategies.
- [`SharedFileTracker`](@ref): Default strategy — single shared `_keys.sjl` file.
- [`PerPodFileTracker`](@ref): Per-pod strategy — one file per pod ID, merged on read.
- [`NoKeyTracker`](@ref): No-op strategy — never records or loads keys.
- [`key_tracker`](@ref): Override to set the tracking strategy per object type / property.
- [`record!`](@ref): Record an accessed key via a `KeyTracker`.
- [`load_keys`](@ref): Load the full set of recorded keys via a `KeyTracker`.
"""
module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached, @cache_path, @clear_cache!, @persist, remake, fetchindex, getstatus, PropertyComputationError, unwrap_error, entries, cached_entries, clear_all_caches!, PersistentSet, KeyTracker, SharedFileTracker, PerPodFileTracker, NoKeyTracker, key_tracker, record!, load_keys

import SHA, Serialization

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
compute_property(o, ::Val{:__status__}) = nothing
compute_property(o, ::Val{:__substatus__}, name, args...; kwargs...) =
    _default_substatus(o.__status__, name, args...; kwargs...)
_default_substatus(status, name, args...; kwargs...) = nothing

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
((;o)::IndexableProperty{name})(indices...; kwargs...) where {name} =
    _computeproperty(o, name, indices...; kwargs...)
Base.getindex(ip::IndexableProperty, indices...; fetch=Base.fetch, kwargs...) =
    get!(ip.cache, (indices, (;kwargs...))) do
        ip(indices...; kwargs...)
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
# NOTE: iteration is NOT truly thread-safe — each iterate call locks independently,
# so the dict can mutate between calls. For thread-safe iteration, use
# lock(c.lock) do ... end or entries(ip) which holds the lock for the full sweep.
Base.iterate(c::ThreadsafeDict) = lock(c.lock) do; iterate(c.cache); end
Base.iterate(c::ThreadsafeDict, state) = lock(c.lock) do; iterate(c.cache, state); end
Base.empty!(c::ThreadsafeDict) = (lock(c.lock) do; empty!(c.cache); empty!(c.tasks); empty!(c.status); end; c)
n_running(c::ThreadsafeDict) = lock(c.lock) do; length(c.tasks); end
Base.show(io::IO, c::ThreadsafeDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeDict{", K, ",", V, "}(", length(c.cache), " cached, ", length(c.tasks), " running)")
end
Base.getindex(ip::IndexableProperty{name,<:Any,<:ThreadsafeDict}, indices...; fetch=Base.fetch, retry_failed=true, kwargs...) where {name} = begin
    (;o, cache) = ip
    substatus_f = if name != :__substatus__ && name != :__status__ && haskey(meta(typeof(o)), :__substatus__)
        () -> begin
            root = hasproperty(o, :__status__) ? o.__status__ : nothing
            compute_property(o, Val(:__substatus__), name, indices...; __status__=root, kwargs...)
        end
    else
        nothing
    end
    get!(cache, (indices, (;kwargs...)); fetch, substatus=substatus_f, retry_failed) do s
        getorcomputeproperty(o, name, indices...; __status__=s, kwargs...)
    end
end
Base.get!(f::Function, c::ThreadsafeDict, key; fetch=Base.fetch, substatus=nothing, retry_failed=true) = begin
    rv = lock(c.lock) do
        get(c.cache, key) do
            # Clean up failed tasks so they can be retried (only when retry_failed=true)
            if retry_failed && haskey(c.tasks, key) && istaskdone(c.tasks[key]) && istaskfailed(c.tasks[key])
                pop!(c.tasks, key)
                haskey(c.status, key) && pop!(c.status, key)
            end
            get!(c.tasks, key) do
                s = isnothing(substatus) ? nothing : substatus()
                if !isnothing(s)
                    c.status[key] = s
                end
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
Base.delete!(c::ThreadsafeDict, key) = begin
    lock(c.lock) do
        delete!(c.status, key)
        delete!(c.tasks, key)
        delete!(c.cache, key)
    end
    c
end

"""
    getstatus(ip::IndexableProperty, indices...; kwargs...)

Return the status object associated with an in-flight computation for the given
key, or `nothing` if no status exists (computation not started, already finished,
or no `__substatus__` defined).

Only meaningful for `IndexableProperty` backed by a `ThreadsafeDict`.
"""
getstatus(ip::IndexableProperty{<:Any,<:Any,<:ThreadsafeDict}, indices...; kwargs...) = begin
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

Pass `force=true` to unconditionally recompute: clears both the in-memory cache
entry and the on-disk cache file so `getindex` always spawns a fresh Task.

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
function fetchindex(fetch, ip::IndexableProperty{<:Any,<:Any,<:ThreadsafeDict}, indices...; force=false, kwargs...)
    if force
        maybepop!(ip.cache, (indices, (;kwargs...)))
        path = get_cache_path(ip.o, name(ip), indices...; kwargs...)
        isfile(path) && rm(path)
    end
    rv = getindex(ip, indices...; fetch=identity, retry_failed=false, kwargs...)
    status = getstatus(ip, indices...; kwargs...)
    fetch(rv, status)
end
# Fallback for non-ThreadsafeDict IPs (1-arg callback, no status)
fetchindex(fetch, args...; kwargs...) = getindex(args...; fetch, kwargs...)
maybepop!(c::AbstractDict, key) = haskey(c, key) && pop!(c, key)
maybepop!(c::ThreadsafeDict, key) = begin
    lock(c.lock) do
        haskey(c.status, key) && pop!(c.status, key)
        maybepop!(c.cache, key)
    end
end
subcache(::PropertyCache{<:Dict}) = Dict()
subcache(::PropertyCache{<:ThreadsafeDict}) = ThreadsafeDict()

# --- PersistentSet ---

"""
    PersistentSet(path)

A thread-safe `Set` that persists to disk via `Serialization`. Loads existing
data from `path` on construction, or starts empty if the file doesn't exist.
"""
struct PersistentSet{P<:AbstractString,S<:AbstractSet}
    lock::ReentrantLock
    path::P
    data::S
end
PersistentSet(path) = begin
    data = isfile(path) ? Serialization.deserialize(path) : Set()
    PersistentSet(ReentrantLock(), path, data)
end
Base.push!(s::PersistentSet, item) = @lock s.lock begin
    item in s.data && return s
    isfile(s.path) && union!(s.data, Serialization.deserialize(s.path))
    Serialization.serialize(s.path, push!(s.data, item))
    s
end
Base.pop!(s::PersistentSet, item) = @lock s.lock begin
    pop!(s.data, item)
    Serialization.serialize(s.path, s.data)
    s
end
Base.in(item, s::PersistentSet) = @lock s.lock item in s.data
Base.length(s::PersistentSet) = @lock s.lock length(s.data)
Base.collect(s::PersistentSet) = @lock s.lock collect(s.data)
# NOTE: iteration is NOT truly thread-safe — each iterate call locks independently.
Base.iterate(s::PersistentSet) = @lock s.lock iterate(s.data)
Base.iterate(s::PersistentSet, state) = @lock s.lock iterate(s.data, state)
Base.show(io::IO, s::PersistentSet) = print(io, "PersistentSet(", length(s.data), " items, ", s.path, ")")

# --- entries / cached_entries for IndexableProperty ---

"""
    entries(ip::IndexableProperty)

Return a vector of `(; key, state, status, value)` for all entries in a
`ThreadsafeDict`-backed `IndexableProperty`. `state` is one of `:running`,
`:failed`, `:finishing`, or `:done`. `value` is the cached result (for `:done`)
or the `Task` (for running/failed/finishing). `status` is the substatus object
or `nothing`.
"""
function entries(ip::IndexableProperty{<:Any,<:Any,<:ThreadsafeDict})
    result = NamedTuple{(:key, :state, :status, :value), Tuple{Any, Symbol, Any, Any}}[]
    lock(ip.cache.lock) do
        for (k, task) in ip.cache.tasks
            status = get(ip.cache.status, k, nothing)
            state = if istaskfailed(task)
                :failed
            elseif istaskdone(task)
                :finishing
            else
                :running
            end
            push!(result, (; key=k, state, status, value=task))
        end
        for (k, v) in ip.cache.cache
            haskey(ip.cache.tasks, k) && continue
            push!(result, (; key=k, state=:done, status=nothing, value=v))
        end
    end
    result
end

"""
    cached_entries(ip::IndexableProperty)

Return a vector of `(key, value)` pairs for completed (non-Task) entries only.
"""
function cached_entries(ip::IndexableProperty{<:Any,<:Any,<:ThreadsafeDict})
    lock(ip.cache.lock) do
        collect(ip.cache.cache)
    end
end
function cached_entries(ip::IndexableProperty)
    collect(ip.cache)
end

# --- clear_all_caches! ---

"""
    clear_all_caches!(obj)

Clear all `@cached` properties on a `@dynamicstruct` instance — both in-memory
and on disk. Equivalent to calling `@clear_cache!` on every cached property.
"""
function clear_all_caches!(obj)
    m = meta(typeof(obj))
    for (name, info) in m
        isfixed(info) && continue
        Symbol("@cached") in info.macros || continue
        clear_cache!(obj, name)
    end
    nothing
end

# --- KeyTracker: pluggable strategy for accessed-keys persistence ---

"""
    KeyTracker

Abstract type for pluggable accessed-keys persistence strategies. Implement
`record!(tracker, key)` and `load_keys(tracker)` for custom strategies.

Override `key_tracker(o, ::Val{name})` on your object type to select a strategy.
"""
abstract type KeyTracker end

"""
    SharedFileTracker(path)

Default strategy: all pods/processes share a single `_keys.sjl` file.
Simple, but not safe for concurrent multi-process writes to NFS.
"""
struct SharedFileTracker <: KeyTracker
    path::String
end

"""
    PerPodFileTracker(base_path, pod_id)

Per-pod strategy: each pod writes only to its own `_keys_{pod_id}.sjl` file.
`load_keys` unions all matching files. Safe for NFS multi-pod setups — writes
are never concurrent since each pod touches only its own file.
"""
struct PerPodFileTracker <: KeyTracker
    base_path::String  # path WITHOUT extension, e.g. "cache/abc/cmdstan_keys"
    pod_id::String
end

"""
    NoKeyTracker()

No-op strategy: never records or loads keys. Use when tracking is unwanted.
"""
struct NoKeyTracker <: KeyTracker end

function _record_key_to_path(path, key)
    mkpath(dirname(path))
    existing = isfile(path) ? Serialization.deserialize(path) : Set()
    key in existing && return
    push!(existing, key)
    Serialization.serialize(path, existing)
    nothing
end

"""
    record!(tracker::KeyTracker, key)

Record that `key` was accessed, persisting according to the tracker's strategy.
"""
record!(tracker::SharedFileTracker, key) = _record_key_to_path(tracker.path, key)
record!(tracker::NoKeyTracker, key)      = nothing
function record!(tracker::PerPodFileTracker, key)
    _record_key_to_path(tracker.base_path * "_" * tracker.pod_id * ".sjl", key)
end

"""
    load_keys(tracker::KeyTracker) -> Set

Load the full set of recorded keys according to the tracker's strategy.
"""
load_keys(tracker::SharedFileTracker) =
    isfile(tracker.path) ? Serialization.deserialize(tracker.path) : Set()
load_keys(tracker::NoKeyTracker) = Set()
function load_keys(tracker::PerPodFileTracker)
    dir    = dirname(tracker.base_path)
    prefix = basename(tracker.base_path) * "_"
    isdir(dir) || return Set()
    files = filter(
        f -> startswith(basename(f), prefix) && endswith(f, ".sjl"),
        readdir(dir; join=true)
    )
    isempty(files) && return Set()
    mapreduce(Serialization.deserialize, union, files)
end

"""
    key_tracker(o, ::Val{name}) -> KeyTracker

Return the `KeyTracker` to use for property `name` on object `o`.
Override this method on your type to change the tracking strategy.

```julia
# Example: use per-pod files for all indexed properties on MyType
DynamicObjects.key_tracker(o::MyType, ::Val{name}) where {name} =
    DynamicObjects.PerPodFileTracker(joinpath(o.cache_path, string(name) * "_keys"), pod_id)
```
"""
key_tracker(o, ::Val{name}) where {name} =
    SharedFileTracker(joinpath(o.cache_path, string(name) * "_keys.sjl"))

# --- Accessed-keys tracking for IndexableProperty ---

"""
    accessed_keys(ip::IndexableProperty)

Return the set of keys that have been accessed for this IndexableProperty,
loaded from disk. Returns an empty `Set` if no keys have been recorded.
"""
function accessed_keys(ip::IndexableProperty{name}) where {name}
    load_keys(key_tracker(ip.o, Val(name)))
end

"""
    record_access!(ip::IndexableProperty, key)

Record that `key` was accessed for this IndexableProperty, persisting to disk.
"""
function record_access!(ip::IndexableProperty{name}, key) where {name}
    record!(key_tracker(ip.o, Val(name)), key)
end

# Internal: record accessed key from getorcomputeproperty context
function _record_accessed_key(o, name::Symbol, indices, kwargs)
    record!(key_tracker(o, Val(name)), (indices, (;kwargs...)))
end

_computeproperty(o, name, indices...; __status__=nothing, kwargs...) = begin
    vname = Val(name)
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
            else
                cache_status == :started && @warn "Cache file $cache_path exists but has size 0.\nAssuming a previous run failed."
                touch(cache_path)
                nothing
            end
            if cache_status != :ready || resumes(o, vname, indices...; kwargs...)
                @debug "Generating $cache_path..."
                rv = compute_property(o, vname, indices...; _status_kw..., (name=>rv, )..., kwargs...)
                Serialization.serialize(cache_path, rv)
            end
            # Record accessed key for indexed @cached properties
            if !isempty(indices)
                _record_accessed_key(o, name, indices, kwargs)
            end
            rv
        else
            compute_property(o, vname, indices...; _status_kw..., kwargs...)
        end
    catch e
        kw_tuple = isempty(kwargs) ? () : Tuple(pairs(kwargs))
        bt = catch_backtrace()
        throw(PropertyComputationError(
            string(typeof(o).name.name),
            name,
            indices,
            kw_tuple,
            (e, bt),
        ))
    end
end
getorcomputeproperty(o, name, indices...; kwargs...) = if hasfield(typeof(o), name)
    @assert length(indices) == length(kwargs) == 0
    getfield(o, name)
else
    get!(getfield(o, :cache), name, indices...; kwargs...) do
        # When called with no indices on an indexed property (declared with
        # call/ref syntax, e.g. `x() = ...` or `x[i] = ...`), return an
        # IndexableProperty wrapper instead of calling compute_property.
        if isempty(indices) && isempty(kwargs)
            m = meta(typeof(o))
            if haskey(m, name) && m[name].indexed
                return IndexableProperty(name, o, subcache(getfield(o, :cache)))
            end
        end
        _computeproperty(o, name, indices...; kwargs...)
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
        cp = o.cache_path
        if isdir(cp)
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
walk_rhs(e::Expr; locals, properties, lnn=nothing) = if e.head == :let
    # locals = properties[dependent].locals
    ls = Set{Symbol}()
    !Meta.isexpr(e.args[1], :block) && (e.args[1] = Expr(:block, e.args[1]))
    map!(e.args[1].args, e.args[1].args) do arg 
        isa(arg, Symbol) && (arg = Expr(:(=), arg, arg))
        @assert Meta.isexpr(arg, :(=))
        name, rhs = arg.args[1], walk_rhs(arg.args[2]; locals, properties, lnn)
        name in locals || push!(ls, name)
        push!(locals, name)
        Expr(:(=), name, rhs)
    end
    e.args[2] = walk_rhs(e.args[2]; locals, properties, lnn)
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
    Expr(e.head, e.args[1], walk_rhs(e.args[2]; locals=new_locals, properties, lnn))
elseif e.head == :for
    # for x in range; body; end — iterator var is local in body
    # Multi-iterator: for x in xs, y in ys → args[1] is a :block of :(=)
    iter_block = e.args[1]
    iters = Meta.isexpr(iter_block, :block) ? iter_block.args : [iter_block]
    ls = mapreduce(it -> extractnames([it.args[1]]), union, iters)
    new_locals = union(locals, ls)
    walked_iters = [Expr(:(=), it.args[1], walk_rhs(it.args[2]; locals=new_locals, properties, lnn)) for it in iters]
    walked_iter_block = Meta.isexpr(iter_block, :block) ? Expr(:block, walked_iters...) : walked_iters[1]
    walked_body = walk_rhs(e.args[2]; locals=new_locals, properties, lnn)
    Expr(:for, walked_iter_block, walked_body)
elseif e.head == :generator
    # x for x in range — iterator var(s) are local in the body expression
    # args[1] = body, args[2:end] = Expr(:(=), var, range) or Expr(:filter, cond, Expr(:(=), ...) ...)
    raw_iters = e.args[2:end]
    # Extract all :(=) iterators, unwrapping :filter
    all_eq = Expr[]
    for it in raw_iters
        if Meta.isexpr(it, :filter)
            append!(all_eq, filter(a -> Meta.isexpr(a, :(=)), it.args))
        elseif Meta.isexpr(it, :(=))
            push!(all_eq, it)
        end
    end
    ls = isempty(all_eq) ? Set{Symbol}() : mapreduce(it -> extractnames([it.args[1]]), union, all_eq)
    new_locals = union(locals, ls)
    walked_body = walk_rhs(e.args[1]; locals=new_locals, properties, lnn)
    walked_iters = map(raw_iters) do it
        if Meta.isexpr(it, :filter)
            # filter args: condition, then :(=) iterators
            walked_args = map(it.args) do a
                if Meta.isexpr(a, :(=))
                    Expr(:(=), a.args[1], walk_rhs(a.args[2]; locals, properties, lnn))
                else
                    walk_rhs(a; locals=new_locals, properties, lnn)
                end
            end
            Expr(:filter, walked_args...)
        else
            Expr(:(=), it.args[1], walk_rhs(it.args[2]; locals, properties, lnn))
        end
    end
    Expr(:generator, walked_body, walked_iters...)
elseif e.head == :function
    # function g(x); body; end — func name and params are local in body
    sig = e.args[1]
    if Meta.isexpr(sig, :call)
        ls = extractnames(sig.args)  # includes func name + params
        new_locals = union(locals, ls)
        Expr(:function, sig, walk_rhs(e.args[2]; locals=new_locals, properties, lnn))
    else
        Expr(:function, sig, walk_rhs(e.args[2]; locals, properties, lnn))
    end
elseif e.head == :try
    # try; body; catch e; catch_body; [finally; finally_body;] end
    # args: [try_body, catch_var, catch_body, [finally_body]]
    walked_try = walk_rhs(e.args[1]; locals, properties, lnn)
    catch_var = e.args[2]  # Symbol or false
    catch_locals = catch_var isa Symbol ? union(locals, Set([catch_var])) : locals
    walked_catch = walk_rhs(e.args[3]; locals=catch_locals, properties, lnn)
    if length(e.args) >= 4
        walked_finally = walk_rhs(e.args[4]; locals, properties, lnn)
        Expr(:try, walked_try, catch_var, walked_catch, walked_finally)
    else
        Expr(:try, walked_try, catch_var, walked_catch)
    end
elseif e.head in (:kw, :(=))
    # For local function defs like f(x) = x + 1, add func name + params as locals in body
    if Meta.isexpr(e.args[1], :call)
        ls = extractnames(e.args[1].args)  # includes func name + params
        new_locals = union(locals, ls)
        Expr(e.head, e.args[1], walk_rhs.(e.args[2:end]; locals=new_locals, properties, lnn)...)
    else
        # Warn if assigning to a property name inside a block — likely intended as local
        lhs = e.args[1]
        if e.head == :(=)
            shadowed = if lhs isa Symbol
                haskey(properties, lhs) && !(lhs in locals) ? [lhs] : Symbol[]
            elseif Meta.isexpr(lhs, :tuple)
                [s for s in lhs.args if s isa Symbol && haskey(properties, s) && !(s in locals)]
            else
                Symbol[]
            end
            for s in shadowed
                loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
                @warn "Assignment to `$s` in a property RHS shadows property `$s`$loc. This writes to the property cache, not a local variable. Use `let $s = ...` for a local."
            end
        end
        Expr(e.head, e.args[1], walk_rhs.(e.args[2:end]; locals, properties, lnn)...)
    end
elseif e.head == :tuple
    # Named tuple: (x=1, y=2) — :(=) children are field definitions, not assignments.
    # Walk only the values, not the keys.
    walked = map(e.args) do arg
        if Meta.isexpr(arg, :(=))
            Expr(:(=), arg.args[1], walk_rhs(arg.args[2]; locals, properties, lnn))
        else
            walk_rhs(arg; locals, properties, lnn)
        end
    end
    Expr(:tuple, walked...)
else
    # Track LineNumberNodes for better warning locations
    new_lnn = lnn
    walked = map(e.args) do arg
        if arg isa LineNumberNode
            new_lnn = arg
            arg
        else
            walk_rhs(arg; locals, properties, lnn=new_lnn)
        end
    end
    Expr(e.head, walked...)
end
walk_rhs(e::Symbol; locals, properties, lnn=nothing) = if haskey(properties, e) && !(e in locals)
    :(__self__.$e)
else
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
    f = x.args[1]
    # Collect keyword args in two passes: fixed kwargs first, splats (kwargs...) last.
    # This is necessary because the new Expr-based method generation may merge multiple
    # :parameters nodes (e.g. one from info.indices containing `kwargs...` and one from
    # cp_kwargs containing `name=val`). Julia requires splat kwargs to be final, so we
    # sort them to the end regardless of which :parameters node they originated from.
    pargs_fixed = []
    pargs_splat = []
    args = []
    for arg in fixcall.(x.args[2:end])
        if Meta.isexpr(arg, :parameters)
            for a in arg.args
                Meta.isexpr(a, :(...)) ? push!(pargs_splat, a) : push!(pargs_fixed, a)
            end
        else
            push!(args, arg)
        end
    end
    Expr(x.head, f, Expr(:parameters, pargs_fixed..., pargs_splat...), args...)
else
    Expr(x.head, fixcall.(x.args)...)
end
dynamicstruct(expr; docstring=nothing, cache_type=:serial, child_handler=nothing) = begin
    @assert expr.head == :struct
    mut, head, body = expr.args
    type = head
    Meta.isexpr(type, :(<:)) && (type = type.args[1])
    Meta.isexpr(type, :(curly)) && (type = type.args[1])
    @assert body.head == :block
    # --- Extract inline struct definitions ---
    # Collect parent property names (excluding inline structs themselves)
    parent_props = Symbol[]
    for arg in body.args
        arg isa Expr || continue
        a = arg
        while Meta.isexpr(a, :macrocall); a = a.args[end]; end
        # Skip inline structs (both forms)
        Meta.isexpr(a, :struct) && continue
        Meta.isexpr(a, :(=)) && Meta.isexpr(a.args[2], :struct) && continue
        lhs = if Meta.isexpr(a, :(=))
            a.args[1]
        else
            a  # fixed field: bare symbol or typed symbol
        end
        Meta.isexpr(lhs, (:call, :ref)) && (lhs = lhs.args[1])
        Meta.isexpr(lhs, :(::)) && (lhs = lhs.args[1])
        lhs isa Symbol && push!(parent_props, lhs)
    end
    extracted_structs = Expr[]
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        prop_name = nothing
        child_struct = nothing
        # Form 1: prop = struct Name ... end
        if Meta.isexpr(arg, :(=)) && Meta.isexpr(arg.args[2], :struct)
            prop_name = arg.args[1]
            child_struct = arg.args[2]
        # Form 2: struct Name ... end (bare)
        elseif Meta.isexpr(arg, :struct)
            child_struct = arg
        end
        isnothing(child_struct) && continue
        child_name = child_struct.args[2]
        isnothing(prop_name) && (prop_name = child_name)
        # Rename child struct to Parent_Child to avoid kwarg shadowing
        gen_name = Symbol(type, "_", child_name)
        child_struct.args[2] = gen_name
        # Collect child's own property names to avoid collision
        child_props = Set{Symbol}()
        for ca in child_struct.args[3].args
            ca isa Expr || continue
            ca2 = ca
            while Meta.isexpr(ca2, :macrocall); ca2 = ca2.args[end]; end
            Meta.isexpr(ca2, :(=)) || continue
            clhs = ca2.args[1]
            Meta.isexpr(clhs, (:call, :ref)) && (clhs = clhs.args[1])
            Meta.isexpr(clhs, :(::)) && (clhs = clhs.args[1])
            clhs isa Symbol && push!(child_props, clhs)
        end
        # Prepend __parent__ and forwarded properties to child body
        child_body = child_struct.args[3]
        forwarded = [pp for pp in parent_props if !(pp in child_props)]
        prepend = Expr[]
        push!(prepend, :(__parent__ = nothing))
        if !isempty(forwarded)
            push!(prepend, :($(Expr(:tuple, Expr(:parameters, forwarded...))) = __parent__))
        end
        child_body.args = vcat(prepend, child_body.args)
        push!(extracted_structs, child_struct)
        # Replace with property assignment
        body.args[i] = :($prop_name = $gen_name(; __parent__=__self__))
    end
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
        indexed = false
        while Meta.isexpr(arg, :macrocall)
            push!(macros, arg.args[1])
            arg = arg.args[end]
        end
        if Meta.isexpr(arg, :function)
            fname = Meta.isexpr(arg.args[1], :call) ? arg.args[1].args[1] : arg.args[1]
            error("Use short-form syntax for properties in @dynamicstruct: `$fname(...) = ...` instead of `function $fname(...) ... end`. If `$fname` is a helper that doesn't depend on the struct's state, move it outside the @dynamicstruct body.")
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
            # When RHS is a bare symbol in named destructuring, skip the hidden
            # group property and extract directly: (;a, b) = config → a = config.a
            # Otherwise, use a group property to evaluate the RHS once.
            extract_from = if named && rhs isa Symbol
                rhs
            else
                group_name = Symbol("_tuple_", join(prop_names, "_"))
                group_locals = Set{Symbol}(prop_names)
                push!(group_locals, group_name)
                push!(oproperties, group_name=>(;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false))
                push!(docs, (group_name=>(doc, true)))
                group_name
            end
            doc = nothing
            for (prop_name, source) in members
                extract_rhs = if source isa Symbol
                    Expr(:., extract_from, QuoteNode(source))
                else
                    :($extract_from[$source])
                end
                push!(oproperties, prop_name=>(;lhs=prop_name, macros=Set{Symbol}(), rhs=extract_rhs, lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([prop_name]), indices=tuple(), indexed=false))
                push!(docs, (prop_name=>(nothing, true)))
            end
            continue
        end
        if Meta.isexpr(arg, :ref)
            loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
            pname = arg.args[1]
            Meta.isexpr(pname, :(::)) && (pname = pname.args[1])
            @warn "Deprecated: `$pname` uses [] syntax which cannot combine with kwargs$loc. Use () instead: $pname($(join(arg.args[2:end], ", ")))"
        end
        if Meta.isexpr(arg, (:ref, :call))
            arg, indices... = arg.args
            indexed = true
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
        push!(oproperties, name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices, indexed))
    end
    properties = Dict(oproperties)

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
    result = Expr(:block)
    # Prepend extracted inline child structs (processed recursively)
    _child_handler = isnothing(child_handler) ? dynamicstruct : child_handler
    for s in extracted_structs
        child_result = _child_handler(s)
        # Unwrap esc() — parent handles escaping
        @assert Meta.isexpr(child_result, :escape)
        push!(result.args, child_result.args[1])
    end
    push!(result.args, Expr(:block,
        :(@doc $docstring $struct_expr),
        quote
            $Base.hasproperty(__self__::$type, name::Symbol) = name in $(Tuple(keys(properties)))
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
                # Build method definitions with Expr directly (not :() syntax)
                # so the parser doesn't insert DynamicObjects.jl LNNs into
                # the method body — Julia uses the body's first LNN for
                # Method.file/line, which must point at user code.
                _lnn = something(info.lnn, LineNumberNode(0, :unknown))
                _call(f, extras...) = fixcall(Expr(:call,
                    Expr(:., DynamicObjects, QuoteNode(f)),
                    :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    info.indices..., Expr(:parameters, extras...),
                ))
                iscached_val = Symbol("@cached") in info.macros
                Expr(:block,
                    _lnn, Expr(:(=), _call(:compute_property, cp_kwargs...), Expr(:block, _lnn, walk_rhs(info.rhs; info.locals, properties, lnn=info.lnn))),
                    _lnn, Expr(:(=), _call(:iscached), Expr(:block, _lnn, iscached_val)),
                    _lnn, Expr(:(=), _call(:resumes), Expr(:block, _lnn, false)),
                )
            end
            for (name, info) in oproperties if !isfixed(info)
        ]...,
        # IndexableProperty wrappers for indexed properties are now created
        # directly in getorcomputeproperty (via meta check), so no zero-arg
        # compute_property methods are needed here.
    ))
    esc(result)
end

# Replace only the top-level LineNumberNodes in a block, leaving nested ones intact.
# This gives Revise the source-location metadata it needs to track method changes,
# while preserving internal LineNumberNodes for useful stacktraces.
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

"""
    PropertyComputationError <: Exception

Wraps an error that occurred during lazy property computation, adding context
about which property failed (property name, type, indices/kwargs). The original
exception and backtrace are stored in the `cause` field.
"""
struct PropertyComputationError <: Exception
    type_name::String
    property::Symbol
    indices::Tuple
    kwargs::Tuple  # tuple of pairs
    cause::Any
end

"""
    unwrap_error(e)

Recursively unwrap `TaskFailedException`, `CompositeException`, and
`PropertyComputationError` wrappers to find the root cause exception.
"""
unwrap_error(e::Base.TaskFailedException) = unwrap_error(e.task.exception)
unwrap_error(e::CompositeException) = unwrap_error(first(e.exceptions))
unwrap_error(e::PropertyComputationError) = unwrap_error(_cause_error(e))
unwrap_error(e) = e

# Extract the exception from cause (which may be a (exception, backtrace) tuple)
_cause_error(e::PropertyComputationError) = e.cause isa Tuple ? first(e.cause) : e.cause

function _format_property_key(name, indices, kwargs)
    s = string(name)
    pos_parts = !isempty(indices) ? repr.(collect(indices)) : String[]
    kw_parts = ["$k=$(repr(v))" for (k, v) in kwargs]
    all_parts = isempty(pos_parts) && !isempty(kw_parts) ?
        ["; " * join(kw_parts, ", ")] :
        vcat(pos_parts, isempty(kw_parts) ? String[] : ["; " * join(kw_parts, ", ")])
    isempty(all_parts) ? s : s * "(" * join(all_parts, ", ") * ")"
end

function Base.showerror(io::IO, e::PropertyComputationError)
    key = _format_property_key(e.property, e.indices, e.kwargs)
    print(io, "PropertyComputationError: computing `$key` on $(e.type_name)\n")
    cause_err = _cause_error(e)
    cause_bt = e.cause isa Tuple && length(e.cause) >= 2 ? e.cause[2] : nothing
    print(io, "  Caused by: ")
    if cause_err isa PropertyComputationError
        showerror(io, cause_err)
    elseif !isnothing(cause_bt)
        showerror(io, cause_err, cause_bt)
    else
        showerror(io, cause_err)
    end
end

end