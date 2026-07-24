using TestItemRunner

# Progress threading is IMPLIED: every ordinary property and indexed-property
# evaluation nests under whoever asked for it, with NO `@progress` / `@fetch!`
# marker on any LHS and none at any call site. The only user-facing progress
# metadata is the DOCSTRING — documented properties get a labelled row,
# undocumented ones stay bare wrappers the renderer inlines away.
#
# Nothing in the fixtures below carries a progress macro. That is the point of
# the file: if any assertion here needs one added to pass, the feature is gone.
@testmodule ImpliedProgressFixtures begin
using DynamicObjects
import DynamicObjects.Treebars
using DynamicObjects.Treebars: render_text, @progress
export render_text, @progress, rows, depth_of, labels,
    IPApp, IPInner, IPOuter, IPViaForeign, IPWithIP, IPBoom, IPPhased,
    IPQualifiedPhased, IPKw, IPSpawned, IPRewriteRuntime, REWRITE_CALLS,
    IPSlow, IPUndocumented, IPMarked

# ── Rendered-tree helpers ────────────────────────────────────────────────────
# `render_text` is the offline preview of what the browser shows, and it shares
# the HTML renderer's display rules — so asserting on it is asserting on what a
# user would see, not on an internal structure that might never render.
const _STATES = ('✓', '✗', '▶', '·')

"Rendered rows as `label => depth` pairs, in render order, durations stripped."
function rows(tree)
    out = Pair{String,Int}[]
    for line in split(render_text(tree), '\n')
        cs = collect(line)
        i = findfirst(c -> c in _STATES, cs)
        isnothing(i) && continue
        label = strip(join(cs[i+1:end]))
        label = replace(label, r"\s*\[[^\]]*\]$" => "")   # drop the duration
        push!(out, String(label) => (i - 1) ÷ 3)
    end
    out
end

labels(tree) = first.(rows(tree))

"Depth of the first row whose label is exactly `label`; `nothing` if absent."
function depth_of(tree, label)
    for (l, d) in rows(tree)
        l == label && return d
    end
    nothing
end

# ── Fixtures — not one progress macro on any LHS ─────────────────────────────

# Plain sibling chain: top → summarised → raw.
@dynamicstruct struct IPApp
    n::Int
    """Load raw data"""
    raw = (sleep(0.02); collect(1:n))
    """Summarise"""
    summarised = sum(raw)
    """Top level"""
    top = summarised + 1
end

@dynamicstruct struct IPInner
    k::Int
    """Inner work"""
    work = (sleep(0.01); k^2)
end

# Nesting THROUGH another DynamicObject held in a property.
@dynamicstruct struct IPOuter
    k::Int
    inner = IPInner(k)
    """Combined"""
    combined = inner.work + 1
end

# The property read happens inside an ordinary function. The deliberately
# property-scoped rewrite cannot see through that foreign frame; `@PROGRESS`
# remains the explicit escape hatch for code that wants exhaustive call
# instrumentation.
ip_helper(x) = x.work * 10

@dynamicstruct struct IPViaForeign
    k::Int
    inner = IPInner(k)
    """Through a foreign function"""
    indirect = ip_helper(inner)
end

@dynamicstruct struct IPWithIP
    n::Int
    """Per-index work"""
    item(i) = (sleep(0.01); i * n)
    """All items"""
    total = sum(item(i) for i in 1:3)
end

@dynamicstruct struct IPBoom
    n::Int
    """Explodes"""
    bad = error("boom")
    """Wraps"""
    wrapper = bad + 1
end

# The one remaining escape hatch: inline phase markers, still with NO marker on
# the LHS. Both the imported bare form and the module-qualified form are part of
# Treebars' supported source surface.
@dynamicstruct struct IPPhased
    n::Int
    """Two phases"""
    staged = begin
        @progress "first"
        x = (sleep(0.01); n + 1)
        @progress "second"
        (sleep(0.01); x * 2)
    end
end

@dynamicstruct struct IPQualifiedPhased
    n::Int
    """Qualified phases"""
    staged = begin
        Treebars.@progress "qual-first"
        x = (sleep(0.01); n + 1)
        Treebars.@progress "qual-second"
        (sleep(0.01); x * 2)
    end
end

@dynamicstruct struct IPKw
    n::Int
    """Scaled"""
    scaled(i; factor = 2) = (sleep(0.01); i * n * factor)
    """Uses kwargs"""
    uses = scaled(3; factor = 4)
end

# A source-visible property read inside a user-spawned task captures the
# explicit lexical progress node in the closure. No task-local inheritance is
# involved, and concurrent objects cannot overwrite one another's parent.
@dynamicstruct struct IPSpawned
    n::Int
    """Spawned child"""
    child = (sleep(0.02); 2n)
    """Spawned caller"""
    parent = fetch(Threads.@spawn child)
end

# Exercise the source forms whose surrounding macros/lowering can otherwise
# obscure a property-rooted call. The atomic counter verifies caching semantics
# as well as the result values.
const REWRITE_CALLS = Threads.Atomic{Int}(0)

