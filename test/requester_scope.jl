using TestItemRunner

# Deferred work runs in its requester's dynamic scope. A task inherits its scoped values from
# the task that spawns it, so a `@queued` computation admitted by another job's slot release,
# or a computation run by an executor's worker, used to see that task's scoped values — a
# layer's request context (HTMXObjects' reader and page language) was lost there (snag
# `queued-work-drop-1178886a`). Only the job queue's slot stays the running task's own.
@testmodule RequesterScopeFixtures begin
using DynamicObjects
import DynamicObjects: ScopedValues
export RSJobs, RS_TAG, RS_STARTED, RS_GATE, gate_reset!, settles, seen, seen_reset!, tagged

const RS_TAG = ScopedValues.ScopedValue{Symbol}(:unset)
const RS_STARTED = Threads.Atomic{Int}(0)
const RS_GATE = Ref(Base.Event())
const RS_SEEN = Dict{String,Any}()
const RS_LOCK = ReentrantLock()

gate_reset!() = (RS_STARTED[] = 0; RS_GATE[] = Base.Event())
settles(f, seconds=10.0) = timedwait(f, seconds; pollint=0.01) === :ok
see!(k, v=RS_TAG[]) = lock(() -> (RS_SEEN[k] = v), RS_LOCK)
seen(k) = lock(() -> get(RS_SEEN, k, :never), RS_LOCK)
seen_reset!() = lock(() -> empty!(RS_SEEN), RS_LOCK)
tagged(f, tag::Symbol) = ScopedValues.with(f, RS_TAG => tag)

@dynamicstruct struct RSJobs
    # Holds the queue's only slot until the test opens the gate.
    @queued gated(i::Int) = (see!("gated $i"); Threads.atomic_add!(RS_STARTED, 1); wait(RS_GATE[]); i)
    @queued item(i::Int) = (see!("item $i"); 10i)
    @queued @fresh fresh_item(i::Int) = (see!("fresh item $i"); 10i)
    # Waits on a queued child, which needs the coordinator's slot back.
    @queued coordinator(i::Int) = (see!("coordinator $i"); item(100 + i) + 1)
    work(i::Int) = (see!("work $i"); 10i)
    # Each records the queue slot it runs under.
    @queued outer(i::Int) = (see!("outer $i", DynamicObjects._QUEUE_HOLDER[]); inner(i) + 1)
    @queued inner(i::Int) = (see!("inner $i", DynamicObjects._QUEUE_HOLDER[]); 10i)
end
end

@testitem "a waiting @queued computation sees its caller's scoped values, not its admitter's" setup=[RequesterScopeFixtures] begin
using DynamicObjects
gate_reset!(); seen_reset!()
DynamicObjects.configure_queue!(; max_running=1)
try
    o = RSJobs()
    blocker = Threads.@spawn tagged(() -> o.gated(1), :blocker)   # holds the only slot
    @test settles(() -> RS_STARTED[] == 1)
    callers = [Threads.@spawn(tagged(() -> o.item(2), :item_caller)),
               Threads.@spawn(tagged(() -> o.fresh_item(3), :fresh_caller)),
               Threads.@spawn(tagged(() -> o.coordinator(4), :coordinator_caller))]
    @test settles(() -> DynamicObjects.queue_settings().queued == 3)
    notify(RS_GATE[])                    # the blocker's release admits the waiting calls
    @test fetch(blocker) == 1
    # A coordinator that kept its slot while waiting would deadlock the queue.
    settles(() -> all(istaskdone, callers)) || DynamicObjects.configure_queue!(; max_running=0)
    @test fetch.(callers) == [20, 30, 1041]
    @test seen("gated 1") === :blocker
    @test seen("item 2") === :item_caller
    @test seen("fresh item 3") === :fresh_caller
    @test seen("coordinator 4") === :coordinator_caller
    # The coordinator requested its child, so the child runs in the coordinator's scope.
    @test seen("item 104") === :coordinator_caller
finally
    DynamicObjects.configure_queue!(; max_running=0)
end
end

@testitem "an executor's worker runs a computation in the scope it was started in" setup=[RequesterScopeFixtures] begin
using DynamicObjects
import DynamicObjects: run!
seen_reset!()
o = RSJobs()
jobs = Channel{Any}(Inf)
worker = tagged(() -> Threads.@spawn(foreach(run!, jobs)), :worker)
value = tagged(:caller) do
    p = o.work(1; fetch=Deferred(d -> put!(jobs, d)))
    @test p isa Pending
    fetch(p)
end
close(jobs)
wait(worker)
@test value == 10
@test seen("work 1") === :caller
end

@testitem "a queued computation holds its own queue slot, not its requester's" setup=[RequesterScopeFixtures] begin
using DynamicObjects
seen_reset!()
DynamicObjects.configure_queue!(; max_running=2)
try
    o = RSJobs()
    t = Threads.@spawn o.outer(1)
    settles(() -> istaskdone(t)) || DynamicObjects.configure_queue!(; max_running=0)
    @test fetch(t) == 11
    outer_slot, inner_slot = seen("outer 1"), seen("inner 1")
    @test outer_slot isa DynamicObjects._QueueSlot
    @test inner_slot isa DynamicObjects._QueueSlot
    # `outer` requested `inner`; re-entering outer's scope must not hand inner outer's slot.
    @test inner_slot !== outer_slot
finally
    DynamicObjects.configure_queue!(; max_running=0)
end
end
