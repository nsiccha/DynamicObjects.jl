module DynamicObjects
export DynamicObject, @dynamic_object#, update, cached, 
import Serialization

"""
    DynamicObject{T}

A `DynamicObject` is a thin named wrapper around a generic NamedTuple which enables function overloading.
The type is inefficient computationally, but can enable more efficient prototyping/development.
"""
struct DynamicObject{T}
    nt::NamedTuple
    DynamicObject{T}(nt::NamedTuple) where T = new(nt)
end
esc_arg(arg::Symbol) = esc(arg)
esc_arg(arg::Expr) = arg.head == :(=) ? :($(esc(arg.args[1]))=$(arg.args[2])) : esc(arg)
get_arg_symbol(arg::Symbol) = arg
get_arg_symbol(arg::Expr) = arg.head == :(=) ? get_arg_symbol(arg.args[1]) : arg.args[1]

"""
    @dynamic_object(name, args...)

Defines a DynamicObject:

```
@@dynamic_object Rectangle height width
```

defines a dynamic type called `Rectangle = DynamicObject{:Rectangle}` with
defining attributes `height` and `width` and defines a constructor
```
Rectangle(height, width; kwargs...) = DynamicObject{:Rectangle}((height=height, width=with, kwargs...))
```

This dynamic type can be used in function definitions as 
```
area(what::Rectangle) = what.height * what.width
```
"""
macro dynamic_object(name, args...)
    sname = QuoteNode(name)
    ename = esc(name)
    eargs = esc_arg.(args)
    kwargs = esc(:kwargs) 
    argnames = get_arg_symbol.(args)
    aargs = [esc(:($(arg)=$(arg))) for arg in argnames]
    quote
        Base.@__doc__ $ename = DynamicObject{$sname}
        $DynamicObject{$sname}($(eargs...); $kwargs...) = DynamicObject{$sname}((
            $(aargs...), $kwargs...
        ))
    end
end
Base.propertynames(value::DynamicObject) = propertynames(value.nt)
function Base.getproperty(value::DynamicObject, name::Symbol)
    if name == :nt
        getfield(value, name)
    else
        if hasproperty(value.nt, name)
            getproperty(value.nt, name)
        else
            getfield(Main, name)(value)
        end
    end
end
# DynamicObject{T}(nt::NamedTuple) where T = DynamicObject{T}(nt)
DynamicObject{T}(what::DynamicObject) where T = DynamicObject{T}(what.nt)
DynamicObject{T}(;kwargs...) where T = DynamicObject{T}((;kwargs...))

# DynamicObject{T}() where T = DynamicObject{T}(NamedTuple())
# default(what, name) = missing
# getprop(what, name, def=default(DynamicObject, name)) = hasproperty(what, name) ? getproperty(what, name) : def
Base.show(io::IO, what::DynamicObject{T}) where T = print(io, T, what.nt)
Base.merge(what::DynamicObject, args...) = typeof(what)(merge(what.nt, args...))
# Base.length(what::DynamicObject) = 1
# Base.size(what::DynamicObject) = ()
# Base.getindex(what::DynamicObject, i) = what
# Base.iterate(what::DynamicObject) = iterate([what])
# Base.merge(what::DynamicObject, arg1::DynamicObject, args...) = typeof(what)(merge(what.nt, arg1.nt, args...))
# igetproperty(obj, sym) = getproperty(obj, sym)
# igetproperty(obj, sym, args...) = igetproperty(getproperty(obj, sym), args...)
update(what; kwargs...) = merge(what, (;kwargs...))
update(what, args...) = merge(what, (;zip(args, getproperty.([what], args))...))
# update_default(what, args...) = update(wha)

# what = DynamicObject
Base.hash(what::DynamicObject{T}, h::Int=0) where T = Base.hash((what.nt, T, h))

function cached(what::DynamicObject, key)
    if hasproperty(what, key)
        # println("LOADING FROM DynamicObject")
        getproperty(what, key)
    else
        if !isdir("cache")
            mkdir("cache")
        end
        file_name = "cache/$(key)_$(what.hash)"
        if isfile(file_name)
            # println("LOADING FROM FILE!")
            Serialization.deserialize(file_name)
        else
            # println("COMPUTING")
            rv = getproperty(what, key)
            Serialization.serialize(file_name, rv)
            rv
        end
    end
end
# update_cached(what, args...) = merge(what, (;zip(args, cached.([what], args))...))
# Plots.plot!(p, what) = Plots.plot()
# Plots.plot(what::DynamicObject{T}) where T = Plots.plot!(Plots.plot(), what)

end
