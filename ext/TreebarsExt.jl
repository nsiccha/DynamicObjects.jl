module TreebarsExt

using DynamicObjects, Treebars

DynamicObjects._default_substatus(status::Treebars.ProgressNode, name, args...; kwargs...) =
    Treebars.initialize_progress!(status; description="$name[$(join(args, ","))]")

end
