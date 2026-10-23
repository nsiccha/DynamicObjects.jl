using TestItemRunner

# Snag `inside-an-htmxob-2bc9c4ea`: a property body's local method whose name
# (or parameter name) equals a property resolved to the property instead —
# `source(relpath) = …; source(x)` called the `@param source` String. Local
# methods are ordinary Julia bindings: the name is local in the enclosing scope,
# the parameters in the body, for every signature shape; and the scope-opening
# forms (`let`, `while`, `try`) keep what they bind inside them.
@testmodule LocalBindingFixtures begin
using DynamicObjects
using DynamicObjects.Treebars: @progress
export Receipts, LocalSignatures, LocalScopes, LocalDestructures

# Snag `local-namedtuple-c640cee8`: `local` with a destructuring or typed target
# declares every name it binds, and a named destructure stays valid Julia in a
# declaration or a binding header. `a` is also a property here.
@dynamicstruct struct LocalDestructures
    a::Int = 100
    named(nt; k=1) = begin
        local (; a, b) = nt
        a + b + k
    end
    positional(t) = begin
        local (a, b) = t
        a + b
    end
    typed(v) = begin
        local a::Int = v
        a + 1
    end
    value(nt) = (local (; b) = nt)
    let_bound(nt) = let (; a, b) = nt
        a + b
    end
    looped(nts) = begin
        acc = 0
        for (; a, b) in nts
            acc += a + b
        end
        acc
    end
    comprehended(nts) = [a + b for (; a, b) in nts if a > 0]
    @progress marked(nt) = begin
        local (; a, b) = nt
        a + b
    end
    @fetch! fetched(nt) = begin
        local (; a, b) = nt
        a + b
    end
end

@dynamicstruct struct Receipts
    source::String = ""
    table(year::Int; sources=Dict{String,Any}()) = begin
        source(relpath) = get!(() -> "row:" * relpath, sources, String(relpath))
        [source(r) for r in ("a.csv", "b.csv")]
    end
end

@dynamicstruct struct LocalSignatures
    x::Int = 100
    k::Int = 7
    typed = begin
        f(x)::Int = x + 1
        f(1)
    end
    whered = begin
        g(x::T) where {T} = x
        g(2)
    end
    longtyped = begin
        function h(x)::Int
            x + 1
        end
        h(3)
    end
    anonymous = begin
        a = function (x) x + 1 end
        a(4)
    end
    longform = begin
        function k(n) n * 2 end
        k(5)
    end
    declared = begin
        function k end
        k(n::Int) = n + 1
        k(1)
    end
end

@dynamicstruct struct LocalScopes
    x::Int = 100
    source::String = "prop"
    let_scoped = begin
        let
            source(r) = r * "!"
            source("in")
        end * "/" * source
    end
    while_scoped = begin
        out = String[]
        i = 0
        while i < 1
            source(r) = r * "?"
            push!(out, source("w"))
            i += 1
        end
        (out[1], source)
    end
    try_scoped = begin
        r = try
            source(v) = v * "#"
            source("t")
        catch
            "caught"
        end
        (r, source)
    end
    if_branch = begin
        if true
            source(v) = v * "+"
        end
        source("i")
    end
    try_else = try
        nothing
    catch
        :caught
    else
        :else_ran
    end
    typed_let = let x::Int = 3
        x + 1
    end
end
end

@testitem "local method named like a property shadows it" tags=[:core] setup=[LocalBindingFixtures] begin
    using DynamicObjects
    @test Receipts().table(2026) == ["row:a.csv", "row:b.csv"]
    # No phantom dependency edge on the shadowed property.
    @test isempty(DynamicObjects.metafirst(Receipts, :table).dependson)
end

@testitem "local method signatures bind their name and parameters" tags=[:core] setup=[LocalBindingFixtures] begin
    s = LocalSignatures()
    @test s.typed == 2
    @test s.whered == 2
    @test s.longtyped == 4
    @test s.anonymous == 5
    @test s.longform == 10
    @test s.declared == 2
end

@testitem "let, while and try keep their local bindings inside" tags=[:core] setup=[LocalBindingFixtures] begin
    s = LocalScopes()
    @test s.let_scoped == "in!/prop"
    @test s.while_scoped == ("w?", "prop")
    @test s.try_scoped == ("t#", "prop")
    @test s.if_branch == "i+"          # `if` opens no scope
    @test s.try_else == :else_ran
    @test s.typed_let == 4
end

@testitem "local destructuring declares its names, in every body form" tags=[:core] setup=[LocalBindingFixtures] begin
    using DynamicObjects
    s = LocalDestructures()
    @test s.named((a=1, b=2)) == 4
    @test s.positional((1, 2)) == 3
    @test s.typed(1) == 2
    @test s.value((b=5,)) == (b=5,)
    @test s.let_bound((a=1, b=2)) == 3
    @test s.looped([(a=1, b=2), (a=3, b=4)]) == 10
    @test s.comprehended([(a=1, b=2), (a=-1, b=5)]) == [3]
    @test s.marked((a=1, b=2)) == 3
    @test s.fetched((a=1, b=2)) == 3
    # The declared `a` is the local, not the property: no dependency edge on it.
    for name in (:named, :positional, :typed, :marked, :fetched)
        @test :a ∉ DynamicObjects.metafirst(LocalDestructures, name).dependson
    end
    @test s.a == 100
end
