using TestItemRunner

# The bounded job queue and the `@queued` marker. `@queued` on an indexed, memoized
# property admits every computation of it through `job_queue()`, whoever calls it: a plain
# call from any task, a `Threads.@threads` iteration, a progress-threaded call, another
# property's body. At most `max_running` run at once. A queued computation that blocks on
# another one — or a task it spawned does — gives its slot back for good, so coordinators
# waiting on queued children cannot deadlock the queue.
#
# Every item that might deadlock switches the queue off before it fetches: a failed
# `timedwait` followed by `fetch` would hang instead of failing.
@testmodule JobQueueFixtures begin
using DynamicObjects
using DynamicObjects.Treebars: render_text
import DynamicObjects.Treebars
export Jobs, CallWork, counts_reset!, peak, done, running, gate!, release!, queue_off!,
       heavy!, settles

const COUNTS_LOCK = ReentrantLock()
const COUNTS = Dict(:running => 0, :peak => 0, :done => 0)
const GATES = Dict{Int,Base.Event}()

counts_reset!() = lock(COUNTS_LOCK) do
    foreach(k -> COUNTS[k] = 0, collect(keys(COUNTS)))
    empty!(GATES)
end
peak() = lock(() -> COUNTS[:peak], COUNTS_LOCK)
done() = lock(() -> COUNTS[:done], COUNTS_LOCK)
running() = lock(() -> COUNTS[:running], COUNTS_LOCK)
gate!(b) = lock(() -> get!(Base.Event, GATES, b), COUNTS_LOCK)
release!(b) = notify(gate!(b))
queue_off!() = DynamicObjects.configure_queue!(; max_running=0)
settles(f, seconds) = timedwait(f, seconds; pollint=0.01) === :ok

# A heavy body: counts how many run at once and records its threadpool. A gated batch
# (`b < 0`) holds until the test releases it.
function heavy!(b::Int, i::Int)
    lock(COUNTS_LOCK) do
        COUNTS[:running] += 1
        COUNTS[:peak] = max(COUNTS[:peak], COUNTS[:running])
    end
    try
        b < 0 ? wait(gate!(b)) : sleep(0.05)
    finally
        lock(COUNTS_LOCK) do
            COUNTS[:running] -= 1
            COUNTS[:done] += 1
        end
    end
    (i, Threads.threadpool())
end

# A coordinator's `Threads.@threads` loop over queued items. With `release=false` each
# iteration polls its item's handle instead of blocking on it — a wait the queue cannot
# see, so the coordinator keeps its slot.
function run_items(o, b::Int, n::Int, release::Bool)
    total = Threads.Atomic{Int}(0)
    Threads.@threads for i in 1:n
        handle = o.item(b, i; fetch=identity)
        if !release && handle isa Pending
            while !isready(handle)
                sleep(0.01)
            end
        end
        value = handle isa Pending ? fetch(handle) : handle
        Threads.atomic_add!(total, first(value))
    end
    total[]
end

@dynamicstruct struct Jobs
    "Synthetic heavy item"
    @queued @progress item(b::Int, i::Int) = heavy!(b, i)
    "Unmarked item"
    free_item(b::Int, i::Int) = heavy!(b, i)
    # A coordinator whose `Threads.@threads` iterations call the queued item with a
    # plain (blocking) call.
    @queued batch(b::Int, n::Int) = begin
        total = Threads.Atomic{Int}(0)
        Threads.@threads for i in 1:n
            Threads.atomic_add!(total, first(item(b, i)))
        end
        total[]
    end
    # The same coordinator, choosing whether its waits are visible to the queue.
    @queued polled_batch(b::Int, n::Int; release::Bool=true) =
        run_items(__self__, b, n, release)
    # A caller with a progress tree: its loop's item calls are threaded through
    # `__progress__`, so each item's node hangs under "Items".
    @progress listing(b::Int, n::Int) = begin
        Treebars.@progress "Items" for i in 1:n
            item(b, i)
        end
        n
    end
    "Synthetic failing item"
    @queued doomed(i::Int) = error("doomed $i")
    "Synthetic fresh item"
    @queued @fresh fresh_item(b::Int, i::Int) = heavy!(b, i)
    # The progress-threaded caller of the fresh item.
    @progress fresh_listing(b::Int, n::Int) = begin
        Treebars.@progress "Fresh items" for i in 1:n
            fresh_item(b, i)
        end
        n
    end
