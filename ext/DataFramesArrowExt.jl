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
function DynamicObjects.load(::Val{:mmap}, path::AbstractString, ::Type{DataFrame})
    open(path, "r") do io
        magic = ntuple(_ -> eof(io) ? 0x00 : read(io, UInt8), 6)
        magic == (0x41, 0x52, 0x52, 0x4f, 0x57, 0x31) ||  # b"ARROW1"
            error("@mmap DataFrame: $path is not an Arrow file (bad magic $magic, expected b\"ARROW1\") — likely a stale cache in a different format; throwing so DynamicObjects recomputes.")
    end
    DataFrame(Arrow.Table(path); copycols=false)
end

end
