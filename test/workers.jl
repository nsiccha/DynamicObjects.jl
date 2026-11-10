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
    @test unwrap_error(err) isa ErrorException && unwrap_error(err).msg == "doomed 1"
    @test occursin("doomed 1", sprint(showerror, err))
    @test DynamicObjects.queue_settings().workers == 1
end
@test DynamicObjects.worker_status() == (; workers=0, running=false, pid=nothing,
    started_at=nothing, in_flight=0, last_message_at=nothing)
end

@testitem "workers: container identities agree for disk, mmap, children and versions" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, Serialization
using WorkerToy: HashCompiled, HashToy, HashVersioned
const DO = DynamicObjects
data = Dict{String,Any}("k$i" => i for i in 1:30)
sizehint!(data, 1000)
data["matrix"] = reshape(collect(1.0:6.0), 2, 3)'
data["nested"] = Any[(values=Set([:a, :b]),), :pair => Dict(:x => 1, :y => 2)]
io = IOBuffer(); serialize(io, data); seekstart(io)
rebuilt = deserialize(io)
@test isequal(data, rebuilt)

with_worker() do
    dir = mktempdir()
    o = HashToy(HashCompiled("model", data), dir)
    peer = HashToy(HashCompiled("model", rebuilt), dir)
    @test o.__hash__ == peer.__hash__
    status = DO.Treebars.initialize_progress!(:state; description="Hash requester")
    result = DO.fetchindex!(status, o.saved, 2)
    @test result.pid == worker_pid() != getpid()
    @test result.value == 2 + length(data)
    @test result.hash == o.__hash__
    @test result.compiled_hash == o.compiled.__hash__
    @test isfile(DO.get_cache_path(o, :saved, 2))
    @test peer.saved(2) == result

    mapped = o.mapped(2)
    @test mapped == fill(Float64(result.value), 4)
    @test isfile(DO.get_cache_path(o, :mapped, 2))
    @test peer.mapped(2) == mapped
    child_result = o.child(3).saved(4)
    @test child_result == (pid=worker_pid(), value=7 + length(data))
    @test peer.child(3).saved(4) == child_result
    view_result = remount(o; __prefix__="/view").saved(3)
    @test view_result.pid == worker_pid() && view_result.hash == o.__hash__

    # Invalidation addresses the same worker object even after the Dict travelled.
    invalidate!(o.saved, 2)
    again = o.saved(2)
    @test again.n > result.n && again.value == result.value
    @test again.hash == o.__hash__ && again.pid == worker_pid()

    a, b = HashVersioned(data, dir, "v1"), HashVersioned(rebuilt, dir, "v2")
    @test a.__identity_hash__ == b.__identity_hash__
    @test a.__cache_path__ != b.__cache_path__
    @test a.saved(2) == (pid=worker_pid(), revision="v1", value=2 + length(data))
    @test b.saved(2) == (pid=worker_pid(), revision="v2", value=2 + length(data))
    @test HashVersioned(rebuilt, dir, "v1").saved(2) == a.saved(2)
end
end

