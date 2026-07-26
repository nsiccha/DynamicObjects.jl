using TestItemRunner

@testmodule SelfNamedFixtures begin
using DynamicObjects
export SelfNamedFixture, SelfNamedKwargFixture, DistinctIndexFixture,
    SelfNamedCachedFixture, SelfNamedLooseFixture, CACHED_CALLS, LOOSE_CALLS,
    cp_kwarg_names

const CACHED_CALLS = Ref(0)
const LOOSE_CALLS = Ref(0)

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

# `_computeproperty` has TWO disk-cache branches — the `__strict__` one that takes
# a path lock, and the plain one taken when locking is off — and each has its own
# `compute_property` call passing the resume value. They carry the same collision,
# so suppressing it in only one leaves a self-named `@cached` property throwing an
# unsupported-keyword `MethodError` under `__strict__ = false`.
@dynamicstruct struct SelfNamedLooseFixture
    base::String
    @cached dataset(dataset::String) = begin
        LOOSE_CALLS[] += 1
        base * "/" * dataset
    end
end

# The kwarg names of the `compute_property` method emitted for `T`'s property
# `name` — the signature the fix is about, read straight off the method table.
#
# `unwrap_unionall` because `methods` is GLOBAL: a parametric `@dynamicstruct`
# anywhere in the suite emits `compute_property(o::Foo{T}, ::Val{:x}) where T`,
# whose `sig` is a `UnionAll` with no `.parameters` at all. Reaching for that
# field directly threw `type UnionAll has no field parameters` for every call
# here as soon as `test/parametric_structs.jl` shared a worker with this file —
# a failure that depends on test scheduling, not on anything this file declares.
_cp_sig_params(m) = Base.unwrap_unionall(m.sig).parameters

function cp_kwarg_names(T, name::Symbol)
    ms = [
        m for m in methods(DynamicObjects.compute_property)
        if length(_cp_sig_params(m)) >= 3 &&
            _cp_sig_params(m)[2] === T && _cp_sig_params(m)[3] === Val{name}
    ]
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

@testitem "the non-strict disk-cache branch suppresses it too" setup=[SelfNamedFixtures] begin
using DynamicObjects

# `__strict__ = false` routes through the second `compute_property` call site.
# It passed the resume kwarg unconditionally, so the first computation died with
# an unsupported-keyword `MethodError` even though the strict branch was fixed.
base = mktempdir()
LOOSE_CALLS[] = 0
o = SelfNamedLooseFixture("/data"; __cache_base__ = base, __strict__ = false)
@test o.dataset("a.csv") == "/data/a.csv"
@test LOOSE_CALLS[] == 1

# And it still reads back from disk rather than recomputing.
@test SelfNamedLooseFixture(
    "/data"; __cache_base__ = base, __strict__ = false,
).dataset("a.csv") == "/data/a.csv"
@test LOOSE_CALLS[] == 1
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
