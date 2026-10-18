using TestItemRunner

# An indexed property memoizes per `(args, kwargs)`. Hashing that tuple hashed every
# container argument by its full contents, several times per call, so a large shared
# context passed to a per-row helper cost seconds per page (snag
# `memo-key-hashing-28c8f3be`). A memo key now hashes each mutable argument once per
# object, while calls still share an entry exactly when their arguments are `isequal`.
@testmodule MemoKeyFixtures begin
using DynamicObjects
export Bag, MKApp, mk_calls, mk_reset!, BAG_HASHES, MK_GATE

# A container whose content hash is counted.
const BAG_HASHES = Threads.Atomic{Int}(0)
mutable struct Bag
    items::Vector{Int}
end
Base.hash(b::Bag, h::UInt) = (Threads.atomic_add!(BAG_HASHES, 1); hash(b.items, hash(:Bag, h)))
Base.isequal(a::Bag, b::Bag) = isequal(a.items, b.items)

const MK_CALLS = Dict{Any,Int}()
const MK_LOCK = ReentrantLock()
_bump!(k) = lock(() -> (MK_CALLS[k] = get(MK_CALLS, k, 0) + 1), MK_LOCK)
mk_calls(k) = lock(() -> get(MK_CALLS, k, 0), MK_LOCK)
mk_reset!() = lock(() -> empty!(MK_CALLS), MK_LOCK)

# Receives the escaped `__self__` but reads no request context, so remount views share it.
_opaque_helper(app, settings) = sum(values(settings))
const MK_GATE = Ref{Any}(nothing)

@dynamicstruct struct MKApp
    __cache_path__::String
    ctx = nothing
    row_html(context, row::Int) = (_bump!((:row_html, row)); string("<tr>", row, "</tr>"))
    total(numbers) = (_bump!(:total); sum(numbers))
    configured(n::Int; options=Int[]) = (_bump!((:configured, n)); n + sum(options; init=0))
    @cached saved(settings::Dict) = (_bump!(:saved); sum(values(settings)))
    shares(settings::Dict) = (_bump!(:shares); _opaque_helper(__self__, settings))
    gated(numbers) = (take!(MK_GATE[]); sum(numbers))
end
end

@testitem "a container argument is hashed once per object across calls" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
o = MKApp(mktempdir())
context = (; bag=Bag(collect(1:1000)), labels=Dict("a" => 1))
BAG_HASHES[] = 0
for row in 1:200
    @test o.row_html(context, row) == "<tr>$row</tr>"
end
# Before the fix every call hashed the bag several times (about 1,000 hashes here).
@test BAG_HASHES[] == 1
@test all(row -> mk_calls((:row_html, row)) == 1, 1:200)
# Hits still return the stored value without recomputing.
@test o.row_html(context, 7) == "<tr>7</tr>"
@test mk_calls((:row_html, 7)) == 1
@test BAG_HASHES[] == 1
end

@testitem "equal but distinct containers still share one entry" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
o = MKApp(mktempdir())
@test o.total([1, 2, 3]) == 6
@test o.total([1, 2, 3]) == 6          # a new, equal vector
@test o.total(1:3) == 6                 # `isequal` to the vector, so the same entry
@test mk_calls(:total) == 1
@test o.total([1, 2, 4]) == 7
@test mk_calls(:total) == 2
# Containers inside tuples, named tuples and keyword arguments.
ctx_a = (; bag=Bag([1, 2]), names=["x"])
ctx_b = (; bag=Bag([1, 2]), names=["x"])
@test o.row_html(ctx_a, 1) == o.row_html(ctx_b, 1)
@test mk_calls((:row_html, 1)) == 1
@test o.configured(1; options=[2, 3]) == 6
@test o.configured(1; options=[2, 3]) == 6
@test mk_calls((:configured, 1)) == 1
@test o.configured(1) == 1              # no kwargs: a distinct entry, as before
@test mk_calls((:configured, 1)) == 2
end

