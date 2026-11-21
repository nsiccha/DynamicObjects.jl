# One latch identifies one publication, even when invalidation replaces a value
# by an identical object. Only holders of the old latch can read its delivery.
mutable struct _MemoLatch
    const condition::Threads.Condition
    saved::Any
    disk_path::Union{Nothing,String}
    stamp::Union{Nothing,Tuple{UInt,UInt,Int64,Float64,Float64}}
    mapped::Bool
    _MemoLatch(lk) = new(Threads.Condition(lk), _missing_sentinel, nothing, nothing, false)
end
Base.wait(l::_MemoLatch) = wait(l.condition)
Base.notify(l::_MemoLatch) = notify(l.condition)

# Only the physical value dictionary owns the generation. Replacing a slot,
# pruning, clearing an overlay or collecting the root releases it naturally.
# Every existing dictionary consumer continues to see the original value.
mutable struct _RetainedMemo
    const value::Any
    const store::Any
    const key::Any
    const name::Symbol
    const computing::Any
    const status::Any
    const lock::ReentrantLock
    const latch::_MemoLatch
    const native_bytes::Union{Nothing,Missing,Int}
    ticket::UInt
    disk::Bool
end
_unwrap_memo(v) = v
_unwrap_memo(m::_RetainedMemo) = m.value
# Restore serialized slots as ordinary values. Queue tickets and delivery
# latches identify a generation in the process that created it.
Serialization.serialize(s::Serialization.AbstractSerializer, m::_RetainedMemo) = Serialization.serialize(s, m.value)

# Remount and materialization ownership use the physical store as a weak
# identity token. An immutable wrapper could be collected while its Dict lives.
mutable struct _MemoValues{K,V} <: AbstractDict{K,V}
    const raw::Dict{K,V}
end
Base.length(d::_MemoValues) = length(d.raw)
Base.haskey(d::_MemoValues, k) = haskey(d.raw, k)
Base.get(d::_MemoValues, k, default) = _unwrap_memo(get(d.raw, k, default))
Base.getindex(d::_MemoValues, k) = _unwrap_memo(d.raw[k])
Base.setindex!(d::_MemoValues, v, k) = (d.raw[k] = v)
Base.delete!(d::_MemoValues, k) = (delete!(d.raw, k); d)
Base.empty!(d::_MemoValues) = (empty!(d.raw); d)
Base.pop!(d::_MemoValues, k) = _unwrap_memo(pop!(d.raw, k))
Base.pop!(d::_MemoValues, k, default) = _unwrap_memo(pop!(d.raw, k, default))
function Base.iterate(d::_MemoValues{K,V}, state...) where {K,V}
    entry = iterate(d.raw, state...)
    entry === nothing && return nothing
    (k, v), next = entry
    # Keep the dictionary's pair type across entries in heterogeneous stores.
    (Pair{K,V}(k, _unwrap_memo(v)), next)
end

# These ordered indexes hold neither a key, a cache nor its value. The third
# index visits two old tickets per addition, including below the pressure
# threshold, so short-lived roots leave no growing list of dead references.
const _MemoOrder = OrderedDict{UInt,WeakRef}
const _MEMO_DISK = _MemoOrder()
const _MEMO_RECENT = _MemoOrder()
const _MEMO_SWEEP = _MemoOrder()
const _MEMO_LOCK = ReentrantLock()
const _MEMO_TICKET = Ref(UInt(0))
const _MOST_RECENT_MEMO = Threads.Atomic{UInt}(0)
const _MEMO_EVICTED = Ref((disk=0, memory=0, estimated_payload_bytes=0, mapped_payload_bytes=0,
                           estimated_native_bytes=0, unknown_native_slots=0))
const _NEXT_MEMO_CHECK = Threads.Atomic{UInt64}(0)
const _MEMO_PROTECTED_NAMES = IdDict{Type,Set{Symbol}}()
const _TRIMMING_MEMOS = Threads.Atomic{Bool}(false)
const _HEAP_HINT = Ref(UInt64(0))
const _PROCESS_BUDGET = Ref(0)
const _NEXT_PROCESS_CHECK = Ref(UInt64(0)) # only the sampler writes this

