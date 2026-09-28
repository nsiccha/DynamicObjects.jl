# API Reference

Everything exported by `DynamicObjects`. For usage and worked examples see
the [manual](index.md).

## The struct macro

```@docs
@dynamicstruct
```

## In-struct property markers

These are *not* real macros — they are pattern-matched by `@dynamicstruct`
inside a struct body. Don't rely on them in arbitrary positions.

| Marker                       | Effect                                                                                  |
|------------------------------|-----------------------------------------------------------------------------------------|
| `@cached prop = expr`        | Persist to disk under `cache_path`. Per-key for indexed properties.                     |
| `@cached v"N" prop = expr`   | Versioned disk cache; bumping `N` invalidates files without changing inputs.            |
| `@persist prop = expr`       | Write the in-memory value back to disk on demand (see [`@persist`](@ref)).              |

## Cache inspection

Real macros — usable inside *and* outside `@dynamicstruct` bodies. Inside
a body, drop the object prefix and use the bare property name.

```@docs
@cache_status
@is_cached
@cache_path
@clear_cache!
@persist
```

## Functions

```@docs
remake
remount
fetchindex
fetchindex!
fetchproperty
fetchproperty!
getstatus
Pending
```

## Reflection and application declarations

```@docs
property_descriptor
property_descriptors
type_descriptor
option_declarations
has_option_declaration
property_options
option_domain
option_records
declaration_metadata
declaration_graph
declaration_node_id
materialization_observation
declaration_observations
```

## Cache maintenance

```@docs
entries
cached_entries
clear_all_caches!
clear_mem_caches!
clear_disk_caches!
invalidate!
```

## Error handling

```@docs
PropertyComputationError
unwrap_error
```

## Persistent collections

```@docs
PersistentSet
LazyPersistentDict
```

## Pluggable key tracking

For bounding on-disk caches when the full key set isn't known up front.

```@docs
KeyTracker
SharedFileTracker
NoKeyTracker
key_tracker
record!
load_keys
```

## Composite mmap formats

An extension implements both `DynamicObjects.save(Val(:mmap), path, value)` and
`DynamicObjects.load(Val(:mmap), path, Type)`. Register a distinct leading magic
with `DynamicObjects.register_mmap_container!(magic::AbstractVector{UInt8}, loader)`
from the extension's `__init__`; `loader(path)` handles unannotated properties.
DO supplies the writer with an unpublished sibling temporary path and renames
it atomically after `save` succeeds. The extension must close and validate its
whole envelope before returning, including its structural metadata and EOF.

Composite containers can reuse DOMM numeric blocks without copying DO's type
registry, alignment or mmap implementation:

```julia
path = tempname()
blocks = open(path, "w") do io
    write(io, "container-prefix")
    map(([1.0, 2.0], fill(Int16(3)))) do array
        start = position(io)
        DynamicObjects.save(Val(:mmap), io, array)
        (start, position(io))
    end
end
arrays = open(path, "r") do io
    map(blocks) do (start, stop)
        seek(io, start)
        DynamicObjects.load(Val(:mmap), io; end_offset=stop)
    end
end
# arrays == ([1.0, 2.0], fill(Int16(3))); mappings survive the stream close.
```

Stream overloads leave stream ownership with the caller. Loads require a
read-only file stream and advance to the exact numeric block end. Supply the
exclusive `end_offset` stored by the envelope to keep a corrupt leaf header from
mapping the next leaf's bytes. Stream loading handles numeric DOMM blocks; the
container registry remains the path-level format dispatcher.

```@docs
DynamicObjects.save
DynamicObjects.load
```
