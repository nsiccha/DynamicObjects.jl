using TestModules, Random, DynamicObjects, Serialization
import DynamicObjects: @persist

# --- Struct definitions (hoisted to module scope) ---

_multi_lhs_counter = Ref(0)
@dynamicstruct struct MultiLhs
    x::Float64
    a, b = (_multi_lhs_counter[] += 1; (x, 2x))
    c = a + b
end

_multi_lhs_cached_path = Ref("")
@dynamicstruct struct CachedMultiLhs
    cache_path = _multi_lhs_cached_path[]
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
    cache_path = _clearable_path[]
    @cached result = sum(rand(10))
    @cached indexed[k] = k ^ 2
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
    cache_path = _disk_cache_path[]
    a = 1
    b = 2 * a
    @cached c = a * b
    @cached d = isnothing(d) ? 1 : d + 1
end

_idx_path = Ref("")
@dynamicstruct struct Idx
    cache_path = _idx_path[]
    i[idx]              = idx
    @cached ci[idx]     = idx ^ 2
    @cached ci3[i, j, k] = i + 10 * j + 100 * k
end

@dynamicstruct struct AllDefaults
    item[x="default"] = "got: $x"
    multi[a=1, b=2] = a + b
end

_call_vs_bracket_counter = Ref(0)
@dynamicstruct struct CallVsBracket
    counted[x] = (_call_vs_bracket_counter[] += 1; x * 2)
end

@dynamicstruct struct Par
    slow = (sleep(0.1); randn())
    slowi[i] = (sleep(0.05); i + randn())
end

_regression_path = Ref("")
@dynamicstruct struct D1
    cache_path = _regression_path[]
    a = 1
    b = 2 * a
    @cached c = a * b
    @cached d = isnothing(d) ? 1 : d + 1
    i[idx] = idx
    @cached ci[idx] = idx ^ 2
    @cached ci3[i, j, k] = i + 10 * j + 100 * k
    parallel_test = begin
        sleep(1)
        randn()
    end
    parallel_testi[i] = begin
        sleep(1)
        i + randn()
    end
end

_assign_in_rhs_path = Ref("")
@dynamicstruct struct AssignInRhs
    x::Int
    cache_path = _assign_in_rhs_path[]
    @cached flag = false
    toggle[req] = begin
        flag = !flag
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
    slow[key] = (sleep(0.05); key * 2)
end

@dynamicstruct struct FailingProps
    will_fail = error("serial failure")
    will_fail_indexed(key) = error("serial failure for key=$key")
end

_persistable_path = Ref("")
@dynamicstruct struct Persistable
    cache_path = _persistable_path[]
    @cached counter = 0
    increment[req] = begin
        counter = counter + 1
        @persist counter
        counter
    end
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

@testset "Parallel cache" begin
    serial = Par()
    vals_serial = asyncmap(_ -> serial.slow, 1:6)
    @test Threads.nthreads() == 1 || length(unique(vals_serial)) > 1
    par = Par(; cache_type = :parallel)
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
    @test @cache_status(serial_d1.ci3[1, 2, 3]) == :ready
    @test Threads.nthreads() == 1 || length(unique(asyncmap(i -> serial_d1.parallel_test, 1:10))) > 1
    parallel_d1 = D1(; cache_type = :parallel)
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
    app = AsyncApp(; cache_type=:parallel)
    @test app.slow[3] == 6
    seen_task = Ref(false)
    result = fetchindex(app.slow, 42) do rv, status
        if isa(rv, Task)
            seen_task[] = true
            Base.fetch(rv)
        else
            rv
        end
    end
    @test result == 84
    seen_task2 = Ref(false)
    result2 = fetchindex(app.slow, 42) do rv, status
        if isa(rv, Task)
            seen_task2[] = true
        end
        isa(rv, Task) ? Base.fetch(rv) : rv
    end
    @test result2 == 84
    @test seen_task2[] == false
end

@testset "Persist with disk cache" begin
    _persistable_path[] = mktempdir()
    s = Persistable()
    @test s.counter == 0
    s.increment["go"]
    @test s.counter == 1
    s2 = Persistable(; cache_path=_persistable_path[])
    @test s2.counter == 1
end

@testset "PropertyComputationError" begin
    # Serial: scalar property
    f = FailingProps()
    err = try; f.will_fail; nothing; catch e; e; end
    @test err isa DynamicObjects.PropertyComputationError
    @test err.property == :will_fail
    @test err.type_name == "FailingProps"
    @test DynamicObjects.unwrap_error(err) isa ErrorException

    # Serial: indexed property
    f2 = FailingProps()
    err2 = try; f2.will_fail_indexed["abc"]; nothing; catch e; e; end
    @test err2 isa DynamicObjects.PropertyComputationError
    @test err2.property == :will_fail_indexed
    @test err2.indices == ("abc",)

    # Parallel: indexed property (TaskFailedException wrapped)
    pf = FailingProps(; cache_type=:parallel)
    err3 = try; pf.will_fail_indexed["xyz"]; nothing; catch e; e; end
    @test err3 isa Base.TaskFailedException
    inner = err3.task.exception
    @test inner isa DynamicObjects.PropertyComputationError
    @test inner.property == :will_fail_indexed
    @test DynamicObjects.unwrap_error(inner) isa ErrorException
end