# Only the task holding _TRIMMING_MEMOS updates the retry schedule. New
# eligible publications can earn an earlier attempt under _MEMO_LOCK.
mutable struct _ProcessTrimRetry
    last_excess::Int
    delay_ns::UInt64
    retry_at::UInt64
    bytes_until_retry::Int
end
const _PROCESS_RETRY = _ProcessTrimRetry(0, 0, 0, 0)
_memo_retention_enabled() = _HEAP_HINT[] != 0 || _PROCESS_BUDGET[] != 0

# Julia's heap estimate includes allocations since its last collection. A
# quick collection also counts old objects that have since died. Releases
# under heap pressure are decided on a full collection's measurement, Julia's
# own or one DynamicObjects runs, and one measurement decides at most one
# batch. Only the task holding _TRIMMING_MEMOS reads or writes this.
mutable struct _HeapMeasurement
    seen::Tuple{Int,Int} # (collections, full collections) at the last look
    pending::Union{Nothing,Int} # full measurement not yet used for a decision
    live::Int                   # live heap at the last decision
    batch::Int                  # slot limit for the next release
    check_after::UInt64
    delay_ns::UInt64            # backoff after little measured relief
    retry_ticket::UInt          # eligible publications at the start of that wait
end
const _HEAP_BATCH = 16
const _HEAP_MEASURE = _HeapMeasurement((0, 0), nothing, 0, _HEAP_BATCH, 0, 0, 0)
const _FULL_COLLECTIONS = Threads.Atomic{Int}(0)
_collected_heap_bytes() = Int(ccall(:jl_gc_live_bytes, Int64, ()))
function _gc_activity()
    n = Base.gc_num()
    (Int(n.pause), Int(n.full_sweep)), Int(n.allocd + n.deferred_alloc)
end

# Recency across all slots also supplies the fallback order for a disk file
# that disappeared or was replaced. Its original read age still applies.
function _forget_ticket!(ticket)
    delete!(_MEMO_DISK, ticket)
    delete!(_MEMO_RECENT, ticket)
    delete!(_MEMO_SWEEP, ticket)
end
function _register_memo!(m)
    lock(_MEMO_LOCK) do
        for _ in 1:min(2, length(_MEMO_SWEEP))
            id, ref = popfirst!(_MEMO_SWEEP)
            if ref.value === nothing
                _forget_ticket!(id)
            else
                _MEMO_SWEEP[id] = ref
            end
        end
        m.ticket = _MEMO_TICKET[] += 1
        _MOST_RECENT_MEMO[] = m.ticket
        ref = WeakRef(m)
        _MEMO_RECENT[m.ticket] = _MEMO_SWEEP[m.ticket] = ref
        m.disk && (_MEMO_DISK[m.ticket] = ref)
        remaining = _PROCESS_RETRY.bytes_until_retry
        if remaining > 0
            m.latch.mapped || (remaining -= min(remaining, _memo_bytes(m.value)))
            native = m.native_bytes isa Int ? m.native_bytes : 0
            _PROCESS_RETRY.bytes_until_retry = remaining - min(remaining, native)
        end
    end
end

# Track ordinary reads, including reads through a remount of the same physical slot.
function _touch_memo!(c, key)
    store = _scope_dict(c.cache, key)
    store isa _MemoValues || return
    m = get(store.raw, key, nothing)
    m isa _RetainedMemo || return
    m.ticket == _MOST_RECENT_MEMO[] && return
    lock(_MEMO_LOCK) do
        m.ticket == 0 && return
        _MOST_RECENT_MEMO[] == m.ticket && return
        _MOST_RECENT_MEMO[] = m.ticket
        ref = _MEMO_SWEEP[m.ticket]
        delete!(_MEMO_RECENT, m.ticket)
        _MEMO_RECENT[m.ticket] = ref
        if m.disk
            delete!(_MEMO_DISK, m.ticket)
            _MEMO_DISK[m.ticket] = ref
        end
    end
    nothing
end

