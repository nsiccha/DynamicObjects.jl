using TestItemRunner

# `@state`: per-instance state that whole-object clears keep and `sync!` never
# drops (snag `in-invoices-jl-a-6b1221ee`, decision `1oc1ssr`). The shape is the
# Invoices `AppData` singleton's ECB refresh throttle: a mutable record with a
# lock that every mutating route's `clear_mem_caches!` used to rebuild.
@testmodule StateFixtures begin
using DynamicObjects
export Throttle, StateApp, StateIndexed, StateChained, StateReadsField,
       StateTracked, StateHoldsTracked, STATE_CALLS

const STATE_CALLS = Dict{Any,Int}()
_bump!(key) = (STATE_CALLS[key] = get(STATE_CALLS, key, 0) + 1)

mutable struct Throttle
    lock::ReentrantLock
    last_attempt::Union{Nothing,Float64}
    Throttle() = new(ReentrantLock(), nothing)
end

@dynamicstruct struct StateApp
    root::String
    @state throttle = (_bump!(:throttle); Throttle())
    listing = (_bump!(:listing); root * "/listing")
    status = (_bump!(:status); something(throttle.last_attempt, -1.0))
end

@dynamicstruct struct StateIndexed
    @state limiter(source::Symbol) = (_bump!((:limiter, source)); Throttle())
    label(source::Symbol) = (_bump!((:label, source)); string(source))
end

@dynamicstruct struct StateChained
    @state mutex = (_bump!(:mutex); ReentrantLock())
    @state guarded = (_bump!(:guarded); (; mutex, log = String[]))
    summary = (_bump!(:summary); length(guarded.log))
end

@dynamicstruct struct StateReadsField
    limit::Int
    other::Int
    @state budget = (_bump!(:budget); Ref(limit))
end

@dynamicstruct struct StateTracked
    source::TrackedFile
    @state attempts = (_bump!(:attempts); (; path = tracked_path(source), count = Ref(0)))
    content = (_bump!(:content); read(source))
end

@dynamicstruct struct StateHoldsTracked
    path::String
    @state watched = TrackedFile(path; read = p -> read(p, String))
    text = (_bump!(:text); read(watched))
end
end

@testitem "@state survives clear_mem_caches!; ordinary properties recompute" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
app = StateApp("/data")
t = app.throttle
t.last_attempt = 1.0
@test app.listing == "/data/listing"
@test app.status == 1.0
clear_mem_caches!(app)
@test app.throttle === t
@test app.throttle.last_attempt == 1.0
@test STATE_CALLS[:throttle] == 1
@test app.listing == "/data/listing"
@test STATE_CALLS[:listing] == 2
@test app.status == 1.0
@test STATE_CALLS[:status] == 2
# A clear builds no unread state; the first read builds it once.
fresh_app = StateApp("/other")
clear_mem_caches!(fresh_app)
@test STATE_CALLS[:throttle] == 1
@test fresh_app.throttle !== t
@test STATE_CALLS[:throttle] == 2
end

@testitem "clear_cache! resets a named @state and its dependents, never as a dependent" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
app = StateApp("/data")
t = app.throttle
t.last_attempt = 3.0
@test app.status == 3.0
@test app.listing == "/data/listing"
# Forcing another stage leaves the state alone.
@test DynamicObjects.clear_cache!(app, :listing) == [:listing]
@test app.throttle === t
# Naming the state resets it, and what reads it recomputes.
@test DynamicObjects.clear_cache!(app, :throttle) == [:status, :throttle]
t2 = app.throttle
@test t2 !== t
@test t2.last_attempt === nothing
@test app.status == -1.0
@test STATE_CALLS[:throttle] == 2
# The macro form is the same operation.
@clear_cache! app.throttle
@test app.throttle !== t2
@test STATE_CALLS[:throttle] == 3
end

@testitem "indexed @state keeps every entry across a clear; invalidate! resets one" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
o = StateIndexed()
ecb = o.limiter(:ecb)
bank = o.limiter(:bank)
@test o.label(:ecb) == "ecb"
clear_mem_caches!(o)
@test o.limiter(:ecb) === ecb
@test o.limiter(:bank) === bank
@test STATE_CALLS[(:limiter, :ecb)] == 1
@test o.label(:ecb) == "ecb"
@test STATE_CALLS[(:label, :ecb)] == 2
invalidate!(o.limiter, :ecb)
@test o.limiter(:ecb) !== ecb
@test o.limiter(:bank) === bank
@test STATE_CALLS[(:limiter, :ecb)] == 2
end

@testitem "@state may read another @state; resetting the first resets the second" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
o = StateChained()
g = o.guarded
push!(g.log, "attempt")
@test o.summary == 1
clear_mem_caches!(o)
@test o.guarded === g
@test o.guarded.mutex === o.mutex
@test o.summary == 1
@test STATE_CALLS[:summary] == 2
@test DynamicObjects.clear_cache!(o, :mutex) == [:guarded, :mutex, :summary]
@test o.guarded !== g
@test o.summary == 0
end

