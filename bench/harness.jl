## Bruno-shape LRU harness — synthetic repro of the perf hotspot in
## DynamicObjects' LRU/eviction layer.
##
## Mirrors Bruno's `web-pkpd/src/app.jl` shape: an AppData root + ~13
## child DOs constructed with explicit `__parent__=__self__`, each
## holding IPs that cache realistic shapes (large Vector{String},
## Dict{Symbol,Vector{Float64}}, NamedTuple, nested DO).
##
## Run from the worktree root:
##   julia --project=. -t 16 bench/harness.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using DynamicObjects
using Random
using Printf

const N_ROWS = 1_000_000
const N_COLS = 8

Random.seed!(1234)

# --- Child DOs ---------------------------------------------------------------
#
# In `@dynamicstruct` bodies, RHS expressions reference other fields by
# *bare name* (the macro rewrites). `__parent__` is declared explicitly
# (no default ⇒ required) so children must be constructed with a parent.

@dynamicstruct struct ColumnsDO
    __parent__
    n_rows::Int       = N_ROWS
    n_cols::Int       = N_COLS
    columns           = Dict{Symbol,Vector{Float64}}(
        Symbol("c", i) => randn(n_rows) for i in 1:n_cols
    )
    column_means      = (; (k => sum(v)/length(v) for (k,v) in columns)...)
end

@dynamicstruct struct LabelsDO
    __parent__
    n_rows::Int       = N_ROWS
    labels            = String[string("row_", i) for i in 1:n_rows]
    unique_labels     = unique(labels)
end

@dynamicstruct struct TagsDO
    __parent__
    n_rows::Int       = N_ROWS
    tags              = String[string("tag_", rand(1:1000)) for _ in 1:n_rows]
end

@dynamicstruct struct MetaDO
    __parent__
    info              = (; created_at=time(), version="0.1.0", n_cols=N_COLS, n_rows=N_ROWS)
    summary           = string("rows=", info.n_rows, " cols=", info.n_cols)
end

@dynamicstruct struct StatsDO
    __parent__
    means             = Float64[sum(randn(1000))/1000 for _ in 1:200]
    sds               = Float64[sqrt(sum(randn(1000).^2)/999) for _ in 1:200]
    summary_nt        = (; mean=sum(means)/length(means), sd=sum(sds)/length(sds))
end

@dynamicstruct struct WideDO
    __parent__
    cells             = Vector{Float64}[randn(10_000) for _ in 1:50]
end

@dynamicstruct struct StringsDO
    __parent__
    n::Int            = 500_000
    text              = String[string("entry_", i, "_", rand(UInt32)) for i in 1:n]
end

# Nested DO — IP returns another DO. The inner gets `self` (the NestedDO)
# as its parent, so the chain goes AppData → NestedDO → ColumnsDO.
@dynamicstruct struct NestedDO
    __parent__
    inner             = ColumnsDO(__self__)
end

# Root AppData with explicit per-child constructions, mirroring app.jl:19-31.
@dynamicstruct struct AppData
    columns           = ColumnsDO(__self__)
    labels            = LabelsDO(__self__)
    tags              = TagsDO(__self__)
    meta              = MetaDO(__self__)
    stats             = StatsDO(__self__)
    wide              = WideDO(__self__)
    strings           = StringsDO(__self__)
    nested            = NestedDO(__self__)
    columns2          = ColumnsDO(__self__)
    labels2           = LabelsDO(__self__)
    tags2             = TagsDO(__self__)
    meta2             = MetaDO(__self__)
    stats2            = StatsDO(__self__)
end

# --- cache_stats_walk: mirror Bruno's `/structure/cache_bytes` --------------
#
# Walk the cache tree by following any value that is itself a DO (has a
# `:cache::PropertyCache` field), aggregating per-DO byte counts and entry
# counts. This is the read-side hot path we expect Bruno to call repeatedly.

const PCType = DynamicObjects.PropertyCache

_is_do(x) = isstructtype(typeof(x)) && hasfield(typeof(x), :cache) && getfield(x, :cache) isa PCType

function cache_stats_walk(root)
    bytes_total = Ref(0)
    entries_total = Ref(0)
    n_dos = Ref(0)
    seen = Base.IdSet{Any}()
    _walk!(root, bytes_total, entries_total, n_dos, seen)
    (; bytes_total=bytes_total[], entries_total=entries_total[], n_dos=n_dos[])
end

