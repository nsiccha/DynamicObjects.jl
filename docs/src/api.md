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
