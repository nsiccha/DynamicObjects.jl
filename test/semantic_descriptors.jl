using TestItemRunner

@testmodule SemanticFixtures begin
using DynamicObjects
export SemanticQuality, draft, final, SemanticDescriptorFixture,
    SemanticPendingFixture, ComputedVersionedSemanticDescriptorFixture,
    AutomaticSemanticContextFixture, GovernedMaterializationFixture,
    GOVERNED_MATERIALIZATION_CACHE_BASE,
    GOVERNED_MATERIALIZATION_CALLS, GOVERNED_MMAP_CALLS,
    GOVERNED_SERIAL_CALLS,
    GovernedLazyColumns, GovernedNestedFixture, GovernedScopeFixture,
    GOVERNED_POLICY_CALLS, MisclaimedColumn, OwnFormatPayload,
    GovernedPolicyFixture, GovernedDefaultBaseFixture,
    LegacySemanticMeta, DeduplicatedKeyFixture

@enum SemanticQuality draft final

@dynamicstruct struct AutomaticSemanticContextFixture
    study::Symbol
    confirmed::Bool

    prepared = (study, confirmed)
    fit(; draws::Int=1000) = (;prepared, draws)
    predict(subject::Int) = (;study, confirmed, subject)
end

const GOVERNED_MATERIALIZATION_CALLS = Threads.Atomic{Int}(0)
const GOVERNED_MMAP_CALLS = Threads.Atomic{Int}(0)
const GOVERNED_SERIAL_CALLS = Threads.Atomic{Int}(0)
const GOVERNED_MATERIALIZATION_CACHE_BASE = Ref("cache")

@dynamicstruct struct GovernedMaterializationFixture
    @versioned revision::Int
    value::Int
    request = nothing
    __cache_base__ = GOVERNED_MATERIALIZATION_CACHE_BASE[]
    __hold_recent_version__ = false

    compute(scale::Int) = begin
        Threads.atomic_add!(GOVERNED_MATERIALIZATION_CALLS, 1)
        sleep(0.05)
        value * scale
    end
    callsite_probe(scale::Int) = begin
        call = Threads.atomic_add!(GOVERNED_MATERIALIZATION_CALLS, 1) + 1
        (value * scale, call)
    end
    @fresh fresh_compute(scale::Int) = value * scale

    large_array(scale::Int)::Vector{Float64} = begin
        Threads.atomic_add!(GOVERNED_MMAP_CALLS, 1)
        fill(Float64(value * scale), 1 + (1024 * 1024) ÷ sizeof(Float64))
    end

    large_text(scale::Int)::String = begin
        Threads.atomic_add!(GOVERNED_SERIAL_CALLS, 1)
        repeat(string(value * scale), 1 + 1024 * 1024)
    end
end

const GOVERNED_LARGE_LENGTH = 1 + (1024 * 1024) ÷ sizeof(Float64)

# Declares no `__cache_base__`, so its cache path is DO's cwd-relative default.
@dynamicstruct struct GovernedDefaultBaseFixture
    value::Int

    compute(scale::Int) = value * scale
    large(scale::Int)::Vector{Float64} =
        fill(Float64(value * scale), GOVERNED_LARGE_LENGTH)
end

# A lazy column-concatenation view over arrays it does not own — the shape of a
# pooled view over per-chain memory-mapped matrices.
struct GovernedLazyColumns <: AbstractMatrix{Float64}
    columns::Vector{Vector{Float64}}
end
Base.size(m::GovernedLazyColumns) = (length(first(m.columns)), length(m.columns))
Base.getindex(m::GovernedLazyColumns, i::Int, j::Int) = m.columns[j][i]

@dynamicstruct struct GovernedNestedFixture
    value::Int
    __cache_base__ = GOVERNED_MATERIALIZATION_CACHE_BASE[]

    large = fill(Float64(value), GOVERNED_LARGE_LENGTH)
    @struct part = begin
        heavy = fill(2.0 * value, GOVERNED_LARGE_LENGTH)
        lazy = GovernedLazyColumns([large, heavy])
    end
end

