using TestItemRunner

@testmodule DeferredExecutorFixtures begin
using DynamicObjects
export DeferredApp, DEFERRED_GATES, DEFERRED_RUNS, reset_deferred!, release_deferred!

const DEFERRED_LOCK = ReentrantLock()
const DEFERRED_GATES = Dict{Int,Base.Event}()
const DEFERRED_RUNS = Int[]

function reset_deferred!()
    lock(DEFERRED_LOCK) do
        empty!(DEFERRED_GATES)
        empty!(DEFERRED_RUNS)
    end
end

release_deferred!(x) = notify(lock(() -> get!(Base.Event, DEFERRED_GATES, x), DEFERRED_LOCK))

function gated(x)
    gate = lock(DEFERRED_LOCK) do
        push!(DEFERRED_RUNS, x)
        get!(Base.Event, DEFERRED_GATES, x)
    end
    wait(gate)
    x * 10
end

@dynamicstruct struct DeferredApp
    work(x) = gated(x)
    boom(x) = error("boom $x")
end
end

@testitem "Deferred hands first-arriving computes to its executor" setup=[DeferredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!, abandon!

reset_deferred!()
queue = DeferredCompute[]
queue_lock = ReentrantLock()
executor = d -> lock(() -> push!(queue, d), queue_lock)
sel = Deferred(executor)
o = DeferredApp()

# First arriver: a Pending comes back and the compute sits in the queue unstarted.
p = o.work(1; fetch=sel)
@test p isa Pending
@test !isready(p)
@test length(queue) == 1
@test isempty(DEFERRED_RUNS)

# While queued the key is in flight: a second poller dedupes onto it (no second
# enqueue) and shows up as :running in `entries`.
p2 = o.work(1; fetch=sel)
@test p2 isa Pending
@test length(queue) == 1
@test any(e -> e.state === :running, entries(o.work))

# A blocking accessor waits on the queued compute instead of recomputing.
blocking = Threads.@spawn o.work(1)
@test timedwait(() -> istaskstarted(blocking), 5.0) === :ok
sleep(0.05)
@test !istaskdone(blocking)

# The executor runs it; everyone gets the one value.
d = only(queue)
runner = Threads.@spawn run!(d)
@test timedwait(() -> DEFERRED_RUNS == [1], 5.0; pollint=0.01) === :ok
release_deferred!(1)
@test fetch(runner) === true
@test fetch(p) == 10
@test fetch(p2) == 10
@test fetch(blocking) == 10
@test DEFERRED_RUNS == [1]
@test run!(d) === false            # only the first claim takes effect
@test abandon!(d) === false
@test o.work(1; fetch=sel) == 10   # cached: no executor call
@test length(queue) == 1
end

@testitem "abandon! fails a queued compute and allows a retry" setup=[DeferredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!, abandon!

reset_deferred!()
queue = DeferredCompute[]
sel = Deferred(d -> push!(queue, d))
o = DeferredApp()

p = o.work(2; fetch=sel)
waiter = Threads.@spawn try
    fetch(p)
catch err
    err
end
d = only(queue)
@test abandon!(d, "client went away") === true
err = fetch(waiter)
@test err isa ComputeAbandoned
@test contains(sprint(showerror, err), "client went away")
@test isempty(DEFERRED_RUNS)                 # never ran
@test run!(d) === false
@test any(e -> e.state === :failed, entries(o.work))

# The default retry_failed=true recomputes on the next access.
release_deferred!(2)
@test o.work(2) == 20
@test DEFERRED_RUNS == [2]
end

@testitem "Deferred executors may run inline and failures are recorded" setup=[DeferredExecutorFixtures] begin
using DynamicObjects
import DynamicObjects: run!

reset_deferred!()
inline = Deferred(d -> run!(d))
o = DeferredApp()
release_deferred!(3)
# Running synchronously inside the executor makes the call blocking: the value,
# not a Pending, comes back.
@test o.work(3; fetch=inline) == 30

# A failing deferred compute is recorded, not thrown from the worker.
p = o.boom(1; fetch=inline)
@test_throws Exception fetch(p)
@test any(e -> e.state === :failed, entries(o.boom))

# A bounded FIFO pool: at most `n` computes run at once.
reset_deferred!()
function bounded_executor(n)
    queue = Channel{DeferredCompute}(Inf)
    for _ in 1:n
        worker = Threads.@spawn for d in queue
            run!(d)
        end
        errormonitor(worker)
    end
    d -> put!(queue, d)
end
pool = Deferred(bounded_executor(1))
handles = [o.work(x; fetch=pool) for x in 10:12]
@test all(h -> h isa Pending, handles)
@test timedwait(() -> length(DEFERRED_RUNS) == 1, 5.0; pollint=0.01) === :ok
sleep(0.1)
@test DEFERRED_RUNS == [10]                  # the others wait their turn
foreach(release_deferred!, 10:12)
@test fetch.(handles) == [100, 110, 120]
@test DEFERRED_RUNS == [10, 11, 12]
end
