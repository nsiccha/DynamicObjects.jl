# Shared by all types and keyword shapes: only direct dependency edges and
# eligible names grow with a declaration. No transitive Val tuples, per-name
# helpers, or repeated one-field NamedTuple merges enter Julia's compiler.
const _HASH_DUNDERS = (:__hash__, :__hash_fields__, :__cache_base__, :__cache_path__)
struct _CarryPlan
    names::Vector{Symbol}
    graph::_DependencyGraph
    opaque::Vector{Symbol}
    lock::ReentrantLock
    by_changes::Dict{Tuple{Vararg{Symbol}},Vector{Symbol}}
end

function _CarryPlan(names, dependencies, identity, opaque)
    edges = Dict{Symbol,Set{Symbol}}(name => copy(deps) for (name, deps) in dependencies)
    # A hash/path read is sensitive to the whole construction identity as well
    # as its explicit reads. Keep both; an early return on a hash dependency
    # must not hide a different dependency or an opaque reader.
    for name in _HASH_DUNDERS
        union!(get!(() -> Set{Symbol}(), edges, name), identity)
    end
    _CarryPlan(names, _DependencyGraph(edges), collect(Symbol, opaque),
               ReentrantLock(), Dict{Tuple{Vararg{Symbol}},Vector{Symbol}}())
end

_carry_plan(::Type) = nothing
_copy_remake_cache!(destination, source, ::Nothing, changed, inputs) = nothing

struct _CarryMiss end
const _CARRY_MISS = _CarryMiss()

function _carry_names(plan::_CarryPlan, changed)
    @nospecialize changed
    isempty(changed) && return plan.names
    cached = lock(() -> get(plan.by_changes, changed, nothing), plan.lock)
    cached === nothing || return cached
    invalidated = union(Set{Symbol}(changed), plan.opaque)
    _close_dependents!(invalidated, plan.graph)
    names = filter(name -> !(name in invalidated), plan.names)
    lock(plan.lock) do
        existing = get(plan.by_changes, changed, nothing)
        existing === nothing || return existing
        # Keyword names, never values. Repeated shapes share analysis without
        # specializing code on a transitive set. Bound retained results to 32
        # shapes per declaration; rarer shapes still use the same traversal.
        length(plan.by_changes) < 32 && (plan.by_changes[changed] = names)
        names
    end
end

function _copy_remake_cache!(destination, source, plan::_CarryPlan, changed, inputs)
    @nospecialize changed inputs
    for name in _carry_names(plan, changed)
        haskey(inputs, name) && continue
        value = get(source, name, _CARRY_MISS)
        (value === _CARRY_MISS || value isa Pending) && continue
        _seed_store!(destination, name, value)
    end
    nothing
end

"""
    remake(object; changes...)

Construct a new object of the same type with replaced fields or property
overrides. Settled scalar values whose declared dependencies are unaffected may
be carried over. Changed inputs invalidate their transitive dependents.
In-flight computations and indexed-property caches are not copied.

Constructor overrides remain inputs unless replaced. A scalar `@state` value
is carried unless a fixed field its initializer reads changed. An opaque
property that passes `__self__` to uninspected code is carried only when no
keyword changes were supplied.

The original object remains available. Pass new input values rather than
mutating fields, arguments or cached outputs. Use [`remount`](@ref) to bind
request context while sharing retained work instead of constructing a new value.
"""
remake(obj; kwargs...) = _remake(obj, values(kwargs))
function _remake(obj::T, nt::NamedTuple{KW}) where {T,KW}
    fixed = fieldnames(T)[1:end-1]               # all fields except :cache
    args = Any[haskey(nt, n) ? nt[n] : getfield(obj, n) for n in fixed]
    # The source's own construction kwargs are inputs, not memos: pass them to
    # the constructor (unless this call names them) so they become the new
    # instance's seeds. Reuse the source's still-valid memoized properties;
    # constructor kwargs override any carried value. Carried values are
    # written into the new cache AFTER construction rather than passed as
    # constructor kwargs: they are still-valid memos, not instance inputs, so
    # a later `clear_mem_caches!` must drop (recompute) them while the seeds
    # survive.
    explicit = Base.structdiff(nt, NamedTuple{fixed})
    inputs = merge(Base.structdiff(_construction_seed(obj), nt), explicit)
    remade = T(args...; inputs...)
    _copy_remake_cache!(getfield(remade, :cache).cache, getfield(obj, :cache).cache,
                        _carry_plan(T), KW, inputs)
    remade
end
