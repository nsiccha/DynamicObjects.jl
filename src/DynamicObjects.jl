"""
    DynamicObjects

Provides the `@dynamicstruct` macro for defining structs with lazily computed,
optionally disk-cached properties.

# Exports
- [`@dynamicstruct`](@ref): Define a struct with computed/cached properties.
- [`@cache_status`](@ref): Get the disk-cache status of a property (`:unstarted`, `:started`, `:ready`).
- [`@is_cached`](@ref): Check whether a property's disk cache is ready.
- [`@cache_path`](@ref): Get the file path used for a property's disk cache.
- [`@lru`](@ref): Bound an indexed property's in-memory cache via LRU eviction.
- [`remake`](@ref): Create a new instance of a `@dynamicstruct` type with some fields changed.
- [`fetchindex`](@ref): Non-blocking access to `ThreadsafeDict`-backed properties with `(rv, status)` callback.
- [`getstatus`](@ref): Read the status object for an in-flight computation.
- [`@clear_cache!`](@ref): Clear the disk and in-memory cache for a property.
- [`@persist`](@ref): Manually persist a property value to disk cache.
- [`PropertyComputationError`](@ref): Exception wrapper for errors during property computation.
- [`unwrap_error`](@ref): Dig through exception wrappers to find the root cause.
- [`entries`](@ref): List all entries in a `ThreadsafeDict`-backed property with state info.
- [`cached_entries`](@ref): Iterate completed (non-Task) entries of an indexed property.
- [`clear_mem_caches!`](@ref): Clear in-memory memoized values (disk caches untouched).
- [`clear_disk_caches!`](@ref): Delete on-disk cache files (in-memory values untouched).
- [`clear_all_caches!`](@ref): Clear both in-memory and disk caches.
- [`PersistentSet`](@ref): Thread-safe, disk-persisted `Set`.
- [`LazyPersistentDict`](@ref): Thread-safe, lazily-loaded, disk-persisted `Dict`.
- [`KeyTracker`](@ref): Abstract type for pluggable accessed-keys persistence strategies.
- [`SharedFileTracker`](@ref): Default strategy — single shared `_keys.sjl` file.
- [`PerPodFileTracker`](@ref): Per-pod strategy — one file per pod ID, merged on read.
- [`NoKeyTracker`](@ref): No-op strategy — never records or loads keys.
- [`key_tracker`](@ref): Override to set the tracking strategy per object type / property.
- [`record!`](@ref): Record an accessed key via a `KeyTracker`.
- [`load_keys`](@ref): Load the full set of recorded keys via a `KeyTracker`.
"""
module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached, @cache_path, @clear_cache!, @persist, @memo, @lru, remake, fetchindex, fetchindex!, getstatus, PropertyComputationError, unwrap_error, entries, cached_entries, clear_all_caches!, clear_mem_caches!, clear_disk_caches!, PersistentSet, LazyPersistentDict, KeyTracker, SharedFileTracker, PerPodFileTracker, NoKeyTracker, key_tracker, record!, load_keys, cancel!, cancel_all!, ThreadsafeLRUDict, LRUDict

import SHA, Serialization

struct DiskCacheLocks
    lock::ReentrantLock
    locks::Dict{String, ReentrantLock}
end
DiskCacheLocks() = DiskCacheLocks(ReentrantLock(), Dict{String, ReentrantLock}())
get_path_lock!(d::DiskCacheLocks, path::String) = lock(d.lock) do
    get!(() -> ReentrantLock(), d.locks, path)
end

persistent_hash(x) = begin
    b = IOBuffer()
    Serialization.serialize(b, x)
    bytes2hex(SHA.sha1(take!(b)))
end
iscached(o, ::Val) = false
cache_version(o, ::Val) = nothing
compute_property(o, ::Val{:hash_fields}) = ntuple(Base.Fix1(getfield, o), fieldcount(typeof(o))-1)
compute_property(o, ::Val{:hash}) = persistent_hash((typeof(o), _hash_replace(o.hash_fields)))
# Shallow walker used only by the :hash compute. Leaves non-DO values
# structurally identical so hashes stay stable for DOs that don't nest DOs,
# and substitutes any DO with its own (stable) `.hash` string. Per-type
# `_hash_replace(::MyType) = x.hash` overloads are emitted by @dynamicstruct.
_hash_replace(x::Tuple) = map(_hash_replace, x)
_hash_replace(x::NamedTuple) = map(_hash_replace, x)
_hash_replace(x) = x
compute_property(o, ::Val{:cache_base}) = "cache"
compute_property(o, ::Val{:cache_path}) = joinpath(o.cache_base, o.hash)
compute_property(o, ::Val{:__status__}) = nothing
compute_property(o, ::Val{:__strict__}) = true
compute_property(o, ::Val{:__cache_type__}) = typeof(getfield(o, :cache).cache)
compute_property(o, ::Val{:__substatus__}, name, args...; kwargs...) =
    _default_substatus(o.__status__, o, name, args...; kwargs...)
_default_substatus(status, o, name, args...; kwargs...) = nothing

# Substatus lifecycle hooks — overridden by TreebarsExt to forward to
# `Treebars.finalize_progress!` / `Treebars.fail_progress!`. Default is no-op
# so DO stays independent of Treebars. Called from ThreadsafeDict's spawn
# wrapper around `f(s)` to give the substatus the `with_progress` init/run/
# finalize symmetry it otherwise lacks.
_finalize_substatus!(s) = nothing
_finalize_substatus!(::Nothing) = nothing
_fail_substatus!(s, e) = nothing
_fail_substatus!(::Nothing, e) = nothing

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
"""
    AbstractThreadsafeDict{K,V}

Supertype for the lock-protected, task-spawning dicts that back `:parallel`
indexed properties. Concrete subtypes (`ThreadsafeDict`, `ThreadsafeLRUDict`)
share the `(lock, cache, tasks, status)` shape so that `getstatus`/`cancel!`/
`fetchindex`/`entries` and the `IndexableProperty` task-spawning `getindex`
dispatch generically.
"""
abstract type AbstractThreadsafeDict{K,V} <: AbstractDict{K,V} end

struct ThreadsafeDict{K,V} <: AbstractThreadsafeDict{K,V}
    lock::ReentrantLock
    cache::Dict{K,V}
    tasks::Dict{K,Task}
    status::Dict{K,Any}
    ThreadsafeDict{K,V}(c) where {K,V} = new{K,V}(ReentrantLock(), Dict{K,V}(c), Dict{K,Task}(), Dict{K,Any}())
    ThreadsafeDict() = new{Any,Any}(ReentrantLock(), Dict{Any,Any}(), Dict{Any,Task}(), Dict{Any,Any}())
end

"""
    ThreadsafeLRUDict{K,V}(maxsize)

A `ThreadsafeDict` variant that bounds its cache to `maxsize` entries, evicting
the least-recently-used keys on insert. Eviction skips keys that have an
in-flight `Task` (i.e. a running computation), so callers awaiting a result
never observe its cache slot vanish underneath them. If every slot is pinned
by a running task, the dict is allowed to temporarily exceed `maxsize`.

The `(lock, cache, tasks, status)` shape matches `ThreadsafeDict`, so all the
generic dispatch on `<:AbstractThreadsafeDict` (`getstatus`, `cancel!`,
`fetchindex`, `entries`, …) works unchanged.
"""
mutable struct ThreadsafeLRUDict{K,V} <: AbstractThreadsafeDict{K,V}
    lock::ReentrantLock
    cache::Dict{K,V}
    tasks::Dict{K,Task}
    status::Dict{K,Any}
    order::Vector{K}        # MRU-last
    maxsize::Int
end
ThreadsafeLRUDict{K,V}(maxsize::Integer) where {K,V} =
    ThreadsafeLRUDict{K,V}(ReentrantLock(), Dict{K,V}(), Dict{K,Task}(), Dict{K,Any}(), K[], Int(maxsize))
ThreadsafeLRUDict(maxsize::Integer) = ThreadsafeLRUDict{Any,Any}(maxsize)

"""
    LRUDict{K,V}(maxsize)

Plain (non-thread-safe) `Dict` bounded to `maxsize` entries via least-recently-used
eviction. Used as the per-property in-memory cache for `@lru`-marked properties on
`:serial` `@dynamicstruct` instances.
"""
mutable struct LRUDict{K,V} <: AbstractDict{K,V}
    cache::Dict{K,V}
    order::Vector{K}        # MRU-last
    maxsize::Int
    LRUDict{K,V}(maxsize::Integer) where {K,V} = new{K,V}(Dict{K,V}(), K[], Int(maxsize))
end
LRUDict(maxsize::Integer) = LRUDict{Any,Any}(maxsize)

const _cache_types = (;serial=Dict, parallel=ThreadsafeDict)
resolve_cache_type(s::Symbol) = get(_cache_types, s, s)
resolve_cache_type(T::Type) = T.name.wrapper
resolve_cache_type(T::UnionAll) = T

Base.length(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.cache); end
# NOTE: iteration is NOT truly thread-safe — each iterate call locks independently,
# so the dict can mutate between calls. For thread-safe iteration, use
# lock(c.lock) do ... end or entries(ip) which holds the lock for the full sweep.
Base.iterate(c::AbstractThreadsafeDict) = lock(c.lock) do; iterate(c.cache); end
Base.iterate(c::AbstractThreadsafeDict, state) = lock(c.lock) do; iterate(c.cache, state); end
Base.empty!(c::ThreadsafeDict) = (lock(c.lock) do; empty!(c.cache); empty!(c.tasks); empty!(c.status); end; c)
Base.empty!(c::ThreadsafeLRUDict) = (lock(c.lock) do; empty!(c.cache); empty!(c.tasks); empty!(c.status); empty!(c.order); end; c)
n_running(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.tasks); end
Base.show(io::IO, c::ThreadsafeDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeDict{", K, ",", V, "}(", length(c.cache), " cached, ", length(c.tasks), " running)")
end
Base.show(io::IO, c::ThreadsafeLRUDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeLRUDict{", K, ",", V, "}(", length(c.cache), "/", c.maxsize, " cached, ", length(c.tasks), " running)")
end
Base.getindex(ip::IndexableProperty{name,<:Any,<:AbstractThreadsafeDict}, indices...; fetch=Base.fetch, retry_failed=true, kwargs...) where {name} = begin
    (;o, cache) = ip
    substatus_f = if name != :__substatus__ && name != :__status__
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name, indices...; __status__=root, kwargs...)
        end
    else
        nothing
    end
    get!(cache, (indices, (;kwargs...)); fetch, substatus=substatus_f, retry_failed) do s
        getorcomputeproperty(o, name, indices...; __status__=s, kwargs...)
    end
end
Base.get!(f::Function, c::AbstractThreadsafeDict, key; fetch=Base.fetch, substatus=nothing, retry_failed=true) = begin
    rv = lock(c.lock) do
        v = get(c.cache, key, _missing_sentinel)
        if v !== _missing_sentinel
            _on_hit!(c, key)
            v
        else
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
                    try
                        tmp = f(s)
                        lock(c.lock) do
                            c.cache[key] = tmp
                            pop!(c.tasks, key)
                            _on_store!(c, key)
                        end
                        _finalize_substatus!(s)
                        tmp
                    catch e
                        # Leave c.tasks/c.status populated so entries()/getstatus()
                        # can surface the failure until retry_failed clears it.
                        _fail_substatus!(s, e)
                        rethrow()
                    end
                end
            end
        end
    end
    fetch(rv)
end

# Singleton sentinel so a single `get` lookup distinguishes "key absent" from
# "key present with value === nothing" without allowing collision with any
# user-stored value.
struct _Missing end
const _missing_sentinel = _Missing()

# Hooks into get! for LRU bookkeeping. No-ops on plain ThreadsafeDict;
# ThreadsafeLRUDict implements ordering and eviction. Both run under c.lock.
_on_hit!(::AbstractThreadsafeDict, key) = nothing
_on_store!(::AbstractThreadsafeDict, key) = nothing
function _on_hit!(c::ThreadsafeLRUDict, key)
    idx = findfirst(==(key), c.order)
    isnothing(idx) && return
    idx == length(c.order) && return
    deleteat!(c.order, idx)
    push!(c.order, key)
end
function _on_store!(c::ThreadsafeLRUDict, key)
    push!(c.order, key)
    # Evict from front, skipping pinned keys (those with running tasks).
    # If every slot is pinned, leave the dict temporarily oversized.
    while length(c.cache) > c.maxsize
        evicted = false
        for i in eachindex(c.order)
            k = c.order[i]
            if !haskey(c.tasks, k)
                deleteat!(c.order, i)
                haskey(c.cache, k) && pop!(c.cache, k)
                haskey(c.status, k) && pop!(c.status, k)
                evicted = true
                break
            end
        end
        evicted || break
    end
end

Base.pop!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        haskey(c.status, key) && pop!(c.status, key)
        _drop_order!(c, key)
        pop!(c.cache, key)
    end
end
Base.delete!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        delete!(c.status, key)
        delete!(c.tasks, key)
        _drop_order!(c, key)
        delete!(c.cache, key)
    end
    c
end
_drop_order!(::AbstractThreadsafeDict, key) = nothing
function _drop_order!(c::ThreadsafeLRUDict, key)
    idx = findfirst(==(key), c.order)
    isnothing(idx) || deleteat!(c.order, idx)
end

# --- Synchronous LRUDict (for :serial @dynamicstruct + @lru) ---
Base.length(c::LRUDict) = length(c.cache)
Base.iterate(c::LRUDict, args...) = iterate(c.cache, args...)
Base.haskey(c::LRUDict, key) = haskey(c.cache, key)
Base.empty!(c::LRUDict) = (empty!(c.cache); empty!(c.order); c)
Base.show(io::IO, c::LRUDict{K,V}) where {K,V} =
    print(io, "LRUDict{", K, ",", V, "}(", length(c.cache), "/", c.maxsize, ")")
function _touch_lru!(c::LRUDict, key)
    idx = findfirst(==(key), c.order)
    isnothing(idx) && return
    idx == length(c.order) && return
    deleteat!(c.order, idx)
    push!(c.order, key)
end
function Base.get!(f::Function, c::LRUDict, key)
    if haskey(c.cache, key)
        _touch_lru!(c, key)
        return c.cache[key]
    end
    v = f()
    c.cache[key] = v
    push!(c.order, key)
    while length(c.cache) > c.maxsize
        evicted = popfirst!(c.order)
        delete!(c.cache, evicted)
    end
    v
end
function Base.pop!(c::LRUDict, key)
    idx = findfirst(==(key), c.order)
    isnothing(idx) || deleteat!(c.order, idx)
    pop!(c.cache, key)
end
function Base.delete!(c::LRUDict, key)
    idx = findfirst(==(key), c.order)
    isnothing(idx) || deleteat!(c.order, idx)
    delete!(c.cache, key)
    c
end

"""
    getstatus(ip::IndexableProperty, indices...; kwargs...)

Return the status object associated with an in-flight computation for the given
key, or `nothing` if no status exists (computation not started, already finished,
or no `__substatus__` defined).

Only meaningful for `IndexableProperty` backed by a `ThreadsafeDict`.
"""
getstatus(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}, indices...; kwargs...) = begin
    lock(ip.cache.lock) do
        get(ip.cache.status, (indices, (;kwargs...)), nothing)
    end
end
getstatus(::IndexableProperty, indices...; kwargs...) = nothing

"""
    cancel!(ip::IndexableProperty, indices...; kwargs...)

Cancel a running task for the given key on a `ThreadsafeDict`-backed `IndexableProperty`.
Returns `true` if a running task was found and interrupted, `false` otherwise.
"""
cancel!(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}, indices...; kwargs...) = begin
    key = (indices, (;kwargs...))
    lock(ip.cache.lock) do
        if haskey(ip.cache.tasks, key) && !istaskdone(ip.cache.tasks[key])
            Base.schedule(ip.cache.tasks[key], InterruptException(); error=true)
            pop!(ip.cache.tasks, key)
            haskey(ip.cache.status, key) && pop!(ip.cache.status, key)
            true
        else
            false
        end
    end
end
cancel!(::IndexableProperty, args...; kwargs...) = false

"""
    cancel_all!(ip::IndexableProperty)

Cancel all running tasks on a `ThreadsafeDict`-backed `IndexableProperty`.
"""
cancel_all!(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}) = begin
    lock(ip.cache.lock) do
        for (key, task) in ip.cache.tasks
            istaskdone(task) || Base.schedule(task, InterruptException(); error=true)
        end
        empty!(ip.cache.tasks)
        empty!(ip.cache.status)
    end
    nothing
end
cancel_all!(::IndexableProperty) = nothing

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
function fetchindex(fetch, ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}, indices...;
                    force=false, retry_failed=force, kwargs...)
    if force
        maybepop!(ip.cache, (indices, (;kwargs...)))
        path = get_cache_path(ip.o, name(ip), indices...; kwargs...)
        isfile(path) && rm(path)
    end
    rv = getindex(ip, indices...; fetch=identity, retry_failed, kwargs...)
    status = getstatus(ip, indices...; kwargs...)
    fetch(rv, status)
end
# Fallback for non-ThreadsafeDict IPs (1-arg callback, no status)
fetchindex(fetch, args...; kwargs...) = getindex(args...; fetch, kwargs...)

