using TestItemRunner

@testmodule TrackedValueFixtures begin
using DynamicObjects
export Library, Shelf, ShelfReader, ShelfApp, RunTable, Page, CachedSummary, KeyedDocs,
    TV_CALLS, TV_CACHE_BASE, write_doc, write_status, write_shelf_item

const TV_CALLS = Dict{Any,Int}()
_tv_count!(key) = (TV_CALLS[key] = get(TV_CALLS, key, 0) + 1)

write_doc(root, name, body=name) = begin
    mkpath(joinpath(root, "docs"))
    write(joinpath(root, "docs", "$name.txt"), body)
end

# Tracked inputs carry no marker: ordinary properties whose VALUE is tracked,
# read by ordinary derived properties.
@dynamicstruct struct Library
    root::String
    docs = TrackedDirectory(joinpath(root, "docs");
        match = path -> endswith(path, ".txt"),
        key = path -> Symbol(first(splitext(basename(path)))),
        read = path -> read(path, String))
    titles = sort!(collect(keys(docs)))
    title_count = length(titles)
    settings = TrackedFile(joinpath(root, "settings.txt"); read = path -> read(path, String))
    mode = strip(read(settings))
    label = root * "!"
end

write_shelf_item(root, name) = begin
    mkpath(joinpath(root, "shelf"))
    write(joinpath(root, "shelf", "$name.txt"), name)
end

# The tracked value lives in a nested object; holders derive from it.
@dynamicstruct struct Shelf
    root::String
    items = TrackedDirectory(joinpath(root, "shelf");
        key = path -> Symbol(first(splitext(basename(path)))))
    item_keys = sort!(collect(keys(items)))
end

# `shelf` arrives as a constructor FIELD.
@dynamicstruct struct ShelfReader
    shelf
    key::Symbol
    title = uppercase(string(key))
    sibling_count = length(shelf.item_keys)
    # Reads the child's TRACKED slot directly, not a property derived from it.
    raw_count = length(shelf.items)
end

@dynamicstruct struct ShelfApp
    root::String
    shelf = Shelf(root)
    readers = [ShelfReader(shelf, key) for key in shelf.item_keys]
    reader_count = length(readers)
end

write_status(root, id, body) = begin
    mkpath(joinpath(root, id))
    write(joinpath(root, id, "status.txt"), body)
end

# One child per run directory; each run tracks its own status file.
@dynamicstruct struct RunTable
    root::String
    listing = TrackedDirectory(root; match = isdir, key = basename)
    ids = sort!(collect(keys(listing)))
    @struct run(id) = begin
        status = TrackedFile(joinpath(root, id, "status.txt"); read = path -> read(path, String))
        summary = (_tv_count!((:summary, id)); uppercase(read(status)))
    end
    table = [run(id).summary for id in ids]
end

# `request` is the rebindable context stand-in for remount.
@dynamicstruct struct Page
    root::String
    request = "retained"
    docs = TrackedDirectory(joinpath(root, "docs");
        match = path -> endswith(path, ".txt"),
        key = path -> Symbol(first(splitext(basename(path)))))
    titles = sort!(collect(keys(docs)))
    banner = string(request, ":", length(titles))
end

const TV_CACHE_BASE = Ref("")

@dynamicstruct struct CachedSummary
    root::String
    __cache_base__ = TV_CACHE_BASE[]
    source = TrackedFile(joinpath(root, "input.txt"); read = path -> read(path, String))
    @cached summary = (_tv_count!(:cached_summary); uppercase(read(source)))
end

# An indexed property whose entries are tracked values, and one derived from it.
@dynamicstruct struct KeyedDocs
    root::String
    doc(name::Symbol) = TrackedFile(joinpath(root, "$name.txt"); read = path -> read(path, String))
    size_of(name::Symbol) = (_tv_count!((:size_of, name)); length(read(doc(name))))
end
end

@testitem "TrackedFile reads once and notices a change" begin
using DynamicObjects

