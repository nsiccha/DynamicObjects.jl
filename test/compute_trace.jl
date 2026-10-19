using TestItemRunner

# `with_compute_trace` records what property reads did: per `(type, property)` the hits,
# memoized and fresh computations, disk loads, waits, polls and failures with their times,
# plus a log of the invalidations issued meanwhile. It follows the calling task into tasks
# it spawns and into deferred work (executors, the job queue), and records nothing outside
# a scope (snag `no-trace-of-what-e8f9d53e`).
@testmodule ComputeTraceFixtures begin
using DynamicObjects
export CTApp, CTSlow, CTDisk, CTGated, CTClearer, CTTracked, CTQueue, CTView,
       CTHashed, CTHashView, SlowHash, SLOW_HASH_S,
       CT_CACHE_BASE, CT_STARTED, CT_GATE, row, hasrow, settles, gate_reset!

const CT_CACHE_BASE = Ref("")
const CT_STARTED = Threads.Atomic{Int}(0)
const CT_GATE = Ref(Base.Event())

gate_reset!() = (CT_STARTED[] = 0; CT_GATE[] = Base.Event())
_gated(x) = (Threads.atomic_add!(CT_STARTED, 1); wait(CT_GATE[]); x)
settles(f, seconds=10.0) = timedwait(f, seconds; pollint=0.01) === :ok

row(trace, T, name) =
    only(filter(r -> r.type === T && r.property === name, compute_trace_rows(trace)))
hasrow(trace, T, name) = any(r -> r.type === T && r.property === name, compute_trace_rows(trace))

@dynamicstruct struct CTApp
    seed::Int
    a = seed + 1
    b(x::Int) = a + x
    @fresh c(x::Int) = seed * x
    top = b(1) + b(2) + c(1) + c(2) + a
    boom = error("boom $seed")
    work(x::Int) = 10x
end

@dynamicstruct struct CTSlow
    child = (sleep(0.3); 1)
    parent = (sleep(0.05); child + 1)
end

@dynamicstruct struct CTDisk
    seed::Int
    __cache_base__ = CT_CACHE_BASE[]
    @cached stored = 2seed
end

@dynamicstruct struct CTGated
    slow = _gated(1)
end

@dynamicstruct struct CTClearer
    app::CTApp
    reset = (clear_mem_caches!(app); true)
end

@dynamicstruct struct CTTracked
    path::String
    source = TrackedFile(path; read = p -> read(p, String))
    text = read(source)
    shout = uppercase(text)
end

@dynamicstruct struct CTQueue
    @queued gated(i::Int) = _gated(i)
    @queued item(i::Int) = 10i
end

_opaque(app, n) = Ref(n)
@dynamicstruct struct CTView
    ctx = nothing
    shares(n::Int) = _opaque(__self__, n)
end

# An argument that takes `SLOW_HASH_S` to hash; equal values are distinct objects, so each
# one is hashed when it is first passed.
const SLOW_HASH_S = 0.05
mutable struct SlowHash
    v::Int
end
Base.hash(x::SlowHash, h::UInt) = (sleep(SLOW_HASH_S); hash(x.v, h))
Base.:(==)(a::SlowHash, b::SlowHash) = a.v == b.v

@dynamicstruct struct CTHashed
    keyed(k::SlowHash) = k.v
end

@dynamicstruct struct CTHashView
    ctx = nothing
    shares(k::SlowHash) = _opaque(__self__, k.v)
end
end

@testitem "with_compute_trace counts hits, memoized and fresh computations per property" setup=[ComputeTraceFixtures] begin
using DynamicObjects
app = CTApp(1)
value, trace = with_compute_trace() do
    app.top + app.top + app.b(1) + app.b(7)
end
@test value == 2app.top + app.b(1) + app.b(7)
@test trace isa ComputeTrace
@test DynamicObjects._ACTIVE_TRACES[] == 0

top = row(trace, CTApp, :top)
@test (top.calls, top.computed, top.hits, top.fresh) == (2, 1, 1, 0)
b = row(trace, CTApp, :b)
@test (b.calls, b.computed, b.hits) == (4, 3, 1)      # b(1), b(2), b(7) computed; b(1) re-read
a = row(trace, CTApp, :a)
@test (a.calls, a.computed, a.hits) == (4, 1, 3)      # read by b(1), b(2), top and b(7)
c = row(trace, CTApp, :c)
@test (c.calls, c.fresh, c.computed, c.hits) == (2, 2, 0, 0)
@test all(r -> r.total_s >= r.self_s >= 0, compute_trace_rows(trace))
@test all(r -> r.max_s <= r.total_s, compute_trace_rows(trace))

# Outside a scope nothing records, and reading the wrapper `app.b` is not a read of `b`.
app.top
@test row(trace, CTApp, :top).calls == 2
@test DynamicObjects._ACTIVE_TRACES[] == 0
end

