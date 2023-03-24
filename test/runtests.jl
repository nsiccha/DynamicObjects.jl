using DynamicObject
using Test

Rectangle = Object{:rectangle}
rectangle(height, width) = Rectangle((height=height, width=width))
area(what::Rectangle) = what.height * what.width
rect = rectangle(10, 20)

@testset "DynamicObject.jl" begin
    @test rect.area == 200
end