@dynamicstruct struct IPRewriteRuntime
    n::Int
    """Counted indexed work"""
    item(i) = (Threads.atomic_add!(REWRITE_CALLS, 1); i + n)
    """Explicitly memoized pair"""
    memo_pair = (@memo! item(1), @memo! item(1))
    """Explicitly fresh pair"""
    fresh_pair = (@fresh item(2), @fresh item(2))
    """Broadcasted pair"""
    broadcasted = item.([3, 4])
    """Function-taking indexed work"""
    withfn(f, x) = f(x) + n
    """Do-block caller"""
    do_value = withfn(3) do x
        2x
    end
end

# Long enough to sample the tree mid-flight from another task.
@dynamicstruct struct IPSlow
    n::Int
    """Step A"""
    a = (sleep(0.3); n)
    """Step B"""
    b = (sleep(0.3); a + 1)
    """Whole job"""
    job = b * 2
end

# No docstrings anywhere: the tree must stay empty of rows.
@dynamicstruct struct IPUndocumented
    n::Int
    leaf = (sleep(0.01); n * 2)
    root = leaf + 1
end

# The explicit markers remain supported overrides.
@dynamicstruct struct IPMarked
    n::Int
    """Marked leaf"""
    leaf = (sleep(0.01); n * 2)
    """Marked root"""
    @fetch! root = leaf + 1
end
end

@testitem "implied progress: plain sibling nesting" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
a = IPApp(3)
@test a.top == 7
ls = labels(a.__status__)
@test "Top level" in ls
@test "Summarise" in ls
@test "Load raw data" in ls
# Each is strictly deeper than the one that asked for it — the whole point.
@test depth_of(a.__status__, "Summarise") > depth_of(a.__status__, "Top level")
@test depth_of(a.__status__, "Load raw data") > depth_of(a.__status__, "Summarise")
end

@testitem "implied progress: nesting through a nested DynamicObject" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
o = IPOuter(4)
@test o.combined == 17
# `inner` is a whole other object with its own `__status__` root; the read still
# lands under the property that asked for it.
@test depth_of(o.__status__, "Inner work") > depth_of(o.__status__, "Combined")
end

@testitem "implied progress: property scope stops at a foreign function" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
vf = IPViaForeign(3)
@test vf.indirect == 90
# `ip_helper` is an ordinary function — the generated property body contains
# no `inner.work` syntax to rewrite. Its work stays on the nested object's own
# tree rather than leaking through task-local state into the caller's tree.
@test depth_of(vf.__status__, "Inner work") === nothing
@test depth_of(vf.inner.__status__, "Inner work") !== nothing
end

@testitem "implied progress: indexed properties nest per index" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
w = IPWithIP(2)
@test w.total == 12
rs = rows(w.__status__)
total_depth = depth_of(w.__status__, "All items")
items = [d for (l, d) in rs if l == "Per-index work"]
@test length(items) == 3                       # one child per index
@test all(>(total_depth), items)
end

@testitem "implied progress: completion leaves the tree standing" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
a = IPApp(2)
a.top
txt = render_text(a.__status__)
# Every node finished, and none vanished. The property-scoped fetch path creates
# a cold child directly beneath the explicit caller node; warm shared subtrees
# are attached there by `_attach_fetched!`.
@test occursin("✓ Top level", txt)
@test occursin("✓ Summarise", txt)
@test occursin("✓ Load raw data", txt)
# The object ROOT stays `▶` — it is a live root that is never finalized. Every
# property node beneath it is finished.
@test count(==('▶'), txt) == 1
end

@testitem "implied progress: nests while still running" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
sl = IPSlow(1)
t = Threads.@spawn sl.job
sleep(0.45)
mid = rows(sl.__status__)
@test !isempty(mid)
@test any(((l, _),) -> l == "Whole job", mid)
# The in-flight shape is what a polling web route renders.
@test occursin("▶ Whole job", render_text(sl.__status__))
@test fetch(t) == 4
@test depth_of(sl.__status__, "Step A") > depth_of(sl.__status__, "Step B") >
    depth_of(sl.__status__, "Whole job")
end

@testitem "implied progress: a failure nests under its caller" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
using DynamicObjects: PropertyComputationError
bo = IPBoom(1)
@test_throws PropertyComputationError bo.wrapper
txt = render_text(bo.__status__)
@test occursin("✗ Wraps", txt)
@test occursin("✗ Explodes", txt)
# The failing property must render UNDER the one that called it, not beside it.
@test depth_of(bo.__status__, "Explodes") > depth_of(bo.__status__, "Wraps")
end

@testitem "implied progress: a cache hit adds no second node" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
a = IPApp(3)
a.top                       # computes raw → summarised → top
before = rows(a.__status__)
a.raw                       # already cached; re-read from top level
a.summarised
after = rows(a.__status__)
# Cached work is shown once, where it was actually done — a hit neither recomputes
# nor duplicates the row.
@test after == before
@test count(((l, _),) -> l == "Load raw data", after) == 1
end

