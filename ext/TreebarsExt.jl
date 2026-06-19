module TreebarsExt

using DynamicObjects, Treebars

# Description of a property's substatus node: the property's docstring — the
# opt-in signal for "label this in the progress tree" — when present, else an
# empty string, which makes the Treebars node a bare wrapper the renderer
# inlines (children hoist up; no empty level). This is the `displayed =
# !isnothing(doc)` rule: undocumented properties add no labelled noise to the
# tree, documented ones do.
#
# `transient` is consumed here (default true → substatus auto-detaches on finalize);
# it does not reach the property body. Pass transient=false to keep finished substatuses
# pinned to the parent tree (e.g. for historical "N finished" pill display).
function DynamicObjects._default_substatus(status::Treebars.ProgressNode, o, name, args...; transient=true, kwargs...)
    info = DynamicObjects.metafirst(typeof(o), name)
    desc = (!isnothing(info) && !isnothing(DynamicObjects.property_doc(info))) ?
        something(DynamicObjects._property_description(o, Val(name), args...; kwargs...), "") : ""
    Treebars.initialize_progress!(status; description=desc, transient)
end

# Lifecycle hooks — give DO's ThreadsafeDict-spawned substatuses the with_progress
# init/run/finalize symmetry. Success path calls finalize (which detaches transient
# nodes from the tree); failure path calls fail (which leaves failed nodes pinned
# so they stay visible until retry_failed clears them).
DynamicObjects._finalize_substatus!(s::Treebars.ProgressNode) = Treebars.finalize_progress!(s)
DynamicObjects._fail_substatus!(s::Treebars.ProgressNode, e) = Treebars.fail_progress!(s, e)

# Disk-load reporting — set the substatus message to a human-readable
# "from disk: <size>" so big-file loads show up in the tree instead of
# stalling silently. Description stays as the property label; message
# is the running annotation Treebars renders alongside.
DynamicObjects._report_disk_load!(s::Treebars.ProgressNode, cache_path, size_bytes) =
    Treebars.update_progress!(s, "from disk: " * DynamicObjects._format_size(size_bytes))

DynamicObjects.fetchindex!(status::Treebars.ProgressNode, ip, indices...; fetch=Base.fetch, kwargs...) =
    DynamicObjects.fetchindex(ip, indices...; kwargs...) do rv, s
        Treebars.add_child!(status, s)
        fetch(rv)
    end

DynamicObjects.fetchproperty!(status::Treebars.ProgressNode, o, name::Symbol) =
    DynamicObjects.fetchproperty(o, name) do rv, s
        !isnothing(s) && Treebars.add_child!(status, s)
        Base.fetch(rv)
    end

end
