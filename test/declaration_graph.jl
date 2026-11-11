using TestItemRunner

@testmodule DeclarationGraphFixtures begin
using DynamicObjects
export DeclarationGraphFixture, DeclarationObservationFixture,
    DECLARATION_OBSERVATION_CALLS, DeclarationSelectionFixture,
    DeclarationSelectionMethods, DeclarationSelectionUnknowns

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

@dynamicstruct struct DeclarationSelectionFixture
    input::Int
    mode::Int
    @options(mode) = 1:input
    observations = begin
        DECLARATION_OBSERVATION_CALLS[] += 1
        input
    end
    assessment = 2observations
    forecast = assessment + 1
    alternate = observations + mode
    unused = error("selection must not compute")
end

@dynamicstruct struct DeclarationSelectionMethods
    left::Int
    right::Int
    choose(value::Int) = value + left
    choose(value::String) = length(value) + right
    result(value) = choose(value)
end

@dynamicstruct struct DeclarationSelectionUnknowns
    input::Int
    mode::Int
    @options(mode) = getproperty(__self__, :input)
    opaque = getproperty(__self__, :input)
    missing = __self__.__not_declared__
    @struct child = begin
        answer = input + 1
    end
    nested = child.answer
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

@testitem "declaration selection stops at explicit boundaries" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects
using Serialization

DECLARATION_OBSERVATION_CALLS[] = 0
graph = declaration_graph(DeclarationSelectionFixture)
before = deepcopy(graph)
node(name) = declaration_node_id(graph, DeclarationSelectionFixture, name)
forecast, assessment, observations = node.((:forecast, :assessment, :observations))
full = declaration_selection(graph, forecast)
@test full.schema == "dynamicobjects.declaration-selection/v1"
@test full.graph == graph.root
@test Set(full.required) == Set([forecast, assessment, observations, node(:input)])
@test full.context == [graph.root]
@test isempty(full.boundaries)
@test isempty(full.unresolved)
@test !(node(:unused) in getproperty.(full.nodes, :id))

cut = declaration_selection(graph, [forecast]; boundaries=[assessment, node(:unused)])
@test cut.required == [forecast]
@test cut.boundaries == [assessment]
@test cut.context == [graph.root]
@test !(observations in getproperty.(cut.nodes, :id))
@test any(reason -> reason.node == assessment && reason.from == forecast &&
    reason.kind === :depends_on && reason.edge !== nothing, cut.reasons)
@test !any(reason -> reason.node == observations, cut.reasons)
@test all(edge -> edge.from in getproperty.(cut.nodes, :id) &&
    edge.to in getproperty.(cut.nodes, :id), cut.edges)
@test all(record -> record in graph.nodes, cut.nodes)
@test all(record -> record in graph.edges, cut.edges)

# A boundary does not cut an independent local path to its dependencies.
shared = declaration_selection(graph, [forecast, node(:alternate)]; boundaries=assessment)
@test observations in shared.required
@test node(:input) in shared.required
@test node(:mode) in shared.required
@test assessment ∉ shared.required
@test shared.boundaries == [assessment]
@test any(record -> record.kind === :domain, shared.nodes)
@test declaration_selection(graph, [node(:alternate), forecast, forecast];
    boundaries=[assessment, assessment]) == shared

# Overlap and omissions impose no partition/exhaustiveness requirement.
@test observations in intersect(Set(full.required), Set(shared.required))
@test node(:unused) ∉ union(Set(full.required), Set(shared.required))
@test graph == before
@test DECLARATION_OBSERVATION_CALLS[] == 0
buffer = IOBuffer()
serialize(buffer, shared)
seekstart(buffer)
@test deserialize(buffer) == shared

empty = declaration_selection(graph, ())
@test isempty(empty.nodes) && isempty(empty.edges) && isempty(empty.reasons)
@test isempty(empty.required) && isempty(empty.context) && isempty(empty.boundaries)
# A type supplies context; containment must not silently select every property.
@test declaration_selection(graph, graph.root).required == [graph.root]
@test_throws ArgumentError declaration_selection(graph, forecast; boundaries=forecast)
@test_throws ArgumentError declaration_selection(graph, "absent")
@test_throws ArgumentError declaration_selection(graph, forecast; boundaries="absent")
@test_throws ArgumentError declaration_selection(graph, [:forecast])
@test_throws ArgumentError declaration_selection(merge(graph, (;schema="unknown")), forecast)
end

@testitem "declaration selection preserves method and domain requirements" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects

graph = declaration_graph(DeclarationSelectionMethods)
root = declaration_node_id(graph, DeclarationSelectionMethods, :result)
selected = declaration_selection(graph, root)
for occurrence in 1:2
    method = declaration_node_id(graph, DeclarationSelectionMethods, :choose;
        declaration=occurrence)
    @test method in selected.required
    @test any(edge -> edge.kind === :depends_on && edge.from == root &&
        edge.to == method, selected.edges)
end
for name in (:left, :right)
    @test declaration_node_id(graph, DeclarationSelectionMethods, name) in selected.required
end

