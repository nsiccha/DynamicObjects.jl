using TestItemRunner

@testmodule TypedIndexedForwardingFixtures begin
using DynamicObjects
export TypedIndexedParent

# snag typed-indexed-pr-8df56aea: the inline-child auto-forward collected parent
# property names by peeling the index call before the return annotation, so
# `name(args)::T` stayed a call and contributed no name. Every typed indexed
# property was then missing from `(; …) = __parent__`, and a bare read in the
# child died with `UndefVarError` at compute time.
@dynamicstruct struct TypedIndexedParent
    base::Int
    plain(i) = base + i
    typed(i::Int)::Int = base * i
    weighted(i::Int; w::Int=2)::Int = base * i * w
    _kw_only(; w::Int=2)::Int = base * w
    "Documented and typed."
    documented(i::Int)::Int = base - i
    @struct child(k) = begin
        p = plain(k)
        t = typed(k)
        w = weighted(k; w=3)
        o = _kw_only(; w=k)
        d = documented(k)
        @progress threaded = typed(k) + 1
    end
end
end # @testmodule TypedIndexedForwardingFixtures

@testitem "typed indexed properties forward into inline children" tags=[:core] setup=[TypedIndexedForwardingFixtures] begin
using DynamicObjects

parent = TypedIndexedParent(10)
child = parent.child(2)
@test child.p == 12
@test child.t == 20
@test child.w == 60
@test child.o == 20
@test child.d == 8
@test child.threaded == 21

child_declared = first.(DynamicObjects.meta(typeof(child)))
for name in (:plain, :typed, :weighted, :_kw_only, :documented)
    @test name in child_declared
end
end
