"""
    DynamicObjects

Provides the `@dynamicstruct` macro for defining structs with lazily computed,
optionally disk-cached properties.

# Exports
- [`@dynamicstruct`](@ref): Define a struct with computed/cached properties.
- [`@cache_status`](@ref): Get the disk-cache status of a property (`:unstarted`, `:started`, `:ready`).
- [`@is_cached`](@ref): Check whether a property's disk cache is ready.
- [`@cache_path`](@ref): Get the file path used for a property's disk cache.
- [`@memo!`](@ref): Wrap a call site so `IndexableProperty` callees are cached.
- [`memoize!`](@ref): Explicit cached call into an `IndexableProperty`.
- [`maybememoize!`](@ref): Dispatch helper behind `@memo!`; cached on IPs, plain call otherwise.
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
export @dynamicstruct, @cache_status, @is_cached, @cache_path, @clear_cache!, @persist, @memo!, @dynamic_progress, memoize!, maybememoize!, maybeprogress!, noprogress, remake, fetchindex, fetchindex!, getstatus, PropertyComputationError, unwrap_error, entries, cached_entries, clear_all_caches!, clear_mem_caches!, clear_disk_caches!, PersistentSet, LazyPersistentDict, KeyTracker, SharedFileTracker, PerPodFileTracker, NoKeyTracker, key_tracker, record!, load_keys, cancel!, cancel_all!, set_cache_budget!, cache_budget, cache_bytes, cache_entries, subtree_bytes, subtree_budget, last_evicted, is_pinnable_value

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

# Disk-load reporting hook — TreebarsExt overrides to set the substatus
# message to "from disk: <size>". Default no-op. Called from
# `_computeproperty` just before `Serialization.deserialize` when the cache
# is `:ready` so the user sees something flash up for big-file loads
# instead of a silent stall.
_report_disk_load!(s, cache_path, size_bytes) = nothing
_report_disk_load!(::Nothing, _, _) = nothing

# Format a byte count as "1.2 MB" / "850 KB" / "42 B" for human-readable
# progress messages.
function _format_size(n::Integer)
    n < 1024            && return "$n B"
    n < 1024^2          && return string(round(n / 1024,        digits=1), " KB")
    n < 1024^3          && return string(round(n / 1024^2,      digits=1), " MB")
    string(round(n / 1024^3, digits=1), " GB")
end

"""
    PropertyCache{D}(cache, sizes, pinned, bytes, budget, parent_pc, owner_ref, last_evicted)

Per-DO-instance memoization cache for `@dynamicstruct` properties. `cache::D` is
the underlying `Dict` (`:serial`) or `ThreadsafeDict` (`:parallel`) holding the
memoized values for non-indexed properties.

The remaining fields back the LRU/eviction layer:
- `sizes` — bytes recorded at store for each `(name, args_key)` entry; written
  once at store via `_summarysize_capped`, never re-measured on hit.
- `pinned` — entries that the eviction loop must skip (auto-pinned via
  `is_pinnable_value` at store; never evicted).
- `bytes` — atomic running subtotal of `sizes` for THIS cache only (no
  recursion). Subtree totals are tracked at the budget-holder via push-up.
- `budget` — `0` = not a budget-holder, push deltas up to parent; `>0` = this
  PropertyCache is the budget-holder for its subtree.
- `parent_pc` — lazily resolved `WeakRef` to the parent DO's PropertyCache, used
  for push-up traversal.
- `owner_ref` — `WeakRef` to the owning DO instance, set right after `new(...)`
  in the `@dynamicstruct` constructor via `_link_owner!`. Lets the eviction
  walker find `__parent__` without plumbing the DO through every `get!`.
- `last_evicted` — single-slot history on the budget-holder; `Tuple{Symbol,Any}`
  of the most recent evicted entry, or `nothing`. Used by `last_evicted(obj)`.
"""
struct PropertyCache{D<:AbstractDict{Symbol,Any}}
    cache::D
    sizes::Dict{Tuple{Symbol,Any}, Int}
    pinned::Set{Tuple{Symbol,Any}}
    bytes::Threads.Atomic{Int}
    budget::Threads.Atomic{Int}
    parent_pc::Base.RefValue{Any}    # Union{Nothing, WeakRef} — lazily resolved
    owner_ref::Base.RefValue{Any}    # Union{Nothing, WeakRef} — set via _link_owner!
    last_evicted::Base.RefValue{Any} # Union{Nothing, Tuple{Symbol,Any}}
    lru_order::Vector{Tuple{Symbol,Any}}  # access-order (MRU-last); local to this PC
    descendants::Vector{WeakRef}     # populated on budget-holders only; descendant PCs in this subtree
    lru_lock::ReentrantLock          # protects lru_order / descendants mutation
    PropertyCache(D, c::NamedTuple) = new{D{Symbol,Any}}(
        D{Symbol,Any}(pairs(c)),
        Dict{Tuple{Symbol,Any},Int}(),
        Set{Tuple{Symbol,Any}}(),
        Threads.Atomic{Int}(0),
        Threads.Atomic{Int}(0),
        Ref{Any}(nothing),
        Ref{Any}(nothing),
        Ref{Any}(nothing),
        Tuple{Symbol,Any}[],
        WeakRef[],
        ReentrantLock(),
    )
end

# Owner-link injection. Called by `@dynamicstruct` lowering right after
# `new(...)` constructs the instance so the eviction walker can find
# `__parent__` from any PropertyCache without plumbing the owning DO through
# every `get!`. Safe to call repeatedly (idempotent after first set).
#
# Also eagerly resolves `parent_pc`: `__parent__` is passed as a kwarg by the
# child-constructor lowering (see ~L3574) and therefore lives as an entry in
# `pc.cache` immediately after construction, NOT as a struct field. Resolving
# it here avoids any later `owner.__parent__` / `getfield(owner, :__parent__)`
# lookup at hit/store time — both are wrong (one recurses through the cache
# machinery, the other misses because `__parent__` isn't a struct slot).
function _link_owner!(pc::PropertyCache, owner)
    pc.owner_ref[] === nothing || return nothing
    pc.owner_ref[] = WeakRef(owner)
    parent_obj = get(pc.cache, :__parent__, nothing)
    if parent_obj !== nothing && parent_obj !== owner
        parent_pc = getfield(parent_obj, :cache)
        parent_pc isa PropertyCache && (pc.parent_pc[] = WeakRef(parent_pc))
    end
    nothing
end
_link_owner!(_, _) = nothing  # tolerate non-PropertyCache (e.g. unit tests / fixed-only structs)

# --- Native-handle detection (D1 resolution: shallow direct-field check) ---

_is_handle_field_type(::Type{<:Ptr}) = true
_is_handle_field_type(::Type{<:IO}) = true
_is_handle_field_type(::Type{<:Base.RefValue}) = true
_is_handle_field_type(::Type{<:Threads.AbstractLock}) = true
_is_handle_field_type(::Type) = false

"""
    is_pinnable_value(::Type{T}) -> Bool
    is_pinnable_value(v) -> Bool

Whether values of type `T` (or value `v`) should be auto-pinned in the cache —
i.e. never evicted by the LRU layer. The default implementation does a shallow
direct-field check: returns `true` iff any of `fieldtypes(T)` is `Ptr`, `IO`,
`Base.RefValue`, `Threads.AbstractLock`, or a subtype thereof.

Pure-data types like `Array`, `Dict`, `DataFrame`, `String`, `Vector{Any}` are
NOT pinned by default (no direct pointer field) and remain eviction
candidates. Wrapper types whose direct fields are pure data but which
transitively hold a native resource should add a one-line override:

```julia
DynamicObjects.is_pinnable_value(::Type{<:MyBridgeHandle}) = true
```
"""
# Bounded type-level walk: true iff T (or any of its transitive field
# types, the eltype of an array, or key/value type of a dict) is a
# native-handle type. Depth cap (8) terminates pathological types and
# any mutable cycles. Catches `Tuple{BridgeStanModel, X}` where the
# direct field type isn't itself a Ptr/IO but contains one.
function _type_has_handle(::Type{T}, depth::Int=8) where {T}
    _is_handle_field_type(T) && return true
    depth <= 0 && return false
    isbitstype(T) && return false
    # Abstract / Union / Any-typed slots: we can't see inside them at the
    # type level. Treat as "no handle" so eviction stays effective; users
    # whose Any-typed cache values transitively hold a native resource
    # should add an override for their wrapper type.
    isconcretetype(T) || return false
    T <: Type && return false  # types-of-types aren't user data
    if T <: AbstractArray
        return _type_has_handle(eltype(T), depth - 1)
    end
    if T <: AbstractDict
        return _type_has_handle(keytype(T), depth - 1) ||
               _type_has_handle(valtype(T), depth - 1)
    end
    for ft in fieldtypes(T)
        _type_has_handle(ft, depth - 1) && return true
    end
    false
end

is_pinnable_value(::Type{T}) where {T} = _type_has_handle(T)
is_pinnable_value(v) = is_pinnable_value(typeof(v))

# --- Size measurement (D5 resolution: bounded recursion-depth walker) ---

"""
    _summarysize_capped(v, depth=8) -> Int

Approximate byte size of `v` with a bounded recursion depth. Walks the
common container shapes (`AbstractArray` of non-isbits elements,
`AbstractDict`, `Tuple`, generic struct fields) up to `depth` levels and
falls back to `sizeof(typeof(v))` for the unwalked remainder.

