# ---------- print_structure ----------------------------------------------------
# Programmatic rendering of a DO/HTMXO type's structure, suitable for spotting
# IPs, inline children, routes, @param decls, and constructor fields at a glance.
# Walks `meta(T)` for properties + `_nested_struct_type(T, Val(name))` for inline
# children. HTMXO-specific introspection (`_param_names`, route macro tags) is
# read defensively so DO-only types print cleanly too.

const _PRINT_STRUCT_ROUTE_MACROS = Set([
    Symbol("@get"), Symbol("@post"), Symbol("@put"),
    Symbol("@patch"), Symbol("@delete"), Symbol("@ws"),
])

# Skip auto-generated and DO-internal property names. Dunder names
# (`__self__`, `__parent__`, `__status__`, …) are normally hidden, but
# `prop::T = rhs` registrations on a dunder name (e.g. `__appdata__::AppData`)
# represent a real user-declared nested DO subtree the user wants to see —
# the registered `_nested_struct_type` is the signal.
_print_struct_skip(::Type{T}, name::Symbol) where {T} = begin
    s = String(name)
    is_dunder = startswith(s, "__") && endswith(s, "__")
    is_dunder && _walk_nested_type(T, name) !== nothing && return false
    is_dunder ||
        startswith(s, "_tuple_") ||
        name === :__hash_fields__ ||
        name === :__cache_path__ ||
        name === :__hash__ ||
        name === :cache
end

# A property whose RHS is just `__parent__.something` — auto-forwarded into an
# inline child by the macro. Not a user-authored property of the child.
_print_struct_is_forwarded(rhs) =
    Meta.isexpr(rhs, :.) && length(rhs.args) == 2 &&
    rhs.args[1] === :__parent__ && rhs.args[2] isa QuoteNode

# Compact one-line render of a default expression — chops noisy whitespace.
_print_struct_short(x) = replace(string(x), r"\s+" => " ")

# Defensive HTMXO `_param_names(T)` lookup — the function lives in HTMXObjects;
# DO-only types don't have it. Empty tuple if the binding isn't loaded.
function _print_struct_param_names(T::Type)
    htmxo = get(Base.loaded_modules,
        Base.PkgId(Base.UUID("b12ef442-5798-4353-80f3-9562b03a0cb6"),
                   "HTMXObjects"),
        nothing)
    htmxo === nothing && return ()
    isdefined(htmxo, :_param_names) || return ()
    try htmxo._param_names(T) catch; () end
end

# --- IP arg worst-case dependency bound ---------------------------------------
# For each IP, find its call sites in the DO tree. Each caller is some property
# of some type. Take the union of every caller's *static identity scope* — its
# own IP positional args, plus the ancestor types' constructor fields and
# `@param` names walking up to root. That set is an honest *upper bound*: the
# IP arg's value can be derived from no more than these names (modulo dynamic
# inputs from outside the tree, like HTTP request bodies).
#
# Static and cheap — no AST walking of caller bodies, no dataflow, no
# substitution. The annotation reads "at most depends on {names}", which is
# what `print_structure` advertises.

# Extract bare positional arg names from an `info.indices` tuple. Drops kwargs
# (the `:parameters` slot) and unwraps `name::T` annotations.
function _ip_positional_args(indices)
    names = Symbol[]
    for idx in indices
        Meta.isexpr(idx, :parameters) && continue
        n = Meta.isexpr(idx, :(::)) ? idx.args[1] : idx
        n isa Symbol && push!(names, n)
    end
    names
end

# Reachable types from a root via _nested_struct_type. Used to bound the
# call-site search so we don't chase outside the DO tree print_structure
# is rendering.
function _all_types_in_tree(root::Type)
    seen = Set{Type}([root])
    queue = Type[root]
    while !isempty(queue)
        T = popfirst!(queue)
        props = try meta(T) catch; nothing end
        props === nothing && continue
        seen_names = Set{Symbol}()
        for (name, _) in props
            name in seen_names && continue
            push!(seen_names, name)
            nested = _walk_nested_type(T, name)
            nested === nothing && continue
            nested in seen && continue
            push!(seen, nested)
            push!(queue, nested)
        end
    end
    seen
end

