using DynamicObjects
import DynamicObjects: _read_slot_types, _slot_eltype

# Regression: read-side slot-type recovery under Phase-B `Slot{Any}` storage.
#
# Storage boxes every COMPUTED slot as `Slot{Any}` (bounded `__DO_S__`, no whole-tree composite);
# the concrete READ type is recovered PER-PROPERTY over the actual `typeof(o)`
# (`_read_slot_types` / `_read_slot_types_expr`) and applied at the read by `_getprop`'s
# `::_slot_eltype(typeof(o), Val(name))` assert on the slotted path.
#
# TWO layers, TWO reliability tiers:
#  * The DRIVER (`_read_slot_types` / `_slot_eltype`) recovers concrete types DETERMINISTICALLY:
#    direct + single-hop navigating + within-struct sibling-chain reads → concrete; deep
#    MULTI-hop cross-DO chains (`parent.appdata.datasets`) → `Any` (a Julia inference-effort
#    limit); an always-thrower `Union{}` widens to `Any` locally WITHOUT poisoning its siblings.
#    THIS is what we hard-assert.
#  * The READ-SITE FOLD (`o.x` actually inferring the recovered type) is BEST-EFFORT: the FIRST
#    `getproperty` inference per type cannot const-fold the `@generated`-backed assert (→ `Any`);
#    subsequent reads of that type fold fine. Order-dependent, SOUND (never wrong, never
#    `Union{}`, always ≥ the all-`Any` baseline) — so we only REPORT it, never gate on it.
#    (Whether best-effort read stability is acceptable, or the return_type-derived assert needs
#    reworking for reliable folding, is a live decision for `DynamicObjects`.)
# Runs standalone: `julia --project=. test/regression/read_recovery.jl`.

@dynamicstruct struct SDatasets; tag::Int; rows = tag*100 + (isnothing(__parent__) ? 0 : __parent__.seed); end
@dynamicstruct struct SAppData; seed::Int; datasets = SDatasets(seed; __parent__ = __self__); end
@dynamicstruct struct SFit; m::Int; ds = __parent__.__appdata__.datasets; result = m + ds.rows; end
@dynamicstruct struct SCtx; cfg::Int; __appdata__ = SAppData(cfg); fit = SFit(cfg; __parent__ = __self__); end
@dynamicstruct struct SLeaf; v::Int; doubled = 2v; end
@dynamicstruct struct SHost; n::Int; leaf = SLeaf(n); total = n + leaf.doubled; end
@dynamicstruct struct SThrow; k::Int; boom = error("always"); child = SLeaf(k); end

ctx = SCtx(7); host = SHost(5); thr = SThrow(3)
Th = typeof(host); Tl = typeof(host.leaf); Tc = typeof(ctx)
Tds = typeof(ctx.__appdata__.datasets); Tapp = typeof(ctx.__appdata__); Tfit = typeof(ctx.fit)

# (1) soundness — runtime values correct, no S-dependence convert crash, thrower isolated
@assert ctx.__appdata__.datasets.rows == 707
@assert ctx.fit.ds.rows == 707
@assert ctx.fit.result == 714
@assert host.total == 15
@assert thr.child.doubled == 6

# (2) storage bounded: every slot is Slot{Any} (flat, no composite embedded in the struct type)
ST = fieldtype(Th, :slots)
@assert all(fieldtype(ST, n) === DynamicObjects.Slot{Any} for n in fieldnames(ST)) "storage not flat Slot{Any}: $ST"

# (3) DRIVER recovery (deterministic): direct/single-hop/sibling-chain reads recover concretely
@assert _slot_eltype(Tl,  Val(:doubled)) === Int    "driver: SLeaf.doubled"
@assert _slot_eltype(Th,  Val(:total))   === Int    "driver: SHost.total (n+leaf.doubled)"
@assert _slot_eltype(Tds, Val(:rows))    === Int    "driver: SDatasets.rows (…+parent.seed)"
@assert _slot_eltype(Th,  Val(:leaf))    <: SLeaf   "driver: SHost.leaf"
@assert _slot_eltype(Tc,  Val(:__appdata__)) <: SAppData "driver: SCtx.__appdata__"
@assert _slot_eltype(Tapp,Val(:datasets)) <: SDatasets  "driver: SAppData.datasets"

# (3b) robustness: an always-thrower (Union{} locally → Any) must NOT poison its sibling's driver type
@assert _slot_eltype(typeof(thr), Val(:boom))  === Any   "driver: boom should widen to Any"
@assert _slot_eltype(typeof(thr), Val(:child)) <: SLeaf  "driver: child poisoned by sibling thrower"

# (3c) deep MULTI-hop cross-DO chain: driver degrades GRACEFULLY to Any (never Union{})
@assert _slot_eltype(Tfit, Val(:ds)) !== Union{} "driver: SFit.ds is Union{} — recovery BROKEN not merely imprecise"

# (4) read-site assert is SOUND: `_getprop`'s `slot.value::_slot_eltype(...)` never narrows below the
#     runtime value — the value conforms to the recovered type (a too-narrow R would THROW on read).
@assert host.total isa _slot_eltype(Th, Val(:total))
@assert host.leaf  isa _slot_eltype(Th, Val(:leaf))
@assert ctx.__appdata__ isa _slot_eltype(Tc, Val(:__appdata__))
@assert ctx.__appdata__.datasets.rows isa _slot_eltype(Tds, Val(:rows))
@assert ctx.fit.ds isa _slot_eltype(Tfit, Val(:ds))   # ds=Any: trivially conforms, still correct

# (5) flat / blowup-free deep-nest construction (a re-introduced composite would go super-linear)
@dynamicstruct struct D0; x::Int; v = x*2; end
@dynamicstruct struct D1; x::Int; c = D0(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D2; x::Int; c = D1(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D3; x::Int; c = D2(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D4; x::Int; c = D3(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D5; x::Int; c = D4(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D6; x::Int; c = D5(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D7; x::Int; c = D6(x; __parent__=__self__); v = c.v + x; end
t = @elapsed D7(1)
@assert D7(1).v == 9 "deep-nest value wrong (D_k.v = 2 + k; D7 = 9)"
@assert t < 30.0 "deep-nest construct took $(t)s — composite/inference blowup re-introduced?"

println("read_recovery OK — soundness 707/707/714; read assert sound (runtime values conform); ",
        "flat Slot{Any} storage; DRIVER recovery deterministic (leaf/total/rows/leaf/appdata concrete, ",
        "deep-chain ds=Any graceful, thrower isolated); blowup-free 8-deep nest ($(round(t,digits=2))s). ",
        "NOTE: read-SITE type-stability (o.x folding to the recovered type) is best-effort/order-dependent ",
        "— see decision on the return_type-derived assert; NOT gated here.")