"""
    fetchindex!(callback, ip, indices...; fetch=Base.fetch, kwargs...)

In-place variant of [`fetchindex`](@ref). When `callback` is `nothing`, falls
through to a plain `getindex(ip, indices...; fetch, kwargs...)` — useful for
sites that opt out of the two-phase fetch dance without changing call shape.
"""
fetchindex!(::Nothing, ip, indices...; fetch=Base.fetch, kwargs...) = getindex(ip, indices...; fetch, kwargs...)
maybepop!(c::AbstractDict, key) = haskey(c, key) && pop!(c, key)
maybepop!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        maybepop!(c.cache, key)
        maybepop!(c.tasks, key)
        maybepop!(c.status, key)
        _drop_order!(c, key)
    end
end

# Per-property cache backing. Default falls through to the parent cache type;
# `@dynamicstruct` emits 4-arg overrides for `@lru`-marked properties to swap
# in an LRU-bounded dict. The 4-arg form is keyed on `(ParentType, Val{name})`
# so an `@lru` directive on one struct doesn't leak to another struct that
# happens to declare a property with the same Symbol.
subcache(pc::PropertyCache, ::Type, ::Val) = subcache(pc)
subcache(::PropertyCache{<:Dict}) = Dict()
subcache(::PropertyCache{<:AbstractThreadsafeDict}) = ThreadsafeDict()

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

# --- LazyPersistentDict ---

"""
    LazyPersistentDict{D<:AbstractDict}(path[, empty_data]; seed!)

Threadsafe dict backed by `Serialization.serialize`/`deserialize`. The backing
file path is resolved **lazily** via a callable `path` so the constructor
itself is precompile-safe (no `mkpath`, no file I/O). The on-disk file is
loaded on the first operation (double-checked under the lock), and the
optional `seed!(data)` callback runs once after load if the dict is empty.
Mutations persist to disk synchronously under the lock.

`path` may be an `AbstractString` (fixed path) or a 0-arg function returning
a `String`. Pass an ordered backing dict (e.g. `OrderedDict{K,V}()`) to
preserve insertion order.
"""
mutable struct LazyPersistentDict{D<:AbstractDict}
    path_fn::Function
    data::D
    seed!::Function
    lock::ReentrantLock
    loaded::Bool
end

_no_seed!(_) = nothing

_path_fn(path::AbstractString) = (let p = String(path); () -> p end)
_path_fn(path) = path

function LazyPersistentDict(path, empty_data::D = Dict{Any,Any}();
        seed! = _no_seed!) where {D<:AbstractDict}
    LazyPersistentDict{D}(_path_fn(path), empty_data, seed!, ReentrantLock(), false)
end

# If the deserialized payload's concrete type matches `d.data`'s, swap the
# whole container in (cheaper, preserves identity semantics). Otherwise merge
# entries into the existing one.
_ingest_loaded!(d::LazyPersistentDict{D}, loaded::D) where {D} = (d.data = loaded)
_ingest_loaded!(d::LazyPersistentDict, loaded) = merge!(d.data, loaded)

function _ensure_loaded!(d::LazyPersistentDict)
    @lock d.lock begin
        d.loaded && return
        p = d.path_fn()
        if isfile(p)
            _ingest_loaded!(d, Serialization.deserialize(p))
        end
        if isempty(d.data)
            d.seed!(d.data)
            if !isempty(d.data)
                _persist_unlocked!(d)
            end
        end
        d.loaded = true
    end
end

function _persist_unlocked!(d::LazyPersistentDict)
    p = d.path_fn()
    mkpath(dirname(p))
    Serialization.serialize(p, d.data)
end

Base.keys(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock collect(keys(d.data)))
Base.values(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock collect(values(d.data)))
Base.pairs(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock collect(pairs(d.data)))
Base.length(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock length(d.data))
Base.isempty(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock isempty(d.data))
Base.haskey(d::LazyPersistentDict, k) = (_ensure_loaded!(d); @lock d.lock haskey(d.data, k))
Base.getindex(d::LazyPersistentDict, k) = (_ensure_loaded!(d); @lock d.lock d.data[k])
Base.get(d::LazyPersistentDict, k, default) = (_ensure_loaded!(d); @lock d.lock get(d.data, k, default))

function Base.iterate(d::LazyPersistentDict, st=nothing)
    if st === nothing
        _ensure_loaded!(d)
        snap = @lock d.lock collect(pairs(d.data))
        rv = iterate(snap)
        rv === nothing && return nothing
        (pair, idx) = rv
        return (pair, (snap, idx))
    end
    (snap, idx) = st
    rv = iterate(snap, idx)
    rv === nothing && return nothing
    (pair, next_idx) = rv
    (pair, (snap, next_idx))
end
Base.IteratorSize(::Type{<:LazyPersistentDict}) = Base.HasLength()
Base.eltype(::Type{LazyPersistentDict{D}}) where {D<:AbstractDict} = eltype(D)

function Base.setindex!(d::LazyPersistentDict, v, k)
    _ensure_loaded!(d)
    @lock d.lock begin
        d.data[k] = v
        _persist_unlocked!(d)
    end
    v
end

function Base.delete!(d::LazyPersistentDict, k)
    _ensure_loaded!(d)
    @lock d.lock begin
        delete!(d.data, k)
        _persist_unlocked!(d)
    end
    d
end

function Base.get!(f::Function, d::LazyPersistentDict, k)
    _ensure_loaded!(d)
    @lock d.lock begin
        haskey(d.data, k) && return d.data[k]
        rv = f()
        d.data[k] = rv
        _persist_unlocked!(d)
        rv
    end
end

# --- entries / cached_entries for IndexableProperty ---

"""
    entries(ip::IndexableProperty)

Return a vector of `(; key, state, status, value)` for all entries in a
`ThreadsafeDict`-backed `IndexableProperty`. `state` is one of `:running`,
`:failed`, `:finishing`, or `:done`. `value` is the cached result (for `:done`)
or the `Task` (for running/failed/finishing). `status` is the substatus object
or `nothing`.
"""
function entries(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict})
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
function cached_entries(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict})
    lock(ip.cache.lock) do
        collect(ip.cache.cache)
    end
end
function cached_entries(ip::IndexableProperty)
    collect(ip.cache)
end

# --- cache clearing ---

"""
    clear_mem_caches!(obj)

Clear all in-memory memoized property values on a `@dynamicstruct` instance,
leaving disk caches (`@cached` files) untouched. Every derived property —
including child DOs stored as values — will be recomputed on next access.

This is useful after hot-reloading code via Revise: property values computed by
old method definitions stay memoized until the process restarts or this function
is called.
"""
function clear_mem_caches!(obj)
    empty!(getfield(obj, :cache).cache)
    nothing
end

"""
    clear_disk_caches!(obj)

Delete all on-disk cache files for `@cached` properties on a `@dynamicstruct`
instance. In-memory values are left intact (they'll be stale until
`clear_mem_caches!` is also called, or until the process restarts).
"""
function clear_disk_caches!(obj)
    m = meta(typeof(obj))
    cp = obj.cache_path
    isdir(cp) || return nothing
    for (name, info) in m
        isfixed(info) && continue
        Symbol("@cached") in info.macros || continue
        prefix = string(name)
        for f in readdir(cp)
            if endswith(f, ".sjl") && (f == prefix * ".sjl" || startswith(f, prefix * "_"))
                rm(joinpath(cp, f))
            end
        end
    end
    nothing
end

"""
    clear_all_caches!(obj)

Clear all `@cached` properties on a `@dynamicstruct` instance — both in-memory
and on disk. Equivalent to `clear_mem_caches!` + `clear_disk_caches!`.
"""
function clear_all_caches!(obj)
    clear_mem_caches!(obj)
    clear_disk_caches!(obj)
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

# TODO: use DiskCacheLocks to make _record_key_to_path concurrency-safe
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
# Disabled: key tracking files are not concurrency-safe and cause EOFError crashes
function _record_accessed_key(o, name::Symbol, indices, kwargs)
    # record!(key_tracker(o, Val(name)), (indices, (;kwargs...)))
    nothing
end

_computeproperty(o, name, indices...; __status__=nothing, kwargs...) = begin
    vname = Val(name)
    isnothing(__status__) && name != :__status__ && (__status__ = getorcomputeproperty(o, :__status__))
    _status_kw = is_generated_property(o, name) ? (; __status__) : (;)
    try
        if iscached(o, vname, indices...; kwargs...)
            cache_path = get_cache_path(o, name, indices...; kwargs...)
            mkpath(dirname(cache_path))
            __strict__ = getorcomputeproperty(o, :__strict__)
            _is_threadsafe = getorcomputeproperty(o, :__cache_type__) <: AbstractThreadsafeDict
            _cache_context = """Object type: $(nameof(typeof(o))) (objectid: $(objectid(o)), hash: $(hash(o)))
Cache dict: $(_is_threadsafe ? "ThreadsafeDict (parallel)" : "Dict (serial) — if concurrent access is intended, use cache_type=:parallel")
If multiple objects with the same hash are writing here concurrently, this may indicate a concurrency issue or a hashing collision."""
            disk_locks = _disk_cache(o, vname)
            rv = if __strict__ && !isnothing(disk_locks)
                path_lock = get_path_lock!(disk_locks, cache_path)
                if islocked(path_lock)
                    @info "Waiting for disk cache lock on $cache_path\n$_cache_context"
                end
                lock(path_lock) do
                    cache_status = get_cache_status(cache_path)
                    rv = if cache_status == :ready
                        try
                            Serialization.deserialize(cache_path)
                        catch e
                            @warn "Deserialization failed for $cache_path, recomputing.\n$_cache_context" exception=e
                            rm(cache_path; force=true)
                            nothing
                        end
                    else
                        nothing
                    end
                    if isnothing(rv) || resumes(o, vname, indices...; kwargs...)
                        @debug "Generating $cache_path...\n$_cache_context"
                        rv = compute_property(o, vname, indices...; _status_kw..., (name=>rv, )..., kwargs...)
                        Serialization.serialize(cache_path, rv)
                    end
                    rv
                end
            else
                # Non-strict or no disk locks: original flow
                cache_status = get_cache_status(cache_path)
                rv = if cache_status == :ready
                    try
                        Serialization.deserialize(cache_path)
                    catch e
                        @warn "Deserialization failed for $cache_path, recomputing.\n$_cache_context\nEnable __strict__=true for disk cache locking to prevent concurrent write issues." exception=e
                        rm(cache_path; force=true)
                        cache_status = :unstarted
                        touch(cache_path)
                        nothing
                    end
                else
                    if cache_status == :started
                        @warn "Cache file $cache_path exists but has size 0.\nAssuming a previous run failed.\n$_cache_context\nEnable __strict__=true for disk cache locking to prevent concurrent write issues."
                    end
                    touch(cache_path)
                    nothing
                end
                if cache_status != :ready || resumes(o, vname, indices...; kwargs...)
                    @debug "Generating $cache_path...\n$_cache_context"
                    rv = compute_property(o, vname, indices...; _status_kw..., (name=>rv, )..., kwargs...)
                    Serialization.serialize(cache_path, rv)
                end
                rv
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
            if is_indexed_property(o, name)
                return IndexableProperty(name, o, subcache(getfield(o, :cache), typeof(o), Val(name)))
            end
        end
        _computeproperty(o, name, indices...; kwargs...)
    end
end
maybehash(x::Number) = x
maybehash(x::Symbol) = x
maybehash(x) = persistent_hash(x)

# Build a single path-segment identifier for a (name, args, kwargs) triple,
# joining the parts with "_" via `maybehash`. Used in two places:
#   1. As the file-name body of `get_cache_path` (with ".sjl" appended).
#   2. As the per-level directory name in the inline-child cache_path
#      auto-wiring, so the on-disk layout mirrors the DO hierarchy.
# Kwargs are sorted by name so callers passing the same kwargs in different
# syntactic order land in the same segment.
cache_segment(name, args...; kwargs...) = begin
    parts = length(kwargs) == 0 ? (name, args...) : (name, args..., sort(collect(kwargs); by=first)...)
    join(map(maybehash, parts), "_")
end
get_cache_path(o, name, args...; kwargs...) = begin
    seg = cache_segment(name, args...; kwargs...)
    ver = cache_version(o, Val(name))
    !isnothing(ver) && (seg = seg * "_v" * string(ver))
    joinpath(o.cache_path, seg * ".sjl")
end
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
"""
    @lru maxsize prop(idx...) = expr

Mark an indexed property in a `@dynamicstruct` body so that its per-property
in-memory cache is bounded to `maxsize` entries with least-recently-used
eviction, instead of the unbounded `Dict`/`ThreadsafeDict` inherited from the
struct's `cache_type`.

`maxsize` must be a literal integer (so the bound is fixed at struct-definition
time). Eviction is task-aware on `:parallel` structs: keys with an in-flight
`Task` are never evicted — if every slot is pinned, the cache temporarily
exceeds `maxsize` until something settles.

`@lru` is orthogonal to `@cached`: both can apply to the same property — the
disk cache is unaffected, only the in-memory dict is bounded.

```julia
@dynamicstruct struct App
    @lru 100 sim(subject_id) = expensive(subject_id)
    @cached @lru 50 fit(model, seed) = run_fit(model, seed)
end
```

Outside a `@dynamicstruct` body the macro is a no-op pass-through on the
property expression — the actual cache substitution is done via the
`subcache` overrides emitted by `@dynamicstruct`.
"""
macro lru(maxsize, x)
    _validate_lru_maxsize(maxsize)
    esc(x)
end

"""
    @persist o.prop
    @persist o.prop[indices...]

Write the in-memory value of `o.prop` (or the indexed entry `o.prop[indices...]`)
back to its disk cache. Use after mutating a value in place when the property
was declared with `@cached` and the on-disk copy is now stale relative to the
in-memory copy.
"""
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

"""
    @memo f(args...; kwargs...)

Rewrite `f(args...; kwargs...)` as `getindex(f, args...; kwargs...)`. This makes
memoization explicit at the call site for `IndexableProperty` properties defined
inside a `@dynamicstruct`.

Inside a `@dynamicstruct`, an indexable property `prop(i) = ...` can be invoked
two different ways:

- `o.prop(i)` — recompute on every call, no caching.
- `o.prop[i]` — look up in the in-memory cache, compute (and cache) on miss.

The bracket-vs-paren distinction is easy to miss when reading code. `@memo` lets
you keep the call syntax while still going through the cached path:

```julia
@memo o.prop(i)        # equivalent to o.prop[i]
@memo o.prop(i; k=v)   # equivalent to getindex(o.prop, i; k=v)
```
"""
macro memo(x)
    Meta.isexpr(x, :call) || error("@memo expects a call expression `f(args...; kwargs...)`, got: $x")
    fixcall(Expr(:call, GlobalRef(Base, :getindex), x.args...)) |> esc
end

persist(v, args...; kwargs...) = begin
    Serialization.serialize(
        get_cache_path(args...; kwargs...),
        v
    )
end

# Pop a specific (indices, kwargs) entry from an IndexableProperty's cache,
# or no-op when the entry isn't an IP.
_maybepop_indexed!(v::IndexableProperty, indices, kwargs) =
    (maybepop!(v.cache, (indices, (;kwargs...))); nothing)
_maybepop_indexed!(args...) = nothing

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
        haskey(cache, name) && _maybepop_indexed!(cache[name], indices, kwargs)
        # Clear specific disk cache file
        path = get_cache_path(o, name, indices...; kwargs...)
        isfile(path) && rm(path)
    end
    nothing
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
macro clear_cache!(x)
    cache_f_expr(x; f=clear_cache!) |> esc
end

isfixed(kv::Pair) = isfixed(kv[2])
isfixed(info::NamedTuple) = isnothing(info.rhs)

# Per-element handler for the `:local` branch of `walk_rhs` — register
# Symbol locals via dispatch instead of an `if arg isa Symbol …` chain
# inside the loop body. Tuple-Expr leaves go through `_push_if_symbol!`,
# Symbol assignment LHS through `_walk_local_assign!`.
_walk_local_arg!(arg::Symbol; locals, kwargs...) = (push!(locals, arg); arg)
_walk_local_arg!(arg; locals, properties, lnn) = walk_rhs(arg; locals, properties, lnn)
function _walk_local_arg!(arg::Expr; locals, properties, lnn)
    if Meta.isexpr(arg, :(=))
        return _walk_local_assign!(arg.args[1], arg, locals, properties, lnn)
    elseif Meta.isexpr(arg, :tuple)
        foreach(s -> _push_if_symbol!(locals, s), arg.args)
        return arg
    end
    walk_rhs(arg; locals, properties, lnn)
end
_walk_local_assign!(lhs::Symbol, arg, locals, properties, lnn) =
    (push!(locals, lhs); Expr(:(=), lhs, walk_rhs(arg.args[2]; locals, properties, lnn)))
_walk_local_assign!(_, arg, locals, properties, lnn) = walk_rhs(arg; locals, properties, lnn)
_push_if_symbol!(locals, s::Symbol) = (push!(locals, s); nothing)
_push_if_symbol!(_, _) = nothing

# Per-element handler for the trailing-else branch of `walk_rhs(::Expr)`.
# LineNumberNode arms record the LNN into a Ref so subsequent siblings
# pick it up; everything else recurses with the most recent LNN. Avoids
# the `if arg isa LineNumberNode` mutating-closure pattern.
_walk_with_lnn_tracking!(arg::LineNumberNode, ref, locals, properties) = (ref[] = arg; arg)
_walk_with_lnn_tracking!(arg, ref, locals, properties) =
    walk_rhs(arg; locals, properties, lnn=ref[])