# Map child_type → (parent_type, prop_name_in_parent) — built by walking the
# tree from the root via `_nested_struct_type`. Lets us climb the type chain
# for static-scope lookup. The root has no entry in this map.
function _build_parent_map(root::Type)
    parents = Dict{Type, Tuple{Type, Symbol}}()
    seen = Set{Type}([root])
    queue = Type[root]
    while !isempty(queue)
        T = popfirst!(queue)
        props = try meta(T) catch; nothing end
        props === nothing && continue
        seen_names = Set{Symbol}()
        for (name, _) in props
            name in seen_names && continue
            push!(seen_names, name)
            nested = _walk_nested_type(T, name)
            nested === nothing && continue
            nested in seen && continue
            push!(seen, nested)
            push!(queue, nested)
            parents[nested] = (T, name)
        end
    end
    parents
end

# Names visible as "root identity" at a property body inside type T:
# constructor fields and `@param` names, walking parent_map up to root. If
# `T` is reached via an IP property of its parent, that IP's positional arg
# names are also in scope.
function _enclosing_scope(T::Type, parents)
    names = Set{Symbol}()
    cur = T
    while true
        for f in fieldnames(cur)
            f === :cache && continue
            s = String(f)
            (startswith(s, "__") && endswith(s, "__")) && continue
            push!(names, f)
        end
        for p in _print_struct_param_names(cur)
            push!(names, p)
        end
        haskey(parents, cur) || break
        parent_T, parent_prop = parents[cur]
        try
            # `metafirst` is fine: scope walk only needs one parent IP's positional
            # args; if duplicate declarations ever exist they share the IP signature.
            info = metafirst(parent_T, parent_prop)
            if info !== nothing
                for a in _ip_positional_args(info.indices)
                    push!(names, a)
                end
            end
        catch
        end
        cur = parent_T
    end
    names
end

# Dot-chain leftmost Symbol — `render.stan.code` → `:render`; bare `code` →
# `:code`. `nothing` for non-symbol roots.
function _dot_chain_root(expr)
    expr isa Symbol && return expr
    Meta.isexpr(expr, :., 2) && return _dot_chain_root(expr.args[1])
    nothing
end

# Conservative call-site detector: matches `target(…)` and `parent.target(…)`
# only when the leftmost symbol resolves to a property of the caller's type
# or one of the macro-injected names. Excludes unrelated namespaces (`h.code`,
# `Base.length`, …) that happen to share a property name.
function _has_call_to(expr, target::Symbol, cprops)
    expr isa Expr || return false
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        if callee === target
            cprops !== nothing && _cprops_has(cprops, target) && return true
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            if root !== nothing &&
               (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                (cprops !== nothing && _cprops_has(cprops, root)))
                return true
            end
        end
    end
    for a in expr.args
        _has_call_to(a, target, cprops) && return true
    end
    false
end

# Scope of a caller property: enclosing static scope of its type, plus its own
# IP positional args (so `name` from `@get stage(name)` flows through into the
# bound for any IP called from inside `stage`'s body).
function _caller_scope(caller_T::Type, caller_prop::Symbol, parents)
    names = _enclosing_scope(caller_T, parents)
    info = try metafirst(caller_T, caller_prop) catch; nothing end
    if info !== nothing
        for a in _ip_positional_args(info.indices)
            push!(names, a)
        end
    end
    names
end

# Raw worst-case bound — the union of callers' static identity scopes,
# possibly containing intermediate IP-arg names (like `bundle` from an
# enclosing IP). `_print_struct_worst_case` expands these to root identities.
function _raw_worst_case(types_in_tree, parents, T::Type, prop_name::Symbol, info)
    isempty(_ip_positional_args(info.indices)) && return nothing
    callers = Set{Tuple{Type,Symbol}}()
    for U in types_in_tree
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (uname, uinfo) in uprops
            uinfo.rhs === nothing && continue
            (U === T && uname === prop_name) && continue
            _has_call_to(uinfo.rhs, prop_name, uprops) || continue
            push!(callers, (U, uname))
        end
    end
    isempty(callers) && return (:none,)
    bound = Set{Symbol}()
    for (cT, cp) in callers
        union!(bound, _caller_scope(cT, cp, parents))
    end
    (:bound, sort!(collect(bound)))
end

# Expand a single name to its root identities (@param / field / unbounded
# IP arg). If the name is itself an IP arg with an in-tree caller bound,
# recurse into that bound. Cycle protection via `visited`.
function _expand_name!(out::Set{Symbol}, name::Symbol,
                      types_in_tree, parents, visited::Set{Symbol})
    name in visited && return
    push!(visited, name)
    # Root identity: @param or constructor field anywhere in the tree.
    for T in types_in_tree
        for f in fieldnames(T)
            f === name && (push!(out, name); return)
        end
        for p in _print_struct_param_names(T)
            p === name && (push!(out, name); return)
        end
    end
    # IP arg: replace with its IP's bound (recursively).
    for T in types_in_tree
        props = try meta(T) catch; nothing end
        props === nothing && continue
        for (pn, pinfo) in props
            for a in _ip_positional_args(pinfo.indices)
                a === name || continue
                raw = _raw_worst_case(types_in_tree, parents, T, pn, pinfo)
                if raw !== nothing && raw[1] === :bound
                    for n in raw[2]
                        _expand_name!(out, n, types_in_tree, parents, visited)
                    end
                else
                    # IP has no in-tree callers — treat as root.
                    push!(out, name)
                end
                return
            end
        end
    end
    # Unrecognized — keep as-is.
    push!(out, name)
