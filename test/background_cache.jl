using TestItemRunner

@testmodule BackgroundCacheFixtures begin
using DynamicObjects, Logging
export CollectLogger, nrecords, snaprecords, poll_settled, poll_advanced, poll_value_quiet, poll_quiet

# Minimal capturing logger (avoids a LoggingExtras test dep). Refresh tasks log
# from background threads, so every access takes the lock.
struct CollectLogger <: AbstractLogger
    lock::ReentrantLock
    records::Vector{Any}
end
CollectLogger() = CollectLogger(ReentrantLock(), Any[])
Logging.min_enabled_level(::CollectLogger) = Logging.BelowMinLevel
Logging.shouldlog(::CollectLogger, level, _mod, _group, _id) = true
function Logging.handle_message(l::CollectLogger, level, message, _mod, _group, _id, file, line; kwargs...)
    lock(l.lock) do
        push!(l.records, (; level, message, kwargs=Dict{Symbol,Any}(kwargs)))
    end
    nothing
end
nrecords(l::CollectLogger) = lock(l.lock) do
    length(l.records)
end
snaprecords(l::CollectLogger) = lock(l.lock) do
    copy(l.records)
end

# Poll `f` until it `== want`, sleeping between probes so a single-threaded
# runner still schedules the background refresh. Errors loudly on timeout and
# reports the last value seen — a timeout that hides what it saw is unactionable.
function poll_settled(f, want; timeout=15.0)
    t0 = time()
    last = nothing
    while true
        last = f()
        last == want && return nothing
        if time() - t0 > timeout
            error("timed out waiting for ", want, "; last seen: ", last)
        end
        sleep(0.005)
    end
end

# Poll `f` until it differs from `baseline` (a generation advanced, whatever
# number it carries). For use after a stale read: the satisfying read may
# itself be the stale kick, so pinning an exact next generation is racy.
function poll_advanced(f, baseline; timeout=15.0)
    t0 = time()
    while true
        v = f()
        v != baseline && return v
        time() - t0 > timeout && error("timed out waiting for advancement past ", baseline)
        sleep(0.005)
    end
end

# Kick-free exact poll: waits for `key` to settle to `want` by reading the
# backing Dict under the lock instead of the public read path (which kicks by
# construction — with ttl=0 *every* observing read would kick its successor,
# so quiescence between phases is only observable white-box).
struct _WBAbsent end
const _wb_absent = _WBAbsent()
function poll_value_quiet(c, key, want; timeout=15.0)
    t0 = time()
    last = _wb_absent
    while true
        last = lock(c.lock) do
            get(c.values, key, _wb_absent)
        end
        last !== _wb_absent && last == want && return last
        if time() - t0 > timeout
            error("timed out waiting for ", key, " == ", want, "; last seen: ", last)
        end
        sleep(0.005)
    end
end

# Drain: wait until no refresh is in flight (white-box — a public read would
# kick). Every item ends with this: a build that outlives its item reads
# module state TestItemRunner may already have torn down (observed on one
# thread as a post-item `get(::Nothing, ...)` MethodError from a leftover
# successor kick), so no task may outlive its item.
function poll_quiet(c; timeout=15.0)
    t0 = time()
    while true
        quiet = lock(c.lock) do
            isempty(c.refreshing)
        end
        quiet && return nothing
        time() - t0 > timeout && error("timed out waiting for quiescence")
        sleep(0.005)
    end
end
end

# NOTE on timing discipline (learned on a load-19 box): the main task can be
# descheduled for hundreds of milliseconds between any two statements, so a
# test must never assume main-thread timeliness. The load-proof rules:
# - build counters are per-testitem locals (never a shared Dict a later item
#   could empty! while a refresh is in flight) and captured at bump time, so a
#   refresh never re-reads shared state after yielding;
# - ttl=0 makes staleness a construction, not a race: every idle read is stale
#   by definition, so no sleep is needed and no stall window exists. Only the
#   concurrent-readers item uses a real TTL expiry (it tests expiry itself);
# - gates that must hold across main-thread statements use a long backoff
#   (30 s — no realistic stall outlasts it) and are cleared deterministically
#   with invalidate! instead of slept through;
# - sleeps only ever wait OUT a short backoff/TTL (a late wake means *more*
#   expired, which still kicks) and never precede a must-stay-gated read;
# - exact build counts are asserted only where kicks are gated (bump BEFORE
#   take! observes kicks; bump after would observe admissions and mask a broken
#   dedup). After an ungated value poll, assert advancement/shape instead: the
#   satisfying read may itself be the stale kick, so the next generation number
#   is schedule-dependent.
# - every item ends with poll_quiet: no refresh may outlive its item (see the
#   helper's comment).

