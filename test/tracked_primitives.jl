using TestItemRunner

@testmodule TrackedFixtures begin
using DynamicObjects
export TrackedStore, NestedStore, NestedDataset, NestedApp, write_model, write_dataset

write_model(root, name, body) = begin
    dir = joinpath(root, "models")
    mkpath(dir)
    path = joinpath(dir, name)
    write(path, body)
    path
end

# A changeable value carries no annotation: it is an ordinary property whose
# VALUE is tracked, and the properties reading it are ordinary derived reads.
@dynamicstruct struct TrackedStore
    root::AbstractString

    scenarios = ThreadSafeDict{Symbol,Int}(:a => 1)
    labels = sort!(collect(keys(scenarios)))
    label_count = length(labels)

    catalogue = TrackedDirectory(
        joinpath(root, "models");
        match = path -> endswith(path, ".txt"),
        key = path -> Symbol(first(splitext(basename(path)))),
        read = path -> read(path, String),
        version = :hash,
    )
    catalogue_keys = sort!(collect(keys(catalogue)))

    retained = ProviderRoots()
    retained_count = length(retained)
end

# The mock's real shape: the tracked values live in a nested store, and the
# root derives from the store's derived properties. Nothing here is annotated
# and nothing is flattened.
@dynamicstruct struct NestedStore
    root::AbstractString
    datasets = TrackedDirectory(
        joinpath(root, "data");
        match = path -> endswith(path, ".txt"),
        key = path -> Symbol(first(splitext(basename(path)))),
        version = :hash,
    )
    dataset_keys = sort!(collect(keys(datasets)))
end

# `store` arrives as a constructor FIELD, the way `Dataset(; store, key)` does.
@dynamicstruct struct NestedDataset
    store
    key::Symbol
    title = uppercase(string(key))
    sibling_count = length(store.dataset_keys)
end

@dynamicstruct struct NestedApp
    root::AbstractString
    store = NestedStore(root)
    dataset_nodes = [NestedDataset(store, key) for key in store.dataset_keys]
    node_count = length(dataset_nodes)
end

write_dataset(root, name) = begin
    dir = joinpath(root, "data")
    mkpath(dir)
    write(joinpath(dir, name), name)
end
end

@testitem "ThreadSafeDict is a Dict that reports a version" begin
using DynamicObjects

d = ThreadSafeDict{Symbol,Int}(:a => 1, :b => 2)
@test d isa AbstractDict{Symbol,Int}
@test length(d) == 2
@test d[:a] == 1
@test get(d, :missing, -1) == -1
@test haskey(d, :b)
@test sort(collect(keys(d))) == [:a, :b]
@test sort(collect(values(d))) == [1, 2]
@test sort(collect(d)) == [:a => 1, :b => 2]

start = tracked_version(d)
d[:c] = 3
@test tracked_version(d) > start
# Storing what is already there is not a change — a bump would invalidate
# every dependent for nothing.
unchanged = tracked_version(d)
d[:c] = 3
@test tracked_version(d) == unchanged
# Neither is deleting what was never there.
delete!(d, :nope)
@test tracked_version(d) == unchanged
delete!(d, :c)
@test tracked_version(d) > unchanged
@test !haskey(d, :c)

@test pop!(d, :a) == 1
@test pop!(d, :a, :gone) === :gone
@test_throws KeyError pop!(d, :a)
empty!(d)
@test isempty(d)

@test ThreadSafeDict() isa ThreadSafeDict{Any,Any}
@test ThreadSafeDict(:a => 1) isa ThreadSafeDict{Symbol,Int}
@test isempty(ThreadSafeDict{Symbol,Int}())
end

@testitem "ThreadSafeDict get! is atomic under contention" begin
using DynamicObjects

d = ThreadSafeDict{Symbol,Vector{Int}}()
# Every racer proposes its own value; exactly one wins, and each loser can
# tell it lost by identity — the check-and-insert the mock relies on.
proposals = [Int[i] for i in 1:64]
observed = Vector{Any}(undef, 64)
@sync for i in 1:64
    Threads.@spawn observed[i] = get!(() -> proposals[i], d, :one)
end
winner = d[:one]
@test all(o -> o === winner, observed)
@test count(i -> observed[i] === proposals[i], 1:64) == 1
@test length(d) == 1

# Concurrent distinct writes lose nothing.
counter = ThreadSafeDict{Int,Int}()
@sync for i in 1:256
    Threads.@spawn counter[i] = i
end
@test length(counter) == 256
@test all(i -> counter[i] == i, 1:256)

# A hit does not bump; only the insert did.
settled = tracked_version(d)
@test get!(() -> Int[-1], d, :one) === winner
@test tracked_version(d) == settled
end

@testitem "on_change! observers see every real change" begin
using DynamicObjects

d = ThreadSafeDict{Symbol,Int}()
seen = Int[]
on_change!(() -> push!(seen, length(d)), d)
d[:a] = 1
d[:a] = 1          # no change, no notification
d[:b] = 2
delete!(d, :a)
delete!(d, :zzz)   # absent, no notification
@test seen == [1, 2, 1]

