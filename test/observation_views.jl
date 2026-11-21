using TestItemRunner

# `@is_cached` reads the disk entry only; `materialization_observation` is the
# non-computing probe for an entry in memory or in flight, and on a `remount`
# view it reads an indexed entry where the view's next read would find it
# (snag `do-use-is-cached-240dfced`).
@testmodule ObservationViewFixtures begin
using DynamicObjects
export ObservedViewApp, OBSERVED_GATE, SizeProbe, StateProbeApp

const OBSERVED_GATE = Ref{Any}(nothing)
_observed_opaque(app, n) = n * 100
_observed_opaque_context(app, n) = (app.ctx, n)

@dynamicstruct struct ObservedViewApp
    base::Float64
    ctx = nothing
    stage(dose, shift) = base * dose + shift
    per_view(n) = (ctx, n)
    opaque(n) = _observed_opaque(__self__, n)
    opaque_context(n) = _observed_opaque_context(__self__, n)
    @cached stored(n) = base * n
    slow(n) = (take!(OBSERVED_GATE[]); n)
    gate_is_cached(doses) = [@is_cached(__self__.stage(d, -50.0)) for d in doses]
    gate_observed(doses) = [materialization_state(__self__, :stage, d, -50.0) for d in doses]
end

struct SizeProbe
    calls::Base.RefValue{Int}
end
function Base.summarysize(probe::SizeProbe)
    probe.calls[] += 1
    123
end

@dynamicstruct struct StateProbeApp
    payload::SizeProbe
    scalar = payload
    item(n; bytes) = bytes ? payload : nothing
    broken(n) = error("failed to compute")
    @fresh preview() = 1
end
end

@testitem "@is_cached reads disk; materialization_observation reads memory" tags=[:semantic] setup=[ObservationViewFixtures] begin
    using DynamicObjects
    o = ObservedViewApp(2.0; __cache_base__ = mktempdir())
    doses = [1.0, 2.0]
    @test o.gate_observed(doses) == [:unmaterialized, :unmaterialized]
    @test [o.stage(d, -50.0) for d in doses] == [-48.0, -46.0]

    # A memory-only entry is never on disk, however often it was computed.
    @test !@is_cached(o.stage(1.0, -50.0))
    @test @cache_status(o.stage(1.0, -50.0)) === :unstarted
    @test @fresh(o.gate_is_cached(doses)) == [false, false]

    observed = materialization_observation(o, :stage, 1.0, -50.0)
    @test observed.state === :ready
    @test observed.ready
    @test !observed.stored
    @test observed.tier === :memory
    @test materialization_observation(o, :stage, 1.0, -50).state === :ready
    @test materialization_observation(o, :stage, 3.0, -50.0).state === :unmaterialized
    @test @fresh(o.gate_observed(doses)) == [:ready, :ready]

    # A disk-backed entry answers both, and stays stored after a memory clear.
    @test o.stored(3) == 6.0
    @test @is_cached(o.stored(3))
    @test materialization_state(o, :stored, 3) === materialization_observation(o, :stored, 3).state === :ready
    clear_mem_caches!(o)
    @test @is_cached(o.stored(3))
    cleared = materialization_observation(o, :stored, 3)
    @test cleared.state === :stored
    @test materialization_state(o, :stored, 3) === cleared.state
    @test !cleared.ready
    @test cleared.stored
    @test materialization_observation(o, :stage, 1.0, -50.0).state === :unmaterialized

    # An interrupted write leaves an empty disk entry.
    write(cleared.path, "")
    @test materialization_state(o, :stored, 3) === materialization_observation(o, :stored, 3).state === :stored_partial
end

