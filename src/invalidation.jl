# --- downstream invalidation ----------------------------------------------------

"""
    dependents(T::Type, name::Symbol) -> Vector{Symbol}

Every property of `T` whose value can change when `name`'s does, transitively —
the inverse of the `dependson` walk the macro runs on every property body. Exact
for source-visible sibling reads; a value reached some other way (a global, or
`__self__` handed to foreign code) is invisible to it, exactly as for
[`remake`](@ref)'s carry-over. Sorted; excludes `name` itself.
"""
dependents(T::Type, name::Symbol) = sort!(collect(_dependents_of(T, (name,))))

# Union over `names` of each one's transitive dependents. A name in `names` is
# included only when it depends on ANOTHER name in the set: a changed slot keeps
# its own value (the same container observed the change), but a slot derived from
# a different changed one is stale like any other dependent.
_dependents_of(T::Type, names) = _dependents_in(_dependency_map(T), names)

function _dependency_map(T::Type)
    dependencies = Dict{Symbol,Set{Symbol}}()
    for (name, info) in meta(T)
        deps = get(info, :dependson, nothing)
        deps === nothing || union!(get!(() -> Set{Symbol}(), dependencies, name), deps)
    end
    dependencies
end

# Per-object sync state, anchored on the retained cache's lock: a DO object is an
# immutable struct and cannot be weakly referenced, its cache lock can. A remount
# view resolves to its retained source, so the source and every view share one
# record — the shared cache is what holds the derived values.
mutable struct _SyncRecord
    # slot (`name`, or `(name, indexed key)`) => (objectid of the observed value, version)
    stamps::Dict{Any,Tuple{UInt,UInt64}}
    generation::UInt64
end

const _SYNC_LOCK = ReentrantLock()
const _SYNC_RECORDS = WeakKeyDict{ReentrantLock,_SyncRecord}()

_sync_record(shared::ThreadsafeDict) = lock(_SYNC_LOCK) do
    get!(() -> _SyncRecord(Dict{Any,Tuple{UInt,UInt64}}(), UInt64(1)), _SYNC_RECORDS, shared.lock)
end

# An invalidation dropped values of `record`'s object: its version moves, so a
# holder drops what it derived from the object on its next `sync!`, which from
# now on has a version to observe. Call under `_SYNC_LOCK`.
function _version_moved!(record::_SyncRecord)
    record.generation += UInt64(1)
    _TRACKED_IN_USE[] = true
    nothing
end

# `clear_mem_caches!(o)` dropped the derived values `dropped`: their sync stamps go
# with them, as `_drop_targets!` forgets a dropped slot's, and `o`'s version moves.
# After the clear, never before it: a holder synced in between would recompute from
# the values about to be dropped and stamp the moved version.
function _object_cleared!(o, dropped)
    lock(_SYNC_LOCK) do
        record = _sync_record(last(_remount_source(o)))
        filter!(p -> !(_slot_name(first(p)) in dropped), record.stamps)
        _version_moved!(record)
    end
end

"""
    object_version(o) -> UInt64

Monotone count of the changes [`sync!`](@ref) has observed through `o` — a
tracked value it holds moving, or a nested object it holds changing — and of
the invalidations that dropped values of `o` (`DynamicObjects.clear_cache!`,
[`clear_mem_caches!`](@ref)). The aggregate a holder watches: `sync!` stamps
each child's version per holder, so a child shared by several parents reports
its change to each, whenever each looks. A remount view reports its retained
object's number. Eviction ([`prune_mem_caches!`](@ref)) does not move it.
"""
function object_version(o)
    _is_dynamic_object(o) ||
        throw(ArgumentError("object_version: $(typeof(o)) is not a @dynamicstruct object"))
    _sync_record(last(_remount_source(o))).generation
end

