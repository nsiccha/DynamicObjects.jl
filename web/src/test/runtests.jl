using TestModules, Random, DynamicObjects, Serialization, Arrow, DataFrames
import DynamicObjects: @persist, entries, cached_entries, clear_all_caches!, PersistentSet, accessed_keys, record_access!

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

@dynamicstruct struct Overridable
    x::Float64
    doubled = 2 * x
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

_assign_in_rhs_path = Ref("")
@dynamicstruct struct AssignInRhs
    x::Int
    __cache_path__ = _assign_in_rhs_path[]
    @cached flag = false
    toggle(req) = begin
        # Bare `flag = !flag` would trip the property-shadow check
        # (post f4d7c14: error, was warn). Route the cache write
        # through the explicit `setproperty!` path instead — same
        # observable effect (writes to the property cache), no
        # ambiguity for the macro's RHS walker.
        __self__.flag = !flag
        @persist flag
        flag
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

_persistable_path = Ref("")
@dynamicstruct struct Persistable
    __cache_path__ = _persistable_path[]
    @cached counter = 0
    increment(req) = begin
        # See `AssignInRhs` above — explicit `setproperty!` path
        # avoids tripping the macro's property-shadow check.
        __self__.counter = counter + 1
        @persist counter
        counter
    end
end

@dynamicstruct struct EntriesApp
    slow(key) = (sleep(0.05); key * 2)
end

_cached_keys_path = Ref("")
@dynamicstruct struct CachedKeysApp
    __cache_path__ = _cached_keys_path[]
    @cached result(key) = key ^ 2
end

_clearall_path = Ref("")
@dynamicstruct struct ClearAllApp
    __cache_path__ = _clearall_path[]
    @cached a = 42
    @cached b(k) = k * 2
    uncached = 99
end

_kwargs_keys_path = Ref("")
@dynamicstruct struct KwargsKeysApp
    __cache_path__ = _kwargs_keys_path[]
    @cached result(key; mode="default") = "$key:$mode"
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

@dynamicstruct struct HashParentTuple
    leaves::Tuple
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

# --- Tests ---

@testset "Multi-lhs assignment" begin
    _multi_lhs_counter[] = 0
    m = MultiLhs(3.0)
    _multi_lhs_counter[] = 0
    @test m.a == 3.0
    @test _multi_lhs_counter[] == 1
    @test m.b == 6.0
    @test _multi_lhs_counter[] == 1
    @test m.c == 9.0
end

@testset "Multi-lhs with @cached" begin
    _multi_lhs_cached_path[] = mktempdir()
    c = CachedMultiLhs()
    @test c.a == 1
    @test c.b == 2
    group_name = Symbol("_tuple_a_b")
    @test @cache_status(c._tuple_a_b) == :ready
end

@testset "Multi-lhs three values" begin
    t = ThreeValues()
    @test t.x == 10
    @test t.y == 20
    @test t.z == 30
end

@testset "Named destructuring (;a, b) = ..." begin
    _named_destr_counter[] = 0
    n = NamedDestr(3.0)
    _named_destr_counter[] = 0
    @test n.val == 9.0
    @test _named_destr_counter[] == 1
    @test n.grad == 6.0
    @test _named_destr_counter[] == 1
    @test n.sum_vg == 15.0
end

@testset "Named destructuring with rename" begin
    r = RenameDestr(3.0)
    @test r.x_val == 9.0
    @test r.x_grad == 6.0
end

@testset "Named destructuring with prefix" begin
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

@testset "Named destructuring mixed" begin
    m = MixedDestr()
    @test m.a == 1
    @test m.x_b == 2
    @test m.y_c == 3
    @test m.y_d == 4
end

