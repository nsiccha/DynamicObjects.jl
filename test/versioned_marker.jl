# Regression: the `@versioned` marker (A2 of the file-backed feature).
#
# `@versioned x` tags `x` as the cache VERSION dimension. DO excludes it from the
# object's identity hash and instead uses it to select a per-version path segment,
# so a versioned object caches under `base/<identity>/<version>/…`. `x` may be a
# FIXED field (probe passed in / `remake`d) OR — since b2tsvz, Option B — a
# COMPUTED property DO derives itself (e.g. `file_version(path)`): additive to
# identity, guarded against cache-path cycles.
#
# Fixtures are defined inside the item so the whole `@versioned` contract (fixed
# + computed) lives in one selectable unit; the nested `@testset`s keep the
# original structure. Previously this file used `Test.@testset` and never ran in
# CI (it wasn't `include`d) — folding it into a `@testitem` closes that gap.

"""
Exercises the complete @versioned cache identity contract: fixed and computed
versions, remake invalidation, cycle rejection, pruning, and retention opt-out.
"""
@testitem "@versioned marker" tags=[:versioned] begin
    using DynamicObjects: remake, has_versioned_fields

    @dynamicstruct struct PlainNoVer
        a::Int
        b::Int
        s() = a + b
    end

    @dynamicstruct struct Versioned
        path::String
        @versioned content_version::String
        n() = length(path) + length(content_version)
    end

    @dynamicstruct struct VersionedDisk
        path::String
        @versioned content_version::String
        @cached payload() = string(path, ":", content_version)
    end

    # Computed @versioned (b2tsvz opt B): DO derives the version from the file's
    # content itself — identity stays the `path`, the version tracks the content hash.
    @dynamicstruct struct FileVersioned
        path::String
        @versioned content_ver = file_version(path; by = :hash)
    end

    @dynamicstruct struct FileVersionedDisk
        path::String
        @versioned content_ver = file_version(path; by = :hash)
        @cached payload() = string("v=", content_ver)
    end

    @testset "non-versioned struct is byte-identical" begin
        p = PlainNoVer(1, 2)
        @test !has_versioned_fields(PlainNoVer)
        @test p.__cache_path__ == joinpath(p.__cache_base__, p.__hash__)
        @test p.__identity_hash__ == p.__hash__
        @test p.__version_tag__ == ""
    end

    @testset "identity/version split" begin
        v1 = Versioned("/tmp/x", "v1")
        v2 = Versioned("/tmp/x", "v2")   # same identity (path), new version
        v3 = Versioned("/tmp/y", "v1")   # different identity, same version
        @test has_versioned_fields(Versioned)
        @test v1.__version_tag__ != ""
        @test v1.__version_tag__ != v2.__version_tag__          # version differs
        @test v1.__identity_hash__ == v2.__identity_hash__      # identity excludes version
        @test v1.__identity_hash__ != v3.__identity_hash__      # path differs → identity differs
        @test dirname(v1.__cache_path__) == dirname(v2.__cache_path__)  # share identity dir
        @test v1.__cache_path__ != v2.__cache_path__            # differ only in version segment
        @test basename(dirname(v1.__cache_path__)) == v1.__identity_hash__
        @test basename(v1.__cache_path__) == v1.__version_tag__
    end

    @testset "remake bumps the version → new path, same identity dir" begin
        v1 = Versioned("/tmp/x", "v1")
        v2 = remake(v1; content_version = "v9")
        @test v2.__identity_hash__ == v1.__identity_hash__
        @test v2.__cache_path__ != v1.__cache_path__
        @test dirname(v2.__cache_path__) == dirname(v1.__cache_path__)
    end

    @testset "computed @versioned: DO derives the version (b2tsvz opt B)" begin
        dir = mktempdir()
        f = joinpath(dir, "data.bin")
        write(f, "one")
        a = FileVersioned(f)
        @test has_versioned_fields(FileVersioned)
        @test a.content_ver == file_version(f; by = :hash)     # DO computes the probe itself
        id1, tag1 = a.__identity_hash__, a.__version_tag__
        @test tag1 != ""                                       # computed prop drives a real version
        @test basename(a.__cache_path__) == tag1
        @test basename(dirname(a.__cache_path__)) == id1

        write(f, "two")                                        # same path (identity), new content
        b = FileVersioned(f)
        @test b.__identity_hash__ == id1                       # identity EXCLUDES the computed version
        @test b.__version_tag__ != tag1                        # version tracks the derived content hash
        @test dirname(b.__cache_path__) == dirname(a.__cache_path__)  # share the identity dir
        @test b.__cache_path__ != a.__cache_path__             # differ only in the version segment
    end

    @testset "computed @versioned: a @cached payload auto-invalidates on file change" begin
        base = mktempdir()
        dir = mktempdir()
        f = joinpath(dir, "in.txt")
        write(f, "alpha")
        o1 = FileVersionedDisk(f; __cache_base__ = base)
        @test o1.payload() == "v=" * file_version(f; by = :hash)
        @test isfile(joinpath(o1.__cache_path__, "payload.sjl"))

        write(f, "beta")                                       # content changes under the same path
        o2 = FileVersionedDisk(f; __cache_base__ = base)
        @test o2.__identity_hash__ == o1.__identity_hash__     # same identity
        @test o2.__cache_path__ != o1.__cache_path__           # new version segment
        @test o2.payload() == "v=" * file_version(f; by = :hash)  # fresh, not the stale "alpha" value
    end

    @testset "computed @versioned rejects a cache-path cycle (acyclicity guard)" begin
        # (a) version derived from a @cached property → transitive cycle
        e1 = try
            @eval @dynamicstruct struct BadVerCachedDep
                x::Int
                @cached expensive() = x * 2
                @versioned v = expensive() + 1
            end
            nothing
        catch e; e end
        @test e1 !== nothing
        @test occursin("cycle", lowercase(sprint(showerror, e1)))

        # (b) the version property itself marked @cached → self-cycle
        e2 = try
            @eval @dynamicstruct struct BadVerSelfCache
                x::Int
                @versioned @cached v() = x
            end
            nothing
        catch e; e end
        @test e2 !== nothing
        @test occursin("@cached", sprint(showerror, e2))

        # (c) version reads the cache-path machinery directly
        e3 = try
            @eval @dynamicstruct struct BadVerCachePath
                x::Int
                @versioned v = length(__cache_path__)
            end
            nothing
        catch e; e end
        @test e3 !== nothing
        @test occursin("cycle", lowercase(sprint(showerror, e3)))
    end

    @testset "hold only the most recent — a new version prunes the old" begin
        base = mktempdir()
        d1 = VersionedDisk("/data/f", "v1"; __cache_base__ = base)
        @test d1.payload() == "/data/f:v1"                         # computes + writes disk
        @test isfile(joinpath(d1.__cache_path__, "payload.sjl"))
        @test readdir(dirname(d1.__cache_path__)) == [basename(d1.__cache_path__)]

        d2 = VersionedDisk("/data/f", "v2"; __cache_base__ = base) # same identity, new version
        @test d1.__identity_hash__ == d2.__identity_hash__
        @test d2.payload() == "/data/f:v2"                         # writes v2 + prunes v1
        @test readdir(dirname(d2.__cache_path__)) == [basename(d2.__cache_path__)]  # only v2
        @test !isdir(d1.__cache_path__)                            # v1's version dir pruned
    end

    @testset "opt out: __hold_recent_version__=false keeps every version" begin
        base = mktempdir()
        k1 = VersionedDisk("/data/g", "v1"; __cache_base__ = base, __hold_recent_version__ = false)
        k1.payload()
        k2 = VersionedDisk("/data/g", "v2"; __cache_base__ = base, __hold_recent_version__ = false)
        k2.payload()
        @test Set(readdir(dirname(k2.__cache_path__))) ==
              Set([basename(k1.__cache_path__), basename(k2.__cache_path__)])
        @test isdir(k1.__cache_path__)
    end

    @testset "file_version probe helper" begin
        dir = mktempdir()
        f = joinpath(dir, "a.txt")
        @test file_version(f) == ""                       # missing file → stable ""
        @test file_version(f; by = :hash) == ""
        write(f, "hello")
        @test file_version(f; by = :mtime) != ""
        h1 = file_version(f; by = :hash)
        @test h1 == file_version(f; by = :hash)           # stable for unchanged content
        write(f, "changed!!")
        @test file_version(f; by = :hash) != h1           # content change → version changes
        @test file_version(f; by = :git) != ""            # git blob id (or :hash fallback)
        @test_throws ErrorException file_version(f; by = :bogus)
    end
