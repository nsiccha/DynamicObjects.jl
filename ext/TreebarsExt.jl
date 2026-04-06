module TreebarsExt

using DynamicObjects, Treebars

DynamicObjects._default_substatus(status::Treebars.ProgressNode, o, name, args...; kwargs...) =
    Treebars.initialize_progress!(status; description=DynamicObjects._property_description(o, Val(name), args...; kwargs...))

end
