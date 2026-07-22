using TestItemRunner

@testmodule SemanticFixtures begin
using DynamicObjects
export SemanticQuality, draft, final, SemanticDescriptorFixture,
    SemanticPendingFixture, ComputedVersionedSemanticDescriptorFixture,
    BadSemanticInputName, LegacySemanticMeta,
    DeduplicatedKeyFixture, SiblingAsSemanticInput

@enum SemanticQuality draft final

@dynamicstruct struct SemanticDescriptorFixture
    @versioned revision::Int
    enabled::Bool
    quality::SemanticQuality
    @semantic (inputs=(mode=(domain=static_domain((
        (value=:fast, label="Fast"),
        (value=:careful, label="Careful", help="Use the full solver"),
    )),),),) mode::Symbol

    dataset_options(cohort::Symbol) = cohort === :north ? [:n1, :n2] : [:s1]

    @semantic (
        inputs=(dataset=(domain=dynamic_domain(:dataset_options;
            dependencies=(:cohort,)),),),
        output=(estimated_bytes=32 * 1024^2, compute_seconds=4.0,
            expected_reuse=3, portable=true),
    ) @cached v"2" fit(dataset::Symbol, cohort::Symbol; scale::Int=1)::Vector{Float64} =
        fill(Float64(scale), dataset === :n1 ? 2 : 1)

    @semantic (output=(mmap_eligible=true, immutable=true, portable=true),) @mmap @progress matrix::Matrix{Float64} = reshape(collect(1.0:4.0), 2, 2)

    @semantic (output=(estimated_bytes=64 * 1024^2, compute_seconds=3.0,
        expected_reuse=5, mmap_eligible=true, immutable=true, portable=true),) candidate::Vector{Float64} = [1.0, 2.0]

    @fresh preview(x::Int) = 2x
end

@dynamicstruct struct SemanticPendingFixture
    gate::Channel{Nothing}
    slow(x::Int) = (take!(gate); x + 1)
end

@dynamicstruct struct ComputedVersionedSemanticDescriptorFixture
    @versioned fixture_version = "synthetic_depot_v1"

    @semantic (
        inputs=(study=(domain=static_domain((:north, :south)),),),
        output=(mmap_eligible=true, immutable=true, portable=true),
    ) @mmap @progress prediction_grid(
        study::Symbol,
        model::Symbol,
        dose::Float64=100.0,
    )::Matrix{Float64} = fill(dose, 2, 2)
end

@dynamicstruct struct BadSemanticInputName
    @semantic (inputs=(missing=(domain=static_domain((1, 2)),),),) value(x::Int) = x
end

# The deduplicated shape do-use §6 documents: a key tuple shared by several
# operations lives ONCE as fixed fields carrying the domains, and the
# operations read them as bare siblings instead of restating `inputs=`.
@dynamicstruct struct DeduplicatedKeyFixture
    @semantic (inputs=(study=(domain=static_domain((:north, :south)),),),) study::Symbol
    @semantic (inputs=(model=(domain=static_domain((:one_cmt, :two_cmt)),),),) model::Symbol
    @semantic (inputs=(dose=(domain=static_domain((50.0, 100.0)),),),) dose::Float64

    prediction_grid()::Matrix{Float64} = fill(dose, 2, 2)
    summary_table()::Vector{Float64} = [dose, study === :north ? 1.0 : 2.0]
    # `dependencies` is direct, not transitive: this reports `summary_table`,
    # never the `study`/`dose` that `summary_table` itself reads.
    headline()::Float64 = first(summary_table())
end

@dynamicstruct struct SiblingAsSemanticInput
    study::Symbol
    @semantic (inputs=(study=(domain=static_domain((:north, :south)),),),) grid() = study
end

struct LegacySemanticMeta end
DynamicObjects.meta(::Type{LegacySemanticMeta}) = [
    :legacy => (;lhs=:legacy, macros=Set{Symbol}(), rhs=:(1), lnn=nothing,
        dependson=Set{Symbol}(), locals=Set{Symbol}(), indices=(),
        indexed=false, cache_version=nothing, doc=nothing),
]

end # @testmodule SemanticFixtures