@testitem "implied progress: __status__ = nothing stays silent" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
q = IPApp(3; __status__ = nothing)
@test q.top == 7            # value path unaffected
@test isnothing(q.__status__)
@test render_text(q.__status__) == "(no progress tree)"
end

@testitem "implied progress: undocumented properties add no rows" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
u = IPUndocumented(3)
@test u.root == 7
# The docstring is the opt-in. Without one the node is a bare wrapper, which the
# renderer inlines away — so implied progress costs an undocumented struct
# nothing visible.
@test all(isempty, labels(u.__status__))
end

@testitem "implied progress: inline @progress phases need no LHS marker" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
p = IPPhased(5)
@test p.staged == 12
staged = depth_of(p.__status__, "Two phases")
@test depth_of(p.__status__, "first") > staged
@test depth_of(p.__status__, "second") > staged
end

@testitem "implied progress: qualified inline phases need no LHS marker" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
p = IPQualifiedPhased(5)
@test p.staged == 12
staged = depth_of(p.__status__, "Qualified phases")
@test depth_of(p.__status__, "qual-first") > staged
@test depth_of(p.__status__, "qual-second") > staged
end

@testitem "implied progress: keyword arguments nest" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
k = IPKw(2)
@test k.uses == 24
@test depth_of(k.__status__, "Scaled") > depth_of(k.__status__, "Uses kwargs")
end

@testitem "implied progress: spawned work captures an explicit parent" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
a = IPSpawned(2)
b = IPSpawned(7)
ta = Threads.@spawn a.parent
tb = Threads.@spawn b.parent
@test fetch(ta) == 4
@test fetch(tb) == 14
@test depth_of(a.__status__, "Spawned child") >
    depth_of(a.__status__, "Spawned caller")
@test depth_of(b.__status__, "Spawned child") >
    depth_of(b.__status__, "Spawned caller")
end

@testitem "implied progress: memo, fresh, broadcast and do forms execute" tags=[:progress] setup=[ImpliedProgressFixtures] begin
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

for (child, parent) in (
    "Counted indexed work" => "Explicitly memoized pair",
    "Counted indexed work" => "Explicitly fresh pair",
    "Counted indexed work" => "Broadcasted pair",
    "Function-taking indexed work" => "Do-block caller",
)
    @test depth_of(r.__status__, child) > depth_of(r.__status__, parent)
end
end

@testitem "implied progress: property-scoped rewrite preserves syntax roles" tags=[:progress] begin
using DynamicObjects
const propfetch = GlobalRef(DynamicObjects, :maybefetchproperty!)
const indexfetch = GlobalRef(DynamicObjects, :maybefetchindex!)
rw(ex) = DynamicObjects._progress_property_rewrite(:p, ex)
count_ref(x, target) = x == target ? 1 :
    x isa Expr ? sum(a -> count_ref(a, target), x.args; init=0) : 0

# A foreign call remains a foreign call; its property-valued argument is fetched.
foreign = rw(:(sum(obj.y)))
@test foreign.args[1] === :sum
@test foreign.args[2].args[1] == propfetch

# A property-rooted call is the only call form wrapped by maybefetchindex!.
ipcall = rw(:(obj.ip(x; k=other.y)))
@test ipcall.args[1] == indexfetch
@test any(a -> Meta.isexpr(a, :parameters), ipcall.args)

# Assignment targets, quoted code, macro heads and type positions are syntax,
# not property evaluations.
assignment_src = :(obj.y = rhs.z)
assignment = rw(assignment_src)
@test assignment.args[1] == assignment_src.args[1]
@test assignment.args[2].args[1] == propfetch

quoted = quote obj.y end
@test rw(quoted) == quoted

macro_src = :(@example obj.y)
macro_rw = rw(macro_src)
@test macro_rw.args[1] == macro_src.args[1]
@test macro_rw.args[3].args[1] == propfetch

typed_src = :(obj.y::M.T)
typed = rw(typed_src)
@test typed.args[1].args[1] == propfetch
@test typed.args[2] == typed_src.args[2]

# Broadcast, do-block and shorthand keyword/destructure shapes remain valid
# Julia while still routing their property evaluations.
broadcasted = rw(:(obj.ip.(xs)))
@test broadcasted.head === :.
@test broadcasted.args[1] == indexfetch

doblock = rw(:(obj.ip(xs) do x
    x.y
end))
@test doblock.head === :call
@test doblock.args[1] == indexfetch

shorthand = rw(Expr(:call, :f, Expr(:parameters, :(obj.y))))
params = only(a for a in shorthand.args if Meta.isexpr(a, :parameters))
@test Meta.isexpr(only(params.args), :kw)

destructured = rw(:((; a, b) = obj))
@test count_ref(destructured, propfetch) == 2
end

@testitem "implied progress: explicit markers still override" tags=[:progress] setup=[ImpliedProgressFixtures] begin
using .ImpliedProgressFixtures
m = IPMarked(3)
@test m.root == 7
# `@fetch!` keeps its own (poller/spawning) lowering; implied threading stands
# down on any progress-marked declaration, and the nesting is unchanged.
@test depth_of(m.__status__, "Marked leaf") > depth_of(m.__status__, "Marked root")
end
