using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2
const freed = Threads.Atomic{Int}(0)

mutable struct NativeBuffer
    handle::Ptr{UInt8}
    bytes::Int
end
function native_buffer(n)
    p = Libc.malloc(n)
    p == C_NULL && error("native allocation failed")
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), p, 17, n)
    finalizer(NativeBuffer(p, n)) do b
        Libc.free(b.handle)
        Threads.atomic_add!(freed, b.bytes)
    end
end

@dynamicstruct struct NativeCache
    n::Int
    sized(i) = native_buffer(n)
    unsized(i) = native_buffer(n)
    pinned = native_buffer(n)
    bad(i) = native_buffer(64)
    marker(k) = k
end
DO.memo_native_bytes(::Type{NativeCache}, ::Val{:sized}, b::NativeBuffer) = b.bytes
DO.memo_native_bytes(::Type{NativeCache}, ::Val{:unsized}, ::NativeBuffer) = missing
DO.memo_native_bytes(::Type{NativeCache}, ::Val{:bad}, ::NativeBuffer) = -1
has_slot(o, name) = any(e -> e.property === name, mem_cache_entries(o))

function check_native_lifetime()
    stats = memo_retention_stats()
    @test stats.heap_hint_bytes == 0
    @test stats.process_budget_bytes == 8 * 1024^3
    o = NativeCache(16 * MiB)
    pinned = o.pinned
    held = o.sized(1)
    o.sized(2)
    o.unsized(1)
    o.marker(1)
    @test has_slot(o, :sized) && has_slot(o, :unsized)
    GC.gc(true)
    old = memo_retention_stats()
    @test freed[] == 0
    # Exercise a normal hit with a measured footprint above the soft target.
    DO._PROCESS_BUDGET[] = old.process_memory_bytes - MiB
    DO._NEXT_PROCESS_CHECK[] = DO._NEXT_MEMO_CHECK[] = 0
    o.marker(1)
    stats = memo_retention_stats()
    @test !has_slot(o, :sized) && !has_slot(o, :unsized)
    @test stats.estimated_native_bytes - old.estimated_native_bytes == 32 * MiB
    @test stats.unknown_native_slots - old.unknown_native_slots == 1
    @test freed[] == 32 * MiB
    @test unsafe_load(held.handle) == 17
    @test o.pinned === pinned
    @test has_slot(o, :pinned)

    # All remaining native data has an external owner. A fruitless batch of
    # small ordinary results gets a cooldown, even on a large publication.
    DO._PROCESS_BUDGET[] = old.process_budget_bytes
    o.marker(2)
    o.marker(3)
    GC.gc(true)
    DO._PROCESS_BUDGET[] = 1
    DO._NEXT_PROCESS_CHECK[] = DO._NEXT_MEMO_CHECK[] = 0
    o.marker(3)
    deadline = DO._PROCESS_RETRY.retry_at
    @test deadline > time_ns() + 1_000_000_000
    before = memo_retention_stats().memory
    o.marker(4)
    DO._check_memo_pressure!(true)
    @test DO._PROCESS_RETRY.retry_at == deadline
    @test memo_retention_stats().memory == before
    @test o.pinned === pinned
    @info "Footprint after native finalizers" before=old.process_memory_bytes after=stats.process_memory_bytes freed_bytes=freed[]
    GC.@preserve held pinned nothing
end

function check_native_growth()
    # Cross a budget with real native growth, leaving the polling deadlines
    # alone. Calibrate against this process's baseline (including its JIT).
    warm = NativeCache(64)
    warm.sized(1)
    warm.marker(1)
    GC.gc(true)
    o = NativeCache(16 * MiB)
    before = memo_retention_stats()
    DO._PROCESS_BUDGET[] = cld(10 * (before.process_memory_bytes + 32 * MiB), 9)
    for i in 1:6
        o.sized(i)
    end
    @test timedwait(12; pollint=0.05) do
        o.marker(1)
        memo_retention_stats().estimated_native_bytes - before.estimated_native_bytes >= o.n
    end == :ok
    after = memo_retention_stats()
    @test after.live_heap_bytes < after.process_budget_bytes * 0.9
    @test freed[] >= o.n
    @info "Native growth triggered release" baseline=before.process_memory_bytes budget=after.process_budget_bytes live_heap=after.live_heap_bytes declared_bytes_released=(after.estimated_native_bytes - before.estimated_native_bytes)
end

if !isempty(ARGS)
    @assert only(ARGS) == "growth"
    check_native_growth()
    exit()
end

if Sys.islinux() || Sys.isapple()
    check_native_lifetime()
    GC.gc(true)
    @test freed[] == 64 * MiB
end

# An invalid declaration fails the computation and allows a retry.
o = NativeCache(64)
for _ in 1:2
    cause = try
        o.bad(1)
    catch err
        unwrap_error(err)
    end
    @test cause isa ArgumentError && occursin("memo_native_bytes", cause.msg)
end
@test !has_slot(o, :bad)
