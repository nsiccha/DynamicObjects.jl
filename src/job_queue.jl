# --- Job queue: bounded admission of `@queued` computations ------------------------------
#
# `@queued` on an indexed, memoized property declares its `property_executor` to be a
# `QueueExecutor` over the process-wide `job_queue()`: every memoized computation of the
# property waits its turn there, whoever calls it. Off by default (`max_running=0`): an
# enqueued computation starts at once. With `configure_queue!(; max_running=n)` at most `n`
# hold a slot at a time, and the rest wait in FIFO order, their progress node pending and
# reading "queued · #k" until it starts when the computation runs.
#
# Each admitted computation runs on its own `:default` task and holds its slot until it
# finishes, or until it — or any task it spawned, such as a `Threads.@threads` iteration —
# first blocks waiting on another queued computation (`await_deferred`, `fetch` of a
# `QueuedCall`). It then gives the slot back for good: the cap counts heavy work rather than
# the coordinators waiting on it, and coordinators that each wait on queued children cannot
# deadlock the queue. A scoped value (`_QUEUE_HOLDER`) carries the slot into the tasks a
# computation spawns.

"""
    DynamicObjects.QueuedItem

One entry of a [`JobQueue`](@ref DynamicObjects.JobQueue), as
[`enqueue!`](@ref DynamicObjects.enqueue!) creates it and queue observers receive it:

- `work` — what runs: a [`DeferredCompute`](@ref), a
  [`QueuedCall`](@ref DynamicObjects.QueuedCall), or any value with `run!` / `abandon!`
  methods;
- `property` — the name of the `@queued` property it computes, `nothing` otherwise;
- `tag` — whatever the enqueuer attached (a [`QueueExecutor`](@ref DynamicObjects.QueueExecutor)'s
  `tag`);
- `enqueued_ns` — `time_ns()` when it was enqueued.
"""
mutable struct QueuedItem
    const work::Any
    const property::Union{Nothing,Symbol}
    const tag::Any
    const enqueued_ns::UInt64
    note::Int   # the position its progress node shows ("queued · #k"); 0 for none
end

# The connection of a queue to its worker process (see `workers.jl`).
mutable struct _RemoteRequest
    const id::Int
    const events::Channel{Any}
    worker::Any       # the worker it was sent to; only that worker's exit abandons it
end

"""
Connection to one worker process: its Malt handle (`worker`), the actor task that makes
every Malt call, and the requests in flight.
"""
mutable struct _WorkerConn
    const lock::ReentrantLock
    const ops::Channel{Any}
    actor::Union{Nothing,Task}
    worker::Any                 # a `Malt.Worker`, `nothing` while none runs
    spawning::Union{Nothing,Task}
    pid::Int
    started_at::Float64
    last_message_at::Float64
    next_id::Int
    const inflight::Dict{Int,_RemoteRequest}
    const loaded::Set{Base.PkgId}
end
_WorkerConn() = _WorkerConn(ReentrantLock(), Channel{Any}(Inf), nothing, nothing, nothing, 0, NaN, NaN, 0,
                            Dict{Int,_RemoteRequest}(), Set{Base.PkgId}())

"""
    DynamicObjects.JobQueue(; max_running=0)

FIFO admission under `max_running` slots. Each admitted item runs on its own `:default` task
and holds one slot until it finishes, or until it — or a task it spawned — blocks on another
queued computation, which gives the slot back for good. `max_running=0` means unbounded:
every item starts at once, holding no slot. `@queued` properties admit through the
process-wide [`job_queue()`](@ref DynamicObjects.job_queue); see
[`configure_queue!`](@ref DynamicObjects.configure_queue!).
"""
mutable struct JobQueue
    const lock::ReentrantLock
    const waiting::Vector{QueuedItem}
    const observers::Vector{Any}
    max_running::Int
    running::Int    # slots held
    workers::Int    # 0: admitted items run here; 1: in the worker process
    worker_start::Symbol
    worker_exeflags::Union{Nothing,Vector{String}}
    worker_preload::Vector{Base.PkgId}
    const conn::_WorkerConn
end
function JobQueue(; max_running::Integer=0)
    _check_max_running(max_running)
    JobQueue(ReentrantLock(), QueuedItem[], Any[], Int(max_running), 0, 0, :lazy, nothing,
             Base.PkgId[], _WorkerConn())
end

_check_max_running(n) =
    n >= 0 || throw(ArgumentError("max_running must be non-negative, got $(n)"))

