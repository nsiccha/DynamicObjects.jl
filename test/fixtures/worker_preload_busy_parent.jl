# One parent thread. It cannot service its port reader or timers during this
# interval. An initializer receipt identifies the worker even before the
# parent's first opportunity to process the handshake.
using DynamicObjects
const DO = DynamicObjects
push!(LOAD_PATH, joinpath(pkgdir(DO), "test", "fixtures", "workers"))
using WorkerToy
id = Base.PkgId(Base.UUID("6ff30dc2-6786-49b3-8560-52d617bc86d8"), "WorkerPreloadGate")
mktempdir() do dir
    withenv("DO_WORKER_PRELOAD_GATE" => dir, "JULIA_WORKER_TIMEOUT" => "3") do
        gate = joinpath(dir, "release")
        script = joinpath(dir, "boot.jl")
        write(script, "timedwait(() -> isfile($(repr(gate))), 60)")
        try
            DO.configure_queue!(; workers=1, worker_start=:now, worker_preload=[id],
                                worker_exeflags=["--threads=1,1", "-L", script])
            touch(gate)
            # Keep the sole thread out of Julia's scheduler until both
            # the port deadline and the application initializer have passed.
            deadline = time() + 90
            function observe(marker)
                while !isfile(joinpath(dir, marker))
                    time() < deadline || error("worker did not reach $marker independently")
                    ccall(:uv_sleep, Cvoid, (Cuint,), 25)
                end
            end
            observe("started")
            ccall(:uv_sleep, Cvoid, (Cuint,), 4500)
            touch(joinpath(dir, "go"))
            observe("finished")
            pid = parse(Int, only(readlines(joinpath(dir, "initializers"))))
            value = Toy(2, mktempdir()).square(3)
            @assert value.value == 18 && value.pid == pid == DO.worker_status().pid
            @assert readlines(joinpath(dir, "initializers")) == [string(pid)]
            println("first queued result ", value.value, " on original worker ", pid)
        finally
            touch(joinpath(dir, "go"))
            touch(gate)
            DO.configure_queue!(; workers=0, worker_start=:lazy, worker_preload=[])
        end
    end
end
