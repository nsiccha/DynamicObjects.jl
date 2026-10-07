using TestItemRunner

# A property's executor chosen at its declaration (`property_executor`) admits every
# memoized computation of it, whichever task triggers it and however it is called, and
# every blocking wait on it goes through `await_deferred` (snag
# `declaration-site-7e1514f0`).
@testmodule DeclaredExecutorFixtures begin
using DynamicObjects
import DynamicObjects: run!, abandon!
export DXApp, EXECUTOR, PAUSE, Recorder, queued, waits, take_one!, CountingPool, run_tasks,
       SlotQueue, runs, reset_runs!

const EXECUTOR = Ref{Any}(nothing)   # what DXApp's marked properties declare
const PAUSE = Ref(0.0)

const RUNS = Any[]
const RUNS_LOCK = ReentrantLock()
_ran!(x) = lock(() -> push!(RUNS, (x, current_task())), RUNS_LOCK)
runs() = lock(() -> first.(RUNS), RUNS_LOCK)
run_tasks() = lock(() -> last.(RUNS), RUNS_LOCK)
reset_runs!() = lock(() -> empty!(RUNS), RUNS_LOCK)

_helper(app, i) = 10i
_ctx_helper(app, i) = (app.ctx, i)

@dynamicstruct struct DXApp
    ctx = nothing
    item(i::Int) = (_ran!((:item, i)); sleep(PAUSE[]); 10i)
    boom(i::Int) = (_ran!((:boom, i)); error("boom $i"))
    unmarked(i::Int) = (_ran!((:unmarked, i)); 10i)
    @progress batch(n::Int) = begin
        Threads.@threads for i in 1:n
            item(i)
        end
        n
    end
    outer(n::Int) = (_ran!((:outer, n)); item(n) + 1)
    opaque_item(i::Int) = (_ran!((:opaque, i)); _helper(__self__, i))
    ctx_item(i::Int) = (_ran!((:ctx, i)); _ctx_helper(__self__, i))
end
for name in (:item, :boom, :outer, :opaque_item, :ctx_item)
    @eval DynamicObjects.property_executor(::DXApp, ::Val{$(QuoteNode(name))}) = EXECUTOR[]
end

# Queues every compute for the test to run by hand; counts hook calls.
struct Recorder
    queue::Vector{DeferredCompute}
    waits::Base.RefValue{Int}
    lock::ReentrantLock
end
Recorder() = Recorder(DeferredCompute[], Ref(0), ReentrantLock())
(r::Recorder)(d::DeferredCompute) = lock(() -> push!(r.queue, d), r.lock)
function DynamicObjects.await_deferred(wait, r::Recorder)
    lock(() -> r.waits[] += 1, r.lock)
    wait()
end
queued(r) = lock(() -> length(r.queue), r.lock)
waits(r) = lock(() -> r.waits[], r.lock)
take_one!(r) = lock(() -> popfirst!(r.queue), r.lock)

# `n` workers running computes FIFO; records the peak number running at once.
struct CountingPool
    queue::Channel{DeferredCompute}
    workers::Vector{Task}
    running::Threads.Atomic{Int}
    peak::Threads.Atomic{Int}
    waits::Threads.Atomic{Int}
end
function CountingPool(n)
    pool = CountingPool(Channel{DeferredCompute}(Inf), Task[], Threads.Atomic{Int}(0),
                        Threads.Atomic{Int}(0), Threads.Atomic{Int}(0))
    for _ in 1:n
        worker = Threads.@spawn for d in pool.queue
            now = Threads.atomic_add!(pool.running, 1) + 1
            Threads.atomic_max!(pool.peak, now)
            try
                run!(d)
            finally
                Threads.atomic_sub!(pool.running, 1)
            end
        end
        push!(pool.workers, errormonitor(worker))
    end
    pool
end
(pool::CountingPool)(d::DeferredCompute) = put!(pool.queue, d)
function DynamicObjects.await_deferred(wait, pool::CountingPool)
    Threads.atomic_add!(pool.waits, 1)
    wait()
end

# `n` runner slots, FIFO. A compute holds its slot while it runs; with
# `release_on_wait`, a compute blocked on another one gives its slot back meanwhile.
struct SlotQueue
    slots::Base.Semaphore
    queue::Channel{DeferredCompute}
    seen::Vector{DeferredCompute}
    lock::ReentrantLock
    release_on_wait::Bool
