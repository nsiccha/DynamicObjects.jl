using TestItemRunner

@testsnippet DOImports begin
    using Test, Random, DynamicObjects, Serialization, Arrow, DataFrames
    import DynamicObjects: entries, cached_entries, clear_all_caches!, PersistentSet
end

# The legacy deferred suite evaluated these definitions once at module
# scope, then ran the deferred testsets sequentially. A shared test module keeps
# that behavior: its mutable counters remain shared across items, while each
# item still receives a fresh test module through `DOImports`.
@testmodule DOFixtures begin
using DynamicObjects, Random

export MultiLhs, CachedMultiLhs, ThreeValues, NamedDestr, RenameDestr,
    PrefixDestr, MixedDestr, Clearable, TwoFields, Basic,
    WithDefault, Remakeable, RemountGraph, Cached, VersionedCache, UnversionedCache,
    VersionedIndexedCache, Idx, AllDefaults, CallVsBracket, Par, D1,
    LetScope, LambdaScope, SharedDep, AsyncApp, FailingProps,
    EntriesApp, ClearAllApp, FetchKwargs, HashLeaf, HashParent, HashNoDOs,
    BareRefMagic, BareRefOverride,
    _multi_lhs_counter, _multi_lhs_cached_path, _named_destr_counter,
    _prefix_destr_counter_x, _prefix_destr_counter_y, _clearable_path,
    _remount_intrinsic_count, _remount_summary_count, _remount_slow_count,
    _remount_child_count, _remount_indexed_child_count, _remount_cache_base,
    _remount_started, _remount_release,
    _disk_cache_path, _version_cache_path, _idx_path,
    _call_vs_bracket_counter, _regression_path, _clearall_path

# --- Struct definitions (hoisted to module scope) ---

_multi_lhs_counter = Ref(0)
@dynamicstruct struct MultiLhs
    x::Float64
    a, b = (_multi_lhs_counter[] += 1; (x, 2x))
    c = a + b
end

_multi_lhs_cached_path = Ref("")
@dynamicstruct struct CachedMultiLhs
    __cache_path__ = _multi_lhs_cached_path[]
    @cached a, b = (1, 2)
end

@dynamicstruct struct ThreeValues
    x, y, z = (10, 20, 30)
end

_named_destr_counter = Ref(0)
@dynamicstruct struct NamedDestr
    x::Float64
    (;val, grad) = (_named_destr_counter[] += 1; (val=x^2, grad=2x))
    sum_vg = val + grad
end

@dynamicstruct struct RenameDestr
    x::Float64
    (;x_val<=val, x_grad<=grad) = (val=x^2, grad=2x)
end

_prefix_destr_counter_x = Ref(0)
_prefix_destr_counter_y = Ref(0)
@dynamicstruct struct PrefixDestr
    x::Float64
    y::Float64
    (;x_ <= (val, grad)) = (_prefix_destr_counter_x[] += 1; (val=x^2, grad=2x))
    (;y_ <= (val, grad)) = (_prefix_destr_counter_y[] += 1; (val=y^2, grad=2y))
    total = x_val + y_val
end

@dynamicstruct struct MixedDestr
    (;a, x_b<=b, y_ <= (c, d)) = (a=1, b=2, c=3, d=4)
end

_clearable_path = Ref("")
@dynamicstruct struct Clearable
    __cache_path__ = _clearable_path[]
    @cached result = sum(rand(10))
    @cached indexed(k) = k ^ 2
end

@dynamicstruct struct TwoFields
    x::Float64
    y::Int
    sum_xy = x + y
end

@dynamicstruct struct Basic
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
    sum2  = x + y
end

@dynamicstruct struct WithDefault
    x::Float64
    expensive = x ^ 2
end

@dynamicstruct struct Remakeable
    x::Float64
    y::Float64
    sum_xy = x + y
end

_remount_intrinsic_count = Ref(0)
_remount_summary_count = Ref(0)
_remount_slow_count = Ref(0)
_remount_child_count = Ref(0)
_remount_indexed_child_count = Ref(0)
_remount_cache_base = Ref("")
_remount_started = Ref{Any}(nothing)
_remount_release = Ref{Any}(nothing)

@dynamicstruct struct RemountGraph
    payload::String
    @versioned content_version::String
    __cache_base__ = _remount_cache_base[]
    __req__ = error("request context is required")
    __parent__ = nothing
    __prefix__ = ""
    fit_key = __req__.fit_key
    intrinsic = (_remount_intrinsic_count[] += 1; Ref((payload, content_version)))
    safe_index(operation) = (intrinsic, operation)
    acceptance_summary(operation) = begin
        _remount_summary_count[] += 1
        (fit_key, operation)
    end
    @cached request_disk(operation) = (fit_key, operation)
    @mmap mapped::Vector{Int} = [1, 2, 3]
    @struct child = begin
        current_fit_key = __parent__.fit_key
        intrinsic_child = (_remount_child_count[] += 1; Ref(:child))
        child_index(operation) = (intrinsic_child, operation)
    end
    @struct indexed_child(key) = begin
        current_fit_key = __parent__.fit_key
        intrinsic_child = (_remount_indexed_child_count[] += 1; Ref(key))
    end
    slow_intrinsic = begin
        _remount_slow_count[] += 1
        put!(_remount_started[], nothing)
        take!(_remount_release[])
        Ref(:finished)
    end
end

_disk_cache_path = Ref("")
@dynamicstruct struct Cached
    __cache_path__ = _disk_cache_path[]
    a = 1
    b = 2 * a
    @cached c = a * b
    @cached d = isnothing(d) ? 1 : d + 1
end

_version_cache_path = Ref("")
@dynamicstruct struct VersionedCache
    __cache_path__ = _version_cache_path[]
    @cached v"1" result = 42
end

@dynamicstruct struct UnversionedCache
    __cache_path__ = _version_cache_path[]
    @cached result = 42
end

@dynamicstruct struct VersionedIndexedCache
    __cache_path__ = _version_cache_path[]
    @cached v"1" result(key) = key ^ 2
end

_idx_path = Ref("")
@dynamicstruct struct Idx
    __cache_path__ = _idx_path[]
    i(idx)              = idx
    @cached ci(idx)     = idx ^ 2
    @cached ci3(i, j, k) = i + 10 * j + 100 * k
end

@dynamicstruct struct AllDefaults
    item(x="default") = "got: $x"
    multi(a=1, b=2) = a + b
end

_call_vs_bracket_counter = Ref(0)
@dynamicstruct struct CallVsBracket
    counted(x) = (_call_vs_bracket_counter[] += 1; x * 2)
end

@dynamicstruct struct Par
    slow = (sleep(0.1); randn())
    slowi(i) = (sleep(0.05); i + randn())
end

_regression_path = Ref("")
@dynamicstruct struct D1
    __cache_path__ = _regression_path[]
    a = 1
    b = 2 * a
    @cached c = a * b
    @cached d = isnothing(d) ? 1 : d + 1
    i(idx) = idx
    @cached ci(idx) = idx ^ 2
    @cached ci3(i, j, k) = i + 10 * j + 100 * k
    parallel_test = begin
        sleep(1)
        randn()
    end
    parallel_testi(i) = begin
        sleep(1)
        i + randn()
    end
end

@dynamicstruct struct LetScope
    x::Float64
    result = let x = 99.0
        x + 1
    end
end

@dynamicstruct struct LambdaScope
    x::Float64
    items = [1.0, 2.0, 3.0]
    mapped = map(x -> x * 2, items)
end

@dynamicstruct struct SharedDep
    x::Float64
    intermediate = x * 10
    a = intermediate + 1
    b = intermediate + 2
end

@dynamicstruct struct AsyncApp
    slow(key) = (sleep(0.05); key * 2)
end

@dynamicstruct struct FailingProps
    will_fail = error("serial failure")
    will_fail_indexed(key) = error("serial failure for key=$key")
end

@dynamicstruct struct EntriesApp
    slow(key) = (sleep(0.05); key * 2)
end

_clearall_path = Ref("")
@dynamicstruct struct ClearAllApp
    __cache_path__ = _clearall_path[]
    @cached a = 42
    @cached b(k) = k * 2
    uncached = 99
end

