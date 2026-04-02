# DynamicObjects.jl

`DynamicObjects.jl` provides the `@dynamicstruct` macro for defining Julia structs
with lazily computed, optionally disk-cached properties.

## Quick start

```julia
using DynamicObjects

@dynamicstruct struct Point
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
end

p = Point(3.0, 4.0)
p.r      # 5.0  (computed on first access, cached in-memory)
p.theta  # atan(4, 3)
```

## Key concepts

### Fixed fields vs derived properties

Lines **without** `=` declare fixed fields — they become constructor arguments:

```julia
@dynamicstruct struct Foo
    a::Int        # fixed: set at construction time
    b = a * 2     # derived: computed lazily from a
end

Foo(3).b   # 6
```

Properties on the right-hand side of `=` may reference any other field or
property by name; the reference is automatically resolved through the object.
Order of definition does not matter.

### In-memory caching

Derived properties are computed at most once per object and stored in an
in-memory cache.  To share values across tasks without duplicate computation,
pass `cache_type=:parallel` to the constructor:

```julia
obj = Foo(3; cache_type=:parallel)
```

### Disk caching with `@cached`

Mark a property `@cached` to additionally persist it to disk:

```julia
@dynamicstruct struct Experiment
    n::Int
    @cached result = sum(rand(n))
end

e = Experiment(1_000_000)
e.result    # computed and written to cache/
e2 = Experiment(1_000_000)
e2.result   # loaded from disk (same n → same hash → same path)
```

The cache location is controlled by `cache_base` (defaults to `"cache"`) and
`cache_path` (defaults to `joinpath(cache_base, hash_of_fields)`).

### Indexable properties

Use bracket syntax to define properties that take indices:

```julia
@dynamicstruct struct Grid
    f[i, j] = i + 10 * j
    label(i, j) = "cell ($i, $j)"           # call syntax
    @cached g[i, j] = i^2 + j^2             # each (i,j) pair cached to disk
end

grid = Grid()
grid.f[1, 2]       # 21        — cached per index
grid.label(1, 2)    # "cell (1, 2)" — computed fresh each call
```

Both bracket and call syntax define indexable properties — the difference is
in the calling convention:

- `obj.prop[args...]` caches the result per index in memory (same args → same result).
- `obj.prop(args...)` computes fresh each time (directly invokes `compute_property`, no caching).

**Note:** `obj.prop[args...; kwargs...]` is **not valid Julia syntax** — semicolons
inside `[]` mean array concatenation, not keyword arguments. Use call syntax `()`
for kwargs:

```julia
obj.prop(args...; kwarg=val)   # ✓ works
obj.prop[args...; kwarg=val]   # ✗ not valid Julia
```

Call-syntax properties can accept keyword arguments:

```julia
@dynamicstruct struct Formatter
    format(x; digits=2) = round(x; digits)
end

f = Formatter()
f.format(π)              # 3.14
f.format(π; digits=4)    # 3.1416
```

### Dynamic dispatch on indexable properties

Since indexable properties generate standard Julia `compute_property` methods,
they participate in Julia's multiple dispatch.  You can define multiple
signatures for the same property name:

```julia
@dynamicstruct struct Greeter
    greeting = "Hello"
    greet(name::String) = "$(greeting), $(name)!"
    greet(n::Int)       = "$(greeting), person #$(n)!"
end

g = Greeter()
g.greet("Alice")   # "Hello, Alice!"
g.greet(42)        # "Hello, person #42!"
```

This works because each definition emits a separate method with the appropriate
type signature, just like ordinary Julia function definitions.

### How property references work (`__self__`)

When writing the RHS of a derived property, bare names that match any
property or field of the struct are **automatically rewritten** to
`__self__.<name>`. The generated method looks like:

```julia
# What you write:
@dynamicstruct struct Foo
    a::Int
    b = a * 2
end

# What gets generated (simplified):
DynamicObjects.compute_property(::Val{:b}, __self__::Foo) = __self__.a * 2
```

This means `__self__` is available as a bare symbol in any property RHS —
it's the parameter name of the generated method. You normally don't need
it directly, but it's required for API calls like `get_cache_status`:

```julia
@dynamicstruct struct App
    @cached data[url] = fetch(url)
    loader[url] = begin
        status = DynamicObjects.get_cache_status(__self__, :data, url)
        status == :ready ? data[url] : "Loading..."
    end
end
```

### Scoping rules

Not every bare name gets rewritten — `let` bindings and lambda parameters
are treated as local and left alone, even if they shadow a property:

```julia
@dynamicstruct struct App
    items = [1, 2, 3, 4]
    evens = let items = filter(iseven, items)  # outer `items` → __self__.items
        sum(items)                              # inner `items` is the local
    end
    mapped = map(x -> x * 2, items)           # `x` is local, `items` → __self__.items
end
```

### Mutating the cache (`setproperty!`)

Derived properties can be overwritten at runtime:

```julia
p = Point(3.0, 4.0)
p.r       # 5.0
p.r = 99
p.r       # 99
```

Inside a property RHS, writing `prop = value` is rewritten to
`__self__.prop = value`, which calls `setproperty!` and updates the
in-memory cache:

```julia
@dynamicstruct struct Counter
    @cached count = 0
    increment = begin
        count = count + 1   # rewritten to: __self__.count = __self__.count + 1
        count
    end
end
```

### Persisting cache changes (`@persist`)

When you mutate a `@cached` property via assignment, the change only
affects the in-memory cache. Use `@persist` to serialise the current
value back to disk:

```julia
@dynamicstruct struct Timer
    @cached running = false
    @cached current_log = nothing

    toggle = begin
        running = !running
        @persist running
        if !running
            current_log = nothing
            @persist current_log
        end
    end
end

t = Timer()
t.toggle    # running = true, persisted to disk
# In a new session:
t2 = Timer()
t2.running  # true — loaded from disk
```

`@persist` also works for indexed cached properties: `@persist data[url]`.

### Constructor kwargs as cache overrides

Keyword arguments pre-populate the cache, overriding any derived property:

```julia
p = Point(3.0, 4.0; r=10.0)
p.r  # 10.0 — override, not computed
```

### remake

`remake` creates a new instance with some fields changed:

```julia
e2 = remake(e; n=2_000_000)   # fresh instance, n changed, result recomputed
```

Keyword arguments that don't match fixed fields are treated as cache
overrides, same as the constructor:

```julia
e3 = remake(e; result=0.0)    # n unchanged, result pre-set to 0.0
```

## Extended example

The `@dynamicstruct` macro is particularly useful for computational experiments
where some steps are expensive and should be cached:

```julia
using DynamicObjects

@dynamicstruct struct Analysis
    data_path::String
    n_samples::Int

    # derived from fixed fields
    data       = load_data(data_path)
    subsample  = data[1:n_samples]

    # expensive: cached to disk, keyed by (data_path, n_samples)
    @cached fit    = run_model(subsample)
    @cached report = summarise(fit)
end

a = Analysis("data.csv", 1000)
a.report   # computes everything and caches fit + report

# later, in a new session:
a2 = Analysis("data.csv", 1000)
a2.report  # loads fit and report from disk — no recomputation
```
