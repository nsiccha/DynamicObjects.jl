using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

# A result owning malloc memory that its finalizer frees.
mutable struct Block
    ptr::Ptr{UInt8}
    bytes::Int
end
function block(bytes)
    p = Libc.malloc(bytes)
    p == C_NULL && error("native allocation failed")
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), p, 1, bytes)
    finalizer(b -> Libc.free(b.ptr), Block(p, bytes))
end
DO.memo_native_bytes(b::Block) = b.bytes

@dynamicstruct struct Blocks
    buf(i) = block(16MiB)
    marker(k) = k
end

@testset "a footprint batch reads the pages its release freed" begin
    if DO._MALLOC_TRIM[] == C_NULL
        @test !(Sys.islinux() && Base.Libc.Libdl.dlopen_e("libc.so.6") != C_NULL)
    else
        # Serve the blocks from glibc's main arena (below 32 MiB), where a
        # freed block under a live one stays resident until malloc_trim.
        @test ccall(:mallopt, Cint, (Cint, Cint), -3 #= M_MMAP_THRESHOLD =#, 32MiB) == 1
        o = Blocks()
        for i in 1:20
            o.buf(i)
        end
        o.marker(1)
        # Julia trims after a full collection only when the peak resident
        # set grew by a quarter since its last trim. Spend that trim here.
        GC.gc(true)
        before = DO._process_memory_bytes()
        # The 80% target lies 160 MiB below the footprint: ten blocks.
        DO._PROCESS_BUDGET[] = cld(5 * (before - 160MiB), 4)
        DO._NEXT_PROCESS_CHECK[] = DO._NEXT_MEMO_CHECK[] = 0
        o.marker(1)
        stats = memo_retention_stats()
        @test stats.estimated_native_bytes >= 160MiB
        @test stats.process_memory_bytes < before - 128MiB
        @test DO._PROCESS_RETRY.delay_ns == 0
        @info "Footprint after a released batch" before after=stats.process_memory_bytes released_bytes=stats.estimated_native_bytes
    end
end