@testitem "unbuilt reads kick the first build; stale reads serve old then swap" setup=[BackgroundCacheFixtures] begin
using DynamicObjects

# ttl=0: every idle read is stale by construction — no sleeps, no stall window.
# Values only (no count pins — the gated item below owns exact counts).
counts = Dict{Any,Int}()
build = k -> (n = (counts[k] = get(counts, k, 0) + 1); (:v, n))
c = BackgroundCache{String,Tuple{Symbol,Int}}(build; ttl=0, unbuilt=(:none, 0))

@test c["a"] == (:none, 0)
poll_settled(() -> c["a"], (:v, 1))

v_old = c["a"]
@test v_old[1] == :v
v = poll_advanced(() -> c["a"], v_old)
@test v[1] == :v && v != v_old
poll_quiet(c)
end

@testitem "concurrent readers share one refresh per key" setup=[BackgroundCacheFixtures] begin
using DynamicObjects

counts = Dict{Any,Int}()
gate = Channel{Nothing}(1)
# Bump BEFORE the gate: every kick bumps (blocked or not), so the count
# observes kicks — bumping after take! would observe admissions and mask a
# broken dedup. A spurious stale kick is indistinguishable from the planned
# refresh here (one token admits exactly one landing either way), so the
# exact counts below hold on any schedule.
build = k -> (n = (counts[k] = get(counts, k, 0) + 1); take!(gate); (:v, n))
c = BackgroundCache{String,Tuple{Symbol,Int}}(build; ttl=0.05, unbuilt=(:none, 0))

@test c["a"] == (:none, 0)
put!(gate, nothing)
poll_value_quiet(c, "a", (:v, 1))
sleep(0.08)

results = Vector{Any}(undef, 8)
@sync for i in 1:8
    Threads.@spawn results[i] = c["a"]
end
@test all(==((:v, 1)), results)
put!(gate, nothing)
poll_value_quiet(c, "a", (:v, 2))
@test counts["a"] == 2

# Same dedup before the first build: every racer reads unbuilt, one build runs.
results_b = Vector{Any}(undef, 8)
@sync for i in 1:8
    Threads.@spawn results_b[i] = c["b"]
end
@test all(==((:none, 0)), results_b)
put!(gate, nothing)
poll_value_quiet(c, "b", (:v, 1))
@test counts["b"] == 1
poll_quiet(c)
end

@testitem "failures keep the previous value and log with a backtrace" setup=[BackgroundCacheFixtures] begin
using DynamicObjects, Logging

counts = Dict{Any,Int}()
fail = Ref(true)
build = k -> (n = (counts[k] = get(counts, k, 0) + 1); fail[] && error("boom-", k); (:v, n))
logger = CollectLogger()
# ttl=0 (stale by construction) + a 30 s backoff (no stall outlasts it).
c = BackgroundCache{String,Any}(build; ttl=0, unbuilt=:unbuilt, backoff_base=30.0, backoff_max=30.0)

old = global_logger(logger)
try
    @test c["a"] === :unbuilt
    poll_settled(() -> nrecords(logger), 1)
    rec = only(snaprecords(logger))
    @test rec.level == Logging.Error
    @test rec.kwargs[:key] == "a"
    ex, bt = rec.kwargs[:exception]
    @test ex isa ErrorException
    @test bt isa Vector && !isempty(bt)

    # Gated: further reads serve unbuilt without kicking (the 30 s gate
    # outlasts any scheduling stall, so this holds on any schedule).
    @test c["a"] === :unbuilt
    @test c["a"] === :unbuilt
    @test counts["a"] == 1
    @test nrecords(logger) == 1

    # A later demand retries once the gate is cleared and then succeeds. The
    # quiet poll observes the landing without kicking (with ttl=0 a public
    # read would kick its successor), so exactly B1+B2 ran and (:v, 2) is exact.
    fail[] = false
    @test invalidate!(c, "a") === nothing
    @test c["a"] === :unbuilt
    @test poll_value_quiet(c, "a", (:v, 2)) == (:v, 2)
    @test counts["a"] == 2
    @test nrecords(logger) == 1

    # A failure against a settled value keeps the stale value and logs again.
    # Self-consistent (no assumed generation): the 30 s gate holds the value
    # stable across the post-failure reads on any schedule. No sleep needed —
    # ttl=0 makes the read stale by construction.
    fail[] = true
    v3a = c["a"]
    @test v3a == (:v, 2)
    poll_settled(() -> nrecords(logger), 2)
    @test c["a"] == v3a
    @test nrecords(logger) == 2
    poll_quiet(c)