end

# Public worst-case bound: returns the EXPANDED form. Every name in the
# result is a root identity (@param, field, or IP arg of an unbounded IP);
# intermediate IP-arg names are unfolded to their own bounds.
# Memoized expanded worst-case bound. `analyze_structure` / `structure(T)`
# invoke this from multiple call sites for the same (T, prop) — bound-group
# precompute, hierarchical-placement check, and render annotations. Without
# caching we re-walk the whole `types_in_tree × props_per_type` cross product
# several times.
#
# Cache is **per-call**, passed explicitly. No global state — concurrent
# requests get their own cache so there are no races on `setindex!` / shared
# entries. The default-arg form creates a fresh dict for callers that don't
# care about cross-call reuse; hot callers inside `analyze_structure` /
# `_build_structure` thread a single dict through to amortize the work.
const _WCCache = IdDict{Tuple{Type,Symbol}, Any}

_print_struct_worst_case(types_in_tree, parents, T::Type, prop_name::Symbol, info) =
    _print_struct_worst_case(types_in_tree, parents, T, prop_name, info, _WCCache())

function _print_struct_worst_case(types_in_tree, parents, T::Type,
                                  prop_name::Symbol, info, cache::_WCCache)
    key = (T, prop_name)
    haskey(cache, key) && return cache[key]
    raw = _raw_worst_case(types_in_tree, parents, T, prop_name, info)
    result = if raw === nothing
        nothing
    elseif raw[1] === :none
        raw
    else
        expanded = Set{Symbol}()
        for n in raw[2]
            _expand_name!(expanded, n, types_in_tree, parents, Set{Symbol}())
        end
        (:bound, sort!(collect(expanded)))
    end
    cache[key] = result
    result
end

# --- Identity coloring --------------------------------------------------------
# Each "scope identifier" (constructor field, @param name, IP positional arg)
# is colored deterministically by its name so the same name reads as the same
# color everywhere it appears — in `fields:` / `@param:` lists, in IP
# signatures, and in worst-case bound sets. Lets you visually trace bonds:
# spot `formula` once, then scan for matching color anywhere else.

# 32 vivid full-spectrum hues — saturation high enough that adjacent
# identities are easy to tell apart at a glance. Identity coloring is
# applied as an underline-only mark (`Semantic{:underlined}`), not as
# foreground text color, so bright/saturated values are fine — the text
# itself stays at default contrast. Stored as `#rrggbb` so they drop into
# CSS directly and need only a hex→RGB parse for the terminal's truecolor
# escape.
const _IDENT_PALETTE = (
    "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf",
    "#aec7e8", "#ffbb78", "#98df8a", "#ff9896", "#c5b0d5",
    "#c49c94", "#f7b6d2", "#c7c7c7", "#dbdb8d", "#9edae5",
    "#393b79", "#637939", "#8c6d31", "#843c39", "#7b4173",
    "#5254a3", "#8ca252", "#bd9e39", "#ad494a", "#a55194",
    "#6b6ecf", "#cedb9c",
)