"""
Documents the stable descriptor schema for fixed, computed, indexed, and
legacy properties, including inferred and declared input domains.
"""
@testitem "semantic property descriptors" tags=[:semantic] setup=[SemanticFixtures] begin
    fixed = property_descriptor(SemanticDescriptorFixture, :enabled)
    @test fixed.role === :input
    @test fixed.output.materialization.tier === :field
    @test fixed.inputs[1].domain.kind === :static
    @test getproperty.(fixed.inputs[1].domain.options, :value) == [false, true]

    enum_input = property_descriptor(SemanticDescriptorFixture, :quality)
    @test getproperty.(enum_input.inputs[1].domain.options, :value) ==
        [draft, final]

    static_input = property_descriptor(SemanticDescriptorFixture, :mode)
    @test static_input.inputs[1].domain.kind === :static
    @test getproperty.(static_input.inputs[1].domain.options, :label) ==
        ["Fast", "Careful"]
    @test static_input.inputs[1].domain.options[2].help == "Use the full solver"

    fit = property_descriptor(SemanticDescriptorFixture, :fit)
    @test fit.role === :operation
    @test fit.indexed
    @test fit.output.type == Vector{Float64}
    @test fit.output.materialization.tier === :serialized
    @test fit.output.materialization.source === :declared
    @test fit.semantics.memoized
    @test fit.semantics.cached
    @test fit.semantics.versioned
    @test !fit.semantics.declared_versioned
    @test fit.semantics.version_dependencies == [:revision]
    @test fit.semantics.invalidation.content_version
    @test fit.semantics.pending
    @test fit.semantics.progress
    @test !fit.semantics.fresh
    @test fit.semantics.cache_version == v"2"
    @test fit.semantics.invalidation.cache_version == v"2"
    dataset = only(filter(input -> input.name === :dataset, fit.inputs))
    @test dataset.domain.kind === :dynamic
    @test dataset.domain.provider === :dataset_options
    @test dataset.domain.dependencies == [:cohort]
    @test only(filter(input -> input.name === :scale, fit.inputs)).kind === :keyword
    provider = property_descriptor(SemanticDescriptorFixture, dataset.domain.provider)
    @test provider.role === :operation
    @test provider.semantics.pending

    version = property_descriptor(SemanticDescriptorFixture, :revision)
    @test version.semantics.versioned
    @test version.semantics.declared_versioned
    @test version.semantics.version_dependencies == [:revision]
    @test version.semantics.invalidation.content_version

    mapped = property_descriptor(SemanticDescriptorFixture, :matrix)
    @test mapped.output.materialization.tier === :mmap
    @test mapped.semantics.mmap
    @test mapped.semantics.versioned
    @test !mapped.semantics.declared_versioned
    @test mapped.semantics.version_dependencies == [:revision]
    @test mapped.semantics.invalidation ==
        (content_version=true, cache_version=nothing)
    @test mapped.semantics.progress_mode === :instrumented
    @test mapped.output.materialization.hints.mmap_eligible

    grid = property_descriptor(
        ComputedVersionedSemanticDescriptorFixture, :prediction_grid)
    @test grid.role === :operation
    @test grid.indexed
    @test grid.output.materialization.tier === :mmap
    @test grid.output.materialization.hints.mmap_eligible
    @test grid.semantics.mmap
    @test grid.semantics.progress
    @test grid.semantics.progress_mode === :instrumented
    @test grid.semantics.versioned
    @test !grid.semantics.declared_versioned
    @test grid.semantics.version_dependencies == [:fixture_version]
    @test grid.semantics.invalidation ==
        (content_version=true, cache_version=nothing)

    fresh_descriptor = property_descriptor(SemanticDescriptorFixture, :preview)
    @test fresh_descriptor.semantics.fresh
    @test !fresh_descriptor.semantics.memoized
    @test !fresh_descriptor.semantics.pending
    @test fresh_descriptor.output.materialization.tier === :recompute

    names = getproperty.(property_descriptors(SemanticDescriptorFixture), :name)
    @test names[1:4] == [:revision, :enabled, :quality, :mode]
    @test :fit in names

    legacy = property_descriptor(LegacySemanticMeta, :legacy)
    @test legacy.name === :legacy
    @test legacy.output.type === nothing
    @test legacy.output.materialization.tier === :memory
    @test !legacy.semantics.versioned
    @test isempty(legacy.semantics.version_dependencies)
end

"""
Checks budget-aware materialization recommendations while preserving an
explicitly declared storage tier over automatic heuristics.
"""
@testitem "budgeted materialization recommendations" tags=[:semantic] setup=[SemanticFixtures] begin
    candidate = property_descriptor(SemanticDescriptorFixture, :candidate)
    mmap_plan = materialization_plan(candidate;
        memory_available_bytes=8 * 1024^2,
        disk_available_bytes=128 * 1024^2)
    @test mmap_plan.tier === :mmap
    @test mmap_plan.automatic
    @test mmap_plan.budgeted

    @test materialization_plan(candidate).tier === :memory
    @test materialization_plan(candidate;
        estimated_bytes=512,
        memory_available_bytes=1024,
        disk_available_bytes=0,
        mmap_eligible=false).tier === :memory
    @test materialization_plan(candidate;
        estimated_bytes=2048,
        compute_seconds=0.01,
        expected_reuse=1,
        memory_available_bytes=1024,
        disk_available_bytes=0).tier === :recompute

    declared = materialization_plan(
        property_descriptor(SemanticDescriptorFixture, :matrix);
        memory_available_bytes=0, disk_available_bytes=0)
    @test declared.tier === :mmap
    @test !declared.automatic
    @test declared.reason === :declared
