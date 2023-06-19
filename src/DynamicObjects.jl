module DynamicObjects
export AbstractDynamicObject, DynamicObject, @dynamic_object, @dynamic_type, update, cached, unpack
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
        DynamicObjects.unpack(what::$ename) = DynamicObjects.unpack(what::$ename, $argnames...)
    end
end

get_sname(name::Symbol) = QuoteNode(name)
get_sname(name::Expr) = QuoteNode(name.args[1])
ename_and_ebase(name::Symbol, default) = esc(name), default
ename_and_ebase(name::Expr, default) = esc.(name.args)

abstract type AbstractDynamicObject end

# persistent_hash(what, h) = hash(what, h)
persistent_hash(what, h) = hash(persistent_hash_attributes(what), h)
persistent_hash_attributes(what) = what
# https://github.com/JuliaLang/julia/blob/master/base/namedtuple.jl#L253
persistent_hash(x::NamedTuple, h) = xor(objectid(Base._nt_names(x)), persistent_hash(Tuple(x), h))
# https://github.com/JuliaLang/julia/blob/master/base/tuple.jl#L510
persistent_hash(x::Tuple, h) = hash(persistent_hash.(x, h), h)
# ?
persistent_hash(x::AbstractArray, h) = hash(persistent_hash.(x, h), h)

macro dynamic_type(name)
    ename, ebase = ename_and_ebase(name, AbstractDynamicObject)
    # eupdate = esc(:update)
    quote
        Base.@__doc__ struct $ename{T} <: $ebase
            nt::NamedTuple
            # $ename{T}(nt::$NT) where T = new(nt)
        end
        Base.propertynames(what::$ename) = propertynames(what.nt)
        function Base.getproperty(what::$ename, name::Symbol)
            if name == :nt
                getfield(what, name)
            else
                if hasproperty(what.nt, name)
                    getproperty(what.nt, name)
                elseif isdefined($__module__, name)
                    getproperty($__module__, name)(what)
                elseif isdefined(Main, name)
                    # Should this actually be done? 
                    getproperty(Main, name)(what)
                elseif startswith(String(name), "cached_")
                    DynamicObjects.cached(what, Symbol(String(name)[8:end]))
                else
                    # Should this be a different error?
                    throw(DomainError(name, "Can't resolve attribute $(name). Looked in $($__module__) and Main."))
                end
            end
        end
        $ename{T}(what::$ename) where T = $ename{T}(what.nt)
        $ename{T}(;kwargs...) where T = $ename{T}((;kwargs...))
        Base.show(io::IO, what::$ename{T}) where T = print(io, T, what.nt)
        Base.merge(what::$ename, args...) = typeof(what)(merge(what.nt, args...))
        # DynamicObjects.update(what::$ename; kwargs...) = merge(what, (;kwargs...))
        DynamicObjects.update(what::$ename, args::Symbol...; kwargs...) = merge(what, (;kwargs...), (;zip(args, getproperty.([what], args))...))
        Base.hash(what::$ename{T}, h::UInt=UInt(0)) where T = DynamicObjects.persistent_hash((what.nt, T), h)
    end
end

# update(what::AbstractDynamicObject) = what
unpack(what, args::Symbol...) = getproperty.([what], args)
update(args::Symbol...; kwargs...) = what->update(what, args...; kwargs...)

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


get_cache_path() = get(ENV, "DYNAMIC_CACHE", "cache")
set_cache_path!(path::AbstractString) = (ENV["DYNAMIC_CACHE"] = path)
get_cache_path(key::Symbol, what) = joinpath(get_cache_path(), "$(key)_$(typeof(what))_$(what.hash)")
read_cache(what, key::Symbol) = Serialization.deserialize(get_cache_path(key, what))
write_cache(what, key::Symbol, rv) = Serialization.serialize(get_cache_path(key, what), rv)
# get_cache_verbosity() = get(ENV, "DYNAMIC_CACHE_VERBOSITY", 0)
# set_cache_verbosity!(path::AbstractString) = (ENV["DYNAMIC_CACHE_VERBOSITY"] = path)

function cached(what, key::Symbol, no_disk=false)
    if hasproperty(what, key)
        # println("LOADING FROM DynamicObject")
        getproperty(what, key)
    else
        mkpath(get_cache_path())
        file_name = get_cache_path(key, what)
        if !no_disk && isfile(file_name)
            # println("LOADING FROM FILE!")
            Serialization.deserialize(file_name)
        else
            rv = getproperty(what, key)
            Serialization.serialize(file_name, rv)
            rv
        end
    end
end
cached(key::Symbol) = x->cached(x, key)

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