# A throwing observer neither blocks the writer nor swallows the change.
noisy = ThreadSafeDict{Symbol,Int}()
on_change!(() -> error("observer is broken"), noisy)
before = tracked_version(noisy)
noisy[:a] = 1
@test tracked_version(noisy) > before
@test noisy[:a] == 1
end

@testitem "ProviderRoots retains and releases by provider" begin
using DynamicObjects

roots = ProviderRoots()
@test roots isa AbstractDict{String,Any}
@test isempty(roots)

retain!(roots, "fit-1", [1, 2, 3]; provider=:sampler)
retain!(roots, "fit-2", [4]; provider=:sampler)
retain!(roots, "fit-3", [5]; provider=:import)
@test length(roots) == 3
@test provider_of(roots, "fit-1") === :sampler
@test provider_of(roots, "nobody") === nothing
@test retained_providers(roots) == [:import, :sampler]
@test sort(collect(keys(roots))) == ["fit-1", "fit-2", "fit-3"]
@test sort(map(sum, values(roots))) == [4, 5, 6]

# `delete!` releases one id; a provider going away releases the rest as ONE
# change, not one per id.
before = tracked_version(roots)
delete!(roots, "fit-2")
after_delete = tracked_version(roots)
@test after_delete > before
@test release!(roots; provider=:sampler) == ["fit-1"]
@test tracked_version(roots) == after_delete + 1
@test collect(keys(roots)) == ["fit-3"]
@test release!(roots; provider=:sampler) == String[]
@test tracked_version(roots) == after_delete + 1

# Plain `setindex!` retains under the default provider.
roots["fit-4"] = :anything
@test provider_of(roots, "fit-4") === :default
end

@testitem "TrackedFile reads once and notices a change" begin
using DynamicObjects

dir = mktempdir()
path = joinpath(dir, "config.toml")

missing_file = TrackedFile(path)
# A path that does not exist yet is not an error — it has a stable version and
# starts producing changes when it appears.
@test !isfile(missing_file)
@test tracked_version(missing_file) == tracked_version(missing_file)
@test_throws SystemError read(missing_file)

write(path, "one")
f = TrackedFile(path; read=p -> read(p, String), version=:hash)
@test read(f) == "one"
@test read(f) === read(f)          # memoized, not re-read
@test isfile(f)
@test stat(f).size == 3
@test tracked_path(f) == path

before = tracked_version(f)
write(path, "two")
@test tracked_version(f) > before
@test read(f) == "two"

# Rewriting identical CONTENT is not a change under `:hash`.
settled = tracked_version(f)
write(path, "two")
@test tracked_version(f) == settled

changes = Ref(0)
on_change!(() -> changes[] += 1, f)
write(path, "three")
tracked_version(f)
@test changes[] == 1

@test_throws ErrorException TrackedFile(path; version=:nonsense)
end

@testitem "TrackedDirectory tracks membership and content as one version" begin
using DynamicObjects

dir = mktempdir()
write(joinpath(dir, "a.toml"), "first")
write(joinpath(dir, "b.toml"), "second")
write(joinpath(dir, "ignored.txt"), "not a model")

d = TrackedDirectory(dir;
    match = path -> endswith(path, ".toml"),
    key = path -> Symbol(first(splitext(basename(path)))),
    read = path -> read(path, String),
    version = :hash,
)
@test d isa AbstractDict
@test collect(keys(d)) == [:a, :b]          # sorted path order, reproducible
@test collect(keys(d)) isa Vector{Symbol}   # narrowed to what `key` produces
@test length(d) == 2
@test d[:a] == "first"
@test haskey(d, :b)
@test !haskey(d, :ignored)
@test_throws KeyError d[:ignored]
@test get(d, :ignored, "none") == "none"
@test sort(values(d)) == ["first", "second"]
@test collect(d) == [:a => "first", :b => "second"]
@test basename(tracked_paths(d)[:a]) == "a.toml"
@test tracked_path(d) == dir

# A file appearing is a change...
before = tracked_version(d)
write(joinpath(dir, "c.toml"), "third")
@test tracked_version(d) > before
@test collect(keys(d)) == [:a, :b, :c]
@test d[:c] == "third"

# ...as is a file's content changing, through the same version.
before = tracked_version(d)
write(joinpath(dir, "a.toml"), "rewritten")
@test tracked_version(d) > before
@test d[:a] == "rewritten"
# The unchanged neighbour keeps its memoized value.
@test d[:b] === d[:b]

# ...and so is a file disappearing.
before = tracked_version(d)
rm(joinpath(dir, "b.toml"))
@test tracked_version(d) > before
@test collect(keys(d)) == [:a, :c]
@test !haskey(d, :b)

# A directory that does not exist is empty, not an error.
absent = TrackedDirectory(joinpath(dir, "nope"))
@test isempty(absent)
@test collect(keys(absent)) == []
@test !isdir(absent)

