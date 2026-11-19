using TestItemRunner

@testitem "scoped cache entries follow their readers" tags=[:core] begin
using DynamicObjects
@dynamicstruct struct Sample
    offset::Int
    @state custom = Ref(1)
    item(i::Int) = [offset + i]
    subtotal = first(item(2)) + first(item(3))
end
o = Sample(10)
keysheld() = sort([first(first(e.key)) for e in mem_cache_entries(o) if e.property === :item])
pre = o.item(1)
state = o.custom
ver = object_version(o)
result = with_compute_scope() do
    @test o.subtotal == 25
    shared = o.item(2)
    with_compute_scope() do
        @test o.item(2) === shared
        o.item(4)
    end
    @test keysheld() == [1,2,3]
    shared
end
@test result == [12]
@test keysheld() == [1]
@test o.item(1) === pre && o.custom === state
@test object_version(o) == ver
@test_throws ErrorException with_compute_scope() do
    o.item(6)
    error("report failed")
end
@test keysheld() == [1]

ready = Channel{Nothing}(1)
release = Channel{Nothing}(1)
one = Threads.@spawn with_compute_scope() do
    o.item(7)
    put!(ready, nothing)
    take!(release)
end
take!(ready)
adopted = o.item(7)
put!(release, nothing)
fetch(one)
@test o.item(7) === adopted
@test keysheld() == [1,7]

first_done = Channel{Nothing}(1)
second_read = Channel{Nothing}(1)
finish_first = Channel{Nothing}(1)
finish_second = Channel{Nothing}(1)
a = Threads.@spawn with_compute_scope() do
    o.item(8)
    put!(first_done, nothing)
    take!(finish_first)
end
take!(first_done)
b = Threads.@spawn with_compute_scope() do
    o.item(8)
    put!(second_read, nothing)
    take!(finish_second)
end
take!(second_read)
put!(finish_first, nothing)
fetch(a)
@test 8 in keysheld()
put!(finish_second, nothing)
fetch(b)
@test keysheld() == [1,7]
end

@testitem "worker report releases six intermediate buffers" setup=[WorkerFixtures] tags=[:core,:workers] begin
using DynamicObjects, WorkerToy
report = WorkerToy.ScopedReport(1)
@test prune_worker_mem_caches!(Returns(false), report) == (objects=0, kept=0, evicted=0)
with_worker() do
    output = with_compute_scope() do
        sums = [report.render(i) for i in 1:6]
        @test report.census() == 6 * 1024^2
        @test WorkerToy.buffer_census(report) == 0
        sums
    end
    @test output == (1:6) .* 1024^2
    @test report.census() == 0
    report.render(1)
    @test prune_mem_caches!(Returns(false), report).evicted == 0
    @test report.census() == 1024^2
    @test prune_worker_mem_caches!(Returns(false), report).evicted == 1
    @test report.census() == 0
    @test prune_worker_mem_caches!(Returns(false), WorkerToy.ScopedReport(987)).objects == 0

    # Two reports read the same worker key. Closing one only drops its own
    # claim, and an ordinary worker read can adopt the shared result.
    with_compute_scope() do
        report.render(4)
        with_compute_scope() do
            report.render(4)
            report.render(5)
        end
        @test report.census() == 1024^2
    end
    @test report.census() == 0
    ready = Channel{Nothing}(1)
    finish = Channel{Nothing}(1)
    export_task = Threads.@spawn with_compute_scope() do
        report.render(3)
        put!(ready, nothing)
        take!(finish)
    end
    take!(ready)
    try
        @test report.render(3) == 3*1024^2
    finally
        put!(finish, nothing)
    end
    fetch(export_task)
    @test report.census() == 1024^2
    @test_throws Exception prune_worker_mem_caches!(Returns(:invalid), report)
    @test prune_worker_mem_caches!(Returns(false), report).evicted == 1
    mktempdir() do dir
        toy = Toy(2, dir)
        pending = toy.gated(7; dir, fetch=identity)
        @test waitfor(joinpath(dir, "started_7_1"))
        try
            @test with_compute_scope(() -> report.render(1)) == 1024^2
            prune_worker_mem_caches!(Returns(false), toy)
            @test !isready(pending)
        finally
            touch(joinpath(dir, "go_7"))
        end
        v = fetch(pending)
        @test v.pid == worker_pid() && v.n == 1 && v.value == 9
    end
