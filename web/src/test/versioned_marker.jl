# Regression: the `@versioned` marker (A2 of the file-backed feature).
#
# `@versioned name::T` tags a FIXED field as the cache VERSION dimension. DO
# excludes it from the object's identity hash and instead uses it to select a
# per-version path segment, so a versioned object caches under
# `base/<identity>/<version>/…`. This bakes the hand-rolled content_version
# pattern (see filebacked_content_version.jl) into a one-marker feature:
#   - all versions of one logical object share the identity dir;
#   - a fresh version cache-misses cleanly;
#   - "hold only the most recent" prunes stale sibling version dirs on write
#     (default-on for versioned types; opt out with __hold_recent_version__=false);
#   - non-versioned structs are byte-identical to before (fast path preserved).
# The probe (mtime / content-hash / git HEAD) stays consumer-computed and is
# passed in / `remake`d — no per-access I/O.
#
# Standalone: julia --project=<env-with-DO> test/versioned_marker.jl
# In-suite:   add `include("versioned_marker.jl")` to runtests.jl.
using Test, DynamicObjects
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

@testset "@versioned marker" begin
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

    @testset "@versioned on a computed property errors at expansion" begin
        err = try
            @eval @dynamicstruct struct BadVersioned
                x::Int
                @versioned bad() = 5
            end
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("@versioned", sprint(showerror, err))
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