dir = mktempdir()
path = joinpath(dir, "config.txt")

missing_file = TrackedFile(path)
# A path that does not exist yet has a stable version and changes when it appears.
@test !isfile(missing_file)
@test tracked_version(missing_file) == tracked_version(missing_file)
@test_throws SystemError read(missing_file)

write(path, "one")
@test tracked_version(missing_file) > 1

f = TrackedFile(path; read = p -> read(p, String))
@test read(f) == "one"
bytes = TrackedFile(path)          # default reader: a fresh Vector{UInt8} per read
@test read(bytes) == codeunits("one")
@test read(bytes) === read(bytes)  # memoized, not re-read
@test isfile(f)
@test stat(f).size == 3
@test tracked_path(f) == path

# The default :mtime probe stamps size too, so a rewrite of a different length
# registers even within one filesystem timestamp tick.
before = tracked_version(f)
write(path, "three")
@test tracked_version(f) > before
@test read(f) == "three"

# Under :hash, rewriting identical content is not a change.
h = TrackedFile(path; read = p -> read(p, String), version = :hash)
settled = tracked_version(h)
write(path, "three")
@test tracked_version(h) == settled

changes = Ref(0)
on_change!(() -> changes[] += 1, h)
write(path, "four!")
tracked_version(h)
@test changes[] == 1
# A forced change bumps, drops the memoized read and notifies.
v = tracked_version(h)
@test notify_change!(h) > v
@test changes[] == 2
memo = read(bytes)
notify_change!(bytes)
@test read(bytes) == memo && read(bytes) !== memo

# A throwing observer is logged, never thrown at the writer.
on_change!(() -> error("observer failed"), h)
@test_logs (:error, r"tracked-value observer threw") match_mode=:any notify_change!(h)

@test_throws ArgumentError TrackedFile(path; version = :nonsense)
@test_throws ArgumentError TrackedDirectory(dir; version = :nonsense)
@test tracked_version(42) === nothing
end

@testitem "TrackedDirectory tracks membership and content as one version" begin
using DynamicObjects

dir = mktempdir()
write(joinpath(dir, "a.toml"), "first")
write(joinpath(dir, "b.toml"), "second")
write(joinpath(dir, "ignored.txt"), "not matched")

d = TrackedDirectory(dir;
    match = path -> endswith(path, ".toml"),
    key = path -> Symbol(first(splitext(basename(path)))),
    read = path -> read(path, String),
    version = :hash)
@test d isa AbstractDict
@test collect(keys(d)) == [:a, :b]          # sorted path order
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

before = tracked_version(d)
write(joinpath(dir, "c.toml"), "third")
@test tracked_version(d) > before
@test collect(keys(d)) == [:a, :b, :c]

boxed = TrackedDirectory(dir; match = path -> endswith(path, ".toml"),
    key = path -> Symbol(first(splitext(basename(path)))), read = path -> [read(path, String)])
a_memo, b_memo = boxed[:a], boxed[:b]
before = tracked_version(d)
write(joinpath(dir, "a.toml"), "rewritten")
@test tracked_version(d) > before
@test d[:a] == "rewritten"
@test boxed[:a] !== a_memo && only(boxed[:a]) == "rewritten"
@test boxed[:b] === b_memo                   # the unchanged neighbour keeps its value

before = tracked_version(d)
rm(joinpath(dir, "b.toml"))
@test tracked_version(d) > before
@test collect(keys(d)) == [:a, :c]

absent = TrackedDirectory(joinpath(dir, "nope"))
@test isempty(absent)
@test collect(keys(absent)) == []
@test !isdir(absent)

# Subdirectories as entries: an entry added inside one moves its stamp.
runs = mktempdir()
mkpath(joinpath(runs, "r1"))
listing = TrackedDirectory(runs; match = isdir, key = basename)
@test collect(keys(listing)) == ["r1"]
before = tracked_version(listing)
write(joinpath(runs, "r1", "new.json"), "{}")
@test tracked_version(listing) > before

