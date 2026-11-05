using TestItemRunner

# The worker process behind `@queued` (`configure_queue!(; workers=1)`). The toy application
# is a real package, `test/fixtures/workers/WorkerToy`, because the worker loads the package
# that defines the root object's type. Its values carry the computing process's id and a
# per-process computation count; gates are files, which both processes see.
#
# Every item switches the worker off again in `finally`: other files' `@queued` types live in
# test modules, which a worker cannot load.
@testmodule WorkerFixtures begin
const FIXTURES = joinpath(@__DIR__, "fixtures", "workers")
FIXTURES in LOAD_PATH || push!(LOAD_PATH, FIXTURES)
using DynamicObjects
using WorkerToy
export Toy, settled_count, reset_settled!, with_worker, waitfor, worker_pid, settles

settles(f, seconds=60.0) = timedwait(f, seconds; pollint=0.02) === :ok
waitfor(path, seconds=120.0) = settles(() -> isfile(path), seconds)
worker_pid() = DynamicObjects.worker_status().pid

function with_worker(f)
    DynamicObjects.configure_queue!(; workers=1)
    try
        f()
    finally
        DynamicObjects.configure_queue!(; workers=0)
    end
end
end

@testitem "workers: @queued values come back from the worker, memory and disk tier" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    root = mktempdir()
    t = Toy(2, root)
    reset_settled!()

    # Memory tier: computed in the worker, serialized back, stored here, settled once.
    r = t.square(3)
    @test r.value == 18
    @test r.pid == worker_pid() != getpid()
    # `property_settled` runs after waiters are released, so a caller can return first.
    @test settles(() -> settled_count(:square) == 1)
    @test t.square(3) === r                     # a hit: no new computation, no new settlement
    sleep(0.2)
    @test settled_count(:square) == 1
    @test DynamicObjects.worker_status().in_flight == 0

    # Disk tier: the worker publishes the entry; this process loads it from disk.
    c = t.cube(2)
    @test c.value == 16 && c.pid == worker_pid()
    @test isfile(DynamicObjects.get_cache_path(t, :cube, 2))
    @test settles(() -> settled_count(:cube) == 1)
    # A content-equal object reads the same entry; the worker serves it from its warm memo.
    @test Toy(2, root).cube(2) == c

    # An inline child is addressed by its memoized step from the root.
    @test t.child(3).scaled(2) == (pid=worker_pid(), value=12)
    # A DO object a worker computation returns is this process's object at that address.
    kid = Threads.@spawn t.kid(3)
    settles(() -> istaskdone(kid), 30.0) || error("worker child result did not settle")
    @test fetch(kid) === t.child(3)
    # A fresh call goes to the worker too, every time.
    f1, f2 = t.fresh_item(4), t.fresh_item(4)
    @test f1.pid == f2.pid == worker_pid()
    @test f2.n == f1.n + 1
    # A remount view travels with its context.
    @test remount(t; __prefix__="/a").prefixed(1) == (pid=worker_pid(), value="/a1")
    @test remount(t; __prefix__="/b").prefixed(1) == (pid=worker_pid(), value="/b1")

    # A failure in the worker arrives as this property's PropertyComputationError.
    err = try
        t.doomed(1); nothing
    catch e
        e
    end
    @test err isa PropertyComputationError && err.property == :doomed
    @test unwrap_error(err) isa DynamicObjects.RemoteComputationError
    @test occursin("doomed 1", sprint(showerror, err))
    @test DynamicObjects.queue_settings().workers == 1
end
@test DynamicObjects.worker_status() == (; workers=0, running=false, pid=nothing,
    started_at=nothing, in_flight=0, last_message_at=nothing)
end

@testitem "workers: same-key callers share one worker computation" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    dir = mktempdir()
    t = Toy(1, mktempdir())
    tasks = [Threads.@spawn t.gated(5; dir) for _ in 1:4]
    @test waitfor(joinpath(dir, "started_5_1"))
    @test DynamicObjects.worker_status().in_flight == 1
    touch(joinpath(dir, "go_5"))
    results = fetch.(tasks)
    @test all(==(results[1]), results)
    @test results[1].n == 1 && results[1].pid == worker_pid()
    @test !isfile(joinpath(dir, "started_5_2"))
end
end

@testitem "workers: an invalidation during a worker computation publishes nothing" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    dir = mktempdir()
    t = Toy(1, mktempdir())
    reset_settled!()
    p = t.gated(1; dir, fetch=identity)
    @test p isa Pending
    @test waitfor(joinpath(dir, "started_1_1"))
    # The clear retracts this process's computation and, forwarded, the worker's: the
    # worker's first computation stores nothing there either, so the re-resolved access
    # computes again instead of joining it.
    DynamicObjects.clear_cache!(t, :gated)
    touch(joinpath(dir, "go_1"))
    v = fetch(p)
    @test v.n == 2
    @test isfile(joinpath(dir, "started_1_2"))
    @test t.gated(1; dir) === v
    @test settles(() -> settled_count(:gated) == 1)
    sleep(0.2)
    @test settled_count(:gated) == 1

    # The same for one entry of a disk-tier property: both processes drop it, and the
    # recomputed value is published again.
    first_cube = t.cube(3)
    path = DynamicObjects.get_cache_path(t, :cube, 3)
    @test isfile(path)
    invalidate!(t.cube, 3)
    @test !isfile(path)
    second_cube = t.cube(3)
    @test second_cube.n == first_cube.n + 1
    @test isfile(path)

    # Retract an in-flight disk write. Hold the replacement so that an old writer
    # publishing after invalidation cannot be hidden by a new successful write.
    p = t.gated_disk(9; dir, fetch=identity)
    @test waitfor(joinpath(dir, "disk_started_9_1"))
    path = DynamicObjects.get_cache_path(t, :gated_disk, 9; dir)
    invalidate!(t.gated_disk, 9; dir)
    replacement = Threads.@spawn fetch(p)
    touch(joinpath(dir, "disk_go_9_1"))
    @test waitfor(joinpath(dir, "disk_started_9_2"))
    @test settles(() -> DynamicObjects.worker_status().in_flight == 1)
    @test !isfile(path)
    touch(joinpath(dir, "disk_go_9_2"))
    @test fetch(replacement).n == 2
    @test isfile(path)
    @test settles(() -> settled_count(:gated_disk) == 1)
