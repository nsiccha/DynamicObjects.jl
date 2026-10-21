using TestItemRunner

# DynamicObjects' body rewrites keep a call as it was written (snag
# `bump-bruno-to-dy-9b97054b`). `fixcall` used to give every call it touched a keyword
# block and sort splats after named keywords. The always-on rewrite (`ed0f8bc`) runs every
# call in an unmarked body through it, so a macro reading its argument saw a `;` the author
# never wrote: Treebars' `@progress "label" map(itr) do … end` spliced the empty block into
# `progress_map`'s positional arguments, and lowering failed with `invalid syntax ;`.
# Sorting also inverted keyword precedence: `f(; nt..., a = 2)` passed `nt.a`, under
# `@memo!`, `@fresh` and `@fetch!` too.
@testmodule MapSugarFixtures begin
using DynamicObjects
using DynamicObjects.Treebars: render_text, @progress
export render_text, node_of, CSMapSugar

"The progress node of bare property `name`'s computation on `o`, once one started."
node_of(o, name::Symbol) = DynamicObjects._status_of(getfield(o, :cache).cache, name)

# Treebars' map-sugar in an unmarked body, with a product iterable read from siblings and
# a destructured do-argument (the reported Bruno shape).
@dynamicstruct struct CSMapSugar
    xs = [1, 2]
    ys = [3, 4]
    "Cells"
    cells = @progress "Sweep" map(Iterators.product(xs, ys)) do (x, y)
        x + y
    end
    "Plain map"
    plain = @progress map(x -> 2x, xs)
end
end

@testmodule KwOrderFixtures begin
using DynamicObjects
export CSKwOrder

kwarg_a(; kwargs...) = kwargs[:a]

# The later keyword wins, as in plain Julia, through every rewrite.
@dynamicstruct struct CSKwOrder
    nt = (a = 1,)
    item(i; kwargs...) = (i, kwargs[:a])
    unmarked = kwarg_a(; nt..., a = 2)
    earlier = kwarg_a(; a = 2, nt...)
    threaded = item(0; nt..., a = 2)
    memo = @memo! item(1; nt..., a = 2)
    fresh = @fresh item(2; nt..., a = 2)
    @progress progressed = kwarg_a(; nt..., a = 2)
    @fetch! fetched = kwarg_a(; nt..., a = 2)
end
end

@testitem "call shape: map-sugar in an unmarked body lowers and counts its elements" tags=[:progress] setup=[MapSugarFixtures] begin
using .MapSugarFixtures
o = CSMapSugar()
@test o.cells == [4 5; 5 6]
@test occursin("✓ Sweep (4/4)", render_text(node_of(o, :cells)))
@test o.plain == [2, 4]
end

@testitem "call shape: keyword order is precedence through every rewrite" setup=[KwOrderFixtures] begin
using .KwOrderFixtures
o = CSKwOrder()
@test o.unmarked == 2
@test o.earlier == 1
@test o.threaded == (0, 2)
@test o.memo == (1, 2)
@test o.fresh == (2, 2)
@test o.progressed == 2
@test o.fetched == 2
end

@testitem "call shape: fixcall adds no keyword block and keeps a written one" begin
using DynamicObjects
fixcall = DynamicObjects.fixcall
rw(ex) = DynamicObjects._implied_progress_rewrite(:p, ex)
has_block(x) = x isa Expr && (Meta.isexpr(x, :parameters) || any(has_block, x.args))

# No keyword block written, none added: in a plain call, a threaded call, and a do-block.
@test fixcall(:(f(g(x)))) == :(f(g(x)))
@test !has_block(rw(:(sum(obj.y))))
@test !has_block(rw(:(obj.ip(x))))
@test !has_block(rw(:(map(xs) do x
    x + 1
end)))
sugar = Base.remove_linenums!(:(@progress "label" map(xs) do x
    x + 1
end))
@test Base.remove_linenums!(rw(sugar)) == sugar

# A written block moves first when arguments are spliced before it, in its own order.
spliced = fixcall(Expr(:call, :f, :a, Expr(:parameters, :(nt...), Expr(:kw, :k, 1)), :b))
@test spliced == Expr(:call, :f, Expr(:parameters, :(nt...), Expr(:kw, :k, 1)), :a, :b)
@test rw(:(f(1; nt..., a = 2))) == :(f(1; nt..., a = 2))
threaded = rw(:(obj.ip(1; nt..., a = 2)))
@test threaded.args[2] == Expr(:parameters, :(nt...), Expr(:kw, :a, 2))

# Several blocks (method generation merges a signature's with its own) become one, the
# splat last as a signature requires.
merged = fixcall(Expr(:call, :f, :x, Expr(:parameters, :(kwargs...)),
                      Expr(:parameters, Expr(:kw, :k, 1))))
@test merged == Expr(:call, :f, Expr(:parameters, Expr(:kw, :k, 1), :(kwargs...)), :x)
end
