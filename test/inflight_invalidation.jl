using TestItemRunner

# An invalidation that lands while a computation is in flight: the computation may have
# read what was invalidated, so nothing it produces is stored (memory, explicit disk entry,
# governed automatic entry); its own caller still gets its value; waiters and poll handles
# re-resolve. Each computation of `rates` waits on a gate keyed by the content it read, so
# a test decides which in-flight computation finishes when.
@testmodule InflightInvalidationFixtures begin
using DynamicObjects
export Book, DiskBook, GovernedBook, StateBook, GOVERNED_BASE, gate_open!, reset_gates!, next_read, waiting

const GATES = Dict{String,Channel{Nothing}}()
const GATES_LOCK = ReentrantLock()
const READS = Channel{String}(Inf)
gate(content) = lock(() -> get!(() -> Channel{Nothing}(Inf), GATES, content), GATES_LOCK)
gate_open!(content) = put!(gate(content), nothing)
reset_gates!() = (lock(() -> empty!(GATES), GATES_LOCK); while isready(READS); take!(READS); end)
next_read(seconds=10) = timedwait(() -> isready(READS), seconds) === :ok ? take!(READS) : nothing

# How many tasks are parked on the in-flight latch of `key` in cache `c` (blocking
# waiters, `fetch`es of a `Pending`), so a test invalidates only once they wait there.
waiting(c, key) = lock(c.lock) do
    cnd = get(c.computing, key, nothing)
    cnd === nothing ? 0 : length(cnd.waitq)
end

gated_read(path) = begin
    content = read(path, String)
    put!(READS, content)
    take!(gate(content))
    content
end

@dynamicstruct struct Book
    path::String
    source = TrackedFile(path; read = p -> read(p, String))
    rates = gated_read(path)
    summary = "summary of " * rates
    chapter(i) = gated_read(path) * string(i)
    tracked_summary = "tracked " * read(source)
    # Refreshers that write the data file and invalidate from inside their own compute.
    @fresh refresh_all(new) = (write(path, new); clear_mem_caches!(__self__); new)
    @fresh refresh_named(new) = (write(path, new); DynamicObjects.clear_cache!(__self__, :rates); new)
    @fresh refresh_tracked(new) = (write(path, new); notify_change!(source); sync!(__self__); new)
    # A memoized aggregate whose own compute triggers the refresh of what it reads.
    combined(new) = begin
        before = rates
        refresh_named(new)
        before * "+" * rates
    end
end

@dynamicstruct struct DiskBook
    path::String
    __cache_path__::String
    @cached rates = gated_read(path)
end

@dynamicstruct struct StateBook
    path::String
    # Per-instance state: its initializer reads only a fixed field.
    @state log = (gated_read(path); String[])
end

const GOVERNED_BASE = Ref("")
@dynamicstruct struct GovernedBook
    path::String
    __cache_base__ = GOVERNED_BASE[]
    # Over 1 MiB, so governed execution persists it.
    large(scale::Int)::String = repeat(gated_read(path), scale * (1 + 1024 * 1024))
end
end

@testitem "a sibling in flight across an invalidation is not stored" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
for (label, refresh) in (("clear_mem_caches!", (o, x) -> o.refresh_all(x)),
                         ("clear_cache!", (o, x) -> o.refresh_named(x)))
    reset_gates!()
    path = tempname(); write(path, "old")
    book = Book(path)
    inflight = Threads.@spawn book.rates
    @test next_read() == "old"
    refresh(book, "new")
    gate_open!("old")
    @test fetch(inflight) == "old"              # its own caller gets its value
    gate_open!("new")
    @test book.rates == "new"                   # but it was not stored
    @test next_read() == "new"
    @test book.summary == "summary of new"
end
end

