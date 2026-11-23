using TestItemRunner

@testmodule DeclarationAnalysisFixtures begin
using DynamicObjects
export AnalysisChain, AnalysisDuplicates

info(name, dependencies; fixed=false) = (;
    lhs=name, rhs=fixed ? nothing : :(1), indices=(),
    dependson=Set{Symbol}(dependencies), macros=Set{Symbol}(),
)

struct AnalysisChain{N} end
function DynamicObjects.meta(::Type{AnalysisChain{N}}) where N
    entries = Pair{Symbol,NamedTuple}[:input => info(:input, (); fixed=true)]
    for i in 1:N
        name = Symbol(:p, i)
        previous = i == 1 ? :input : Symbol(:p, i - 1)
        push!(entries, name => info(name, (previous,)))
    end
    entries
end

struct AnalysisDuplicates end
DynamicObjects.meta(::Type{AnalysisDuplicates}) = [
    :left => info(:left, (); fixed=true),
    :right => info(:right, (); fixed=true),
    :choose => info(:choose, (:left,)),
    :choose => info(:choose, (:right,)),
    :result => info(:result, (:choose, :unknown)),
]
end

@testitem "dependency traversal agrees with fixed-point closure" tags=[:core] begin
    const DO = DynamicObjects
    function reference_close(roots, edges, excluded=())
        reached = Set(roots)
        while true
            next = union(reached, Set(name for (name, deps) in edges
                if !(name in excluded) && !isdisjoint(deps, reached)))
            next == reached && return reached
            reached = next
        end
    end
    nodes = (:a, :b, :c)
    subset(mask) = Set{Symbol}(nodes[i] for i in 1:3 if !iszero(mask & (1 << (i - 1))))
    # All directed graphs on three nodes, including self-edges and cycles.
    for bits in 0:511
        edges = Dict(name => Symbol[nodes[j] for j in 1:3
            if !iszero(bits & (1 << (3(i - 1) + j - 1)))] for (i, name) in enumerate(nodes))
        graph = DO._DependencyGraph(edges)
        for mask in 0:7
            roots = subset(mask)
            expected = Set{Symbol}()
            for root in roots
                union!(expected, setdiff(reference_close((root,), edges), (root,)))
            end
            @test DO._dependents_in(graph, roots) == expected
            for barrier in ((), (:b,), (:a, :c))
                @test DO._close_dependents!(copy(roots), graph, barrier) ==
                    reference_close(roots, edges, barrier)
            end
        end
    end
    graph = DO._DependencyGraph(Dict(:a => [:external], :b => [:a]))
    @test DO._dependents_in(graph, (:external,)) == Set((:a, :b))
end

@testitem "shared reflection preserves declaration order and first-declaration reads" tags=[:semantic] setup=[DeclarationAnalysisFixtures] begin
    descriptors = property_descriptors(AnalysisDuplicates)
    @test getproperty.(descriptors, :name) == [:left, :right, :choose, :choose, :result]
    @test getproperty.(descriptors[3].inputs, :name) == [:left]
    @test getproperty.(descriptors[4].inputs, :name) == [:right]
    @test getproperty.(descriptors[5].inputs, :name) == [:left]
    @test property_descriptor(AnalysisDuplicates, :choose) == descriptors[3]
    @test DynamicObjects.dependents(AnalysisDuplicates, :right) == [:choose, :result]
    @test isempty(property_descriptors(Int))
    @test property_descriptor(Int, :missing) === nothing
end

@testitem "named lookup follows the current first declaration" tags=[:semantic] begin
    @dynamicstruct struct NamedLookup{Tag}
        base::Int
        choice(i) = base + i
        choice(i, j) = base + i + j
    end
    T = NamedLookup{:regular}
    entries = DynamicObjects.meta(T)
    @test first.(entries) == [:base, :choice, :choice]
    @test metafirst(T, :choice) === last(entries[2])
    @test metaall(T, :choice) == last.(entries[2:3])
    @test metafirst(T, :missing) === nothing

    # More specific, user-provided metadata remains authoritative, even when
    # it changes between calls. Its records belong to that provider.
    custom_entries = [:other => (; value=[1]), :other => (; value=[2])]
    @eval DynamicObjects.meta(::Type{NamedLookup{:custom}}) = $custom_entries
    @test metafirst(NamedLookup{:custom}, :choice) === nothing
    @test metafirst(NamedLookup{:custom}, :other) === last(custom_entries[1])
    reverse!(custom_entries)
    @test metafirst(NamedLookup{:custom}, :other) === last(custom_entries[1])

    # Re-expanding the same struct replaces its declaration source and index.
    @dynamicstruct struct NamedLookup{Tag}
        base::Int
        other = base
    end
    @test metafirst(T, :choice) === nothing
    @test metafirst(T, :other) === last(DynamicObjects.meta(T)[2])
end

@testitem "allocations for named lookup scale with the declarations returned" tags=[:semantic] begin
    function allinfos(T, names)
        [metafirst(T, name) for name in names]
    end
    function lookup_bytes(T)
        names = first.(DynamicObjects.meta(T))
        @test allinfos(T, names) == last.(DynamicObjects.meta(T))
        minimum(@allocated(allinfos(T, names)) for _ in 1:3)
    end
    for width in (32, 128)
        typename = Symbol(:WideLookup, width)
        fields = [:($(Symbol(:p, i)) = $i) for i in 1:width]
        @eval @dynamicstruct struct $typename
            $(fields...)
        end
    end
    small = lookup_bytes(WideLookup32)
    large = lookup_bytes(WideLookup128)
    @test large < 8small
end

@testitem "chain reflection allocation growth stays bounded" tags=[:semantic] setup=[DeclarationAnalysisFixtures] begin
    for T in (AnalysisChain{64}, AnalysisChain{256})
        descriptors = property_descriptors(T)
        @test all(d -> getproperty.(d.inputs, :name) == [:input], descriptors)
    end
    small = minimum(@allocated(property_descriptors(AnalysisChain{64})) for _ in 1:3)
    large = minimum(@allocated(property_descriptors(AnalysisChain{256})) for _ in 1:3)
    # Four times the declarations; generous headroom for container growth,
    # while rejecting the former quadratic/cubic dependency reconstruction.
    @test large < 8small
end
