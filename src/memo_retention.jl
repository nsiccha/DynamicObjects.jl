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
function Base.iterate(d::_MemoValues, state...)
    entry = iterate(d.raw, state...)
    entry === nothing && return nothing
    (k, v), next = entry
    (k => _unwrap_memo(v), next)
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
const _MEMO_EVICTED = Ref((disk=0, memory=0, estimated_payload_bytes=0, mapped_payload_bytes=0))
const _NEXT_MEMO_CHECK = Threads.Atomic{UInt64}(0)
const _MEMO_PROTECTED_NAMES = IdDict{Type,Set{Symbol}}()
const _TRIMMING_MEMOS = Threads.Atomic{Bool}(false)
const _HEAP_HINT = Ref(UInt64(0))

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

function _register_publication!(c, key, latch, f, v)
    f isa _Settling && _plain_memo_payload(v) || return
    eligible = lock(() -> _eligible_memo(_MEMO_PROTECTED_NAMES, f, key), _MEMO_LOCK)
    eligible || return
    store = _scope_dict(c.cache, key)
    store isa _MemoValues{<:Any,Any} || return
    m = _RetainedMemo(v, store, key, f.name, _scope_dict(c.computing, key),
                      _scope_dict(c.status, key), c.lock, latch, 0, latch.stamp !== nothing)
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
        eligible = current && _plain_memo_payload(m.value)
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
            _MEMO_EVICTED[] = (disk=counts.disk + m.disk, memory=counts.memory + !m.disk,
                estimated_payload_bytes=counts.estimated_payload_bytes + bytes - mapped,
                mapped_payload_bytes=counts.mapped_payload_bytes + mapped)
            bytes - mapped
        end
    finally
        unlock(m.lock)
    end
end

function _trim_memos!(excess; batch=16)
    for _ in 1:batch
        excess > 0 || break
        bytes = _release_coldest_memo!()
        bytes === nothing && break
        excess -= bytes
    end
    nothing
end

function _check_memo_pressure!(large_store=false)
    hint = _HEAP_HINT[]
    hint == 0 && return
    now = time_ns()
    deadline = _NEXT_MEMO_CHECK[]
    now < deadline && !large_store && return
    # An eligible large publication checks immediately. Hits poll at most
    # once per interval, including when unrelated allocations cause pressure.
    if !large_store
        Threads.atomic_cas!(_NEXT_MEMO_CHECK, deadline, now + 50_000_000) == deadline || return
    end
    live = Base.gc_live_bytes()
    live >= hint - hint ÷ 10 || return
    Threads.atomic_cas!(_TRIMMING_MEMOS, false, true) && return
    try
        _trim_memos!(Int(live) - Int(hint - hint ÷ 5))
    finally
        _TRIMMING_MEMOS[] = false
    end
end

"""
    memo_retention_stats()
    memo_retention_stats(queue)

Report this process's heap hint, Julia's current live-heap estimate and
cumulative automatic memo releases in the disk and memory tiers.
`estimated_payload_bytes` counts shallow payloads dropped from slots and
`mapped_payload_bytes` counts known explicit mappings separately. Aliases can
contribute to several slots and other owners may still hold the value.
For a queue configured with zero or one worker, the result is `(; requester, worker)`.
`worker` is `nothing` when the process is absent. For a pool, the result is
`(; requester, workers)` with a snapshot per configured slot, in slot order.
A slot without a live process contains `nothing`. Reading statistics leaves idle workers idle.
"""
function memo_retention_stats()
    counts = lock(() -> _MEMO_EVICTED[], _MEMO_LOCK)
    (; pid=getpid(), heap_hint_bytes=_HEAP_HINT[], live_heap_bytes=Base.gc_live_bytes(), counts...)
end

function __init__()
    _HEAP_HINT[] = Base.JLOptions().heap_size_hint
    # A queue between retries can be exiting even before its first worker exists.
    atexit(() -> (_WORKERS_EXITING[] = true))
end
