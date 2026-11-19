using TestItemRunner

@testitem "worker preloads: configuration selects packages and owns its list" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
q = DO.JobQueue()
packages = [WorkerToy]
DO.configure_queue!(q; worker_preload=packages)
empty!(packages)
@test q.worker_preload == [Base.PkgId(WorkerToy)]
DO.configure_queue!(q; worker_preload=[WorkerToy, WorkerToy.RequestContext, Base.PkgId(WorkerToy)])
@test q.worker_preload == [Base.PkgId(WorkerToy)]
DO.configure_queue!(q; max_running=2)
@test q.worker_preload == [Base.PkgId(WorkerToy)]
# The public list names loadable packages, not Main-defined modules or ambiguous names.
@test_throws ArgumentError DO.configure_queue!(q; max_running=3, worker_preload=[Main])
@test_throws ArgumentError DO.configure_queue!(q; worker_preload=["WorkerToy"])
@test_throws ArgumentError DO.configure_queue!(q; worker_preload=[Base.PkgId("WorkerToy")])
@test DO.queue_settings(q).max_running == 2
@test q.worker_preload == [Base.PkgId(WorkerToy)]
DO.configure_queue!(q; worker_preload=[])
@test isempty(q.worker_preload)
@test !DO.worker_status(q).running
end

@testitem "worker preloads: now loads the app before work and again after restart" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
const TB = DO.Treebars
q = DO.job_queue()
id = Base.PkgId(WorkerToy)
loaded() = lock(() -> id in q.conns[1].loaded && DO._worker_alive(q.conns[1].worker), q.conns[1].lock)
try
    DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[WorkerToy])
    # No computation has been submitted: package initialization is background startup work.
    settles(loaded, 120.0) || error("background startup did not preload WorkerToy")
    @test id in DO._remote_fetch(q.conns[1], q.conns[1].worker, DO._loaded_packages)
    @test DO.worker_status().in_flight == 0
    for attempt in 1:2
        t = Toy(3, mktempdir())
        node = TB.initialize_progress!(:state; description="first computation")
        value = DO.fetchindex!(node, t.square, 4)
        @test value.value == 48
        @test value.pid == DO.worker_status().pid != getpid()
        @test !occursin(r"Loading packages: [^\n]*WorkerToy", TB.render_text(node))
        attempt == 2 && break
        oldpid = DO.worker_status().pid
        DO.restart_worker!()
        settles(() -> loaded() && DO.worker_status().pid != oldpid, 120.0) ||
            error("replacement worker did not preload WorkerToy")
    end
finally
    DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
end
end

@testitem "worker preloads: lazy waits for work and now updates a running worker" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
q = DO.job_queue()
extra = Base.PkgId(Base.UUID("f6d9a3c2-1e0b-4c57-8a44-7d2e9b6c1f30"), "WorkerOnlyFault")
loaded(id) = lock(() -> id in q.conns[1].loaded, q.conns[1].lock)
try
    DO.configure_queue!(; workers=1, worker_start=:lazy, worker_preload=[extra])
    @test !DO.worker_status().running
    @test q.conns[1].spawning === nothing
    @test Toy(2, mktempdir()).square(3).value == 18
    @test loaded(extra)
    # A fresh worker has not loaded the extra package; an update preloads it without a job
    # or a restart, even when the worker was already running before :now was selected.
    DO.configure_queue!(; worker_preload=[])
    DO.restart_worker!()
    @test Toy(2, mktempdir()).square(3).value == 18
    @test !loaded(extra)
    pid = DO.worker_status().pid
    DO.configure_queue!(; worker_start=:now, worker_preload=[extra])
    settles(() -> loaded(extra), 120.0) || error("running worker did not preload the new list")
    @test DO.worker_status().pid == pid
    @test extra in DO._remote_fetch(q.conns[1], q.conns[1].worker, DO._loaded_packages)
    DO.configure_queue!(; worker_preload=[])
    @test loaded(extra)  # clearing configuration cannot unload an initialized package
finally
    DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
end
end

