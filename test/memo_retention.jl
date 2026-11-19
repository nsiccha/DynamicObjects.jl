using TestItemRunner

@testitem "heap pressure trims ordinary requester and worker memos" tags=[:core, :workers] begin
script = joinpath(@__DIR__, "fixtures", "memo_retention.jl")
for hint in ("0", "128M")
    flags = hint == "0" ? String[] : ["--heap-size-hint=$hint"]
    @test success(`$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=1,1 $flags $script $hint`)
end
end

@testitem "retention order, delivery, ownership and byte accounting" tags=[:core] begin
script = joinpath(@__DIR__, "fixtures", "memo_retention_order.jl")
@test success(`$(first(Base.julia_cmd().exec)) --startup-file=no --project=$(Base.active_project()) --threads=2 --heap-size-hint=8G $script`)
end