@testset "@clear_cache!" begin
    _clearable_path[] = mktempdir()
    c = Clearable()
    val1 = c.result
    @test @is_cached c.result
    @clear_cache! c.result
    @test @cache_status(c.result) == :unstarted
    val2 = c.result
    @test @is_cached c.result
    @test c.indexed[3] == 9
    @test c.indexed[4] == 16
    @test @is_cached c.indexed[3]
    @test @is_cached c.indexed[4]
    @clear_cache! c.indexed[3]
    @test @cache_status(c.indexed[3]) == :unstarted
    @test @is_cached c.indexed[4]
    c.indexed[3]
    @test @is_cached c.indexed[3]
    @clear_cache! c.indexed
    @test @cache_status(c.indexed[3]) == :unstarted
    @test @cache_status(c.indexed[4]) == :unstarted
end

@testset "Constructor named parameters" begin
    t = TwoFields(1.0, 2)
    @test t.sum_xy == 3.0
    @test_throws MethodError TwoFields(1.0)
    @test_throws MethodError TwoFields(1.0, 2, 3)
end

@testset "Basic properties" begin
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

@testset "setproperty! override" begin
    o = Overridable(3.0)
    @test o.doubled ≈ 6.0
    o.doubled = 99.0
    @test o.doubled ≈ 99.0
end

@testset "Constructor kwargs" begin
    w = WithDefault(4.0; expensive=0.0)
    @test w.expensive == 0.0
end

@testset "remake" begin
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

@testset "Disk cache" begin
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

@testset "Indexable properties" begin
    _idx_path[] = mktempdir()
    s = Idx()
    @test s.i[5]        == 5
    @test s.i[10]       == 10
    @test @cache_status(s.ci[3]) == :unstarted
    @test s.ci[3]       == 9
    @test @cache_status(s.ci[3]) == :ready
    @test @cache_status(s.ci3[1, 2, 3]) == :unstarted
    @test s.ci3[1, 2, 3] == 321
    @test @cache_status(s.ci3[1, 2, 3]) == :ready
    @test isa(s.ci3, DynamicObjects.IndexableProperty)
end

@testset "All-default indexed properties" begin
    s = AllDefaults()
    @test isa(s.item, DynamicObjects.IndexableProperty)
    @test isa(s.multi, DynamicObjects.IndexableProperty)
    @test s.item["hello"] == "got: hello"
    @test s.multi[10, 20] == 30
    @test s.item["default"] == "got: default"
    @test s.multi[1, 2] == 3
end

@testset "Call vs bracket caching" begin
    _call_vs_bracket_counter[] = 0
    s = CallVsBracket()
    _call_vs_bracket_counter[] = 0
    @test s.counted[5] == 10
    @test _call_vs_bracket_counter[] == 1
    @test s.counted[5] == 10
    @test _call_vs_bracket_counter[] == 1
    @test s.counted[6] == 12
    @test _call_vs_bracket_counter[] == 2
end

@testset "Fast-hit path: repeat bare read hits cache (no recompute)" begin
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

@testset "Fast-hit path: cached IndexableProperty wrapper is returned, not rebuilt" begin
    # A bare read of an indexed property caches its IndexableProperty wrapper
    # under the property name; the fast-hit path must return that SAME cached
    # wrapper on repeat access, not build a fresh one (ba00aa9).
    s = AllDefaults()
    ip1 = s.item
    @test isa(ip1, DynamicObjects.IndexableProperty)
    ip2 = s.item
    @test ip1 === ip2
end

@testset "Parallel cache" begin
    serial = Par()
    vals_serial = asyncmap(_ -> serial.slow, 1:6)
    # compute-at-most-once: concurrent cold reads of a cached bare prop share the
    # one published value (cache_type=:serial was removed — every cache now dedups).
    @test length(unique(vals_serial)) == 1
    par = Par()
    vals_par = asyncmap(_ -> par.slow, 1:6)
    @test length(unique(vals_par)) == 1
    vals_idx = asyncmap(i -> par.slowi[i], 1:6)
    @test length(unique(vals_idx)) == 6
end

