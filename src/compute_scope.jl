# Cache ownership is recorded at latch acquisition, before a second requester can join.
# Different views of the same physical dictionary must share the same ownership record.
struct _TargetLifetimes
    last_use::Dict{Symbol,Int}
    uncertain_until::Int
end

# A queued result can be read in two processes. Its caller cache generation
# owns one claim on the worker generation, including across caller-only hits.
struct _WorkerResultPin
    conn::_WorkerConn
    worker::Any
    request::Int
end

mutable struct _ComputeScope
    # Each claim goes directly into its last target's bucket. Finishing a
    # target never scans the other targets' intermediates.
    entries::Dict{Int,Base.IdSet{Any}}
    lifetimes::Union{Nothing,_TargetLifetimes}
    target::Int
    parent::Union{Nothing,_ComputeScope}  # executing queued/deferred job inside a scope
    protected_names::IdDict{Type,Set{Symbol}}
    workers::IdDict{Any,Any}
    releases::Vector{Tuple{_WorkerResultPin,Bool}}
    closed::Bool
    remote_lock::ReentrantLock
end

const _COMPUTE_SCOPE = ScopedValues.ScopedValue{Union{Nothing,_ComputeScope}}(nothing)
const _SCOPE_LOCK = ReentrantLock()
const _OPEN_SCOPE_COUNT = Threads.Atomic{Int}(0)

mutable struct _ScopeEntry
    slot::_MemSlot
    name::Symbol
    owners::IdDict{_ComputeScope,Int}
    pending_result::Union{Nothing,Base.RefValue{Any}}
    worker_result::Union{Nothing,_WorkerResultPin}
    memo::Union{Nothing,_RetainedMemo}
    adopted::Bool
end

const _SCOPE_SLOTS = IdDict{Any,Dict{Any,_ScopeEntry}}()

_scope_dict(d, key) = d
_scope_dict(d::MountedDict, key) = _scope_dict(_mounted_dict(d, key), key)
_scope_dict(d::_TaintingDict, key) = d.inner

# Called under _SCOPE_LOCK. The cache lock guards its physical dictionary.
function _scope_entry(c, key)
    entries = get(_SCOPE_SLOTS, _scope_dict(c.cache, key), nothing)
    entries === nothing ? nothing : get(entries, key, nothing)
end

function _new_compute_scope(lifetimes=nothing, target=1; parent=nothing)
    protected = parent === nothing ? IdDict{Type,Set{Symbol}}() : parent.protected_names
    scope = _ComputeScope(Dict{Int,Base.IdSet{Any}}(), lifetimes, target, parent,
                          protected, IdDict{Any,Any}(), Tuple{_WorkerResultPin,Bool}[], false, ReentrantLock())
    Threads.atomic_add!(_OPEN_SCOPE_COUNT, 1)
    scope
end

# Caller holds _SCOPE_LOCK. A new writer or an ordinary reader adopts the slot.
function _forget_scope_entry!(entry; adopt=false, releasing=nothing)
    if entry.worker_result !== nothing
        owner = releasing === nothing ? first(keys(entry.owners)) : releasing
        push!(owner.releases, (entry.worker_result, adopt))
        entry.worker_result = nothing
    end
    adopt && entry.memo !== nothing && _register_memo!(entry.memo)
    slot = entry.slot
    entries = _SCOPE_SLOTS[slot.cache]
    delete!(entries, slot.key)
    isempty(entries) && delete!(_SCOPE_SLOTS, slot.cache)
    for (owner, deadline) in entry.owners
        delete!(owner.entries[deadline], entry)
    end
    empty!(entry.owners)
    nothing
end

function _claim_scope_entry!(entry, scope)
    if scope === nothing || scope.closed
        if !_memo_retention_enabled()
            _forget_scope_entry!(entry; adopt=true)
        else
            # Other readers still own this generation until their last target.
            entry.adopted = true
        end
        return
    end
    # A managed job can outlive its enclosing scope. Its own claim lasts until
    # the job finishes, and the report's claim lasts until all targets finish.
    while scope !== nothing
        if !scope.closed && !haskey(entry.owners, scope)
            plan = scope.lifetimes
            deadline = plan === nothing ? 0 :
                max(scope.target, plan.uncertain_until, get(plan.last_use, entry.name, 0))
            entry.owners[scope] = deadline
            bucket = get!(() -> Base.IdSet{Any}(), scope.entries, deadline)
            push!(bucket, entry)
        end
        scope = scope.parent
    end
    nothing
end

# Called under the cache lock on hits and joins. Pre-existing ordinary memos
# are borrowed only when they participate in automatic retention.
@inline function _on_hit!(c::AbstractThreadsafeDict, key)
    _OPEN_SCOPE_COUNT[] == 0 || _share_scope_entry!(c, key)
    _memo_retention_enabled() && _touch_memo!(c, key)
    nothing
end

