# Cached signal analysis

A synthetic voltage trace is represented by a fixed vector of samples. This example
subtracts the sample mean, applies a gain, and computes the sum of squared
amplitudes. The input is a small, fixed vector so that the computations and
cache entries can be inspected together. No random generator, file download,
or fitted model is involved. The same object structure can hold a larger
trace without changing how a reader requests its derived values.

## Object

The formulas belong to the object. A field holds the samples; properties
express the dependency chain from samples to offset, centered values, scaled
values, and squared amplitude. A gain is an argument to an indexed property,
so each requested gain has its own cache entry.

```@example signal
using DynamicObjects

@dynamicstruct struct Signal
    samples::Vector{Float64}
    offset = sum(samples) / length(samples)
    centered = samples .- offset
    scaled(gain::Float64) = gain .* centered
    energy(gain::Float64) = sum(abs2, scaled(gain))
end

signal = Signal([1.0, 2.0, 4.0, 5.0])
__docs_output__ = begin # hide
signal.samples
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The samples are in volts, gain is dimensionless, and `energy` here is a sum
of squared voltages. It is not physical energy in joules: that would also
require a sampling interval and an electrical model. The field is an input
owned by this calculation. After constructing the object, leave that vector
unchanged; changing its contents in place would not inform the dependency
system that its derived values are obsolete.

The descriptor exposes the dependencies recorded from the property bodies
without running those bodies. It provides a generated view of the definition,
so changing the formula also changes this table at the next documentation build.

```@example signal
__docs_output__ = begin # hide
[(name, property_descriptor(Signal, name).dependencies)
 for name in (:offset, :centered, :scaled, :energy)]
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The dependency names describe declared reads. They are not a general analysis
of effects inside arbitrary Julia functions. Keep the reads that define your
calculation visible in the property bodies; pass explicit inputs to helpers.

## Reads

Repeated calls with the same arguments reuse the stored array. Calls with a
different gain compute a distinct result, while sharing the centered samples.
The trace records what happened during this group of reads.

```@example signal
values, trace = with_compute_trace() do
    (first = signal.scaled(2.0),
     again = signal.scaled(2.0),
     lower = signal.scaled(0.5),
     energy = signal.energy(2.0))
end
@assert values.first === values.again # hide
@assert values.energy == sum(abs2, values.first) # hide
__docs_output__ = begin # hide
values
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

`first` and `again` refer to the same array. Treat that returned array as
read-only; use `copy` before modifying it for another purpose. Otherwise a
later reader would receive the edited result from the cache. The `lower`
result uses another entry because its argument differs. `energy` reads the
already stored scaled array instead of repeating the scaling operation.

## Diagnostics

The trace table separates body computations from memory hits. It counts
property reads rather than elapsed time, so this example makes no claim about
speed. Compilation, input size, key hashing, and the cost of each formula
would all affect a timing measurement.

```@example signal
rows = sort(compute_trace_rows(trace); by = row -> string(row.property))
scaled_row = only(filter(row -> row.property == :scaled, rows)) # hide
@assert (scaled_row.computed, scaled_row.hits) == (2, 2) # hide
@assert all(row.computed == 1 for row in rows if row.property != :scaled) # hide
__docs_output__ = begin # hide
[(property = row.property, calls = row.calls,
  computed = row.computed, hits = row.hits) for row in rows]
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The figure is built from those same rows. Orange bars show requests answered
from memory; blue bars show executions of a property body. A hit on `scaled`
does not read `centered` again, because the stored scaled array already
contains the result. That is why the counts at adjacent stages need not be
equal, even though one stage depends on another.

```@example signal
using AlgebraOfVega

counts = [(property = string(row.property), outcome = label,
           calls = getproperty(row, field))
          for row in rows for (label, field) in
          (("Computed", :computed), ("Memory hit", :hits))]
plot = data(counts) *
    mapping(:property => "Property", :calls => "Reads (count)";
            color = :outcome => "Outcome", dodge_x = :outcome) *
    visual(BarPlot) *
    config(height = 260,
           scales = scales(Color = (categories = ["Computed", "Memory hit"],
                                     palette = ["#2a78d6", "#eb6834"]),
                           Y = (zero = true,)),
           config = (axis = (labelFontSize = 14, titleFontSize = 14, labelAngle = 0),))
nothing # hide
```