# Regression: `@fetch!` over a fetched IP call that carries kwargs. `walk_rhs`
# rewrites the `; n_grid` shorthand to `; __self__.n_grid` (a `:.` shorthand —
# valid Julia), so `_fetch_rewrite` must keep it valid keyword syntax rather
# than turning it into a bare `maybefetchproperty!(…)` call (which 500'd with
# `invalid keyword argument syntax`). Reported by
# Bruno:qt:super.dense-progress:worker, 2026-06-23. A regression fails this
# file at load time (the struct won't macroexpand).
@dynamicstruct struct FetchKwargs
    n_grid = 100
    base = 5
    from_schedule(a, b; n_grid=1) = a + b + n_grid           # IP with a kwarg
    @fetch! shorthand() = from_schedule(base, base; n_grid)   # `; n_grid` (n_grid is a sibling property)
    @fetch! explicit() = from_schedule(base, base; n_grid=7)  # `; n_grid=literal`
end

@dynamicstruct struct HashLeaf
    x::Int
    y::String
end

@dynamicstruct struct HashParent
    leaf::HashLeaf
    k::Int
end

@dynamicstruct struct HashNoDOs
    x::Int
    y::Vector{Float64}
end

# Bare references to the injected magic dunders (uniform bare-ref injection):
# a body may write `__hash__`/`__cache_base__`/… bare, resolved like a sibling.
@dynamicstruct struct BareRefMagic
    w::Int
    fromhash   = "h:" * __hash__
    frombase   = __cache_base__
    fromstrict = __strict__
    fromfields = __hash_fields__
end
# A user override of a data dunder still wins (injection guard is user-only).
@dynamicstruct struct BareRefOverride
    __cache_base__ = "custom"
    derived = __cache_base__ * "/x"
end

end # @testmodule DOFixtures

# --- Tests ---

@testitem "Multi-lhs assignment" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _multi_lhs_counter[] = 0
    m = MultiLhs(3.0)
    _multi_lhs_counter[] = 0
    @test m.a == 3.0
    @test _multi_lhs_counter[] == 1
    @test m.b == 6.0
    @test _multi_lhs_counter[] == 1
    @test m.c == 9.0
end

@testitem "Multi-lhs with @cached" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _multi_lhs_cached_path[] = mktempdir()
    c = CachedMultiLhs()
    @test c.a == 1
    @test c.b == 2
    group_name = Symbol("_tuple_a_b")
    @test @cache_status(c._tuple_a_b) == :ready
end

@testitem "Multi-lhs three values" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    t = ThreeValues()
    @test t.x == 10
    @test t.y == 20
    @test t.z == 30
end

@testitem "Named destructuring (;a, b) = ..." tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _named_destr_counter[] = 0
    n = NamedDestr(3.0)
    _named_destr_counter[] = 0
    @test n.val == 9.0
    @test _named_destr_counter[] == 1
    @test n.grad == 6.0
    @test _named_destr_counter[] == 1
    @test n.sum_vg == 15.0
end

@testitem "Named destructuring with rename" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    r = RenameDestr(3.0)
    @test r.x_val == 9.0
    @test r.x_grad == 6.0
end

@testitem "Named destructuring with prefix" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _prefix_destr_counter_x[] = 0
    _prefix_destr_counter_y[] = 0
    p = PrefixDestr(3.0, 4.0)
    _prefix_destr_counter_x[] = 0
    _prefix_destr_counter_y[] = 0
    @test p.x_val == 9.0
    @test p.x_grad == 6.0
    @test _prefix_destr_counter_x[] == 1
    @test p.y_val == 16.0
    @test p.y_grad == 8.0
    @test _prefix_destr_counter_y[] == 1
    @test _prefix_destr_counter_x[] == 1
    @test _prefix_destr_counter_y[] == 1
    @test p.total == 25.0
end

@testitem "Named destructuring mixed" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    m = MixedDestr()
    @test m.a == 1
    @test m.x_b == 2
    @test m.y_c == 3
    @test m.y_d == 4
end

"""
Clears scalar, individual indexed, and whole indexed-property cache entries
from both memory and disk.
"""
@testitem "@clear_cache!" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _clearable_path[] = mktempdir()
    c = Clearable()
    val1 = c.result
    @test @is_cached c.result
    @clear_cache! c.result
    @test @cache_status(c.result) == :unstarted
    val2 = c.result
    @test @is_cached c.result
    @test c.indexed(3) == 9
    @test c.indexed(4) == 16
    @test @is_cached c.indexed(3)
    @test @is_cached c.indexed(4)
    @clear_cache! c.indexed(3)
    @test @cache_status(c.indexed(3)) == :unstarted
    @test @is_cached c.indexed(4)
    c.indexed(3)
    @test @is_cached c.indexed(3)
    @clear_cache! c.indexed
    @test @cache_status(c.indexed(3)) == :unstarted
    @test @cache_status(c.indexed(4)) == :unstarted
end

@testitem "Constructor named parameters" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    t = TwoFields(1.0, 2)
    @test t.sum_xy == 3.0
    @test_throws MethodError TwoFields(1.0)
    @test_throws MethodError TwoFields(1.0, 2, 3)
end

@testitem "Basic properties" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    b = Basic(3.0, 4.0)
    @test b.x == 3.0
    @test b.y == 4.0
    @test b.r ≈ 5.0
    @test b.theta ≈ atan(4.0, 3.0)
    @test b.sum2 ≈ 7.0
    @test hasproperty(b, :x) == true
    @test hasproperty(b, :r) == true
    @test hasproperty(b, :nonexistent) == false
end

@testitem "Constructor kwargs" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    w = WithDefault(4.0; expensive=0.0)
    @test w.expensive == 0.0
end

@testitem "remake" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    orig = Remakeable(1.0, 2.0)
    @test orig.sum_xy ≈ 3.0
    r1 = remake(orig; x=10.0)
    @test r1.x == 10.0
    @test r1.y == 2.0
    @test r1.sum_xy ≈ 12.0
    r2 = remake(orig; y=20.0)
    @test r2.x == 1.0
    @test r2.y == 20.0
    @test r2.sum_xy ≈ 21.0
    r3 = remake(orig; sum_xy=99.0)
    @test r3.x == 1.0
    @test r3.y == 2.0
    @test r3.sum_xy == 99.0
end