Measured once at store and stored in `PropertyCache.sizes`; never re-measured
on hit. This is intentionally an approximation — exact byte accounting under
`Base.summarysize` is non-trivial to bound (no depth knob exposed) and the
LRU layer only needs eviction-order signal, not accuracy. Pathological inputs
(deep Vega-Lite spec Dicts, nested Stan draw matrices) stop walking at
`depth` and contribute their nominal type-shell size instead of a full walk.
"""
# --- Push-up bookkeeping (D6 sync-on-store; eviction trigger lands next commit) ---

# Resolve and cache the parent PropertyCache via the owning DO's __parent__.
# Called from the cache write path (post-`get!` closure) which runs OUTSIDE
# the cache lock — see Base.get!(::AbstractThreadsafeDict, ...) below at the
# spawn task body — so triggering `__parent__` resolution here can recurse
# into the cache machinery without deadlocking on a held lock.
# Parent PropertyCache lookup. `parent_pc` is resolved eagerly by
# `_link_owner!` from the `:__parent__` kwarg stored in `pc.cache` at
# construction time, so this is just a cheap WeakRef read.
# Returns `nothing` for roots, GC'd parents, or PCs whose owner wasn't
# linked (e.g. fixed-only structs that never call `_link_owner!`).
function _parent_pc(pc::PropertyCache)
    cached = pc.parent_pc[]
    cached isa WeakRef || return nothing
    val = cached.value
    val isa PropertyCache ? val : nothing
end

# Opt-in gate: bookkeeping (sizing, LRU ordering, push-up, descendant
# registration) is entirely skipped unless some PC in the parent chain
# has a budget set via `set_cache_budget!`. Without this, every cache
# store would do O(tree-depth + value-size) work for no eviction benefit.
# Stores that happen before `set_cache_budget!` is called won't count
# toward the budget — acceptable: callers are expected to set the budget
# early in startup, before significant cache traffic.
function _any_budget_in_chain(pc::PropertyCache)
    cur::Union{PropertyCache,Nothing} = pc
    while cur !== nothing
        cur.budget[] > 0 && return true
        cur = _parent_pc(cur)
    end
    false
end

# Walk __parent__ chain bumping each PropertyCache's local `bytes` by delta.
# Registers `originating_pc` as a descendant at every budget-holder encountered
# (so push-down eviction can enumerate the subtree). O(tree-depth) per call.
# Returns the nearest budget-holder (if any) so the caller can fire eviction.
function _push_delta_up!(originating_pc::PropertyCache, delta::Int)
    first_holder = nothing
    parent_pc = _parent_pc(originating_pc)
    while parent_pc !== nothing
        Threads.atomic_add!(parent_pc.bytes, delta)
        if parent_pc.budget[] > 0
            _register_descendant!(parent_pc, originating_pc)
            first_holder === nothing && (first_holder = parent_pc)
        end
        parent_pc = _parent_pc(parent_pc)
    end
    first_holder
end

# Add `descendant_pc` to `holder`'s descendants list if not already present.
# WeakRef-based so dead descendants drop out naturally on GC; the eviction
# walker skips dead refs.
function _register_descendant!(holder::PropertyCache, descendant_pc::PropertyCache)
    lock(holder.lru_lock) do
        for wref in holder.descendants
            wref.value === descendant_pc && return
        end
        push!(holder.descendants, WeakRef(descendant_pc))
    end
    nothing
end

# Move `key` to MRU position in `pc.lru_order`. Called on cache hits.
function _touch_lru_pc!(pc::PropertyCache, key::Tuple{Symbol,Any})
    lock(pc.lru_lock) do
        idx = findfirst(==(key), pc.lru_order)
        if idx !== nothing
            idx == length(pc.lru_order) && return
            deleteat!(pc.lru_order, idx)
        end
        push!(pc.lru_order, key)
    end
    nothing
end

# Hit recorder — called when a `get!` resolves to an existing entry (no
# user callback fired). Updates LRU access order so eviction picks oldest-
# accessed first, not oldest-stored.
function _record_pc_hit!(pc::PropertyCache, name::Symbol, args_key)
    _any_budget_in_chain(pc) || return
    _touch_lru_pc!(pc, (name, args_key))
end

# Called on cache miss (after the body returns `v`), inside the user-callback
# closure that runs OUTSIDE the cache lock per Base.get!(::AbstractThreadsafeDict)
# spawn pattern. Records size, pin status, LRU order, propagates the byte
# delta up the __parent__ chain, and fires eviction if a budget-holder is
# over budget.
function _record_pc_store!(pc::PropertyCache, name::Symbol, args_key, v)
    _any_budget_in_chain(pc) || return
    # If v is a DO (has a PropertyCache) that wasn't constructed with an
    # explicit __parent__ kwarg, wire its parent_pc to us now — this is the
    # moment we know v's parent. Without this, IPs that return a DO via a
    # plain constructor call (no @include lowering) end up with a child PC
    # that has no parent link, so push-up from the child can't reach the
    # budget-holder. Only fills `nothing` slots; explicit __parent__ still wins.
    if hasfield(typeof(v), :cache)
        v_cache = getfield(v, :cache)
        if v_cache isa PropertyCache && v_cache.parent_pc[] === nothing
            v_cache.parent_pc[] = WeakRef(pc)
        end
    end
    key = (name, args_key)
    sz = _summarysize_capped(v)
    pinnable = is_pinnable_value(v)
    Threads.atomic_add!(pc.bytes, sz)
    # Single critical section for pc.sizes / pc.pinned / pc.lru_order — all
    # three are plain Base containers that MUST NOT be mutated concurrently
    # (Base.Dict rehash-during-insert under threads is a textbook SIGABRT
    # vector). Same `lru_lock` serves all three; cheap, simple.
    lock(pc.lru_lock) do
        pc.sizes[key] = sz
        pinnable && push!(pc.pinned, key)
        # If already in order (shouldn't normally happen on store, but defensive
        # in case of overwrite via setindex!), bump to MRU; else append.
        idx = findfirst(==(key), pc.lru_order)
        idx !== nothing && deleteat!(pc.lru_order, idx)
        push!(pc.lru_order, key)
    end
    # If `pc` is itself a budget-holder, also record self as descendant
    # (we never push-up to ourselves). Otherwise push-up registers us at
    # ancestor budget-holders.
    pc.budget[] > 0 && _register_descendant!(pc, pc)
    holder = _push_delta_up!(pc, sz)
    # Fire eviction if we are or are below a budget-holder. Self is checked
    # too — if pc is a budget-holder, the push-up didn't go anywhere but pc
    # itself may be over budget.
    if pc.budget[] > 0
        _maybe_evict!(pc)
    elseif holder !== nothing
        _maybe_evict!(holder)
    end
    nothing
end

# --- Push-down eviction (D6 sync-on-store + D3 cost-aware bias) ---

# Determine whether a `(name, args_key)` slot on PropertyCache `pc` corresponds
# to a `@cached` property. Looks up `meta(typeof(owner))` for the property's
# info bag and checks `info.macros`.
function _is_cached_slot(pc::PropertyCache, name::Symbol)
    owner_ref = pc.owner_ref[]
    owner_ref isa WeakRef || return false
    owner = owner_ref.value
    owner === nothing && return false
    info = metafirst(typeof(owner), name)
    info === nothing && return false
    Symbol("@cached") in info.macros
end

# Check whether `(name, args_key)` is currently the target of an in-flight
# Task somewhere. For bare-prop slots, that's `pc.cache.tasks[name]`. For IP
# slots, we'd need to dig into the IP's subcache — left for v2 (the bare-prop
# tasks check covers the common case; an IP in-flight task evict-and-recompute
# would mean wasted work but not corruption, since the cache machinery
# spawns a fresh task on the next access).
function _entry_in_flight(pc::PropertyCache, key::Tuple{Symbol,Any})
    name, args_key = key
    pc.cache isa AbstractThreadsafeDict || return false
    if args_key === ()
        return lock(pc.cache.lock) do; haskey(pc.cache.tasks, name); end
    end
    # IP slot — look up the IP wrapper in pc.cache (its own lock), then
    # peek at the IP's subcache.tasks under that subcache's lock.
    ip = get(pc.cache, name, nothing)
    ip isa IndexableProperty || return false
    ip.cache isa AbstractThreadsafeDict || return false
    lock(ip.cache.lock) do; haskey(ip.cache.tasks, args_key); end
end

# Single eviction step: pop the entry, update sizes/bytes/lru_order, push
# the negative delta up the parent chain (so the budget-holder's `bytes`
# decreases too).
function _evict_entry!(pc::PropertyCache, key::Tuple{Symbol,Any})
    name, args_key = key
    # Race-safe claim: pop sizes + pinned + lru_order in one critical
    # section. A second concurrent evictor for the same key gets sz==0
    # from pop! and bails — without this, both would atomic_sub by the
    # same sz, drifting pc.bytes negative.
    sz = lock(pc.lru_lock) do
        s = pop!(pc.sizes, key, 0)
        delete!(pc.pinned, key)
        idx = findfirst(==(key), pc.lru_order)
        idx !== nothing && deleteat!(pc.lru_order, idx)
        s
    end
    sz > 0 || return  # already evicted by another caller
    if args_key === ()
        # Bare-prop slot. Use the cache's pop! (delegates through
        # AbstractThreadsafeDict if applicable, with task cleanup).
        haskey(pc.cache, name) && pop!(pc.cache, name)
    else
        # IP slot. The actual storage is on the IP's per-property subcache,
        # not pc.cache. Reach it via the owning DO's IP wrapper.
        owner_ref = pc.owner_ref[]
        if owner_ref isa WeakRef && owner_ref.value !== nothing
            # Read the IP wrapper from pc.cache[name] (cached IP wrapper).
            if haskey(pc.cache, name)
                ip = pc.cache[name]
                ip isa IndexableProperty && haskey(ip.cache, args_key) && pop!(ip.cache, args_key)
            end
        end
    end
    Threads.atomic_sub!(pc.bytes, sz)
    # Push -sz up to all ancestor budget-holders
    parent_pc = _parent_pc(pc)
    while parent_pc !== nothing
        Threads.atomic_sub!(parent_pc.bytes, sz)
        parent_pc = _parent_pc(parent_pc)
    end
    nothing
end

# Gather every (pc, key, is_cached, position) tuple eligible for eviction
# from holder's subtree, skipping pinned and in-flight entries.
function _gather_eviction_candidates(holder::PropertyCache)
    out = Vector{Tuple{PropertyCache, Tuple{Symbol,Any}, Bool, Int}}()
    visited = Set{PropertyCache}()
    # Walk holder + descendants
    pcs = lock(holder.lru_lock) do
        # Take a snapshot of descendants under the lock; live refs only.
        live = PropertyCache[holder]
        for wref in holder.descendants
            pc = wref.value
            pc isa PropertyCache && pc !== holder && push!(live, pc)
        end
        live
    end
    for pc in pcs
        pc in visited && continue
        push!(visited, pc)
        lock(pc.lru_lock) do
            for (i, key) in enumerate(pc.lru_order)
                key in pc.pinned && continue
                _entry_in_flight(pc, key) && continue
                push!(out, (pc, key, _is_cached_slot(pc, key[1]), i))
            end
        end
    end
    out
end

# Main eviction loop. Called when a store crosses the budget threshold on
# `holder`. Runs synchronously inside the user-callback closure of the
# triggering store — outside any cache lock — so the lock-hold profile is
# unchanged from today's `_on_store!` semantics.
function _maybe_evict!(holder::PropertyCache)
    holder.budget[] <= 0 && return  # not a budget-holder
    holder.bytes[] <= holder.budget[] && return  # under budget
    candidates = _gather_eviction_candidates(holder)
    # Sort: @cached slots first (cheap re-deserialize wins), then by LRU
    # position (oldest-accessed first within each tier).
    sort!(candidates, by = c -> (c[3] ? 0 : 1, c[4]))
    for (pc, key, _, _) in candidates
        holder.bytes[] <= holder.budget[] && break
        _evict_entry!(pc, key)
        holder.last_evicted[] = key
    end
    nothing
end

_safe_typesize(::Type{T}) where {T} = isbitstype(T) ? sizeof(T) : 0

# Skip Julia-internal "infrastructure" objects whose memory is shared
# globally and not user-controllable; descending into them also risks
# UndefRefError / runaway recursion via Type<->MethodTable<->Vector{Any}
# back-edges.
_skip_summarysize(v) = v isa Type || v isa Function || v isa Module ||
    v isa Task || v isa Core.MethodTable || v isa Method ||
    v isa Core.CodeInstance || v isa Core.MethodInstance

# Subtree-root boundary: a nested DynamicObject (anything with a
# `__cache__::PropertyCache` field) is already tracked by its own PC
# via push-up bookkeeping, an IndexableProperty's entries are charged
# at memoize-store time, and a PropertyCache is itself the tracker.
# Descending into them is both double-counting AND O(tree) per store
# because IPs hold back-references to their owner DO — without this
# boundary, every store walks the whole tree (terminating only via
# the depth/visited cap, but pathologically slow).
_is_subtree_root(v) = v isa PropertyCache || v isa IndexableProperty ||
    hasfield(typeof(v), :__cache__)

function _summarysize_capped(v, depth::Int=8, visited::Base.IdSet=Base.IdSet())
    _skip_summarysize(v) && return 0
    v in visited && return 0
    !isbits(v) && push!(visited, v)
    if v isa String
        return sizeof(v)
    elseif v isa Symbol
        return ncodeunits(string(v))
    end
    n = _safe_typesize(typeof(v))
    _is_subtree_root(v) && return n
    depth <= 0 && return n
    if v isa AbstractArray && !isbitstype(eltype(v))
        for i in eachindex(v)
            isassigned(v, i) || continue
            n += _summarysize_capped(@inbounds(v[i]), depth - 1, visited)
        end
    elseif v isa AbstractArray
        # isbits eltype — array is contiguous; one bulk charge.
        n = sizeof(v)
    elseif v isa AbstractDict
        for (k, val) in v
            n += _summarysize_capped(k, depth - 1, visited)
            n += _summarysize_capped(val, depth - 1, visited)
        end
    elseif v isa Tuple || v isa NamedTuple
        for elt in v
            n += _summarysize_capped(elt, depth - 1, visited)
        end
    elseif !isbits(v)
        for i in 1:nfields(v)
            isdefined(v, i) || continue
            n += _summarysize_capped(getfield(v, i), depth - 1, visited)
        end
    end
    n
end

# Bare-prop path: forwards `substatus` so the inner `ThreadsafeDict.get!`
# creates a Treebars node + lifecycle just like it does for IPs. Closure
# takes `s` (the substatus the spawn wrapper passes) so the body can
# attach work to it. PropertyCache caches only the one-shot per-name
# IP-wrapper / first-compute result (no kwargs in the cache key);
# kwargs-keyed caching is the IP wrapper's job (`memoize!`).
# `getorcomputeproperty` routes around this layer when indices/kwargs are
# present (see ~L1109), so this overload only needs to handle the
# bare-name case.
Base.get!(f::Function, c::PropertyCache, key; substatus=nothing, kwargs...) = begin
    # Hit-vs-miss detection: race-prone but LRU ordering is approximate —
    # a wrong move-to-back has no correctness impact, just suboptimal
    # eviction order. The store path is correct regardless.
    was_hit = haskey(c.cache, key)
    rv = get!(c.cache, key; substatus) do s
        v = f(s)
        _record_pc_store!(c, key, (), v)
        v
    end
    was_hit && _record_pc_hit!(c, key, ())
    rv
end
Base.get!(f::Function, ::PropertyCache, key, indices...; kwargs...) = f(nothing)
Base.setindex!(c::PropertyCache, args...) = setindex!(c.cache, args...)
Base.show(io::IO, pc::PropertyCache) = print(io, "PropertyCache(",
    length(pc.cache), " properties, ", _format_size(pc.bytes[]),
    pc.budget[] > 0 ? string(" / budget ", _format_size(pc.budget[])) : "",
    ")")

# --- LRU/eviction API ---

"""
    set_cache_budget!(obj, n_bytes::Integer)

