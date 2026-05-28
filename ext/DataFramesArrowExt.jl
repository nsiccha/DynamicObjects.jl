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

DynamicObjects.load(::Val{:mmap}, path::AbstractString, ::Type{DataFrame}) =
    DataFrame(Arrow.Table(path); copycols=false)

end
