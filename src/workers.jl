# --- Worker process: `@queued` computations in a separate Julia process --------------------
#
# With `configure_queue!(; workers=1)` every computation the job queue admits — a memoized
# computation of a `@queued` property (`DeferredCompute`) or a fresh one (`QueuedCall`) —
# runs in a long-lived worker process instead of on a `:default` task of this one, so a
# compile, a GC pause or a deadlock in heavy work never stalls the process serving pages.
#
# What travels is an address, never an object: the root's type, fixed fields and construction
# inputs, the `(property, key)` steps from the root to the computing object, and a `remount`
# view's context. The worker builds the same root (same package, same environment), keeps it
# by `__hash__`, walks the same memoized steps, and computes the property through its own
# ordinary memoized path. The result comes back through the cache's own guarded path
# (`run!(produce, d)`), so the in-flight fence, `property_settled`, waiters and
# `Pending.resolve` behave as for a local computation. A disk-tier value (`@cached`, `@mmap`)
# is published by the worker under the same `base/<__hash__>/…` path and loaded here; a
# memory-tier value is serialized back.
#
# Transport is Malt.jl. Malt's host side is not thread-safe (a `Worker`'s message counter and
# reply table are plain fields its receive loop reads concurrently), and its loops are tasks
# pinned to the thread that created the worker. So every Malt call of one worker runs on one
# actor task (`_WorkerConn.actor`), on an interactive thread when there is one; callers on any
# thread hand it closures and wait for their reply. Malt has no worker-to-host calls: the
# worker queues its events (log records, requester messages, results) and an event pump on the
# actor's thread long-polls them, in order.

"""
    DynamicObjects.RemoteComputationError(pid, message)

The failure of a computation that ran in the worker process `pid`, as the worker printed it
(`message` holds the exception and its backtrace there). It arrives wrapped in a
[`PropertyComputationError`](@ref) for the property this process asked for;
[`unwrap_error`](@ref) returns it.
"""
struct RemoteComputationError <: Exception
    pid::Int
    message::String
end
Base.showerror(io::IO, e::RemoteComputationError) =
    print(io, "RemoteComputationError: in worker process ", e.pid, ":\n", e.message)

# --- Addresses -------------------------------------------------------------------------------

# Construction inputs that cannot travel: the request itself and the progress root.
const _LOCAL_SEED_NAMES = (:__status__, :__req__)

struct _RootAddress
    type::Type
    fixed::Tuple
    seed::NamedTuple
    digest::Any        # the root's `__hash__`: the worker keeps roots by it
end
struct _ChildAddress
    parent::Any        # an address
    name::Symbol
    indexed::Bool
    args::Tuple
    kwargs::NamedTuple
end
struct _ViewAddress
    base::Any          # the address of the retained object
    context::NamedTuple
end
const _Address = Union{_RootAddress,_ChildAddress,_ViewAddress}

# Why an object cannot be sent to a worker.
struct _NotAddressable <: Exception
    msg::String
end
Base.showerror(io::IO, e::_NotAddressable) = print(io, e.msg)

# The address of DO object `o`. `strict`: no fallback for a child its parent does not hold
# (an invalidation forwards only to what the worker can find by walking).
function _address(o; strict::Bool=false)
    pc = getfield(o, :cache)
    parent = get(pc.seed, :__parent__, nothing)
    if _is_dynamic_object(parent)
        step = _child_step(parent, o)
        step === nothing || return _ChildAddress(_address(parent; strict), step...)
    end
    c = pc.cache
    if c isa MountedThreadsafeDict
        return _ViewAddress(_address(c.source; strict), _wire(_without_local(pc.seed)))
    end
    strict && parent !== nothing && _is_dynamic_object(parent) && throw(_NotAddressable(
        "$(typeof(o)) is not held by its parent"))
    _root_address(o)
end

function _root_address(o)
    T = typeof(o)
    root = Base.moduleroot(parentmodule(T))
    if root === Main || Base.PkgId(root).uuid === nothing
        throw(_NotAddressable("`$(T)` is defined in `$(root)`, which a worker process cannot " *
            "load. Define the type in a package (the worker loads the package that defines " *
            "the root object's type), or run with `DynamicObjects.configure_queue!(; workers=0)`."))
    end
    fixed = Tuple(_wire(getfield(o, n)) for n in fieldnames(T)[1:end-1])
    _RootAddress(T, fixed, _wire(_without_local(_construction_seed(o))), o.__hash__)
end

_without_local(seed::NamedTuple) = Base.structdiff(seed, NamedTuple{_LOCAL_SEED_NAMES})

# The `(name, indexed, args, kwargs)` step under which `parent` holds `o`, or `nothing`.
function _child_step(parent, o)
    for (name, value) in _held_values(getfield(parent, :cache).cache)
        # Only a declared child is a construction path. An ordinary property can
        # return that same child: addressing it through that alias can make the
        # requester wait on the very computation whose result it is resolving.
        _nested_struct_type(typeof(parent), Val(name)) === nothing && continue
        value === o && return (name, false, (), (;))
        value isa IndexableProperty || continue
        for ((args, kwargs), w) in cached_entries(value)
            w === o && return (name, true, _wire(args), _wire(kwargs))
        end
    end
    nothing
end

_held_values(c::AbstractThreadsafeDict) =
    [(name, value) for (cache, _, _) in _clear_parts(c) for (name, value) in lock(() -> collect(pairs(cache)), c.lock)]
_held_values(c::AbstractDict) = collect(pairs(c))

# A value as it travels: DO objects by address, tuples and named tuples walked.
_wire(x) = _is_dynamic_object(x) ? _address(x) : x
_wire(t::Tuple) = map(_wire, t)
_wire(nt::NamedTuple) = map(_wire, nt)

_unwire(x, objects) = x
_unwire(a::_Address, objects) = _resolve(a, objects)
_unwire(t::Tuple, objects) = map(x -> _unwire(x, objects), t)
_unwire(nt::NamedTuple, objects) = map(x -> _unwire(x, objects), nt)

