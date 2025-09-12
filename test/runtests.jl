using DynamicObjects, Serialization
using Test

@testset begin
    path = mktempdir()
    @dynamicstruct struct D1
        cache_path = path
        a = 1
        b = 2*a
        @cached c = a*b 
        @cached d = isnothing(d) ? 1 : d+1
        i[idx] = idx
        @cached ci[idx] = idx ^ 2
        @cached ci3[i, j, k] = i + 10*j + 100*k
        parallel_test = begin 
            sleep(1)
            randn()
        end
        parallel_testi[i]= begin 
            sleep(1)
            i + randn()
        end
        # @cached rci[idx] = isnothing(rci) 
    end
    getb(x::D1) = x.b
    serial_d1 = D1()
    @test hasproperty(serial_d1, :a) == hasproperty(serial_d1, :b) == true
    @test 2*serial_d1.a == serial_d1.b == 2
    @test_throws ErrorException @inferred getb(serial_d1)
    @test @cache_status(serial_d1.c) == :unstarted
    @test serial_d1.c == serial_d1.a * serial_d1.b
    @test @cache_status(serial_d1.c) == :ready
    @test @cache_status(serial_d1.d) == :unstarted
    @test serial_d1.d == 1
    @test @cache_status(serial_d1.d) == :ready
    @test serial_d1.d == 1
    serial_d1 = D1()
    @test serial_d1.d == 2
    @test serial_d1.i[1] == 1
    @test @cache_status(serial_d1.ci[2]) == :unstarted
    @test serial_d1.ci[2] == 4
    @test @cache_status(serial_d1.ci[2]) == :ready
    @test @cache_status(serial_d1.ci3[1,2,3]) == :unstarted
    @test serial_d1.ci3[1,2,3] == 321
    @test isa(serial_d1.ci3, DynamicObjects.IndexableProperty)
    @test @cache_status(serial_d1.ci3[1,2,3]) == :ready
    @test Threads.nthreads() == 1 || length(unique(asyncmap(i->serial_d1.parallel_test, 1:10))) > 1
    parallel_d1 = D1(;cache_type=:parallel)
    @test length(unique(asyncmap(i->parallel_d1.parallel_test, 1:10))) == 1
    @test length(unique(asyncmap(i->parallel_d1.parallel_testi[i], 1:10))) == 10
end