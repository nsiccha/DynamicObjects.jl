using TestItemRunner

# `DynamicObjects.property_settled` reports each value a computation of a memoized property
# stores: once, after the store and the release of every waiter, outside the cache locks, so
# a notification sent from it reaches readers that find the new value (snag
# `tracked-projecti-720b52a5`).
@testmodule SettledFixtures begin
using DynamicObjects
export PSApp, PSTracked, PSView, PSCached, settled, settled_reset!, of_kind,
       COMPUTES, CACHED_COMPUTES, GATE, HOOK_GATE, HOOK_THROWS, FAIL

const SETTLED = Any[]
const SETTLED_LOCK = ReentrantLock()
_record!(x) = lock(() -> push!(SETTLED, x), SETTLED_LOCK)
settled() = lock(() -> copy(SETTLED), SETTLED_LOCK)
settled_reset!() = lock(() -> empty!(SETTLED), SETTLED_LOCK)
of_kind(kind) = filter(x -> first(x) === kind, settled())

const COMPUTES = Threads.Atomic{Int}(0)
const CACHED_COMPUTES = Threads.Atomic{Int}(0)
const GATE = Ref{Any}(nothing)        # a Channel: `value`'s body blocks on it
const HOOK_GATE = Ref{Any}(nothing)   # a Channel: `value`'s hook blocks on it
const HOOK_THROWS = Ref(false)
const FAIL = Ref(false)

_gate(gate) = gate[] === nothing || take!(gate[])

@dynamicstruct struct PSApp
    seed::Int
    value = (Threads.atomic_add!(COMPUTES, 1); _gate(GATE); FAIL[] && error("value failed"); [seed])
    doubled = 2 .* value
    item(i::Int; scale::Int=1) = [(seed + i) * scale]
    @fresh fresh_item(i::Int) = [seed + i]
    unhooked = [seed + 1]
    # A member method: sibling names read as they do in a property body, and a re-read of
    # the property returns the stored value.
    DynamicObjects.property_settled(__self__, ::Val{:value}, stored) = begin
        _record!((:value, stored, value === stored, seed))
        _gate(HOOK_GATE)
        HOOK_THROWS[] && error("hook failed")
    end
end
DynamicObjects.property_settled(app::PSApp, ::Val{:doubled}, stored) =
    _record!((:doubled, stored, app.doubled === stored))
DynamicObjects.property_settled(app::PSApp, ::Val{:item}, stored, i; kwargs...) =
    _record!((:item, stored, i, (; kwargs...), app.item(i; kwargs...) === stored))

@dynamicstruct struct PSTracked
    path::String
    source = TrackedFile(path; read = p -> read(p, String))
    text = Ref(read(source))
    DynamicObjects.property_settled(__self__, ::Val{:text}, stored) =
        _record!((:text, stored[], text === stored))
end

# Helpers outside the struct receive the escaped `__self__`: opaque under `remount`.
_reads_nothing(app) = Ref(app.seed)
_reads_context(app) = Ref((app.ctx, app.seed))

@dynamicstruct struct PSView
    seed::Int
    ctx = nothing
    shared = [seed]
    opaque_shared = _reads_nothing(__self__)
    opaque_context = _reads_context(__self__)
    opaque_context_item(i::Int) = (_reads_context(__self__), i)
end
for name in (:shared, :opaque_shared, :opaque_context)
    @eval DynamicObjects.property_settled(view::PSView, ::Val{$(QuoteNode(name))}, stored) =
        _record!(($(QuoteNode(name)), view.ctx, stored, getproperty(view, $(QuoteNode(name))) === stored))
end
DynamicObjects.property_settled(view::PSView, ::Val{:opaque_context_item}, stored, i) =
    _record!((:opaque_context_item, view.ctx, stored, view.opaque_context_item(i) === stored))

@dynamicstruct struct PSCached
    key::Int
    @cached stored = (Threads.atomic_add!(CACHED_COMPUTES, 1); [key])
end
DynamicObjects.property_settled(::PSCached, ::Val{:stored}, value) = _record!((:stored, value))
end

@testitem "property_settled reports each stored value once; hits, waiters and fresh calls do not" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
app = PSApp(1)
value = app.value
@test value == [1]
@test settled() == [(:value, value, true, 1)]
@test app.value === value
@test length(settled()) == 1
doubled = app.doubled
@test of_kind(:doubled) == [(:doubled, doubled, true)]
item = app.item(2; scale=3)
@test item == [9]
@test of_kind(:item) == [(:item, item, 2, (; scale=3), true)]
@test app.item(2; scale=3) === item
@test length(of_kind(:item)) == 1
@test app.item(2) == [3]   # a distinct entry settles on its own
@test of_kind(:item)[end][4] == (;)
# A property without a hook keeps the default no-op; `@fresh` computations store nothing.
@test app.unhooked == [2]
before = length(settled())
@test app.fresh_item(2) == [3]
@test fresh(app.item, 5) == [6]
@test length(settled()) == before
# The member method is a method, not a property.
@test property_descriptor(PSApp, :property_settled) === nothing
end

