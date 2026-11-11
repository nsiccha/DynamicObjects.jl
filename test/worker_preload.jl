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
loaded() = lock(() -> id in q.conn.loaded && DO._worker_alive(q.conn.worker), q.conn.lock)
try
    DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[WorkerToy])
    # No computation has been submitted: package initialization is background startup work.
    settles(loaded, 120.0) || error("background startup did not preload WorkerToy")
    @test id in DO._remote_fetch(q.conn, q.conn.worker, DO._loaded_packages)
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
loaded(id) = lock(() -> id in q.conn.loaded, q.conn.lock)
try
    DO.configure_queue!(; workers=1, worker_start=:lazy, worker_preload=[extra])
    @test !DO.worker_status().running
    @test q.conn.spawning === nothing
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
    @test extra in DO._remote_fetch(q.conn, q.conn.worker, DO._loaded_packages)
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
    DO.configure_queue!(; workers=1, worker_start=:lazy, worker_preload=[missing])
    @test_logs (:error, r"preloading the worker process failed") begin
        task = DO._start_worker_soon!(q)
        settles(() -> istaskdone(task), 120.0) || error("failed preload did not settle")
        fetch(task)
    end
    @test !(missing in lock(() -> copy(q.conn.loaded), q.conn.lock))
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