function _park_memo!(m)
    lock(_MEMO_LOCK) do
        _forget_ticket!(m.ticket)
        m.ticket = 0
    end
end

# A conservative type proof avoids walking a potentially enormous result on
# every publication. In particular, containers of unknown elements can hold a
# stateful dynamic child or a native resource. Inputs and state are also
# protected independently of their payload type.
function _plain_memo_type(T, depth)
    depth > 0 && isconcretetype(T) || return false
    T in (String, Symbol) && return true
    T <: Union{Ptr,Ref,IO,Task,Channel,Function,Type,Core.LLVMPtr} && return false
    T <: BitArray && return true
    if T <: Array
        return _plain_memo_type(eltype(T), depth - 1)
    elseif T <: Dict
        return _plain_memo_type(keytype(T), depth - 1) && _plain_memo_type(valtype(T), depth - 1)
    end
    isprimitivetype(T) && return true
    ismutabletype(T) && return false
    all(ft -> _plain_memo_type(ft, depth - 1), fieldtypes(T))
end
@generated _plain_memo(::T) where T = _plain_memo_type(T, 8)

# Small mixed containers can also be proved safe without a census. One shared
# inspection budget bounds branching and terminates cycles and undefined slots.
function _plain_memo_value(v, remaining)
    _plain_memo(v) && return true
    remaining[] > 0 || return false
    if v isa Array
        length(v) <= remaining[] || return false
        remaining[] -= length(v)
        return all(i -> isassigned(v, i) && _plain_memo_value(v[i], remaining), eachindex(v))
    elseif v isa Dict
        2 * length(v) <= remaining[] || return false
        remaining[] -= 2 * length(v)
        return all(p -> _plain_memo_value(p.first, remaining) && _plain_memo_value(p.second, remaining), v)
    elseif v isa Union{Tuple,NamedTuple}
        length(v) <= remaining[] || return false
        remaining[] -= length(v)
        return all(x -> _plain_memo_value(x, remaining), v)
    end
    false
end
_plain_memo_payload(v) = _plain_memo(v) || _plain_memo_value(v, Ref(32))

# Shallow logical payload per released slot. Aliases count per slot, mappings
# are reported separately, and opaque container interiors are never traversed.
_memo_bytes(v) = isbitstype(typeof(v)) ? sizeof(v) : 0
_memo_bytes(v::String) = ncodeunits(v)
_memo_bytes(v::Array) = sizeof(v)

"""
    DynamicObjects.memo_native_bytes(owner_type, ::Val{property}, value::T)
    DynamicObjects.memo_native_bytes(value::T)

Declare that a native result can be rebuilt after its cache slot is released.
Return an estimated native byte count (a nonnegative `Int`), or `missing` when
the size is unknown. The default `nothing` preserves native-handle pinning.

The three-argument method declares one property: specialize on the owner type,
the property and the result type `T`. The one-argument method declares a type
that your package owns, for every property that returns it in any owner,
inline `@struct` children included. A property declaration takes precedence
over the declaration of its result type, also when it returns `nothing`.

A property without either declaration that returns the same mutable object as
a declared slot is released with that object's estimate. A kept copy would
retain the resource while a later read of its producer builds a second one.

The method runs at publication and should only inspect the result. The producer
is responsible for replaying the correct inputs, including any seed or file.
A disk-cached producer must also support restoring a valid live resource.
DynamicObjects drops its reference and leaves resource finalization to the owner.
"""
memo_native_bytes(owner_type, property, value) = _undeclared_native_bytes(value)
memo_native_bytes(value) = nothing

# Objects that a declaration made releasable, by identity and held weakly.
# Only mutable objects have an identity that costs nothing to compare. Each
# addition also visits two old entries, as _MEMO_SWEEP does for its tickets.
const _DECLARED_NATIVE = OrderedDict{UInt,Tuple{WeakRef,Union{Missing,Int}}}()

function _remember_native!(v, bytes)
    ismutable(v) || return
    lock(_MEMO_LOCK) do
        for _ in 1:min(2, length(_DECLARED_NATIVE))
            id, entry = popfirst!(_DECLARED_NATIVE)
            entry[1].value === nothing || (_DECLARED_NATIVE[id] = entry)
        end
        _DECLARED_NATIVE[objectid(v)] = (WeakRef(v), bytes)
    end
    nothing