@testitem "remount retains intrinsic cache identity and rebinds context" tags=[:core] setup=[DOImports, DOFixtures] begin
    _remount_intrinsic_count[] = 0
    _remount_summary_count[] = 0
    _remount_slow_count[] = 0
    _remount_child_count[] = 0
    _remount_indexed_child_count[] = 0
    _remount_cache_base[] = mktempdir()
    _remount_started[] = Channel{Nothing}(1)
    _remount_release[] = Channel{Nothing}(1)

    source = RemountGraph("payload", "v1")
    intrinsic = source.intrinsic
    mapped = source.mapped
    source_safe = source.safe_index
    @test source_safe(:same) == (intrinsic, :same)
    source_child = source.child
    child_intrinsic = source_child.intrinsic_child
    source_child_index = source_child.child_index
    @test source_child_index(:same) == (child_intrinsic, :same)
    source_indexed_child_ip = source.indexed_child
    source_indexed_child = source_indexed_child_ip(:same)
    indexed_child_intrinsic = source_indexed_child.intrinsic_child

    request_a = (fit_key=:A,)
    request_b = (fit_key=:B,)
    a = remount(source; __req__=request_a, __parent__=:parent_a, __prefix__="/a")
    b = remount(source; __req__=request_b, __parent__=:parent_b, __prefix__="/b")

    @test a.fit_key === :A
    @test b.fit_key === :B
    @test a.__parent__ === :parent_a
    @test b.__parent__ === :parent_b
    @test a.__prefix__ == "/a"
    @test b.__prefix__ == "/b"
    @test a.acceptance_summary(:identical) == (:A, :identical)
    @test b.acceptance_summary(:identical) == (:B, :identical)
    @test _remount_summary_count[] == 2
    @test a.request_disk(:identical) == (:A, :identical)
    @test b.request_disk(:identical) == (:B, :identical)

    # Settled scalar/mmap/version state is the retained graph's exact value.
    @test a.intrinsic === intrinsic
    @test b.intrinsic === intrinsic
    @test _remount_intrinsic_count[] == 1
    @test a.mapped === mapped
    @test b.mapped === mapped
    @test a.__version_tag__ == source.__version_tag__
    @test b.__cache_path__ == source.__cache_path__

    # Every mounted wrapper owns the current view. Safe indexed work shares its
    # per-argument cache; request-derived indexed work has a local subcache.
    a_safe = a.safe_index
    b_safe = b.safe_index
    @test a_safe.o === a
    @test b_safe.o === b
    @test a_safe.cache === source_safe.cache
    @test b_safe.cache === source_safe.cache
    @test a_safe(:same) === source_safe(:same)
    @test a.acceptance_summary.o === a
    @test b.acceptance_summary.o === b
    @test a.acceptance_summary.cache !== b.acceptance_summary.cache

    # Inline children cannot retain the source parent across mounts.
    @test a.child.__parent__ === a
    @test b.child.__parent__ === b
    @test a.child.current_fit_key === :A
    @test b.child.current_fit_key === :B
    @test a.child.intrinsic_child === child_intrinsic
    @test b.child.intrinsic_child === child_intrinsic
    @test _remount_child_count[] == 1
    @test a.child.child_index.o === a.child
    @test b.child.child_index.o === b.child
    @test a.child.child_index.cache === source_child_index.cache
    @test b.child.child_index.cache === source_child_index.cache

    # Settled indexed children get request-local wrapper/subcache identities but
    # retain each child's intrinsic cache while rebinding its parent.
    a_indexed_child_ip = a.indexed_child
    b_indexed_child_ip = b.indexed_child
    a_indexed_child = a_indexed_child_ip(:same)
    b_indexed_child = b_indexed_child_ip(:same)
    @test a_indexed_child_ip.o === a
    @test b_indexed_child_ip.o === b
    @test a_indexed_child_ip.cache !== source_indexed_child_ip.cache
    @test b_indexed_child_ip.cache !== source_indexed_child_ip.cache
    @test a_indexed_child.__parent__ === a
    @test b_indexed_child.__parent__ === b
    @test a_indexed_child.current_fit_key === :A
    @test b_indexed_child.current_fit_key === :B
    @test a_indexed_child.intrinsic_child === indexed_child_intrinsic
    @test b_indexed_child.intrinsic_child === indexed_child_intrinsic
    @test _remount_indexed_child_count[] == 1

    # Remounting a view peels back to the retained source, never the prior
    # request-local overlay.
    c = remount(a; __req__=(fit_key=:C,), __parent__=:parent_c, __prefix__="/c")
    @test c.acceptance_summary(:identical) == (:C, :identical)
    @test c.intrinsic === intrinsic

    # An intrinsic computation already in flight is not copied or restarted:
    # the mounted view deduplicates onto the retained latch and value.
    pending_source = fetchproperty(source, :slow_intrinsic) do rv, _
        rv
    end
    @test pending_source isa Pending
    take!(_remount_started[])
    pending_view = remount(source; __req__=request_a, __parent__=:parent_a,
                           __prefix__="/a")
    pending_mounted = fetchproperty(pending_view, :slow_intrinsic) do rv, _
        rv
    end
    @test pending_mounted isa Pending
    put!(_remount_release[], nothing)
    slow_source = fetch(pending_source)
    @test fetch(pending_mounted) === slow_source
    @test pending_view.slow_intrinsic === slow_source
    @test _remount_slow_count[] == 1

    # A shared-cache remount cannot change the retained identity dimensions.
    @test_throws ErrorException remount(source; payload="other")
    @test_throws ErrorException remount(source; content_version="v2")
    @test_throws ErrorException remount(source; __cache_base__=mktempdir())
    @test_throws ErrorException remount(source; unknown_context=1)
end

@testitem "Disk cache" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _disk_cache_path[] = mktempdir()
    d = Cached()
    @test @cache_status(d.c) == :unstarted
    @test @is_cached(d.c) == false
    val_c = d.c
    @test val_c == 2
    @test @cache_status(d.c) == :ready
    @test @is_cached(d.c) == true
    cp = @cache_path d.c
    @test isa(cp, AbstractString)
    @test isfile(cp)
    @test @cache_status(d.d) == :unstarted
    @test d.d == 1
    @test @cache_status(d.d) == :ready
    d2 = Cached()
    @test d2.d == 1
end

"""
Checks indexed call syntax, default memoization, disk-cache status, and
multi-index key handling.
"""
@testitem "Indexable properties" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _idx_path[] = mktempdir()
    s = Idx()
    @test s.i(5)        == 5
    @test s.i(10)       == 10
    @test @cache_status(s.ci(3)) == :unstarted
    @test s.ci(3)       == 9
    @test @cache_status(s.ci(3)) == :ready
    @test @cache_status(s.ci3(1, 2, 3)) == :unstarted
    @test s.ci3(1, 2, 3) == 321
    @test @cache_status(s.ci3(1, 2, 3)) == :ready
    @test isa(s.ci3, DynamicObjects.IndexableProperty)
end

@testitem "All-default indexed properties" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    s = AllDefaults()
    @test isa(s.item, DynamicObjects.IndexableProperty)
    @test isa(s.multi, DynamicObjects.IndexableProperty)
    @test s.item("hello") == "got: hello"
    @test s.multi(10, 20) == 30
    @test s.item("default") == "got: default"
    @test s.multi(1, 2) == 3
end

@testitem "Indexed calls cache by default" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _call_vs_bracket_counter[] = 0
    s = CallVsBracket()
    _call_vs_bracket_counter[] = 0
    @test s.counted(5) == 10
    @test _call_vs_bracket_counter[] == 1
    @test s.counted(5) == 10
    @test _call_vs_bracket_counter[] == 1
    @test s.counted(6) == 12
    @test _call_vs_bracket_counter[] == 2
end

@testitem "Fast-hit path: repeat bare read hits cache (no recompute)" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # Exercises the `_peek_hit` early-return in getorcomputeproperty: a second
    # read of a cached bare property returns the memoized value without rerunning
    # the body (ba00aa9). MultiLhs bumps _multi_lhs_counter once per (a,b) compute.
    _multi_lhs_counter[] = 0
    m = MultiLhs(5.0)
    v1 = m.a
    @test _multi_lhs_counter[] == 1     # first read computes
    v2 = m.a
    @test _multi_lhs_counter[] == 1     # fast-hit: no recompute
    @test v1 === v2                     # returns the identical cached value
end

@testitem "Fast-hit path: cached IndexableProperty wrapper is returned, not rebuilt" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # A bare read of an indexed property caches its IndexableProperty wrapper
    # under the property name; the fast-hit path must return that SAME cached
    # wrapper on repeat access, not build a fresh one (ba00aa9).
    s = AllDefaults()
    ip1 = s.item
    @test isa(ip1, DynamicObjects.IndexableProperty)
    ip2 = s.item
    @test ip1 === ip2
end

@testitem "Parallel cache" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    serial = Par()
    vals_serial = asyncmap(_ -> serial.slow, 1:6)
    # compute-at-most-once: concurrent cold reads of a cached bare prop share the
    # one published value (cache_type=:serial was removed — every cache now dedups).
    @test length(unique(vals_serial)) == 1
    par = Par()
    vals_par = asyncmap(_ -> par.slow, 1:6)
    @test length(unique(vals_par)) == 1
    vals_idx = asyncmap(i -> par.slowi(i), 1:6)
    @test length(unique(vals_idx)) == 6
end

@testitem "Regression" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _regression_path[] = mktempdir()
    getb(x::D1) = x.b
    serial_d1 = D1()
    @test hasproperty(serial_d1, :a) == hasproperty(serial_d1, :b) == true
    @test 2 * serial_d1.a == serial_d1.b == 2
    @test_throws ErrorException @inferred getb(serial_d1)
    @test @cache_status(serial_d1.c) == :unstarted
    @test serial_d1.c == serial_d1.a * serial_d1.b
    @test @cache_status(serial_d1.c) == :ready
    @test @cache_status(serial_d1.d) == :unstarted
    @test serial_d1.d == 1
    @test @cache_status(serial_d1.d) == :ready
    @test serial_d1.d == 1
    serial_d1 = D1()
    @test serial_d1.d == 1
    @test serial_d1.i(1) == 1
    @test @cache_status(serial_d1.ci(2)) == :unstarted
    @test serial_d1.ci(2) == 4
    @test @cache_status(serial_d1.ci(2)) == :ready
    @test @cache_status(serial_d1.ci3(1, 2, 3)) == :unstarted
    @test serial_d1.ci3(1, 2, 3) == 321
    @test isa(serial_d1.ci3, DynamicObjects.IndexableProperty)
    @test @cache_status(serial_d1.ci3(1, 2, 3)) == :ready
    # compute-at-most-once: concurrent reads share one value (was: serial double-compute)
    @test length(unique(asyncmap(i -> serial_d1.parallel_test, 1:10))) == 1
    parallel_d1 = D1()
    @test length(unique(asyncmap(i -> parallel_d1.parallel_test, 1:10))) == 1
    @test length(unique(asyncmap(i -> parallel_d1.parallel_testi(i), 1:10))) == 10
