using TestItemRunner

@testmodule ProgressLabelFixtures begin
using DynamicObjects
export LabelledRoute, HeadingLedRoute, BlankLedRoute, EmptyDocRoute,
    InterpLabelRoute, SectionedRoute

# The user-resolved separator contract: `---` splits summary from details,
# `===` splits the progress part from the OpenAPI part (snag
# property-progres-3d8a7460). Uses the resolving comment's literal runs.
@dynamicstruct struct SectionedRoute
    """Rollup summary line.

    --------------
    Details paragraph with *markdown*.
    - a detail item
    =================
    # Arguments
    - `show`: `active` (default) or `all`.
    """
    sectioned = 1
end

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

@testitem "_docstring_sections splits summary/details/openapi" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    sections = DynamicObjects._docstring_sections
    # The resolving comment's literal runs.
    sec = sections("Sum.\n\n--------------\nDetails here.\n=================\n# Arguments\n- `x`: y.")
    @test sec.summary == "Sum."
    @test sec.details == "Details here."
    @test sec.openapi == "# Arguments\n- `x`: y."
    @test sec.explicit_summary
    # Short runs and surrounding whitespace also split (no magic count).
    sec = sections("  Sum.\n---\nD.\n===\nO.")
    @test (sec.summary, sec.details, sec.openapi) == ("Sum.", "D.", "O.")
    # A `---` below `===` is OpenAPI content, not a summary split.
    sec = sections("Sum.\n===\nO1.\n---\nO2.")
    @test sec.summary == "Sum."
    @test sec.details == ""
    @test sec.openapi == "O1.\n---\nO2."
    @test !sec.explicit_summary
    # `===` first means an empty progress part.
    sec = sections("===\nOnly openapi.")
    @test sec.summary == ""
    @test sec.openapi == "Only openapi."
    # No separators: the whole docstring is the summary block.
    sec = sections("Just text.\nMore text.")
    @test sec.summary == "Just text.\nMore text."
    @test sec.details == ""
    @test sec.openapi == ""
    @test !sec.explicit_summary
    # Markdown list items never split (dashes must own the whole line).
    sec = sections("Sum.\n- item\n--- x\n=== y")
    @test !sec.explicit_summary
    @test sec.openapi == ""
end

@testitem "progress label follows the separator contract" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    summary = DynamicObjects._docstring_summary
    # Explicit summaries are verbatim, including `# Arguments`-style bodies
    # above the separator; the OpenAPI part never leaks into the label.
    @test summary("Rollup summary.\n--------------\nDetails.\n=================\n# Arguments") ==
        "Rollup summary."
    # Multi-line explicit summaries pass verbatim — the author drew the line.
    @test summary("Line one.\nLine two.\n---\nDetails.") == "Line one.\nLine two."
    @test summary("# Headed.\nSecond.\n---\nDetails.") == "# Headed.\nSecond."
    # Single-line explicit summaries still shed a heading sigil.
    @test summary("# Titled.\n---\nDetails.") == "Titled."
    # `===`-only: first line of the progress head, OpenAPI part excluded.
    @test summary("Head one.\nHead two.\n=================\n# Arguments\n- `x`: y.") ==
        "Head one."
    # `===`-first: nothing usable for progress.
    @test summary("=================\nOnly openapi.") === nothing
end

@testitem "sectioned route labels from its summary, reflects in full" tags=[:core] setup=[ProgressLabelFixtures] begin
    using DynamicObjects
    o = SectionedRoute()
    s = DynamicObjects.compute_property(o, Val(:__substatus__), :sectioned)
    @test s.impl.description == "Rollup summary line."
    full = DynamicObjects.property_doc(DynamicObjects.metafirst(SectionedRoute, :sectioned))
    @test occursin("Rollup summary line.", full)
    @test occursin("--------------", full)
    @test occursin("Details paragraph", full)
    @test occursin("=================", full)
    @test occursin("# Arguments", full)
end
