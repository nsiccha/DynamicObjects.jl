# Fresh-process fixture for test/property_invalidation.jl: no tracked value exists and
# no `clear_cache!` has moved a version, so `sync!` looks at nothing until
# `clear_mem_caches!` moves one.
module ClearMemCachesHolderProcess
using DynamicObjects

const SOURCE = Ref(1)

@dynamicstruct struct Inner
    x::Int
    value = SOURCE[] * x
end

@dynamicstruct struct Holder
    inner(x::Int) = Inner(x)
    total(x::Int) = inner(x).value + 100
end

h = Holder()
h.total(2) == 102 || error("before the clear: total(2) = $(h.total(2))")
DynamicObjects._TRACKED_IN_USE[] && error("not a fresh process: sync! already looks")
isempty(sync!(h)) || error("sync! dropped something before the clear")

SOURCE[] = 5
clear_mem_caches!(h.inner(2))
dropped = sync!(h)
dropped == [:total] || error("sync! dropped $dropped, expected [:total]")
h.total(2) == 110 || error("after the clear: total(2) = $(h.total(2))")
println("CLEAR-HOLDER-PROCESS-OK")
end