end
function SlotQueue(n; release_on_wait::Bool)
    q = SlotQueue(Base.Semaphore(n), Channel{DeferredCompute}(Inf), DeferredCompute[],
                  ReentrantLock(), release_on_wait)
    dispatcher = Threads.@spawn for d in q.queue
        Base.acquire(q.slots)
        errormonitor(Threads.@spawn _run_holding_slot(q, d))
    end
    errormonitor(dispatcher)
    q
end
function _run_holding_slot(q::SlotQueue, d::DeferredCompute)
    task_local_storage(:slot_holder, q)
    try
        run!(d)
    finally
        Base.release(q.slots)
    end
end
(q::SlotQueue)(d::DeferredCompute) = (lock(() -> push!(q.seen, d), q.lock); put!(q.queue, d))
function DynamicObjects.await_deferred(wait, q::SlotQueue)
    holds = q.release_on_wait && get(task_local_storage(), :slot_holder, nothing) === q
    holds || return wait()
    Base.release(q.slots)
    try
        wait()
    finally
        Base.acquire(q.slots)
    end
end
end

@testitem "a declared executor admits blocking calls and pollers share the compute" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!

reset_runs!()
r = Recorder(); EXECUTOR[] = r
o = DXApp()

# A blocking call no longer computes inline: its compute waits in the executor, and the
# caller blocks through `await_deferred`.
first = Threads.@spawn o.item(1)
@test timedwait(() -> queued(r) == 1 && waits(r) == 1, 5.0; pollint=0.01) === :ok
@test isempty(runs())
# A second blocking caller and a poller share the queued compute: nothing new is queued.
second = Threads.@spawn o.item(1)
@test timedwait(() -> waits(r) == 2, 5.0; pollint=0.01) === :ok
p = o.item(1; fetch=identity)
@test p isa Pending
@test p.executor === r
@test only(e.value for e in entries(o.item) if e.state === :running).executor === r
@test queued(r) == 1

run!(take_one!(r))
@test fetch(first) == 10
@test fetch(second) == 10
@test fetch(p) == 10            # settled: no wait, no hook
@test waits(r) == 2
@test runs() == [(:item, 1)]

# A cached value never reaches the executor or the hook.
@test o.item(1) == 10
@test queued(r) == 0
@test waits(r) == 2

# Properties without a declared executor are unchanged: computed inline.
@test o.unmarked(1) == 10
@test queued(r) == 0
EXECUTOR[] = nothing
end

@testitem "a blocking fetch of a poll handle waits through the executor" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!

reset_runs!()
r = Recorder(); EXECUTOR[] = r
o = DXApp()
p = o.item(2; fetch=identity)
@test p isa Pending
waiter = Threads.@spawn fetch(p)
@test timedwait(() -> waits(r) == 1, 5.0; pollint=0.01) === :ok
run!(take_one!(r))
@test fetch(waiter) == 20

# A caller's own `Deferred` takes precedence over the declaration.
other = Recorder()
q = o.item(3; fetch=Deferred(other))
@test q isa Pending
@test queued(other) == 1
@test queued(r) == 0
waiter = Threads.@spawn fetch(q)
@test timedwait(() -> waits(other) == 1, 5.0; pollint=0.01) === :ok
@test waits(r) == 1
run!(take_one!(other))
@test fetch(waiter) == 30
EXECUTOR[] = nothing
end

@testitem "an executor that runs inline returns the value with no wait" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!

reset_runs!()
struct Inline end
(::Inline)(d) = run!(d)
DynamicObjects.await_deferred(wait, ::Inline) = error("no wait expected")
EXECUTOR[] = Inline()
o = DXApp()
@test o.item(7) == 70
@test o.item(8; fetch=identity) == 80
@test runs() == [(:item, 7), (:item, 8)]
EXECUTOR[] = nothing
end

@testitem "declared-executor failures and abandon! reach blocking callers" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!, abandon!

reset_runs!()
r = Recorder(); EXECUTOR[] = r
o = DXApp()
caught(f) = Threads.@spawn try f() catch err; err end

