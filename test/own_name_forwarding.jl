using TestItemRunner

@testmodule OwnNameForwardingFixtures begin
using DynamicObjects
export OwnNameParent, OwnNameJoint, OwnNamePlainJoint, OwnNameSelfIndexed

# snag inline-struct-ow-3f55b471: an inline child forwarded every parent
# property except its own name, so `fit` was undefined inside `@struct fit(…)`.
# A bare `fit(:other)` in the child body died with `UndefVarError`, and a struct
# `@include`d into the child that destructured `(; fit) = __self__.__parent__`
# died with `no method matching compute_property(::…_fit_inline, ::Val{:fit})`.
@dynamicstruct struct OwnNameJoint
    sibling_label = begin
        (; fit) = __self__.__parent__
        fit(:other).label
    end
end

@dynamicstruct struct OwnNamePlainJoint
    up = begin
        (; single) = __self__.__parent__
        single.x
    end
end

@dynamicstruct struct OwnNameParent
    base::Int
    @struct fit(dataset) = begin
        label = string(dataset, "-", base)
        sibling = fit(:other).label
        @progress threaded = fit(:threaded).label
        @include joint = OwnNameJoint()
    end
    @struct single = begin
        x = base + 1
        via_own_name = single.x
        @include joint = OwnNamePlainJoint()
    end
    @fresh @struct scratch(k::Int) = begin
        next_k = scratch(k + 1).k
    end
end

# An index argument named like its inline child shadows the forwarded name.
@dynamicstruct struct OwnNameSelfIndexed
    @struct dataset(dataset::String) = begin
        upper = uppercase(dataset)
    end
end
end # @testmodule OwnNameForwardingFixtures

@testitem "an indexed inline child reaches its own name" tags=[:core] setup=[OwnNameForwardingFixtures] begin
parent = OwnNameParent(10)
child = parent.fit(:a)
@test child.label == "a-10"
@test child.fit === parent.fit
@test child.sibling == "other-10"
@test child.threaded == "threaded-10"
@test child.joint.sibling_label == "other-10"
@test parent.fit(:other) === child.fit(:other)
end

@testitem "a plain inline child's own name is the child itself" tags=[:core] setup=[OwnNameForwardingFixtures] begin
parent = OwnNameParent(10)
child = parent.single
@test child.single === child
@test child.via_own_name == 11
@test child.joint.up == 11
end

@testitem "a fresh indexed inline child reaches its own name" tags=[:core] setup=[OwnNameForwardingFixtures] begin
parent = OwnNameParent(10)
@test parent.scratch(1).next_k == 2
end

@testitem "index arguments and child declarations shadow the own name" tags=[:core] setup=[OwnNameForwardingFixtures] begin
@test OwnNameSelfIndexed().dataset("abc").upper == "ABC"
@test OwnNameSelfIndexed().dataset("abc").dataset == "abc"
end

@testitem "own-name forwarding leaves structure walks finite" tags=[:core] setup=[OwnNameForwardingFixtures] begin
using DynamicObjects
parent = OwnNameParent(10)
parent.single.via_own_name
parent.fit(:a).sibling
@test sync!(parent) == Symbol[]
entries = collect(mem_cache_entries(parent))
@test count(e -> e.object === parent.single && e.property === :single, entries) == 1
@test prune_mem_caches!(Returns(true), parent).evicted == 0
@test DynamicObjects.clear_cache!(parent, :single) == [:single]
@test parent.single.single === parent.single
end
