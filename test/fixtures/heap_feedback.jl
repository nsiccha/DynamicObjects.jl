using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

mutable struct BufferResult
    data::Vector{UInt8}
    lock::ReentrantLock
end
DO.memo_native_bytes(::BufferResult) = missing
@dynamicstruct struct BufferStore
    item(i) = BufferResult(fill(UInt8(mod(i, 251)), 128 * 1024), ReentrantLock())
end

@testset "warm cache hits reclaim opaque Julia results after a burst" begin
    DO._PROCESS_BUDGET[] = 0
    DO._HEAP_HINT[] = 16 * 1024MiB
    store = BufferStore()
    item = store.item
    foreach(item, 1:512)
    hot = item(512)
    GC.gc(true)
    live = DO._collected_heap_bytes()
    # Relative to this process's warmed runtime, require 16 MiB of relief.
    # Even a complete first probe can reclaim only 2 MiB of these buffers.
    trigger = live - 16MiB
    DO._HEAP_HINT[] = fld(10 * trigger, 9)
    before = memo_retention_stats()
    @test timedwait(20; pollint=0.07) do
        item(512)
        DO._collected_heap_bytes() < trigger
    end == :ok
    @test item(512) === hot
    after = memo_retention_stats()
    @test after.memory - before.memory > 16
    @test after.estimated_native_bytes == before.estimated_native_bytes
    @test after.estimated_payload_bytes == before.estimated_payload_bytes
    @test after.unknown_native_slots > before.unknown_native_slots
end

@testset "a skipped collection supplies no heap measurement" begin
    before = DO._FULL_COLLECTIONS[]
    enabled = GC.enable(false)
    try
        @test DO._measure_heap!() === nothing
        @test DO._HEAP_MEASURE.pending === nothing
        @test DO._FULL_COLLECTIONS[] == before
    finally
        GC.enable(enabled)
    end
end