Mark `obj` (a `@dynamicstruct` instance) as the cache budget-holder for its
subtree, with a budget of `n_bytes` bytes. All `@dynamicstruct` instances
hanging off `obj` via `__parent__` push their cache-byte deltas up to `obj` on
store; when the subtotal exceeds the budget, eviction runs to drain it back
under the limit. A budget of `0` disables eviction at this node (delegates up
to the next ancestor with a budget set, if any).

There is no opt-in marker on the type — any DO instance can become a
budget-holder by calling this function. Push-up walks via `__parent__` stop
at the nearest ancestor with `budget > 0`. If no ancestor in the chain has a
budget set, push-up terminates without effect; the cache behaves identically
to today (no eviction, no overhead beyond a single atomic add per store).

Typical usage in app init:
```julia
const APPDATA = AppData()
set_cache_budget!(APPDATA, parse(Int, get(ENV, "JULIA_HEAP_SIZE", "0")) ÷ 2)
```
"""
set_cache_budget!(obj, n_bytes::Integer) = (getfield(obj, :cache).budget[] = Int(n_bytes); nothing)

"""
    cache_budget(obj) -> Int

The cache budget set on `obj`'s PropertyCache (the value passed to
`set_cache_budget!`). Returns `0` if `obj` is not a budget-holder. Does NOT
walk `__parent__` — see [`subtree_budget`](@ref) for the recursive variant.
"""
cache_budget(obj) = getfield(obj, :cache).budget[]

"""
    cache_bytes(obj) -> Int

LOCAL byte subtotal of `obj`'s PropertyCache — sum of `summarysize` over the
entries memoized directly on this instance. Does NOT walk `__parent__`. For
the budget-holder's subtree total, see [`subtree_bytes`](@ref). For a
budget-holder these return the same value (the push-up sum lands here).
"""
cache_bytes(obj) = getfield(obj, :cache).bytes[]

"""
    cache_entries(obj) -> Int

Number of memoized entries currently held on `obj`'s PropertyCache (this
instance only, no recursion).
"""
cache_entries(obj) = length(getfield(obj, :cache).cache)

"""
    subtree_bytes(obj) -> Int

Total bytes in the budget-holder's subtree containing `obj`. Walks `__parent__`
upward to the nearest ancestor with `budget > 0` and returns its `bytes[]`. If
no ancestor in the chain has a budget set, falls back to `cache_bytes(obj)`.
"""
subtree_bytes(obj) = let holder = _find_budget_holder_obj(obj)
    holder === nothing ? cache_bytes(obj) : cache_bytes(holder)
end

"""
    subtree_budget(obj) -> Int

Budget of the nearest ancestor budget-holder (including `obj` itself), or `0`
if no budget is set anywhere in the chain.
"""
subtree_budget(obj) = let holder = _find_budget_holder_obj(obj)
    holder === nothing ? 0 : cache_budget(holder)
end

"""
    last_evicted(obj) -> Union{Nothing, Tuple{Symbol, Any}}

`(name, args_key)` of the most recent entry evicted from the budget-holder's
subtree containing `obj`, or `nothing` if no eviction has happened yet (or no
budget-holder in the chain). Single-slot history; the previous value is
overwritten on each new eviction.
"""
last_evicted(obj) = let holder = _find_budget_holder_obj(obj)
    holder === nothing ? nothing : getfield(holder, :cache).last_evicted[]
end

# Walks `__parent__` from `obj` upward, returning the nearest DO whose
# PropertyCache has `budget > 0`, or `nothing` if no budget-holder in the chain.
# Used by `subtree_*` and `last_evicted` getters; not exported.
function _find_budget_holder_obj(obj)
    cur = obj
    while cur !== nothing
        pc = getfield(cur, :cache)
        pc isa PropertyCache && pc.budget[] > 0 && return cur
        cur = hasproperty(cur, :__parent__) ? cur.__parent__ : nothing
    end
    nothing
end
struct IndexableProperty{N,O,D<:AbstractDict}
    o::O
    cache::D
    IndexableProperty(N,o,cache=Dict()) = new{N,typeof(o),typeof(cache)}(o, cache)
end
name(::IndexableProperty{N}) where {N} = N
Base.show(io::IO, ip::IndexableProperty{N}) where {N} = print(io, "IndexableProperty :", N, " (", ip.cache, ")")
((;o)::IndexableProperty{name})(indices...; kwargs...) where {name} =
    _computeproperty(o, name, indices...; kwargs...)
"""
    memoize!(ip::IndexableProperty, args...; kwargs...)

Cached call into an `IndexableProperty`'s per-key dict. Returns the cached
value if `(args, kwargs)` was seen before; otherwise calls `ip(args...; kwargs...)`,
stores the result, and returns it. This is the explicit, exported function
form of cached IP access — use it whenever you'd previously have written
`ip[args...]`, *especially* in kwargs-only call sites (`memoize!(ip; k=v)`)
which the legacy bracket syntax couldn't express at all (`ip[; k=v]` doesn't
parse as Julia).

For two-phase access (returning a `Task` while computing) on
`ThreadsafeDict`-backed IPs, see [`fetchindex`](@ref). Inside a
`@dynamicstruct` body, the convenience macro [`@memo!`](@ref) wraps every
call-site in `maybememoize!(callee, args...; kwargs...)` so cached IPs and
plain functions can share the same syntax.
"""
memoize!(ip::IndexableProperty{name}, args...; fetch=Base.fetch, kwargs...) where {name} = begin
    args_key = (args, (;kwargs...))
    was_hit = haskey(ip.cache, args_key)
    rv = get!(ip.cache, args_key) do
        v = ip(args...; kwargs...)
        owner_pc = getfield(ip.o, :cache)
        owner_pc isa PropertyCache && _record_pc_store!(owner_pc, name, args_key, v)
        v
    end
    if was_hit
        owner_pc = getfield(ip.o, :cache)
        owner_pc isa PropertyCache && _record_pc_hit!(owner_pc, name, args_key)
    end
    rv
end
"""
    AbstractThreadsafeDict{K,V}

Supertype for the lock-protected, task-spawning dicts that back `:parallel`
indexed properties. The concrete subtype `ThreadsafeDict`
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

const _cache_types = (;serial=Dict, parallel=ThreadsafeDict)
resolve_cache_type(s::Symbol) = get(_cache_types, s, s)
resolve_cache_type(T::Type) = T.name.wrapper
resolve_cache_type(T::UnionAll) = T

Base.length(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.cache); end
Base.haskey(c::AbstractThreadsafeDict, key) = lock(c.lock) do; haskey(c.cache, key); end
Base.get(c::AbstractThreadsafeDict, key, default) = lock(c.lock) do; get(c.cache, key, default); end
# NOTE: iteration is NOT truly thread-safe — each iterate call locks independently,
# so the dict can mutate between calls. For thread-safe iteration, use
# lock(c.lock) do ... end or entries(ip) which holds the lock for the full sweep.
Base.iterate(c::AbstractThreadsafeDict) = lock(c.lock) do; iterate(c.cache); end
Base.iterate(c::AbstractThreadsafeDict, state) = lock(c.lock) do; iterate(c.cache, state); end
Base.empty!(c::ThreadsafeDict) = (lock(c.lock) do; empty!(c.cache); empty!(c.tasks); empty!(c.status); end; c)
n_running(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.tasks); end
Base.show(io::IO, c::ThreadsafeDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeDict{", K, ",", V, "}(", length(c.cache), " cached, ", length(c.tasks), " running)")
end
memoize!(ip::IndexableProperty{name,<:Any,<:AbstractThreadsafeDict}, indices...; fetch=Base.fetch, retry_failed=true, kwargs...) where {name} = begin
    (;o, cache) = ip
    substatus_f = if name != :__substatus__ && name != :__status__
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name, indices...; __status__=root, kwargs...)
        end
    else
        nothing
    end
    args_key = (indices, (;kwargs...))
    was_hit = lock(cache.lock) do; haskey(cache.cache, args_key); end
    rv = get!(cache, args_key; fetch, substatus=substatus_f, retry_failed) do s
        # Call `_computeproperty` directly, NOT `getorcomputeproperty`:
        # the latter, when `indices` and `kwargs` are both empty AND
        # `is_indexed_property(o, name)` (we're already inside the IP wrapper,
        # so this is always true), short-circuits to return the IP wrapper
        # itself (see `getorcomputeproperty`'s IP-wrapper branch ~L1156).
        # That would cache the IP wrapper at `((), (;))` instead of running
        # the body — `@memo! o.foo()` on a 0-arg IP would never actually
        # compute anything. `_computeproperty` skips the wrapper short-circuit
        # and goes straight to the body.
        v = _computeproperty(o, name, indices...; __status__=s, kwargs...)
        # Push-up bookkeeping: record IP slot's size+pin status on the OWNING
        # PropertyCache (not the per-IP subcache `cache`). One sizes/pinned
        # dict per DO tracks both bare-prop AND IP entries, keyed by
        # `(prop_name, args_key)`.
        owner_pc = getfield(o, :cache)
        owner_pc isa PropertyCache && _record_pc_store!(owner_pc, name, args_key, v)
        v
    end
    if was_hit
        owner_pc = getfield(o, :cache)
        owner_pc isa PropertyCache && _record_pc_hit!(owner_pc, name, args_key)
    end
    rv
end
# `substatus()` is invoked OUTSIDE the cache lock. Calling it under the
# lock is unsafe: substatus factories can recurse into other DO properties
# (e.g. user-defined `_property_description` reads `o.foo`) which spawn a
# task on the SAME `c`, and that task's `lock(c.lock)` write-back blocks
# behind the lock the parent holds while fetching → deadlock.
# Slow path: do a fast-path check first; only if we genuinely need to spawn
# do we drop the lock, build `s`, and re-take the lock to install. A race
# (someone else won between phases) means we discard `s` via finalize.
Base.get!(f::Function, c::AbstractThreadsafeDict, key; fetch=Base.fetch, substatus=nothing, retry_failed=true) = begin
    fast = lock(c.lock) do
        v = get(c.cache, key, _missing_sentinel)
        if v !== _missing_sentinel
            _on_hit!(c, key)
            return (:value, v)
        end
        if retry_failed && haskey(c.tasks, key) && istaskdone(c.tasks[key]) && istaskfailed(c.tasks[key])
            pop!(c.tasks, key)
            haskey(c.status, key) && pop!(c.status, key)
        end
        haskey(c.tasks, key) && return (:task, c.tasks[key])
        nothing
    end
    if fast !== nothing
        kind, x = fast
        return kind === :value ? x : fetch(x)
    end
    # No value, no in-flight task — build substatus outside the lock.
    s = isnothing(substatus) ? nothing : substatus()
    rv = lock(c.lock) do
        v = get(c.cache, key, _missing_sentinel)
        if v !== _missing_sentinel
            _on_hit!(c, key)
            return (:lost_value, v)
        end
        if retry_failed && haskey(c.tasks, key) && istaskdone(c.tasks[key]) && istaskfailed(c.tasks[key])
            pop!(c.tasks, key)
            haskey(c.status, key) && pop!(c.status, key)
        end
        haskey(c.tasks, key) && return (:lost_task, c.tasks[key])
        if !isnothing(s)
            c.status[key] = s
        end
        task = Threads.@spawn begin
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
        c.tasks[key] = task
        return (:won, task)
    end
    kind, x = rv
    if kind === :lost_value || kind === :lost_task
        # We built `s` but didn't install it — finalize so the Treebars
        # node (if any) detaches instead of leaking.
        !isnothing(s) && _finalize_substatus!(s)
        return kind === :lost_value ? x : fetch(x)
    end
    fetch(x)
