# DynamicObject.jl

Implements a dynamic object type with caching.

```julia
using DynamicObject

Rectangle = Object{:rectangle}
Rectangle(height, width) = Rectangle((height=height, width=width))
area(what::Rectangle) = what.height * what.width

rect = Rectangle(10, 20)
print("A $(rect) has an area of $(rect.area).")
```