@dynamicstruct struct GovernedScopeFixture
    value::Int
    __cache_base__ = GOVERNED_MATERIALIZATION_CACHE_BASE[]

    nested = GovernedNestedFixture(value)
    @struct own_part = begin
        heavy = fill(3.0 * value, GOVERNED_LARGE_LENGTH)
    end

    total(scale::Int) =
        scale * (sum(nested.large) + sum(nested.part.heavy) + sum(own_part.heavy))
    lazy_view(scale::Int) = nested.part.lazy
    @fresh fresh_lazy_view(scale::Int) = nested.part.lazy
end

const GOVERNED_POLICY_CALLS = Threads.Atomic{Int}(0)

# An array type with its own mmap `save` that does not round-trip its type: it
# writes its backing data in DO's array format, so it reloads as a bare Vector
# (the shape of a `TreeData` whose leaves are views).
struct MisclaimedColumn <: AbstractVector{Float64}
    data::Vector{Float64}
end
Base.size(column::MisclaimedColumn) = size(column.data)
Base.getindex(column::MisclaimedColumn, i::Int) = column.data[i]
DynamicObjects.save(::Val{:mmap}, path::AbstractString, column::MisclaimedColumn) =
    DynamicObjects.save(Val(:mmap), path, column.data)

# A non-array type with its own type-preserving mmap container, registered the
# way TreeArrays registers `TreeData`: no eligibility declaration beyond `save`.
struct OwnFormatPayload
    values::Vector{Float64}
end
Base.:(==)(a::OwnFormatPayload, b::OwnFormatPayload) = a.values == b.values
const OWN_FORMAT_MAGIC = collect(codeunits("DOOWNFMT"))
function DynamicObjects.save(::Val{:mmap}, path::AbstractString, payload::OwnFormatPayload)
    open(path, "w") do io
        write(io, OWN_FORMAT_MAGIC)
        DynamicObjects.save(Val(:mmap), io, payload.values)
    end
    nothing
end
DynamicObjects.load(::Val{:mmap}, path::AbstractString, ::Type{OwnFormatPayload}) =
    open(path, "r") do io
        read(io, length(OWN_FORMAT_MAGIC)) == OWN_FORMAT_MAGIC ||
            error("not an OwnFormatPayload container")
        OwnFormatPayload(DynamicObjects.load(Val(:mmap), io, nothing;
            end_offset=filesize(io)))
    end
DynamicObjects.register_mmap_container!(OWN_FORMAT_MAGIC,
    path -> DynamicObjects.load(Val(:mmap), path, OwnFormatPayload))

@dynamicstruct struct GovernedPolicyFixture
    value::Int
    __cache_base__ = GOVERNED_MATERIALIZATION_CACHE_BASE[]

    slow_small(scale::Int)::Vector{Float64} = begin
        sleep(1.1)
        [Float64(value * scale)]
    end
    misclaimed(scale::Int) =
        MisclaimedColumn(fill(Float64(value * scale), GOVERNED_LARGE_LENGTH))
    own_format(scale::Int) =
        OwnFormatPayload(fill(Float64(value * scale), GOVERNED_LARGE_LENGTH))
    plain(scale::Int)::Vector{Float64} = begin
        Threads.atomic_add!(GOVERNED_POLICY_CALLS, 1)
        fill(Float64(value * scale), GOVERNED_LARGE_LENGTH)
    end
end

@dynamicstruct struct SemanticDescriptorFixture
    @versioned revision::Int
    enabled::Bool
    quality::SemanticQuality
    mode::Symbol

    @cached v"2" fit(dataset::Symbol, cohort::Symbol; scale::Int=1)::Vector{Float64} =
        fill(Float64(scale), dataset === :n1 ? 2 : 1)

    @mmap @progress matrix::Matrix{Float64} = reshape(collect(1.0:4.0), 2, 2)

    @fresh preview(x::Int) = 2x
end

@dynamicstruct struct SemanticPendingFixture
    gate::Channel{Nothing}
    slow(x::Int) = (take!(gate); x + 1)
end

@dynamicstruct struct ComputedVersionedSemanticDescriptorFixture
    @versioned fixture_version = "synthetic_depot_v1"

    @mmap @progress prediction_grid(
        study::Symbol,
        model::Symbol,
        dose::Float64=100.0,
    )::Matrix{Float64} = fill(dose, 2, 2)
end

