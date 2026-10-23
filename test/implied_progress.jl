using TestItemRunner

# Progress nesting is IMPLIED (decision `0yvb74c`): every property read written in an
# unmarked body — a sibling, or another object's property, through any receiver —
# shows the computation it starts or waits for under the reading body's node, with no
# `@progress` / `@fetch!` marker anywhere. The computation keeps its own place in its
# owner's tree; once it finishes it leaves the reader again (a failed one stays). A read
# inside an ordinary helper function is the helper's business and stays flat.
#
# Explicit threading (`@fetch!`, an `@progress` body's sibling reads) is the same blocking
# read computed inline, but its node stays under the reader and hits show "(cached)".
#
# Nesting is observed while the work runs: each fixture parks on a gate the test opens.
@testmodule ImpliedProgressFixtures begin
using DynamicObjects
import DynamicObjects.Treebars
using DynamicObjects.Treebars: render_text, @progress
export render_text, @progress, rows, depth_of, labels, gate, release!, settles, node_of, poller,
    IPChain, IPInner, IPOuter, IPDestructured, IPViaHelper, IPWithIP, IPBoom, IPKw, IPSpawned,
    IPRewriteRuntime, REWRITE_CALLS, IPReread, REREAD_CALLS, IPMarked, IPLocked,
    IPUnderLock, IPFetchLocked, IPFetchUnderLock, IPTaskOf, IPFetchTask, IPGatedSource,
    IPFetching, IPPopulation, IPModel, IPRoute, IPRemountRoot, IPPhased, IPLoops, IPLabelled

const _STATES = ('✓', '✗', '▶', '·')

"Rendered rows as `label => depth` pairs, in render order, durations stripped."
function rows(tree)
    out = Pair{String,Int}[]
    for line in split(render_text(tree), '\n')
        cs = collect(line)
        i = findfirst(c -> c in _STATES, cs)
        isnothing(i) && continue
        label = strip(join(cs[i+1:end]))
        label = replace(label, r"\s*\[[^\]]*\]$" => "")
        push!(out, String(label) => (i - 1) ÷ 3)
    end
    out
end
labels(tree) = first.(rows(tree))
function depth_of(tree, label)
    for (l, d) in rows(tree)
        l == label && return d
    end
    nothing
end

const GATES = Dict{Symbol,Base.Event}()
const GATES_LOCK = ReentrantLock()
gate(k::Symbol) = wait(lock(() -> get!(Base.Event, GATES, k), GATES_LOCK))
release!(k::Symbol) = notify(lock(() -> get!(Base.Event, GATES, k), GATES_LOCK))
settles(f, seconds=20) = timedwait(f, seconds; pollint=0.01) === :ok

"The progress node of bare property `name`'s computation on `o`, once one started."
node_of(o, name::Symbol) = DynamicObjects._status_of(getfield(o, :cache).cache, name)
poller() = Treebars.initialize_progress!(:state; description="poller")

# ── Fixtures — no progress marker on any LHS unless the test is about markers ──

@dynamicstruct struct IPChain
    tag::Symbol
    "Load raw data"
    raw = (gate(tag); [1, 2, 3])
    "Summarise"
    summarised = sum(raw)
    "Top level"
    top = summarised + 1
end

@dynamicstruct struct IPInner
    tag::Symbol
    "Inner work"
    work = (gate(tag); 9)
end

# Another object held in a field: `inner.work` nests like a sibling.
@dynamicstruct struct IPOuter
    inner
    "Combined"
    combined = inner.work + 1
end

# A named destructure in a declaration or a binding header reads like `inner.work`
# (snag `local-namedtuple-c640cee8`).
@dynamicstruct struct IPDestructured
    inner
    "Declared"
    declared = begin
        local (; work) = inner
        work + 1
    end
    "Let-bound"
    let_bound = let (; work) = inner
        work + 2
    end
    "Looped"
    looped = begin
        acc = 0
        for (; work) in (inner,)
            acc += work + 3
        end
        acc
    end
    "Comprehended"
    comprehended = only([work + 4 for (; work) in (inner,) if work > 0])
end

# The read happens inside an ordinary helper, which the rewrite never sees.
ip_helper(x) = x.work * 10
@dynamicstruct struct IPViaHelper
    inner
    "Through a helper"
    indirect = ip_helper(inner)
end

