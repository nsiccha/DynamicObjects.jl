# Changelog

All notable changes to DynamicObjects.jl are documented here, newest first.

Every landing that adds or changes public API (an export, a macro or marker, a
keyword, a method, or documented behaviour a dependant can rely on) bumps the
patch digit in `Project.toml` and adds its entry under a new heading at the
top of this file. An entry that breaks something a dependant relies on says
**Breaking:** and what to change. The minor digit, the breaking one in
[semantic versioning](https://semver.org/) before 1.0, last moved at 0.5.0.
A package or app that calls that API states the version as its floor, for
example `[compat] DynamicObjects = "0.5.1"`. An environment that pins an older
DynamicObjects commit is then refused when it resolves, with
`Unsatisfiable requirements detected for package DynamicObjects`, instead of
failing or silently behaving differently at run time.

## 0.5.1

The first version since 0.5.0 that names an API line. It carries everything on
`pre-inference` from 0.5.0 (`3840678`) up to this release, so a
"DynamicObjects ≥ `<commit>`" floor stated for any earlier commit is met by
0.5.1. Among it:

- Deferred and `@queued` work runs in its requester's `ScopedValue` scope, so
  a layer's request context (HTMXObjects' reader and page language) reaches a
  computation that another job's slot release admits or an executor's worker
  runs. Only the job queue's slot stays the running task's own. New
  dependency: ScopedValues 1.6 (`ffb9d70`).
- Deferred and queued work logs to its requester's logger (`ba25e73`).
- `@queued` marks an indexed property whose computations run through the
  process-wide job queue; `DynamicObjects.configure_queue!(; max_running)`
  bounds how many run at once and `DynamicObjects.queue_settings()` reports
  it (`64aba0c`).
- `DynamicObjects.property_executor(o, Val(name))` declares where an indexed
  property's computations run, and `DynamicObjects.await_deferred` is the hook
  a blocking caller waits through (`5db38c6`); a `Deferred` selector hands
  background computations to an executor (`463b82a`).
- `invalidate!(ip, args...; kwargs...)` drops one indexed entry (`a2576d3`).
- `BackgroundCache`: a standalone stale-while-revalidate cache, with batched
  refresh through `build_many` and an `on_settle` callback after each store
  (`331aefd`, `700816f`, `ef11fe2`).
- `TrackedFile`, `TrackedDirectory`, `sync!`, `on_change!`, `notify_change!`,
  `object_version` and `dependents`: tracked file values, and `sync!` drops
  what read a changed input (`9a37cf4`).
- `@clear_cache! obj.prop` and `DynamicObjects.clear_cache!(obj, :name)` drop
  the property's dependents too (`7dacad2`).
- `@state` declares per-instance state that clears keep (`cd2c284`).
- `DynamicObjects.property_settled` reports each value a memoized property
  stores (`d92f2d2`).
- An invalidated in-flight computation publishes nothing, and its waiters
  wake and re-resolve (`515f6ec`, `bddc145`).
- `DynamicObjects.canonical_hash(x)` is the public digest for a custom
  `__hash__` (`24a7d68`).
- `mem_cache_entries(root)` and `prune_mem_caches!(keep, root)` walk and prune
  the in-memory caches (`c228a2c`).
- `with_compute_trace`, `ComputeTrace` and `compute_trace_rows`: an opt-in
  record of what a computation read, computed, waited on and invalidated
  (`8a3b3f7`).
- Property reads written in any body nest in its Treebars progress node, and
  unmarked bodies run inline phases (`ed0f8bc`, `704256e`); a `@progress`
  label may read properties (`7613902`, needs Treebars `3282255`).
- Progress labels take a docstring's summary section (`bfde319`).
- Composite mmap streams accept bounded read-only blocks (`b20ab45`).
- Cache identity changed, so the affected entries are computed once more and
  the old directories stay on disk until deleted:
  - DynamicObjects arguments in disk-cache keys are keyed by their `__hash__`
    (`f0b896f`);
  - the default identity covers the construction inputs an object reads
    (`6818ea9`);
  - a `@versioned` type's identity follows its declared `__hash__` or
    `__hash_fields__` (`5829ce4`).
- Automatic storage never changes a value's type, and memory-maps only large
  values (`9aafcd6`).

## 0.5.0

Every commit from `3840678` until 0.5.1. The number names no API line, so a
dependant cannot use it as a floor for API added after `3840678`.
