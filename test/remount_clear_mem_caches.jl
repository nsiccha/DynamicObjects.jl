using TestItemRunner

@testmodule RemountClearFixtures begin
using DynamicObjects
export RemountStore, RC_CALLS, RC_GEN

const RC_CALLS = Dict{Any,Int}()
const RC_GEN = Ref(0)
_rc_bump!(k) = (RC_CALLS[k] = get(RC_CALLS, k, 0) + 1)

# `tag` is the rebindable request-context stand-in; `read_value` is
# context-independent, so a remounted view shares its per-argument subcache
# with the retained object. `RC_GEN` stands in for the on-disk state a save
# mutates between the pre-read and the post-clear render.
@dynamicstruct struct RemountStore
    tag = "retained"
    read_value(key) = (_rc_bump!((:read_value, key, RC_GEN[])); (RC_GEN[], key))
    # Reads the context, so a view computes it in its own subcache.
    tagged(key) = (_rc_bump!((:tagged, key, RC_GEN[])); (tag, RC_GEN[], key))
end
end

@testitem "remount shares the retained indexed subcache" setup=[RemountClearFixtures] begin
using DynamicObjects

empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
@test s.read_value(1) == (0, 1)
ctx = remount(s; tag="req-1")
@test ctx.read_value.cache === s.read_value.cache
@test ctx.read_value(1) == (0, 1)
@test RC_CALLS[(:read_value, 1, 0)] == 1
end

@testitem "clear_mem_caches! drops indexed entries a live remount already read" setup=[RemountClearFixtures] begin
using DynamicObjects

# The POST shape: request view reads before the save, retained object is
# cleared after it, the same request renders through its own view.
empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
@test s.read_value(1) == (0, 1)
ctx = remount(s; tag="req-1")
@test ctx.read_value(1) == (0, 1)

RC_GEN[] = 10  # the save
clear_mem_caches!(s)

@test s.read_value(1) == (10, 1)
# The view still shares the retained subcache, so it reads the object's
# recomputation instead of computing its own.
@test ctx.read_value(1) == (10, 1)
@test RC_CALLS[(:read_value, 1, 10)] == 1
@test ctx.read_value(1) == (10, 1)
@test RC_CALLS[(:read_value, 1, 10)] == 1
end

@testitem "clear_mem_caches! drops entries the remount itself populated" setup=[RemountClearFixtures] begin
using DynamicObjects

# Same drop when the request view is the first and only reader: the pre-read
# lands in the shared subcache, and the clear must reach it there.
empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
ctx = remount(s; tag="req-1")
@test ctx.read_value(2) == (0, 2)

RC_GEN[] = 10  # the save
clear_mem_caches!(s)

@test ctx.read_value(2) == (10, 2)
# The clear keeps the retained wrapper and its subcache, so the view and the
# retained object still share one: the retained re-read is a hit.
@test s.read_value(2) == (10, 2)
@test RC_CALLS[(:read_value, 2, 10)] == 1
end

@testitem "a live remount view stays attached across repeated clears" setup=[RemountClearFixtures] begin
using DynamicObjects

empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
ctx = remount(s; tag="req-1")
@test ctx.read_value(1) == (0, 1)
for gen in (10, 20, 30)
    RC_GEN[] = gen
    clear_mem_caches!(s)
    @test ctx.read_value(1) == (gen, 1)
    @test s.read_value(1) == (gen, 1)
    @test RC_CALLS[(:read_value, 1, gen)] == 1
end
end

@testitem "clear_mem_caches! of a view reaches the retained object's own subcaches" setup=[RemountClearFixtures] begin
using DynamicObjects

# `tagged` reads the context, so the view holds its own wrapper and the
# retained one is masked from the view; clearing through the view clears the
# retained object too, and a handle on its wrapper stays attached.
empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
held = s.tagged
@test s.tagged(1) == ("retained", 0, 1)
ctx = remount(s; tag="req-1")
@test ctx.tagged(1) == ("req-1", 0, 1)

RC_GEN[] = 10
clear_mem_caches!(ctx)
@test held(1) == ("retained", 10, 1)
@test s.tagged(1) == ("retained", 10, 1)
@test ctx.tagged(1) == ("req-1", 10, 1)
@test RC_CALLS[(:tagged, 1, 10)] == 2
end

@testitem "clear_mem_caches! drops entries for a destructured wrapper handle" setup=[RemountClearFixtures] begin
using DynamicObjects

# The same alias class without remount: a wrapper captured before the clear
# keeps referencing its subcache, so the clear must empty it, not just drop
# the top-level entry.
empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
@test s.read_value(1) == (0, 1)
held = s.read_value

RC_GEN[] = 10  # the save
clear_mem_caches!(s)

@test held(1) == (10, 1)
# The handle and the object share one subcache, so this is a hit.
@test s.read_value(1) == (10, 1)
@test RC_CALLS[(:read_value, 1, 10)] == 1
end

@testitem "clear_mem_caches! with no live view still drops the memo" setup=[RemountClearFixtures] begin
using DynamicObjects

# Control: the outside-any-request shape always worked — the dropped wrapper
# takes its unaliased subcache with it. A later view then reads fresh.
empty!(RC_CALLS)
RC_GEN[] = 0
s = RemountStore()
@test s.read_value(1) == (0, 1)

RC_GEN[] = 10  # the save
clear_mem_caches!(s)

ctx = remount(s; tag="req-2")
@test ctx.read_value(1) == (10, 1)
# The mounted read recreates the retained wrapper behind the shared subcache,
# so the retained re-read is a hit, not a second compute.
@test s.read_value(1) == (10, 1)
@test RC_CALLS[(:read_value, 1, 10)] == 1
end