@testitem "self time excludes the nested computations recorded on the same task" setup=[ComputeTraceFixtures] begin
using DynamicObjects
CTSlow().parent                       # compile outside the measurement
with_compute_trace(() -> CTSlow().parent)
_, trace = with_compute_trace(() -> CTSlow().parent)
parent, child = row(trace, CTSlow, :parent), row(trace, CTSlow, :child)
@test child.total_s >= 0.3
@test child.self_s == child.total_s
@test parent.total_s >= 0.35
@test parent.self_s >= 0.05
@test isapprox(parent.self_s, parent.total_s - child.total_s; atol=1e-8)
# Rows sort by own time: the parent's 0.05 s self time ranks below the child's 0.3 s.
@test [r.property for r in compute_trace_rows(trace)] == [:child, :parent]
end

@testitem "a @cached property served from its disk entry counts as disk" setup=[ComputeTraceFixtures] begin
using DynamicObjects
CT_CACHE_BASE[] = mktempdir()
d = CTDisk(3)
_, first_trace = with_compute_trace(() -> d.stored)
@test (row(first_trace, CTDisk, :stored).computed, row(first_trace, CTDisk, :stored).disk) == (1, 0)
clear_mem_caches!(d)
_, second_trace = with_compute_trace(() -> d.stored)
r = row(second_trace, CTDisk, :stored)
@test (r.calls, r.disk, r.computed) == (1, 1, 0)
# DynamicObjects' own `__name__` properties (hash, cache path, status) are not recorded.
@test all(r -> !startswith(string(r.property), "__"), compute_trace_rows(first_trace))
end

@testitem "spawned tasks inherit the trace; a read joining a running computation is a wait" setup=[ComputeTraceFixtures] begin
using DynamicObjects
gate_reset!()
o = CTGated()
_, trace = with_compute_trace() do
    computer = Threads.@spawn o.slow
    @test settles(() -> CT_STARTED[] == 1)
    waiter = Threads.@spawn o.slow
    sleep(0.2)
    @test !istaskdone(waiter)
    notify(CT_GATE[])
    fetch(computer) + fetch(waiter)
end
r = row(trace, CTGated, :slow)
@test (r.calls, r.computed, r.waits, r.hits) == (2, 1, 1, 0)
@test r.wait_s > 0.1
end

@testitem "an executor's worker records into the trace its computation was started in" setup=[ComputeTraceFixtures] begin
using DynamicObjects
import DynamicObjects: run!
app = CTApp(2)
jobs, go = Channel{Any}(Inf), Base.Event()
worker = Threads.@spawn (wait(go); foreach(run!, jobs))   # started outside any trace
_, trace = with_compute_trace() do
    p = app.work(1; fetch=Deferred(d -> put!(jobs, d)))
    @test p isa Pending
    notify(go)
    fetch(p)
end
close(jobs)
wait(worker)
r = row(trace, CTApp, :work)
@test r.computed == 1
@test r.pending == 1

# Work started outside every trace is not recorded by a worker that inherited one.
inner_jobs = Channel{Any}(Inf)
started, finish = Base.Event(), Base.Event()
traced = Threads.@spawn with_compute_trace() do
    inner = Threads.@spawn foreach(run!, inner_jobs)   # inherits this trace
    notify(started)
    wait(finish)
    close(inner_jobs)
    wait(inner)
end
wait(started)
p = app.work(2; fetch=Deferred(d -> put!(inner_jobs, d)))
@test fetch(p) == 20
notify(finish)
_, other = fetch(traced)
@test !hasrow(other, CTApp, :work)
end

@testitem "a @queued computation admitted by an untraced task records into its caller's trace" setup=[ComputeTraceFixtures] begin
using DynamicObjects
gate_reset!()
DynamicObjects.configure_queue!(; max_running=1)
try
    o = CTQueue()
    blocker = Threads.@spawn o.gated(1)         # untraced, holds the only slot
    @test settles(() -> CT_STARTED[] == 1)
    traced = Threads.@spawn with_compute_trace(() -> o.item(2))
    sleep(0.2)
    @test !istaskdone(traced)                   # its item waits for the slot
    notify(CT_GATE[])
    @test fetch(blocker) == 1
    value, trace = fetch(traced)
    @test value == 20
    r = row(trace, CTQueue, :item)
    @test r.computed == 1
    @test r.waits == 1                          # the caller waited for its queued computation
    @test !hasrow(trace, CTQueue, :gated)
finally
    DynamicObjects.configure_queue!(; max_running=0)
end
end

@testitem "invalidations are logged with what they dropped and where they were issued" setup=[ComputeTraceFixtures] begin
using DynamicObjects
app = CTApp(1)
app.top
app.b(5)
_, trace = with_compute_trace() do
    DynamicObjects.clear_cache!(app, :a)
    app.b(5)
    invalidate!(app.b, 5)
    invalidate!(app.b, 99)
    CTClearer(app).reset
