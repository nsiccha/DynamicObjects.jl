using TestItemRunner

@testitem "DOMM stream writes preserve standalone bytes and caller inputs" tags=[:core] begin
using DynamicObjects

for input in ([1.0 2.0; 3.0 4.0], Float32[1, 2], Int16[-3, 4],
              ComplexF64[1 + 2im], Bool[true, false], fill(7.0), Float64[])
    original = copy(input)
    path = tempname()
    DynamicObjects.save(Val(:mmap), path, input)
    buffer = IOBuffer()
    @test DynamicObjects.save(Val(:mmap), buffer, input) === input
    @test isopen(buffer)
    @test take!(buffer) == read(path)
    @test DynamicObjects.load(Val(:mmap), path, typeof(input)) == original
    @test input == original
end

@test_throws ErrorException DynamicObjects.save(Val(:mmap), IOBuffer(), ["unsupported"])
@test_throws ErrorException DynamicObjects.save(Val(:mmap), IOBuffer(), reshape([1], ntuple(_ -> 1, 33)))
end

@testitem "embedded DOMM blocks map within their bounds and survive stream closure" tags=[:core] begin
using DynamicObjects

path = tempname()
inputs = (Float32[1 2; 3 4], fill(Int16(5)), Float64[])
originals = map(copy, inputs)
blocks = open(path, "w") do io
    write(io, "tree-envelope") # deliberately unaligned numeric header
    spans = map(inputs) do input
        start = position(io)
        DynamicObjects.save(Val(:mmap), io, input)
        (start, position(io))
    end
    write(io, "footer")
    spans
end

mapped = open(path, "r") do io
    @test read(io, 13) == collect(codeunits("tree-envelope"))
    arrays = map(blocks, inputs) do (start, stop), input
        seek(io, start)
        value = DynamicObjects.load(Val(:mmap), io, typeof(input); end_offset=stop)
        @test position(io) == stop
        @test isopen(io)
        value
    end
    @test String(read(io)) == "footer"
    arrays
end
@test mapped == originals
@test inputs == originals

open(path, "r") do io
    start, stop = first(blocks)
    seek(io, start)
    @test DynamicObjects.load(Val(:mmap), io; end_offset=stop) == first(originals)
    seek(io, start)
    @test_throws ErrorException DynamicObjects.load(Val(:mmap), io, Matrix{Float64}; end_offset=stop)
    seek(io, start)
    @test_throws ErrorException DynamicObjects.load(Val(:mmap), io, Vector{Float32}; end_offset=stop)
    seek(io, start)
    @test_throws ErrorException DynamicObjects.load(Val(:mmap), io; end_offset=stop - 1)
    seek(io, start)
    @test_throws ArgumentError DynamicObjects.load(Val(:mmap), io; end_offset=filesize(io) + 1)
end
open(path, "r+") do io
    seek(io, first(blocks)[1])
    @test_throws ArgumentError DynamicObjects.load(Val(:mmap), io)
end

# Windows does not permit replacing a file with a live mapping. Unix must keep
# the old inode's published bytes stable while the new entry becomes visible.
if Sys.iswindows()
    @test_skip "atomic replacement of a live mmap requires Unix file semantics"
else
    standalone = tempname()
    DynamicObjects.save(Val(:mmap), standalone, first(inputs))
    old = DynamicObjects.load(Val(:mmap), standalone)
    replacement = Float32[11 12; 13 14]
    DynamicObjects._atomic_save(Val(:mmap), standalone, replacement)
    @test old == first(originals)
    @test DynamicObjects.load(Val(:mmap), standalone) == replacement
    @test first(inputs) == first(originals)
end
end

@testitem "DOMM stream loaders reject truncated and overflowing payloads before mapping" tags=[:core] begin
using DynamicObjects

for extent in (Int64(100), Int64(typemax(Int)))
    path = tempname()
    open(path, "w") do io
        write(io, codeunits("DOMM"), UInt8(2), UInt8(4), UInt8(1), extent)
        write(io, UInt8(0)) # aligned header, deliberately missing Int8 payload
    end
    open(path, "r") do io
        err = try
            DynamicObjects.load(Val(:mmap), io)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(extent == 100 ? "truncated" : "overflows", sprint(showerror, err))
    end
end
end
