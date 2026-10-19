using TestItemRunner

# `mem_cache_entries` walks what an object graph holds in memory; `prune_mem_caches!` evicts
# the derived entries a predicate rejects, keeping inputs, state, wrappers and DO's own
# entries, and touching no disk entry (snag `public-cache-wal-cc9ca2f3`).
@testmodule MemWalkFixtures begin
using DynamicObjects
export MWRoot, MWDisk, MWVersioned, MWView, MWSettled, mw_calls, mw_reset!, mw_settled,
       MW_STARTED, MW_RELEASE, file_snapshot, entry_at

const MW_CALLS = Dict{Any,Int}()
const MW_LOCK = ReentrantLock()
_mw_bump!(k) = lock(() -> (MW_CALLS[k] = get(MW_CALLS, k, 0) + 1), MW_LOCK)
mw_calls(k) = lock(() -> get(MW_CALLS, k, 0), MW_LOCK)
mw_reset!() = lock(() -> empty!(MW_CALLS), MW_LOCK)

const MW_STARTED = Ref{Any}(nothing)
const MW_RELEASE = Ref{Any}(nothing)

# Receives the escaped `__self__`, so `opaque` is shared opaque work across remount views.
_mw_opaque(app, key) = Ref(key)

@dynamicstruct struct MWRoot
    base::String
    @state attempts = Ref(0)
    values = (_mw_bump!(:values); [1.0, 2.0, 3.0])
    total = (_mw_bump!(:total); sum(values))
    label = (_mw_bump!(:label); "derived-" * base)
    note = (_mw_bump!(:note); string(base, ":", total))
    @struct child(name::Symbol) = begin
        weight = length(string(name)) * 1.0
        tag = (_mw_bump!((:tag, name)); string(base, "/", name))
        up = __parent__   # a derived back-reference: a cycle the walk stops at
    end
    @struct solo = begin
        z = [0.5]
    end
    score(k) = (_mw_bump!((:score, k)); k * 2.0)
    words(k) = (_mw_bump!((:words, k)); repeat("w", k))
    kids = [child(:a), child(:b)]   # objects held one level deep in a vector
    slow = (_mw_bump!(:slow); put!(MW_STARTED[], nothing); take!(MW_RELEASE[]); 99.0)
end

@dynamicstruct struct MWDisk
    __cache_base__ = tempdir()
    __hash_fields__ = ()
    @cached stored = (_mw_bump!(:stored); Dict(:payload => "disk"))
end

@dynamicstruct struct MWVersioned
    path::String
    __cache_base__ = tempdir()
    @versioned content_version = (_mw_bump!(:content_version); file_version(path; by=:hash))
    @cached rendered() = (_mw_bump!(:rendered); uppercase(read(path, String)))
end

@dynamicstruct struct MWView
    tag = "retained"
    read_value(key) = (_mw_bump!((:read_value, key)); [Float64(key)])
    tagged(key) = (_mw_bump!((:tagged, key)); string(tag, key))
    opaque(key) = (_mw_bump!((:opaque, key)); _mw_opaque(__self__, key))
end

const MW_SETTLED = Any[]
mw_settled() = lock(() -> copy(MW_SETTLED), MW_LOCK)
@dynamicstruct struct MWSettled
    seed::Int
    value = [string(seed)]
    DynamicObjects.property_settled(__self__, ::Val{:value}, stored) =
        lock(() -> push!(MW_SETTLED, stored), MW_LOCK)
end

function file_snapshot(root)
    snapshot = Dict{String,Vector{UInt8}}()
    for (dir, _, files) in walkdir(root), file in files
        path = joinpath(dir, file)
        snapshot[relpath(path, root)] = read(path)
    end
    snapshot
end

# The one listed entry of `object` for `property` (and `key`).
entry_at(entries, object, property, key=nothing) =
    only(e for e in entries if e.object === object && e.property === property && isequal(e.key, key))
end

@testitem "mem_cache_entries lists bare, indexed and nested entries by role, computing nothing" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
root = MWRoot("b"; label="override")
root.total; root.score(3); root.words(2); root.solo.z
root.attempts[] = 7
kid = root.child(:x)
kid.tag

entries = collect(mem_cache_entries(root))
@test eltype(mem_cache_entries(root)) == DynamicObjects.MemCacheEntry
# The walk computes nothing: `note` was never read, `values`/`total` once each.
@test (mw_calls(:note), mw_calls(:values), mw_calls(:total)) == (0, 1, 1)

