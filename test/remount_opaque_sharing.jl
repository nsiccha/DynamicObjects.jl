using TestItemRunner

# Opaque properties hand a bare `__self__` to code outside the struct, so the
# static dependency scan cannot tell whether they read request context. A
# remount view computes them once for every view that rebinds the same context,
# under a guarded `__self__`; only a computation that actually reads context
# stays per view (snag `remount-opaque-s-2938c22c`).
@testmodule RemountOpaqueFixtures begin
using DynamicObjects
export ROQ, roq_calls, roq_reset!, ROQ_STARTED, ROQ_RELEASE

const ROQ_CALLS = Dict{Any,Int}()
const ROQ_LOCK = ReentrantLock()
_roq_bump!(k) = lock(() -> (ROQ_CALLS[k] = get(ROQ_CALLS, k, 0) + 1), ROQ_LOCK)
roq_calls(k) = lock(() -> get(ROQ_CALLS, k, 0), ROQ_LOCK)
roq_reset!() = lock(() -> empty!(ROQ_CALLS), ROQ_LOCK)

const ROQ_STARTED = Ref{Any}(nothing)
const ROQ_RELEASE = Ref{Any}(nothing)
_roq_gate!() = (put!(ROQ_STARTED[], nothing); take!(ROQ_RELEASE[]))

# Helpers outside the struct: each receives the escaped `__self__`.
_reads_nothing(app, n) = Ref(n)
_reads_intrinsic(app, n) = Ref(app.helper(n))
_reads_context(app, n) = (app.ctx, n)
_reads_opaque(app, n) = app.shares(n)
_reads_opaque_context(app, n) = app.ctx_reader(n)
_retains(app) = (; app)
_fails(app, n) = throw(ArgumentError("no context, n=$n"))
_fails_after_context(app, n) = throw(ArgumentError("ctx=$(app.ctx), n=$n"))
# Reaches request context without `getproperty`: a direct cache peek.
_peeks_context(app, n) = (get(getfield(app, :cache).cache, :ctx, :absent), n)

@dynamicstruct struct ROQ
    ctx = nothing
    helper(n::Int) = n + 1
    shares(n::Int) = (_roq_bump!((:shares, n)); _reads_intrinsic(__self__, n))
    bare_share = (_roq_bump!(:bare_share); _reads_nothing(__self__, 7))
    ctx_reader(n::Int) = (_roq_bump!((:ctx_reader, n)); _reads_context(__self__, n))
    bare_ctx = (_roq_bump!(:bare_ctx); _reads_context(__self__, 0))
    nested_share(n::Int) = (_roq_bump!((:nested_share, n)); _reads_opaque(__self__, n))
    nested_ctx(n::Int) = (_roq_bump!((:nested_ctx, n)); _reads_opaque_context(__self__, n))
    # Not opaque itself: a static dependent of an opaque property.
    dependent(n::Int) = (_roq_bump!((:dependent, n)); shares(n)[] * 10)
    retains = (_roq_bump!(:retains); _retains(__self__))
    slow(n::Int) = (_roq_bump!((:slow, n)); _roq_gate!(); _reads_intrinsic(__self__, n))
    slow_ctx(n::Int) = (_roq_bump!((:slow_ctx, n)); _roq_gate!(); _reads_context(__self__, n))
    fails(n::Int) = (_roq_bump!((:fails, n)); _fails(__self__, n))
    fails_ctx(n::Int) = (_roq_bump!((:fails_ctx, n)); _fails_after_context(__self__, n))
    peeks(n::Int) = (_roq_bump!((:peeks, n)); _peeks_context(__self__, n))
    @progress polled(key::String) = (_roq_bump!((:polled, key)); _roq_gate!(); _reads_intrinsic(__self__, length(key)))
end
end

@testitem "remount shares opaque work that reads no request context" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
source = ROQ()
views = [remount(source; ctx=i) for i in 1:3]
shared = views[1].shares(1)
@test shared[] == 2
@test all(v -> v.shares(1) === shared, views)
@test roq_calls((:shares, 1)) == 1
bare = views[1].bare_share
@test bare[] == 7
@test all(v -> v.bare_share === bare, views)
@test roq_calls(:bare_share) == 1
# Opaque work reading other opaque work, and static dependents of opaque work.
@test all(v -> v.nested_share(1) === shared, views)
@test roq_calls((:nested_share, 1)) == 1
@test all(v -> v.dependent(1) == 20, views)
@test roq_calls((:dependent, 1)) == 1
# A later view — and a remount of a view — reuse the same work.
@test remount(views[2]; ctx=:late).shares(1) === shared
@test roq_calls((:shares, 1)) == 1
end

@testitem "remount keeps opaque work that reads request context per view" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
source = ROQ()
views = [remount(source; ctx=i) for i in 1:3]
for (i, v) in enumerate(views)
    @test v.ctx_reader(1) == (i, 1)
    @test v.bare_ctx == (i, 0)
    @test v.nested_ctx(1) == (i, 1)
end
# One computation per view: the first requester's guarded computation is its
# own value, never repeated.
@test roq_calls((:ctx_reader, 1)) == 3
@test roq_calls(:bare_ctx) == 3
@test roq_calls((:nested_ctx, 1)) == 3
for (i, v) in enumerate(views)
    @test v.ctx_reader(1) == (i, 1)
    @test v.bare_ctx == (i, 0)
end
@test roq_calls((:ctx_reader, 1)) == 3
@test roq_calls(:bare_ctx) == 3
# The retained object's own computation sees its own context.
@test source.ctx_reader(1) == (nothing, 1)
end