end

# A property declaration never reaches this fallback, so its `nothing` holds.
function _undeclared_native_bytes(v)
    bytes = memo_native_bytes(v)
    (bytes === nothing && ismutable(v)) || return bytes
    lock(_MEMO_LOCK) do
        entry = get(_DECLARED_NATIVE, objectid(v), nothing)
        entry !== nothing && entry[1].value === v ? entry[2] : nothing
    end
end

function _publication_native_bytes(c, key, f, v)
    _memo_retention_enabled() && f isa _Settling || return nothing
    (_plain_memo(v) || _is_dynamic_object(v) || v isa IndexableProperty) && return nothing
    # Constructor seeds, @state and versioned properties never opt in. Run
    # user code outside cache locks and inside the normal compute error path.
    eligible = lock(c.lock) do
        lock(() -> _eligible_memo(_MEMO_PROTECTED_NAMES, f, key), _MEMO_LOCK)
    end
    eligible || return nothing
    bytes = memo_native_bytes(typeof(f.o), Val(f.name), v)
    (bytes === nothing || bytes === missing || (bytes isa Int && bytes >= 0)) ||
        throw(ArgumentError("memo_native_bytes must return nothing, missing or a nonnegative Int"))
    bytes
end

function _register_publication!(c, key, latch, f, v, native_bytes)
    f isa _Settling && (native_bytes !== nothing || _plain_memo_payload(v)) || return
    eligible = lock(() -> _eligible_memo(_MEMO_PROTECTED_NAMES, f, key), _MEMO_LOCK)
    eligible || return
    store = _scope_dict(c.cache, key)
    store isa _MemoValues{<:Any,Any} || return
    native_bytes === nothing || _remember_native!(v, native_bytes)
    m = _RetainedMemo(v, store, key, f.name, _scope_dict(c.computing, key),
                      _scope_dict(c.status, key), c.lock, latch, native_bytes, 0, latch.stamp !== nothing)
    store.raw[key] = m
    if _OPEN_SCOPE_COUNT[] != 0
        claimed = lock(_SCOPE_LOCK) do
            entry = _scope_entry(c, key)
            entry === nothing && return false
            entry.memo = m
            true
        end
        claimed && return
    end
    _register_memo!(m)
    nothing
end

function _memo_file_stamp(path)
    st = try
        stat(path)
    catch err
        err isa Base.IOError || err isa SystemError || rethrow()
        return nothing   # the next ordinary read cannot rely on this file
    end
    isfile(st) && st.size > 0 ? (st.device, st.inode, st.size, st.mtime, st.ctime) : nothing
end

function _record_memo_disk!(guard, o, name, args, kwargs, path)
    guard === nothing && return
    resumes(o, Val(name), args...; kwargs...) && return
    guard.latch.disk_path = path
    guard.latch.stamp = _memo_file_stamp(path)
    guard.latch.mapped = _disk_format(o, Val(name)) === Val(:mmap)
    nothing
end

# Called under the order lock. Keep the most recently used slot warm even if
# other, non-cache allocations already exceed the hint.
function _coldest_ticket()
    for order in (_MEMO_DISK, _MEMO_RECENT)
        isempty(order) && continue
        ticket = first(order).first
        ticket == _MOST_RECENT_MEMO[] || return ticket
    end
    UInt(0)
end

