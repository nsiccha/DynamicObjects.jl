using Test, Documenter, DynamicObjects

@testset "doctest" begin
    doctest(DynamicObjects)
end

Rectangle = DynamicObject{:rectangle}
rectangle(height, width) = Rectangle((height=height, width=width))
area(what::Rectangle) = what.height * what.width
rect = rectangle(10, 20)

@testset "DynamicObjects.jl" begin
    @test rect.area == 200
end
