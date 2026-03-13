using DynamicObjects, Serialization
import DynamicObjects: @persist
using Test

# ── Basic struct: fixed fields + derived properties ──────────────────────────

@testset "Basic properties" begin
    @dynamicstruct struct Basic
        x::Float64
        y::Float64
        r     = sqrt(x^2 + y^2)
        theta = atan(y, x)
        sum2  = x + y
    end

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

# ── setproperty! overrides a cached value ────────────────────────────────────

@testset "setproperty! override" begin
    @dynamicstruct struct Overridable
        x::Float64
        doubled = 2 * x
    end

    o = Overridable(3.0)
    @test o.doubled ≈ 6.0
    o.doubled = 99.0
    @test o.doubled ≈ 99.0
end

# ── Constructor kwargs pre-populate the cache ─────────────────────────────────

@testset "Constructor kwargs" begin
    @dynamicstruct struct WithDefault
        x::Float64
        expensive = x ^ 2
    end

    w = WithDefault(4.0; expensive=0.0)
    @test w.expensive == 0.0   # pre-populated, computation skipped
end

# ── remake ────────────────────────────────────────────────────────────────────

@testset "remake" begin
    @dynamicstruct struct Remakeable
        x::Float64
        y::Float64
        sum_xy = x + y
    end

    orig = Remakeable(1.0, 2.0)
    @test orig.sum_xy ≈ 3.0

    r1 = remake(orig; x=10.0)
    @test r1.x == 10.0
    @test r1.y == 2.0       # copied from orig
    @test r1.sum_xy ≈ 12.0  # recomputed

    r2 = remake(orig; y=20.0)
    @test r2.x == 1.0
    @test r2.y == 20.0
    @test r2.sum_xy ≈ 21.0

    r3 = remake(orig; sum_xy=99.0)  # pre-populate cache
    @test r3.x == 1.0
    @test r3.y == 2.0
    @test r3.sum_xy == 99.0
end

# ── Disk-cached properties ────────────────────────────────────────────────────

@testset "Disk cache" begin
    path = mktempdir()

    @dynamicstruct struct Cached
        cache_path = path
        a = 1
        b = 2 * a
        @cached c = a * b
        # resumable: passes current cached value as keyword arg; nil → 1
        @cached d = isnothing(d) ? 1 : d + 1
    end

    d = Cached()

    # c is not cached yet
    @test @cache_status(d.c) == :unstarted
    @test @is_cached(d.c) == false

    val_c = d.c
    @test val_c == 2          # a=1, b=2, c=1*2=2
    @test @cache_status(d.c) == :ready
    @test @is_cached(d.c) == true

    # @cache_path returns a string path
    cp = @cache_path d.c
    @test isa(cp, AbstractString)
    @test isfile(cp)

    # resumable-style: first access → 1 (nothing → 1 branch)
    @test @cache_status(d.d) == :unstarted
    @test d.d == 1
    @test @cache_status(d.d) == :ready

    # second object with same hash loads the cached value (resumes = false)
    d2 = Cached()
    @test d2.d == 1
end

# ── Indexable properties ───────────────────────────────────────────────────────

@testset "Indexable properties" begin
    path = mktempdir()

    @dynamicstruct struct Idx
        cache_path = path
        i[idx]              = idx
        @cached ci[idx]     = idx ^ 2
        @cached ci3[i, j, k] = i + 10 * j + 100 * k
    end

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

# ── Indexed properties with all-default indices ──────────────────────────────

@testset "All-default indexed properties" begin
    @dynamicstruct struct AllDefaults
        item[x="default"] = "got: $x"
        multi[a=1, b=2] = a + b
    end

    s = AllDefaults()

    # IndexableProperty wrapper should be returned for zero-arg access
    @test isa(s.item, DynamicObjects.IndexableProperty)
    @test isa(s.multi, DynamicObjects.IndexableProperty)

    # Explicit args work
    @test s.item["hello"] == "got: hello"
    @test s.multi[10, 20] == 30

    # Default args work
    @test s.item["default"] == "got: default"
    @test s.multi[1, 2] == 3