@dynamicstruct struct IPWithIP
    tag::Symbol
    "Per-index work"
    item(i) = (i == 2 && gate(tag); 10i)
    "All items"
    total = sum(item(i) for i in 1:3)
end

@dynamicstruct struct IPBoom
    n::Int
    "Explodes"
    bad = error("boom")
    "Wraps"
    wrapper = bad + 1
end

@dynamicstruct struct IPKw
    tag::Symbol
    "Scaled"
    scaled(i; factor = 2) = (gate(tag); i * factor)
    "Uses kwargs"
    uses = scaled(3; factor = 4)
end

# A read in a spawned task captures the body's node lexically.
@dynamicstruct struct IPSpawned
    tag::Symbol
    "Spawned child"
    child = (gate(tag); 4)
    "Spawned caller"
    parent = fetch(Threads.@spawn child)
end

# Source forms whose surrounding macros or lowering could obscure a property call.
const REWRITE_CALLS = Threads.Atomic{Int}(0)
@dynamicstruct struct IPRewriteRuntime
    n::Int
    "Counted indexed work"
    item(i) = (Threads.atomic_add!(REWRITE_CALLS, 1); i + n)
    "Explicitly memoized pair"
    memo_pair = (@memo! item(1), @memo! item(1))
    "Explicitly fresh pair"
    fresh_pair = (@fresh item(2), @fresh item(2))
    "Broadcasted pair"
    broadcasted = item.([3, 4])
    "Function-taking indexed work"
    withfn(f, x) = f(x) + n
    "Do-block caller"
    do_value = withfn(3) do x
        2x
    end
    "Destructured"
    destructured = begin
        (; memo_pair, broadcasted) = __self__
        first(memo_pair) + last(broadcasted)
    end
    "Dot macro"
    dotted = @. broadcasted + n
end

const REREAD_CALLS = Threads.Atomic{Int}(0)
@dynamicstruct struct IPReread
    n::Int
    "Base"
    base = (Threads.atomic_add!(REREAD_CALLS, 1); n)
    "First reader"
    first = base + 1
    "Second reader"
    second = base + 2
end

# An explicit marker still owns its body: `@fetch!` attaches what it reads for good.
@dynamicstruct struct IPMarked
    n::Int
    "Marked leaf"
    leaf = n * 2
    "Marked root"
    @fetch! root = leaf + 1
end

# A threaded read computes inline: a lock its body holds is still held by the reader.
const IP_LOCK = ReentrantLock()
@dynamicstruct struct IPLocked
    n::Int
    "Locked value"
    locked() = lock(() -> 42, IP_LOCK)
end
@dynamicstruct struct IPUnderLock
    other
    "Reads under the lock"
    value = lock(IP_LOCK) do
        other.locked()
    end
end

# Explicit threading (`@fetch!`, an `@progress` body's sibling reads) computes inline too
# (todo `1o2uih6`). Its own lock, so a regression fails these items without hanging others.
const IP_FETCH_LOCK = ReentrantLock()
@dynamicstruct struct IPFetchLocked
    n::Int
    "Locked entry"
    entry(k) = lock(() -> 10k, IP_FETCH_LOCK)
    "Locked bare"
    bare = lock(() -> n, IP_FETCH_LOCK)
end
@dynamicstruct struct IPFetchUnderLock
    other
    entry_read() = lock(() -> @fetch!(__status__, other.entry(1)), IP_FETCH_LOCK)
    bare_read = lock(() -> @fetch!(__status__, other.bare), IP_FETCH_LOCK)
    "Locked sibling entry"
    sibling(k) = lock(() -> k + 100, IP_FETCH_LOCK)
    "Locked sibling"
    sibling_bare = lock(() -> 200, IP_FETCH_LOCK)
    @progress marked_entry_read = lock(() -> sibling(1), IP_FETCH_LOCK)
    @progress marked_bare_read = lock(() -> sibling_bare, IP_FETCH_LOCK)
end

# Each computation reports the task it ran on.
@dynamicstruct struct IPTaskOf
    n::Int
    "Entry task"
    entry(k) = current_task()
    "Bare task"
    bare = current_task()
end
@dynamicstruct struct IPFetchTask
    other
    entry_read() = (@fetch!(__status__, other.entry(1)), current_task())
    bare_read = (@fetch!(__status__, other.bare), current_task())
    "Sibling entry task"
    sibling(k) = current_task()
    "Sibling task"
    sibling_bare = current_task()
    @progress marked_entry_read = (sibling(1), current_task())
    @progress marked_bare_read = (sibling_bare, current_task())