plain = TrackedDirectory(dir; match = path -> endswith(path, ".txt"))
@test basename(plain[Symbol("ignored.txt")]) == "ignored.txt"
end

@testitem "sync! drops what reads a changed tracked value, and nothing else" setup=[TrackedValueFixtures] begin
using DynamicObjects

root = mktempdir()
write_doc(root, "one")
write(joinpath(root, "settings.txt"), "fast")
lib = Library(root)

@test lib.title_count == 1
@test lib.mode == "fast"
@test lib.label == root * "!"
@test dependents(Library, :docs) == [:title_count, :titles]
@test dependents(Library, :settings) == [:mode]
@test dependents(Library, :title_count) == Symbol[]

@test sync!(lib) == Symbol[]
docs = lib.docs
write_doc(root, "two")
@test sync!(lib) == [:title_count, :titles]
@test lib.title_count == 2
@test lib.docs === docs        # the tracked container itself is kept
@test sync!(lib) == Symbol[]

write(joinpath(root, "settings.txt"), "careful")
@test sync!(lib) == [:mode]
@test lib.mode == "careful"
@test lib.title_count == 2      # untouched side of the graph stays cached

@test sync!(lib) == Symbol[]
@test sync!(42) == Symbol[]     # not a @dynamicstruct object: no cache to sync
@test_throws ArgumentError object_version(42)
end

@testitem "a change between a dependent's compute and the first sync! is not missed" setup=[TrackedValueFixtures] begin
using DynamicObjects

# The request shape: a host syncs the root BEFORE any property is read, the
# request computes, and the file changes before the next request's sync.
root = mktempdir()
write_doc(root, "one")
lib = Library(root)
@test sync!(lib) == Symbol[]          # nothing computed yet
@test lib.title_count == 1            # computed after the sync
write_doc(root, "two")
@test sync!(lib) == [:title_count, :titles]
@test lib.title_count == 2

# And with no change in between, the first stamp is not mistaken for one.
root2 = mktempdir()
write_doc(root2, "one")
fresh_lib = Library(root2)
@test fresh_lib.title_count == 1
@test sync!(fresh_lib) == Symbol[]
@test fresh_lib.title_count == 1
end

@testitem "a change under a nested object reaches every holder" setup=[TrackedValueFixtures] begin
using DynamicObjects

root = mktempdir()
write_shelf_item(root, "one")
app = ShelfApp(root)
@test app.reader_count == 1
shelf = app.shelf
reader = only(app.readers)
@test reader.sibling_count == 1
@test reader.raw_count == 1
@test sync!(app) == Symbol[]

write_shelf_item(root, "two")
@test sync!(app) == [:reader_count, :readers]
@test app.shelf === shelf          # the nested object is not rebuilt
@test app.reader_count == 2
@test all(r -> r.sibling_count == 2 && r.raw_count == 2, app.readers)

# Two holders of ONE shelf through a constructor field: each learns of the
# change once, whenever it syncs — including a value read straight from the
# shelf's tracked slot.
left = ShelfReader(shelf, :left)
right = ShelfReader(shelf, :right)
@test (left.sibling_count, left.raw_count) == (2, 2)
@test (right.sibling_count, right.raw_count) == (2, 2)
# A holder's first sync cannot tell which of the shelf's earlier changes its
# values already saw, so it drops them once — the shelf has changed before.
@test sync!(left) == [:raw_count, :sibling_count]
@test sync!(right) == [:raw_count, :sibling_count]
@test (left.sibling_count, left.raw_count, right.sibling_count, right.raw_count) == (2, 2, 2, 2)
@test sync!(left) == Symbol[]
@test sync!(right) == Symbol[]
write_shelf_item(root, "three")
@test sync!(left) == [:raw_count, :sibling_count]
@test (left.sibling_count, left.raw_count) == (3, 3)
@test right.raw_count == 2          # not synced yet: still the old derived value
@test sync!(right) == [:raw_count, :sibling_count]
@test right.raw_count == 3
end