walk_rhs(e; kwargs...) = e
walk_rhs(e::Expr; locals, properties, lnn=nothing) = if e.head == :let
    # locals = properties[dependent].locals
    ls = Set{Symbol}()
    !Meta.isexpr(e.args[1], :block) && (e.args[1] = Expr(:block, e.args[1]))
    map!(e.args[1].args, e.args[1].args) do arg
        arg = _normalize_let_binding(arg)
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
    ls = extractnames(Meta.isexpr(params, :tuple) ? params.args : [params])
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
    catch_locals = catch_var === false ? locals : union(locals, Set([catch_var]))
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
            shadowed = _shadowed_lhs(lhs, properties, locals)
            for s in shadowed
                loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
                error("Assignment to `$s` in a property RHS shadows property `$s`$loc. This writes to the property cache, not a local variable. Declare it with `local $s` (or `local $s = ...`) or use `let $s = ...` to make it a local.")
            end
        end
        walked_lhs = Meta.isexpr(lhs, (:ref, :.)) ? walk_rhs(lhs; locals, properties, lnn) : lhs
        Expr(e.head, walked_lhs, walk_rhs.(e.args[2:end]; locals, properties, lnn)...)
    end
elseif e.head == :local
    # `local x`, `local x, y, z`, or `local x = expr` — add names to the local
    # scope so subsequent assignments don't hit the property cache.
    walked = map(arg -> _walk_local_arg!(arg; locals, properties, lnn), e.args)
    Expr(:local, walked...)
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
    # Track LineNumberNodes for better warning locations. Dispatch on
    # the arg type via `_walk_with_lnn_tracking!` (LNN method updates
    # the Ref; the fallback walks the arg with the current LNN) instead
    # of branching on `isa` inside the loop body.
    ref_lnn = Ref{Any}(lnn)
    walked = map(arg -> _walk_with_lnn_tracking!(arg, ref_lnn, locals, properties), e.args)
    Expr(e.head, walked...)
end
walk_rhs(e::Symbol; locals, properties, lnn=nothing) = if haskey(properties, e) && !(e in locals)
    :(__self__.$e)
else
    e
end

# --- Linter ----------------------------------------------------------------
#
# Lints are computed by `analyze_structure(T)` — a tree-walk over `meta(T)`
# that produces a `Vector{LintMessage}`. `print_structure(T)` weaves these
# messages inline next to the affected property/struct. There is no
# automatic stderr/error emission from the macro; lints surface only when
# you render the structure.

struct LintMessage
    type::Type
    prop::Union{Symbol,Nothing}     # nothing = struct-level lint
    severity::Symbol                # :warn or :error
    short::String                   # 1-line summary for inline rendering
    long::String                    # full message
    lnn::Union{LineNumberNode,Nothing}
end

# --- Bare-rhs scanners (used by no-self-access check) ---
_contains_self_ref(e::Symbol) = e === :__self__
_contains_self_ref(e::Expr) = any(_contains_self_ref, e.args)
_contains_self_ref(_) = false

_contains_bare_prop_ref(e::Symbol, prop_names) = e in prop_names
_contains_bare_prop_ref(e::Expr, prop_names) = any(a -> _contains_bare_prop_ref(a, prop_names), e.args)
_contains_bare_prop_ref(_, _) = false

_contains_call(_) = false
_contains_call(e::Expr) = Meta.isexpr(e, :call) || any(_contains_call, e.args)

# Common short identifiers that ARE meaningful — full English words, or
# unambiguous in any code context. Anything else under 4 characters is
# almost always cryptic on a public-facing IP signature / route param.
const _OK_SHORT_NAMES = Set{Symbol}([
    :id, :to, :at, :as, :ok, :it, :in, :on, :up, :by, :of, :no,
    :url, :uri, :key, :val, :err, :tag, :now, :all, :any, :len,
])

# Indexed properties on `@dynamicstruct`/`@htmx` structs are the public
# API of those structs — IP signatures and route parameter names show up
# in URLs, docs, and call sites, so they must communicate intent. Flag
# 1-letter names (`x`, `n`, …) and 2-3 letter abbreviations (`pn`, `df`,
# `ctx`, …) on indexed property arg lists. Local loop counters
# (`for i in 1:n`) are unaffected — they live in property bodies, not
# in declared signatures.
# Forwarded inline-child props have `rhs == __parent__.x`, courtesy of the
# `(;a, b) = __parent__` destructure inserted by the inline-include desugar.
# Filter them out of struct-level lints — they're scoped views, not owned.
_is_forwarded(rhs::Expr) = rhs.head === :. && length(rhs.args) == 2 &&
                            rhs.args[1] === :__parent__
_is_forwarded(::Any) = false

# Dunders auto-injected by DO/HTMXO machinery — never user-state.
const _AUTO_DUNDERS = Set([:__parent__, :__prefix__, :__req__, :__route__])

# --- Per-property checks ---------------------------------------------------

function _check_cryptic_arg_names!(msgs, type, name::Symbol, info)
    isempty(info.indices) && return
    bad = String[]
    for idx in info.indices
        Meta.isexpr(idx, :parameters) && continue
        a = idx
        Meta.isexpr(a, :kw) && (a = a.args[1])
        Meta.isexpr(a, :(::)) && (a = a.args[1])
        a isa Symbol || continue
        s = String(a)
        startswith(s, "_") && continue
        length(s) >= 4 && continue
        a in _OK_SHORT_NAMES && continue
        push!(bad, s)
    end
    isempty(bad) && return
    short = "cryptic arg name(s): " * join(map(s -> "`$s`", bad), ", ")
    long  = "Property `$type.$name(…)` has cryptic parameter name(s) $(join(map(s -> "`$s`", bad), ", ")). Indexed-property args are public API (URLs, IP cache keys, call sites) and must communicate intent. Rename to meaningful English names — `posterior_name` not `pn`, `dataframe` not `df`, `value` not `x`. Single-letter names belong in tight algorithmic locals, not declared signatures."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

function _check_no_self_access!(msgs, type, name::Symbol, info, prop_names,
                                bound_siblings, bound)
    isempty(info.indices) && return
    isempty(info.macros) || return
    info.rhs === nothing && return
    _contains_call(info.rhs) || return
    _contains_self_ref(info.rhs) && return
    _contains_bare_prop_ref(info.rhs, prop_names) && return
    args = _ip_positional_args(info.indices)
    argstr = join(string.(args), ", ")
    if !isempty(bound_siblings)
        slist   = join(map(s -> "`$s`", bound_siblings), ", ")
        depsstr = join(string.(bound), ", ")
        short = "stateless — body uses no sibling state; shares deps `{$depsstr}` with $slist, fold the cluster into one inline child keyed on `($depsstr)` rather than each on its own args"
    else
        short = "stateless — body uses no sibling state; fold to `@struct $name($argstr) = begin … end` if args own an identity, or accept as helper"
    end
    long  = "Property `$type.$name(…)` calls functions but reads no sibling state. This property does not belong on `$type`. Lift it to an inline-child DO that owns the underlying object/key and exposes the derivations as bare properties. (A) Args key on a 'thing' the struct isn't modelling yet → introduce `@struct entry(k) = begin …end`. (B) Args all come from one existing object → lift `$name` to be a property OF that object."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

function _check_trivial_cached_wrapper!(msgs, type, name::Symbol, info)
    Symbol("@cached") in info.macros || return
    rhs = info.rhs
    Meta.isexpr(rhs, :call) || return
    prop_arg_names = Symbol[]
    for idx in info.indices
        Meta.isexpr(idx, :parameters) && continue
        a = idx
        Meta.isexpr(a, :(::)) && (a = a.args[1])
        a isa Symbol && push!(prop_arg_names, a)
    end
    call_args = Symbol[]
    for a in rhs.args[2:end]
        Meta.isexpr(a, :parameters) && continue
        sym = a
        Meta.isexpr(sym, :(::)) && (sym = sym.args[1])
        sym isa Symbol || return
        push!(call_args, sym)
    end
    prop_arg_names == call_args || return
    callee = rhs.args[1]
    short = "thin @cached wrapper around `$callee(…)`"
    long  = "`@cached $type.$name(…)` is a thin wrapper around `$callee(…)` — body is one call passing the same args. Inline `$callee`'s body into the @cached property, or drop the wrapper and have callers `@cached`-call `$callee` directly. The current shape is doing both."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# --- Per-struct checks ----------------------------------------------------

function _check_singleton_struct!(msgs, type, oproperties)
    user = []
    for (n, info) in oproperties
        n in _AUTO_DUNDERS && continue
        s = String(n)
        startswith(s, "_tuple_") && continue
        n === :hash_fields && continue
        push!(user, (n, info))
    end
    length(user) == 1 || return
    (only_name, only_info) = first(user)
    advice = only_info.indexed ?
        "Replace with `$only_name(args…) = …` on the enclosing scope." :
        "Replace with `$only_name = …` on the enclosing scope."
    short = "singleton: only one user property `$only_name`"
    long  = "`$type` has exactly one user-declared property: `$only_name`. $advice The struct shell adds nothing."
    push!(msgs, LintMessage(type, nothing, :warn, short, long, only_info.lnn))
end

function _check_repeated_prefix!(msgs, type, oproperties)
    own_names = Symbol[n for (n, info) in oproperties if !_is_forwarded(info.rhs)]
    name_set = Set(own_names)
    by_prefix = Dict{String, Vector{Symbol}}()
    for n in own_names
        s = String(n)
        startswith(s, "__") && endswith(s, "__") && continue
        startswith(s, "_tuple_") && continue
        underscore = findfirst(==('_'), s)
        isnothing(underscore) && continue
        underscore == 1       && continue
        prefix = s[1:underscore-1]
        push!(get!(by_prefix, prefix, Symbol[]), n)
    end
    for (prefix, group) in by_prefix
        length(group) >= 2 || continue
        if Symbol(prefix) in name_set
            short = "$(length(group)) `$(prefix)_*` siblings + bare `$prefix` — fold into it"
            long  = "`$type` has $(length(group)) properties named `$(prefix)_*` ($(join(group, ", "))) AND a bare `$prefix` property. Move the `$(prefix)_*` members INTO `$prefix` as bare suffixes (`$type.$prefix.<suffix>`)."
            push!(msgs, LintMessage(type, nothing, :error, short, long, nothing))
        else
            short = "$(length(group)) `$(prefix)_*` siblings — group as `@struct $prefix`"
            long  = "`$type` has $(length(group)) properties sharing `$(prefix)_*` prefix: $(join(group, ", ")). Group inside `@struct $prefix = begin …end` so the shared-prefix names become bare members of the child."
            push!(msgs, LintMessage(type, nothing, :warn, short, long, nothing))
        end
    end
end

function _check_shared_arg_signature!(msgs, type, oproperties)
    by_sig = Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}()
    for (name, info) in oproperties
        _is_forwarded(info.rhs) && continue
        isempty(info.indices) && continue
        sig = Symbol[]
        for idx in info.indices
            Meta.isexpr(idx, :parameters) && continue
            a = idx
            Meta.isexpr(a, :(::)) && (a = a.args[1])
            a isa Symbol && push!(sig, a)
        end
        isempty(sig) && continue
        push!(get!(by_sig, Tuple(sig), Symbol[]), name)
    end
    for (sig, group) in by_sig
        length(group) >= 2 || continue
        argstr = join(sig, ", ")
        short = "$(length(group)) IPs share `($argstr)` — group as `@struct shared($argstr)`"
        long  = "`$type` has $(length(group)) indexed properties sharing the `($argstr)` signature: $(join(group, ", ")). They all key on the same identity. Move them into an inline child `@struct shared($argstr) = begin …end`."
        push!(msgs, LintMessage(type, nothing, :warn, short, long, nothing))
        by_prefix = Dict{String, Vector{Symbol}}()
        for n in group
            s = String(n)
            underscore = findfirst(==('_'), s)
            (isnothing(underscore) || underscore == 1) && continue
            push!(get!(by_prefix, s[1:underscore-1], Symbol[]), n)
        end
        for (prefix, sub) in by_prefix
            length(sub) >= 2 || continue
            short_e = "$(length(sub)) IPs share `($argstr)` AND `$(prefix)_*` — fold to `@struct $prefix($argstr)`"
            long_e  = "`$type` has $(length(sub)) indexed properties that share BOTH the `($argstr)` signature AND the `$(prefix)_*` prefix: $(join(sub, ", ")). Fold them into `@struct $prefix($argstr) = begin …end`."
            push!(msgs, LintMessage(type, nothing, :error, short_e, long_e, nothing))
        end
    end
end

# --- New: hierarchical placement (lint #1) -------------------------------
# For an IP at T.prop with worst-case bound {k1, k2, ...}, every name in the
# bound should be visible in T's enclosing static scope (constructor fields,
# `@param`s, IP positional args along the parent chain). Anything outside
# that scope means the IP is reaching across the tree.

function _check_hierarchical_placement!(msgs, types_in_tree, parent_map, type, name, info)
    isempty(_ip_positional_args(info.indices)) && return
    wc = _print_struct_worst_case(types_in_tree, parent_map, type, name, info)
    (wc === nothing || wc[1] !== :bound) && return
    bound = wc[2]
    scope = _enclosing_scope(type, parent_map)
    for a in _ip_positional_args(info.indices)
        push!(scope, a)
    end
    misplaced = filter(n -> n ∉ scope, bound)
    isempty(misplaced) && return
    nlist = join(map(n -> "`$n`", misplaced), ", ")
    short = "depends on $nlist (not in scope) — relocate under the subtree that introduces $(length(misplaced) == 1 ? "it" : "them"), or pass as arg of an enclosing IP"
    long  = "`$type.$name(…)` depends on $nlist, which is not in `$type`'s enclosing scope (fields, `@param`s, parent IP args). The IP is reaching across the tree. Either relocate the IP under the subtree that introduces these names, or take them as explicit args of an enclosing IP."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# --- New: redundant-args lint --------------------------------------------
# For an IP with positional args, walk every in-tree caller and collect the
# arg expressions actually passed. If at every detected call site the same
# (parent-chain-normalized) expression is passed for arg position `i`, then
# arg `i` is constant across callers — drop it and have the IP body read
# the value directly.

# Collect all `target(args…)` call sites in `expr` matching `_has_call_to`'s
# rules; return Vector of positional-arg expression lists (one per call).
function _collect_call_args!(out::Vector{Vector{Any}}, expr, target::Symbol, cprops)
    expr isa Expr || return
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        match = false
        if callee === target
            match = cprops !== nothing && haskey(cprops, target)
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            match = root !== nothing &&
                    (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                     (cprops !== nothing && haskey(cprops, root)))
        end
        if match
            args = Any[]
            for a in expr.args[2:end]
                Meta.isexpr(a, :parameters) && continue   # drop kwargs
                push!(args, a)
            end
            push!(out, args)
        end
    end
    for a in expr.args
        _collect_call_args!(out, a, target, cprops)
    end
end

_collect_call_args(expr, target, cprops) =
    (out = Vector{Vector{Any}}(); _collect_call_args!(out, expr, target, cprops); out)

# Normalize a `__self__.X…` / `__parent__[.__parent__]*.X…` dot chain to
# `(BaseType, :a, :b, ...)` where BaseType is reached by walking parent_map
# off `caller_T` once per leading `__parent__`. Returns `nothing` for any
# other shape so callers fall back to comparing the raw `Expr`.
function _normalize_dot_chain(expr, caller_T::Type, parent_map)
    accessors = Symbol[]
    cur = expr
    while Meta.isexpr(cur, :., 2) && cur.args[2] isa QuoteNode
        pushfirst!(accessors, cur.args[2].value)
        cur = cur.args[1]
    end
    cur isa Symbol || return nothing
    root = cur
    base_T = caller_T
    if root === :__parent__
        base_T = haskey(parent_map, caller_T) ? parent_map[caller_T][1] : caller_T
        while !isempty(accessors) && accessors[1] === :__parent__
            popfirst!(accessors)
            base_T = haskey(parent_map, base_T) ? parent_map[base_T][1] : base_T
        end
    elseif root === :__self__
        base_T = caller_T
    else
        return nothing
    end
    (base_T, accessors...)
end

function _normalize_arg(expr, caller_T::Type, parent_map)
    r = _normalize_dot_chain(expr, caller_T, parent_map)
    r === nothing ? expr : r
end

_show_normalized(v::Tuple) = isempty(v[2:end]) ? string(nameof(v[1])) :
                             string(nameof(v[1]), ".", join(v[2:end], "."))
_show_normalized(v) = string(v)

function _check_redundant_args!(msgs, types_in_tree, parent_map, type, name::Symbol, info)
    pos = _ip_positional_args(info.indices)
    isempty(pos) && return
    all_caller_args = Vector{Vector{Any}}()
    for U in types_in_tree
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (uname, uinfo) in uprops
            uinfo.rhs === nothing && continue
            (U === type && uname === name) && continue
            for argset in _collect_call_args(uinfo.rhs, name, uprops)
                push!(all_caller_args,
                      Any[_normalize_arg(a, U, parent_map) for a in argset])
            end
        end
    end
    isempty(all_caller_args) && return
    redundant = Tuple{Symbol,Any}[]
    for i in eachindex(pos)
        all(length(a) >= i for a in all_caller_args) || continue
        vals = [a[i] for a in all_caller_args]
        all(v -> v == vals[1], vals) || continue
        # Only flag if the value is addressable from the IP's own scope
        # (i.e. `_normalize_dot_chain` resolved it to (BaseType, accessors...)).
        # Raw Symbols / Exprs are caller-locals — IP body can't read them.
        vals[1] isa Tuple || continue
        push!(redundant, (pos[i], vals[1]))
    end
    isempty(redundant) && return
    parts = ["`$n` always passed `$(_show_normalized(v))`" for (n, v) in redundant]
    short = "redundant arg$(length(redundant) == 1 ? "" : "s"): " * join(parts, ", ") *
            " — drop from signature, read directly in body"
    long  = "Across $(length(all_caller_args)) detected call site(s) of `$type.$name(…)`, " *
            "$(length(redundant) == 1 ? "this argument is" : "these arguments are") always " *
            "passed the same expression. Drop $(length(redundant) == 1 ? "it" : "them") from " *
            "the signature and have the body read the value directly via `__self__.…` / " *
            "`__parent__.…`. Refines the same-bound / no-self-access guidance: the bound " *
            "shows what the callers' SCOPES carry; this lint shows what they actually PASS."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# --- New: identical-bound siblings (lint #3) -----------------------------