@testset "Regression" begin
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
    @test serial_d1.i[1] == 1
    @test @cache_status(serial_d1.ci[2]) == :unstarted
    @test serial_d1.ci[2] == 4
    @test @cache_status(serial_d1.ci[2]) == :ready
    @test @cache_status(serial_d1.ci3[1, 2, 3]) == :unstarted
    @test serial_d1.ci3[1, 2, 3] == 321
    @test isa(serial_d1.ci3, DynamicObjects.IndexableProperty)
    @test @cache_status(serial_d1.ci3(1, 2, 3)) == :ready
    # compute-at-most-once: concurrent reads share one value (was: serial double-compute)
    @test length(unique(asyncmap(i -> serial_d1.parallel_test, 1:10))) == 1
    parallel_d1 = D1()
    @test length(unique(asyncmap(i -> parallel_d1.parallel_test, 1:10))) == 1
    @test length(unique(asyncmap(i -> parallel_d1.parallel_testi[i], 1:10))) == 10
end

@testset "Property assignment in RHS" begin
    _assign_in_rhs_path[] = mktempdir()
    s = AssignInRhs(1)
    @test s.flag == false
    s.toggle["go"]
    @test s.flag == true
    s.toggle["go2"]
    @test s.flag == false
end

@testset "Let block scoping" begin
    @test LetScope(5.0).result == 100.0
end

@testset "Lambda parameter scoping" begin
    @test LambdaScope(99.0).mapped == [2.0, 4.0, 6.0]
end

@testset "Shared dependency" begin
    @test SharedDep(3.0).a == 31.0
    @test SharedDep(3.0).b == 32.0
end

@testset "fetchindex" begin
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

@testset "@fetch! kwargs" begin
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

@testset "Persist with disk cache" begin
    _persistable_path[] = mktempdir()
    s = Persistable()
    @test s.counter == 0
    s.increment["go"]
    @test s.counter == 1
    s2 = Persistable(; __cache_path__=_persistable_path[])
    @test s2.counter == 1
end

@testset "PropertyComputationError" begin
    # Serial: scalar property
    f = FailingProps()
    err = (@test_throws DynamicObjects.PropertyComputationError f.will_fail).value
    @test err.property == :will_fail
    @test err.type_name == "FailingProps"
    @test DynamicObjects.unwrap_error(err) isa ErrorException

    # Serial: indexed property
    f2 = FailingProps()
    err2 = (@test_throws DynamicObjects.PropertyComputationError f2.will_fail_indexed["abc"]).value
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

@testset "entries / cached_entries" begin
    app = EntriesApp()
    # Compute some values
    @test app.slow[1] == 2
    @test app.slow[2] == 4
    es = entries(app.slow)
    @test length(es) == 2
    @test all(e -> e.state == :done, es)
    @test Set(e.value for e in es) == Set([2, 4])

    ce = cached_entries(app.slow)
    @test length(ce) == 2
    @test Set(v for (_, v) in ce) == Set([2, 4])
end

@testset "clear_all_caches!" begin
    _clearall_path[] = mktempdir()
    app = ClearAllApp()
    @test app.a == 42
    @test app.b[3] == 6
    @test @is_cached app.a
    @test @is_cached app.b[3]
    clear_all_caches!(app)
    @test @cache_status(app.a) == :unstarted
    @test @cache_status(app.b[3]) == :unstarted
    # uncached property still works
    @test app.uncached == 99
end

@testset "PersistentSet" begin
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

@testset "accessed_keys tracking" begin
    _cached_keys_path[] = mktempdir()
    app = CachedKeysApp()
    # No keys accessed yet
    ak = accessed_keys(app.result)
    @test isempty(ak)
    # Access some keys
    @test app.result[3] == 9
    @test app.result[5] == 25
    ak = accessed_keys(app.result)
    @test length(ak) == 2
    @test ((3,), (;)) in ak
    @test ((5,), (;)) in ak
    # Accessing same key again doesn't duplicate
    @test app.result[3] == 9
    ak = accessed_keys(app.result)
    @test length(ak) == 2
    # New instance with same cache_path sees the same keys
    app2 = CachedKeysApp(; __cache_path__=_cached_keys_path[])
    ak2 = accessed_keys(app2.result)
    @test length(ak2) == 2
end

