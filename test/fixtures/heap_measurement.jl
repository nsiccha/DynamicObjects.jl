using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

# A sample reads Julia's collected heap. A measuring collection supplies a
# second reading. Allocations since collection can trigger that measurement.
const counts = Ref((1000, 0))
const allocated = Ref(0)
const estimates = Int[]
const footprints = Union{Int,Nothing}[]
@eval DO _gc_activity() = (Main.counts[], Main.allocated[])
@eval DO _collected_heap_bytes() = popfirst!(Main.estimates)
@eval DO _process_memory_bytes() = popfirst!(Main.footprints)

mutable struct HeapResult
    data::Vector{UInt8}
    lock::ReentrantLock
end
DO.memo_native_bytes(::HeapResult) = 100MiB # external bytes cannot size a heap batch
@dynamicstruct struct HeapStore
    item(i) = HeapResult(zeros(UInt8, 1024), ReentrantLock())
end

young!() = (counts[] = counts[] .+ (1, 0))
full!() = (counts[] = counts[] .+ (1, 1))
measured() = DO._FULL_COLLECTIONS[]
releases() = DO._MEMO_EVICTED[].memory
function check!(hit, samples...; growth=0, due=false, publication=false, process=())
    append!(estimates, samples)
    append!(footprints, process)
    allocated[] = growth
    if DO._HEAP_MEASURE.check_after != 0
        DO._HEAP_MEASURE.check_after = due ? UInt64(1) : typemax(UInt64)
    end
    DO._NEXT_MEMO_CHECK[] = publication ? typemax(UInt64) : 0
    DO._NEXT_PROCESS_CHECK[] = isempty(process) ? typemax(UInt64) : 0
    hit()
    @test isempty(estimates)
    @test isempty(footprints)
    DO._NEXT_MEMO_CHECK[] = typemax(UInt64)
end

@testset "heap releases follow measured live data" begin
    DO._PROCESS_BUDGET[] = 0
    DO._HEAP_HINT[] = 100MiB  # pressure starts at 90, target is 80
    # Populate without taking scripted measurements during the setup.
    DO._TRIMMING_MEMOS[] = true
    store = HeapStore()
    item = store.item
    for i in 1:2048
        item(i)
    end
    DO._TRIMMING_MEMOS[] = false
    hit() = item(2048)

    # A burst before Julia's next collection proves to be mostly garbage.
    check!(hit, 35MiB, 50MiB; growth=60MiB)
    @test measured() == 1 && releases() == 0
    check!(hit, 50MiB)
    @test measured() == 1

    # A young collection still counts dead old objects. A full one confirms
    # pressure, preserving the tenth-of-hint step after a below-trigger read.
    young!(); check!(hit, 300MiB, 85MiB)
    @test measured() == 2 && releases() == 0
    young!(); check!(hit, 92MiB)
    @test measured() == 2
    young!(); check!(hit, 96MiB, 85MiB)
    @test measured() == 3 && releases() == 0

    # One full measurement starts one probe. The post-release measurement
    # is available for the next due hit even if Julia collects nothing else.
    full!(); check!(hit, 150MiB, 146MiB)
    @test measured() == 4 && releases() == 16
    check!(hit, 146MiB)
    @test measured() == 4 && releases() == 16
    check!(hit, 146MiB, 92MiB; due=true)
    @test measured() == 5 && releases() == 80  # growth capped at 4 × 16

    # The 64 releases freed 54 MiB. Cover the remaining 12 MiB in 15 slots.
    # Mixed collections since that measurement require a new baseline.
    young!(); full!(); check!(hit, 110MiB, 92MiB, 92MiB; due=true)
    @test measured() == 7 && releases() == 95
    @test DO._HEAP_MEASURE.delay_ns == 5_000_000_000

    # Full sweeps also observe the cooldown. A due retry starts small.
    full!(); check!(hit, 94MiB)
    @test measured() == 7 && releases() == 95
    check!(hit, 94MiB, 94MiB; due=true)
    @test measured() == 8 && releases() == 111
    @test DO._HEAP_MEASURE.delay_ns == 10_000_000_000

    # Either growth or new publications alone leave the wait in place.
    check!(hit, 94MiB; growth=30MiB)
    @test measured() == 8 && releases() == 111
    check!(() -> item(2049), 94MiB; publication=true)
    @test measured() == 8 && releases() == 111
    # New garbage cannot rearm a costly probe. Growth kept by a quick
    # collection plus the new eligible result can, without waiting for time.
    check!(hit, 94MiB; growth=30MiB)
    @test measured() == 8 && releases() == 111
    young!(); check!(hit, 124MiB, 120MiB, 110MiB)
    @test measured() == 10 && releases() == 127
    @test DO._HEAP_MEASURE.delay_ns == 0

    # A below-trigger measurement ends the episode. A footprint collection
    # supplies the next heap baseline even during a footprint cooldown.
    full!(); check!(hit, 70MiB)
    @test releases() == 127 && DO._HEAP_MEASURE.batch == 16
    DO._PROCESS_BUDGET[] = 100MiB
    check!(hit, 70MiB, 120MiB; process=(300MiB, 300MiB))
    before = releases()
    @test DO._PROCESS_RETRY.delay_ns > 0
    n = measured()
    check!(hit, 120MiB, 105MiB; process=(300MiB,))
    @test measured() == n + 1 && releases() == before + 16
    @test DO._PROCESS_RETRY.delay_ns > 0

    # No eligible result: a later hit cannot force a collection on every poll.
    DO._PROCESS_BUDGET[] = 0
    DO._trim_memos!(typemax(Int); batch=3000)
    before = releases()
    full!(); check!(hit, 105MiB; due=true)
    @test releases() == before && DO._HEAP_MEASURE.delay_ns > 0
    check!(hit, 130MiB)
    @test releases() == before && measured() == n + 1
    push!(footprints, nothing)
    @test memo_retention_stats().full_collections == measured()
    DO._HEAP_HINT[] = 0
end
