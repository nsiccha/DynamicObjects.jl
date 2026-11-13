# --- Compute trace -----------------------------------------------------------------------
#
# An opt-in, scoped record of what property reads did (snag `no-trace-of-what-e8f9d53e`).
# `with_compute_trace(f)` collects, per `(type, property)`, the reads that hit memory, waited
# for a computation running elsewhere, computed (memoized), ran uncached (`@fresh`), loaded a
# disk entry or threw, with their times, plus a log of the invalidations issued meanwhile.
#
# The trace follows the calling task into tasks it spawns (a `ScopedValue`), and into deferred
# work: a `DeferredCompute` or `QueuedCall` re-enters the scope it was created in when it runs
# (`_Requester`), because executor workers and job-queue admissions run it on a task whose own
# scope belongs to someone else.
#
# With no trace active anywhere, each hook costs one atomic load (`_ACTIVE_TRACES`).

mutable struct _TraceStats
    calls::Int
    hits::Int
    computed::Int
    fresh::Int
    disk::Int
    waits::Int
    pending::Int
    errors::Int
    hit_ns::UInt64
    wait_ns::UInt64
    total_ns::UInt64
    self_ns::UInt64
    max_ns::UInt64
end
_TraceStats() = _TraceStats(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

"""
    ComputeTraceEvent

One read a [`ComputeTrace`](@ref) kept (`with_compute_trace(f; events=n)`): `at` (seconds
since the trace started), `type`, `property`, `args` (the `(indices, kwargs)` of an indexed
read, held by reference, or `nothing` for a bare read), `outcome` (`:hit`, `:wait`,
`:pending`, `:computed`, `:disk`, `:fresh`, `:error` or `:failed`) and `duration` (seconds).
"""
struct ComputeTraceEvent
    at::Float64
    type::DataType
    property::Symbol
    args::Any
    outcome::Symbol
    duration::Float64
end

"""
    ComputeTraceInvalidation

One invalidation a [`ComputeTrace`](@ref) logged: `at` (seconds since the trace started),
`verb` (`:clear_mem_caches!`, `:clear_cache!`, `:invalidate!`, `:sync!` or
`:clear_disk_caches!`), the object's `type`, the property names it `dropped` (that held a
value), the entry `key` `(indices, kwargs)` of a per-entry `invalidate!` (else `nothing`), and
`issued_from`: `(type, property)` of the traced computation running on the issuing task, or
`nothing` when it was issued outside one.
"""
struct ComputeTraceInvalidation
    at::Float64
    verb::Symbol
    type::DataType
    dropped::Vector{Symbol}
    key::Any
    issued_from::Union{Nothing,Tuple{DataType,Symbol}}
end

"""
    ComputeTrace(; events=0, invalidations=1000)

What property reads did while a [`with_compute_trace`](@ref) scope using it was active. Show
it for a per-property table and the invalidation log; [`compute_trace_rows`](@ref) returns the
table as data. Fields:

- `events::Vector{ComputeTraceEvent}`: the first `events` reads (none by default), and
  `events_dropped`, how many more were not kept;
- `invalidations::Vector{ComputeTraceInvalidation}`: the first `invalidations` invalidations,
  and `invalidations_dropped`.

A trace records only while one of its scopes is active, so a trace whose scopes have all
ended never changes, even when a task spawned inside one of them outlives it.
"""
mutable struct ComputeTrace
    const lock::ReentrantLock
    const stats::Dict{Tuple{DataType,Symbol},_TraceStats}
    const events::Vector{ComputeTraceEvent}
    const invalidations::Vector{ComputeTraceInvalidation}
    const max_events::Int
    const max_invalidations::Int
    events_dropped::Int
    invalidations_dropped::Int
    first_ns::UInt64        # first activation; 0 before
    active::Int             # active `with_compute_trace` scopes using this trace
    active_since_ns::UInt64
    traced_ns::UInt64       # wall time of the ended activations
end
ComputeTrace(; events::Integer=0, invalidations::Integer=1000) =
    ComputeTrace(ReentrantLock(), Dict{Tuple{DataType,Symbol},_TraceStats}(),
                 ComputeTraceEvent[], ComputeTraceInvalidation[],
                 max(0, Int(events)), max(0, Int(invalidations)), 0, 0, 0, 0, 0, 0)

# The traces a task records into: the innermost scope's trace, then each enclosing one.
struct _TraceScope
    trace::ComputeTrace
    outer::Union{Nothing,_TraceScope}
end
const _TRACE = ScopedValues.ScopedValue{Union{Nothing,_TraceScope}}(nothing)
# Active `with_compute_trace` scopes in the process: the gate every hook reads first.
const _ACTIVE_TRACES = Threads.Atomic{Int}(0)

_trace_scope() = _ACTIVE_TRACES[] == 0 ? nothing : _TRACE[]
# A start time for a read that may be traced; 0 when no trace is active anywhere.
_trace_clock() = _ACTIVE_TRACES[] == 0 ? UInt64(0) : time_ns()

_scope_has(::Nothing, ::ComputeTrace) = false
_scope_has(s::_TraceScope, t::ComputeTrace) = s.trace === t || _scope_has(s.outer, t)

"""
    with_compute_trace(f; events=0, invalidations=1000) -> (value, trace)
    with_compute_trace(f, trace::ComputeTrace)

Run `f()` and record property reads in a [`ComputeTrace`](@ref). The scope follows
spawned tasks and deferred work. Nested scopes also record in the outer trace.
An existing trace can collect several calls and remains available if `f` throws.

[`compute_trace_rows`](@ref) reports counts and times by type and property.
Outcomes distinguish memory hits, memoized computations, fresh computations,
disk reads, waits, pending polls and errors. Dunder-property reads and a direct
`fetch` of a `Pending` handle are not recorded separately.

`total_s` includes nested reads; `self_s` subtracts reads nested on the computing
task. It does not subtract time spent waiting for separately spawned tasks.
`hit_s` includes key hashing. These are measured durations, not estimates of
execution time with compilation excluded.

`events` retains at most that many individual reads in `trace.events`, holding
arguments by reference. `invalidations` bounds the invalidation log, which records
clears, entry invalidations and synchronization that drops values. The trace
stops changing when all its scopes have ended.
"""
function with_compute_trace(f; events::Integer=0, invalidations::Integer=1000)
    trace = ComputeTrace(; events, invalidations)
    value = with_compute_trace(f, trace)
    (value, trace)
end
function with_compute_trace(f, trace::ComputeTrace)
    _trace_activate!(trace)
    Threads.atomic_add!(_ACTIVE_TRACES, 1)
    try
        outer = _TRACE[]
        _scope_has(outer, trace) ? f() : ScopedValues.with(f, _TRACE => _TraceScope(trace, outer))
    finally
        Threads.atomic_sub!(_ACTIVE_TRACES, 1)
        _trace_deactivate!(trace)
    end
end

_trace_activate!(t::ComputeTrace) = lock(t.lock) do
    t.active += 1
    if t.active == 1
        now = time_ns()
        t.first_ns == 0 && (t.first_ns = now)
        t.active_since_ns = now
    end
    nothing
end
_trace_deactivate!(t::ComputeTrace) = lock(t.lock) do
    t.active -= 1
    t.active == 0 && (t.traced_ns += time_ns() - t.active_since_ns)
    nothing
end

# Seconds since `t` first started (the caller holds `t.lock`).
_trace_at(t::ComputeTrace) = (time_ns() - t.first_ns) / 1e9

# DynamicObjects' own `__name__` properties are not recorded.
_traced_name(name::Symbol) = !_is_dunder_name(name)
# Read the Symbol's bytes in place (no `String` allocation); a Symbol is never freed.
function _is_dunder_name(name::Symbol)
    n = sizeof(name)
    p = Base.unsafe_convert(Ptr{UInt8}, name)
    n > 4 && unsafe_load(p, 1) == UInt8('_') && unsafe_load(p, 2) == UInt8('_') &&
        unsafe_load(p, n - 1) == UInt8('_') && unsafe_load(p, n) == UInt8('_')
end

# The arguments a read is recorded with: `nothing` for a bare read.
_trace_args(indices::Tuple, kwargs::NamedTuple) =
    isempty(indices) && isempty(kwargs) ? nothing : (indices, kwargs)

# A traced computation running on this task. Reads nested in it add their time to
# `child_ns`; a disk load marks it `disk`.
mutable struct _TraceFrame
    const scope::_TraceScope
    const type::DataType
    const name::Symbol
    const args::Any
    const start_ns::UInt64
    child_ns::UInt64
    disk::Bool
end
const _TRACE_FRAMES = :__dynamicobjects_trace_frames__

_trace_frames() = get!(() -> _TraceFrame[], task_local_storage(), _TRACE_FRAMES)::Vector{_TraceFrame}
# The innermost traced computation on this task, without creating task-local storage.
function _trace_top()
    storage = current_task().storage
    storage === nothing && return nothing
    frames = get(storage, _TRACE_FRAMES, nothing)
    frames === nothing || isempty(frames) ? nothing : last(frames)::_TraceFrame
end

# Record one outcome (a `Val`) of a read of `o.name` in every trace of `scope`.
function _trace_record!(scope::_TraceScope, T::DataType, name::Symbol, args, outcome::Val,
                        dt::UInt64, self::UInt64)
    s = scope
    while s !== nothing
        _trace_add!(s.trace, T, name, args, outcome, dt, self)
        s = s.outer
    end
    nothing
end
function _trace_add!(t::ComputeTrace, T::DataType, name::Symbol, args, outcome::Val{O},
                     dt::UInt64, self::UInt64) where {O}
    lock(t.lock) do
        t.active > 0 || return nothing
        st = get!(_TraceStats, t.stats, (T, name))
        st.calls += 1
        _trace_count!(st, outcome, dt, self)
        if length(t.events) < t.max_events
            push!(t.events, ComputeTraceEvent(_trace_at(t), T, name, args, O, dt / 1e9))
        elseif t.max_events > 0
            t.events_dropped += 1
        end
        nothing
    end
end
_trace_count!(st::_TraceStats, ::Val{:hit}, dt, self) = (st.hits += 1; st.hit_ns += dt)
_trace_count!(st::_TraceStats, ::Val{:wait}, dt, self) = (st.waits += 1; st.wait_ns += dt)
_trace_count!(st::_TraceStats, ::Val{:pending}, dt, self) = (st.pending += 1)
_trace_count!(st::_TraceStats, ::Val{:failed}, dt, self) = (st.errors += 1)
_trace_count!(st::_TraceStats, ::Val{:computed}, dt, self) = (st.computed += 1; _trace_time!(st, dt, self))
_trace_count!(st::_TraceStats, ::Val{:disk}, dt, self) = (st.disk += 1; _trace_time!(st, dt, self))
_trace_count!(st::_TraceStats, ::Val{:fresh}, dt, self) = (st.fresh += 1; _trace_time!(st, dt, self))
_trace_count!(st::_TraceStats, ::Val{:error}, dt, self) = (st.errors += 1; _trace_time!(st, dt, self))
_trace_time!(st::_TraceStats, dt, self) =
    (st.total_ns += dt; st.self_ns += self; st.max_ns = max(st.max_ns, dt))

# Record a read of `o.name` started at `t0` (`_trace_clock()`, nonzero) that did not run a
# computation on this task (a hit, a wait, a poll; `outcome` a `Val`). Its time, taken before
# any bookkeeping, is nested work of the computation running on this task.
_trace_read!(o, name::Symbol, args, outcome::Val, t0::UInt64) =
    _trace_read_dt!(o, name, args, outcome, time_ns() - t0)
# The same for a read through a cache `get!`, which knows the property from its compute.
_trace_read!(f, outcome::Val, t0::UInt64) = nothing
function _trace_read!(s::_Settling, outcome::Val, t0::UInt64)
    dt = time_ns() - t0
    _trace_read_dt!(s.o, s.name, _trace_args(s.args, s.kwargs), outcome, dt)
end
function _trace_read_dt!(o, name::Symbol, args, outcome::Val, dt::UInt64)
    scope = _TRACE[]
    (scope === nothing || !_traced_name(name)) && return nothing
    top = _trace_top()
    top === nothing || (top.child_ns += dt)
    _trace_record!(scope, typeof(o), name, args, outcome, dt, UInt64(0))
end

# Run `compute()` (a computation of `o.name`) as a traced computation. `memoized`: whether
# it publishes into a cache (a memoized computation) rather than computing fresh.
function _traced_compute(compute, scope::_TraceScope, o, name::Symbol, indices, kwargs, memoized::Bool)
    frames = _trace_frames()
    frame = _TraceFrame(scope, typeof(o), name, _trace_args(indices, kwargs), time_ns(), 0, false)
    push!(frames, frame)
    outcome = :error
    try
        v = compute()
        outcome = frame.disk ? :disk : memoized ? :computed : :fresh
        v
    finally
        last(frames) === frame && pop!(frames)
        dt = time_ns() - frame.start_ns
        parent = _trace_top()
        parent === nothing || (parent.child_ns += dt)
        _trace_record!(scope, frame.type, name, frame.args, Val(outcome), dt, dt - min(dt, frame.child_ns))
    end
end

# Mark the traced computation of `o.name` running on this task as served from (`true`) or
# not from (`false`) its disk entry.
function _trace_disk!(o, name::Symbol, disk::Bool)
    _ACTIVE_TRACES[] == 0 && return nothing
    top = _trace_top()
    top !== nothing && top.type === typeof(o) && top.name === name && (top.disk = disk)
    nothing
end

# Log an invalidation of `o` in every trace of the current scope.
function _trace_invalidation!(verb::Symbol, o, dropped, key=nothing)
    scope = _trace_scope()
    scope === nothing && return nothing
    top = _trace_top()
    from = top === nothing ? nothing : (top.type, top.name)
    names = sort!(unique!(Symbol[n for n in dropped if _traced_name(n)]))
    s = scope
    while s !== nothing
        t = s.trace
        lock(t.lock) do
            t.active > 0 || return
            if length(t.invalidations) < t.max_invalidations
                push!(t.invalidations, ComputeTraceInvalidation(_trace_at(t), verb, typeof(o), names, key, from))
            else
                t.invalidations_dropped += 1
            end
        end
        s = s.outer
    end
    nothing
end

"""
    compute_trace_rows(trace::ComputeTrace) -> Vector{NamedTuple}

The per-property table of a [`ComputeTrace`](@ref) as data, one row per `(type, property)`
with `type`, `property`, `calls`, `hits`, `computed`, `fresh`, `disk`, `waits`, `pending`,
`errors` and the times in seconds `self_s`, `total_s`, `max_s`, `hit_s`, `wait_s` (see
[`with_compute_trace`](@ref)). Sorted by own time, `self_s + hit_s`, then by `calls`.
"""
function compute_trace_rows(t::ComputeTrace)
    rows = lock(t.lock) do
        [(; type=T, property=name, st.calls, st.hits, st.computed, st.fresh, st.disk, st.waits,
            st.pending, st.errors, self_s=st.self_ns / 1e9, total_s=st.total_ns / 1e9,
            max_s=st.max_ns / 1e9, hit_s=st.hit_ns / 1e9, wait_s=st.wait_ns / 1e9)
         for ((T, name), st) in t.stats]
    end
    sort!(rows; by=r -> (-(r.self_s + r.hit_s), -r.calls, string(r.type), string(r.property)))
end

# Wall time of `t`'s activations, including one still running.
_trace_wall_s(t::ComputeTrace) = lock(t.lock) do
    (t.traced_ns + (t.active > 0 ? time_ns() - t.active_since_ns : UInt64(0))) / 1e9
end

# Seconds with three decimals.
function _trace_seconds(x::Real)
    ms = round(Int, 1000 * x)
    string(div(ms, 1000), ".", lpad(rem(ms, 1000), 3, '0'))
end

# A type as the report names it: unqualified, with its parameters (`View{:qt}`).
_trace_type_label(T::DataType) =
    isempty(T.parameters) ? string(nameof(T)) : string(nameof(T), "{", join(map(repr, T.parameters), ", "), "}")
_trace_label(T::DataType, name::Symbol) = string(_trace_type_label(T), ".", name)

# The table columns, in print order: header, row field, formatter, always shown.
const _TRACE_COLUMNS = (
    ("self s", :self_s, _trace_seconds, true),
    ("total s", :total_s, _trace_seconds, false),
    ("max s", :max_s, _trace_seconds, false),
    ("hit s", :hit_s, _trace_seconds, false),
    ("wait s", :wait_s, _trace_seconds, false),
    ("calls", :calls, string, true),
    ("hits", :hits, string, false),
    ("computed", :computed, string, false),
    ("fresh", :fresh, string, false),
    ("disk", :disk, string, false),
    ("waits", :waits, string, false),
    ("pending", :pending, string, false),
    ("errors", :errors, string, false),
)

Base.show(io::IO, t::ComputeTrace) = lock(t.lock) do
    print(io, "ComputeTrace(", length(t.stats), " properties, ",
          sum((st.calls for st in values(t.stats)); init=0), " reads, ",
          length(t.invalidations) + t.invalidations_dropped, " invalidations)")
end

function Base.show(io::IO, ::MIME"text/plain", t::ComputeTrace)
    rows = compute_trace_rows(t)
    invalidations, inv_dropped, events, ev_dropped = lock(t.lock) do
        (copy(t.invalidations), t.invalidations_dropped, length(t.events), t.events_dropped)
    end
    total(f) = sum((getfield(r, f) for r in rows); init=0)
    print(io, "ComputeTrace: ", _trace_seconds(_trace_wall_s(t)), " s traced · ",
          total(:calls), " reads · ", total(:hits), " hits · ", total(:computed), " computed · ",
          total(:fresh), " fresh · ", total(:disk), " disk · ",
          length(invalidations) + inv_dropped, " invalidations")
    if !isempty(rows)
        columns = [c for c in _TRACE_COLUMNS if c[4] || any(r -> getfield(r, c[2]) != 0, rows)]
        cells = [[c[3](getfield(r, c[2])) for c in columns] for r in rows]
        widths = [maximum(length, (c[1], (row[i] for row in cells)...)) for (i, c) in enumerate(columns)]
        print(io, "\n ", join((lpad(c[1], w) for (c, w) in zip(columns, widths)), "  "), "  property")
        for (r, row) in zip(rows, cells)
            print(io, "\n ", join((lpad(x, w) for (x, w) in zip(row, widths)), "  "), "  ",
                  _trace_label(r.type, r.property))
        end
    end
    if !isempty(invalidations)
        print(io, "\nInvalidations:")
        for inv in invalidations
            print(io, "\n  +", _trace_seconds(inv.at), " s  ", inv.verb, "(", _trace_type_label(inv.type), ")  ",
                  inv.issued_from === nothing ? "issued outside a traced computation" :
                      "issued from " * _trace_label(inv.issued_from...),
                  "  dropped ", isempty(inv.dropped) ? "nothing" : join(inv.dropped, ", "))
            inv.key === nothing || print(io, "  key ", repr(inv.key; context=:limit => true))
        end
        inv_dropped > 0 && print(io, "\n  … ", inv_dropped, " more not kept (invalidations=)")
    end
    events > 0 && print(io, "\n", events, " events kept in `trace.events`",
                        ev_dropped > 0 ? ", $(ev_dropped) more not kept" : "")
    nothing
end

# The publish guard of a running memoized computation: its latch. What the computation
# publishes besides its value — a disk entry, an opaque requester's own value — checks the
# guard first, so an invalidation that retracted the latch meanwhile is not undone. It lives
# in the computing task's local storage, set by `_run_cache_compute!` and taken by the
# computation's own `_computeproperty`, so nested computations never see it: a memoized one
# sets its own, an uncached one (`fresh`) has none.
struct _PublishGuard{C<:AbstractThreadsafeDict,K}
    cache::C
    key::K
    latch::Threads.Condition
end
const _PUBLISH_GUARD = :__dynamicobjects_publish_guard__

# Whether the computation behind `guard` may still publish (`nothing`: no guard).
_publishable(::Nothing) = true
_publishable(g::_PublishGuard) = lock(g.cache.lock) do
    get(g.cache.computing, g.key, nothing) === g.latch
end

_with_publish_guard(compute, f, c, key, cnd) = compute()
function _with_publish_guard(compute, ::_Settling, c, key, cnd)
    storage = task_local_storage()
    previous = get(storage, _PUBLISH_GUARD, nothing)
    storage[_PUBLISH_GUARD] = _PublishGuard(c, key, cnd)
    try
        compute()
    finally
        previous === nothing ? delete!(storage, _PUBLISH_GUARD) : (storage[_PUBLISH_GUARD] = previous)
    end
end

# The guard of the computation starting on this task (`take`: none is left for what it
# nests), without creating task-local storage where there is none.
function _publish_guard(; take::Bool=false)
    storage = current_task().storage
    storage === nothing && return nothing
    take ? pop!(storage, _PUBLISH_GUARD, nothing) : get(storage, _PUBLISH_GUARD, nothing)
end

# Run a `c.cache`-backed compute to completion under the `cnd` latch. Compute OUTSIDE the
# lock (the RHS recurses into siblings on the same lock), then publish the value + drop the
# latch + notify; on failure record the exception in `c.errors` + drop the latch + notify,
# and rethrow. Used inline (blocking first-arriver) and inside the fire-and-forget spawn
# (poller first-arriver) alike — the value/error both reach every other accessor through
# `cache`/`errors` + the latch, so the compute Task is never retained. A value this
# computation stored is then reported to `property_settled` (`f` a `_Settling`), with waiters
# already released and no lock held.
#
# An invalidation (`clear_mem_caches!`, `clear_cache!`, `sync!`, `invalidate!`, `force=true`)
# retracts the latch of a compute in flight and wakes its waiters (`_retract!`), which find
# the latch gone and re-resolve against the current state. Such a compute may have read what
# was invalidated, so it publishes nothing: its value (or failure) goes to its own caller only.
function _run_cache_compute!(c::AbstractThreadsafeDict, key, cnd::Threads.Condition, f, s)
    local v
    _start_substatus!(s)
    try
        v = _with_publish_guard(() -> f(s), f, c, key, cnd)
    catch e
        # Fail the node before waking waiters: a waiter that shows it under its own
        # node (`_linked`) keeps it there exactly when it reads as failed.
        !isnothing(s) && _fail_compute_status!(f, s, e)
        lock(c.lock) do
            if get(c.computing, key, nothing) === cnd
                delete!(c.computing, key)
                c.errors[key] = e
            end
            notify(cnd)
        end
        _failed!(f)
        rethrow()
    end
    # The node must be terminal before releasing waiters: a remote waiter can close
    # its progress mirror as soon as fetch returns.
    !isnothing(s) && _finish_compute_status!(f, s)
    stored, published = lock(c.lock) do
        if get(c.computing, key, nothing) !== cnd
            notify(cnd)                # retracted mid-flight (its waiters already woke then)
            return (v, false)
        end
        existing = get(c.cache, key, _missing_sentinel)
        published = existing === _missing_sentinel
        if published
            c.cache[key] = v
            _on_store!(c, key)
            existing = v
        else
            _on_hit!(c, key)          # defensive: someone published first
        end
        delete!(c.computing, key)
        notify(cnd)                    # leave c.status[key] finalized — getstatus / the "(cached)" note rely on it
        (existing, published)
    end
    published && _settled!(f, stored)
    stored
end

# Blocking waiter: block on `cnd` until the value lands (return it) or the compute fails
# (rethrow the recorded exception). If the computer vanished with neither (evicted mid
# flight), recompute from scratch OUTSIDE the lock. With an executor the blocking part
# runs inside `await_deferred`.
function _await_cache_value!(c::AbstractThreadsafeDict, key, cnd::Threads.Condition, f; fetch=Base.fetch, substatus=nothing, retry_failed=true, link=nothing)
    t0 = _trace_clock()
    outcome = _latch_outcome(c, key, cnd, false)
    if outcome[1] === :pending
        outcome = _blocking(_selector_executor(fetch)) do
            _latch_outcome(c, key, cnd, true)
        end
    end
    t0 == 0 || _trace_read!(f, Val(:wait), t0)
    outcome[1] === :value && return outcome[2]
    outcome[1] === :error && throw(outcome[2])
    return get!(f, c, key; fetch, substatus, retry_failed, link)   # :gone → recompute
end

# The progress node of `key`'s computation, registered when it started.
_status_of(c::AbstractThreadsafeDict, key) = lock(() -> get(c.status, key, nothing), c.lock)

# Show `node`, the computation a threaded read computes or waits for, under `parent`, the
# node of the code that wrote the read, while `f` runs. The computation keeps its own
# parent (its owner's tree). A finished node leaves `parent` again; a failed one stays,
# so the failure shows where it was waited for. A node already under `parent` (attached
# explicitly, or created there) is left alone.
_linked(f, parent, node) = f()
function _linked(f, parent::Treebars.ProgressNode, node::Treebars.ProgressNode)
    (parent === node || node in parent.children) && return f()
    Treebars.add_child!(parent, node)
    try
        f()
    finally
        Treebars.is_failed(node) || pop!(parent.children, node, nothing)
    end
end

# The `link` of a read `@fetch!` or `@progress` threads (`fetchindex!` / `fetchproperty!`
# with a progress node). The read is the ordinary blocking read, computed inline, but the
# computation's node stays under `parent` after it finishes, and a hit attaches the entry's
# node too, noted "(cached)" when documented (`_attach_fetched!`).
struct _Attached
    parent::Treebars.ProgressNode
end
_linked(f, a::_Attached, node) = (Treebars.add_child!(a.parent, node); f())
# What a hit of `key` in `c` shows under `link`: nothing, except for an `_Attached` read.
_link_hit!(link, c, key, v) = nothing
_link_hit!(a::_Attached, c::AbstractThreadsafeDict, key, v) =
    _attach_fetched!(a.parent, v, _status_of(c, key))

# The state of `key` behind latch `cnd`: `:value`, `:error`, `:gone` (the latch was
# retracted with neither), or — without `block` — `:pending` while it is still in flight.
_latch_outcome(c::AbstractThreadsafeDict, key, cnd::Threads.Condition, block::Bool) =
    lock(c.lock) do
        while true
            v = get(c.cache, key, _missing_sentinel)
            v !== _missing_sentinel && (_on_hit!(c, key); return (:value, v))
            haskey(c.errors, key) && return (:error, c.errors[key])
            get(c.computing, key, nothing) === cnd || return (:gone, nothing)
            block || return (:pending, nothing)
            wait(cnd)
        end
    end

_blocking(wait, ::Nothing) = wait()
_blocking(wait, executor) = await_deferred(wait, executor)

"""
    Pending

Cheap, non-`Task` handle a poller (`fetchindex` / `fetchproperty` / `get!(…; fetch=identity)`)
gets back while a value is still being computed. It points at where the value will land — a
`Slot` (bare props) or the backing `(cache, key)` — plus the in-flight latch, so a caller can
`fetch(p)` to BLOCK for the value (rethrowing if the compute failed) or ignore it and poll
again later. Replaces the former "`rv` is a `Task` while in-flight" poll contract: callers
now branch on `rv isa Pending` (still computing) vs. the value (done). The progress/status
node stays optional and is never relied on for readiness.

A handle for a computation started through an executor (a `Deferred` selector, or the
property's `DynamicObjects.property_executor`) carries that executor, and a blocking
`fetch` on it waits through `DynamicObjects.await_deferred`.

If the computation is invalidated while in flight (`clear_mem_caches!`, `clear_cache!`,
`sync!`, `invalidate!`, `force=true`), its value is not stored, and `fetch` re-resolves the
access: it waits for a computation started since, or starts one. A `fetch` already waiting
re-resolves at the invalidation, not when the invalidated computation ends.
"""
struct Pending{C<:AbstractThreadsafeDict, K, S, E, R}
    cache::C
    key::K
    slot::S       # a `Slot{T}` for slotted bare props; `nothing` for `cache`-backed keys
    executor::E   # the executor a blocking `fetch` waits through; `nothing` for none
    resolve::R    # re-runs the access once its computation was retracted; `nothing` for none
end
Pending(cache, key, slot) = Pending(cache, key, slot, nothing, nothing)
Pending(cache, key, slot, executor) = Pending(cache, key, slot, executor, nothing)
# The selector that blocks for `p`'s computation through its executor.
_blocking_selector(p::Pending) = p.executor === nothing ? Base.fetch : _BlockingDeferred(p.executor)

# Non-blocking readiness probe — a `Task`-like surface for callers migrating off `rv isa Task`.
Base.isready(p::Pending) = p.slot === nothing ? haskey(p.cache, p.key) : (@atomic :acquire p.slot.set)

# Would `fetch(p)` return or throw without waiting?
_settled(p::Pending) = isready(p) || lock(p.cache.lock) do
    haskey(p.cache.errors, p.key) || !haskey(p.cache.computing, p.key)
end

# Block until the value lands (return it) or the compute fails (rethrow). Mirrors
# `fetch(::Task)` so `fetch=Base.fetch` and an explicit `fetch(::Pending)` behave alike.
Base.fetch(p::Pending) = p.executor === nothing || _settled(p) ? _fetch_pending(p) :
    await_deferred(() -> _fetch_pending(p), p.executor)

function _fetch_pending(p::Pending)
    c = p.cache
    if p.slot !== nothing
        slot = p.slot
        while !(@atomic :acquire slot.set)
            again = lock(c.lock) do
                (@atomic :acquire slot.set) && return false
                haskey(c.errors, p.key) && throw(c.errors[p.key])
                cnd = get(c.computing, p.key, nothing)
                cnd === nothing && return false
                wait(cnd::Threads.Condition)
                true
            end
            again || break
        end
        (@atomic :acquire slot.set) && return slot.value
        error("Pending: slot ", p.key, " is unset with no compute in flight")
    end
    while true
        step = lock(c.lock) do
            v = get(c.cache, p.key, _missing_sentinel)
            v !== _missing_sentinel && return (:value, v)
            haskey(c.errors, p.key) && return (:error, c.errors[p.key])
            cnd = get(c.computing, p.key, nothing)
            cnd === nothing && return (:gone, nothing)
            wait(cnd::Threads.Condition)
            (:retry, nothing)
        end
        step[1] === :value && return step[2]
        step[1] === :error && throw(step[2])
        if step[1] === :gone
            p.resolve === nothing && error("Pending: key ", p.key, " has no value and no compute in flight")
            return p.resolve()
        end
    end
end