# Color-by-bound: each name in the tree maps to a *fingerprint* — its upstream
# worst-case bound set if it's an IP positional arg, or its own name (treated
# as a root identity) if it's a @param / fixed field / IP arg without callers.
# Two names with the same fingerprint render in the same color, so two args
# named differently but with identical upstream identity slices (`bundle1` /
# `bundle2`) still bound visually.
#
# The fingerprint approach over-groups in the worst case (two unrelated args
# that happen to share the same upstream scope collide), but matches the
# "same identity = same color" intent the static analyzer can actually
# justify, with no dataflow cost.
function _build_color_map(root::Type)
    types_in_tree = _all_types_in_tree(root)
    parent_map = _build_parent_map(root)
    # Pass 1 — collect all names that exist in the tree and assign each its
    # fingerprint. Root identities (@params, fixed fields) fingerprint as
    # singletons; IP args with a tightenable bound fingerprint as the bound.
    fingerprint = Dict{Symbol, Any}()
    function set_root!(n::Symbol)
        # Root identities take precedence over IP-arg-bound fingerprints when
        # the same name appears in both roles — a @param IS its own identity.
        fingerprint[n] = (:name, n)
    end
    visited = Set{Type}()
    function visit_type(T)
        T in visited && return
        push!(visited, T)
        for f in fieldnames(T)
            f === :cache && continue
            s = String(f); (startswith(s, "__") && endswith(s, "__")) && continue
            set_root!(f)
        end
        for p in _print_struct_param_names(T); set_root!(p); end
        props = try meta(T) catch; nothing end
        props === nothing && return
        # Color fingerprint cares about per-name identity; iterate the unique
        # names in the order `meta(T)` declared them (sorted for stable color
        # assignment), then look up the first matching info.
        seen_names = Set{Symbol}()
        unique_names = Symbol[]
        for (n, _) in props
            n in seen_names && continue
            push!(seen_names, n); push!(unique_names, n)
        end
        for name in sort!(unique_names)
            _print_struct_skip(T, name) && continue
            info = metafirst(T, name)
            args = _ip_positional_args(info.indices)
            if !isempty(args)
                wc = _print_struct_worst_case(types_in_tree, parent_map, T, name, info)
                fp = (wc !== nothing && wc[1] === :bound) ?
                     (:bound, Tuple(wc[2])) : nothing
                for a in args
                    haskey(fingerprint, a) && continue   # @param/field wins
                    fingerprint[a] = fp === nothing ? (:name, a) : fp
                end
            end
            nested = _walk_nested_type(T, name)
            nested === nothing || visit_type(nested)
        end
    end
    visit_type(root)
    # Pass 2 — assign each unique fingerprint a hex color in stable order
    # (sorted by name of the first member to encounter it).
    fp_to_idx = Dict{Any, Int}()
    name_to_color = Dict{Symbol, String}()
    for n in sort!(collect(keys(fingerprint)))
        fp = fingerprint[n]
        idx = get!(fp_to_idx, fp, length(fp_to_idx) + 1)
        name_to_color[n] = _IDENT_PALETTE[mod1(idx, length(_IDENT_PALETTE))]
    end
    name_to_color
end

# --- Structured representation ------------------------------------------------
# A minimal HTML-tag-shaped DOM. `Tag` is a Symbol type parameter (Val-like,
# so dispatch happens at compile time); `content` is whatever the tag holds
# (string, single node, vector of nodes, or nothing); `attributes` is a
# NamedTuple of HTML-style attrs (`class="…"`, `color=…`, etc.).
#
# Generic HTML rendering is `<tag attrs>content</tag>` — overrides per tag
# when the default isn't right. Markdown / terminal fall back to "just emit
# the content" with overrides for the tags that actually carry meaning in
# those formats (`:strong` → ANSI bold / `**…**`; etc.).

abstract type AbstractNode end

struct Node{Tag, C<:Tuple, A<:NamedTuple} <: AbstractNode
    content::C
    attributes::A
    function Node(tag::Symbol, args...; kwargs...)
        a = (;kwargs...)
        new{tag, typeof(args), typeof(a)}(args, a)
    end
end

# `Semantic` mirrors `Node`'s shape but is NOT an HTML element — it carries
# our domain concepts (`:line`, `:section`, `:colored`, `:lint`) that have
# format-specific renderings but no faithful HTML tag. The split means the
# generic HTML fallback for `Node` can never accidentally produce invalid
# `<line>` / `<section>` markup for a Semantic tag.
struct Semantic{Tag, C<:Tuple, A<:NamedTuple} <: AbstractNode
    content::C
    attributes::A
    function Semantic(tag::Symbol, args...; kwargs...)
        a = (;kwargs...)
        new{tag, typeof(args), typeof(a)}(args, a)
    end
end

# Cobweb-style builders: `h.tag(args...; attrs...)` for HTML elements;
# `s.tag(args...; attrs...)` for Semantic nodes. Each `getproperty` overload
# turns any tag-name access into a constructor closure.
function h end
Base.getproperty(::typeof(h), tag::Symbol) =
    (args...; kwargs...) -> Node(tag, args...; kwargs...)
Base.propertynames(::typeof(h)) = ()

function sem end
Base.getproperty(::typeof(sem), tag::Symbol) =
    (args...; kwargs...) -> Semantic(tag, args...; kwargs...)
Base.propertynames(::typeof(sem)) = ()

# === Builder ==================================================================