end
end

@testitem "workers: a dead worker fails its computations with ComputeAbandoned; the next call starts a fresh one" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    dir = mktempdir()
    t = Toy(3, mktempdir())
    p = t.gated(7; dir, fetch=identity)
    @test waitfor(joinpath(dir, "started_7_1"))
    pid = worker_pid()
    run(`kill -9 $pid`)
    err = try
        fetch(p); nothing
    catch e
        e
    end
    @test err isa ComputeAbandoned && err.started
    @test occursin("exited", sprint(showerror, err))
    r = t.square(2)
    @test r.value == 12
    @test r.pid == worker_pid() != pid

    # `restart_worker!` stops the worker through its process handle, with the same outcome.
    p = t.gated(8; dir, fetch=identity)
    @test waitfor(joinpath(dir, "started_8_1"))
    old = worker_pid()
    stopped = @elapsed status = DynamicObjects.restart_worker!()
    @test status.running == false
    @test stopped < 15
    @test (try fetch(p); false catch e; e isa ComputeAbandoned end)
    @test settles(() -> DynamicObjects.worker_status().in_flight == 0)
    touch(joinpath(dir, "go_8"))
    @test t.gated(8; dir).pid != old
end
end

@testitem "workers: requester messages, forwarded logs and interrupts" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, Logging
import DynamicObjects.Treebars
with_worker() do
    t = Toy(1, mktempdir())
    received = []
    DynamicObjects.on_requester_message!(:toy) do payload
        push!(received, payload)
    end
    # Messages and log records arrive in order, before the value, under the requester's logger.
    @test_logs (:info, "toy log") match_mode=:any begin
        @test t.talks(5) == 5
    end
    @test received == [(5, worker_pid()), (6, worker_pid())]

    # In one process the send reaches the handler at once.
    empty!(received)
    DynamicObjects.send_to_requester(:toy, :local)
    @test received == [:local]

    # An interrupt requested on this process's node reaches the worker's.
    dir = mktempdir()
    p = t.stoppable(1; dir, fetch=identity)
    @test waitfor(joinpath(dir, "stoppable_1"))
    node = getstatus(t.stoppable, 1; dir)
    @test node isa Treebars.ProgressNode
    Treebars.request_interrupt!(node)
    @test fetch(p) == (pid=worker_pid(), value=:interrupted)
end
end

@testitem "workers: request-reading bodies stay local; types outside a package are refused" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
@dynamicstruct struct NotInAPackage
    @queued twice(x::Int) = 2x
end
@test_throws ArgumentError DynamicObjects.configure_queue!(; workers=2)
@test_throws ArgumentError DynamicObjects.configure_queue!(; worker_start=:later)
with_worker() do
    t = Toy(1, mktempdir())
    r = @test_logs (:warn, r"reads the request") t.reads_request(1)
    @test r.pid == getpid()
    @test t.reads_request(2).pid == getpid()          # warned once per property
    err = try
        NotInAPackage().twice(1); nothing
    catch e
        e
    end
    @test err isa PropertyComputationError
    @test unwrap_error(err) isa ArgumentError
    @test occursin("cannot send `twice` to the worker process", sprint(showerror, err))
end
# Without a worker the same property computes here, as before.
@test NotInAPackage().twice(1) == 2
end

@testitem "workers: the worker's progress tree shows under the requester's node" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
using WorkerToy
import DynamicObjects.Treebars
with_worker() do
    t = Toy(4, mktempdir())
    dir = mktempdir()
    for n in (12, 14)   # the first run includes the mirror's first-use compilation
        p = t.counted(n; dir, fetch=identity)
        @test waitfor(joinpath(dir, "half_$n"))
        node = getstatus(t.counted, n; dir)
        # The replica rebuilds the worker's tree live under this process's node.
        @test settles(() -> occursin("Steps ($(n ÷ 2)/$n)", Treebars.render_text(node)), 30.0)
        touch(joinpath(dir, "go_$n"))
        @test fetch(p) == n
        text = Treebars.render_text(node)
        @test occursin("✓ Counted item", text)
        @test occursin("✓ Steps ($n/$n)", text)
        conn = DynamicObjects.job_queue().conn
        source_duration = DynamicObjects._remote_fetch(conn, conn.worker,
            WorkerToy.counted_duration, DynamicObjects._address(t), n, dir)
        @test Treebars.duration(node) == source_duration
    end
end
end