@testitem "a constructor kwarg still overrides @state and survives a clear" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
mine = Throttle()
app = StateApp("/data"; throttle=mine)
@test app.throttle === mine
clear_mem_caches!(app)
@test app.throttle === mine
@test !haskey(STATE_CALLS, :throttle)
end

@testitem "remake carries @state unless a fixed field its initializer reads changed" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
app = StateApp("/data")
t = app.throttle
r = remake(app; root="/elsewhere")
@test r.throttle === t
@test r.listing == "/elsewhere/listing"
# The carried state is kept by the remade instance's own clear: before
# `@state`, a constructor-kwarg seed was carried as a plain memo and lost here.
clear_mem_caches!(r)
@test r.throttle === t
@test STATE_CALLS[:throttle] == 1

f = StateReadsField(5, 1)
b = f.budget
@test remake(f; other=2).budget === b
changed = remake(f; limit=7)
@test changed.budget !== b
@test changed.budget[] == 7
@test STATE_CALLS[:budget] == 2
end

@testitem "remount views share the retained object's @state across clears" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
app = StateApp("/data")
view1 = remount(app; listing="request-1")
t = view1.throttle
@test app.throttle === t
clear_mem_caches!(view1)
@test view1.throttle === t
@test app.throttle === t
view2 = remount(app; listing="request-2")
@test view2.throttle === t
clear_mem_caches!(app)
@test view2.throttle === t
@test STATE_CALLS[:throttle] == 1
end

@testitem "sync! never drops @state; what reads a changed state value still drops" setup=[StateFixtures] begin
using DynamicObjects

empty!(STATE_CALLS)
dir = mktempdir()
input = joinpath(dir, "input.txt")
write(input, "one")

# The state reads a tracked fixed field: a change drops the ordinary reader only.
o = StateTracked(TrackedFile(input; read = p -> read(p, String)))
a = o.attempts
@test o.content == "one"
sync!(o)
write(input, "two, longer")
@test sync!(o) == [:content]
@test o.attempts === a
@test o.content == "two, longer"
@test STATE_CALLS[:attempts] == 1

# The state's own value is tracked: its readers drop, the state is kept.
other = joinpath(dir, "watched.txt")
write(other, "first")
h = StateHoldsTracked(other)
w = h.watched
@test h.text == "first"
sync!(h)
write(other, "second, longer")
@test sync!(h) == [:text]
@test h.watched === w
@test h.text == "second, longer"
end

@testitem "@state is reported in descriptors and never promoted to disk" setup=[StateFixtures] begin
using DynamicObjects

d = property_descriptor(StateApp, :throttle)
@test d.semantics.state
@test d.semantics.memoized
@test d.output.materialization.tier === :memory
plain = property_descriptor(StateApp, :listing)
@test !plain.semantics.state
@test plain.output.materialization.tier === :automatic
@test property_descriptor(StateIndexed, :limiter).semantics.state
end

@testitem "@state initializers derive from nothing a clear could move" setup=[StateFixtures] begin
using DynamicObjects

# refused: a @state initializer reading a computed property would make the
# state derived, so keeping it across clears would serve stale state
# (decision `1oc1ssr`).
@test_throws "reads computed property `listing`" macroexpand(@__MODULE__, :(
    @dynamicstruct struct StateReadsComputed
        root::String
        listing = root * "/listing"
        @state cache = Dict(listing => 0)
    end))
# refused: handing `__self__` to other code hides what the initializer reads
# (decision `1oc1ssr`).
@test_throws "hands `__self__` to other code" macroexpand(@__MODULE__, :(
    @dynamicstruct struct StateOpaque
        root::String
        @state handle = make_handle(__self__)
    end))
# refused: disk persistence, never-cache, version and queue markers contradict
# in-memory state kept for the instance's life (decision `1oc1ssr`).
for marker in (Symbol("@cached"), Symbol("@fresh"), Symbol("@versioned"), Symbol("@queued"))
    decl = Expr(:macrocall, marker, LineNumberNode(0),
        Expr(:macrocall, Symbol("@state"), LineNumberNode(0), :(record(key) = Ref(key))))
    ex = Expr(:macrocall, Symbol("@dynamicstruct"), LineNumberNode(0),
        Expr(:struct, false, :StateConflict, Expr(:block, decl)))
    @test_throws "cannot combine with $marker" macroexpand(@__MODULE__, ex)
end
# Fixed fields, index arguments and other @state properties are allowed.
@test macroexpand(@__MODULE__, :(
    @dynamicstruct struct StateAllowed
        limit::Int
        @state base = Ref(limit)
        @state per_key(key) = (base, key)
    end)) isa Expr
end
