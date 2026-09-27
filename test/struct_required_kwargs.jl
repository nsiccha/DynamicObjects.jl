using TestItemRunner

@testmodule StructRequiredKwargFixtures begin
using DynamicObjects
export KwargChildRoute, LabelledKwargChildRoute, BareKwargChildRoute,
    DefaultedKwargChildRoute, KwargChildRoute__rows_inline

# Snag required-indexed-165c772b: an indexed `@struct` inline child with a
# REQUIRED kwarg (`K::Int`, no default) died with `UndefKeywordError` before
# the body ran — the auto-wired `__status__` substatus call forwarded the
# positional indices but dropped the kwargs, while the emitted
# `_is_property_documented` override carries the property's full signature.
@dynamicstruct struct KwargChildRoute
    @struct _rows(fit_key; K::Int, top_chains::Int=0) = begin
        total = K + top_chains
    end
end

# Documented variant: the progress label interpolates `$K` against the
# call-site value (do-use: `$kwarg` interpolation for property metadata).
@dynamicstruct struct LabelledKwargChildRoute
    """NPDE rows for draw budget $K."""
    @struct _rows(fit_key; K::Int, top_chains::Int=0) = begin
        total = K + top_chains
    end
end

# Undocumented required-kwarg child: computes, but its substatus stays a
# bare wrapper (empty description) that the tree inlines.
@dynamicstruct struct BareKwargChildRoute
    @struct _rows(fit_key; K::Int) = begin
        total = 2K
    end
end

# Defaulted kwargs always computed (defaults filled the dropped values), but
# the label interpolated the DEFAULT, not the call-site value. The same
# forwarding fix corrects the label.
@dynamicstruct struct DefaultedKwargChildRoute
    """Editor for $relpath with default $default."""
    @struct editor(relpath; default::String="") = begin
        shown = string(relpath, ":", default)
    end
end

end # @testmodule StructRequiredKwargFixtures

@testitem "indexed @struct with required kwarg computes with call-site kwargs" tags=[:core] setup=[StructRequiredKwargFixtures] begin
    using DynamicObjects
    # The required kwarg is a computed fallback, not a fixed struct field
    # (the `K = nothing` prepend must not lower to a field, or the
    # kwargs-only child constructor matches no method).
    @test fieldnames(KwargChildRoute__rows_inline) == (:cache,)
    @test !DynamicObjects.isfixed(DynamicObjects.metafirst(KwargChildRoute__rows_inline, :K))

    o = KwargChildRoute()
    child = o._rows("a"; K=500)
    @test child.total == 500
    @test child.K == 500
    @test child.fit_key == "a"
    @test child.top_chains == 0

    # Memoization still keys on the kwargs: distinct K, distinct child.
    other = o._rows("a"; K=7)
    @test other.total == 7
    @test other !== child
    @test o._rows("a"; K=500) === child
end

@testitem "required-kwarg @struct progress label interpolates call-site kwargs" tags=[:core] setup=[StructRequiredKwargFixtures] begin
    using DynamicObjects
    o = LabelledKwargChildRoute()
    child = o._rows("a"; K=500)
    @test child.total == 500
    s = DynamicObjects.compute_property(o, Val(:__substatus__), :_rows, "a"; K=500)
    @test s.impl.description == "NPDE rows for draw budget 500."
end

@testitem "undocumented required-kwarg @struct stays a bare wrapper" tags=[:core] setup=[StructRequiredKwargFixtures] begin
    using DynamicObjects
    o = BareKwargChildRoute()
    @test o._rows("a"; K=21).total == 42
    s = DynamicObjects.compute_property(o, Val(:__substatus__), :_rows, "a"; K=21)
    @test s.impl.description == ""
end

@testitem "defaulted-kwarg @struct label uses the call-site value" tags=[:core] setup=[StructRequiredKwargFixtures] begin
    using DynamicObjects
    o = DefaultedKwargChildRoute()
    child = o.editor("a/b"; default="x")
    @test child.shown == "a/b:x"
    s = DynamicObjects.compute_property(o, Val(:__substatus__), :editor, "a/b"; default="x")
    @test s.impl.description == "Editor for a/b with default x."
end