@testitem "remount treats a direct cache peek of request context as a context read" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
source = ROQ()
views = [remount(source; ctx=i) for i in 1:3]
@test [v.peeks(1) for v in views] == [(i, 1) for i in 1:3]
@test roq_calls((:peeks, 1)) == 3
end

@testitem "an in-flight opaque computation serves every remount poll" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
ROQ_STARTED[] = Channel{Nothing}(1)
ROQ_RELEASE[] = Channel{Nothing}(1)
source = ROQ()
poll(view) = fetchindex(view.slow, 1) do rv, status
    rv
end
first = poll(remount(source; ctx=1))
@test first isa Pending
take!(ROQ_STARTED[])
# Each poll arrives on a fresh view, as each HTTP request does.
later = [poll(remount(source; ctx=i)) for i in 2:5]
@test all(p -> p isa Pending, later)
@test roq_calls((:slow, 1)) == 1
put!(ROQ_RELEASE[], nothing)
value = fetch(first)
@test value[] == 2
@test all(p -> fetch(p) === value, later)
@test poll(remount(source; ctx=6)) === value
@test roq_calls((:slow, 1)) == 1
end

@testitem "a context-dependent computation in flight falls back to each view" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
ROQ_STARTED[] = Channel{Nothing}(1)
ROQ_RELEASE[] = Channel{Nothing}(1)
source = ROQ()
a = remount(source; ctx=:a)
b = remount(source; ctx=:b)
pending_a = fetchindex(a.slow_ctx, 1) do rv, status
    rv
end
@test pending_a isa Pending
take!(ROQ_STARTED[])
# `b` blocks on `a`'s computation, learns it read context, and computes its own.
waiter = Threads.@spawn b.slow_ctx(1)
put!(ROQ_RELEASE[], nothing)
take!(ROQ_STARTED[])
put!(ROQ_RELEASE[], nothing)
@test fetch(waiter) == (:b, 1)
# `a`'s own handle resolves to `a`'s value, not to the shared latch's signal.
@test fetch(pending_a) == (:a, 1)
@test a.slow_ctx(1) == (:a, 1)
@test roq_calls((:slow_ctx, 1)) == 2
# Later views go straight to their own computation.
c = remount(source; ctx=:c)
task = Threads.@spawn c.slow_ctx(1)
take!(ROQ_STARTED[])
put!(ROQ_RELEASE[], nothing)
@test fetch(task) == (:c, 1)
@test roq_calls((:slow_ctx, 1)) == 3
end

@testitem "a shared opaque value's retained __self__ refuses request context" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
source = ROQ()
a = remount(source; ctx=:a)
b = remount(source; ctx=:b)
retained = a.retains
@test b.retains === retained
@test roq_calls(:retains) == 1
# Context-independent state stays reachable through it.
@test retained.app.helper(3) == 4
err = try
    retained.app.ctx
    nothing
catch e
    e
end
@test err isa DynamicObjects.RemountSharedContextError
@test err.property === :retains
@test err.context === :ctx
@test occursin("pass it as an argument", sprint(showerror, err))
end

@testitem "remount opaque failures stay with the computation that raised them" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
source = ROQ()
a = remount(source; ctx=:a)
b = remount(source; ctx=:b)
failure(f) = try
    f()
    nothing
catch e
    e
end
# A context-independent failure is the same failure for every view.
err = failure(() -> a.fails(1))
@test err isa PropertyComputationError
@test DynamicObjects.unwrap_error(err) isa ArgumentError
# A failure after reading context belongs to the view whose context it read.
err_a = failure(() -> a.fails_ctx(1))
err_b = failure(() -> b.fails_ctx(1))
@test occursin("ctx=a", sprint(showerror, DynamicObjects.unwrap_error(err_a)))
@test occursin("ctx=b", sprint(showerror, DynamicObjects.unwrap_error(err_b)))
@test roq_calls((:fails_ctx, 1)) == 2
end

@testitem "clear_mem_caches! drops remount-shared opaque work" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
source = ROQ()
a = remount(source; ctx=:a)
live = remount(source; ctx=:live)
@test a.shares(1)[] == 2
@test a.ctx_reader(1) == (:a, 1)
clear_mem_caches!(source)
# A view that was live across the clear recomputes, and views created after
# the clear share that computation.
@test live.shares(1)[] == 2
@test roq_calls((:shares, 1)) == 2
b = remount(source; ctx=:b)
@test b.shares(1) === live.shares(1)
@test roq_calls((:shares, 1)) == 2
# A cleared context-dependent key is attempted as shared work again.
@test b.ctx_reader(1) == (:b, 1)
@test remount(source; ctx=:c).ctx_reader(1) == (:c, 1)
@test roq_calls((:ctx_reader, 1)) == 3
# Clearing through a view reaches the shared work too.
clear_mem_caches!(b)
@test live.shares(1)[] == 2
@test roq_calls((:shares, 1)) == 3
end

@testitem "a polled @progress opaque property resolves across remounts" setup=[RemountOpaqueFixtures] begin
using DynamicObjects
roq_reset!()
ROQ_STARTED[] = Channel{Nothing}(1)
ROQ_RELEASE[] = Channel{Nothing}(1)
source = ROQ()
poll(i) = fetchindex(remount(source; ctx=i).polled, "abc") do rv, status
    (rv, status)
end
rv, status = poll(1)
@test rv isa Pending
@test status !== nothing
take!(ROQ_STARTED[])
for i in 2:4
    rv_i, status_i = poll(i)
    @test rv_i isa Pending
    @test status_i === status
end
put!(ROQ_RELEASE[], nothing)
@test fetch(rv)[] == 4
done, _ = poll(5)
@test done === fetch(rv)
@test roq_calls((:polled, "abc")) == 1
end
