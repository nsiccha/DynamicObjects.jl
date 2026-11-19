# Standalone so the same probe can run in a fresh native macOS or Linux
# process without installing the package or disturbing an application.
using Test, Mmap
include(joinpath(@__DIR__, "..", "..", "src", "process_memory.jl"))

@noinline function sample_with_mapping(bytes)
    pages = Mmap.mmap(Vector{UInt8}, bytes; shared=false)
    fill!(pages, 37)
    GC.@preserve pages _process_memory_bytes()
end

function probe()
    bytes = 64 * 1024^2
    sample_with_mapping(4096)  # compile the mapping and sampler before measuring
    GC.gc(true)
    before = _process_memory_bytes()
    p = Libc.malloc(bytes)
    p == C_NULL && error("Could not allocate $bytes bytes")
    during = try
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), p, 37, bytes)
        _process_memory_bytes()
    finally
        Libc.free(p)
    end
    after = _process_memory_bytes()
    @info "Native allocator" pid=getpid() before during after
    @test during - before > bytes ÷ 2

    # free may keep pages in the allocator. The private mapping is unmapped
    # by Mmap's finalizer when its last reference goes out of scope.
    GC.gc(true)
    before = _process_memory_bytes()
    during = sample_with_mapping(bytes)
    GC.gc(true)
    after = _process_memory_bytes()
    @info "Private mapping" pid=getpid() before during after
    @test during - before > bytes ÷ 2
    @test during - after > bytes ÷ 2
end

if Sys.isapple() || Sys.islinux()
    probe()
else
    @test _process_memory_bytes() === nothing
end
