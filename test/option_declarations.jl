using TestItemRunner

@testmodule OptionFixtures begin
using DynamicObjects
export OptionDomainFixture, UndeclaredOptionFixture, VarargOperationFixture,
    DocumentedNodeFixture, UndocumentedNodeFixture, OPTION_STUDIES,
    option_values_for

# Application data DynamicObjects knows nothing about. The point of `@options`
# is that a domain may be spelled in terms of these and still be recorded.
const OPTION_STUDIES = Dict(:north => [:depot_1cmt], :south => [:depot_1cmt, :tmdd])
option_values_for(study) = OPTION_STUDIES[study]

"""A study gallery."""
@dynamicstruct struct OptionDomainFixture
    study::Symbol
    model::Symbol

    # Static: nothing but module-level data, so the domain is fixed for the type.
    @options study = sort!(collect(keys(OPTION_STUDIES)))
    # Context-dependent: reads the sibling `study`, so a consumer must
    # re-evaluate it whenever `study` changes.
    @options model = option_values_for(study)

    prediction_grid(dose::Float64=100.0) = (study, model, dose)
end

@dynamicstruct struct UndeclaredOptionFixture
    study::Symbol
    # No input of this type is named `cohort`; the declaration is still
    # inspectable rather than silently lost.
    @options cohort = [:a, :b]
end

@dynamicstruct struct VarargOperationFixture
    root::Symbol
    evidence(path...; ndraw::Int=8) = (root, path, ndraw)
    single(path; ndraw::Int=8) = (root, path, ndraw)
end

@dynamicstruct struct UndocumentedNodeFixture
    value::Int
end

"""A documented node."""
@dynamicstruct struct DocumentedNodeFixture
    value::Int
end
end

@testitem "@options records static and dependent domains" setup=[OptionFixtures] begin
using DynamicObjects

declarations = option_declarations(OptionDomainFixture)
@test first.(declarations) == [:study, :model]

study, model = last.(declarations)

@test study.parameter === :study
@test study.expression == :(sort!(collect(keys(OPTION_STUDIES))))
@test study.expression_string == "sort!(collect(keys(OPTION_STUDIES)))"
@test study.dependencies == Symbol[]
@test study.static
@test study.source === :options
@test study.lnn isa LineNumberNode

@test model.parameter === :model
@test model.expression == :(option_values_for(study))
@test model.dependencies == [:study]
@test !model.static
end

@testitem "@options declarations are not properties" setup=[OptionFixtures] begin
using DynamicObjects

# The declaration must not shadow the field it governs, add a property, or
# leave a marker on the field's own metadata.
@test first.(DynamicObjects.meta(OptionDomainFixture)) == [:study, :model, :prediction_grid]
@test !(Symbol("@options") in DynamicObjects.metafirst(OptionDomainFixture, :study).macros)

o = OptionDomainFixture(:south, :tmdd)
@test o.study === :south
@test o.model === :tmdd
@test o.prediction_grid() == (:south, :tmdd, 100.0)
end

@testitem "@options domains reach the descriptor graph" setup=[OptionFixtures] begin
using DynamicObjects

field = only(property_descriptor(OptionDomainFixture, :model).inputs)
@test field.kind === :field
@test field.domain.kind === :declared
@test field.domain.dependencies == [:study]
@test isempty(field.domain.options)
@test field.domain.declaration.expression == :(option_values_for(study))
@test !field.domain.declaration.static

# The same declaration governs the operation's promoted context inputs — one
# declaration per parameter name, however many operations take it.
grid = property_descriptor(OptionDomainFixture, :prediction_grid)
by_name = Dict(input.name => input for input in grid.inputs)
@test by_name[:study].kind === :context
@test by_name[:study].domain.kind === :declared
@test by_name[:study].domain.declaration.static
@test by_name[:model].domain.declaration.dependencies == [:study]
# An input with no declaration and no type-provable domain stays unrestricted.
@test by_name[:dose].kind === :positional
@test by_name[:dose].domain.kind === :unrestricted
@test by_name[:dose].domain.declaration === nothing
end

@testitem "@options for an unattached parameter stays inspectable" setup=[OptionFixtures] begin
using DynamicObjects

declarations = option_declarations(UndeclaredOptionFixture)
@test first.(declarations) == [:cohort]
@test last(only(declarations)).static
# It governs no input, so no descriptor claims it.
@test only(property_descriptor(UndeclaredOptionFixture, :study).inputs).domain.kind ===
    :unrestricted
end

@testitem "types without @options keep the empty default" setup=[OptionFixtures] begin
using DynamicObjects

@test option_declarations(VarargOperationFixture) == Pair{Symbol,NamedTuple}[]
@test option_declarations(Int) == Pair{Symbol,NamedTuple}[]
end

@testitem "varargs are marked in signatures and descriptors" setup=[OptionFixtures] begin
using DynamicObjects

evidence = property_signature(VarargOperationFixture, :evidence)
path = only(evidence.positional)
@test path.name === :path
@test path.vararg
@test !path.required
@test !only(evidence.kwargs).vararg

# A plain optional positional must stay distinguishable from a splat.
single = only(property_signature(VarargOperationFixture, :single).positional)
@test !single.vararg

inputs = property_descriptor(VarargOperationFixture, :evidence).inputs
by_name = Dict(input.name => input for input in inputs)
@test by_name[:path].vararg
@test !by_name[:ndraw].vararg
@test !only(property_descriptor(VarargOperationFixture, :root).inputs).vararg
end

@testitem "type_descriptor reports the node's own docstring" setup=[OptionFixtures] begin
using DynamicObjects

documented = type_descriptor(DocumentedNodeFixture)
@test documented.type === DocumentedNodeFixture
@test documented.name === :DocumentedNodeFixture
@test documented.description == "A documented node."
@test isempty(documented.options)

# The auto-generated property-list docstring is a `?T` fallback, not a label.
@test type_descriptor(UndocumentedNodeFixture).description === nothing

@test type_descriptor(OptionDomainFixture).description == "A study gallery."
@test first.(type_descriptor(OptionDomainFixture).options) == [:study, :model]
end

@testitem "malformed @options declarations are rejected" setup=[OptionFixtures] begin
using DynamicObjects

@test_throws LoadError @eval @dynamicstruct struct BadOptionsShape
    study::Symbol
    @options study
end
@test_throws LoadError @eval @dynamicstruct struct BadOptionsArgument
    study::Symbol
    @options v"2" study = [:a]
end
@test_throws LoadError @eval @dynamicstruct struct BadOptionsMarkerCombo
    study::Symbol
    @cached @options study = [:a]
end
end
