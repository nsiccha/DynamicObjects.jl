using TestItemRunner

@testmodule SelfNamedFixtures begin
using DynamicObjects
export SelfNamedFixture, SelfNamedKwargFixture, DistinctIndexFixture,
    SelfNamedCachedFixture, CACHED_CALLS, cp_kwarg_names

const CACHED_CALLS = Ref(0)

# The index arg named after the property it indexes: `dataset(dataset)` reads as
# "the thing FOR this dataset". Before the fix this was a hard expansion error —
# `syntax: function argument name not unique: "dataset"` — because the emitted
# `compute_property` carried a kwarg of the same name.
@dynamicstruct struct SelfNamedFixture
    base::String
    dataset(dataset::String) = base * "/" * dataset
end

# The same collision reached through a kwarg rather than a positional.
@dynamicstruct struct SelfNamedKwargFixture
    scale::Int
    weight(; weight::Int = 2) = scale * weight
end

# A DIFFERENT index name must keep the self-kwarg — that is how an indexed body
# reaches its own IndexableProperty (recursion) and how a `@cached` body
# receives the value to resume from.
@dynamicstruct struct DistinctIndexFixture
    seed::Int
    transform(i::Int) = seed + i
end

@dynamicstruct struct SelfNamedCachedFixture
    base::String
    @cached dataset(dataset::String) = begin
        CACHED_CALLS[] += 1
        base * "/" * dataset
    end
end

# Does `m` carry the `compute_property` signature emitted for `T`'s property `name`?
#
# `m.sig` is a `UnionAll`, not a `Tuple` DataType, for every method a PARAMETRIC
# `@dynamicstruct` emits — `compute_property(o::Foo{T}, ::Val{:x}) where T` — and a
# `UnionAll` has no `.parameters` field at all, so reading it threw `type UnionAll
# has no field parameters`. `methods()` is GLOBAL, so this predicate sees every
# parametric struct any other test file in the same process has defined: the failure
# depended on test scheduling, not on anything this file declares, which is why the
# file passed 30/30 in isolation and errored 5/9 in the full suite once
# `test/parametric_structs.jl` shared a worker with it.
#
# Unwrap first. A parametric signature's `parameters[2]` is then a typevar-carrying
# type that simply fails `=== T`, which is the non-match we want.
_cp_sig_matches(m, T, name::Symbol) = begin
    sig = Base.unwrap_unionall(m.sig)
    sig isa DataType && length(sig.parameters) >= 3 &&
        sig.parameters[2] === T && sig.parameters[3] === Val{name}
end

# The kwarg names of the `compute_property` method emitted for `T`'s property
# `name` — the signature the fix is about, read straight off the method table.
function cp_kwarg_names(T, name::Symbol)
    ms = [m for m in methods(DynamicObjects.compute_property) if _cp_sig_matches(m, T, name)]
    Base.kwarg_decl(only(ms))
end
end

@testitem "an index arg may share the property's name" setup=[SelfNamedFixtures] begin
using DynamicObjects

o = SelfNamedFixture("/data")
# The positional wins in the body, which is the only reading that makes sense.
@test o.dataset("a.csv") == "/data/a.csv"
@test o.dataset("b.csv") == "/data/b.csv"

@test SelfNamedKwargFixture(3).weight() == 6
@test SelfNamedKwargFixture(3).weight(; weight = 5) == 15
end

@testitem "the self-named kwarg is suppressed, and only then" setup=[SelfNamedFixtures] begin
using DynamicObjects

# Suppressed: it would be a second argument called `dataset` in one signature.
@test :dataset ∉ cp_kwarg_names(SelfNamedFixture, :dataset)
# The kwarg form collides the same way (`function argument name not unique`),
# and here the surviving `weight` is the USER's own — exactly one of it.
@test count(==(:weight), cp_kwarg_names(SelfNamedKwargFixture, :weight)) == 1
# Everything else about the signature is unchanged.
@test :__status__ ∈ cp_kwarg_names(SelfNamedFixture, :dataset)

# A distinct index name keeps it — suppression is not a blanket change.
@test :transform ∈ cp_kwarg_names(DistinctIndexFixture, :transform)
@test :__status__ ∈ cp_kwarg_names(DistinctIndexFixture, :transform)
@test DistinctIndexFixture(10).transform(5) == 15

@test DynamicObjects._self_named_index(SelfNamedFixture("/data"), Val(:dataset))
@test DynamicObjects._self_named_index(SelfNamedKwargFixture(1), Val(:weight))
@test !DynamicObjects._self_named_index(DistinctIndexFixture(1), Val(:transform))
end

@testitem "a @cached self-named index does not pass a resume value" setup=[SelfNamedFixtures] begin
using DynamicObjects

# The disk-cache path hands the loaded value back to the body under the
# property's own name. There is no kwarg to receive it here, so it must not be
# passed — otherwise the FIRST computation (rv === nothing) throws an
# unsupported-keyword MethodError.
base = mktempdir()
CACHED_CALLS[] = 0
o = SelfNamedCachedFixture("/data"; __cache_base__ = base)
@test o.dataset("a.csv") == "/data/a.csv"
@test CACHED_CALLS[] == 1

# In-memory memoization, then a fresh equal object reading the same disk cache.
@test o.dataset("a.csv") == "/data/a.csv"
@test CACHED_CALLS[] == 1
@test SelfNamedCachedFixture("/data"; __cache_base__ = base).dataset("a.csv") == "/data/a.csv"
@test CACHED_CALLS[] == 1

# A different index is a different cache entry.
@test o.dataset("b.csv") == "/data/b.csv"
@test CACHED_CALLS[] == 2
end

@testitem "self-named indices reach the descriptors unchanged" setup=[SelfNamedFixtures] begin
using DynamicObjects

info = DynamicObjects.metafirst(SelfNamedFixture, :dataset)
@test info.indexed
@test collect(info.indices) == [:(dataset::String)]
# The index shadows the property, so the body depends on `base` only.
@test info.dependson == Set([:base])
@test :dataset in info.locals

signature = property_signature(SelfNamedFixture, :dataset)
@test only(signature.positional).name === :dataset
@test only(signature.positional).type === String

descriptor = property_descriptor(SelfNamedFixture, :dataset)
@test descriptor.indexed
@test !descriptor.fixed
@test only(input.name for input in descriptor.inputs if input.kind === :positional) === :dataset
end
