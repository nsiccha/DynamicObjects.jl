using DynamicObjects
import DynamicObjects: _slot_eltype

# Regression: read-side slot-type recovery under Phase-B `Slot{Any}` storage.
#
# Storage boxes every COMPUTED slot as `Slot{Any}` (bounded `__DO_S__`, no whole-tree composite);
# the concrete READ type is recovered PER-PROPERTY over the actual `typeof(o)`
# (`_read_slot_types` / `_read_slot_types_expr`) and applied at the read by `_getprop`'s
# `::_slot_eltype(typeof(o), Val(name))` assert on the slotted path.
#
# Covers: (1) soundness incl. the joint S-dependence shape (SCtx/SFit/SAppData/SDatasets — a
# nested-DO child whose type embeds its parent); (2) read precision for direct + single-hop
# navigating reads; (3) robustness — one `Union{}` (always-thrower) property does NOT poison its
# neighbours (per-property inference, not the fragile all-or-nothing joint); (4) flat `Slot{Any}`
# storage + blowup-free deep-nest construction. Deep MULTI-hop navigating reads
# (`parent.appdata.datasets` — 2+ getproperty hops) degrade GRACEFULLY to `Any` (a Julia
# inference-effort limit on chained generated-assert reads) — never to `Union{}`, never wrong at
# runtime. Runs standalone: `julia --project=. test/regression/read_recovery.jl`.

@dynamicstruct struct SDatasets; tag::Int; rows = tag*100 + (isnothing(__parent__) ? 0 : __parent__.seed); end
@dynamicstruct struct SAppData; seed::Int; datasets = SDatasets(seed; __parent__ = __self__); end
@dynamicstruct struct SFit; m::Int; ds = __parent__.__appdata__.datasets; result = m + ds.rows; end
@dynamicstruct struct SCtx; cfg::Int; __appdata__ = SAppData(cfg); fit = SFit(cfg; __parent__ = __self__); end
@dynamicstruct struct SLeaf; v::Int; doubled = 2v; end
@dynamicstruct struct SHost; n::Int; leaf = SLeaf(n); total = n + leaf.doubled; end
@dynamicstruct struct SThrow; k::Int; boom = error("always"); child = SLeaf(k); end

rt(f, T) = Core.Compiler.return_type(f, Tuple{T})

# (1) soundness — runtime values correct, no S-dependence convert crash, thrower isolated
ctx = SCtx(7); host = SHost(5); thr = SThrow(3)
@assert ctx.__appdata__.datasets.rows == 707
@assert ctx.fit.ds.rows == 707
@assert ctx.fit.result == 714
@assert host.total == 15
@assert thr.child.doubled == 6

# (4a) storage bounded: every slot is Slot{Any} (flat, no composite embedded in the struct type)
ST = fieldtype(typeof(host), :slots)
@assert all(fieldtype(ST, n) === DynamicObjects.Slot{Any} for n in fieldnames(ST)) "storage not flat Slot{Any}: $ST"

# (2) read precision: direct + single-hop navigating reads recover concretely (the real
#     end-to-end read a consumer sees — const-name getproperty via a closure)
@assert rt(o->o.doubled, typeof(host.leaf))               === Int      "leaf.doubled not Int"
@assert rt(o->o.total,   typeof(host))                    === Int      "host.total (n+leaf.doubled) not Int"
@assert rt(o->o.rows,    typeof(ctx.__appdata__.datasets)) === Int      "datasets.rows not Int"
@assert rt(o->o.leaf,    typeof(host))                    <: SLeaf     "host.leaf not <: SLeaf"
@assert rt(o->o.__appdata__, typeof(ctx))                 <: SAppData  "ctx.__appdata__ not <: SAppData"

# (3) robustness: SThrow.boom (never-returns → Union{} locally → Any) must NOT poison child
@assert _slot_eltype(typeof(thr), Val(:boom))  === Any    "boom (never-returns) should widen to Any"
@assert rt(o->o.child, typeof(thr))            <: SLeaf   "child poisoned by sibling thrower"

# deep MULTI-hop chain degrades GRACEFULLY (Any-or-better, NEVER Union{}); runtime stays correct
ds_t = rt(o->o.ds, typeof(ctx.fit))
@assert ds_t !== Union{} "SFit.ds (deep chain) is Union{} — read recovery is BROKEN, not merely imprecise"

# (4b) flat / blowup-free deep-nest construction: a re-introduced composite would make this
#      super-linear (old rung-2 ran minutes at depth 10); flat Slot{Any} keeps it trivial.
@dynamicstruct struct D0; x::Int; v = x*2; end
@dynamicstruct struct D1; x::Int; c = D0(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D2; x::Int; c = D1(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D3; x::Int; c = D2(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D4; x::Int; c = D3(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D5; x::Int; c = D4(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D6; x::Int; c = D5(x; __parent__=__self__); v = c.v + x; end
@dynamicstruct struct D7; x::Int; c = D6(x; __parent__=__self__); v = c.v + x; end
t = @elapsed D7(1)                    # cold construct of the 8-deep __parent__-threaded chain
@assert D7(1).v == 9 "deep-nest value wrong (D_k.v = 2 + k; D7 = 9)"
@assert t < 30.0 "deep-nest construct took $(t)s — composite/inference blowup re-introduced?"

println("read_recovery OK — 707/707/714 sound; direct+shallow reads concrete; thrower isolated; ",
        "flat Slot{Any} storage; blowup-free 8-deep nest ($(round(t,digits=2))s); deep multi-hop = $ds_t (graceful)")
