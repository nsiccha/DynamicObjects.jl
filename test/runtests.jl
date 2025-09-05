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
        # @cached rci[idx] = isnothing(rci) 
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
    @test d1.i[1] == 1
    @test d1.ci[2] == 4
    @test isfile(joinpath(path, "ci_2.sjl"))
    @test d1.ci3[1,2,3] == 321
    @test isa(d1.ci3, DynamicObjects.IndexableProperty)
    @test d1.ci3[1,2,3] == 321
    @test isa(d1.ci3, DynamicObjects.IndexableProperty)
    @test isfile(joinpath(path, "ci3_1_2_3.sjl"))
end