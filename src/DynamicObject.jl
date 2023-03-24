module DynamicObject
import Serialization
struct Object{T}
    nt::NamedTuple
    Object{T}(nt::NamedTuple) where T = new(nt)
end
Base.propertynames(value::Object) = propertynames(value.nt)
function Base.getproperty(value::Object, name::Symbol)
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
# Object{T}(nt::NamedTuple) where T = Object{T}(g.nt)
Object{T}(g::Object) where T = Object{T}(g.nt)
Object{T}(;kwargs...) where T = Object{T}((;kwargs...))

# Object{T}() where T = Object{T}(NamedTuple())
# default(g, name) = missing
# getprop(g, name, def=default(Object, name)) = hasproperty(g, name) ? getproperty(g, name) : def
Base.merge(g::Object, args...) = typeof(g)(merge(g.nt, args...))
Base.length(g::Object) = 1
Base.size(g::Object) = ()
Base.getindex(g::Object, i) = g
Base.iterate(g::Object) = iterate([g])
# Base.merge(g::Object, arg1::Object, args...) = typeof(g)(merge(g.nt, arg1.nt, args...))
# igetproperty(obj, sym) = getproperty(obj, sym)
# igetproperty(obj, sym, args...) = igetproperty(getproperty(obj, sym), args...)
update(what; kwargs...) = merge(what, (;kwargs...))
update(what, args...) = merge(what, (;zip(args, getproperty.([what], args))...))
# update_default(what, args...) = update(wha)

# G = Object
Base.hash(g::Object) = Base.hash(repr(g))

function cached(g::Object, key)
    if hasproperty(g, key)
        # println("LOADING FROM OBJECT")
        getproperty(g, key)
    else
        if !isdir("cache")
            mkdir("cache")
        end
        file_name = "cache/$(key)_$(g.hash)"
        if isfile(file_name)
            # println("LOADING FROM FILE!")
            Serialization.deserialize(file_name)
        else
            # println("COMPUTING")
            rv = getproperty(g, key)
            Serialization.serialize(file_name, rv)
            rv
        end
    end
end
update_cached(what, args...) = merge(what, (;zip(args, cached.([what], args))...))
# Plots.plot!(p, what) = Plots.plot()
# Plots.plot(what::Object{T}) where T = Plots.plot!(Plots.plot(), what)
export Object, update, cached, update_cached

end
