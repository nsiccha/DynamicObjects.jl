# Cache lifetime

Choose which values remain in memory, which also persist to disk, and what an
invalidation removes. Plain property reads memoize; `@cached` adds disk storage.
It does not make a property indexed or change whether it can be polled.

## Memory

A repeated indexed call returns its stored value. `fresh` computes the selected
property without reading or writing its cache.

```@example caches
using DynamicObjects

@dynamicstruct struct Transform
    values::Vector{Float64}
    scaled(gain) = gain .* values
end

transform = Transform([1.0, 2.0])
first_read = transform.scaled(3.0)
@assert transform.scaled(3.0) === first_read # hide
@assert fresh(transform.scaled, 3.0) !== first_read # hide
__docs_output__ = begin # hide
(reused = transform.scaled(3.0) === first_read,
 fresh_is_distinct = fresh(transform.scaled, 3.0) !== first_read,
 original_still_stored = transform.scaled(3.0) === first_read)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The macro `@fresh` is the call-site form. A declaration marked `@fresh` uses that
policy for each call. `@memo!` is retained for explicit cached access; ordinary
indexed calls already memoize.

Treat returned arrays and other mutable results as read-only. Make a copy
before changing them. Mutation would also change what later cache hits return.

## Automatic release under memory pressure

Start Julia with an explicit `--heap-size-hint` to enable automatic trimming.
The requester and each queue worker use their own hint as a soft budget for
both the Julia heap and process memory. On macOS the process signal is physical
footprint, including compressed pages. On Linux it is resident memory plus
private anonymous swap (`VmRSS + VmSwap`). On other platforms the heap signal
still applies.

To set a separate per-process budget, set `DYNAMICOBJECTS_PROCESS_BUDGET_BYTES`
to a byte count in the environment before starting Julia. This also works
without a heap hint. An explicit zero disables process-pressure sampling on
cache access. With both budgets zero, ordinary reads retain memoized results
for the object's lifetime.

When either measurement reaches 90% of its budget, reads and publications can
release up to 16 cold derived entries toward an 80% target. The most recently
used eligible result stays warm. After a batch driven by process pressure,
DynamicObjects collects garbage and rechecks the footprint. It waits longer
between process checks when the batch gives little relief.

DynamicObjects first releases cold results that can reload from their
`@cached` or `@mmap` file. It then releases the least recently read eligible
memory-only results. A later read runs that body again. For a randomized fit
this can produce different draws. Use an explicit disk cache to reuse the
published draws, or a compute scope to share a result during a report.

Trimming preserves constructor inputs, state and its owning objects, versions,
in-flight work, pending deliveries, and scope claims. The package checks
eligibility from the result type or a bounded inspection of a small mixed
container. Values that may own native resources stay in memory by default.
For a property that can reliably recreate its native result, declare the
result eligible. This property can recompile its regular expression from the
same pattern.

```@example caches
@dynamicstruct struct Patterns
    pattern::String
    compiled = Regex(pattern)
end
DynamicObjects.memo_native_bytes(::Type{Patterns}, ::Val{:compiled}, ::Regex) = missing
occursin(Patterns("^fit").compiled, "fit-1")
```

Return a nonnegative `Int` when the producer knows the native byte count.
`missing` declares the size unknown. A producer of a BridgeStan model can
use the same declaration when it can replay the library, data and seed.
Other properties returning the same
type keep their default lifetime. Releasing a slot drops one reference.
Callers can continue using their own references, and the model's finalizer
can run after its last owner releases it.

`memo_retention_stats(DynamicObjects.job_queue())` reports separate requester
and worker counts, estimated slot payloads, known mapping sizes, and current
heap and process measurements. `process_memory_bytes` is `nothing` when
unavailable. `estimated_native_bytes` sums declared estimates and
`unknown_native_slots` counts releases without a size estimate. Two slots
that reference the same value each contribute when released.

With zero or one configured worker, read `stats.worker`. With two or more,
read `stats.workers` in queue slot order. Each live snapshot includes its PID.
An absent process gives `nothing`, and reading the statistics never starts one.

## Computing a report

Put the reads for one report in `with_compute_scope`. Its targets can share an
expensive intermediate. The cache drops derived entries created solely for
that scope on return or error, including in the queue worker. The returned
values remain usable. A value that was already warm stays warm. A concurrent
ordinary reader keeps the value it reads, and overlapping scopes release
shared work after their last claim ends. A caller-side hit on a queued fit
also keeps the same fit available to a worker-side plot.

```@example caches
report = with_compute_scope() do
    (; normal=transform.scaled(1.0), double=transform.scaled(2.0))