"""
    sync!(o) -> Vector{Symbol}

Bring `o`'s cache up to date with the tracked values it holds, and return the
names of `o`'s properties dropped (sorted).

Every fixed field and every already-computed property of `o` — including each
settled entry of an indexed property — is examined:

- a [`TrackedFile`](@ref) / [`TrackedDirectory`](@ref) is polled and its
  [`tracked_version`](@ref) compared with the one seen last time;
- a nested `@dynamicstruct` object (directly, as an indexed-property entry, as
  a `TrackedDirectory` value, or as an element of an array, tuple or dict) is
  synced first, and its [`object_version`](@ref) compared the same way.

Where a version moved, the transitive [`dependents`](@ref) of that property are
dropped — memory, and the disk entry of a `@cached` / `@mmap` dependent — so the
next read recomputes them. The changed slot itself is kept: it is the same
container (or object) that observed the change.

The children `o` holds — inline `@struct` children, and any object constructed
with `__parent__ = o` held where `sync!` looks — drop what they read of a dropped
or changed property of `o`, and what they derived from it. A child reads a parent
property through a forwarded (bare) name, `__parent__.name`,
`__self__.__parent__.name` or `(; name) = __parent__`; a forwarded copy still
holding the very value `o` keeps stays. The child instance, its inputs and its
`@state` are kept, and `o` drops what it derived from a child that dropped
something in the same call. A dropped indexed property loses
all its entries. A file changing under one entry of `@struct run(id) = …` drops
only that child's own derived properties, plus whatever the parent derived from
`run`. A `@state` property is never dropped, even when a fixed field its
initializer read moved; what reads the state still drops when the state's own
value observes a change.

On an object with a computed `@versioned` property, dropping anything also drops
that property, what reads it (memory only) and the cache path, so the next read
re-derives the version and publishes recomputed values under it; its children's
cache paths, which extend it, move with it. A fixed
`@versioned` field is kept: move it with [`remake`](@ref).

A slot `sync!` has not stamped yet compares against the version its value had
when it was first read, so a change between a dependent's computation and the
first `sync!` is still a change.

Computes nothing: only values already in memory are examined, at the cost of one
probe per tracked file plus a walk of the cached entries. Each object is synced
once per call however many parents hold it; `__parent__` back-references are not
followed. On a [`remount`](@ref) view it syncs the retained object and then
drops the view's own copies of the dropped names, and its child views' copies
of what they read of them. `sync!` of a value that is not
a `@dynamicstruct` object returns `Symbol[]`: it holds no property cache.

Call it where a host decides what to serve. HTMXObjects' root provider calls it
on every request root. In-flight semantics follow [`invalidate!`](@ref): a
compute running when its entry is dropped stores nothing, and the next read
recomputes.
"""
function sync!(o)
    (_TRACKED_IN_USE[] && _is_dynamic_object(o)) || return Symbol[]
    forward = _invalidation_address(o)
    dropped = lock(_SYNC_LOCK) do
        copy(first(_sync!(o, IdDict{Any,Any}())))
    end
    isempty(dropped) || _forward_invalidation(forward, :sync!)
    dropped
end

const _SYNC_BACKREFS = (:__parent__, :__self__)

_settled_snapshot(c::AbstractThreadsafeDict) = lock(c.lock) do; collect(pairs(c.cache)); end

# Returns `(dropped, targets, moved)`: the names dropped from memory, every name
# found stale, and the slots whose kept value observed a change (a remount view
# drops its own copies of the stale names, and its children's reads of both).
const _NOTHING_STALE = (Symbol[], Set{Symbol}(), Set{Symbol}())

function _sync!(o, visited)
    source, shared = _remount_source(o)
    source === o || return _sync_view!(o, source, visited)
    record = _sync_record(shared)
    # Also the cycle guard: an object still being synced reports nothing.
    haskey(visited, record) && return visited[record]
    visited[record] = _NOTHING_STALE
    changed = Set{Symbol}()
    for field in fieldnames(typeof(o))
        (field === :cache || field in _SYNC_BACKREFS) && continue
        _observe_slot!(changed, record, field, field, getfield(o, field), visited)
    end
    for (name, value) in _settled_snapshot(shared)
        name in _SYNC_BACKREFS && continue
        if value isa IndexableProperty
            for (key, entry) in _settled_snapshot(value.cache)
                _observe_slot!(changed, record, (name, key), name, entry, visited)
            end
        else
            _observe_slot!(changed, record, name, name, value, visited)
        end
    end
    isempty(changed) && return _NOTHING_STALE
    # Bump even when nothing here was cached: a holder may have derived from the
    # changed slot through this object (`length(store.files)`).
    record.generation += UInt64(1)
    # `@state` is never derived, so no observed change makes it stale; its
    # ordinary dependents still drop.
    targets = setdiff!(_dependents_of(typeof(o), changed), _state_names(typeof(o)))
    dropped, stale = _drop_targets!(o, shared, record, targets; moved=changed)
    isempty(dropped) || _trace_invalidation!(:sync!, o, dropped)
    visited[record] = (dropped, stale, changed)