function _release_coldest_memo!()
    ticket, m = lock(_MEMO_LOCK) do
        id = _coldest_ticket()
        id == 0 && return (id, nothing)
        memo = _MEMO_SWEEP[id].value
        memo === nothing && _forget_ticket!(id)
        (id, memo)
    end
    ticket == 0 && return nothing
    m === nothing && return 0
    # Reads can invoke this check inside another cache operation. Never wait
    # for a second cache lock. A busy oldest entry is retried at the next check.
    trylock(m.lock) || return nothing
    try
        current = get(m.store.raw, m.key, nothing) === m
        # A small mixed container can acquire state or a handle after publication.
        eligible = current && (m.native_bytes !== nothing || _plain_memo_payload(m.value))
        recoverable = current && m.disk && _memo_file_stamp(m.latch.disk_path) == m.latch.stamp
        lock(_MEMO_LOCK) do
            m.ticket == ticket && _coldest_ticket() == ticket || return 0
            if !current
                _forget_ticket!(ticket)
                return 0
            end
            haskey(m.computing, m.key) && return nothing
            if !eligible
                m.store.raw[m.key] = m.value
                _forget_ticket!(ticket)
                return 0
            end
            if m.disk && !recoverable
                delete!(_MEMO_DISK, ticket)
                m.disk = false
                return 0
            end
            m.latch.saved = m.value
            delete!(m.store, m.key)
            delete!(m.status, m.key)
            _forget_ticket!(ticket)
            bytes = _memo_bytes(m.value)
            counts = _MEMO_EVICTED[]
            mapped = m.latch.mapped ? bytes : 0
            native = m.native_bytes isa Int ? m.native_bytes : 0
            _MEMO_EVICTED[] = (disk=counts.disk + m.disk, memory=counts.memory + !m.disk,
                estimated_payload_bytes=counts.estimated_payload_bytes + bytes - mapped,
                mapped_payload_bytes=counts.mapped_payload_bytes + mapped,
                estimated_native_bytes=counts.estimated_native_bytes + native,
                unknown_native_slots=counts.unknown_native_slots + ismissing(m.native_bytes))
            (; heap=bytes - mapped, native)
        end
    finally
        unlock(m.lock)
    end
end

# Heap batches start small and grow on measured relief. The footprint path
# uses producer estimates only where the cold cache can cover its excess.
const _MAX_MEMO_BATCH = 1024
const _PROCESS_BATCH = Ref(_MAX_MEMO_BATCH)
const _MEMO_CHECK_NS = UInt64(50_000_000)

_memo_estimate(m) = (m.latch.mapped ? 0 : _memo_bytes(m.value)) +
                    (m.native_bytes isa Int ? m.native_bytes : 0)

# One pass over the recency order, stopping once the estimates cover `excess`.
function _cold_estimates_cover(excess)
    lock(_MEMO_LOCK) do
        covered = 0
        for (ticket, ref) in _MEMO_RECENT
            m = ref.value
            (m === nothing || ticket == _MOST_RECENT_MEMO[]) && continue
            covered += _memo_estimate(m)
            covered >= excess && return true
        end
        false
    end
end

_process_batch(excess) = excess > 0 && _footprint_follows_releases() &&
    _cold_estimates_cover(excess) ? _PROCESS_BATCH[] : _HEAP_BATCH

function _trim_memos!(heap_excess, process_excess=0; batch=_HEAP_BATCH, process_batch=batch)
    released = unsized = 0
    for i in 1:max(batch, process_batch)
        (i <= batch && heap_excess > 0 || i <= process_batch && process_excess > 0) || break
        bytes = _release_coldest_memo!()
        bytes === nothing && break
        bytes === 0 && continue # stale, ineligible or demoted ticket
        released += 1
        heap_excess -= min(heap_excess, bytes.heap)
        estimate = bytes.heap + bytes.native
        process_excess -= min(process_excess, estimate)
        if estimate == 0 && (unsized += 1) >= _HEAP_BATCH
            process_excess = 0
        end
    end
    released
end

function _memo_excess(used, limit)
    limit == 0 && return 0
    used === nothing && return 0
    used < limit - limit ÷ 10 ? 0 : Int(used - (limit - limit ÷ 5))
end

function _reset_process_retry!()
    retry = _PROCESS_RETRY
    retry.last_excess = retry.delay_ns = retry.retry_at = 0
    lock(_MEMO_LOCK) do
        retry.bytes_until_retry = 0
    end
end

