# Reflection

Inspect an object's declared inputs, dependencies, and storage policy without
computing its properties. Use these descriptions to build inspectors or
controls from the same definitions that run the calculation.

## Descriptors

`property_descriptor` returns a data record for one property. The record
includes its role, dependencies, inputs, output, and lifecycle semantics.

```@example reflection
using DynamicObjects

@dynamicstruct struct Analysis
    values::Vector{Float64}
    enabled::Bool = true
    total = enabled ? sum(values) : 0.0
    scaled(gain::Float64) = gain * total
end

descriptor = property_descriptor(Analysis, :scaled)
__docs_output__ = begin # hide
(role = descriptor.role, dependencies = descriptor.dependencies,
 indexed = descriptor.indexed, memoized = descriptor.semantics.memoized)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

`property_descriptors` preserves declaration order, including repeated indexed
signatures. `type_descriptor` describes the type itself. Neither requires an
instance or runs a property body. The dependencies are extracted from visible
reads, so they cannot describe every effect hidden inside arbitrary helpers.

## Domains

Boolean and enumeration types imply finite domains. An `@options` declaration
can specify an application domain, including one dependent on other properties.
Reflection reports that declaration; `property_options` evaluates its value
for an object.

```@example reflection
__docs_output__ = begin # hide
property_descriptor(Analysis, :enabled).domain
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

For a declared domain, evaluate it only when the application needs its choices.
Type-level reflection remains a description of the declaration, not a request
to run the code that computes those choices.

## Observations

`materialization_observation` reports the current cache state without
requesting a missing value. The declaration describes what may be computed;
an observation describes what is available on this particular instance.

```@example reflection
analysis = Analysis([1.0, 2.0, 3.0])
before = materialization_observation(analysis, :total)
analysis.total
after = materialization_observation(analysis, :total)
@assert before.state == :unmaterialized && after.state == :ready # hide
__docs_output__ = begin # hide
(before = before.state, after = after.state)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

[`declaration_graph`](@ref) assembles type and property declarations with
stable identifiers. [`declaration_observations`](@ref) adds a separate state
overlay. Consumers use [`declaration_node_id`](@ref) to connect their own
records to this graph instead of reproducing its identifier encoding.

## Selecting declarations

[`declaration_selection`](@ref) follows dependencies and domain links from
chosen declaration IDs. For the `Analysis` definition above, selecting `scaled`
normally retains `total`, `enabled`, and `values`. If another service supplies
`total`, mark it as an explicit boundary:

```@example reflection
graph = declaration_graph(Analysis)
scaled = declaration_node_id(graph, Analysis, :scaled)
total = declaration_node_id(graph, Analysis, :total)
selection = declaration_selection(graph, scaled; boundaries=[total])
@assert selection.required == [scaled] # hide
@assert selection.boundaries == [total] # hide
@assert selection.context == [graph.root] # hide
__docs_output__ = begin # hide
(local_declarations = length(selection.required),
 external_boundaries = length(selection.boundaries),
 unresolved = selection.unresolved)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The boundary is reported but its dependencies are not followed. A separate local
path to one of those dependencies still retains it. Selections can overlap and
need not cover every declaration. No property body is run.

`required`, `boundaries`, and `context` contain disjoint ID sets. `context`
preserves containing types and mount properties; it does not select their
computations, siblings, or children. Even a type root selects only itself.
Select a mount property explicitly too if its computation belongs in the plan.
`nodes` and `edges` preserve original source and fragment metadata; `reasons`
identify the roots and edges responsible for selection. Output keeps graph
order regardless of root order.

Read `unresolved` before treating a selection as an execution plan: it reports
opaque self access, missing dependency names, known nested or parent reads whose
member requirements are not represented, and unavailable analysis from older
graphs. Dependencies with multiple same-name methods retain all declarations
conservatively. Even an empty diagnostic list cannot prove completeness or
purity for arbitrary helpers and runtime dispatch. Contributed framework nodes
use their supplied edges; the selector neither prunes source nor rewrites calls
across services.

## Source information

`property_signature`, `property_doc`, and `property_source_info` expose the
signature, description, and source location. [`structure`](@ref) and
[`print_structure`](@ref) describe the property tree; [`lint_index`](@ref)
returns diagnostics associated with its declarations.

The [reflection reference](../reference/reflection.md) also contains lifecycle
entry points for semantic hosts. Application code normally calls its
properties directly; it does not need to construct a materialization store.

[Cached signal analysis](../examples/signal.md) places a generated dependency
view beside the object and a trace beside its actual reads.
