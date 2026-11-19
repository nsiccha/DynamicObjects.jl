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
    @state first_task = Channel{Task}(1)
    @state release_first = Base.Event()
    slow(x) = begin
        n = _bump!((:slow, x))
        if n == 1
            put!(first_task, current_task())
            wait(release_first)
        end
        (x, n)
    end
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

@testitem "in-flight invalidation is not cancellation, and its value is not stored" setup=[PerEntryInvalidationFixtures] begin
using DynamicObjects

empty!(INV_CALLS)
for (key, force) in ((1, false), (2, true))
    o = InvApp(mktempdir())
    pending = fetchindex((value, _) -> value, o.slow, key)
    @test pending isa Pending
    first = take!(o.first_task)
    # Finish the replacement first, then let the superseded computation
    # finish and check that its older value cannot overwrite the newer one.
    replacement = Threads.@spawn begin
        if force
            fetchindex(o.slow, key; force=true) do value, status
                value isa Pending ? fetch(value) : value
            end
        else
            invalidate!(o.slow, key)
            fetch(pending)
        end
    end
    try
        @test timedwait(() -> istaskdone(replacement), 30) === :ok
    finally
        notify(o.release_first)
    end
    wait(first)
    @test fetch(replacement) == (key, 2)
    @test fetch(pending) == (key, 2)
    @test o.slow(key) == (key, 2)
    @test INV_CALLS[(:slow, key)] == 2
end
end