function _sample_process_excess!(budget, now)
    (budget == 0 || now < _NEXT_PROCESS_CHECK[]) && return 0
    _NEXT_PROCESS_CHECK[] = now + 250_000_000
    footprint = _process_memory_bytes()
    footprint === nothing && return 0
    excess = _memo_excess(footprint, budget)
    retry = _PROCESS_RETRY
    if excess == 0
        retry.last_excess == 0 || _reset_process_retry!()
    elseif now < retry.retry_at && lock(() -> retry.bytes_until_retry > 0, _MEMO_LOCK)
        return 0
    end
    excess
end

function _record_process_relief!(excess, after, budget, now)
    retry = _PROCESS_RETRY
    # A collection can repeatedly remove temporary allocations while leaving
    # exactly the same footprint behind. Compare consecutive post-GC samples
    # as well as the drop within this batch.
    reference = retry.last_excess == 0 ? excess : min(retry.last_excess, excess)
    remaining = after === nothing ? reference : _memo_excess(after, budget)
    if remaining == 0 || reference - remaining >= cld(reference, 20)
        _reset_process_retry!()
    else
        retry.delay_ns = clamp(2 * retry.delay_ns, UInt64(5_000_000_000), UInt64(300_000_000_000))
        retry.retry_at = now + retry.delay_ns
        lock(_MEMO_LOCK) do
            retry.bytes_until_retry = cld(remaining, 20)
        end
    end
    retry.last_excess = remaining
    nothing
end

function _measure_heap!()
    before = Base.gc_num().pause
    GC.gc(true)
    m = _HEAP_MEASURE
    m.seen = first(_gc_activity())
    # Julia can skip an explicit collection, e.g. while GC is disabled.
    if Base.gc_num().pause == before
        m.pending = nothing
    else
        Threads.atomic_add!(_FULL_COLLECTIONS, 1)
        m.pending = _collected_heap_bytes()
    end
end

# Compare full measurements on either side of the release, before returning
# to the caller: publications between checks can otherwise hide all its relief.
function _record_heap_relief!(m, hint, after, released)
    excess = _memo_excess(after, hint)
    relief = m.live - after
    m.live = after
    m.batch = _HEAP_BATCH
    if excess == 0
        m.delay_ns = m.check_after = 0
    elseif released > 0 && relief >= cld(excess, 256)
        # Evicting the slot metadata alone can produce a small positive delta.
        # Require measurable progress (1/256 of the remaining gap) to expand.
        bytes_per_slot = max(1, relief ÷ released)
        m.batch = min(cld(excess, bytes_per_slot), 4 * released, _MAX_MEMO_BATCH)
        m.delay_ns = 0
        m.check_after = time_ns() + _MEMO_CHECK_NS
    else
        m.delay_ns = clamp(2 * m.delay_ns, UInt64(5_000_000_000), UInt64(300_000_000_000))
        m.check_after = time_ns() + m.delay_ns
        m.retry_ticket = lock(() -> _MEMO_TICKET[], _MEMO_LOCK)
    end
end

function _sample_heap_excess!(hint, now)
    hint == 0 && return 0
    m = _HEAP_MEASURE
    counts, allocated = _gc_activity()
    collected = _collected_heap_bytes()
    collections, full = counts .- m.seen
    m.seen = counts
    if collections > 0
        m.pending = full == collections ? collected : nothing
    end
    if m.pending !== nothing && _memo_excess(m.pending, hint) == 0
        m.live = m.pending
        m.batch = _HEAP_BATCH
        m.delay_ns = m.check_after = 0
        m.pending = nothing
    end
    step = max(1, Int(hint ÷ 10))
    if now < m.check_after
        # After a low-yield probe, transient allocations alone cannot earn
        # another one. Require both growth kept by a GC and new eligible slots.
        m.delay_ns > 0 && collected - m.live >= step || return 0
        lock(() -> _MEMO_TICKET[] != m.retry_ticket, _MEMO_LOCK) || return 0
    end
    # A measurement may already be waiting, e.g. from a footprint batch.
    # If substantial allocations followed it, establish a fresh baseline so
    # they cannot hide the effect of dropping the next batch.
    if m.pending === nothing || allocated >= cld(max(1, _memo_excess(m.pending, hint)), 256)
        estimate = collected + allocated
        _memo_excess(estimate, hint) > 0 || return 0
        estimate - m.live >= step || m.check_after != 0 || m.pending !== nothing || return 0
        _measure_heap!() === nothing && return 0
    end
    m.live = m.pending::Int
    m.pending = nothing
    excess = _memo_excess(m.live, hint)
    if excess == 0
        m.delay_ns = m.check_after = 0
        m.batch = _HEAP_BATCH
    end
    excess
