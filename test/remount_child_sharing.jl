using TestItemRunner

@testmodule RemountChildFixtures begin
using DynamicObjects
export ChildRoot, OpaqueChildRoot, RCS_CALLS, RCS_STARTED, RCS_RELEASE, rcs_reset!

const RCS_CALLS = Dict{Symbol,Int}()
const RCS_LOCK = ReentrantLock()
# Unbounded, and released once per view: a regression that starts a second
# `slow()` fails its count assertion instead of blocking forever.
const RCS_STARTED = Ref(Channel{Nothing}(Inf))
const RCS_RELEASE = Ref(Channel{Nothing}(Inf))
_rcs_bump!(k) = lock(() -> (RCS_CALLS[k] = get(RCS_CALLS, k, 0) + 1), RCS_LOCK)
function rcs_reset!()
    empty!(RCS_CALLS)
    RCS_STARTED[] = Channel{Nothing}(Inf)
    RCS_RELEASE[] = Channel{Nothing}(Inf)
    nothing
end

# `ctx` is the request context each remount rebinds. `data` is
# context-independent parent state; `scoped` derives from the context. Every
# child is read through remount views only, never on the retained source first.
@dynamicstruct struct ChildRoot
    ctx = nothing
    data = (_rcs_bump!(:data); [1, 2, 3])
    scoped = (ctx, :scoped)
    @struct child(k::Int) = begin
        intrinsic() = (_rcs_bump!(:child_intrinsic); Ref(k))
        on_parent() = (_rcs_bump!(:child_on_parent); sum(data) + k)
        on_context() = (_rcs_bump!(:child_on_context); scoped)
        slow() = begin
            _rcs_bump!(:child_slow)
            put!(RCS_STARTED[], nothing)
            take!(RCS_RELEASE[])
            Ref(k)
        end
        @struct grandchild = begin
            deep() = (_rcs_bump!(:grandchild_deep); Ref(sum(data)))
        end
    end
    @struct single = begin
        intrinsic() = (_rcs_bump!(:single_intrinsic); Ref(:single))
        on_parent() = (_rcs_bump!(:single_on_parent); Ref(sum(data)))
    end
    @fresh @struct fresh_child(k::Int) = begin
        intrinsic() = (_rcs_bump!(:fresh_intrinsic); Ref(k))
    end
end

# Opaque child work: each body hands `__self__` to a helper outside the struct,
# which reads a child property built on a forwarded parent name.
_rcs_reads_total(c, n) = Ref(c.total + n)
_rcs_reads_scoped(c, n) = (c.scoped_here, n)

@dynamicstruct struct OpaqueChildRoot
    ctx = nothing
    data = [1, 2, 3]
    scoped = (ctx, :scoped)
    @struct child(k::Int) = begin
        total = sum(data)
        scoped_here = scoped
        on_parent(n::Int) = (_rcs_bump!(:opaque_on_parent); _rcs_reads_total(__self__, n))
        on_context(n::Int) = (_rcs_bump!(:opaque_on_context); _rcs_reads_scoped(__self__, n))
    end
end
end

@testitem "an inline child first read through a remount view is realized on the retained source" setup=[RemountChildFixtures] begin
using DynamicObjects

rcs_reset!()
source = ChildRoot()
views = [remount(source; ctx=i) for i in 1:3]
for v in views
    @test v.child(1).__parent__ === v
    @test v.single.__parent__ === v
end
# Each view holds its own child instance (it carries the view as parent) ...
@test views[1].child(1) !== views[2].child(1)
@test views[1].single !== views[2].single
# ... over ONE child cache, so the child's context-independent work runs once.
child_values = [v.child(1).intrinsic() for v in views]
single_values = [v.single.intrinsic() for v in views]
@test all(x -> x === child_values[1], child_values)
@test all(x -> x === single_values[1], single_values)
@test RCS_CALLS[:child_intrinsic] == 1
@test RCS_CALLS[:single_intrinsic] == 1
# That cache is the retained source's own child, parented by the source.
@test source.child(1).__parent__ === source
@test source.child(1).intrinsic() === child_values[1]
@test source.single.intrinsic() === single_values[1]
@test RCS_CALLS[:child_intrinsic] == 1
@test RCS_CALLS[:single_intrinsic] == 1
# The view-built child keeps its own progress node rather than the source's.
@test views[1].child(1).__status__ !== source.child(1).__status__
end

