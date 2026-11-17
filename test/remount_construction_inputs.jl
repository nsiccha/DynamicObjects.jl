using TestItemRunner

# A keyword an object was constructed with is an input of that object. A remount
# view keeps it, whatever the declared default it replaces would have read.
@testmodule RemountInputFixtures begin
using DynamicObjects
export InRoot, InKid, InParent, InOpaque, InInline, InAliasKid, InAliasParent,
    InPlainKid, InPlainParent, InScoped, RIN_CALLS, rin_reset!

const RIN_CALLS = Dict{Symbol,Int}()
const RIN_LOCK = ReentrantLock()
_rin_bump!(k) = lock(() -> (RIN_CALLS[k] = get(RIN_CALLS, k, 0) + 1), RIN_LOCK)
rin_reset!() = (empty!(RIN_CALLS); nothing)

# `ctx` is the context each view rebinds; the default of `a` reads it.
@dynamicstruct struct InRoot
    ctx = nothing
    a = (_rin_bump!(:a); ctx === nothing ? 0.2 : 0.2 + ctx)
    b = 10a
    f(i) = (ctx, i)
end

# The shape HTMXObjects mounts: an external child whose parameter default reads
# the request, constructed with a keyword for that parameter.
@dynamicstruct struct InKid
    __parent__ = nothing
    __req__ = nothing
    a = __req__ === nothing ? 0.2 : 0.2 + __req__
    b = 10a
end
@dynamicstruct struct InParent
    __req__ = nothing
    @include kid = InKid(; a = 0.4)
end
# The registration `@htmx` emits for every external `@include`.
DynamicObjects._nested_struct_type(::Type{InParent}, ::Val{:kid}) = InKid

# Defaults that hand `__self__` to code the dependency scan cannot follow.
_rin_default(o) = o.ctx === nothing ? 0.2 : 0.2 + o.ctx
_rin_scaled(o) = 100 * o.a
@dynamicstruct struct InOpaque
    ctx = nothing
    a = _rin_default(__self__)
    scaled = (_rin_bump!(:scaled); _rin_scaled(__self__))
end

@dynamicstruct struct InInline
    ctx = nothing
    data = 1
    @struct single = begin
        mine = data + 1
    end
end

# `data` of the child is an alias of its parent's `data`.
@dynamicstruct struct InAliasKid
    __parent__ = nothing
    data = __parent__.data
    twice = 2 * data
end
@dynamicstruct struct InAliasParent
    ctx = nothing
    data = 1
    @include kid = InAliasKid(; data = 50)
end
DynamicObjects._nested_struct_type(::Type{InAliasParent}, ::Val{:kid}) = InAliasKid

@dynamicstruct struct InPlainKid
    __parent__ = nothing
    a = 0.2
end
@dynamicstruct struct InPlainParent
    ctx = nothing
    @include kid = InPlainKid(; a = 0.4)
end
DynamicObjects._nested_struct_type(::Type{InPlainParent}, ::Val{:kid}) = InPlainKid

# Request-scoped names, each with a default that reads the rebound context.
@dynamicstruct struct InScoped
    ctx = nothing
    __status__ = (ctx, :status)
    __req__ = (ctx, :req)
    __prefix__ = (ctx, :prefix)
end
end

@testitem "a remount view keeps a construction keyword whose default reads rebound context" setup=[RemountInputFixtures] begin
using DynamicObjects

rin_reset!()
source = InRoot(; a = 0.4)
views = [remount(source; ctx = i) for i in 1:3]
for v in views
    @test v.a == 0.4
    @test v.b == 4.0
end
@test source.a == 0.4 && source.b == 4.0
# The default the keyword replaces never ran, on the source or on a view.
@test get(RIN_CALLS, :a, 0) == 0

# Without the keyword, every view still computes the default from its own context.
plain = InRoot()
@test remount(plain; ctx = 1).a == 1.2
@test remount(plain; ctx = 2).b == 22.0
@test plain.a == 0.2

# A name the call rebinds takes the rebound value.
rebound = remount(source; ctx = 1, a = 0.7)
@test rebound.a == 0.7 && rebound.b == 7.0
@test source.a == 0.4

# A view of a view is a view of the retained object.
@test remount(views[1]; ctx = 9).a == 0.4
end

@testitem "an external child a view adopts keeps its construction keywords" setup=[RemountInputFixtures] begin
using DynamicObjects