end

# Work for a `QueuedCall`: a gated call counts like an item.
CallWork(b, i) = () -> first(heavy!(b, i))
end

@testitem "@queued runs at most max_running computations at once, from any task" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
cap = 2
try
    DynamicObjects.configure_queue!(; max_running=cap)
    # 3×cap concurrent plain calls of the queued property: at most `cap` bodies run at
    # once, each on `:default`.
    counts_reset!()
    w = Jobs()
    results = fetch.([Threads.@spawn w.item(1, i) for i in 1:3cap])
    @test first.(results) == collect(1:3cap)
    @test all(==(:default), last.(results))
    @test done() == 3cap
    @test peak() == cap
    @test DynamicObjects.queue_settings() == (; max_running=cap, queued=0, running=0)

    # The same calls from `Threads.@threads` iterations.
    counts_reset!()
    total = Threads.Atomic{Int}(0)
    Threads.@threads for i in 1:3cap
        Threads.atomic_add!(total, first(w.item(2, i)))
    end
    @test total[] == sum(1:3cap)
    @test peak() == min(cap, Threads.nthreads())

    # Control: the same calls of the unmarked property all run at once.
    counts_reset!()
    fetch.([Threads.@spawn w.free_item(3, i) for i in 1:3cap])
    @test peak() == 3cap
finally
    queue_off!()
end
end

@testitem "callers of one @queued computation share it and its slot; cached values never queue" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
seen = DynamicObjects.QueuedItem[]
seen_lock = ReentrantLock()
observer = DynamicObjects.observe_queue!(item -> lock(() -> push!(seen, item), seen_lock))
try
    DynamicObjects.configure_queue!(; max_running=1)
    counts_reset!()
    w = Jobs()
    shared = fetch.([Threads.@spawn w.item(4, 1) for _ in 1:3])
    @test allequal(shared)
    @test done() == 1
    items = lock(() -> copy(seen), seen_lock)
    @test length(items) == 1
    @test only(items).property === :item
    @test only(items).work isa DeferredCompute
    @test only(items).tag === nothing
    # Cached: neither runs nor queues.
    @test w.item(4, 1) == first(shared)
    @test done() == 1
    @test lock(() -> length(seen), seen_lock) == 1
finally
    DynamicObjects.unobserve_queue!(observer)
    queue_off!()
end
# Unobserved: later enqueues reach no one.
Jobs().item(5, 1)
@test length(seen) == 1
end

@testitem "@queued coordinators waiting on @queued children from @threads all complete" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
cap = 2
try
    DynamicObjects.configure_queue!(; max_running=cap)
    # `cap` coordinators take every slot, then each waits on 3×cap queued items from
    # `Threads.@threads` iterations. Holding their slots while they wait would deadlock.
    counts_reset!()
    w = Jobs()
    coordinators = [Threads.@spawn w.batch(b, 3cap) for b in 10:9+cap]
    ok = settles(() -> all(istaskdone, coordinators), 60.0)
    @test ok
    ok || queue_off!()
    @test fetch.(coordinators) == fill(sum(1:3cap), cap)
    @test done() == cap * 3cap
    @test peak() <= cap
    @test DynamicObjects.queue_settings().running == 0

    # The same through poll handles that the coordinators `fetch`.
    counts_reset!()
    coordinators = [Threads.@spawn w.polled_batch(b, 3cap) for b in 20:19+cap]
    ok = settles(() -> all(istaskdone, coordinators), 60.0)
    @test ok
    ok || queue_off!()
    @test fetch.(coordinators) == fill(sum(1:3cap), cap)
    @test peak() <= cap