# Group IPs at the SAME scope by bound; if 2+ share a bound, they likely
# belong in one inline child keyed on that shared identity.

function _check_identical_bound_siblings!(msgs, bound_groups, types_in_tree, parent_map)
    for (T, by_bound) in bound_groups
        props = try meta(T) catch; nothing end
        props === nothing && continue
        scope = _enclosing_scope(T, parent_map)
        for (bound, group) in by_bound
            length(group) >= 2 || continue
            # Fire only when the shared bound represents a real upstream
            # identity — i.e. extend BEYOND the type's local scope. Empty
            # bound and bound fully within local scope (e.g. siblings
            # sharing only auto-forwarded `@param`s) have no identity to
            # fold around.
            isempty(bound) && continue
            all(n -> n in scope, bound) && continue
            argstr = join(string.(bound), ", ")
            for member in group
                others = filter(!=(member), group)
                olist = join(map(o -> "`$o`", others), ", ")
                short = "same deps as $olist — fold all $(length(group)) into `@struct shared($argstr) = begin … end`, callers `.shared($argstr).<member>`"
                long  = "`$T.$member(…)` has the same upstream deps `{$argstr}` as $olist. They share an identity that isn't currently modelled; fold them into one inline child keyed on `($argstr)` and expose the per-member derivations as bare properties of it."
                info = props[member]
                push!(msgs, LintMessage(T, member, :warn, short, long, info.lnn))
            end
        end
    end
end

# --- Top-level analyzer ---------------------------------------------------

"""    analyze_structure(T::Type) -> Vector{LintMessage}

Walk T's DO/HTMXO type tree and run all lint checks. Pure analysis pass —
no side effects, no logging. `print_structure(T)` calls this internally and
weaves the messages inline. Callers wanting CI-style output can iterate the
returned vector themselves.
"""
function analyze_structure(T::Type)
    msgs = LintMessage[]
    types_in_tree = _all_types_in_tree(T)
    parent_map    = _build_parent_map(T)
    bound_groups  = _bound_groups(types_in_tree, parent_map)

    for U in types_in_tree
        props = try meta(U) catch; nothing end
        props === nothing && continue
        oproperties = collect(props)
        prop_names  = Set(keys(props))
        type_bound  = get(bound_groups, U, Dict{Tuple{Vararg{Symbol}},Vector{Symbol}}())

        # Per-property
        for (n, info) in oproperties
            siblings, bound = _siblings_in_bound(type_bound, n)
            _check_cryptic_arg_names!(msgs, U, n, info)
            _check_no_self_access!(msgs, U, n, info, prop_names, siblings, bound)
            _check_trivial_cached_wrapper!(msgs, U, n, info)
            _check_hierarchical_placement!(msgs, types_in_tree, parent_map, U, n, info)
            _check_redundant_args!(msgs, types_in_tree, parent_map, U, n, info)
        end

        # Struct-level (skip forwarded entries from singleton/prefix views)
        own = [n => info for (n, info) in oproperties
               if info.rhs === nothing || !_is_forwarded(info.rhs)]
        _check_singleton_struct!(msgs, U, own)
        _check_repeated_prefix!(msgs, U, own)
        _check_shared_arg_signature!(msgs, U, own)
    end

    _check_identical_bound_siblings!(msgs, bound_groups, types_in_tree, parent_map)
    msgs
end

# bond_groups: Type → Dict{bound::Tuple → group::Vector{Symbol}}.
# Computed once per analyze pass; reused by both `_check_no_self_access!`
# (to name same-bound siblings in its message) and
# `_check_identical_bound_siblings!` (for cluster emission).
function _bound_groups(types_in_tree, parent_map)
    out = Dict{Type, Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}}()
    for T in types_in_tree
        props = try meta(T) catch; nothing end
        props === nothing && continue
        by_bound = Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}()
        for (name, info) in props
            isempty(_ip_positional_args(info.indices)) && continue
            wc = _print_struct_worst_case(types_in_tree, parent_map, T, name, info)
            (wc === nothing || wc[1] !== :bound) && continue
            push!(get!(by_bound, Tuple(wc[2]), Symbol[]), name)
        end
        out[T] = by_bound
    end
    out
end

# For (type, prop), return (siblings, bound) — siblings are other props in
# the same bound group (size ≥2), or empty if prop isn't in any group.
function _siblings_in_bound(type_bonds, name::Symbol)
    for (bound, group) in type_bonds
        name in group || continue
        length(group) >= 2 || continue
        return filter(!=(name), group), collect(bound)
    end
    Symbol[], Symbol[]
end

function compute_property end
function iscached end
function resumes end
function meta end
"""    _property_description(o, ::Val{name}, args...; kwargs...)

Return a human-readable description for the property `name` with the given arguments.
Override generated per-property when a docstring is present in @dynamicstruct.
Default: "name(arg1,arg2,...; k1=v1,k2=v2)" — kwargs section is omitted when empty.
"""
_property_description(o, ::Val{name}, args...; kwargs...) where {name} = begin
    argstr = join(args, ",")
    kwstr = isempty(kwargs) ? "" : "; " * join(("$k=$v" for (k, v) in kwargs), ",")
    "$name($argstr$kwstr)"
end
is_generated_property(o, name) = false
is_indexed_property(o, name) = false
_disk_cache(o, name) = nothing
"""    _nested_struct_type(::Type{T}, ::Val{name})

Return the type of the nested struct exposed under property `name` on `T`,
or `nothing` if `name` is not backed by a nested struct. Methods are emitted
by `@dynamicstruct` for every inline `@struct` child, and by `@htmx` for
each `@include` external. Used both by `print_structure` and by
HTMXObjects' route-walking machinery.
"""
_nested_struct_type(::Type, ::Val) = nothing

"""    _analysis_nested_type(::Type{T}, ::Val{name})

Like `_nested_struct_type`, but registered for `prop::T = rhs` typed
computed properties only — the analyzer's tree walk follows them while
HTMXObjects' route walker does not (so typed primitives like
`port::Int = 8080` don't crash route registration on `meta(::Type{Int})`).
"""
_analysis_nested_type(::Type, ::Val) = nothing

# Union of both hooks for analyzer + render code paths. `_nested_struct_type`
# wins if both are defined for the same property (shouldn't normally happen).
function _walk_nested_type(T, name::Symbol)
    t = _nested_struct_type(T, Val(name))
    t !== nothing && return t
    _analysis_nested_type(T, Val(name))
end
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
# Unwrap a `GlobalRef(M, :@name)` to its bare `:@name` Symbol. Macro names
# arrive as either form depending on whether the macrocall came through
# Julia's docstring lowering or a direct user write.
_resolve_macro_name(m::GlobalRef) = m.name
_resolve_macro_name(m) = m

# Property names introduced by an `arg`'s LHS — bare symbols, typed
# fields, and tuple destructures. Inline structs and other shapes
# contribute none. Used to assemble `parent_props` in `dynamicstruct`.
_collect_lhs_names(::Any) = ()
_collect_lhs_names(lhs::Symbol) = (lhs,)
_collect_lhs_names(lhs::Expr) =
    Meta.isexpr(lhs, :tuple) ? Tuple(_collect_destructure_names(lhs)) : ()

# Render a stored docstring back to a String for the auto-generated
# property listing. Strings pass through; anything else (an `Expr` from
# string interpolation) gets `show_unquoted` to recover the source.
_doc_to_string(doc::AbstractString) = doc
_doc_to_string(doc) = sprint(Base.show_unquoted, doc)

# Build the extraction RHS for one member of a destructuring assignment.
# Symbol source → `extract_from.source`; integer index → `extract_from[i]`.
_extract_member(extract_from, source::Symbol) = Expr(:., extract_from, QuoteNode(source))
_extract_member(extract_from, source) = :($extract_from[$source])

# Replace `LineNumberNode` markers in a block with `lnn` (used by
# `setlnn` to rewrite line tags onto user-supplied locations); leave
# everything else untouched.
_replace_lnn(::LineNumberNode, lnn) = lnn
_replace_lnn(x, _) = x

# Validate `@lru maxsize` / `@cached` Integer args at macro time without
# inlining `isa(..., Integer) || error(...)`. Per-type method ⇒ Integer
# passes silently; anything else hits the fallback that errors with the
# offending value.
_validate_lru_maxsize(::Integer) = nothing
_validate_lru_maxsize(x) = error("@lru: maxsize must be a literal Integer, got: $x")

# Property-macro accumulator: doc / cache_version / lru_size / macros are
# the four pieces of state the body-args parser threads through the
# `while Meta.isexpr(arg, :macrocall)` peeling loop. Bundling them into a
# small mutable struct lets per-macro logic live in dispatched methods of
# `_apply_property_macro!` (one method per macro shape) instead of in
# branch arms inside the loop body.
mutable struct _PropertyMacroState
    doc::Any
    cache_version::Any
    lru_size::Any
    macros::Set{Symbol}
end

# Default: register the macro name in `state.macros` and unwrap to the
# inner expression so the loop continues peeling.
_apply_property_macro!(state::_PropertyMacroState, ::Val{name}, arg) where {name} =
    (push!(state.macros, name); arg.args[end])

# `@doc "str" <def>` — silently consume (don't push to macros) and capture
# the docstring. `length(arg.args) >= 4` matches Julia's lowered shape
# (`(:macrocall, :@doc, LNN, "str", <def>)`); shorter forms fall back to
# the default behavior.
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@doc")}, arg)
    if length(arg.args) >= 4
        docexpr = arg.args[end-1]
        (docexpr isa AbstractString || Meta.isexpr(docexpr, :string)) && (state.doc = docexpr)
        return arg.args[end]
    end
    push!(state.macros, Symbol("@doc"))
    arg.args[end]
end

# `@cached <prop> = …` (length 3) or `@cached v"…" <prop> = …` (length 4
# with a version argument).
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@cached")}, arg)
    push!(state.macros, Symbol("@cached"))
    length(arg.args) == 4 && (state.cache_version = _parse_cache_version(arg.args[3]))
    arg.args[end]
end
_parse_cache_version(v::VersionNumber) = v
function _parse_cache_version(ver_expr::Expr)
    Meta.isexpr(ver_expr, :macrocall) && ver_expr.args[1] == Symbol("@v_str") ||
        error("@cached version argument must be a version string like v\"2\", got: $ver_expr")
    VersionNumber(ver_expr.args[end])
end
_parse_cache_version(x) =
    error("@cached version argument must be a version string like v\"2\", got: $x")

# `@lru N <prop> = …` — N must be a literal Integer (validated via
# `_validate_lru_maxsize`'s fallback method).
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@lru")}, arg)
    push!(state.macros, Symbol("@lru"))
    if length(arg.args) == 4
        sz = arg.args[3]
        _validate_lru_maxsize(sz)
        state.lru_size = Int(sz)
    end
    arg.args[end]
end

# Body-args metadata absorber: LineNumberNode / String / `:string` Expr
# args are not properties — they update the `lnn` / `doc` accumulators
# the next real property will pick up. Per-type method dispatch replaces
# the `if arg isa LineNumberNode … end; if arg isa String || Meta.isexpr
# (arg, :string) …` chain at the top of the body-args loop. Returns
# `true` when the arg was absorbed (caller `continue`s) and `false`
# otherwise. `ctx` is a NamedTuple of `lnn::Ref` / `doc::Ref`.
_absorb_body_metadata!(_, _) = false
_absorb_body_metadata!(arg::LineNumberNode, ctx) = (ctx.lnn[] = arg; true)
_absorb_body_metadata!(arg::AbstractString, ctx) = (ctx.doc[] = arg; true)
function _absorb_body_metadata!(arg::Expr, ctx)
    arg.head === :string || return false
    ctx.doc[] = arg; true
end

# Normalise a `let` binding: a bare Symbol `x` becomes `x = x` (so the
# rest of the let-walker can treat every binding as an `Expr(:(=), …)`),
# already-`=`-shaped bindings pass through.
_normalize_let_binding(arg::Symbol) = Expr(:(=), arg, arg)
_normalize_let_binding(arg) = arg

# Names from an `lhs` that would shadow a property when assigned. Plain symbols
# match if they name a property and aren't already declared local; tuples
# expand to their symbol leaves; anything else can't shadow.
_shadowed_lhs(_, _, _) = Symbol[]
_shadowed_lhs(lhs::Symbol, properties, locals) =
    haskey(properties, lhs) && !(lhs in locals) ? [lhs] : Symbol[]
function _shadowed_lhs(lhs::Expr, properties, locals)
    lhs.head === :tuple || return Symbol[]
    out = Symbol[]
    for s in lhs.args
        append!(out, _shadowed_lhs(s, properties, locals))
    end
    out
end

_collect_leaves(e) = error("unsupported destructuring element: $e")
_collect_leaves(e::Symbol) = Symbol[e]
function _collect_leaves(e::Expr)
    e.head === :(::) && return Symbol[e.args[1]]
    e.head === :tuple && return mapreduce(_collect_leaves, append!, e.args; init=Symbol[])
    error("unsupported destructuring element: $e")
end
_emit_positional_destructure!(oproperties, docs, elements, source_sym, lnn) = for (i, a) in enumerate(elements)
    _emit_positional_element!(oproperties, docs, a, i, source_sym, lnn)
end
_emit_positional_element!(_, _, a, _, _, _) = error("unsupported destructuring element: $a")
_emit_positional_element!(oproperties, docs, a::Symbol, i, source_sym, lnn) =
    _push_positional_leaf!(oproperties, docs, a, i, source_sym, lnn)
function _emit_positional_element!(oproperties, docs, a::Expr, i, source_sym, lnn)
    a.head === :(::) && return _push_positional_leaf!(oproperties, docs, a.args[1], i, source_sym, lnn)
    a.head === :tuple || error("unsupported destructuring element: $a")
    inner_leaves = _collect_leaves(a)
    inner_name = Symbol("_tuple_", join(inner_leaves, "_"))
    inner_locals = Set{Symbol}(inner_leaves); push!(inner_locals, inner_name)
    push!(oproperties, inner_name => (;lhs=inner_name, macros=Set{Symbol}(), rhs=:($source_sym[$i]), lnn, dependson=Set{Symbol}(), locals=inner_locals, indices=tuple(), indexed=false, cache_version=nothing, lru_size=nothing))
    push!(docs, (inner_name => (nothing, true)))
    _emit_positional_destructure!(oproperties, docs, a.args, inner_name, lnn)
end
function _push_positional_leaf!(oproperties, docs, leaf::Symbol, i, source_sym, lnn)
    push!(oproperties, leaf => (;lhs=leaf, macros=Set{Symbol}(), rhs=:($source_sym[$i]), lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([leaf]), indices=tuple(), indexed=false, cache_version=nothing, lru_size=nothing))
    push!(docs, (leaf => (nothing, true)))
end
# One element of a named-destructure LHS: either a bare Symbol leaf or a
# `target <= source` rename (Symbol or :tuple source). Anything else is
# silently ignored — the main parsing loop already errors on bad shapes.
_collect_destructure_named!(_, _) = nothing
_collect_destructure_named!(names, a::Symbol) = (push!(names, a); nothing)
function _collect_destructure_named!(names, a::Expr)
    a.head === :call && a.args[1] == :(<=) || return nothing
    _collect_destructure_renamed!(names, a.args[2], a.args[3])
    nothing
end
_collect_destructure_renamed!(_, _, _) = nothing
_collect_destructure_renamed!(names, target::Symbol, ::Symbol) = (push!(names, target); nothing)
function _collect_destructure_renamed!(names, target::Symbol, source::Expr)
    source.head === :tuple || return nothing
    prefix = string(target)
    for s in source.args
        _push_prefixed_name!(names, prefix, s)
    end
    nothing
end
_push_prefixed_name!(_, _, _) = nothing
_push_prefixed_name!(names, prefix, s::Symbol) = (push!(names, Symbol(prefix, s)); nothing)

# Body-loop sibling of the `_collect_destructure_*` family: same per-shape
# dispatch, but pushes `target => source-or-prefixed-name` pairs into the
# `members::Vector{Pair{Symbol,Any}}` accumulator the main loop hands to
# `extract_from`. Replaces the inner `if a isa Symbol … elseif Meta.isexpr(a, :call)
# && a.args[1] == :(<=) …` arms in the destructure-handling block.
_emit_named_member!(_, _) = nothing
_emit_named_member!(members, a::Symbol) = (push!(members, a => a); nothing)
function _emit_named_member!(members, a::Expr)
    a.head === :call && a.args[1] == :(<=) || return nothing
    _emit_renamed_member!(members, a.args[2], a.args[3])
    nothing
end
_emit_renamed_member!(_, _, _) = nothing
_emit_renamed_member!(members, target::Symbol, source::Symbol) =
    (push!(members, target => source); nothing)
function _emit_renamed_member!(members, target::Symbol, source::Expr)
    source.head === :tuple || return nothing
    prefix = string(target)
    for s in source.args
        _push_prefixed_member!(members, prefix, s)
    end
    nothing
end
_push_prefixed_member!(_, _, _) = nothing
_push_prefixed_member!(members, prefix, s::Symbol) =
    (push!(members, Symbol(prefix, s) => s); nothing)

