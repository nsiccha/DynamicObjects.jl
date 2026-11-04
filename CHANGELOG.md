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

## 0.5.6

- A property that reads a member of an inline `@struct` child is shared across
  `remount` views unless that member reaches rebound context. It was recomputed
  for every view, and so was everything derived from it, so a retained request
  root paid for that work on every request. With `model = make(pins.ap3)`,
  `fit = model.fit()` and `evaluation = score(fit)`, all three now compute once.
  It stays per view, with each view's value, when the member reads context
  directly, through a forwarded parent name or `__parent__`, or through a nested
  child, or through a keyword default of the child's call; when the body holds
  the child itself (`f(pins)`); and when the member is opaque. `sync!` and
  `clear_cache!` reach these properties as before.
- Such a property now follows the contract of every shared property. One that
  also depends on something no input records, such as the clock or a file read
  through a plain path, used to be recomputed per request by accident and now
  keeps its first value: declare it `@fresh`, or read the file through a
  `TrackedFile`. As a shared property, a `@cached` or `@mmap` one now uses its
  disk entry through a view.
- `remount` decides its routing once per type and set of rebound names, instead
  of on every call. On a struct of 300 properties it takes 125 µs, down from
  579 µs.

## 0.5.5

- One disk entry per memo entry. Calls whose arguments are `isequal` share a
  memory entry, and they now share a `@cached`/`@mmap` entry too, for positional
  and keyword arguments and for an indexed inline child's directory and
  `__hash__`. `f(-50)` and `f(-50.0)` used to name two files, so a restart
  recomputed whichever spelling had not computed first. This covers numbers of
  any type, a `SubString` and its `String`, ranges, views and arrays of any
  numeric element type, tuples, named tuples, pairs, and `Dict`s and `Set`s
  whatever their insertion history.
- Fixed: a non-dyadic `Float32` shared a file with the `Float64` that prints the
  same, so `f(0.1)` could return the value stored by `f(0.1f0)`. An existing file
  cannot tell which of the two wrote it. If a property was called with both
  types, bump its `v"N"`.
- Fixed: an argument printing a `/` (`1//3`, `Symbol("a/b")`) wrote a nested file
  that `clear_disk_caches!` never removed. It is now a flat entry, `f_1over3.sjl`.
- A later spelling gets the result the first spelling computed, across a restart
  as within a process. A property whose result depends on an argument's type
  rather than its value, or that has same-name methods split by numeric type
  (`f(x::Int)` and `f(x::Float64)`), already behaved this way in memory.
- These stay separate entries, which costs a recompute and never serves a wrong
  value: `Bool` against numbers, a range longer than 2^24 against its array, array
  wrappers such as sparse arrays against their dense equal, an argument holding
  one array twice against one holding two equal arrays, and types with their own
  cross-type `isequal` (`Day(1)` and `Hour(24)`).
- **Breaking:** these disk keys move once. The next access recomputes the entry,
  and the old file stays as an orphan no process reads until
  `clear_disk_caches!`, `clear_cache!` or your own cleanup removes it: an
  integer-valued float (`mwc_24.0.sjl` becomes `mwc_24.sjl`), an array whose
  elements are all integer-valued floats, a tuple holding an integer-valued float
  (`(0.5, 1.0)`), a non-dyadic `Float32`, a rational, a range, view or bit array,
  a `SubString`, a complex number with integer-valued float parts, an array of any
  other numeric or abstract element type, every `Dict` or `Set` argument, and the
  `__hash__` of an indexed inline child whose index has one of these spellings.
  Keys of `Int`, `Bool`, `Symbol`, `String`, non-integer floats, `Vector{Int}`,
  float vectors holding a non-integer, `@dynamicstruct` objects and `DataFrame`s
  do not move.

## 0.5.4

- DynamicObjects states its Treebars floor where Pkg sees it:
  `[compat] Treebars = "0.1.1"`. Treebars 0.1.1 (`14068fa`) is the first
  Treebars version number that carries everything DynamicObjects uses, the
  last of it being `treebar_notes` (Treebars `753f826`, needed since 0.5.2).
  An environment that pins an older Treebars is now refused when it resolves,
  with `Unsatisfiable requirements detected for package Treebars`, instead of
  resolving and then failing to load. That includes the commits from `753f826`
  up to `14068fa`: they carry `treebar_notes` but still say 0.1.0.
  **Breaking:** an environment pinning one of those commits moves its Treebars
  pin to `14068fa` (0.1.1) or later when it moves to DynamicObjects 0.5.4.
  The load-time check stays, for an environment that loads DynamicObjects
  without resolving it. Its message now names Treebars 0.1.1.

## 0.5.3

- Quoted code in a property body stays as written. A name inside `:(…)` or
  `quote … end` that equals a sibling property is no longer rewritten to
  `__self__.name`, and it no longer counts as a dependency of the property:
  `fragment = :(1 + source)` returns `:(1 + source)`, and `@fetch!`,
  `@dynamic_progress`, `@memo!` and `@fresh` leave calls inside a quote alone.
  An assignment in a quote (`:(source = 1)`) is no longer refused as shadowing
  a property. What the quote interpolates when it is built is ordinary body
  code: `$source` reads the sibling, and the read nests under the body's
  progress node. A nested quote takes one more `$`, as in Julia.
  **Breaking:** a body that relied on the old rewrite gets a bare symbol
  instead of `__self__.name`; interpolate the value with `$name`.

## 0.5.2

- The notes DynamicObjects writes into Treebars progress nodes follow the
  language of the page that renders them: `from disk: 26.9 MB` while a
  `@cached` value loads, `queued · #k` while a computation waits in the job
  queue, and `(cached)` on an in-memory hit. A page declaring
  `__lang__ = "de"` shows `aus dem Zwischenspeicher (26,9 MB)`,
  `wartet · Nr. 2` and `(zwischengespeichert)`; English renders the old
  strings. DO's words are the table `DynamicObjects.progress_notes`, which an
  app rewords through Treebars' `treebar_texts` (`9cc0d8a`).
- An in-memory hit's `(cached)` is now the node's note instead of a suffix on
  its label, so it replaces an earlier `from disk: …` note: a node loaded from
  disk and later hit reads `X — (cached)`, no longer
  `X (cached) — from disk: 26.9 MB` (`9cc0d8a`).
- Loading DynamicObjects needs Treebars `753f826` or later (`treebar_notes`)
  and says so if it is older. Treebars is still at 0.1.0, so `[compat]`
  cannot state this floor (`9cc0d8a`).

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