# A key tuple shared by several operations lives once as fixed fields; the
# operations read them as bare siblings.
@dynamicstruct struct DeduplicatedKeyFixture
    study::Symbol
    model::Symbol
    dose::Float64

    prediction_grid()::Matrix{Float64} = fill(dose, 2, 2)
    summary_table()::Vector{Float64} = [dose, study === :north ? 1.0 : 2.0]
    # `dependencies` is direct, not transitive: this reports `summary_table`,
    # never the `study`/`dose` that `summary_table` itself reads.
    headline()::Float64 = first(summary_table())
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
legacy properties, including type-inferred input domains.
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

    unrestricted = property_descriptor(SemanticDescriptorFixture, :mode)
    @test unrestricted.inputs[1].domain.kind === :unrestricted
    @test isempty(unrestricted.inputs[1].domain.options)

    # Framework consumers can normalize already-known option data without
    # imposing an application naming or annotation convention.
    normalized = static_domain((
        (value=:fast, label="Fast"),
        (value=:careful, label="Careful", help="Use the full solver"),
    ))
    @test getproperty.(normalized.options, :label) == ["Fast", "Careful"]
    @test normalized.options[2].help == "Use the full solver"

    fit = property_descriptor(SemanticDescriptorFixture, :fit)
    @test fit.role === :operation
    @test fit.indexed
    @test fit.output.type == Vector{Float64}
    @test fit.output.materialization.tier === :serialized
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
    @test dataset.domain.kind === :unrestricted
    @test only(filter(input -> input.name === :scale, fit.inputs)).kind === :keyword

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

    grid = property_descriptor(
        ComputedVersionedSemanticDescriptorFixture, :prediction_grid)
    @test grid.role === :operation
    @test grid.indexed
    @test grid.output.materialization.tier === :mmap
    @test grid.inputs[1].name === :study
    @test grid.inputs[1].domain.kind === :unrestricted
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
    @test legacy.output.materialization.tier === :automatic
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
    @test getproperty.(fit.inputs, :name) == [:study, :confirmed, :draws]
    @test getproperty.(fit.inputs[1:2], :kind) == [:context, :context]
    @test fit.inputs[1].domain.kind === :unrestricted
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
    GOVERNED_MMAP_CALLS[] = 0
    GOVERNED_SERIAL_CALLS[] = 0
    cache_base = mktempdir()
    GOVERNED_MATERIALIZATION_CACHE_BASE[] = cache_base
    context = (;
        scope=:job,
        key=(;mount="/study", job=:one),
        retention=(;max_entries=1, ttl=60.0),
    )

    owned_path, owned_handle, owned_marker = let
        retained = GovernedMaterializationFixture(1, 7)
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
        # A result kept in memory stores nothing, so the root's directory is
        # not claimed (or created) yet.
        @test ownership.owned_paths == String[]
        @test !ispath(path)
        @test property_descriptor(
            GovernedMaterializationFixture,
            :compute).output.materialization.tier === :automatic
        # Duration is the non-compilation portion of first-hit wall time. A
        # trivial scalar must not become a disk entry just because Julia had to
        # compile its property method on first use.
        @test !isfile(DynamicObjects.get_cache_path(object, :compute, 3))
        @test DynamicObjects._effective_compute_seconds(
            41_500_000_000, 41_450_000_000) ≈ 0.05
        @test DynamicObjects._effective_compute_seconds(1, 2) == 0.0

        # No marker is needed for either disk format. The governed executor
        # chooses mmap for a large isbits array and serialization for a large
        # non-mmap value from their observed runtime values.
        mapped = execute_materialization(context, object, :large_array, 2)
        @test length(mapped) == 1 + (1024 * 1024) ÷ sizeof(Float64)
        @test all(==(14.0), mapped)
        mapped_path = DynamicObjects.get_cache_path(object, :large_array, 2)
        @test isfile(mapped_path)
        @test isfile(mapped_path * ".auto")
        @test materialization_observation(
            object, :large_array, 2).tier === :mmap
        # The first disk write claimed the root's directory.
        @test materialization_ownership(context, object).owned_paths ==
            [abspath(path)]

        text = execute_materialization(context, object, :large_text, 2)
        @test startswith(text, "14")
        serialized_path = DynamicObjects.get_cache_path(object, :large_text, 2)
        @test isfile(serialized_path)
        @test isfile(serialized_path * ".auto")
        @test materialization_observation(
            object, :large_text, 2).tier === :serialized

        clear_mem_caches!(object)
        @test execute_materialization(
            context, object, :large_array, 2) == mapped
        @test execute_materialization(context, object, :large_text, 2) == text
        @test GOVERNED_MMAP_CALLS[] == 1
        @test GOVERNED_SERIAL_CALLS[] == 1

        wrong_context = merge(context, (;key=(;mount="/study", job=:other)))
        @test release_materialization!(wrong_context, retained;
            reason=:lru).state === :unowned
        # Execution used the request remount; provider release carries the
        # retained source root. Both resolve to the same shared-cache owner.
        released = release_materialization!(context, retained; reason=:lru)
        @test released.state === :deferred
        @test materialization_ownership(context, object).release_reason === :lru

        marker = joinpath(path, ".dynamicobjects-owner")
        handle = WeakRef(getfield(retained, :cache).cache.cache)
        retained = object = nothing
        (path, handle, marker)
    end

    GC.gc(); GC.gc()
    @test owned_handle.value === nothing
    collected = materialization_gc!()
    @test abspath(owned_path) in collected.deleted_paths
    @test !ispath(owned_path)
    @test !ispath(owned_marker)

    # A new @versioned value gets a distinct governed path under the same
    # logical identity. Nothing is configured beyond the ordinary DO field.
    v1 = GovernedMaterializationFixture(1, 9)
    v2 = GovernedMaterializationFixture(2, 9)
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
        object = GovernedMaterializationFixture(3, 11)
        path = object.__cache_path__
        mkpath(path)
        user_file = joinpath(path, "user-owned.txt")
        write(user_file, "keep")
        @test execute_materialization(
            unowned_context, object, :compute, 2) == 22
        # Nothing was stored, so no claim was attempted yet.
        @test materialization_ownership(
            unowned_context, object).unowned_paths == String[]
        # A promotion attempt finds the pre-existing directory and leaves it
        # alone: the large value stays in memory and nothing is written there.
        @test all(==(22.0), execute_materialization(
            unowned_context, object, :large_array, 2))
        @test !isfile(DynamicObjects.get_cache_path(object, :large_array, 2))
        @test !ispath(joinpath(path, ".dynamicobjects-owner"))
        ownership = materialization_ownership(unowned_context, object)
        @test ownership.owned_paths == String[]
        @test ownership.unowned_paths == [abspath(path)]
        @test release_materialization!(unowned_context, object;
            reason=:ttl).state === :deferred
        handle = WeakRef(getfield(object, :cache).cache.cache)
        object = nothing
        (path, user_file, handle)
    end

    GC.gc(); GC.gc()
    @test unowned_handle.value === nothing
    preserved = materialization_gc!()
    @test abspath(unowned_path) in preserved.preserved_paths
    @test isfile(unowned_file)
    @test read(unowned_file, String) == "keep"