# The object an address names. `objects` (the worker's) keeps roots and views, so every
# computation of one root shares its memo; `nothing` builds them anew.
function _resolve(a::_RootAddress, objects)
    _kept!(objects, (a.type, a.digest)) do
        a.type(_unwire(a.fixed, objects)...; _unwire(a.seed, objects)...)
    end
end
function _resolve(a::_ChildAddress, objects)
    v = getproperty(_resolve(a.parent, objects), a.name)
    a.indexed ? v(_unwire(a.args, objects)...; _unwire(a.kwargs, objects)...) : v
end
function _resolve(a::_ViewAddress, objects)
    base = _resolve(a.base, objects)
    _kept!(objects, (_address_key(a.base), _address_key(a.context))) do
        remount(base; _unwire(a.context, objects)...)
    end
end

# `build()`, kept in `objects` under `key` (the first one built wins a race).
_kept!(build, ::Nothing, key) = build()
function _kept!(build, objects, key)
    o = lock(() -> get(objects.dict, key, nothing), objects.lock)
    o === nothing || return o
    o = build()
    lock(() -> get!(objects.dict, key, o), objects.lock)
end

# The object an address names if the worker already holds it, else `nothing`: an
# invalidation never builds what it would clear.
function _resolve_existing(a::_RootAddress, objects)
    lock(() -> get(objects.dict, (a.type, a.digest), nothing), objects.lock)
end
function _resolve_existing(a::_ChildAddress, objects)
    parent = _resolve_existing(a.parent, objects)
    parent === nothing && return nothing
    held = _held_values(getfield(parent, :cache).cache)
    i = findfirst(p -> first(p) === a.name, held)
    i === nothing && return nothing
    value = last(held[i])
    a.indexed || return value
    value isa IndexableProperty || return nothing
    key = (_unwire(a.args, objects), _unwire(a.kwargs, objects))
    for (k, w) in cached_entries(value)
        _key_isequal(k[1], key[1]) && _key_isequal(k[2], key[2]) && return w
    end
    nothing
end
function _resolve_existing(a::_ViewAddress, objects)
    _resolve_existing(a.base, objects) === nothing && return nothing
    key = (_address_key(a.base), _address_key(a.context))
    lock(() -> get(objects.dict, key, nothing), objects.lock)
end

# A hashable stand-in for an address: deserialized fixed fields are new objects, so an
# address itself never hashes alike twice.
_address_key(a::_RootAddress) = (a.type, a.digest)
_address_key(a::_ChildAddress) = (_address_key(a.parent), a.name, _address_key(a.args), _address_key(a.kwargs))
_address_key(a::_ViewAddress) = (_address_key(a.base), _address_key(a.context))
_address_key(t::Tuple) = map(_address_key, t)
_address_key(nt::NamedTuple) = map(_address_key, nt)
_address_key(x) = x

# The packages a worker must load before it can read `x`.
function _packages!(set::Set{Base.PkgId}, x)
    _type_packages!(set, typeof(x))
    set
end
function _packages!(set::Set{Base.PkgId}, a::_RootAddress)
    _type_packages!(set, a.type)
    _packages!(set, a.fixed); _packages!(set, a.seed)
end
_packages!(set::Set{Base.PkgId}, a::_ChildAddress) =
    (_packages!(set, a.parent); _packages!(set, a.args); _packages!(set, a.kwargs))
_packages!(set::Set{Base.PkgId}, a::_ViewAddress) = (_packages!(set, a.base); _packages!(set, a.context))
_packages!(set::Set{Base.PkgId}, t::Union{Tuple,NamedTuple}) = (foreach(x -> _packages!(set, x), t); set)

function _type_packages!(set::Set{Base.PkgId}, T, seen=Base.IdSet{Any}())
    T in seen && return set
    push!(seen, T)
    if T isa UnionAll
        _type_packages!(set, Base.unwrap_unionall(T), seen)
    elseif T isa Union
        _type_packages!(set, T.a, seen); _type_packages!(set, T.b, seen)
    elseif T isa DataType
        root = Base.moduleroot(parentmodule(T))
        if root !== Core && root !== Base && root !== Main
            id = Base.PkgId(root)
            id.uuid === nothing || push!(set, id)
        end
        foreach(p -> p isa Type && _type_packages!(set, p, seen), T.parameters)
    end
    set
end

# --- Requester scoped values ----------------------------------------------------------------

# ScopedValue identity is process-local. Send a package/module/binding address, not a copy
# of the variable; the package's __init__ registers the worker's own variable and converter.
const _WorkerScopeKey = Tuple{Base.PkgId,Tuple{Vararg{Symbol}},Symbol}
struct _WorkerScopeBinding
    variable::ScopedValues.ScopedValue
    wire::Any
    unwire::Any
end
const _WORKER_SCOPES = Dict{_WorkerScopeKey,_WorkerScopeBinding}()
const _WORKER_SCOPES_LOCK = ReentrantLock()

function _worker_scope_key(owner::Module, name::Symbol)
    root = Base.moduleroot(owner)
    id = Base.PkgId(root)
    (root === Main || id.uuid === nothing) && throw(ArgumentError(
        "carry_to_worker!: $(owner).$(name) must belong to a loadable package"))
    path = Symbol[]
    while owner !== root
        pushfirst!(path, nameof(owner))
        owner = parentmodule(owner)
    end
    (id, Tuple(path), name)
end

_worker_scope_name(key) = join((Symbol(key[1].name), key[2]..., key[3]), ".")

