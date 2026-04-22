# API Reference

Exports of `DynamicObjects`. For usage, patterns, and worked examples see the
[manual](index.md).

## The struct macro

```@docs
@dynamicstruct
```

## Caching macros

In-struct property markers (pattern-matched by `@dynamicstruct`, not real
macros — do not use outside a struct body):

- `@cached prop = expr` — on-disk JLD2 cache, keyed by hashable ancestry.
- `@persist prop = expr` — like `@cached` but writes a single file per object,
  recomputes on mismatch.
- `@lru prop = expr` — process-local LRU cache.
- `@memo prop = expr` — unbounded in-process memoisation.

Real macros for inspecting the `@cached` path of a property:

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

## Error handling

```@docs
PropertyComputationError
unwrap_error
```

## Supporting types

```@docs
PersistentSet
LazyPersistentDict
ThreadsafeLRUDict
LRUDict
```

## Key tracking (advanced)

For bounding on-disk caches when the full key set isn't known up front:

```@docs
KeyTracker
NoKeyTracker
SharedFileTracker
PerPodFileTracker
key_tracker
record!
load_keys
```

## Cancellation

```@docs
cancel!
cancel_all!
```
