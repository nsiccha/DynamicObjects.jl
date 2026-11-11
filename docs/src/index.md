# DynamicObjects.jl

DynamicObjects defines Julia structs with lazy properties that reuse computed values in memory and, when requested, on disk.

Install this documentation's development line from a terminal:

```sh
julia -e 'using Pkg; Pkg.add([
    PackageSpec(url="https://github.com/nsiccha/Treebars.jl",
                rev="main"),
    PackageSpec(url="https://github.com/nsiccha/DynamicObjects.jl",
                rev="pre-inference")
])'
```

```@example start
using DynamicObjects

@dynamicstruct struct Point
    x::Float64
    y::Float64
    radius = hypot(x, y)
end

point = Point(3.0, 4.0)
@assert point.radius == 5.0 # hide
__docs_output__ = begin # hide
point.radius
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

`x` and `y` are constructor fields. `radius` computes on its first read and
reuses that value on later reads. Its body refers to the fields by name.

## Next steps

Read [Properties](guides/properties.md) to define argument-taking properties,
or follow [Cached signal analysis](examples/signal.md) to measure which reads
compute and which reuse results. The [reference](reference/objects.md) records
the public contracts.

Treat fields, call arguments, and returned values as immutable after passing
them to an object. Use [`remake`](@ref) for changed inputs and the
[cache guide](guides/caches.md) for explicit invalidation.