end

@testitem "Let block scoping" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    @test LetScope(5.0).result == 100.0
end

@testitem "Lambda parameter scoping" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    @test LambdaScope(99.0).mapped == [2.0, 4.0, 6.0]
end

@testitem "Shared dependency" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    @test SharedDep(3.0).a == 31.0
    @test SharedDep(3.0).b == 32.0
end

"""
Exercises non-blocking indexed access: a cold read yields Pending, while a
warm read returns its value directly.
"""
@testitem "fetchindex" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    app = AsyncApp()
    @test app.slow(3) == 6
    seen_task = Ref(false)
    result = fetchindex(app.slow, 42) do rv, status
        if isa(rv, Pending)
            seen_task[] = true
            Base.fetch(rv)
        else
            rv
        end
    end
    @test result == 84
    seen_task2 = Ref(false)
    result2 = fetchindex(app.slow, 42) do rv, status
        if isa(rv, Pending)
            seen_task2[] = true
        end
        isa(rv, Pending) ? Base.fetch(rv) : rv
    end
    @test result2 == 84
    @test seen_task2[] == false
end

@testitem "@fetch! kwargs" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    o = FetchKwargs()
    @test o.shorthand() == 110   # `; n_grid` shorthand threads the property (5+5+100)
    @test o.explicit() == 17     # `; n_grid=7` explicit kwarg (5+5+7)
    # Reporter's ask: `@fetch!(p, some_ip(x; kw=1))` => `maybefetchindex!(p, some_ip, x; kw=1)`.
    rw = DynamicObjects._fetch_rewrite(:p, :(some_ip(x; kw=1)))
    @test occursin("maybefetchindex!(p, some_ip, x; kw = 1)", string(rw))
    # Dotted keyword shorthand `; o.n` must become a `:kw`, never a bare call.
    rw2 = DynamicObjects._fetch_rewrite(:p, Expr(:call, :ip, Expr(:parameters, :(o.n))))
    params = rw2.args[findfirst(a -> Meta.isexpr(a, :parameters), rw2.args)]
    @test Meta.isexpr(params.args[1], :kw)
    @test params.args[1].args[1] == :n
end

"""
Ensures scalar and indexed failures expose consistent property context and
retain the original exception through unwrap_error.
"""
@testitem "PropertyComputationError" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # Serial: scalar property
    f = FailingProps()
    err = (@test_throws DynamicObjects.PropertyComputationError f.will_fail).value
    @test err.property == :will_fail
    @test err.type_name == "FailingProps"
    @test DynamicObjects.unwrap_error(err) isa ErrorException

    # Serial: indexed property
    f2 = FailingProps()
    err2 = (@test_throws DynamicObjects.PropertyComputationError f2.will_fail_indexed("abc")).value
    @test err2.property == :will_fail_indexed
    @test err2.indices == ("abc",)

    # Parallel: indexed property. The blocking bare call computes synchronously
    # (fetch defaults to Base.fetch), so it surfaces the PropertyComputationError
    # DIRECTLY — no TaskFailedException wrapper — converging with the serial path
    # (commit 0e07742, synchronous compute on the blocking-default get! path).
    # A TaskFailedException is only observable via non-blocking access
    # (fetch=identity), which fetches the spawned task explicitly.
    pf = FailingProps()
    err3 = (@test_throws DynamicObjects.PropertyComputationError pf.will_fail_indexed("xyz")).value
    @test err3.property == :will_fail_indexed
    @test err3.indices == ("xyz",)
    @test DynamicObjects.unwrap_error(err3) isa ErrorException
end

@testitem "entries / cached_entries" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    app = EntriesApp()
    # Compute some values
    @test app.slow(1) == 2
    @test app.slow(2) == 4
    es = entries(app.slow)
    @test length(es) == 2
    @test all(e -> e.state == :done, es)
    @test Set(e.value for e in es) == Set([2, 4])

    ce = cached_entries(app.slow)
    @test length(ce) == 2
    @test Set(v for (_, v) in ce) == Set([2, 4])
end

@testitem "clear_all_caches!" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _clearall_path[] = mktempdir()
    app = ClearAllApp()
    @test app.a == 42
    @test app.b(3) == 6
    @test @is_cached app.a
    @test @is_cached app.b(3)
    clear_all_caches!(app)
    @test @cache_status(app.a) == :unstarted
    @test @cache_status(app.b(3)) == :unstarted
    # uncached property still works
    @test app.uncached == 99
end

@testitem "PersistentSet" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    path = joinpath(mktempdir(), "test_set.sjl")
    s = PersistentSet(path)
    @test length(s) == 0
    push!(s, "a")
    push!(s, "b")
    @test length(s) == 2
    @test "a" in s
    @test !("c" in s)
    # Persists across instances
    s2 = PersistentSet(path)
    @test length(s2) == 2
    @test "a" in s2
    pop!(s2, "a")
    @test length(s2) == 1
    @test !("a" in s2)
    # Idempotent push
    push!(s2, "b")
    @test length(s2) == 1
end

@testitem "cached_entries on plain Dict" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    app = CallVsBracket()
    app.counted(1)
    app.counted(2)
    ce = cached_entries(app.counted)
    @test length(ce) == 2
    @test Set(v for (_, v) in ce) == Set([2, 4])
end

@testitem "clear_all_caches! on object with no @cached" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    b = Basic(3.0, 4.0)
    # Should be a no-op, not error
    clear_all_caches!(b)
    @test b.r ≈ 5.0
end

@testitem "PersistentSet collect and iterate" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    path = joinpath(mktempdir(), "iter_set.sjl")
    s = PersistentSet(path)
    push!(s, 1)
    push!(s, 2)
    push!(s, 3)
    @test Set(collect(s)) == Set([1, 2, 3])
    # iterate
    items = Set{Any}()
    for item in s
        push!(items, item)
    end
    @test items == Set([1, 2, 3])
end

@testitem "Hash with nested DOs" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # 1. DO with no nested DOs: hash uses raw serialize of fixed fields,
    #    unaffected by the _hash_replace walker (values pass through).
    no_dos = HashNoDOs(7, [1.0, 2.0, 3.0])
    expected = DynamicObjects.persistent_hash((HashNoDOs, (7, [1.0, 2.0, 3.0])))
    @test no_dos.__hash__ == expected

    # 2. Nested DO as a fixed field: parent.__hash__ is driven by the child's
    #    fixed fields — same fields produce the same hash; different fields do not.
    h1 = HashParent(HashLeaf(1, "a"), 42).__hash__
    @test HashParent(HashLeaf(1, "a"), 42).__hash__ == h1
    @test HashParent(HashLeaf(2, "a"), 42).__hash__ != h1
end

@testitem "magic-property dunderization + deprecations" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    o = HashNoDOs(7, [1.0, 2.0, 3.0])
    # dunder access works
    @test o.__hash__ isa String
    @test o.__cache_base__ == "cache"
    @test o.__cache_path__ == joinpath(o.__cache_base__, o.__hash__)
    # ACCESS surface: old data-side names + removed __cache_type__ error
    @test_throws PropertyComputationError o.hash
    @test_throws PropertyComputationError o.cache_path
    @test_throws PropertyComputationError o.cache_base
    @test_throws PropertyComputationError o.hash_fields
    @test_throws PropertyComputationError o.__cache_type__
    # cache_type kwarg is a hard removal error, not a warning
    @test_throws ErrorException HashNoDOs(7, [1.0]; cache_type=:parallel)
    # the cache_type MACRO option (positional `:parallel` or `cache_type=…`) errors too
    for ex in (:(@dynamicstruct :parallel struct _DepMacroCT; a=1; end),
               :(@dynamicstruct cache_type=:parallel struct _DepMacroCT2; a=1; end))
        threw = false
        try; macroexpand(@__MODULE__, ex); catch; threw = true; end
        @test threw
    end
    # DEFINITION surface: declaring an old name errors at expansion time
    for ex in (:(@dynamicstruct struct _DepBadCP; a=1; cache_path="x"; end),
               :(@dynamicstruct struct _DepBadHF; a=1; hash_fields=(1,); end),
               :(@dynamicstruct struct _DepBadCT; a=1; __cache_type__=1; end))
        threw = false
        try; macroexpand(@__MODULE__, ex); catch; threw = true; end
        @test threw
    end
    # a MIGRATED declaration still expands cleanly
    @test macroexpand(@__MODULE__, :(@dynamicstruct struct _DepGoodCP; a=1; __cache_path__="x"; end)) isa Expr
end