end

function _check_memo_pressure!(large_store=false)
    now = time_ns()
    deadline = _NEXT_MEMO_CHECK[]
    now < deadline && !large_store && return
    # An eligible large publication checks immediately. Hits poll at most
    # once per interval, including when unrelated allocations cause pressure.
    if !large_store
        Threads.atomic_cas!(_NEXT_MEMO_CHECK, deadline, now + _MEMO_CHECK_NS) == deadline || return
    end
    Threads.atomic_cas!(_TRIMMING_MEMOS, false, true) && return
    try
        hint = _HEAP_HINT[]
        heap_excess = _sample_heap_excess!(hint, now)
        budget = _PROCESS_BUDGET[]
        process_excess = _sample_process_excess!(budget, now)
        max(heap_excess, process_excess) > 0 || return
        m = _HEAP_MEASURE
        released = _trim_memos!(heap_excess, process_excess; batch=m.batch, process_batch=_process_batch(process_excess))
        # One collection supplies both signals when the two triggers coincide.
        released > 0 && _measure_heap!()
        if heap_excess > 0
            after = something(m.pending, m.live)
            _record_heap_relief!(m, hint, after, released)
        end
        if process_excess > 0 && released > 0
            _return_free_memory!()
            after = _process_memory_bytes()
            _record_process_relief!(process_excess, after, budget, time_ns())
        end
    finally
        _TRIMMING_MEMOS[] = false
    end
end

"""
    memo_retention_stats()
    memo_retention_stats(queue)

Report this process's heap hint, Julia's current live-heap estimate, the
process-memory budget and current footprint (`nothing` when unavailable), and
cumulative automatic memo releases in the disk and memory tiers.
`estimated_payload_bytes` counts shallow payloads dropped from slots and
`mapped_payload_bytes` counts known explicit mappings separately. Aliases can
contribute to several slots and other owners may still hold the value.
`estimated_native_bytes` sums producer estimates, and `unknown_native_slots`
counts released native results for which the producer supplied no estimate.
`full_collections` counts full collections DynamicObjects ran to
confirm pressure or measure relief. A collection after a batch can serve both
the heap and footprint checks.
For a queue configured with zero or one worker, the result is `(; requester, worker)`.
`worker` is `nothing` when the process is absent. For a pool, the result is
`(; requester, workers)` with a snapshot per configured slot, in slot order.
A slot without a live process contains `nothing`. Reading statistics leaves idle workers idle.
"""
function memo_retention_stats()
    counts = lock(() -> _MEMO_EVICTED[], _MEMO_LOCK)
    (; pid=getpid(), heap_hint_bytes=_HEAP_HINT[], live_heap_bytes=Base.gc_live_bytes(),
       process_budget_bytes=_PROCESS_BUDGET[], process_memory_bytes=_process_memory_bytes(), counts...,
       full_collections=_FULL_COLLECTIONS[])
end

function __init__()
    _init_malloc_trim!()
    _HEAP_HINT[] = Base.JLOptions().heap_size_hint
    budget = get(ENV, "DYNAMICOBJECTS_PROCESS_BUDGET_BYTES", nothing)
    if budget === nothing
        _PROCESS_BUDGET[] = _HEAP_HINT[]
    else
        value = tryparse(Int, budget)
        (value !== nothing && value >= 0) ||
            throw(ArgumentError("DYNAMICOBJECTS_PROCESS_BUDGET_BYTES must be a nonnegative integer byte count, got $(repr(budget))"))
        _PROCESS_BUDGET[] = value
    end
    # A queue between retries can be exiting even before its first worker exists.
    atexit(() -> (_WORKERS_EXITING[] = true))
end