"""
    DynamicObjects.carry_to_worker!(owner::Module, name::Symbol; wire=identity, unwire=identity)

Carry the `ScopedValue` bound to `owner.name` into worker computations. Register it in the
owning package's `__init__`, so both processes register their own variable and conversion
functions. `owner` may be a nested module of that package. Returns the scoped variable;
registering the same binding again replaces its converters for subsequent computations.

Before submitting a computation, `wire(variable[])` runs in the initiating requester's
scope. The result must be serializable data. The worker loads the owning package and binds
its registered variable to `unwire(value)` while reconstructing the addressed object and
running its computation. Default values travel too. Each computation has its own scope;
bindings do not persist into later requests, including after an error or worker restart.
Conversions must not mutate their inputs. Register before starting computations.

This applies to memoized and fresh `@queued` property computations with `workers=1`.
In-process computations already inherit every requester scoped value and do not call these
converters. A shared memoized computation still uses the scope of its first caller; this
does not add context to cache keys. Unregistered scoped values are not transported.
Missing worker registrations and conversion failures fail the computation instead of
silently running it with a default value.
"""
function carry_to_worker!(owner::Module, name::Symbol; wire=identity, unwire=identity)
    key = _worker_scope_key(owner, name)
    isdefined(owner, name) || throw(ArgumentError("carry_to_worker!: $(owner).$(name) is not defined"))
    variable = getfield(owner, name)
    variable isa ScopedValues.ScopedValue || throw(ArgumentError(
        "carry_to_worker!: $(owner).$(name) is not a ScopedValue"))
    lock(() -> _WORKER_SCOPES[key] = _WorkerScopeBinding(variable, wire, unwire), _WORKER_SCOPES_LOCK)
    variable
end

function _capture_worker_scopes!(packages)
    bindings = lock(() -> collect(_WORKER_SCOPES), _WORKER_SCOPES_LOCK)
    map(bindings) do (key, binding)
        push!(packages, key[1])
        value = binding.wire(binding.variable[])
        _packages!(packages, value)
        (key, value)
    end
end

function _with_worker_scopes(f, values)
    bindings = lock(_WORKER_SCOPES_LOCK) do
        map(values) do (key, _)
            get(_WORKER_SCOPES, key, nothing)
        end
    end
    scoped = map(zip(values, bindings)) do ((key, value), binding)
        binding === nothing && throw(ArgumentError(
            "DynamicObjects worker: $(_worker_scope_name(key)) is not registered; " *
            "call carry_to_worker! in the owning package's __init__"))
        binding.variable => binding.unwire(value)
    end
    ScopedValues.with(f, scoped...)
end

# --- Requester messages ----------------------------------------------------------------------

const _WORKER_REQUEST = ScopedValues.ScopedValue{Union{Nothing,Int}}(nothing)
const _REQUESTER_HANDLERS = Dict{Symbol,Any}()
const _REQUESTER_HANDLERS_LOCK = ReentrantLock()

"""
    DynamicObjects.on_requester_message!(f, tag::Symbol) -> f

Handle the messages a computation sends with
[`send_to_requester(tag, payload)`](@ref DynamicObjects.send_to_requester): `f(payload)` runs
in this process, as whoever requested the computation — under its logger and with its
`ScopedValue`s — on the task waiting for the computation's result, before that result is
published and in order with its other messages and log records. One handler per tag;
registering again replaces it. A throwing handler is logged and the computation continues.
"""
function on_requester_message!(f, tag::Symbol)
    lock(() -> _REQUESTER_HANDLERS[tag] = f, _REQUESTER_HANDLERS_LOCK)
    f
end

"""
    DynamicObjects.send_to_requester(tag::Symbol, payload)

Send `payload` from a running computation to whoever requested it, where the handler
registered with [`on_requester_message!`](@ref DynamicObjects.on_requester_message!) for `tag`
receives it. In a worker process the payload is serialized to the process that sent the
computation and handled there; anywhere else the handler is called at once, in the current
scope. A computation that several callers share sends to the one that started it. Without a
handler for `tag`, the message is dropped.
"""
function send_to_requester(tag::Symbol, payload)
    id = _WORKER_REQUEST[]
    id === nothing && return (_deliver_requester_message(tag, payload); nothing)
    _push_event!(id, :message, (tag, payload))
    nothing
end

function _deliver_requester_message(tag::Symbol, payload)
    f = lock(() -> get(_REQUESTER_HANDLERS, tag, nothing), _REQUESTER_HANDLERS_LOCK)
    f === nothing && return nothing
    try
        f(payload)
    catch err
        @error "DynamicObjects: the requester message handler for $(repr(tag)) threw" exception = (err, catch_backtrace())
    end
    nothing
end

# --- Worker side -------------------------------------------------------------------------------

const _IS_WORKER = Threads.Atomic{Bool}(false)
const _W_CONTROL = Channel{Any}(Inf)
const _W_EVENTS = Channel{Any}(Inf)
const _W_OBJECTS = (; lock=ReentrantLock(), dict=Dict{Any,Any}())
const _W_NODES = Dict{Int,Any}()          # request id => (progress node, mirror or nothing)
const _W_NODES_LOCK = ReentrantLock()

# Set up this process as a worker: called once by the process that spawned it.
function _worker_init!()
    _IS_WORKER[] = true
    configure_queue!(; max_running=0)
    # Pinned to the thread Malt's handlers run on, so control messages run in arrival order.
    errormonitor(@async _worker_control_loop())
    (; pid=getpid(), threads=Threads.nthreads())
end

function _worker_require(ids::Vector{Base.PkgId})
    foreach(Base.require, ids)
    nothing
end

_worker_submit(msg...) = (put!(_W_CONTROL, (:submit, msg...)); nothing)
_worker_invalidate(msg...) = (put!(_W_CONTROL, (:invalidate, msg...)); nothing)
_worker_interrupt(id::Int, node_id::Int=1) = (put!(_W_CONTROL, (:interrupt, id, node_id)); nothing)

# The events queued since the last call, oldest first; waits for at least one.
function _worker_take_events()
    batch = Any[take!(_W_EVENTS)]
    while isready(_W_EVENTS)
        push!(batch, take!(_W_EVENTS))
    end
    batch
end

