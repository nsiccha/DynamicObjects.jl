using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

# Script Julia's collection counters and its live-heap estimate. Every heap
# sample reads the estimate once, and every collection DynamicObjects runs to
# measure the heap reads it again. Scripted counters ignore real collections.
const counts = Ref((1000, 0))
const estimates = Int[]
const footprints = Union{Int,Nothing}[]
@eval DO _gc_counts() = Main.counts[]
@eval DO _collected_heap_bytes() = popfirst!(Main.estimates)
@eval DO _process_memory_bytes() = popfirst!(Main.footprints)

@dynamicstruct struct HeapStore
    item(i) = zeros(UInt8, 1024)
end

young!() = (counts[] = counts[] .+ (1, 0))
full!() = (counts[] = counts[] .+ (1, 1))
measured() = DO._FULL_COLLECTIONS[]
releases() = DO._MEMO_EVICTED[].memory
function check!(hit, samples...; process=())
    append!(estimates, samples)
    append!(footprints, process)
    DO._NEXT_MEMO_CHECK[] = 0
    DO._NEXT_PROCESS_CHECK[] = isempty(process) ? typemax(UInt64) : 0
    hit()
    @test isempty(estimates)
    @test isempty(footprints)
    DO._NEXT_MEMO_CHECK[] = typemax(UInt64)
end

@testset "heap releases follow measured live data" begin
    DO._PROCESS_BUDGET[] = 0
    DO._HEAP_HINT[] = 100MiB  # pressure starts at 90, target is 80
    DO._NEXT_MEMO_CHECK[] = typemax(UInt64)
    store = HeapStore()
    item = store.item
    for i in 1:256
        item(i)
    end
    hit() = item(256)

    # A reading over the trigger that a full collection shows to be garbage
    # releases nothing, and the same reading without a collection since is
    # not measured again.
    check!(hit, 300MiB, 50MiB)
    @test measured() == 1 && releases() == 0
    check!(hit, 300MiB)
    @test measured() == 1 && releases() == 0

    # After a measurement in the 80-90% band, Julia's estimate must exceed it
    # by a tenth of the hint before the next full collection.
    young!(); check!(hit, 300MiB, 85MiB)
    @test measured() == 2 && releases() == 0
    young!(); check!(hit, 92MiB)
    @test measured() == 2
    young!(); check!(hit, 96MiB, 85MiB)
    @test measured() == 3 && releases() == 0

    # When every collection since the last look was full, Julia's estimate is
    # the measurement: no extra collection. One measurement decides one batch.
    full!(); check!(hit, 150MiB)
    @test measured() == 3 && releases() == 16
    check!(hit, 150MiB)
    @test releases() == 16

    # A batch that released results is measured after the next collection
    # without waiting for growth.
    young!(); check!(hit, 140MiB, 120MiB)
    @test measured() == 4 && releases() == 32

    # A measurement whose batch finds nothing eligible waits for growth.
    DO._trim_memos!(typemax(Int); batch=1000)
    before = releases()
    young!(); check!(hit, 140MiB, 120MiB)
    @test measured() == 5 && releases() == before
    young!(); check!(hit, 125MiB)
    @test measured() == 5
    young!(); check!(hit, 131MiB, 120MiB)
    @test measured() == 6 && releases() == before

    # The collection after a footprint-driven batch also measures the heap;
    # the next heap sample decides on it without collecting again.
    for i in 257:300
        item(i)
    end
    hit2() = item(300)
    DO._PROCESS_BUDGET[] = 100MiB
    before = releases()
    check!(hit2, 125MiB, 95MiB; process=(300MiB, 250MiB))
    @test measured() == 7 && releases() == before + 16
    check!(hit2, 125MiB)
    @test measured() == 7 && releases() > before + 16

    push!(footprints, nothing)  # the statistics read the footprint once
    @test memo_retention_stats().full_collections == measured()
    DO._HEAP_HINT[] = 0
    DO._PROCESS_BUDGET[] = 0
end