@testitem "magic-property bare-ref resolution" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    b = BareRefMagic(3)
    @test b.fromhash   == "h:" * b.__hash__
    @test b.frombase   == "cache"
    @test b.fromstrict === true
    @test b.fromfields == b.__hash_fields__ == (3,)
    # The active pre-inference storage path does not promise an inferred return
    # type, but the ordinary property read still returns the declared value.
    gh(o) = o.fromhash
    @test gh(b) isa String
    # user override wins, and a sibling bare-ref sees it
    o = BareRefOverride()
    @test o.__cache_base__ == "custom"
    @test o.derived == "custom/x"
end

@testitem "DataFrame hash canonicalization" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # Ext-provided _hash_replace(::AbstractDataFrame). Shape assertion
    # doubles as a load guard: if the ext failed to load, _hash_replace(df)
    # would hit the generic `_hash_replace(x) = x` fallthrough and return
    # the df itself, failing this destructure loudly rather than passing
    # vacuously.
    df1 = DataFrame(a=[1, 2, 3], b=["x", "y", "z"])
    df2 = DataFrame(a=[1, 2, 3], b=["x", "y", "z"])

    names_rep, cols_rep = DynamicObjects._hash_replace(df1)
    @test names_rep isa Vector{String}
    @test names_rep == ["a", "b"]
    @test cols_rep isa Vector
    @test cols_rep == [[1, 2, 3], ["x", "y", "z"]]

    h1 = DynamicObjects.persistent_hash(DynamicObjects._hash_replace(df1))
    h2 = DynamicObjects.persistent_hash(DynamicObjects._hash_replace(df2))
    @test h1 == h2  # stable across two independent constructions

    h_copy = DynamicObjects.persistent_hash(DynamicObjects._hash_replace(df1[:, :]))
    @test h1 == h_copy  # equal for df vs df[:, :]
end

@testitem "Cache versioning" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _version_cache_path[] = mktempdir()

    v_obj = VersionedCache()
    u_obj = UnversionedCache()

    # cache_version dispatch
    @test DynamicObjects.cache_version(v_obj, Val(:result)) == v"1"
    @test DynamicObjects.cache_version(u_obj, Val(:result)) === nothing

    # Versioned and unversioned produce different paths
    v_path = DynamicObjects.get_cache_path(v_obj, :result)
    u_path = DynamicObjects.get_cache_path(u_obj, :result)
    @test v_path != u_path

    # Unversioned path is stable (same as a fresh object)
    u_obj2 = UnversionedCache()
    u_path2 = DynamicObjects.get_cache_path(u_obj2, :result)
    @test u_path == u_path2

    # Version string appears in path
    @test occursin("v1.0.0", v_path)
    @test !occursin("v1.0.0", u_path)

    # Indexed properties also pick up the version
    vi_obj = VersionedIndexedCache()
    @test DynamicObjects.cache_version(vi_obj, Val(:result)) == v"1"
    vi_path = DynamicObjects.get_cache_path(vi_obj, :result, "foo")
    @test occursin("v1.0.0", vi_path)
end

# ── compute-at-most-once on the typed-slot path (hardening for todo gbe5di) ──
# A slotted bare COMPUTED property must run its RHS AT MOST ONCE even when many
# threads race a cold slot, and blocking `o.x` reads must coordinate with pollers
# (`fetchproperty`) through the same in-flight latch (`c.computing`). A failed
# compute lands in `c.errors`; every waiter rethrows it and a fresh access clears
# it and recomputes. The atomic counters below observe the actual RHS-run count,
# so a double-compute (a latch regression) is caught deterministically, not just
# masked by first-write-wins publish.
@testmodule DOSlotFixtures begin
using DynamicObjects
export SlotAtMostOnce, SlotFailing, _slot_amo_calls, _slot_fail_calls

_slot_amo_calls = Threads.Atomic{Int}(0)
@dynamicstruct struct SlotAtMostOnce
    x::Int
    v = (Threads.atomic_add!(_slot_amo_calls, 1); sleep(0.03); 2x)
end

_slot_fail_calls = Threads.Atomic{Int}(0)
@dynamicstruct struct SlotFailing
    x::Int
    boom = (Threads.atomic_add!(_slot_fail_calls, 1); sleep(0.02); error("slot boom $x"))
end

end # @testmodule DOSlotFixtures

"""
Races blocking readers against one cold property and proves its RHS executes
exactly once.
"""
@testitem "slot compute-at-most-once (blocking race)" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _slot_amo_calls[] = 0
    o = SlotAtMostOnce(21)
    vals = fetch.([Threads.@spawn o.v for _ in 1:16])   # 16 tasks race the cold slot
    @test all(==(42), vals)                             # every racer sees the one value
    @test _slot_amo_calls[] == 1                        # RHS ran EXACTLY once
    @test o.v == 42                                     # warm read: no recompute
    @test _slot_amo_calls[] == 1
end

@testitem "slot block+poll coherence" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _slot_amo_calls[] = 0
    o = SlotAtMostOnce(50)
    # A poller (fetchproperty → Pending while cold) and a blocking reader race the
    # SAME cold slot; they must coordinate on ONE compute via the latch.
    t_poll = Threads.@spawn fetchproperty(o, :v) do rv, status
        rv isa Pending ? fetch(rv) : rv
    end
    t_block = Threads.@spawn o.v
    @test fetch(t_poll) == 100
    @test fetch(t_block) == 100
    @test _slot_amo_calls[] == 1
    # A poll on the now-warm slot returns the value directly — no Pending handed out.
    saw_pending = Ref(false)
    late = fetchproperty(o, :v) do rv, status
        rv isa Pending && (saw_pending[] = true)
        rv isa Pending ? fetch(rv) : rv
    end
    @test late == 100
    @test saw_pending[] == false
    @test _slot_amo_calls[] == 1
end

"""
Pins failure fan-out, retry, and polling behavior for readers sharing one
in-flight slot computation.
"""
@testitem "slot failure → c.errors → all waiters rethrow" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _slot_fail_calls[] = 0
    o = SlotFailing(7)
    errs = fetch.([Threads.@spawn(try o.boom; nothing catch e; e end) for _ in 1:8])
    @test all(e -> e isa PropertyComputationError, errs)  # every waiter rethrew the recorded error
    @test all(e -> e.property === :boom, errs)
    @test _slot_fail_calls[] == 1                         # RHS ran once; waiters did NOT recompute
    # retry: a fresh access clears the recorded error, recomputes, throws again
    @test_throws PropertyComputationError o.boom
    @test _slot_fail_calls[] == 2
    # poll path: fetch(::Pending) on a failing slot rethrows too
    o2 = SlotFailing(9)
    perr = Ref{Any}(nothing)
    fetchproperty(o2, :boom) do rv, status
        rv isa Pending || return rv
        try fetch(rv) catch e; perr[] = e end
    end
    @test perr[] isa PropertyComputationError
end

# ── `__status__` defaults IN (decision 2f84ap; commits 96c63be → 15357f1) ──
# `compute_property(o, ::Val{:__status__})` returns a `description=""` :state root
# instead of `nothing`, so every DO gets a progress tree without boilerplate.
# Two invariants make that flip safe, and both are load-bearing:
#   * a fresh per-instance root must NOT leak into `__hash__` (else every disk
#     cache lookup misses), and
#   * the root must NOT be LRU-evictable (a re-computed root forks the tree: the
#     web layer keeps rendering the old node while new work attaches to the new).
# `__status__ = nothing` is an ordinary overrideable default — `@include` mounts a
# child under the parent by overriding it, and the point-of-use kwarg opts out.
@testmodule DOStatusFixtures begin
using DynamicObjects, Random
export StatusPlain, StatusChildQuiet, StatusParentDefault,
    StatusParentSilenced, StatusParentSilencedNoSemi,
    StatusParentParentNoSemi, StatusBodySees, StatusBudgeted,
    _TBProgressNode, _status_body_seen

const _TBProgressNode = DynamicObjects.Treebars.ProgressNode

@dynamicstruct struct StatusPlain
    x::Int
    y = 2x
end

@dynamicstruct struct StatusChildQuiet
    __status__ = nothing
    x::Int
    y = 2x
end

@dynamicstruct struct StatusParentDefault
    @include kid = StatusChildQuiet(1)
end

@dynamicstruct struct StatusParentSilenced
    @include kid = StatusChildQuiet(1; __status__ = nothing)
end