@testitem "workers: roots that share __hash__ keep their own construction inputs" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
using WorkerToy: HashCompiled, HashToy, HashVersionedOwn
const DO = DynamicObjects
with_worker() do
    root = mktempdir()
    # Request context is not identity: these fresh roots share `__hash__`, so the worker
    # used to compute both on the root it built first (snag `fresh-root-worke-beeaa921`).
    a, b = Toy(2, root; __prefix__="/a"), Toy(2, root; __prefix__="/b")
    @test a.__hash__ == b.__hash__
    @test a.prefixed(1) == (pid=worker_pid(), value="/a1")
    @test b.prefixed(1) == (pid=worker_pid(), value="/b1")
    # A content-equal root with the same context finds the worker's warm root; a root
    # with other context computes on its own, as a fresh root does in this process.
    first = a.square(5)
    @test first.pid == worker_pid()
    @test Toy(2, root; __prefix__="/a").square(5) == first
    @test b.square(5).n == first.n + 1
    # A DO object a worker computation returns is this process's object at that address.
    kid = Threads.@spawn b.kid(3)
    settles(() -> istaskdone(kid), 30.0) || error("worker child result did not settle")
    @test fetch(kid) === b.child(3)

    # Cache placement is not identity either: each root publishes under its own base.
    dir_a, dir_b = mktempdir(), mktempdir()
    c1, c2 = Toy(3, root; __cache_base__=dir_a), Toy(3, root; __cache_base__=dir_b)
    @test c1.__hash__ == c2.__hash__
    @test c1.cube(2).value == c2.cube(2).value == 24
    @test startswith(DO.get_cache_path(c2, :cube, 2), dir_b)
    @test isfile(DO.get_cache_path(c1, :cube, 2)) && isfile(DO.get_cache_path(c2, :cube, 2))

    # A declared identity may leave out a fixed field, here the one that places the cache.
    compiled = HashCompiled("model", Dict("k" => 1))
    h1, h2 = HashToy(compiled, dir_a), HashToy(compiled, dir_b)
    @test h1.__hash__ == h2.__hash__
    @test h1.saved(2).value == h2.saved(2).value == 3
    @test isfile(DO.get_cache_path(h1, :saved, 2)) && isfile(DO.get_cache_path(h2, :saved, 2))

    # The same for a version a declared identity leaves out (todo `12fnna6`), and an
    # invalidation reaches the root of its own version.
    data = Dict("k" => 1)
    v1, v2 = HashVersionedOwn(data, dir_a, "v1"), HashVersionedOwn(data, dir_a, "v2")
    @test v1.__hash__ == v2.__hash__ && v1.__cache_path__ != v2.__cache_path__
    @test v1.saved(2) == (pid=worker_pid(), revision="v1", value=3)
    @test v2.saved(2) == (pid=worker_pid(), revision="v2", value=3)
    path = DO.get_cache_path(v2, :saved, 2)
    @test isfile(path)
    invalidate!(v2.saved, 2)
    @test !isfile(path)
    @test v2.saved(2).revision == "v2"
    @test isfile(path)
end
end

@testitem "workers: a constructor __hash__ names one directory in both processes" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
using WorkerToy: HashVersioned, HashVersionedOwn
const DO = DynamicObjects
with_worker() do
    dir = mktempdir()
    data = Dict("k" => 1)
    # A versioned type with a declared identity, then with the default one. Without the
    # keyword reaching the worker, it would publish elsewhere and the requester's read of
    # the entry would fail: `the two processes do not agree on the cache location`.
    for make in ((; kw...) -> HashVersionedOwn(data, dir, "v1"; kw...),
                 (; kw...) -> HashVersioned(data, dir, "v1"; kw...))
        earlier = make(; __hash__ = "earlier-identity")
        @test earlier.__cache_path__ == joinpath(dir, "earlier-identity", earlier.__version_tag__)
        @test earlier.saved(2) == (pid=worker_pid(), revision="v1", value=3)
        path = DO.get_cache_path(earlier, :saved, 2)
        @test startswith(path, earlier.__cache_path__) && isfile(path)
        @test !isfile(DO.get_cache_path(make(), :saved, 2))
        invalidate!(earlier.saved, 2)
        @test !isfile(path)
    end
end
end

@testitem "workers: the worker keeps a bounded number of request-context objects" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
const DO = DynamicObjects
with_worker() do
    root, dir = mktempdir(), mktempdir()
    plain = Toy(2, root)
    warm = plain.square(3)
    conn = DO.job_queue().conn
    kept() = DO._remote_fetch(conn, conn.worker, DO._worker_kept_objects)

    # A computation in flight keeps its context-bearing root, however many others pass.
    held = Threads.@spawn Toy(2, root; __prefix__="/held").gated(1; dir)
    @test waitfor(joinpath(dir, "started_1_1"))
    for i in 1:(DO._WORKER_KEEP + 6)
        o = isodd(i) ? Toy(2, root; __prefix__="/p$i") : remount(plain; __prefix__="/p$i")
        @test o.prefixed(i).value == "/p$i$i"
    end
    @test kept().context == DO._WORKER_KEEP
    joined = Threads.@spawn Toy(2, root; __prefix__="/held").gated(1; dir)
    @test settles(() -> DO.worker_status().in_flight == 2)
    touch(joinpath(dir, "go_1"))
    @test fetch(joined) == fetch(held)
    @test !isfile(joinpath(dir, "started_1_2"))

    # An evicted context computes again on a root built anew; a root built from its
    # identity alone is never evicted, so its memo stays warm.
    @test Toy(2, root; __prefix__="/p1").prefixed(1).value == "/p11"
    @test Toy(2, root).square(3) == warm
    @test kept().context <= DO._WORKER_KEEP
    @test kept().pinned == 0
