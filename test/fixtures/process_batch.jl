using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

# Footprint readings are scripted: one before a batch, one after its collection.
# An indexed read checks pressure twice (the property, then its entry); when
# the first check outlasts the sampling interval, the second finds no reading.
const readings = Union{Int,Nothing}[]
@eval DO _process_memory_bytes() = isempty(Main.readings) ? nothing : popfirst!(Main.readings)
# The scripts stand for a footprint that follows releases, as it does where
# glibc returns freed pages; nothing real is freed to return here.
@eval DO _footprint_follows_releases() = true
@eval DO _return_free_memory!() = nothing

# A rebuildable native result whose size its producer does not know.
mutable struct Opaque end
DO.memo_native_bytes(::Opaque) = missing

@dynamicstruct struct BatchStore
    item(i) = zeros(UInt8, MiB)
    handle(i) = Opaque()
end

function check!(hit, samples...)
    append!(readings, samples)
    DO._NEXT_MEMO_CHECK[] = DO._NEXT_PROCESS_CHECK[] = 0
    hit()
    @test isempty(readings)
    DO._NEXT_PROCESS_CHECK[] = typemax(UInt64)
end
releases() = DO._MEMO_EVICTED[].memory

@testset "a footprint batch covers the excess when the cold cache can" begin
    @test DO._PROCESS_BATCH[] == 1024
    DO._PROCESS_BUDGET[] = 100MiB  # pressure starts at 90, target is 80
    DO._NEXT_PROCESS_CHECK[] = typemax(UInt64)

    # Results without an estimate stop a batch after 16, also in a batch the
    # cold results' estimates (99 MiB) could size to the 30 MiB excess.
    let store = BatchStore()
        for i in 1:40
            store.handle(i)
        end
        for i in 1:100
            store.item(i)
        end
        check!(() -> store.item(100), 110MiB, 79MiB)
        @test releases() == 16
        @test DO._MEMO_EVICTED[].unknown_native_slots == 16
        clear_mem_caches!(store)  # leave no colder results for the cases below
    end
    GC.gc(true)  # the next publications sweep those results' tickets

    store = BatchStore()
    for i in 1:100
        store.item(i)
    end
    hit() = store.item(100)

    # 60 MiB over the target: the 60 coldest one-MiB results, then one collection.
    before = releases()
    check!(hit, 140MiB, 79MiB)
    @test releases() - before == 60
    @test DO._PROCESS_RETRY.delay_ns == 0

    # 500 MiB over, beyond the 39 MiB the cold results hold, as for memory the
    # cache does not own: the batch stays at 16 and the backoff protects the rest.
    before = releases()
    check!(hit, 580MiB, 79MiB)
    @test releases() - before == 16

    # A sized batch never releases more than _PROCESS_BATCH[] results.
    DO._PROCESS_BATCH[] = 20
    for i in 101:200
        store.item(i)
    end
    before = releases()
    check!(hit, 130MiB, 79MiB)
    @test releases() - before == 20
    DO._PROCESS_BATCH[] = 1024
end

# Where the reading after a collection is not known to show what a release
# freed, a coverable excess keeps the 16-result batch.
@eval DO _footprint_follows_releases() = false
@testset "no sized batch where the footprint does not follow releases" begin
    store = BatchStore()
    for i in 1:100
        store.item(i)
    end
    before = releases()
    check!(() -> store.item(100), 140MiB, 79MiB)
    @test releases() - before == 16
    DO._PROCESS_BUDGET[] = 0
end
