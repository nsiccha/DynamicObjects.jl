# DynamicObjects.jl

Implements a dynamic object type with convenient/confusing `.`-syntax and caching.

```julia
using DynamicObjects

@dynamic_object Rectangle height width  
area(what::Rectangle) = what.height * what.width

rect = Rectangle(10, 20)
println("A $(rect) has an area of $(rect.area).")
```

```
A Rectangle(height = 10, width = 20) has an area of 200.
```