@testitem "a caller that starts after the invalidation gets its own computation" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
for (label, refresh) in (("clear_mem_caches!", (o, x) -> o.refresh_all(x)),
                         ("clear_cache!", (o, x) -> o.refresh_named(x)))
    reset_gates!()
    path = tempname(); write(path, "old")
    book = Book(path)
    before = Threads.@spawn book.rates
    @test next_read() == "old"
    refresh(book, "new")
    after = Threads.@spawn book.rates
    @test next_read() == "new"                  # it started a computation of its own
    gate_open!("old"); @test fetch(before) == "old"   # the pre-invalidation one finishes first
    gate_open!("new"); @test fetch(after) == "new"
    @test book.rates == "new"
end
end

@testitem "waiters and poll handles of a retracted computation re-resolve" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
reset_gates!()
path = tempname(); write(path, "old")
book = Book(path)
computer = Threads.@spawn book.rates
@test next_read() == "old"
waiter = Threads.@spawn book.rates              # blocks on the in-flight computation
handle = DynamicObjects.fetchproperty((value, status) -> value, book, :rates)
@test handle isa Pending
sleep(0.2)
book.refresh_named("new")
# Fetched while the retracted computation still runs: it waits for, or starts, a current one.
fetched = Threads.@spawn fetch(handle)
gate_open!("old")
@test fetch(computer) == "old"
@test next_read() == "new"
gate_open!("new")
@test fetch(waiter) == "new"
@test fetch(fetched) == "new"
@test book.rates == "new"
end

@testitem "invalidating from inside a computation of the same object" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
reset_gates!()
path = tempname(); write(path, "a")
book = Book(path)
gate_open!("a")
@test book.summary == "summary of a"
@test next_read() == "a"

# The aggregate's own computation clears `rates` and its dependents — itself included.
# It completes without deadlock and returns what it computed, but that value straddled
# the refresh, so it is not stored: the next read recomputes it from the new data.
gate_open!("b")
done = Threads.@spawn book.combined("b")
@test timedwait(() -> istaskdone(done), 10) === :ok
@test fetch(done) == "a+b"
@test next_read() == "b"
@test book.summary == "summary of b"
gate_open!("b")
@test book.combined("b") == "b+b"               # recomputed: "a+b" was not stored
@test next_read() == "b"

# A sibling mid-compute on another task when another computation invalidates.
for refresh in (:refresh_all, :refresh_named)
    reset_gates!()
    write(path, "old")
    book = Book(path)
    sibling = Threads.@spawn book.rates
    @test next_read() == "old"
    refresher = Threads.@spawn getproperty(book, refresh)("new")
    @test timedwait(() -> istaskdone(refresher), 10) === :ok
    gate_open!("old"); gate_open!("new")
    @test fetch(sibling) == "old"
    @test book.summary == "summary of new"
end

# Tracked input: notify_change! + sync! from inside a computation drops the dependents.
write(path, "t1")
book = Book(path)
@test book.tracked_summary == "tracked t1"
@test book.refresh_tracked("t2") == "t2"
@test book.tracked_summary == "tracked t2"
end

@testitem "an explicit disk entry is not published by a retracted computation" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
reset_gates!()
path = tempname(); write(path, "old")
cache_dir = mktempdir()
book = DiskBook(path, cache_dir)
entry = DynamicObjects.get_cache_path(book, :rates)
inflight = Threads.@spawn book.rates
@test next_read() == "old"
write(path, "new")
DynamicObjects.clear_cache!(book, :rates)
gate_open!("old")
@test fetch(inflight) == "old"
@test !isfile(entry)                            # the stale value never reached disk
gate_open!("new")
@test book.rates == "new"
@test isfile(entry)
# A later process (a new object over the same cache) reads the current entry.
@test DiskBook(path, cache_dir).rates == "new"
@test next_read() == "new"
end

@testitem "governed automatic storage skips a retracted computation" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
reset_gates!()
GOVERNED_BASE[] = mktempdir()
context = (; scope=:job, key=(; mount="/books", job=:one), retention=(; max_entries=1, ttl=60.0))
path = tempname(); write(path, "o")
book = GovernedBook(path)
entry = DynamicObjects.get_cache_path(book, :large, 1)
running = Threads.@spawn execute_materialization(context, book, :large, 1)
@test next_read() == "o"
write(path, "n")
invalidate!(book.large, 1)
gate_open!("o")
@test startswith(fetch(running), "oo")
@test !isfile(entry)
@test !isfile(entry * ".auto")
gate_open!("n")
@test startswith(execute_materialization(context, book, :large, 1), "nn")
@test isfile(entry)
@test isfile(entry * ".auto")
@test next_read() == "n"
end

