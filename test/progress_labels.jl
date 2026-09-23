using TestItemRunner

@testmodule ProgressLabelFixtures begin
using DynamicObjects
export LabelledRoute, HeadingLedRoute, BlankLedRoute, EmptyDocRoute,
    InterpLabelRoute

# A route-style docstring: a one-line summary, then a blank line, then the
# `# Arguments` curl/API reference (mirrors the KB's real `/agents/foryou`
# docstring that snag property-progres-3d8a7460 was filed against).
@dynamicstruct struct LabelledRoute
    """For-You master/detail rollup (waiting rows always render; floor pads only the parked tail).

    # Arguments
    - `show`: `active` (default) or `all`.
    - `embedded`: `1` drops the own heading (swapped responses).
    """
    foryou = 1
    plain = 2
end

@dynamicstruct struct HeadingLedRoute
    """# Route Title

    Body text the tree must not show.
    """
    titled = 1
end

@dynamicstruct struct BlankLedRoute
    """

    Summary after blank lines.

    # Arguments
    - `x`: something.
    """
    skipped = 1
end

@dynamicstruct struct EmptyDocRoute
    ""
    empty = 1
end

# `$tag` interpolates against the call-site value (manual: Property
# docstrings), so the evaluated description can carry newlines the authored
# text never had — the summary must truncate those too.
@dynamicstruct struct InterpLabelRoute
    """Summary for $tag.

    # Arguments
    - `tag`: injected value.
    """
    what(tag::String) = tag
end

end # @testmodule ProgressLabelFixtures

@testitem "progress node shows the docstring summary, not the full docstring" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    o = LabelledRoute()
    root = o.__status__
    s = DynamicObjects.compute_property(o, Val(:__substatus__), :foryou)
    @test s isa DynamicObjects.Treebars.ProgressNode
    @test s.parent === root
    @test s.impl.description ==
        "For-You master/detail rollup (waiting rows always render; floor pads only the parked tail)."
    @test !occursin("# Arguments", s.impl.description)

    # Undocumented properties stay bare wrappers that inline.
    u = DynamicObjects.compute_property(o, Val(:__substatus__), :plain)
    @test u.impl.description == ""
end

@testitem "progress summary sheds heading sigils and skips blank lines" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    h = HeadingLedRoute()
    @test DynamicObjects.compute_property(h, Val(:__substatus__), :titled).impl.description ==
        "Route Title"

    b = BlankLedRoute()
    @test DynamicObjects.compute_property(b, Val(:__substatus__), :skipped).impl.description ==
        "Summary after blank lines."

    # A docstring with no usable line inlines like an undocumented property.
    e = EmptyDocRoute()
    @test DynamicObjects.compute_property(e, Val(:__substatus__), :empty).impl.description == ""
end

@testitem "progress summary truncates interpolated newlines" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    o = InterpLabelRoute()
    full = DynamicObjects._property_description(o, Val(:what), "A\nB")
    @test occursin("Summary for A\nB.", full)
    s = DynamicObjects.compute_property(o, Val(:__substatus__), :what, "A\nB")
    @test s.impl.description == "Summary for A"
end

@testitem "full docstring stays on reflection" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    o = LabelledRoute()
    @test occursin(
        "# Arguments",
        DynamicObjects.property_doc(DynamicObjects.metafirst(LabelledRoute, :foryou)),
    )
    # The emitted override still returns the full text: only the progress
    # label summarizes, so schema/OpenAPI/descriptor readers are untouched.
    @test occursin("# Arguments", DynamicObjects._property_description(o, Val(:foryou)))
end

@testitem "_docstring_summary edge cases match the HTMXObjects core" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    first_line = DynamicObjects._docstring_first_line
    summary = DynamicObjects._docstring_summary
    @test first_line("one\ntwo") == "one"
    @test first_line("\n  \n  two\n") == "two"
    @test first_line("") === nothing
    @test first_line("\n  \n") === nothing
    @test first_line("a\r\nb") == "a"
    @test summary("# Title") == "Title"
    @test summary("## Deep heading") == "Deep heading"
    @test summary("#nospace") == "#nospace"
    @test summary("plain") == "plain"
    @test summary("") === nothing
    @test summary(nothing) === nothing
    @test summary(42) === nothing
end