# Flatten a destructuring LHS to the property names it introduces. Mirrors the
# main property-parsing loop (`:tuple` branch): positional → per-index leaves
# (recursing into nested tuples), named → per-member name with `<=` rename and
# prefix-tuple expansion. Used by `parent_props` collection so inline children
# auto-forward destructured parent properties the same way as bare ones.
_collect_destructure_names(lhs) = begin
    names = Symbol[]
    Meta.isexpr(lhs, :tuple) || return names
    named = length(lhs.args) == 1 && Meta.isexpr(lhs.args[1], :parameters)
    raw_args = named ? lhs.args[1].args : lhs.args
    if named
        for a in raw_args
            _collect_destructure_named!(names, a)
        end
    else
        append!(names, _collect_leaves(lhs))
    end
    names
end
# Name of a single kwarg in a `:parameters` block: bare `Symbol`s are
# their own name, `Expr(:kw, name, default)` carries the name as
# `args[1]`, anything else has no name. Per-type methods replace the
# `kw isa Symbol ? … : (Meta.isexpr(kw, :kw) ? … : nothing)` ternary.
_kwarg_name(kw::Symbol) = kw
_kwarg_name(kw::Expr) = Meta.isexpr(kw, :kw) ? kw.args[1] : nothing
_kwarg_name(_) = nothing

function _inject_include_kwargs!(call_expr, prop_name)
    params_idx = findfirst(a -> Meta.isexpr(a, :parameters), call_expr.args)
    if params_idx === nothing
        params = Expr(:parameters)
        insert!(call_expr.args, 2, params)
    else
        params = call_expr.args[params_idx]
    end
    has_parent = false
    has_status = false
    for kw in params.args
        name = _kwarg_name(kw)
        name === :__parent__ && (has_parent = true)
        name === :__status__ && (has_status = true)
    end
    has_parent || push!(params.args, Expr(:kw, :__parent__, :__self__))
    has_status || push!(params.args, Expr(:kw, :__status__,
        Expr(:call, compute_property, :__self__, :(Val(:__substatus__)), QuoteNode(prop_name))))
    call_expr
end

function _process_include_externals!(body)
    # Returned: (prop_name, type_expr) for each `@include`'d external. Used
    # to emit `_analysis_nested_type` so `analyze_structure` walks the
    # included type's tree even when the enclosing struct is
    # `@dynamicstruct` (and therefore HTMXObjects' route walker — which
    # would otherwise emit `_nested_struct_type` — never runs). For `@htmx`
    # structs HTMXObjects also emits `_nested_struct_type`, which
    # `_walk_nested_type` queries first; the duplicate `_analysis_nested_type`
    # entry is redundant but harmless.
    externals = Pair{Symbol, Any}[]
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        expr = arg
        parent_expr = nothing
        while Meta.isexpr(expr, :macrocall) && expr.args[1] != Symbol("@include")
            parent_expr = expr
            expr = expr.args[end]
        end
        Meta.isexpr(expr, :macrocall) && expr.args[1] == Symbol("@include") || continue
        inner = expr.args[end]
        Meta.isexpr(inner, :(=)) || continue
        lhs = inner.args[1]
        rhs = inner.args[2]
        Meta.isexpr(rhs, :call) || continue
        # LHS is a bare prop name `prop` for the classic non-indexed form, or a
        # call expression `prop(args…)` for the indexed-include form
        # (`@include foo(x, y) = External(x, y)`). Either way, the LHS expression
        # is preserved verbatim in the rewritten assignment so DO sees the
        # property as either bare or indexed accordingly.
        prop_name = if lhs isa Symbol
            lhs
        elseif Meta.isexpr(lhs, :call) && lhs.args[1] isa Symbol
            lhs.args[1]
        else
            continue
        end
        type_expr = rhs.args[1]
        push!(externals, prop_name => type_expr)
        _inject_include_kwargs!(rhs, prop_name)
        assignment = :($lhs = $rhs)
        if isnothing(parent_expr)
            body.args[i] = assignment
        else
            parent_expr.args[end] = assignment
        end
    end
    externals
end

# Detect an inline-method form `f(__self__, ...) = body` (or with `where`
# clauses, qualified function names like `Base.show`, and `__self__` at any
# positional index). Returns `(; fname, sig_args, where_params, self_idx)`
# or `nothing` if the LHS isn't a method-shaped definition with a `__self__`
# parameter.
_detect_inline_method_lhs(_) = nothing
function _detect_inline_method_lhs(lhs::Expr)
    where_params = Any[]
    sig = lhs
    while Meta.isexpr(sig, :where)
        append!(where_params, sig.args[2:end])
        sig = sig.args[1]
    end
    Meta.isexpr(sig, :call) || return nothing
    length(sig.args) >= 2 || return nothing
    sig_args = collect(sig.args[2:end])
    self_idx = nothing
    for (i, a) in enumerate(sig_args)
        Meta.isexpr(a, :parameters) && continue
        a_sym = a
        Meta.isexpr(a_sym, :(::)) && (a_sym = a_sym.args[1])
        if a_sym === :__self__
            self_idx = i
            break
        end
    end
    isnothing(self_idx) && return nothing
    (; fname=sig.args[1], sig_args, where_params, self_idx)
end

