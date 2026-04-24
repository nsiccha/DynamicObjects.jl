# API Reference

Everything exported by `DynamicObjects`. For usage and worked examples see
the [manual](index.md).

## The struct macro

```@docs
@dynamicstruct
```

## In-struct property markers

These are *not* real macros — they are pattern-matched by `@dynamicstruct`
inside a struct body. Outside a struct body they're either no-ops, real
macros (e.g. `@memo`), or undefined. Don't rely on them in arbitrary
positions.

| Marker                       | Effect                                                                                  |
|------------------------------|-----------------------------------------------------------------------------------------|
| `@cached prop = expr`        | Persist to disk under `cache_path`. Per-key for indexed properties.                     |
| `@cached v"N" prop = expr`   | Versioned disk cache; bumping `N` invalidates files without changing inputs.            |
| `@persist prop = expr`       | Write the in-memory value back to disk on demand (see [`@persist`](@ref)).              |
| `@lru N prop(idx) = expr`    | Bound the per-property in-memory dict to `N` entries (LRU eviction).                    |
| `@memo prop = expr`          | Inside a struct: rewrite call → bracket access. Outside: process-wide function memoize. |

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
fetchindex
fetchindex!
getstatus
```

## Cache maintenance

```@docs
entries
cached_entries
clear_all_caches!
clear_mem_caches!
clear_disk_caches!
```

## Cancellation

```@docs
cancel!
cancel_all!
```

## Error handling

```@docs
PropertyComputationError
unwrap_error
```

## Persistent / bounded collections

```@docs
PersistentSet
LazyPersistentDict
LRUDict
ThreadsafeLRUDict
```

## Pluggable key tracking

For bounding on-disk caches when the full key set isn't known up front.

```@docs
KeyTracker
SharedFileTracker
PerPodFileTracker
NoKeyTracker
key_tracker
record!
load_keys
```
