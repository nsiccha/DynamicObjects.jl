# A process holding a DynamicObjects worker, for `test/workers.jl`: it starts the worker,
# prints the worker's pid and `ready`, and waits to be signalled.
push!(LOAD_PATH, joinpath(@__DIR__, "workers"))
using DynamicObjects, WorkerToy
DynamicObjects.configure_queue!(; workers=1)
Toy(2, mktempdir()).square(3)
println("worker pid ", DynamicObjects.worker_status().pid)
println("ready")
flush(stdout)
wait()