# One admitted item's claim on a slot of `queue`.
mutable struct _QueueSlot
    const queue::JobQueue
    @atomic held::Bool
end

# The slot of the queued computation the current task works for — set where an admitted
# item starts and inherited by every task it spawns; `nothing` outside one, and inside one
# admitted while its queue was off.
const _QUEUE_HOLDER = ScopedValues.ScopedValue{Union{Nothing,_QueueSlot}}(nothing)

const _JOB_QUEUE = JobQueue()

"""
    DynamicObjects.job_queue() -> JobQueue

The process-wide queue that `@queued` properties admit their computations through.
"""
job_queue() = _JOB_QUEUE

"""
    DynamicObjects.configure_queue!(q=job_queue(); max_running=nothing, workers=nothing,
                                    worker_start=nothing, worker_exeflags=nothing,
                                    worker_preload=nothing) -> NamedTuple

Bound how many queued computations run at once. Off by default (`max_running=0`): a
`@queued` computation starts on `:default` at once. With `max_running=n` at most `n` run at a
time and the rest wait in FIFO order, their progress node pending (`·`, no clock) and reading
"queued · #k"; they start
as earlier ones finish or give their slot back. Raising the cap starts more of what waits;
`max_running=0` starts everything still waiting. Running computations are never interrupted.

With `workers=1` every computation the queue admits — each memoized or fresh computation of
a `@queued` property — runs in a separate, long-lived Julia worker process instead of on a
`:default` task of this one, so a compile, a GC pause or a deadlock there never stalls this
process. Slots, FIFO order and the "queued · #k" note are unchanged; an admitted computation
holds its slot while the worker runs it. The worker builds the same object from the same
inputs (the root object's type must be defined in a package, which the worker loads), computes
the property through its own memoized path, and hands the value back: a `@cached` / `@mmap`
value through its disk entry, which this process then loads; any other value serialized. The
worker's memo stays warm across computations. A computation whose body reads the request
(`__req__`) stays in this process, with one warning per property. A worker's exception arrives
as a [`PropertyComputationError`](@ref) caused by a
[`RemoteComputationError`](@ref DynamicObjects.RemoteComputationError) that holds the worker's
printout, and [`unwrap_error`](@ref) returns the exception itself wherever it can cross; a worker
that exits fails every computation it ran with [`ComputeAbandoned`](@ref), and the next one starts
a fresh worker. `workers=0` (the default) runs everything here; switching to it stops the worker.
When this process exits, its exit hooks kill the worker at once instead of waiting for it, so a
stuck worker never holds the exit up.

The worker runs this process's Julia with its code-generation flags, active project,
`LOAD_PATH` and `DEPOT_PATH`, and by default `--threads=<this process's default threads>,1`,
so its message loop keeps answering on the interactive thread while computations run on the
default ones; `worker_exeflags` replaces that thread flag (pass e.g. `["--threads=8,1"]`).
The worker also inherits this process's full `--heap-size-hint`, when set, unless
`worker_exeflags` supplies one explicitly. This is a per-process garbage-collection hint,
not a shared memory cap: the parent, worker and other processes still need their own headroom.
These flags apply at worker startup and restart; changing them does not reconfigure a
running worker.
`worker_start=:lazy` (the default) starts it with the first computation sent to it,
`worker_start=:now` at once, in the background. Set `worker_preload=[AppModule]` to also load
the application's packages at startup, before any computation is submitted. The list accepts
package modules (a nested module selects its root package) or `Base.PkgId`s, and is reapplied
after a restart. With `:lazy`, these packages load with the first worker-bound computation.
Changing the list under `:now` also loads its packages into an already-running worker;
`worker_preload=[]` clears the list for future starts but cannot unload packages. An omitted
list stays unchanged. Preload failures are logged during background startup and fail a
computation that still needs the preload; they are never treated as successful loads.
Packages outside the list load when a computation first needs them. Preloading runs package
initializers; it does not run properties or compile their first calls. A computation that waits for
the worker to start, or for it to load packages, shows each wait as a phase of its progress
node ("Starting the worker process", "Loading packages: …", from
`DynamicObjects.progress_notes`), kept there ahead of the worker's own phases.
See [`worker_status`](@ref DynamicObjects.worker_status) and
[`restart_worker!`](@ref DynamicObjects.restart_worker!).

Returns [`queue_settings(q)`](@ref DynamicObjects.queue_settings); an omitted setting is
unchanged.
"""
function configure_queue!(q::JobQueue=job_queue(); max_running=nothing, workers=nothing,
                          worker_start=nothing, worker_exeflags=nothing, worker_preload=nothing)
    if workers !== nothing
        workers in (0, 1) || throw(ArgumentError(
            "workers must be 0 or 1 (one worker process per queue), got $(workers)"))
        _IS_WORKER[] && workers > 0 && (workers = 0)   # a worker never spawns its own
    end
    worker_start === nothing || worker_start in (:lazy, :now) || throw(ArgumentError(
        "worker_start must be :lazy or :now, got $(repr(worker_start))"))
    worker_exeflags === nothing || (worker_exeflags = String[string(f) for f in worker_exeflags])
    worker_preload === nothing || (worker_preload = unique!(Base.PkgId[_preload_pkgid(p) for p in worker_preload]))
    if max_running !== nothing
        _check_max_running(max_running)
        admitted = lock(q.lock) do
            q.max_running = Int(max_running)
            _admit!(q)
        end
        foreach(_start_admitted, admitted)
    end
    worker_start === nothing || (q.worker_start = worker_start)
    worker_exeflags === nothing || (q.worker_exeflags = worker_exeflags)
    worker_preload === nothing || lock(q.lock) do
        q.worker_preload = worker_preload
    end
    if workers !== nothing
        q.workers = Int(workers)
        q.workers > 0 && (_WORKERS_ACTIVE[] = true)
        q.workers == 0 && _stop_worker!(q)
    end
    q.workers > 0 && q.worker_start === :now &&
        (!_worker_alive(q.conn.worker) || !isempty(_worker_preload(q))) && _start_worker_soon!(q)
    queue_settings(q)
