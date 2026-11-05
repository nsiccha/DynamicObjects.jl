using TestItemRunner

# A memo key matches arguments by `isequal`, while a disk key was built from how an argument
# prints or serializes. So `f(-50)` and `f(-50.0)` shared one memory entry and named two
# files, and a restart recomputed the spelling that had not computed first. The reverse
# served wrong values: `0.1f0` and `0.1` are not `isequal` but printed alike (snag
# `memo-key-isequal-1b4ae3b0`). One memo entry now has one disk entry.
@testmodule DiskKeyFixtures begin
using DynamicObjects
export DKOwner, DKDays, DKHours, dk_calls, dk_reset!, disk_files, DISK_KEY_CORPUS, EQUAL_TYPES_APART, today_segment

const CALLS = Dict{Symbol,Int}()
const CALLS_LOCK = ReentrantLock()
_bump!(name) = lock(() -> (CALLS[name] = get(CALLS, name, 0) + 1), CALLS_LOCK)
dk_calls(name) = lock(() -> get(CALLS, name, 0), CALLS_LOCK)
dk_reset!() = lock(() -> empty!(CALLS), CALLS_LOCK)

@dynamicstruct struct DKOwner
    seed::Int
    @mmap frac(threshold)::Vector{Float64} = (_bump!(:frac); fill(Float64(threshold), 3))
    @cached saved(argument) = (_bump!(:saved); (argument, seed))
    @cached with_keyword(; threshold=1, label="x") = (_bump!(:with_keyword); (threshold, label))
    @cached typed(x::Int) = "Int"
    @cached typed(x::Float64) = "Float64"
    @struct child(threshold; scale=1) = begin
        @cached stored = (_bump!(:child); threshold * scale)
    end
    @cached from_child(inner) = (_bump!(:from_child); inner.stored)
end

disk_files(o) = sort!(filter(f -> endswith(f, ".sjl"), readdir(o.__cache_path__)))

# Today's formula before this fix, kept as the pin for keys that must not move.
_today_hash(x::Number) = x
_today_hash(x::Symbol) = x
_today_hash(x) = DynamicObjects.canonical_hash(x)
today_segment(name, args...; kwargs...) = DynamicObjects._bound_segment(join(map(_today_hash,
    length(kwargs) == 0 ? (name, args...) : (name, args..., sort(collect(kwargs); by=first)...)), "_"))

mutable struct DKMutable
    x::Int
end

# A type with its own cross-type `isequal`, as `Dates.Day(1)` and `Dates.Hour(24)` have.
struct DKDays
    n::Int
end
struct DKHours
    n::Int
end
Base.isequal(a::DKDays, b::DKHours) = 24 * a.n == b.n
Base.isequal(a::DKHours, b::DKDays) = isequal(b, a)
Base.hash(x::DKDays, h::UInt) = hash(24 * x.n, h)
Base.hash(x::DKHours, h::UInt) = hash(x.n, h)

# Types left out on purpose: equal values of these keep separate entries (`_disk_key`).
_is_bool_like(x) = x isa Bool || (x isa AbstractArray && eltype(x) === Bool)
const EQUAL_TYPES_APART = (
    (a, b) -> xor(_is_bool_like(a), _is_bool_like(b)),
    (a, b) -> a isa Union{DKDays,DKHours} && b isa Union{DKDays,DKHours},
)

