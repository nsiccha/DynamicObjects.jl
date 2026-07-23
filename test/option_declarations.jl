using TestItemRunner

@testmodule OptionFixtures begin
using DynamicObjects
export OptionDomainFixture, SpaceFormOptionFixture, OverrideableDefaultFixture,
    UndeclaredOptionFixture, VarargOperationFixture, DocumentedNodeFixture,
    UndocumentedNodeFixture, OPTION_STUDIES, option_values_for

# Application data DynamicObjects knows nothing about. The point of `@options`
# is that a domain may be spelled in terms of these and still be recorded.
const OPTION_STUDIES = Dict(:north => [:depot_1cmt], :south => [:depot_1cmt, :tmdd])
option_values_for(study) = OPTION_STUDIES[study]

"""A study gallery."""
@dynamicstruct struct OptionDomainFixture
    study::Symbol
    model::Symbol

    # Static: nothing but module-level data, so the domain is fixed for the type.
    @options(study) = sort!(collect(keys(OPTION_STUDIES)))
    # Context-dependent: reads the sibling `study`, so a consumer must re-read it
    # whenever `study` changes.
    @options(model) = option_values_for(study)
    # A domain is any value supporting `in` — no new vocabulary.
    @options(dose) = 10.0:10.0:100.0

    prediction_grid(dose::Float64=100.0; seed::Int=0) = (study, model, dose, seed)
end

# The space form parses to the same thing.
@dynamicstruct struct SpaceFormOptionFixture
    study::Symbol
    @options study = [:north, :south]
end

# The shape the SbPMX mock is written in: parameters are overrideable defaults,
# i.e. computed properties with no call signature.
@dynamicstruct struct OverrideableDefaultFixture
    n_chain::Integer        = 8
    target_acceptance::Real = 0.95
    resume::Bool            = true

    @options(n_chain)           = 1:64
    @options(target_acceptance) = 0.5:0.005:0.999

    draws(seed::Integer) = (n_chain, target_acceptance, resume, seed)
end

@dynamicstruct struct UndeclaredOptionFixture
    study::Symbol
    # No input of this type is named `cohort`; the declaration is still
    # inspectable rather than silently lost.
    @options(cohort) = [:a, :b]
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
@test first.(declarations) == [:study, :model, :dose]

study, model, _ = last.(declarations)

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

@testitem "@options lowers to __options__, never to the parameter" setup=[OptionFixtures] begin
using DynamicObjects

# The declaration must not shadow the field it governs, nor leave a marker on
# that field's own metadata: it becomes one `__options__` declaration each.
@test first.(DynamicObjects.meta(OptionDomainFixture)) ==
    [:study, :model, :__options__, :__options__, :__options__, :prediction_grid]
@test !(Symbol("@options") in DynamicObjects.metafirst(OptionDomainFixture, :study).macros)

o = OptionDomainFixture(:south, :tmdd)
@test o.study === :south
@test o.model === :tmdd
@test o.prediction_grid() == (:south, :tmdd, 100.0, 0)
end

@testitem "@options domains evaluate against the object" setup=[OptionFixtures] begin
using DynamicObjects

o = OptionDomainFixture(:south, :tmdd)
@test property_options(o, :study) == [:north, :south]
# Dependent: answered against THIS object's `study`, which is what makes an
# object the thing you evaluate a domain on.
@test property_options(o, :model) == [:depot_1cmt, :tmdd]
@test property_options(OptionDomainFixture(:north, :depot_1cmt), :model) == [:depot_1cmt]
# Membership is the whole contract; a domain is any value supporting `in`.
@test o.model in property_options(o, :model)
@test !(:tmdd in property_options(OptionDomainFixture(:north, :depot_1cmt), :model))
@test 50.0 in property_options(o, :dose)

@test has_option_declaration(OptionDomainFixture, :model)
@test !has_option_declaration(OptionDomainFixture, :prediction_grid)
# No declaration, no answer — and no error for asking.
@test property_options(o, :prediction_grid) === nothing
@test property_options(UndeclaredOptionFixture(:north), :study) === nothing

# The domain is an ordinary memoized property, so the expression runs once.
@test property_options(o, :model) === property_options(o, :model)
end

@testitem "@options accepts the space form too" setup=[OptionFixtures] begin
using DynamicObjects

declaration = last(only(option_declarations(SpaceFormOptionFixture)))
@test declaration.parameter === :study
@test declaration.expression == :([:north, :south])
@test declaration.static
@test property_options(SpaceFormOptionFixture(:north), :study) == [:north, :south]
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
# The `dose` declaration governs this operation's `dose` argument too — one
# declaration per parameter NAME, however many operations take it.
@test by_name[:dose].kind === :positional
@test by_name[:dose].domain.kind === :declared
@test by_name[:dose].domain.declaration.static
# An input with no declaration and no type-provable domain stays unrestricted.
@test by_name[:seed].kind === :keyword
@test by_name[:seed].domain.kind === :unrestricted
@test by_name[:seed].domain.declaration === nothing
end

@testitem "overrideable defaults carry a domain on the descriptor" setup=[OptionFixtures] begin
using DynamicObjects

# A computed property with no signature: there is no `inputs` entry, so the
# domain has to be on the descriptor itself.
n_chain = property_descriptor(OverrideableDefaultFixture, :n_chain)
@test !n_chain.fixed
@test isempty(n_chain.inputs)
@test n_chain.domain.kind === :declared
@test n_chain.domain.declaration.expression == :(1:64)
@test n_chain.domain.declaration.static

# `Bool` still proves its own domain with no declaration at all.
resume = property_descriptor(OverrideableDefaultFixture, :resume)
@test resume.domain.kind === :static
@test [option.value for option in resume.domain.options] == [false, true]
@test resume.domain.declaration === nothing

# An operation's own value has no domain anyone declared.
@test property_descriptor(OverrideableDefaultFixture, :draws).domain.kind === :unrestricted

o = OverrideableDefaultFixture()
@test o.n_chain == 8
@test o.n_chain in property_options(o, :n_chain)
@test !(0 in property_options(o, :n_chain))
# The default is overrideable, and the domain does not change with it.
@test OverrideableDefaultFixture(; n_chain=32).n_chain == 32
@test property_options(OverrideableDefaultFixture(; n_chain=32), :n_chain) == 1:64
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
@test first.(type_descriptor(OptionDomainFixture).options) == [:study, :model, :dose]
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
@test_throws LoadError @eval @dynamicstruct struct BadOptionsTwoParameters
    study::Symbol
    @options(study, cohort) = [:a]
end
@test_throws LoadError @eval @dynamicstruct struct BadOptionsMarkerCombo
    study::Symbol
    @cached @options study = [:a]
end
@test_throws LoadError @eval @dynamicstruct struct DuplicateOptionsParameter
    study::Symbol
    @options(study) = [:north]
    @options(study) = [:south]
end
end
