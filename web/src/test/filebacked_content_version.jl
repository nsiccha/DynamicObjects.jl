# Regression: the file-backed / externally-backed DO pattern.
#
# A DO whose semantic identity is the *contents* of files it reads (Invoices'
# `AppData`: invoice YAML, off_days.yml, disabled_holidays.yml) must cache while
# the files are unchanged and invalidate exactly when they change. DO keys
# identity on the declared fixed fields, not on file bytes, so a plain memoized
# loader goes stale on edit (and `__hash__` — the disk-cache key — is blind to
# content). The supported answer is NOT viral `@fresh` (never-cache): model the
# file state as a `content_version` fixed field set from an external probe
# (mtime / content-hash / git-HEAD) and `remake(obj; content_version=new)` at the
# mutation boundary. This works on the CURRENT `remake` (fresh object, empty
# cache) — no carry-over required — and pins that contract.
#
# Standalone: julia --project=<env-with-DO> test/filebacked_content_version.jl
# In-suite:   add `include("filebacked_content_version.jl")` to runtests.jl.
using Test, DynamicObjects
using DynamicObjects: remake

@dynamicstruct struct FileBackedCV
    path::String
    content_version::String        # external probe: mtime / blob-hash / git HEAD
    load_lines() = begin
        _pin = content_version     # honest dependency: output is a function of the
                                   # committed state; also the edge a future
                                   # remake-carryover DAG would key on.
        isfile(path) ? readlines(path) : String[]
    end
    line_count() = length(load_lines())
    # Inline child exactly like Invoices' `period`: reads the parent's file-backed
    # loader via __parent__. Plain @struct (NOT @fresh) → caches, rebuilt by remake.
    @struct tagged(tag::String) = begin
        n = __parent__.line_count()
        label = string(tag, ":", n)
    end
end

@testset "file-backed content-version identity" begin
    tmp = tempname()
    write(tmp, "a\nb\n")
    fb1 = FileBackedCV(tmp, "v1")

    # caches within a version (memoized; no per-access re-read) — no @fresh needed
    @test fb1.line_count() == 2
    @test fb1.line_count() == 2
    @test fb1.tagged("m").label == "m:2"     # inline child cached
    @test fb1.tagged("m").label == "m:2"

    # THE SNAG: editing the file without a remake serves the stale cached value
    write(tmp, "a\nb\nc\nd\n")
    @test fb1.line_count() == 2              # stale — identity unchanged

    # THE FIX: remake with the new probe invalidates the file-derived subtree
    fb2 = remake(fb1; content_version="v2")
    @test fb2.line_count() == 4              # fresh
    @test fb2.tagged("m").label == "m:4"     # inline child rebuilt (no @fresh)
    @test fb1.line_count() == 2              # old object keeps its identity

    # disk-cache key is content-sensitive: content_version flows into __hash__
    @test fb1.__hash__ != fb2.__hash__
end
