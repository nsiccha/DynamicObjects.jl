module DynamicObjects
export AbstractDynamicObject, DynamicObject, @dynamic_object, @dynamic_type#, update, cached, 
import Serialization


esc_arg(arg::Symbol) = esc(arg)
function esc_arg(arg::Expr) 
    if arg.head == :(=)
        # When parsing the macro argument, "default assignments" such as
        # `param=42` are turned into `Expr(:(=), :param, 42)`. However, to
        # specify default arguments to functions, this needs to be provided
        # as `Expr(:kw, :param, 42)`:
        Expr(:kw, esc(arg.args[1]), esc(arg.args[2]))
    else
        esc(arg)
    end
end
get_arg_symbol(arg::Symbol) = arg
get_arg_symbol(arg::Expr) = arg.head == :(=) ? get_arg_symbol(arg.args[1]) : arg.args[1]

"""
    @dynamic_object(name, args...)

Defines a DynamicObject:

```
@dynamic_object Rectangle height width
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
    sname = get_sname(name)
    ename, ebase = ename_and_ebase(name, DynamicObject)
    # ename = esc(name)
    eargs = esc_arg.(args)
    kwargs = esc(:kwargs) 
    argnames = get_arg_symbol.(args)
    aargs = [esc(:($(arg)=$(arg))) for arg in argnames]
    quote
        Base.@__doc__ $ename = $ebase{$sname}
        $ebase{$sname}($(eargs...); $kwargs...) = $ebase{$sname}((
            $(aargs...), $kwargs...
        ))
    end
end

get_sname(name::Symbol) = QuoteNode(name)
get_sname(name::Expr) = QuoteNode(name.args[1])
ename_and_ebase(name::Symbol, default) = esc(name), default
ename_and_ebase(name::Expr, default) = esc.(name.args)

abstract type AbstractDynamicObject end

macro dynamic_type(name)
    ename, ebase = ename_and_ebase(name, AbstractDynamicObject)
    NT = esc(:NamedTuple)
    Base = esc(:Base)
    quote
        Base.@__doc__ struct $ename{T} <: $ebase
            nt::$NT
            # $ename{T}(nt::$NT) where T = new(nt)
        end
        $Base.propertynames(what::$ename) = propertynames(what.nt)
        function $Base.getproperty(what::$ename, name::Symbol)
            if name == :nt
                getfield(what, name)
            else
                if hasproperty(what.nt, name)
                    getproperty(what.nt, name)
                else
                    getfield(Main, name)(what)
                end
            end
        end
        $ename{T}(what::$ename) where T = $ename{T}(what.nt)
        $ename{T}(;kwargs...) where T = $ename{T}((;kwargs...))
        $Base.show(io::IO, what::$ename{T}) where T = print(io, T, what.nt)
        $Base.merge(what::$ename, args...) = typeof(what)(merge(what.nt, args...))
        update(what::$ename; kwargs...) = merge(what, (;kwargs...))
        update(what::$ename, args...) = merge(what, (;zip(args, getproperty.([what], args))...))
        $Base.hash(what::$ename{T}, h::Int=0) where T = hash((what.nt, T, h))
    end
end

"""
    DynamicObject{T}

A `DynamicObject` is a thin named wrapper around a generic NamedTuple which enables function overloading.
The type is inefficient computationally, but can enable more efficient prototyping/development.
"""
@dynamic_type DynamicObject 
# struct DynamicObject{T}
#     nt::NamedTuple
#     DynamicObject{T}(nt::NamedTuple) where T = new(nt)
# end

# Base.propertynames(value::DynamicObject) = propertynames(value.nt)
# function Base.getproperty(value::DynamicObject, name::Symbol)
#     if name == :nt
#         getfield(value, name)
#     else
#         if hasproperty(value.nt, name)
#             getproperty(value.nt, name)
#         else
#             getfield(Main, name)(value)
#         end
#     end
# end
# # DynamicObject{T}(nt::NamedTuple) where T = DynamicObject{T}(nt)
# DynamicObject{T}(what::DynamicObject) where T = DynamicObject{T}(what.nt)
# DynamicObject{T}(;kwargs...) where T = DynamicObject{T}((;kwargs...))
# Base.show(io::IO, what::DynamicObject{T}) where T = print(io, T, what.nt)
# Base.merge(what::DynamicObject, args...) = typeof(what)(merge(what.nt, args...))
# update(what; kwargs...) = merge(what, (;kwargs...))
# update(what, args...) = merge(what, (;zip(args, getproperty.([what], args))...))
# Base.hash(what::DynamicObject{T}, h::Int=0) where T = Base.hash((what.nt, T, h))


# function cached(what::DynamicObject, key)
#     if hasproperty(what, key)
#         # println("LOADING FROM DynamicObject")
#         getproperty(what, key)
#     else
#         if !isdir("cache")
#             mkdir("cache")
#         end
#         file_name = "cache/$(key)_$(what.hash)"
#         if isfile(file_name)
#             # println("LOADING FROM FILE!")
#             Serialization.deserialize(file_name)
#         else
#             # println("COMPUTING")
#             rv = getproperty(what, key)
#             Serialization.serialize(file_name, rv)
#             rv
#         end
#     end
# end

# DynamicObject{T}() where T = DynamicObject{T}(NamedTuple())
# default(what, name) = missing
# getprop(what, name, def=default(DynamicObject, name)) = hasproperty(what, name) ? getproperty(what, name) : def

# Base.length(what::DynamicObject) = 1
# Base.size(what::DynamicObject) = ()
# Base.getindex(what::DynamicObject, i) = what
# Base.iterate(what::DynamicObject) = iterate([what])
# Base.merge(what::DynamicObject, arg1::DynamicObject, args...) = typeof(what)(merge(what.nt, arg1.nt, args...))
# igetproperty(obj, sym) = getproperty(obj, sym)
# igetproperty(obj, sym, args...) = igetproperty(getproperty(obj, sym), args...)
# update_default(what, args...) = update(wha)

# what = DynamicObject
# update_cached(what, args...) = merge(what, (;zip(args, cached.([what], args))...))
# Plots.plot!(p, what) = Plots.plot()
# Plots.plot(what::DynamicObject{T}) where T = Plots.plot!(Plots.plot(), what)

end