# The same opt-out written WITHOUT the semicolon. Julia parses `Child(k = v)` as
# an `Expr(:kw, …)` among the POSITIONAL args, not into the `:parameters` block,
# so `_inject_include_kwargs!` used to miss it, inject a second `__status__`, and
# die at expansion with `keyword argument "__status__" repeated`.
@dynamicstruct struct StatusParentSilencedNoSemi
    @include kid = StatusChildQuiet(1, __status__ = nothing)
end

@dynamicstruct struct StatusParentParentNoSemi
    @include kid = StatusChildQuiet(1, __parent__ = __self__)
end

_status_body_seen = Ref{Any}(:unset)
@dynamicstruct struct StatusBodySees
    x::Int
    y = (_status_body_seen[] = __status__; 2x)
end

@dynamicstruct struct StatusBudgeted
    n::Int
    big1 = randn(20_000)   # ~160 KB each
    big2 = randn(20_000)
    big3 = randn(20_000)
end

end # @testmodule DOStatusFixtures

@testitem "progress status defaults to a state root" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    o = StatusPlain(3)
    @test o.__status__ isa _TBProgressNode
    @test o.__status__ === o.__status__          # cached: one root per instance
    @test o.y == 6
    @test StatusPlain(3).__status__ !== o.__status__  # distinct instances, distinct roots
end

@testitem "progress status constructor kwarg overrides default" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    o = StatusPlain(3; __status__ = nothing)
    @test o.__status__ === nothing
    @test o.y == 6                               # compute still works with progress off
end

@testitem "progress status standalone nothing default" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    o = StatusChildQuiet(1)
    @test o.__status__ === nothing
    @test o.y == 2
end

@testitem "progress status include overrides child default" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # `@include` injects `__status__ = <parent substatus>` as a constructor kwarg,
    # which beats the child's declared `__status__ = nothing`. That override is the
    # point of @include — it is what mounts the child under the parent's tree.
    #
    # ANCESTOR, not direct parent: with implied progress the substatus is parented
    # at the ambient node, so the child mounts under the property that included it
    # rather than flat at the object root. That is the intended shape — the kid's
    # work renders nested beneath `kid`, not beside it — and the root is still what
    # the whole subtree hangs from.
    p = StatusParentDefault()
    @test p.kid.__status__ isa _TBProgressNode
    status_chain(n) = isnothing(n) ? Any[] : pushfirst!(status_chain(n.parent), n)
    @test any(n -> n === p.__status__, status_chain(p.kid.__status__))
end

@testitem "progress status include point of use optout" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # The documented escape hatch: `has_status` at the call site suppresses injection.
    @test StatusParentSilenced().kid.__status__ === nothing
end

@testitem "progress status include optout without a semicolon" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # Both spellings of the escape hatch must silence the subtree. The
    # no-semicolon one is the spelling a user reaches for by mistake, and it used
    # to fail at macro expansion rather than opt out.
    @test StatusParentSilencedNoSemi().kid.__status__ === nothing
    @test StatusParentSilencedNoSemi().kid.y == 2      # child still computes
end

@testitem "progress status include explicit parent without a semicolon" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # `__parent__` had the identical hole. Supplying it before the semicolon must
    # be honoured (not injected a second time), while `__status__` — which the
    # call site did NOT supply — is still injected, so progress stays on.
    p = StatusParentParentNoSemi()
    @test p.kid.__parent__ === p
    @test p.kid.__status__ isa _TBProgressNode
end

# Every kwarg name the finished call carries, in both places Julia may park one.
# Deliberately independent of `_kwarg_name` / `_positional_kwarg_name` (the
# functions under test) — the invariant is what LOWERING sees: each of
# `__parent__` / `__status__` present exactly once.
@testmodule DOIncludeFixtures begin
export _include_kw_names

function _include_kw_names(e::Expr)
    names = Symbol[]
    for a in e.args
        if Meta.isexpr(a, :parameters)
            for kw in a.args
                kw isa Symbol && (push!(names, kw); continue)          # `f(; x)` shorthand
                Meta.isexpr(kw, :kw) && push!(names, kw.args[1])
            end
        elseif Meta.isexpr(a, :kw)
            push!(names, a.args[1])
        end
    end
    names
end

end # @testmodule DOIncludeFixtures

@testitem "include kwarg injection is spelling agnostic" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # `Child(; x)` is the `x = x` shorthand and DOES supply the kwarg; `Child(x)`
    # passes the variable positionally and does NOT. That asymmetry is exactly
    # why the positional scan may only accept `Expr(:kw, …)`.
    for src in ("Child()",
                "Child(1)",
                "Child(; __status__ = nothing)",           # after the semicolon
                "Child(__status__ = nothing)",             # before it
                "Child(1, __status__ = nothing)",          # after a positional value
                "Child(; __parent__ = p)",
                "Child(__parent__ = p)",
                "Child(__parent__ = p, __status__ = nothing)",
                "Child(; __status__)",                     # shorthand supplies it
                "Child(__status__)",                       # a positional VALUE — does not
                "Child(f(__status__ = 1))")                # nested call — not our kwarg
        e = DynamicObjects._inject_include_kwargs!(Meta.parse(src), :kid)
        ns = _include_kw_names(e)
        @test count(==(:__status__), ns) == 1
        @test count(==(:__parent__), ns) == 1
        # The reported symptom was a LOWERING error, so assert against lowering.
        @test !Meta.isexpr(Meta.lower(@__MODULE__, e), :error)
    end
end

@testitem "include kwarg injection preserves the call site" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    e = DynamicObjects._inject_include_kwargs!(Meta.parse("Child(1, __status__ = nothing)"), :kid)
    @test e.args[1] === :Child                       # callee untouched
    @test 1 in e.args                                # positional value survives
    # The call site's own `__status__` is kept where it was written, not moved.
    # (`a.args[2]` is the AST node `:nothing`, not the value `nothing`.)
    @test any(a -> Meta.isexpr(a, :kw) && a.args[1] === :__status__ && a.args[2] === :nothing, e.args)
    # …and only `__parent__` was injected, into the `:parameters` block.
    params = e.args[findfirst(a -> Meta.isexpr(a, :parameters), e.args)]
    @test _include_kw_names(params) == [:__parent__]
end

"""
Verifies that the progress substatus created for a property reaches its body and
is visible from nested work.
"""
@testitem "progress substatus reaches property body" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _status_body_seen[] = :unset
    o = StatusBodySees(3)
    root = o.__status__
    @test o.y == 6
    @test _status_body_seen[] isa _TBProgressNode
    @test _status_body_seen[] !== root           # body gets a child, not the root
    @test _status_body_seen[].parent === root

    _status_body_seen[] = :unset
    o2 = StatusBodySees(3; __status__ = nothing)
    @test o2.y == 6
    @test _status_body_seen[] === nothing        # opted out ⇒ body sees nothing

    # Dunder reads take the `_bare_substatus_f` early-out: no substatus, no recursion
    # (`o.__status__` would otherwise re-enter `__substatus__` → `o.__status__`).
    _status_body_seen[] = :unset
    @test o.__hash__ isa AbstractString
    @test _status_body_seen[] === :unset
end

@testitem "progress status does not perturb cache key" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # `__hash_fields__` walks struct FIELDS; `__status__` is a PropertyCache entry,
    # so per-instance roots must not reach the hash — otherwise the disk cache for a
    # given input would miss on every fresh object.
    a, b = StatusPlain(3), StatusPlain(3)
    @test a.__status__ !== b.__status__
    @test a.__hash__ == b.__hash__
    @test a.__cache_path__ == b.__cache_path__
    @test StatusPlain(3; __status__ = nothing).__hash__ == a.__hash__
    @test StatusPlain(4).__hash__ != a.__hash__
end

@testitem "progress status root is stable across property reads" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # Was two eviction testsets (the status root is pinned; a `nothing` optout
    # stays out of the LRU). The LRU is gone, but the invariant they really
    # guarded is not: reading properties must never replace the status root. A
    # forked tree means the web layer keeps rendering the old node while new
    # work attaches to the new one.
    o = StatusBudgeted(1)
    root = o.__status__
    o.big1; o.big2; o.big3
    @test o.__status__ === root

    # …and an explicit opt-out stays opted out.
    o2 = StatusBudgeted(1; __status__ = nothing)
    @test o2.__status__ === nothing
    o2.big1; o2.big2; o2.big3
    @test o2.__status__ === nothing
end

