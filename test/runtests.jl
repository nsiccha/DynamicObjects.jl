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
    @test Foo.rect.area == 200
end

module This_module_ensures_that_we_can_use_dynamic_type_by_itself
    using DynamicObjects: @dynamic_type
    @dynamic_type MyType
end

module This_module_ensures_that_we_can_use_dynamic_object_by_itself
    using DynamicObjects: @dynamic_object
    @dynamic_object MyObject param param2  # currently infinite recursion for single-argument
    obj = MyObject(42, 123)
end

@testset "definitions inside modules" begin
    @test_broken isabstracttype(This_module_ensures_that_we_can_use_dynamic_type_by_itself.MyType)
    @test This_module_ensures_that_we_can_use_dynamic_type_by_itself.MyType <: AbstractDynamicObject

    @test This_module_ensures_that_we_can_use_dynamic_object_by_itself.MyObject <: AbstractDynamicObject
    @test This_module_ensures_that_we_can_use_dynamic_object_by_itself.obj isa DynamicObject
end

@testset "zero-argument types" begin
    @dynamic_object ZeroObject
    @test_broken ZeroObject()
end
