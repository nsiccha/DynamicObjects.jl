using TestItemRunner

@testmodule SemanticFixtures begin
using DynamicObjects
export SemanticQuality, draft, final, SemanticDescriptorFixture,
    SemanticPendingFixture, ComputedVersionedSemanticDescriptorFixture,
    AutomaticSemanticContextFixture, GovernedMaterializationFixture,
    GOVERNED_MATERIALIZATION_CALLS,
    BadSemanticInputName, LegacySemanticMeta,
    DeduplicatedKeyFixture, SiblingAsSemanticInput

@enum SemanticQuality draft final

@dynamicstruct struct AutomaticSemanticContextFixture
    @semantic (inputs=(study=(domain=static_domain((:alpha, :beta)),),),) study::Symbol
    confirmed::Bool

    prepared = (study, confirmed)
    fit(; draws::Int=1000) = (;prepared, draws)
    predict(subject::Int) = (;study, confirmed, subject)
end

const GOVERNED_MATERIALIZATION_CALLS = Threads.Atomic{Int}(0)

@dynamicstruct struct GovernedMaterializationFixture
    @versioned revision::Int
    value::Int
    request = nothing

    @cached compute(scale::Int) = begin
        Threads.atomic_add!(GOVERNED_MATERIALIZATION_CALLS, 1)
        sleep(0.05)
        value * scale
    end
