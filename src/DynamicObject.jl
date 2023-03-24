module DynamicObject
import Serialization
struct DynamicObject{T}
    nt::NamedTuple
    DynamicObject{T}(nt::NamedTuple) where T = new(nt)
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
# DynamicObject{T}(nt::NamedTuple) where T = DynamicObject{T}(g.nt)
DynamicObject{T}(g::DynamicObject) where T = DynamicObject{T}(g.nt)
DynamicObject{T}(;kwargs...) where T = DynamicObject{T}((;kwargs...))

# DynamicObject{T}() where T = DynamicObject{T}(NamedTuple())
# default(g, name) = missing
# getprop(g, name, def=default(DynamicObject, name)) = hasproperty(g, name) ? getproperty(g, name) : def
Base.merge(g::DynamicObject, args...) = typeof(g)(merge(g.nt, args...))
Base.length(g::DynamicObject) = 1
Base.size(g::DynamicObject) = ()
Base.getindex(g::DynamicObject, i) = g
Base.iterate(g::DynamicObject) = iterate([g])
# Base.merge(g::DynamicObject, arg1::DynamicObject, args...) = typeof(g)(merge(g.nt, arg1.nt, args...))
# igetproperty(obj, sym) = getproperty(obj, sym)
# igetproperty(obj, sym, args...) = igetproperty(getproperty(obj, sym), args...)
update(what; kwargs...) = merge(what, (;kwargs...))
update(what, args...) = merge(what, (;zip(args, getproperty.([what], args))...))
# update_default(what, args...) = update(wha)

# G = DynamicObject
Base.hash(g::DynamicObject) = Base.hash(repr(g))

function cached(g::DynamicObject, key)
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
# Plots.plot(what::DynamicObject{T}) where T = Plots.plot!(Plots.plot(), what)
export DynamicObject, update, cached, update_cached

end