end

"""
    DynamicObjects.queue_settings(q=job_queue()) -> (; max_running, queued, running, workers)

`q`'s cap, the number of items waiting, the number of slots held, and the number of worker
processes configured (see [`configure_queue!`](@ref DynamicObjects.configure_queue!)).
"""
queue_settings(q::JobQueue=job_queue()) = lock(q.lock) do
    (; max_running=q.max_running, queued=length(q.waiting), running=q.running, workers=q.workers)
end

"""
    DynamicObjects.observe_queue!(f, q=job_queue()) -> f

Call `f(item::QueuedItem)` for every item enqueued on `q` from now on: on the enqueuing task,
before the item can start, with no queue lock held. A layer on top records each queued
computation here, e.g. as a job named after `item.property`. A throwing observer is logged
and the item is queued regardless: an enqueue runs inside a property access, and failing it
would leave the computation in flight forever. Remove it with
[`unobserve_queue!`](@ref DynamicObjects.unobserve_queue!).
"""
function observe_queue!(f, q::JobQueue=job_queue())
    lock(() -> push!(q.observers, f), q.lock)
    f
end

"""
    DynamicObjects.unobserve_queue!(f, q=job_queue())

Stop calling `f` for items enqueued on `q`.
"""
function unobserve_queue!(f, q::JobQueue=job_queue())
    lock(() -> filter!(g -> g !== f, q.observers), q.lock)
    nothing
end

"""
    DynamicObjects.enqueue!(q::JobQueue, work; property=nothing, tag=nothing) -> QueuedItem

Queue `work` — a [`DeferredCompute`](@ref), a [`QueuedCall`](@ref DynamicObjects.QueuedCall),
or any value with `run!(work)` / `abandon!(work, reason)` methods (exactly one of which takes
effect) — behind what already waits in `q`. It starts on a `:default` task as soon as a slot
is free, at once while `q` is off. Observers see the item before it can start.
"""
function enqueue!(q::JobQueue, work; property::Union{Nothing,Symbol}=nothing, tag=nothing)
    item = QueuedItem(work, property, tag, time_ns(), 0)
    for f in lock(() -> copy(q.observers), q.lock)
        try
            f(item)
        catch err
            @error("DynamicObjects job queue: an observer threw; the item is queued regardless",
                   observer=f, property, exception=(err, catch_backtrace()))
        end
    end
    admitted = lock(q.lock) do
        push!(q.waiting, item)
        if q.max_running > 0 && q.running >= q.max_running
            # Appending changes only this item's position. Renumbering the
            # whole waiting queue here made a burst of N arrivals quadratic.
            _note_position!(item, length(q.waiting))
            _Admitted[]
        else
            _admit!(q)
        end
    end
    foreach(_start_admitted, admitted)
    item
end

