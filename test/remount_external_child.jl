using TestItemRunner

@testmodule RemountExternalFixtures begin
using DynamicObjects
export ExtChild, ExtGrand, ExtRoot, REC_CALLS, REC_ELSEWHERE, rec_reset!

const REC_CALLS = Dict{String,Int}()
const REC_LOCK = ReentrantLock()
_rec_bump!(k) = lock(() -> (REC_CALLS[k] = get(REC_CALLS, k, 0) + 1), REC_LOCK)
rec_reset!() = (empty!(REC_CALLS); nothing)

# External children: everything they know arrives as constructor kwargs.
@dynamicstruct struct ExtGrand
    __parent__ = nothing
    label::String = ""
    work = (_rec_bump!("grand:" * label); Ref(label))
end

@dynamicstruct struct ExtChild
    __parent__ = nothing
    arg::String = ""
    work = (_rec_bump!("child:" * arg); Ref(arg))
    @include grand = ExtGrand(; label = arg * "/grand")
end

# Not the parent of anything it is passed to below.
const REC_ELSEWHERE = ExtChild(; arg = "elsewhere")

_rec_self_url(o) = o.__prefix__ * "/self"

# `__prefix__` is the context each view rebinds.
@dynamicstruct struct ExtRoot
    __prefix__ = ""
    url = __prefix__ * "/openapi"
    @include through_property = ExtChild(; arg = url)
    @include direct = ExtChild(; arg = __prefix__)
    # Reads the context through `__self__`, which the dependency scan cannot follow.
    @include through_self = ExtChild(; arg = _rec_self_url(__self__))
    @include constant = ExtChild(; arg = "constant")
    @include elsewhere = ExtChild(; __parent__ = REC_ELSEWHERE, arg = "other parent")
    keyed(k) = ExtChild(; __parent__ = __self__, arg = url * "/" * string(k))
end

# The registration `@htmx` emits for every external `@include`.
for name in (:through_property, :direct, :through_self, :constant, :elsewhere, :keyed)
    @eval DynamicObjects._nested_struct_type(::Type{ExtRoot}, ::Val{$(QuoteNode(name))}) = ExtChild
end
DynamicObjects._nested_struct_type(::Type{ExtChild}, ::Val{:grand}) = ExtGrand
end

@testitem "an external child's constructor arguments follow each remount view's context" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
# Realized on the retained source first, as HTMXObjects' root priming does.
for name in (:through_property, :direct, :through_self, :constant, :elsewhere)
    getproperty(source, name).work
end
for prefix in ("/first", "/p/A", "")
    v = remount(source; __prefix__=prefix)
    @test v.url == prefix * "/openapi"
    @test v.through_property.arg == prefix * "/openapi"
    @test v.direct.arg == prefix
    @test v.through_self.arg == prefix * "/self"
    @test v.through_property.work[] == prefix * "/openapi"
    @test v.constant.arg == "constant"
    @test v.constant.__parent__ === v
end
# A child built the same way under every view shares the source child's work.
@test REC_CALLS["child:constant"] == 1
@test REC_CALLS["child:/first/openapi"] == 1
@test REC_CALLS["child:/p/A/openapi"] == 1
@test REC_CALLS["child:/openapi"] == 1
end

@testitem "a remount view shares the source's external child when it constructs it alike" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
retained = source.through_property
retained_work = retained.work
same = remount(source; __prefix__="/first")
other = remount(source; __prefix__="/p/A")
# Same constructor arguments: the view's own child instance over the source child's cache.
@test same.through_property !== retained
@test same.through_property.__parent__ === same
@test same.through_property.work === retained_work
# Its progress node is the source child's, as for any shared work.
@test same.through_property.__status__ === retained.__status__
# Different arguments: a child of the view's own.
@test other.through_property.__parent__ === other
@test other.through_property.work !== retained_work
@test other.through_property.work[] == "/p/A/openapi"
@test REC_CALLS["child:/first/openapi"] == 1
@test REC_CALLS["child:/p/A/openapi"] == 1
# Reading through the view never rebuilds or replaces the source's child.
@test source.through_property === retained
@test retained.__parent__ === source
end

@testitem "adopting the source's external child adds nothing to the retained progress tree" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
source.constant.work
source.through_property.work
source.keyed(1).work
# A view of a struct that declares no `__status__` reports into the source's tree.
nodes() = length(source.__status__.children)
before = nodes()
for _ in 1:20
    v = remount(source; __prefix__="/first")
    v.constant.work
    v.through_property.work
    v.keyed(1).work
end
@test nodes() == before
end

@testitem "an indexed external child is constructed per remount view key" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
retained_work = source.keyed(1).work
same = remount(source; __prefix__="/first")
other = remount(source; __prefix__="/p/A")
@test same.keyed(1).__parent__ === same
@test same.keyed(1).work === retained_work
@test other.keyed(1).__parent__ === other
@test other.keyed(1).arg == "/p/A/openapi/1"
@test other.keyed(1).work[] == "/p/A/openapi/1"
@test REC_CALLS["child:/first/openapi/1"] == 1
@test REC_CALLS["child:/p/A/openapi/1"] == 1
end

@testitem "nested external children are constructed per view at every remount level" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
source.constant.grand.work
source.through_property.grand.work
for prefix in ("/first", "/p/A")
    v = remount(source; __prefix__=prefix)
    @test v.constant.grand.__parent__ === v.constant
    @test v.constant.grand.work[] == "constant/grand"
    @test v.through_property.grand.label == prefix * "/openapi/grand"
    @test v.through_property.grand.work[] == prefix * "/openapi/grand"
end
@test REC_CALLS["grand:constant/grand"] == 1
@test REC_CALLS["grand:/first/openapi/grand"] == 1
@test REC_CALLS["grand:/p/A/openapi/grand"] == 1
end

@testitem "an external child never realized on the source is the view's own" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
views = [remount(source; __prefix__="/first") for _ in 1:2]
@test views[1].constant.work !== views[2].constant.work
@test REC_CALLS["child:constant"] == 2
# Reading through a view does not realize the child on the source.
@test !haskey(DynamicObjects._remount_source(source)[2], :constant)
end

@testitem "an external child passed another parent stays the view's own" setup=[RemountExternalFixtures] begin
using DynamicObjects

rec_reset!()
source = ExtRoot(; __prefix__="/first")
retained_work = source.elsewhere.work
v = remount(source; __prefix__="/first")
@test v.elsewhere.__parent__ === REC_ELSEWHERE
@test v.elsewhere.work !== retained_work
end