abandoned = caught(() -> o.item(4))
@test timedwait(() -> queued(r) == 1, 5.0; pollint=0.01) === :ok
abandon!(take_one!(r), "stopped")
err = fetch(abandoned)
@test err isa ComputeAbandoned
@test contains(sprint(showerror, err), "stopped")
@test isempty(runs())

# retry_failed=true (the default): the next call queues a fresh compute.
retried = Threads.@spawn o.item(4)
@test timedwait(() -> queued(r) == 1, 5.0; pollint=0.01) === :ok
run!(take_one!(r))
@test fetch(retried) == 40

failing = caught(() -> o.boom(1))
@test timedwait(() -> queued(r) == 1, 5.0; pollint=0.01) === :ok
run!(take_one!(r))
err = fetch(failing)
@test err isa Exception
@test contains(sprint(showerror, err), "boom 1")
@test any(e -> e.state === :failed, entries(o.boom))
EXECUTOR[] = nothing
end

@testitem "@progress-threaded calls run on the declared executor" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects

reset_runs!()
pool = CountingPool(1); EXECUTOR[] = pool
PAUSE[] = 0.02
o = DXApp()
n = 6
@test o.batch(n) == n
PAUSE[] = 0.0
@test sort(runs()) == [(:item, i) for i in 1:n]
@test all(t -> t in pool.workers, run_tasks())
@test pool.peak[] == 1                 # one worker: never two items at once
@test pool.waits[] == n                # every iteration blocked through the hook
@test o.batch(n) == n                  # memoized
@test pool.waits[] == n
EXECUTOR[] = nothing
end

@testitem "a computation waiting on executor work can give its slot back" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: abandon!

reset_runs!()
# One slot. `outer` holds it and blocks on `item`, which needs a slot too.
q = SlotQueue(1; release_on_wait=true); EXECUTOR[] = q
o = DXApp()
done = Threads.@spawn o.outer(5)
@test timedwait(() -> istaskdone(done), 10.0; pollint=0.01) === :ok
@test fetch(done) == 51
@test runs() == [(:outer, 5), (:item, 5)]

# Control: without the hook giving the slot back, `item` is never admitted.
reset_runs!()
q = SlotQueue(1; release_on_wait=false); EXECUTOR[] = q
o = DXApp()
stuck = Threads.@spawn try o.outer(6) catch err; err end
@test timedwait(() -> istaskdone(stuck), 1.0; pollint=0.01) === :timed_out
@test runs() == [(:outer, 6)]
# Unblock it: the queued `item` is abandoned, so `outer` fails and frees the slot.
waiting = lock(() -> copy(q.seen), q.lock)
@test length(waiting) == 2
@test abandon!(waiting[2], "control") === true
@test timedwait(() -> istaskdone(stuck), 10.0; pollint=0.01) === :ok
@test contains(sprint(showerror, fetch(stuck)), "control")
EXECUTOR[] = nothing
end

@testitem "remount views admit shared and opaque work through the declared executor" setup=[DeclaredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!

reset_runs!()
r = Recorder(); EXECUTOR[] = r
source = DXApp()
views = [remount(source; ctx=i) for i in 1:2]

# Context-independent indexed work lives in the retained source's cache.
waiter = Threads.@spawn views[1].item(9)
@test timedwait(() -> queued(r) == 1 && waits(r) == 1, 5.0; pollint=0.01) === :ok
run!(take_one!(r))
@test fetch(waiter) == 90
@test views[2].item(9) == 90
@test source.item(9) == 90
@test queued(r) == 0

# Opaque work that reads no context runs once for every view, through the executor.
waiter = Threads.@spawn views[1].opaque_item(2)
@test timedwait(() -> queued(r) == 1, 5.0; pollint=0.01) === :ok
run!(take_one!(r))
@test fetch(waiter) == 20
@test views[2].opaque_item(2) == 20
@test queued(r) == 0

# Opaque work that reads context is computed per view, each one admitted.
results = map(views) do view
    task = Threads.@spawn view.ctx_item(1)
    @test timedwait(() -> queued(r) == 1, 5.0; pollint=0.01) === :ok
    run!(take_one!(r))
    fetch(task)
end
@test results == [(1, 1), (2, 1)]
@test count(==((:ctx, 1)), runs()) == 2
EXECUTOR[] = nothing
end