"""
    DynamicObjects.queued_items(q=job_queue()) -> Vector{QueuedItem}

The items waiting in `q`, oldest first: an item's index is its queue position. Admitted
items are not listed.
"""
queued_items(q::JobQueue=job_queue()) = lock(() -> copy(q.waiting), q.lock)

"""
    DynamicObjects.queue_position(handle, q=job_queue()) -> Int or nothing

The 1-based position in `q` of the waiting computation behind `handle` — a [`Pending`](@ref)
(matched by its cache and key), a [`DeferredCompute`](@ref), a
[`QueuedCall`](@ref DynamicObjects.QueuedCall) or a [`QueuedItem`](@ref DynamicObjects.QueuedItem);
`nothing` when it is not waiting (admitted, finished, or never queued).
"""
queue_position(handle, q::JobQueue=job_queue()) =
    lock(() -> findfirst(item -> _queued_for(item, handle), q.waiting), q.lock)

_queued_for(item::QueuedItem, handle::QueuedItem) = item === handle
_queued_for(item::QueuedItem, p::Pending) = _computes(item.work, p)
_queued_for(item::QueuedItem, work) = item.work === work
_computes(d::DeferredCompute, p::Pending) = d.cache === p.cache && isequal(d.key, p.key)
_computes(_, ::Pending) = false

"""
    DynamicObjects.abandon_queued!(q, items, reason="abandoned") -> Int

Take those of `items` (`QueuedItem`s) that still wait in `q` out of it and `abandon!` each:
a `DeferredCompute`'s key fails with [`ComputeAbandoned`](@ref), and so does a
`QueuedCall`'s `fetch`. Items already admitted are left alone. Returns how many were
abandoned. Which waiting items to give up on — say, those nobody has polled for a while — is
the caller's decision.
"""
function abandon_queued!(q::JobQueue, items, reason::AbstractString="abandoned")
    chosen = Base.IdSet{Any}(items)
    taken = lock(q.lock) do
        taken = filter(in(chosen), q.waiting)
        isempty(taken) && return taken
        filter!(!in(chosen), q.waiting)
        # The abandoned leave as if admitted; those still waiting move up.
        _note_positions!(q, taken)
        taken
    end
    for item in taken
        abandon!(item.work, reason)
    end
    length(taken)
end

"""
    DynamicObjects.QueueExecutor(queue=job_queue(); property=nothing, tag=nothing)

A [`Deferred`](@ref) executor that [`enqueue!`](@ref DynamicObjects.enqueue!)s each
`DeferredCompute` on `queue`, carrying `property` and `tag` to its
[`QueuedItem`](@ref DynamicObjects.QueuedItem). A `@queued` property's declared
`property_executor` is one, with its own name as `property`; pass one as
`fetch=Deferred(QueueExecutor(...))` to queue a single call. Every blocking wait on a
computation it started gives back the slot of the queued computation the waiting task works
for (see [`await_deferred`](@ref DynamicObjects.await_deferred)).
"""
struct QueueExecutor
    queue::JobQueue
    property::Union{Nothing,Symbol}
    tag::Any
end
QueueExecutor(queue::JobQueue=job_queue(); property=nothing, tag=nothing) =
    QueueExecutor(queue, property, tag)

(e::QueueExecutor)(d) = (enqueue!(e.queue, d; e.property, e.tag); nothing)

# A task blocking on queued work is no longer doing heavy work of its own: it gives back
# the slot of the queued computation it works for before it waits.
function await_deferred(wait, ::QueueExecutor)
    _release_slot!(_QUEUE_HOLDER[])
    wait()
end

# The executor `@queued` declares for property `name`.
_queued_executor(name::Symbol) = QueueExecutor(job_queue(), name, nothing)

"""
    DynamicObjects.QueuedCall(f)

A queueable call with no cache cell behind it: [`enqueue!`](@ref DynamicObjects.enqueue!) it,
then `fetch` it for `f()`'s value (rethrowing its failure, or [`ComputeAbandoned`](@ref) if it
was abandoned before it started) and `isready` it to poll. It follows the
[`DeferredCompute`](@ref) contract: exactly one of `run!(call)` and `abandon!(call, reason)`
takes effect. A blocking `fetch` from inside a queued computation first gives that
computation's slot back, as a wait on a `@queued` property does. `status`, a progress node,
reads "queued · #k" while the call waits and is started when the call runs: create it with
`Treebars.prepare_progress!` to show the call as waiting rather than running. Whichever task
runs the call, `f` runs under the logger and with the `ScopedValue`s current where the call
was created; only the job queue's slot is the running task's own.

A fresh computation of a `@queued` property (declaration-site `@fresh`, or a call-site
`fresh`) runs as one: the caller waits for its turn and its value.
"""
mutable struct QueuedCall
    const f::Any
    const status::Any                         # progress node for the "queued · #k" note
    const outcome::Channel{Tuple{Bool,Any}}   # (true, value) | (false, exception)
    @atomic claimed::Bool
    const requester::_Requester               # the scope and logger it was created in