function _share_scope_entry!(c, key)
    lock(_SCOPE_LOCK) do
        entry = _scope_entry(c, key)
        scope = _COMPUTE_SCOPE[]
        if entry === nothing && scope !== nothing && !scope.closed && _memo_retention_enabled()
            store = _scope_dict(c.cache, key)
            m = store isa _MemoValues ? get(store.raw, key, nothing) : nothing
            if m isa _RetainedMemo
                # Borrow a pre-existing ordinary slot. Scope exit returns it to
                # the warm cache, including when several scopes borrowed it.
                _park_memo!(m)
                entry = _new_scope_entry!(c, key, m.name, m, true)
            end
        end
        entry === nothing || _claim_scope_entry!(entry, scope)
    end
end

# A wrapper or a constructor seed is never claimed. Only the ordinary property
# producers carry _Settling; state and identity have their existing prune roles.
_eligible_memo(protected_names, f, key) = false
function _eligible_memo(protected_names, f::_Settling, key)
    name, o = f.name, f.o
    _is_dunder(name) && return false
    key isa Symbol && haskey(getfield(o, :cache).seed, name) && return false
    # One metadata walk per type in the report, including its deferred jobs.
    protected = get!(protected_names, typeof(o)) do
        union!(Set{Symbol}(_state_names(typeof(o))), _computed_version_names(typeof(o)))
    end
    name ∉ protected
end

@inline function _scope_new_generation!(c, key, f)
    _OPEN_SCOPE_COUNT[] == 0 || _record_scope_generation!(c, key, f)
    nothing
end

function _record_scope_generation!(c, key, f)
    scope = _COMPUTE_SCOPE[]
    cache = _scope_dict(c.cache, key)
    lock(_SCOPE_LOCK) do
        entries = get(_SCOPE_SLOTS, cache, nothing)
        old = entries === nothing ? nothing : get(entries, key, nothing)
        old === nothing || _forget_scope_entry!(old)
        scope !== nothing && !scope.closed && _eligible_memo(scope.protected_names, f, key) || return
        entry = _new_scope_entry!(c, key, f.name, nothing, false)
        _claim_scope_entry!(entry, scope)
    end
end

function _new_scope_entry!(c, key, name, memo, adopted)
    store = _scope_dict(c.cache, key)
    entries = get!(() -> Dict{Any,_ScopeEntry}(), _SCOPE_SLOTS, store)
    slot = _MemSlot(c.lock, store, _scope_dict(c.computing, key), _scope_dict(c.status, key), key)
    entry = _ScopeEntry(slot, name, IdDict{_ComputeScope,Int}(), nothing, nothing, memo, adopted)
    entries[key] = entry
    entry
end

# A pending handle may cross the scope boundary after its job already finished.
# Hand that handle the settled value when evicting the slot. Only handles keep
# this cell afterwards; a later normal read of the property still recomputes.
struct _ScopeResolver{F}
    retry::F
    saved::Base.RefValue{Any}
end
(r::_ScopeResolver)() = r.retry()
_pending_saved(resolve) = _missing_sentinel
_pending_saved(resolve::_ScopeResolver) = resolve.saved[]  # under the cache lock

function _scope_resolver(retry, c, key)
    _OPEN_SCOPE_COUNT[] == 0 && return retry
    lock(c.lock) do
        lock(_SCOPE_LOCK) do
            entry = _scope_entry(c, key)
            entry === nothing && return retry
            if entry.pending_result === nothing
                entry.pending_result = Ref{Any}(_missing_sentinel)
            end
            _ScopeResolver(retry, entry.pending_result)
        end
    end
end

function _release_scope_entry!(scope, entry)
    slot = entry.slot
    lock(slot.lock) do
        lock(_SCOPE_LOCK) do
            deadline = get(entry.owners, scope, nothing)
            deadline === nothing && return
            delete!(scope.entries[deadline], entry)
            delete!(entry.owners, scope)
            isempty(entry.owners) || return
            # An escaped computation still owns its latch and must publish for its callers.
            computing = haskey(slot.computing, slot.key)
            adopt = computing || entry.adopted
            _forget_scope_entry!(entry; adopt, releasing=scope)
            adopt && return
            haskey(slot.cache, slot.key) || return
            if entry.pending_result !== nothing
                entry.pending_result[] = slot.cache[slot.key]
            end
            delete!(slot.cache, slot.key)
            delete!(slot.status, slot.key)
        end
    end
end

function _close_compute_scope!(scope)
    entries = lock(_SCOPE_LOCK) do
        scope.closed = true
        [entry for bucket in values(scope.entries) for entry in bucket]
    end
    try
        foreach(entry -> _release_scope_entry!(scope, entry), entries)
        _release_scope_workers!(scope)
    finally
        Threads.atomic_sub!(_OPEN_SCOPE_COUNT, 1)
    end
    nothing
end

function _in_compute_work(work)
    parent = _COMPUTE_SCOPE[]
    parent === nothing && return work()
    _with_compute_scope(work, _new_compute_scope(; parent))
end

