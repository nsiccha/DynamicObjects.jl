using TestItemRunner

@testmodule PerEntryInvalidationFixtures begin
using DynamicObjects
export InvApp, INV_CALLS

const INV_CALLS = Dict{Any,Int}()
_bump!(k) = (INV_CALLS[k] = get(INV_CALLS, k, 0) + 1)

@dynamicstruct struct InvApp
    __cache_path__::String
    plain(x; scale=1) = (_bump!((:plain, x, scale)); x * scale * 10)
    @cached saved(x) = (_bump!((:saved, x)); x + 100)
    slow(x) = (sleep(3.0); n = _bump!((:slow, x)); (x, n))
end
end

@testitem "invalidate! drops one entry; next access recomputes and re-caches" setup=[PerEntryInvalidationFixtures] begin
using DynamicObjects

empty!(INV_CALLS)
o = InvApp(mktempdir())
@test o.plain(3) == 30
@test o.plain(3) == 30
@test INV_CALLS[(:plain, 3, 1)] == 1
@test o.plain(4) == 40

@test invalidate!(o.plain, 3) === nothing
@test o.plain(3) == 30
@test INV_CALLS[(:plain, 3, 1)] == 2
@test o.plain(3) == 30
@test INV_CALLS[(:plain, 3, 1)] == 2
@test INV_CALLS[(:plain, 4, 1)] == 1

# kwargs are part of the key: same args, other kwargs untouched.
@test o.plain(3; scale=2) == 60
@test INV_CALLS[(:plain, 3, 2)] == 1
invalidate!(o.plain, 3; scale=2)
@test o.plain(3; scale=2) == 60
@test INV_CALLS[(:plain, 3, 2)] == 2
@test INV_CALLS[(:plain, 3, 1)] == 2

# The macro form shares the primitive, including splats (the route shape).
# NOTE: the cleared key must match the call's kwargs exactly as passed —
# `o.plain(4)` (no kwargs) and `o.plain(4; scale=1)` are distinct entries.
args = (3,); kw = (; scale=2)
@clear_cache! o.plain(args...; kw...)
@test o.plain(3; scale=2) == 60
@test INV_CALLS[(:plain, 3, 2)] == 3
end

@testitem "invalidate! drops the disk entry for @cached" setup=[PerEntryInvalidationFixtures] begin
using DynamicObjects

empty!(INV_CALLS)
o = InvApp(mktempdir())
@test o.saved(7) == 107
@test o.saved(8) == 108
@test (@is_cached o.saved(7))
@test (@is_cached o.saved(8))

invalidate!(o.saved, 7)
@test (@cache_status o.saved(7)) == :unstarted
@test (@is_cached o.saved(8))
@test o.saved(7) == 107
@test INV_CALLS[(:saved, 7)] == 2
@test (@is_cached o.saved(7))
end

@testitem "invalidate!-then-call matches force=true transitions" setup=[PerEntryInvalidationFixtures] begin
using DynamicObjects

empty!(INV_CALLS)
o = InvApp(mktempdir())
@test o.plain(5) == 50
@test INV_CALLS[(:plain, 5, 1)] == 1

# The poller path: force recomputes and re-caches exactly once.
forced = fetchindex(o.plain, 5; force=true) do rv, status
    rv isa Pending ? fetch(rv) : rv
end
@test forced == 50
@test INV_CALLS[(:plain, 5, 1)] == 2
@test o.plain(5) == 50
@test INV_CALLS[(:plain, 5, 1)] == 2

# The plain-route shape: identical transitions.
invalidate!(o.plain, 5)
@test o.plain(5) == 50
@test INV_CALLS[(:plain, 5, 1)] == 3
@test o.plain(5) == 50
@test INV_CALLS[(:plain, 5, 1)] == 3
end

@testitem "in-flight invalidation is not cancellation" setup=[PerEntryInvalidationFixtures] begin
using DynamicObjects

empty!(INV_CALLS)
o = InvApp(mktempdir())
started(key) = begin
    for _ in 1:200
        DynamicObjects.n_running(o.slow.cache) >= 1 && return true
        sleep(0.05)
    end
    false
end

# Mid-flight clear: the compute is not stopped; its value lands and is served.
t = Threads.@spawn fetchindex(o.slow, 1) do rv, status
    rv
end
@test started(1)
pend = Base.fetch(t)
@test pend isa Pending
invalidate!(o.slow, 1)
# The old handle fetched in the gap errors: latch dropped, nothing registered.
gap_err = try
    fetch(pend)
    nothing
catch e
    e
end
@test gap_err isa ErrorException
@test occursin("no compute in flight", gap_err.msg)
sleep(3.5)
@test INV_CALLS[(:slow, 1)] == 1
@test o.slow(1) == (1, 1)
@test INV_CALLS[(:slow, 1)] == 1

# force=true mid-flight spawns a second compute; both run, one value wins.
t2 = Threads.@spawn fetchindex(o.slow, 2) do rv, status
    rv
end
@test started(2)
pend2 = Base.fetch(t2)
@test pend2 isa Pending
forced2 = fetchindex(o.slow, 2; force=true) do rv, status
    rv isa Pending ? fetch(rv) : rv
end
@test forced2 isa Tuple
sleep(3.5)
@test INV_CALLS[(:slow, 2)] == 2
@test o.slow(2) == forced2
@test INV_CALLS[(:slow, 2)] == 2
end
