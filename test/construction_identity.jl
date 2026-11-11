using TestItemRunner

# An object's default identity covers what it was constructed from: its fixed
# fields and the constructor keywords its properties read (snag
# `include-child-em-c6b53d27`, decision `0e4o8w2`). Before, only fixed fields
# counted. A struct mounted with `@include` that read everything from its
# parent had an empty identity, so the children of every parent shared one disk
# cache. Two objects differing only in an override, and plain inline children
# used as cache-key arguments, collided the same way.

@testmodule ConstructionIdentityFixtures begin
using DynamicObjects
export CI_BASE, CIChild, CIBareChild, CIDeclaredChild, CIShared, CIOwner,
    CIProbe, CIUnread, CIState, CIVersioned, CIVersionedChild, CIOpaque,
    CIPlainHolder, CIConsumer, CIContext, ci_peek

const CI_BASE = mktempdir()

# No fixed fields: every input comes from the parent.
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

# A constructor `__hash__` names the object's cache directory on every shape of type:
# that is how a consumer reads an entry stored under an earlier identity, without knowing
# DO's file layout (snag `constructor-hash-d738b3b5`). Each shape below declares its
# identity differently, and `EarlierPlain` / `EarlierVersioned` write the entries
# independently, as an earlier release of the type did.
@testmodule EarlierIdentityFixtures begin
using DynamicObjects
export RUNS, EarlierPlain, EarlierVersioned, SHAPES, earlier_writer, with_override

const RUNS = Ref(0)
counted(value) = (RUNS[] += 1; value)

@dynamicstruct struct EarlierPlain
    key::String
    answer::String
    __hash__ = key
    @cached val = answer
    @cached idx(k) = string(answer, ":", k)
end
@dynamicstruct struct EarlierVersioned
    key::String
    answer::String
    @versioned version::String
    __hash__ = key
    @cached val = answer
    @cached idx(k) = string(answer, ":", k)
end

@dynamicstruct struct PlainDefault
    tag::String
    context = "default"
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end
@dynamicstruct struct PlainFields
    tag::String
    placement::String
    context = "default"
    __hash_fields__ = (tag,)
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end
@dynamicstruct struct PlainHash
    tag::String
    context = "default"
    __hash__ = DynamicObjects.canonical_hash((typeof(__self__), "format-1", tag))
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end
@dynamicstruct struct VersionedDefault
    tag::String
    @versioned version::String
    context = "default"
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end
@dynamicstruct struct VersionedComputed
    tag::String
    context = "default"
    @versioned version = "v1"
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end
# A versioned value whose identity includes placement and a tag.
@dynamicstruct struct VersionedFields
    placement::String
    tag::String
    @versioned version::String
    context = "default"
    __hash_fields__ = (tag,)
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end
@dynamicstruct struct VersionedHash
    tag::String
    @versioned version::String
    context = "default"
    __hash__ = DynamicObjects.canonical_hash((typeof(__self__), "format-1", tag))
    @cached val = counted(string("computed:", tag))
    @cached idx(k) = counted(string("computed:", tag, ":", k))
end

# Each shape, how to build it, and whether it is `@versioned`.
const SHAPES = (
    (PlainDefault, (; kw...) -> PlainDefault("t"; kw...), false),
    (PlainFields, (; kw...) -> PlainFields("t", "here"; kw...), false),
    (PlainHash, (; kw...) -> PlainHash("t"; kw...), false),
    (VersionedDefault, (; kw...) -> VersionedDefault("t", "v1"; kw...), true),
    (VersionedComputed, (; kw...) -> VersionedComputed("t"; kw...), true),
    (VersionedFields, (; kw...) -> VersionedFields("here", "t", "v1"; kw...), true),
    (VersionedHash, (; kw...) -> VersionedHash("t", "v1"; kw...), true),
)

