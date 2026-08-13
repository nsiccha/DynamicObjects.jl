using TestItemRunner

@testmodule DeclarationGraphFixtures begin
using DynamicObjects
export DeclarationGraphFixture, DeclarationObservationFixture,
    DECLARATION_OBSERVATION_CALLS

"""A root application declaration used to prove graph reflection."""
@dynamicstruct struct DeclarationGraphFixture
    "The seed shared by every calculation."
    seed::Int
    mode::Int

    @options(seed) = 1:3
    @options(mode) = 1:seed

    "A derived scalar."
    doubled = 2seed

    "Scale the derived value."
    calculate(scale::Int=2)::Int = doubled * scale

    @struct child = begin
        "A nested declaration."
        answer = 42
    end
end

DynamicObjects.declaration_metadata(::Type{DeclarationGraphFixture}) = (;
    category=:application,
    audience="humans",
)
DynamicObjects.declaration_metadata(
    ::Type{DeclarationGraphFixture}, ::Val{:calculate}) = (;
        category=:calculation,
    )

const DECLARATION_OBSERVATION_CALLS = Ref(0)

@dynamicstruct struct DeclarationObservationFixture
    input::Int
    scalar = begin
        DECLARATION_OBSERVATION_CALLS[] += 1
        2input
    end
    indexed(i::Int) = begin
        DECLARATION_OBSERVATION_CALLS[] += 1
        input + i
    end
end

end # @testmodule DeclarationGraphFixtures

"""The base graph is deterministic, complete, and keeps only declared edges."""
@testitem "application declaration graph" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects
using Serialization

graph = declaration_graph(DeclarationGraphFixture)
again = declaration_graph(DeclarationGraphFixture(2, 1))

@test graph == again
@test graph.schema == "dynamicobjects.declaration-graph/v1"
@test graph.root == declaration_node_id(graph, DeclarationGraphFixture)
@test graph.metadata.namespace == "dynamicobjects"
@test first(graph.metadata.fragments).namespace == "dynamicobjects"
@test all(node -> node.id isa String && node.kind isa Symbol &&
    node.label isa String && node.fragment isa String &&
    haskey(node, :metadata), graph.nodes)
@test all(edge -> edge.id isa String && edge.kind isa Symbol &&
    edge.from isa String && edge.to isa String &&
    edge.fragment isa String && haskey(edge, :metadata), graph.edges)
@test length(unique(vcat(getproperty.(graph.nodes, :id),
                         getproperty.(graph.edges, :id)))) ==
    length(graph.nodes) + length(graph.edges)

buffer = IOBuffer()
serialize(buffer, graph)
seekstart(buffer)
@test deserialize(buffer) == graph

root = only(filter(node -> node.id == graph.root, graph.nodes))
@test root.kind === :type
@test root.metadata.descriptor.description ==
    "A root application declaration used to prove graph reflection."
@test root.metadata.extensions == (;
    category=:application,
    audience="humans",
)

seed_id = declaration_node_id(graph, DeclarationGraphFixture, :seed)
doubled_id = declaration_node_id(graph, DeclarationGraphFixture, :doubled)
calculate_id = declaration_node_id(graph, DeclarationGraphFixture, :calculate)
@test all(!isnothing, (seed_id, doubled_id, calculate_id))
@test declaration_node_id(
    graph, DeclarationGraphFixture, :calculate; declaration=2) === nothing

calculate = only(filter(node -> node.id == calculate_id, graph.nodes))
@test calculate.metadata.owner == graph.root
@test calculate.metadata.owner_type_key == root.metadata.type_key
@test calculate.metadata.name === :calculate
@test calculate.metadata.declaration == 1
@test calculate.metadata.extensions == (;category=:calculation)
@test calculate.metadata.descriptor.output.type === Int
@test calculate.metadata.signature.positional[1].name === :scale
@test calculate.metadata.signature.positional[1].default == 2
@test calculate.metadata.source.location.file !== nothing
@test calculate.metadata.source.location.line isa Int
@test occursin("doubled * scale", calculate.metadata.source.code)
@test occursin("doubled * scale", calculate.metadata.source.rhs)

@test any(edge -> edge.kind === :contains &&
    edge.from == graph.root && edge.to == calculate_id, graph.edges)
@test any(edge -> edge.kind === :depends_on &&
    edge.from == calculate_id && edge.to == doubled_id, graph.edges)
@test !any(edge -> edge.kind === :depends_on &&
    edge.from == calculate_id && edge.to == seed_id, graph.edges)

child_property_id = declaration_node_id(graph, DeclarationGraphFixture, :child)
child_edge = only(filter(edge -> edge.kind === :contains &&
    edge.from == child_property_id, graph.edges))
child = only(filter(node -> node.id == child_edge.to, graph.nodes))
@test child.kind === :type
@test child.id != graph.root