# Events are serialized where they are queued, one by one: one that cannot be serialized
# fails its own request instead of the whole batch.
function _push_event!(id::Int, kind::Symbol, payload)
    bytes = try
        _serialized(payload)
    catch err
        kind === :log && return nothing
        kind = :failed
        _serialized("the worker could not send the result back: " * sprint(showerror, err))
    end
    put!(_W_EVENTS, (id, kind, bytes))
    nothing
end
_serialized(x) = (io = IOBuffer(); Serialization.serialize(io, x); take!(io))
_deserialized(bytes::Vector{UInt8}) = Serialization.deserialize(IOBuffer(bytes))

function _worker_control_loop()
    for msg in _W_CONTROL
        try
            # The application package is loaded after this loop started: its methods are newer.
            Base.invokelatest(_worker_control, Val(first(msg)), Base.tail(msg)...)
        catch err
            @error "DynamicObjects worker: a control message failed" kind = first(msg) exception = (err, catch_backtrace())
        end
    end
end

function _worker_control(::Val{:submit}, id::Int, address, name::Symbol, args, kwargs, is_fresh::Bool,
                         min_level::Int32, mirrored::Bool, scopes)
    logger = _ForwardLogger(id, Base.CoreLogging.LogLevel(min_level))
    started = try
        _with_worker_scopes(scopes) do
            ScopedValues.with_logger(logger) do
                ScopedValues.with(_WORKER_REQUEST => id) do
                    o = _resolve(address, _W_OBJECTS)
                    sync!(_retained_object(_root_of(o)))
                    args = _unwire(args, _W_OBJECTS)
                    kwargs = _unwire(kwargs, _W_OBJECTS)
                    ip = getproperty(o, name)
                    if is_fresh
                        # A fresh call has no cache cell to hold its node: it gets one here, as a
                        # progress-threaded fresh call does, so its tree can be mirrored.
                        node = _default_substatus(o.__status__, o, name, args...; __pending__=true, kwargs...)
                        mirror = mirrored ? _mirror(id, node) : nothing
                        (o, Threads.@spawn(_fresh_in_worker(o, name, args, kwargs, node)), node, mirror)
                    else
                        rv = memoize!(ip, args...; fetch=identity, kwargs...)
                        node = rv isa Pending ? getstatus(ip, args...; kwargs...) : nothing
                        (o, rv, node, mirrored ? _mirror(id, node) : nothing)
                    end
                end
            end
        end
    catch err
        _push_event!(id, :failed, _failure_text(err, catch_backtrace()))
        return
    end
    o, handle, node, mirror = started
    node === nothing || lock(() -> _W_NODES[id] = (node, mirror), _W_NODES_LOCK)
    errormonitor(Threads.@spawn Base.invokelatest(_worker_finish, id, o, name, args, kwargs, is_fresh,
                                                  handle, mirror))
    nothing
end

_root_of(o) = (p = get(getfield(o, :cache).seed, :__parent__, nothing); _is_dynamic_object(p) ? _root_of(p) : o)

function _fresh_in_worker(o, name::Symbol, args, kwargs, node)
    try
        v = _fresh_through(property_executor(o, Val(name)), _FreshCompute(o, name, args, kwargs, node), node)
        _finalize_substatus!(node)
        v
    catch err
        _fail_substatus!(node, err)
        rethrow()
    end
end

# Treebars' cross-process mirror: the computation's progress
# tree is followed here and rebuilt under the requester's node.
_mirror(id::Int, node) = nothing
function _mirror(id::Int, node::Treebars.ProgressNode)
    try
        Treebars.mirror_progress(frame -> _push_event!(id, :progress, frame), node)
    catch err
        @error "DynamicObjects worker: the progress tree of a computation cannot be mirrored" exception = (err, catch_backtrace())
        nothing
    end
end

function _worker_finish(id, o, name, args, kwargs, is_fresh, handle, mirror)
    try
        succeeded = false
        value = try
            result = handle isa Union{Pending,Task} ? fetch(handle) : handle
            succeeded = true
            result
        finally
            # The closing frame (the whole final tree) goes out before the outcome.
            if mirror !== nothing
                close(mirror)
                _push_event!(id, :progress_closed, succeeded ? :done : :failed)
            end
        end
        _push_event!(id, :done, is_fresh ? _wire_result(value) : _result_payload(o, name, args, kwargs, value))
    catch err
        _push_event!(id, :failed, _failure_text(err, catch_backtrace()))
    finally
        lock(() -> delete!(_W_NODES, id), _W_NODES_LOCK)
    end
end

# A disk-tier value the worker published travels as the path the requester loads; a value
# whose entry is missing (its computation was invalidated mid-flight) travels itself.
struct _OnDisk
    path::String
end
function _result_payload(o, name::Symbol, args, kwargs, value)
    if iscached(o, Val(name), args...; kwargs...) && !_remount_invalidated(o, name)
        path = get_cache_path(o, name, args...; kwargs...)
        get_cache_status(path) === :ready && return _OnDisk(path)
    end
    _wire_result(value)
end
_wire_result(value) = _is_dynamic_object(value) ? _address(value) : value

_failure_text(err::Base.TaskFailedException, bt) = _failure_text(err.task.exception, err.task.backtrace)
_failure_text(err, bt) = sprint(showerror, err, bt)
_failure_text(err::PropertyComputationError, bt) = sprint(showerror, err)

function _worker_control(::Val{:invalidate}, address, verb::Symbol, args...)
    o = _resolve_existing(address, _W_OBJECTS)
    o === nothing && return
    _apply_invalidation(Val(verb), o, args...)
end
_apply_invalidation(::Val{:clear_cache!}, o, name::Symbol) = (_invalidate_property!(o, name); nothing)
_apply_invalidation(::Val{:invalidate!}, o, name::Symbol, args, kwargs) =
    (_clear_cache_entry!(o, name, _unwire(args, _W_OBJECTS)...; _unwire(kwargs, _W_OBJECTS)...); nothing)
