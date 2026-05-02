# DynamicObjects.jl

Structs whose *fields* are constructor arguments and whose *properties* are
lazily computed methods that memoize their results — in memory, on disk,
across threads, or all three. Built for long-running pipelines where the same
expensive value gets touched from many places, and where adding a new derived
quantity should be as cheap as writing one line of code.

```julia
using DynamicObjects

@dynamicstruct struct Point
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
end

p = Point(3.0, 4.0)
p.r      # 5.0  — computed on first access, cached on the instance
p.theta  # ditto, independent of `r`
```

Lines without `=` become **fixed fields** (positional constructor arguments).
Lines with `=` become **lazy properties**: the RHS is compiled into a
`compute_property` method, run on first access, and stored in an instance
cache. Bare names like `x` and `y` on the RHS are auto-rewritten to
`__self__.x` / `__self__.y`, so you don't have to spell out the receiver.

## Headline features

- **Lazy properties.** Order-independent; any RHS may reference any other
  field or property by bare name.
- **Indexed properties.** `prop(args...) = expr` declares a property that
  takes arguments. `obj.prop(args...)` recomputes; `@memo obj.prop(args...)`
  caches per `(args, kwargs)` tuple.
- **Disk caching.** `@cached prop = …` persists results under a
  hash-derived path. `@memo f(x) = …` does the same for free functions.
