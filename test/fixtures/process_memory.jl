# Standalone so the same probe can run in a fresh native macOS or Linux
# process without installing the package or disturbing an application.
using Test
include(joinpath(@__DIR__, "..", "..", "src", "process_memory.jl"))

function probe()
    bytes = 64 * 1024^2
    _process_memory_bytes()  # warm the sampler
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
    @show getpid() before during after
    @test during - before > bytes ÷ 2
    @test during - after > bytes ÷ 2
end

if Sys.isapple() || Sys.islinux()
    probe()
else
    @test _process_memory_bytes() === nothing
end
