using Test, DynamicObjects
const DO = DynamicObjects
const MiB = 1024^2

# The queue worker keeps up to 64 request views of a retained root (`_WORKER_KEEP`). A
# view reading a context-independent indexed property reads the root's subcache, so a
# release of that slot frees the value however many kept views have read it (snag
# `worker-remount-v-0f760831`). Run with a process budget, so results are releasable.
@dynamicstruct struct ViewApp
    ctx = nothing
    shared(i::Int) = fill(UInt8(i), MiB)
    own(i::Int) = (ctx, i)
end

const N = 20
root = ViewApp()
views = [remount(root; ctx=k) for k in 1:63]
foreach(i -> root.shared(i), 1:N)
for v in views, i in 1:N
    v.shared(i)
    v.own(i)
end
@test all(v -> getfield(v.shared, :cache) === getfield(root.shared, :cache), views)

refs = [WeakRef(root.shared(i)) for i in 1:N]
held = root.shared(N)   # a value held outside the cache stays alive: the WeakRef control
GC.gc(true)
@test all(r -> r.value !== nothing, refs)

before = DO._MEMO_EVICTED[].memory
# Reads refresh recency, so release past the views' own (63 × N) colder entries too.
DO._trim_memos!(0, typemax(Int); batch=0, process_batch=2 * 64 * N)
@test DO._MEMO_EVICTED[].memory - before >= N
GC.gc(true); GC.gc(true)
@test count(r -> r.value === nothing, refs) == N - 1
@test refs[N].value === held
@test length(views) == 63   # the views stayed alive throughout
@test views[1].shared(1) == fill(UInt8(1), MiB)   # a later read recomputes