"""
    with_compute_scope(f)

Run `f()` and return its result. Newly memoized derived values are shared across
its reads, including joined tasks and queued worker computations. On return or
exception, release this scope's entries in each process. Other open scopes keep
entries they have read until their own last use. A reader outside a scope adopts
an entry into the ordinary cache. Pre-existing cache entries, inputs, state,
disk files and the values returned to callers keep their usual lifetime.

Use one scope around targets which might reuse a result, such as the table and
figure in a report. A nested scope marks a known earlier last use. Join tasks
and fetch pending targets inside their scope to include their whole computation.
An unfinished computation continues and can still deliver its result.
"""
with_compute_scope(f) = _with_compute_scope(f, _new_compute_scope())

function _with_compute_scope(f, scope)
    try
        ScopedValues.with(f, _COMPUTE_SCOPE => scope)
    finally
        _close_compute_scope!(scope)
    end
end

# Ordinary Julia callbacks can read arbitrary objects, including globals. An
# unrecognised expression therefore extends the lifetime of every scoped entry.
# Only simple declared reads are a proof that other entries can be released.
_local_reads_only(x, declared) = x isa Union{Number,AbstractString,Char,QuoteNode,LineNumberNode,Nothing} ||
    (x isa Symbol && x in declared)
function _local_reads_only(x::Expr, declared)
    x.head in (:block, :tuple) || return false
    all(arg -> _local_reads_only(arg, declared), x.args)
end

# Walk from the last requested target backwards. The first visit to a name is
# its last possible use; shared subgraphs and cycles cost one visit per name.
function _target_lifetimes(T, targets)
    infos = meta(T)
    declared = Set{Symbol}(name for (name, _) in infos)
    dependencies = _dependency_map(T)
    opaque = Set{Symbol}(something(_remount_opaque_properties(T), declared))
    # A settlement hook can read another property even when its own RHS is a
    # literal. In that case use the explicit report boundary for this type.
    signature = Tuple{typeof(property_settled),T,Val,Any,Vararg{Any}}
    hook = any(m -> m.module !== @__MODULE__() && typeintersect(m.sig, signature) !== Union{},
               methods(property_settled))
    for (name, info) in infos
        # Indexed argument defaults and constructor-supplied callables can
        # invoke user code outside the source-visible RHS.
        if hook || get(info, :indexed, false) || !_local_reads_only(get(info, :rhs, nothing), declared)
            push!(opaque, name)
        end
    end
    last_use = Dict{Symbol,Int}()
    uncertain_until = 0
    for i in reverse(eachindex(targets))
        name = targets[i].property
        name in declared || throw(ArgumentError("unknown property `$name` on $T"))
        todo = [name]
        while !isempty(todo)
            key = pop!(todo)
            haskey(last_use, key) && continue
            last_use[key] = i
            if key in opaque || !(key in declared)
                uncertain_until = max(uncertain_until, i)
            end
            append!(todo, get(dependencies, key, ()))
        end
    end
    _TargetLifetimes(last_use, uncertain_until)
end

function _target_delivered!(scope)
    step, entries = lock(_SCOPE_LOCK) do
        step = scope.target
        scope.target += 1
        (step, collect(get(scope.entries, step, ())))
    end
    foreach(entry -> _release_scope_entry!(scope, entry), entries)
    lock(() -> delete!(scope.entries, step), _SCOPE_LOCK)
    _flush_worker_results!(scope)
    _on_scope_workers!(scope, _worker_target_delivered!)
    nothing
end

_target_spec(name::Symbol) = (; property=name, args=(), kwargs=(;))
function _target_spec(t::NamedTuple)
    name, args, kwargs = t.property, get(t, :args, ()), get(t, :kwargs, (;))
    name isa Symbol && args isa Tuple && kwargs isa NamedTuple &&
        all(k -> k in (:property, :args, :kwargs), keys(t)) ||
        throw(ArgumentError("expected (; property::Symbol, args::Tuple, kwargs::NamedTuple)"))
    (; property=name, args, kwargs)
end

"""
    compute_targets(root, targets)

Compute the given properties in order and return their values in a vector.
Use a symbol for a bare property or a named tuple such as
`(; property=:fit, args=(2,), kwargs=(; draws=500))` for an indexed call.

This form knows the remaining targets. For simple, declared sibling reads it
releases derived entries at their last possible target. An arbitrary Julia
call or an unresolved dependency can read other entries, so such a target
keeps earlier results available through its execution. Indexed keys of the
same declaration are treated conservatively. For a dynamic set of requests or
application callbacks use [`with_compute_scope`](@ref).
"""
function compute_targets(root, targets)
    _is_dynamic_object(root) || throw(ArgumentError("expected a @dynamicstruct root"))
    specs = [_target_spec(t) for t in targets]
    scope = _new_compute_scope(_target_lifetimes(typeof(root), specs))
    _with_compute_scope(scope) do
        map(specs) do t
            value = if is_indexed_property(root, t.property)
                getproperty(root, t.property)(t.args...; t.kwargs...)
            else
                isempty(t.args) && isempty(t.kwargs) || throw(ArgumentError("bare property `$(t.property)` takes no arguments"))
                getproperty(root, t.property)
            end
            _target_delivered!(scope)
            value
        end
    end
end