end

@dynamicstruct struct IPGatedSource
    tag::Symbol
    "Gated work"
    work = (gate(tag); 9)
    "Gated entry"
    entry(k) = (gate(tag); 10k)
end
@dynamicstruct struct IPFetching
    other
    "Fetching bare"
    bare_read = @fetch!(__status__, other.work)
    "Fetching entry"
    entry_read = @fetch!(__status__, other.entry(2))
end

# The snag's shape (`awaited-compute-bde2f24d`): a route reads another object's
# `@queued` fit, whose `@progress` body reads a third object's `@queued` fit.
@dynamicstruct struct IPPopulation
    tag::Symbol
    "Population fit"
    @queued @progress fit() = begin
        @progress "population phase"
        gate(tag)
        :population
    end
end
@dynamicstruct struct IPModel
    population
    "Model fit"
    @queued @progress fit() = begin
        @progress "model stage 1"
        (:model, population.fit())
    end
end
@dynamicstruct struct IPRoute
    model
    "Route"
    route() = (model.fit(), :viewed)
end

# Inline phases need no marker on the property (decision `0r44qxt`); both the imported
# and the module-qualified spelling are Treebars' source surface.
@dynamicstruct struct IPPhased
    tag::Symbol
    "Two phases"
    staged = begin
        @progress "first"
        x = tag === :never ? 0 : 1
        Treebars.@progress "second"
        gate(tag)
        x + 1
    end
end

# Loops stay plain unless counted explicitly.
@dynamicstruct struct IPLoops
    tag::Symbol
    "Plain loop"
    plain = begin
        acc = 0
        for i in 1:3
            acc += i
        end
        gate(tag)
        acc
    end
    "Counted loop"
    counted = begin
        acc = 0
        @progress "items" for i in 1:3
            acc += i
        end
        acc
    end
end

# A read in an `@progress` label is a read like any other (snag `inline-phase-lab-c8aa11da`):
# it nests under the node the labelled node is created under.
@dynamicstruct struct IPLabelled
    tag::Symbol
    inner
    "Label source"
    title(x) = (gate(tag); "T$x")
    "Phase label"
    phase_label = begin
        @progress "phase $(title(1))"
        1
    end
    "Loop-body phase label"
    loop_phase_label = begin
        acc = 0
        for i in 1:2
            @progress "phase $(title(i))"
            acc += i
        end
        acc
    end
    "Block label"
    block_label = begin
        v = @progress "block $(title(3))" begin
            3
        end
        v
    end
    "Loop label"
    loop_label = begin
        acc = 0
        @progress "items $(title(4))" for i in 1:2
            acc += i
        end
        acc
    end
    "Marked label"
    @progress marked_label = begin
        @progress "phase $(title(5))"
        5
    end
    "Marked other label"
    @progress marked_other_label = begin
        @progress "phase $(inner.work)"
        6
    end
end

# Request views of a retained root (HTMXObjects' `RootProvider`).
@dynamicstruct struct IPRemountRoot
    inner
    __prefix__ = ""
    "Routed"
    routed() = (inner.work, __prefix__)
end
end

@testitem "implied progress: sibling reads nest under the reading property while they run" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
c = IPChain(:chain)
t = Threads.@spawn c.top
@test settles(() -> node_of(c, :raw) !== nothing)
top = node_of(c, :top)
@test settles(() -> depth_of(top, "Load raw data") == 2)
@test depth_of(top, "Top level") == 0
@test depth_of(top, "Summarise") == 1
# Each computation keeps its place in the owner's tree, rendered once.
@test count(==("Load raw data"), labels(c.__status__)) == 1
release!(:chain)
@test fetch(t) == 7
# Finished work leaves the reader again.
@test labels(top) == ["Top level"]
end

@testitem "implied progress: another object's property nests like a sibling" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
o = IPOuter(IPInner(:outer))
t = Threads.@spawn o.combined
@test settles(() -> node_of(o.inner, :work) !== nothing)
@test settles(() -> depth_of(node_of(o, :combined), "Inner work") == 1)
@test "Inner work" in labels(o.inner.__status__)
release!(:outer)
@test fetch(t) == 10
end

