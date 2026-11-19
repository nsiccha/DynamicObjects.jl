# A process holding a DynamicObjects worker, for `test/workers.jl`: it starts the worker,
# prints the worker's pid and `ready`, and waits to be signalled unless an
# output path is supplied for the normal-exit check.
push!(LOAD_PATH, joinpath(@__DIR__, "workers"))
using DynamicObjects, WorkerToy
if !isempty(ARGS)
    # This hook runs after the worker kill hook. Yield long enough for its
    # event pump and supervisor to handle the death while the parent is alive.
    atexit() do
        q = DynamicObjects.job_queue()
        supervisor = only(q.conns).eager
        stopped = timedwait(() -> istaskdone(supervisor), 10.0)
        write(only(ARGS), string(stopped, " ", DynamicObjects.worker_status().running))
    end
end
DynamicObjects.configure_queue!(; workers=1, worker_start=:now, worker_preload=[WorkerToy])
Toy(2, mktempdir()).square(3)
println("worker pid ", DynamicObjects.worker_status().pid)
println("ready")
flush(stdout)
isempty(ARGS) && wait()