end
end

@testitem "scoped automatic storage keeps a warm mapping and releases a cold one" setup=[SemanticFixtures] tags=[:core] begin
using DynamicObjects
mktempdir() do dir
    GOVERNED_MATERIALIZATION_CACHE_BASE[] = dir
    o = GovernedMaterializationFixture(1, 7)
    context = (; scope=:job, key=(; job=:report), retention=(; max_entries=1, ttl=60.0))
    warm = o.large_array(2)
    promoted = with_compute_scope(() -> execute_materialization(context, o, :large_array, 2))
    @test promoted == warm
    @test only(cached_entries(o.large_array)).second === promoted
    reloaded = with_compute_scope(() -> execute_materialization(context, o, :large_array, 2))
    @test only(cached_entries(o.large_array)).second === reloaded
    cold = with_compute_scope(() -> execute_materialization(context, o, :large_array, 3))
    @test length(cached_entries(o.large_array)) == 1
    @test isfile(DynamicObjects.get_cache_path(o, :large_array, 3))
    @test all(==(21.0), cold)
end
end

@testitem "a caller cache hit keeps the same fit available to worker-side plots" setup=[WorkerFixtures] tags=[:core,:workers] begin
using DynamicObjects, WorkerToy
report = WorkerToy.ScopedReport(21)
with_worker() do
    function worker_pins()
        conn = only(DynamicObjects.job_queue().conns)
        DynamicObjects._remote_fetch(conn, conn.worker, Core.eval, DynamicObjects,
                                     :(length(_WORKER_RESULT_PINS)))
    end
    function start_report(i)
        ready, finish = Channel{Int}(1), Channel{Nothing}(1)
        task = Threads.@spawn with_compute_scope() do
            put!(ready, report.fit(i))
            take!(finish)
        end
        take!(ready), () -> (put!(finish, nothing); fetch(task))
    end

    fit, close_first = start_report(1)
    with_compute_scope() do
        @test report.fit(1) == fit  # served entirely in the caller
        close_first()
        @test report.plot_fit(1) == fit
    end
    @test isempty(cached_entries(report.fit))
    @test worker_pins() == 0
    @test report.plot_fit(1) != fit  # both scope claims ended

    fit, close_first = start_report(2)
    @test report.fit(2) == fit       # an ordinary caller adopts the warm result
    close_first()
    @test report.plot_fit(2) == fit
    @test worker_pins() == 0
end
end

@testitem "planned targets release last uses and preserve unknown future reads" tags=[:core] begin
using DynamicObjects
@dynamicstruct struct Batch
    input::Vector{Int}
    data = input
    first = data
    again = data
    tail = 17
    indirect = indirect_read(__self__)
    keyed(i::Int; multiplier=1) = i * multiplier
end
indirect_read(o) = o.data
o = Batch([4])
# Observe the same boundaries that the public batch runner advances. Observing
# them in a property hook would itself add an opaque dependency to this graph.
function snapshots_for(names)
    specs = DynamicObjects._target_spec.(names)
    scope = DynamicObjects._new_compute_scope(DynamicObjects._target_lifetimes(Batch, specs))
    DynamicObjects._with_compute_scope(scope) do
        map(names) do name
            getproperty(o, name)
            held = Set(e.property for e in mem_cache_entries(o) if e.role === :derived)
            DynamicObjects._target_delivered!(scope)
            held
        end
    end
end
outputs = compute_targets(o, [:first, :again, :tail])
@test outputs[1] === outputs[2]
_, second, last = snapshots_for([:first, :again, :tail])
@test :first ∉ second && :data in second
@test :data ∉ last && :again ∉ last
@test isempty([e for e in mem_cache_entries(o) if e.role === :derived])
outputs = compute_targets(o, [:first, :indirect, :tail])
@test outputs[1] === outputs[2]
_, second, last = snapshots_for([:first, :indirect, :tail])
@test :first in second
@test :first ∉ last
@test compute_targets(o, [(; property=:keyed, args=(4,), kwargs=(; multiplier=3))]) == [12]
@test_throws ArgumentError compute_targets(o, [:missing])
@test_throws ArgumentError compute_targets(o, [(; property=:tail, args=(1,))])