@testitem "implied progress: a named destructure nests in a declaration or a binding header" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
for (name, value) in ((:declared, 10), (:let_bound, 11), (:looped, 12), (:comprehended, 13))
    tag = Symbol(:destructured_, name)
    d = IPDestructured(IPInner(tag))
    t = Threads.@spawn getproperty(d, name)
    @test settles(() -> node_of(d.inner, :work) !== nothing)
    @test settles(() -> depth_of(node_of(d, name), "Inner work") == 1)
    release!(tag)
    @test fetch(t) == value
end
end

@testitem "implied progress: a read inside a helper stays flat" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
v = IPViaHelper(IPInner(:helper))
t = Threads.@spawn v.indirect
@test settles(() -> node_of(v.inner, :work) !== nothing)
@test labels(node_of(v, :indirect)) == ["Through a helper"]
@test "Inner work" in labels(v.inner.__status__)
release!(:helper)
@test fetch(t) == 90
end

@testitem "implied progress: indexed reads and keyword arguments nest" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
w = IPWithIP(:items)
t = Threads.@spawn w.total
@test settles(() -> DynamicObjects.getstatus(w.item, 2) !== nothing)
@test settles(() -> depth_of(node_of(w, :total), "Per-index work") == 1)
release!(:items)
@test fetch(t) == 60

k = IPKw(:kw)
t = Threads.@spawn k.uses
@test settles(() -> DynamicObjects.getstatus(k.scaled, 3; factor = 4) !== nothing)
@test settles(() -> depth_of(node_of(k, :uses), "Scaled") == 1)
release!(:kw)
@test fetch(t) == 12
end

@testitem "implied progress: a spawned read captures the body's node" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
s = IPSpawned(:spawned)
t = Threads.@spawn s.parent
@test settles(() -> node_of(s, :child) !== nothing)
@test settles(() -> depth_of(node_of(s, :parent), "Spawned child") == 1)
release!(:spawned)
@test fetch(t) == 4
end

@testitem "implied progress: a failure stays under its reader" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
b = IPBoom(1)
@test_throws PropertyComputationError b.wrapper
w = node_of(b, :wrapper)
@test ("Wraps" => 0) in rows(w)
@test ("Explodes" => 1) in rows(w)
@test occursin("✗ Explodes", render_text(w))
end

@testitem "implied progress: a cache hit links nothing" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
REREAD_CALLS[] = 0
r = IPReread(3)
@test r.first == 4
@test r.second == 5
@test REREAD_CALLS[] == 1
@test labels(node_of(r, :second)) == ["Second reader"]
@test !occursin("(cached)", render_text(r.__status__))
end

@testitem "implied progress: memo, fresh, broadcast, do, destructuring and @. keep their meaning" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
REWRITE_CALLS[] = 0
r = IPRewriteRuntime(10)
@test r.memo_pair == (11, 11)
@test REWRITE_CALLS[] == 1
@test r.fresh_pair == (12, 12)
@test REWRITE_CALLS[] == 3
@test r.broadcasted == [13, 14]
@test REWRITE_CALLS[] == 5
@test r.do_value == 16
@test r.destructured == 25
@test r.dotted == [23, 24]
end

@testitem "implied progress: an explicit marker still owns its body" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
m = IPMarked(3)
@test m.root == 7
# `@fetch!` attaches what it read for good, as before.
@test depth_of(node_of(m, :root), "Marked leaf") == 1
end

@testitem "implied progress: __status__ = nothing stays silent" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
release!(:silent)
c = IPChain(:silent; __status__ = nothing)
@test c.top == 7
@test isnothing(c.__status__)
end

@testitem "implied progress: a threaded read under the reader's lock does not deadlock" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
u = IPUnderLock(IPLocked(1))
t = Threads.@spawn u.value
@test settles(() -> istaskdone(t), 10)
@test fetch(t) == 42
end

@testitem "explicit threading: @fetch! and @progress reads under the reader's lock do not deadlock" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
for (read, expected) in ((u -> u.entry_read(), 10), (u -> u.bare_read, 3),
                         (u -> u.marked_entry_read, 101), (u -> u.marked_bare_read, 200))
    u = IPFetchUnderLock(IPFetchLocked(3))
    t = Threads.@spawn read(u)
    # Never `fetch` a task that did not finish: it would hang the suite instead of failing.
    @test settles(() -> istaskdone(t), 10)
    istaskdone(t) && @test fetch(t) == expected
end
end