end

# Drop `targets` from a retained object (`_drop_property!`) and forget their sync
# stamps. The children it holds drop what they read of those names and of the
# `moved` ones — slots whose kept value observed a change — (`_drop_child_reads!`),
# and then this object drops what it derived from those children, until nothing
# more is stale. Dropping anything re-keys a computed `@versioned` version; a
# re-keyed object, or one whose parent's cache path moved (`repath`), drops its
# cache path after every disk drop, and so do the children whose path derives
# from it. `stored` also removes the disk entries that are not in memory, as
# `clear_cache!` does. Returns `(dropped, stale)`: the names that held a value
# (in memory, or on disk with `stored`), and every name now unset.
function _drop_targets!(o, shared::ThreadsafeDict, record::_SyncRecord, targets;
                        moved=(), stored::Bool=false, repath::Bool=false, verb::Symbol=:sync!,
                        facts=IdDict{Type,Any}())
    T = typeof(o)
    f = _type_facts(facts, T)
    dropped = Symbol[]
    stale = Set{Symbol}()
    reach = union(Set{Symbol}(moved), targets)
    rekeyed = false
    while !isempty(reach)
        stored && append!(dropped, (n for n in sort!(collect(targets)) if _drop_stored_entries!(o, shared, n)))
        filter!(p -> !(_slot_name(first(p)) in targets), record.stamps)
        append!(dropped, (n for n in sort!(collect(targets)) if _drop_property!(o, shared, n)))
        union!(stale, targets)
        # After the drops above: their disk entries live under the current cache path.
        rekey = rekeyed || isempty(stale) ? nothing : _version_rekey(T, stale)
        if rekey !== nothing
            filter!(p -> !(_slot_name(first(p)) in rekey), record.stamps)
            append!(dropped, (n for n in sort!(collect(rekey)) if _drop_property!(o, shared, n; disk=false)))
            union!(stale, rekey)
            union!(reach, rekey)
            rekeyed = true
        end
        holders = _drop_child_reads!(o, shared, record, reach; stored, verb, facts)
        targets = setdiff!(setdiff!(_dependents_in(f.dependencies, holders), f.state), stale)
        reach = copy(targets)
    end
    repath = repath && f.derives_path
    rekeyed && maybepop!(shared, :__version_tag__)
    (rekeyed || repath) && maybepop!(shared, :__cache_path__)
    (rekeyed || repath) && _drop_child_reads!(o, shared, record, (); stored, repath=true, verb, facts)
    (sort!(unique!(dropped)), stale)
end

# What the children `o` holds read of its properties named in `reach`. A child is
# a `@dynamicstruct` object constructed with `__parent__ = o` (an inline `@struct`
# child, an `@include`d struct, `File(; __parent__=__self__, path)`), held where
# `sync!` looks (`_held_children`). Each drops its reads and what it derived from
# them (`_drop_parent_reads!`), recursively, and its `object_version` moves when
# anything went. Returns the names of `o`'s slots holding a child that dropped
# something: what `o` derived from those slots is stale too.
function _drop_child_reads!(o, shared::ThreadsafeDict, record::_SyncRecord, reach;
                            stored::Bool, repath::Bool=false, verb::Symbol, facts)
    holders = Set{Symbol}()
    isempty(reach) && !repath && return holders
    moves = IdDict{Any,Any}()
    for (slot, name, value, child) in _held_children(o, shared)
        from = get!(moves, child) do
            _drop_parent_reads!(child, o, shared, reach; stored, repath, verb, facts)
        end
        from === nothing && continue
        push!(holders, name)
        # `o` drops what it derived from this slot now, so a stamp that saw the
        # child's previous version moves with it: `o`'s next `sync!` must not drop
        # the recomputed values again. (A container's stamp is a combined version;
        # its next `sync!` drops its dependents once more.)
        value === child && _advance_stamp!(record, slot, child, from)
    end
    holders
