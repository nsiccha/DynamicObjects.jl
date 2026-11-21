using TestItemRunner

@testitem "heap pressure trims ordinary requester and worker memos" tags=[:core, :workers] begin
script = joinpath(@__DIR__, "fixtures", "memo_retention.jl")
for mode in ("0", "128M", "process")
    mode == "process" && !(Sys.islinux() || Sys.isapple()) && continue
    flags = mode == "128M" ? ["--heap-size-hint=128M"] : String[]
    cmd = `$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=1,1 $flags $script $mode`
    budget = mode == "process" ? string(128 * 1024^2) : nothing
    @test success(addenv(cmd, "DYNAMICOBJECTS_PROCESS_BUDGET_BYTES" => budget))
end
end

@testitem "process footprint and native cache ownership" tags=[:core] begin
    cases = [("process_memory.jl", String[]), ("native_retention.jl", String[]),
             ("native_declarations.jl", String[])]
    # A fresh allocator makes the growth case independent of pages kept
    # after the lifetime case freed its own buffers.
    if Sys.islinux() || Sys.isapple()
        push!(cases, ("native_retention.jl", ["growth"]))
    end
    for (fixture, args) in cases
        script = joinpath(@__DIR__, "fixtures", fixture)
        cmd = `$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) $script $args`
        cmd = addenv(cmd, "DYNAMICOBJECTS_PROCESS_BUDGET_BYTES" => string(8 * 1024^3))
        @test success(pipeline(cmd; stdout, stderr))
    end
end

@testitem "low-yield process releases back off and recover" tags=[:core] begin
    script = joinpath(@__DIR__, "fixtures", "process_retry.jl")
    cmd = `$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=2 $script`
    @test success(pipeline(cmd; stdout, stderr))
end

@testitem "heap releases follow measured live data" tags=[:core] begin
    script = joinpath(@__DIR__, "fixtures", "heap_measurement.jl")
    cmd = `$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=2 $script`
    @test success(pipeline(cmd; stdout, stderr))
end

@testitem "footprint batches cover the excess and return the pages they free" tags=[:core] begin
    for fixture in ("process_batch.jl", "process_pages.jl")
        script = joinpath(@__DIR__, "fixtures", fixture)
        cmd = `$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) $script`
        # A budget at publication makes results releasable; each script sets its own.
        cmd = addenv(cmd, "DYNAMICOBJECTS_PROCESS_BUDGET_BYTES" => string(8 * 1024^3))
        @test success(pipeline(cmd; stdout, stderr))
    end
end

@testitem "retention order, delivery, ownership and byte accounting" tags=[:core] begin
script = joinpath(@__DIR__, "fixtures", "memo_retention_order.jl")
@test success(`$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=2 --heap-size-hint=8G $script`)
end
