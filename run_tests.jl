#!/usr/bin/env julia
# run_tests.jl — run the DynamicObjects test suite from the command line.
#
# WHY THIS EXISTS (and not `Pkg.test`):
#   `Pkg.test()` is broken here on Julia 1.10 — its sandbox re-resolves the
#   test environment and dies with `can not merge projects` on DynamicObjects'
#   git-`[sources]` deps (TestModules, Treebars). Even when it resolves, it
#   tests the *GitHub* versions of those deps, not your LOCAL working copies.
#   This runner `develop`s the local sibling checkouts instead, so it tests
#   the code you are actually editing.
#
#   A bare `include("test/runtests.jl")` is ALSO wrong: the suite uses
#   `TestModules.@testset`, which DEFERS — it defines `test_*()` functions but
#   never runs them — so a plain include exits 0 having tested nothing (a
#   silent false-green). We `include` to DEFINE the testsets, then call
#   `runtests!` to actually RUN them.
#
# USAGE:  julia run_tests.jl          # from the repo root
# CI:     .github/workflows/test.yml runs exactly this.
#
# For fast, iterative test running, use the web app instead: it exposes the
# SAME testsets interactively at /tests (see web/src/DynamicObjectsWeb.jl,
# which mounts HTMXObjects' TestRoutes over this same runtests.jl).

import Pkg

const DO_ROOT = @__DIR__                    # this file lives at the repo root
const PARENT  = dirname(DO_ROOT)

# Locate a local checkout of one of DynamicObjects' git-`[sources]` deps: a
# SIBLING of this repo (local dev layout, ~/github/nsiccha/<name>) or a
# SUBDIRECTORY of it (the CI layout — cloned into the workspace, see
# .github/workflows/test.yml). Errors loudly if absent: the suite must run
# against local checkouts, and silently falling back to the GitHub versions is
# the `Pkg.test` behaviour this file exists to avoid.
function local_checkout(name)
    for cand in (joinpath(PARENT, name), joinpath(DO_ROOT, name))
        isdir(cand) && return cand
    end
    error("run_tests.jl: no local checkout of $name found — clone it as a " *
          "sibling of this repo (~/github/nsiccha/$name) or into this repo root.")
end

# A throwaway environment developed against the LOCAL checkouts. The develops
# are batched into a single call so resolution sees every local path at once —
# a split call re-resolves and trips on the unregistered git-`[sources]` deps.
Pkg.activate(mktempdir())
Pkg.develop(map(p -> Pkg.PackageSpec(path = p), [
    DO_ROOT,
    local_checkout("TestModules.jl"),
    local_checkout("Treebars.jl"),
]))
# The registered / stdlib packages the suite `using`s directly.
Pkg.add(["Arrow", "DataFrames", "Random", "Serialization", "Test"])

# Define the deferred testsets in a throwaway module, then run them for real.
# `runtests!` wraps everything in a top-level `@testset`, which THROWS a
# `TestSetException` if anything failed — so a red suite exits non-zero.
const SUITE = Module(:DynamicObjectsTests)
Base.include(SUITE, joinpath(DO_ROOT, "test", "runtests.jl"))

import TestModules
TestModules.runtests!(SUITE)
