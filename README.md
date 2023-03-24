# DynamicObjects.jl

Implements a dynamic object type with caching.

```julia
using DynamicObjects

Rectangle = DynamicObject{:rectangle}
DynamicObject{:rectangle}(height, width; kwargs...) = Rectangle((height=height, width=width, kwargs...))
unit(what::Rectangle) = "mm"
area(what::Rectangle, unit=what.unit) = "$(what.height * what.width)$(unit)^2"

rect = Rectangle(10, 20)
println("A $(rect) has an area of $(rect.area).")
```

```
A DynamicObject{:rectangle}((height = 10, width = 20)) has an area of 200mm^2.
```