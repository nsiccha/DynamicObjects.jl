using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

# Drive real cache hits, publications, and collections in an isolated process.
# Each release that forces a collection consumes a second footprint reading.
const readings = Union{Int,Nothing}[]
@eval DO _process_memory_bytes() = popfirst!(Main.readings)

@dynamicstruct struct RetryStore
    item(i, bytes) = zeros(UInt8, bytes)
end

function check!(hit, samples...; due=false)
    append!(readings, samples)
    due && (DO._PROCESS_RETRY.retry_at = 0)
    DO._NEXT_MEMO_CHECK[] = DO._NEXT_PROCESS_CHECK[] = 0
    hit()
    @test isempty(readings)
    DO._NEXT_PROCESS_CHECK[] = typemax(UInt64)
end

@testset "process-pressure retry on ordinary reads and publications" begin
    DO._PROCESS_BUDGET[] = 100MiB  # pressure starts at 90, target is 80
    DO._NEXT_PROCESS_CHECK[] = typemax(UInt64)
    store = RetryStore()
    item = store.item
    for i in 1:256
        item(i, 64)
    end
    hit() = item(256, 64)
    retry = DO._PROCESS_RETRY
    releases() = DO._MEMO_EVICTED[].memory

    # 9 MiB is less than 5% of the 220 MiB gap.
    check!(hit, 300MiB, 291MiB)
    @test releases() == 16
    @test retry.delay_ns == 5_000_000_000
    check!(hit, 350MiB)
    check!(hit, nothing)
    @test releases() == 16
    @test retry.delay_ns == 5_000_000_000

    # Every collection appears to free 59 MiB, but its settled footprint
    # is always 291 MiB. Expire the timer without sleeping for five minutes.
    for seconds in (10, 20, 40, 80, 160, 300, 300)
        started = time_ns()
        check!(hit, 350MiB, 291MiB; due=true)
        @test retry.delay_ns == seconds * 1_000_000_000
        @test retry.retry_at >= started + retry.delay_ns
    end

    # A genuine reduction restores the fast cadence. Missing evidence on
    # a subsequent collection costs a retry, and retains the last baseline.
    check!(hit, 350MiB, 250MiB; due=true)
    @test retry.delay_ns == 0
    check!(hit, 350MiB, nothing)
    @test retry.delay_ns == 5_000_000_000
    check!(hit, 350MiB, 250MiB; due=true)
    @test retry.delay_ns == 10_000_000_000

    # Concurrent publications together cover 5% of the remaining 170 MiB
    # gap. A publication alone does not show the retry succeeded.
    before = releases()
    @sync for i in 257:261
        Threads.@spawn item(i, MiB)
    end
    check!(hit, 250MiB)
    @test releases() == before
    @sync for i in 262:266
        Threads.@spawn item(i, MiB)
    end
    check!(hit, 250MiB, 250MiB)
    @test releases() == before + 16
    @test retry.delay_ns == 20_000_000_000

    # Real heap pressure can release a batch during the process cooldown,
    # decided on its own measuring collection, without a footprint sample
    # or a change to the retry schedule.
    DO._HEAP_HINT[] = 1
    check!(hit, 250MiB)
    @test releases() > before + 16
    @test retry.delay_ns == 20_000_000_000
    DO._HEAP_HINT[] = 0

    # Cheap samples notice a fresh pressure episode during the cooldown.
    check!(hit, 89MiB)
    @test retry.delay_ns == 0
    check!(hit, 250MiB, 89MiB)
    @test retry.last_excess == retry.delay_ns == 0
    DO._PROCESS_BUDGET[] = 0
    check!(hit)
end
