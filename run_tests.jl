#!/usr/bin/env julia
# run_tests.jl — run the DynamicObjects test suite from the command line.
#
# WHY THIS EXISTS (and not `Pkg.test`):
#   `Pkg.test()` is broken here on Julia 1.10 — its sandbox re-resolves the
#   test environment and dies with `can not merge projects` on DynamicObjects'
#   git-`[sources]` deps (TestModules, Treebars). Even when it resolves, it
#   tests the *GitHub* versions of those deps, not your LOCAL working copies.
#   This runner `develop`s the local checkouts instead, so it tests the code
#   you are actually editing.
#
#   A bare `include("runtests.jl")` is ALSO wrong: the suite uses
#   `TestModules.@testset`, which DEFERS — it defines `test_*()` functions but
#   never runs them — so a plain include exits 0 having tested nothing (a
#   silent false-green). We `include` to DEFINE the testsets, then call
#   `runtests!` to actually RUN them. The same trap bites when the include
#   defines *no* testsets at all, so we refuse to run an empty suite (below).
#
# USAGE:  julia run_tests.jl          # from the repo root, a sibling
#                                     # worktree, or a git worktree
# CI:     .github/workflows/test.yml runs exactly this.
#
# For fast, iterative test running, use the web app instead: it exposes the
# SAME testsets interactively at /tests (see web/src/DynamicObjectsWeb.jl,
# which mounts HTMXObjects' TestRoutes over this same runtests.jl).

import Pkg

const DO_ROOT = @__DIR__                    # this file lives at the repo root
const PARENT  = dirname(DO_ROOT)

# The main worktree of this repo, or `nothing`. A `git worktree` (both the
# sibling checkouts used for feature work and the KB agents' worktrees under
# ~/.local/state/kb-agents-worktrees) lives far away from the local clones, so
# the deps must be resolved relative to the MAIN checkout, not to us.
function main_worktree()
    try
        out = readchomp(Cmd(`git rev-parse --git-common-dir`; dir = DO_ROOT))
        common = rstrip(isabspath(out) ? out : abspath(joinpath(DO_ROOT, out)), '/')
        basename(common) == ".git" ? dirname(common) : nothing
    catch
        nothing            # not a git checkout, or no git on PATH
    end
end

# Directories that may hold a local checkout of a git-`[sources]` dep, in
# precedence order: an explicit override, a sibling of this repo (local dev
# layout), a subdirectory (the CI layout — cloned into the workspace, see
# .github/workflows/test.yml), then a sibling of the main checkout (we are a
# git worktree).
function candidate_dirs()
    dirs = String[]
    override = get(ENV, "DO_TEST_DEPS", "")
    isempty(override) || push!(dirs, override)
    push!(dirs, PARENT, DO_ROOT)
    mw = main_worktree()
    isnothing(mw) || mw == DO_ROOT || push!(dirs, dirname(mw))
    unique(dirs)
end

# Errors loudly if absent: the suite must run against local checkouts, and
# silently falling back to the GitHub versions is the `Pkg.test` behaviour this
# file exists to avoid.
function local_checkout(name)
    searched = String[]
    for dir in candidate_dirs()
        cand = joinpath(dir, name)
        push!(searched, cand)
        isdir(cand) && return cand
    end
    error("run_tests.jl: no local checkout of $name found. Searched:\n" *
          join(("  " * s for s in searched), "\n") *
          "\nClone it beside this repo, or set DO_TEST_DEPS=<dir containing $name>.")
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
# Include the REAL path rather than the `test/` symlink that points at it: git
# on Windows checks symlinks out as plain text files unless core.symlinks is
# on, and the CI matrix covers windows-latest.
const SUITE = Module(:DynamicObjectsTests)
Base.include(SUITE, joinpath(DO_ROOT, "web", "src", "test", "runtests.jl"))

import TestModules

# Guard the false-green: `runtests!` wraps `run_all!` in a top-level `@testset`,
# which only throws when a test FAILED. A suite that defined no testsets runs
# nothing, fails nothing, and exits 0 — reporting success having tested nothing.
const DISCOVERED = TestModules.test_names(SUITE)
isempty(DISCOVERED) && error(
    "run_tests.jl: runtests.jl defined ZERO testsets — refusing to report success. " *
    "Either the include failed to define any `TestModules.@testset`, or they were " *
    "shadowed by `Test.@testset` (which runs at include time instead of deferring).")
@info "run_tests.jl: running $(length(DISCOVERED)) testsets"

# Throws a `TestSetException` if anything failed — so a red suite exits non-zero.
TestModules.runtests!(SUITE)