end

@testitem "governed execution keeps fetch selectors out of storage keys" tags=[:semantic] setup=[SemanticFixtures] begin
    using DynamicObjects

    GOVERNED_MATERIALIZATION_CALLS[] = 0
    GOVERNED_MATERIALIZATION_CACHE_BASE[] = mktempdir()
    object = GovernedMaterializationFixture(1, 7)
    context = (;scope=:session, key="deferred-execution", retention=(;max_entries=1, ttl=nothing))
    queue = DeferredCompute[]
    stop = Base.Event()
    running = Threads.@spawn wait(stop)
    try
        @test timedwait(() -> istaskstarted(running), 5.0) === :ok
        # A request-owned executor can close over a running Task. It must only
        # select how the computation starts, never enter the persistent key.
        selector = Deferred(d -> (istaskstarted(running); push!(queue, d)))
        pending = execute_materialization(context, object, :compute, 3; fetch=selector)
        @test pending isa Pending
        @test !isready(pending)
        @test length(queue) == 1

        # A fresh operation has no selector to forward. Its default call
        # must remain keyword-free at the indexed property boundary.
        @test execute_materialization(context, object, :fresh_compute, 5) == 35

        another = execute_materialization(context, object, :compute, 3;
            fetch=Deferred(d -> error("the same application key was queued twice")))
        @test another isa Pending
        @test length(queue) == 1

        @test DynamicObjects.run!(only(queue))
        @test fetch(pending) == 21
        @test fetch(another) == 21
        @test GOVERNED_MATERIALIZATION_CALLS[] == 1
        @test execute_materialization(context, object, :compute, 3;
            fetch=selector) == 21
        @test !isfile(DynamicObjects.get_cache_path(object, :compute, 3))

        # HTMXObjects omits the selector for declaration-site @fresh. The
        # corresponding direct computation returns values but queues nothing
        # and runs again for the same application arguments.
        @test (fresh(object.compute, 4), fresh(object.compute, 4)) == (28, 28)
        @test GOVERNED_MATERIALIZATION_CALLS[] == 3
        @test length(queue) == 1
    finally
        notify(stop)
        wait(running)
    end
