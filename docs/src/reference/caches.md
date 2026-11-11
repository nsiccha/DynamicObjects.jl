# Caches

## Inspection

```@docs
@cache_status
@is_cached
@cache_path
entries
cached_entries
mem_cache_entries
DynamicObjects.MemCacheEntry
```

## Invalidation

```@docs
@clear_cache!
DynamicObjects.clear_cache!
invalidate!
clear_mem_caches!
clear_disk_caches!
clear_all_caches!
prune_mem_caches!
```

## Persistence

```@docs
@persist
PersistentSet
LazyPersistentDict
DynamicObjects.canonical_hash
```

## Key tracking

```@docs
KeyTracker
SharedFileTracker
NoKeyTracker
key_tracker
record!
load_keys
```

## Refresh

```@docs
BackgroundCache
```
