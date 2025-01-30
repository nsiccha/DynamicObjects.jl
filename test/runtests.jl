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
    end
    getb(x::D1) = x.b
    d1 = D1()
    @test hasproperty(d1, :a) == hasproperty(d1, :b) == true
    @test 2*d1.a == d1.b == 2
    @test_throws ErrorException @inferred getb(d1)
    @test !isfile(joinpath(path, "c.sjl"))
    @test d1.c == d1.a * d1.b
    @test isfile(joinpath(path, "c.sjl"))
    @test !isfile(joinpath(path, "d.sjl"))
    @test d1.d == 1
    @test isfile(joinpath(path, "d.sjl"))
    @test d1.d == 1
    d1 = D1()
    @test d1.d == 2
    @test isfile(joinpath(path, "d.sjl"))
    @staticstruct struct S1
        a=1
        b=2*a
        getb() = b
        getb1() = self.b
    end
    t1 = S1()
    @test 2*t1.a == t1.b == 2
    @test getb(t1) == getb1(t1)
    @inferred getb(t1)
    @inferred getb1(t1)
end