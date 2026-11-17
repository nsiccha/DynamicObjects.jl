using TestItemRunner

# A keyword an object was constructed with is an input of the object, not a
# value derived from its declared default. `sync!` and `clear_cache!` keep it
# wherever the drop step meets it: among the dependents of a changed tracked
# value, among what a holder derived from a child, as a computed `@versioned`
# version, and as a remount view's rebound context. Before, `sync!` dropped the
# keyword and the next read recomputed its declared default, while a later
# `clear_mem_caches!` restored it (snag `sync-drops-const-2643711a`).

@testmodule SyncInputFixtures begin
using DynamicObjects
export SyncIn, InputsCard, InputsBoard, InputsVersioned, SI_CACHE_BASE

@dynamicstruct struct SyncIn
    root::String
    settings = TrackedFile(joinpath(root, "settings.txt"); read = path -> read(path, String))
    raw = read(settings)
    mode = strip(read(settings))
    shout = uppercase(mode)
end

# Children held in a container read their parent's `mode`; `headline` is derived
# from the children only, so the parent's own graph does not reach it from
# `settings`: the holder step does.
@dynamicstruct struct InputsCard
    (; mode) = __parent__
    shown = "card:" * mode
end

@dynamicstruct struct InputsBoard
    root::String
    settings = TrackedFile(joinpath(root, "settings.txt"); read = path -> read(path, String))
    mode = strip(read(settings))
    cards = [InputsCard(; __parent__ = __self__) for _ in 1:2]
    headline = join([card.shown for card in cards], ",")
end

const SI_CACHE_BASE = Ref("")

# The version probes the file itself, so it is not a dependent of `source`:
# dropping `summary` re-keys it.
@dynamicstruct struct InputsVersioned
    root::String
    __cache_base__ = SI_CACHE_BASE[]
    source = TrackedFile(joinpath(root, "input.txt"); read = path -> read(path, String))
    @versioned content_version = file_version(joinpath(root, "input.txt"); by = :hash)
    @cached summary = uppercase(read(source))
    tag = string("v=", content_version)
end
end

@testitem "sync! keeps a construction keyword whose default reads a tracked value" setup=[SyncInputFixtures] begin
using DynamicObjects

root = mktempdir()
write(joinpath(root, "settings.txt"), "one")
o = SyncIn(root; mode = "kept")
@test (o.raw, o.mode, o.shout) == ("one", "kept", "KEPT")
plain = SyncIn(root)
@test (plain.raw, plain.mode, plain.shout) == ("one", "one", "ONE")

write(joinpath(root, "settings.txt"), "two!")
@test sync!(o) == [:raw, :shout]
@test (o.raw, o.mode, o.shout) == ("two!", "kept", "KEPT")
# The control: without the keyword, `mode` is derived and follows the file.
@test sync!(plain) == [:mode, :raw, :shout]
@test plain.mode == "two!"

# Every invalidation now agrees on the keyword.
clear_mem_caches!(o)
@test (o.raw, o.mode, o.shout) == ("two!", "kept", "KEPT")
@test DynamicObjects.clear_cache!(o, :settings) == [:raw, :settings, :shout]
@test o.mode == "kept"
@test DynamicObjects.clear_cache!(o, :mode) == Symbol[]
@test o.mode == "kept"
@test sync!(o) == Symbol[]
end

@testitem "the holder step keeps a construction keyword derived from children" setup=[SyncInputFixtures] begin
using DynamicObjects

root = mktempdir()
write(joinpath(root, "settings.txt"), "one")
@test dependents(InputsBoard, :settings) == [:mode]

pinned = InputsBoard(root; headline = "pinned")
@test pinned.cards[2].shown == "card:one"
@test pinned.headline == "pinned"
board = InputsBoard(root)
@test board.headline == "card:one,card:one"

write(joinpath(root, "settings.txt"), "two!")
@test sync!(pinned) == [:mode]
@test pinned.cards[2].shown == "card:two!"
@test pinned.headline == "pinned"
@test sync!(board) == [:headline, :mode]
@test board.headline == "card:two!,card:two!"

# `clear_cache!` takes the same holder step.
@test DynamicObjects.clear_cache!(pinned, :mode) == [:mode]
@test pinned.headline == "pinned"
@test DynamicObjects.clear_cache!(board, :mode) == [:headline, :mode]
@test board.headline == "card:two!,card:two!"
end

@testitem "a computed @versioned version given as a keyword is not re-keyed" setup=[SyncInputFixtures] begin
using DynamicObjects

SI_CACHE_BASE[] = mktempdir()
root = mktempdir()
write(joinpath(root, "input.txt"), "first")
v = InputsVersioned(root; content_version = "pinned")
@test v.summary == "FIRST"
@test v.tag == "v=pinned"
path = v.__cache_path__

write(joinpath(root, "input.txt"), "second!")
@test sync!(v) == [:summary]
@test v.content_version == "pinned"
@test v.tag == "v=pinned"
@test v.__cache_path__ == path
@test v.summary == "SECOND!"

# The control, on its own root (its disk entries must not depend on the pinned
# instance's): a derived version is re-keyed with what reads it.
root2 = mktempdir()
write(joinpath(root2, "input.txt"), "first")
d = InputsVersioned(root2)
version = d.content_version
@test d.tag == "v=$version"
@test d.summary == "FIRST"
write(joinpath(root2, "input.txt"), "second!")
@test sync!(d) == [:content_version, :summary, :tag]
@test d.content_version != version
@test d.tag == "v=$(d.content_version)"
@test d.summary == "SECOND!"
end

@testitem "a remount view keeps its rebound context through sync! and clear_cache!" setup=[SyncInputFixtures] begin
using DynamicObjects

root = mktempdir()
write(joinpath(root, "settings.txt"), "one")
o = SyncIn(root)
view = remount(o; mode = "view")
@test (o.mode, view.mode, view.shout) == ("one", "view", "VIEW")

write(joinpath(root, "settings.txt"), "two!")
@test sync!(view) == [:mode, :shout]
@test view.mode == "view"
@test view.shout == "VIEW"
@test o.mode == "two!"
@test view.raw == "two!"

@test DynamicObjects.clear_cache!(view, :settings) == [:mode, :raw, :settings, :shout]
@test view.mode == "view"
@test view.shout == "VIEW"
@test o.mode == "two!"
end
