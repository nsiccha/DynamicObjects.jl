using DynamicObjects
import DynamicObjects: _slot_types

# Rung-2 bounded-fixpoint recovery: a nested-DO slot that is INDEPENDENT of the parent's
# slots (built with no `__parent__`, or reading the parent only through its own base-widened
# `__parent__` → `Any`) is recovered to its concrete type instead of rung-1's bare base.
# A genuinely self-referential slot stays correctly typed (`SFit{…ds::Slot{Any}…}`).
# Runs standalone (`julia --project=. this.jl`); asserts soundness (707/707/714) AND recovery.

@dynamicstruct struct SDatasets
    tag::Int
    rows = tag * 100 + (isnothing(__parent__) ? 0 : __parent__.seed)
end
@dynamicstruct struct SAppData
    seed::Int
    datasets = SDatasets(seed; __parent__ = __self__)
end
@dynamicstruct struct SFit
    m::Int
    ds = __parent__.__appdata__.datasets
    result = m + ds.rows
end
@dynamicstruct struct SCtx
    cfg::Int
    __appdata__ = SAppData(cfg)              # no __parent__ → RESOLVABLE
    fit = SFit(cfg; __parent__ = __self__)   # self-ref → base-widen
end
@dynamicstruct struct SLeaf
    v::Int
    doubled = 2v
end
@dynamicstruct struct SHost
    n::Int
    leaf = SLeaf(n)                          # no __parent__ → RESOLVABLE
    total = n + leaf.doubled
end

ctx = SCtx(7); host = SHost(5)
# soundness — accepting a concrete slot must NOT re-freeze a wrong type (S-dependence crash)
@assert ctx.__appdata__.datasets.rows == 707
@assert ctx.fit.ds.rows == 707
@assert ctx.fit.result == 714
@assert host.total == 15
# recovery — the resolvable nested-DO slots must be concrete, not rung-1 bare base
@assert !isempty(fieldtype(_slot_types(typeof(ctx)),  :__appdata__).parameters) "SCtx.__appdata__ not recovered"
@assert !isempty(fieldtype(_slot_types(typeof(host)), :leaf).parameters)        "SHost.leaf not recovered"
println("FIXPOINT OK  (707/707/714, __appdata__+leaf concrete) — rung-2 recovery verified")