# --- `@mmap` payload contract (snag: `@mmap … ::TreeData`) ---------------------
# `@mmap`'s gate is the property's RUNTIME VALUE, not its `::T` annotation
# (`_disk_eltype` only steers `load`). Accepted: an `AbstractArray` of isbits
# numeric eltype, or a type an extension claims (`DataFrame`). A non-AbstractArray
# wrapper (`TreeData`, `AxisArray`, …) is rejected at save — after the body has
# already run. Nothing pinned this; `@mmap` had no test coverage at all.

@testmodule DOMmapFixtures begin
using DynamicObjects, DataFrames
export MmapOpaque, MmapHalfDone, MmapWrapArr, MmapPayloads, MmapHealing,
    _mmap_base, _mmap_heal_base, _mmap_heal_counter

# Stands in for `TreeData`: deliberately NOT an `AbstractArray` subtype.
struct MmapOpaque; a::Matrix{Float64}; end

# A type whose owner defined `save` but forgot `load` — the trap the save-side
# error message walks you into ("define save … + the matching load").
struct MmapHalfDone; a::Vector{Float64}; end
DynamicObjects.save(::Val{:mmap}, path::AbstractString, x::MmapHalfDone) =
    (open(io -> write(io, x.a), path, "w"); x)

# An `AbstractArray` *wrapper*. `@mmap` would densify it on save and load it back
# as a bare `Array`, so a `::MmapWrapArr{…}` annotation is REJECTED where the
# struct is defined (D7) rather than silently violated on every read.
struct MmapWrapArr{T,N} <: AbstractArray{T,N}; a::Array{T,N}; end
Base.size(m::MmapWrapArr) = size(m.a)
Base.getindex(m::MmapWrapArr, i...) = m.a[i...]
Base.Array(m::MmapWrapArr) = m.a

_mmap_base = Ref("")
@dynamicstruct struct MmapPayloads
    __cache_base__ = _mmap_base[]
    @mmap annotated::Matrix{Float64} = [1.0 2.0; 3.0 4.0]
    @mmap unannotated               = [5.0, 6.0, 7.0]
    @mmap tbl::DataFrame            = DataFrame(:a => [1.0, 2.0])
    # An abstract supertype is fine: a bare `Matrix` IS an `AbstractMatrix`, so
    # nothing is violated. Only a CONCRETE wrapper annotation is rejected.
    @mmap absmat::AbstractMatrix{Float64} = [8.0 9.0; 10.0 11.0]
    @mmap opaque::MmapOpaque        = MmapOpaque([1.0 2.0; 3.0 4.0])
    # Same value, NO annotation: the gate is the runtime value, so this must fail
    # identically. This is the piece's central claim.
    @mmap opaque_bare               = MmapOpaque([1.0 2.0; 3.0 4.0])
    # Un-annotated DataFrame: `load` sniffs ARROW1 and routes to the ext (2dc42fe).
    @mmap tbl_bare                  = DataFrame(:a => [3.0, 4.0])
    # `save` defined, `load` missing: writes, then cannot be read back.
    @mmap half::MmapHalfDone        = MmapHalfDone([1.0, 2.0])
    wrapped = MmapOpaque(annotated)   # the wrap-on-read escape hatch
end

_mmap_heal_base = Ref("")
_mmap_heal_counter = Ref(0)
@dynamicstruct struct MmapHealing
    __cache_base__ = _mmap_heal_base[]
    @mmap payload::Vector{Float64} = (_mmap_heal_counter[] += 1; [1.0, 2.0, 3.0])
end

end # @testmodule DOMmapFixtures

"""
Defines accepted @mmap payloads, rejects unsupported wrappers, and verifies
read-only mappings plus truncated-file recovery.
"""
@testitem "@mmap payload contract" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    _mmap_base[] = mktempdir()
    o = MmapPayloads()

    # Annotated array: type-stable, mmap-backed, PROT_READ.
    @test o.annotated isa Matrix{Float64}
    @test o.annotated == [1.0 2.0; 3.0 4.0]
    @test_throws ReadOnlyMemoryError o.annotated[1, 1] = 0.0

    # Un-annotated array: self-describing DOMM load.
    @test o.unannotated isa Vector{Float64}
    @test o.unannotated == [5.0, 6.0, 7.0]

    # A pre-existing header-only cache hit is already self-healing: the read
    # path catches `_mmap_check_complete`, deletes the partial file, recomputes,
    # and publishes a complete replacement. This distinguishes the reported
    # cache-hit theory from the actual bug below (a NEW short write being
    # published, then failing at the post-save reload outside that catch).
    _mmap_heal_base[] = mktempdir()
    _mmap_heal_counter[] = 0
    h1 = MmapHealing()
    @test h1.payload == [1.0, 2.0, 3.0]
    heal_path = @cache_path h1.payload
    header_offset = open(heal_path, "r") do io
        _, _, _, offset = DynamicObjects._mmap_read_header(io)
        offset
    end
    # Windows forbids truncating a file while its mmap is live. Drop the only
    # owning object and force finalization before simulating the partial file.
    h1 = nothing
    GC.gc(true)
    open(heal_path, "r+") do io
        truncate(io, header_offset)
    end
    @test filesize(heal_path) == header_offset
    h2 = MmapHealing()
    @test h2.payload == [1.0, 2.0, 3.0]
    @test _mmap_heal_counter[] == 2
    @test filesize(heal_path) == header_offset + 3 * sizeof(Float64)

    # A disk-full write can return normally while leaving only the header on
    # macOS. The post-close validator must reject that temp before
    # `_atomic_save` can rename it into the cache namespace.
    partial_path = tempname()
    write(partial_path, zeros(UInt8, header_offset))
    partial_err = try
        DynamicObjects._mmap_check_written_complete(
            partial_path, header_offset, 3 * sizeof(Float64))
        nothing
    catch e
        e
    end
    @test partial_err !== nothing
    @test occursin("no partial cache entry will be published", sprint(showerror, partial_err))

    # A non-AbstractArray type an extension claims.
    @test o.tbl isa DataFrame
    @test o.tbl.a == [1.0, 2.0]

    # A concrete AbstractArray WRAPPER annotation is rejected where the struct is
    # defined (D7): `@mmap` densifies on save and always loads a bare `Array`, so
    # `::MmapWrapArr{Float64,2}` could only ever be a lie. Previously this
    # round-tripped silently to a `Matrix{Float64}`.
    wrapper_err = try
        @eval @dynamicstruct struct MmapBadWrapper
            @mmap w::MmapWrapArr{Float64,2} = MmapWrapArr([8.0 9.0; 10.0 11.0])
        end
        nothing
    catch e
        e
    end
    @test wrapper_err !== nothing
    wrapper_msg = sprint(showerror, wrapper_err)
    @test occursin("MmapWrapArr", wrapper_msg)
    @test occursin("Array{Float64,2}", wrapper_msg)   # names the annotation to use

    # ...but an abstract supertype annotation still works: a `Matrix` satisfies it.
    @test o.absmat isa Matrix{Float64}
    @test o.absmat == [8.0 9.0; 10.0 11.0]

    # A non-AbstractArray, non-claimed payload is rejected at save, and the error
    # names the wrap-on-read escape hatch.
    err = try; o.opaque; nothing catch e; e end
    @test err !== nothing
    msg = sprint(showerror, err)
    @test occursin("no `save` method", msg)
    @test occursin("MmapOpaque", msg)
    @test occursin("rebuild the wrapper in a plain sibling", msg)

    # …and that hatch works: mmap the backing array, wrap it in a plain sibling.
    @test o.wrapped isa MmapOpaque
    @test o.wrapped.a == [1.0 2.0; 3.0 4.0]

    # Direct `save` on a bare opaque value throws the same way.
    @test_throws ErrorException DynamicObjects.save(Val(:mmap), tempname(), MmapOpaque(zeros(1, 1)))

    # THE CENTRAL CLAIM: the gate is the runtime VALUE, not the `::T` annotation
    # (`_disk_eltype` only steers `load`). So dropping the annotation changes
    # nothing — the same value is rejected the same way.
    bare_err = try; o.opaque_bare; nothing catch e; e end
    @test bare_err !== nothing
    @test occursin("no `save` method", sprint(showerror, bare_err))
    @test occursin("MmapOpaque", sprint(showerror, bare_err))

    # Un-annotated `DataFrame`: `load` sniffs the file's ARROW1 magic and routes to
    # the ext instead of DO's own DOMM array container (2dc42fe). Round-trips, and
    # the columns stay memory-mapped read-only.
    @test o.tbl_bare isa DataFrame
    @test o.tbl_bare.a == [3.0, 4.0]
    @test_throws ReadOnlyMemoryError o.tbl_bare.a[1] = 0.0

    # `save` without its `load`: the file is written, then nothing can read it back.
    # The error must name the type and the missing half, not just the format token.
    half_err = try; o.half; nothing catch e; e end
    @test half_err !== nothing
    half_msg = sprint(showerror, half_err)
    @test occursin("no `load` method", half_msg)
    @test occursin("MmapHalfDone", half_msg)
    @test occursin("BOTH halves", half_msg)

    # Direct `load` with an unclaimed annotated type throws the same way.
    @test_throws ErrorException DynamicObjects.load(Val(:mmap), tempname(), MmapOpaque)
    direct = try; DynamicObjects.load(Val(:mmap), tempname(), MmapOpaque) catch e; e end
    @test occursin("MmapOpaque", sprint(showerror, direct))