# Build a single styled token from a string + style flags. Wraps innermost-out
# so the on-the-wire nesting matches CSS-style cascade ordering: span > u >
# strong > em > text.
function _tok(s::AbstractString; bold=false, italic=false, underline=false, color=nothing)
    n = String(s)
    italic    && (n = h.em(n))
    bold      && (n = h.strong(n))
    underline && (n = h.u(n))
    color === nothing || (n = sem.underlined(n; color))
    n
end
_tok_ident(name::Symbol, color_map) =
    _tok(string(name); color=get(color_map, name, nothing))

function _build_sig_arg(a, color_map)
    # Use Any[] — recursive calls mix element types (`:colored` from
    # `_tok_ident`, plain Strings from `_tok` with no styling, `:em` from
    # `_tok(...; italic=true)`), and a typed literal would lock to whichever
    # came first.
    if a isa Symbol
        Any[_tok_ident(a, color_map)]
    elseif Meta.isexpr(a, :kw)
        nodes = _build_sig_arg(a.args[1], color_map)
        push!(nodes, _tok("=" * _print_struct_short(a.args[2]); italic=true))
        nodes
    elseif Meta.isexpr(a, :(::))
        if length(a.args) == 1
            Any[_tok("::" * string(a.args[1]); italic=true)]
        else
            nodes = _build_sig_arg(a.args[1], color_map)
            push!(nodes, _tok("::" * _print_struct_short(a.args[2]); italic=true))
            nodes
        end
    else
        Any[_tok(_print_struct_short(a))]
    end
end

function _signature_nodes(indices, color_map)
    isempty(indices) && return Any[]
    out = Any[_tok("(")]
    pos = []; kw = []
    for idx in indices
        Meta.isexpr(idx, :parameters) ? append!(kw, idx.args) : push!(pos, idx)
    end
    for (i, a) in enumerate(pos)
        i == 1 || push!(out, _tok(", "))
        append!(out, _build_sig_arg(a, color_map))
    end
    if !isempty(kw)
        push!(out, _tok("; "))
        for (i, a) in enumerate(kw)
            i == 1 || push!(out, _tok(", "))
            append!(out, _build_sig_arg(a, color_map))
        end
    end
    push!(out, _tok(")"))
    out
end

function _dep_nodes(dep, color_map)
    dep === nothing && return Any[]
    out = Any[_tok("  [")]
    if dep[1] === :none
        push!(out, _tok("no callers in tree"; italic=true))
    else
        push!(out, _tok("⊆ {"))
        for (i, n) in enumerate(dep[2])
            i == 1 || push!(out, _tok(", "))
            push!(out, _tok_ident(n, color_map))
        end
        push!(out, _tok("}"))
    end
    push!(out, _tok("]"))
    out
end

function _prop_nodes(route_tag::String, cached::Bool, name::Symbol,
                     indices, dep, color_map)
    out = Any[]
    isempty(route_tag) || push!(out, _tok(route_tag; bold=true, italic=true))
    cached && push!(out, _tok("@cached "; bold=true, italic=true))
    push!(out, _tok(string(name)))
    append!(out, _signature_nodes(indices, color_map))
    append!(out, _dep_nodes(dep, color_map))
    out
end

# Build the lint index — `Dict{(Type, Union{Symbol,Nothing}), Vector{LintMessage}}` —
# from a flat lint list. `_build_section` looks up `(T, prop_name)` for IP-level
# annotations and `(T, nothing)` for struct-level ones.
function _build_lint_index(msgs::Vector{LintMessage})
    idx = Dict{Tuple{Type,Union{Symbol,Nothing}}, Vector{LintMessage}}()
    for m in msgs
        push!(get!(idx, (m.type, m.prop), LintMessage[]), m)
    end
    idx
end

# Build a `Semantic{:lint}` node for one LintMessage. The severity attribute
# drives format-specific rendering (color/icon).
_lint_node(msg::LintMessage) =
    sem.lint(msg.short; severity=msg.severity)