total = entry_at(entries, root, :total)
@test (total.value, total.role, total.path) == (6.0, :derived, ())
@test entry_at(entries, root, :label).role === :input
@test entry_at(entries, root, :label).value == "override"
@test entry_at(entries, root, :attempts).role === :state
@test entry_at(entries, root, :__status__).role === :internal
score = entry_at(entries, root, :score, ((3,), (;)))
@test (score.value, score.role) == (6.0, :derived)
# An indexed property is listed entry by entry, never as its wrapper; fixed fields are not
# cache entries.
@test !any(e -> e.value isa DynamicObjects.IndexableProperty, entries)
@test !any(e -> e.object === root && e.property === :base, entries)

@test entry_at(entries, kid, :tag).path == ((:child, ((:x,), (;))),)
@test entry_at(entries, kid, :tag).role === :derived
@test entry_at(entries, kid, :__parent__).role === :input
@test entry_at(entries, kid, :name).role === :input
@test entry_at(entries, root.solo, :z).path == ((:solo, nothing),)
end

@testitem "mem_cache_entries lists each object once: aliases and cycles terminate" setup=[MemWalkFixtures] begin
using DynamicObjects
root = MWRoot("c")
a = root.child(:a)
a.up; a.tag
root.kids   # holds child(:a) again, and child(:b)

entries = collect(mem_cache_entries(root))
caches = unique(e -> objectid(getfield(e.object, :cache)), entries)
@test length(caches) == 3   # root, child(:a), child(:b); `a.up` is root again
@test allunique([(objectid(getfield(e.object, :cache)), e.property, e.key) for e in entries])
b = root.child(:b)
@test entry_at(entries, b, :name).path in (((:kids, nothing),), ((:child, ((:b,), (;))),))
# Inputs are never followed: walking a child does not climb to its parent through `__parent__`.
@test all(e -> e.object !== root, mem_cache_entries(root.child(:b)))
end

@testitem "mem_cache_entries is lazy and restartable, and refuses a non-object root" setup=[MemWalkFixtures] begin
using DynamicObjects
root = MWRoot("d")
root.total
root.child(:x).tag
walk = mem_cache_entries(root)
@test first(walk).object === root
@test length(collect(Iterators.take(walk, 2))) == 2
@test length(collect(walk)) == length(collect(walk))
@test_throws ArgumentError mem_cache_entries(42)
@test_throws ArgumentError prune_mem_caches!(Returns(true), "not an object")
end

@testitem "prune_mem_caches! evicts rejected derived entries and keeps inputs, state, wrappers and DO's entries" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
root = MWRoot("b"; label="override")
root.total
root.attempts[] = 7
kid = root.child(:x)
kid.tag
handle = root.score
handle(3)
root.words(2)
status = root.__status__
values = root.values

keep(entry) = entry.value isa Number || entry.value isa Array{Float64}
# Kept: `values`, `total`, `score(3)`. Evicted: the `child(:x)` entry, `words(2)`, `kid.tag`
# and `kid.base` (the child's forwarded copy of the parent's `base`, read by `tag`).
@test prune_mem_caches!(keep, root) == (objects=2, kept=3, evicted=4)
@test prune_mem_caches!(keep, root) == (objects=1, kept=3, evicted=0)

# Inputs, state and DO's own entries are untouched.
@test root.label == "override"
@test root.attempts[] == 7
@test root.__status__ === status
@test kid.name === :x
# Kept values are the same objects and are not recomputed.
@test root.values === values
@test root.total == 6.0 && mw_calls(:total) == 1
@test root.score(3) == 6.0 && mw_calls((:score, 3)) == 1
# Evicted values recompute on their next read; the held child still reaches its parent.
@test root.words(2) == "ww" && mw_calls((:words, 2)) == 2
@test kid.tag == "b/x" && mw_calls((:tag, :x)) == 2
@test getfield(root.child(:x), :cache) !== getfield(kid, :cache)
# The wrapper stays, so the held handle and the object share one subcache.
@test getfield(root.score, :cache) === getfield(handle, :cache)
invalidate!(root.score, 3)
@test isempty(cached_entries(handle))
end

