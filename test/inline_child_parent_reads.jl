using TestItemRunner

# A child reads its parent's properties: an inline `@struct` child through the
# names it forwards (`content` below is the child's own copy of the parent's), and
# any child through `__parent__.name`. `sync!` and `clear_cache!` drop what the
# children an object holds read of a property they drop, and what each child
# derived from it; before, the parent recomputed while every child kept its first
# copy for good (snag `inline-child-kee-8949a0ed`).

@testmodule ParentReadFixtures begin
using DynamicObjects
export ReadParent, ReadHolder, ReadSub, ReadSubDestructured, ReadSubOverridden,
    ReadVersioned, PR_CALLS, PR_CACHE_BASE

const PR_CALLS = Dict{Any,Int}()
_pr!(key) = (PR_CALLS[key] = get(PR_CALLS, key, 0) + 1)
const PR_CACHE_BASE = Ref("")

@dynamicstruct struct ReadParent
    path::String
    request = "retained"
    tracked = TrackedFile(path; read = p -> read(p, String))
    content = read(tracked)
    other = "o"
    fit(k::Symbol) = string(content, "-fit-", k)
    @struct child(k::Symbol) = begin
        @state visits = Ref(0)
        seen = (_pr!((:seen, k)); content * string(k))
        stable = (_pr!((:stable, k)); other * string(k))
        via_fit = fit(k) * "!"
        explicit = __parent__.content * "|"
        size = length(read(__parent__.tracked))
        @struct leaf = begin
            deep = seen * "."
        end
    end
    @struct single = begin
        seen = (_pr!(:single); content * "!")
    end
    table = [child(k).leaf.deep for k in (:x, :y)]
end

# Children that are not inline: an `@include`d struct reading its parent through
# a destructure, one whose read is overridden at construction, and children held
# in an array.
@dynamicstruct struct ReadSub
    (; content) = __parent__
    seen = content * "/sub"
end

@dynamicstruct struct ReadSubDestructured
    (; content) = __self__.__parent__
    seen = content * "/destructured"
end

@dynamicstruct struct ReadSubOverridden
    (; content) = __parent__
    seen = content * "/overridden"
end

@dynamicstruct struct ReadHolder
    path::String
    tracked = TrackedFile(path; read = p -> read(p, String))
    content = read(tracked)
    @include sub = ReadSub()
    @include destructured = ReadSubDestructured()
    @include overridden = ReadSubOverridden(; content = "fixed")
    subs = [ReadSub(; __parent__ = __self__) for _ in 1:2]
    total = join((sub.seen, destructured.seen, overridden.seen, subs[2].seen), " ")
end

# A versioned parent: its children's disk entries live under its cache path.
@dynamicstruct struct ReadVersioned
    path::String
    __cache_base__ = PR_CACHE_BASE[]
    tracked = TrackedFile(path; read = p -> read(p, String))
    @versioned content_version = file_version(path; by = :hash)
    content = read(tracked)
    @struct child(k::Symbol) = begin
        @cached payload = (_pr!((:payload, k)); content * string(k))
    end
end
end

@testitem "sync! drops what inline children read of a changed parent property" setup=[ParentReadFixtures] begin
using DynamicObjects

path = tempname(); write(path, "a")
empty!(PR_CALLS)
p = ReadParent(path)
x = p.child(:x)
@test (x.seen, x.stable, x.via_fit, x.explicit, x.size) == ("ax", "ox", "a-fit-x!", "a|", 1)
@test p.single.seen == "a!"
@test p.table == ["ax.", "ay."]
x.visits[] = 3
@test sync!(p) == Symbol[]

write(path, "bb"); notify_change!(p.tracked)
# The parent's `table` derives from the children, so it drops in the same call.
@test sync!(p) == [:content, :fit, :table]
@test p.child(:x) === x                      # the child itself is kept
@test x.content == "bb"                      # its forwarded copy is not
@test (x.seen, x.via_fit, x.explicit, x.size) == ("bbx", "bb-fit-x!", "bb|", 2)
@test p.single.seen == "bb!"
@test p.table == ["bbx.", "bby."]
# What no dropped property reaches is kept, `@state` included.
@test x.stable == "ox"
@test PR_CALLS[(:stable, :x)] == 1
@test PR_CALLS[(:seen, :x)] == 2
@test x.visits[] == 3
# Nothing is dropped twice.
@test sync!(p) == Symbol[]
@test PR_CALLS[(:seen, :x)] == 2
end

@testitem "clear_cache! reaches what inline children read of the cleared property" setup=[ParentReadFixtures] begin
using DynamicObjects

path = tempname(); write(path, "a")
empty!(PR_CALLS)
p = ReadParent(path)
x = p.child(:x)
@test p.table == ["ax.", "ay."] && x.stable == "ox" && p.single.seen == "a!"
@test DynamicObjects.clear_cache!(p, :content) == [:content, :table]
@test p.table == ["ax.", "ay."] && p.single.seen == "a!"
# Recomputed from the cleared property, not served from the children's copies.
@test PR_CALLS[(:seen, :x)] == 2 && PR_CALLS[:single] == 2
@test PR_CALLS[(:stable, :x)] == 1
@test object_version(x) > 1                  # holders of the child see it move
@test sync!(p) == Symbol[]
@test PR_CALLS[(:seen, :x)] == 2
end

@testitem "sync! reaches children read through __parent__, destructures and arrays" setup=[ParentReadFixtures] begin
using DynamicObjects

path = tempname(); write(path, "a")
h = ReadHolder(path)
@test h.total == "a/sub a/destructured fixed/overridden a/sub"
write(path, "bb"); notify_change!(h.tracked)
@test sync!(h) == [:content, :total]
# An override at construction is an input, not a read of the parent.
@test h.total == "bb/sub bb/destructured fixed/overridden bb/sub"
@test h.overridden.content == "fixed"
end

@testitem "a child's cache path follows its parent's re-keyed version" setup=[ParentReadFixtures] begin
using DynamicObjects

PR_CACHE_BASE[] = mktempdir()
path = tempname(); write(path, "a")
empty!(PR_CALLS)
p = ReadVersioned(path; __hold_recent_version__ = false)
x = p.child(:x)
@test x.payload == "ax"
old_dir = x.__cache_path__
@test startswith(old_dir, p.__cache_path__)

write(path, "bb"); notify_change!(p.tracked)
@test sync!(p) == [:content, :content_version]
@test x.payload == "bbx"
# Stored under the new version: the old version's entry still holds the old value.
@test x.__cache_path__ != old_dir
@test startswith(x.__cache_path__, p.__cache_path__)
@test PR_CALLS[(:payload, :x)] == 2

@test isfile(joinpath(x.__cache_path__, "payload.sjl"))

# The old content again: the old version holds no entry computed from the new one.
write(path, "a")
again = ReadVersioned(path; __hold_recent_version__ = false)
@test again.child(:x).payload == "ax"
end

@testitem "sync! through a remount view refreshes children read through the view" setup=[ParentReadFixtures] begin
using DynamicObjects

path = tempname(); write(path, "a")
p = ReadParent(path)
view = remount(p; request = "r1")
@test view.child(:x).seen == "ax"
@test view.table == ["ax.", "ay."]
write(path, "bb"); notify_change!(p.tracked)
@test :table in sync!(view)
@test view.child(:x).seen == "bbx"
@test remount(p; request = "r2").table == ["bbx.", "bby."]
@test p.child(:x).seen == "bbx"
end