function _build_section(T::Type, header;
                        max_depth, types_in_tree, parent_map, color_map, lint_index, visited)
    header === nothing && (header = sem.line(_tok(string(nameof(T)); bold=true)))
    body = Any[]
    if T in visited
        push!(body, sem.line(_tok("(cycle)"; italic=true)))
        return sem.section(body...; header)
    end
    push!(visited, T)

    # Struct-level lints (prop=nothing) emitted as their own lines after the header.
    for msg in get(lint_index, (T, nothing), LintMessage[])
        push!(body, sem.line(_lint_node(msg)))
    end

    fixed = filter(n -> n !== :cache, collect(fieldnames(T)))
    if !isempty(fixed)
        toks = Any[_tok("fields: "; italic=true)]
        for (i, f) in enumerate(fixed)
            i == 1 || push!(toks, _tok(", "))
            push!(toks, _tok_ident(f, color_map))
        end
        push!(body, sem.line(toks...))
    end

    params = _print_struct_param_names(T)
    if !isempty(params)
        toks = Any[_tok("@param: "; italic=true)]
        for (i, p) in enumerate(params)
            i == 1 || push!(toks, _tok(", "))
            push!(toks, _tok_ident(p, color_map))
        end
        push!(body, sem.line(toks...))
    end

    props = try meta(T) catch; nothing end
    if props !== nothing
        # Render every declaration in declaration order — duplicates are kept,
        # since each yields its own `compute_property` method and deserves its
        # own line. Sorting by name groups duplicates together; secondary key
        # is the original index for a stable order within a group.
        pairs_with_idx = [(i, name, info) for (i, (name, info)) in enumerate(props)]
        sort!(pairs_with_idx; by=t -> (t[2], t[1]))
        for (_, name, info) in pairs_with_idx
            _print_struct_skip(T, name) && continue
            info.rhs === nothing && continue
            _print_struct_is_forwarded(info.rhs) && continue

            nested = _walk_nested_type(T, name)
            route_tag = ""
            for m in info.macros
                if m in _PRINT_STRUCT_ROUTE_MACROS
                    route_tag = String(m) * " "
                    break
                end
            end
            cached = Symbol("@cached") in info.macros
            dep = info.indexed ?
                _print_struct_worst_case(types_in_tree, parent_map, T, name, info) :
                nothing
            nodes = _prop_nodes(route_tag, cached, name, info.indices, dep, color_map)
            prop_lints = get(lint_index, (T, name), LintMessage[])

            if nested !== nothing && max_depth > 0
                push!(nodes, _tok(" = "))
                push!(nodes, _tok(string(nameof(nested)); bold=true))
                nested_sec = _build_section(nested, sem.line(nodes...);
                    max_depth=max_depth-1, types_in_tree, parent_map, color_map,
                    lint_index, visited=copy(visited))
                push!(body, nested_sec)
            else
                push!(body, sem.line(nodes...))
            end
            # One line per lint message, after the IP's line/section.
            for msg in prop_lints
                push!(body, sem.line(_lint_node(msg)))
            end
        end
    end
    sem.section(body...; header)
end

function _build_structure(T::Type;
                          max_depth=typemax(Int),
                          types_in_tree=_all_types_in_tree(T),
                          parent_map=_build_parent_map(T),
                          color_map=_build_color_map(T),
                          lint_index=_build_lint_index(analyze_structure(T)))
    sec = _build_section(T, nothing; max_depth, types_in_tree, parent_map, color_map,
                         lint_index, visited=Set{Type}())
    h.pre(sec; class="do-structure")
end

# === Rendering via Base.show / MIME ===========================================

# Parse `#rrggbb` → (R, G, B). Used for the terminal's truecolor escape.
function _hex_to_rgb(hex::AbstractString)
    @assert length(hex) == 7 && hex[1] == '#' "expected #rrggbb, got $hex"
    parse(Int, hex[2:3], base=16),
    parse(Int, hex[4:5], base=16),
    parse(Int, hex[6:7], base=16)
end
_html_escape(io::IO, s::AbstractString) = replace(io, s,
    '&'  => "&amp;",
    '<'  => "&lt;",
    '>'  => "&gt;",
    '"'  => "&quot;",
    '\'' => "&#39;")
_html_escape(io::IO, x) = _html_escape(io, string(x))

# --- Generic content emission (used by all formats) ---
# Content is always a Tuple of items — typically Strings (text leaves) or
# Nodes (children). Iterate and dispatch each via `_show_one`.
_show_content(io, m, content::Tuple) = for c in content; _show_one(io, m, c) end
_show_one(io, m, n::AbstractNode) = show(io, m, n)
_show_one(io, ::MIME"text/html", s::AbstractString) = _html_escape(io, s)
_show_one(io, m, s::AbstractString) = print(io, s)

# --- Show dispatch via `_show_node` ----------------------------------------
# Every Base.show on an AbstractNode delegates to `_show_node`. Inside
# `_show_node` there are no Base stdlib methods to disambiguate against, so
# per-tag overrides on generic MIME work without the per-(MIME, Tag) bloat
# we'd otherwise need to break Base's text/plain ambiguity.
Base.show(io::IO, m::MIME"text/plain",    n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, m::MIME"text/markdown", n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, m::MIME"text/html",     n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, n::AbstractNode) = _show_node(io, MIME"text/plain"(), n)