finally
    queue_off!()
end
end

@testitem "a coordinator that hides its wait keeps its slot and deadlocks the queue" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
cap = 2
try
    DynamicObjects.configure_queue!(; max_running=cap)
    # Control for the item above: each iteration polls `isready` instead of blocking, so
    # the coordinators keep their slots and their children never start.
    counts_reset!()
    w = Jobs()
    stuck = [Threads.@spawn w.polled_batch(b, 3cap; release=false) for b in 30:29+cap]
    @test !settles(() -> all(istaskdone, stuck), 2.0)
    @test done() == 0
    @test DynamicObjects.queue_settings().running == cap
    @test DynamicObjects.queue_settings().queued > 0
    # Switching the queue off starts everything waiting, which ends it.
    queue_off!()
    @test settles(() -> all(istaskdone, stuck), 60.0)
    @test fetch.(stuck) == fill(sum(1:3cap), cap)
    @test done() == cap * 3cap
finally
    queue_off!()
end
end

@testitem "a caller's progress tree shows its waiting @queued child as queued · #k" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
using DynamicObjects.Treebars: render_text
try
    DynamicObjects.configure_queue!(; max_running=1)
    counts_reset!()
    w = Jobs()
    # A gated item holds the one slot; the caller's item waits behind it.
    blocker = Threads.@spawn w.item(-1, 1)
    @test settles(() -> DynamicObjects.queue_settings().running == 1, 10.0)
    caller = Threads.@spawn w.listing(40, 1)
    @test settles(() -> DynamicObjects.queue_settings().queued == 1, 10.0)
    @test settles(() -> contains(render_text(w.__status__), "queued · #1"), 10.0)
    @test contains(render_text(w.__status__), "Items")
    release!(-1)
    @test settles(() -> istaskdone(caller), 30.0)
    @test fetch(caller) == 1
    @test !contains(render_text(w.__status__), "queued · #")
    fetch(blocker)
finally
    release!(-1)
    queue_off!()
end
end

@testitem "a waiting @queued computation's node is pending, and its clock starts at admission" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
using DynamicObjects.Treebars: render_text, is_pending, is_running, duration
import DynamicObjects.Treebars
using Dates: Millisecond
# The progress node of the computation waiting behind `w`'s gated blocker.
waiting_node(w) = begin
    found = nothing
    walk(n) = (n.impl.message == "queued · #1" && (found = n); foreach(walk, n.children))
    walk(w.__status__)
    found
end
try
    DynamicObjects.configure_queue!(; max_running=1)
    counts_reset!()
    w = Jobs()
    blocker = Threads.@spawn w.item(-7, 1)
    @test settles(() -> DynamicObjects.queue_settings().running == 1, 10.0)
    caller = Threads.@spawn w.listing(41, 1)
    @test settles(() -> waiting_node(w) !== nothing, 10.0)
    node = waiting_node(w)
    # Waiting is not running: pending (`·`), no duration, the note kept.
    @test is_pending(node.impl)
    line = only(filter(contains("queued · #1"), split(render_text(w.__status__), '\n')))
    @test contains(line, "· Synthetic heavy item — queued · #1")
    @test !contains(line, "▶")
    @test !contains(line, "[")
    sleep(0.6)
    @test duration(node.impl) == Millisecond(0)
    release!(-7)
    @test settles(() -> istaskdone(caller), 30.0)
    @test fetch(caller) == 1
    # It ran for its own ~0.05 s, not for the ~0.6 s it waited.
    @test !is_pending(node.impl) && !is_running(node.impl)
    @test duration(node.impl) < Millisecond(500)
    fetch(blocker)

    # A waiting fresh call of a `@queued` property is pending the same way.
    blocker = Threads.@spawn w.item(-8, 1)
    @test settles(() -> DynamicObjects.queue_settings().running == 1, 10.0)
    caller = Threads.@spawn w.fresh_listing(83, 1)
    @test settles(() -> waiting_node(w) !== nothing, 10.0)
    node = waiting_node(w)
    @test is_pending(node.impl)
    sleep(0.6)
    release!(-8)
    @test settles(() -> istaskdone(caller), 30.0)
    @test fetch(caller) == 1
    @test !is_pending(node.impl) && !is_running(node.impl)
    @test duration(node.impl) < Millisecond(500)
    fetch(blocker)