@testitem "invalidate!, fetchindex and getstatus address container-keyed entries" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
o = MKApp(mktempdir())
@test o.total([5, 5]) == 10
invalidate!(o.total, [5, 5])            # an equal vector, not the stored one
@test o.total([5, 5]) == 10
@test mk_calls(:total) == 2
@clear_cache! o.total([5, 5])
@test o.total([5, 5]) == 10
@test mk_calls(:total) == 3
@test fetchindex((rv, status) -> rv, o.total, [5, 5]) == 10
@test mk_calls(:total) == 3
@test fetchindex((rv, status) -> fetch(rv), o.total, [5, 5]; force=true) == 10
@test mk_calls(:total) == 4
# An in-flight compute's status is found through an equal argument.
MK_GATE[] = Channel{Nothing}(1)
rv, status = fetchindex((rv, status) -> (rv, status), o.gated, [1, 2])
@test rv isa DynamicObjects.Pending
@test status !== nothing
@test getstatus(o.gated, [1, 2]) === status
put!(MK_GATE[], nothing)
@test fetch(rv) == 3
@test o.gated([1, 2]) == 3
end

@testitem "entries and cached_entries report plain argument tuples" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
o = MKApp(mktempdir())
nums = [1, 2]
@test o.total(nums) == 3
@test o.configured(4; options=[1]) == 5
es = entries(o.total)
@test length(es) == 1
@test only(es).key isa Tuple
@test only(es).key == ((nums,), (;))
@test only(es).state === :done
@test cached_entries(o.total) == [((nums,), (;)) => 3]
@test only(cached_entries(o.configured)).first == ((4,), (; options=[1]))
end

@testitem "@cached disk keys stay content-based across instances" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
dir = mktempdir()
@test MKApp(dir).saved(Dict(:a => 1, :b => 2)) == 3
# A new instance, a new (equal) Dict: the disk entry is found, nothing recomputes.
@test MKApp(dir).saved(Dict(:b => 2, :a => 1)) == 3
@test mk_calls(:saved) == 1
end

@testitem "remount views share container-keyed opaque work" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
source = MKApp(mktempdir())
views = [remount(source; ctx=i) for i in 1:3]
@test all(v -> v.shares(Dict(:a => 2, :b => 3)) == 5, views)
@test mk_calls(:shares) == 1
@test only(entries(views[1].shares)).key == ((Dict(:a => 2, :b => 3),), (;))
invalidate!(views[2].shares, Dict(:a => 2, :b => 3))
@test views[3].shares(Dict(:a => 2, :b => 3)) == 5
@test mk_calls(:shares) == 2
end

@testitem "concurrent calls with a shared context compute each key once" setup=[MemoKeyFixtures] begin
using DynamicObjects
mk_reset!()
o = MKApp(mktempdir())
context = (; bag=Bag(collect(1:100)), table=Dict(i => string(i) for i in 1:100))
results = Vector{String}(undef, 400)
Threads.@threads for i in 1:400
    results[i] = o.row_html(context, mod1(i, 20))
end
@test results == [string("<tr>", mod1(i, 20), "</tr>") for i in 1:400]
@test all(row -> mk_calls((:row_html, row)) == 1, 1:20)
end

@testitem "a remembered content hash does not keep its object alive" setup=[MemoKeyFixtures] begin
using DynamicObjects
function remember_temporary()
    d = Dict(i => rand(10) for i in 1:10)
    h = DynamicObjects._content_hash(d)
    @test h == hash(d)
    @test DynamicObjects._content_hash(d) == h   # served from the table
    WeakRef(d)
end
ref = remember_temporary()
GC.gc(true); GC.gc(true)
@test ref.value === nothing
# Strings and symbols are hashed directly, never remembered by identity.
@test DynamicObjects._content_hash("abc") == hash("abc")
@test DynamicObjects._content_hash(:abc) == hash(:abc)
end
