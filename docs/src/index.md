# DynamicObjects.jl

Structs with lazily computed, optionally disk-cached properties.

```julia
using DynamicObjects

@dynamicstruct struct Point
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
end

p = Point(3.0, 4.0)
p.r      # 5.0  — computed on first access, then cached in-memory
p.theta  # atan(4, 3)
```

Every name on the left of `=` becomes a **property**. Fixed fields (no `=`) are
constructor arguments. Derived properties are compiled into
`compute_property` methods and memoised per instance. Adding `@cached` also
persists results to disk, keyed by a hash of the fixed fields.

## Defining properties

### Fixed fields

Lines without `=` are fixed fields — positional constructor arguments:

```julia
@dynamicstruct struct Foo
    a::Int
    b::String
end

Foo(3, "hi")   # Foo(a=3, b="hi")
```

### Derived properties

Any RHS referencing other fields or properties by name works; order of
definition does not matter.

```julia
@dynamicstruct struct Foo
    a::Int
    b = a * 2        # derived
    c = b + 1        # references another derived property
end
```

### Indexed properties (call & bracket syntax)

Use call syntax `prop(args...) = expr` to declare indexed properties:

```julia
@dynamicstruct struct App
    items = [1, 2, 3, 4]
    filter(pred)       = Base.filter(pred, items)
    element(i::Int)    = items[i]
    render(i; tag="li") = "<$(tag)>$(element(i))</$(tag)>"
end

a = App()
a.filter(iseven)           # [2, 4] — fresh each call
a.filter[iseven]           # [2, 4] — cached in-memory by argument
a.render(1; tag="span")    # "<span>1</span>"
```

**Calling convention:**

- `obj.prop(args...)` — computes fresh each time (no caching).
- `obj.prop[args...]` — caches the result in-memory keyed by `(args, kwargs)`.

Multiple method signatures work; they participate in normal Julia dispatch:

```julia
greet(name::String) = "Hello, $(name)!"
greet(n::Int)       = "Hello, person #$(n)!"
```

!!! warning "Don't use bracket syntax in declarations"
    Declaring with `prop[i] = expr` silently works but can't combine with kwargs
    (`prop[i](; kw=default)` throws `AssertionError`). Always declare with
    call syntax: `prop(i; kw=default)`. Bracket syntax is only for *access*.

!!! warning "Brackets can't carry kwargs"
    `obj.prop[args...; kwargs...]` is not valid Julia — semicolons inside `[]`
    mean array concatenation. Use `obj.prop(args...; kwargs...)` when you need
    kwargs (call-syntax is uncached though). Bracket access is positional only.

### Zero-arg indexed properties

`x() = expr` and `x = expr` are **different**:

```julia
timestamp = time()   # plain: cached once, always returns the same value
now()     = time()   # indexed: obj.now() is fresh each call, obj.now[] caches
```

### Multi-LHS destructuring

A single expression can define several properties at once:

```julia
@dynamicstruct struct Grad
    x::Float64
    val, grad = (f(x), df(x))              # positional (by index)
    (; val, grad) = (; val=f(x), grad=df(x))  # named (by field)
    (; x_val<=val, x_grad<=grad) = autodiff(x)   # per-field rename
    (; x_ <= (val, grad)) = autodiff(x)          # prefix shorthand
    (; a, x_b<=b, y_ <= (c, d)) = f()            # mixed
    @cached a, b = expensive()                   # @cached applies to the group
end
```

The group is computed once (stored in a hidden property); individual members
extract by index or field name. `<=` reads as "from": `x_val<=val` means
"property `x_val` is extracted from field `val`".

## How bare names are resolved (`__self__`)

Inside a property RHS, bare names matching another field or property are
rewritten to `__self__.<name>`. The generated method is roughly:

```julia
# You write:
@dynamicstruct struct Foo
    a::Int
    b = a * 2
end

# Generated (simplified):
compute_property(::Val{:b}, __self__::Foo) = __self__.a * 2
```

`__self__` is the parameter name of the generated method, available as a bare
symbol in any RHS. You'll need it explicitly for API calls that take the
object, e.g. `get_cache_status(__self__, :data, url)`.

**Scoping:** `let`-bindings, lambda parameters, and LHS symbols (named-tuple
keys, assignment targets) are left alone even if they shadow a property:

```julia
evens = let items = filter(iseven, items)   # outer `items` → __self__.items
    sum(items)                               # inner `items` is the local let-binding
end
mapped = map(x -> x * 2, items)              # `x` is local, `items` → __self__.items
```

## Caching

### In-memory cache

Every derived property's value is stored in an instance-level cache dict after
first compute. The dict type is controlled by `cache_type`:

- `cache_type=:serial` (default) — `Dict{Symbol,Any}`.
- `cache_type=:parallel` — `ThreadsafeDict{Symbol,Any}`, deduplicates in-flight
  tasks and is safe for concurrent access.

