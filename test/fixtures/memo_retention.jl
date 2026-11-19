using Test, DynamicObjects
push!(LOAD_PATH, joinpath(@__DIR__, "workers"))
using WorkerToy: RetentionRoot

@testset "automatic retention with heap hint $(only(ARGS))" begin
    enabled = only(ARGS) != "0"
    q = DynamicObjects.job_queue()
    @test memo_retention_stats(q).worker === nothing
    DynamicObjects.configure_queue!(q; workers=1)
    try
        mktempdir() do dir
            root = RetentionRoot(dir)
            disk = first(root.saved(1))
            first_build = first(root.blob(1))
            for k in 2:17
                root.blob(k)
            end
            remote_count, builds = root.snapshot()
            local_count = length(cached_entries(root.blob))
            stats = memo_retention_stats(q)
            @test stats.requester.pid != stats.worker.pid
            @test stats.requester.heap_hint_bytes == stats.worker.heap_hint_bytes ==
                (enabled ? 128 * 1024^2 : 0)
            for s in stats
                @test s.live_heap_bytes > 0
                @test enabled == (s.disk > 0 && s.memory > 0)
            end
            @test enabled ? max(remote_count, local_count) < 17 : remote_count == local_count == 17
            @test enabled == (first(root.blob(1)) != first_build)
            @test first(root.saved(1)) == disk
            _, after = root.snapshot()
            @test after[:saved] == builds[:saved] == 1
            @test after[:blob] == builds[:blob] + enabled
        end
    finally
        DynamicObjects.configure_queue!(q; workers=0)
    end
end
