using TestItemRunner

# `DynamicObjects.canonical_hash` is the public spelling of the cache-identity
# digest (snag `public-canonical-373bfc6f`): consumers that override `__hash__`
# previously called the private `_hash_replace` + `persistent_hash` pair. Every
# internal identity hash now routes through it, so these items pin that the
# routing moved no existing digest and that a custom `__hash__` written with it
# keys exactly as the private spelling did.

@testmodule CanonicalHashFixtures begin
using DynamicObjects, DataFrames, Arrow
export CHInner, CHPlain, CHVersioned, CHCustom, CH_VERSION

@dynamicstruct struct CHInner
    x::Int
    blob(i) = fill(Float64(i), 1_000)
end

@dynamicstruct struct CHPlain
    a::Int
    inner::CHInner
    label::String
end

@dynamicstruct struct CHVersioned
    path::String
    @versioned content_version::String
end

const CH_VERSION = "replay-v3"

# The consumer shape: mix in a format version and hash a derived value in place
# of a raw field.
@dynamicstruct struct CHCustom
    code::String
    frame
    inner::CHInner
    seed = 1
    stripped = replace(code, r"\s+" => "")
    __hash__ = DynamicObjects.canonical_hash((typeof(__self__), CH_VERSION, (stripped, frame, inner, seed)))
end
end

@testitem "canonical_hash is the digest every identity hash already used" tags=[:core] setup=[CanonicalHashFixtures] begin
using DynamicObjects
const DO = DynamicObjects

# Plain values pass through unchanged, so the digest is plain serialization.
for value in (1, "a", (1, "a"), (x = 1, y = "a"), [1.0, 2.0])
    @test DO.canonical_hash(value) == DO.persistent_hash(value)
end

# A nested DO is replaced by its `__hash__`, so memoized state never moves it.
inner = CHInner(1)
cold = DO.canonical_hash((inner, "a"))
@test cold == DO.persistent_hash((inner.__hash__, "a"))
inner.blob(1)
@test DO.canonical_hash((inner, "a")) == cold
@test DO.canonical_hash((CHInner(1), "a")) == cold

# The routed internal sites match their previous formulas byte for byte.
o = CHPlain(1, inner, "a")
@test o.__hash__ == DO.persistent_hash((CHPlain, DO._hash_replace(o.__hash_fields__)))
@test o.__cache_path__ == joinpath("cache", o.__hash__)
v = CHVersioned("a.txt", "v1")
@test v.__identity_hash__ ==
    DO.persistent_hash((CHVersioned, DO._hash_replace(DO._identity_hash_fields(v))))
@test v.__version_tag__ == DO.persistent_hash(DO._hash_replace(DO._version_hash_fields(v)))
@test DO.maybehash((inner, "a")) == cold
@test DO.maybehash(3) === 3
@test DO.maybehash(:s) === :s
end

@testitem "a custom __hash__ through canonical_hash keys like the private spelling" tags=[:core] setup=[CanonicalHashFixtures] begin
using DynamicObjects, DataFrames, Arrow
const DO = DynamicObjects

frame = DataFrame(x = [1, 2], y = ["a", "b"])
inner = CHInner(1)
o = CHCustom("a b", frame, inner)
# Byte-identical to what consumers wrote before the public name existed, so a
# migration to `canonical_hash` keeps every existing disk entry.
@test o.__hash__ == DO.persistent_hash(
    (CHCustom, CH_VERSION, DO._hash_replace(("ab", frame, inner, 1))))
@test o.__cache_path__ == joinpath("cache", o.__hash__)

# Equal content keys alike: a separately built DataFrame, a warm nested DO, and
# whitespace the derived field strips.
inner.blob(2)
@test CHCustom("a  b", DataFrame(x = [1, 2], y = ["a", "b"]), CHInner(1)).__hash__ == o.__hash__
@test CHCustom("a b", DataFrame(x = [1, 3], y = ["a", "b"]), inner).__hash__ != o.__hash__
@test CHCustom("a b", frame, CHInner(2)).__hash__ != o.__hash__

# Whatever contains the custom-hashed object keys it by that custom `__hash__`.
@test DO.canonical_hash((o, 1)) == DO.persistent_hash((o.__hash__, 1))
end
