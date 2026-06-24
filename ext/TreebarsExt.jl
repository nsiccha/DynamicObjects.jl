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
    # Gate the label PER CALL SIGNATURE: `_is_property_documented` dispatches on
    # `args...` (one `true` method emitted per documented declaration), so a
    # property with multiple signatures resolves its OWN doc-presence here —
    # unlike the old `property_doc(metafirst(T, name))`, which keyed on type+name
    # only and always reflected the first declaration. The matching
    # `_property_description` override is likewise per-signature, so the rendered
    # label text is the right signature's docstring.
    desc = DynamicObjects._is_property_documented(o, Val(name), args...; kwargs...) ?
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
# in-memory cache — a hit. How we present a hit depends on whether the cached
# property is DOCUMENTED:
#
# - DOCUMENTED (`s.impl.description` non-empty, e.g. "Compute subject data"): a
#   SINGLE finished node directly under `status` — no wrapper, no extra level —
#   labelled "<original label> (cached)" and carrying `s`'s FROZEN original-compute
#   duration, so it renders e.g. "Compute subject data (cached) — done (13s)".
#   See `_cached_node!`.
# - UNDOCUMENTED (`s.impl.description` empty): nothing extra — attach `s` directly
#   (as the running path does); its empty description makes it a bare wrapper that
#   the renderer inlines away (no info-free node, no extra level). (If a disk-load
#   left a "from disk: …" message on `s`, it stays a meaningful message leaf — an
#   accepted edge.)
#
# While the computation is still running (`rv isa Task`), or there is no substatus
# (`s === nothing`), we attach `s` directly — the live sub-tree, unchanged.
function _attach_fetched!(status::Treebars.ProgressNode, rv, s)
    if !(rv isa Task) && !isnothing(s) && !isempty(s.impl.description)
        _cached_node!(status, s)           # documented in-memory hit → "(cached)" node
    else
        Treebars.add_child!(status, s)     # undocumented hit (inlines) / running / no substatus
    end
    nothing
end

# Get-or-create the single "<label> (cached)" node for documented cached node `s`
# under `status`. Idempotent and leak-free with no module-level state: the node is
# anchored to `s`'s IDENTITY via its `meta.cache_anchor`, so repeated hits / polls
# of the same cached value (web routes poll the tree repeatedly; `getstatus`
# returns the same shared `s` each time) reuse the existing node instead of piling
# up duplicates. Identity — not the description — is the key on purpose: distinct
# indexed keys can share a docstring-derived description, and they must NOT
# collapse onto one node.
#
# The node is built born-finished: a fresh `StateProgress` whose `started_at` /
# `finalized_at` are COPIED from `s.impl` (set before the `ProgressNode` is
# published into `status.children`, so a concurrent render never sees a half-built
# node) — this carries `s`'s frozen ORIGINAL-compute duration and reports as
# finished, identical impl end-state to a `finalize_progress!`'d node (no children
# to cascade, `propagates=false`, `transient=false`). `s` is removed from
# `status`'s direct children (a prior running phase may have attached it) so the
# hit shows ONLY this node, not also a bare `s`.
function _cached_node!(status::Treebars.ProgressNode, s::Treebars.ProgressNode)
    for c in status.children
        get(c.meta, :cache_anchor, nothing) === s && return c
    end
    si = s.impl
    impl = Treebars.StateProgress(; description=si.description * " (cached)")
    impl.running = false
    impl.started_at = si.started_at
    impl.finalized_at = si.finalized_at
    w = Treebars.ProgressNode(
        impl, (; propagates=false, transient=false, displayed=true, cache_anchor=s);
        parent=status,
    )
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
