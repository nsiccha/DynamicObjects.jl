using TestItemRunner

@testmodule RhsLessFixtures begin
using DynamicObjects
export RhsLessFixture, MarkedRhsLessFixture, ShadowingFixture

# `f(i)` with no rhs: a call form declared here and implemented elsewhere.
# There is no body, so nothing to walk and nothing for the indices to shadow.
@dynamicstruct struct RhsLessFixture
    scale = 10
    transform(i)
    lookup(key::Symbol; fallback::Int=0)
end

# The shape an indexed `@include` leaves behind once its marker — which DO
# does not own — is peeled: rhs-less, indexed, marker captured for the
# consumer that mounts it.
@dynamicstruct struct MarkedRhsLessFixture
    root::Symbol
    @include mount(key::Symbol)
end

# An indexed property WITH a body still shadows a same-named sibling with its
# own index; guarding the rhs-less path must not touch that.
@dynamicstruct struct ShadowingFixture
    scale = 10
    scaled(scale) = scale
    unscaled(i) = scale + i
end
end

@testitem "rhs-less indexed declarations expand" setup=[RhsLessFixtures] begin
using DynamicObjects

info = DynamicObjects.metafirst(RhsLessFixture, :transform)
@test info.indexed
@test collect(info.indices) == [:i]
@test info.rhs === nothing
@test DynamicObjects.isfixed(info)
# No body was walked, so neither set exists — the same state a plain fixed
# field carries, which is what every downstream reader already tolerates.
@test info.locals === nothing
@test info.dependson === nothing

# It is a constructor slot, positional like any other fixed field.
o = RhsLessFixture(i -> 2i, (key; fallback=0) -> fallback)
@test o.transform(3) == 6
@test o.scale == 10
end

@testitem "rhs-less indexed declarations reach the descriptors" setup=[RhsLessFixtures] begin
using DynamicObjects

signature = property_signature(RhsLessFixture, :lookup)
@test only(signature.positional).name === :key
@test only(signature.kwargs) == (; name=:fallback, type=Int, required=false, default=0, vararg=false)

descriptor = property_descriptor(RhsLessFixture, :lookup)
@test descriptor.fixed
@test descriptor.indexed
@test descriptor.dependencies == Symbol[]

# `dependson === nothing` (no rhs) renders as "depends on nothing" rather
# than throwing — true of every fixed field, not just indexed ones.
@test DynamicObjects.property_source_info(RhsLessFixture, :lookup).dependson == Symbol[]
@test DynamicObjects.property_source_info(RhsLessFixture, :lookup).rhs_string ==
    "(no rhs — forwarded/typed property)"
@test DynamicObjects.property_source_info(MarkedRhsLessFixture, :root).dependson == Symbol[]
end

@testitem "foreign markers survive on an rhs-less declaration" setup=[RhsLessFixtures] begin
using DynamicObjects

info = DynamicObjects.metafirst(MarkedRhsLessFixture, :mount)
@test Symbol("@include") in info.macros
@test info.indexed
@test collect(info.indices) == [:(key::Symbol)]
@test info.rhs === nothing
end

@testitem "DO's own rhs-acting markers are rejected without an rhs" setup=[RhsLessFixtures] begin
using DynamicObjects

@test_throws LoadError @eval @dynamicstruct struct CachedWithoutBody
    scale = 10
    @cached transform(i)
end
@test_throws LoadError @eval @dynamicstruct struct FreshWithoutBody
    scale = 10
    @fresh transform(i)
end
# `@versioned` is DO's own but means something on a field: a cache-version
# dimension. It must keep working.
@eval @dynamicstruct struct VersionedField
    @versioned tag::Symbol
    scale = 10
end
@test VersionedField(:a).scale == 10
end

@testitem "indexed properties with a body still shadow siblings" setup=[RhsLessFixtures] begin
using DynamicObjects

o = ShadowingFixture()
# The index shadows the sibling of the same name...
@test o.scaled(3) == 3
# ...while an unshadowed sibling still resolves through `__self__`.
@test o.unscaled(3) == 13
@test DynamicObjects.metafirst(ShadowingFixture, :scaled).dependson == Set{Symbol}()
@test DynamicObjects.metafirst(ShadowingFixture, :unscaled).dependson == Set([:scale])
end