end

# Singleton sentinel so a single `get` lookup distinguishes "key absent" from
# "key present with value === nothing" without allowing collision with any
# user-stored value.
struct _Missing end
const _missing_sentinel = _Missing()

# Hooks into get! for cache bookkeeping. Now always no-ops at this layer;
# the new per-PropertyCache LRU layer handles ordering and eviction (see
# `_record_pc_store!` / `_record_pc_hit!` / `_maybe_evict!` above).
_on_hit!(::AbstractThreadsafeDict, key) = nothing
_on_store!(::AbstractThreadsafeDict, key) = nothing
_drop_order!(::AbstractThreadsafeDict, key) = nothing

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

Call `memoize!(ip, indices...; kwargs...)` with a custom `fetch` function.

For `IndexableProperty` backed by a `ThreadsafeDict`, `memoize!` spawns a `Task`
for the computation. The `fetch` callback receives `(rv, status)` where `rv` is
the `Task` (still running) or the computed result (done), and `status` is the
substatus object (from `__substatus__`) or `nothing`.

Pass `force=true` to unconditionally recompute: clears both the in-memory cache
entry and the on-disk cache file so `memoize!` always spawns a fresh Task.

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
    rv = memoize!(ip, indices...; fetch=identity, retry_failed, kwargs...)
    status = getstatus(ip, indices...; kwargs...)
    fetch(rv, status)
end
# Fallback for non-ThreadsafeDict IPs (1-arg callback, no status)
fetchindex(fetch, ip::IndexableProperty, indices...; kwargs...) = memoize!(ip, indices...; fetch, kwargs...)

"""
    fetchindex!(callback, ip, indices...; fetch=Base.fetch, kwargs...)

In-place variant of [`fetchindex`](@ref). When `callback` is `nothing`, falls
through to a plain `memoize!(ip, indices...; fetch, kwargs...)` — useful for
sites that opt out of the two-phase fetch dance without changing call shape.
"""
fetchindex!(::Nothing, ip, indices...; fetch=Base.fetch, kwargs...) = memoize!(ip, indices...; fetch, kwargs...)
maybepop!(c::AbstractDict, key) = haskey(c, key) && pop!(c, key)
maybepop!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        maybepop!(c.cache, key)
        maybepop!(c.tasks, key)
        maybepop!(c.status, key)
        _drop_order!(c, key)
    end
end

# Subcache factory for indexed-property dicts. Default routes by cache_type:
# `:serial` → `Dict`, `:parallel` → `ThreadsafeDict`. The 4-arg form is keyed
# on `(ParentType, Val{name})` for future per-property overrides; currently
# unused.
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
# entries into the existing one. Kept as a single method with a runtime type
# check: a two-method `(LazyPersistentDict{D}, ::D)` / `(LazyPersistentDict,
# ::Any)` pair is ambiguous when the payload type equals `D` — Julia's
# specificity rule cannot rank a diagonal `where` against a fully generic slot.
function _ingest_loaded!(d::LazyPersistentDict, loaded)
    if loaded isa typeof(d.data)
        d.data = loaded
    else
        merge!(d.data, loaded)
    end
end

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
                # Concurrent access to the same cache file is upstream user
                # error: N copies of the same logical object are racing the
                # same disk file instead of sharing one memoized result.
                # `trylock` atomically rejects the second-caller race (where
                # the prior `islocked` + `lock(...) do` pair was racy) and
                # the error names the type to point the user at the missing
                # `@memo` construction site.
                if !trylock(path_lock)
                    error("""Concurrent access to disk cache $cache_path — \
                          this almost always means the construction site for \
                          $(nameof(typeof(o))) needs an `@memo!` so the same \
                          logical object is not being computed in N copies \
                          racing the same cache file.
$_cache_context""")
                end
                try
                    cache_status = get_cache_status(cache_path)
                    rv = if cache_status == :ready
                        _report_disk_load!(__status__, cache_path, filesize(cache_path))
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
                finally
                    unlock(path_lock)
                end
            else
                # Non-strict or no disk locks: original flow
                cache_status = get_cache_status(cache_path)
                rv = if cache_status == :ready
                    _report_disk_load!(__status__, cache_path, filesize(cache_path))
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
elseif !isempty(indices) || !isempty(kwargs)
    # Non-empty indices/kwargs path: bypass the PropertyCache layer entirely.
    # PropertyCache keys only on `name` (it's meant to cache one-shot
    # IP-wrapper construction per property — see the IP-wrapper return
    # branch below). Forwarding `(indices, kwargs)` through `get!(::PropertyCache, …)`
    # is unsound: the cache would collide across different (indices, kwargs)
    # tuples, and the inner `Base.get!(::AbstractThreadsafeDict, …)` rejects
    # arbitrary kwargs with MethodError. The IP-wrapper / `memoize!` machinery
    # owns kwargs-keyed caching for indexed properties; we just hand off.
    _computeproperty(o, name, indices...; __status__, kwargs...)
else
    # For plain (non-indexed) generated user-facing properties, build a
    # substatus closure so the spawn wrapper attaches a Treebars node to
    # the parent's __status__ for the duration of the compute. Skip
    # dunder names (`__status__`, `__appdata__`, …) and IPs (which get
    # their own substatus via `memoize!(::IndexableProperty, …)`).
    substatus_f = if name != :__substatus__ && name != :__status__ &&
                     !(startswith(string(name), "__") && endswith(string(name), "__")) &&
                     is_generated_property(o, name) && !is_indexed_property(o, name)
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name; __status__=root)
        end
    else
        nothing
    end
    get!(getfield(o, :cache), name; substatus=substatus_f) do s
        # When called with no indices on an indexed property (declared with
        # call/ref syntax, e.g. `x() = ...` or `x[i] = ...`), return an
        # IndexableProperty wrapper instead of calling compute_property.
        if is_indexed_property(o, name)
            return IndexableProperty(name, o, subcache(getfield(o, :cache), typeof(o), Val(name)))
        end
        # `s` is the substatus the spawn wrapper passed (or `nothing` when
        # `substatus_f` was nothing). Pass it as `__status__` so the body
        # — and any IP/property accesses inside — attach to it.
        _computeproperty(o, name; __status__=s)
    end
end
maybehash(x::Number) = x
maybehash(x::Symbol) = x
maybehash(x) = persistent_hash(x)

# POSIX per-path-component byte limit. A single file or directory name longer
# than this fails with ENAMETOOLONG on `mkpath`/`open`, no matter how short
# the total path is.
const NAME_MAX = 255
# Cap for `cache_segment` output. Kept below `NAME_MAX` so the suffixes that
# `get_cache_path` appends afterwards (`_v<version>` and `.sjl`) still leave
# the final filename within the per-component limit.
const _CACHE_SEGMENT_MAX = NAME_MAX - 55

# Truncate `s` to at most `maxbytes` UTF-8 code units, never splitting a char.
_truncate_codeunits(s::AbstractString, maxbytes::Integer) = begin
    n = 0
    io = IOBuffer()
    for c in s
        w = ncodeunits(c)
        n + w > maxbytes && break
        n += w
        print(io, c)
    end
    String(take!(io))
end

# Keep a path segment within `_CACHE_SEGMENT_MAX`. Short segments pass through
# unchanged so the on-disk layout stays human-readable; an overlong one (e.g. a
# fat IndexableProperty key over many args) is replaced by a readable prefix
# plus a SHA1 digest of the *full* segment — bounded, navigable, collision-free.
_bound_segment(seg::AbstractString) = begin
    ncodeunits(seg) <= _CACHE_SEGMENT_MAX && return String(seg)
    digest = persistent_hash(seg)
    head = _truncate_codeunits(seg, _CACHE_SEGMENT_MAX - ncodeunits(digest) - 1)
    head * "_" * digest
end

# Build a single path-segment identifier for a (name, args, kwargs) triple,
# joining the parts with "_" via `maybehash`. Used in two places:
#   1. As the file-name body of `get_cache_path` (with ".sjl" appended).
#   2. As the per-level directory name in the inline-child cache_path
#      auto-wiring, so the on-disk layout mirrors the DO hierarchy.
# Kwargs are sorted by name so callers passing the same kwargs in different
# syntactic order land in the same segment. The joined result is passed through
# `_bound_segment` so a fat key cannot blow past the filesystem's NAME_MAX.
cache_segment(name, args...; kwargs...) = begin
    parts = length(kwargs) == 0 ? (name, args...) : (name, args..., sort(collect(kwargs); by=first)...)
    _bound_segment(join(map(maybehash, parts), "_"))
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
    @cache_status o.prop(indices...)

Return the disk-cache status of a `@cached` property as a `Symbol`:
- `:unstarted` — no cache file exists yet.
- `:started`   — an empty placeholder file exists (previous run may have crashed).
- `:ready`     — a complete cache file exists and can be deserialized.

Can be used both outside and inside a `@dynamicstruct` body. Inside a struct
definition, omit the object prefix — just use the property name (with parens
for indexed properties).

```julia
# Outside the struct:
@cache_status e.result          # :unstarted (before first access)
e.result
@cache_status e.result          # :ready
@cache_status e.ci(2)           # for indexed properties — call syntax

# Inside the struct body:
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    status(key) = @cache_status result(key)   # :unstarted, :started, or :ready
end
```

The legacy bracket form (`@cache_status o.prop[indices...]`) still works for
backward compatibility but is discouraged in new code — prefer call syntax,
which mirrors the way the property is invoked.
"""
macro cache_status(x)
    cache_f_expr(x; f=get_cache_status) |> esc
end

"""
    @is_cached o.prop
    @is_cached o.prop(indices...)

Return `true` if the disk cache for `o.prop` (or `o.prop(indices...)`) is
`:ready`, i.e. the cached value can be loaded from disk without recomputation.

Can be used both outside and inside a `@dynamicstruct` body. Inside a struct
definition, omit the object prefix — just use the property name (with parens
for indexed properties).

```julia
# Outside the struct:
@is_cached e.result   # false before first access, true afterwards

# Inside the struct body:
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    summary(key) = if @is_cached result(key)
        "cached: \$(@memo! result(key))"
    else
        "not yet computed"
    end
end
```

The legacy bracket form (`@is_cached o.prop[indices...]`) still works for
backward compatibility but is discouraged in new code.
"""
macro is_cached(x)
    :($(cache_f_expr(x; f=get_cache_status)) == :ready) |> esc
end

"""
    @cache_path o.prop
    @cache_path o.prop(indices...)

Return the file path where the disk-cached value of `o.prop` (or
`o.prop(indices...)`) is (or would be) stored.

```julia
@cache_path e.result          # e.g. "cache/<hash>/result.sjl"
@cache_path e.ci(2)           # "cache/<hash>/ci_2.sjl"
```

The legacy bracket form is still accepted but discouraged.
"""
macro cache_path(x)
    cache_f_expr(x; f=get_cache_path) |> esc
end
"""
    @persist o.prop
    @persist o.prop(indices...)

Write the in-memory value of `o.prop` (or the indexed entry `o.prop(indices...)`)
back to its disk cache. Use after mutating a value in place when the property
was declared with `@cached` and the on-disk copy is now stale relative to the
in-memory copy.

The legacy bracket form (`@persist o.prop[indices...]`) still works but is
discouraged in new code — prefer call syntax.
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
    maybememoize!(f, args...; kwargs...)

Dispatch helper used by `@memo!`. The default just calls `f(args...; kwargs...)`,
so non-IP callees (functions, types, callable structs) behave like normal
calls. The specialization for `IndexableProperty` routes through
[`memoize!`](@ref), hitting the in-memory cache.
"""
maybememoize!(f, args...; kwargs...) = f(args...; kwargs...)
maybememoize!(p::IndexableProperty, args...; kwargs...) = memoize!(p, args...; kwargs...)
# `maybememoize!(::typeof(maybeprogress!), …)` stacking arms live below
# `maybeprogress!`'s definition — they reference `typeof(maybeprogress!)`,
# which has to exist at parse time.

"""
    @memo! expr