@testset "accessed_keys with kwargs" begin
    _kwargs_keys_path[] = mktempdir()
    app = KwargsKeysApp()
    @test app.result("x") == "x:default"
    @test app.result("x"; mode="fast") == "x:fast"
    ak = accessed_keys(app.result)
    @test length(ak) == 2
    # Call with no explicit kwargs records (("x",), (;))
    @test (("x",), (;)) in ak
    # Call with explicit kwargs records them in the key
    @test (("x",), (;mode="fast")) in ak
end

@testset "cached_entries on plain Dict" begin
    app = CallVsBracket()
    app.counted[1]
    app.counted[2]
    ce = cached_entries(app.counted)
    @test length(ce) == 2
    @test Set(v for (_, v) in ce) == Set([2, 4])
end

@testset "clear_all_caches! on object with no @cached" begin
    b = Basic(3.0, 4.0)
    # Should be a no-op, not error
    clear_all_caches!(b)
    @test b.r ≈ 5.0
end

@testset "PersistentSet collect and iterate" begin
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

@testset "Hash with nested DOs" begin
    # 1. DO with no nested DOs: hash uses raw serialize of fixed fields,
    #    unaffected by the _hash_replace walker (values pass through).
    no_dos = HashNoDOs(7, [1.0, 2.0, 3.0])
    expected = DynamicObjects.persistent_hash((HashNoDOs, (7, [1.0, 2.0, 3.0])))
    @test no_dos.__hash__ == expected

    # 2. Nested DO as a fixed field: parent.__hash__ depends on child.__hash__
    #    only, not on the child's cache dict contents.
    leaf = HashLeaf(1, "a")
    parent1 = HashParent(leaf, 42)
    h1 = parent1.__hash__
    # Mutate the leaf's cache dict. Pre-fix, this would change parent.__hash__
    # because the raw leaf (including its cache) got serialized.
    getfield(leaf, :cache)[:garbage] = rand(100)
    parent2 = HashParent(leaf, 42)  # fresh parent wrapping the mutated leaf
    @test parent2.__hash__ == h1

    # 3. Different leaf fixed fields → different parent hash.
    parent3 = HashParent(HashLeaf(2, "a"), 42)
    @test parent3.__hash__ != h1

    # 4. Tuple of DOs: shallow recursion collapses each DO via _hash_replace.
    leaves = (HashLeaf(1, "a"), HashLeaf(2, "b"))
    p_tup1 = HashParentTuple(leaves, 0)
    h_tup = p_tup1.__hash__
    getfield(leaves[1], :cache)[:junk] = :junk
    p_tup2 = HashParentTuple(leaves, 0)
    @test p_tup2.__hash__ == h_tup
end

@testset "magic-property dunderization + deprecations" begin
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

@testset "magic-property bare-ref resolution" begin
    b = BareRefMagic(3)
    @test b.fromhash   == "h:" * b.__hash__
    @test b.frombase   == "cache"
    @test b.fromstrict === true
    @test b.fromfields == b.__hash_fields__ == (3,)
    # a body reading a magic dunder inherits its slot type (String, not Any)
    gh(o) = o.fromhash
    @test only(Base.return_types(gh, (typeof(b),))) === String
    # user override wins, and a sibling bare-ref sees it
    o = BareRefOverride()
    @test o.__cache_base__ == "custom"
    @test o.derived == "custom/x"
end

@testset "DataFrame hash canonicalization" begin
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

@testset "Cache versioning" begin
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

@testset "slot compute-at-most-once (blocking race)" begin
    _slot_amo_calls[] = 0
    o = SlotAtMostOnce(21)
    vals = fetch.([Threads.@spawn o.v for _ in 1:16])   # 16 tasks race the cold slot
    @test all(==(42), vals)                             # every racer sees the one value
    @test _slot_amo_calls[] == 1                        # RHS ran EXACTLY once
    @test o.v == 42                                     # warm read: no recompute
    @test _slot_amo_calls[] == 1
end

@testset "slot block+poll coherence" begin
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