@testitem "an indexed child's file change drops that child's work only" setup=[TrackedValueFixtures] begin
using DynamicObjects

root = mktempdir()
write_status(root, "a", "queued")
write_status(root, "b", "queued")
empty!(TV_CALLS)
runs = RunTable(root)
@test runs.table == ["QUEUED", "QUEUED"]
@test TV_CALLS[(:summary, "a")] == 1 && TV_CALLS[(:summary, "b")] == 1
@test sync!(runs) == Symbol[]

write_status(root, "a", "running")
@test sync!(runs) == [:table]
@test runs.table == ["RUNNING", "QUEUED"]
@test TV_CALLS[(:summary, "a")] == 2
@test TV_CALLS[(:summary, "b")] == 1     # the other run's work is kept
@test sync!(runs) == Symbol[]

# A new run directory changes the listing.
write_status(root, "c", "queued")
@test sync!(runs) == [:ids, :table]
@test runs.table == ["RUNNING", "QUEUED", "QUEUED"]
@test TV_CALLS[(:summary, "b")] == 1
end

@testitem "an indexed property's tracked entries invalidate its dependents" setup=[TrackedValueFixtures] begin
using DynamicObjects

root = mktempdir()
write(joinpath(root, "a.txt"), "aa")
write(joinpath(root, "b.txt"), "bbb")
empty!(TV_CALLS)
docs = KeyedDocs(root)
@test docs.size_of(:a) == 2 && docs.size_of(:b) == 3
@test sync!(docs) == Symbol[]
write(joinpath(root, "a.txt"), "aaaa")
# The dependent is an indexed property: it loses all its entries.
@test sync!(docs) == [:size_of]
@test docs.size_of(:a) == 4
@test docs.size_of(:b) == 3
@test TV_CALLS[(:size_of, :b)] == 2

# Per-entry invalidation of an indexed property keyed by a Symbol still works.
@test invalidate!(docs.doc, :a) === nothing
end

@testitem "sync! on a remount view drops shared and view-local work" setup=[TrackedValueFixtures] begin
using DynamicObjects

root = mktempdir()
write_doc(root, "one")
page = Page(root)
view = remount(page; request = "req-1")
@test view.banner == "req-1:1"
@test page.titles == [:one]          # shared with the view
@test sync!(view) == Symbol[]

write_doc(root, "two")
@test sync!(view) == [:banner, :titles]
@test view.banner == "req-1:2"
@test page.titles == [:one, :two]
@test object_version(view) == object_version(page)
later = remount(page; request = "req-2")
@test sync!(later) == Symbol[]
@test later.banner == "req-2:2"
end

@testitem "sync! removes a dropped @cached dependent's disk entry" setup=[TrackedValueFixtures] begin
using DynamicObjects

TV_CACHE_BASE[] = mktempdir()
root = mktempdir()
write(joinpath(root, "input.txt"), "first")
empty!(TV_CALLS)
s = CachedSummary(root)
@test s.summary == "FIRST"
@test sync!(s) == Symbol[]
write(joinpath(root, "input.txt"), "second!")
@test sync!(s) == [:summary]
# Without the disk drop this would reload "FIRST" from the stale entry.
@test s.summary == "SECOND!"
@test TV_CALLS[:cached_summary] == 2
end

@testitem "sync! cost at a few hundred tracked files" setup=[TrackedValueFixtures] begin
using DynamicObjects

root = mktempdir()
for i in 1:300
    write_status(root, string("run", lpad(i, 3, '0')), "queued")
end
runs = RunTable(root)
@test length(runs.table) == 300
sync!(runs); sync!(runs)
elapsed = minimum(@elapsed(sync!(runs)) for _ in 1:5)
@info "sync! over 300 run directories and 300 tracked files, nothing changed" elapsed
@test elapsed < 1.0
write_status(root, "run150", "done!")
@test sync!(runs) == [:table]
@test runs.table[150] == "DONE!"
end