Rewrite every call inside `expr` as `maybememoize!(callee, args…)`. At
runtime `maybememoize!` dispatches: `IndexableProperty` callees go through
[`memoize!`](@ref) (cached); everything else just calls normally.

`@memo!` is the preferred in-body way to ask for cached access at a call
site — the marker makes the caching visible to the reader. It is what an
indexed-property call site should use whenever the result should be memoized.
For one-shot cached calls outside a `@dynamicstruct` body, call `memoize!`
directly.

Inside a `@dynamicstruct`, an indexable property `prop(i) = ...` can be
invoked two different ways:

- `o.prop(i)` — recompute on every call, no caching.
- `@memo! o.prop(i)` — look up in the in-memory cache, compute (and cache) on miss.

```julia
@memo! o.prop(i)                          # cached access
@memo! o.prop(i; k=v)                     # kwargs participate in the cache key

# Chained IP calls all get memoized; intermediate non-IP calls (e.g.
# top-level helpers) just call normally:
@memo! qt.loaded(dataset; data_version).filtered(; src).eda.counts
@memo! sort(x.prop(i))
```

The bang on `@memo!` / `memoize!` / `maybememoize!` reflects that each
mutates the per-key in-memory cache. There is no bracket access on
`IndexableProperty` — `ip[args...]` and `ip[; kw...]` are unsupported
(the latter never parsed in the first place); use the function forms.
"""
macro memo!(x)
    esc(_memo_rewrite(x))
end

# Recursively rewrite every call site to `maybememoize!(...)`. Plain property
# accesses (`.foo`, `.bar.baz`) are left untouched — only `:call` heads are
# transformed. `maybememoize!`'s dispatch decides at runtime whether to
# memoize (IP) or just call (everything else).
_memo_rewrite(x) = x
function _memo_rewrite(x::Expr)
    if Meta.isexpr(x, :call) && length(x.args) >= 1
        rewritten = Any[_memo_rewrite(a) for a in x.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybememoize!), rewritten...))
    end
    Expr(x.head, Any[_memo_rewrite(a) for a in x.args]...)
end

"""
    noprogress(f, args...; kwargs...)

Opt out of dynamic progress wrapping at a specific call site. Inside an IP
body annotated with `@dynamic_progress`, every call is rewritten to
`maybeprogress!(__progress__, callee, args…)`. Writing `noprogress(f, args…)`
makes the rewriter emit `maybeprogress!(__progress__, noprogress, f, args…)`,
which dispatches to a method that just runs `f(args…)` without any progress
attachment.

Note the argument shape: `noprogress(f, args…)` (comma-separated callee and
its args), not `noprogress(f(args…))` — the latter would still wrap `f(args…)`
under the body-wide rewrite before `noprogress` ever sees it.

Outside a `@dynamic_progress` body, `noprogress(f, args…)` is just `f(args…)`.
"""
noprogress(f, args...; kwargs...) = f(args...; kwargs...)

"""
    maybeprogress!(progress, callee, args…; kwargs...)

Runtime dispatch arm for `@dynamic_progress`-rewritten call sites. The
rewriter wraps every call as `maybeprogress!(__progress__, callee, args…)`,
where `__progress__` resolves to the current Treebars progress context (the
enclosing IP's `__status__` at top level; a nested `@progress` block re-binds
it to that block's node). Dispatch on `callee`:

- `callee::IndexableProperty` — open a per-call substatus rooted at
  `progress`, run the IP body inside it (no caching).
- `callee::typeof(noprogress)` — opt-out, calls through (`noprogress(f, args…)`).
- anything else — plain `callee(args…; kwargs…)`.

The caching stack — `@memo! foo(x)` inside a `@dynamic_progress` body —
lands at `maybememoize!(maybeprogress!, progress, callee, args…)` after
natural macro expansion order, and is handled by the corresponding
`maybememoize!` dispatch arms (see above).

`progress === nothing` is fine throughout — the `_default_substatus` /
`fetchindex!` paths have explicit `::Nothing` fallbacks.
"""
maybeprogress!(progress, f, args...; kwargs...) = f(args...; kwargs...)

maybeprogress!(progress, ::typeof(noprogress), f, args...; kwargs...) =
    f(args...; kwargs...)

# `@memo!` expands outside `@dynamic_progress`'s `_progress_rewrite`, so a
# `@memo! foo(x)` inside a `@dynamic_progress` body lands at runtime as
# `maybememoize!(maybeprogress!, __progress__, callee, args…)` — i.e. with
# `maybeprogress!` swallowed as the first positional arg. These dispatch arms
# undo that nesting: an IP callee goes through `fetchindex!` (cached + progress);
# a plain callee runs without caching but still under the progress context.
maybememoize!(::typeof(maybeprogress!), progress, f::IndexableProperty, args...; kwargs...) =
    fetchindex!(progress, f, args...; kwargs...)
maybememoize!(::typeof(maybeprogress!), progress, f, args...; kwargs...) =
    maybeprogress!(progress, f, args...; kwargs...)

maybeprogress!(progress, ip::IndexableProperty{name}, indices...; kwargs...) where {name} = begin
    o = ip.o
    _info = metafirst(typeof(o), name)
    _displayed = _info === nothing ? true : get(_info, :displayed, true)
    # Per-call substatus, parented under `progress` (instead of the default
    # `o.__status__`). When `progress === nothing` this returns `nothing` and
    # everything downstream falls back to the standard `o.__status__` flow
    # inside `_computeproperty`.
    s = _default_substatus(progress, o, name, indices...; displayed=_displayed, kwargs...)
    try
        rv = _computeproperty(o, name, indices...; __status__=s, kwargs...)
        _finalize_substatus!(s)
        rv
    catch e
        _fail_substatus!(s, e)
        rethrow()
    end
end

# Recursively rewrite every call site to `maybeprogress!($progress_var, …)`.
# Mirrors `_memo_rewrite`'s shape; orthogonal but stackable.
#
# `progress_var` is the in-scope identifier the call sites should reference
# — typically `:__progress__`. Inside a Tb `@progress label body` block
# (or anything that rebinds the identifier), `__progress__` gets the
# per-block node, so the same emitted code transparently follows the
# nesting.
#
# Stacking with `@memo!`: `@dynamic_progress`'s macro expansion runs before
# `@memo!`'s (outside→in), so `@memo! foo(x)` is still a `:macrocall` here —
# we just recurse into it like any other Expr. The inner `foo(x)` becomes
# `maybeprogress!(__progress__, foo, x)`. When `@memo!` expands later, its
# own `_memo_rewrite` sees that `:call` and turns it into
# `maybememoize!(maybeprogress!, __progress__, foo, x)`. The
# `maybememoize!(::typeof(maybeprogress!), …)` dispatch arms (above) then
# do the right thing at runtime.
_progress_rewrite(progress_var::Symbol, x) = x
function _progress_rewrite(progress_var::Symbol, x::Expr)
    if Meta.isexpr(x, :call) && length(x.args) >= 1
        rewritten = Any[_progress_rewrite(progress_var, a) for a in x.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybeprogress!), progress_var, rewritten...))
    end
    Expr(x.head, Any[_progress_rewrite(progress_var, a) for a in x.args]...)
end

"""
    @dynamic_progress progress_var body

Rewrite every `:call` inside `body` as
`maybeprogress!(progress_var, callee, args…)`. Returns the rewritten body
unchanged otherwise. **The caller is responsible for binding
`progress_var`** — e.g. via `Treebars.@progress progress_var body` — and
for keeping DO free of a hard `Treebars` dependency.

`maybeprogress!` dispatches on `progress_var`'s runtime type: a
`Treebars.ProgressNode` (when the caller has wrapped in `Tb.@progress`)
opens per-call substatuses; `noprogress` opts out; anything else
collapses to a plain `f(args…)`. The macro itself doesn't care which.

In `@dynamicstruct`, a property marker `@dynamic_progress` lowers to

    prop() = @dynamic_progress __status__ body

where `__status__` is the IP caller's bound progress context (or
`nothing`).

Standalone:

    Treebars.@progress my_status begin
        @dynamic_progress my_status begin
            a = foo(x)           # → maybeprogress!(my_status, foo, x)
            b = @memo! bar(y)    # cached + progress (see `maybememoize!`)
            a + b
        end
    end