finally
    release!(-7)
    release!(-8)
    queue_off!()
end
end

@testitem "raising the cap admits more; switching the queue off admits everything" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
try
    DynamicObjects.configure_queue!(; max_running=1)
    counts_reset!()
    w = Jobs()
    calls = [Threads.@spawn w.item(-2, i) for i in 1:4]
    @test settles(() -> DynamicObjects.queue_settings() ==
                        (; max_running=1, queued=3, running=1), 10.0)
    @test DynamicObjects.configure_queue!(; max_running=3) ==
          (; max_running=3, queued=1, running=3)
    @test settles(() -> running() == 3, 10.0)
    @test DynamicObjects.configure_queue!(; max_running=0).queued == 0
    @test settles(() -> running() == 4, 10.0)
    # Unchanged when omitted; refused when negative.
    @test DynamicObjects.configure_queue!().max_running == 0
    @test_throws ArgumentError DynamicObjects.configure_queue!(; max_running=-1)
    release!(-2)
    @test first.(fetch.(calls)) == 1:4
    # Slots taken while the cap was on are given back as those computations finish.
    @test settles(() -> DynamicObjects.queue_settings().running == 0, 10.0)
finally
    release!(-2)
    queue_off!()
end
end

@testitem "positions, abandonment and failures of waiting @queued computations" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
try
    DynamicObjects.configure_queue!(; max_running=1)
    counts_reset!()
    w = Jobs()
    blocker = Threads.@spawn w.item(-3, 1)
    @test settles(() -> DynamicObjects.queue_settings().running == 1, 10.0)
    # Poll handles of waiting computations know their positions.
    p2 = w.item(50, 2; fetch=identity)
    p3 = w.item(50, 3; fetch=identity)
    @test p2 isa Pending && p3 isa Pending
    @test DynamicObjects.queue_position(p2) == 1
    @test DynamicObjects.queue_position(p3) == 2
    items = DynamicObjects.queued_items()
    @test DynamicObjects.queue_position(items[2]) == 2
    @test DynamicObjects.queue_position(items[1].work) == 1
    # Abandoning the first moves the second up; the abandoned key fails, and a later
    # access starts afresh.
    @test DynamicObjects.abandon_queued!(DynamicObjects.job_queue(), items[1:1], "gone") == 1
    @test DynamicObjects.abandon_queued!(DynamicObjects.job_queue(), items[1:1], "gone") == 0
    @test DynamicObjects.queue_position(p2) === nothing
    @test DynamicObjects.queue_position(p3) == 1
    err = try
        fetch(p2)
        nothing
    catch e
        e
    end
    @test err isa ComputeAbandoned
    @test contains(err.reason, "gone")
    release!(-3)
    fetch(blocker)
    @test first(fetch(p3)) == 3
    @test first(w.item(50, 2)) == 2
    # A failing queued computation reaches its caller and gives its slot back.
    @test_throws "doomed 7" w.doomed(7)
    @test settles(() -> DynamicObjects.queue_settings().running == 0, 10.0)
finally
    release!(-3)
    queue_off!()
end
end

