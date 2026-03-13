# DynamicObjects.jl

[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://nsiccha.github.io/DynamicObjects.jl/dev/)
[![CI](https://github.com/nsiccha/DynamicObjects.jl/actions/workflows/test.yml/badge.svg)](https://github.com/nsiccha/DynamicObjects.jl/actions/workflows/test.yml)

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

## See also

- [ReactiveObjects.jl](https://github.com/nsiccha/ReactiveObjects.jl) — reactive variant with automatic recomputation
