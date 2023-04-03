using Test, Documenter, DynamicObjects

@testset "doctest" begin
    doctest(DynamicObjects)
end

module Foo
    using DynamicObjects
    Rectangle = DynamicObject{:rectangle}
    rectangle(height, width) = Rectangle((height=height, width=width))
    area(what::Rectangle) = what.height * what.width
    rect = rectangle(10, 20)
end

@testset "DynamicObjects.jl" begin
    @test Foo.area(Foo.rect) == 200
    @test_broken Foo.rect.area == 200
end

module FooBar
# ISSUE: this does not work without explicitly importing AbstractDynamicObject
    using DynamicObjects: @dynamic_type, AbstractDynamicObject
    @dynamic_type MyType
end