end

"""
Observes unmaterialized, pending, and ready states without forcing a property,
then verifies that the same progress object remains visible through completion.
"""
@testitem "materialization and Pending observability" tags=[:semantic] setup=[SemanticFixtures] begin
    cache_base = mktempdir()
    o = SemanticDescriptorFixture(1, true, final, :fast;
        __cache_base__=cache_base)

    before = materialization_observation(o, :fit, :n1, :north; scale=2)
    @test before.state === :unmaterialized
    @test before.memory_state === :unmaterialized
    @test before.disk_state === :unstarted

    @test o.fit(:n1, :north; scale=2) == [2.0, 2.0]
    after = materialization_observation(o, :fit, :n1, :north; scale=2)
    @test after.ready
    @test after.stored
    @test after.memory_state === :ready
    @test after.disk_state === :ready
    @test after.value_type == Vector{Float64}
    @test after.estimated_bytes == 16

    mmap_before = materialization_observation(o, :matrix)
    @test mmap_before.disk_state === :unstarted
    @test o.matrix == [1.0 3.0; 2.0 4.0]
    mmap_after = materialization_observation(o, :matrix)
    @test mmap_after.ready
    @test mmap_after.stored
    @test mmap_after.tier === :memory

    @test o.preview(4) == 8
    fresh = materialization_observation(o, :preview, 4)
    @test fresh.state === :fresh
    @test !fresh.ready

    gate = Channel{Nothing}(1)
    pending_object = SemanticPendingFixture(gate)
    pending, status = fetchindex((value, progress) -> (value, progress),
        pending_object.slow, 4)
    @test pending isa Pending
    during = materialization_observation(pending_object, :slow, 4)
    @test during.pending
    @test during.progress === status
    put!(gate, nothing)
    @test fetch(pending) == 5
    done = materialization_observation(pending_object, :slow, 4)
    @test done.ready
    @test done.state === :ready
end

"""
Invalid semantic metadata must fail during introspection while leaving normal
property construction and execution unaffected.
"""
@testitem "semantic metadata validation stays local to introspection" tags=[:semantic] setup=[SemanticFixtures] begin
    err = try
        property_descriptor(BadSemanticInputName, :value)
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("unknown property inputs", sprint(showerror, err))
    @test BadSemanticInputName().value(3) == 3
end

"""
Pins the deduplicated-key contract documented in do-use §6: a shared key tuple
is declared once as fixed fields carrying the option domains, and operations
reach those domains through `dependencies` rather than restating `inputs=`.
"""
@testitem "deduplicated key tuple via fixed-field domains" tags=[:semantic] setup=[SemanticFixtures] begin
    T = DeduplicatedKeyFixture

    # A fixed field is its own single input, keyed by the field's own name.
    for (name, values) in ((:study, [:north, :south]),
                           (:model, [:one_cmt, :two_cmt]),
                           (:dose, [50.0, 100.0]))
        d = property_descriptor(T, name)
        @test d.role === :input
        @test d.fixed
        @test length(d.inputs) == 1
        @test d.inputs[1].name === name
        @test d.inputs[1].kind === :field
        @test d.inputs[1].required
        @test d.inputs[1].domain.kind === :static
        @test getproperty.(d.inputs[1].domain.options, :value) == values
    end

    # Operations restate nothing: no own inputs, siblings via `dependencies`.
    grid = property_descriptor(T, :prediction_grid)
    @test grid.role === :operation
    @test isempty(grid.inputs)
    @test grid.dependencies == [:dose]

    summary = property_descriptor(T, :summary_table)
    @test isempty(summary.inputs)
    @test summary.dependencies == [:dose, :study]

    # `dependencies` is DIRECT, not transitive.
    headline = property_descriptor(T, :headline)
    @test headline.dependencies == [:summary_table]

    # The consumer recipe: resolve an operation's choices off its dependencies.
    resolved = Dict{Symbol,Any}()
    for dep in summary.dependencies
        d = property_descriptor(T, dep)
        d.fixed || continue
        resolved[dep] = getproperty.(d.inputs[1].domain.options, :value)
    end
    @test resolved == Dict(:dose => [50.0, 100.0], :study => [:north, :south])

    o = T(:north, :one_cmt, 100.0)
    @test o.prediction_grid() == fill(100.0, 2, 2)
    @test o.summary_table() == [100.0, 1.0]
    @test o.headline() == 100.0

    # A sibling is NOT addressable as an operation's own `@semantic` input.
    err = try
        property_descriptor(SiblingAsSemanticInput, :grid)
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("unknown property inputs", sprint(showerror, err))
end