@testitem "prune_mem_caches! touches no disk entry: an evicted @cached value reloads from disk" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
mktempdir() do dir
    disk = MWDisk(; __cache_base__=dir)
    @test disk.stored == Dict(:payload => "disk")
    path = disk.__cache_path__
    before = file_snapshot(dir)
    @test !isempty(before)
    @test prune_mem_caches!(Returns(false), disk).evicted >= 1
    @test disk.__cache_path__ == path
    @test file_snapshot(dir) == before
    @test disk.stored == Dict(:payload => "disk")
    @test mw_calls(:stored) == 1   # reloaded, not recomputed
end
end

@testitem "prune_mem_caches! keeps a computed @versioned property and the cache path" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
mktempdir() do dir
    path = joinpath(dir, "cv.md")
    write(path, "one")
    cv = MWVersioned(path; __cache_base__=dir)
    @test cv.rendered() == "ONE"
    version = cv.content_version
    cache_path = cv.__cache_path__
    @test entry_at(collect(mem_cache_entries(cv)), cv, :content_version).role === :internal
    write(path, "two")
    prune_mem_caches!(Returns(false), cv)
    # Re-deriving the version here would store new content under the old cache path.
    @test cv.content_version == version && mw_calls(:content_version) == 1
    @test cv.__cache_path__ == cache_path
end
end

@testitem "eviction drops no dependents and moves no version" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
root = MWRoot("e")
root.note
version = object_version(root)
@test prune_mem_caches!(entry -> entry.property !== :values, root).evicted == 1
@test root.total == 6.0 && mw_calls(:total) == 1
@test root.note == "e:6.0" && mw_calls(:note) == 1
@test object_version(root) == version
@test sync!(root) == Symbol[]
@test root.values == [1.0, 2.0, 3.0] && mw_calls(:values) == 2
end

@testitem "prune_mem_caches! leaves a computation in flight alone" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
MW_STARTED[] = Channel{Nothing}(1)
MW_RELEASE[] = Channel{Nothing}(1)
root = MWRoot("f")
root.total
pending = DynamicObjects.fetchproperty(root, :slow) do value, _
    value
end
@test pending isa DynamicObjects.Pending
take!(MW_STARTED[])
@test !any(e -> e.property === :slow, mem_cache_entries(root))
@test prune_mem_caches!(Returns(false), root).evicted >= 1
put!(MW_RELEASE[], nothing)
@test timedwait(() -> isready(pending), 30.0) === :ok
@test fetch(pending) == 99.0
@test root.slow == 99.0 && mw_calls(:slow) == 1   # stored despite the prune
end

@testitem "a remount view lists its own entries and its retained object's, and prunes both" setup=[MemWalkFixtures] begin
using DynamicObjects
mw_reset!()
source = MWView()
source.read_value(1)
view = remount(source; tag="req")
view.tagged(2)
view.opaque(3)

entries = collect(mem_cache_entries(view))
@test entry_at(entries, view, :tagged, ((2,), (;))).role === :derived
@test entry_at(entries, view, :tag).role === :input
@test entry_at(entries, source, :read_value, ((1,), (;))).value == [1.0]
# Opaque work the views share is held, and listed, by the retained object.
@test entry_at(entries, source, :opaque, ((3,), (;))).value[] == 3
@test any(e -> e.property === :opaque, mem_cache_entries(source))

@test prune_mem_caches!(Returns(false), view).evicted >= 3
@test view.tagged(2) == "req2" && mw_calls((:tagged, 2)) == 2
@test view.read_value(1) == [1.0] && mw_calls((:read_value, 1)) == 2
@test source.read_value(1) == [1.0] && mw_calls((:read_value, 1)) == 2
@test getfield(view.read_value, :cache) === getfield(source.read_value, :cache)
@test view.opaque(3)[] == 3 && mw_calls((:opaque, 3)) == 2
end

@testitem "an evicted value's recompute settles again" setup=[MemWalkFixtures] begin
using DynamicObjects
object = MWSettled(4)
value = object.value
@test mw_settled() == [value]
prune_mem_caches!(Returns(false), object)
@test object.value == ["4"]
@test mw_settled() == [value, object.value]
end

@testitem "prune_mem_caches! requires a Bool from keep" setup=[MemWalkFixtures] begin
using DynamicObjects
root = MWRoot("g")
root.total
# refused: a non-Bool answer is a caller error, never read as "keep" (dev §1, no silent defaults)
@test_throws TypeError prune_mem_caches!(entry -> nothing, root)
@test root.total == 6.0
end