@testset "slot failure → c.errors → all waiters rethrow" begin
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
    perr = nothing
    fetchproperty(o2, :boom) do rv, status
        rv isa Pending || return rv
        try fetch(rv) catch e; perr = e end
    end
    @test perr isa PropertyComputationError
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

@testset "progress status defaults to a state root" begin
    o = StatusPlain(3)
    @test o.__status__ isa _TBProgressNode
    @test o.__status__ === o.__status__          # cached: one root per instance
    @test o.y == 6
    @test StatusPlain(3).__status__ !== o.__status__  # distinct instances, distinct roots
end

@testset "progress status constructor kwarg overrides default" begin
    o = StatusPlain(3; __status__ = nothing)
    @test o.__status__ === nothing
    @test o.y == 6                               # compute still works with progress off
end

@testset "progress status standalone nothing default" begin
    o = StatusChildQuiet(1)
    @test o.__status__ === nothing
    @test o.y == 2
end

@testset "progress status include overrides child default" begin
    # `@include` injects `__status__ = <parent substatus>` as a constructor kwarg,
    # which beats the child's declared `__status__ = nothing`. That override is the
    # point of @include — it is what mounts the child under the parent's tree.
    p = StatusParentDefault()
    @test p.kid.__status__ isa _TBProgressNode
    @test p.kid.__status__.parent === p.__status__
end

@testset "progress status include point of use optout" begin
    # The documented escape hatch: `has_status` at the call site suppresses injection.
    @test StatusParentSilenced().kid.__status__ === nothing
end

@testset "progress status include optout without a semicolon" begin
    # Both spellings of the escape hatch must silence the subtree. The
    # no-semicolon one is the spelling a user reaches for by mistake, and it used
    # to fail at macro expansion rather than opt out.
    @test StatusParentSilencedNoSemi().kid.__status__ === nothing
    @test StatusParentSilencedNoSemi().kid.y == 2      # child still computes
end

@testset "progress status include explicit parent without a semicolon" begin
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

@testset "include kwarg injection is spelling agnostic" begin
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

@testset "include kwarg injection preserves the call site" begin
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

@testset "progress substatus reaches property body" begin
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

@testset "progress status does not perturb cache key" begin
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

@testset "progress status root is stable across property reads" begin
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

# Stands in for `TreeData`: deliberately NOT an `AbstractArray` subtype.
struct MmapOpaque; a::Matrix{Float64}; end

# A type whose owner defined `save` but forgot `load` — the trap the save-side
# error message walks you into ("define save … + the matching load").
struct MmapHalfDone; a::Vector{Float64}; end
DynamicObjects.save(::Val{:mmap}, path::AbstractString, x::MmapHalfDone) =
    (open(io -> write(io, x.a), path, "w"); x)

# An `AbstractArray` *wrapper*: accepted, but round-trips to a bare `Array`.
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
    @mmap wrapper::MmapWrapArr{Float64,2} = MmapWrapArr([8.0 9.0; 10.0 11.0])
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

@testset "@mmap payload contract" begin
    _mmap_base[] = mktempdir()
    o = MmapPayloads()

    # Annotated array: type-stable, mmap-backed, PROT_READ.
    @test o.annotated isa Matrix{Float64}
    @test o.annotated == [1.0 2.0; 3.0 4.0]
    @test_throws ReadOnlyMemoryError o.annotated[1, 1] = 0.0

    # Un-annotated array: self-describing DOMM load.
    @test o.unannotated isa Vector{Float64}
    @test o.unannotated == [5.0, 6.0, 7.0]

    # A non-AbstractArray type an extension claims.
    @test o.tbl isa DataFrame
    @test o.tbl.a == [1.0, 2.0]

    # An AbstractArray wrapper is densified on save and comes back a bare Array —
    # the `::MmapWrapArr` annotation does NOT survive the round trip.
    @test o.wrapper isa Matrix{Float64}
    @test !(o.wrapper isa MmapWrapArr)
    @test o.wrapper == [8.0 9.0; 10.0 11.0]

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