_apply_invalidation(::Val{:clear_mem_caches!}, o) = (clear_mem_caches!(o); nothing)
_apply_invalidation(::Val{:sync!}, o) = (sync!(o); nothing)

# An interrupt a viewer requested on the requester's node of a computation (`node_id` 1) or,
# through the mirror, on one of its nodes.
function _worker_control(::Val{:interrupt}, id::Int, node_id::Int)
    held = lock(() -> get(_W_NODES, id, nothing), _W_NODES_LOCK)
    held === nothing && return nothing
    node, mirror = held
    mirror === nothing ? Treebars.request_interrupt!(node) : Treebars.request_interrupt!(mirror, node_id)
    nothing
end

# Forwards a worker computation's log records to its requester, whose logger decides.
struct _ForwardLogger <: Base.CoreLogging.AbstractLogger
    id::Int
    min_level::Base.CoreLogging.LogLevel
end
Base.CoreLogging.min_enabled_level(l::_ForwardLogger) = l.min_level
Base.CoreLogging.shouldlog(::_ForwardLogger, level, _module, group, id) = true
Base.CoreLogging.catch_exceptions(::_ForwardLogger) = true
function Base.CoreLogging.handle_message(l::_ForwardLogger, level, message, _module, group, id,
                                         file, line; kwargs...)
    record = (Int32(Base.CoreLogging.LogLevel(level).level), string(message), string(nameof(_module)),
              group isa Symbol ? group : Symbol(string(group)), id isa Symbol ? id : Symbol(string(id)),
              file === nothing ? nothing : string(file), line === nothing ? nothing : Int(line),
              Pair{Symbol,Any}[k => _log_value(v) for (k, v) in kwargs])
    _push_event!(l.id, :log, record)
    nothing
end
_log_value(v::Union{Number,AbstractString,Symbol,Nothing,Missing}) = v
_log_value(v::Exception) = sprint(showerror, v)
_log_value(v::Tuple{Exception,Any}) = sprint(showerror, v...)
_log_value(v) = sprint(show, v; context=:limit => true)

# --- Requesting side ------------------------------------------------------------------------

# Whether any queue has a worker configured: one atomic load gates every forwarding hook.
const _WORKERS_ACTIVE = Threads.Atomic{Bool}(false)

# Run `f()` on the actor task and return its value (rethrowing its failure).
function _on_actor(f, conn::_WorkerConn)
    _ensure_actor!(conn)
    reply = Channel{Any}(1)
    put!(conn.ops, (f, reply))
    ok, value = take!(reply)
    ok ? value : throw(value)
end

function _ensure_actor!(conn::_WorkerConn)
    lock(conn.lock) do
        conn.actor === nothing || return
        conn.actor = Threads.nthreads(:interactive) > 0 ?
            Threads.@spawn(:interactive, _actor_loop(conn)) : Threads.@spawn(_actor_loop(conn))
        errormonitor(conn.actor)
    end
    nothing
end

function _actor_loop(conn::_WorkerConn)
    for (f, reply) in conn.ops
        outcome = try
            (true, f())
        catch err
            (false, err)
        end
        put!(reply, outcome)
    end
end

# A Malt call made on the actor (so sends keep their order), waited for here. Malt's worker
# calls `f` from a task that runs in the world it started in, before DynamicObjects and the
# application were loaded there: every call goes through `invokelatest`.
function _remote_fetch(conn::_WorkerConn, w, f, args...)
    task = _on_actor(() -> Malt.remote_call(Base.invokelatest, w, f, args...), conn)
    try
        fetch(task)
    catch err
        throw(err isa TaskFailedException ? err.task.exception : err)
    end
end
_remote_do(conn::_WorkerConn, w, f, args...) =
    _on_actor(() -> Malt.remote_do(Base.invokelatest, w, f, args...), conn)

_worker_alive(w) = w !== nothing && Malt.isrunning(w)

# The running worker of `q`, spawned first if there is none.
function _ensure_worker!(q)
    conn = q.conn
    while true
        spawning = lock(conn.lock) do
            _worker_alive(conn.worker) && return conn.worker
            conn.spawning === nothing && (conn.spawning = Threads.@spawn _spawn_worker!(q))
            conn.spawning
        end
        spawning isa Task || return spawning
        try
            fetch(spawning)
        catch err
            lock(conn.lock) do
                conn.spawning === spawning && (conn.spawning = nothing)
            end
            throw(err isa TaskFailedException ? err.task.exception : err)
        end
    end
end

const _DYNAMICOBJECTS_PKGID = Base.PkgId(@__MODULE__)

function _worker_exeflags(q)
    flags = String[c for c in Base.julia_cmd().exec[2:end]]
    project = Base.active_project()
    project === nothing || push!(flags, "--project=" * project)
    append!(flags, something(q.worker_exeflags,
        ["--threads=$(Threads.nthreads(:default)),1"]))
    flags
end

function _worker_env()
    sep = Sys.iswindows() ? ";" : ":"
    env = ["JULIA_LOAD_PATH=" * join(LOAD_PATH, sep), "JULIA_DEPOT_PATH=" * join(DEPOT_PATH, sep)]
    haskey(ENV, "OPENBLAS_NUM_THREADS") && push!(env, "OPENBLAS_NUM_THREADS=" * ENV["OPENBLAS_NUM_THREADS"])
    env
end

function _spawn_worker!(q)
    conn = q.conn
    exeflags = _worker_exeflags(q)
    w = _on_actor(() -> Malt.Worker(; exeflags, env=_worker_env()), conn)
    try
        id = _DYNAMICOBJECTS_PKGID
        load = :(Base.require(Base.PkgId(Base.UUID($(string(id.uuid))), $(id.name))); nothing)
        fetch(_on_actor(() -> Malt.remote_eval(w, load), conn))
        info = _remote_fetch(conn, w, _worker_init!)
        lock(conn.lock) do
            conn.worker = w
            conn.spawning = nothing
            conn.pid = info.pid
            conn.started_at = time()
            conn.last_message_at = NaN
            empty!(conn.loaded)
        end
        _on_actor(() -> errormonitor(@async _event_pump(conn, w)), conn)
    catch
        _stop_process(conn, w)
        rethrow()
    end
    w
