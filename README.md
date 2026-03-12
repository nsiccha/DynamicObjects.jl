# DynamicObjects.jl

Structs with lazily computed, optionally disk-cached properties.

```julia
using DynamicObjects

@dynamicstruct struct MyStruct
    a::Float64
    b = a + 1        # derived from `a`
    c = b + 1        # derived from `b`
    @cached d = c + 1 # disk-cached
    e = d + 1
end

s = MyStruct(1.0)
s.b  # 2.0 — computed on first access, then cached in memory
s.d  # 4.0 — computed on first access, then cached to disk
```

See the [full documentation](https://nsiccha.github.io/DynamicObjects.jl) for details on indexed properties, `@persist`, scoping rules, thread safety, and more.