```julia
obj = Foo(3; cache_type=:parallel)
```

You can set the package-level default via the 2-arg macro form:

```julia
@dynamicstruct :parallel struct SafeApp
    data(id) = expensive(id)
end
```

### Overriding and mutating cached values

Keyword arguments to the constructor (or to [`remake`](@ref)) pre-populate the
cache:

```julia
p = Point(3.0, 4.0; r=10.0)   # p.r returns 10.0 without computing
```

Inside a property body, `prop = value` is rewritten to
`__self__.prop = value`, which writes to the in-memory cache:

```julia
@dynamicstruct struct Counter
    @cached count = 0
    increment = begin
        count = count + 1   # rewrites to __self__.count = __self__.count + 1
        count
    end
end
```

### Disk caching with `@cached`

```julia
@dynamicstruct struct Experiment
    n::Int
    @cached result = sum(rand(n))
end

e = Experiment(1_000)
e.result    # computes and serialises to "cache/<hash>/result.sjl"
Experiment(1_000).result  # loads from disk
```

`@cached` also works on indexed properties — each argument tuple is keyed and
persisted separately:

```julia
@cached g(i, j) = i^2 + j^2   # one file per (i, j)
```

**Cache location** — `cache_path = joinpath(cache_base, hash)` where
`cache_base` defaults to `"cache"` and `hash` is derived from `hash_fields`
(default: all fixed fields). Override either to move caches or narrow the
hash:

```julia
@dynamicstruct struct Foo
    a::Int
    b::Int
    hash_fields = (a,)         # only `a` contributes to the hash
    cache_base  = "/mnt/cache"
    @cached result = a + b     # `b` can change without invalidating the cache
end
```

### `@persist` — write cached state back to disk

`@cached` properties load from disk on first access and are mutated in-memory
via `prop = value`. Use `@persist prop` to flush the current in-memory value
back to the cache file:

```julia
@dynamicstruct struct Timer
    @cached running = false
    @cached log     = nothing
    toggle = begin
        running = !running
        @persist running
        if !running
            log = nothing
            @persist log
        end
    end
end
```

Indexed forms work: `@persist data[url]`.

### LRU eviction with `@lru`

Cap the in-memory entries for an indexed property. Orthogonal to `@cached`:
you can combine them.

```julia
@dynamicstruct struct Models
    @cached @lru 50 fit(seed) = run_fit(seed)  # 50 most-recent kept in RAM, all on disk
end
```

### Memoising free functions with `@memo`

```julia
@memo expensive(x, y) = heavy_computation(x, y)
```

Produces a process-wide memoised version. Useful outside `@dynamicstruct`.

### Cache inspection

All of these work on indexed properties too (e.g. `@is_cached obj.result[key]`):

| Macro / function                        | Returns                                   |
|-----------------------------------------|-------------------------------------------|
| `@cache_status obj.result`              | `:unstarted` / `:started` / `:ready`       |
| `@is_cached obj.result`                 | `true` / `false`                           |
| `@cache_path obj.result`                | on-disk path                               |
| `@clear_cache! obj.result`              | clear disk + in-memory entries             |
| `@clear_cache! obj.result[key]`         | clear one index                            |
| `clear_mem_caches!(obj)`                | clear all in-memory caches on `obj`        |
| `clear_disk_caches!(obj)`               | clear all on-disk caches on `obj`          |
| `clear_all_caches!(obj)`                | both                                       |

These macros also work inside `@dynamicstruct` bodies — omit the object
prefix and use bare property names:

```julia
summary(key) = @is_cached(result[key]) ? "done" : "pending"
```

## Inline nested structs

Child structs defined inside a parent `@dynamicstruct` are auto-wired to the
parent — they get a `__parent__` field and transparently access any parent
property that isn't shadowed. Four forms:

```julia
@dynamicstruct struct Parent
    x::Float64
    y = x + 1

    # Form 1 — explicit property name
    sub = struct Sub
        z = x + y        # x, y forwarded from Parent
    end

    # Form 2 — struct name becomes the property name
    struct Sub2
        w = x * 2
    end

    # Form 1a — indexed inline struct
    subject(id::Int) = struct Subject
        score = x + id   # id is a child field, x is forwarded
    end

    # Form 3 — `@struct` marker, auto-generated child name
    @struct anon(id::Int) = begin
        total = x * id
    end

    # Form 3 with kwargs — defaults can be overridden at call/index sites
    @struct weighted(id; scale=2, bias) = begin
        total = x * id * scale + bias   # scale has a default; bias is required
    end
end

p = Parent(1.0)
p.sub.z              # 3.0
p.Sub2.w             # 2.0
p.subject(7).score   # 8.0 — fresh each call
p.subject[7].score   # 8.0 — cached in-memory by id
p.anon(3).total      # 3.0
p.weighted(3; bias=1).total            # uses scale=2
p.weighted[3; bias=1, scale=5].total   # distinct cache entry from the above
```