# --- Defaults ---

# Node text/plain & text/markdown: emit content, no wrapping.
_show_node(io::IO, m::MIME"text/plain",    n::Node) = _show_content(io, m, n.content)
_show_node(io::IO, m::MIME"text/markdown", n::Node) = _show_content(io, m, n.content)

# Node text/html: <tag attrs>content</tag> — the only format that needs the
# tag in the output.
function _show_node(io::IO, m::MIME"text/html", n::Node{Tag}) where {Tag}
    print(io, "<", Tag)
    for (k, v) in pairs(n.attributes)
        v === nothing && continue
        print(io, " ", k, "=\"")
        _html_escape(io, v)
        print(io, "\"")
    end
    print(io, ">")
    _show_content(io, m, n.content)
    print(io, "</", Tag, ">")
end

# Semantic default: emit content with no wrapping in every format. Per-tag
# overrides on `_show_node(io, ::MIME, ::Semantic{:tag})` add format-specific
# behavior; thanks to the `_show_node` indirection, one method covers all
# three MIMEs without ambiguity.
_show_node(io::IO, m::MIME, n::Semantic) = _show_content(io, m, n.content)

# --- Tag-specific overrides ------------------------------------------------

# Inline style wrappers for terminal — emit ANSI start/end around content.
function _ansi_wrap(io, m, n, on, off)
    color = get(io, :color, false)
    color && print(io, on)
    _show_content(io, m, n.content)
    color && print(io, off)
end
_show_node(io::IO, m::MIME"text/plain", n::Node{:strong}) = _ansi_wrap(io, m, n, "\e[1m", "\e[22m")
_show_node(io::IO, m::MIME"text/plain", n::Node{:em})     = _ansi_wrap(io, m, n, "\e[3m", "\e[23m")
_show_node(io::IO, m::MIME"text/plain", n::Node{:u})      = _ansi_wrap(io, m, n, "\e[4m", "\e[24m")

function _show_node(io::IO, m::MIME"text/markdown", n::Node{:strong})
    print(io, "**"); _show_content(io, m, n.content); print(io, "**")
end
function _show_node(io::IO, m::MIME"text/markdown", n::Node{:em})
    print(io, "*"); _show_content(io, m, n.content); print(io, "*")
end

# `:colored` (Semantic) — content with the foreground in the given color.
# Used for emphasis where the whole token should pop (lint warnings).
function _show_node(io::IO, m::MIME"text/plain", n::Semantic{:colored})
    r, g, b = _hex_to_rgb(n.attributes.color)
    _ansi_wrap(io, m, n, "\e[38;2;$r;$g;$(b)m", "\e[39m")
end
function _show_node(io::IO, m::MIME"text/html", n::Semantic{:colored})
    show(io, m, Node(:span, n.content...; style="color:$(n.attributes.color)"))
end

# `:underlined` (Semantic) — default-color text with a thick colored
# underline. Used for bound identities so the bound hue marks identity
# without dominating the text. Terminal: ANSI `\e[4m` (underline on) +
# `\e[58;2;R;G;Bm` (truecolor underline color). HTML: `text-decoration:
# underline` + `text-decoration-color` + `text-decoration-thickness:2px`.
function _show_node(io::IO, m::MIME"text/plain", n::Semantic{:underlined})
    r, g, b = _hex_to_rgb(n.attributes.color)
    _ansi_wrap(io, m, n, "\e[4m\e[58;2;$r;$g;$(b)m", "\e[59m\e[24m")
end
function _show_node(io::IO, m::MIME"text/html", n::Semantic{:underlined})
    show(io, m, Node(:span, n.content...;
        style="text-decoration:underline; text-decoration-color:$(n.attributes.color); text-decoration-thickness:2px; text-underline-offset:2px"))
end

# `:line` (Semantic) — indent + content + newline. One method covers all
# three formats thanks to the `_show_node` indirection.
function _show_node(io::IO, m::MIME, n::Semantic{:line})
    print(io, "  "^get(io, :do_struct_depth, 0))
    _show_content(io, m, n.content)
    println(io)
end

# `:section` (Semantic) — render header at current depth, content one level
# deeper.
function _show_node(io::IO, m::MIME, n::Semantic{:section})
    hdr = get(n.attributes, :header, nothing)
    hdr === nothing || show(io, m, hdr)
    depth = get(io, :do_struct_depth, 0)
    body_io = IOContext(io, :do_struct_depth => hdr === nothing ? depth : depth + 1)
    _show_content(body_io, m, n.content)
end

