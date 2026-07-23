using TestItemRunner

@testmodule IncludeCallFormFixtures begin
using DynamicObjects
export IncludeLeaf, IncludeRoot, IncludeSelfNamedRoot

@dynamicstruct struct IncludeLeaf
    key::Symbol
    label = uppercase(string(key))
end

# `@include item(key) = Leaf(key)` is a SHORT-FORM METHOD DEFINITION, so Julia
# hands DO the same `:block` rhs as `@include kid = begin … end`. Before the
# unwrap, the call form was rejected with the block form's error message and no
# call-form include could register its child type at all.
@dynamicstruct struct IncludeRoot
    base::String
    @include kid = IncludeLeaf(:root)
    @include item(key::Symbol) = IncludeLeaf(key)
    port::Int = 8080
end

# The two fixes meet here: the index arg is named after the property AND the
# declaration is a call-form include. This is the mock's `dataset(dataset)`.
@dynamicstruct struct IncludeSelfNamedRoot
    base::String
    @include dataset(dataset::Symbol) = IncludeLeaf(dataset)
end
end

@testitem "call-form @include mounts a child" setup=[IncludeCallFormFixtures] begin
using DynamicObjects

o = IncludeRoot("/x")
@test o.kid.label == "ROOT"
@test o.item(:a).label == "A"
@test o.item(:b).label == "B"
# The include wiring is the same for both forms: the child knows its parent.
@test o.item(:a).__parent__ === o
@test o.kid.__parent__ === o

# The indexed declaration keeps its index; nothing was folded into a block body.
info = DynamicObjects.metafirst(IncludeRoot, :item)
@test info.indexed
@test collect(info.indices) == [:(key::Symbol)]
@test Meta.isexpr(info.rhs, :call)
end

@testitem "call-form @include registers the child type" setup=[IncludeCallFormFixtures] begin
using DynamicObjects

# The whole point: a consumer (HTMXObjects' route walker) can recover the child
# type from the type alone, before any object exists.
@test nested_object_type(IncludeRoot, :item) === IncludeLeaf
@test nested_object_type(IncludeRoot, :kid) === IncludeLeaf
@test nested_object_type(IncludeSelfNamedRoot, :dataset) === IncludeLeaf

# Guarded: a typed primitive registers with the analyzer hook but is NOT a
# nested object, so a route walker following this never reaches `meta(Int)`.
@test DynamicObjects._walk_nested_type(IncludeRoot, :port) === Int
@test nested_object_type(IncludeRoot, :port) === nothing
@test nested_object_type(IncludeRoot, :base) === nothing
@test nested_object_type(IncludeLeaf, :label) === nothing
@test nested_object_type(Int, :x) === nothing
end

@testitem "a self-named index survives the include rewrite" setup=[IncludeCallFormFixtures] begin
using DynamicObjects

o = IncludeSelfNamedRoot("/x")
@test o.dataset(:north).label == "NORTH"
@test o.dataset(:north).__parent__ === o
@test DynamicObjects._self_named_index(o, Val(:dataset))
end

@testitem "_unwrap_short_form_body is total" begin
using DynamicObjects
unwrap = DynamicObjects._unwrap_short_form_body

# The parser's wrapping around a short-form method body: one statement out.
@test unwrap(Meta.parse("f(x) = g(x)").args[2]) == :(g(x))
@test unwrap(Meta.parse("item(key::Symbol) = Leaf(key)").args[2]) == :(Leaf(key))

# A REAL body comes back as the same block — never a sentinel. HTMXObjects
# delegates here and converts a multi-statement `@include revise = begin … end`
# into an inline sub-router by testing `Meta.isexpr(out, :block)`; returning
# `nothing` fell through that check, dropped the declaration, and took
# HTMXObjects/src/routes/shared_ops_routes.jl:21 down at load time.
body = Meta.parse("kid = begin\n    a = 1\n    Leaf(a)\nend").args[2]
@test unwrap(body) === body
@test Meta.isexpr(unwrap(body), :block)

# Anything it cannot unwrap passes straight through.
@test unwrap(:x) === :x
@test unwrap(:(Leaf(1))) == :(Leaf(1))
@test unwrap(1) === 1
@test unwrap(Meta.parse("f(x) = begin end").args[2]) == Meta.parse("f(x) = begin end").args[2]
end

@testitem "a genuine block body is still rejected under @dynamicstruct" setup=[IncludeCallFormFixtures] begin
using DynamicObjects

# Only a SINGLE-statement block is the parser's short-form wrapping. A real
# body — bare or indexed — is an HTMXObjects sub-router and has no meaning here.
for bad in (
    quote
        @dynamicstruct struct BadBareBlockInclude
            base::String
            @include kid = begin
                a = 1
                IncludeLeaf(:x)
            end
        end
    end,
    quote
        @dynamicstruct struct BadIndexedBlockInclude
            base::String
            @include item(key::Symbol) = begin
                a = key
                IncludeLeaf(a)
            end
        end
    end,
)
    err = try (@eval $bad; nothing) catch e; e end
    @test err !== nothing
    @test occursin("inline sub-router", sprint(showerror, err))
end
end
