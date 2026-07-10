module DataFramesArrowExt

using DynamicObjects, Arrow, DataFrames

# Arrow-backed `@mmap` for a `DataFrame` property. Slots under the existing
# `:mmap` disk-format token by value-type dispatch — no new marker, no macro
# change. A property declared `@mmap tbl::DataFrame = …` emits
# `_disk_format = Val(:mmap)` + `_disk_eltype = DataFrame`, so the disk path
# dispatches `save(Val(:mmap), path, ::DataFrame)` on write and
# `load(Val(:mmap), path, ::Type{DataFrame})` on read. Both win unambiguously
# over the core `::AbstractArray` / `::Type{<:AbstractArray}` / `::Any` methods
# (DataFrame and AbstractArray are disjoint).
#
# `copycols=false` keeps the columns as Arrow's memory-mapped, read-only
# vectors (mutation faults with ReadOnlyMemoryError) — the same PROT_READ
# contract as the array `@mmap` path. The columns live in the OS page cache,
# so `_is_mmap_slot`'s LRU zero-bill is correct for them.
DynamicObjects.save(::Val{:mmap}, path::AbstractString, df::DataFrame) =
    Arrow.write(path, df)

# `Arrow.Table` returns an empty 0-column table — it does NOT throw — when
# handed a non-Arrow file (e.g. a stale Serialization `.sjl` left at the same
# cache_path by a prior `@cached` version of this property). Without a guard,
# DO's disk-cache load-failure catch (DynamicObjects.jl:1583-1591) never fires
# and the empty table is served as a valid cache hit. Validate the Arrow file
# magic (b"ARROW1") and throw on mismatch — mirroring the raw mmap path's
# `_mmap_read_header` DOMM check — so the stale file is rm'd and recomputed.
const _ARROW_MAGIC = (0x41, 0x52, 0x52, 0x4f, 0x57, 0x31)  # b"ARROW1"

# `@mmap df = …` with NO `::DataFrame` annotation: the disk path calls
# `load(Val(:mmap), path, nothing)`, which sniffs the file's leading magic and
# routes here instead of into DO's own `DOMM` array container. Registered from
# `__init__` because a top-level `push!` into DynamicObjects' registry would run
# at precompile time and not survive into the loading process.
__init__() = DynamicObjects.register_mmap_container!(collect(UInt8, _ARROW_MAGIC),
    path -> DynamicObjects.load(Val(:mmap), path, DataFrame))

function DynamicObjects.load(::Val{:mmap}, path::AbstractString, ::Type{DataFrame})
    fsz = filesize(path)
    fsz >= 2 * length(_ARROW_MAGIC) ||
        error("@mmap DataFrame: $path is $fsz bytes — too short to be an Arrow file; throwing so DynamicObjects recomputes.")
    open(path, "r") do io
        magic = ntuple(_ -> eof(io) ? 0x00 : read(io, UInt8), 6)
        magic == _ARROW_MAGIC ||
            error("@mmap DataFrame: $path is not an Arrow file (bad magic $magic, expected b\"ARROW1\") — likely a stale cache in a different format; throwing so DynamicObjects recomputes.")
        # An Arrow IPC file repeats the magic AFTER its footer, so a truncated file
        # keeps the leading magic and loses the trailing one. `Arrow.Table` does NOT
        # throw on that — it silently yields a 0-row table (measured), which the disk
        # cache would then serve as a valid hit: empty draws, no warning. Arrow also
        # mmaps and `unsafe_wrap`s buffers at offsets read from the (now missing)
        # footer, which is a fault waiting to happen. Reject before parsing.
        seek(io, fsz - length(_ARROW_MAGIC))
        tail = ntuple(_ -> read(io, UInt8), 6)
        tail == _ARROW_MAGIC ||
            error("@mmap DataFrame: $path is truncated — missing the trailing b\"ARROW1\" magic (found $tail). A partial cache file (e.g. the disk filled mid-write); it will be deleted and recomputed.")
    end
    df = DataFrame(Arrow.Table(path); copycols=false)
    # LRU provenance (D6): `copycols=false` means these column objects ARE the
    # memory-mapped buffers Arrow just handed us, so they are what billing will
    # meet when it descends the DataFrame. Mark the columns, not the frame — a
    # frame walked field-by-field would also sweep up the heap `Vector`s inside
    # its column index and silently zero-bill them.
    for col in eachcol(df)
        DynamicObjects._mark_mmapped!(col)
    end
    df
end

# Content-canonical hash key for a bare `DataFrame` in `hash_fields`. Without
# this, the generic `_hash_replace(x) = x` fallthrough serializes the df
# whole — including its `colindex` Dict, table/col metadata, and any
# view/lazy column wrappers, all of which are process-varying structural
# state, not content. Reducing to names + densified columns strips that
# state while keeping logical content — the same collapse a `Matrix(df)`
# workaround relies on, but keeps column names and doesn't `Any`-promote
# heterogeneous columns. `collect` deliberately keeps `CategoricalValue`s
# as-is (no CategoricalArrays dep here) — they hash stably through
# Serialization. This is cross-process stability only; cross-version
# stability is out of scope.
DynamicObjects._hash_replace(df::AbstractDataFrame) =
    (string.(names(df)), [collect(c) for c in eachcol(df)])

end
