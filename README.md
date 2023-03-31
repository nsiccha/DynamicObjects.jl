# DynamicObjects.jl

Implements a dynamic object type which can be redefined with convenient/confusing `.`-syntax and caching.

```julia
using DynamicObjects

"""
A fancy rectangle.
"""
@dynamic_object Rectangle height width  
area(what::Rectangle) = what.height * what.width

rect = Rectangle(10, 20)
println("A $(rect) has an area of $(rect.area).")
```

```
A Rectangle(height = 10, width = 20) has an area of 200.
```

## To add/fix:

* Inheritance (e.g. `@dynamic_object Rectangle <: Polygon height width`)
* Defining a single argument type without a type on that argument (e.g. `@dynamic_object Circle radius`)