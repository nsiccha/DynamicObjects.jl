# Integration probe with BridgeStan's public test_models/simple/simple.stan.
# Pass its compiled shared library in ARGS and start with a large heap hint.
using Test, DynamicObjects, BridgeStan
const DO = DynamicObjects
@dynamicstruct struct ModelCache
    library::String
    model(i) = BridgeStan.StanModel(library, "{\"N\":2}", 204; warn=false)
    pinned = BridgeStan.StanModel(library, "{\"N\":2}", 204; warn=false)
    marker(i) = i
end
DO.memo_native_bytes(::Type{ModelCache}, ::Val{:model}, ::BridgeStan.StanModel) = missing
function check_model(library)
    o = ModelCache(library)
    held = o.model(1)
    pinned = o.pinned
    q = [0.5, -0.75]
    expected = BridgeStan.log_density_gradient(held, q)
    @test expected == (-sum(abs2, q)/2, -q)
    with_compute_scope() do
        @test o.model(1) === held
        o.marker(1)
        DO._trim_memos!(typemax(Int))
        @test o.model(1) === held
    end
    o.marker(2)
    before = memo_retention_stats()
    DO._trim_memos!(typemax(Int))
    @test memo_retention_stats().unknown_native_slots == before.unknown_native_slots + 1
    GC.gc(true)
    rebuilt = o.model(1)
    @test rebuilt !== held
    @test BridgeStan.log_density_gradient(rebuilt, q) == BridgeStan.log_density_gradient(held, q) == expected
    @test o.pinned === pinned
    WeakRef(held)
end
old = check_model(only(ARGS))
GC.gc(true)
@test old.value === nothing
