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

# In-memory cache hit rendering (decision 1it9aqq → reworked; supersedes the
# generic "read from memory cache" wrapper).
#
# `fetchindex`/`fetchproperty` follow the contract: the callback's `rv` is a
# `Task` while the computation is in flight, and the cached VALUE once it is done.
# So at callback entry `!(rv isa Task)` means the value was already in the
# in-memory cache — a hit. On a DOCUMENTED in-memory hit we KEEP the original
# node `s` and its ENTIRE sub-step subtree intact, and swap ONLY the subtree
# ROOT's LABEL — appending " (cached)" in place — so it renders e.g.
# "Compute subject data (cached) — done (13s)" (carrying `s`'s own frozen
# ORIGINAL-compute duration) with all of `s`'s sub-steps rendering beneath it,
# unchanged.
#
# In-place relabel (vs. a new born-finished root with the children re-homed) is
# the correct mechanism here: `s` is SHARED per cache key (`getstatus` returns
# the same node to every status tree / poll). Re-homing `s`'s children into a new
# node would EMPTY `s.children`, so a second status tree hitting the same shared
# `s` would build a CHILDLESS "(cached)" node — exactly the collapsed-subtree bug
# this corrects. Relabeling `s` itself keeps the one shared subtree intact for all
# trees, preserves children's (immutable) parent pointers, and mirrors
# `_report_disk_load!` above, which already mutates the shared `s`'s display state
# in place.
#
# UNDOCUMENTED hit (`s.impl.description` empty): no relabel — `s` stays a bare
# wrapper the renderer inlines away. Running (`rv isa Task`) and no-substatus
# (`s === nothing`): no relabel. All four paths then attach `s` via `add_child!`
# (idempotent on the `ThreadsafeSet`; no-op on `nothing`).
const _CACHED_SUFFIX = " (cached)"

function _attach_fetched!(status::Treebars.ProgressNode, rv, s)
    if !(rv isa Task) && !isnothing(s) && !isempty(s.impl.description)
        _mark_cached!(s)                   # documented in-memory hit → relabel root in place
    end
    Treebars.add_child!(status, s)         # keep/attach the subtree root (no-op on `nothing`)
    nothing
end

# Append the "(cached)" suffix to `s`'s description exactly once. Idempotent under
# repeat polls (web routes poll the tree repeatedly and re-fetch the same shared
# `s`) via the `endswith` guard, and locked on `s.impl.lock` so concurrent first
# hits cannot double-append. `s` is finished/frozen on a hit, so the visible
# duration stays the frozen original-compute time.
function _mark_cached!(s::Treebars.ProgressNode)
    sp = s.impl
    lock(sp.lock) do
        endswith(sp.description, _CACHED_SUFFIX) || (sp.description *= _CACHED_SUFFIX)
    end
    nothing
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