end

# Drop `child`'s properties that read a parent property named in `reach`, and
# what it derived from them. An alias (`_parent_alias`) still holding the very
# value its parent keeps — a tracked value that observed the change, an indexed
# wrapper emptied in place — stays; only what derives from it goes. Inputs
# (`__parent__`, index arguments, overrides) and `@state` stay. Returns the
# child's `object_version` before it moved, or `nothing` when nothing went.
function _drop_parent_reads!(child, parent, pshared::ThreadsafeDict, reach;
                             stored::Bool, repath::Bool, verb::Symbol, facts)
    source, shared = _remount_source(child)
    targets = _parent_read_targets(_type_facts(facts, typeof(source)), source, shared, parent, pshared, reach)
    isempty(targets) && !repath && return nothing
    record = _sync_record(shared)
    dropped, _ = _drop_targets!(source, shared, record, targets; stored, repath, verb, facts)
    isempty(dropped) && return nothing
    _trace_invalidation!(verb, source, dropped)
    from = record.generation
    record.generation += UInt64(1)
    from
end

# What the drop step needs of a type, computed once per `sync!` / `clear_cache!`.
struct _TypeFacts
    dependencies::_DependencyGraph
    reads::Vector{Tuple{Symbol,Set{Symbol},Union{Symbol,Nothing}}}
    state::Vector{Symbol}
    derives_path::Bool
end

_type_facts(facts::IdDict{Type,Any}, T::Type) = get!(facts, T) do
    _TypeFacts(_DependencyGraph(_dependency_map(T)), _parent_read_table(T), collect(Symbol, _state_names(T)),
               _derives_parent_path(T))
end::_TypeFacts

# `(name, parent reads, alias target)` for each property of `T` whose body reads
# its parent's properties as `__parent__.name` or `__self__.__parent__.name`:
# every name an inline child forwards, any authored read, and a destructure
# `(; a, b) = __self__.__parent__`, which binds the parent to a temporary first.
# The alias target is the name a body that is exactly such a read copies. A
# parent handed to other code is opaque here, as `__self__` is to `dependents`.
function _parent_read_table(T::Type)
    bodies = [(name, get(info, :rhs, nothing)) for (name, info) in meta(T)]
    handles = Set{Any}(_PARENT_REFS)
    for (name, rhs) in bodies
        rhs in _PARENT_REFS && push!(handles, name, :(__self__.$name))
    end
    table = Tuple{Symbol,Set{Symbol},Union{Symbol,Nothing}}[]
    for (name, rhs) in bodies
        names = _parent_reads!(Set{Symbol}(), rhs, handles)
        isempty(names) || push!(table, (name, names, _parent_read(rhs, handles)))
    end
    table
end

const _PARENT_REFS = (:__parent__, :(__self__.__parent__))

_parent_read(ex, handles) = Meta.isexpr(ex, :., 2) && ex.args[2] isa QuoteNode &&
    ex.args[2].value isa Symbol && ex.args[1] in handles ? ex.args[2].value : nothing

_parent_reads!(names, _, handles) = names
function _parent_reads!(names, ex::Expr, handles)
    target = _parent_read(ex, handles)
    target === nothing || push!(names, target)
    foreach(arg -> _parent_reads!(names, arg, handles), ex.args)
    names
end

# An inline child's cache path extends its parent's (`joinpath(__parent__.__cache_path__, …)`).
_derives_parent_path(T::Type) = any(((n, info),) -> n === :__cache_path__ &&
    :__cache_path__ in _parent_reads!(Set{Symbol}(), get(info, :rhs, nothing), _PARENT_REFS), meta(T))