end

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
Promotes transitive fixed-field dependencies into operation inputs
automatically, so shared selections are declared once and never repeated in
dependent operation signatures or metadata.
"""
@testitem "semantic inputs follow the dependency graph" tags=[:semantic] setup=[SemanticFixtures] begin
    prepared = property_descriptor(AutomaticSemanticContextFixture, :prepared)
    @test getproperty.(prepared.inputs, :name) == [:study, :confirmed]
    @test getproperty.(prepared.inputs, :kind) == [:context, :context]

    fit = property_descriptor(AutomaticSemanticContextFixture, :fit)
    @test fit.dependencies == [:prepared]
    @test fit.dependency_closure == [:study, :confirmed, :prepared]
    @test getproperty.(fit.inputs, :name) == [:study, :confirmed, :draws]
    @test getproperty.(fit.inputs[1:2], :kind) == [:context, :context]
    @test getproperty.(fit.inputs[1].domain.options, :value) == [:alpha, :beta]
    @test getproperty.(fit.inputs[2].domain.options, :value) == [false, true]
    @test fit.inputs[1].source == (;
        type=AutomaticSemanticContextFixture,
        property=:study,
    )
    @test fit.inputs[1].scope === :object
    @test fit.inputs[3].kind === :keyword
    @test fit.inputs[3].default == 1000

    # The shared inputs are absent from both call signatures: dependency
    # analysis, not a fragment reference or duplicated route arg, supplied them.
    fit_signature = property_signature(AutomaticSemanticContextFixture, :fit)
    @test isempty(fit_signature.positional)
    @test getproperty.(fit_signature.kwargs, :name) == [:draws]
    predict_signature = property_signature(
        AutomaticSemanticContextFixture, :predict)
    @test getproperty.(predict_signature.positional, :name) == [:subject]
    @test getproperty.(property_descriptor(
        AutomaticSemanticContextFixture, :predict).inputs, :name) ==
        [:study, :confirmed, :subject]
end

"""
Executes through ordinary DO caches while pinning framework-only ownership,
then proves release waits for reachability and never adopts a pre-existing
directory. Identity/version and retention remain reflected in the lifecycle.
"""
@testitem "governed materialization execution and GC" tags=[:semantic] setup=[SemanticFixtures] begin
    GOVERNED_MATERIALIZATION_CALLS[] = 0
    cache_base = mktempdir()
    context = (;
        scope=:job,
        key=(;mount="/study", job=:one),
        retention=(;max_entries=1, ttl=60.0),
    )

    owned_path, owned_handle, owned_marker = let
        retained = GovernedMaterializationFixture(1, 7;
            __cache_base__=cache_base,
            __hold_recent_version__=false)
        object = remount(retained; request=:current_request)
        path = object.__cache_path__
        @test !ispath(path)

        first_task = Threads.@spawn execute_materialization(
            context, object, :compute, 3)
        second_task = Threads.@spawn execute_materialization(
            context, object, :compute, 3)
        @test fetch(first_task) == 21
        @test fetch(second_task) == 21
        @test GOVERNED_MATERIALIZATION_CALLS[] == 1
        first_task = second_task = nothing

        ownership = materialization_ownership(context, object)
        @test ownership.state === :active
        @test ownership.scope === :job
        @test ownership.identity == object.__identity_hash__
        @test ownership.version == object.__version_tag__
        @test ownership.retention == (;max_entries=1, ttl=60.0)
        @test ownership.active == 0
        @test ownership.reachable
        @test ownership.owned_paths == [abspath(path)]
        @test isfile(joinpath(path, "compute_3.sjl"))

        wrong_context = merge(context, (;key=(;mount="/study", job=:other)))
        @test release_materialization!(wrong_context, retained;
            reason=:lru).state === :unowned
        # Execution used the request remount; provider release carries the
        # retained source root. Both resolve to the same shared-cache owner.
        released = release_materialization!(context, retained; reason=:lru)
        @test released.state === :deferred
        @test materialization_ownership(context, object).release_reason === :lru

        marker = joinpath(path, ".dynamicobjects-owner")
        (path, WeakRef(getfield(retained, :cache).cache.cache), marker)
    end

    GC.gc(); GC.gc()
    @test owned_handle.value === nothing
    collected = materialization_gc!()
    @test abspath(owned_path) in collected.deleted_paths
    @test !ispath(owned_path)
    @test !ispath(owned_marker)

    # A new @versioned value gets a distinct governed path under the same
    # logical identity. Nothing is configured beyond the ordinary DO field.
    v1 = GovernedMaterializationFixture(1, 9;
        __cache_base__=cache_base, __hold_recent_version__=false)
    v2 = GovernedMaterializationFixture(2, 9;
        __cache_base__=cache_base, __hold_recent_version__=false)
    @test v1.__identity_hash__ == v2.__identity_hash__
    @test v1.__version_tag__ != v2.__version_tag__
    @test v1.__cache_path__ != v2.__cache_path__

    # Existing storage is deliberately not adopted. The operation may use it,
    # but release/GC reports it as preserved and leaves the user's file alone.
    unowned_context = (;
        scope=:job,
        key=(;mount="/study", job=:preexisting),
        retention=(;max_entries=1, ttl=60.0),
    )
    unowned_path, unowned_file, unowned_handle = let
        object = GovernedMaterializationFixture(3, 11;
            __cache_base__=cache_base, __hold_recent_version__=false)
        path = object.__cache_path__
        mkpath(path)
        user_file = joinpath(path, "user-owned.txt")
        write(user_file, "keep")
        @test execute_materialization(
            unowned_context, object, :compute, 2) == 22
        ownership = materialization_ownership(unowned_context, object)
        @test ownership.owned_paths == String[]
        @test ownership.unowned_paths == [abspath(path)]
        @test release_materialization!(unowned_context, object;
            reason=:ttl).state === :deferred
        (path, user_file, WeakRef(getfield(object, :cache).cache.cache))
    end

    GC.gc(); GC.gc()
    @test unowned_handle.value === nothing
    preserved = materialization_gc!()
    @test abspath(unowned_path) in preserved.preserved_paths
    @test isfile(unowned_file)
    @test read(unowned_file, String) == "keep"
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
Pins the zero-configuration deduplicated-key contract: a shared key tuple is
declared once as fixed fields carrying the option domains, and dependent
operations receive effective context inputs without restating `inputs=`.
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

    # Operations restate nothing. Their signatures stay empty while descriptors
    # promote the fixed dependencies into effective context inputs.
    grid = property_descriptor(T, :prediction_grid)
    @test grid.role === :operation
    @test grid.dependencies == [:dose]
    @test grid.dependency_closure == [:dose]
    @test getproperty.(grid.inputs, :name) == [:dose]
    @test only(grid.inputs).kind === :context

    summary = property_descriptor(T, :summary_table)
    @test summary.dependencies == [:dose, :study]
    @test summary.dependency_closure == [:study, :dose]
    @test getproperty.(summary.inputs, :name) == [:study, :dose]
    @test all(input -> input.kind === :context, summary.inputs)

    # `dependencies` stays direct; `dependency_closure` is transitive and the
    # effective inputs have already been expanded from it.
    headline = property_descriptor(T, :headline)
    @test headline.dependencies == [:summary_table]
    @test headline.dependency_closure == [:study, :dose, :summary_table]
    @test getproperty.(headline.inputs, :name) == [:study, :dose]

    # Consumers read the effective inputs directly; no graph walk or fragment
    # registry is required merely to reconstruct the shared choices.
    resolved = Dict(input.name =>
        getproperty.(input.domain.options, :value) for input in summary.inputs)
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
