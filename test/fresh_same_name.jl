using TestItemRunner

@testmodule FreshSameNameFixtures begin
using DynamicObjects
export count_marker_defs

# Count method definitions of `marker` (e.g. `:_never_cache`) in a
# macroexpansion: `f(...) = ...` defs whose call head names the marker.
# Call SITES are bare `:call`s, never under `:(=)`, so only definitions
# match.
function count_marker_defs(ex, marker::Symbol)
    n = Ref(0)
    function walk(x)
        if Meta.isexpr(x, :(=)) && length(x.args) >= 1
            lhs = x.args[1]
            if Meta.isexpr(lhs, :call) && !isempty(lhs.args)
                f = lhs.args[1]
                fname = f isa Expr && f.head === :. ? f.args[2].value :
                    f isa GlobalRef ? f.name : f
                fname === marker && (n[] += 1)
            end
        end
        x isa Expr && foreach(walk, x.args)
    end
    walk(ex)
    return n[]
end
end

@testitem "same-name @fresh declarations emit one _never_cache method" setup=[FreshSameNameFixtures] begin
using DynamicObjects

# Multi-verb same-name properties (e.g. `@get x` + `@post x` lowered by
# HTMXObjects) share one name-keyed `_never_cache` method: a second
# identical definition is a method overwrite, which Julia rejects during
# precompilation ("Method overwriting is not permitted during Module
# precompilation").
ex = macroexpand(@__MODULE__, :(@dynamicstruct struct FreshSameNameA
    @fresh x(a) = 1
    @fresh x(a, b) = 2
end))
@test count_marker_defs(ex, :_never_cache) == 1

# Controls: the single-declaration shape still emits exactly one, and a
# mixed fresh/plain pair keeps the one from its @fresh declaration.
ex_single = macroexpand(@__MODULE__, :(@dynamicstruct struct FreshSameNameB
    @fresh x(a) = 1
end))
@test count_marker_defs(ex_single, :_never_cache) == 1

ex_mixed = macroexpand(@__MODULE__, :(@dynamicstruct struct FreshSameNameC
    @fresh x(a) = 1
    x(a, b) = 2
end))
@test count_marker_defs(ex_mixed, :_never_cache) == 1
end

@testitem "same-name self-named indices emit one _self_named_index method" setup=[FreshSameNameFixtures] begin
using DynamicObjects

# The same per-name shape as `_never_cache`: `_self_named_index` is keyed
# by (type, name) only, so same-name declarations must share one
# definition rather than emitting an identical overwrite.
ex = macroexpand(@__MODULE__, :(@dynamicstruct struct FreshSameNameD
    y(y, a) = 1
    y(y, a, b) = 2
end))
@test count_marker_defs(ex, :_self_named_index) == 1
end

@testitem "one marker per name even when split across declarations" setup=[FreshSameNameFixtures] begin
using DynamicObjects

# `@fresh` on one declaration and a self-named index on another of the same
# name: each marker is still emitted (once) — the dedup is per marker, not
# per name.
ex = macroexpand(@__MODULE__, :(@dynamicstruct struct FreshSameNameE
    @fresh z(a) = 1
    z(z, a, b) = 2
end))
@test count_marker_defs(ex, :_never_cache) == 1
@test count_marker_defs(ex, :_self_named_index) == 1
end

@testitem "same-name declarations keep every body reachable" setup=[FreshSameNameFixtures] begin
using DynamicObjects

# The dedup drops only the repeated marker definition — every
# declaration's own compute_property (each body) must survive.
@dynamicstruct struct FreshSameNameRuntime
    @fresh x(a) = (:one, a)
    @fresh x(a, b) = (:two, a, b)
end

o = FreshSameNameRuntime()
@test o.x(1) == (:one, 1)
@test o.x(1, 2) == (:two, 1, 2)
@test DynamicObjects._never_cache(o, Val(:x))
end