"Stores `answer` under `key` from a type that shares nothing with the shape reading it."
function earlier_writer(versioned, key, answer, base)
    writer = versioned ?
        EarlierVersioned(key, answer, "v1"; __cache_base__ = base, __hold_recent_version__ = false) :
        EarlierPlain(key, answer; __cache_base__ = base)
    writer.val
    writer.idx(1)
    writer
end
end

@testitem "a constructor __hash__ names the cache directory on every identity shape" tags=[:core] setup=[EarlierIdentityFixtures] begin
using DynamicObjects
const DO = DynamicObjects
key = "earlier-identity"

@testset "$T" for (T, make, versioned) in SHAPES
    base = mktempdir()
    current = make(; __cache_base__ = base)
    earlier = make(; __cache_base__ = base, __hash__ = key)
    # The sensitivity control: without the keyword the object lives elsewhere.
    @test current.__cache_path__ != earlier.__cache_path__
    @test earlier.__hash__ == earlier.__identity_hash__ == key
    @test earlier.__cache_path__ == (versioned ?
        joinpath(base, key, earlier.__version_tag__) : joinpath(base, key))
    # A version still selects the segment below the moved directory.
    versioned && @test earlier.__version_tag__ == current.__version_tag__

    # Nothing stored there yet, whatever the current identity holds.
    current.val
    @test !@is_cached(earlier.val)
    @test !@is_cached(earlier.idx(1))

    writer = earlier_writer(versioned, key, "stored", base)
    @test writer.__cache_path__ == earlier.__cache_path__
    RUNS[] = 0
    @test @is_cached(earlier.val)
    @test @is_cached(earlier.idx(1))
    @test earlier.val == "stored"
    @test earlier.idx(1) == "stored:1"
    @test DO.materialization_observation(earlier, :val).disk_state == :ready
    @test startswith((@cache_path earlier.val), earlier.__cache_path__)
    @test RUNS[] == 0                        # read from disk, no body ran

    # The current identity keeps its own entry.
    @test current.val == "computed:t"

    # A clear keeps the keyword: the object stays where it was, and reloads.
    DO.clear_mem_caches!(earlier)
    @test earlier.__hash__ == key
    @test earlier.__cache_path__ == writer.__cache_path__
    @test earlier.val == "stored"
    @test RUNS[] == 0

    # A remount view has the object's identity, and `remake` carries the keyword.
    @test DO.remount(earlier; context = "view").__cache_path__ == earlier.__cache_path__
    remade = remake(earlier; tag = "another")
    @test remade.__hash__ == key
    @test remade.__cache_path__ == earlier.__cache_path__
    @test remade.val == "stored"
    @test RUNS[] == 0

    # `remake` naming the keyword moves a settled object, and serves nothing it held.
    moved = remake(current; __hash__ = "another-identity")
    @test moved.__hash__ == "another-identity"
    @test occursin("another-identity", moved.__cache_path__)
    @test !@is_cached(moved.val)

    # The clears act on that directory, and leave the current identity alone.
    invalidate!(earlier.idx, 1)
    @test !@is_cached(earlier.idx(1))
    @test @is_cached(earlier.val)
    @test !isempty(DO.clear_cache!(earlier, :val))
    @test !@is_cached(earlier.val)
    @test !isfile(joinpath(earlier.__cache_path__, "val.sjl"))
    @test @is_cached(make(; __cache_base__ = base).val)
    earlier_writer(versioned, key, "again", base)
    @test @is_cached(make(; __cache_base__ = base, __hash__ = key).val)
    DO.clear_disk_caches!(make(; __cache_base__ = base, __hash__ = key))
    @test !isfile(joinpath(writer.__cache_path__, "val.sjl"))
    @test @is_cached(make(; __cache_base__ = base).val)

    # Without an entry, a read runs the body and stores under that identity, so guard
    # a read that must not choose anew with `@is_cached`.
    miss = make(; __cache_base__ = base, __hash__ = "no-entry-here")
    @test !@is_cached(miss.val)
    @test miss.val == "computed:t"
    @test isfile(joinpath(miss.__cache_path__, "val.sjl"))
