# Cold-process liveness fixture, run at one default thread (the parent passes
# `--threads=1`). Each settle hands a re-read of its key to a separate
# same-thread task, which runs after the refresh unit has finished, so at
# `ttl=0` the cache keeps rebuilding the key for as long as the loop runs.
# That loop wastes builds, but it must never starve the thread: the main
# task's timer sleeps have to return while the loop is live.
module BackgroundCacheLiveness
using DynamicObjects

Threads.nthreads() == 1 || error("run this fixture with --threads=1, got ", Threads.nthreads())

function quiesce(c, builds; timeout=60.0)
    t0 = time()
    while true
        idle = lock(() -> isempty(c.refreshing), c.lock)
        seen = builds[]
        sleep(0.05)
        idle && lock(() -> isempty(c.refreshing), c.lock) && builds[] == seen && return nothing
        time() - t0 > timeout && error("the feedback loop did not stop")
    end
end

function check(mode)
    println("mode=", mode, " start"); flush(stdout)
    stop = Threads.Atomic{Bool}(false)
    builds = Threads.Atomic{Int}(0)
    holder = Ref{Any}()
    on_settle = (k, old, new) -> (stop[] || @async(holder[][k]); nothing)
    c = if mode === :batch
        BackgroundCache{String,Int}(ks -> (Threads.atomic_add!(builds, length(ks)); Dict(k => 1 for k in ks));
                                    batch=8, ttl=0, unbuilt=0, on_settle)
    else
        BackgroundCache{String,Int}(k -> (Threads.atomic_add!(builds, 1); 1); ttl=0, unbuilt=0, on_settle)
    end
    holder[] = c
    c["x"]
    # Warm-up: every iteration is itself a timer sleep that only returns if
    # the loop yields, so a regression hangs here (the parent's timeout fails
    # it). Waiting for a warmed, demonstrably live loop keeps first-call
    # compilation (slow under CI's coverage instrumentation) out of the
    # measured window below.
    t0 = time()
    while builds[] < 100
        sleep(0.05)
        time() - t0 > 60 && error("feedback loop never got going: ", builds[], " builds in 60 s")
    end
    b1 = builds[]
    t1 = time()
    sleep(0.3)
    slept = time() - t1
    b2 = builds[]
    stop[] = true
    quiesce(c, builds)
    # Positive control: the loop kept building across the measured sleep, so
    # the sleep returned despite it rather than because it had died out.
    b2 > b1 || error("feedback loop not live during the measured sleep: builds ", b1, " -> ", b2)
    println("mode=", mode, " slept=", round(slept; digits=2), "s builds=", b1, "->", b2); flush(stdout)
end

check(:single)
check(:batch)
println("BACKGROUND-CACHE-LIVENESS-OK")
end