end

@testitem "governed callback preserves explicit fresh execution" tags=[:semantic] setup=[SemanticFixtures] begin
    using DynamicObjects

    GOVERNED_MATERIALIZATION_CALLS[] = 0
    GOVERNED_MATERIALIZATION_CACHE_BASE[] = mktempdir()
    object = GovernedMaterializationFixture(1, 7)
    context = (;scope=:session, key="callsite-fresh", retention=(;max_entries=1, ttl=nothing))

    cached = object.callsite_probe(2)
    @test cached == (14, 1)
    @test materialization_ownership(context, object).state === :unowned

    uncached = execute_materialization(context, object) do
        ownership = materialization_ownership(context, object)
        @test ownership.state === :active
        @test ownership.active == 1
        (
            fresh(object.callsite_probe, 2),
            maybeprogress!(nothing, object.callsite_probe, 2),
        )
    end
    @test uncached == ((14, 2), (14, 3))

    ownership = materialization_ownership(context, object)
    @test ownership.state === :active
    @test ownership.active == 0
    # The callback form stores nothing, so it claims no directory.
    @test ownership.owned_paths == String[]
    @test !ispath(object.__cache_path__)
    @test object.callsite_probe(2) == cached
    @test GOVERNED_MATERIALIZATION_CALLS[] == 3
    @test !isfile(DynamicObjects.get_cache_path(object, :callsite_probe, 2))

    @test_throws ErrorException execute_materialization(context, object) do
        @test materialization_ownership(context, object).active == 1
        error("callback failure")
    end
    @test materialization_ownership(context, object).active == 0
end

"""
DO's default `__cache_base__` is relative to the process cwd, so a service whose
cwd is its deployment checkout must not gain a `cache/` directory from governed
executions that store nothing (snag `run-an-htmxobjec-9153c247`). Such an
owner must not contest the directory either: a later owner that does store
still claims it and promotes.
"""
@testitem "governed execution that stores nothing writes no files" tags=[:semantic] setup=[SemanticFixtures] begin
    using DynamicObjects

    cwd = mktempdir()
    cd(cwd) do
        object = GovernedDefaultBaseFixture(7)
        @test !isabspath(object.__cache_path__)

        # HTMXObjects' default provider: a fresh root per request, which never
        # stores — not even a large value.
        request = (;scope=:request, key="", retention=nothing)
        @test execute_materialization(request, object, :compute, 3) == 21
        @test all(==(7.0), execute_materialization(request, object, :large, 1))
        @test execute_materialization(request, object) do
            fresh(object.compute, 4)
        end == 28
        retained = (;
            scope=:session, key="default-base",
            retention=(;max_entries=1, ttl=nothing),
        )
        @test execute_materialization(retained, object, :compute, 5) == 35
        @test isempty(readdir(cwd))
        @test materialization_ownership(request, object).owned_paths == String[]
        @test materialization_ownership(retained, object).owned_paths == String[]

        @test all(==(14.0), execute_materialization(retained, object, :large, 2))
        path = abspath(object.__cache_path__)
        large_path = abspath(DynamicObjects.get_cache_path(object, :large, 2))
        @test isfile(large_path)
        @test isfile(large_path * ".auto")
        ownership = materialization_ownership(retained, object)
        @test ownership.owned_paths == [path]
        @test strip(read(joinpath(path, ".dynamicobjects-owner"), String)) ==
            ownership.owner
    end
