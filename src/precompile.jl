# Warm shared implementation paths with synthetic values. This module is private;
# the workload runs only while precompiling and performs no disk or worker work.
module _PrecompileWorkload
using ..DynamicObjects
using PrecompileTools: @compile_workload

@dynamicstruct struct Workload
    input::Int
    value = input + 1
    indexed(i::Int) = input + i
end

@compile_workload begin
    let object = Workload(1000; __status__=nothing)
        object.value
        object.indexed(3)
        object.indexed(3)
        property_descriptors(Workload)
        declaration_graph(Workload)
        remake(object)
        remake(object; input=2000)
    end
end
end
