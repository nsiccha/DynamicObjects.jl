using TestItemRunner

# Deferred work logs where its requester logs. A task inherits its logger from the task that
# spawns it, so a `@queued` computation admitted by another job's slot release, or a
# computation run by an executor's worker, used to log to that task's logger instead of the
# logger its caller had set (snag `log-lines-emitte-68e385aa`).
@testmodule RequesterLoggerFixtures begin
using DynamicObjects
export RLJobs, RL_STARTED, RL_GATE, gate_reset!, settles, messages

const RL_STARTED = Threads.Atomic{Int}(0)
const RL_GATE = Ref(Base.Event())

gate_reset!() = (RL_STARTED[] = 0; RL_GATE[] = Base.Event())
settles(f, seconds=10.0) = timedwait(f, seconds; pollint=0.01) === :ok
messages(logger) = [string(r.message) for r in logger.logs]

@dynamicstruct struct RLJobs
    # Holds the queue's only slot until the test opens the gate.
    @queued gated(i::Int) = (Threads.atomic_add!(RL_STARTED, 1); wait(RL_GATE[]); @info "gated $i"; i)
    @queued item(i::Int) = (@info "item $i"; 10i)
    @queued @fresh fresh_item(i::Int) = (@info "fresh item $i"; 10i)
    # Waits on a queued child, which needs the coordinator's slot back.
    @queued coordinator(i::Int) = (@info "coordinator $i"; item(100 + i) + 1)
    work(i::Int) = (@info "work $i"; 10i)
end
end

@testitem "a waiting @queued computation logs to its caller's logger, not its admitter's" setup=[RequesterLoggerFixtures] begin
using DynamicObjects, Logging
gate_reset!()
DynamicObjects.configure_queue!(; max_running=1)
try
    o = RLJobs()
    blocker_log, item_log, fresh_log, coordinator_log = (TestLogger() for _ in 1:4)
    blocker = Threads.@spawn with_logger(() -> o.gated(1), blocker_log)   # holds the only slot
    @test settles(() -> RL_STARTED[] == 1)
    callers = [Threads.@spawn(with_logger(() -> o.item(2), item_log)),
               Threads.@spawn(with_logger(() -> o.fresh_item(3), fresh_log)),
               Threads.@spawn(with_logger(() -> o.coordinator(4), coordinator_log))]
    @test settles(() -> DynamicObjects.queue_settings().queued == 3)
    notify(RL_GATE[])                    # the blocker's release admits the waiting calls
    @test fetch(blocker) == 1
    # A coordinator that kept its slot while waiting would deadlock the queue.
    settles(() -> all(istaskdone, callers)) || DynamicObjects.configure_queue!(; max_running=0)
    @test fetch.(callers) == [20, 30, 1041]
    @test messages(blocker_log) == ["gated 1"]
    @test messages(item_log) == ["item 2"]
    @test messages(fresh_log) == ["fresh item 3"]
    @test sort(messages(coordinator_log)) == ["coordinator 4", "item 104"]
finally
    DynamicObjects.configure_queue!(; max_running=0)
end
end

@testitem "an executor's worker logs a computation to the logger it was started under" setup=[RequesterLoggerFixtures] begin
using DynamicObjects, Logging
import DynamicObjects: run!
o = RLJobs()
jobs = Channel{Any}(Inf)
worker_log, caller_log = TestLogger(), TestLogger()
worker = with_logger(() -> Threads.@spawn(foreach(run!, jobs)), worker_log)
value = with_logger(caller_log) do
    p = o.work(1; fetch=Deferred(d -> put!(jobs, d)))
    @test p isa Pending
    fetch(p)
end
close(jobs)
wait(worker)
@test value == 10
@test messages(caller_log) == ["work 1"]
@test isempty(worker_log.logs)
end