end
QueuedCall(f; status=nothing) =
    QueuedCall(f, status, Channel{Tuple{Bool,Any}}(1), false, _Requester())

_claim!(c::QueuedCall) = (@atomicswap c.claimed = true) === false

function run!(c::QueuedCall)
    _claim!(c) || return false
    _start_substatus!(c.status)
    outcome = try
        (true, _as_requested(c.f, c.requester))
    catch err
        (false, err)
    end
    put!(c.outcome, outcome)
    true
end

function abandon!(c::QueuedCall, reason::AbstractString="abandoned")
    _claim!(c) || return false
    put!(c.outcome, (false, ComputeAbandoned(String(reason))))
    true
end

Base.isready(c::QueuedCall) = isready(c.outcome)

function Base.fetch(c::QueuedCall)
    isready(c) || _release_slot!(_QUEUE_HOLDER[])
    ok, value = fetch(c.outcome)
    ok ? value : throw(value)
end

# An admitted item and the slot it holds (`nothing` while its queue is off).
const _Admitted = Tuple{QueuedItem,Union{Nothing,_QueueSlot},JobQueue}

# Admit waiting items, oldest first, while slots are free — every one while the queue is
# off. The caller holds `q.lock` and starts what this returns once it has let go of it.
function _admit!(q::JobQueue)
    admitted = _Admitted[]
    while !isempty(q.waiting) && (q.max_running == 0 || q.running < q.max_running)
        item = popfirst!(q.waiting)
        slot = q.max_running == 0 ? nothing : _QueueSlot(q, true)
        slot === nothing || (q.running += 1)
        push!(admitted, (item, slot, q))
    end
    _note_positions!(q, map(first, admitted))
    admitted
end

# A waiting computation's progress node reads "queued · #k"; one that leaves the queue has
# its note cleared before it starts. The caller holds `q.lock`, which orders the notes of
# concurrent admissions.
function _note_positions!(q::JobQueue, left)
    foreach(item -> _note_position!(item, 0), left)
    for (k, item) in enumerate(q.waiting)
        _note_position!(item, k)
    end
end

function _note_position!(item::QueuedItem, k::Int)
    item.note == k && return
    item.note = k
    _note_substatus!(_queued_status(item.work),
        k == 0 ? "" : Treebars.treebar_note(:queued_position; position = k))
end

_queued_status(d::DeferredCompute) = d.status
_queued_status(c::QueuedCall) = c.status
_queued_status(_) = nothing

# A fresh computation of a property whose declared executor is a job queue's (`@queued`)
# waits its turn there as a `QueuedCall`, and the caller waits for its value; any other
# executor starts memoized computations only, so a fresh one runs inline. `status` is the
# call's pending progress node; it starts when the computation runs.
_fresh_through(executor, compute, status=nothing) = (_start_substatus!(status); compute())
_fresh_through(e::QueueExecutor, compute, status=nothing) =
    fetch(enqueue!(e.queue, QueuedCall(compute; status); e.property, e.tag).work)

# Literal pool symbol: `@spawn` accepts a computed pool only on newer Julia.
_start_admitted((item, slot, q)::_Admitted) =
    errormonitor(Threads.@spawn :default _run_admitted(q, item, slot))

# Run an admitted item as `slot`'s holder — whatever scope its admitting task had — then
# give the slot back unless a wait already did.
function _run_admitted(q::JobQueue, item::QueuedItem, slot::Union{Nothing,_QueueSlot})
    try
        ScopedValues.with(() -> _run_item(q, item), _QUEUE_HOLDER => slot)
    finally
        _release_slot!(slot)
    end
end

# Give `slot` back, at most once, and start what that admits.
_release_slot!(::Nothing) = false
function _release_slot!(slot::_QueueSlot)
    (@atomicswap slot.held = false) || return false
    q = slot.queue
    admitted = lock(q.lock) do
        q.running -= 1
        _admit!(q)
    end
    foreach(_start_admitted, admitted)
    true
end