mode_domain = only(filter(node ->
    node.kind === :domain && node.metadata.parameter === :mode, graph.nodes))
mode_id = declaration_node_id(graph, DeclarationGraphFixture, :mode)
@test mode_domain.metadata.declaration.expression == :(1:seed)
@test any(edge -> edge.kind === :describes &&
    edge.from == mode_id && edge.to == mode_domain.id, graph.edges)
@test any(edge -> edge.kind === :depends_on &&
    edge.from == mode_domain.id && edge.to == seed_id, graph.edges)
end

"""External fragments preserve their vocabulary and reject ambiguous IDs."""
@testitem "declaration graph contributions" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects

base = declaration_graph(DeclarationGraphFixture)
calculate_id = declaration_node_id(base, DeclarationGraphFixture, :calculate)
domain = (;
    namespace="example.domain",
    nodes=[(;
        id="example:descriptor:result",
        kind=:descriptor,
        label="Result artifact",
        metadata=(;format=:example),
        href="#result",
    )],
    edges=[(;
        id="example:edge:result",
        kind=:describes,
        from=calculate_id,
        to="example:descriptor:result",
        metadata=(;role=:output),
    )],
)

graph = declaration_graph(DeclarationGraphFixture; contributions=(domain,))
external = only(filter(node -> node.id == "example:descriptor:result", graph.nodes))
@test external.kind === :descriptor
@test external.href == "#result"
@test external.fragment == "example.domain"
@test last(graph.metadata.fragments) == (;
    namespace="example.domain",
    nodes=1,
    edges=1,
)
@test last(graph.edges).fragment == "example.domain"

# Endpoints are checked after all fragments, so an earlier fragment can link to
# a node supplied by a later composer without either namespace rewriting IDs.
first_fragment = (;
    namespace="example.first",
    nodes=[(;id="example:first", kind=:descriptor, label="First", metadata=(;))],
    edges=[(;
        id="example:cross",
        kind=:describes,
        from="example:first",
        to="example:second",
        metadata=(;),
    )],
)
second_fragment = (;
    namespace="example.second",
    nodes=[(;id="example:second", kind=:descriptor, label="Second", metadata=(;))],
    edges=NamedTuple[],
)
cross = declaration_graph(
    DeclarationGraphFixture;
    contributions=(first_fragment, second_fragment),
)
@test getproperty.(last(cross.nodes, 2), :id) ==
    ["example:first", "example:second"]

collision = (;
    namespace="example.collision",
    nodes=[(;id=base.root, kind=:descriptor, label="Collision", metadata=(;))],
    edges=NamedTuple[],
)
@test_throws ErrorException declaration_graph(
    DeclarationGraphFixture; contributions=(collision,))

dangling = (;
    namespace="example.dangling",
    nodes=NamedTuple[],
    edges=[(;
        id="example:dangling-edge",
        kind=:describes,
        from=base.root,
        to="example:missing",
        metadata=(;),
    )],
)
@test_throws ErrorException declaration_graph(
    DeclarationGraphFixture; contributions=(dangling,))
end

"""The optional overlay observes caches but never invokes a property body."""
@testitem "declaration observations do not compute" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects

DECLARATION_OBSERVATION_CALLS[] = 0
object = DeclarationObservationFixture(3)
graph = declaration_graph(object)
scalar_id = declaration_node_id(graph, DeclarationObservationFixture, :scalar)
indexed_id = declaration_node_id(graph, DeclarationObservationFixture, :indexed)

overlay = declaration_observations(object, graph)
@test overlay.schema == "dynamicobjects.declaration-observations/v1"
@test overlay.graph == graph.root
@test DECLARATION_OBSERVATION_CALLS[] == 0
@test !any(observation -> observation.node == indexed_id, overlay.observations)
scalar = only(filter(observation ->
    observation.node == scalar_id, overlay.observations))
@test scalar.call === nothing
@test scalar.observation.state === :unmaterialized

indexed = declaration_observations(object, graph; calls=((;
    node=indexed_id,
    args=(4,),
    kwargs=(;),
),))
@test DECLARATION_OBSERVATION_CALLS[] == 0
indexed_observation = only(filter(observation ->
    observation.node == indexed_id, indexed.observations))
@test indexed_observation.node == indexed_id
@test indexed_observation.call.args == (4,)
@test indexed_observation.observation.state === :unmaterialized

@test object.scalar == 6
@test object.indexed(4) == 7
@test DECLARATION_OBSERVATION_CALLS[] == 2

ready = declaration_observations(object, graph; calls=((;
    node=indexed_id,
    args=(4,),
    kwargs=(;),
),))
@test DECLARATION_OBSERVATION_CALLS[] == 2
by_node = Dict(observation.node => observation for observation in ready.observations)
@test by_node[scalar_id].observation.ready
@test by_node[indexed_id].observation.ready
@test by_node[indexed_id].observation.estimated_bytes == sizeof(Int)
end