@testitem "worker preloads: an early computation waits visibly for background initialization" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
const DO = DynamicObjects
const TB = DO.Treebars
id = Base.PkgId(Base.UUID("6ff30dc2-6786-49b3-8560-52d617bc86d8"), "WorkerPreloadGate")
dir = mktempdir()
withenv("DO_WORKER_PRELOAD_GATE" => dir) do
    try
        DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[id])
        waitfor(joinpath(dir, "started")) || error("background package initializer did not start")
        @test !isfile(joinpath(dir, "finished"))
        t = Toy(2, mktempdir())
        p = t.square(3; fetch=identity)
        @test settles(() -> (node = getstatus(t.square, 3); node !== nothing &&
            occursin(r"Loading packages: [^\n]*WorkerPreloadGate", TB.render_text(node))))
        @test !isready(p)
        touch(joinpath(dir, "go"))
        settles(() -> isready(p), 120.0) || error("computation did not resume after package initialization")
        @test fetch(p).value == 18
        @test isfile(joinpath(dir, "finished"))
    finally
        touch(joinpath(dir, "go"))
        DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
    end
end
end

@testitem "worker preloads: failures are logged and fail the computation until corrected" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, Logging
const DO = DynamicObjects
q = DO.job_queue()
missing = Base.PkgId(Base.UUID("afc73367-81fa-47d7-aee3-02262ce07276"), "MissingWorkerPreload")
try
    failure = (:error, r"preloading the worker process failed")
    @test_logs failure failure failure failure (:warn, r"background worker retries exhausted") begin
        DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[missing])
        settles(() -> lock(() -> q.conns[1].eager === nothing, q.conns[1].lock), 120.0) ||
            error("preload retries did not stop")
    end
    @test !(missing in lock(() -> copy(q.conns[1].loaded), q.conns[1].lock))
    t = Toy(2, mktempdir())
    err = try
        t.square(3)
    catch e
        e
    end
    @test err isa PropertyComputationError
    @test occursin("MissingWorkerPreload", sprint(showerror, err))
    DO.configure_queue!(; worker_preload=[])
    @test t.square(3).value == 18
finally
    DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
end
end

@testitem "worker preloads: idle loss reloads once and a racing request joins the replacement" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
const DO = DynamicObjects
q = DO.job_queue()
id = Base.PkgId(Base.UUID("6ff30dc2-6786-49b3-8560-52d617bc86d8"), "WorkerPreloadGate")
dir = mktempdir()
gate = joinpath(dir, "go")
receipts = joinpath(dir, "initializers")
withenv("DO_WORKER_PRELOAD_GATE" => dir) do
    touch(gate)
    try
        DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[id])
        ready() = lock(() -> DO._worker_alive(q.conns[1].worker) && id in q.conns[1].loaded, q.conns[1].lock)
        settles(ready, 120.0) || error("initial worker did not preload")
        old = q.conns[1].worker
        rm(gate)
        kill(old.handle.proc, Base.SIGKILL)
        settles(() -> length(readlines(receipts)) == 2, 120.0) || error("idle recovery did not preload")
        newpid = DO.worker_status().pid
        @test parse.(Int, readlines(receipts)) == [old.handle.proc_pid, newpid]
        @test DO.worker_status().in_flight == 0
        t = Toy(3, mktempdir())
        p = t.square(2; fetch=identity)
        @test settles(() -> DO.worker_status().in_flight == 1)
        @test !isready(p)
        touch(gate)
        @test settles(() -> isready(p), 120.0) && fetch(p).pid == newpid

        p = t.gated(7; dir, fetch=identity)
        waitfor(joinpath(dir, "started_7_1")) || error("computation did not start")
        kill(q.conns[1].worker.handle.proc, Base.SIGKILL)
        settles(() -> DO._settled(p)) || error("lost computation did not settle")
        @test_throws ComputeAbandoned fetch(p)
        settles(() -> ready() && DO.worker_status().pid != newpid, 120.0) ||
            error("queue did not warm up after losing an in-flight computation")
        @test DO.worker_status().in_flight == 0
        @test length(readlines(receipts)) == 3
    finally
        touch(gate)
        DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
    end
end
end