domains = declaration_graph(DeclarationSelectionFixture)
mode = declaration_node_id(domains, DeclarationSelectionFixture, :mode)
input = declaration_node_id(domains, DeclarationSelectionFixture, :input)
selection = declaration_selection(domains, mode)
domain = only(filter(record -> record.kind === :domain, selection.nodes))
@test domain.id in selection.required
@test input in selection.required
@test any(reason -> reason.node == domain.id && reason.kind === :describes, selection.reasons)
@test any(reason -> reason.node == input && reason.from == domain.id, selection.reasons)
end

@testitem "declaration selection reports uncertainty without executing it" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects

graph = declaration_graph(DeclarationSelectionUnknowns)
node(name) = declaration_node_id(graph, DeclarationSelectionUnknowns, name)
opaque = declaration_selection(graph, node(:opaque))
@test any(item -> item.node == node(:opaque) && item.kind === :opaque_dependencies,
    opaque.unresolved)
missing = declaration_selection(graph, node(:missing))
@test any(item -> item.node == node(:missing) && item.kind === :missing_dependency &&
    item.dependency === :__not_declared__, missing.unresolved)
nested = declaration_selection(graph, node(:nested))
@test any(item -> item.node == node(:nested) && item.kind === :nested_dependency &&
    item.dependency === :child, nested.unresolved)

child_type_id = only(edge.to for edge in graph.edges
    if edge.kind === :contains && edge.from == node(:child))
answer = only(record for record in graph.nodes if record.kind === :property &&
    record.metadata.owner == child_type_id && record.metadata.name === :answer)
inner = declaration_selection(graph, answer.id)
@test child_type_id in inner.context
@test node(:child) in inner.context
@test graph.root in inner.context
@test node(:nested) ∉ getproperty.(inner.nodes, :id)
@test any(item -> item.kind === :nested_dependency && item.dependency === :__parent__,
    inner.unresolved)

domain = declaration_selection(graph, node(:mode))
@test any(item -> item.kind === :opaque_dependencies &&
    any(record -> record.id == item.node && record.kind === :domain, domain.nodes),
    domain.unresolved)

# A reached external node is described, never analyzed as local work.
fragment = (;namespace="example.selection",
    nodes=[(;id="example:root", kind=:operation, label="External caller",
        metadata=(;dependency_analysis="framework-private"))],
    edges=[(;id="example:call", kind=:depends_on, from="example:root",
        to=node(:opaque), metadata=(;transport=:http))])
extended = declaration_graph(DeclarationSelectionUnknowns; contributions=fragment)
cut = declaration_selection(extended, "example:root"; boundaries=node(:opaque))
@test isempty(cut.unresolved)
@test cut.boundaries == [node(:opaque)]
@test last(cut.edges).metadata == (;transport=:http)

# Older serialized graphs remain usable but do not acquire a false certainty.
old_nodes = [merge(record, (;metadata=Base.structdiff(record.metadata,
    NamedTuple{(:dependency_analysis,)}))) for record in graph.nodes]
old = merge(graph, (;nodes=old_nodes))
@test any(item -> item.kind === :unavailable_analysis,
    declaration_selection(old, node(:input)).unresolved)
end

@testitem "declaration selection handles contributed cycles and long paths" tags=[:declaration_graph] setup=[DeclarationGraphFixtures] begin
using DynamicObjects

count = 5000
nodes = [(;id="example:$index", kind=:operation, label="Operation $index", metadata=(;))
    for index in 1:count]
edges = [(;id="example:edge:$index", kind=:depends_on, from="example:$index",
    to="example:$(index + 1)", metadata=(;)) for index in 1:count-1]
push!(edges, (;id="example:cycle", kind=:depends_on, from="example:$count",
    to="example:1", metadata=(;)))
fragment = (;namespace="example.selection", nodes, edges)
graph = declaration_graph(DeclarationObservationFixture; contributions=fragment)
all_nodes = declaration_selection(graph, "example:1")
@test length(all_nodes.required) == count
@test length(all_nodes.nodes) == count
@test length(all_nodes.edges) == count
@test length(all_nodes.reasons) == count + 1
@test isempty(all_nodes.context)
@test isempty(all_nodes.unresolved)

cut = declaration_selection(graph, "example:1"; boundaries="example:3")
@test cut.required == ["example:1", "example:2"]
@test cut.boundaries == ["example:3"]
@test length(cut.edges) == 2
@test length(cut.reasons) == 3

# Containment cycles terminate too, without turning context into requirements.
context_edges = [
    (;id="example:context:1", kind=:contains, from="example:4", to="example:1", metadata=(;)),
    (;id="example:context:2", kind=:contains, from="example:5", to="example:4", metadata=(;)),
    (;id="example:context:3", kind=:contains, from="example:4", to="example:5", metadata=(;)),
]
with_context = declaration_graph(DeclarationObservationFixture;
    contributions=(fragment, (;namespace="example.context", nodes=NamedTuple[], edges=context_edges)))
selection = declaration_selection(with_context, "example:1"; boundaries="example:3")
@test selection.context == ["example:4", "example:5"]
@test selection.required == cut.required
@test !any(reason -> reason.kind === :depends_on && reason.from == "example:4",
    selection.reasons)
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
