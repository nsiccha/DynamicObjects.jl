using TestItemRunner

@testitem "worker pool: admission, root affinity, replica invalidation and isolated failure" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
const DO = DynamicObjects
dir = mktempdir()
root = mktempdir()
t = Toy(2, root)
other = Toy(3, mktempdir())
slots() = DO.worker_status().processes
gate(obj, x) = obj.gated(x; dir, fetch=identity)
release(x) = touch(joinpath(dir, "go_$x"))
started(x) = settles(() -> any(startswith("started_$(x)_"), readdir(dir)), 120.0)
try
    DO.configure_queue!(; workers=2, max_running=2)
    @test !any(p -> p.running, slots())
    @test_throws ArgumentError DO.restart_worker!()
    @test_throws ArgumentError DO.restart_worker!(; pid=-1)

    fit = gate(t, 1)
    started(1) || error("first request did not reach its worker")
    joined = gate(t, 1)
    figure = gate(t, 2)
    started(2) || error("same-root figure could not start beside the fit")
    pids = [s.pid for s in slots()]
    @test all(p -> p != getpid(), pids) && allunique(pids)
    @test [s.in_flight for s in slots()] == [1, 1]
    waiting = gate(other, 3)
    @test settles(() -> DO.queue_settings().queued == 1)
    release(2)
    @test fetch(figure).pid == pids[2]
    started(3) || error("global admission did not release the next request")
    release(3)
    @test fetch(waiting).pid == pids[2]
    # While slot one is held, slot two must publish this disk entry and serve this root.
    disk = t.cube(7)
    @test disk.pid == pids[2] && disk.value == 686
    @test isfile(DO.get_cache_path(t, :cube, 7))
    second = t.square(7)
    release(1)
    @test fetch(fit) == fetch(joined)
    @test fetch(fit).pid == pids[1] && fetch(fit).value == 3
    @test other.fresh_item(10).pid == pids[2]  # warm root wins a tie with slot one

    # Populate the same construction's memory memo on both processes. Distinct requester
    # objects bypass the requester memo while reaching the identical worker address.
    first = Toy(2, root).square(7)
    @test first.pid == pids[1] && second.pid == pids[2]
    invalidate!(t.square, 7)
    invalidate!(t.cube, 7)
    @test !isfile(DO.get_cache_path(t, :cube, 7))
    @test Toy(2, root).square(7).n > first.n
    hold = gate(t, 4)
    started(4) || error("replacement fit did not start")
    @test Toy(2, root).square(7).n > second.n
    @test Toy(2, root).cube(7).n > disk.n

    # A busy surplus worker survives idle cleanup. Its sibling's abrupt exit fails only
    # that request; after release the surplus exits, and subsequent overlap recreates it.
    survivor = gate(t, 5)
    started(5) || error("surviving request did not start")
    DO.configure_queue!(; worker_idle_timeout=0.25)
    sleep(0.5)
    @test [s.pid for s in slots()] == pids
    run(Sys.iswindows() ? `taskkill /F /PID $(pids[1])` : `kill -9 $(pids[1])`)
    @test_throws ComputeAbandoned fetch(hold)
    release(5)
    @test fetch(survivor).pid == pids[2]
    @test settles(() -> !slots()[2].running)
    fresh = gate(t, 6)
    started(6) || error("first worker did not recover")
    newpid = slots()[1].pid
    @test newpid != pids[1]
    retry = gate(t, 7)
    started(7) || error("surplus worker did not recover")
    replacement_pid = slots()[2].pid
    DO.restart_worker!(; pid=pids[2])
    @test slots()[2].pid == replacement_pid
    DO.restart_worker!(; pid=replacement_pid)
    @test_throws ComputeAbandoned fetch(retry)
    release(6)
    @test fetch(fresh).pid == newpid
finally
    foreach(release, 1:7)
    DO.configure_queue!(; workers=0, max_running=0, worker_idle_timeout=300)
end
end

