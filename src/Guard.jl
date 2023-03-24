module Guard
import Serialization
struct guard{T}
    nt::NamedTuple
    guard{T}(nt::NamedTuple) where T = new(nt)
end
Base.propertynames(value::guard) = propertynames(value.nt)
function Base.getproperty(value::guard, name::Symbol)
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
# guard{T}(nt::NamedTuple) where T = guard{T}(g.nt)
guard{T}(g::guard) where T = guard{T}(g.nt)
guard{T}(;kwargs...) where T = guard{T}((;kwargs...))

# guard{T}() where T = guard{T}(NamedTuple())
# default(g, name) = missing
# getprop(g, name, def=default(guard, name)) = hasproperty(g, name) ? getproperty(g, name) : def
Base.merge(g::guard, args...) = typeof(g)(merge(g.nt, args...))
Base.length(g::guard) = 1
Base.size(g::guard) = ()
Base.getindex(g::guard, i) = g
Base.iterate(g::guard) = iterate([g])
# Base.merge(g::guard, arg1::guard, args...) = typeof(g)(merge(g.nt, arg1.nt, args...))
# igetproperty(obj, sym) = getproperty(obj, sym)
# igetproperty(obj, sym, args...) = igetproperty(getproperty(obj, sym), args...)
update(what; kwargs...) = merge(what, (;kwargs...))
update(what, args...) = merge(what, (;zip(args, getproperty.([what], args))...))
# update_default(what, args...) = update(wha)

# G = guard
Base.hash(g::guard) = Base.hash(repr(g))

function cached(g::guard, key)
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
# Plots.plot(what::guard{T}) where T = Plots.plot!(Plots.plot(), what)
export guard, update, cached, update_cached

end