end

# Deliver the worker's events to their requests until the worker exits; then fail every
# request still in flight with `ComputeAbandoned`.
function _event_pump(conn::_WorkerConn, w)
    reason = nothing
    while true
        batch = try
            fetch(Malt.remote_call(Base.invokelatest, w, _worker_take_events))
        catch err
            err = err isa TaskFailedException ? err.task.exception : err
            reason = err isa Malt.TerminatedWorkerException ?
                "the worker process (pid $(w.proc_pid)) exited while computing it" :
                "the connection to the worker process failed: " * sprint(showerror, err)
            break
        end
        lock(conn.lock) do
            conn.last_message_at = time()
            for (id, kind, bytes) in batch
                req = get(conn.inflight, id, nothing)
                req === nothing || put!(req.events, (kind, bytes))
            end
        end
    end
    _abandon_inflight!(conn, w, reason)
end

function _abandon_inflight!(conn::_WorkerConn, w, reason)
    lock(conn.lock) do
        conn.worker === w && (conn.worker = nothing)
        for req in values(conn.inflight)
            req.worker === w && put!(req.events, (:abandoned, reason))
        end
    end
    _malt_stop_quietly(conn, w)
    nothing
end

# Stop `w` through its own process handle: asked to exit, then `SIGTERM`, then `SIGKILL`. A
# stuck worker never runs the exit it is asked for, so the signals follow within seconds.
_stop_process(conn, w) = _on_actor(() -> Malt.stop(w; exit_timeout=3.0, term_timeout=3.0), conn)

_malt_stop_quietly(conn, w) = try
    Malt.isrunning(w) && _stop_process(conn, w)
catch
end

function _ensure_packages!(conn::_WorkerConn, w, ids)
    missing = lock(() -> setdiff(ids, conn.loaded), conn.lock)
    isempty(missing) && return
    _remote_fetch(conn, w, _worker_require, collect(missing))
    lock(() -> union!(conn.loaded, missing), conn.lock)
    nothing
end

# Whether this process sends `item`'s work to the worker of `q`.
_worker_bound(q, item) = q.workers > 0 && _worker_compute(item.work) !== nothing

# The `(o, name, args, kwargs)` a queued work item computes, or `nothing` when it is not a
# property computation the worker can run.
_worker_compute(work) = nothing
function _worker_compute(d::DeferredCompute)
    f = d.f
    f isa _Settling && f.local_value === nothing || return nothing
    _is_dynamic_object(f.o) || return nothing
    (f.o, f.name, f.args, f.kwargs)
end
function _worker_compute(c::QueuedCall)
    f = c.f
    f isa _FreshCompute || return nothing
    (f.o, f.name, f.args, f.kwargs)
end

# Properties kept in this process because their body reads the request: one warning each.
const _KEPT_LOCAL = Set{Tuple{Type,Symbol}}()
const _KEPT_LOCAL_LOCK = ReentrantLock()

function _reads_request(o, name::Symbol)
    T = typeof(o)
    name in dependents(T, :__req__) || return false
    first_time = lock(_KEPT_LOCAL_LOCK) do
        (T, name) in _KEPT_LOCAL ? false : (push!(_KEPT_LOCAL, (T, name)); true)
    end
    first_time && @warn("DynamicObjects: `$(name)` of `$(nameof(T))` reads the request " *
        "(`__req__`), so its computations stay in this process instead of the worker. Pass what " *
        "it needs from the request as arguments to move it to the worker.")
    true
end

# Run an admitted item: in the worker when it is bound there, else here.
function _run_item(q, item)
    compute = q.workers > 0 ? _worker_compute(item.work) : nothing
    (compute === nothing || _reads_request(compute[1], compute[2])) && return run!(item.work)
    run!(_WorkerCompute(q, compute, item.work isa QueuedCall, :pending), item.work)
end

mutable struct _WorkerCompute{Q,C}
    queue::Q
    compute::C
    is_fresh::Bool
    progress_outcome::Symbol
end
(f::_WorkerCompute)(status) = _compute_in_worker(f, f.compute..., status)

function _compute_in_worker(f::_WorkerCompute, o, name::Symbol, args::Tuple, kwargs::NamedTuple, status)
    q, is_fresh = f.queue, f.is_fresh
    conn = q.conn
    address, wired_args, wired_kwargs = try
        _address(o), _wire(args), _wire(kwargs)
    catch err
        err isa _NotAddressable || rethrow()
        throw(PropertyComputationError(string(nameof(typeof(o))), name, args, Tuple(pairs(kwargs)),
            (ArgumentError("DynamicObjects cannot send `$(name)` to the worker process: " * err.msg), nothing)))
    end
    packages = _packages!(_packages!(_packages!(Set{Base.PkgId}(), address), wired_args), wired_kwargs)
    scopes = try
        _capture_worker_scopes!(packages)
    catch err
        throw(PropertyComputationError(string(nameof(typeof(o))), name, args, Tuple(pairs(kwargs)),
            (err, catch_backtrace())))
    end
    min_level = Int32(Base.CoreLogging.min_enabled_level(ScopedValues.current_logger()).level)
    req = lock(conn.lock) do
        conn.next_id += 1
        r = _RemoteRequest(conn.next_id, Channel{Any}(Inf), nothing)
        conn.inflight[r.id] = r
        r
    end
    interrupter = nothing
    try
        w, pid = _submit!(q, req, o, name, args, kwargs, packages,
                          (req.id, address, name, wired_args, wired_kwargs, is_fresh, min_level,
                           _mirrorable(status), scopes))
        replica = _replica(status, conn, w, req.id)
        interrupter = replica === nothing ? _forward_interrupts(conn, w, req.id, status) : replica
        while true
            kind, payload = take!(req.events)
            if kind === :progress
                replica === nothing || Treebars.apply_frame!(replica, _deserialized(payload))
            elseif kind === :progress_closed
                # Keep the worker's final timestamps. A subsequent local failure
                # (for example, loading its disk result) still fails this node.
                replica === nothing || (f.progress_outcome = _deserialized(payload))
            elseif kind === :log
                _emit_log(_deserialized(payload), pid)
            elseif kind === :message
                _deliver_requester_message(_deserialized(payload)...)
            elseif kind === :done
                value = _deserialized(payload)
                value isa _OnDisk && return _load_published(o, name, args, kwargs, status, value.path)
                return value isa _Address ? _resolve(value, _requester_objects(o)) : value
            elseif kind === :failed
                _throw_remote(o, name, args, kwargs, pid, _deserialized(payload))
            elseif kind === :abandoned
                throw(ComputeAbandoned(payload, true))
            end
        end
    finally
        interrupter === nothing || close(interrupter)
        lock(() -> delete!(conn.inflight, req.id), conn.lock)
    end
