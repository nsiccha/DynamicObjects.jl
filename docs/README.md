# Documentation

The sidebar has four groups. Each page has one purpose:

| Group | Page | Reader task |
| --- | --- | --- |
| Start | `index.md` | Install the package and read a lazy property. |
| Guides | `guides/properties.md` | Define fields, scalar and indexed properties, and nested objects. |
| Guides | `guides/caches.md` | Choose memory or disk storage and invalidate the intended scope. |
| Guides | `guides/files.md` | Refresh file-backed values without retaining stale derived results. |
| Guides | `guides/polling.md` | Poll work, inspect progress, and configure queues and worker execution. |
| Guides | `guides/reflection.md` | Inspect declarations without executing property bodies. |
| Examples | `examples/signal.md` | Measure reuse and invalidation in a signal transformation. |
| Reference | `reference/objects.md` | Look up construction, access and error contracts. |
| Reference | `reference/caches.md` | Look up cache inspection, eviction and persistence. |
| Reference | `reference/execution.md` | Look up polling, progress, executors, queue/worker controls and traces. |
| Reference | `reference/files.md` | Look up tracked inputs, change notifications and composite mmap formats. |
| Reference | `reference/reflection.md` | Look up descriptors and semantic-host integration. |

Build from the repository root with `julia --project=docs docs/make.jl` after
instantiating the docs environment. On a managed development host use
`kb-acquire-compute-token --here --why 'DynamicObjects docs' -- kb-run-compact kb-docs-build`.
The build executes the examples, enforces exported-docstring coverage and
generates the figure HTML and Vega-Lite JSON below `docs/build/`. The lint also
checks the qualified public API entries, which `checkdocs = :exports` cannot
cover. These include queue/worker controls, executor hooks, cache identity,
trace records and mmap extension functions. Their authoritative docstrings
belong on the task-specific reference pages even though they are not exported.
Neither generated figures nor dependency downloads belong in git.

The former `gallery.md` and `api.md` are removed. The gallery depended on an
unavailable web recording. Its copied embed runtime is removed with it. The
former home-page manual is replaced by the guides and example listed above.
The web application under `web/` remains independent of the documentation build.
