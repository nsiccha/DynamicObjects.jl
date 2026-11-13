using TestItemRunner

@testmodule RemakeAnalysisFixtures begin
using DynamicObjects
export CarryAnalysis, PendingCarry, hidden_reads
const hidden_reads = Ref(0)
read_hidden(o) = (hidden_reads[] += 1; o.a)
@dynamicstruct struct CarryAnalysis
    x::Int
    __hash_fields__ = (x,)
    a = x + 1
    plain = a + 1
    mixed = (__hash__, plain)
    opaque = read_hidden(__self__)
    opaque_hash = (__hash__, opaque)
    indexed(i::Int) = x + i
    @struct child = begin
        value = x
    end
end
@dynamicstruct struct PendingCarry
    started::Channel{Nothing}
    release::Channel{Nothing}
    slow = begin
        put!(started, nothing)
        take!(release)
        42
    end
end
end

@testitem "remake keeps all dependencies alongside hash and opaque reads" tags=[:core] setup=[RemakeAnalysisFixtures] begin
    o = CarryAnalysis(2; __status__=nothing)
    original = o.mixed
    @test last(original) == 4
    @test last(o.opaque_hash) == 3
    count = hidden_reads[]
    r = remake(o; a=10)
    @test r.mixed == (first(original), 11)
    @test r.opaque_hash == (first(original), 10)
    @test hidden_reads[] == count + 1
    @test remake(o).mixed === original
    o.indexed(1)
    child = o.child
    unchanged = remake(o)
    @test unchanged.indexed !== o.indexed
    @test unchanged.child !== child
    @test unchanged.child.__parent__ === unchanged
end

@testitem "remake does not wait for or carry in-flight values" tags=[:core] setup=[RemakeAnalysisFixtures] begin
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    o = PendingCarry(started, release; __status__=nothing)
    task = Threads.@spawn o.slow
    try
        take!(started)
        copy = remake(o)
        @test !haskey(getfield(copy, :cache).cache, :slow)
    finally
        put!(release, nothing)
    end
    @test fetch(task) == 42
end
