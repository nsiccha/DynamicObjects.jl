using TestItemRunner

@testmodule ParametricFixtures begin
using DynamicObjects
export AbstractParamView, EmptyParam, OneParamProp, WrappedValue, BoundedValue,
    TwoParams, NonParametric

abstract type AbstractParamView end

# The shape the SbPMX review file uses: a parameter that no field mentions, on an
# otherwise EMPTY struct, under an abstract supertype. The emitted inner
# constructor cannot infer `Kind`, so it must bind it on the signature and apply
# it to `new` — a bare `new` is a hard expansion error ("too few type parameters
# specified in new{...}"), which is why no parametric @dynamicstruct expanded.
@dynamicstruct struct EmptyParam{Kind} <: AbstractParamView end

@dynamicstruct struct OneParamProp{Kind} <: AbstractParamView
    base::String
    # A type parameter is bound on every emitted method, so a body reads it the
    # way it reads a sibling.
    tagged = string(base, "-", Kind)
    scaled(i::Int) = string(Kind, "/", base, i)
end

# Parameters the fields DO determine: `WrappedValue(1)` must keep working, not
# just `WrappedValue{Int}(1)`.
@dynamicstruct struct WrappedValue{T}
    value::T
    doubled = value + value
end

@dynamicstruct struct BoundedValue{T<:Real}
    value::T
    halved = value / 2
end

@dynamicstruct struct TwoParams{A,B}
    left::A
    right::B
    joined = string(left, "|", right)
end

@dynamicstruct struct NonParametric
    x::Int
    doubled = 2x
end
end

@testitem "an empty parametric struct expands" setup=[ParametricFixtures] begin
using DynamicObjects

v = EmptyParam{:qt}()
@test v isa EmptyParam{:qt}
@test v isa AbstractParamView          # the supertype survives the rewrite
@test typeof(v) !== EmptyParam         # the parameter is really applied
@test DynamicObjects.meta(EmptyParam{:qt}) == Pair{Symbol,NamedTuple}[]
@test EmptyParam{:other}() isa AbstractParamView
end

@testitem "type parameters are readable from property bodies" setup=[ParametricFixtures] begin
using DynamicObjects

o = OneParamProp{:qt}("b")
@test o.base == "b"
@test o.tagged == "b-qt"
@test o.scaled(3) == "qt/b3"
# A different parameter is a different type with its own methods and values.
@test OneParamProp{:pk}("b").tagged == "b-pk"
@test typeof(o) !== typeof(OneParamProp{:pk}("b"))
end

@testitem "field-determined parameters keep the inferring constructor" setup=[ParametricFixtures] begin
using DynamicObjects

# Declaring an inner constructor normally replaces BOTH of Julia's defaults;
# the inferring one is re-emitted when every parameter occurs in a field type.
@test typeof(WrappedValue(3)) === WrappedValue{Int}
@test WrappedValue(3).doubled == 6
@test typeof(WrappedValue{Float64}(1.5)) === WrappedValue{Float64}
@test WrappedValue{Float64}(1.5).doubled == 3.0

@test typeof(BoundedValue(2.0)) === BoundedValue{Float64}
@test BoundedValue(2.0).halved == 1.0
@test_throws TypeError BoundedValue{String}("x")

@test typeof(TwoParams(1, "a")) === TwoParams{Int,String}
@test TwoParams(1, "a").joined == "1|a"

# Not re-emitted where it would be unsolvable: `EmptyParam()` has no `Kind`.
@test_throws MethodError EmptyParam()
end

@testitem "the per-type machinery dispatches on the applied type" setup=[ParametricFixtures] begin
using DynamicObjects

T = OneParamProp{:qt}
o = T("b")
# `::Type{OneParamProp}` would match the UnionAll only — every per-type method
# has to accept the type a user actually holds.
@test first.(DynamicObjects.meta(T)) == [:base, :tagged, :scaled]
@test first.(property_descriptors(T)) == [:base, :tagged, :scaled]
@test property_descriptor(T, :tagged).dependencies == [:base]
@test option_declarations(T) == Pair{Symbol,NamedTuple}[]
@test occursin("OneParamProp", sprint(io -> print_structure(io, T)))
@test o.__cache_path__ isa AbstractString
@test o.__hash__ isa AbstractString

# remake/remount rebuild the SAME applied type, not the UnionAll.
r = remake(o; base = "c")
@test typeof(r) === T
@test r.tagged == "c-qt"
end

@testitem "non-parametric structs are untouched" setup=[ParametricFixtures] begin
using DynamicObjects

o = NonParametric(21)
@test o.doubled == 42
@test typeof(remake(o; x = 1)) === NonParametric
@test first.(DynamicObjects.meta(NonParametric)) == [:x, :doubled]
end