end

# ── Call syntax (fresh each time) vs bracket syntax (cached) ─────────────────

@testset "Call vs bracket caching" begin
    counter = Ref(0)

    @dynamicstruct struct CallVsBracket
        counted[x] = (counter[] += 1; x * 2)
    end

    s = CallVsBracket()

    # Bracket syntax: cached per index
    counter[] = 0
    @test s.counted[5] == 10
    @test counter[] == 1
    @test s.counted[5] == 10  # cached — counter should NOT increment
    @test counter[] == 1

    # Different index: computes again
    @test s.counted[6] == 12
    @test counter[] == 2
end

# ── Parallel (threadsafe) cache ───────────────────────────────────────────────

@testset "Parallel cache" begin
    @dynamicstruct struct Par
        slow = (sleep(0.1); randn())
        slowi[i] = (sleep(0.05); i + randn())
    end

    # serial: may compute multiple times
    serial = Par()
    vals_serial = asyncmap(_ -> serial.slow, 1:6)
    @test Threads.nthreads() == 1 || length(unique(vals_serial)) > 1

    # parallel: same task shared → identical result
    par = Par(; cache_type = :parallel)
    vals_par = asyncmap(_ -> par.slow, 1:6)
    @test length(unique(vals_par)) == 1

    # indexable: each index is an independent task
    vals_idx = asyncmap(i -> par.slowi[i], 1:6)
    @test length(unique(vals_idx)) == 6
end

# ── Legacy full-coverage testset (kept for regression) ───────────────────────

@testset "Regression" begin
    path = mktempdir()
    @dynamicstruct struct D1
        cache_path = path
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
    @test serial_d1.d == 1  # resumes=false: reload returns cached value, no recompute
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

# ── Property assignment in RHS ───────────────────────────────────────────────

@testset "Property assignment in RHS" begin
    path = mktempdir()

    @dynamicstruct struct AssignInRhs
        x::Int
        cache_path = path
        @cached flag = false
        toggle[req] = begin
            flag = !flag
            @persist flag
            flag
        end
    end

    s = AssignInRhs(1)
    @test s.flag == false
    s.toggle["go"]
    @test s.flag == true
    s.toggle["go2"]
    @test s.flag == false
end

# ── Let block scoping ────────────────────────────────────────────────────────

@testset "Let block scoping" begin
    @dynamicstruct struct LetScope
        x::Float64
        result = let x = 99.0
            x + 1
        end
    end

    @test LetScope(5.0).result == 100.0
end

# ── Lambda parameter scoping ─────────────────────────────────────────────────

@testset "Lambda parameter scoping" begin
    @dynamicstruct struct LambdaScope
        x::Float64
        items = [1.0, 2.0, 3.0]
        mapped = map(x -> x * 2, items)
    end

    @test LambdaScope(99.0).mapped == [2.0, 4.0, 6.0]
end

# ── Multiple derived properties with shared dependency ────────────────────────

@testset "Shared dependency" begin
    @dynamicstruct struct SharedDep
        x::Float64
        intermediate = x * 10
        a = intermediate + 1
        b = intermediate + 2
    end

    @test SharedDep(3.0).a == 31.0
    @test SharedDep(3.0).b == 32.0
end

# ── @persist macro with disk cache ───────────────────────────────────────────

@testset "Persist with disk cache" begin
    path = mktempdir()

    @dynamicstruct struct Persistable
        cache_path = path
        @cached counter = 0
        increment[req] = begin
            counter = counter + 1
            @persist counter
            counter
        end
    end

    s = Persistable()
    @test s.counter == 0
    s.increment["go"]
    @test s.counter == 1

    # New instance with same cache_path should load persisted value
    s2 = Persistable(; cache_path=path)
    @test s2.counter == 1
end
