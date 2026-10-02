using TestItemRunner

@testmodule ProgressMarkerLoopFixtures begin
using DynamicObjects
using DynamicObjects.Treebars: render_text
export MarkerLoopRoute, MarkerLoopRoute_summary_inline

# Snag cached-progress-a24845f4: the `@progress` property marker threads a
# bare sibling read through `__progress__`, including one in a loop's
# ITERATOR (`for i in eachindex(doses)` → `for i in
# eachindex(maybefetchproperty!(__progress__, __self__, :doses))`). Treebars
# auto-instruments every plain `for` / `@threads for` under the marker's wrap,
# and only Treebars `37ea8c7`+ renames `__progress__` in a loop iterator (as
# the enclosing node). On an older Treebars the first call throws
# `UndefVarError: __progress__ not defined` at the loop line. The reported
# site was a kwargs-only `@cached @progress` property on an indexed `@struct`
# child; neither the kwargs-only signature nor the inline child mattered.
const CACHE_BASE = mktempdir()

@dynamicstruct struct MarkerLoopRoute
    __cache_base__ = CACHE_BASE
    scale = 2.0
    @struct summary(doses::Vector{Int}; offset::Int=0) = begin
        "Per-dose basis"
        basis(dose) = dose * scale
        "Kwargs-only bands"
        @cached @progress bands_kwonly(; probs=0.5) = begin
            local out = zeros(length(doses))
            for dose_index in eachindex(doses)
                out[dose_index] = basis(doses[dose_index]) * probs + offset
            end
            out
        end
        "Positional bands"
        @cached @progress bands_positional(probs) = begin
            local out = zeros(length(doses))
            for dose_index in eachindex(doses)
                out[dose_index] = basis(doses[dose_index]) * probs + offset
            end
            out
        end
        @progress threaded_total() = begin
            local out = zeros(length(doses))
            Threads.@threads for dose_index in eachindex(doses)
                out[dose_index] = basis(doses[dose_index])
            end
            sum(out)
        end
        @progress nested_total() = begin
            local total = 0.0
            for dose in doses
                for factor in eachindex(doses)
                    total += basis(dose) * factor
                end
            end
            total
        end
        @progress multi_iterator_total() = begin
            local total = 0.0
            for dose in doses, factor in eachindex(doses)
                total += basis(dose) * factor
            end
            total
        end
        # Snapshots this property's own progress node during the last
        # iteration, while the loop counter is still live.
        @progress loop_tree() = begin
            local total = 0.0
            local tree = ""
            for dose_index in eachindex(doses)
                total += basis(doses[dose_index])
                dose_index == length(doses) && (tree = render_text(__status__))
            end
            (; total, tree)
        end
    end
end

end # @testmodule ProgressMarkerLoopFixtures

@testitem "@cached @progress kwargs-only child property reads a sibling in a for iterator" tags=[:core] setup=[ProgressMarkerLoopFixtures] begin
    o = MarkerLoopRoute()
    child = o.summary([1, 2, 3]; offset=1)
    @test child.bands_kwonly() == [2.0, 3.0, 4.0]
    @test child.bands_kwonly(; probs=1.0) == [3.0, 5.0, 7.0]
    @test child.bands_positional(0.5) == [2.0, 3.0, 4.0]
    # The marker composes with `@cached`: the value was published to disk, and
    # a fresh owner reads the stored entry back.
    fresh_child = MarkerLoopRoute().summary([1, 2, 3]; offset=1)
    observed = materialization_observation(fresh_child, :bands_kwonly)
    @test observed.stored
    @test !observed.ready
    @test fresh_child.bands_kwonly() == [2.0, 3.0, 4.0]
end

@testitem "@progress marker threads sibling reads in @threads, nested and multi-iterator loops" tags=[:core] setup=[ProgressMarkerLoopFixtures] begin
    child = MarkerLoopRoute().summary([1, 2, 3])
    @test child.threaded_total() == 12.0
    @test child.nested_total() == 72.0
    @test child.multi_iterator_total() == 72.0
end

@testitem "@progress marker hangs sibling computes under the loop counter" tags=[:core] setup=[ProgressMarkerLoopFixtures] begin
    child = MarkerLoopRoute().summary([4, 5, 6])
    (; total, tree) = child.loop_tree()
    @test total == 30.0
    lines = split(tree, '\n')
    loop_line = findfirst(line -> occursin("for dose_index", line), lines)
    @test !isnothing(loop_line)
    loop_depth = findfirst(!in(" │├└─"), lines[loop_line])
    basis_lines = filter(line -> occursin("Per-dose basis", line), lines)
    @test length(basis_lines) == 3
    @test all(line -> findfirst(!in(" │├└─"), line) > loop_depth, basis_lines)
    @test all(i -> i > loop_line, findall(line -> occursin("Per-dose basis", line), lines))
end
