using TestItemRunner

# `DynamicObjects.canonical_hash` is the public spelling of the cache-identity
# digest (snag `public-canonical-373bfc6f`): consumers that override `__hash__`
# previously called the private `_hash_replace` + `persistent_hash` pair. Every
# internal identity hash now routes through it, so these items pin that the
# routing moved no existing digest and that a custom `__hash__` written with it
# keys exactly as the private spelling did.

@testmodule CanonicalHashFixtures begin
using DynamicObjects, DataFrames, Arrow
export CHInner, CHPlain, CHVersioned, CHCustom, CH_VERSION, CHLazyArray

struct CHLazyArray <: AbstractMatrix{Float64}
    n::Int
end
Base.size(x::CHLazyArray) = (x.n, x.n)
Base.getindex(::CHLazyArray, ::Int, ::Int) = error("hashing must not materialize a lazy array")

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

@testitem "container identity survives insertion history and serialization" tags=[:core] begin
using DynamicObjects, Serialization
const DO = DynamicObjects
roundtrip(x) = (io = IOBuffer(); serialize(io, x); seekstart(io); deserialize(io))

for n in (0, 3, 10, 30, 100)
    forward = Dict{String,Any}("k$i" => i for i in 1:n)
    reserved = Dict{String,Any}("k$i" => i for i in n:-1:1)
    sizehint!(reserved, 1000)
    # A matrix wrapper in the reported model inputs must stay stable too.
    forward["matrix"] = reserved["matrix"] = reshape(collect(1.0:6.0), 2, 3)'
    @test isequal(forward, reserved)
    expected = DO.canonical_hash(("code", forward))
    @test DO.canonical_hash(("code", reserved)) == expected
    @test DO.canonical_hash(("code", roundtrip(reserved))) == expected
    @test DO.canonical_hash(("code", roundtrip(forward))) == expected
    @test DO.canonical_hash(("code", merge(forward, Dict("different" => 0)))) != expected

    a, b = Set(keys(forward)), Set(reverse(collect(keys(forward))))
    sizehint!(b, 1000)
    @test DO.canonical_hash(a) == DO.canonical_hash(b) == DO.canonical_hash(roundtrip(b))
end

# Preserve identity's existing scalar/type distinctions: _disk_key's broader
# numeric isequal normalization belongs to indexed arguments, not object identity.
@test DO.canonical_hash(Dict{Any,Any}(:x => 1)) != DO.canonical_hash(Dict{Any,Any}(:x => 1.0))
@test DO.canonical_hash(Dict(:x => 1)) != DO.canonical_hash(Dict{Any,Any}(:x => 1))
@test DO.canonical_hash(Set([1])) != DO.canonical_hash(Set([1.0]))
@test DO.canonical_hash(Set{Int}()) != DO.canonical_hash(Set{String}())

# Dicts and Sets nested inside pairs, arrays and one another all reach the walker.
a = Dict(:x => Any[(values=Set([:a, :b]),), :nested => Dict(:a => 1, :b => 2)])
b = Dict(:x => Any[(values=Set([:b, :a]),), :nested => Dict(:b => 2, :a => 1)])
@test DO.canonical_hash(a) == DO.canonical_hash(b) == DO.canonical_hash(roundtrip(b))
@test DO.canonical_hash(a[:x]) == DO.canonical_hash(b[:x])

# Aliases and cycles survive the walk, and no input is modified.
d = Dict{String,Any}("x" => 1)
d["self"] = d
before = collect(keys(d))
@test DO.canonical_hash(d) == DO.canonical_hash(roundtrip(d))
@test d["self"] === d && collect(keys(d)) == before
v = Any[d, d]
push!(v, v)
@test DO.canonical_hash(v) == DO.canonical_hash(roundtrip(v))
@test v[1] === v[2] === d && v[3] === v
end

@testitem "nested dynamic objects and tables hash content without their memoized state" tags=[:core] setup=[CanonicalHashFixtures] begin
using DynamicObjects, DataFrames, Arrow
const DO = DynamicObjects
@test Base.get_extension(DO, :DataFramesArrowExt) !== nothing

inner = CHInner(1)
df = DataFrame(x=[1, 2], y=["a", "b"])
make(inner, df) = Dict(:objects => [inner], :table => df, :pair => (:child => inner))
value = make(inner, df)
cold = DO.canonical_hash(value)
inner.blob(10)
@test DO.canonical_hash(value) == cold
@test DO.canonical_hash(make(CHInner(1), copy(df))) == cold
@test DO.canonical_hash(make(CHInner(2), copy(df))) != cold
@test DO.canonical_hash(make(CHInner(1), DataFrame(x=[1, 3], y=["a", "b"]))) != cold

# A top-level extension replacement also re-enters the container walk.
column = Dict{String,Any}("k$i" => i for i in 1:30)
reserved = copy(column)
sizehint!(reserved, 1000)
@test DO.canonical_hash(DataFrame(x=[column])) == DO.canonical_hash(DataFrame(x=[reserved]))
@test DO.canonical_hash(df) == DO.persistent_hash((string.(names(df)), [collect(c) for c in eachcol(df)]))

# Distinct keys may canonicalize alike. Their differing values must determine
# the tie order, not the Dict's original iteration order.
k1, k2 = CHInner(1), CHInner(1)
a = Dict(k1 => "a", k2 => "b")
b = Dict(k2 => "b", k1 => "a")
sizehint!(b, 1000)
@test length(a) == length(b) == 2
@test DO.canonical_hash(a) == DO.canonical_hash(b)
end

@testitem "unaffected identities keep their bytes and array wrappers stay lazy" tags=[:core] setup=[CanonicalHashFixtures] begin
using DynamicObjects
const DO = DynamicObjects
values = (1, 1.0, -0.0, true, "x", :x, (1, :x), (x=1, y=:y),
    [1.0, 2.0], Any[1, "x"], ["x", "y"], Pair{Any,Any}(:x, 1),
    reshape(collect(1.0:6.0), 2, 3)', CHLazyArray(10^9))
for x in values
    @test DO.canonical_hash(x) == DO.persistent_hash(x)
end
v = [1, 2]
@test DO.canonical_hash((v, v)) == DO.persistent_hash((v, v))
@test DO.canonical_hash(Any[v, v]) == DO.persistent_hash(Any[v, v])
end