# What `child` (cache `c`) must drop when its parent's (`pc`) names in `reach`
# moved: its properties reading one of them, and what derives from those. An alias
# still holding the very value its parent holds stays (only what derives from it
# goes); inputs and `@state` stay.
function _parent_read_targets(f::_TypeFacts, child, c, parent, pc, reach)
    inputs = keys(getfield(child, :cache).seed)
    reads = Set{Symbol}()
    kept = Set{Symbol}()
    for (name, names, target) in f.reads
        (name in inputs || isdisjoint(names, reach)) && continue
        holds = target !== nothing && _same_value(_peek(child, c, name), _peek(parent, pc, target))
        push!(holds ? kept : reads, name)
    end
    setdiff!(union!(_dependents_in(f.dependencies, union(reads, kept)), reads), f.state, inputs)
end

# A value of an object without computing it: a fixed field, or what its cache
# (`c`, a view's routing local and shared names) holds; `_missing_sentinel` when nothing.
_peek(o, c::AbstractThreadsafeDict, name::Symbol) = name !== :cache && hasfield(typeof(o), name) ?
    getfield(o, name) : get(c, name, _missing_sentinel)
_same_value(a, b) = a !== _missing_sentinel && a === b

# A holder that stamped `child` at exactly `from` already dropped what it derived
# from it: stamp the version the child moved to.
function _advance_stamp!(record::_SyncRecord, slot, child, from)
    id = objectid(child)
    stamp = get(record.stamps, slot, nothing)
    seen = stamp !== nothing && first(stamp) == id ? last(stamp) : UInt64(1)
    seen == from && (record.stamps[slot] = (id, object_version(child)))
    nothing
end

# The children a retained cache holds, as `(slot, name, value, child)`: each object
# constructed with `__parent__` set to its owner, found where `sync!` looks — a
# property value or indexed entry (`value` is what the slot holds), a
# `TrackedDirectory` value, or an element of an array, tuple or dict.
function _held_children(o, shared::ThreadsafeDict)
    held = Tuple{Any,Symbol,Any,Any}[]
    for (name, value) in _settled_snapshot(shared)
        name in _SYNC_BACKREFS && continue
        if _own_wrapper(o, name, value)
            for (key, entry) in _settled_snapshot(value.cache)
                _push_children!(held, shared, (name, key), name, entry)
            end
        else
            _push_children!(held, shared, name, name, value)
        end
    end
    held
end

function _push_children!(held, shared, slot, name, value)
    for object in _held_objects(value)
        _parent_cache(object) === shared && push!(held, (slot, name, value, object))
    end
end

_held_objects(value) = _is_dynamic_object(value) ? (value,) : _contained_objects(_container_elements(value))
_held_objects(d::TrackedDirectory) = _element_objects(d)
_contained_objects(::Tuple{}) = ()
_contained_objects(elements) = Any[object for element in elements for object in _element_objects(element)]
_element_objects(value) = _is_dynamic_object(value) ? (value,) : ()
_element_objects(d::TrackedDirectory) =
    Any[v for v in lock(() -> collect(values(d.values)), d.state.lock) if _is_dynamic_object(v)]

function _parent_cache(object)
    parent = get(getfield(object, :cache).seed, :__parent__, nothing)
    _is_dynamic_object(parent) ? last(_remount_source(parent)) : nothing
end

# `clear_cache!(o, name)`: drop `name` and its transitive dependents, keeping the
# object's inputs (fixed fields, construction/`remake` overrides). Unlike `sync!`,
# the drop reaches disk entries that are not in memory — a forced property must
# not reload what an earlier process stored — and `name` itself goes too. The
# version moves only when something was dropped, so holders drop their own
# dependents of this object on their next `sync!`.
function _invalidate_property!(o, name::Symbol)
    source, shared = _remount_source(o)
    T = typeof(source)
    _check_invalidatable(T, name)
    inputs = keys(getfield(source, :cache).seed)
    targets = setdiff!(push!(_dependents_of(T, (name,)), name), inputs)
    result = lock(_SYNC_LOCK) do
        record = _sync_record(shared)
        dropped, stale = _drop_targets!(source, shared, record, targets; stored=true, verb=:clear_cache!)
        if source !== o
            append!(dropped, _drop_view_copies!(o, stale))
            _drop_view_child_reads!(o, stale, :clear_cache!)
        end
        result = sort!(unique!(dropped))
        isempty(result) || _version_moved!(record)
        result
    end
    _trace_invalidation!(:clear_cache!, o, result)
    result
