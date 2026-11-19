using Test, DynamicObjects
const DO = DynamicObjects
const RELEASE = Channel{Nothing}(1)
const STARTED = Channel{Nothing}(1)
slow_result() = (put!(STARTED, nothing); take!(RELEASE); [42])
@dynamicstruct struct RetentionOrder
    folder::String
    __cache_base__ = folder
    override = "default"
    @state attempt = Ref(0)
    @struct child = begin
        @state counter = Ref(0)
    end
    bytes(k) = fill(UInt8(k), 256)
    mixed(k) = Any[k]
    alias(k) = bytes(1)
    @cached saved(k) = fill(UInt8(k), 16)
    @mmap mapped(k) = fill(UInt8(k), 1024)
    native = (handle=Ptr{Cvoid}(1),)
    slow = slow_result()
end
keys_in(ip) = Set(first(first(e.key)) for e in entries(ip) if e.state === :done)
trim_one() = DO._trim_memos!(typemax(Int); batch=1)
drain() = DO._trim_memos!(typemax(Int); batch=256)

@testset "physical generations and report ownership" begin
    o = RetentionOrder(mktempdir(); override="input")
    o.attempt[] = 4
    child = o.child
    child.counter[] = 9
    native = o.native
    old = o.bytes(1)
    o.bytes(2)
    o.bytes(1)
    disk = o.saved(1)
    o.bytes(3)
    version = object_version(o)
    trim_one()
    @test isempty(keys_in(o.saved))
    @test keys_in(o.bytes) == Set(1:3)
    trim_one()
    @test keys_in(o.bytes) == Set([1, 3])
    @test o.saved(1) == disk
    @test object_version(o) == version
    @test o.bytes(1) === old

    # A deleted disk file loses priority. Preserve the original ordering
    # among memory-only candidates and recheck the physical generation.
    gone = o.saved(2)
    rm(@cache_path o.saved(2))
    o.bytes(6)
    before = memo_retention_stats()
    drain()
    @test memo_retention_stats().disk == before.disk + 1 # saved(1) still had its file
    @test isempty(keys_in(o.saved))
    @test o.saved(2) == gone

    # A pending handle can be fetched repeatedly after its original slot was
    # reclaimed, without rerunning its gated computation.
    p = DO.fetchproperty((value, status) -> value, o, :slow)
    take!(STARTED)
    drain()
    put!(RELEASE, nothing)
    v = fetch(p)
    o.bytes(10)
    drain()
    @test isready(p) && fetch(p) === v
    @test !any(e -> e.property == :slow, mem_cache_entries(o))

    existing = o.bytes(7)
    with_compute_scope() do
        @test o.bytes(7) === existing
        claimed = o.bytes(8)
        DO.ScopedValues.with(DO._COMPUTE_SCOPE => nothing) do
            @test o.bytes(8) === claimed  # adopted while the report still owns it
            o.bytes(9)
            drain()
        end
        @test o.bytes(7) === existing && o.bytes(8) === claimed
    end
    o.bytes(10)
    drain()
    @test isempty(intersect(keys_in(o.bytes), [7, 8]))
    @test o.attempt[] == 4 && o.child === child && child.counter[] == 9
    @test o.override == "input"
    @test any(e -> e.property === :native && e.value === native, mem_cache_entries(o))

    mixed = o.mixed(1)
    push!(mixed, child)
    o.bytes(20)
    drain()
    @test o.mixed(1) === mixed && last(mixed) === child

    # Each removed reference contributes its logical slot payload. A caller
    # may keep that same storage alive after both slots disappear.
    shared = o.alias(1)
    @test shared === o.bytes(1)
    o.bytes(20)
    drain()
    before = memo_retention_stats()
    a = o.bytes(1)
    @test o.alias(2) === a
    o.bytes(20)
    drain()
    after = memo_retention_stats()
    @test after.memory - before.memory == 2
    @test after.estimated_payload_bytes - before.estimated_payload_bytes == 2 * sizeof(a)
    @test all(==(1), a)
    o.mapped(1)
    o.bytes(20)
    before = memo_retention_stats()
    trim_one()
    after = memo_retention_stats()
    @test after.disk == before.disk + 1
    @test after.mapped_payload_bytes == before.mapped_payload_bytes + 1024
    @test after.estimated_payload_bytes == before.estimated_payload_bytes
end

@testset "hits through a held indexed property sample heap pressure" begin
    root = RetentionOrder(mktempdir())
    ip = root.bytes
    ip(1)
    keep = ip(2)
    hint = DO._HEAP_HINT[]
    try
        DO._HEAP_HINT[] = 1
        DO._NEXT_MEMO_CHECK[] = 0
        @test ip(2) === keep
        @test keys_in(ip) == Set([2])
    finally
        DO._HEAP_HINT[] = hint
    end
end

@dynamicstruct struct RetentionView
    tag = "source"
    value(k) = fill(k, 8)
    label(k) = (tag, k)
end

@testset "remount and root lifetime" begin
    root = RetentionView()
    mounted = remount(root; tag="request")
    shared = mounted.value(1)
    @test root.value(1) === shared
    @test mounted.label(1) == ("request", 1)
    @test root.label(1) == ("source", 1)
    mounted.value(2)
    drain()
    @test 1 ∉ keys_in(mounted.value) && 1 ∉ keys_in(root.value)
    @test root.label(1) != mounted.label(1)
    function discarded()
        transient = RetentionView()
        data = transient.value(42)
        WeakRef(data)
    end
    ref = discarded()
    GC.gc(true)
    @test ref.value === nothing
end
