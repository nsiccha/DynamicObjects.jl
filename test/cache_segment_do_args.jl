using TestItemRunner

@testmodule CacheSegFixtures begin
using DynamicObjects
export CacheSegInner, CacheSegOuter, SEG_DERIVE_CALLS

@dynamicstruct struct CacheSegInner
    x::Int
    blob(i) = fill(Float64(i), 100_000)
end

const SEG_DERIVE_CALLS = Ref(0)

@dynamicstruct struct CacheSegOuter
    seed::Int
    @cached derive(inner::CacheSegInner) = (SEG_DERIVE_CALLS[] += 1; inner.x + seed)
end
end

@testitem "a DO argument hashes by __hash__, not by memoized state" tags=[:core] setup=[CacheSegFixtures] begin
using DynamicObjects

a = CacheSegInner(1)
cold = DynamicObjects.cache_segment(:derive, a)
# Memoizing ~800KB onto the argument must not move its disk-cache key: before
# the fix this serialized the whole object including its PropertyCache, so the
# key grew with cached state and never matched across restarts.
a.blob(1)
@test DynamicObjects.cache_segment(:derive, a) == cold
# The mechanism, pinned: the segment hashes the stable identity string.
@test DynamicObjects.cache_segment(:derive, a) ==
    DynamicObjects.cache_segment(:derive, a.__hash__)
# A distinct but content-equal instance (the restart analogue) keys identically.
b = CacheSegInner(1)
b.blob(2)
@test DynamicObjects.cache_segment(:derive, b) == cold
# Different fixed fields still key differently.
@test DynamicObjects.cache_segment(:derive, CacheSegInner(2)) != cold
end

@testitem "plain-value segments are byte-identical to direct hashing" tags=[:core] setup=[CacheSegFixtures] begin
using DynamicObjects

# `_hash_replace` is the identity on plain values, so routing `maybehash`
# through it must not move any existing non-DO key.
@test DynamicObjects.maybehash(3) === 3
@test DynamicObjects.maybehash(:s) === :s
@test DynamicObjects.maybehash("s") == DynamicObjects.persistent_hash("s")
@test DynamicObjects.maybehash((1, "a")) == DynamicObjects.persistent_hash((1, "a"))
@test DynamicObjects.maybehash([1.0, 2.0]) == DynamicObjects.persistent_hash([1.0, 2.0])
@test DynamicObjects.maybehash((x = 1, y = "a")) ==
    DynamicObjects.persistent_hash((x = 1, y = "a"))
end

@testitem "a @cached IP with a DO arg hits disk across memoized state" tags=[:core] setup=[CacheSegFixtures] begin
using DynamicObjects

base = mktempdir()
SEG_DERIVE_CALLS[] = 0
# Write the disk entry with a cold argument.
@test CacheSegOuter(10; __cache_base__ = base).derive(CacheSegInner(1)) == 11
@test SEG_DERIVE_CALLS[] == 1
# A warm argument through a fresh equal owner (the restart analogue) must hit
# the same entry — same value, no recompute.
warm = CacheSegInner(1)
warm.blob(1)
@test CacheSegOuter(10; __cache_base__ = base).derive(warm) == 11
@test SEG_DERIVE_CALLS[] == 1
end
