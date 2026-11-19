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
    for fixture in ("process_memory.jl", "native_retention.jl")
        script = joinpath(@__DIR__, "fixtures", fixture)
        cmd = `$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) $script`
        @test success(addenv(cmd, "DYNAMICOBJECTS_PROCESS_BUDGET_BYTES" => string(8 * 1024^3)))
    end
end

@testitem "retention order, delivery, ownership and byte accounting" tags=[:core] begin
script = joinpath(@__DIR__, "fixtures", "memo_retention_order.jl")
@test success(`$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=2 --heap-size-hint=8G $script`)
end