end
log = trace.invalidations
@test [i.verb for i in log] == [:clear_cache!, :invalidate!, :invalidate!, :clear_mem_caches!]
@test log[1].dropped == [:a, :b, :top]
@test log[1].type === CTApp
@test log[1].issued_from === nothing
@test log[2].dropped == [:b]
@test log[2].key == ((5,), NamedTuple())
@test log[3].dropped == Symbol[]
@test log[4].issued_from == (CTClearer, :reset)
@test log[4].dropped == [:a]                    # `b` holds no entry after its invalidate!
@test issorted(i.at for i in log)

text = sprint(show, MIME"text/plain"(), trace)
@test occursin("Invalidations:", text)
@test occursin("issued from CTClearer.reset", text)
@test occursin("CTApp.b", text)
@test startswith(sprint(show, trace), "ComputeTrace(")
end

@testitem "sync! logs each object whose memory values it dropped" setup=[ComputeTraceFixtures] begin
using DynamicObjects
path = joinpath(mktempdir(), "input.txt")
write(path, "hi")
o = CTTracked(path)
@test o.shout == "HI"
_, trace = with_compute_trace() do
    sync!(o)                                    # nothing changed: not logged
    write(path, "ho")
    sync!(o)
    o.shout
end
@test only(trace.invalidations).verb === :sync!
@test only(trace.invalidations).dropped == [:shout, :text]
@test row(trace, CTTracked, :shout).computed == 1
end

@testitem "failures, the event log, nesting, reuse and finished traces" setup=[ComputeTraceFixtures] begin
using DynamicObjects
app = CTApp(4)
_, trace = with_compute_trace(; events=3) do
    @test_throws PropertyComputationError app.boom
    @test_throws PropertyComputationError app.boom   # a failed computation is retried
    app.a + app.a + app.b(1)
end
@test row(trace, CTApp, :boom).errors == 2
@test length(trace.events) == 3
@test trace.events_dropped == 3                   # a hit, then b(1) and its read of a
@test [e.outcome for e in trace.events] == [:error, :error, :computed]
@test trace.events[3].property === :a && trace.events[3].args === nothing
@test occursin("3 events kept", sprint(show, MIME"text/plain"(), trace))

# An inner scope also records into the enclosing trace.
app2 = CTApp(5)
inner_trace = Ref{Any}(nothing)
_, outer = with_compute_trace() do
    app2.a
    _, inner_trace[] = with_compute_trace(() -> app2.b(1))
end
@test row(outer, CTApp, :b).computed == 1
@test row(outer, CTApp, :a).calls == 2
@test row(inner_trace[], CTApp, :b).computed == 1
@test row(inner_trace[], CTApp, :a).hits == 1

# A supplied trace keeps what it recorded when `f` throws, and collects several calls.
kept = ComputeTrace()
@test_throws ErrorException with_compute_trace(() -> (CTApp(6).a; error("request failed")), kept)
@test with_compute_trace(() -> CTApp(7).a, kept) == 8
@test row(kept, CTApp, :a).computed == 2
@test DynamicObjects._ACTIVE_TRACES[] == 0

# A task that outlives its scope no longer changes the trace.
gate = Base.Event()
late = Ref{Task}()
_, finished = with_compute_trace() do
    late[] = Threads.@spawn (wait(gate); CTApp(8).a)
end
notify(gate)
@test fetch(late[]) == 9
@test !hasrow(finished, CTApp, :a)
end

@testitem "a remount view's read of shared opaque work is a hit" setup=[ComputeTraceFixtures] begin
using DynamicObjects
source = CTView()
views = [remount(source; ctx=i) for i in 1:2]
_, trace = with_compute_trace() do
    views[1].shares(1)[] + views[2].shares(1)[]
end
r = row(trace, CTView, :shares)
@test (r.calls, r.computed, r.hits) == (2, 1, 1)
end

@testitem "a traced hit's time includes hashing its key" setup=[ComputeTraceFixtures] begin
using DynamicObjects
# `memoize!` hashes the key (`_memo_key`) before it looks the entry up. A hit passing an
# equal but distinct argument hashes it anew, and that is part of the read's time. Each
# traced path is warmed first with the argument already passed (its hash is remembered),
# so first-call compilation is not what crosses the bound.
app = CTHashed()
k = SlowHash(1)
app.keyed(k)
with_compute_trace(() -> app.keyed(k))
_, trace = with_compute_trace() do
    app.keyed(SlowHash(1))
end
r = row(trace, CTHashed, :keyed)
@test (r.calls, r.hits) == (1, 1)
@test r.hit_s >= SLOW_HASH_S

# The same for a remount view's read of opaque work another view computed.
source = CTHashView()
views = [remount(source; ctx=i) for i in 1:2]
k = SlowHash(2)
views[1].shares(k)
with_compute_trace(() -> views[2].shares(k))
_, trace = with_compute_trace() do
    views[2].shares(SlowHash(2))[]
end
r = row(trace, CTHashView, :shares)
@test (r.calls, r.hits) == (1, 1)
@test r.hit_s >= SLOW_HASH_S
end