end
end

@testitem "a constructor __hash_fields__ moves the directory unless __hash__ is declared" tags=[:core] setup=[EarlierIdentityFixtures] begin
using DynamicObjects
const DO = DynamicObjects

@testset "$T" for (T, make, versioned) in SHAPES
    base = mktempdir()
    earlier = make(; __cache_base__ = base, __hash_fields__ = ("earlier", "fields"))
    current = make(; __cache_base__ = base)
    if any(p -> first(p) === :__hash__, DO.meta(T))
        # A declared `__hash__` reads what it reads, and these do not read `__hash_fields__`.
        @test earlier.__hash__ == current.__hash__
        @test earlier.__cache_path__ == current.__cache_path__
    else
        key = DO.canonical_hash((T, ("earlier", "fields")))
        @test earlier.__hash__ == earlier.__identity_hash__ == key
        @test earlier.__cache_path__ == (versioned ?
            joinpath(base, key, earlier.__version_tag__) : joinpath(base, key))
        earlier_writer(versioned, key, "stored", base)
        @test @is_cached(earlier.val)
        @test earlier.val == "stored"
    end
end
end

@testitem "the earlier key of a type whose identity moved is canonical_hash of what it hashed" tags=[:core] setup=[EarlierIdentityFixtures] begin
using DynamicObjects
using DynamicObjects: canonical_hash
base = mktempdir()

# The reported move: every fixed field but the version, to a declared `__hash_fields__`.
@dynamicstruct struct WhenDefault
    placement::String
    tag::String
    @versioned version::String
    @cached val = "from the default identity"
end
stored = WhenDefault("here", "t", "v1"; __cache_base__ = base)
stored.val
key = canonical_hash((WhenDefault, ("here", "t")))
@test stored.__identity_hash__ == key
reader = EarlierIdentityFixtures.VersionedFields("elsewhere", "t", "v1"; __cache_base__ = base, __hash__ = key)
@test reader.__cache_path__ == stored.__cache_path__
@test @is_cached(reader.val)
@test reader.val == "from the default identity"

# The move back: a default-identity versioned type reading a declared identity's entry.
declared = EarlierIdentityFixtures.VersionedFields("here", "t", "v1"; __cache_base__ = base, __hold_recent_version__ = false)
RUNS[] = 0
@test declared.val == "computed:t"
back = WhenDefault("here", "t", "v1"; __cache_base__ = base, __hash__ = declared.__hash__)
@test back.__cache_path__ == declared.__cache_path__
@test @is_cached(back.val)
@test back.val == "computed:t"
@test RUNS[] == 1
end

@testitem "reading under a moved identity prunes its other versions unless told not to" tags=[:core] setup=[EarlierIdentityFixtures] begin
using DynamicObjects
key = "earlier-identity"
pin(version, base; kw...) = EarlierIdentityFixtures.VersionedFields("here", "t", version; __cache_base__ = base, __hash__ = key, kw...)

function two_versions()
    base = mktempdir()
    for version in ("v1", "v2")
        EarlierVersioned(key, "stored-$version", version; __cache_base__ = base, __hold_recent_version__ = false).val
    end
    @test length(readdir(joinpath(base, key))) == 2
    base
end

# `@is_cached` only looks; loading the entry holds the most recent, as computing does.
base = two_versions()
reader = pin("v1", base)
@test @is_cached(reader.val)
@test length(readdir(joinpath(base, key))) == 2
@test reader.val == "stored-v1"
@test length(readdir(joinpath(base, key))) == 1

# So an entry an older release still reads takes `__hold_recent_version__ = false`.
base = two_versions()
reader = pin("v1", base; __hold_recent_version__ = false)
@test reader.val == "stored-v1"
@test length(readdir(joinpath(base, key))) == 2
end