@testitem "explicit threading: @fetch! and @progress reads compute on the reader's task" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
u = IPFetchTask(IPTaskOf(1))
for (computed, reader) in (u.entry_read(), u.bare_read, u.marked_entry_read, u.marked_bare_read)
    @test computed === reader
end
end

@testitem "explicit threading: @fetch! keeps the read's node under the reader" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
src = IPGatedSource(:fetched)
r = IPFetching(src)
tb = Threads.@spawn r.bare_read
te = Threads.@spawn r.entry_read
@test settles(() -> depth_of(r.__status__, "Gated work") !== nothing &&
                    depth_of(r.__status__, "Gated entry") !== nothing)
@test depth_of(r.__status__, "Gated work") == depth_of(r.__status__, "Fetching bare") + 1
@test depth_of(r.__status__, "Gated entry") == depth_of(r.__status__, "Fetching entry") + 1
# Each computation keeps its place in its owner's tree.
@test "Gated work" in labels(src.__status__)
@test "Gated entry" in labels(src.__status__)
release!(:fetched)
@test settles(() -> istaskdone(tb) && istaskdone(te))
@test fetch(tb) == 9
@test fetch(te) == 20
# Unlike an implied read's link, the finished node stays under the reader. (A finished
# subtree renders only from its own node.)
@test labels(node_of(r, :bare_read)) == ["Fetching bare", "Gated work"]
@test labels(node_of(r, :entry_read)) == ["Fetching entry", "Gated entry"]
# A hit shows the entry's finished node under the reader, relabelled.
r2 = IPFetching(src)
@test r2.bare_read == 9
@test r2.entry_read == 20
@test labels(node_of(r2, :bare_read)) == ["Fetching bare", "Gated work (cached)"]
@test labels(node_of(r2, :entry_read)) == ["Fetching entry", "Gated entry (cached)"]
end

@testitem "implied progress: a route shows queued fits read without @fetch!" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
DynamicObjects.configure_queue!(; max_running=4)
try
    app = IPRoute(IPModel(IPPopulation(:route)))
    p = poller()
    rv = fetchindex!(p, app.route; fetch=identity)
    @test rv isa DynamicObjects.Pending
    @test settles(() -> "population phase" in labels(p))
    route = depth_of(p, "Route")
    @test depth_of(p, "Model fit") == route + 1
    # The read inside the marked fit nests under the phase it runs in.
    @test depth_of(p, "model stage 1") == route + 2
    @test depth_of(p, "Population fit") == route + 3
    # Each fit keeps its place in its owner's tree.
    @test "Model fit" in labels(app.model.__status__)
    @test "Population fit" in labels(app.model.population.__status__)
    release!(:route)
    @test fetch(rv) == ((:model, :population), :viewed)
finally
    DynamicObjects.configure_queue!(; max_running=0)
end
end

@testitem "implied progress: a remount view's read nests" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
root = IPRemountRoot(IPInner(:remount))
view = DynamicObjects.remount(root; __prefix__ = "/v")
p = poller()
rv = fetchindex!(p, view.routed; fetch=identity)
@test settles(() -> node_of(root.inner, :work) !== nothing)
@test settles(() -> depth_of(p, "Inner work") == depth_of(p, "Routed") + 1)
release!(:remount)
@test fetch(rv) == (9, "/v")
end

@testitem "implied progress: the rewrite preserves syntax roles" tags=[:progress] begin
using DynamicObjects
const readref = GlobalRef(DynamicObjects, :_read_threaded)
const callref = GlobalRef(DynamicObjects, :_call_threaded)
rw(ex, self=true) = DynamicObjects._implied_progress_rewrite(:p, ex, self)
count_ref(x, target) = x == target ? 1 :
    x isa Expr ? sum(a -> count_ref(a, target), x.args; init=0) : 0

# A foreign call stays a foreign call; its property-valued argument is read through.
foreign = rw(:(sum(obj.y)))
@test foreign.args[1] === :sum
@test count_ref(foreign, readref) == 1

# A property-rooted call is the only call form routed through `_call_threaded`, and the
# callee `obj.ip` itself stays a plain access.
ipcall = rw(:(obj.ip(x; k = other.y)))
@test ipcall.args[1] == callref
@test any(a -> Meta.isexpr(a, :parameters), ipcall.args)
@test count_ref(ipcall, readref) == 1

