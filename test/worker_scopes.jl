using TestItemRunner

@testmodule WorkerScopeFixtures begin
using DynamicObjects
const FIXTURES = joinpath(@__DIR__, "fixtures", "workers")
FIXTURES in LOAD_PATH || push!(LOAD_PATH, FIXTURES)
using WorkerToy
const Context = WorkerToy.RequestContext
const SV = DynamicObjects.ScopedValues
export Context, SV, scoped, default_context, private_context
default_context = (audience=:public, page=(lang=:en,), text="default", local_only=:default)
private_context = (audience=:private, page=(lang=:de,), text="request", local_only=:default)
scoped(f) = SV.with(f, Context.AUDIENCE => :private, Context.PAGE => (lang=:de,),
    Context.TEXT => Ref("request"), Context.LOCAL_ONLY => :requester)
end

@testitem "worker scopes: local and remote memoized and fresh calls preserve requester values" setup=[WorkerFixtures, WorkerScopeFixtures] tags=[:core, :workers] begin
using DynamicObjects
for workers in (0, 1)
    DynamicObjects.configure_queue!(; workers)
    try
        t = Toy(1, mktempdir())
        first = scoped(() -> t.context(1))
        expected = workers == 0 ? merge(private_context, (local_only=:requester,)) : private_context
        @test first.context == expected
        @test first.pid == (workers == 0 ? getpid() : worker_pid())
        @test t.context(1) === first  # Scope is not a cache key: the first caller still wins.
        @test t.context(2).context == default_context
        @test scoped(() -> t.fresh_context(1)).context == expected
        @test t.fresh_context(1).context == default_context
        # Local work inherits the complete scope; wire conversion is only for a worker.
        if workers == 0
            @test SV.with(() -> t.context(3), Context.TEXT => Ref("fail-wire")).context.text == "fail-wire"
        else
            # The worker replays this child's omitted default argument while resolving
            # its address. Bind context before that reconstruction, not just the body.
            child = t.context_child(1)
            @test scoped(() -> child.constructor_context(1)).audience == :private
            @test t.context_child(2).constructor_context(1).audience == :public
            DynamicObjects.restart_worker!()
            @test scoped(() -> t.context(3)).context == private_context
            @test t.context(4).context == default_context
        end
    finally
        DynamicObjects.configure_queue!(; workers=0)
    end
end
end

@testitem "worker scopes: delayed admission captures the initiating caller for fresh and memoized work" setup=[WorkerFixtures, WorkerScopeFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    DynamicObjects.configure_queue!(; max_running=1)
    dir = mktempdir()
    try
        t = Toy(1, mktempdir())
        blocker = t.gated(1; dir, fetch=identity)
        waitfor(joinpath(dir, "started_1_1")) || error("blocking worker did not start")
        pending = scoped(() -> t.context(2; fetch=identity))
        fresh = scoped(() -> Threads.@spawn t.fresh_context(3))
        settles(() -> DynamicObjects.queue_settings().queued == 2) || error("context calls did not queue")
        touch(joinpath(dir, "go_1"))
        @test fetch(blocker).value == 2
        @test fetch(pending).context == private_context
        settles(() -> istaskdone(fresh)) || error("fresh context call did not settle")
        @test fetch(fresh).context == private_context
        @test t.context(4).context == default_context
    finally
        touch(joinpath(dir, "go_1"))
        DynamicObjects.configure_queue!(; max_running=0)
    end
end
end

@testitem "worker scopes: concurrent requests and following defaults remain isolated" setup=[WorkerFixtures, WorkerScopeFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    DynamicObjects.configure_queue!(; max_running=2)
    dir = mktempdir()
    try
        t = Toy(1, mktempdir())
        private = scoped(() -> t.gated_context(1; dir, fetch=identity))
        public = t.gated_context(2; dir, fetch=identity)
        all(x -> waitfor(joinpath(dir, "context_$x")), (1, 2)) || error("concurrent contexts did not start")
        touch(joinpath(dir, "context_go_2"))
        @test fetch(public).context == default_context
        touch(joinpath(dir, "context_go_1"))
        @test fetch(private).context == private_context
        @test t.context(3).context == default_context
    finally
        foreach(x -> touch(joinpath(dir, "context_go_$x")), (1, 2))
        DynamicObjects.configure_queue!(; max_running=0)
    end
end
end

@testitem "worker scopes: conversion failures fail the property and release request state" setup=[WorkerFixtures, WorkerScopeFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    t = Toy(1, mktempdir())
    for property in (t.context, t.fresh_context), (i, marker) in enumerate(("fail-wire", "fail-unwire"))
        err = try
            SV.with(() -> property(i), Context.TEXT => Ref(marker))
            nothing
        catch e
            e
        end
        @test err isa PropertyComputationError
        @test occursin(replace(marker, "fail-" => "context ") * " failed", sprint(showerror, err))
        @test settles(() -> DynamicObjects.worker_status().in_flight == 0)
        @test property(10 + i).context == default_context
    end
end
end

@testitem "worker scopes: a registration loads its owning package into an already running worker" setup=[WorkerFixtures, WorkerScopeFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    t = Toy(1, mktempdir())
    pid = t.square(1).pid
    id = Base.PkgId(Base.UUID("3bdc1aa0-83eb-41fb-9fb2-b4955339e07c"), "WorkerScopeLate")
    owner = Base.require(id)
    # This package does not occur in the object's type, arguments or return type.
    result = SV.with(() -> t.late_context(1), owner.VALUE => :late_request)
    @test result == (pid=pid, value=:late_request)
    @test t.late_context(2) == (pid=pid, value=:unset)
    DynamicObjects.restart_worker!()
    @test SV.with(() -> t.late_context(3), owner.VALUE => :restarted).value == :restarted
end
end

@testitem "worker scopes: missing worker registrations fail instead of silently using defaults" setup=[WorkerFixtures, WorkerScopeFixtures] tags=[:core, :workers] begin
using DynamicObjects
with_worker() do
    # Deliberately omit this registration from the fixture's __init__.
    key = DynamicObjects._worker_scope_key(Context, :LOCAL_ONLY)
    DynamicObjects.carry_to_worker!(Context, :LOCAL_ONLY)
    try
        t = Toy(1, mktempdir())
        err = try
            scoped(() -> t.context(1)); nothing
        catch e
            e
        end
        @test err isa PropertyComputationError
        @test occursin("WorkerToy.RequestContext.LOCAL_ONLY is not registered", sprint(showerror, err))
        @test settles(() -> DynamicObjects.worker_status().in_flight == 0)
    finally
        lock(() -> delete!(DynamicObjects._WORKER_SCOPES, key), DynamicObjects._WORKER_SCOPES_LOCK)
    end
    @test Toy(1, mktempdir()).context(2).context == default_context
end
@test_throws ArgumentError DynamicObjects.carry_to_worker!(Main, :anything)
@test_throws ArgumentError DynamicObjects.carry_to_worker!(Context, :missing)
@test_throws ArgumentError DynamicObjects.carry_to_worker!(Context, :snapshot)
end