end

# --- @fresh @struct inline child (snag fresh-struct-no-6b7bb3e4) ---
# `@fresh @struct` threads the never-cache marker onto the constructor property
# so the call form builds a FRESH child each call, with `__parent__` wired the
# same way the memoizing plain-`@struct` path does. Before the fix the `@fresh`
# wrapper shadowed the inline-child rewrite (no child type, no `__parent__`),
# giving a clean compile that threw `UndefVarError: __parent__` only when the
# call form was first hit.
@testmodule DOFreshFixtures begin
using DynamicObjects
export FreshStructParent, CachedStructParent

@dynamicstruct struct FreshStructParent
    disabled = Set([2, 4])
    disabled_holidays_set() = disabled
    @fresh @struct period(yr::Int, mo::Int) = begin
        public_holidays = let d = __parent__.disabled_holidays_set()
            [h for h in 1:5 if !(h in d)]
        end
        label = string(yr, "-", mo)
    end
end

@dynamicstruct struct CachedStructParent
    disabled = Set([2, 4])
    disabled_holidays_set() = disabled
    @struct period(yr::Int, mo::Int) = begin
        public_holidays = let d = __parent__.disabled_holidays_set()
            [h for h in 1:5 if !(h in d)]
        end
    end
end

end # @testmodule DOFreshFixtures

"""
Checks that @fresh @struct creates a distinct parent-wired child per call,
while the ordinary inline-struct form remains memoized.
"""
@testitem "@fresh @struct inline child (snag fresh-struct-no-6b7bb3e4)" tags=[:core] setup=[DOImports, DOFixtures, DOSlotFixtures, DOStatusFixtures, DOIncludeFixtures, DOMmapFixtures, DOFreshFixtures] begin
    # @fresh @struct: never-cache marker rides onto the constructor property, so
    # the call form builds a fresh child per call with __parent__ wired.
    p = FreshStructParent()
    @test DynamicObjects._never_cache(p, Val(:period)) == true
    c1 = p.period(2026, 7)
    @test c1.__parent__ === p                # __parent__ injected on the fresh path
    @test c1.public_holidays == [1, 3, 5]    # __parent__.disabled_holidays_set() resolved
    @test c1.label == "2026-7"
    c2 = p.period(2026, 7)
    @test c1 !== c2                          # fresh: a distinct instance each call

    # plain @struct: memoized child (same instance), __parent__ still wired.
    q = CachedStructParent()
    @test DynamicObjects._never_cache(q, Val(:period)) == false
    d1 = q.period(2026, 7); d2 = q.period(2026, 7)
    @test d1.public_holidays == [1, 3, 5]
    @test d1 === d2                          # memoized: same instance

    # A disk-cache marker wrapping @struct stays rejected at macro time (the
    # child + __parent__ would never be emitted → clean-compile/broken-live).
    cached_err = try
        @eval @dynamicstruct struct BadCachedStruct
            d = Set([1])
            @cached @struct kid(i::Int) = begin v = __parent__.d end
        end
        nothing
    catch e
        e
    end
    @test cached_err !== nothing
    @test occursin("@cached", sprint(showerror, cached_err))
end

# ── Ambient (annotation-free) progress ───────────────────────────────────────
# An ordinary property/IP read performed inside another property's body mounts
# its progress node under the caller's node, exactly as an explicit `@fetch!`
# would — no `@progress`, no `@fetch!`, no threaded `__progress__` anywhere in
# these fixtures. The docstrings only LABEL the nodes; a node is built either
# way (`_default_substatus`), which is what keeps this distinct from the
# docstring-triggered auto-progress stack that was reverted in 2026-05.
@testmodule DOAmbientFixtures begin
using DynamicObjects
export AmbientLeaf, AmbientMid, AmbientTop, AmbientTwice, AmbientBoom,
    ambient_descendants

@dynamicstruct struct AmbientLeaf
    n::Int
    "Leaf work"
    leafval() = 2n
end

@dynamicstruct struct AmbientMid
    n::Int
    @include leaf = AmbientLeaf(n)
    "Mid work"
    midval() = leaf.leafval() + 1
end

@dynamicstruct struct AmbientTop
    n::Int
    @include mid = AmbientMid(n)
    "Top work"
    topval() = mid.midval() + 100
end

# Two siblings reading the SAME nested IP on the SAME instance: the first
# computes it, the second takes an in-memory hit and must still mount the
# original node with its subtree intact.
@dynamicstruct struct AmbientTwice
    @include t = AmbientTop(5)
    "First consumer"
    first_use() = t.topval()
    "Second consumer"
    second_use() = t.topval()
end

@dynamicstruct struct AmbientBoom
    "Boom leaf"
    boomleaf() = error("nested boom")
    "Boom top"
    boomtop() = boomleaf()
end

function ambient_descendants(node, acc=String[])
    for child in node.children
        push!(acc, child.impl.description)
        ambient_descendants(child, acc)
    end
    acc
end
end # @testmodule DOAmbientFixtures

@testitem "ambient progress — nesting without annotations" tags=[:core] setup=[DOAmbientFixtures] begin
    using DynamicObjects
    const TBNode = DynamicObjects.Treebars.ProgressNode

    # Outside any computation there is nothing to attach to.
    @test DynamicObjects.ambient_progress() === nothing

    o = AmbientTop(3)
    @test o.topval() == 2 * 3 + 1 + 100
    top = DynamicObjects.getstatus(o.topval)
    @test top isa TBNode
    @test top.impl.description == "Top work"
    desc = ambient_descendants(top)
    # Three levels deep, discovered purely from execution nesting.
    @test "Mid work" in desc
    @test "Leaf work" in desc

    # The body sees itself as the ambient node while it runs, and the ambient
    # node is restored afterwards.
    @test DynamicObjects.ambient_progress() === nothing
end

@testitem "ambient progress — cache hit keeps the subtree" tags=[:core] setup=[DOAmbientFixtures] begin
    using DynamicObjects

    x = AmbientTwice()
    @test x.first_use() == x.second_use()

    second = ambient_descendants(DynamicObjects.getstatus(x.second_use))
    # The hit mounts the ORIGINAL node, relabelled in place — not a childless
    # "(cached)" stub, which is the collapsed-subtree bug this guards.
    @test "Top work (cached)" in second
    @test "Mid work" in second
    @test "Leaf work" in second
end

@testitem "ambient progress — nested failure stays visible" tags=[:core] setup=[DOAmbientFixtures] begin
    using DynamicObjects

    b = AmbientBoom()
    @test_throws DynamicObjects.PropertyComputationError b.boomtop()
    node = DynamicObjects.getstatus(b.boomtop)
    # A failed node is pinned rather than detached, so the tree still shows
    # WHICH nested step failed.
    @test "Boom leaf" in ambient_descendants(node)
end

@testitem "ambient progress — with_ambient_progress scoping" tags=[:core] setup=[DOAmbientFixtures] begin
    using DynamicObjects
    const TBNode = DynamicObjects.Treebars.ProgressNode

    root = DynamicObjects.Treebars.initialize_progress!(:state; description="root")
    @test DynamicObjects.ambient_progress() === nothing
    inner = DynamicObjects.with_ambient_progress(root) do
        DynamicObjects.ambient_progress()
    end
    @test inner === root
    @test DynamicObjects.ambient_progress() === nothing

    # `nothing` is transparent: a property with no substatus must not orphan its
    # callees, so the current ambient node stays in place.
    kept = DynamicObjects.with_ambient_progress(root) do
        DynamicObjects.with_ambient_progress(nothing) do
            DynamicObjects.ambient_progress()
        end
    end
    @test kept === root

    # Restored even when the body throws.
    @test_throws ErrorException DynamicObjects.with_ambient_progress(() -> error("x"), root)
    @test DynamicObjects.ambient_progress() === nothing
end
