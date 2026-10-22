using TestItemRunner

# An object's default identity covers what it was constructed from: its fixed
# fields and the constructor keywords its properties read (snag
# `include-child-em-c6b53d27`, decision `0e4o8w2`). Before, only fixed fields
# counted. A struct mounted with `@include` that read everything from its
# parent had an empty identity, so the children of every parent shared one disk
# cache: Bruno's prior, PK-only and joint fits were all served the prior's
# entry. Two objects differing only in an override, and plain inline children
# used as cache-key arguments, collided the same way.

@testmodule ConstructionIdentityFixtures begin
using DynamicObjects
export CI_BASE, CIChild, CIBareChild, CIDeclaredChild, CIShared, CIOwner,
    CIProbe, CIUnread, CIState, CIVersioned, CIVersionedChild, CIOpaque,
    CIPlainHolder, CIConsumer, CIContext, ci_peek

const CI_BASE = mktempdir()

# Bruno's `QTJointPKData` shape: no fixed fields, every input from the parent.
@dynamicstruct struct CIChild
    (; regime) = __self__.__parent__
    __cache_base__ = CI_BASE
    @cached fit(; seed = 1) = "fit[$regime, seed=$seed]"
end

# The same, with the parent read bare and never declared.
@dynamicstruct struct CIBareChild
    (; regime) = __parent__
    __cache_base__ = CI_BASE
    @cached fit(; seed = 1) = "fit[$regime, seed=$seed]"
end

# A declared `__hash_fields__` that names the parent bare, without declaring it.
@dynamicstruct struct CIDeclaredChild
    (; regime) = __self__.__parent__
    __hash_fields__ = (__parent__,)
    __cache_base__ = CI_BASE
    @cached fit(; seed = 1) = "fit[$regime, seed=$seed]"
end

# Deliberately shared across parents: the override is the identity.
@dynamicstruct struct CIShared
    (; regime) = __self__.__parent__
    __hash_fields__ = ()
    __cache_base__ = CI_BASE
    @cached fit(; seed = 1) = "fit[$regime, seed=$seed]"
end

@dynamicstruct struct CIOwner
    regime::Symbol
    __cache_base__ = CI_BASE
    @include child = CIChild()
    @include bare = CIBareChild()
    @include declared = CIDeclaredChild()
    @include shared = CIShared()
    # The reported nesting: an `@include` inside an indexed inline child.
    @struct run(dataset) = begin
        tag = string(regime, ":", dataset)
        @include nested = CIChild()
    end
end

@dynamicstruct struct CIProbe
    dir::String
    label = "default"
    unused = "nobody reads this"
    __cache_base__ = CI_BASE
    @cached shout() = uppercase(label)
    location = __cache_path__
end

# Nothing reads `label`, so no override of it is an identity input.
@dynamicstruct struct CIUnread
    dir::String
    label = "default"
end

@dynamicstruct struct CIState
    dir::String
    @state limiter = Ref(0)
    count = limiter[] + 1
end

@dynamicstruct struct CIVersioned
    path::String
    @versioned content_version = "v1"
    __cache_base__ = CI_BASE
    @cached rendered() = uppercase(path)
end

@dynamicstruct struct CIVersionedChild
    (; regime) = __self__.__parent__
    @versioned content_version = "v1"
    __cache_base__ = CI_BASE
    @cached fit() = "fit[$regime]"
end

ci_peek(o) = o.label
# A body that hands `__self__` to other code may read any input.
@dynamicstruct struct CIOpaque
    dir::String
    label = "default"
    seen = ci_peek(__self__)
end

@dynamicstruct struct CIPlainHolder
    regime::Symbol
    @struct plain = begin
        value = string(regime)
    end
end

@dynamicstruct struct CIConsumer
    __cache_base__ = CI_BASE
    @cached summarize(child) = child.value
end

@dynamicstruct struct CIContext
    dir::String
    label = "default"
    __prefix__ = ""
    __cache_base__ = CI_BASE
    @cached shout() = uppercase(label)
    url = __prefix__ * "/" * label
end
end

@testitem "an @include'd child that reads its parent caches under that parent" tags=[:core] setup=[ConstructionIdentityFixtures] begin
using DynamicObjects
const DO = DynamicObjects

prior, joint = CIOwner(:prior), CIOwner(:joint)
@test prior.__hash__ != joint.__hash__
for child in (:child, :bare, :declared)
    a, b = getproperty(prior, child), getproperty(joint, child)
    @test a.__hash__ != b.__hash__
    @test a.__cache_path__ != b.__cache_path__
    @test a.fit() == "fit[prior, seed=1]"
    # The sensitivity control: same type, same call kwargs, a different parent.
    @test b.fit() == "fit[joint, seed=1]"
    # A fresh owner reads the joint entry back from disk, not the prior one.
    @test getproperty(CIOwner(:joint), child).fit() == "fit[joint, seed=1]"
end
# The parent enters identity through its own `__hash__`.
@test prior.child.__hash_fields__ == ((; __parent__ = prior),)
@test prior.child.__hash__ == DO.canonical_hash((CIChild, ((; __parent__ = prior),)))
@test prior.child.__hash__ == CIOwner(:prior).child.__hash__
# A bare `__parent__` resolves in a struct that never declares it.
@test DO._identity_input_names(CIBareChild) == (:__parent__, :regime)
@test prior.declared.__hash__ == DO.canonical_hash((CIDeclaredChild, prior.declared.__hash_fields__))

