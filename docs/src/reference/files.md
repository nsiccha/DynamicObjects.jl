# Files

## Tracked inputs

```@docs
TrackedFile
TrackedDirectory
tracked_path
tracked_paths
tracked_version
file_version
```

## Change propagation

```@docs
sync!
notify_change!
on_change!
object_version
dependents
```

## Composite mmap formats

An extension implements `DynamicObjects.save(Val(:mmap), path, value)` and
`DynamicObjects.load(Val(:mmap), path, Type)`. Register a distinct leading magic
with `DynamicObjects.register_mmap_container!(magic::AbstractVector{UInt8}, loader)`
from the extension's `__init__`; `loader(path)` handles unannotated properties.
DynamicObjects supplies the writer with an unpublished temporary path and
publishes it atomically after `save` returns. The extension must close and
validate its complete file before returning.

The stream overloads below let composite formats reuse numeric array blocks.
Record each block's exclusive end and pass it as `end_offset` when loading so
a corrupt header cannot map bytes from the next block.

```@docs
DynamicObjects.save
DynamicObjects.load
```