source = InParent()
@test source.kid.a == 0.4
for req in 1:3
    view = remount(source; __req__ = req)
    kid = view.kid
    # The view's child is the retained child, rebound to the view.
    @test DynamicObjects._retained_object(kid) === source.kid
    @test kid.__parent__ === view
    @test kid.__req__ == req
    @test kid.a == 0.4
    @test kid.b == 4.0
end
# A child the source never realized is the view's own and was constructed with the keyword.
unrealized = remount(InParent(); __req__ = 1)
@test unrealized.kid.a == 0.4 && unrealized.kid.b == 4.0
end

@testitem "a kept keyword replaces an opaque default and is what opaque work reads" setup=[RemountInputFixtures] begin
using DynamicObjects

rin_reset!()
source = InOpaque(; a = 0.4)
views = [remount(source; ctx = i) for i in 1:2]
for v in views
    @test v.a == 0.4
    @test v.scaled == 40.0
end
@test source.scaled == 40.0
# Without the keyword the opaque default follows each view's context.
plain = InOpaque()
@test remount(plain; ctx = 1).a == 1.2
@test remount(plain; ctx = 1).scaled == 120.0
end

@testitem "a kept keyword replaces a parent alias" setup=[RemountInputFixtures] begin
using DynamicObjects

source = InAliasParent()
@test source.kid.data == 50 && source.kid.twice == 100
view = remount(source; ctx = 1)
kid = view.kid
@test DynamicObjects._retained_object(kid) === source.kid
# Read twice: an alias is checked against its parent on every read.
@test kid.data == 50
@test kid.data == 50
@test kid.twice == 100
@test view.data == 1
end

@testitem "a child passed at construction is the view's child" setup=[RemountInputFixtures] begin
using DynamicObjects

# An external child.
given = InPlainKid(; a = 0.9)
source = InPlainParent(; kid = given)
view = remount(source; ctx = 1)
@test source.kid === given
@test view.kid === given
@test view.kid.a == 0.9
# Without the keyword the view constructs the declared child.
@test remount(InPlainParent(); ctx = 1).kid.a == 0.4

# An inline child of another parent keeps that parent.
other = InInline(; data = 100)
borrowed = InInline(; single = other.single)
@test borrowed.single.mine == 101
bview = remount(borrowed; ctx = 1)
@test bview.single === other.single
@test bview.single.mine == 101
end

@testitem "an indexed property constructed as a value reads that value through a view" setup=[RemountInputFixtures] begin
using DynamicObjects

source = InRoot(; f = :plain)
@test source.f === :plain
@test remount(source; ctx = 1).f === :plain
# Declared, it is indexed per view.
@test remount(InRoot(); ctx = 1).f(2) == (1, 2)
end

@testitem "request-scoped construction keywords stay the view's own" setup=[RemountInputFixtures] begin
using DynamicObjects

source = InScoped(; __status__ = nothing, __req__ = :first, __prefix__ = "/first")
@test source.__req__ === :first
view = remount(source; ctx = 1)
@test view.__status__ == (1, :status)
@test view.__req__ == (1, :req)
@test view.__prefix__ == (1, :prefix)
end

@testitem "clears and invalidation keep a view's construction keywords" setup=[RemountInputFixtures] begin
using DynamicObjects

source = InRoot(; a = 0.4)
view = remount(source; ctx = 1)
@test view.b == 4.0

# A clear of the view restores its context and the kept keyword.
clear_mem_caches!(view)
@test view.ctx == 1 && view.a == 0.4 && view.b == 4.0
# A clear of the retained object leaves a live view's inputs in place.
clear_mem_caches!(source)
@test view.a == 0.4 && view.b == 4.0
@test remount(source; ctx = 2).a == 0.4

# Dropping the context the default would have read, or the keyword itself, keeps the input.
DynamicObjects.clear_cache!(view, :ctx)
@test view.a == 0.4 && view.b == 4.0
DynamicObjects.clear_cache!(view, :a)
@test view.a == 0.4 && source.a == 0.4

# The kept keyword is an input of the view: memory pruning never evicts it.
pruned = remount(source; ctx = 3)
@test pruned.b == 4.0
entry = only(e for e in mem_cache_entries(pruned) if e.object === pruned && e.property === :a)
@test entry.role === :input
prune_mem_caches!(_ -> false, pruned)
@test pruned.a == 0.4

# `remake` of a view keeps it too.
remade = remake(view; ctx = 5)
@test remade.a == 0.4 && remade.b == 4.0
end