@testitem "materialization_observation on a remount view reads where the view would" tags=[:semantic] setup=[ObservationViewFixtures] begin
    using DynamicObjects
    function observed(o, name, args...)
        state = materialization_state(o, name, args...)
        @test state === materialization_observation(o, name, args...).state
        state
    end
    wrapper(view, name) = DynamicObjects._cache_snapshot(getfield(view, :cache).cache, name).state

    o = ObservedViewApp(2.0)
    o.stage(1.0, -50.0)

    # Shared work the retained object computed, seen from a view that never read it.
    view = remount(o; ctx = 1)
    @test observed(view, :stage, 1.0, -50.0) === :ready
    @test observed(view, :stage, 1.0, -50) === :ready
    @test observed(view, :stage, 2.0, -50.0) === :unmaterialized
    @test materialization_observation(view, :stage, 1.0, -50.0).value_type === Float64
    # Observing builds no wrapper on the view.
    @test wrapper(view, :stage) === :unmaterialized
    @test view.stage(1.0, -50.0) == -48.0
    @test wrapper(view, :stage) === :ready

    # Shared work one view computed, seen from another.
    view.stage(3.0, -50.0)
    @test observed(remount(o; ctx = 2), :stage, 3.0, -50.0) === :ready

    # Work that reads context belongs to the view that computed it.
    view.per_view(3)
    @test observed(view, :per_view, 3) === :ready
    @test observed(remount(o; ctx = 2), :per_view, 3) === :unmaterialized
    o.per_view(4)
    @test observed(remount(o; ctx = 2), :per_view, 4) === :unmaterialized

    # Opaque work is shared among views until a key reads context.
    view.opaque(5)
    @test observed(view, :opaque, 5) === :ready
    @test observed(remount(o; ctx = 3), :opaque, 5) === :ready
    o.opaque(6)
    @test observed(remount(o; ctx = 3), :opaque, 6) === :unmaterialized
    @test view.opaque_context(7) == (1, 7)
    @test observed(view, :opaque_context, 7) === :ready
    @test observed(remount(o; ctx = 5), :opaque_context, 7) === :unmaterialized

    # Work in flight on the retained object reads as pending from a fresh view.
    gate = Channel{Nothing}(1)
    OBSERVED_GATE[] = gate
    pending = fetchindex((value, status) -> value, o.slow, 1)
    @test pending isa Pending
    @test observed(remount(o; ctx = 6), :slow, 1) === :pending
    put!(gate, nothing)
    @test fetch(pending) == 1
    @test observed(remount(o; ctx = 6), :slow, 1) === :ready
end

@testitem "materialization_state skips sizing and forwards property keywords" tags=[:semantic] setup=[ObservationViewFixtures] begin
    using DynamicObjects
    probe = SizeProbe(Ref(0))
    o = StateProbeApp(probe; __cache_base__=mktempdir())
    @test materialization_state(o, :payload) === :ready
    @test materialization_state(o, :scalar) === :unmaterialized
    @test materialization_state(o, :item, 1; bytes=true) === :unmaterialized
    @test o.scalar === o.item(1; bytes=true) === probe
    @test materialization_state(o, :scalar) === :ready
    @test materialization_state(o, :item, 1; bytes=false) === :unmaterialized
    @test o.item(1; bytes=false) === nothing
    @test materialization_state(o, :item, 1; bytes=false) === :ready
    @test all(_ -> materialization_state(o, :item, 1; bytes=true) === :ready, 1:54)
    @test probe.calls[] == 0
    observation = materialization_observation(o, :item, 1; bytes=true)
    @test observation.state === :ready
    @test observation.estimated_bytes == 123
    @test probe.calls[] == 1

    @test materialization_state(o, :preview) === materialization_observation(o, :preview).state === :fresh
    @test_throws DynamicObjects.PropertyComputationError o.broken(2)
    @test materialization_state(o, :broken, 2) === materialization_observation(o, :broken, 2).state === :failed
    @test_throws ErrorException materialization_state(o, :unknown)
    @test_throws ErrorException materialization_state(o, :payload, 1)
    @test_throws ErrorException materialization_state(o, :scalar; bytes=true)
end
