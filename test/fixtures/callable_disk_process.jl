# Public cold-process fixture: file logging proves actual computation without
# mutating any captured state, input, retained callback argument or cached value.
module CallableDiskProcess
using DynamicObjects, Serialization, Test

const IMPLEMENTATION_VERSION = VersionNumber(ARGS[3])
@eval named_total(input) = $(parse(Int, ARGS[4])) * sum(input)
scaled(factor) = input -> factor * sum(input)
above(threshold) = input -> count(>(threshold), input)
struct OffsetTotal
    offset::Int
end
(f::OffsetTotal)(input) = sum(input) + f.offset
record(path, operation) = open(path, "a") do io
    println(io, operation)
end

@eval @dynamicstruct struct CallableOwner
    input::Vector{Float64}
    trace = joinpath(__cache_base__, "executions.txt")
    allow_compute = true
    @cached $IMPLEMENTATION_VERSION statistic(f) = begin
        allow_compute || error("cold hit recomputed statistic")
        record(trace, "statistic")
        [f(input)]
    end
    @cached $IMPLEMENTATION_VERSION keyword(; f) = begin
        allow_compute || error("cold hit recomputed keyword")
        record(trace, "keyword")
        [f(input)]
    end
    @cached $IMPLEMENTATION_VERSION bundle(statistics) = begin
        allow_compute || error("cold hit recomputed bundle")
        record(trace, "bundle")
        map(f -> f(input), statistics)
    end
    @mmap $IMPLEMENTATION_VERSION numeric(statistics) = begin
        allow_compute || error("cold hit recomputed mmap")
        record(trace, "numeric")
        Float64[Base.values(map(f -> f(input), statistics))...]
    end
end

function main(base, mode, capture, expected_factor)
    input = [1.0, 2.0, 3.0]
    original = copy(input)
    o = CallableOwner(input; __cache_base__=base, __status__=nothing,
                      allow_compute=mode == "compute")
    existing = isdir(base) ? [(joinpath(dir, name), read(joinpath(dir, name)))
        for (dir, _, names) in walkdir(base) for name in names
        if endswith(name, ".sjl") && any(prefix -> startswith(name, prefix),
            ("statistic_", "keyword_", "bundle_", "numeric_"))] : []

    functions = (named_total, sum, scaled(capture), scaled(3), OffsetTotal(4))
    outputs = map(f -> o.statistic(f), functions)
    retained = copy(first(outputs))
    @test outputs == ([6.0expected_factor], [6.0], [6.0capture], [18.0], [10.0])
    @test o.statistic(first(functions)) === first(outputs)
    keywords = (o.keyword(f=scaled(capture)), o.keyword(f=scaled(3)))
    @test keywords == ([6.0capture], [18.0])
    statistics = (total=named_total, above=above(capture))
    bundle = o.bundle(statistics)
    numeric = o.numeric(statistics)
    @test bundle == (total=6.0expected_factor, above=count(>(capture), original))
    @test numeric == collect(values(bundle))
    @test first(outputs) == retained
    @test input == original
    @test all(file -> read(first(file)) == last(file), existing)

    snapshot = (; segments=map(f -> DynamicObjects.cache_segment(:statistic, f), functions),
        outputs, keywords, bundle, numeric=copy(numeric), input=copy(input),
        paths=map(f -> DynamicObjects.get_cache_path(o, :statistic, f), functions))
    Serialization.serialize(joinpath(base, "snapshot.sjl"), snapshot)
    println("CALLABLE-PROCESS-OK ", mode, " v", IMPLEMENTATION_VERSION)
end
end
CallableDiskProcess.main(ARGS[1], ARGS[2], parse(Int, ARGS[5]), parse(Int, ARGS[6]))