end

"""
Pins the scope of automatic storage: only the executed property's own returned
value is observed. Large unmarked properties it reads on a nested DO object or
an `@struct` child stay in ordinary memory memoization, and a lazy array view
the operation returns keeps its type instead of being densified into an mmap.
"""
@testitem "governed materialization scope and lazy views" tags=[:semantic] setup=[SemanticFixtures] begin
    cache_base = mktempdir()
    GOVERNED_MATERIALIZATION_CACHE_BASE[] = cache_base
    context = (;
        scope=:job,
        key=(;mount="/scope", job=:one),
        retention=(;max_entries=1, ttl=60.0),
    )
    automatic_entries() = sort!([basename(file)
        for (dir, _, files) in walkdir(cache_base) for file in files
        if endswith(file, ".auto")])

    root = GovernedScopeFixture(2)
    n = length(root.nested.large)
    @test n * sizeof(Float64) > 1024 * 1024
    @test execute_materialization(context, root, :total, 3) ==
        3 * n * (2.0 + 4.0 + 6.0)
    # Every value the operation read is over the 1 MiB promotion threshold, yet
    # none of them was executed by the host, so none is governed.
    for (object, name) in (
            (root.nested, :large),
            (root.nested.part, :heavy),
            (root.own_part, :heavy))
        observed = materialization_observation(object, name)
        @test observed.tier === :memory
        @test observed.ready
        @test !observed.stored
    end
    @test all(entry -> startswith(entry, "total_"), automatic_entries())

    # The executed property's own large result is promoted — but a lazy view
    # keeps its type: it serializes rather than becoming a dense mmapped Matrix.
    view = execute_materialization(context, root, :lazy_view, 1)
    @test view isa GovernedLazyColumns
    @test size(view) == (n, 2)
    observed = materialization_observation(root, :lazy_view, 1)
    @test observed.stored
    @test observed.tier === :serialized
    clear_mem_caches!(root)
    reloaded = execute_materialization(context, root, :lazy_view, 1)
    @test reloaded isa GovernedLazyColumns
    @test reloaded == view

    # A plain Array result still memory-maps (pinned with `large_array` above);
    # declaration-site `@fresh` opts the executed property out entirely.
    fresh_view = execute_materialization(context, root, :fresh_lazy_view, 1)
    @test fresh_view isa GovernedLazyColumns
    @test !materialization_observation(root, :fresh_lazy_view, 1).stored
    @test !any(entry -> startswith(entry, "fresh_lazy_view_"), automatic_entries())
end