# Assignment targets, quoted code and type positions are syntax, not evaluations.
assignment_src = :(obj.y = rhs.z)
assignment = rw(assignment_src)
@test assignment.args[1] == assignment_src.args[1]
@test assignment.args[2].args[1] == readref
quoted = Expr(:quote, :(obj.y))
@test rw(quoted) == quoted
typed_src = :(obj.y::M.T)
typed = rw(typed_src)
@test typed.args[1].args[1] == readref
@test typed.args[2] == typed_src.args[2]

# Macros: ordinary-code macros are walked, others are left as written.
@test count_ref(rw(:(@views obj.y[1:2])), readref) == 1
dot_src = :(@. obj.y + 1)
@test rw(dot_src) == dot_src
ccall_src = :(@ccall lib.f(x::Int)::Int)
@test rw(ccall_src) == ccall_src

# Broadcast, do-block, keyword shorthand and destructuring stay valid Julia.
broadcasted = rw(:(obj.ip.(xs)))
@test broadcasted.head === :.
@test broadcasted.args[1] == callref
doblock = rw(:(obj.ip(xs) do x
    x.y
end))
@test doblock.head === :call
@test doblock.args[1] == callref
shorthand = rw(Expr(:call, :f, Expr(:parameters, :(obj.y))))
params = only(a for a in shorthand.args if Meta.isexpr(a, :parameters))
@test Meta.isexpr(only(params.args), :kw)
@test count_ref(rw(:((; a, b) = obj)), readref) == 2
# A named destructure in a declaration or a binding header reads through too, and the
# result still lowers (snag `local-namedtuple-c640cee8`: `local begin … end` did not).
lowers(ex) = !Meta.isexpr(Meta.lower(@__MODULE__, :((obj, objs) -> $ex)), :error)
for src in (:(local (; a, b) = obj), :(global (; a, b) = obj), :(let (; a, b) = obj; a end),
            :(for (; a, b) in objs; end), :([a for (; a, b) in objs if b > 0]))
    @test lowers(src)
    @test count_ref(rw(src), readref) == 2
    @test lowers(rw(src))
end

# Inside an `@progress` body only reads on other objects are rewritten; `__self__`
# reads are left to the marker's own threading.
@test rw(:(__self__.y), false) == :(__self__.y)
@test count_ref(rw(:(__self__.ip(other.y)), false), readref) == 1
@test rw(:(__self__.ip(1)), false).args[1] == :(__self__.ip)
@test rw(:(other.ip(1)), false).args[1] == callref
end

@testitem "implied progress: inline phases need no marker on the property" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
p = IPPhased(:phased)
t = Threads.@spawn p.staged
@test settles(() -> "second" in labels(something(node_of(p, :staged), poller())))
staged = node_of(p, :staged)
@test depth_of(staged, "first") == 1
@test depth_of(staged, "second") == 1
@test occursin("▶ second", render_text(staged))
release!(:phased)
@test fetch(t) == 2
@test occursin("✓ second", render_text(staged))
end

@testitem "implied progress: loops stay uncounted unless marked" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
l = IPLoops(:loops)
t = Threads.@spawn l.plain
@test settles(() -> node_of(l, :plain) !== nothing)
@test labels(node_of(l, :plain)) == ["Plain loop"]
release!(:loops)
@test fetch(t) == 6
@test labels(node_of(l, :plain)) == ["Plain loop"]
@test l.counted == 6
@test "items (3/3)" in labels(node_of(l, :counted))
end

@testitem "implied progress: a read in an @progress label nests and fills the label" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
for (name, value, source, label) in (
        (:phase_label, 1, "Label source", "phase T1"),
        (:loop_phase_label, 3, "Label source", nothing),  # its phases leave with their iteration
        (:block_label, 3, "Label source", "block T3"),
        (:loop_label, 3, "Label source", "items T4 (2/2)"),
        (:marked_label, 5, "Label source", "phase T5"),
        (:marked_other_label, 6, "Inner work", "phase 9"))
    tag = Symbol(:labelled_, name)
    o = IPLabelled(tag, IPInner(tag))
    t = Threads.@spawn getproperty(o, name)
    @test settles(() -> (n = node_of(o, name); n !== nothing && depth_of(n, source) == 1))
    release!(tag)
    @test settles(() -> istaskdone(t), 10)
    istaskdone(t) && @test fetch(t) == value
    isnothing(label) || @test label in labels(node_of(o, name))
end
end