end
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
using DynamicObjects, WorkerToy
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
    # The old remote request may re-resolve its Pending and join the replacement,
    # so both requests can stay in flight. Wait for the old computing task itself:
    # its publication fence has run, while the replacement remains gated.
    conn = DynamicObjects.job_queue().conn
    @test settles(() -> DynamicObjects._remote_fetch(conn, conn.worker,
        WorkerToy.disk_task_finished, 1))
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
    run(Sys.iswindows() ? `taskkill /F /PID $pid` : `kill -9 $pid`)
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

@testitem "workers: a replaced worker's computations log to their requesters" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, Logging
# The records of the gated talking item that reached `logger`, as `x => worker pid`.
talked(logger) = [Dict(r.kwargs)[:x] => Dict(r.kwargs)[:worker] for r in logger.logs
                  if r.message == "gated toy log"]
kill_worker(pid) = run(Sys.iswindows() ? `taskkill /F /PID $pid` : `kill -9 $pid`)
with_worker() do
    t = Toy(1, mktempdir())
    dir = mktempdir()
    received = []
    DynamicObjects.on_requester_message!(p -> push!(received, p), :toy)
    @test t.square(1).pid == worker_pid()
    if !Sys.iswindows()
        # Hold the worker, so the next request waits in its send, and kill it there. The
        # request never reached it, so it goes to a fresh worker and logs to its requester
        # from there. Its requester used to get `ComputeAbandoned` while the fresh worker
        # computed it for nobody, so a retry joined that computation and received none of
        # its records (snag `worker-log-recor-d660d227`).
        held = worker_pid()
        run(`kill -STOP $held`)
        logger = TestLogger()
        task = Threads.@spawn with_logger(() -> t.gated_talks(1; dir), logger)
        @test settles(() -> DynamicObjects.worker_status().in_flight == 1)
        run(`kill -KILL $held`)
        @test settles(() -> something(worker_pid(), held) != held, 120.0)
        fresh = worker_pid()
        @test waitfor(joinpath(dir, "talking_1_$fresh"))
        touch(joinpath(dir, "talk_go_1"))
        @test fetch(task) == 1
        @test talked(logger) == [1 => fresh]
        @test received == [(1, fresh)]
        @test DynamicObjects.worker_status().in_flight == 0
    end

    # A worker killed while it computes fails that computation, after its records arrived.
    # The retry computes on a fresh worker, and its records reach the retry's logger.
    empty!(received)
    old = worker_pid()
    first_logger, retry_logger = TestLogger(), TestLogger()
    task = Threads.@spawn with_logger(() -> t.gated_talks(2; dir), first_logger)
    @test waitfor(joinpath(dir, "talking_2_$old"))
    @test settles(() -> length(received) == 1)
    @test talked(first_logger) == [2 => old]
    kill_worker(old)
    err = try
        fetch(task); nothing
    catch e
        unwrap_error(e)
    end
    @test err isa ComputeAbandoned && err.started
    touch(joinpath(dir, "talk_go_2"))
    @test with_logger(() -> t.gated_talks(2; dir), retry_logger) == 2
    new = worker_pid()
    @test new != old
    @test talked(retry_logger) == [2 => new]
    @test received == [(2, old), (2, new)]
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
    r = @test_logs (:warn, r"reads the request") match_mode=:any t.reads_request(1)
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

@testitem "workers: a worker's exception reads as it does in one process" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
using WorkerToy: ToyFault
failure(f) = try
    f()
    error("expected a failure")
catch e
    e
