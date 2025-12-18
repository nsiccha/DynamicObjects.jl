# DynamicObjects.jl

Provides an `@dynamicstruct` macro, allowing quickly defining structs with derived (and optionally cached) properties, 
which can be defined inline using `prop = expr` using all previously or afterwards defined fields and properties, e.g. as

```julia
using DynamicObjects

@dynamicstruct struct MyStruct 
    "Standard fields are defined without an `=` sign. These can have types."
    a::Float64
    "Derived properties can use any of the other fields or properties (provided there are no cycles)."
    b = a + 1
    "Derived properties can be cached."
    @cached d = c + 1
    "Order of definition does not matter"
    c = b + 1
    "Derived properties get computed lazily and then get stored locally."
    e = d + 1
end
```

See [https://nsiccha.github.io/DynamicObjects.jl](https://nsiccha.github.io/DynamicObjects.jl) for a non-minimal example.