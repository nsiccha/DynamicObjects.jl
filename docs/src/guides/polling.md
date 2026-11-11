# Polling and progress

Request a property without blocking the caller, distinguish a pending result
from a completed value, and inspect progress. Both scalar and indexed
properties support polling. A normal blocking read computes inline on its
caller's task unless an executor changes that policy.

## Scalar polling

`fetchproperty` starts or observes a scalar computation and passes the result
and status to a callback. This example holds the computation behind a channel,
so the pending state is reproducible without timing assumptions.

```@example polling
using DynamicObjects

@dynamicstruct struct Work
    gate::Channel{Nothing}
    "A gated scalar computation."
    value = (take!(gate); 42)
    scaled(gain) = gain * value
end

work = Work(Channel{Nothing}(1))
pending = fetchproperty(work, :value) do result, status
    result
end
@assert pending isa Pending # hide
__docs_output__ = begin # hide
pending isa Pending
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The callback runs with a `Pending` handle while work is in flight. It can
render a waiting state without fetching the value. Calling `fetch` on that
handle blocks until the computation completes or throws.

```@example polling
put!(work.gate, nothing)
@assert fetch(pending) == 42 # hide
__docs_output__ = begin # hide
fetch(pending)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

## Indexed polling

`fetchindex` is the corresponding operation for an argument-taking property.
Its callback also receives `(result, status)`. A completed entry returns its
value immediately; an unfinished entry returns a handle.

```@example polling
result = fetchindex(work.scaled, 2) do value, status
    value
end
value = result isa Pending ? fetch(result) : result
@assert value == 84 # hide
__docs_output__ = begin # hide
value
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Polling does not require `@cached`. Disk persistence is a separate choice.
Repeated requests for the same entry share its in-flight computation.
`force=true` on `fetchindex` invalidates the requested entry before requesting
it again; use the [cache guide](caches.md) to choose the invalidation scope.

## Progress

An object supplies a Treebars progress root by default. A property's docstring
labels its progress node. Reads visible inside a property body attach under
the reader; the status passed to a poll callback is the node for the observed
computation, or `nothing` when progress is disabled.

```@example polling
status = getstatus(work.scaled, 2)
__docs_output__ = begin # hide
(root_exists = work.__status__ !== nothing,
 entry_status_exists = status !== nothing)
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Pass `__status__ = nothing` when constructing an object to turn its progress
off. To label a root, provide a Treebars node as that keyword. The
[`fetchindex!`](@ref) and [`fetchproperty!`](@ref) overloads accept a progress
node when a caller needs explicit attachment. `@fetch!` threads those reads
through a block; ordinary property bodies already attach their visible reads.

## Executors and errors

`@queued` on an indexed property routes its computations through the package's
job queue. Framework code can also supply a [`Deferred`](@ref) executor.
Queueing changes where work runs, not which arguments identify a cached entry.
Keep synchronous computations as ordinary properties unless the application
needs a scheduling policy.

A failed body is reported through [`PropertyComputationError`](@ref).
[`unwrap_error`](@ref) retrieves the underlying exception for error reporting.
Invalidation retracts a cached computation; it does not forcibly stop arbitrary
Julia code already running. See [`ComputeAbandoned`](@ref) for work abandoned
before execution.

[Cached signal analysis](../examples/signal.md) uses [`with_compute_trace`](@ref)
to distinguish work from cache reuse without relying on elapsed times.