end
@assert report.double == [2.0, 4.0] # hide
@assert length(cached_entries(transform.scaled)) == 1 # only the earlier gain of 3 survives; hide
show(stdout, MIME"text/plain"(), report) # hide
println() # hide
```

For a known sequence use `compute_targets(root, [:table, :figure])`. Pass
`(; property=:scaled, args=(2.0,))` for an indexed call. The planner uses the
declared reads of the remaining targets to release entries earlier where it
can establish their last use. If a target calls arbitrary Julia code, the scope
keeps uncertain inputs for it. Join asynchronous reads inside the report to
include their whole lifetime. Each explicitly nested scope can mark an earlier
boundary for work that only its own targets need.

Use `prune_worker_mem_caches!(keep, root)` for a maintenance operation on an
existing worker root. The predicate runs there and returns counts to the caller.
Ordinary `prune_mem_caches!(keep, root)` runs in the caller. Each operation
preserves disk entries, object versions and work in flight.

## Disk

Mark a property `@cached` to serialize its value. Put the cache in a location
you control with `__cache_base__`. This example uses a temporary directory,
so each documentation build starts with an empty disk cache.

```@example caches
@dynamicstruct struct DiskSummary
    values::Vector{Float64}
    @cached v"1" total = sum(values)
end

cache_directory = mktempdir()
summary = DiskSummary([1.0, 2.0, 3.0]; __cache_base__ = cache_directory)
value = summary.total
__docs_output__ = begin # hide
(value = value, file_exists = isfile(@cache_path summary.total),
 ready = @is_cached(summary.total))
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The path is selected from the object's content identity, the property name,
and any indexed arguments or version markers. Fixed fields and relevant
constructor overrides participate in the default identity. Keep the identity
inputs immutable. Change the declared cache version when a formula changes
and existing files must no longer be reused.

A memory clear retains disk files. The trace records a disk read when the value
is requested again.

```@example caches
clear_mem_caches!(summary)
value, trace = with_compute_trace(() -> summary.total)
row = only(filter(row -> row.property == :total, compute_trace_rows(trace)))
@assert value == 6.0 && row.computed == 0 && row.disk == 1 # hide
__docs_output__ = begin # hide
(value = value, computed = row.computed, disk_reads = row.disk)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

`@mmap` is the disk marker for supported memory-mapped values, including numeric
arrays. Use it when retaining such arrays on disk is part of the application;
keep its returned mapping read-only, like any other cached value.

## Invalidation scope

| Operation | Scope |
| --- | --- |
| `invalidate!(object.property, arguments...)` | One indexed entry, memory and disk. |
| `@clear_cache! object.property` | The property and its declared dependents. |
| `clear_mem_caches!(object)` | Derived memory values; retains disk files, constructor inputs and state. |
| `clear_disk_caches!(object)` | Disk files; leaves memory values. |
| `clear_all_caches!(object)` | Both memory and disk caches. |
| `prune_mem_caches!(keep, object)` | Derived memory entries rejected by `keep`, without invalidating dependents. |

An entry clear is narrower than clearing its whole property. If downstream
properties also need to be recomputed, clear the property rather than only
one argument tuple.

```@example caches
invalidate!(transform.scaled, 3.0)
second_read = transform.scaled(3.0)
@assert second_read !== first_read && second_read == first_read # hide
__docs_output__ = begin # hide
(same_values = second_read == first_read,
 recomputed_array = second_read !== first_read)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Invalidation does not cancel an already running body. Its original caller can
still receive the result, but the retracted computation cannot publish it back
to the cleared cache. Waiters resolve against the current entry.

## Instance state

Use `@state` for instance-owned state such as a lock or request counter. It is
kept by memory clears and file synchronization. Its initializer may read fixed
fields and other state properties, but not derived properties.

```@example caches
@dynamicstruct struct Session
    @state requests = Ref(0)
    label = "ready"
end

session = Session()
session.requests[] += 1
clear_mem_caches!(session)
@assert session.requests[] == 1 # hide
__docs_output__ = begin # hide
session.requests[]
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Reset an individual state property with `@clear_cache! session.requests`.
For a retained application's request context, [`remount`](@ref) creates a view
that shares unrelated cached work while rebinding that context; it is distinct
from replacing data inputs with `remake`. The view keeps the keywords the
retained object was constructed with, also for a property whose declared default
reads the rebound context.

```@example caches
rm(cache_directory; recursive = true) # hide
nothing # hide
```

[Cached signal analysis](../examples/signal.md) traces repeated reads and
property-wide invalidation through a dependency chain.
