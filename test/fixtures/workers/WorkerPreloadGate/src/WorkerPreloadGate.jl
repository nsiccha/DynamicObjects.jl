module WorkerPreloadGate
function __init__()
    dir = ENV["DO_WORKER_PRELOAD_GATE"]
    touch(joinpath(dir, "started"))
    timedwait(() -> isfile(joinpath(dir, "go")), 120.0; pollint=0.02) === :ok ||
        error("WorkerPreloadGate initializer was not released")
    touch(joinpath(dir, "finished"))
end
end