"""
Pins the storage policy: automatic storage may change where a value lives but
never its type, and memory-maps only values large enough to benefit. A small
result promoted for its compute time serializes; a codec that would reload a
different type is never used; an entry that cannot prove its recorded type is
recomputed rather than served.
"""
@testitem "governed materialization keeps types and maps only large values" tags=[:semantic] setup=[SemanticFixtures] begin
    using Logging
    cache_base = mktempdir()
    GOVERNED_MATERIALIZATION_CACHE_BASE[] = cache_base
    GOVERNED_POLICY_CALLS[] = 0
    context = (;
        scope=:job,
        key=(;mount="/policy", job=:one),
        retention=(;max_entries=1, ttl=60.0),
    )
    object = GovernedPolicyFixture(2)

    # Slow but tiny: promoted for its compute time, serialized rather than mapped.
    @test execute_materialization(context, object, :slow_small, 3) == [6.0]
    small = materialization_observation(object, :slow_small, 3)
    @test small.stored
    @test small.tier === :serialized

    # A type's own mmap format makes it eligible with no other declaration;
    # DO's generic array writer and the untyped fallback do not.
    @test DynamicObjects._automatic_mmap_eligible(
        OwnFormatPayload(Float64[]))
    @test DynamicObjects._automatic_mmap_eligible(Float64[])
    @test !DynamicObjects._automatic_mmap_eligible(view(Float64[1, 2], 1:1))
    @test !DynamicObjects._automatic_mmap_eligible("not mappable")
    own = execute_materialization(context, object, :own_format, 1)
    @test own isa OwnFormatPayload
    @test materialization_observation(object, :own_format, 1).tier === :mmap
    clear_mem_caches!(object)
    reloaded = execute_materialization(context, object, :own_format, 1)
    @test reloaded isa OwnFormatPayload
    @test reloaded == own

    # A format that does not round-trip the value's type is caught on write.
    misclaimed = @test_logs (:warn, r"serializing instead") match_mode=:any execute_materialization(
        context, object, :misclaimed, 1)
    @test misclaimed isa MisclaimedColumn
    @test materialization_observation(object, :misclaimed, 1).tier === :serialized
    clear_mem_caches!(object)
    @test execute_materialization(context, object, :misclaimed, 1) isa MisclaimedColumn

    # A large plain Array still maps, and its metadata records the computed type.
    @test execute_materialization(context, object, :plain, 1) isa Vector{Float64}
    @test GOVERNED_POLICY_CALLS[] == 1
    @test materialization_observation(object, :plain, 1).tier === :mmap
    path = DynamicObjects.get_cache_path(object, :plain, 1)
    metadata = DynamicObjects._automatic_materialization_metadata(path)
    @test metadata.value_type === Vector{Float64}

    # A legacy mmap entry (no recorded type) may hold a densified wrapper, so it
    # is recomputed once and rewritten with its type; the rewrite is trusted.
    legacy = Base.structdiff(metadata, NamedTuple{(:value_type,)})
    clear_mem_caches!(object)
    GC.gc(); GC.gc()
    DynamicObjects._atomic_save(Val(:serial), path * ".auto", legacy)
    @test @test_logs (:warn, r"does not reload as its computed type") match_mode=:any execute_materialization(
        context, object, :plain, 1) isa Vector{Float64}
    @test GOVERNED_POLICY_CALLS[] == 2
    @test DynamicObjects._automatic_materialization_metadata(
        path).value_type === Vector{Float64}
    clear_mem_caches!(object)
    @test execute_materialization(context, object, :plain, 1) isa Vector{Float64}
    @test GOVERNED_POLICY_CALLS[] == 2
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
    @test mmap_after.tier === :mmap

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

@testitem "@semantic metadata is removed" tags=[:semantic] begin
    using DynamicObjects
    err = try
        macroexpand(@__MODULE__, :(
            @dynamicstruct struct RemovedSemanticFixture
                @semantic (inputs=(;),) value(x::Int) = x
            end
        ))
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("@semantic was removed", sprint(showerror, err))
end

"""
Pins the zero-configuration deduplicated-key contract: a shared key tuple is
declared once as fixed fields, and dependent operations receive effective
context inputs without extra metadata.
"""
@testitem "deduplicated key tuple via fixed fields" tags=[:semantic] setup=[SemanticFixtures] begin
    T = DeduplicatedKeyFixture

    # A fixed field is its own single input, keyed by the field's own name.
    for name in (:study, :model, :dose)
        d = property_descriptor(T, name)
        @test d.role === :input
        @test d.fixed
        @test length(d.inputs) == 1
        @test d.inputs[1].name === name
        @test d.inputs[1].kind === :field
        @test d.inputs[1].required
        @test d.inputs[1].domain.kind === :unrestricted
    end

    # Operations restate nothing. Their signatures stay empty while descriptors
    # promote the fixed dependencies into effective context inputs.
    grid = property_descriptor(T, :prediction_grid)
    @test grid.role === :operation
    @test grid.dependencies == [:dose]
    @test getproperty.(grid.inputs, :name) == [:dose]
    @test only(grid.inputs).kind === :context

    summary = property_descriptor(T, :summary_table)
    @test summary.dependencies == [:dose, :study]
    @test getproperty.(summary.inputs, :name) == [:study, :dose]
    @test all(input -> input.kind === :context, summary.inputs)

    # `dependencies` stays direct while effective context inputs have already
    # been expanded transitively.
    headline = property_descriptor(T, :headline)
    @test headline.dependencies == [:summary_table]
    @test getproperty.(headline.inputs, :name) == [:study, :dose]

    o = T(:north, :one_cmt, 100.0)
    @test o.prediction_grid() == fill(100.0, 2, 2)
    @test o.summary_table() == [100.0, 1.0]
    @test o.headline() == 100.0
end