const DISK_KEY_CORPUS = Any[
    # integer-valued numbers of every kind
    -50, -50.0, Int32(-50), -50 // 1, big(-50), -50.0f0, big(-50.0), Float16(-50), -50 + 0im, -50.0 + 0.0im,
    1, 1.0, true, UInt8(1), 1 // 1, 0, 0.0, false, 0.0f0, 0 // 1,
    # signed zero is not `isequal` to zero
    -0.0, -0.0f0, Complex(1.0, -0.0), Complex(0.0, -0.0),
    # non-integers, exact and not
    0.5, 0.5f0, 1 // 2, big(0.5), Float16(0.5), 0.1, 0.1f0, big"0.1", 1 // 3, 2 // 6, big(1) // 3, 0.10000000149011612,
    # complex
    1 + 2im, 1.0 + 2.0im, 1.5 + 2.0im, 1.5f0 + 2.0f0im, (1 // 3) + (1 // 7) * im, (big(1) // 3) + (big(1) // 7) * im,
    # beyond Int and Float64
    2.0^70, big(2)^70, Int128(2)^70, 2.0^63, Int128(2)^63, typemax(Int), typemax(Int) - 1,
    Float64(typemax(Int)), typemax(UInt64), big(10)^30, 1e300, BigInt(1e300), 2^53 + 1, 2.0^53,
    # non-finite
    NaN, NaN32, -NaN, big(NaN), Inf, Inf32, -Inf, big(Inf), -Inf32, 1 // 0,
    # not rational
    π, Float64(π), ℯ,
    # strings and other scalars
    "ab", SubString("abc", 1, 2), :ab, "1", :x, nothing, missing, 'a',
    # arrays and ranges
    [1, 2], 1:2, [1.0, 2.0], Int32[1, 2], Any[1, 2], Any[1.0, 2], 1.0:2.0, Base.OneTo(2), view([1, 2, 3], 1:2),
    [1.0, 2.5], Any[1, 2.5], Real[1, 5 // 2], Float32[1.0, 2.5],
    [0.0], [-0.0], [0], [true], trues(1), [1], Bool[1, 0], [1, 0], BitVector([1, 0]),
    [2.0^70, 1.0], Any[big(2)^70, 1], [2^53 + 1, 1],
    # empty arrays are all `isequal` at one size, and not across sizes
    Int[], Float64[], String[], Any[], Symbol[], 1:0, zeros(Int, 0, 2), zeros(Float64, 0, 2), zeros(Int, 2, 0),
    # shape
    reshape([1, 2, 3, 4], 2, 2), [1.0 3.0; 2.0 4.0], Any[1 3; 2 4], [1, 2, 3, 4], [1 2 3 4],
    # nesting and element types
    [[1, 2], [3]], [[1.0, 2.0], [3.0]], Any[[1, 2], [3.0]], ["a", "b"], Any["a", "b"], [SubString("a"), SubString("b")],
    [:a, :b], [1, missing], Any[1, missing], [1.0, missing], [1.5, missing],
    # tuples, named tuples, pairs
    (1, 2), (1.0, 2.0), (1, 2.0), (a = 1,), (a = 1.0,), (b = 1,), (a = 1, b = 2), (b = 2, a = 1), ((1, 2), 3), ((1.0, 2.0), 3),
    1 => 2, 1.0 => 2, ("a", 1), (SubString("ab", 1, 1), 1.0), ("a", 1.5), ([1, 2], 3), (1:2, 3.0),
    # dicts and sets
    Dict(:a => 1), Dict(:a => 1.0), Dict{Any,Any}(:a => 1), Dict(:a => 2), Dict(1 => :a), Dict(1.0 => :a),
    Dict{Int,Int}(), Dict{Symbol,String}(), Set([1]), Set([1.0]), Set(Any[1]), Set([2]), Set{Int}(), Set{String}(),
    # types with their own `isequal`
    DKDays(1), DKHours(24), DKHours(25), DKMutable(1), DKMutable(2),
]
end

@testitem "a fresh process finds the entry whichever spelling stored it" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects

base = mktempdir()
dk_reset!()
# The reported order: the Float stores it, the Int is a memory hit and writes nothing.
first_process = DKOwner(1; __cache_base__=base)
@test first_process.frac(-50.0) == fill(-50.0, 3)
@test first_process.frac(-50) == fill(-50.0, 3)
@test dk_calls(:frac) == 1
@test disk_files(first_process) == ["frac_-50.sjl"]

# A fresh object on the same cache is the restart: the Int call finds the entry.
second_process = DKOwner(1; __cache_base__=base)
@test second_process.frac(-50) == fill(-50.0, 3)
@test dk_calls(:frac) == 1
# And the other order: an Int stores what a Float then finds.
@test DKOwner(1; __cache_base__=base).frac(-7) == fill(-7.0, 3)
@test DKOwner(1; __cache_base__=base).frac(-7.0) == fill(-7.0, 3)
@test dk_calls(:frac) == 2
@test disk_files(second_process) == ["frac_-50.sjl", "frac_-7.sjl"]
end

@testitem "keywords, containers and strings share one entry too" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects

base = mktempdir()
dk_reset!()
fresh() = DKOwner(1; __cache_base__=base)
@test fresh().with_keyword(; threshold=2.0, label="y") == (2.0, "y")
@test fresh().with_keyword(; threshold=2, label=SubString("yz", 1, 1)) == (2.0, "y")
@test fresh().with_keyword(; label="y", threshold=2) == (2.0, "y")
@test dk_calls(:with_keyword) == 1

for spellings in (
    (1:3, [1, 2, 3], [1.0, 2.0, 3.0], Any[1, 2.0, 3], view([1, 2, 3, 4], 1:3)),
    ((1, 2.0), (1.0, 2), (1, 2)),
    ((a = 1,), (a = 1.0,)),
    (Dict(:a => 1, :b => 2), Dict(:b => 2.0, :a => 1.0), Dict{Any,Any}(:b => 2, :a => 1)),
    (Set([1, 2]), Set([2.0, 1.0])),
    ("ab", SubString("abc", 1, 2)),
)
    dk_reset!()
    for spelling in spellings
        fresh().saved(spelling)
    end
    @test dk_calls(:saved) == 1
end
end

@testitem "equal dicts share an entry whatever their insertion history" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

forward = Dict{Int,Int}()
backward = Dict{Int,Int}()
for key in 1:64
    forward[key] = key
end
for key in 64:-1:1
    backward[key] = key
end
pruned = Dict(key => key for key in 1:1000)
for key in 11:1000
    delete!(pruned, key)
end
@test isequal(forward, backward)
# The positive control: these iterate differently, so a key built by iterating them differs.
@test collect(forward) != collect(backward)
@test DO.persistent_hash(forward) != DO.persistent_hash(backward)
@test DO.cache_segment(:f, forward) == DO.cache_segment(:f, backward)
@test collect(pruned) != collect(Dict(key => key for key in 1:10))
@test DO.cache_segment(:f, pruned) == DO.cache_segment(:f, Dict(key => key for key in 1:10))
end

@testitem "values that are not isequal never share an entry" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

base = mktempdir()
dk_reset!()
owner = DKOwner(1; __cache_base__=base)
# These printed alike, so the second call read the first one's file.
@test owner.frac(0.1f0) == fill(Float64(0.1f0), 3)
@test owner.frac(0.1) == fill(0.1, 3)
@test dk_calls(:frac) == 2
@test length(disk_files(owner)) == 2
@test today_segment(:frac, 0.1f0) == today_segment(:frac, 0.1)
@test DO.cache_segment(:frac, 0.1f0) != DO.cache_segment(:frac, 0.1)

# Signed zero: `isequal(0.0, -0.0)` is false, in arrays and complex numbers too.
@test DO.cache_segment(:f, -0.0) != DO.cache_segment(:f, 0.0)
@test DO.cache_segment(:f, [-0.0]) != DO.cache_segment(:f, [0.0])
@test DO.cache_segment(:f, Complex(1.0, -0.0)) != DO.cache_segment(:f, Complex(1.0, 0.0))
# An exact integer above Float64's reach is not the float it rounds to.
@test !isequal(2^53 + 1, 2.0^53 + 1)
@test DO.cache_segment(:f, 2^53 + 1) != DO.cache_segment(:f, 2.0^53 + 1)
# An array with offset axes is not `isequal` to its dense copy.
offset = view([1, 2, 3], Base.IdentityUnitRange(2:3))
@test offset isa SubArray{<:Any,<:Any,<:Array}
@test Base.has_offset_axes(offset)
@test !isequal(offset, [2, 3])
@test DO.cache_segment(:f, offset) != DO.cache_segment(:f, [2, 3])
@test !isequal(Base.IdentityUnitRange(2:3), [2, 3])
@test DO.cache_segment(:f, Base.IdentityUnitRange(2:3)) != DO.cache_segment(:f, [2, 3])
end

@testitem "the disk key follows isequal across the corpus" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

corpus = DISK_KEY_CORPUS
segments = String[DO.cache_segment(:f, x) for x in corpus]
today = String[today_segment(:f, x) for x in corpus]
pair_indices = [(i, j) for i in eachindex(corpus) for j in i+1:lastindex(corpus)]
equal_pairs = filter(((i, j),) -> isequal(corpus[i], corpus[j]), pair_indices)
apart_on_purpose((i, j)) = any(apart -> apart(corpus[i], corpus[j]), EQUAL_TYPES_APART)
# Not `isequal`, one key: would serve a wrong value.
wrong = [(corpus[i], corpus[j]) for (i, j) in pair_indices
    if segments[i] == segments[j] && !isequal(corpus[i], corpus[j])]
# `isequal`, two keys: a repeated computation.
split = [(corpus[i], corpus[j]) for (i, j) in equal_pairs
    if segments[i] != segments[j] && !apart_on_purpose((i, j))]
@test isempty(wrong)
@test isempty(split)
# The positive control: the corpus really crosses types, and today's keys failed on it.
@test count(((i, j),) -> typeof(corpus[i]) !== typeof(corpus[j]), equal_pairs) > 100
@test count(((i, j),) -> today[i] != today[j], equal_pairs) > 100
# Types left out on purpose stay apart, which costs a recompute and never a wrong value.
@test DO.cache_segment(:f, true) != DO.cache_segment(:f, 1)
@test isequal(DKDays(1), DKHours(24))
@test DO.cache_segment(:f, DKDays(1)) != DO.cache_segment(:f, DKHours(24))
end

@testitem "a canonical spelling keeps its existing disk key" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

# Moving one of these would recompute caches for nothing.
@testset "$(repr(x))" for x in Any[-50, 100, 0, typemax(Int), 0.5, -2.5, 1e300, -0.0, NaN, Inf, true, false, :sym, "text",
    Symbol("with_underscore"), [1, 2, 3], Int[], [1.5, 2.0], [1.0, NaN], [true, false], ["a"], [:a], (1, "a"), (1, 2.5),
    (a = 1, b = "x"), (; c = (1, :d)), nothing, big(10)^30, π, [[1, 2], [3]], ["a" "b"], 'c', 1 + 2im, 1.5 + 2.0im]
    @test DO.cache_segment(:f, x) == today_segment(:f, x)
end
# Keyword pairs keep the type they had, also for mixed value types.
@test DO.cache_segment(:f; a=1) == today_segment(:f; a=1)
@test DO.cache_segment(:f; a=1, b="x") == today_segment(:f; a=1, b="x")
@test DO.cache_segment(:f; a=1, b=2.5) == today_segment(:f; a=1, b=2.5)
@test DO.cache_segment(:f, 1, "s", 2.5; b=2, a=1) == today_segment(:f, 1, "s", 2.5; b=2, a=1)
@test DO.maybehash(3) === 3
@test DO.maybehash(:s) === :s
# Spellings the key does move, which the changelog names.
@test DO.cache_segment(:f, 24.0) == "f_24"
@test DO.cache_segment(:f, 24.0) != today_segment(:f, 24.0)
@test DO.cache_segment(:f, [1.0, 2.0]) == today_segment(:f, [1, 2])
@test DO.cache_segment(:f, 1:2) == today_segment(:f, [1, 2])
end

@testitem "DynamicObjects values and DataFrames keep their keys" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects, DataFrames, Arrow
const DO = DynamicObjects

@test Base.get_extension(DynamicObjects, :DataFramesArrowExt) !== nothing
owner = DKOwner(1)
frame = DataFrame(x = [1, 2], y = [0.5, 1.5])
@test DO.cache_segment(:f, owner) == today_segment(:f, owner)
@test DO.cache_segment(:f, (owner, 1, "a")) == today_segment(:f, (owner, 1, "a"))
@test DO.cache_segment(:f, frame) == today_segment(:f, frame)
@test DO.cache_segment(:f, (frame, owner)) == today_segment(:f, (frame, owner))
# They still go through `canonical_hash`, so a tuple's integer-valued float moves beside them.
@test DO.cache_segment(:f, (owner, 2.0)) == DO.cache_segment(:f, (owner, 2))
@test DO.cache_segment(:f, (frame, 2.0)) == DO.cache_segment(:f, (frame, 2))
end

@testitem "a huge range keeps its own key rather than being collected" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

huge = 1:(DO._RANGE_DISK_KEY_MAX + 1)
@test DO._disk_key(huge) === huge
# Far more than this host could hold if it were collected.
@test DO.cache_segment(:f, 1:10^15) == today_segment(:f, 1:10^15)
@test DO._disk_key(1:1000) == collect(1:1000)
@test DO._disk_key(1:1000) isa Vector{Int}
end

@testitem "an inline child's directory and identity follow isequal" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects

base = mktempdir()
dk_reset!()
first_process = DKOwner(1; __cache_base__=base)
@test first_process.child(2.0).stored == 2.0
@test first_process.child(2) === first_process.child(2.0)
second_process = DKOwner(1; __cache_base__=base)
@test second_process.child(2).stored == 2.0
@test dk_calls(:child) == 1
@test length(filter(startswith("child"), readdir(first_process.__cache_path__))) == 1

# Its identity does not depend on the spelling that built it first, so what keys on it hits.
@test DKOwner(1; __cache_base__=base).child(2).__hash__ == DKOwner(1; __cache_base__=base).child(2.0).__hash__
@test DKOwner(1; __cache_base__=base).child(2; scale=1).__hash__ == DKOwner(1; __cache_base__=base).child(2.0; scale=1.0).__hash__
@test DKOwner(1; __cache_base__=base).child(2).__hash__ != DKOwner(1; __cache_base__=base).child(3).__hash__
dk_reset!()
@test DKOwner(1; __cache_base__=base).from_child(DKOwner(1; __cache_base__=base).child(2.0)) == 2.0
@test DKOwner(1; __cache_base__=base).from_child(DKOwner(1; __cache_base__=base).child(2)) == 2.0
@test dk_calls(:from_child) == 1
end

@testitem "an argument printing a slash stays a flat entry clears can reach" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

base = mktempdir()
dk_reset!()
owner = DKOwner(1; __cache_base__=base)
@testset "$(repr(argument))" for argument in (1 // 3, (1 // 3) + (1 // 7) * im, Symbol("a/b"), Symbol("a*b"), Symbol("a:b"), Symbol("a|b?c"))
    dk_reset!()
    @test !occursin('/', DO.cache_segment(:saved, argument))
    DKOwner(1; __cache_base__=base).saved(argument)
    @test dk_calls(:saved) == 1
    # Nothing nested: every entry sits directly in the object's cache directory.
    @test all(isfile, joinpath.(owner.__cache_path__, readdir(owner.__cache_path__)))
    clear_disk_caches!(owner)
    @test isempty(readdir(owner.__cache_path__))
    DKOwner(1; __cache_base__=base).saved(argument)
    @test dk_calls(:saved) == 2
    clear_disk_caches!(owner)
end
# Non-dyadic rationals are spelled readably, and are still distinct.
@test DO.cache_segment(:f, 1 // 3) == "f_1over3"
@test DO.cache_segment(:f, 2 // 6) == "f_1over3"
@test DO.cache_segment(:f, 1 // 3) != DO.cache_segment(:f, 3)
end

@testitem "a file name is legal on Windows, and distinct arguments keep distinct names" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects
const DO = DynamicObjects

# The rule itself, on every host. The round trip above runs it for real on Windows.
@test DO._windows_file_name("saved_1over3 + 1over7*im") == "saved_1over3 + 1over7%2Aim"
@test DO._windows_file_name("f_a:b") == "f_a%3Ab"
@test DO._windows_file_name("f_a|b?c<d>\"e\\f") == "f_a%7Cb%3Fc%3Cd%3E%22e%5Cf"
@test DO._windows_file_name("f_\tx") == "f_%09x"
names = ["f_a*b", "f_a:b", "f_a?b", "f_a|b", "f_a<b", "f_a>b", "f_a\"b", "f_a\\b"]
@test allunique(DO._windows_file_name.(names))
@test !any(name -> any(DO._is_windows_reserved, DO._windows_file_name(name)), names)
# What needs no encoding keeps its name, including on Windows.
for name in ("f_-50", "f_1.5", "f_1 + 2im", "f_1over3", "f_π", "f_" * DO.persistent_hash(1), "f_a_b")
    @test DO._windows_file_name(name) === name
end
# Keys move on no other host.
@test DO._path_safe("f_a*b:c") == (Sys.iswindows() ? "f_a%2Ab%3Ac" : "f_a*b:c")
@test DO.cache_segment(:f, Symbol("a*b")) == (Sys.iswindows() ? "f_a%2Ab" : today_segment(:f, Symbol("a*b")))
end

@testitem "invalidation and status see one entry per isequal value" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects

base = mktempdir()
dk_reset!()
owner = DKOwner(1; __cache_base__=base)
# `@cached`, not `@mmap`: Windows refuses to delete a file a live mapping holds.
owner.saved(-50.0)
@test (@cache_status owner.saved(-50)) === :ready
@test (@cache_status owner.saved(-50.0)) === :ready
@test (@cache_path owner.saved(-50)) == (@cache_path owner.saved(-50.0))
# Dropping one spelling drops the entry, memory and disk.
invalidate!(owner.saved, -50)
@test (@cache_status owner.saved(-50.0)) === :unstarted
owner.saved(-50.0)
@test dk_calls(:saved) == 2
DynamicObjects.clear_cache!(owner, :saved)
@test (@cache_status owner.saved(-50)) === :unstarted
end

@testitem "a body still receives the caller's argument, and typed methods keep the first" tags=[:core] setup=[DiskKeyFixtures] begin
using DynamicObjects

base = mktempdir()
dk_reset!()
# `_disk_key` only names the entry: the first spelling is what the body sees.
@test DKOwner(1; __cache_base__=base).saved(2.0) == (2.0, 1)
# A later spelling gets that value, as it does within a process (do-use §2).
@test DKOwner(1; __cache_base__=base).saved(2) == (2.0, 1)
@test DKOwner(2; __cache_base__=base).saved(2) == (2, 2)
# Same-name methods split by numeric type share an entry in memory, so across a restart too.
memory = DKOwner(3; __cache_base__=base)
@test memory.typed(1) == "Int"
@test memory.typed(1.0) == "Int"
@test DKOwner(3; __cache_base__=base).typed(1.0) == "Int"
end
