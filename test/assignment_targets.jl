using TestItemRunner

# Snag `in-invoices-jl-s-8ee4cf2f`: a destructuring assignment whose targets are
# fields of a sibling (`fetch.day, fetch.at = …`) left the sibling name bare, so
# computing the property threw `UndefVarError`. Every read inside an assignment
# target resolves like any other read: the container of a field or index target
# and a type annotation, at any depth of a destructuring.
@testmodule AssignmentTargetFixtures begin
using DynamicObjects
export Attempt, Fetcher, Targets

mutable struct Attempt
    const lock::ReentrantLock
    day::Int
    at::Int
end
Attempt() = Attempt(ReentrantLock(), 0, 0)

@dynamicstruct struct Fetcher
    @state attempt = Attempt()
    # The reported shape: the whole RHS is a do-block that destructures into
    # fields of a `@state` sibling.
    fetched(day::Int) = lock(attempt.lock) do
        attempt.day, attempt.at = day, 10day
        (attempt.day, attempt.at)
    end
    @progress tracked(day::Int) = begin
        attempt.day, attempt.at = day, 2day
        attempt.at
    end
end

@dynamicstruct struct Targets
    @state box = Attempt()
    @state slots = zeros(2)
    slot::Int = 2
    vals = [1.0, 2.0]
    indexed = begin
        buf = zeros(2)
        slots[1], buf[slot] = 3.0, 4.0
        (slots[1], buf[2])
    end
    nested = begin
        (box.day, (box.at, other)) = (5, (6, 7))
        (box.day, box.at, other)
    end
    splatted = begin
        box.day, rest... = 8, 9, 10
        (box.day, rest)
    end
    typed = begin
        x::eltype(vals) = 3
        x
    end
end
end

@testitem "destructuring into sibling fields resolves the sibling" tags=[:core] setup=[AssignmentTargetFixtures] begin
    using DynamicObjects
    f = Fetcher()
    @test f.fetched(3) == (3, 30)
    @test (f.attempt.day, f.attempt.at) == (3, 30)
    @test f.tracked(4) == 8
    @test DynamicObjects.metafirst(Fetcher, :fetched).dependson == Set([:attempt])
end

@testitem "reads in index, nested, splat and typed assignment targets resolve" tags=[:core] setup=[AssignmentTargetFixtures] begin
    using DynamicObjects
    t = Targets()
    @test t.indexed == (3.0, 4.0)
    @test t.nested == (5, 6, 7)
    @test t.splatted == (8, (9, 10))
    @test t.typed === 3.0
    @test DynamicObjects.metafirst(Targets, :indexed).dependson == Set([:slots, :slot])
    @test DynamicObjects.metafirst(Targets, :typed).dependson == Set([:vals])
end