@dynamicstruct struct Hooked
    buffer = [1]
    later = 2
end
observed = Ref{Any}()
DynamicObjects.property_settled(o::Hooked, ::Val{:later}, v) = (observed[] = o.buffer)
result = compute_targets(Hooked(), [:buffer, :later])
@test observed[] === result[1]
end

@testitem "scope keeps replacements, disk results and escaped computations" tags=[:core] begin
using DynamicObjects
@dynamicstruct struct Effects
    root::String
    __cache_base__ = root
    item(i::Int) = [i]
    @cached saved(i::Int) = [i]
    slow(i::Int) = begin
        touch(joinpath(root, "started"))
        while !isfile(joinpath(root, "go"))
            sleep(0.01)
        end
        first(item(i))
    end
end
mktempdir() do dir
    o = Effects(dir)
    started, finish = Channel{Nothing}(1), Channel{Nothing}(1)
    work = Threads.@spawn with_compute_scope() do
        o.item(1)
        put!(started, nothing)
        take!(finish)
    end
    take!(started)
    invalidate!(o.item, 1)
    replacement = o.item(1)
    put!(finish, nothing)
    fetch(work)
    @test o.item(1) === replacement
    with_compute_scope(() -> o.saved(2))
    @test isempty(cached_entries(o.saved))
    @test isfile(DynamicObjects.get_cache_path(o, :saved, 2))
    @test o.saved(2) == [2]
    pending = with_compute_scope() do
        handle = o.slow(3; fetch=identity)
        @test timedwait(() -> isfile(joinpath(dir, "started")), 30) === :ok
        handle
    end
    touch(joinpath(dir, "go"))
    @test fetch(pending) == 3
    @test timedwait(() -> all(e -> first(first(e.first)) != 3, cached_entries(o.item)), 10) === :ok
end
end

@testitem "opaque remount values and held pending results keep their ownership" setup=[RemountOpaqueFixtures] tags=[:core] begin
using DynamicObjects
roq_reset!()
source = ROQ()
v = remount(source; ctx=7)
with_compute_scope() do
    @test v.bare_ctx == (7, 0)
    @test v.ctx_reader(2) == (7, 2)
    v.shares(1)
    v.bare_share
end
@test v.bare_ctx == (7, 0) && roq_calls(:bare_ctx) == 2
@test v.ctx_reader(2) == (7, 2) && roq_calls((:ctx_reader, 2)) == 2
@test v.shares(1)[] == 2 && roq_calls((:shares, 1)) == 2
@test v.bare_share[] == 7 && roq_calls(:bare_share) == 2

@dynamicstruct struct Delayed
    input::Int
    result(i) = [input, i]
end
o = Delayed(2)
jobs = Channel{Any}(1)
handle = with_compute_scope() do
    p = o.result(2; fetch=Deferred(job -> put!(jobs, job)))
    DynamicObjects.run!(take!(jobs))
    @test isready(p)
    p
end
@test isempty(cached_entries(o.result))
@test isready(handle)
v1 = fetch(handle)
@test v1 == [2,2]
@test isempty(cached_entries(o.result))
@test o.result(2) !== v1
end

@testitem "worker scope failure, scoped target lists and worker replacement" setup=[WorkerFixtures] tags=[:core,:workers] begin
using DynamicObjects, WorkerToy
report = WorkerToy.ScopedReport(7)
with_worker() do
    @test_throws ErrorException with_compute_scope() do
        report.render(1)
        error("export failed")
    end
    @test report.census() == 0
    @test compute_targets(report, [(; property=:render, args=(2,)),
                                    (; property=:census)]) == [2*1024^2, 1024^2]
    @test report.census() == 0
    with_compute_scope() do
        report.render(1)
        first_pid = worker_pid()
        DynamicObjects.restart_worker!()
        @test report.render(3) == 3*1024^2
        @test worker_pid() != first_pid
    end
    @test report.census() == 0
end
end