end

"""
A versioned type that declares `__hash_fields__` or `__hash__` keeps its
`@cached` entries under that identity, `base/<__hash__>/<version>/`, as every
type does, and the declaration may not read the version (snag
`cache-a-versione-5429048f`).
"""
@testitem "@versioned identity follows a declared __hash_fields__ or __hash__" tags=[:versioned] begin
    using DynamicObjects: canonical_hash

    const FIT_RUNS = Ref(0)

    # The reporter's shape: a computed version, and `__hash_fields__` leaving out
    # where the data lives, so a copy of the data at another path shares the fit.
    @dynamicstruct struct IdFieldsModel
        data_dir::String
        seed::Int
        revision::Int
        __hash_fields__ = (seed,)
        @versioned model_version = string("model-", revision)
        @cached fit() = (FIT_RUNS[] += 1; (seed, revision))
    end

    @dynamicstruct struct IdFieldsFixed
        path::String
        host::String
        @versioned content_version::String
        __hash_fields__ = (path,)
        @cached payload() = string(path, ":", content_version)
    end

    @dynamicstruct struct IdCustomHash
        path::String
        tag::Int
        __hash__ = canonical_hash((typeof(__self__), "format-1", tag))
        @versioned model_version = "model-1"
    end

    # The auto `__hash_fields__ = (__parent__, selection, K)` of an indexed inline
    # child is a declared override too, and reads no version.
    @dynamicstruct struct IdParent
        name::String
        version = "v1"
        @struct rows(selection; K::Int) = begin
            @versioned derived = __parent__.version
            __hold_recent_version__ = false
            @cached payload = (selection, K, name)
        end
    end

    @testset "__hash_fields__ names the identity directory" begin
        base = mktempdir()
        original = IdFieldsModel("/data/rain", 1, 1; __cache_base__ = base)
        elsewhere = IdFieldsModel("/copy/rain", 1, 1; __cache_base__ = base)
        @test original.__identity_hash__ == original.__hash__
        @test elsewhere.__identity_hash__ == original.__identity_hash__
        @test elsewhere.__cache_path__ == original.__cache_path__
        @test basename(dirname(original.__cache_path__)) == original.__hash__
        @test basename(original.__cache_path__) == original.__version_tag__

        @test original.fit() == (1, 1)
        @test elsewhere.fit() == (1, 1)
        @test FIT_RUNS[] == 1                 # the copy read the original's entry

        other_seed = IdFieldsModel("/data/rain", 2, 1; __cache_base__ = base)
        @test other_seed.__identity_hash__ != original.__identity_hash__

        # The version still selects the segment, and hold-most-recent still prunes.
        next = IdFieldsModel("/copy/rain", 1, 2; __cache_base__ = base)
        @test next.__identity_hash__ == original.__identity_hash__
        @test next.__version_tag__ != original.__version_tag__
        @test next.fit() == (1, 2)
        @test FIT_RUNS[] == 2
        @test readdir(dirname(next.__cache_path__)) == [basename(next.__cache_path__)]
    end

    @testset "a fixed @versioned field left out of __hash_fields__" begin
        base = mktempdir()
        v1 = IdFieldsFixed("/data/f", "alpha", "v1"; __cache_base__ = base)
        v2 = IdFieldsFixed("/data/f", "beta", "v2"; __cache_base__ = base)
        @test v1.__identity_hash__ == v1.__hash__ == v2.__identity_hash__
        @test v1.__version_tag__ != v2.__version_tag__
        @test v1.payload() == "/data/f:v1"
        @test v2.payload() == "/data/f:v2"
        @test readdir(dirname(v2.__cache_path__)) == [basename(v2.__cache_path__)]
    end

    @testset "a custom __hash__ names the identity directory" begin
        a = IdCustomHash("/x", 1)
        b = IdCustomHash("/y", 1)
        @test a.__identity_hash__ == a.__hash__ == canonical_hash((IdCustomHash, "format-1", 1))
        @test a.__cache_path__ == b.__cache_path__
        @test a.__cache_path__ == joinpath(a.__cache_base__, a.__hash__, a.__version_tag__)
        @test IdCustomHash("/x", 2).__identity_hash__ != a.__identity_hash__
    end

    @testset "indexed inline children keep their entries apart" begin
        base = mktempdir()
        parent = IdParent("p"; __cache_base__ = base)
        @test parent.rows(:north; K = 1).payload == (:north, 1, "p")
        @test parent.rows(:south; K = 2).payload == (:south, 2, "p")
        @test IdParent("q"; __cache_base__ = base).rows(:north; K = 1).payload == (:north, 1, "q")
    end

    # refused: `@versioned` makes the property the cache version, the directory
    # below identity; an identity override that reads it gives every version its
    # own identity directory, so hold-most-recent never prunes (snag
    # `cache-a-versione-5429048f`).
    refusal(ex) = try
        Core.eval(@__MODULE__, ex)
        nothing
    catch e
        sprint(showerror, e)
    end
    fixed_in_fields = refusal(:(@dynamicstruct struct IdBadFixed
        path::String
        @versioned content_version::String
        __hash_fields__ = (path, content_version)
    end))
    @test fixed_in_fields !== nothing
    @test occursin("`__hash_fields__` (transitively) reads `@versioned` property `content_version`", fixed_in_fields)

    computed_via_sibling = refusal(:(@dynamicstruct struct IdBadComputed
        seed::Int
        @versioned model_version = "model-1"
        label = string(seed, model_version)
        __hash_fields__ = (label,)
    end))
    @test computed_via_sibling !== nothing
    @test occursin("reads `@versioned` property `model_version`", computed_via_sibling)

    hash_over_default_fields = refusal(:(@dynamicstruct struct IdBadHash
        path::String
        @versioned content_version::String
        __hash__ = canonical_hash((typeof(__self__), "format-1", __hash_fields__))
    end))
    @test hash_over_default_fields !== nothing
    @test occursin("`__hash__` (transitively) reads `@versioned` property `content_version`", hash_over_default_fields)
end