# The default reader hands back the path, for a directory of things the
# consumer will open itself.
plain = TrackedDirectory(dir; match = path -> endswith(path, ".txt"))
@test basename(plain[Symbol("ignored.txt")]) == "ignored.txt"
end

@testitem "a tracked value invalidates what reads it" setup=[TrackedFixtures] begin
using DynamicObjects

root = mktempdir()
write_model(root, "one.txt", "first")
o = TrackedStore(root)

@test o.label_count == 1
@test o.catalogue_keys == [:one]
@test o.retained_count == 0

# The dependency graph is the one the macro already walked.
@test dependents(TrackedStore, :scenarios) == [:label_count, :labels]
@test dependents(TrackedStore, :labels) == [:label_count]
@test dependents(TrackedStore, :label_count) == Symbol[]

# The first sync records versions: there is no "before" to compare against.
@test sync!(o) == Symbol[]

o.scenarios[:b] = 2
@test sync!(o) == [:label_count, :labels]
@test o.label_count == 2
@test o.labels == [:a, :b]
# The tracked value itself survives — it is the same container, and it is what
# observed the change.
@test o.scenarios[:b] == 2
@test sync!(o) == Symbol[]

# A file appearing on disk invalidates exactly the same way a mutation does.
write_model(root, "two.txt", "second")
@test sync!(o) == [:catalogue_keys]
@test o.catalogue_keys == [:one, :two]
@test o.catalogue[:two] == "second"

# Retaining a root is a change like any other.
retain!(o.retained, "fit-1", o; provider=:test)
@test sync!(o) == [:retained_count]
@test o.retained_count == 1

# Untracked properties are never dropped, however many times we sync.
@test sync!(o) == Symbol[]
@test o.root == root
end

@testitem "invalidate! drops the closure, not the world" setup=[TrackedFixtures] begin
using DynamicObjects

root = mktempdir()
o = TrackedStore(root)
@test o.label_count == 1
@test o.catalogue_keys == Symbol[]

# Only what reads `scenarios` goes; the catalogue side of the graph is
# untouched.
@test invalidate!(o, :scenarios) == [:label_count, :labels]
@test invalidate!(o, :scenarios) == Symbol[]      # already dropped
@test o.catalogue_keys == Symbol[]

# `self=true` drops the tracked property too — which means the RHS runs again
# and produces a NEW container, losing in-place mutations. That is why the
# default is `false`.
before = o.scenarios
before[:b] = 2
@test o.label_count == 2          # recompute so there is something to drop
@test invalidate!(o, :scenarios; self=true) == [:label_count, :labels, :scenarios]
@test o.scenarios !== before
@test o.label_count == 1
end

@testitem "a change under a nested store reaches the root" setup=[TrackedFixtures] begin
using DynamicObjects

root = mktempdir()
write_dataset(root, "one.txt")
app = NestedApp(root)

@test app.node_count == 1
@test app.store.dataset_keys == [:one]
store = app.store
node = only(app.dataset_nodes)
@test node.title == "ONE"
@test node.sibling_count == 1

@test sync!(app) == Symbol[]      # first call records, drops nothing

# A file appears under the store. The root holds no tracked value at all — it
# only holds the store — so this is exactly the boundary a non-recursive sync
# would miss.
write_dataset(root, "two.txt")
@test sync!(app) == [:dataset_nodes, :node_count]
@test app.store.dataset_keys == [:one, :two]
@test app.node_count == 2
# The store itself was not rebuilt: it is the same object, and only what was
# derived from it went.
@test app.store === store
@test sync!(app) == Symbol[]

# The node reached the store through a constructor FIELD, and the diamond
# (root → store, root → nodes → store) syncs the store once and gives every
# holder the same answer.
write_dataset(root, "three.txt")
@test sync!(app) == [:dataset_nodes, :node_count]
@test only([n.key for n in app.dataset_nodes if n.key === :three]) === :three
@test all(n -> n.sibling_count == 3, app.dataset_nodes)
end

@testitem "sync! terminates on a back-reference and reuses shared work" setup=[TrackedFixtures] begin
using DynamicObjects

root = mktempdir()
write_dataset(root, "one.txt")
store = NestedStore(root)

# Two independent nodes over ONE store: syncing either must not double-count,
# and syncing a node must sync the store it holds.
left = NestedDataset(store, :left)
right = NestedDataset(store, :right)
@test left.sibling_count == 1
@test right.sibling_count == 1
@test sync!(left) == Symbol[]
@test sync!(right) == Symbol[]

write_dataset(root, "two.txt")
@test sync!(left) == [:sibling_count]
@test left.sibling_count == 2
# `right` has not been synced yet, so its own derived value is still stale —
# each object is brought up to date when it is synced, not before.
@test right.sibling_count == 1
@test sync!(right) == [:sibling_count]
@test right.sibling_count == 2
end