end

function _check_invalidatable(T::Type, name::Symbol)
    infos = [info for (n, info) in meta(T) if n === name]
    isempty(infos) &&
        throw(ArgumentError("clear_cache!: $(nameof(T)) declares no property `$name`"))
    all(isfixed, infos) && throw(ArgumentError(
        "clear_cache!: `$name` is a fixed field of $(nameof(T)) — an input, not a cached value; " *
        "construct the object with a new value via `remake(obj; $name=…)`"))
    nothing
end

# Every disk entry `name` has — in memory or not, every indexed key — wherever
# `name` is stored on disk at all. Returns whether a file was removed.
function _drop_stored_entries!(o, shared::ThreadsafeDict, name::Symbol)
    _stored_on_disk(o, shared, name) || return false
    T = typeof(o)
    if any(((n, info),) -> n === name && get(info, :indexed, false), meta(T))
        dir = o.__cache_path__
        isdir(dir) || return false
        owners = _disk_owner_names(T)
        removed = false
        for file in readdir(dir)
            stem = _cache_file_stem(file)
            (stem === nothing || _disk_owner(owners, stem) !== name) && continue
            path = joinpath(dir, file)
            isfile(path) || continue
            rm(path; force=true)
            removed = true
        end
        removed
    else
        path = get_cache_path(o, name)
        removed = isfile(path) || isfile(_automatic_materialization_path(path))
        _remove_disk_entry!(o, name)
        removed
    end
end

# A cache file's stem: `name` for a bare property, `name_<args>` for an indexed
# entry (`cache_segment`). Temporary files of an in-flight write are not entries.
function _cache_file_stem(file::AbstractString)
    endswith(file, ".sjl") && return chop(file; tail=4)
    auto = ".sjl" * _AUTOMATIC_MATERIALIZATION_SUFFIX
    endswith(file, auto) && return chop(file; tail=ncodeunits(auto))
    nothing
end

# Declared names, longest first: `fit_summary.sjl` belongs to `fit_summary`, not
# to an entry of `fit`.
_disk_owner_names(T::Type) =
    sort!(unique!(Symbol[n for (n, _) in meta(T)]); by=n -> ncodeunits(string(n)), rev=true)

function _disk_owner(owners, stem::AbstractString)
    for n in owners
        s = string(n)
        (stem == s || startswith(stem, s * "_")) && return n
    end
    nothing
end

# A versioned object keys its disk entries by version, and a computed `@versioned`
# property is memoized like any other: without this, a dependent `sync!` drops is
# recomputed and published under the version the OLD content had, so a later
# process whose input matches that version reads the new value. So once anything
# is dropped, drop the computed version properties and what reads them too (memory
# only — their disk entries are valid for the old version), then the cache path:
# the next read re-derives the version and publishes under it. A fixed `@versioned`
# field is the caller's claim and cannot be re-derived (`remake` moves it).
# Returns the names to drop besides `targets`, or `nothing` when there is no
# computed version to re-derive.
function _version_rekey(T::Type, targets)
    isempty(targets) && return nothing
    versions = _computed_version_names(T)
    isempty(versions) && return nothing
    setdiff!(union!(Set{Symbol}(versions), _dependents_of(T, versions)), targets)
end

# `T`'s computed `@versioned` properties: what its cache path derives from besides the
# fixed fields. A fixed `@versioned` field is an input and not among them.
_computed_version_names(T::Type) = has_versioned_fields(T) ?
    Symbol[name for (name, info) in meta(T) if !isfixed(info) && Symbol("@versioned") in info.macros] :
    Symbol[]

_slot_name(slot::Symbol) = slot
_slot_name(slot::Tuple) = first(slot)