@testitem "clear_mem_caches! keeps a @state computation in flight" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
reset_gates!()
path = tempname(); write(path, "s")
book = StateBook(path)
initializing = Threads.@spawn book.log
@test next_read() == "s"
clear_mem_caches!(book)
reader = Threads.@spawn book.log                # joins the kept computation
gate_open!("s"); gate_open!("s")                # a second initializer would not block
state = fetch(initializing)
@test fetch(reader) === state
@test book.log === state                        # stored: one state object, one init
@test next_read(1) === nothing                  # the initializer ran once
end

@testitem "waiters of a retracted computation re-resolve at the invalidation" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
# The retracted computation stays blocked until the end: its waiters, blocking ones and
# `fetch`es of a poll handle taken before, must not wait for it.
bare = (; access = b -> b.rates, cache = b -> getfield(b, :cache).cache, key = :rates,
          handle = b -> DynamicObjects.fetchproperty((value, status) -> value, b, :rates),
          old = "old", new = "new")
# `key` peeks at the subcache's in-flight latch, which is keyed by the memo key.
indexed = (; access = b -> b.chapter(1), cache = b -> b.chapter.cache, key = DynamicObjects._memo_key((1,), (;)),
             handle = b -> fetchindex((value, status) -> value, b.chapter, 1),
             old = "old1", new = "new1")
invalidations = (("clear_mem_caches!", b -> clear_mem_caches!(b), (bare, indexed)),
                 ("clear_cache!", b -> DynamicObjects.clear_cache!(b, :rates), (bare,)),
                 ("clear_cache! indexed", b -> DynamicObjects.clear_cache!(b, :chapter), (indexed,)),
                 ("invalidate!", b -> invalidate!(b.chapter, 1), (indexed,)))
for (label, invalidate, shapes) in invalidations, shape in shapes
    reset_gates!()
    path = tempname(); write(path, "old")
    book = Book(path)
    computer = Threads.@spawn shape.access(book)
    @test next_read() == "old"
    waiter = Threads.@spawn shape.access(book)
    handle = shape.handle(book)
    @test handle isa Pending
    fetched = Threads.@spawn fetch(handle)
    @test timedwait(() -> waiting(shape.cache(book), shape.key) == 2, 10) === :ok
    write(path, "new")
    invalidate(book)
    # Re-resolving, the waiters start one current computation and share it; nothing else
    # accesses the property meanwhile, and the retracted computation is still blocked.
    @test next_read() == "new"
    gate_open!("new")
    released = timedwait(() -> istaskdone(waiter) && istaskdone(fetched), 10) === :ok
    @test released
    @test !istaskdone(computer)
    # The object reads the value they computed.
    released && @test shape.access(book) == shape.new
    @test next_read(0.5) === nothing
    # Unblock everything, including what a regression would leave waiting.
    gate_open!("old"); gate_open!("new"); gate_open!("new")
    @test fetch(computer) == shape.old
    @test fetch(waiter) == shape.new
    @test fetch(fetched) == shape.new
    @test shape.access(book) == shape.new          # the retracted computation never landed
end
end

@testitem "clear_mem_caches! keeps every holder of an indexed subcache attached" setup=[InflightInvalidationFixtures] begin
using DynamicObjects
reset_gates!()
path = tempname(); write(path, "a")
book = Book(path)
held = book.chapter                             # a destructured wrapper handle
for content in ("a", "b", "c")
    write(path, content)
    clear_mem_caches!(book)
    gate_open!(content); gate_open!(content)    # a detached subcache would compute twice
    @test held(1) == content * "1"
    @test next_read() == content
    # The object and the handle share one computation per clear, however many clears
    # came before.
    @test book.chapter(1) == content * "1"
    @test next_read(0.5) === nothing
end
end
