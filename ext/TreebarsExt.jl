module TreebarsExt

using DynamicObjects, Treebars

# `transient` is consumed here (default true → substatus auto-detaches on finalize);
# it does not reach the property body. Pass transient=false to keep finished substatuses
# pinned to the parent tree (e.g. for historical "N finished" pill display).
DynamicObjects._default_substatus(status::Treebars.ProgressNode, o, name, args...; transient=true, kwargs...) =
    Treebars.initialize_progress!(status;
        description=DynamicObjects._property_description(o, Val(name), args...; kwargs...),
        transient)

# Lifecycle hooks — give DO's ThreadsafeDict-spawned substatuses the with_progress
# init/run/finalize symmetry. Success path calls finalize (which detaches transient
# nodes from the tree); failure path calls fail (which leaves failed nodes pinned
# so they stay visible until retry_failed clears them).
DynamicObjects._finalize_substatus!(s::Treebars.ProgressNode) = Treebars.finalize_progress!(s)
DynamicObjects._fail_substatus!(s::Treebars.ProgressNode, e) = Treebars.fail_progress!(s, e)

end
