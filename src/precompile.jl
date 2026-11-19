# Warm shared implementation paths with synthetic values. This module is private;
# the workload runs only while precompiling and launches no worker processes.
module _PrecompileWorkload
using ..DynamicObjects
using PrecompileTools: @compile_workload
const DO = DynamicObjects

@dynamicstruct struct Workload
    input::Int
    value = input + 1
    indexed(i::Int) = input + i
    @options(input) = 1:3
end

@compile_workload begin
    let object = Workload(1000; __status__=nothing)
        object.value
        object.indexed(3)
        object.indexed(3)
        property_options(object, :input)
        property_descriptors(Workload)
        declaration_graph(Workload)
        # Reflection and route builders can read declaration pairs through an
        # abstract container, even when the workload inlines these small calls.
        entry = Pair{Symbol,DO._DeclarationInfo}
        precompile(Base.indexed_iterate, (entry, Int))
        precompile(Base.indexed_iterate, (entry, Int, Int))
        precompile(DO.isfixed, (DO._DeclarationInfo,))
        precompile(get, (DO._DeclarationInfo, Symbol, Tuple{}))
        precompile(get, (DO._DeclarationInfo, Symbol, Nothing))
        remake(object)
        remake(object; input=2000)

        # Exercise the request address and reply framing in memory. The
        # blocking launch, worker initialization and pump entry points are
        # compiled by signature so no process or background task survives.
        address = DO._address(object)
        DO._packages!(Set{Base.PkgId}(), address)
        call = DO._WorkerCall(DO._worker_require, (Base.PkgId[],))
        DO._deserialized(take!(DO._serialized_buffer(call)))
        precompile(call, ())
        DO._push_event!(1, :done, address, "indexed(3)", typemax(Int))
        batch = DO._worker_take_events()
        DO._deserialized(only(batch)[5])
        DO.configure_queue!(DO.JobQueue(); workers=0, worker_start=:lazy, worker_preload=[DO])
        precompile(DO._spawn_worker!, (DO.JobQueue, DO._WorkerConn, Base.Event))
        precompile(DO._open_queue_worker, (DO._WorkerConn, Vector{String}, Vector{Base.PkgId}, Base.Event))
        precompile(DO._ensure_packages!, (DO._WorkerConn, DO._QueueWorker, Vector{Base.PkgId}))
        precompile(DO._actor_loop, (DO._WorkerConn,))
        precompile(DO._event_pump, (DO._WorkerConn, DO._QueueWorker))
        precompile(DO._init_preloaded_worker!, (Vector{Base.PkgId},))
        precompile(DO._worker_boot_info, ())
        precompile(DO._worker_take_events, ())
        precompile(DO.Malt.remote_call, (typeof(Base.invokelatest), DO.Malt.Worker, DO._WorkerCall))
        precompile(DO._worker_require, (Vector{Base.PkgId},))
        precompile(DO._worker_control_loop, ())
    end
end
end