@testitem "remounted child work on shared parent state is reused; context-derived work is not" setup=[RemountChildFixtures] begin
using DynamicObjects

rcs_reset!()
source = ChildRoot()
for i in 1:3
    v = remount(source; ctx=i)
    @test v.child(1).on_parent() == 7
    @test v.single.on_parent()[] == 6
    @test v.child(1).on_context() == (i, :scoped)
end
@test RCS_CALLS[:data] == 1
@test RCS_CALLS[:child_on_parent] == 1
@test RCS_CALLS[:single_on_parent] == 1
@test RCS_CALLS[:child_on_context] == 3

# An explicit `__parent__` rebinding to a different object proves nothing about
# the forwarded parent state, so the child recomputes against the new parent.
other = ChildRoot(; data=[10])
rebound = remount(source.child(1); __parent__=other)
@test rebound.on_parent() == 11
@test RCS_CALLS[:child_on_parent] == 2
end

@testitem "remount views share one in-flight child computation" setup=[RemountChildFixtures] begin
using DynamicObjects

rcs_reset!()
source = ChildRoot()
a = remount(source; ctx=:a)
b = remount(source; ctx=:b)
pending_a = fetchindex(a.child(1).slow) do rv, _
    rv
end
@test pending_a isa Pending
take!(RCS_STARTED[])
pending_b = fetchindex(b.child(1).slow) do rv, _
    rv
end
@test pending_b isa Pending
foreach(_ -> put!(RCS_RELEASE[], nothing), 1:3)
@test fetch(pending_a) === fetch(pending_b)
@test remount(source; ctx=:c).child(1).slow() === fetch(pending_a)
@test RCS_CALLS[:child_slow] == 1
end

@testitem "nested inline children share through every remount level" setup=[RemountChildFixtures] begin
using DynamicObjects

rcs_reset!()
source = ChildRoot()
for i in 1:3
    v = remount(source; ctx=i)
    grandchild = v.child(1).grandchild
    @test grandchild.__parent__ === v.child(1)
    @test grandchild.deep()[] == 6
end
@test RCS_CALLS[:grandchild_deep] == 1
end

@testitem "a @fresh inline child stays a fresh view-local child per call" setup=[RemountChildFixtures] begin
using DynamicObjects

rcs_reset!()
source = ChildRoot()
v = remount(source; ctx=1)
first_child = v.fresh_child(1)
second_child = v.fresh_child(1)
@test first_child !== second_child
@test first_child.__parent__ === v
@test first_child.intrinsic() !== second_child.intrinsic()
@test RCS_CALLS[:fresh_intrinsic] == 2
@test length(source.fresh_child.cache) == 0
end

@testitem "opaque child work reading shared parent state is shared across remount views" setup=[RemountChildFixtures] begin
using DynamicObjects

rcs_reset!()
source = OpaqueChildRoot()
views = [remount(source; ctx=i) for i in 1:3]
# The guarded `__self__` reads `total`, built on the forwarded parent `data`
# that every view shares, so one computation serves every view.
on_parent = [v.child(1).on_parent(5) for v in views]
@test all(x -> x === on_parent[1], on_parent)
@test on_parent[1][] == 11
@test RCS_CALLS[:opaque_on_parent] == 1
# `scoped_here` forwards a parent property derived from the rebound `ctx`, so
# reading it makes the key per view, each with that view's own context.
@test [v.child(1).on_context(5) for v in views] == [((i, :scoped), 5) for i in 1:3]
@test RCS_CALLS[:opaque_on_context] == 3
end