dynamicstruct(expr; docstring=nothing, cache_type=:parallel, child_handler=nothing, is_child=false, lint=true) = begin
    @assert expr.head == :struct
    mut, head, body = expr.args
    type = head
    Meta.isexpr(type, :(<:)) && (type = type.args[1])
    Meta.isexpr(type, :(curly)) && (type = type.args[1])
    @assert body.head == :block
    # --- Rewrite `@struct prop[(idx...)] = begin body end` into the equivalent
    # `prop[(idx...)] = struct <auto-named> body end` so the Form 1 path picks
    # it up. `@struct` is not a real macro — it's a marker handled here.
    # Also peels a `Core.@doc "str" @struct …` wrapper so docstrings on
    # `@struct` properties survive the rewrite (Julia's parser auto-wraps
    # `"str"\n<def>` inside any `:struct` body, including @dynamicstruct's).
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        # Peel a `Core.@doc "str" <inner>` wrapper if present.
        doc_wrapper = nothing
        macro_arg = arg
        if Meta.isexpr(macro_arg, :macrocall)
            mname = macro_arg.args[1]
            mname = _resolve_macro_name(mname)
            if mname === Symbol("@doc") && length(macro_arg.args) >= 4
                doc_wrapper = macro_arg
                macro_arg = macro_arg.args[end]
            end
        end
        Meta.isexpr(macro_arg, :macrocall) || continue
        macro_arg.args[1] == Symbol("@struct") || continue
        inner = macro_arg.args[end]
        Meta.isexpr(inner, :(=)) ||
            error("@struct: expected `prop = begin ... end` or `prop(idx...) = begin ... end`, got $(macro_arg)")
        lhs = inner.args[1]
        rhs = inner.args[2]
        Meta.isexpr(rhs, :block) ||
            error("@struct: RHS must be a `begin ... end` block, got $(rhs)")
        prop_sym = Meta.isexpr(lhs, :call) ? lhs.args[1] : lhs
        prop_sym isa Symbol ||
            error("@struct: LHS must be `prop` or `prop(idx...)`, got $(lhs)")
        gen_child_name = Symbol(prop_sym, "_inline")
        rewritten = Expr(:(=), lhs, Expr(:struct, false, gen_child_name, rhs))
        body.args[i] = isnothing(doc_wrapper) ? rewritten :
            Expr(:macrocall, doc_wrapper.args[1:end-1]..., rewritten)
    end
    # --- Process @include external structs ---
    # Returned (prop, type) pairs feed `_analysis_nested_type` so the
    # analyzer walks @include'd externals even when the enclosing struct
    # is `@dynamicstruct` (no HTMXObjects route walker = no
    # `_nested_struct_type` for these unless we add it here).
    include_externals_pairs = _process_include_externals!(body)
    # --- Extract inline struct definitions ---
    # Collect parent property names (excluding inline structs themselves)
    parent_props = Symbol[]
    for arg in body.args
        arg isa LineNumberNode && continue
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
        # `_collect_lhs_names` dispatches: bare Symbol → (sym,), tuple
        # destructure → recursive name collection, anything else → ().
        # Each new shape is a method, not another `if` arm.
        append!(parent_props, _collect_lhs_names(lhs))
    end
    extracted_structs = Expr[]
    # Parallel record of (parent-property-name => generated-child-type-name) for
    # each inline `@struct` child, used to emit `_nested_struct_type` methods so
    # `print_structure` can walk the inline-child tree.
    inline_child_pairs = Pair{Symbol,Any}[]
    # Typed computed properties (`prop::T = rhs`) register T only with
    # `_analysis_nested_type` (not `_nested_struct_type`), so the analyzer's
    # tree walk follows them but HTMXObjects' route walker doesn't (typed
    # primitives like `port::Int = 8080` would otherwise crash route
    # registration on `meta(::Type{Int})`).
    analysis_child_pairs = Pair{Symbol,Any}[]
    append!(analysis_child_pairs, include_externals_pairs)
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        # Peel a `Core.@doc "str" <inner>` wrapper if present, so that
        # `"docstring"\n@struct prop(args) = …` (which pass 1 has already
        # rewritten to `Core.@doc "str" (prop(args) = struct gen … end)`)
        # is recognised as Form 1a here. The wrapper is reattached to the
        # constructor assignment at the end so the third pass picks the
        # docstring up via its `@doc` unwrap and routes it into
        # `_property_description`.
        doc_wrapper = nothing
        form_arg = arg
        if Meta.isexpr(form_arg, :macrocall)
            mname = form_arg.args[1]
            mname = _resolve_macro_name(mname)
            if mname === Symbol("@doc") && length(form_arg.args) >= 4
                doc_wrapper = form_arg
                form_arg = form_arg.args[end]
            end
        end
        prop_name = nothing
        child_struct = nothing
        index_params = Symbol[]
        # (name, default_or_nothing) — `nothing` here means "no user-supplied
        # default" (required kwarg); any explicit default (even a literal
        # `nothing` written by the user) is wrapped in Some(...).
        index_kwargs = Tuple{Symbol,Any}[]
        # Form 1a: prop(idx...) = struct Name ... end  (indexed inline struct)
        # Julia parses short-form function defs with a :block wrapper around the
        # RHS — so `subject(idx) = struct Subject ... end` has args[2] = :block
        # containing a LineNumberNode + the :struct. Unwrap that case.
        if Meta.isexpr(form_arg, :(=)) && Meta.isexpr(form_arg.args[1], :call)
            rhs_expr = form_arg.args[2]
            if Meta.isexpr(rhs_expr, :block)
                inner = [a for a in rhs_expr.args if !(a isa LineNumberNode)]
                length(inner) == 1 && Meta.isexpr(inner[1], :struct) && (rhs_expr = inner[1])
            end
            if Meta.isexpr(rhs_expr, :struct)
                call_expr = form_arg.args[1]
                prop_name = call_expr.args[1]
                for p in call_expr.args[2:end]
                    if Meta.isexpr(p, :parameters)
                        for kw in p.args
                            if Meta.isexpr(kw, :kw)
                                kname = kw.args[1]
                                Meta.isexpr(kname, :(::)) && (kname = kname.args[1])
                                @assert kname isa Symbol "indexed inline struct kwarg name must be a Symbol, got $(kw.args[1])"
                                push!(index_kwargs, (kname, Some(kw.args[2])))
                            else
                                kname = Meta.isexpr(kw, :(::)) ? kw.args[1] : kw
                                @assert kname isa Symbol "indexed inline struct kwarg name must be a Symbol, got $kw"
                                push!(index_kwargs, (kname, nothing))
                            end
                        end
                    else
                        pname = Meta.isexpr(p, :(::)) ? p.args[1] : p
                        @assert pname isa Symbol "indexed inline struct: index param must be a Symbol, got $p"
                        push!(index_params, pname)
                    end
                end
                child_struct = rhs_expr
            end
        # Form 1b: prop = struct Name ... end
        elseif Meta.isexpr(form_arg, :(=)) && Meta.isexpr(form_arg.args[2], :struct)
            prop_name = form_arg.args[1]
            child_struct = form_arg.args[2]
        # Form 2: struct Name ... end (bare)
        elseif Meta.isexpr(form_arg, :struct)
            child_struct = form_arg
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
            _push_if_symbol!(child_props, clhs)
        end
        # Prepend __parent__, index params, hash_fields override, and
        # forwarded parent properties to the child body.
        child_body = child_struct.args[3]
        kwarg_names = Symbol[n for (n, _) in index_kwargs]
        prepend_names = Set{Symbol}([:__parent__, index_params..., kwarg_names...])
        # For indexed inline structs we override hash_fields to
        # (__parent__, indices..., kwargs...) so the child's disk-cache
        # namespace is tied to the parent hash AND to the kwarg values. Skip
        # if the user declared hash_fields inside the child body.
        will_prepend_hash_fields = (!isempty(index_params) || !isempty(index_kwargs)) && !(:hash_fields in child_props)
        will_prepend_hash_fields && push!(prepend_names, :hash_fields)
        # Never forward DO-internal cache/identity properties from the parent
        # into the child — they have per-instance semantics (the child has its
        # own hash/cache_path/cache_base) and forwarding them collides with the
        # automatic machinery (e.g. with our hash_fields prepend, producing
        # duplicate compute_property method definitions).
        nonforwardable = Set{Symbol}([:hash_fields, :hash, :cache_path, :cache])
        # Forward parent properties that (a) aren't overridden in the child,
        # (b) aren't __status__ (scoped separately), (c) aren't DO-internal
        # cache/identity names, and (d) aren't one of the names we're about
        # to prepend ourselves.
        # Dedupe: a parent can declare the same property name multiple times
        # (indexed properties with multi-method dispatch on the index type).
        # We only want one forwarding extractor per name.
        forwarded = unique!(Symbol[pp for pp in parent_props if !(pp in child_props) && pp != :__status__ && !(pp in nonforwardable) && !(pp in prepend_names)])
        prepend = Expr[]
        push!(prepend, :(__parent__ = nothing))
        for ip in index_params
            push!(prepend, :($ip = nothing))
        end
        # For kwargs: use user-supplied default if any, else `nothing`. The
        # value actually used at runtime comes from the constructor kwarg;
        # the in-body rhs is a compute_property fallback (required kwargs
        # won't hit it because the parent wrapper's call signature enforces
        # them at the call site).
        for (kname, kdefault) in index_kwargs
            rhs = kdefault === nothing ? nothing : something(kdefault)
            push!(prepend, :($kname = $rhs))
        end
        if will_prepend_hash_fields
            push!(prepend, :(hash_fields = $(Expr(:tuple, :__parent__, index_params..., kwarg_names...))))
        end
        if !isempty(forwarded)
            push!(prepend, :($(Expr(:tuple, Expr(:parameters, forwarded...))) = __parent__))
        end
        # Auto-derive a hierarchical cache_path: extend the parent's path by a
        # per-child directory whose name is the same flat segment that
        # `get_cache_path` would use as the file-name body for this property.
        # On disk this nests as "base/<parent_segment>/<child_segment>/…",
        # ending at the leaf "<property>_<args>.sjl". Skipped when the child
        # body explicitly declares cache_path — explicit wins.
        if !(:cache_path in child_props)
            # Expr(:call) layout: (func, [parameters], positional...). The
            # parameters expression must come right after the function, not
            # after positional args, otherwise Julia's parser rejects it.
            seg_call_args = Any[:(DynamicObjects.cache_segment)]
            !isempty(index_kwargs) && push!(seg_call_args,
                Expr(:parameters, [Expr(:kw, kn, kn) for (kn, _) in index_kwargs]...))
            push!(seg_call_args, QuoteNode(prop_name))
            append!(seg_call_args, index_params)
            seg_call = Expr(:call, seg_call_args...)
            push!(prepend, :(cache_path = joinpath(__parent__.cache_path, $seg_call)))
        end
        child_body.args = vcat(prepend, child_body.args)
        push!(extracted_structs, child_struct)
        push!(inline_child_pairs, prop_name => gen_name)
        # Replace with parent property definition. For indexed form, emit an
        # indexed property `prop(idx...; kw=default, ...)`; for the plain
        # form, a bare `prop`.
        constructor_kwargs = Any[
            Expr(:kw, :__parent__, :__self__),
            (Expr(:kw, ip, ip) for ip in index_params)...,
            (Expr(:kw, kname, kname) for (kname, _) in index_kwargs)...,
            Expr(:kw, :cache_type, :(__self__.__cache_type__)),
        ]
        # Auto-wire __status__ as a substatus of the parent, UNLESS the child
        # body declares its own __status__ (opt-out). Declaring
        # `__status__ = nothing` suppresses per-access Treebar nodes; declaring
        # `__status__ = __parent__.__status__` inherits the parent's status
        # directly without creating a child progress node.
        if !(:__status__ in child_props)
            push!(constructor_kwargs,
                Expr(:kw, :__status__, Expr(:call, compute_property, :__self__, :(Val(:__substatus__)), QuoteNode(prop_name), index_params...)))
        end
        constructor = Expr(:call, gen_name, Expr(:parameters, constructor_kwargs...))
        lhs_expr = if isempty(index_params) && isempty(index_kwargs)
            prop_name
        elseif isempty(index_kwargs)
            Expr(:call, prop_name, index_params...)
        else
            # Emit kwargs as an Expr(:parameters, ...) on the parent-property
            # call signature. Required kwargs stay as bare Symbols; defaulted
            # kwargs become Expr(:kw, name, default).
            kw_nodes = Any[kdefault === nothing ? kname : Expr(:kw, kname, something(kdefault))
                           for (kname, kdefault) in index_kwargs]
            Expr(:call, prop_name, Expr(:parameters, kw_nodes...), index_params...)
        end
        constructor_assignment = Expr(:(=), lhs_expr, constructor)
        body.args[i] = isnothing(doc_wrapper) ? constructor_assignment :
            Expr(:macrocall, doc_wrapper.args[1:end-1]..., constructor_assignment)
    end
    # `lnn` / `doc` flow across iterations via the metadata context.
    # `_absorb_body_metadata!` dispatch fills it from LineNumberNode /
    # AbstractString / `:string` Expr args; "real" property args read
    # `metadata.lnn[]` / `.doc[]` at the top of each iteration and the
    # `doc` ref is reset to `nothing` once that property consumes it.
    metadata = (lnn = Ref{Any}(nothing), doc = Ref{Any}(nothing))
    docs = []
    oproperties = Pair[]
    inline_methods = Any[]
    for arg in body.args
        _absorb_body_metadata!(arg, metadata) && continue
        lnn = metadata.lnn[]
        doc = metadata.doc[]
        macros = Set{Symbol}()
        rhs = nothing
        dependson = nothing
        locals = nothing
        indices = tuple()
        indexed = false
        cache_version = nothing
        lru_size = nothing
        # Peel `@doc` / `@cached` / `@lru` / unrecognised macros from `arg`
        # via `_apply_property_macro!` dispatch (one method per macro
        # shape). The state struct mutates `doc` / `cache_version` /
        # `lru_size` / `macros` in place — `macros` is the same Set the
        # outer loop uses, so we read it back implicitly; the other three
        # are scalars copied back after the loop.
        macro_state = _PropertyMacroState(doc, cache_version, lru_size, macros)
        while Meta.isexpr(arg, :macrocall)
            # `_resolve_macro_name` collapses `GlobalRef(Core, :@doc)` (the
            # form Julia's docstring lowering surfaces) to bare `:@doc`.
            mname = _resolve_macro_name(arg.args[1])
            arg = _apply_property_macro!(macro_state, Val(mname), arg)
        end
        doc = macro_state.doc
        cache_version = macro_state.cache_version
        lru_size = macro_state.lru_size
        # Inline-method form: `f(__self__, ...) = body` (with optional `where`
        # clauses and qualified `Module.f` names). Bypasses property tooling —
        # no compute_property, no getproperty entry — but the body still gets
        # bare-name → `__self__.<prop>` rewriting like a property RHS. Detect
        # before the function-form error and the `:(=)` LHS/RHS split so the
        # full LHS (which may carry `where` clauses) is intact.
        if Meta.isexpr(arg, :(=))
            method_info = _detect_inline_method_lhs(arg.args[1])
            if !isnothing(method_info)
                isempty(macros) ||
                    error("Property-level macros (@cached, @lru, …) cannot be applied to inline methods in @dynamicstruct.")
                push!(inline_methods, (; method_info..., body=arg.args[2], lnn))
                metadata.doc[] = nothing
                continue
            end
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
            # Nested positional destructuring: ((a, b), (c, d)) = expr
            # Handled recursively: outer group + inner group per nested tuple.
            if !named && any(a -> Meta.isexpr(a, :tuple), raw_args)
                all_leaves = _collect_leaves(arg)
                group_name = Symbol("_tuple_", join(all_leaves, "_"))
                group_locals = Set{Symbol}(all_leaves); push!(group_locals, group_name)
                push!(oproperties, group_name => (;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version, lru_size=nothing))
                push!(docs, (group_name => (doc, true)))
                _emit_positional_destructure!(oproperties, docs, raw_args, group_name, lnn)
                metadata.doc[] = nothing
                continue
            end
            # Build list of (property_name, extract_expr_builder) pairs
            # extract_expr_builder takes the group_name and returns the RHS expression
            members = Pair{Symbol, Any}[]  # name => source_field_or_index
            if named
                # Per-shape dispatch via `_emit_named_member!`:
                #   bare symbol     → `a => a`
                #   `target <= src` → `target => src` (Symbol src)
                #                     or `Symbol(prefix, s) => s` for each
                #                     `s` in a `:tuple` src (prefix mode).
                for a in raw_args
                    _emit_named_member!(members, a)
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
                push!(oproperties, group_name=>(;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version, lru_size=nothing))
                push!(docs, (group_name=>(doc, true)))
                group_name
            end
            metadata.doc[] = nothing
            for (prop_name, source) in members
                extract_rhs = _extract_member(extract_from, source)
                push!(oproperties, prop_name=>(;lhs=prop_name, macros=Set{Symbol}(), rhs=extract_rhs, lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([prop_name]), indices=tuple(), indexed=false, cache_version=nothing, lru_size=nothing))
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
        name, ext_type = if Meta.isexpr(arg, :(::))
            arg.args[1], arg.args[2]
        else
            arg, nothing
        end
        @assert name isa Symbol dump(name)
        # `prop::T = rhs` (computed property with a type annotation) registers
        # T with `_analysis_nested_type` so `analyze_structure` walks into
        # T's tree alongside the enclosing struct's. Separate hook from
        # `_nested_struct_type` (which HTMXObjects walks for route mounting)
        # — typed primitives like `port::Int` would otherwise wedge route
        # registration on `meta(Int)`. Indexed properties and fixed fields
        # keep the annotation's existing semantics (Julia field type for
        # fixed, ignored for indexed).
        if ext_type !== nothing && !isnothing(rhs) && !indexed
            push!(analysis_child_pairs, name => ext_type)
        end
        push!(docs, (name=>(doc, !isnothing(rhs))))
        metadata.doc[] = nothing
        !isnothing(locals) && push!(locals, name)
        !isnothing(locals) && push!(locals, :__status__)
        @assert !isnothing(rhs) || length(macros) == 0
        push!(oproperties, name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices, indexed, cache_version, lru_size))
    end
    properties = Dict(oproperties)
    property_docs = Dict(name => doc for (name, (doc, _)) in docs if !isnothing(doc))

    # Struct-level lint passes: repeated-prefix and shared-arg-signature.
    # Lints have moved to `analyze_structure(T)` — run from `print_structure`,
    # not at definition time. The macro no longer emits any lint warnings.

    docstring = something(docstring, "DynamicStruct `$type`.") * "\n\n" * join([
        "* " * (isnothing(doc) ? "" : "$(_doc_to_string(doc)): ") * "`$name" * (hasrhs ? " = ..." : "") * "`"
        for (name, (doc, hasrhs)) in docs
    ], "\n")

    generated_names = Tuple(name for (name, info) in oproperties if !isfixed(info))
    indexed_names = Tuple(name for (name, info) in oproperties if info.indexed)
    cached_names = [(name, Symbol("_", type, "_", name, "_disk_cache")) for (name, info) in oproperties if !isfixed(info) && Symbol("@cached") in info.macros]
    fixed_fields = [(name, info.lhs) for (name, info) in oproperties if isfixed(info)]
    fixed_names = [n for (n, _) in fixed_fields]
    fixed_lhs = [lhs for (_, lhs) in fixed_fields]
    struct_expr = Expr(:struct, mut, head, Expr(:block,
        fixed_lhs..., :(cache::$PropertyCache),
        :($type($(fixed_lhs...); cache_type=$(Meta.quot(cache_type)), kwargs...) = new(
            $(fixed_names...),
            $PropertyCache(
                $(resolve_cache_type)(cache_type),
                (;kwargs...)
            )
        ))
    ))
    result = Expr(:block)
    # Emit per-cached-property DiskCacheLocks
    for (name, varname) in cached_names
        push!(result.args, :($varname = $DiskCacheLocks()))
    end
    # Prepend extracted inline child structs (processed recursively)
    _child_handler = isnothing(child_handler) ? (s -> dynamicstruct(s; cache_type, is_child=true, lint)) : child_handler
    for s in extracted_structs
        child_result = _child_handler(s)
        # Unwrap esc() — parent handles escaping
        @assert Meta.isexpr(child_result, :escape)
        push!(result.args, child_result.args[1])
    end
    # Docstring precedence — without emitting two `@doc` calls (which would
    # warn "Replacing docs" on every Revise reload and, worse, cause
    # `Core.@__doc__` to copy the parent's user docstring onto hoisted
    # inline children by walking every `Base.@__doc__` marker in the
    # expansion):
    #   1. Emit the struct definition bare.
    #   2. Install the auto-generated property-list docstring as a
    #      `Base.Docs.getdoc(::Type{T})` fallback. It's guarded to return
    #      `nothing` when a docstring is already registered for the
    #      binding, so a user docstring always wins.
    #   3. For top-level structs only (`is_child=false`), emit
    #      `Base.@__doc__ $type` as the hook that `Core.@__doc__` rewrites
    #      into `@doc "userdoc" $type` when the user wrote
    #      `"""userdoc"""\n@dynamicstruct struct X ... end`. Children omit
    #      this marker so the parent's user docstring doesn't bleed into
    #      hoisted inline child structs.
    push!(result.args, Expr(:block,
        struct_expr,
        :($Base.Docs.getdoc(::Type{$type}) = begin
            __b = $Base.Docs.Binding(parentmodule($type), nameof($type))
            __m = get($Base.Docs.meta(__b.mod), __b, nothing)
            (__m === nothing || isempty(__m.docs)) ? $docstring : nothing
        end),
        (is_child ? :($type) : :(Base.@__doc__ $type)),
        quote
            $Base.hasproperty(__self__::$type, name::Symbol) = name in $(Tuple(keys(properties)))
            $Base.getproperty(__self__::$type, name::Symbol) = $getorcomputeproperty(__self__, name)
            $Base.setproperty!(__self__::$type, name::Symbol, value) = getfield(__self__, :cache)[name] = value
            $DynamicObjects.meta(::Type{$type}) = $properties
            $DynamicObjects.is_generated_property(::$type, name::Symbol) = name in $generated_names
            $DynamicObjects.is_indexed_property(::$type, name::Symbol) = name in $indexed_names
            $DynamicObjects._hash_replace(__self__::$type) = __self__.hash
            $([:(
                $DynamicObjects._disk_cache(::$type, ::Val{$(QuoteNode(name))}) = $varname
            ) for (name, varname) in cached_names]...)
            $([:(
                $DynamicObjects._nested_struct_type(::Type{$type}, ::Val{$(QuoteNode(prop_name))}) = $gen_name
            ) for (prop_name, gen_name) in inline_child_pairs]...)
            $([:(
                $DynamicObjects._analysis_nested_type(::Type{$type}, ::Val{$(QuoteNode(prop_name))}) = $gen_name
            ) for (prop_name, gen_name) in analysis_child_pairs]...)
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
                # Walk kwarg defaults with kwarg names excluded from locals,
                # so that `seed=seed` correctly transforms the default `seed`
                # into `__self__.seed` rather than leaving it as a bare symbol.
                kwarg_names = Set{Symbol}()
                for idx in info.indices
                    Meta.isexpr(idx, :parameters) || continue
                    for a in idx.args
                        Meta.isexpr(a, :kw) && push!(kwarg_names, a.args[1] isa Expr ? a.args[1].args[1] : a.args[1])
                    end
                end
                defaults_locals = setdiff(info.locals, kwarg_names)
                walked_indices = map(info.indices) do idx
                    if Meta.isexpr(idx, :parameters)
                        Expr(:parameters, map(idx.args) do a
                            if Meta.isexpr(a, :kw)
                                Expr(:kw, a.args[1], walk_rhs(a.args[2]; locals=defaults_locals, properties, lnn=info.lnn))
                            else
                                a
                            end
                        end...)
                    else
                        idx
                    end
                end
                _call(f, extras...) = fixcall(Expr(:call,
                    Expr(:., DynamicObjects, QuoteNode(f)),
                    :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    walked_indices..., Expr(:parameters, extras...),
                ))
                iscached_val = Symbol("@cached") in info.macros
                desc_expr = if haskey(property_docs, name)
                    pdoc = property_docs[name]
                    has_user_kw_splat = any(walked_indices) do idx
                        Meta.isexpr(idx, :parameters) && any(a -> Meta.isexpr(a, :...), idx.args)
                    end
                    desc_extras = has_user_kw_splat ? () : (:(kwargs...),)
                    _lnn, Expr(:(=), _call(:_property_description, desc_extras...), Expr(:block, _lnn, pdoc))
                else
                    nothing
                end
                walked_rhs = walk_rhs(info.rhs; info.locals, properties, lnn=info.lnn)
                block = Expr(:block,
                    _lnn, Expr(:(=), _call(:compute_property, cp_kwargs...), Expr(:block, _lnn, walked_rhs)),
                    _lnn, Expr(:(=), _call(:iscached), Expr(:block, _lnn, iscached_val)),
                    _lnn, Expr(:(=), _call(:resumes), Expr(:block, _lnn, false)),
                )
                if !isnothing(info.cache_version)
                    # Don't use _call — cache_version is per-property, not per-index
                    cv_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:cache_version)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    cv_expr = (_lnn, Expr(:(=), cv_method, Expr(:block, _lnn, info.cache_version)))
                    push!(block.args, cv_expr...)
                end
                if !isnothing(info.lru_size)
                    info.indexed || error("@lru on non-indexed property `$name`: only indexed properties have a per-property cache to bound. Drop the `@lru` or give the property index parameters: `$name(idx) = …`")
                    sz = info.lru_size
                    pc_ts = :($(Expr(:., DynamicObjects, QuoteNode(:PropertyCache))){<:$(Expr(:., DynamicObjects, QuoteNode(:AbstractThreadsafeDict)))})
                    pc_pl = :($(Expr(:., DynamicObjects, QuoteNode(:PropertyCache))){<:Dict})
                    sub_call_ts = Expr(:call, Expr(:., DynamicObjects, QuoteNode(:subcache)),
                        :(::$pc_ts), :(::Type{$type}), :(::Val{$(Meta.quot(name))}))
                    sub_call_pl = Expr(:call, Expr(:., DynamicObjects, QuoteNode(:subcache)),
                        :(::$pc_pl), :(::Type{$type}), :(::Val{$(Meta.quot(name))}))
                    sub_body_ts = Expr(:block, _lnn,
                        Expr(:call, Expr(:curly, Expr(:., DynamicObjects, QuoteNode(:ThreadsafeLRUDict)), :Any, :Any), sz))
                    sub_body_pl = Expr(:block, _lnn,
                        Expr(:call, Expr(:curly, Expr(:., DynamicObjects, QuoteNode(:LRUDict)), :Any, :Any), sz))
                    push!(block.args, _lnn, Expr(:(=), sub_call_ts, sub_body_ts))
                    push!(block.args, _lnn, Expr(:(=), sub_call_pl, sub_body_pl))
                end
                !isnothing(desc_expr) && push!(block.args, desc_expr...)
                block
            end
            for (name, info) in oproperties if !isfixed(info)
        ]...,
        # IndexableProperty wrappers for indexed properties are now created
        # directly in getorcomputeproperty (via meta check), so no zero-arg
        # compute_property methods are needed here.
    ))
    # Emit inline-method definitions: `f(__self__, …) = body` collected from
    # the struct body. These are plain methods on `::type` (so standard
    # multiple dispatch on the remaining args works) — no property entry,
    # no compute_property, not reachable via getproperty. The body is walked
    # with the full `properties` dict so bare references to registered
    # property names are rewritten to `__self__.<name>`, matching the
    # rewrite that runs on property RHSs.
    for m in inline_methods
        sig_args = collect(m.sig_args)
        # Type the bare `__self__` arg to `__self__::<type>`. If the user
        # already wrote `__self__::T`, leave the user's annotation alone.
        if sig_args[m.self_idx] === :__self__
            sig_args[m.self_idx] = :(__self__::$type)
        end
        # Locals shielded from bare-name rewriting: `__self__`, every name
        # introduced by the signature args (incl. typed/destructured/kw),
        # and all `where`-clause type parameters.
        method_locals = Set{Symbol}([:__self__])
        for a in sig_args
            union!(method_locals, extractnames([a]))
        end
        for wp in m.where_params
            wp isa Symbol && push!(method_locals, wp)
            Meta.isexpr(wp, :(<:)) && wp.args[1] isa Symbol && push!(method_locals, wp.args[1])
            Meta.isexpr(wp, :comparison) && wp.args[1] isa Symbol && push!(method_locals, wp.args[1])
        end
        walked_body = walk_rhs(m.body; locals=method_locals, properties, lnn=m.lnn)
        sig = Expr(:call, m.fname, sig_args...)
        if !isempty(m.where_params)
            sig = Expr(:where, sig, m.where_params...)
        end
        method_lnn = something(m.lnn, LineNumberNode(0, :unknown))
        push!(result.args, Expr(:(=), sig, Expr(:block, method_lnn, walked_body)))
    end
    esc(result)
end

# Replace only the top-level LineNumberNodes in a block, leaving nested ones intact.
# This gives Revise the source-location metadata it needs to track method changes,
# while preserving internal LineNumberNodes for useful stacktraces.
function setlnn(lnn::Union{LineNumberNode,Nothing})
    function(expr::Expr)
        isnothing(lnn) && return expr
        @assert expr.head == :block
        Expr(:block, map(x -> _replace_lnn(x, lnn), expr.args)...)
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
- `:serial` — plain `Dict`, single-threaded safe.
- `:parallel` (default) — `ThreadsafeDict`, safe to access from multiple tasks
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

# Async progress with `__status__`

With `cache_type=:parallel`, indexed properties spawn background `Task`s.
Define `__status__` (root progress node) to automatically wire progress into
spawned tasks. A default `__substatus__` is provided that creates child progress
nodes when Treebars is loaded (via the TreebarsExt extension):