```@example signal
HTML(Main.DocsFigures.figure(plot, "cache-counts", # hide
    "Repeated reads reuse the scaled arrays while their dependencies compute once.")) # hide
```

## Fresh access

A fresh call bypasses the selected property's cache: it neither reads nor
replaces that entry. Dependencies still use their ordinary access policy.
Here the fresh scaled array has the same contents as the stored one but a
different identity. The next ordinary call still returns the original array.

```@example signal
uncached, fresh_trace = with_compute_trace() do
    fresh(signal.scaled, 2.0)
end
@assert uncached !== values.first && uncached == values.first # hide
@assert signal.scaled(2.0) === values.first # hide
__docs_output__ = begin # hide
(first_is_cached = signal.scaled(2.0) === values.first,
 fresh_is_distinct = uncached !== values.first,
 same_values = uncached == values.first)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Use this mode when a particular result should not be retained, or to compare
one recomputation with a stored result. It does not refresh inputs for you.
For a changed file, use [tracked inputs](../guides/files.md); for changed
constructor inputs, create a remade object as shown below.

Fresh access also leaves cached downstream values alone. Calling
`fresh(signal.scaled, gain)` is not a request to replace the array that a
previously computed `energy(gain)` used. Choose the operation according to
the intended change: a one-off value needs fresh access; a stage that must
be recomputed for subsequent readers needs invalidation. Keeping those
operations separate matters when the result is an array shared by several
consumers. A recomputation can allocate another array without withdrawing
the one already held by earlier callers.

## Invalidation

Clearing a property also clears values derived from it. Clearing `centered`
therefore makes `scaled` and `energy` recompute, while retaining the independent
`offset` value. The next trace makes that boundary visible.

```@example signal
@clear_cache! signal.centered
_, after_clear = with_compute_trace() do
    signal.energy(2.0)
end
clear_rows = sort(compute_trace_rows(after_clear); by = row -> string(row.property))
@assert only(filter(row -> row.property == :offset, clear_rows)).hits == 1 # hide
@assert all(row.computed == 1 for row in clear_rows if row.property != :offset) # hide
__docs_output__ = begin # hide
[(property = row.property, computed = row.computed, hits = row.hits)
 for row in clear_rows]
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The clear acts on the retained object; it does not change the formulas or the
samples. Use this operation when a stage needs to be recomputed. To change the
data itself, pass a replacement field to `remake`. The original object stays
available for comparison, and properties dependent on the replaced field are
computed for the new object.

For one indexed entry, `invalidate!(signal.scaled, gain)` removes that
argument tuple. It does not express the broader instruction used here to
recompute the dependent energy values. Choose property-wide invalidation
when downstream cached results must also be withdrawn.

```@example signal
changed = remake(signal; samples = [2.0, 3.0, 5.0, 6.0])
@assert changed.offset != signal.offset && changed.centered == signal.centered # hide
__docs_output__ = begin # hide
(original_offset = signal.offset, changed_offset = changed.offset,
 same_centered_values = signal.centered == changed.centered)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

A constant shift changes the offset while leaving the centered values equal.
The equality is a result of the formula, not evidence that a stale cache entry
was carried over. Trace the remade object's first reads if you need to
distinguish equal results from reused computations.

```@raw html
<details><summary>Reproduce</summary>
```

Run from a checkout with the source hash recorded below. The docs
environment supplies AlgebraOfVega; all data and trace rows are generated in
this page during the build. No saved fit or external dataset is required.

```sh
julia --project=docs docs/make.jl
```

```@eval
using DynamicObjects, Markdown, SHA
source = joinpath(dirname(pathof(DynamicObjects)), "..", "docs", "src", "examples", "signal.md")
Markdown.parse("Julia: `$(VERSION)`; DynamicObjects: `$(pkgversion(DynamicObjects))`; page SHA-256: `$(bytes2hex(sha256(read(source))))`.")
```

```@raw html
</details>
```