- **Thread-safe async.** With `cache_type=:parallel` (the default), indexed
  property access spawns a `Task`, deduplicates concurrent requests for the
  same key, and integrates with [`fetchindex`](#async-access) for
  non-blocking UI polling.

## Three orthogonal axes (read before writing DO code)

These are independent. Conflating them is the single most common source of
bugs and confused explanations:

1. **Declaration syntax** decides whether a property is an **IndexableProperty (IP)**.
   - `prop = expr` (no parens on the LHS) → a plain lazy scalar. Not an IP.
     Not pollable. Computed once per instance.
   - `prop(args...; kwargs...) = expr` (LHS has a call) → **this is an IP**,
     with *or without* arguments, with *or without* kwargs.
     `prop() = …` is an IP. `prop(i) = …` is an IP. `prop(; k=1) = …` is an IP.
2. **`cache_type`** decides what dict backs the IP's per-key memo.
   `:parallel` → `ThreadsafeDict` that spawns a `Task` per key, dedupes
   concurrent requests, and is the thing that makes polling via
   [`fetchindex`](#async-access) possible. `:serial` → plain `Dict`.
3. **`@cached`** adds **disk serialisation** on top. It is purely an I/O
   concern — it doesn't decide IP-ness, it doesn't create polling, it
   doesn't spawn tasks. Any IP is pollable regardless of `@cached`; any
   non-IP scalar property can be `@cached` without becoming pollable.

If you want a property to be pollable / cancellable / background-runnable,
declare it with call syntax — that is what makes it an IP. `@cached` is
orthogonal. You almost never need `@cached` just to "make something async".

## Defining properties

### Fixed fields

```julia
@dynamicstruct struct Foo
    a::Int
    b::String
end

Foo(3, "hi")            # positional constructor
Foo(3, "hi"; r=99)      # kwargs pre-populate the cache
```

Type annotations are optional. The struct is concrete; field order matches
declaration order. An auto-emitted `Foo(args...; kwargs...)` constructor
forwards positional args to the fields and stuffs kwargs into the property
cache as overrides.

### Derived properties

Any RHS works; properties may reference each other in any order.

```julia
@dynamicstruct struct Foo
    a::Int
    c = b + 1            # forward reference is fine
    b = a * 2
end
```

A cycle (e.g. `b = c + 1; c = b - 1`) compiles fine but stack-overflows on
access — there's no cycle detection.

### Indexed properties

Use call syntax `prop(args...; kwargs...) = expr`:

```julia
@dynamicstruct struct App
    items = [1, 2, 3, 4]
    filter(pred)        = Base.filter(pred, items)
    element(i::Int)     = items[i]
    render(i; tag="li") = "<$(tag)>$(element(i))</$(tag)>"
end

a = App()
a.filter(iseven)                  # [2, 4] — fresh each call, no caching
@memo a.filter(iseven)            # [2, 4] — cached in the per-property dict
a.render(1; tag="span")           # "<span>1</span>" — fresh
@memo a.render(1; tag="b")        # "<b>1</b>"       — cached, kwargs included
```

Two access forms:

| Access                    | Behavior                                                          |
|---------------------------|-------------------------------------------------------------------|
| `obj.prop(args...)`       | Recompute every call. No caching.                                 |
| `@memo obj.prop(args...)` | Look up `(args, kwargs)` in the per-property dict (cached access). |

`@memo obj.prop(args...)` is the preferred way to get cached access at a
call site — the `@memo` marker makes the caching visible to a reader. The
underlying bracket form `obj.prop[args...]` still works (and is what
`@memo` expands to), but prefer `@memo` in new code: the cache is doing
something that a bare `[...]` doesn't make obvious.

!!! note "`obj.prop` (no call) returns the wrapper"
    Bare `obj.prop` on an indexed property does **not** invoke the body. It
    returns an `IndexableProperty` wrapper that you can pass around (to
    `fetchindex`, `cancel!`, `entries`, etc.). To actually compute, append
    `(args...)` (fresh call) or `@memo` it (cached call):
    ```julia
    a.filter            # IndexableProperty :filter (Dict(...))
    a.filter(iseven)    # [2, 4]              — fresh
    @memo a.filter(iseven)  # [2, 4]          — cached
    fetchindex(a.filter, (iseven,)) do rv, status; … end  # non-blocking
    ```

Multiple methods participate in normal Julia dispatch:

```julia
greet(name::String) = "Hello, $(name)!"
greet(n::Int)       = "Hello, person #$(n)!"
```

!!! warning "Brackets and kwargs don't mix, in either direction"
    - **Declaration:** always `prop(i; kw=default) = …`, never
      `prop[i] = …` — the bracket form can't take kwargs and is
      deprecated.
    - **Access:** always `obj.prop(i; kw=v)` or `@memo obj.prop(i; kw=v)`,
      never `obj.prop[i; kw=v]` — that's invalid Julia (`;` inside `[]`
      means concatenation).

#### Zero-arg call vs plain property

```julia
timestamp = time()                 # plain: cached once on first read
now()     = time()                 # indexed: obj.now() is fresh
@memo obj.now()                    # cached zero-arg access
```

### Multi-LHS destructuring

A single RHS can introduce several properties at once. The group is computed
once into a hidden helper property; individual members extract from it.

```julia
@dynamicstruct struct Grad
    x::Float64
    val, grad = (f(x), df(x))                      # positional: by index
    (; val, grad) = (; val=f(x), grad=df(x))       # named: by field
    (; x_val<=val, x_grad<=grad) = autodiff(x)     # per-field rename
    (; x_<=(val, grad)) = autodiff(x)              # prefix shorthand
    @cached a, b = expensive()                     # macros apply to the group
end
```

Read `<=` as "from": `x_val<=val` means "property `x_val` extracted from
field `val`". When the RHS of a *named* destructure is a bare symbol
(`(;a, b) = config`), no helper is generated — extractors hit `config.a` /
`config.b` directly.

## Bare-name resolution and `__self__`

Inside a property RHS, any bare name matching another field or property is
rewritten to `__self__.<name>`. The generated method is roughly:

```julia
@dynamicstruct struct Foo
    a::Int
    b = a * 2
end

# Generated (simplified):
DynamicObjects.compute_property(__self__::Foo, ::Val{:b}; kwargs...) =
    __self__.a * 2
```

`__self__` is also visible as a bare symbol — useful for explicit API calls
that take the object: `@cache_path(__self__.result)`,
`fetchindex(__self__.fits, key)`, etc.

### Scoping rules

`let`-bindings, lambda parameters, comprehension/`for`-loop iterators,
`function` argument names, `try`/`catch` variables, and `local`-declared
names are all left alone:

```julia
evens = let items = filter(iseven, items)   # outer `items` → __self__.items
    sum(items)                               # inner `items` is the let-binding
end
mapped = map(x -> x * 2, items)              # `x` is local; `items` rewrites
totals = [sum(row) for row in items]         # `row` local; `items` rewrites
```

### "Assignment shadows property" error

Writing `prop = value` inside a property body is interpreted as
`__self__.prop = value` — i.e. it writes to the in-memory cache, not to a
local. To avoid silent bugs, an assignment to a name that is also a property
of the surrounding struct is a compile-time error. Declare the local
explicitly:

```julia
@dynamicstruct struct Counter
    @cached count = 0
    increment = begin
        count = count + 1   # explicitly: rewrites to __self__.count = …
        count
    end

    safe = begin
        local count = 0     # local, doesn't touch the cache
        for _ in 1:10
            count += 1
        end
        count
    end
end
```

`let count = …` works for the same reason.

## Caching

### In-memory cache

Every derived property's value is stored in an instance-level
`PropertyCache` after first compute. The backing dict type is controlled by
`cache_type`:

| `cache_type`       | Backing dict       | Access semantics                                        |
|--------------------|--------------------|---------------------------------------------------------|
| `:parallel` (default) | `ThreadsafeDict` | Lock-protected; concurrent requests for the same key share one `Task`. |
| `:serial`          | `Dict`             | Single-threaded; faster but unsafe under concurrency.   |

```julia
obj = Foo(3; cache_type=:serial)
```

Pass a dict type directly to use a custom backend. The package-level default
can also be set via the multi-arg macro form:

```julia
@dynamicstruct "doc" :serial struct Q
    n::Int
    data(id) = expensive(id)
end
```

### Constructor kwargs as cache overrides

Any kwargs you pass to the constructor are written into the cache as
pre-populated values. Same goes for [`remake`](@ref):

```julia
p  = Point(3.0, 4.0; r=10.0)   # p.r returns 10.0 without computing
p2 = remake(p; r=99.0)         # same fields, override r
```

### Writing to the cache from a body

Inside a property body, `prop = value` rewrites to
`__self__.prop = value`, mutating the cached entry. Useful for stepwise
updates — and the explanation for the [shadowing error](#assignment-shadows-property-error)
above.

### Disk caching: `@cached`

`@cached prop = expr` persists the value to disk under
`joinpath(cache_base, hash, "<prop>.sjl")`:

```julia
@dynamicstruct struct Experiment
    n::Int
    @cached result = sum(rand(n))
end

e = Experiment(1_000_000)
e.result                       # computes, writes to "cache/<hash>/result.sjl"
Experiment(1_000_000).result   # loads from disk on a fresh instance
```

`@cached` works on indexed properties too — each `(args, kwargs)` tuple is
keyed and persisted independently:

```julia
@cached fit(seed) = run_fit(seed)   # cache/<hash>/fit_<arg-hash>.sjl
```

#### Where the file lives

`cache_path` defaults to `joinpath(cache_base, hash)` where `cache_base`
defaults to `"cache"` and `hash` is derived from `hash_fields`. By default
`hash_fields` is the tuple of all fixed fields. Override either to relocate
caches or to narrow the hash:

```julia
@dynamicstruct struct Foo
    a::Int
    b::Int
    hash_fields = (a,)              # `b` is not part of the cache key
    cache_base  = "/mnt/cache"
    @cached result = a + b
end
```

Inside `hash_fields`, any `@dynamicstruct` value is replaced by its own
stable `.hash` string before hashing — so nested DOs don't leak their full
serialised representation into the parent hash.

#### Versioning a cache: `@cached v"2"`

Bumping `v"…"` invalidates that property's disk file even when the inputs
hash the same — useful when you change the property body and don't want
stale `.sjl` files to load:

```julia
@cached v"2" result = improved_algorithm(n)
```

The version mixes into the cache filename
(`result_v2.sjl`); old `result.sjl` files just sit there until cleared.

#### Disk-write locking: `__strict__`

`__strict__ = true` (the default) makes `@cached` writes go through a per-path
`ReentrantLock` so concurrent computations of the same key never race on the
file. Set `__strict__ = false` if you've already coordinated externally and
want to skip the lock.

### `@persist`: write the in-memory value to disk

`@cached` reads from disk on first access and writes after computing. If you
later mutate the in-memory value (`obj.result = …`), it stays in RAM until
you flush it:

```julia
@persist obj.result             # plain
@persist obj.data(url)          # indexed (call form — preferred)
```

### `@lru N`: bound an indexed property's in-memory dict

```julia
@dynamicstruct struct Models
    @lru 100 sim(subject_id)         = simulate(subject_id)        # 100 most-recent kept
    @cached @lru 50 fit(model, seed) = run_fit(model, seed)        # disk + LRU in RAM
end
```

`@lru` is orthogonal to `@cached`: it only bounds the in-memory dict, never
the on-disk cache. On `:parallel` structs, eviction is task-aware — keys
with an in-flight `Task` are never evicted, so awaiters never see their cache
slot vanish. If every slot is pinned, the dict temporarily exceeds `maxsize`.

`maxsize` must be a literal `Int`; only indexed properties may carry `@lru`.

### `@memo`: two distinct meanings

Outside `@dynamicstruct`:

```julia
@memo expensive(x, y) = heavy_computation(x, y)
```

Produces a process-wide memoised version of `expensive` — the usual
[memoize-a-function](https://en.wikipedia.org/wiki/Memoization) pattern.

Inside a `@dynamicstruct` body, `@memo` is a **call-site rewrite** that
turns `obj.prop(args...; kwargs...)` into the cached access path. It is
the preferred way to ask for cached access at a call site — the marker
makes the caching visible to the reader. See
[indexed properties](#indexed-properties).

### Inspecting and clearing caches

| Macro / function                   | Returns                                             |
|------------------------------------|-----------------------------------------------------|
| `@cache_status obj.result`         | `:unstarted` / `:started` / `:ready`                |
| `@is_cached obj.result`            | `true` if the disk cache file is `:ready`           |
| `@cache_path obj.result`           | The on-disk path                                    |
| `@clear_cache! obj.result`         | Drop in-memory + delete all on-disk files           |
| `@clear_cache! obj.result(key)`    | Drop a single index                                 |
| `clear_mem_caches!(obj)`           | Drop every in-memory entry on `obj`                 |
| `clear_disk_caches!(obj)`          | Delete every `@cached` file under `obj.cache_path`  |
| `clear_all_caches!(obj)`           | Both                                                |

Indexed forms use call syntax too: `@is_cached obj.result(key)`,
`@cache_path obj.fit(2; seed=42)`, `@clear_cache! obj.result(key)`. The
inspection macros also accept the legacy bracket form, but prefer parens —
it reads as "inspect this call".

These macros also work *inside* a `@dynamicstruct` body — drop the
object prefix:

```julia
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    summary(key) = @is_cached(result(key)) ? "done" : "pending"
end
```

## Inline nested structs

Child DOs can be defined directly inside a parent body. They get a
`__parent__` field auto-wired and can reference any non-shadowed parent
property by bare name.

```julia
@dynamicstruct struct Parent
    x::Float64
    y = x + 1

    @struct sub = begin
        z = x + y                          # x, y forwarded from parent
    end

    @struct weighted(id; scale=2, bias) = begin
        total = x * id * scale + bias      # id, scale, bias become child properties
    end
end

p = Parent(1.0)
p.sub.z                                # 3.0
p.weighted(3; bias=1).total            # fresh each call (default scale=2)
p.weighted[3; bias=1, scale=5].total   # cached in `weighted`'s per-key dict
```

- **`@struct name = begin … end`** — singleton child, one instance per parent.
- **`@struct name(args...; kw...) = begin … end`** — one cached child per
  `(args, kwargs)` tuple. Args/kwargs become child properties and are
  prepended to the child's auto-`hash_fields`, so distinct call values
  produce distinct cache directories. Required kwargs (no default) are
  enforced at the parent's call site.

Older forms `name = struct Name … end`, bare `struct Name … end`, and
`name(idx) = struct Name … end` still work; `@struct` is just a marker
that auto-generates the child name. In every form:

- The parent's properties (including those introduced by destructuring)
  auto-forward into the child.
- The parent's `cache_type` is inherited.
- The child's `__status__` is auto-wired as a `__substatus__` of the
  parent. Opt out by declaring the child's own `__status__` (e.g.
  `__status__ = nothing` to disable, or `__status__ = __parent__.__status__`
  to inherit without a new node).

`__parent__` is also reachable explicitly — useful in deeply nested chains
(`__parent__.__parent__.pipeline`).

### Property docstrings (with `$kwarg` interpolation)

A string immediately above a property declaration overrides
`_property_description(o, ::Val{:name}, args...; kwargs...)`. That
description is what `__substatus__` reads when constructing a Treebars
progress label, and what `PropertyComputationError` puts in its header.
`$` interpolation resolves against *call-site* values, not declared defaults:

```julia
"Pathfinder(maxiters=\$maxiters)"
pathfinder(instance, init; rng=Xoshiro(42), maxiters=100) =
    initialize_mcmc(instance, init; rng, progress=__status__, maxiters)
```

`@memo obj.pathfinder(m, init; maxiters=500)` shows
`Pathfinder(maxiters=500)`, not the default. Works at any nesting depth.

## Async access

With `cache_type=:parallel` (default), cached access on an indexed property
(`@memo obj.prop(args...)`):

1. Locks the cache.
2. If the value is present → returns it.
3. If a `Task` for the same key is in flight → returns the existing `Task`.
4. Otherwise → spawns a fresh `Task` and registers it.

After the lock is released, the access waits on the `Task` (`fetch`) and
returns the result. If the task throws, the cache slot stays in the failed
state until `retry_failed=true` clears it on the next access.

### `fetchindex` — non-blocking peek

```julia
fetchindex(app.results, key) do rv, status
    if rv isa Task && istaskfailed(rv)
        render_error(rv.result)
    elseif rv isa Task
        render_progress(status)        # still running
    else
        render(rv)                     # done
    end
end

fetchindex(app.results, key; force=true) do rv, status
    # `force=true` clears in-memory + on-disk first → fresh Task
end
```

The `(rv, status)` callback receives the `Task` (when running/failed/just-finished)
or the cached value (when complete), plus the substatus object (or `nothing`).
This is the contract used by HTMX-style UIs that poll a "running" page until
the result drops in.

### Status, cancellation, enumeration

| Function                              | Purpose                                                              |
|---------------------------------------|----------------------------------------------------------------------|
| `getstatus(ip, indices...)`           | Current substatus, or `nothing`                                      |
| `cancel!(ip, indices...)`             | Schedule `InterruptException` on the running task; returns `true` if found |
| `cancel_all!(ip)`                     | Cancel every running task on `ip`                                    |
| `entries(ip)`                         | Vector of `(; key, state, status, value)` for *all* entries          |
| `cached_entries(ip)`                  | Just the completed entries, as `(key, value)` pairs                  |

`state` from `entries` is one of `:running`, `:failed`, `:finishing`, or
`:done`.

### Treebars progress: `__status__` and `__substatus__`

Two conventional properties hook DO into a progress tree:

- `__status__` — root progress node, default `nothing`.
- `__substatus__(name, args...; kwargs...)` — per-property child node hook.

When Treebars.jl is loaded, the `TreebarsExt` extension provides a default
`__substatus__` that creates a child progress node initialised from the
property's `_property_description`. Lifecycle hooks
(`_finalize_substatus!` / `_fail_substatus!`) wire the spawned `Task` into
the tree's init/finalize symmetry.

```julia
using DynamicObjects, Treebars

@dynamicstruct struct App
    __status__ = initialize_progress!(:state; description="App")

    "fit($key)"
    fit(key) = expensive(key; progress=__status__)
end

app = App()
fetchindex!(app.__status__, app.fit, "k1")   # extension method
```

Inside any property body, `__status__` is bound to the relevant node — the
root for plain access, the per-key substatus for cached access on a
`ThreadsafeDict` (i.e. `@memo obj.prop(key)`). Pass it to your inner code
via the `progress=` kwarg of whatever long-running API you call.

`__substatus__` only fires on the **cached** access path
(`@memo obj.prop(key)` / equivalently `obj.prop[key]`). Fresh call syntax
`obj.prop(key)` and scalar property access don't trigger it.

## Construction and `remake`

```julia
p  = Point(3.0, 4.0)             # positional fixed fields
p2 = Point(3.0, 4.0; r=10.0)     # kwargs override the cache
p3 = remake(p; x=5.0)            # change a fixed field; derived recompute
p4 = remake(p; r=99.0)           # change a cached value (not a fixed field)
```

`remake` separates kwargs into "fixed-field updates" and "cache overrides",
so it works for either purpose without you having to know which is which.

## Errors: `PropertyComputationError`

If a property body throws, the exception is wrapped in a
`PropertyComputationError` that records the property name, type, indices,
and kwargs:

```
PropertyComputationError: computing `pathfinder(instance, init; maxiters=500)` on App
  Caused by: ArgumentError(...)
    <inner stacktrace>
```

`unwrap_error(err)` strips `TaskFailedException` /
`CompositeException` / nested `PropertyComputationError` layers to reach the
root cause — handy when surfacing errors in a UI.

## Revise compatibility

Everything inside a `@dynamicstruct` body is hot-reloadable: property
bodies, added / removed / renamed derived properties, indexed signatures,
nested inline structs, and macro-decorated properties all pick up on save.

Limits inherited from Julia + Revise:

- Adding, removing, or reordering **fixed fields** changes the underlying
  struct; you'll need to rename it (`MyStructV2`) or restart the session.
- `const` bindings can't be redefined in-place — don't use `const` for
  things that change.
- New deps in `Project.toml` / `Manifest.toml` require a restart.

After hot-reloading, in-memory caches still hold values computed by the *old*
methods. Call `clear_mem_caches!(obj)` to force recomputation against the
new code without touching `@cached` files.

## Debugging

### Where did this error come from?

Property bodies execute lazily — the throw happens at the access site, not the declaration site. `PropertyComputationError` always tells you *which* property and *which* arguments triggered the failure:

```
PropertyComputationError: computing `pathfinder(instance, init; maxiters=500)` on App
  Caused by: ArgumentError("…")
    <inner stacktrace>
```

When the error percolates up through a chain (e.g. a property that called another that called another), you'll see nested `PropertyComputationError` frames. Use `unwrap_error(err)` to skip past those plus `TaskFailedException` and `CompositeException` to reach the original cause:

```julia
try
    obj.failing_pipeline
catch err
    root = unwrap_error(err)        # the actual ArgumentError, not the wrapper
    @error "pipeline failed" exception=(root, catch_backtrace())
end
```

This is exactly what you want when surfacing errors in a UI: the `PropertyComputationError` headers tell the user where the failure happened in the data dependency tree, while `unwrap_error(err)` gives the underlying cause for log/diagnostic display.

### Cycle detection (or rather: the lack of it)

A property cycle (`b = c + 1; c = b - 1`) is **not** detected — it stack-overflows on access. The Julia trace ends with deeply repeated frames in `compute_property`. If you see this:

```
StackOverflowError:
Stacktrace:
 [1] compute_property(__self__::Foo, ::Val{:b})
 [2] compute_property(__self__::Foo, ::Val{:c})
 [3] compute_property(__self__::Foo, ::Val{:b})
 [4] compute_property(__self__::Foo, ::Val{:c})
 ...
```

…check for circular dependencies between properties.

### Inspecting in-flight tasks

For `:parallel` indexed properties, `entries(ip)` returns a vector of `(; key, state, status, value)` for every key seen so far — `:running`, `:failed`, `:finishing`, or `:done`:

```julia
julia> entries(app.fit)
3-element Vector:
 (key = ("k1",), state = :done,    status = nothing, value = …)
 (key = ("k2",), state = :running, status = ProgressNode(…), value = Task(…))
 (key = ("k3",), state = :failed,  status = nothing, value = Task(…))
```

`getstatus(ip, args...)` returns the substatus of a single key (or `nothing` if absent). `cancel!(ip, args...)` schedules an `InterruptException` on a single running task; `cancel_all!(ip)` does it across the whole property.

### Cache state inspection

For a single property:

```julia
@cache_status obj.result        # :unstarted / :started / :ready
@is_cached    obj.result        # true if disk cache is :ready
@cache_path   obj.result        # absolute on-disk path
```

For an indexed property, append the key:

```julia
@cache_status obj.fit("seed-1")
@is_cached    obj.fit("seed-1")
@cache_path   obj.fit("seed-1")
```

Inside a `@dynamicstruct` body, drop the object prefix:

```julia
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    summary(key) = @is_cached(result(key)) ? "done" : "pending"
end
```

### Nested DO hashing

When a fixed field is itself a `@dynamicstruct`, its `.hash` field is substituted into the parent's hash inputs (so nested DOs don't bloat the parent's serialised hash key). To check what a given object's hash and cache path will be:

```julia
obj.hash         # the cache key
obj.cache_path   # joinpath(obj.cache_base, obj.hash)
```

Override `hash_fields` to narrow the hash, or `cache_base` to relocate caches.

### Force recomputation after Revise

After `Revise` hot-reloads a property body, the in-memory cache still holds values produced by the *old* method. To recompute against the new code without touching `@cached` files on disk:

```julia
clear_mem_caches!(obj)        # wipe the in-memory PropertyCache
obj.result                    # recompute with the new body
```

`clear_mem_caches!` only walks the object you pass it — for nested children, walk them too:

```julia
clear_mem_caches!(parent)
clear_mem_caches!(parent.sub)                                          # singleton child
foreach(clear_mem_caches!, last.(cached_entries(parent.weighted)))     # cached indexed children
```

## Advanced

### Pluggable key tracking: `KeyTracker`

For `@cached` indexed properties, you sometimes want to enumerate *all*
keys ever computed (e.g. to bound on-disk storage by deleting the
least-recently used). The `KeyTracker` hook decides where that key set is
persisted:

| Tracker                          | Strategy                                                       |
|----------------------------------|----------------------------------------------------------------|
| `SharedFileTracker(path)` (default) | One `_keys.sjl` shared by every writer. Simple; not NFS-safe. |
| `PerPodFileTracker(base, pod_id)` | One `_keys_<pod_id>.sjl` per writer; `load_keys` unions them. |
| `NoKeyTracker()`                 | No-op.                                                          |

Override per-type / per-property:

```julia
DynamicObjects.key_tracker(o::MyType, ::Val{name}) where {name} =
    PerPodFileTracker(joinpath(o.cache_path, string(name) * "_keys"), pod_id)
```

`record!` and `load_keys` are the read/write API; recording is currently a
no-op (the dispatch and storage hooks are wired in but the body in
`_record_accessed_key` is intentionally disabled until concurrency-safe
writes land — see the source for details).

### Persistent collections

| Type                                                      | Purpose                                                                                       |
|-----------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `PersistentSet(path)`                                     | Thread-safe `Set` that re-serialises on every `push!`/`pop!`.                                 |
| `LazyPersistentDict(path[, empty]; seed!)`                | Threadsafe dict; backing file resolved lazily, loaded on first op (precompile-safe).          |
| `LRUDict{K,V}(maxsize)`                                   | Plain LRU dict, used internally for `@lru` on `:serial` structs.                              |
| `ThreadsafeLRUDict{K,V}(maxsize)`                         | Lock-protected LRU dict, used internally for `@lru` on `:parallel` structs (task-aware eviction). |

These are exposed as exports; you can use them outside `@dynamicstruct`
contexts wherever they're useful.
