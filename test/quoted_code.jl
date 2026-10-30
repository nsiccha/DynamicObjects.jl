using TestItemRunner

# Snag `sibling-rewrite-7194d49d`: quoted code in a body is data for whoever evaluates
# it later, not a read. A name inside `:(…)` / `quote … end` stays the symbol it is, and
# only what the quote interpolates when it is built is code of the body, by Julia's own
# levels: a nested quote takes one more `$`.
@testmodule QuotedCodeFixtures begin
using DynamicObjects
using DynamicObjects.Treebars: @progress, render_text
import DynamicObjects.Treebars
export QuotedSiblings, QuotedInChild, QuotedMarkers, QuotedProgress, gate, release!, render_text

const GATES = Dict{Symbol,Base.Event}()
const GATES_LOCK = ReentrantLock()
gate(k::Symbol) = wait(lock(() -> get!(Base.Event, GATES, k), GATES_LOCK))
release!(k::Symbol) = notify(lock(() -> get!(Base.Event, GATES, k), GATES_LOCK))

@dynamicstruct struct QuotedSiblings
    source = "x"
    items = [1, 2]
    fragment = :(1 + source)
    block = quote
        y = source
        y
    end
    assigns = :(source = 1)
    interpolated = :(1 + $source)
    splatted = :(f($(items...)))
    nested = :(:(1 + $source))
    nested_interpolated = :(:(1 + $($source)))
    shadowed = let source = 2
        :(source + $source)
    end
    indexed(source) = :(source + $source)
    computed = :(source)
end

@dynamicstruct struct QuotedInChild
    label = "parent"
    @struct child(; source=:column) = begin
        fragment = :(log(y) ~ 1 + source + label)
        interpolated = :(1 + $source + $label)
    end
end

@dynamicstruct struct QuotedMarkers
    source = "x"
    double(value) = 2value
    @fetch! fetched = :(log(y) + source)
    @fetch! fetched_interpolated = :(log(y) + $(double(2)))
    @dynamic_progress dynamic = :(log(y) + source)
    @progress marked = :(log(y) + source + $(double(3)))
    @fresh freshly(value) = value
    fresh_argument = @fresh freshly(:(log(y) + $(double(4))))
    memo_argument = @memo! identity(:(log(y) + 1))
end

@dynamicstruct struct QuotedProgress
    tag::Symbol
    "Slow input"
    slow = (gate(tag); 1)
    "Fragment"
    fragment = :(y + $slow)
end
end

@testitem "quoted names stay symbols" tags=[:core] setup=[QuotedCodeFixtures] begin
    o = QuotedSiblings()
    @test o.fragment == :(1 + source)
    @test o.block.args[2] == :(y = source)
    @test o.assigns == :(source = 1)
    @test o.computed == :source
end

@testitem "an interpolation is code of the body" tags=[:core] setup=[QuotedCodeFixtures] begin
    o = QuotedSiblings()
    @test o.interpolated == :(1 + "x")
    @test o.splatted == :(f(1, 2))
    # A local or an argument keeps its meaning: only the interpolation reads it.
    @test o.shadowed == :(source + 2)
    @test o.indexed(3) == :(source + 3)
end

@testitem "a nested quote takes one more interpolation" tags=[:core] setup=[QuotedCodeFixtures] begin
    o = QuotedSiblings()
    @test o.nested == Expr(:quote, :(1 + $(Expr(:$, :source))))
    @test o.nested_interpolated == Expr(:quote, :(1 + $(Expr(:$, "x"))))
end

@testitem "quoted names are no dependencies" tags=[:core] setup=[QuotedCodeFixtures] begin
    reads = dependents(QuotedSiblings, :source)
    @test :interpolated in reads
    @test :nested_interpolated in reads
    @test isdisjoint(reads, (:fragment, :block, :assigns, :nested, :computed))
    # `shadowed` interpolates a local and `indexed` an argument: neither reads `source`.
    @test isdisjoint(reads, (:shadowed, :indexed))
    @test isempty(property_descriptor(QuotedSiblings, :fragment).dependencies)
    # Quoted `__self__` is no reach into the object either.
    deps = Set{Symbol}()
    @test !DynamicObjects._collect_self_deps!(deps, Expr(:quote, :(__self__.source + __self__)))
    @test isempty(deps)
end

@testitem "an inline child's forwarded names and index arguments stay quoted" tags=[:core] setup=[QuotedCodeFixtures] begin
    child = QuotedInChild().child()
    @test child.fragment == :(log(y) ~ 1 + source + label)
    @test child.interpolated == :(1 + $(:column) + "parent")
end

@testitem "no body marker rewrites quoted code" tags=[:core] setup=[QuotedCodeFixtures] begin
    o = QuotedMarkers()
    @test o.fetched == :(log(y) + source)
    @test o.fetched_interpolated == :(log(y) + 4)
    @test o.dynamic == :(log(y) + source)
    @test o.marked == :(log(y) + source + 6)
    @test o.fresh_argument == :(log(y) + 8)
    @test o.memo_argument == :(log(y) + 1)
end

@testitem "the lint scanners skip quoted code" tags=[:core] setup=[QuotedCodeFixtures] begin
    quoted = Expr(:quote, :(source[1] + __self__))
    @test !DynamicObjects._contains_call(quoted)
    @test !DynamicObjects._contains_self_ref(quoted)
    @test !DynamicObjects._contains_bare_prop_ref(quoted, Set([:source]))
    hits = Symbol[]
    DynamicObjects._scan_bracket_ip!(hits, Expr(:quote, :(__self__.source[1])), Set([:source]))
    @test isempty(hits)
    @test DynamicObjects._contains_call(Expr(:quote, :(1 + $(Expr(:$, :(f(x)))))))
end

@testitem "a read in an interpolation nests like any read" tags=[:core, :progress] setup=[QuotedCodeFixtures] begin
    o = QuotedProgress(:quoted_nesting)
    task = Threads.@spawn o.fragment
    # The owner's tree shows a computation once, at its own place; a read shows on its reader.
    reader() = DynamicObjects._status_of(getfield(o, :cache).cache, :fragment)
    shown() = (node = reader(); node !== nothing && occursin("Slow input", render_text(node)))
    @test timedwait(shown, 20; pollint=0.01) === :ok
    release!(:quoted_nesting)
    @test fetch(task) == :(y + 1)
end
