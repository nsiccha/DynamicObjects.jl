using TestItemRunner

@testmodule PerformanceFixtures begin
using DynamicObjects
export AccessInference, AddressLookup
@dynamicstruct struct AccessInference
    input::Int
    annotated::Int = input + 1
    indexed(i::Int) = input + i
end
@dynamicstruct struct AddressLookup
    @struct child(i::Int) = begin
        value = i
    end
end
end

@testitem "constant fixed-field reads infer without constraining overrides" tags=[:core] setup=[PerformanceFixtures] begin
    read_input(o) = o.input
    o = AccessInference(1000; __status__=nothing)
    @test @inferred(read_input(o)) == 1000
    @test o.annotated == 1001
    overridden = AccessInference(1000; annotated="configured", indexed=identity)
    @test overridden.annotated == "configured"
    @test overridden.indexed(:configured) === :configured
    tasks = map(1:16) do input
        Threads.@spawn remake(o; input).annotated
    end
    @test fetch.(tasks) == collect(2:17)
    @test o.annotated == 1001
end

@testitem "worker child lookup retains only the matching key" tags=[:core] setup=[PerformanceFixtures] begin
    DO = DynamicObjects
    parent = AddressLookup(; __status__=nothing)
    first_child = parent.child(1)
    @test DO._child_step(parent, first_child) == (:child, true, (1,), (;))
    @test DO._held_entry(parent.child, ((1.0,), (;))) === first_child
    @test DO._held_entry(parent.child, ((2,), (;))) === nothing
    small = @allocated DO._child_step(parent, first_child)
    for i in 2:256
        parent.child(i)
    end
    @test DO._child_step(parent, first_child) == (:child, true, (1,), (;))
    large = @allocated DO._child_step(parent, first_child)
    @test large < 4small + 1024
    clear_mem_caches!(parent)
    @test DO._child_step(parent, first_child) === nothing
end
