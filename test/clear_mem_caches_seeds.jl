using TestItemRunner

@testmodule ClearSeedsFixtures begin
using DynamicObjects
export SeedParent, SeedChild, SeedInlineOwner, SeedOverridable, SeedRemakeSrc,
       SeedRemountStore, SEED_CALLS, SEED_GEN

const SEED_CALLS = Dict{Any,Int}()
const SEED_GEN = Ref(0)
_seed_bump!(k) = (SEED_CALLS[k] = get(SEED_CALLS, k, 0) + 1)

@dynamicstruct struct SeedParent
    factor::Int
    svc = factor * 10
end

# Standalone child: `__parent__` is NOT declared, wired purely via a
# constructor kwarg — the Bruno `FitResolver(; __parent__=__self__)` shape.
@dynamicstruct struct SeedChild
    val = (_seed_bump!(:val); __self__.__parent__.svc + SEED_GEN[])
end

@dynamicstruct struct SeedInlineOwner
    path::String
    @struct editor(relpath) = begin
        abs_path = (_seed_bump!((:abs_path, relpath)); joinpath(__parent__.path, relpath))
    end
end

@dynamicstruct struct SeedOverridable
    base::Int
    tuned = (_seed_bump!(:tuned); base + SEED_GEN[])
end

@dynamicstruct struct SeedRemakeSrc
    n::Int
    base = (_seed_bump!(:rbase); sum(1:n) + SEED_GEN[])
    result = (_seed_bump!(:rresult); 2 * base)
end

@dynamicstruct struct SeedRemountStore
    tag = "retained"
    read_value(key) = (_seed_bump!((:read_value, key, SEED_GEN[])); (SEED_GEN[], key))
end
end

@testitem "clear_mem_caches! preserves an undeclared constructor __parent__ seed" setup=[ClearSeedsFixtures] begin
using DynamicObjects

# Pre-fix this threw `MethodError: no method matching
# compute_property(::SeedChild, ::Val{:__parent__})` on the post-clear access:
# the wiring had no fallback to recompute from.
empty!(SEED_CALLS)
SEED_GEN[] = 0
p = SeedParent(2)
c = SeedChild(; __parent__=p)
@test c.val == 20
@test SEED_CALLS[:val] == 1

SEED_GEN[] = 100  # external state moves; derived memos must recompute
clear_mem_caches!(c)

@test c.__parent__ === p
@test c.val == 120
@test SEED_CALLS[:val] == 2
end

@testitem "clear_mem_caches! preserves inline-child __parent__ wiring" setup=[ClearSeedsFixtures] begin
using DynamicObjects

# Pre-fix the declared `__parent__` recomputed to its `nothing` fallback, so
# the post-clear access died with `type Nothing has no field path`.
empty!(SEED_CALLS)
o = SeedInlineOwner("/base")
e = o.editor("a.txt")
@test e.abs_path == "/base/a.txt"
@test e.__parent__ === o
@test SEED_CALLS[(:abs_path, "a.txt")] == 1

clear_mem_caches!(e)

@test e.__parent__ === o
@test e.abs_path == "/base/a.txt"
@test SEED_CALLS[(:abs_path, "a.txt")] == 2
end

@testitem "clear_mem_caches! preserves declared property overrides" setup=[ClearSeedsFixtures] begin
using DynamicObjects

# A constructor-passed override is an instance input, not a memo: the clear
# keeps it instead of recomputing the body (which would answer 105 here).
empty!(SEED_CALLS)
SEED_GEN[] = 0
s = SeedOverridable(5; tuned=999)
@test s.tuned == 999
@test get(SEED_CALLS, :tuned, 0) == 0

SEED_GEN[] = 100
clear_mem_caches!(s)

@test s.tuned == 999
@test get(SEED_CALLS, :tuned, 0) == 0

# Same for a silenced progress subtree: `__status__ = nothing` stays
# silenced instead of recomputing to a live root.
q = SeedOverridable(5; __status__=nothing)
@test q.__status__ === nothing
clear_mem_caches!(q)
@test q.__status__ === nothing
end

@testitem "remake carried values recompute after clear; explicit overrides survive" setup=[ClearSeedsFixtures] begin
using DynamicObjects

# Carried values are still-valid memos, not inputs: they ride along through
# `remake` but a later clear drops them. (Without the post-construction
# carry write they would be seeds and this clear would silently keep them.)
empty!(SEED_CALLS)
SEED_GEN[] = 0
c = SeedRemakeSrc(100)
@test c.result == 2 * 5050
@test SEED_CALLS[:rbase] == 1

r = remake(c)  # nothing changed → base + result carried, no recompute
@test r.result == 2 * 5050
@test SEED_CALLS[:rbase] == 1

SEED_GEN[] = 7
clear_mem_caches!(r)
@test r.result == 2 * (5050 + 7)
@test SEED_CALLS[:rbase] == 2

# An explicit remake override IS an input: it survives the clear.
r2 = remake(c; result=0.0)
@test r2.result == 0.0
clear_mem_caches!(r2)
@test r2.result == 0.0
end

@testitem "clear_mem_caches! on a remount view preserves request context" setup=[ClearSeedsFixtures] begin
using DynamicObjects

# Pre-fix a view clear dropped the request context into the body default
# (`tag` back to "retained") and did the same to the retained object's own
# inputs in the shared cache.
empty!(SEED_CALLS)
SEED_GEN[] = 0
s = SeedRemountStore(; tag="seeded")
@test s.tag == "seeded"
ctx = remount(s; tag="req-1")
@test ctx.tag == "req-1"
@test ctx.read_value(1) == (0, 1)

SEED_GEN[] = 10  # the save
clear_mem_caches!(ctx)

@test ctx.tag == "req-1"
@test s.tag == "seeded"
@test ctx.read_value(1) == (10, 1)
@test s.read_value(1) == (10, 1)
@test SEED_CALLS[(:read_value, 1, 10)] == 1
end
