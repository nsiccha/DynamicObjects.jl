# A package whose indexed properties carry the annotation forms
# `resolve_annotation` looks up. `AnnotationProbe` reflects them while its own
# image is written, when Julia refuses evaluation into this module.
module AnnotationOwner
using DynamicObjects
const Names = Vector{Symbol}
@dynamicstruct struct Page
    item(name::Symbol) = string(name)
    detail(id::Int; n::Int=1) = id + n
    qualified(r::Base.RefValue{Int}) = r[]
    bounded(v::AbstractVector{<:Real}) = sum(v)
    tagged(t::Val{:x}) = 1
    aliased(xs::Names) = length(xs)
    named(x::@NamedTuple{a::Int}) = x.a
    called(f::typeof(sum)) = 1
    bound(x::(Vector{T} where T<:Integer)) = x
    # A form only evaluation resolves: untyped while the image is written.
    picked(x::(true ? Int : String)) = x
    typed(x::Int)::Int = x
end
end
