# Execution

The [polling and progress guide](../guides/polling.md) introduces nonblocking
reads and queued work. Queue and worker controls use the `DynamicObjects.` prefix.

## Polling

```@docs
Pending
fetchindex
fetchindex!
fetchproperty
fetchproperty!
maybefetchindex!
maybefetchproperty!
```

## Progress

```@docs
getstatus
@fetch!
@dynamic_progress
maybeprogress!
noprogress
DynamicObjects.progress_notes
```

## Deferred work

```@docs
Deferred
DeferredCompute
ComputeAbandoned
DynamicObjects.run!
DynamicObjects.abandon!
DynamicObjects.property_executor
DynamicObjects.await_deferred
DynamicObjects.property_settled
```

## Queue configuration

```@docs
DynamicObjects.configure_queue!
DynamicObjects.queue_settings
DynamicObjects.job_queue
DynamicObjects.JobQueue
```

## Queue observation and admission

```@docs
DynamicObjects.QueuedItem
DynamicObjects.observe_queue!
DynamicObjects.unobserve_queue!
DynamicObjects.queued_items
DynamicObjects.queue_position
DynamicObjects.abandon_queued!
DynamicObjects.QueuedCall
DynamicObjects.enqueue!
DynamicObjects.QueueExecutor
```

## Worker lifecycle

```@docs
DynamicObjects.worker_status
DynamicObjects.restart_worker!
DynamicObjects.RemoteComputationError
```

## Worker request context

```@docs
DynamicObjects.carry_to_worker!
DynamicObjects.on_requester_message!
DynamicObjects.send_to_requester
```

## Computation traces

```@docs
with_compute_trace
ComputeTrace
compute_trace_rows
DynamicObjects.ComputeTraceEvent
DynamicObjects.ComputeTraceInvalidation
```
