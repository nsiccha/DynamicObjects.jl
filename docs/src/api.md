# API Reference

Everything exported by `DynamicObjects`. For usage and worked examples see
the [manual](index.md).

## The struct macro

```@docs
@dynamicstruct
```

## In-struct property markers

These are pattern-matched by `@dynamicstruct` inside a struct body. Outside
a struct body they're either no-ops, real macros, or undefined. Don't rely
on them in arbitrary positions.

| Marker                          | Effect                                                                          |
|---------------------------------|---------------------------------------------------------------------------------|
| `@diskcached prop = expr`       | Persist to disk under the instance's `diskcache_path`. Per-key for indexed properties. |
| `@diskcached v"N" prop = expr`  | Versioned disk cache; bumping `N` invalidates files without changing inputs.     |
| `@persist prop = expr`          | Write the in-memory value back to disk on demand (see [`@persist`](@ref)).       |

## Cached access (call-site)

The in-memory cache on an [`IndexableProperty`](@ref) is **opt-in**: calling
the IP wrapper as a function (`o.prop(args...)`) goes straight to the body
on every call. To get cached access, route the call through
[`memoize!`](@ref) — directly, or via the [`@memo!`](@ref) macro which
rewrites every call site inside its argument.

```@docs
@memo!
memoize!
maybememoize!
```

## Cache inspection

Real macros — usable inside *and* outside `@dynamicstruct` bodies. Inside
a body, drop the object prefix and use the bare property name.

```@docs
@diskcache_status
@is_diskcached
@diskcache_path
@clear_diskcache!
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
PerPodFileTracker
NoKeyTracker
key_tracker
record!
load_keys
```