@testitem "concurrent readers share one computation and one settlement" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
GATE[] = Channel{Nothing}(Inf)
try
    app = PSApp(2)
    before = COMPUTES[]
    readers = [Threads.@spawn app.value for _ in 1:8]
    @test timedwait(() -> COMPUTES[] == before + 1, 30) === :ok
    sleep(0.2)
    put!(GATE[], nothing)
    values = fetch.(readers)
    @test all(v -> v === values[1], values)
    @test COMPUTES[] == before + 1
    @test settled() == [(:value, values[1], true, 2)]
finally
    GATE[] = nothing
end
end

@testitem "property_settled runs after waiters are released, before the computing call returns" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
GATE[] = Channel{Nothing}(Inf)
HOOK_GATE[] = Channel{Nothing}(Inf)
try
    app = PSApp(3)
    before = COMPUTES[]
    computing = Threads.@spawn app.value
    @test timedwait(() -> COMPUTES[] == before + 1, 30) === :ok
    waiter = Threads.@spawn app.value
    sleep(0.2)
    put!(GATE[], nothing)
    # The hook has started and is held; the waiter already has the stored value.
    @test timedwait(() -> length(settled()) == 1, 30) === :ok
    @test timedwait(() -> istaskdone(waiter), 30) === :ok
    @test fetch(waiter) == [3]
    @test !istaskdone(computing)
    put!(HOOK_GATE[], nothing)
    @test fetch(computing) === fetch(waiter)
    @test COMPUTES[] == before + 1
finally
    GATE[] = nothing
    HOOK_GATE[] = nothing
end
end

@testitem "a failed computation does not settle; a throwing hook is logged and the value stays stored" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
app = PSApp(4)
FAIL[] = true
try
    @test_throws PropertyComputationError app.value
finally
    FAIL[] = false
end
@test isempty(settled())
HOOK_THROWS[] = true
value = try
    @test_logs (:error, r"property_settled hook threw") app.value
finally
    HOOK_THROWS[] = false
end
@test value == [4]
@test app.value === value
@test settled() == [(:value, value, true, 4)]
end

@testitem "polled computations settle once" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
app = PSApp(5)
rv = fetchproperty((rv, status) -> rv, app, :value)
value = rv isa Pending ? fetch(rv) : rv
@test timedwait(() -> length(of_kind(:value)) == 1, 30) === :ok
@test only(of_kind(:value))[2] === value
rv = fetchindex((rv, status) -> rv, app.item, 7)
item = rv isa Pending ? fetch(rv) : rv
@test timedwait(() -> length(of_kind(:item)) == 1, 30) === :ok
@test only(of_kind(:item))[2] === item
sleep(0.2)
@test length(settled()) == 2
end

@testitem "sync! drops a value; its recompute settles once and an idle sync! does not" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
dir = mktempdir()
path = joinpath(dir, "input.txt")
write(path, "one")
tracked = PSTracked(path)
@test tracked.text[] == "one"
@test settled() == [(:text, "one", true)]
@test sync!(tracked) == Symbol[]
@test tracked.text[] == "one"
@test length(settled()) == 1
write(path, "two!")
@test sync!(tracked) == [:text]
@test length(settled()) == 1   # dropping is not settling
@test tracked.text[] == "two!"
@test settled()[end] == (:text, "two!", true)
@test sync!(tracked) == Symbol[]
@test tracked.text[] == "two!"
@test length(settled()) == 2
end

@testitem "remount views: shared work settles once; context-dependent work settles per view" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
source = PSView(1)
views = [remount(source; ctx=i) for i in 1:3]
shared = views[1].shared
@test all(view -> view.shared === shared, views)
@test of_kind(:shared) == [(:shared, 1, shared, true)]
opaque = views[2].opaque_shared
@test all(view -> view.opaque_shared === opaque, views)
@test of_kind(:opaque_shared) == [(:opaque_shared, 2, opaque, true)]
for (i, view) in enumerate(views)
    @test view.opaque_context[] == (i, 1)
    @test view.opaque_context_item(4)[1][] == (i, 1)
end
for kind in (:opaque_context, :opaque_context_item)
    records = of_kind(kind)
    @test sort([record[2] for record in records]) == [1, 2, 3]
    @test all(record -> record[4], records)
end
@test all(record -> record[3][] == (record[2], 1), of_kind(:opaque_context))
end

@testitem "a value read from an explicit @cached entry settles" setup=[SettledFixtures] begin
using DynamicObjects
settled_reset!()
base = mktempdir()
before = CACHED_COMPUTES[]
first_reader = PSCached(1; __cache_base__ = base)
@test first_reader.stored == [1]
second_reader = PSCached(1; __cache_base__ = base)
@test second_reader.stored == [1]
@test CACHED_COMPUTES[] == before + 1
@test length(of_kind(:stored)) == 2
end