Kwargs on indexed inline structs land in the child's `hash_fields`, so distinct
kwarg values produce distinct cache entries (same rule as positional indices).
Required kwargs (no default) are enforced at the parent's call site.

**What the macro does for you (all forms):**

- Renames the child struct to `Parent_Child` to avoid kwarg shadowing.
- Prepends `__parent__` (and any index params) as fixed fields of the child.
- For indexed forms, sets `hash_fields = (__parent__, indices...)` so the
  child's disk cache is namespaced by parent + indices.
- Forwards every parent property name not already declared in the child
  (parent-property-in-child wins; internal names like `cache_path`, `hash`
  are excluded).
- Inherits the parent's `cache_type` (serial / parallel) automatically.
- Auto-wires `__status__` as a `__substatus__` of the parent — see below.
- Recurses through nested inline structs.

For Form 3 (`@struct`), the auto-generated child is named `<prop>_inline`
(e.g. `Parent_anon_inline`). `@struct` is not a real macro — it's
pattern-matched by `@dynamicstruct` and rewritten into Form 1/1a.

## Progress tracking (`__status__` / `__substatus__`)

The framework exposes two conventional properties:

- `__status__` — root progress node, default `nothing`.
- `__substatus__(name, args...; kwargs...)` — hook for per-property child nodes.

When present (typically via the Treebars.jl extension), they enable automatic
progress tracking for long-running indexed computations:

```julia
@dynamicstruct struct App
    __status__ = initialize_progress!(:state; description="App")
    __substatus__(name, args...; kwargs...) =
        initialize_progress!(__status__; description="$(name)$(args)")

    results(key) = expensive(key; __status__)   # __status__ auto-resolves
end
```

- Inside any property body, `__status__` is a local bound to the relevant
  node: the root `__status__` for plain and call-syntax access, a substatus
  for `ThreadsafeDict`-backed indexed access (i.e. `obj.results[key]`).
- `__substatus__` fires **only** on `ThreadsafeDict` `getindex` — not for
  call syntax, not for scalar access.
- Inline children get `__status__ = __substatus__(parent, :child_prop, idx...)`
  automatically. Opt out by declaring the child's own `__status__` (e.g.
  `__status__ = nothing` to disable, or `__status__ = __parent__.__status__`
  to inherit without creating a new node).

## Async indexed access (`fetchindex`)

For `cache_type=:parallel` indexed properties, `fetchindex` provides
non-blocking access to in-flight computations:

```julia
fetchindex(app.results, key) do rv, status
    if rv isa Task && istaskfailed(rv)
        render_error(rv.result)
    elseif rv isa Task
        render_progress(progress_state(status))   # still running
    else
        render(rv)                                # completed value
    end
end

fetchindex(app.results, key; force=true) do rv, status
    # `force=true` clears the cache entry first — used for "Rerun" buttons
end
```

`getstatus(ip, indices...)` returns the current status without triggering a
fetch. `entries(ip)` and `cached_entries(ip)` enumerate in-flight and
completed entries (see [API](api.md)).

## Construction and `remake`

```julia
p  = Point(3.0, 4.0)            # positional fixed fields
p2 = Point(3.0, 4.0; r=10.0)    # kwarg pre-populates the cache
p3 = remake(p; x=5.0)           # same type, change fixed fields (derived recomputes)
p4 = remake(p; r=99.0)          # change a cached value instead
```

## Errors: `PropertyComputationError`

If a property computation throws, the error is wrapped in a
`PropertyComputationError` that records the property name, object type,
indices, and kwargs. `showerror` prints a concise summary with a "Caused by"
chain; `unwrap_error(err)` peels through `TaskFailedException` /
`CompositeException` layers to reach the root cause.

## Revise compatibility

Everything inside a `@dynamicstruct` body — property bodies, added / removed /
renamed derived properties, indexed signatures, inline nested structs,
macro-decorated properties — is picked up by Revise on save.

Limits (inherited from Julia + Revise):

- Adding, removing, or reordering **fixed fields** changes the underlying
  struct and needs a rename (`MyStruct2`) or a session restart.
- `const` bindings can't be redefined — don't use `const` for things you
  expect to change.
- New deps in `Project.toml` / `Manifest.toml` require a restart.

## Complete example

```julia
using DynamicObjects

@dynamicstruct struct Analysis
    data_path::String
    n_samples::Int

    data      = load_data(data_path)
    subsample = data[1:n_samples]

    @cached fit    = run_model(subsample)
    @cached report = summarise(fit)
end

a  = Analysis("data.csv", 1_000)
a.report   # runs fit + report, caches both

a2 = Analysis("data.csv", 1_000)
a2.report  # loads both from disk
```