```julia
@dynamicstruct struct MyApp
    __status__ = initialize_progress!(:state; description="MyApp")
    results[key] = expensive_computation(__status__)  # __status__ is the substatus
end
app = MyApp(; cache_type=:parallel)

# Non-blocking access with progress:
fetchindex(app.results, key) do rv, status
    rv isa Task ? render_progress(status) : render_result(rv)
end
```

`__substatus__` is called before each Task spawn.
`name` is the property symbol, `args`/`kwargs` are the indices. The returned
object is stored in `ThreadsafeDict.status` (accessible via `getstatus`) and
passed to the computation body as the local `__status__`.

`__substatus__` only fires on ThreadsafeDict `getindex` (bracket access).
Call syntax and scalar property access do not trigger it.
"""
# Parse a single positional macro arg into a (kwarg-name => value) pair.
# `name=value` Expr → `(name => value)`. String/`:string` → `(:docstring => …)`.
# QuoteNode (`:parallel` / `:serial`) → `(:cache_type => sym)`. Anything else
# is rejected with a pointer to the recognised forms.
_parse_macro_opt(a::AbstractString) = (:docstring => a)
_parse_macro_opt(a::QuoteNode) = (:cache_type => a.value)
_parse_macro_opt(a::Expr) = if a.head === :string
    (:docstring => a)
elseif a.head === :(=) && a.args[1] isa Symbol
    (a.args[1] => a.args[2])
else
    error("@dynamicstruct: unsupported option `$a` — use a docstring, `:parallel`/`:serial`, or `name=value`.")
end
_parse_macro_opt(a) = error("@dynamicstruct: unsupported option `$a` — use a docstring, `:parallel`/`:serial`, or `name=value`.")

macro dynamicstruct(args...)
    isempty(args) && error("@dynamicstruct: missing struct definition.")
    expr = last(args)
    kwargs = Dict{Symbol,Any}(_parse_macro_opt(a) for a in args[1:end-1])
    dynamicstruct(expr; kwargs...)
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
_cause_error(e::PropertyComputationError) = _unwrap_cause(e.cause)
_unwrap_cause(c::Tuple) = first(c)
_unwrap_cause(c) = c
_cause_bt(c::Tuple) = length(c) >= 2 ? c[2] : nothing
_cause_bt(_) = nothing

# Compact, truncated repr for error messages — avoids dumping huge DataFrames/
# arrays that happen to be passed as property arguments. Small values (numbers,
# strings, symbols) render identically to `repr`; large/multi-line values
# collapse to a one-line `summary`-style snippet.
function _short_repr(v; limit=120)
    s = sprint(show, v; context=(:limit => true, :compact => true, :displaysize => (3, limit)))
    nl = findfirst('\n', s)
    isnothing(nl) || (s = summary(v))
    length(s) > limit ? first(s, limit - 1) * "…" : s
end

function _format_property_key(name, indices, kwargs)
    s = string(name)
    pos_parts = !isempty(indices) ? _short_repr.(collect(indices)) : String[]
    kw_parts = ["$k=$(_short_repr(v))" for (k, v) in kwargs]
    all_parts = isempty(pos_parts) && !isempty(kw_parts) ?
        ["; " * join(kw_parts, ", ")] :
        vcat(pos_parts, isempty(kw_parts) ? String[] : ["; " * join(kw_parts, ", ")])
    isempty(all_parts) ? s : s * "(" * join(all_parts, ", ") * ")"
end

function Base.showerror(io::IO, e::PropertyComputationError)
    key = _format_property_key(e.property, e.indices, e.kwargs)
    print(io, "PropertyComputationError: computing `$key` on $(e.type_name)\n")
    cause_err = _cause_error(e)
    cause_bt = _cause_bt(e.cause)
    print(io, "  Caused by: ")
    _show_cause(io, cause_err, cause_bt)
end
# PropertyComputationError prints its own filtered backtrace via the 2-arg
# showerror; nested ones must use that path. Otherwise prefer the 3-arg form
# when a backtrace is available.
_show_cause(io, err::PropertyComputationError, _bt) = showerror(io, err)
_show_cause(io, err, ::Nothing) = showerror(io, err)
_show_cause(io, err, bt) = showerror(io, err, bt)

# ---------- print_structure ----------------------------------------------------
# Programmatic rendering of a DO/HTMXO type's structure, suitable for spotting
# IPs, inline children, routes, @param decls, and constructor fields at a glance.
# Walks `meta(T)` for properties + `_nested_struct_type(T, Val(name))` for inline
# children. HTMXO-specific introspection (`_param_names`, route macro tags) is
# read defensively so DO-only types print cleanly too.

const _PRINT_STRUCT_ROUTE_MACROS = Set([
    Symbol("@get"), Symbol("@post"), Symbol("@put"),
    Symbol("@patch"), Symbol("@delete"), Symbol("@ws"),
])

# Skip auto-generated and DO-internal property names. Dunder names
# (`__self__`, `__parent__`, `__status__`, …) are normally hidden, but
# `prop::T = rhs` registrations on a dunder name (e.g. `__appdata__::AppData`)
# represent a real user-declared nested DO subtree the user wants to see —
# the registered `_nested_struct_type` is the signal.
_print_struct_skip(::Type{T}, name::Symbol) where {T} = begin
    s = String(name)
    is_dunder = startswith(s, "__") && endswith(s, "__")
    is_dunder && _walk_nested_type(T, name) !== nothing && return false
    is_dunder ||
        startswith(s, "_tuple_") ||
        name === :hash_fields ||
        name === :cache_path ||
        name === :hash ||
        name === :cache
end

# A property whose RHS is just `__parent__.something` — auto-forwarded into an
# inline child by the macro. Not a user-authored property of the child.
_print_struct_is_forwarded(rhs) =
    Meta.isexpr(rhs, :.) && length(rhs.args) == 2 &&
    rhs.args[1] === :__parent__ && rhs.args[2] isa QuoteNode

# Compact one-line render of a default expression — chops noisy whitespace.
_print_struct_short(x) = replace(string(x), r"\s+" => " ")

# Defensive HTMXO `_param_names(T)` lookup — the function lives in HTMXObjects;
# DO-only types don't have it. Empty tuple if the binding isn't loaded.
function _print_struct_param_names(T::Type)
    htmxo = get(Base.loaded_modules,
        Base.PkgId(Base.UUID("b12ef442-5798-4353-80f3-9562b03a0cb6"),
                   "HTMXObjects"),
        nothing)
    htmxo === nothing && return ()
    isdefined(htmxo, :_param_names) || return ()
    try htmxo._param_names(T) catch; () end
end

# --- IP arg worst-case dependency bound ---------------------------------------
# For each IP, find its call sites in the DO tree. Each caller is some property
# of some type. Take the union of every caller's *static identity scope* — its
# own IP positional args, plus the ancestor types' constructor fields and
# `@param` names walking up to root. That set is an honest *upper bound*: the
# IP arg's value can be derived from no more than these names (modulo dynamic
# inputs from outside the tree, like HTTP request bodies).
#
# Static and cheap — no AST walking of caller bodies, no dataflow, no
# substitution. The annotation reads "at most depends on {names}", which is
# what `print_structure` advertises.

# Extract bare positional arg names from an `info.indices` tuple. Drops kwargs
# (the `:parameters` slot) and unwraps `name::T` annotations.
function _ip_positional_args(indices)
    names = Symbol[]
    for idx in indices
        Meta.isexpr(idx, :parameters) && continue
        n = Meta.isexpr(idx, :(::)) ? idx.args[1] : idx
        n isa Symbol && push!(names, n)
    end
    names
end

# Reachable types from a root via _nested_struct_type. Used to bound the
# call-site search so we don't chase outside the DO tree print_structure
# is rendering.
function _all_types_in_tree(root::Type)
    seen = Set{Type}([root])
    queue = Type[root]
    while !isempty(queue)
        T = popfirst!(queue)
        props = try meta(T) catch; nothing end
        props === nothing && continue
        for name in keys(props)
            nested = _walk_nested_type(T, name)
            nested === nothing && continue
            nested in seen && continue
            push!(seen, nested)
            push!(queue, nested)
        end
    end
    seen
end

# Map child_type → (parent_type, prop_name_in_parent) — built by walking the
# tree from the root via `_nested_struct_type`. Lets us climb the type chain
# for static-scope lookup. The root has no entry in this map.
function _build_parent_map(root::Type)
    parents = Dict{Type, Tuple{Type, Symbol}}()
    seen = Set{Type}([root])
    queue = Type[root]
    while !isempty(queue)
        T = popfirst!(queue)
        props = try meta(T) catch; nothing end
        props === nothing && continue
        for name in keys(props)
            nested = _walk_nested_type(T, name)
            nested === nothing && continue
            nested in seen && continue
            push!(seen, nested)
            push!(queue, nested)
            parents[nested] = (T, name)
        end
    end
    parents
end

# Names visible as "root identity" at a property body inside type T:
# constructor fields and `@param` names, walking parent_map up to root. If
# `T` is reached via an IP property of its parent, that IP's positional arg
# names are also in scope.
function _enclosing_scope(T::Type, parents)
    names = Set{Symbol}()
    cur = T
    while true
        for f in fieldnames(cur)
            f === :cache && continue
            s = String(f)
            (startswith(s, "__") && endswith(s, "__")) && continue
            push!(names, f)
        end
        for p in _print_struct_param_names(cur)
            push!(names, p)
        end
        haskey(parents, cur) || break
        parent_T, parent_prop = parents[cur]
        try
            info = meta(parent_T)[parent_prop]
            for a in _ip_positional_args(info.indices)
                push!(names, a)
            end
        catch
        end
        cur = parent_T
    end
    names
end

# Dot-chain leftmost Symbol — `render.stan.code` → `:render`; bare `code` →
# `:code`. `nothing` for non-symbol roots.
function _dot_chain_root(expr)
    expr isa Symbol && return expr
    Meta.isexpr(expr, :., 2) && return _dot_chain_root(expr.args[1])
    nothing
end

# Conservative call-site detector: matches `target(…)` and `parent.target(…)`
# only when the leftmost symbol resolves to a property of the caller's type
# or one of the macro-injected names. Excludes unrelated namespaces (`h.code`,
# `Base.length`, …) that happen to share a property name.
function _has_call_to(expr, target::Symbol, cprops)
    expr isa Expr || return false
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        if callee === target
            cprops !== nothing && haskey(cprops, target) && return true
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            if root !== nothing &&
               (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                (cprops !== nothing && haskey(cprops, root)))
                return true
            end
        end
    end
    for a in expr.args
        _has_call_to(a, target, cprops) && return true
    end
    false
end

# Scope of a caller property: enclosing static scope of its type, plus its own
# IP positional args (so `name` from `@get stage(name)` flows through into the
# bound for any IP called from inside `stage`'s body).
function _caller_scope(caller_T::Type, caller_prop::Symbol, parents)
    names = _enclosing_scope(caller_T, parents)
    info = try meta(caller_T)[caller_prop] catch; nothing end
    if info !== nothing
        for a in _ip_positional_args(info.indices)
            push!(names, a)
        end
    end
    names
end

# Raw worst-case bound — the union of callers' static identity scopes,
# possibly containing intermediate IP-arg names (like `bundle` from an
# enclosing IP). `_print_struct_worst_case` expands these to root identities.
function _raw_worst_case(types_in_tree, parents, T::Type, prop_name::Symbol, info)
    isempty(_ip_positional_args(info.indices)) && return nothing
    callers = Set{Tuple{Type,Symbol}}()
    for U in types_in_tree
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (uname, uinfo) in uprops
            uinfo.rhs === nothing && continue
            (U === T && uname === prop_name) && continue
            _has_call_to(uinfo.rhs, prop_name, uprops) || continue
            push!(callers, (U, uname))
        end
    end
    isempty(callers) && return (:none,)
    bound = Set{Symbol}()
    for (cT, cp) in callers
        union!(bound, _caller_scope(cT, cp, parents))
    end
    (:bound, sort!(collect(bound)))
end

# Expand a single name to its root identities (@param / field / unbounded
# IP arg). If the name is itself an IP arg with an in-tree caller bound,
# recurse into that bound. Cycle protection via `visited`.
function _expand_name!(out::Set{Symbol}, name::Symbol,
                      types_in_tree, parents, visited::Set{Symbol})
    name in visited && return
    push!(visited, name)
    # Root identity: @param or constructor field anywhere in the tree.
    for T in types_in_tree
        for f in fieldnames(T)
            f === name && (push!(out, name); return)
        end
        for p in _print_struct_param_names(T)
            p === name && (push!(out, name); return)
        end
    end
    # IP arg: replace with its IP's bound (recursively).
    for T in types_in_tree
        props = try meta(T) catch; nothing end
        props === nothing && continue
        for (pn, pinfo) in props
            for a in _ip_positional_args(pinfo.indices)
                a === name || continue
                raw = _raw_worst_case(types_in_tree, parents, T, pn, pinfo)
                if raw !== nothing && raw[1] === :bound
                    for n in raw[2]
                        _expand_name!(out, n, types_in_tree, parents, visited)
                    end
                else
                    # IP has no in-tree callers — treat as root.
                    push!(out, name)
                end
                return
            end
        end
    end
    # Unrecognized — keep as-is.
    push!(out, name)
end

# Public worst-case bound: returns the EXPANDED form. Every name in the
# result is a root identity (@param, field, or IP arg of an unbounded IP);
# intermediate IP-arg names are unfolded to their own bounds.
function _print_struct_worst_case(types_in_tree, parents, T::Type,
                                  prop_name::Symbol, info)
    raw = _raw_worst_case(types_in_tree, parents, T, prop_name, info)
    raw === nothing && return nothing
    raw[1] === :none && return raw
    expanded = Set{Symbol}()
    for n in raw[2]
        _expand_name!(expanded, n, types_in_tree, parents, Set{Symbol}())
    end
    (:bound, sort!(collect(expanded)))
end

# --- Identity coloring --------------------------------------------------------
# Each "scope identifier" (constructor field, @param name, IP positional arg)
# is colored deterministically by its name so the same name reads as the same
# color everywhere it appears — in `fields:` / `@param:` lists, in IP
# signatures, and in worst-case bound sets. Lets you visually trace bonds:
# spot `formula` once, then scan for matching color anywhere else.

# 32 vivid full-spectrum hues — saturation high enough that adjacent
# identities are easy to tell apart at a glance. Identity coloring is
# applied as an underline-only mark (`Semantic{:underlined}`), not as
# foreground text color, so bright/saturated values are fine — the text
# itself stays at default contrast. Stored as `#rrggbb` so they drop into
# CSS directly and need only a hex→RGB parse for the terminal's truecolor
# escape.
const _IDENT_PALETTE = (
    "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf",
    "#aec7e8", "#ffbb78", "#98df8a", "#ff9896", "#c5b0d5",
    "#c49c94", "#f7b6d2", "#c7c7c7", "#dbdb8d", "#9edae5",
    "#393b79", "#637939", "#8c6d31", "#843c39", "#7b4173",
    "#5254a3", "#8ca252", "#bd9e39", "#ad494a", "#a55194",
    "#6b6ecf", "#cedb9c",
)

# Color-by-bound: each name in the tree maps to a *fingerprint* — its upstream
# worst-case bound set if it's an IP positional arg, or its own name (treated
# as a root identity) if it's a @param / fixed field / IP arg without callers.
# Two names with the same fingerprint render in the same color, so two args
# named differently but with identical upstream identity slices (`bundle1` /
# `bundle2`) still bound visually.
#
# The fingerprint approach over-groups in the worst case (two unrelated args
# that happen to share the same upstream scope collide), but matches the
# "same identity = same color" intent the static analyzer can actually
# justify, with no dataflow cost.
function _build_color_map(root::Type)
    types_in_tree = _all_types_in_tree(root)
    parent_map = _build_parent_map(root)
    # Pass 1 — collect all names that exist in the tree and assign each its
    # fingerprint. Root identities (@params, fixed fields) fingerprint as
    # singletons; IP args with a tightenable bound fingerprint as the bound.
    fingerprint = Dict{Symbol, Any}()
    function set_root!(n::Symbol)
        # Root identities take precedence over IP-arg-bound fingerprints when
        # the same name appears in both roles — a @param IS its own identity.
        fingerprint[n] = (:name, n)
    end
    visited = Set{Type}()
    function visit_type(T)
        T in visited && return
        push!(visited, T)
        for f in fieldnames(T)
            f === :cache && continue
            s = String(f); (startswith(s, "__") && endswith(s, "__")) && continue
            set_root!(f)
        end
        for p in _print_struct_param_names(T); set_root!(p); end
        props = try meta(T) catch; nothing end
        props === nothing && return
        for name in sort!(collect(keys(props)))
            _print_struct_skip(T, name) && continue
            info = props[name]
            args = _ip_positional_args(info.indices)
            if !isempty(args)
                wc = _print_struct_worst_case(types_in_tree, parent_map, T, name, info)
                fp = (wc !== nothing && wc[1] === :bound) ?
                     (:bound, Tuple(wc[2])) : nothing
                for a in args
                    haskey(fingerprint, a) && continue   # @param/field wins
                    fingerprint[a] = fp === nothing ? (:name, a) : fp
                end
            end
            nested = _walk_nested_type(T, name)
            nested === nothing || visit_type(nested)
        end
    end
    visit_type(root)
    # Pass 2 — assign each unique fingerprint a hex color in stable order
    # (sorted by name of the first member to encounter it).
    fp_to_idx = Dict{Any, Int}()
    name_to_color = Dict{Symbol, String}()
    for n in sort!(collect(keys(fingerprint)))
        fp = fingerprint[n]
        idx = get!(fp_to_idx, fp, length(fp_to_idx) + 1)
        name_to_color[n] = _IDENT_PALETTE[mod1(idx, length(_IDENT_PALETTE))]
    end
    name_to_color
end

# --- Structured representation ------------------------------------------------
# A minimal HTML-tag-shaped DOM. `Tag` is a Symbol type parameter (Val-like,
# so dispatch happens at compile time); `content` is whatever the tag holds
# (string, single node, vector of nodes, or nothing); `attributes` is a
# NamedTuple of HTML-style attrs (`class="…"`, `color=…`, etc.).
#
# Generic HTML rendering is `<tag attrs>content</tag>` — overrides per tag
# when the default isn't right. Markdown / terminal fall back to "just emit
# the content" with overrides for the tags that actually carry meaning in
# those formats (`:strong` → ANSI bold / `**…**`; etc.).

abstract type AbstractNode end

struct Node{Tag, C<:Tuple, A<:NamedTuple} <: AbstractNode
    content::C
    attributes::A
    function Node(tag::Symbol, args...; kwargs...)
        a = (;kwargs...)
        new{tag, typeof(args), typeof(a)}(args, a)
    end
end

# `Semantic` mirrors `Node`'s shape but is NOT an HTML element — it carries
# our domain concepts (`:line`, `:section`, `:colored`, `:lint`) that have
# format-specific renderings but no faithful HTML tag. The split means the
# generic HTML fallback for `Node` can never accidentally produce invalid
# `<line>` / `<section>` markup for a Semantic tag.
struct Semantic{Tag, C<:Tuple, A<:NamedTuple} <: AbstractNode
    content::C
    attributes::A
    function Semantic(tag::Symbol, args...; kwargs...)
        a = (;kwargs...)
        new{tag, typeof(args), typeof(a)}(args, a)
    end
end

# Cobweb-style builders: `h.tag(args...; attrs...)` for HTML elements;
# `s.tag(args...; attrs...)` for Semantic nodes. Each `getproperty` overload
# turns any tag-name access into a constructor closure.
function h end
Base.getproperty(::typeof(h), tag::Symbol) =
    (args...; kwargs...) -> Node(tag, args...; kwargs...)
Base.propertynames(::typeof(h)) = ()

function sem end
Base.getproperty(::typeof(sem), tag::Symbol) =
    (args...; kwargs...) -> Semantic(tag, args...; kwargs...)
Base.propertynames(::typeof(sem)) = ()

# === Builder ==================================================================

# Build a single styled token from a string + style flags. Wraps innermost-out
# so the on-the-wire nesting matches CSS-style cascade ordering: span > u >
# strong > em > text.
function _tok(s::AbstractString; bold=false, italic=false, underline=false, color=nothing)
    n = String(s)
    italic    && (n = h.em(n))
    bold      && (n = h.strong(n))
    underline && (n = h.u(n))
    color === nothing || (n = sem.underlined(n; color))
    n
end
_tok_ident(name::Symbol, color_map) =
    _tok(string(name); color=get(color_map, name, nothing))

function _build_sig_arg(a, color_map)
    # Use Any[] — recursive calls mix element types (`:colored` from
    # `_tok_ident`, plain Strings from `_tok` with no styling, `:em` from
    # `_tok(...; italic=true)`), and a typed literal would lock to whichever
    # came first.
    if a isa Symbol
        Any[_tok_ident(a, color_map)]
    elseif Meta.isexpr(a, :kw)
        nodes = _build_sig_arg(a.args[1], color_map)
        push!(nodes, _tok("=" * _print_struct_short(a.args[2]); italic=true))
        nodes
    elseif Meta.isexpr(a, :(::))
        if length(a.args) == 1
            Any[_tok("::" * string(a.args[1]); italic=true)]
        else
            nodes = _build_sig_arg(a.args[1], color_map)
            push!(nodes, _tok("::" * _print_struct_short(a.args[2]); italic=true))
            nodes
        end
    else
        Any[_tok(_print_struct_short(a))]
    end
end

function _signature_nodes(indices, color_map)
    isempty(indices) && return Any[]
    out = Any[_tok("(")]
    pos = []; kw = []
    for idx in indices
        Meta.isexpr(idx, :parameters) ? append!(kw, idx.args) : push!(pos, idx)
    end
    for (i, a) in enumerate(pos)
        i == 1 || push!(out, _tok(", "))
        append!(out, _build_sig_arg(a, color_map))
    end
    if !isempty(kw)
        push!(out, _tok("; "))
        for (i, a) in enumerate(kw)
            i == 1 || push!(out, _tok(", "))
            append!(out, _build_sig_arg(a, color_map))
        end
    end
    push!(out, _tok(")"))
    out
end

function _dep_nodes(dep, color_map)
    dep === nothing && return Any[]
    out = Any[_tok("  [")]
    if dep[1] === :none
        push!(out, _tok("no callers in tree"; italic=true))
    else
        push!(out, _tok("⊆ {"))
        for (i, n) in enumerate(dep[2])
            i == 1 || push!(out, _tok(", "))
            push!(out, _tok_ident(n, color_map))
        end
        push!(out, _tok("}"))
    end
    push!(out, _tok("]"))
    out
end

function _prop_nodes(route_tag::String, cached::Bool, name::Symbol,
                     indices, dep, color_map)
    out = Any[]
    isempty(route_tag) || push!(out, _tok(route_tag; bold=true, italic=true))
    cached && push!(out, _tok("@cached "; bold=true, italic=true))
    push!(out, _tok(string(name)))
    append!(out, _signature_nodes(indices, color_map))
    append!(out, _dep_nodes(dep, color_map))
    out
end

# Build the lint index — `Dict{(Type, Union{Symbol,Nothing}), Vector{LintMessage}}` —
# from a flat lint list. `_build_section` looks up `(T, prop_name)` for IP-level
# annotations and `(T, nothing)` for struct-level ones.
function _build_lint_index(msgs::Vector{LintMessage})
    idx = Dict{Tuple{Type,Union{Symbol,Nothing}}, Vector{LintMessage}}()
    for m in msgs
        push!(get!(idx, (m.type, m.prop), LintMessage[]), m)
    end
    idx
end

# Build a `Semantic{:lint}` node for one LintMessage. The severity attribute
# drives format-specific rendering (color/icon).
_lint_node(msg::LintMessage) =
    sem.lint(msg.short; severity=msg.severity)

function _build_section(T::Type, header;
                        max_depth, types_in_tree, parent_map, color_map, lint_index, visited)
    header === nothing && (header = sem.line(_tok(string(nameof(T)); bold=true)))
    body = Any[]
    if T in visited
        push!(body, sem.line(_tok("(cycle)"; italic=true)))
        return sem.section(body...; header)
    end
    push!(visited, T)

    # Struct-level lints (prop=nothing) emitted as their own lines after the header.
    for msg in get(lint_index, (T, nothing), LintMessage[])
        push!(body, sem.line(_lint_node(msg)))
    end

    fixed = filter(n -> n !== :cache, collect(fieldnames(T)))
    if !isempty(fixed)
        toks = Any[_tok("fields: "; italic=true)]
        for (i, f) in enumerate(fixed)
            i == 1 || push!(toks, _tok(", "))
            push!(toks, _tok_ident(f, color_map))
        end
        push!(body, sem.line(toks...))
    end

    params = _print_struct_param_names(T)
    if !isempty(params)
        toks = Any[_tok("@param: "; italic=true)]
        for (i, p) in enumerate(params)
            i == 1 || push!(toks, _tok(", "))
            push!(toks, _tok_ident(p, color_map))
        end
        push!(body, sem.line(toks...))
    end

    props = try meta(T) catch; nothing end
    if props !== nothing
        for name in sort!(collect(keys(props)))
            _print_struct_skip(T, name) && continue
            info = props[name]
            info.rhs === nothing && continue
            _print_struct_is_forwarded(info.rhs) && continue

            nested = _walk_nested_type(T, name)
            route_tag = ""
            for m in info.macros
                if m in _PRINT_STRUCT_ROUTE_MACROS
                    route_tag = String(m) * " "
                    break
                end
            end
            cached = Symbol("@cached") in info.macros
            dep = info.indexed ?
                _print_struct_worst_case(types_in_tree, parent_map, T, name, info) :
                nothing
            nodes = _prop_nodes(route_tag, cached, name, info.indices, dep, color_map)
            prop_lints = get(lint_index, (T, name), LintMessage[])

            if nested !== nothing && max_depth > 0
                push!(nodes, _tok(" = "))
                push!(nodes, _tok(string(nameof(nested)); bold=true))
                nested_sec = _build_section(nested, sem.line(nodes...);
                    max_depth=max_depth-1, types_in_tree, parent_map, color_map,
                    lint_index, visited=copy(visited))
                push!(body, nested_sec)
            else
                push!(body, sem.line(nodes...))
            end
            # One line per lint message, after the IP's line/section.
            for msg in prop_lints
                push!(body, sem.line(_lint_node(msg)))
            end
        end
    end
    sem.section(body...; header)
end

function _build_structure(T::Type;
                          max_depth=typemax(Int),
                          types_in_tree=_all_types_in_tree(T),
                          parent_map=_build_parent_map(T),
                          color_map=_build_color_map(T),
                          lint_index=_build_lint_index(analyze_structure(T)))
    sec = _build_section(T, nothing; max_depth, types_in_tree, parent_map, color_map,
                         lint_index, visited=Set{Type}())
    h.pre(sec; class="do-structure")
end

# === Rendering via Base.show / MIME ===========================================

# Parse `#rrggbb` → (R, G, B). Used for the terminal's truecolor escape.
function _hex_to_rgb(hex::AbstractString)
    @assert length(hex) == 7 && hex[1] == '#' "expected #rrggbb, got $hex"
    parse(Int, hex[2:3], base=16),
    parse(Int, hex[4:5], base=16),
    parse(Int, hex[6:7], base=16)
end
_html_escape(io::IO, s::AbstractString) = replace(io, s,
    '&'  => "&amp;",
    '<'  => "&lt;",
    '>'  => "&gt;",
    '"'  => "&quot;",
    '\'' => "&#39;")
_html_escape(io::IO, x) = _html_escape(io, string(x))

# --- Generic content emission (used by all formats) ---
# Content is always a Tuple of items — typically Strings (text leaves) or
# Nodes (children). Iterate and dispatch each via `_show_one`.
_show_content(io, m, content::Tuple) = for c in content; _show_one(io, m, c) end
_show_one(io, m, n::AbstractNode) = show(io, m, n)
_show_one(io, ::MIME"text/html", s::AbstractString) = _html_escape(io, s)
_show_one(io, m, s::AbstractString) = print(io, s)

# --- Show dispatch via `_show_node` ----------------------------------------
# Every Base.show on an AbstractNode delegates to `_show_node`. Inside
# `_show_node` there are no Base stdlib methods to disambiguate against, so
# per-tag overrides on generic MIME work without the per-(MIME, Tag) bloat
# we'd otherwise need to break Base's text/plain ambiguity.
Base.show(io::IO, m::MIME"text/plain",    n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, m::MIME"text/markdown", n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, m::MIME"text/html",     n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, n::AbstractNode) = _show_node(io, MIME"text/plain"(), n)

# --- Defaults ---

# Node text/plain & text/markdown: emit content, no wrapping.
_show_node(io::IO, m::MIME"text/plain",    n::Node) = _show_content(io, m, n.content)
_show_node(io::IO, m::MIME"text/markdown", n::Node) = _show_content(io, m, n.content)

# Node text/html: <tag attrs>content</tag> — the only format that needs the
# tag in the output.
function _show_node(io::IO, m::MIME"text/html", n::Node{Tag}) where {Tag}
    print(io, "<", Tag)
    for (k, v) in pairs(n.attributes)
        v === nothing && continue
        print(io, " ", k, "=\"")
        _html_escape(io, v)
        print(io, "\"")
    end
    print(io, ">")
    _show_content(io, m, n.content)
    print(io, "</", Tag, ">")
end

# Semantic default: emit content with no wrapping in every format. Per-tag
# overrides on `_show_node(io, ::MIME, ::Semantic{:tag})` add format-specific
# behavior; thanks to the `_show_node` indirection, one method covers all
# three MIMEs without ambiguity.
_show_node(io::IO, m::MIME, n::Semantic) = _show_content(io, m, n.content)

# --- Tag-specific overrides ------------------------------------------------

# Inline style wrappers for terminal — emit ANSI start/end around content.
function _ansi_wrap(io, m, n, on, off)
    color = get(io, :color, false)
    color && print(io, on)
    _show_content(io, m, n.content)
    color && print(io, off)
end
_show_node(io::IO, m::MIME"text/plain", n::Node{:strong}) = _ansi_wrap(io, m, n, "\e[1m", "\e[22m")
_show_node(io::IO, m::MIME"text/plain", n::Node{:em})     = _ansi_wrap(io, m, n, "\e[3m", "\e[23m")
_show_node(io::IO, m::MIME"text/plain", n::Node{:u})      = _ansi_wrap(io, m, n, "\e[4m", "\e[24m")

function _show_node(io::IO, m::MIME"text/markdown", n::Node{:strong})
    print(io, "**"); _show_content(io, m, n.content); print(io, "**")
end
function _show_node(io::IO, m::MIME"text/markdown", n::Node{:em})
    print(io, "*"); _show_content(io, m, n.content); print(io, "*")
end

# `:colored` (Semantic) — content with the foreground in the given color.
# Used for emphasis where the whole token should pop (lint warnings).
function _show_node(io::IO, m::MIME"text/plain", n::Semantic{:colored})
    r, g, b = _hex_to_rgb(n.attributes.color)
    _ansi_wrap(io, m, n, "\e[38;2;$r;$g;$(b)m", "\e[39m")
end
function _show_node(io::IO, m::MIME"text/html", n::Semantic{:colored})
    show(io, m, Node(:span, n.content...; style="color:$(n.attributes.color)"))
end

# `:underlined` (Semantic) — default-color text with a thick colored
# underline. Used for bound identities so the bound hue marks identity
# without dominating the text. Terminal: ANSI `\e[4m` (underline on) +
# `\e[58;2;R;G;Bm` (truecolor underline color). HTML: `text-decoration:
# underline` + `text-decoration-color` + `text-decoration-thickness:2px`.
function _show_node(io::IO, m::MIME"text/plain", n::Semantic{:underlined})
    r, g, b = _hex_to_rgb(n.attributes.color)
    _ansi_wrap(io, m, n, "\e[4m\e[58;2;$r;$g;$(b)m", "\e[59m\e[24m")
end
function _show_node(io::IO, m::MIME"text/html", n::Semantic{:underlined})
    show(io, m, Node(:span, n.content...;
        style="text-decoration:underline; text-decoration-color:$(n.attributes.color); text-decoration-thickness:2px; text-underline-offset:2px"))
end

# `:line` (Semantic) — indent + content + newline. One method covers all
# three formats thanks to the `_show_node` indirection.
function _show_node(io::IO, m::MIME, n::Semantic{:line})
    print(io, "  "^get(io, :do_struct_depth, 0))
    _show_content(io, m, n.content)
    println(io)
end

# `:section` (Semantic) — render header at current depth, content one level
# deeper.
function _show_node(io::IO, m::MIME, n::Semantic{:section})
    hdr = get(n.attributes, :header, nothing)
    hdr === nothing || show(io, m, hdr)
    depth = get(io, :do_struct_depth, 0)
    body_io = IOContext(io, :do_struct_depth => hdr === nothing ? depth : depth + 1)
    _show_content(body_io, m, n.content)
end

# `:pre` (Node, real HTML element) — markdown fences. Terminal and HTML use
# the generic Node defaults (just-content / `<pre class=…>…</pre>`).
function _show_node(io::IO, m::MIME"text/markdown", n::Node{:pre})
    println(io, "```")
    _show_content(io, m, n.content)
    println(io, "```")
end

# `:lint` (Semantic) — bold + colored severity icon + message. Composes the
# existing `Node{:strong}` (bold) with `Semantic{:colored}` (bound palette
# color machinery) — no per-format rendering code here. Colors are muted
# brick / ochre that read on light and dark backgrounds.
function _show_node(io::IO, m::MIME, n::Semantic{:lint})
    icon  = n.attributes.severity === :error ? "✗"       : "⚠"
    color = n.attributes.severity === :error ? "#922b21" : "#b7791f"
    show(io, m, sem.colored(h.strong(icon, " ", n.content...); color))
end

# === Public API ===============================================================

"""    structure(T::Type; max_depth=typemax(Int)) -> Node{:pre}

Build a target-agnostic DOM-ish representation of `T`'s DO/HTMXO tree. The
root is a `Node{:pre}` so it renders as `<pre class="do-structure">…</pre>`
in HTML, fenced ` ``` ` blocks in markdown, and bare indented text in the
terminal. `display(s)` picks the right MIME for the active display.
"""
structure(T::Type; max_depth::Int=typemax(Int)) =
    _build_structure(T; max_depth)

"""    print_structure([io::IO=stdout,] T::Type; max_depth=typemax(Int))

Convenience: `show(io, MIME"text/plain"(), structure(T))`. For markdown or
HTML output, build the structure with `structure(T)` and `show` it under
the desired MIME.
"""
print_structure(T::Type; kwargs...) = print_structure(stdout, T; kwargs...)
print_structure(io::IO, T::Type; max_depth::Int=typemax(Int)) =
    show(io, MIME"text/plain"(), structure(T; max_depth))

export print_structure, structure

end