# Which slots a native declaration reaches: a type declaration in every owner,
# a property declaration over its type, and undeclared copies of a declared
# object. Start with a process budget, so that publications are registered.
using Test, DynamicObjects
const DO = DynamicObjects
const KiB = 1024
const props = (:problem, :sized, :kept, :loose, :model, :other, :legacy)
const built = NamedTuple{props}(ntuple(_ -> Threads.Atomic{Int}(0), length(props)))
const freed = NamedTuple{props}(ntuple(_ -> Threads.Atomic{Int}(0), length(props)))

# The declaring package owns `Owned`. It only produces `Foreign` values.
# `Legacy` has the owner-generic declaration that consumers wrote for 0.5.37.
for T in (:Owned, :Foreign, :Legacy)
    @eval mutable struct $T
        handle::Ptr{UInt8}
        bytes::Int
    end
end
function native(T, n, name)
    p = Libc.malloc(n)
    p == C_NULL && error("native allocation failed")
    Threads.atomic_add!(built[name], 1)
    count = freed[name]
    finalizer(T(p, n)) do h
        Libc.free(h.handle)
        Threads.atomic_add!(count, 1)
    end
end

@dynamicstruct struct Compiled
    n::Int
    problem = native(Owned, n, :problem)
    sized = native(Owned, n, :sized)
    kept = native(Owned, n, :kept)
    loose = native(Owned, n, :loose)
    model = native(Foreign, n, :model)
    other = native(Foreign, n, :other)
    legacy = native(Legacy, n, :legacy)
    marker(k) = k
end
@dynamicstruct struct Sampling
    compiled
    problem = compiled.problem
    model = compiled.model
    other = compiled.other
    @struct fit = begin
        problem = compiled.problem
        model = compiled.model
    end
    @struct qt_fit(dataset) = begin
        problem = compiled.problem
        model = compiled.model
    end
end
DO.memo_native_bytes(::Owned) = missing
DO.memo_native_bytes(::Type{Compiled}, ::Val{:sized}, h::Owned) = h.bytes
DO.memo_native_bytes(::Type{Compiled}, ::Val{:kept}, ::Owned) = nothing
# The value is untyped, as in the docstring's signature. Next to an
# owner-generic declaration for `Owned` this call would be ambiguous.
DO.memo_native_bytes(::Type{Compiled}, ::Val{:loose}, value) = 1
DO.memo_native_bytes(::Type{Compiled}, ::Val{:model}, ::Foreign) = missing
DO.memo_native_bytes(::Type{Compiled}, ::Val{:other}, ::Foreign) = missing
DO.memo_native_bytes(::Type{Sampling}, ::Val{:other}, ::Foreign) = nothing
DO.memo_native_bytes(::Type, ::Val, ::Legacy) = missing

# Reads happen in frames of their own, so that no handle stays rooted here.
@noinline function read_all(c, s)
    c.sized, c.kept, c.loose, c.legacy
    (; problem = c.problem === s.problem === s.fit.problem === s.qt_fit(:a).problem,
       model = c.model === s.model === s.fit.model === s.qt_fit(:a).model,
       other = c.other === s.other)
end
@noinline holds(o, name) = any(e -> e.object === o && e.property === name, mem_cache_entries(o))
@noinline function trim_all(c)
    c.marker(1)        # the most recently used slot stays warm
    while DO._trim_memos!(typemax(Int)) > 0 end
    GC.gc(true)
    GC.gc(true)
end
tally(counter) = map(getindex, counter)

@test memo_retention_stats().process_budget_bytes > 0
c = Compiled(64 * KiB)
s = Sampling(c)
children = Dict(tree_children_map(Sampling)[Sampling])
@test typeof(s.fit) === children[:fit] && typeof(s.qt_fit(:a)) === children[:qt_fit]
@test read_all(c, s) == (problem=true, model=true, other=true)
@test tally(built) == (problem=1, sized=1, kept=1, loose=1, model=1, other=1, legacy=1)
old = memo_retention_stats()
trim_all(c)
stats = memo_retention_stats()

# The type declaration reaches the producer, a copy in another object and the
# plain and indexed inline children.
@test !any(o -> holds(o, :problem), (c, s, s.fit, s.qt_fit(:a)))
# A property declaration takes precedence over its type, also with `nothing`.
@test !holds(c, :sized) && !holds(c, :loose) && holds(c, :kept)
# Copies of an object that only its producer declares are released with it.
@test !any(o -> holds(o, :model), (c, s, s.fit, s.qt_fit(:a)))
# A copy whose property declares `nothing` stays and keeps the instance alive.
@test !holds(c, :other) && holds(s, :other)
@test !holds(c, :legacy)
@test stats.estimated_native_bytes - old.estimated_native_bytes == c.n + 1
@test stats.unknown_native_slots - old.unknown_native_slots == 4 + 4 + 1 + 1
@test tally(freed) == (problem=1, sized=1, kept=0, loose=1, model=1, other=0, legacy=1)

# A later read rebuilds one instance, and its copies are released again. The
# kept copy still holds the first `other`, so its producer now has a second.
@test read_all(c, s) == (problem=true, model=true, other=false)
@test tally(built) == (problem=2, sized=2, kept=1, loose=2, model=2, other=2, legacy=2)
trim_all(c)
@test !any(o -> holds(o, :model), (c, s, s.fit, s.qt_fit(:a)))
@test tally(freed) == (problem=2, sized=2, kept=0, loose=2, model=2, other=1, legacy=2)
@info "Native declarations" slots_of_unknown_size=(stats.unknown_native_slots - old.unknown_native_slots) declared_bytes=(stats.estimated_native_bytes - old.estimated_native_bytes) built=tally(built) freed=tally(freed)