"""
macro dynamic_progress(progress_var, body)
    progress_var isa Symbol ||
        error("@dynamic_progress: progress var must be a Symbol, got $(progress_var)")
    esc(_progress_rewrite(progress_var, body))
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
    @clear_cache! o.prop(indices...)

Clear the disk cache (and in-memory cache) for a `@cached` property.

Without indices, clears **all** cached entries for the property (both the
in-memory value and all `.sjl` files for that property on disk).
With indices, clears only the specific entry.

```julia
@clear_cache! e.result        # clear all cached entries for `result`
@clear_cache! e.ci(3)         # clear only the (3,) entry
```

The legacy bracket form is still accepted but discouraged.
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
walk_rhs(e::Symbol; locals, properties, lnn=nothing) = if (e in properties) && !(e in locals)
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

# Collect every `(callee_name::Symbol, ref_expr)` pair in `e` where `ref_expr`
# is `:ref` head (i.e. `a[b...]`) and the callee resolves to a sibling
# property reference. After `walk_rhs`, in-body sibling references appear as
# either `__self__.<name>` (the common rewrite) or the bare `<name>` (when
# inside a non-shadowed scope; rare since walk_rhs rewrites those too).
# Returns the list of (callee_name, original_ref_callee_expr) hits.
_bracket_ip_callee(::Any) = nothing
function _bracket_ip_callee(e::Symbol)
    # bare sibling name in a `[...]`; resolved by caller against prop_names
    e
end
function _bracket_ip_callee(e::Expr)
    if e.head === :. && length(e.args) == 2 &&
            e.args[1] === :__self__ && e.args[2] isa QuoteNode &&
            e.args[2].value isa Symbol
        return e.args[2].value::Symbol
    end
    nothing
end

_scan_bracket_ip!(_, _, _) = nothing
function _scan_bracket_ip!(hits::Vector{Symbol}, e::Expr, prop_names)
    if Meta.isexpr(e, :ref) && length(e.args) >= 1
        callee = _bracket_ip_callee(e.args[1])
        callee isa Symbol && callee in prop_names && push!(hits, callee)
    end
    for a in e.args
        _scan_bracket_ip!(hits, a, prop_names)
    end
end

function _check_bracket_ip_access!(msgs, type, name::Symbol, info, prop_names, indexed_names)
    info.rhs === nothing && return
    info.rhs isa Expr || return
    hits = Symbol[]
    _scan_bracket_ip!(hits, info.rhs, prop_names)
    isempty(hits) && return
    seen = Set{Symbol}()
    for callee in hits
        callee in indexed_names || continue
        callee in seen && continue
        push!(seen, callee)
        short = "`o.$callee[...]`: use `@memo! o.$callee(...)` or `memoize!(o.$callee, ...)` — bracket access on IndexableProperty is no longer supported"
        long  = "Property `$type.$name` reads `$callee[...]` (bracket access on an `IndexableProperty`). The `ip[args...]` overload has been removed: `ip[; kwargs...]` was never valid Julia syntax (the parser rejects `[; …]`), and Niko hit the gap often enough that the bracket form is gone entirely. Use one of the function forms uniformly: inside a `@dynamicstruct` body, wrap the call site in `@memo! o.$callee(args; kwargs...)`; outside (or when you want the explicit name), call `memoize!(o.$callee, args; kwargs...)` directly. Both go through the same per-key cache the bracket form used."
        push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
    end
end

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
        members = join(map(g -> "`$g`", group), ", ")
        if Symbol(prefix) in name_set
            short = "$(length(group)) `$(prefix)_*` siblings ($members) + bare `$prefix` — fold into it (`@struct`/`@include` body)"
            long  = "`$type` has $(length(group)) properties named `$(prefix)_*` ($(join(group, ", "))) AND a bare `$prefix` property. Move the `$(prefix)_*` members INTO `$prefix` as bare suffixes (`$type.$prefix.<suffix>`). Use `@struct $prefix = begin …end` for data, `@include $prefix = begin …end` for routes."
            push!(msgs, LintMessage(type, nothing, :error, short, long, nothing))
        else
            short = "$(length(group)) `$(prefix)_*` siblings ($members) — group as `@struct $prefix` (or `@include $prefix` if routes)"
            long  = "`$type` has $(length(group)) properties sharing `$(prefix)_*` prefix: $(join(group, ", ")). Group inside `@struct $prefix = begin …end` (data) or `@include $prefix = begin …end` (routes) so the shared-prefix names become bare members of the child."
            push!(msgs, LintMessage(type, nothing, :warn, short, long, nothing))
        end
    end
end

function _check_shared_arg_signature!(msgs, type, oproperties, types_in_tree, parent_map, wc_cache)
    by_sig = Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}()
    info_of = Dict{Symbol, Any}()
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
        info_of[name] = info
    end
    for (sig, group) in by_sig
        length(group) >= 2 || continue
        argstr  = join(sig, ", ")
        members = join(map(g -> "`$g`", group), ", ")
        # Aggregate the worst-case bound across the group. If callers had
        # additional scope identities beyond the args themselves, the args
        # are likely derived FROM those identities. The bound names here
        # name the actual upstream keys.
        upstream = Set{Symbol}()
        for member in group
            wc = _print_struct_worst_case(types_in_tree, parent_map, type,
                                          member, info_of[member], wc_cache)
            wc !== nothing && wc[1] === :bound && union!(upstream, wc[2])
        end
        # Args themselves aren't in the bound (only caller scope is), so
        # any non-empty bound implies derived. Empty bound = proper keys.
        derived  = !isempty(upstream)
        upnames  = sort!(collect(upstream))
        upstr    = join(map(n -> "`$n`", upnames), ", ")
        short, severity = if derived
            ("$(length(group)) IPs share `($argstr)` ($members) — args derived from $upstr; refactor to key on those upstream identities instead of threading `($argstr)` through",
             :warn)
        else
            ("$(length(group)) IPs share `($argstr)` ($members) — `($argstr)` look like proper keys; fold to `@struct shared($argstr)`",
             :warn)
        end
        long = derived ?
            "`$type` has $(length(group)) indexed properties sharing the `($argstr)` signature: $(join(group, ", ")). Their worst-case bound includes $upstr, meaning every call site computes `($argstr)` from those upstream identities. Folding into `@struct shared($argstr)` just shifts the redundancy. Refactor the IPs to key on the upstream identities ($upstr) directly so callers don't have to thread the derived values through." :
            "`$type` has $(length(group)) indexed properties sharing the `($argstr)` signature: $(join(group, ", ")). Worst-case bound is empty — callers pass `($argstr)` without additional scope contributions, so they're independent identities. `@struct shared($argstr) = begin …end` is the right fold; the IP bodies become bare members."
        push!(msgs, LintMessage(type, nothing, severity, short, long, nothing))
        by_prefix = Dict{String, Vector{Symbol}}()
        for n in group
            s = String(n)
            underscore = findfirst(==('_'), s)
            (isnothing(underscore) || underscore == 1) && continue
            push!(get!(by_prefix, s[1:underscore-1], Symbol[]), n)
        end
        for (prefix, sub) in by_prefix
            length(sub) >= 2 || continue
            sub_members = join(map(g -> "`$g`", sub), ", ")
            short_e = derived ?
                "$(length(sub)) IPs share `($argstr)` AND `$(prefix)_*` ($sub_members) — args derived from $upstr; refactor to key on those upstream identities, possibly via `@struct $prefix($(join(upnames, ", "))) = begin … end`" :
                "$(length(sub)) IPs share `($argstr)` AND `$(prefix)_*` ($sub_members) — `($argstr)` look like proper keys; fold to `@struct $prefix($argstr)`"
            long_e  = derived ?
                "`$type` has $(length(sub)) indexed properties that share BOTH the `($argstr)` signature AND the `$(prefix)_*` prefix: $(join(sub, ", ")). Args derive from $upstr; refactor to key on those upstream identities and let the suffixes become bare members of the resulting child." :
                "`$type` has $(length(sub)) indexed properties that share BOTH the `($argstr)` signature AND the `$(prefix)_*` prefix: $(join(sub, ", ")). Fold them into `@struct $prefix($argstr) = begin …end` and let the suffixes become bare members."
            push!(msgs, LintMessage(type, nothing, :error, short_e, long_e, nothing))
        end
    end
end

# --- New: hierarchical placement (lint #1) -------------------------------
# For an IP at T.prop with worst-case bound {k1, k2, ...}, every name in the
# bound should be visible in T's enclosing static scope (constructor fields,
# `@param`s, IP positional args along the parent chain). Anything outside
# that scope means the IP is reaching across the tree.

function _check_hierarchical_placement!(msgs, types_in_tree, parent_map, type, name, info, wc_cache)
    isempty(_ip_positional_args(info.indices)) && return
    wc = _print_struct_worst_case(types_in_tree, parent_map, type, name, info, wc_cache)
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

# Membership test for the `meta(T)` introspection vector — replaces the
# `haskey(cprops, name)` dict lookups that were correct when `meta(T)` was a
# `Dict`. With the per-declaration vector, duplicates are preserved but a
# membership check still only cares whether the name appears at all.
_cprops_has(cprops, name::Symbol) = any(p -> first(p) === name, cprops)

# Collect all `target(args…)` call sites in `expr` matching `_has_call_to`'s
# rules; return Vector of positional-arg expression lists (one per call).
function _collect_call_args!(out::Vector{Vector{Any}}, expr, target::Symbol, cprops)
    expr isa Expr || return
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        match = false
        if callee === target
            match = cprops !== nothing && _cprops_has(cprops, target)
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            match = root !== nothing &&
                    (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                     (cprops !== nothing && _cprops_has(cprops, root)))
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

# Inverted call index: walk every property body in the tree once and bucket
# call sites by callee target. Replaces N×P walks (one per IP target) with
# a single pass; lookups for `_check_redundant_args!` are O(1).
function _build_call_index(types_in_tree)
    out = Dict{Symbol, Vector{Tuple{Type,Symbol,Vector{Any}}}}()
    for U in types_in_tree
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (uname, uinfo) in uprops
            uinfo.rhs === nothing && continue
            _index_calls!(out, uinfo.rhs, uprops, U, uname)
        end
    end
    out
end

function _index_calls!(out, expr, cprops, caller_T::Type, caller_prop::Symbol)
    expr isa Expr || return
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        target = nothing
        if callee isa Symbol
            cprops !== nothing && _cprops_has(cprops, callee) && (target = callee)
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode
            potential = callee.args[2].value
            root = _dot_chain_root(callee.args[1])
            if root !== nothing &&
               (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                (cprops !== nothing && _cprops_has(cprops, root)))
                target = potential
            end
        end
        if target isa Symbol
            args = Any[]
            for a in expr.args[2:end]
                Meta.isexpr(a, :parameters) && continue
                push!(args, a)
            end
            push!(get!(out, target,
                       Vector{Tuple{Type,Symbol,Vector{Any}}}()),
                  (caller_T, caller_prop, args))
        end
    end
    for a in expr.args
        _index_calls!(out, a, cprops, caller_T, caller_prop)
    end
end

# Normalize a `__self__.X…` / `__parent__[.__parent__]*.X…` dot chain to
# `(BaseType, :a, :b, ...)` where BaseType is reached by walking parent_map
# off `caller_T` once per leading `__parent__`. Returns `nothing` for any
# other shape so callers fall back to comparing the raw `Expr`.
function _normalize_dot_chain(expr, caller_T::Type, parent_map)
    accessors = Symbol[]
    cur = expr
    while Meta.isexpr(cur, :., 2) && cur.args[2] isa QuoteNode &&
          cur.args[2].value isa Symbol
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

# --- Top-level pollution: AppData property used only in one subtree -------
# A property of the type registered as `__appdata__` should ideally live at
# the LCA of its callers' subtree, not above. If every reference to
# `__appdata__.X` comes from a single non-root subtree, X is misplaced —
# move it under that subtree's data domain.

function _appdata_top_field(expr)
    expr isa Expr || return nothing
    cur = expr
    accessors = Symbol[]
    while Meta.isexpr(cur, :., 2) && cur.args[2] isa QuoteNode &&
          cur.args[2].value isa Symbol
        pushfirst!(accessors, cur.args[2].value)
        cur = cur.args[1]
    end
    cur === :__appdata__ || return nothing
    isempty(accessors) ? nothing : accessors[1]
end

function _collect_appdata_refs!(out::Set{Symbol}, expr)
    expr isa Expr || return
    field = _appdata_top_field(expr)
    field !== nothing && push!(out, field)
    for a in expr.args
        _collect_appdata_refs!(out, a)
    end
end

function _ancestor_chain(T, parent_map)
    chain = Type[T]
    cur = T
    while haskey(parent_map, cur)
        cur = parent_map[cur][1]
        push!(chain, cur)
    end
    chain
end

function _lca_of(types, parent_map)
    isempty(types) && return nothing
    types_arr = collect(types)
    chains = [_ancestor_chain(T, parent_map) for T in types_arr]
    common = reduce(intersect, [Set(c) for c in chains])
    isempty(common) && return nothing
    for T in chains[1]
        T in common && return T
    end
    nothing
end

function _check_appdata_placement!(msgs, root::Type, types_in_tree, parent_map)
    appdata_T = _walk_nested_type(root, :__appdata__)
    appdata_T === nothing && return
    appdata_props = try meta(appdata_T) catch; nothing end
    appdata_props === nothing && return
    # For each AppData property name, collect set of types whose property
    # bodies reference `__appdata__.<name>` (directly or via destructure).
    callers_of = Dict{Symbol, Set{Type}}()
    for U in types_in_tree
        U === appdata_T && continue
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (_, uinfo) in uprops
            uinfo.rhs === nothing && continue
            refs = Set{Symbol}()
            _collect_appdata_refs!(refs, uinfo.rhs)
            for r in refs
                push!(get!(callers_of, r, Set{Type}()), U)
            end
        end
    end
    for (name, info) in appdata_props
        # Only flag structural sub-trees (registered nested types) — primitive
        # config like `server_id::Int = …` doesn't have a "data domain" to move
        # under.
        _walk_nested_type(appdata_T, name) === nothing && continue
        callers = get(callers_of, name, Set{Type}())
        isempty(callers) && continue
        lca = _lca_of(callers, parent_map)
        (lca === nothing || lca === root) && continue
        ncallers = length(callers)
        short = "only referenced from `$(nameof(lca))`'s subtree ($(ncallers) caller$(ncallers == 1 ? "" : "s")) — move under that domain instead of `__appdata__` top"
        long  = "Property `$(nameof(appdata_T)).$name` is at the `__appdata__` top level but every reference goes through types under `$(nameof(lca))`'s subtree. Move it into `$(nameof(lca))`'s data domain (e.g. as a property of a paired data type) so placement matches actual usage."
        push!(msgs, LintMessage(appdata_T, name, :warn, short, long, info.lnn))
    end
end

function _check_redundant_args!(msgs, call_index, parent_map, type, name::Symbol, info)
    pos = _ip_positional_args(info.indices)
    isempty(pos) && return
    sites = get(call_index, name, Vector{Tuple{Type,Symbol,Vector{Any}}}())
    all_caller_args = Vector{Vector{Any}}()
    for (cT, cp, argset) in sites
        (cT === type && cp === name) && continue
        push!(all_caller_args,
              Any[_normalize_arg(a, cT, parent_map) for a in argset])
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
                # `metafirst` is fine here: this lint groups properties by
                # bound, and even with future duplicate-name declarations the
                # lnn we want is the first occurrence's.
                info = metafirst(T, member)
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
    wc_cache      = _WCCache()
    bound_groups  = _bound_groups(types_in_tree, parent_map, wc_cache)
    call_index    = _build_call_index(types_in_tree)

    for U in types_in_tree
        props = try meta(U) catch; nothing end
        props === nothing && continue
        oproperties = collect(props)
        prop_names  = Set(first(p) for p in props)
        indexed_names = Set{Symbol}(n for (n, info) in oproperties if info.indexed)
        type_bound  = get(bound_groups, U, Dict{Tuple{Vararg{Symbol}},Vector{Symbol}}())

        # Per-property
        for (n, info) in oproperties
            siblings, bound = _siblings_in_bound(type_bound, n)
            _check_cryptic_arg_names!(msgs, U, n, info)
            _check_no_self_access!(msgs, U, n, info, prop_names, siblings, bound)
            _check_trivial_cached_wrapper!(msgs, U, n, info)
            _check_hierarchical_placement!(msgs, types_in_tree, parent_map, U, n, info, wc_cache)
            _check_redundant_args!(msgs, call_index, parent_map, U, n, info)
            _check_bracket_ip_access!(msgs, U, n, info, prop_names, indexed_names)
        end

        # Struct-level (skip forwarded entries from singleton/prefix views)
        own = [n => info for (n, info) in oproperties
               if info.rhs === nothing || !_is_forwarded(info.rhs)]
        _check_singleton_struct!(msgs, U, own)
        _check_repeated_prefix!(msgs, U, own)
        _check_shared_arg_signature!(msgs, U, own, types_in_tree, parent_map, wc_cache)
    end

    _check_identical_bound_siblings!(msgs, bound_groups, types_in_tree, parent_map)
    _check_appdata_placement!(msgs, T, types_in_tree, parent_map)
    msgs
end

# bond_groups: Type → Dict{bound::Tuple → group::Vector{Symbol}}.
# Computed once per analyze pass; reused by both `_check_no_self_access!`
# (to name same-bound siblings in its message) and
# `_check_identical_bound_siblings!` (for cluster emission).
function _bound_groups(types_in_tree, parent_map, wc_cache=_WCCache())
    out = Dict{Type, Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}}()
    for T in types_in_tree
        props = try meta(T) catch; nothing end
        props === nothing && continue
        by_bound = Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}()
        for (name, info) in props
            isempty(_ip_positional_args(info.indices)) && continue
            wc = _print_struct_worst_case(types_in_tree, parent_map, T, name, info, wc_cache)
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

"""
    metafirst(T, name::Symbol) -> Union{Nothing, NamedTuple}