# The reported nesting: an `@include` inside an indexed inline child.
@test prior.run(:a).nested.fit() == "fit[prior, seed=1]"
@test joint.run(:a).nested.fit() == "fit[joint, seed=1]"
@test prior.run(:a).nested.__hash__ != prior.run(:b).nested.__hash__

# A declared identity still wins: this child shares across parents by design.
@test DO._identity_input_names(CIShared) == ()
@test prior.shared.__hash__ == joint.shared.__hash__
end

@testitem "construction overrides that a body reads are identity inputs" tags=[:core] setup=[ConstructionIdentityFixtures] begin
using DynamicObjects
const DO = DynamicObjects

# Only names a body reads, never fixed fields, `@state`, `@versioned` or DO's
# own dunders; `__parent__` when read.
@test DO._identity_input_names(CIProbe) == (:label,)
@test DO._identity_input_names(CIChild) == (:__parent__, :_tuple_regime, :regime)
@test DO._identity_input_names(CIUnread) == ()
@test DO._identity_input_names(CIState) == ()
@test DO._identity_input_names(CIVersioned) == ()
@test DO._identity_input_names(CIOpaque) == (:__parent__, :label, :seen)

x, y = CIProbe("d"; label = "x"), CIProbe("d"; label = "y")
@test x.__hash__ != y.__hash__
@test x.shout() == "X"
@test y.shout() == "Y"
@test CIProbe("d"; label = "y").shout() == "Y"            # from disk
@test x.__hash_fields__ == ("d", (; label = "x"))
# `remake` keeps the override as an input, so identity follows it, and a
# property reading the cache path is recomputed rather than carried.
x.location
z = remake(x; label = "z")
@test z.shout() == "Z"
@test z.location == z.__cache_path__ != x.__cache_path__
@test remake(z; dir = "e").__hash_fields__ == ("e", (; label = "z"))
# A whole-object clear restores the inputs, so identity does not move.
before = x.__hash__
clear_mem_caches!(x)
@test x.__hash__ == before
# An opaque body may read anything: its overrides count without a visible read.
@test CIOpaque("d"; label = "x").__hash__ != CIOpaque("d"; label = "y").__hash__
end

@testitem "objects built without read inputs keep their exact identity" tags=[:core] setup=[ConstructionIdentityFixtures] begin
using DynamicObjects
const DO = DynamicObjects

plain_fields(o) = ntuple(i -> getfield(o, i), fieldcount(typeof(o)) - 1)
legacy_hash(o) = DO.persistent_hash((typeof(o), DO._hash_replace(plain_fields(o))))
for o in (
        CIProbe("d"),                                   # no keywords at all
        CIProbe("d"; unused = "other"),                 # an unread override
        CIProbe("d"; __status__ = nothing),             # DO's own keywords
        CIUnread("d"; label = "x"),                     # nothing reads `label`
        CIState("d"; limiter = Ref(5)),                 # `@state`
    )
    @test o.__hash_fields__ === plain_fields(o)
    @test o.__hash__ == legacy_hash(o)
end
@test CIProbe("d").__hash__ == CIProbe("d"; unused = "other").__hash__
# A `nothing` parent is no parent.
@test CIChild(; __parent__ = nothing).__hash_fields__ === ()
end

@testitem "versioned identity takes the inputs, the version stays a segment" tags=[:core] setup=[ConstructionIdentityFixtures] begin
using DynamicObjects
const DO = DynamicObjects

# A `@versioned` override moves the version, never the identity directory.
a, b = CIVersioned("p"), CIVersioned("p"; content_version = "v2")
@test a.__identity_hash__ == b.__identity_hash__
@test a.__version_tag__ != b.__version_tag__
@test a.__identity_hash__ == DO.canonical_hash((CIVersioned, ("p",)))
# A versioned child mounted under a parent keys its identity by that parent.
c1 = CIVersionedChild(; __parent__ = (; regime = :prior))
c2 = CIVersionedChild(; __parent__ = (; regime = :joint))
@test c1.__identity_hash__ != c2.__identity_hash__
@test c1.fit() == "fit[prior]"
@test c2.fit() == "fit[joint]"
end

@testitem "a plain inline child is identified by its parent" tags=[:core] setup=[ConstructionIdentityFixtures] begin
using DynamicObjects

prior, joint = CIPlainHolder(:prior), CIPlainHolder(:joint)
@test prior.plain.__hash__ != joint.plain.__hash__
consumer = CIConsumer()
@test consumer.summarize(prior.plain) == "prior"
@test consumer.summarize(joint.plain) == "joint"
@test CIConsumer().summarize(CIPlainHolder(:joint).plain) == "joint"   # from disk
end

@testitem "a remount view shares its retained object's identity" tags=[:core] setup=[ConstructionIdentityFixtures] begin
using DynamicObjects

root = CIContext("d"; label = "x")
view = DynamicObjects.remount(root; __prefix__ = "/p")
# The view computes identity first; it is the retained object's.
@test view.__hash__ == root.__hash__
@test view.__hash__ == CIContext("d"; label = "x").__hash__
@test view.__hash__ != CIContext("d"; label = "y").__hash__
@test view.url == "/p/x"
@test view.shout() == root.shout() == "X"
end
