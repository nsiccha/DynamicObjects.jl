# Properties

Define constructor inputs, lazy values, and argument-taking properties with
`@dynamicstruct`. This guide also shows how to group related properties in a
child object and replace inputs without mutating a retained object.

## Fields and values

A declaration without `=` is a constructor field. A declaration with `=` is
an overrideable default whose body runs on its first read.

```@example properties
using DynamicObjects

@dynamicstruct struct Samples
    values::Vector{Float64}
    total = sum(values)
    average = total / length(values)
end

samples = Samples([2.0, 4.0, 6.0])
__docs_output__ = begin # hide
(total = samples.total, average = samples.average)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Bodies may read sibling fields and properties by name, including properties
declared later in the struct. Local variables follow Julia's scoping rules.
Avoid assigning to a sibling's name inside a body: use a separate local name
for an intermediate result. `__self__` refers to the object when an explicit
receiver is needed.

Constructor keywords can replace defaults. A replacement is an input to that
object, and survives a memory clear.

```@example properties
overridden = Samples([2.0, 4.0, 6.0]; total = 30.0)
clear_mem_caches!(overridden)
__docs_output__ = begin # hide
(total = overridden.total, average = overridden.average)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

## Indexed properties

A call on the left side declares an indexed property. Calls use parentheses
and cache results by their positional and keyword arguments. Even a
zero-argument declaration is indexed; reading its name returns a callable
property, while calling it requests a value.

```@example properties
@dynamicstruct struct TextCollection
    words::Vector{String}
    matches(query; limit = length(words)) =
        first(filter(word -> occursin(query, word), words), limit)
    count() = length(words)
end

texts = TextCollection(["apple", "banana", "cherry"])
__docs_output__ = begin # hide
(matches = texts.matches("a"; limit = 1), count = texts.count())
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Repeated argument values share an entry according to `isequal`. Results must
therefore depend on argument values, rather than distinguish equal values
solely by their concrete type. Leave mutable arguments unchanged after passing
them to a property. See [Cache lifetime](caches.md) for fresh access and
invalidation.

## Nested objects

Use an inline `@struct` to put related operations under a named child. The child
can read its parent's fields and properties by name. An indexed child is
retained for each argument tuple like any other indexed property.

```@example properties
@dynamicstruct struct Experiment
    values::Vector{Float64}
    @struct summary = begin
        count = length(values)
        total = sum(values)
    end
    @struct scaled(gain::Float64) = begin
        values_scaled = gain .* values
        total = sum(values_scaled)
    end
end

experiment = Experiment([2.0, 4.0])
__docs_output__ = begin # hide
(count = experiment.summary.count,
 total = experiment.summary.total,
 scaled_total = experiment.scaled(3.0).total)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The child is a grouping of computations, not a copy of the parent's data.
Property docstrings label progress nodes and appear through reflection.
Ordinary Julia helpers that operate only on their arguments can remain
ordinary functions outside the struct.

## Replacement inputs

`remake` creates an object with changed fields or default overrides. It carries
settled values only where the declared dependencies permit reuse. Do not change
an input vector in place and expect derived properties to update automatically.

```@example properties
replacement = remake(samples; values = [10.0, 20.0])
__docs_output__ = begin # hide
(original = samples.average, replacement = replacement.average)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

[Cached signal analysis](../examples/signal.md) uses these declarations and
shows the computations recorded when inputs or cache entries change.