end

# Send `req` to the worker, starting one first if none runs. A worker found dead at the send
# (it exited before this process noticed) is replaced once: nothing ran there yet.
function _submit!(q, req::_RemoteRequest, o, name, args, kwargs, packages, message)
    conn = q.conn
    for attempt in 1:2
        w = try
            _ensure_worker!(q)
        catch err
            throw(ComputeAbandoned("the worker process could not be started: " * sprint(showerror, err), true))
        end
        lock(() -> req.worker = w, conn.lock)
        try
            _ensure_packages!(conn, w, packages)
            _remote_fetch(conn, w, _worker_submit, message...)
            return w, w.proc_pid
        catch err
            if err isa Malt.TerminatedWorkerException
                lock(() -> conn.worker === w && (conn.worker = nothing), conn.lock)
                attempt == 1 && continue
                throw(ComputeAbandoned("the worker process (pid $(w.proc_pid)) exited before it started", true))
            end
            _throw_remote(o, name, args, kwargs, w.proc_pid,
                          err isa Malt.RemoteException ? err.message : sprint(showerror, err))
        end
    end
end

# A DO object a worker computation returned is rebuilt here from its address, starting at the
# requesting object's own root when the address starts there, so it is the object this
# process already holds (`root.child(k)` is the memoized child of this root).
function _requester_objects(o)
    root = _retained_object(_root_of(o))
    (; lock=ReentrantLock(), dict=Dict{Any,Any}((typeof(root), root.__hash__) => root))
end

_throw_remote(o, name, args, kwargs, pid, text::AbstractString) =
    throw(PropertyComputationError(string(nameof(typeof(o))), name, args, Tuple(pairs(kwargs)),
        (RemoteComputationError(pid, text), nothing)))

# Whether the worker's progress tree can be rebuilt under the requester's node `status`.
_mirrorable(status) = status isa Treebars.ProgressNode{<:Treebars.StateProgress}

# The replica of the worker's progress tree under the requester's node `status`; a viewer's
# Stop on it reaches the worker's node.
function _replica(status, conn, w, id)
    _mirrorable(status) || return nothing
    Treebars.progress_replica(status; on_interrupt = node_id -> try
        _remote_do(conn, w, _worker_interrupt, id, Int(node_id))
    catch
    end)
end

# Without a mirror: forward an interrupt requested on the requester's node of the computation
# to the worker's node, once.
function _forward_interrupts(conn, w, id, status)
    status isa Treebars.ProgressNode || return nothing
    Timer(0.1; interval=0.1) do t
        Treebars.interrupt_requested(status) || return
        close(t)
        try
            _remote_do(conn, w, _worker_interrupt, id)
        catch
        end
    end
end

# The worker published `name`'s disk entry: load it here, as the disk branch of
# `_computeproperty` would.
function _load_published(o, name::Symbol, args, kwargs, status, worker_path::String)
    vname = Val(name)
    path = get_cache_path(o, name, args...; kwargs...)
    path == worker_path || error("the worker published `$(name)` at $(worker_path), but this " *
        "process reads it at $(path): the two processes do not agree on the cache location")
    get_cache_status(path) === :ready || error("the worker published `$(name)` at $(path), " *
        "but the entry is gone (invalidated meanwhile?)")
    _report_disk_load!(status, path, filesize(path))
    value = load(_disk_format(o, vname), path, _disk_eltype(o, vname))
    isempty(args) || _record_accessed_key(o, name, args, kwargs)
    value
end

# Re-emit a forwarded log record through the requester's logger.
function _emit_log(record, pid)
    level, message, modname, group, id, file, line, kwargs = record
    logger = ScopedValues.current_logger()
    lvl = Base.CoreLogging.LogLevel(level)
    lvl < Base.CoreLogging.min_enabled_level(logger) && return
    mod = something(_loaded_module(modname), @__MODULE__)
    Base.CoreLogging.shouldlog(logger, lvl, mod, group, id) || return
    Base.CoreLogging.handle_message(logger, lvl, message, mod, group, id, file, line;
                                    kwargs..., worker=pid)
    nothing
end
function _loaded_module(name::AbstractString)
    for m in Base.loaded_modules_array()
        string(nameof(m)) == name && return m
    end
    nothing
end

# --- Invalidation forwarding ------------------------------------------------------------------

# Forward an invalidation of `o` to the worker, which applies it to the object it holds at the
# same address (and ignores it when it holds none). `address` is computed by the caller
# before it invalidates, while `o` is still held by its parent.
function _forward_invalidation(address, verb::Symbol, args...)
    address === nothing && return nothing
    q = job_queue()
    conn = q.conn
    w = lock(() -> conn.worker, conn.lock)
    _worker_alive(w) || return nothing
    try
        _remote_do(conn, w, _worker_invalidate, address, verb, args...)
    catch err
        @debug "DynamicObjects: forwarding an invalidation to the worker failed" exception = err
    end
    nothing
end

