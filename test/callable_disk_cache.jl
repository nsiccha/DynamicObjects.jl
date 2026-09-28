using TestItemRunner

@testitem "callable disk keys reuse across cold processes and honor explicit code versions" tags=[:core] begin
using DynamicObjects, Serialization

base = mktempdir()
script = normpath(joinpath(dirname(pathof(DynamicObjects)), "..", "test", "fixtures", "callable_disk_process.jl"))
project = dirname(Base.active_project())
run_fixture(mode, version, factor, capture, expected_factor=factor) = begin
    output = read(`$(Base.julia_cmd()) --startup-file=no --project=$project $script $base $mode $version $factor $capture $expected_factor`, String)
    @test occursin("CALLABLE-PROCESS-OK", output)
    Serialization.deserialize(joinpath(base, "snapshot.sjl"))
end
executions() = length(readlines(joinpath(base, "executions.txt")))

first_request = run_fixture("compute", "1", 1, 2)
@test executions() == 9
cold_hit = run_fixture("hit", "1", 1, 2)
@test cold_hit == first_request
@test executions() == 9
@test length(unique(first_request.segments)) == 5

# A named method's implementation is NOT its serialized identity. This positive
# control documents why callers must bump the computation's implementation version.
unversioned_code_change = run_fixture("hit", "1", 2, 2, 1)
@test unversioned_code_change == first_request
@test executions() == 9

changed_capture = run_fixture("compute", "1", 1, 4)
@test changed_capture.segments[3] != first_request.segments[3]
@test changed_capture.outputs[3] == [24.0]
@test changed_capture.bundle.above == 0
@test executions() == 13 # positional, keyword, bundle, mmap each miss once
@test run_fixture("hit", "1", 1, 4) == changed_capture
@test executions() == 13

versioned = run_fixture("compute", "2", 2, 2)
@test versioned.segments == first_request.segments
@test versioned.paths != first_request.paths
@test versioned.outputs[1] == [12.0]
@test versioned.bundle.total == 12.0
@test executions() == 22
@test run_fixture("hit", "2", 2, 2) == versioned
@test executions() == 22
end