@testitem "worker pool: a retracted disk publisher cannot unlink its replacement" begin
using DynamicObjects, Serialization
const DO = DynamicObjects
# Hold the actual format writer across retraction and publication by another writer.
# The guard and serialization path here are the ones used by @cached and @mmap.
const writing = Channel{Nothing}(1)
const finish = Channel{Nothing}(1)
function DO.save(::Val{:pool_gate}, path::AbstractString, x)
    serialize(path, x)
    put!(writing, nothing)
    take!(finish)
end
cache = DO.ThreadsafeDict()
key = :entry
latch = Threads.Condition(cache.lock)
cache.computing[key] = latch
guard = DO._PublishGuard(cache, key, latch)
mktempdir() do dir
    path = joinpath(dir, "value")
    stale = Threads.@spawn DO._save_if_publishable!(guard, Val(:pool_gate), path, "old")
    take!(writing)
    try
        lock(() -> delete!(cache.computing, key), cache.lock)
        @test DO._save_if_publishable!(nothing, Val(:serial), path, "new")
    finally
        put!(finish, nothing)
    end
    @test !fetch(stale)
    @test deserialize(path) == "new"
    @test readdir(dir) == ["value"]
end
end

@testitem "worker pool: scope ownership and pruning cover both copies" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
q = DO.job_queue()
report = WorkerToy.ScopedReport(9)
dir = mktempdir()
toy = Toy(1, dir)
slots() = DO.worker_status().processes
function fill_both(round)
    @test report.render(10round) == 10round * 1024^2
    hold = toy.gated(round; dir, fetch=identity)
    settles(() -> any(startswith("started_$(round)_"), readdir(dir)), 120.0) || error("gate did not open")
    try
        @test report.render(10round+1) == (10round+1) * 1024^2
    finally
        touch(joinpath(dir, "go_$round"))
    end
    fetch(hold)
end
try
    DO.configure_queue!(; workers=2, worker_idle_timeout=Inf)
    with_compute_scope() do
        fill_both(1)
        DO.configure_queue!(; worker_idle_timeout=0.1)
        sleep(0.3)
        @test all(p -> p.running, slots())
        DO.configure_queue!(; worker_idle_timeout=Inf)
    end
    @test prune_worker_mem_caches!(Returns(false), report).evicted == 0
    fill_both(2)
    @test prune_worker_mem_caches!(Returns(false), report).evicted == 2
finally
    DO.configure_queue!(; workers=0, worker_idle_timeout=300)
end
end

@testitem "worker pool: a replacement waits for invalidation on the other replica" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
const DO = DynamicObjects
q = DO.job_queue()
dir = mktempdir()
t = Toy(1, dir)
resume = Base.Event()
entered = Base.Event()
try
    DO.configure_queue!(; workers=2)
    hold = t.gated(1; dir, fetch=identity)
    waitfor(joinpath(dir, "started_1_1")) || error("fit did not start")
    prior = t.square(5)
    @test prior.pid == DO.worker_status().processes[2].pid
    # Delay only the first connection's control stream. The second worker can still
    # answer, but its square(5) is stale until the invalidation reaches it.
    blocked = Threads.@spawn DO._on_actor(q.conns[1]) do
        notify(entered)
        wait(resume)
    end
    wait(entered)
    ip = t.square
    key = DO._memo_key((5,), (;))
    clear = Threads.@spawn invalidate!(ip, 5)
    settles(() -> !haskey(ip.cache, key)) || error("requester entry was not retracted")
    replacement = ip(5; fetch=identity)
    @test replacement isa Pending
    blocked_submit() = lock(() -> !isempty(DO._INVALIDATION_CHANGED.waitq), DO._INVALIDATION_CHANGED)
    @test settles(() -> isready(replacement) || blocked_submit())
    @test !isready(replacement)
    notify(resume)
    fetch(blocked)
    fetch(clear)
    value = fetch(replacement)
    @test value.pid == prior.pid && value.n == prior.n + 1
    @test ip(5) === value
    touch(joinpath(dir, "go_1"))
    fetch(hold)
finally
    notify(resume)
    touch(joinpath(dir, "go_1"))
    DO.configure_queue!(; workers=0)
end
end