end
# Wherever the computation throws, a layer above sees its own exception, with its fields.
faults(t) = map((
    () -> t.refused(1),                     # the body of a memoized computation
    () -> t.fresh_refused(2),               # the body of a fresh one
    () -> t.reads_refusal(3),               # a property the body reads
    () -> t.reads_refused(4),               # a `@queued` property the body reads
    () -> t.unmarked_refused(5),            # read by an unmarked property in this process
    () -> fetch(t.refused(6; fetch=identity)),  # polled
)) do read
    inner = unwrap_error(failure(read))
    inner isa ToyFault ? (inner.status, inner.message) : inner
end
expected = ((401, "refused 1"), (402, "fresh refused 2"), (422, "refused by a property"),
    (404, "refused 4"), (405, "refused 5"), (406, "refused 6"))
@test faults(Toy(1, mktempdir())) == expected
with_worker() do
    t = Toy(1, mktempdir())
    @test t.square(1).pid == worker_pid() != getpid()   # the worker path is taken
    @test faults(t) == expected

    # The worker's printout and backtrace stay what the error prints.
    err = failure(() -> t.refused(7))
    @test err isa PropertyComputationError && err.property == :refused
    cause = DynamicObjects._cause_error(err)
    @test cause isa DynamicObjects.RemoteComputationError && cause.pid == worker_pid()
    @test cause.exception === unwrap_error(err)
    text = sprint(showerror, err)
    @test occursin("in worker process $(worker_pid())", text)
    @test occursin("refused 7", text)
    @test occursin("Stacktrace:", text)
    # A failed computation is retried and fails the same way.
    @test unwrap_error(failure(() -> t.refused(7))) isa ToyFault

    # Base's exception types cross too. A rebuilt `MethodError` prints as it does in one
    # process: the world it records is another process's count, so it is not kept.
    inner = unwrap_error(failure(() -> t.wrong_method(1)))
    @test inner isa MethodError
    @test occursin("takes_string", sprint(showerror, inner))
    @test !occursin("too new", sprint(showerror, inner))
    @test unwrap_error(failure(() -> t.wrong_closure(1))) isa MethodError
    # Anything thrown crosses, not only an `Exception`.
    @test unwrap_error(failure(() -> t.throws_string(1))) == "a thrown string"
end
end

@testitem "workers: what cannot cross stays the worker's printout, which says why" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
using WorkerToy: BulkyFault
failure(f) = try
    f()
    error("expected a failure")
catch e
    e
end
with_worker() do
    t = Toy(1, mktempdir())
    limit = DynamicObjects._MAX_CARRIED_BYTES
    under = unwrap_error(failure(() -> t.bulky(limit ÷ 2)))
    @test under isa BulkyFault && length(under.payload) == limit ÷ 2

    only_the_worker = Base.PkgId(Base.UUID("f6d9a3c2-1e0b-4c57-8a44-7d2e9b6c1f30"), "WorkerOnlyFault")
    @test !haskey(Base.loaded_modules, only_the_worker)
    for (read, printed, why) in (
        (() -> t.bulky(2limit), "BulkyFault", "serializes to more than 1 MiB"),
        (() -> t.holds_self(1), "MethodError", "holds a DynamicObjects object"),
        (() -> t.holds_task(1), "HoldsTask", "cannot serialize a running Task"),
        (() -> t.worker_only(1), "only the worker knows 1", "WorkerOnlyFault"),
    )
        err = failure(read)
        @test err isa PropertyComputationError
        inner = unwrap_error(err)
        @test inner isa DynamicObjects.RemoteComputationError
        @test inner.exception === nothing && inner.pid == worker_pid()
        @test occursin(printed, inner.message)
        @test occursin("Stacktrace:", inner.message)
        @test occursin("did not reach the requesting process: ", inner.message)
        @test occursin(why, inner.message)
        # The requester does not hold the payload, as an exception or as its printout.
        @test sizeof(inner.message) < limit ÷ 2
    end
    # Reading the failure did not load the package here.
    @test !haskey(Base.loaded_modules, only_the_worker)