function _walk!(obj, bytes_total, entries_total, n_dos, seen)
    obj in seen && return
    push!(seen, obj)
    pc = getfield(obj, :cache)::PCType
    n_dos[] += 1
    bytes_total[] += pc.bytes[]
    entries_total[] += length(pc.cache)
    vals = Any[]
    lock(pc.lru_lock) do
        for v in values(pc.cache)
            push!(vals, v)
        end
    end
    for v in vals
        if _is_do(v)
            _walk!(v, bytes_total, entries_total, n_dos, seen)
        end
    end
end

# --- driver ------------------------------------------------------------------

function exercise!(app)
    # Touch each child so it gets stored in app's cache.
    app.columns; app.labels; app.tags; app.meta; app.stats; app.wide; app.strings
    app.nested
    app.columns2; app.labels2; app.tags2; app.meta2; app.stats2
    # Force each child's IPs to compute (populates child's own PC).
    for c in (app.columns, app.columns2)
        c.columns; c.column_means
    end
    for c in (app.labels, app.labels2)
        c.labels; c.unique_labels
    end
    for c in (app.tags, app.tags2)
        c.tags
    end
    for c in (app.meta, app.meta2)
        c.info; c.summary
    end
    for c in (app.stats, app.stats2)
        c.means; c.sds; c.summary_nt
    end
    app.wide.cells
    app.strings.text
    app.nested.inner.columns
    app.nested.inner.column_means
    return nothing
end

function time_walk(app; reps=5)
    cache_stats_walk(app)  # warm
    ts = Float64[]
    for _ in 1:reps
        t0 = time_ns()
        cache_stats_walk(app)
        push!(ts, (time_ns()-t0)/1e6)
    end
    (; min=minimum(ts), med=sort(ts)[fld(length(ts)+1, 2)], max=maximum(ts), reps=ts)
end

function run_scenario(label::String; budget::Int)
    @printf "\n[harness] --- %s ---\n" label
    t0 = time_ns()
    app = AppData()
    # Set budget BEFORE first exercise so bookkeeping runs under it.
    DynamicObjects.set_cache_budget!(app, budget)
    t_build_ns = time_ns() - t0

    t1 = time_ns()
    exercise!(app)
    t_exercise_ns = time_ns() - t1

    s = cache_stats_walk(app)
    r = time_walk(app; reps=5)
    sb = DynamicObjects.subtree_bytes(app)

    @printf "  build=%.2fs  exercise=%.2fs  subtree_bytes=%d (%.1f MiB)\n" (t_build_ns/1e9) (t_exercise_ns/1e9) sb (sb/1024^2)
    @printf "  cache_stats: bytes=%d entries=%d n_dos=%d\n" s.bytes_total s.entries_total s.n_dos
    @printf "  walk:        min=%.3fms  med=%.3fms  max=%.3fms\n" r.min r.med r.max
    return (; app, r, s, t_build_ns, t_exercise_ns)
end

function main()
    @printf "[harness] threads=%d  rows=%d  cols=%d\n" Threads.nthreads() N_ROWS N_COLS
    # JIT warmup pass — full-size, so both code paths are fully compiled.
    @printf "[harness] JIT warmup...\n"
    let warm = AppData()
        DynamicObjects.set_cache_budget!(warm, 8*1024^3)
        exercise!(warm)
        cache_stats_walk(warm)
    end
    GC.gc(true)

    r1 = run_scenario("BUDGET = 8 GiB (opt-in, bookkeeping engaged)"; budget=8*1024^3)
    GC.gc(true)
    r0 = run_scenario("BUDGET = 0 (opt-out, bookkeeping skipped)"; budget=0)
    GC.gc(true)
    # Re-run budget-engaged so order-effects are visible.
    r1b = run_scenario("BUDGET = 8 GiB (re-run for stability)"; budget=8*1024^3)
    GC.gc(true)
    # Tiny budget — forces eviction on every store. This is the path that
    # most exercises `_walk_subtree_pcs!` + `_summarysize_capped` on every
    # write. If it's ever going to be slow, it's here.
    r_evict = run_scenario("BUDGET = 1 MiB (forces eviction churn)"; budget=1024^2)
    @printf "\n[harness] exercise overhead (budget run1 vs no-budget): %.2fx\n" (r1.t_exercise_ns/r0.t_exercise_ns)
    @printf "[harness] exercise overhead (budget run2 vs no-budget): %.2fx\n" (r1b.t_exercise_ns/r0.t_exercise_ns)
    @printf "[harness] walk overhead     (budget run1 vs no-budget): %.2fx\n" (r1.r.med/r0.r.med)
    @printf "[harness] exercise overhead (eviction-churn vs no-budget): %.2fx\n" (r_evict.t_exercise_ns/r0.t_exercise_ns)
    return (; r0, r1, r1b, r_evict)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