Return the first info for `name` in `meta(T)`, or `nothing` if absent. Use when you
expect at most one entry and don't care about duplicates.
"""
metafirst(T::Type, name::Symbol) = let m = meta(T)
    for (n, info) in m
        n === name && return info
    end
    nothing
end

"""
    metaall(T, name::Symbol) -> Vector{NamedTuple}

Return all infos for `name` in `meta(T)` in declaration order. Empty if absent.
Use when duplicates are expected (e.g. coexisting route + indexed include).
"""
metaall(T::Type, name::Symbol) = NamedTuple[info for (n, info) in meta(T) if n === name]
"""    _property_description(o, ::Val{name}, args...; kwargs...)

Return a human-readable description for the property `name` with the given arguments.
Override generated per-property when a docstring is present in @dynamicstruct.
Default: "name(arg1,arg2,...; k1=v1,k2=v2)" — kwargs section is omitted when empty.
"""
_property_description(o, ::Val{name}, args...; kwargs...) where {name} = begin
    # Bubble: if `name` is a registered nested-struct property and the
    # nested type carries a user docstring, use that as the description.
    # Inline `@struct child = begin "doc" … end` declarations emit their
    # own per-prop `_property_description` override which wins; bare
    # @include externals and typed properties fall through to here.
    nested = _walk_nested_type(typeof(o), name)
    if nested !== nothing
        desc = _type_description(nested, args...; kwargs...)
        desc !== nothing && return desc
    end
    argstr = join(args, ",")
    kwstr = isempty(kwargs) ? "" : "; " * join(("$k=$v" for (k, v) in kwargs), ",")
    "$name($argstr$kwstr)"
end

"""    _type_description(::Type{T}, args...; kwargs...) -> Union{String,Nothing}

Return a description for an instance of `T` constructed with the given args.
`@dynamicstruct` emits an override for every type it defines that delegates
to `_resolve_type_description(T, args, kwargs)` — this reads the user-attached
docstring (if any) at runtime via `Base.Docs.meta`. Returns `nothing` when
`T` has no user docstring; callers (e.g. `@include`-emitted
`_property_description` overrides) should fall through to a per-property
default in that case.
"""
_type_description(::Type, args...; kwargs...) = nothing

# Runtime: read the user-registered docstring for `T` (if any), strip it,
# format with the construction args. Returns `nothing` when no doc is set —
# the auto-generated property-list fallback installed at line ~2556 lives
# in `Base.Docs.getdoc(::Type{T})`, NOT in `Base.Docs.meta`, so this only
# fires when the user explicitly attached a docstring via `"…"` syntax.
function _resolve_type_description(::Type{T}, args, kwargs) where {T}
    binding  = Base.Docs.Binding(parentmodule(T), nameof(T))
    docs_meta = Base.Docs.meta(binding.mod)
    multidoc = get(docs_meta, binding, nothing)
    (multidoc === nothing || isempty(multidoc.docs)) && return nothing
    raw = first(values(multidoc.docs))
    txt = raw isa Base.Docs.DocStr ? join(raw.text, "") : string(raw)
    label = strip(txt)
    isempty(label) && return nothing
    argstr = join(args, ",")
    kwstr  = isempty(kwargs) ? "" : "; " * join(("$k=$v" for (k, v) in pairs(kwargs)), ",")
    "$label($argstr$kwstr)"
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

# Property-macro accumulator: doc / cache_version / macros are the three
# pieces of state the body-args parser threads through the
# `while Meta.isexpr(arg, :macrocall)` peeling loop. Bundling them into a
# small mutable struct lets per-macro logic live in dispatched methods of
# `_apply_property_macro!` (one method per macro shape) instead of in
# branch arms inside the loop body.
mutable struct _PropertyMacroState
    doc::Any
    cache_version::Any
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
    (lhs in properties) && !(lhs in locals) ? [lhs] : Symbol[]
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
    push!(oproperties, inner_name => (;lhs=inner_name, macros=Set{Symbol}(), rhs=:($source_sym[$i]), lnn, dependson=Set{Symbol}(), locals=inner_locals, indices=tuple(), indexed=false, cache_version=nothing))
    push!(docs, (inner_name => (nothing, true)))
    _emit_positional_destructure!(oproperties, docs, a.args, inner_name, lnn)
end
function _push_positional_leaf!(oproperties, docs, leaf::Symbol, i, source_sym, lnn)
    push!(oproperties, leaf => (;lhs=leaf, macros=Set{Symbol}(), rhs=:($source_sym[$i]), lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([leaf]), indices=tuple(), indexed=false, cache_version=nothing))
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
    # Short-form sugar: `T(arg1::T1, arg2::T2) = begin … end` is shorthand
    # for `struct T; arg1::T1; arg2::T2; … end`. Positional args become
    # fixed/constructor fields. `;`-separated kwargs become regular DO
    # properties — bare `kw` errors at access time if the construction
    # kwarg wasn't supplied; `kw=default` makes the default the property
    # RHS (overridable via the same kwarg at construction). Standard Julia
    # docstrings bind to `T` via `Base.@__doc__` exactly like the long form.
    if Meta.isexpr(expr, :(=)) && length(expr.args) == 2 &&
       Meta.isexpr(expr.args[1], :call) &&
       Meta.isexpr(expr.args[2], :block)
        call = expr.args[1]
        body_block = expr.args[2]
        type_name = call.args[1]
        type_args = call.args[2:end]
        body_extras = Any[]
        positional = Any[]
        for a in type_args
            if Meta.isexpr(a, :parameters)
                for kw in a.args
                    if kw isa Symbol
                        msg = "$(type_name)(; $kw, …): required kwarg `$kw` was not provided at construction."
                        push!(body_extras, Expr(:(=), kw, :($error($msg))))
                    elseif Meta.isexpr(kw, :kw, 2)
                        push!(body_extras, Expr(:(=), kw.args[1], kw.args[2]))
                    else
                        error("@dynamicstruct $type_name(...): unsupported kwarg form `$kw` in short-form signature. Use `name` (required) or `name=default`.")
                    end
                end
            else
                push!(positional, a)
            end
        end
        expr = Expr(:struct, false, type_name,
                    Expr(:block, positional..., body_extras..., body_block.args...))
    end
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
        # `@struct prop(args) = body` parses with body wrapped in `:block`,
        # so the `:block` check above passes for the short-form misuse
        # `@struct prop(args) = ExternalCtor(args)` (where the block holds a
        # single bare call). `@struct` always requires an explicit
        # `begin … end` declaring the child's properties — without this
        # check, the downstream args-parsing loop crashes on the bare call
        # with `union!(::Nothing, ::Set{Any})`.
        rhs_stmts = [a for a in rhs.args if !(a isa LineNumberNode)]
        if length(rhs_stmts) == 1 && !Meta.isexpr(rhs_stmts[1], (:(=), :macrocall, :struct, :tuple))
            error("@struct $prop_sym: body must be an explicit `begin ... end` declaring the child's properties. Got a single bare expression `$(rhs_stmts[1])` — likely a short-form misuse like `@struct $lhs = ExternalCtor(...)`. Rewrite as `@struct $lhs = begin ... end` with the child's properties inline.")
        end
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
        # Parallel list to `index_params` preserving the raw positional-arg
        # expression (`:name` or `:(name::T)`). Used only when emitting the
        # parent property's method signature so `info.indices` carries the
        # type annotation for downstream readers (notably HTMXObjects'
        # `_nested_prefix_and_step`, which feeds URL-segment conversion).
        index_param_exprs = Any[]
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
                        push!(index_param_exprs, p)
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
        # Use `index_param_exprs` (typed `:(name::T)` when annotated, bare
        # `:name` otherwise) for the method signature so downstream readers
        # of `info.indices` see the URL-segment Julia Type. Internal uses
        # of `index_params` above stay on bare Symbols.
        lhs_expr = if isempty(index_params) && isempty(index_kwargs)
            prop_name
        elseif isempty(index_kwargs)
            Expr(:call, prop_name, index_param_exprs...)
        else
            # Emit kwargs as an Expr(:parameters, ...) on the parent-property
            # call signature. Required kwargs stay as bare Symbols; defaulted
            # kwargs become Expr(:kw, name, default).
            kw_nodes = Any[kdefault === nothing ? kname : Expr(:kw, kname, something(kdefault))
                           for (kname, kdefault) in index_kwargs]
            Expr(:call, prop_name, Expr(:parameters, kw_nodes...), index_param_exprs...)
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
        # Peel `@doc` / `@cached` / unrecognised macros from `arg` via
        # `_apply_property_macro!` dispatch (one method per macro shape).
        # The state struct mutates `doc` / `cache_version` / `macros` in
        # place — `macros` is the same Set the outer loop uses, so we read
        # it back implicitly; the other two are scalars copied back after
        # the loop.
        macro_state = _PropertyMacroState(doc, cache_version, macros)
        while Meta.isexpr(arg, :macrocall)
            # `_resolve_macro_name` collapses `GlobalRef(Core, :@doc)` (the
            # form Julia's docstring lowering surfaces) to bare `:@doc`.
            mname = _resolve_macro_name(arg.args[1])
            arg = _apply_property_macro!(macro_state, Val(mname), arg)
        end
        doc = macro_state.doc
        cache_version = macro_state.cache_version
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
                    error("Property-level macros (@cached, …) cannot be applied to inline methods in @dynamicstruct.")
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
                push!(oproperties, group_name => (;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version))
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
                push!(oproperties, group_name=>(;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version))
                push!(docs, (group_name=>(doc, true)))
                group_name
            end
            metadata.doc[] = nothing
            for (prop_name, source) in members
                extract_rhs = _extract_member(extract_from, source)
                push!(oproperties, prop_name=>(;lhs=prop_name, macros=Set{Symbol}(), rhs=extract_rhs, lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([prop_name]), indices=tuple(), indexed=false, cache_version=nothing))
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
        if !(name isa Symbol)
            loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
            hint = if Meta.isexpr(name, :parameters)
                "Looks like a `;`-kwargs clause leaked into the body. If you wrote `@dynamicstruct $type(...; kw, kw=default) = begin … end`, that's now supported — make sure DynamicObjects is up to date."
            elseif Meta.isexpr(name, :tuple)
                "Tuple LHS (e.g. `(a, b) = ...`) destructuring at struct-level is not supported as a property name; either split into separate property declarations or use `let` inside another property's RHS."
            else
                """\
                Each property in @dynamicstruct must have a Symbol name on the LHS — e.g. `name = rhs`, `name(idx) = rhs`, or `name::T = rhs`. \
                Looks like a side-effecting/anonymous statement at struct top-level — DO doesn't run those at construction. To keep the check, either:
                  (a) bind it to a named property and reference that property from a downstream RHS:
                      _check = $arg
                      result = (_check; …)         # forces evaluation when `result` is accessed
                  (b) fold the assertion directly into the RHS of a property that needs to enforce it:
                      result = begin
                          $arg
                          …
                      end
                """
            end
            error("@dynamicstruct $type: cannot interpret `$arg` as a property declaration$loc. $hint")
        end
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
        push!(oproperties, name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices, indexed, cache_version))
    end
    # `properties` holds the per-declaration list (preserves order AND duplicate
    # names — e.g. a future `@get foo()` + `@include foo(x::String)` pair). It's
    # what `meta(T)` returns; macro-internal lookups that just need "is `x` a
    # property name?" use the `prop_names` set built from it.
    properties = collect(oproperties)
    prop_names = Set{Symbol}(first.(oproperties))
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
        :(function $type($(fixed_lhs...); cache_type=$(Meta.quot(cache_type)), kwargs...)
            __inst__ = new(
                $(fixed_names...),
                $PropertyCache(
                    $(resolve_cache_type)(cache_type),
                    (;kwargs...)
                )
            )
            $(_link_owner!)(getfield(__inst__, :cache), __inst__)
            __inst__
        end)
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
            $Base.hasproperty(__self__::$type, name::Symbol) = name in $(Tuple(prop_names))
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
            # Per-T `_type_description` override — delegates to a runtime
            # resolver that reads the user-attached docstring (if any). Lets
            # `@include`-emitted `_property_description` overrides bubble
            # `T`'s docstring up as the progress label when `T(args)` is
            # constructed via an IP.
            $DynamicObjects._type_description(::Type{$type}, args...; kwargs...) =
                $DynamicObjects._resolve_type_description($type, args, (; kwargs...))
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
                                Expr(:kw, a.args[1], walk_rhs(a.args[2]; locals=defaults_locals, properties=prop_names, lnn=info.lnn))
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
                    # Walk the docstring expression so interpolated bare names
                    # resolve through the same scope rules as the property's
                    # body: sibling-property references (`$method`,
                    # `$top_chains`, …) get rewritten to `__self__.<name>`,
                    # while the property's own indices and kwargs stay as
                    # plain locals (they're in the emitted method signature).
                    # String literals with no interpolation are passed through
                    # unchanged by `walk_rhs`.
                    walked_doc = walk_rhs(pdoc; info.locals, properties=prop_names, lnn=info.lnn)
                    _lnn, Expr(:(=), _call(:_property_description, desc_extras...), Expr(:block, _lnn, walked_doc))
                else
                    nothing
                end
                walked_rhs = walk_rhs(info.rhs; info.locals, properties=prop_names, lnn=info.lnn)
                # `@dynamic_progress`-marked: emit the 2-arg form
                # `@dynamic_progress __status__ <body>`. The macro (defined
                # above) handles both the call-site rewrite AND the Tb
                # `@progress __status__ <body>` wrap that binds `__progress__`
                # inside the body. Same outside→in macro expansion order as
                # before — `@memo!` calls inside still expand after, so the
                # `maybememoize!(maybeprogress!, …)` stacking dispatch arms
                # pick them up.
                if Symbol("@dynamic_progress") in info.macros
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(@__MODULE__, Symbol("@dynamic_progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        walked_rhs)
                end
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
    # with the `prop_names` set so bare references to registered property
    # names are rewritten to `__self__.<name>`, matching the rewrite that
    # runs on property RHSs.
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
        walked_body = walk_rhs(m.body; locals=method_locals, properties=prop_names, lnn=m.lnn)
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
# Indexed properties. `obj.prop(args)` is fresh; `@memo! obj.prop(args)` is cached.
# Properties reference each other by bare name (auto-rewritten to __self__.<name>).
@dynamicstruct struct DataSet
    items = ["apple", "banana", "cherry"]
    matches(query)   = filter(x -> occursin(query, x), items)   # call: fresh each time
    top(query; n=1)  = first(matches(query), n)                 # call with kwargs
end

ds = DataSet()
ds.matches("an")        # ["banana"] — fresh each call
@memo! ds.matches("an")  # ["banana"] — cached in the per-property dict
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
    results(key) = expensive_computation(__status__)  # __status__ is the substatus
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
        seen_names = Set{Symbol}()
        for (name, _) in props
            name in seen_names && continue
            push!(seen_names, name)
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
        seen_names = Set{Symbol}()
        for (name, _) in props
            name in seen_names && continue
            push!(seen_names, name)
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
            # `metafirst` is fine: scope walk only needs one parent IP's positional
            # args; if duplicate declarations ever exist they share the IP signature.
            info = metafirst(parent_T, parent_prop)
            if info !== nothing
                for a in _ip_positional_args(info.indices)
                    push!(names, a)
                end
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
            cprops !== nothing && _cprops_has(cprops, target) && return true
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            if root !== nothing &&
               (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                (cprops !== nothing && _cprops_has(cprops, root)))
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
    info = try metafirst(caller_T, caller_prop) catch; nothing end
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
# Memoized expanded worst-case bound. `analyze_structure` / `structure(T)`
# invoke this from multiple call sites for the same (T, prop) — bound-group
# precompute, hierarchical-placement check, and render annotations. Without
# caching we re-walk the whole `types_in_tree × props_per_type` cross product
# several times.
#
# Cache is **per-call**, passed explicitly. No global state — concurrent
# requests get their own cache so there are no races on `setindex!` / shared
# entries. The default-arg form creates a fresh dict for callers that don't
# care about cross-call reuse; hot callers inside `analyze_structure` /
# `_build_structure` thread a single dict through to amortize the work.
const _WCCache = IdDict{Tuple{Type,Symbol}, Any}

_print_struct_worst_case(types_in_tree, parents, T::Type, prop_name::Symbol, info) =
    _print_struct_worst_case(types_in_tree, parents, T, prop_name, info, _WCCache())

function _print_struct_worst_case(types_in_tree, parents, T::Type,
                                  prop_name::Symbol, info, cache::_WCCache)
    key = (T, prop_name)
    haskey(cache, key) && return cache[key]
    raw = _raw_worst_case(types_in_tree, parents, T, prop_name, info)
    result = if raw === nothing
        nothing
    elseif raw[1] === :none
        raw
    else
        expanded = Set{Symbol}()
        for n in raw[2]
            _expand_name!(expanded, n, types_in_tree, parents, Set{Symbol}())
        end
        (:bound, sort!(collect(expanded)))
    end
    cache[key] = result
    result
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
        # Color fingerprint cares about per-name identity; iterate the unique
        # names in the order `meta(T)` declared them (sorted for stable color
        # assignment), then look up the first matching info.
        seen_names = Set{Symbol}()
        unique_names = Symbol[]
        for (n, _) in props
            n in seen_names && continue
            push!(seen_names, n); push!(unique_names, n)
        end
        for name in sort!(unique_names)
            _print_struct_skip(T, name) && continue
            info = metafirst(T, name)
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
        # Render every declaration in declaration order — duplicates are kept,
        # since each yields its own `compute_property` method and deserves its
        # own line. Sorting by name groups duplicates together; secondary key
        # is the original index for a stable order within a group.
        pairs_with_idx = [(i, name, info) for (i, (name, info)) in enumerate(props)]
        sort!(pairs_with_idx; by=t -> (t[2], t[1]))
        for (_, name, info) in pairs_with_idx
            _print_struct_skip(T, name) && continue
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

"""    tree_children_map(root::Type) -> Dict{Type, Vector{Tuple{Symbol, Type}}}