# A view syncs its retained object, then drops its own (view-local) copies of the
# stale names: a context-dependent property derived from a changed shared slot
# lives only in the view, never on the retained object.
function _sync_view!(view, source, visited)
    dropped, targets, moved = _sync!(source, visited)
    local_dropped = _drop_view_copies!(view, targets)
    isempty(local_dropped) || _trace_invalidation!(:sync!, view, local_dropped)
    _drop_view_child_reads!(view, union(targets, moved), :sync!)
    (sort!(union(dropped, local_dropped)), targets, moved)
end

# The children a view holds are views too, each with its own copies of what it
# read of the view: drop those of `reach`, and so on down. (Their shared work is
# the retained children's, which `_drop_child_reads!` reached.)
function _drop_view_child_reads!(view, reach, verb::Symbol, facts=IdDict{Type,Any}())
    isempty(reach) && return nothing
    c = getfield(view, :cache).cache
    for child in _view_children(view, c)
        cc = getfield(child, :cache).cache
        targets = _parent_read_targets(_type_facts(facts, typeof(child)), child, cc, view, c, reach)
        dropped = _drop_view_copies!(child, targets)
        isempty(dropped) || _trace_invalidation!(verb, child, dropped)
        _drop_view_child_reads!(child, targets, verb, facts)
    end
end

# The child views `view` holds in its own (view-local) entries, deduplicated.
function _view_children(view, c::MountedThreadsafeDict)
    entries = lock(() -> collect(values(c.cache.overlay)), c.lock)
    children = IdDict{Any,Nothing}()
    for value in entries
        values_held = value isa IndexableProperty ? last.(_settled_snapshot(value.cache)) : (value,)
        for held in values_held, object in _held_objects(held)
            get(getfield(object, :cache).seed, :__parent__, nothing) === view && (children[object] = nothing)
        end
    end
    collect(keys(children))
end
_view_children(view, ::AbstractThreadsafeDict) = ()

function _drop_view_copies!(view, targets)
    c = getfield(view, :cache).cache
    local_dropped = Symbol[]
    for name in targets
        name in c.local_names || continue
        value, in_flight = lock(c.lock) do
            (get(c.cache.overlay, name, _missing_sentinel), haskey(c.computing.overlay, name))
        end
        if value isa IndexableProperty
            length(value.cache) > 0 && push!(local_dropped, name)
            empty!(value.cache)
        elseif value !== _missing_sentinel || in_flight
            maybepop!(c, name)   # a computation in flight publishes nothing
            value !== _missing_sentinel && push!(local_dropped, name)
        end
    end
    local_dropped
end

function _observe_slot!(changed, record, slot, name, value, visited)
    observed = _observe(value, visited)
    observed === nothing && return nothing
    current, baseline = observed
    id = objectid(value)
    previous = get(record.stamps, slot, nothing)
    record.stamps[slot] = (id, current)
    reference = previous !== nothing && first(previous) == id ? last(previous) : baseline
    reference == current || push!(changed, name)
    nothing
end

# `(current, baseline)` versions of whatever is observable in `value`, or
# `nothing`. The baseline is what a holder that never stamped this value must
# assume its dependents saw.
function _observe(value, visited)
    observed = _observe_element(value, visited)
    observed === nothing ? _observe_container(value, visited) : observed
end

_observe_element(value, visited) =
    _is_dynamic_object(value) ? _observe_object(value, visited) : _observe_tracked(value, visited)

function _observe_object(child, visited)
    _sync!(child, visited)
    # A fresh object starts at generation 1, so 1 is what a holder that derived
    # from it before ever stamping it can have seen.
    (object_version(child), UInt64(1))
end

_observe_tracked(::Any, visited) = nothing
_observe_tracked(f::TrackedFile, visited) =
    (tracked_version(f), lock(f.state.lock) do; f.state.observed; end)
# A directory's memoized values may be objects holding tracked files of their own.
function _observe_tracked(d::TrackedDirectory, visited)
    version = tracked_version(d)
    baseline = lock(d.state.lock) do; d.state.observed; end
    children = _observe_elements(lock(d.state.lock) do; collect(values(d.values)); end, visited)
    children === nothing && return (version, baseline)
    (UInt64(hash(version, UInt(first(children)))), UInt64(hash(baseline, UInt(last(children)))))
