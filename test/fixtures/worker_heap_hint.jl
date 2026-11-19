using Test, DynamicObjects

const DO = DynamicObjects
const PARENT_HINT = parse(UInt64, only(ARGS))

function worker_options(q, conn=only(q.conns))
    w = DO._ensure_worker!(q, conn)
    # Evaluate in the actual Malt worker, without serializing a Main-defined function.
    code = :((hint=Base.JLOptions().heap_size_hint,
              threads=(Threads.nthreads(:default), Threads.nthreads(:interactive)),
              project=Base.active_project(), pid=getpid()))
    task = DO._on_actor(() -> DO.Malt.remote_eval(w.handle, code), conn)
    fetch(task)
end

@testset "worker heap hint: parent=$PARENT_HINT" begin
    @test Base.JLOptions().heap_size_hint == PARENT_HINT
    # Exercise automatic inheritance with default/custom threads and both
    # spellings of an explicit override. A zero parent value means no hint was set.
    cases = (
        (nothing, PARENT_HINT, (1, 1), :lazy),
        (["--threads=2,1"], PARENT_HINT, (2, 1), :now),
        (["--threads=1,1", "--heap-size-hint=1G"], UInt64(1024^3), (1, 1), :lazy),
        (["--threads=1,1", "--heap-size-hint", "1G"], UInt64(1024^3), (1, 1), :now),
    )
    for (custom, expected, threads, start) in cases
        q = DO.JobQueue()
        before = custom === nothing ? nothing : copy(custom)
        try
            DO.configure_queue!(q; workers=1, worker_exeflags=custom, worker_start=start)
            first = worker_options(q)
            @test first.hint == expected
            @test first.threads == threads
            @test first.project == Base.active_project()
            @test first.pid != getpid()
            @test Base.JLOptions().heap_size_hint == PARENT_HINT
            @test custom == before
            if custom === nothing
                flags = DO._worker_exeflags(q, 1)
                count_hint(xs) = count(f -> f == "--heap-size-hint" || startswith(f, "--heap-size-hint="), xs)
                @test count_hint(flags) == max(count_hint(Base.julia_cmd().exec[2:end]), Int(PARENT_HINT != 0))
                DO.restart_worker!(q)
                replacement = worker_options(q)
                @test replacement.pid != first.pid
                @test replacement.hint == expected
                @test replacement.threads == threads
            end
        finally
            DO.configure_queue!(q; workers=0)
        end
    end
end

@testset "pool divides the inherited heap hint across actual worker processes" begin
    q = DO.JobQueue()
    try
        DO.configure_queue!(q; workers=2, worker_start=:now)
        opts = [worker_options(q, conn) for conn in q.conns]
        @test all(o -> o.hint == PARENT_HINT ÷ 2 && o.threads == (1, 1), opts)
        @test opts[1].pid != opts[2].pid
        @test Base.JLOptions().heap_size_hint == PARENT_HINT
    finally
        DO.configure_queue!(q; workers=0)
    end
end
