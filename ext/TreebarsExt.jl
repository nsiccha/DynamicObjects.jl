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

# In-memory cache hit rendering (decision 1it9aqq, option c).
#
# `fetchindex`/`fetchproperty` follow the contract: the callback's `rv` is a
# `Task` while the computation is in flight, and the cached VALUE once it is done.
# So at callback entry `!(rv isa Task)` means the value was already in the
# in-memory cache — a hit. We present a hit as a labelled "read from memory cache"
# node whose only child is the cached+finished substatus `s` (which carries its
# own frozen original-compute duration). Both are finished, so Treebars hides them
# by default but lets the user toggle them on to inspect the cache read: the
# wrapper's own near-instant duration is the read time, `s`'s frozen duration is
# the original compute time. Treebars owns all "— done (…)" formatting.
#
# While the computation is still running (`rv isa Task`) we attach `s` directly —
# the live progress sub-tree, unchanged.
const _CACHE_READ_LABEL = "read from memory cache"

function _attach_fetched!(status::Treebars.ProgressNode, rv, s)
    if !(rv isa Task) && !isnothing(s)
        _cache_read_wrapper!(status, s)    # in-memory hit → wrap (idempotent)
    else
        Treebars.add_child!(status, s)     # running / no substatus (no-op on `nothing`)
    end
    nothing
end

# Get-or-create the single "read from memory cache" wrapper for cached node `s`
# under `status`. Idempotent and leak-free with no module-level state: reuse an
# existing wrapper (matched by label + membership of `s`) so repeated hits / polls
# of the same cached value never pile up duplicate wrappers. `s` is re-homed under
# the wrapper (removed from `status`'s direct children, where a prior running phase
# may have attached it) so it renders only as the wrapper's sole child, not also a
# sibling. Non-transient so finalize freezes its duration without detaching it.
function _cache_read_wrapper!(status::Treebars.ProgressNode, s::Treebars.ProgressNode)
    for c in status.children
        if c.impl isa Treebars.StateProgress && c.impl.description == _CACHE_READ_LABEL && s in c.children
            return c
        end
    end
    w = Treebars.initialize_progress!(status; description=_CACHE_READ_LABEL, transient=false)
    Treebars.add_child!(w, s)
    Treebars.finalize_progress!(w)
    Base.delete!(status.children, s)
    w
end

DynamicObjects.fetchindex!(status::Treebars.ProgressNode, ip, indices...; fetch=Base.fetch, kwargs...) =
    DynamicObjects.fetchindex(ip, indices...; kwargs...) do rv, s
        _attach_fetched!(status, rv, s)
        fetch(rv)
    end

DynamicObjects.fetchproperty!(status::Treebars.ProgressNode, o, name::Symbol) =
    DynamicObjects.fetchproperty(o, name) do rv, s
        _attach_fetched!(status, rv, s)
        Base.fetch(rv)
    end

end