# `:pre` (Node, real HTML element) — markdown fences. Terminal and HTML use
# the generic Node defaults (just-content / `<pre class=…>…</pre>`).
function _show_node(io::IO, m::MIME"text/markdown", n::Node{:pre})
    println(io, "```")
    _show_content(io, m, n.content)
    println(io, "```")
end

# `:lint` (Semantic) — bold + colored severity icon + message. Composes the
# existing `Node{:strong}` (bold) with `Semantic{:colored}` (bound palette
# color machinery) — no per-format rendering code here. Colors are muted
# brick / ochre that read on light and dark backgrounds.
function _show_node(io::IO, m::MIME, n::Semantic{:lint})
    icon  = n.attributes.severity === :error ? "✗"       : "⚠"
    color = n.attributes.severity === :error ? "#922b21" : "#b7791f"
    show(io, m, sem.colored(h.strong(icon, " ", n.content...); color))
end

# === Public API ===============================================================

"""    structure(T::Type; max_depth=typemax(Int)) -> Node{:pre}

Build a target-agnostic DOM-ish representation of `T`'s DO/HTMXO tree. The
root is a `Node{:pre}` so it renders as `<pre class="do-structure">…</pre>`
in HTML, fenced ` ``` ` blocks in markdown, and bare indented text in the
terminal. `display(s)` picks the right MIME for the active display.
"""
structure(T::Type; max_depth::Int=typemax(Int)) =
    _build_structure(T; max_depth)

"""    print_structure([io::IO=stdout,] T::Type; max_depth=typemax(Int))

Convenience: `show(io, MIME"text/plain"(), structure(T))`. For markdown or
HTML output, build the structure with `structure(T)` and `show` it under
the desired MIME.
"""
print_structure(T::Type; kwargs...) = print_structure(stdout, T; kwargs...)
print_structure(io::IO, T::Type; max_depth::Int=typemax(Int)) =
    show(io, MIME"text/plain"(), structure(T; max_depth))

"""    tree_children_map(root::Type) -> Dict{Type, Vector{Tuple{Symbol, Type}}}

Build a `parent → [(prop_name, child_type), …]` map for every DO/HTMXO
type reachable from `root`. Children are sorted alphabetically by `prop_name`.
The inverse of `_build_parent_map`. Pure data — no rendering.
"""
function tree_children_map(root::Type)
    parent_map = _build_parent_map(root)
    children = Dict{Type, Vector{Tuple{Symbol, Type}}}()
    for (child, (parent, prop)) in parent_map
        push!(get!(children, parent, Tuple{Symbol, Type}[]), (prop, child))
    end
    for v in values(children)
        sort!(v; by = p -> string(p[1]))
    end
    children
end

"""    lint_index(root::Type) -> Dict{Type, NamedTuple{(:warns, :errors, :msgs), …}}

Group `analyze_structure(root)` output by `LintMessage.type`. Each entry
carries warn/error counts and the underlying messages. Returns an empty
Dict if `analyze_structure` throws (e.g. partially-defined tree).
"""
function lint_index(root::Type)
    msgs = try analyze_structure(root) catch; LintMessage[] end
    out = Dict{Type, NamedTuple{(:warns, :errors, :msgs), Tuple{Int, Int, Vector{LintMessage}}}}()
    for m in msgs
        e = get!(() -> (warns=0, errors=0, msgs=LintMessage[]), out, m.type)
        push!(e.msgs, m)
        out[m.type] = (
            warns  = e.warns  + (m.severity === :warn  ? 1 : 0),
            errors = e.errors + (m.severity === :error ? 1 : 0),
            msgs   = e.msgs,
        )
    end
    out
end

"""    lookup_type(root::Type, name::AbstractString) -> Union{Type, Nothing}

Find a DO/HTMXO type in the tree rooted at `root` by its bare `nameof`
string. Returns `nothing` if no match.
"""
function lookup_type(root::Type, name::AbstractString)
    for T in _all_types_in_tree(root)
        string(nameof(T)) == name && return T
    end
    nothing
end

"""    callers_by_name(prop::Symbol, root::Type) -> Vector{Tuple{Type, Symbol, Vector{Any}}}

Return every site (caller_type, caller_prop, arg_exprs) that calls a
property *named* `prop` anywhere in the tree rooted at `root`. Matches by
callee NAME, not by resolved owner type, so cross-type name collisions
appear together. Backed by `_build_call_index`.
"""
function callers_by_name(prop::Symbol, root::Type)
    types_in_tree = _all_types_in_tree(root)
    call_index = _build_call_index(types_in_tree)
    get(call_index, prop, Vector{Tuple{Type,Symbol,Vector{Any}}}())
end