finally
    global_logger(old)
end
end

@testitem "an expired backoff retries on the next read" setup=[BackgroundCacheFixtures] begin
using DynamicObjects, Logging

counts = Dict{Any,Int}()
fail = Ref(true)
build = k -> (n = (counts[k] = get(counts, k, 0) + 1); fail[] && error("boom-", k); (:v, n))
logger = CollectLogger()
c = BackgroundCache{String,Any}(build; ttl=60.0, unbuilt=:unbuilt, backoff_base=0.05, backoff_max=1.0)

old = global_logger(logger)
try
    @test c["a"] === :unbuilt
    poll_settled(() -> nrecords(logger), 1)
    # No reads between the failure landing and the sleep, so exactly one
    # build ran; the sleep outlasts the 0.05 s gate (a late wake only helps).
    @test counts["a"] == 1
    sleep(0.15)
    fail[] = false
    @test c["a"] === :unbuilt
    poll_settled(() -> c["a"], (:v, 2))
    @test counts["a"] == 2
    @test nrecords(logger) == 1
    poll_quiet(c)
finally
    global_logger(old)
end
end

@testitem "maxsize evicts stalest-settled keys first" setup=[BackgroundCacheFixtures] begin
using DynamicObjects

counts = Dict{Any,Int}()
gate = Channel{Nothing}(1)
# Gated (not slept): a stalled main task can never observe a mid-assert landing.
# Bump after the gate (see the concurrent-readers item): only released builds count.
build = k -> (take!(gate); n = (counts[k] = get(counts, k, 0) + 1); (k, n))
c = BackgroundCache{String,Tuple{String,Int}}(build; ttl=60.0, unbuilt=("none", 0), maxsize=2)

@test c["k1"] == ("none", 0)
put!(gate, nothing)
poll_settled(() -> c["k1"], ("k1", 1))
@test c["k2"] == ("none", 0)
put!(gate, nothing)
poll_settled(() -> c["k2"], ("k2", 1))
@test c["k3"] == ("none", 0)
put!(gate, nothing)
poll_settled(() -> c["k3"], ("k3", 1))

# k3's landing evicted k1 (stalest); the proving read kicks a gated rebuild
# that cannot land mid-assert, so k2/k3 read fresh deterministically.
@test c["k1"] == ("none", 0)
@test c["k2"] == ("k2", 1)
@test c["k3"] == ("k3", 1)
put!(gate, nothing)
poll_settled(() -> c["k1"], ("k1", 2))
# The rebuild's landing evicted k2 (now stalest).
@test c["k2"] == ("none", 0)
@test c["k3"] == ("k3", 1)
# Drain the k2 rebuild the proving read kicked, so no task outlives the item.
put!(gate, nothing)
poll_settled(() -> c["k2"], ("k2", 2))
poll_quiet(c)
end

@testitem "invalidate! drops the entry; ttl=Inf never stales; bad args throw" setup=[BackgroundCacheFixtures] begin
using DynamicObjects

@test_throws ArgumentError BackgroundCache{String,Int}(k -> 1; ttl=-1.0, unbuilt=0)
@test_throws ArgumentError BackgroundCache{String,Int}(k -> 1; ttl=NaN, unbuilt=0)
@test_throws ArgumentError BackgroundCache{String,Int}(k -> 1; ttl=1.0, unbuilt=0, maxsize=-1)
@test_throws ArgumentError BackgroundCache{String,Int}(k -> 1; ttl=1.0, unbuilt=0, backoff_base=-1.0)

counts = Dict{Any,Int}()
build = k -> (n = (counts[k] = get(counts, k, 0) + 1); (:v, n))
c = BackgroundCache{String,Tuple{Symbol,Int}}(build; ttl=60.0, unbuilt=(:none, 0))
@test c["a"] == (:none, 0)
poll_settled(() -> c["a"], (:v, 1))
@test invalidate!(c, "a") === nothing
@test c["a"] == (:none, 0)
poll_settled(() -> c["a"], (:v, 2))
@test counts["a"] == 2

cinf = BackgroundCache{String,Int}(k -> (counts[k] = get(counts, k, 0) + 1; 7); ttl=Inf, unbuilt=0)
@test cinf["z"] == 0
poll_settled(() -> cinf["z"], 7)
sleep(0.06)
@test cinf["z"] == 7
@test counts["z"] == 1
poll_quiet(c)
poll_quiet(cinf)
end
