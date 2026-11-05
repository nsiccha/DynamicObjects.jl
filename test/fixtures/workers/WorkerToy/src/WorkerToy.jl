# A toy application package for `test/workers.jl`: its `@queued` properties run in the
# worker process once a test configures `workers=1`. Every value carries the id of the process
# that computed it and how many computations of that property the process has run, so a test
# tells worker results from local ones and counts recomputations. Gates are files, which both
# processes see.
module WorkerToy
using DynamicObjects
import DynamicObjects.Treebars
export Toy, settled_count, reset_settled!

# Nested modules and custom value conversion must resolve to the worker's own bindings.
module RequestContext
using DynamicObjects
const SV = DynamicObjects.ScopedValues
const AUDIENCE = SV.ScopedValue(:public)
const PAGE = SV.ScopedValue((lang=:en,))
const TEXT = SV.ScopedValue(Ref("default"))
const LOCAL_ONLY = SV.ScopedValue(:default)
snapshot() = (audience=AUDIENCE[], page=PAGE[], text=TEXT[][], local_only=LOCAL_ONLY[])
function to_wire(value)
    value[] == "fail-wire" && error("context wire failed")
    (:text, value[])
end
function from_wire(value)
    value[1] === :text || error("context wire format lost")
    value[2] == "fail-unwire" && error("context unwire failed")
    Ref(value[2])
end
function __init__()
    DynamicObjects.carry_to_worker!(@__MODULE__, :AUDIENCE)
    DynamicObjects.carry_to_worker!(@__MODULE__, :PAGE)
    DynamicObjects.carry_to_worker!(@__MODULE__, :TEXT; wire=to_wire, unwire=from_wire)
end
end

const COMPUTED = Dict{Symbol,Int}()
const COMPUTED_LOCK = ReentrantLock()
computed!(name) = lock(() -> COMPUTED[name] = get(COMPUTED, name, 0) + 1, COMPUTED_LOCK)

# `property_settled` calls in this process, per property.
const SETTLED = Dict{Symbol,Int}()
const SETTLED_LOCK = ReentrantLock()
settled_count(name) = lock(() -> get(SETTLED, name, 0), SETTLED_LOCK)
reset_settled!() = lock(() -> empty!(SETTLED), SETTLED_LOCK)

# Read the source node through the test's worker connection, so the test can compare
# exact completed durations rather than accepting a requester-side re-finalization.
const COUNTED_NODES = Dict{Int,Any}()
const COUNTED_LOCK = ReentrantLock()
counted_duration(n) = Treebars.duration(lock(() -> COUNTED_NODES[n], COUNTED_LOCK))

# A transport request can re-resolve after invalidation and wait for a replacement.
# Retain the actual computing task to observe when the old disk publisher is done.
const DISK_TASKS = Dict{Int,Task}()
const DISK_TASKS_LOCK = ReentrantLock()
disk_task_finished(n) = istaskdone(lock(() -> DISK_TASKS[n], DISK_TASKS_LOCK))

waitfile(path) = while !isfile(path)
    sleep(0.02)
end

@dynamicstruct struct Toy
    base::Int
    root::String
    __cache_base__ = root
    __req__ = nothing
    __prefix__ = ""
    "Memory-tier item"
    @queued square(x::Int) = (pid=getpid(), n=computed!(:square), value=base * x^2)
    "Disk-tier item"
    @queued @cached cube(x::Int) = (pid=getpid(), n=computed!(:cube), value=base * x^3)
    "Gated item"
    @queued gated(x::Int; dir::String) = begin
        touch(joinpath(dir, "started_$(x)_$(computed!(:gated))"))
        waitfile(joinpath(dir, "go_$x"))
        (pid=getpid(), n=COMPUTED[:gated], value=base + x)
    end
    "Gated disk item"
    @queued @cached gated_disk(x::Int; dir::String) = begin
        n = computed!(:gated_disk)
        lock(() -> DISK_TASKS[n] = current_task(), DISK_TASKS_LOCK)
        touch(joinpath(dir, "disk_started_$(x)_$n"))
        waitfile(joinpath(dir, "disk_go_$(x)_$n"))
        (pid=getpid(), n=n, value=base + x)
    end
    "Failing item"
    @queued doomed(x::Int) = error("doomed $x")
    "Request-reading item"
    @queued reads_request(x::Int) = (pid=getpid(), req=__req__, value=x)
    "Talking item"
    @queued talks(x::Int) = begin
        DynamicObjects.send_to_requester(:toy, (x, getpid()))
        @info "toy log" x
        DynamicObjects.send_to_requester(:toy, (x + 1, getpid()))
        x
    end
    "Interruptible item"
    @queued stoppable(x::Int; dir::String) = begin
        touch(joinpath(dir, "stoppable_$x"))
        while !Treebars.interrupt_requested(__status__)
            sleep(0.02)
        end
        (pid=getpid(), value=:interrupted)
    end
    "Counted item"
    @queued @progress counted(n::Int; dir::String) = begin
        lock(() -> COUNTED_NODES[n] = __status__, COUNTED_LOCK)
        Treebars.@progress "Steps" for i in 1:n
            i == n ÷ 2 + 1 && (touch(joinpath(dir, "half_$n")); waitfile(joinpath(dir, "go_$n")))
        end
        DynamicObjects.send_to_requester(:counted_end, n)
        n
    end
    "Fresh item"
    @queued @fresh fresh_item(x::Int) = (pid=getpid(), n=computed!(:fresh_item), value=x)
    "Requester context, read by a child task"
    @queued context(x::Int) = (pid=getpid(), context=fetch(Threads.@spawn RequestContext.snapshot()))
    "Fresh requester context"
    @queued @fresh fresh_context(x::Int) = (pid=getpid(), context=RequestContext.snapshot())
    "Context held across concurrent worker requests"
    @queued gated_context(x::Int; dir::String) = begin
        touch(joinpath(dir, "context_$x"))
        waitfile(joinpath(dir, "context_go_$x"))
        (pid=getpid(), context=RequestContext.snapshot())
    end
    "Read a separately registered package, loaded after this worker started"
    @queued late_context(x::Int) = begin
        id = Base.PkgId(Base.UUID("3bdc1aa0-83eb-41fb-9fb2-b4955339e07c"), "WorkerScopeLate")
        (pid=getpid(), value=Base.root_module(id).VALUE[])
    end
    "Prefix-reading item"
    @queued prefixed(x::Int) = (pid=getpid(), value=string(__prefix__, x))
    "Child-returning item"
    @queued kid(k::Int) = child(k)
    @struct child(k::Int) = begin
        "Child item"
        @queued scaled(x::Int) = (pid=getpid(), value=base * k * x)
    end
    @struct context_child(k::Int; audience::Symbol=RequestContext.AUDIENCE[]) = begin
        "The scope under which this child's constructor path was evaluated"
        @queued constructor_context(x::Int) = (pid=getpid(), audience=audience)
    end
    DynamicObjects.property_settled(__self__, ::Val{name}, value, args...; kwargs...) where {name} =
        lock(() -> SETTLED[name] = get(SETTLED, name, 0) + 1, SETTLED_LOCK)
end

end
