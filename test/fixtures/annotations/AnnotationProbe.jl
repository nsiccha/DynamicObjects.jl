# Reads `AnnotationOwner.Page`'s signatures at top level, so the reads run
# while this package's image is written and `AnnotationOwner` is closed.
module AnnotationProbe
using DynamicObjects, AnnotationOwner
const PROPERTIES = (:item, :detail, :qualified, :bounded, :tagged, :aliased, :named, :called, :bound, :picked)
types(args) = Any[a.type for a in args]
function read_types()
    out = Pair{Symbol,Any}[]
    for p in PROPERTIES
        sig = DynamicObjects.property_signature(AnnotationOwner.Page, p)
        push!(out, p => (types(sig.positional), types(sig.kwargs)))
    end
    push!(out, :output => DynamicObjects.property_descriptor(AnnotationOwner.Page, :typed).output.type)
    out
end
const GENERATING = ccall(:jl_generating_output, Cint, ())
const WHILE_WRITTEN = read_types()
# One line per read: name, whether it matches the run-time read, both values.
report() = for ((p, written), (_, now)) in zip(WHILE_WRITTEN, read_types())
    println("ANNOTATION ", p, " ", isequal(written, now), " ", repr(written), " ", repr(now))
end
end