end

function _observe_container(value, visited)
    elements = _container_elements(value)
    isempty(elements) ? nothing : _observe_elements(elements, visited)
end

# One level only: the elements of an array, tuple or dict that may be objects or
# tracked values. Deep data (parsed JSON trees, tables) is never walked, and a
# `TrackedDirectory` is observed as a tracked value, never iterated (iterating it
# reads its entries).
_container_elements(value::Union{AbstractArray,Tuple}) =
    _may_hold_observable(eltype(value)) ? value : ()
_container_elements(value::AbstractDict) =
    _may_hold_observable(valtype(value)) ? values(value) : ()
_container_elements(::TrackedDirectory) = ()
_container_elements(::Any) = ()

_may_hold_observable(::Type{T}) where {T} = !isconcretetype(T) || T <: TrackedValue ||
    (hasfield(T, :cache) && fieldtype(T, :cache) <: PropertyCache)

function _observe_elements(elements, visited)
    current = baseline = nothing
    for element in elements
        observed = _observe_element(element, visited)
        observed === nothing && continue
        current = UInt64(hash(first(observed), UInt(something(current, 0))))
        baseline = UInt64(hash(last(observed), UInt(something(baseline, 0))))
    end
    current === nothing ? nothing : (current, baseline)
end

# Drop one property of a retained object: its memory value (every entry of an
# indexed property, emptied in place so a mounted view or destructured handle
# sharing the subcache sees it) and any computation of it in flight, its disk
# entries unless `disk=false`, and its shared opaque-remount work. Memory goes
# first: a computation in flight then publishes nothing, and a disk entry it
# saved before noticing is removed here (`_save_if_publishable!`). Returns
# whether anything was in memory.
function _drop_property!(o, shared::ThreadsafeDict, name::Symbol; disk::Bool=true)
    value, in_flight = lock(shared.lock) do
        (get(shared.cache, name, _missing_sentinel), haskey(shared.computing, name))
    end
    dropped = if value isa IndexableProperty
        held, entry_keys = lock(value.cache.lock) do
            held = collect(keys(value.cache.cache))
            (held, union(held, keys(value.cache.computing)))
        end
        empty!(value.cache)
        disk && _drop_disk_entries!(o, shared, name, entry_keys)
        !isempty(held)
    elseif value !== _missing_sentinel || in_flight
        maybepop!(shared, name)
        disk && _drop_disk_entries!(o, shared, name, (((), (;)),))
        value !== _missing_sentinel
    else
        false
    end
    _drop_opaque_work!(shared, name) || dropped
end

# Disk entries exist only for an explicit `@cached`/`@mmap` property, or for an
# object whose cache path is already computed (governed automatic storage).
_stored_on_disk(o, shared::ThreadsafeDict, name::Symbol) =
    any(((n, info),) -> n === name &&
        !isdisjoint(get(info, :macros, ()), (Symbol("@cached"), Symbol("@mmap"))), meta(typeof(o))) ||
    haskey(shared, :__cache_path__)

function _drop_disk_entries!(o, shared::ThreadsafeDict, name::Symbol, entry_keys)
    _stored_on_disk(o, shared, name) || return nothing
    for (indices, kwargs) in entry_keys
        _remove_disk_entry!(o, name, indices...; kwargs...)
    end
    nothing
end

# The opaque-work namespaces a retained cache holds for its remount views.
_remount_namespaces(shared::ThreadsafeDict) = lock(shared.lock) do
    byset = get(shared.status, _REMOUNT_NAMESPACES_KEY, nothing)
    byset === nothing ? _OpaqueNamespace[] : collect(values(byset))
end

function _drop_opaque_work!(shared::ThreadsafeDict, name::Symbol)
    dropped = false
    for ns in _remount_namespaces(shared)
        sub = lock(() -> get(ns.subcaches, name, nothing), ns.lock)
        if sub !== nothing && length(sub) > 0
            empty!(sub)
            dropped = true
        end
        if haskey(ns.cache, name)
            maybepop!(ns.cache, name)
            dropped = true
        end
    end
    dropped
end