@testitem "QueuedCall queues work without a cache cell" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
import DynamicObjects: QueuedCall, JobQueue, enqueue!, run!, abandon!
counts_reset!()
q = JobQueue(; max_running=1)
blocker = QueuedCall(CallWork(-4, 1))
item = enqueue!(q, blocker; tag=:route)
@test item.tag === :route && item.property === nothing
@test settles(() -> DynamicObjects.queue_settings(q).running == 1, 10.0)
call = QueuedCall(CallWork(60, 2))
waiting = enqueue!(q, call)
@test !isready(call)
@test DynamicObjects.queue_position(call, q) == 1
@test DynamicObjects.queue_position(waiting, q) == 1
release!(-4)
@test fetch(call) == 2
@test fetch(blocker) == 1
# Exactly one of run! and abandon! takes effect.
@test !run!(call) && !abandon!(call, "late")
# Failures and abandonment reach `fetch`.
failing = enqueue!(q, QueuedCall(() -> error("call failed"))).work
@test_throws "call failed" fetch(failing)
gated = enqueue!(q, QueuedCall(CallWork(-5, 3))).work
@test settles(() -> DynamicObjects.queue_settings(q).running == 1, 10.0)
dropped = enqueue!(q, QueuedCall(CallWork(60, 4)))
@test DynamicObjects.abandon_queued!(q, [dropped]) == 1
@test_throws ComputeAbandoned fetch(dropped.work)
release!(-5)
@test fetch(gated) == 3
@test DynamicObjects.queue_settings(q) == (; max_running=1, queued=0, running=0)
# A queued call that blocks on another one in the same queue gives its slot back.
inner = QueuedCall(CallWork(60, 5))
outer = QueuedCall(() -> fetch(enqueue!(q, inner).work) + 1)
enqueue!(q, outer)
ok = settles(() -> isready(outer), 30.0)
@test ok
ok || DynamicObjects.configure_queue!(q; max_running=0)
@test fetch(outer) == 6
release!(-4); release!(-5)
end

@testitem "a throwing queue observer is logged and the item still runs" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects, Logging, Test
observer = DynamicObjects.observe_queue!(item -> error("observer broke"))
try
    w = Jobs()
    value = @test_logs (:error, r"observer threw") match_mode=:any w.item(70, 1)
    @test first(value) == 1
finally
    DynamicObjects.unobserve_queue!(observer)
end
end

@testitem "fresh computations of @queued properties wait their turn too" setup=[JobQueueFixtures] tags=[:core] begin
using DynamicObjects
using DynamicObjects.Treebars: render_text
cap = 2
try
    DynamicObjects.configure_queue!(; max_running=cap)
    # A declaration-site `@queued @fresh` property: every call computes, at most `cap`
    # at a time, on `:default`.
    counts_reset!()
    w = Jobs()
    results = fetch.([Threads.@spawn w.fresh_item(80, 1) for _ in 1:3cap])
    @test first.(results) == fill(1, 3cap)
    @test all(==(:default), last.(results))
    @test done() == 3cap
    @test peak() == cap
    # A call-site `fresh` of a memoized `@queued` property is queued as well.
    counts_reset!()
    fetch.([Threads.@spawn fresh(w.item, 81, 1) for _ in 1:3cap])
    @test done() == 3cap
    @test peak() == cap
    @test DynamicObjects.queue_settings() == (; max_running=cap, queued=0, running=0)

    # A progress-threaded caller shows its waiting fresh call as queued.
    DynamicObjects.configure_queue!(; max_running=1)
    blocker = Threads.@spawn w.item(-6, 1)
    @test settles(() -> DynamicObjects.queue_settings().running == 1, 10.0)
    caller = Threads.@spawn w.fresh_listing(82, 1)
    @test settles(() -> contains(render_text(w.__status__), "queued · #1"), 10.0)
    @test contains(render_text(w.__status__), "Fresh items")
    release!(-6)
    @test settles(() -> istaskdone(caller), 30.0)
    @test fetch(caller) == 1
    @test !contains(render_text(w.__status__), "queued · #")
    fetch(blocker)
finally
    release!(-6)
    queue_off!()
end
end

@testitem "@queued needs an indexed property" tags=[:core] begin
using DynamicObjects
# refused: DynamicObjects starts only memoized computations of call-form properties
# through a declared executor, so `@queued` on a bare property could admit nothing
# (todo `2026-10-07T03-56-29-043-1qvde11`).
bare = :(@dynamicstruct struct BareQueued
    @queued total = 1
end)
@test_throws "call form" macroexpand(@__MODULE__, bare)
end