@testitem "worker preloads: a lost pool member recovers beside a busy sibling and still retires when idle" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
q = DO.job_queue()
dir = mktempdir()
id = Base.PkgId(WorkerToy)
ready(conn) = lock(() -> DO._worker_alive(conn.worker) && id in conn.loaded, conn.lock)
try
    DO.configure_queue!(; workers=2, worker_start=:now, worker_preload=[WorkerToy], worker_idle_timeout=Inf)
    first, second = q.conns
    settles(() -> ready(first) && ready(second), 120.0) || error("pool did not preload")
    survivor = Toy(2, dir).gated(1; dir, fetch=identity)
    waitfor(joinpath(dir, "started_1_1")) || error("sibling request did not start")
    pids = [p.pid for p in DO.worker_status().processes]
    @test [p.in_flight for p in DO.worker_status().processes] == [1, 0]
    kill(second.worker.handle.proc, Base.SIGKILL)
    settles(() -> ready(second) && second.pid != pids[2], 120.0) || error("surplus slot did not recover")
    @test id in DO._remote_fetch(second, second.worker, DO._loaded_packages)
    @test DO.worker_status().processes[1].pid == pids[1]
    touch(joinpath(dir, "go_1"))
    @test fetch(survivor).pid == pids[1]
    monitor = second.eager
    DO.configure_queue!(; worker_idle_timeout=0.1)
    settles(() -> !DO.worker_status().processes[2].running && istaskdone(monitor)) ||
        error("intentional idle retirement did not stop recovery")
    cold = q.conns[2]
    DO.configure_queue!(; workers=2, worker_preload=[WorkerToy])
    @test cold !== second && cold.eager === nothing && cold.spawning === nothing
finally
    touch(joinpath(dir, "go_1"))
    DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[], worker_idle_timeout=300)
end
end

@testitem "worker preloads: disabling or switching to lazy cancels a queued eager launch" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
for settings in ((; workers=0), (; worker_start=:lazy))
    q = DO.JobQueue()
    DO.configure_queue!(q; workers=1)
    conn = only(q.conns)
    entered, release = Base.Event(), Base.Event()
    blocker = Threads.@spawn DO._on_actor(conn) do
        notify(entered)
        wait(release)
    end
    try
        wait(entered)
        DO.configure_queue!(q; workers=1, worker_start=:now, worker_preload=[WorkerToy])
        settles(() -> lock(() -> conn.spawning !== nothing, conn.lock)) || error("launch was never queued")
        supervisor, launch = lock(() -> (conn.eager, conn.spawning), conn.lock)
        DO.configure_queue!(q; settings...)
        notify(release)
        @test fetch(launch) === nothing
        wait(supervisor)
        @test conn.eager === nothing
        @test !DO.worker_status(q).running
    finally
        notify(release)
        wait(blocker)
        DO.configure_queue!(q; workers=0)
    end
end
end

@testitem "worker preloads: repeated short-lived processes stop background retries" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects, WorkerToy
const DO = DynamicObjects
q = DO.job_queue()
id = Base.PkgId(WorkerToy)
try
    DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[WorkerToy])
    supervisor = q.conns[1].eager
    pids = Set{Int}()
    for _ in 1:4
        ready() = lock(q.conns[1].lock) do
            DO._worker_alive(q.conns[1].worker) && q.conns[1].pid ∉ pids && id in q.conns[1].loaded
        end
        settles(ready, 120.0) || error("expected another preloaded worker")
        push!(pids, q.conns[1].pid)
        kill(q.conns[1].worker.handle.proc, Base.SIGKILL)
    end
    settles(() -> istaskdone(supervisor)) || error("rapidly exiting workers kept restarting")
    @test !istaskfailed(supervisor)
    @test !DO.worker_status().running
    # An ordinary request can recover after the automatic attempts are exhausted.
    @test Toy(3, mktempdir()).square(2).pid ∉ pids
    @test q.conns[1].eager isa Task && q.conns[1].eager !== supervisor
finally
    DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
end
end

@testitem "worker preloads: disabling an initializing worker stops its process" setup=[WorkerFixtures] tags=[:core, :workers] begin
using DynamicObjects
const DO = DynamicObjects
q = DO.JobQueue()
dir = mktempdir()
script, started, release = joinpath.(dir, ("boot.jl", "started", "release"))
write(script, """
    push!(Base.package_callbacks, function (id)
        id.name == "DynamicObjects" || return
        touch($(repr(started)))
        timedwait(() -> isfile($(repr(release))), 120.0)
    end)
    """)
try
    DO.configure_queue!(q; workers=1, worker_start=:now, worker_exeflags=["--threads=1,1", "-L", script])
    waitfor(started) || error("worker did not enter the startup gate")
    w = lock(() -> q.conns[1].starting_worker, q.conns[1].lock)
    @test w !== nothing && process_running(w.handle.proc)
    @test !DO.worker_status(q).running
    DO.configure_queue!(q; workers=0)
    @test process_exited(w.handle.proc)
    @test !DO.worker_status(q).running
finally
    touch(release)
    DO.configure_queue!(q; workers=0)
end
end