Build a `parent → [(prop_name, child_type), …]` map for every DO/HTMXO
type reachable from `root`. Children are sorted alphabetically by `prop_name`.
The inverse of `_build_parent_map`. Pure data — no rendering.
"""
function tree_children_map(root::Type)
    parent_map = _build_parent_map(root)
    children = Dict{Type, Vector{Tuple{Symbol, Type}}}()
    for (child, (parent, prop)) in parent_map
        push!(get!(children, parent, Tuple{Symbol, Type}[]), (prop, child))
    end
    for v in values(children)
        sort!(v; by = p -> string(p[1]))
    end
    children
end

"""    lint_index(root::Type) -> Dict{Type, NamedTuple{(:warns, :errors, :msgs), …}}

Group `analyze_structure(root)` output by `LintMessage.type`. Each entry
carries warn/error counts and the underlying messages. Returns an empty
Dict if `analyze_structure` throws (e.g. partially-defined tree).
"""
function lint_index(root::Type)
    msgs = try analyze_structure(root) catch; LintMessage[] end
    out = Dict{Type, NamedTuple{(:warns, :errors, :msgs), Tuple{Int, Int, Vector{LintMessage}}}}()
    for m in msgs
        e = get!(() -> (warns=0, errors=0, msgs=LintMessage[]), out, m.type)
        push!(e.msgs, m)
        out[m.type] = (
            warns  = e.warns  + (m.severity === :warn  ? 1 : 0),
            errors = e.errors + (m.severity === :error ? 1 : 0),
            msgs   = e.msgs,
        )
    end
    out
end

"""    lookup_type(root::Type, name::AbstractString) -> Union{Type, Nothing}

Find a DO/HTMXO type in the tree rooted at `root` by its bare `nameof`
string. Returns `nothing` if no match.
"""
function lookup_type(root::Type, name::AbstractString)
    for T in _all_types_in_tree(root)
        string(nameof(T)) == name && return T
    end
    nothing
end

"""    callers_by_name(prop::Symbol, root::Type) -> Vector{Tuple{Type, Symbol, Vector{Any}}}

Return every site (caller_type, caller_prop, arg_exprs) that calls a
property *named* `prop` anywhere in the tree rooted at `root`. Matches by
callee NAME, not by resolved owner type, so cross-type name collisions
appear together. Backed by `_build_call_index`.
"""
function callers_by_name(prop::Symbol, root::Type)
    types_in_tree = _all_types_in_tree(root)
    call_index = _build_call_index(types_in_tree)
    get(call_index, prop, Vector{Tuple{Type,Symbol,Vector{Any}}}())
end

"""    property_source_info(T::Type, prop::Symbol)
        -> Union{Nothing, NamedTuple{(:rhs_string, :signature, :macros, :dependson), …}}

Extract a property's RHS expression, signature, macro chain, and
dependson set from `meta(T)`. Returns:

- `nothing` if `meta(T)` is undefined,
- `(; rhs_string=:meta_missing, signature, …)` if the prop isn't on `T`,
- otherwise a NamedTuple with:
  - `rhs_string::String` — the lnn-stripped expression as a string, or
    `"(no rhs — forwarded/typed property)"` if `info.rhs === nothing`.
  - `signature::String` — `"name"` or `"name(arg, …)"`.
  - `macros::String` — `"@cached "` etc. (trailing space if non-empty).
  - `dependson::Vector{Symbol}` — sorted dependency names.

Pure data extraction. Renderers turn this into HTML / markdown /
terminal output.
"""
function property_source_info(T::Type, prop::Symbol)
    props = try meta(T) catch; nothing end
    props === nothing && return nothing
    # `metafirst` matches the previous `props[prop]` semantics: if duplicate
    # declarations exist, callers of `property_source_info` get the first.
    info = metafirst(T, prop)
    info === nothing && return (; rhs_string="(property $prop not found on $(nameof(T)))",
                                  signature=string(prop),
                                  macros="",
                                  dependson=Symbol[])
    rhs_string = info.rhs === nothing ? "(no rhs — forwarded/typed property)" :
                 string(Base.remove_linenums!(deepcopy(info.rhs)))
    signature = isempty(info.indices) ? string(info.lhs) :
                string(info.lhs, "(", join(info.indices, ", "), ")")
    macros = isempty(info.macros) ? "" : join(string.(info.macros), " ") * " "
    dependson = isempty(info.dependson) ? Symbol[] : sort!(collect(info.dependson))
    (; rhs_string, signature, macros, dependson)
end

export print_structure, structure
export tree_children_map, lint_index, lookup_type, callers_by_name, property_source_info, LintMessage
export metafirst, metaall

end