end
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
            WorkerToy.counted_duration, n)
        @test Treebars.duration(node) == source_duration
    end

    # A fresh, progress-threaded call has no cache cell, but its replica still
    # keeps the worker's end time. Delay the requester to expose re-finalization.
    DynamicObjects.on_requester_message!(_ -> sleep(0.15), :counted_end)
    parent = Treebars.prepare_progress!(t.__status__; description="Fresh requester")
    task = Threads.@spawn maybeprogress!(parent, t.counted, 16; dir)
    @test waitfor(joinpath(dir, "half_16"))
    @test settles(() -> occursin("Steps (8/16)", Treebars.render_text(parent)), 30.0)
    node = only(parent.children) # a successful fresh call removes its transient node
    touch(joinpath(dir, "go_16"))
    settles(() -> istaskdone(task), 30.0) || error("fresh worker result did not settle")
    @test fetch(task) == 16
    conn = DynamicObjects.job_queue().conn
    source_duration = DynamicObjects._remote_fetch(conn, conn.worker, WorkerToy.counted_duration, 16)
    @test Treebars.duration(node) == source_duration
    DynamicObjects.on_requester_message!(identity, :counted_end)
end
end

# Snag `open-bruno-s-web-e7aa5ae2`: a computation that has to wait for the worker process to
# start, or for it to load packages, used to show nothing on its node until the worker ran it
# (web-sim's first view: 296 s). The two waits are phases of the node, kept once done, in the
# page's language.
@testitem "workers: starting the worker and loading packages are phases of the computation" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
using WorkerToy
import DynamicObjects.Treebars
# The phases DO wrote on `node`, as a page in `lang` writes them.
waits(node, lang) = [Treebars._note_text(c.impl.message, Treebars.treebar_texts(lang))
                     for c in collect(node.children)
                     if isempty(c.impl.description) && c.impl.message isa Treebars.TreebarNote]
lines(node) = split(Treebars.render_text(node), '\n')
with_worker() do
    t = Toy(5, mktempdir())
    dir = mktempdir()
    # The first computation starts the worker: its node says so while it waits.
    p = t.counted(10; dir, fetch=identity)
    node() = getstatus(t.counted, 10; dir)
    @test settles(() -> (n = node(); n !== nothing &&
        occursin("▶ — Starting the worker process", Treebars.render_text(n))))
    @test waitfor(joinpath(dir, "half_10"))
    touch(joinpath(dir, "go_10"))
    @test fetch(p) == 10
    # Both waits stay, finished, ahead of the worker's own phases. The worker also loads the
    # package of every registered requester scope (HTMXObjects', when a test loaded it).
    l = lines(node())
    @test startswith(l[2], "├─ ✓ — Starting the worker process [")
    @test occursin(r"^├─ ✓ — Loading packages: (.*, )?WorkerToy(, .*)? \[", l[3])
    @test startswith(l[4], "└─ ✓ Steps (10/10)")
    en, de = waits(node(), :en), waits(node(), :de)
    @test length(en) == length(de) == 2
    @test en[1] == "Starting the worker process"
    @test de[1] == "Rechenprozess wird gestartet"
    @test occursin(r"^Loading packages: .*WorkerToy", en[2])
    @test occursin(r"^Pakete werden geladen: .*WorkerToy", de[2])

    # The worker runs and has the package: nothing to wait on, so no phase.
    touch(joinpath(dir, "go_12"))
    @test t.counted(12; dir) == 12
    @test isempty(waits(getstatus(t.counted, 12; dir), :en))
    # What the worker loaded as a dependency (Treebars, under DynamicObjects) is known to be
    # loaded: naming it neither asks the worker nor shows a phase.
    conn = DynamicObjects.job_queue().conn
    probe = Treebars.initialize_progress!(:state; description="probe")
    DynamicObjects._ensure_packages!(conn, conn.worker,
        [Base.PkgId(Treebars), Base.PkgId(DynamicObjects), Base.PkgId(WorkerToy)], probe)
    @test isempty(probe.children)

    # A restarted worker starts again and loads the package again.
    DynamicObjects.restart_worker!()
    touch(joinpath(dir, "go_14"))
    @test t.counted(14; dir) == 14
    en = waits(getstatus(t.counted, 14; dir), :en)
    @test length(en) == 2 && en[1] == "Starting the worker process"
    @test occursin("WorkerToy", en[2])
end
end