# Forward the invalidation of one indexed entry.
function _forward_entry_invalidation(o, name::Symbol, indices::Tuple, kwargs::NamedTuple)
    address = _invalidation_address(o)
    address === nothing && return nothing
    wired = try
        (_wire(indices), _wire(kwargs))
    catch
        return nothing
    end
    _forward_invalidation(address, :invalidate!, name, wired...)
end

# The address an invalidation of `o` forwards to, or `nothing` (no worker, or the worker
# cannot hold `o`).
function _invalidation_address(o)
    _WORKERS_ACTIVE[] || return nothing
    _is_dynamic_object(o) || return nothing
    q = job_queue()
    _worker_alive(lock(() -> q.conn.worker, q.conn.lock)) || return nothing
    try
        _address(o; strict=true)
    catch err
        err isa _NotAddressable || @debug "DynamicObjects: no worker address for an invalidation" exception = err
        nothing
    end
end

# --- Status and control -------------------------------------------------------------------------

"""
    DynamicObjects.worker_status(q=job_queue()) -> NamedTuple

The worker process of `q`: `(; workers, running, pid, started_at, in_flight, last_message_at)`.
`workers` is the configured count; `running` whether a worker process is up; `pid` its process
id (`nothing` without one); `started_at` and `last_message_at` are `time()` stamps of its start
and of the last batch of events it sent (`nothing` before the first); `in_flight` counts the
computations this process waits for it to finish. A watchdog that finds a worker stuck (no
message and no CPU for a while) calls [`restart_worker!`](@ref DynamicObjects.restart_worker!).
"""
function worker_status(q=job_queue())
    conn = q.conn
    lock(conn.lock) do
        running = _worker_alive(conn.worker)
        (; workers=q.workers, running, pid=running ? conn.pid : nothing,
           started_at=running ? conn.started_at : nothing, in_flight=length(conn.inflight),
           last_message_at=running && !isnan(conn.last_message_at) ? conn.last_message_at : nothing)
    end
end

"""
    DynamicObjects.restart_worker!(q=job_queue()) -> NamedTuple

Stop `q`'s worker process through its own process handle (asked to exit, then `SIGTERM`, then
`SIGKILL`), which fails every computation in flight there with [`ComputeAbandoned`](@ref); the
next worker-bound computation starts a fresh worker, or one starts at once under
`worker_start=:now`. Returns [`worker_status`](@ref DynamicObjects.worker_status).
"""
function restart_worker!(q=job_queue())
    _stop_worker!(q)
    q.workers > 0 && q.worker_start === :now && _start_worker_soon!(q)
    worker_status(q)
end

function _stop_worker!(q)
    conn = q.conn
    w = lock(() -> conn.worker, conn.lock)
    w === nothing && return nothing
    _stop_process(conn, w)
    _abandon_inflight!(conn, w, "the worker process (pid $(w.proc_pid)) was stopped")
    nothing
end

_start_worker_soon!(q) = errormonitor(Threads.@spawn try
    _ensure_worker!(q)
catch err
    @error "DynamicObjects: starting the worker process failed" exception = (err, catch_backtrace())
end)

"""
    DynamicObjects.run!(produce, d::DeferredCompute) -> Bool

Run `d` with `produce(status)` in place of its own computation: whatever `produce` returns is
published for `d`'s key, and whatever it throws is recorded as the key's failure, exactly as
[`run!(d)`](@ref run!) publishes or records its own computation's outcome. So the in-flight
fence (a computation invalidated meanwhile publishes nothing), `property_settled`, the waiters
and [`Pending`](@ref) handles behave as for a local computation. `produce` runs on the calling
task, under the requester's logger and `ScopedValue`s; `status` is `d`'s progress node, started
before `produce` is called. Returns `false` without calling `produce` if `d` was already run or
abandoned. An executor that computes elsewhere — DynamicObjects' worker process — publishes
through it.
"""
function run!(produce, d::DeferredCompute)
    _claim!(d) || return false
    f = d.f
    producer = f isa _Settling ? _Settling(produce, f.o, f.name, f.args, f.kwargs, f.local_value) : produce
    try
        _as_requested(d.requester) do
            _run_cache_compute!(d.cache, d.key, d.latch, producer, d.status)
        end
    catch
        # recorded in `d.cache.errors` and the substatus by `_run_cache_compute!`
    end
    true
end

# `run!(produce, c)` for a queued fresh call: its caller receives `produce(status)`.
function run!(produce, c::QueuedCall)
    _claim!(c) || return false
    _start_substatus!(c.status)
    outcome = try
        (true, _as_requested(() -> produce(c.status), c.requester))
    catch err
        (false, err)
    end
    _copy_compute_status!(c.f, produce)
    put!(c.outcome, outcome)
    true
end

# A fresh computation of property `name`, as `fresh` and a progress-threaded call queue it.
mutable struct _FreshCompute{O,A<:Tuple,K<:NamedTuple}
    o::O
    name::Symbol
    args::A
    kwargs::K
    status::Any
    progress_outcome::Symbol
end
_FreshCompute(o, name, args, kwargs, status) = _FreshCompute(o, name, args, kwargs, status, :pending)
(c::_FreshCompute)() = _computeproperty(c.o, c.name, c.args...; __status__=c.status, c.kwargs...)

# A fresh caller finalizes its own node after the queued call returns. Carry the
# worker's ownership of the terminal state back to that caller before waking it.
_copy_compute_status!(compute, produce) = nothing
_copy_compute_status!(compute::_FreshCompute, produce::_WorkerCompute) =
    (compute.progress_outcome = produce.progress_outcome; nothing)
_finish_compute_status!(f::Union{_WorkerCompute,_FreshCompute}, status) =
    f.progress_outcome === :done ? nothing : _finalize_substatus!(status)
_fail_compute_status!(f::Union{_WorkerCompute,_FreshCompute}, status, err) =
    f.progress_outcome === :failed ? nothing : _fail_substatus!(status, err)
