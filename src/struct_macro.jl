dynamicstruct(expr; docstring=nothing, child_handler=nothing, is_child=false, lint=true) = begin
    # Short-form sugar: `T(arg1::T1, arg2::T2) = begin … end` is shorthand
    # for `struct T; arg1::T1; arg2::T2; … end`. Positional args become
    # fixed/constructor fields. `;`-separated kwargs become regular DO
    # properties — bare `kw` errors at access time if the construction
    # kwarg wasn't supplied; `kw=default` makes the default the property
    # RHS (overridable via the same kwarg at construction). Standard Julia
    # docstrings bind to `T` via `Base.@__doc__` exactly like the long form.
    if Meta.isexpr(expr, :(=)) && length(expr.args) == 2 &&
       Meta.isexpr(expr.args[1], :call) &&
       Meta.isexpr(expr.args[2], :block)
        call = expr.args[1]
        body_block = expr.args[2]
        type_name = call.args[1]
        type_args = call.args[2:end]
        body_extras = Any[]
        positional = Any[]
        for a in type_args
            if Meta.isexpr(a, :parameters)
                for kw in a.args
                    if kw isa Symbol
                        msg = "$(type_name)(; $kw, …): required kwarg `$kw` was not provided at construction."
                        push!(body_extras, Expr(:(=), kw, :($error($msg))))
                    elseif Meta.isexpr(kw, :kw, 2)
                        push!(body_extras, Expr(:(=), kw.args[1], kw.args[2]))
                    else
                        error("@dynamicstruct $type_name(...): unsupported kwarg form `$kw` in short-form signature. Use `name` (required) or `name=default`.")
                    end
                end
            else
                push!(positional, a)
            end
        end
        expr = Expr(:struct, false, type_name,
                    Expr(:block, positional..., body_extras..., body_block.args...))
    end
    @assert expr.head == :struct
    mut, head, body = expr.args
    type = head
    Meta.isexpr(type, :(<:)) && (type = type.args[1])
    # Type parameters, kept whole (`T<:Real` stays bounded) alongside their bare
    # names. `head` still carries the curly AND the supertype, so the emitted
    # `:struct` keeps both — only the derived pieces below need the split.
    type_params = Meta.isexpr(type, :curly) ? collect(type.args[2:end]) : Any[]
    Meta.isexpr(type, :(curly)) && (type = type.args[1])
    param_names = map(type_params) do p
        Meta.isexpr(p, (:(<:), :(>:))) ? p.args[1] :
        Meta.isexpr(p, :comparison) ? p.args[3] : p
    end
    parametric = !isempty(type_params)
    # `Foo` alone is the UnionAll, so `::Type{Foo}` matches neither `Foo{:a}` nor
    # anything else a user holds. Every per-type method below dispatches on the
    # covariant form instead. Left exact for a non-parametric type, where the two
    # are equivalent but the exact one is more specific.
    type_dispatch = parametric ? Expr(:(<:), type) : type
    # `Foo{K}` for a signature/`new`, `Foo` when there is nothing to apply.
    _curly(f) = parametric ? Expr(:curly, f, param_names...) : f
    _where(sig) = parametric ? Expr(:where, sig, type_params...) : sig
    @assert body.head == :block
    # --- Rewrite `@struct prop[(idx...)] = begin body end` into the equivalent
    # `prop[(idx...)] = struct <auto-named> body end` so the Form 1 path picks
    # it up. `@struct` is not a real macro — it's a marker handled here.
    # Also peels a `Core.@doc "str" @struct …` wrapper so docstrings on
    # `@struct` properties survive the rewrite (Julia's parser auto-wraps
    # `"str"\n<def>` inside any `:struct` body, including @dynamicstruct's).
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        # Peel a `Core.@doc "str" <inner>` wrapper if present.
        doc_wrapper = nothing
        macro_arg = arg
        if Meta.isexpr(macro_arg, :macrocall)
            mname = macro_arg.args[1]
            mname = _resolve_macro_name(mname)
            if mname === Symbol("@doc") && length(macro_arg.args) >= 4
                doc_wrapper = macro_arg
                macro_arg = macro_arg.args[end]
            end
        end
        # Peel a leading `@fresh` wrapper. `@fresh @struct …` parses as
        # `@fresh(@struct(…))`, so without this the `@struct` marker below is
        # never seen and the inline-child rewrite is skipped. We rewrite the
        # inner `@struct` and re-attach `@fresh` (at the `rewritten` re-wrap
        # below) to the emitted `prop = struct …` form, so `@fresh` lands on the
        # constructor property and marks it never-cache — the call form then
        # builds a FRESH child on every call. Only `@fresh` is peeled here; a
        # disk-cache marker (`@cached`/`@mmap`) on `@struct` stays unsupported
        # and is rejected at the `@struct in info.macros` guard downstream.
        fresh_wrapper = nothing
        if Meta.isexpr(macro_arg, :macrocall) &&
           _resolve_macro_name(macro_arg.args[1]) === Symbol("@fresh")
            fresh_wrapper = macro_arg
            macro_arg = macro_arg.args[end]
        end
        Meta.isexpr(macro_arg, :macrocall) || continue
        macro_arg.args[1] == Symbol("@struct") || continue
        inner = macro_arg.args[end]
        Meta.isexpr(inner, :(=)) ||
            error("@struct: expected `prop = begin ... end` or `prop(idx...) = begin ... end`, got $(macro_arg)")
        lhs = inner.args[1]
        rhs = inner.args[2]
        Meta.isexpr(rhs, :block) ||
            error("@struct: RHS must be a `begin ... end` block, got $(rhs)")
        prop_sym = Meta.isexpr(lhs, :call) ? lhs.args[1] : lhs
        prop_sym isa Symbol ||
            error("@struct: LHS must be `prop` or `prop(idx...)`, got $(lhs)")
        # `@struct prop(args) = body` parses with body wrapped in `:block`,
        # so the `:block` check above passes for the short-form misuse
        # `@struct prop(args) = ExternalCtor(args)` (where the block holds a
        # single bare call). `@struct` always requires an explicit
        # `begin … end` declaring the child's properties — without this
        # check, the downstream args-parsing loop crashes on the bare call
        # with `union!(::Nothing, ::Set{Any})`.
        rhs_stmts = [a for a in rhs.args if !(a isa LineNumberNode)]
        if length(rhs_stmts) == 1 && !Meta.isexpr(rhs_stmts[1], (:(=), :macrocall, :struct, :tuple))
            error("@struct $prop_sym: body must be an explicit `begin ... end` declaring the child's properties. Got a single bare expression `$(rhs_stmts[1])` — likely a short-form misuse like `@struct $lhs = ExternalCtor(...)`. Rewrite as `@struct $lhs = begin ... end` with the child's properties inline.")
        end
        gen_child_name = Symbol(prop_sym, "_inline")
        rewritten = Expr(:(=), lhs, Expr(:struct, false, gen_child_name, rhs))
        # Re-attach `@fresh` (peeled above) so it rides the rewritten form into
        # the extraction loop and, ultimately, onto the constructor property.
        isnothing(fresh_wrapper) ||
            (rewritten = Expr(:macrocall, fresh_wrapper.args[1:end-1]..., rewritten))
        body.args[i] = isnothing(doc_wrapper) ? rewritten :
            Expr(:macrocall, doc_wrapper.args[1:end-1]..., rewritten)
    end
    # --- Process @include external structs ---
    # Returned (prop, type) pairs feed `_analysis_nested_type` so the
    # analyzer walks @include'd externals even when the enclosing struct
    # is `@dynamicstruct` (no HTMXObjects route walker = no
    # `_nested_struct_type` for these unless we add it here).
    include_externals_pairs = _process_include_externals!(body)
    # --- Extract inline struct definitions ---
    # Collect parent property names (excluding inline structs themselves)
    parent_props = Symbol[]
    for arg in body.args
        arg isa LineNumberNode && continue
        a = arg
        while Meta.isexpr(a, :macrocall); a = a.args[end]; end
        # Inline structs become regular parent properties after the
        # extraction loop below (the `prop[(idx)]` forms → an
        # IndexableProperty, the bare form → a plain property). Their
        # parent-property names MUST be collected here so a sibling inline
        # `@struct` can reference them by bare name — those names are
        # forwarded into each child scope via `(; …) = __parent__`. The
        # `prop = struct …` / `prop(idx) = struct …` forms carry the name
        # on the LHS and fall through to the generic collector below; the
        # bare `struct Name … end` form carries it as the struct name. Each
        # child also forwards its OWN name, like every other parent property.
        if Meta.isexpr(a, :struct)
            _push_if_symbol!(parent_props, a.args[2])
            continue
        end
        # A `__self__` member method is an ordinary Julia method, not a
        # property: forwarding its name would give each inline child a
        # `name = __parent__.name` property that has no `compute_property`
        # behind it, and would rewrite the child's bare `name(__parent__, …)`
        # call onto that dead property. Unforwarded, the bare call resolves
        # to the module-level method exactly as it does in the parent's own
        # bodies (snag member-method-ca-f20fb4ef).
        Meta.isexpr(a, (:(=), :function)) &&
            !isnothing(_detect_inline_method_lhs(a.args[1])) && continue
        lhs = if Meta.isexpr(a, :(=))
            a.args[1]
        else
            a  # fixed field: bare symbol or typed symbol
        end
        # The return annotation wraps the call (`name(args)::T`), so peel it
        # before the index; peeling the call first left `name(args)` and
        # dropped every typed indexed property from the forward.
        Meta.isexpr(lhs, :(::)) && (lhs = lhs.args[1])
        Meta.isexpr(lhs, (:call, :ref)) && (lhs = lhs.args[1])
        # `_collect_lhs_names` dispatches: bare Symbol → (sym,), tuple
        # destructure → recursive name collection, anything else → ().
        # Each new shape is a method, not another `if` arm.
        append!(parent_props, _collect_lhs_names(lhs))
    end
    extracted_structs = Expr[]
    # Parallel record of (parent-property-name => generated-child-type-name) for
    # each inline `@struct` child, used to emit `_nested_struct_type` methods so
    # `print_structure` can walk the inline-child tree.
    inline_child_pairs = Pair{Symbol,Any}[]
    # Inline children constructed through `_inline_child` (every non-`@fresh`
    # one); emits `_source_shared_child` so `remount` resolves them lazily on
    # the retained source instead of pre-seeding view copies.
    source_shared_children = Symbol[]
    # Typed computed properties (`prop::T = rhs`) register T only with
    # `_analysis_nested_type` (not `_nested_struct_type`), so the analyzer's
    # tree walk follows them but HTMXObjects' route walker doesn't (typed
    # primitives like `port::Int = 8080` would otherwise crash route
    # registration on `meta(::Type{Int})`).
    analysis_child_pairs = Pair{Symbol,Any}[]
    append!(analysis_child_pairs, include_externals_pairs)
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        # Peel a `Core.@doc "str" <inner>` wrapper if present, so that
        # `"docstring"\n@struct prop(args) = …` (which pass 1 has already
        # rewritten to `Core.@doc "str" (prop(args) = struct gen … end)`)
        # is recognised as Form 1a here. The wrapper is reattached to the
        # constructor assignment at the end so the third pass picks the
        # docstring up via its `@doc` unwrap and routes it into
        # `_property_description`.
        doc_wrapper = nothing
        form_arg = arg
        if Meta.isexpr(form_arg, :macrocall)
            mname = form_arg.args[1]
            mname = _resolve_macro_name(mname)
            if mname === Symbol("@doc") && length(form_arg.args) >= 4
                doc_wrapper = form_arg
                form_arg = form_arg.args[end]
            end
        end
        # Peel a `@fresh` wrapper (pass-1 re-attached it around the rewritten
        # `prop = struct …` form). Peeling it lets Form 1/2 detection below match
        # the inline child; it is re-attached to `constructor_assignment` at the
        # end so `@fresh` reaches the property-info collector and emits
        # `_never_cache` for the constructor property (→ fresh child per call).
        fresh_wrapper = nothing
        if Meta.isexpr(form_arg, :macrocall) &&
           _resolve_macro_name(form_arg.args[1]) === Symbol("@fresh")
            fresh_wrapper = form_arg
            form_arg = form_arg.args[end]
        end
        prop_name = nothing
        child_struct = nothing
        index_params = Symbol[]
        # Parallel list to `index_params` preserving the raw positional-arg
        # expression (`:name` or `:(name::T)`). Used only when emitting the
        # parent property's method signature so `info.indices` carries the
        # type annotation for downstream readers (notably HTMXObjects'
        # `_nested_prefix_and_step`, which feeds URL-segment conversion).
        index_param_exprs = Any[]
        # (name, default_or_nothing) — `nothing` here means "no user-supplied
        # default" (required kwarg); any explicit default (even a literal
        # `nothing` written by the user) is wrapped in Some(...).
        index_kwargs = Tuple{Symbol,Any}[]
        # Form 1a: prop(idx...) = struct Name ... end  (indexed inline struct)
        # Julia parses short-form function defs with a :block wrapper around the
        # RHS — so `subject(idx) = struct Subject ... end` has args[2] = :block
        # containing a LineNumberNode + the :struct. Unwrap that case.
        if Meta.isexpr(form_arg, :(=)) && Meta.isexpr(form_arg.args[1], :call)
            rhs_expr = form_arg.args[2]
            if Meta.isexpr(rhs_expr, :block)
                inner = [a for a in rhs_expr.args if !(a isa LineNumberNode)]
                length(inner) == 1 && Meta.isexpr(inner[1], :struct) && (rhs_expr = inner[1])
            end
            if Meta.isexpr(rhs_expr, :struct)
                call_expr = form_arg.args[1]
                prop_name = call_expr.args[1]
                for p in call_expr.args[2:end]
                    if Meta.isexpr(p, :parameters)
                        for kw in p.args
                            if Meta.isexpr(kw, :kw)
                                kname = kw.args[1]
                                Meta.isexpr(kname, :(::)) && (kname = kname.args[1])
                                @assert kname isa Symbol "indexed inline struct kwarg name must be a Symbol, got $(kw.args[1])"
                                push!(index_kwargs, (kname, Some(kw.args[2])))
                            else
                                kname = Meta.isexpr(kw, :(::)) ? kw.args[1] : kw
                                @assert kname isa Symbol "indexed inline struct kwarg name must be a Symbol, got $kw"
                                push!(index_kwargs, (kname, nothing))
                            end
                        end
                    else
                        pname = Meta.isexpr(p, :(::)) ? p.args[1] : p
                        @assert pname isa Symbol "indexed inline struct: index param must be a Symbol, got $p"
                        push!(index_params, pname)
                        push!(index_param_exprs, p)
                    end
                end
                child_struct = rhs_expr
            end
        # Form 1b: prop = struct Name ... end
        elseif Meta.isexpr(form_arg, :(=)) && Meta.isexpr(form_arg.args[2], :struct)
            prop_name = form_arg.args[1]
            child_struct = form_arg.args[2]
        # Form 2: struct Name ... end (bare)
        elseif Meta.isexpr(form_arg, :struct)
            child_struct = form_arg
        end
        isnothing(child_struct) && continue
        child_name = child_struct.args[2]
        isnothing(prop_name) && (prop_name = child_name)
        # Rename child struct to Parent_Child to avoid kwarg shadowing
        gen_name = Symbol(type, "_", child_name)
        child_struct.args[2] = gen_name
        # Collect child's own property names to avoid collision
        child_props = Set{Symbol}()
        for ca in child_struct.args[3].args
            ca isa Expr || continue
            ca2 = ca
            while Meta.isexpr(ca2, :macrocall); ca2 = ca2.args[end]; end
            Meta.isexpr(ca2, :(=)) || continue
            clhs = ca2.args[1]
            Meta.isexpr(clhs, (:call, :ref)) && (clhs = clhs.args[1])
            Meta.isexpr(clhs, :(::)) && (clhs = clhs.args[1])
            _push_if_symbol!(child_props, clhs)
        end
        # Prepend __parent__, index params, __hash_fields__ override, and
        # forwarded parent properties to the child body.
        child_body = child_struct.args[3]
        kwarg_names = Symbol[n for (n, _) in index_kwargs]
        prepend_names = Set{Symbol}([:__parent__, index_params..., kwarg_names...])
        # For indexed inline structs we override __hash_fields__ to
        # (__parent__, indices..., kwargs...) so the child's disk-cache
        # namespace is tied to the parent hash AND to the kwarg values. Skip
        # if the user declared __hash_fields__ inside the child body.
        will_prepend_hash_fields = (!isempty(index_params) || !isempty(index_kwargs)) && !(:__hash_fields__ in child_props)
        will_prepend_hash_fields && push!(prepend_names, :__hash_fields__)
        # Never forward DO-internal cache/identity properties from the parent
        # into the child — they have per-instance semantics (the child has its
        # own hash/cache_path/__cache_base__) and forwarding them collides with the
        # automatic machinery (e.g. with our __hash_fields__ prepend, producing
        # duplicate compute_property method definitions).
        nonforwardable = Set{Symbol}([:__hash_fields__, :__hash__, :__cache_path__, :cache])
        # Forward parent properties that (a) aren't overridden in the child,
        # (b) aren't __status__ (scoped separately), (c) aren't DO-internal
        # cache/identity names, and (d) aren't one of the names we're about
        # to prepend ourselves. The child's OWN name forwards too, so a bare
        # `fit(:other)` in `@struct fit(dataset)` and a struct `@include`d
        # into it that destructures `(; fit) = __self__.__parent__` both reach
        # the parent's property (snag inline-struct-ow-3f55b471). Nothing
        # recurses: `__parent__.fit` is the parent's IndexableProperty, and a
        # plain child's `__parent__.name` is the parent's memoized child, i.e.
        # the child itself. An index param or kwarg of the same name, or a
        # child declaration of it, still wins.
        # Dedupe: a parent can declare the same property name multiple times
        # (indexed properties with multi-method dispatch on the index type).
        # We only want one forwarding extractor per name.
        forwarded = unique!(Symbol[pp for pp in parent_props if !(pp in child_props) && pp != :__status__ && !(pp in nonforwardable) && !(pp in prepend_names)])
        prepend = Expr[]
        push!(prepend, :(__parent__ = nothing))
        for ip in index_params
            push!(prepend, :($ip = nothing))
        end
        # For kwargs: use user-supplied default if any, else `nothing`. The
        # value actually used at runtime comes from the constructor kwarg;
        # the in-body rhs is a compute_property fallback (required kwargs
        # won't hit it because the parent wrapper's call signature enforces
        # them at the call site).
        for (kname, kdefault) in index_kwargs
            # A required kwarg (no user default) falls back to `nothing` —
            # but it must be the literal-source `nothing` (a Symbol, like
            # the `:($ip = nothing)` index prepend above), NEVER the
            # interpolated value: `Expr(:(=), k, nothing)` has
            # `rhs === nothing`, which `isfixed` reads as "no rhs" and
            # lowers to a FIXED STRUCT FIELD — and then the kwargs-only
            # child constructor call matches no method (snag
            # required-indexed-165c772b).
            if kdefault === nothing
                push!(prepend, :($kname = nothing))
            else
                push!(prepend, :($kname = $(something(kdefault))))
            end
        end
        if will_prepend_hash_fields
            # Through `_disk_key`, like this child's own directory (`cache_segment` below): a
            # child is memoized per `isequal` arguments, so its identity must not depend on
            # which spelling built it first.
            push!(prepend, :(__hash_fields__ = $(Expr(:tuple, :__parent__,
                (:(DynamicObjects._disk_key($name)) for name in (index_params..., kwarg_names...))...))))
        end
        # Forward each parent prop as a `@fetch!`-marked property
        # (`@fetch! nm = __parent__.nm`) rather than one
        # `(; nm... ) = __parent__` destructure, so a bare reference to a
        # progress-annotated parent prop threads progress instead of computing
        # the parent IP with no substatus attached (the "Starting (spinner)"
        # bug). The existing @fetch! property marker (731e012) wraps each body
        # at emission as `@fetch! __status__ __parent__.nm` →
        # `maybefetchproperty!(__status__, __parent__, :nm)`. This degrades to
        # plain `getproperty(__parent__, nm)` — byte-identical to the old
        # destructure — when `__status__ === nothing` (Treebars off / no
        # progress), for serial caches, and for forwarded IPs (wrapper
        # returned); it attaches a progress substatus only in the
        # `:parallel`-non-indexed case, and only renders a node for documented
        # props (undocumented → bare wrapper Treebars inlines). No Task ever
        # leaks — `fetchproperty!`'s callback applies `Base.fetch`, blocking to
        # the same value `getproperty` returns today. The destructure is
        # already split per-member by the main `:tuple` lowering, so emitting
        # per-member markers (vs one destructure) produces the SAME child
        # properties, just `@fetch!`-marked. (decision `1vwuhqj`: user chose
        # fix-directly; @fetch! call-site destructure recognition is the
        # orthogonal sibling item (a), not used here.)
        for nm in forwarded
            push!(prepend, :(@fetch! $nm = __parent__.$nm))
        end
        # Auto-derive a hierarchical cache_path: extend the parent's path by a
        # per-child directory whose name is the same flat segment that
        # `get_cache_path` would use as the file-name body for this property.
        # On disk this nests as "base/<parent_segment>/<child_segment>/…",
        # ending at the leaf "<property>_<args>.sjl". Skipped when the child
        # body explicitly declares cache_path — explicit wins.
        if !(:__cache_path__ in child_props)
            # Expr(:call) layout: (func, [parameters], positional...). The
            # parameters expression must come right after the function, not
            # after positional args, otherwise Julia's parser rejects it.
            seg_call_args = Any[:(DynamicObjects.cache_segment)]
            !isempty(index_kwargs) && push!(seg_call_args,
                Expr(:parameters, [Expr(:kw, kn, kn) for (kn, _) in index_kwargs]...))
            push!(seg_call_args, QuoteNode(prop_name))
            append!(seg_call_args, index_params)
            seg_call = Expr(:call, seg_call_args...)
            push!(prepend, :(__cache_path__ = joinpath(__parent__.__cache_path__, $seg_call)))
        end
        child_body.args = vcat(prepend, child_body.args)
        push!(extracted_structs, child_struct)
        push!(inline_child_pairs, prop_name => gen_name)
        # Replace with parent property definition. For indexed form, emit an
        # indexed property `prop(idx...; kw=default, ...)`; for the plain
        # form, a bare `prop`.
        constructor_kwargs = Any[
            Expr(:kw, :__parent__, :__self__),
            (Expr(:kw, ip, ip) for ip in index_params)...,
            (Expr(:kw, kname, kname) for (kname, _) in index_kwargs)...,
        ]
        # Auto-wire __status__ as a substatus of the parent, UNLESS the child
        # body declares its own __status__ (opt-out). Declaring
        # `__status__ = nothing` suppresses per-access Treebar nodes; declaring
        # `__status__ = __parent__.__status__` inherits the parent's status
        # directly without creating a child progress node.
        if !(:__status__ in child_props)
            # Forward the call-site indices AND kwargs into the
            # `__substatus__` probe: the emitted `_is_property_documented`
            # / `_property_description` overrides carry the property's full
            # signature, so a required kwarg (e.g. `K` in `@struct
            # rows(key; K::Int)`) must be supplied here — dropping it dies
            # with `UndefKeywordError` before the body runs (snag
            # required-indexed-165c772b). `Expr(:call)` layout is (func,
            # [parameters], positional...): the parameters block goes right
            # after the callee.
            substatus_args = Any[compute_property, :__self__, :(Val(:__substatus__)),
                QuoteNode(prop_name), index_params...]
            !isempty(index_kwargs) && insert!(substatus_args, 2,
                Expr(:parameters, [Expr(:kw, kn, kn) for (kn, _) in index_kwargs]...))
            push!(constructor_kwargs,
                Expr(:kw, :__status__, Expr(:call, substatus_args...)))
        end
        constructor = Expr(:call, gen_name, Expr(:parameters, constructor_kwargs...))
        # A memoized child is built through `_inline_child`, which runs exactly
        # this constructor on an ordinary object but resolves the child on the
        # retained source for a `remount` view, so every view shares one child
        # cache. A `@fresh` child is a new child per call by contract, so it
        # keeps the bare constructor and stays view-local.
        if isnothing(fresh_wrapper)
            indexed_child = !(isempty(index_params) && isempty(index_kwargs))
            constructor = Expr(:call, _inline_child, :__self__,
                Expr(:call, :Val, QuoteNode(prop_name)), Val(indexed_child),
                Expr(:tuple, index_params...),
                Expr(:tuple, Expr(:parameters, [Expr(:kw, kn, kn) for (kn, _) in index_kwargs]...)),
                gen_name, Expr(:tuple, Expr(:parameters, constructor_kwargs...)))
            push!(source_shared_children, prop_name)
        end
        # Use `index_param_exprs` (typed `:(name::T)` when annotated, bare
        # `:name` otherwise) for the method signature so downstream readers
        # of `info.indices` see the URL-segment Julia Type. Internal uses
        # of `index_params` above stay on bare Symbols.
        lhs_expr = if isempty(index_params) && isempty(index_kwargs)
            prop_name
        elseif isempty(index_kwargs)
            Expr(:call, prop_name, index_param_exprs...)
        else
            # Emit kwargs as an Expr(:parameters, ...) on the parent-property
            # call signature. Required kwargs stay as bare Symbols; defaulted
            # kwargs become Expr(:kw, name, default).
            kw_nodes = Any[kdefault === nothing ? kname : Expr(:kw, kname, something(kdefault))
                           for (kname, kdefault) in index_kwargs]
            Expr(:call, prop_name, Expr(:parameters, kw_nodes...), index_param_exprs...)
        end
        constructor_assignment = Expr(:(=), lhs_expr, constructor)
        # Re-attach `@fresh` (peeled above) so the constructor property is marked
        # never-cache → the call form builds a fresh child on every call.
        isnothing(fresh_wrapper) ||
            (constructor_assignment = Expr(:macrocall, fresh_wrapper.args[1:end-1]..., constructor_assignment))
        body.args[i] = isnothing(doc_wrapper) ? constructor_assignment :
            Expr(:macrocall, doc_wrapper.args[1:end-1]..., constructor_assignment)
    end
    # `lnn` / `doc` flow across iterations via the metadata context.
    # `_absorb_body_metadata!` dispatch fills it from LineNumberNode /
    # AbstractString / `:string` Expr args; "real" property args read
    # `metadata.lnn[]` / `.doc[]` at the top of each iteration and the
    # `doc` ref is reset to `nothing` once that property consumes it.
    metadata = (lnn = Ref{Any}(nothing), doc = Ref{Any}(nothing))
    docs = []
    oproperties = Pair[]
    inline_methods = Any[]
    # `@options <parameter> = <domain expression>` declarations, in body order.
    # Held as `(; parameter, expression, lnn)` until the property list is
    # complete, because the dependency walk needs the full set of sibling names.
    option_decls = Any[]
    # `@mmap` properties: name => eltype-annotation-expr (or `nothing` when
    # un-annotated). Drives the per-property `_disk_format`/`_disk_eltype`
    # emission below.
    mmap_eltypes = Dict{Symbol,Any}()
    for arg in body.args
        _absorb_body_metadata!(arg, metadata) && continue
        lnn = metadata.lnn[]
        doc = metadata.doc[]
        macros = Set{Symbol}()
        rhs = nothing
        dependson = nothing
        locals = nothing
        indices = tuple()
        indexed = false
        cache_version = nothing
        # Peel `@doc` / `@cached` / unrecognised macros from `arg` via
        # `_apply_property_macro!` dispatch (one method per macro shape).
        # The state struct mutates `doc` / `cache_version` / `macros` in
        # place — `macros` is the same Set the outer loop uses, so we read
        # it back implicitly; the other two are scalars copied back after
        # the loop.
        macro_state = _PropertyMacroState(doc, cache_version, macros)
        # `@options(x) = domain` — a PARENTHESIZED macrocall binds only its own
        # arguments, so the marker lands on the LHS of the assignment instead of
        # wrapping it. Normalize to the wrapping form the peel loop expects, so
        # both `@options(x) = …` and `@options x = …` take one path.
        if Meta.isexpr(arg, :(=)) && Meta.isexpr(arg.args[1], :macrocall) &&
                _resolve_macro_name(arg.args[1].args[1]) === Symbol("@options")
            inner = arg.args[1]
            length(inner.args) == 3 ||
                error("@options names exactly one parameter: `@options(<parameter>) = <domain expression>`, got `$arg`")
            arg = Expr(:macrocall, inner.args[1], inner.args[2],
                Expr(:(=), inner.args[end], arg.args[2]))
        end
        while Meta.isexpr(arg, :macrocall)
            # `_resolve_macro_name` collapses `GlobalRef(Core, :@doc)` (the
            # form Julia's docstring lowering surfaces) to bare `:@doc`.
            mname = _resolve_macro_name(arg.args[1])
            arg = _apply_property_macro!(macro_state, Val(mname), arg)
        end
        doc = macro_state.doc
        cache_version = macro_state.cache_version
        # `@options(<parameter>) = <domain>` declares which values an input may
        # take — the one fact the structural descriptors cannot infer. It does
        # NOT declare a property named `<parameter>` (that name is already a
        # field or an argument, and would collide); it lowers to the dunder
        # indexed property `__options__(::Val{parameter})`, so a domain is an
        # ordinary lazily computed DO value: never evaluated unless a consumer
        # asks for it, memoized and invalidated like anything else, and its
        # dependencies fall out of the same walk every other RHS gets. The
        # rewrite happens here and then falls through to ordinary property
        # classification — no separate emission path.
        if Symbol("@options") in macros
            extra = setdiff(macros, (Symbol("@options"),))
            isempty(extra) ||
                error("@dynamicstruct $type: `@options` cannot combine with $(join(sort!(string.(collect(extra))), ", ")).")
            (Meta.isexpr(arg, :(=)) && arg.args[1] isa Symbol) ||
                error("@dynamicstruct $type: `@options` must read `@options(<parameter>) = <domain expression>`, got `$arg`.")
            parameter, domain = arg.args
            any(decl -> decl.parameter === parameter, option_decls) &&
                error("@dynamicstruct $type: duplicate `@options` declaration for `$parameter`; each parameter may declare one domain.")
            push!(option_decls, (; parameter, expression=domain, lnn))
            arg = Expr(:(=),
                Expr(:call, :__options__, Expr(:(::), Expr(:curly, Val, QuoteNode(parameter)))),
                domain)
        end
        # Inline-method short form: `f(__self__, ...) = body`. Bypasses property
        # tooling — no compute_property, no getproperty entry — but the body
        # still gets bare-name → `__self__.<prop>` rewriting like a property
        # RHS. Detect before the `:(=)` LHS/RHS split so the full signature
        # (including `where` and return-type wrappers) stays intact.
        if Meta.isexpr(arg, :(=))
            method_info = _detect_inline_method_lhs(arg.args[1])
            if !isnothing(method_info)
                isempty(macros) ||
                    error("Property-level macros (@cached, …) cannot be applied to inline methods in @dynamicstruct.")
                push!(inline_methods, (; method_info..., body=arg.args[2], lnn))
                metadata.doc[] = nothing
                continue
            end
        end
        if Meta.isexpr(arg, :function)
            # Long-form methods carrying a positional `__self__` have the same
            # ordinary-method semantics as the short form above. A long-form
            # definition without `__self__` is still neither a property nor an
            # inline method and keeps the focused property-syntax diagnostic.
            method_info = _detect_inline_method_lhs(arg.args[1])
            if !isnothing(method_info)
                isempty(macros) ||
                    error("Property-level macros (@cached, …) cannot be applied to inline methods in @dynamicstruct.")
                push!(inline_methods, (; method_info..., body=arg.args[2], lnn))
                metadata.doc[] = nothing
                continue
            end
            fname = Meta.isexpr(arg.args[1], :call) ? arg.args[1].args[1] : arg.args[1]
            error("Use short-form syntax for properties in @dynamicstruct: `$fname(...) = ...` instead of `function $fname(...) ... end`. If `$fname` is a helper that doesn't depend on the struct's state, move it outside the @dynamicstruct body.")
        end
        if Meta.isexpr(arg, :(=))
            arg, rhs = arg.args
            dependson = Set{Symbol}()
            locals = Set{Symbol}()
        end
        # Multi-lhs: a, b = expr or (;a, b) = expr → hidden group property + individual extractors
        if Meta.isexpr(arg, :tuple)
            # Detect named destructuring: (;a, b) parses as Expr(:tuple, Expr(:parameters, :a, :b))
            named = length(arg.args) == 1 && Meta.isexpr(arg.args[1], :parameters)
            raw_args = named ? arg.args[1].args : arg.args
            # Nested positional destructuring: ((a, b), (c, d)) = expr
            # Handled recursively: outer group + inner group per nested tuple.
            if !named && any(a -> Meta.isexpr(a, :tuple), raw_args)
                all_leaves = _collect_leaves(arg)
                group_name = Symbol("_tuple_", join(all_leaves, "_"))
                group_locals = Set{Symbol}(all_leaves); push!(group_locals, group_name)
                push!(oproperties, group_name => (;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version, result_type=nothing, doc))
                push!(docs, (group_name => (doc, true)))
                _emit_positional_destructure!(oproperties, docs, raw_args, group_name, lnn)
                metadata.doc[] = nothing
                continue
            end
            # Build list of (property_name, extract_expr_builder) pairs
            # extract_expr_builder takes the group_name and returns the RHS expression
            members = Pair{Symbol, Any}[]  # name => source_field_or_index
            if named
                # Per-shape dispatch via `_emit_named_member!`:
                #   bare symbol     → `a => a`
                #   `target <= src` → `target => src` (Symbol src)
                #                     or `Symbol(prefix, s) => s` for each
                #                     `s` in a `:tuple` src (prefix mode).
                for a in raw_args
                    _emit_named_member!(members, a)
                end
            else
                for (i, a) in enumerate(raw_args)
                    n = Meta.isexpr(a, :(::)) ? a.args[1] : a
                    push!(members, n => i)
                end
            end
            prop_names = first.(members)
            # When RHS is a bare symbol in named destructuring, skip the hidden
            # group property and extract directly: (;a, b) = config → a = config.a
            # Otherwise, use a group property to evaluate the RHS once.
            extract_from = if named && rhs isa Symbol
                rhs
            else
                group_name = Symbol("_tuple_", join(prop_names, "_"))
                group_locals = Set{Symbol}(prop_names)
                push!(group_locals, group_name)
                push!(oproperties, group_name=>(;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version, result_type=nothing, doc))
                push!(docs, (group_name=>(doc, true)))
                group_name
            end
            metadata.doc[] = nothing
            for (prop_name, source) in members
                extract_rhs = _extract_member(extract_from, source)
                push!(oproperties, prop_name=>(;lhs=prop_name, macros=Set{Symbol}(), rhs=extract_rhs, lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([prop_name]), indices=tuple(), indexed=false, cache_version=nothing, result_type=nothing, doc=nothing))
                push!(docs, (prop_name=>(nothing, true)))
            end
            continue
        end
        if Meta.isexpr(arg, :ref)
            loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
            pname = arg.args[1]
            Meta.isexpr(pname, :(::)) && (pname = pname.args[1])
            @warn "Deprecated: `$pname` uses [] syntax which cannot combine with kwargs$loc. Use () instead: $pname($(join(arg.args[2:end], ", ")))"
        end
        if Meta.isexpr(arg, (:ref, :call))
            arg, indices... = arg.args
            indexed = true
            union!(locals, extractnames(indices))
        end
        name, ext_type = if Meta.isexpr(arg, :(::))
            arg.args[1], arg.args[2]
        else
            arg, nothing
        end
        # `foo(i)::T = rhs` — the `::` annotation wraps the call, so the
        # call/ref index strip above (which only fires on a bare `:ref`/`:call`
        # arg) never ran. Strip the indices from `name` now, mark indexed, and
        # reduce `arg` (→ the `lhs` field below) to the bare callee, matching
        # how non-annotated indexed properties store their `lhs`. `ext_type`
        # stays captured for `@mmap` load lowering.
        if Meta.isexpr(name, (:ref, :call))
            callee, post_indices... = name.args
            indexed = true
            !isnothing(locals) && union!(locals, extractnames(collect(post_indices)))
            indices = (indices..., post_indices...)
            arg = callee
            name = callee
        end
        if !(name isa Symbol)
            loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
            hint = if Meta.isexpr(name, :parameters)
                "Looks like a `;`-kwargs clause leaked into the body. If you wrote `@dynamicstruct $type(...; kw, kw=default) = begin … end`, that's now supported — make sure DynamicObjects is up to date."
            elseif Meta.isexpr(name, :tuple)
                "Tuple LHS (e.g. `(a, b) = ...`) destructuring at struct-level is not supported as a property name; either split into separate property declarations or use `let` inside another property's RHS."
            else
                """\
                Each property in @dynamicstruct must have a Symbol name on the LHS — e.g. `name = rhs`, `name(idx) = rhs`, or `name::T = rhs`. \
                Looks like a side-effecting/anonymous statement at struct top-level — DO doesn't run those at construction. To keep the check, either:
                  (a) bind it to a named property and reference that property from a downstream RHS:
                      _check = $arg
                      result = (_check; …)         # forces evaluation when `result` is accessed
                  (b) fold the assertion directly into the RHS of a property that needs to enforce it:
                      result = begin
                          $arg
                          …
                      end
                """
            end
            error("@dynamicstruct $type: cannot interpret `$arg` as a property declaration$loc. $hint")
        end
        # `prop::T = rhs` (computed property with a type annotation) registers
        # T with `_analysis_nested_type` so `analyze_structure` walks into
        # T's tree alongside the enclosing struct's. Separate hook from
        # `_nested_struct_type` (which HTMXObjects walks for route mounting)
        # — typed primitives like `port::Int` would otherwise wedge route
        # registration on `meta(Int)`. Indexed properties and fixed fields
        # keep the annotation's existing semantics (Julia field type for
        # fixed, ignored for indexed).
        if ext_type !== nothing && !isnothing(rhs) && !indexed
            push!(analysis_child_pairs, name => ext_type)
        end
        # `@mmap` property: record its eltype annotation (or `nothing` when
        # un-annotated) for the `_disk_format`/`_disk_eltype` emission below.
        if Symbol("@mmap") in macros
            mmap_eltypes[name] = ext_type
        end
        push!(docs, (name=>(doc, !isnothing(rhs))))
        metadata.doc[] = nothing
        !isnothing(locals) && push!(locals, name)
        !isnothing(locals) && push!(locals, :__status__)
        # A fixed field (no rhs) may carry ONLY `@versioned` (the cache version
        # dimension); every other marker (@cached/@mmap/@fresh/@dynamic_progress)
        # acts on a computed property and is a mistake on a field.
        @assert !isnothing(rhs) || issubset(macros, (Symbol("@versioned"),)) "fixed field `$name` may not carry markers other than @versioned (got $(sort!(string.(collect(macros)))))"
        push!(oproperties, name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices, indexed, cache_version, result_type=ext_type, doc))
    end
    # `properties` holds the per-declaration list (preserves order AND duplicate
    # names — e.g. a future `@get foo()` + `@include foo(x::String)` pair). It's
    # what `meta(T)` returns; macro-internal lookups that just need "is `x` a
    # property name?" use the `prop_names` set built from it.
    properties = collect(oproperties)
    prop_names = Set{Symbol}(first.(oproperties))
    # Bare-ref resolution set: user property names PLUS the injected magic
    # dunders, so a body may reference `__hash__`/`__cache_path__`/… bare and
    # have `walk_rhs` resolve them to `__self__.…` just like a sibling. Keep
    # `prop_names` itself user-only — the injection guard and `hasproperty`
    # below rely on it meaning "names the user actually declared".
    walk_props = union(prop_names, _BAREREF_MAGIC)

    # Struct-level lint passes: repeated-prefix and shared-arg-signature.
    # Lints have moved to `analyze_structure(T)` — run from `print_structure`,
    # not at definition time. The macro no longer emits any lint warnings.

    docstring = something(docstring, "DynamicStruct `$type`.") * "\n\n" * join([
        "* " * (isnothing(doc) ? "" : "$(_doc_to_string(doc)): ") * "`$name" * (hasrhs ? " = ..." : "") * "`"
        for (name, (doc, hasrhs)) in docs
    ], "\n")

    generated_names = Tuple(name for (name, info) in oproperties if !isfixed(info))
    indexed_names = Tuple(name for (name, info) in oproperties if info.indexed)
    # DiskCacheLocks-bearing properties: `@cached` AND `@mmap` (both persist to
    # disk and want the strict-mode per-path lock). `@mmap` implies disk
    # persistence with the mmap format (D4).
    cached_names = [(name, Symbol("_", type, "_", name, "_disk_cache")) for (name, info) in oproperties if !isfixed(info) && (Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros)]
    # `@mmap` properties → (name, eltype-annotation-expr-or-nothing) for the
    # `_disk_format`/`_disk_eltype` per-property override emission.
    mmap_names = sort!(collect(keys(mmap_eltypes)))
    fixed_fields = [(name, info.lhs) for (name, info) in oproperties if isfixed(info)]
    fixed_names = [n for (n, _) in fixed_fields]
    fixed_lhs = [lhs for (_, lhs) in fixed_fields]
    # ── @versioned: the cache version dimension (fixed field OR computed prop) ─
    # `@versioned x` tags `x` as the version dimension — excluded from the cache
    # IDENTITY, forming a per-version path segment (see `has_versioned_fields` /
    # `__cache_path__`). Two shapes share one contract (decision `b2tsvz`, opt B):
    #   • a FIXED field  → read via `getfield`; excluded from the identity hash so
    #     every version of one object shares an identity dir (what lets pruning work).
    #   • a COMPUTED prop → read via `getorcomputeproperty` (the value DO derives,
    #     e.g. `file_version(path)`); identity is UNCHANGED — a computed prop is
    #     never in `__hash_fields__`, so there is nothing to exclude and the version
    #     segment is purely additive. Acyclicity guarded once `dependson` is built.
    # A declared `__hash__` / `__hash_fields__` is the type's identity override, so
    # the identity dir is `__hash__` (`base/<__hash__>/<version>/`), exactly the dir
    # a non-versioned type would use; the override may not read the version (guarded
    # once `dependson` is built). Without one, identity = the non-versioned fixed
    # fields (snag `cache-a-versione-5429048f`).
    versioned_names = [name for (name, info) in oproperties if Symbol("@versioned") in info.macros]
    versioned_fixed = Set{Symbol}(name for (name, info) in oproperties if isfixed(info) && Symbol("@versioned") in info.macros)
    # A computed `@versioned` prop cannot ALSO be disk-cached: computing its own
    # value would need `__cache_path__` → `__version_tag__` → itself (a cycle).
    for (name, info) in oproperties
        (Symbol("@versioned") in info.macros && !isfixed(info) &&
         (Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros)) &&
            error("@versioned computed property `$name` may not also be @cached/@mmap: computing its value needs the cache path, which needs the version — a cycle. Make the version dimension a plain computed property.")
    end
    identity_fixed_names = [n for n in fixed_names if !(n in versioned_fixed)]
    identity_overrides = Symbol[n for n in (:__hash__, :__hash_fields__) if n in prop_names]
    versioned_defs = isempty(versioned_names) ? Any[] : Any[
        :($DynamicObjects.has_versioned_fields(::Type{$type_dispatch}) = true),
        (isempty(identity_overrides) ?
            :($DynamicObjects._identity_hash_fields(__self__::$type) = $DynamicObjects._with_identity_inputs(__self__,
                $(Expr(:tuple, [:(getfield(__self__, $(QuoteNode(n)))) for n in identity_fixed_names]...)))) :
            :($DynamicObjects._identity_hash(__self__::$type) = __self__.__hash__)),
        :($DynamicObjects._version_hash_fields(__self__::$type) = $(Expr(:tuple, [(n in versioned_fixed ? :(getfield(__self__, $(QuoteNode(n)))) : :($DynamicObjects.getorcomputeproperty(__self__, $(QuoteNode(n))))) for n in versioned_names]...))),
    ]
    # ── Static dependency graph ──────────────────────────────────────────────
    # Lower each declaration once, keeping its authored RHS in metadata.
    # Analysis and method emission use the same lowered body. Index by
    # declaration, not name: overloaded properties have distinct bodies.
    opaque_props = Set{Symbol}()
    child_reads = Dict{Symbol,Set{Tuple{Vararg{Symbol}}}}()
    lowered_rhs = Vector{Any}(undef, length(properties))
    for (declaration_index, (name, info)) in enumerate(properties)
        (info.rhs === nothing) && continue        # fixed fields have no RHS
        walked = walk_rhs(deepcopy(info.rhs); locals=copy(info.locals), properties=walk_props, lnn=info.lnn)
        lowered_rhs[declaration_index] = walked
        _collect_self_deps!(info.dependson, walked) && push!(opaque_props, name)
        isempty(source_shared_children) && continue
        _collect_child_reads!(get!(() -> Set{Tuple{Vararg{Symbol}}}(), child_reads, name),
                              walked, source_shared_children)
    end
    filter!(p -> !isempty(last(p)), child_reads)
    # ── `@options` domain declarations ───────────────────────────────────────
    # Each declaration became an ordinary `__options__(::Val{parameter})`
    # property above, so its `dependson` was just populated by the pass above —
    # a domain that reads a sibling is context-dependent, and that is exactly
    # what `dependson` records. Declaration order is body order in both lists.
    option_infos = [info for (name, info) in properties
        if name === :__options__ && Symbol("@options") in info.macros]
    @assert length(option_infos) == length(option_decls)
    option_declaration_records = Pair{Symbol,NamedTuple}[]
    for (decl, info) in zip(option_decls, option_infos)
        dependencies = sort!(collect(info.dependson))
        push!(option_declaration_records, decl.parameter => (;
            parameter=decl.parameter,
            expression=decl.expression,
            expression_string=string(decl.expression),
            dependencies,
            static=isempty(dependencies),
            source=:options,
            lnn=decl.lnn,
        ))
    end
    option_declaration_defs = isempty(option_declaration_records) ? Any[] : Any[
        :($DynamicObjects.option_declarations(::Type{$type_dispatch}) = $option_declaration_records),
    ]
    # ── @versioned computed props: acyclicity guard (decision `b2tsvz`) ───────
    # A computed version dimension must be derivable WITHOUT a cache path: the path
    # is `…/<identity>/<version_tag>`, and `__version_tag__` reads the version prop,
    # so if that prop (transitively) reads a `@cached`/`@mmap` property the read
    # needs `__cache_path__` → `__version_tag__` → the prop again (a cycle). The
    # `dependson` graph is populated just above, so reject it at macro time with a
    # precise message instead of a runtime stack overflow.
    if any(n -> !(n in versioned_fixed), versioned_names)
        _forbidden_ver_deps = union(
            Set{Symbol}(name for (name, info) in oproperties
                        if Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros),
            Set{Symbol}([:__cache_path__, :__version_tag__, :__identity_hash__]))
        # Fixed fields carry `dependson === nothing` (only computed props get a
        # populated Set above), so skip them — they're leaves in the dep walk and
        # `get(…, Set())` below already treats a missing key as no-deps.
        _ver_depmap = Dict{Symbol,Set{Symbol}}(name => info.dependson
            for (name, info) in properties if info.dependson !== nothing)
        for _vname in versioned_names
            _vname in versioned_fixed && continue
            _seen = Set{Symbol}()
            _stack = collect(get(_ver_depmap, _vname, Set{Symbol}()))
            while !isempty(_stack)
                _d = pop!(_stack)
                _d in _seen && continue
                push!(_seen, _d)
                _d in _forbidden_ver_deps && error("@versioned computed property `$_vname` (transitively) depends on `$_d`, whose value needs the cache path — computing the version would then need the version itself (a cycle). Derive the version dimension without reading any @cached/@mmap property or cache-path machinery.")
                append!(_stack, get(_ver_depmap, _d, Set{Symbol}()))
            end
        end
    end
    # ── @versioned + identity override: the version stays out of identity ─────
    # The override names the identity dir and the version names the segment below
    # it, so an override that reads the version gives every version its own
    # identity dir: "hold only the most recent" then has nothing to prune, and a
    # fixed field's `@versioned` (excluded from identity) contradicts it. Follows
    # the reads the body shows; an undeclared `__hash_fields__` is every fixed field.
    if !isempty(versioned_names) && !isempty(identity_overrides)
        _id_depmap = Dict{Symbol,Set{Symbol}}(name => info.dependson
            for (name, info) in properties if info.dependson !== nothing)
        :__hash_fields__ in prop_names || (_id_depmap[:__hash_fields__] = Set{Symbol}(fixed_names))
        for _oname in identity_overrides
            _seen = Set{Symbol}()
            _stack = collect(get(_id_depmap, _oname, Set{Symbol}()))
            while !isempty(_stack)
                _d = pop!(_stack)
                _d in _seen && continue
                push!(_seen, _d)
                _d in versioned_names && error("`$_oname` (transitively) reads `@versioned` property `$_d`. A `@versioned` property is the cache version: it selects the directory below the identity directory that `$_oname` names, so it cannot be part of identity too — every version would get its own identity directory, and \"hold only the most recent\" could never prune the old ones. Leave `$_d` out of `$_oname`.")
                append!(_stack, get(_id_depmap, _d, Set{Symbol}()))
            end
        end
    end
    # ── @state: per-instance state, never derived ────────────────────────────
    # `@state name = init` memoizes like any property, but whole-object clears
    # keep it and `sync!` never drops it (`_state_names`). That is safe only
    # because the initializer derives from nothing a clear or `sync!` could
    # move: it may read fixed fields and other `@state` properties, never a
    # computed property, and never hand `__self__` to other code. A disk or
    # never-cache marker contradicts in-memory state kept for the instance's
    # life.
    state_names = Symbol[name for (name, info) in oproperties if Symbol("@state") in info.macros]
    for (name, info) in oproperties
        Symbol("@state") in info.macros || continue
        conflicts = intersect(info.macros, _STATE_CONFLICTING_MARKERS)
        isempty(conflicts) || error("@state on property `$name`: cannot combine with $(join(sort!(string.(collect(conflicts))), ", ")). `@state` declares in-memory state kept for the instance's life; disk persistence, never-cache, version and queue markers contradict that. Drop one.")
        name in opaque_props && error("@state on property `$name`: the initializer hands `__self__` to other code, so DO cannot prove it derives from no computed property. A `@state` initializer may read fixed fields and other `@state` properties only.")
        derived = sort!(collect(setdiff(info.dependson, fixed_names, state_names)))
        isempty(derived) || error("@state on property `$name`: the initializer reads computed $(length(derived) == 1 ? "property" : "properties") $(join(("`$d`" for d in derived), ", ")). State is never derived, which is what lets clears and `sync!` keep it; a `@state` initializer may read fixed fields and other `@state` properties only. Pass the value in as a fixed field, or make it an ordinary property.")
    end
    state_defs = isempty(state_names) ? Any[] : Any[
        :($DynamicObjects._state_names(::Type{$type_dispatch}) = $(Tuple(unique!(state_names)))),
    ]
    # ── Construction inputs in the default identity (`_identity_input_names`) ──
    # The constructor keywords a body reads join the default identity next to
    # the fixed fields: `__parent__` when read (also through
    # `__self__.__parent__`, which `dependson` records), and any non-indexed
    # property an override can replace. An opaque body may read any of them.
    # A declared `__hash_fields__`/`__hash__` is the identity, so it gets none
    # (snag `include-child-em-c6b53d27`, decision `0e4o8w2`).
    identity_inputs = Symbol[]
    if isempty(identity_overrides)
        read_names = Set{Symbol}()
        for (_, info) in properties
            info.dependson === nothing || union!(read_names, info.dependson)
        end
        excluded = union(Set{Symbol}(fixed_names), state_names, versioned_names)
        candidates = Set{Symbol}(name for (name, info) in properties if !isfixed(info) && !info.indexed)
        push!(candidates, :__parent__)
        for name in candidates
            (name === :__parent__ || !startswith(String(name), "__")) || continue
            name in excluded && continue
            (!isempty(opaque_props) || name in read_names) && push!(identity_inputs, name)
        end
        sort!(identity_inputs)
    end
    identity_defs = isempty(identity_inputs) ? Any[] : Any[
        :($DynamicObjects._identity_input_names(::Type{$type_dispatch}) = $(Tuple(identity_inputs))),
    ]
    # Carry eligibility and direct edges are data, not generated Val tuples
    # containing every property's transitive closure. One traversal handles a
    # remake's changed inputs; the copy loop has no per-property methods.
    inline_child_names = Set{Symbol}(first(p) for p in inline_child_pairs)
    direct_deps = Dict{Symbol,Set{Symbol}}()
    for (name, info) in properties
        isnothing(info.dependson) && continue
        union!(get!(() -> Set{Symbol}(), direct_deps, name), info.dependson)
    end
    carry_names = unique!(Symbol[name for (name, info) in properties
        if !(isfixed(info) || info.indexed || name in inline_child_names ||
             startswith(String(name), "__"))])
    carry_plan = _CarryPlan(carry_names, direct_deps,
                           union(Set{Symbol}(fixed_names), identity_inputs), opaque_props)
    carry_plan_expr = :($DynamicObjects._carry_plan(::Type{$type_dispatch}) = $carry_plan)
    # An inner constructor whose signature does not mention the type parameters
    # cannot use a bare `new` — Julia rejects the definition outright ("too few
    # type parameters specified in new{...}"), which is why a parametric
    # `@dynamicstruct` never expanded. Bind the parameters on the signature
    # (`Foo{K}(…) where {K}`) and apply them to `new`; both collapse to today's
    # exact expressions when there are none.
    _new = _curly(:new)
    _ctor1 = :(function $(_curly(type))($(fixed_lhs...); cache_type=nothing, kwargs...)
        isnothing(cache_type) || error("`cache_type` was removed (2026-07-07, decision 2canrl); the cache is always threadsafe now — drop this kwarg.")
        __inst__ = $_new(
            $(fixed_names...),
            $PropertyCache(
                $ThreadsafeDict,
                (;kwargs...)
            )
        )
        __inst__
    end)
    _ctor2 = :(function $(_curly(type))(::$DynamicObjects._RemountToken, __cache__::$PropertyCache, $(fixed_lhs...))
        $_new(
            $(fixed_names...),
            __cache__
        )
    end)
    _ctor1.args[1] = _where(_ctor1.args[1])
    _ctor2.args[1] = _where(_ctor2.args[1])
    struct_expr = Expr(:struct, mut, head, Expr(:block,
        fixed_lhs..., :(cache::$PropertyCache), _ctor1, _ctor2
    ))
    # `struct Wrapped{T}; value::T; end` normally gets BOTH `Wrapped{Int}(1)` and
    # the inferring `Wrapped(1)`; declaring any inner constructor replaces both.
    # Re-emit the inferring one — but only when every parameter actually occurs
    # in a field's declared type, since `Wrapped(v) where {T}` is otherwise a
    # static parameter Julia has no way to solve.
    _annotated = mapreduce(union, fixed_lhs; init=Set{Symbol}()) do lhs
        Meta.isexpr(lhs, :(::)) ? _type_symbols(lhs.args[2]) : Set{Symbol}()
    end
    _outer_ctor = parametric && all(in(_annotated), param_names) ? Any[
        Expr(:(=),
            _where(Expr(:call, type, Expr(:parameters, :(kwargs...)), fixed_lhs...)),
            Expr(:call, _curly(type), Expr(:parameters, :(kwargs...)), fixed_names...))
    ] : Any[]
    # ── Magic-property deprecation: reject an OLD name DECLARED in a body ────
    # (2026-07-07, decision 2canrl). Declaring an old data-side name would
    # silently become a plain user property (no disk-cache/content-addressing
    # behavior) now that the magic property lives under its dunder name — so
    # error at expansion. Same registry as the runtime access-shims (no drift).
    for (nm, _) in oproperties
        if haskey(_RENAMED_MAGIC, nm)
            error("`@dynamicstruct $type`: property `$nm` was renamed to " *
                  "`$(_RENAMED_MAGIC[nm])` (2026-07-07, decision 2canrl) — declare " *
                  "`$(_RENAMED_MAGIC[nm]) = …` instead of `$nm = …`.")
        elseif haskey(_REMOVED_MAGIC, nm)
            error("`@dynamicstruct $type`: property `$nm` was removed " *
                  "(2026-07-07, decision 2canrl); $(_REMOVED_MAGIC[nm]).")
        end
    end
    result = Expr(:block)
    # Emit per-cached-property DiskCacheLocks
    for (name, varname) in cached_names
        push!(result.args, :($varname = $DiskCacheLocks()))
    end
    # Prepend extracted inline child structs (processed recursively)
    _child_handler = isnothing(child_handler) ? (s -> dynamicstruct(s; is_child=true, lint)) : child_handler
    for s in extracted_structs
        child_result = _child_handler(s)
        # Unwrap esc() — parent handles escaping
        @assert Meta.isexpr(child_result, :escape)
        push!(result.args, child_result.args[1])
    end
    # Per-name marker dedup: `_never_cache` and `_self_named_index` are keyed
    # by (type, name) only, but `oproperties` is per-DECLARATION — same-name
    # declarations (multi-verb routes: `@get x` + `@post x`) would each emit
    # an identical method, and Julia rejects the duplicate during
    # precompilation ("Method overwriting is not permitted"). The per-name
    # emissions below fire only for the first declaration carrying them.
    # One set per marker, not one shared set: a name may carry `@fresh` on
    # one declaration and a self-named index on another, and both methods
    # must still be emitted.
    _never_cache_emitted = Set{Symbol}()
    _self_named_emitted = Set{Symbol}()
    _queued_emitted = Set{Symbol}()
    # Docstring precedence — without emitting two `@doc` calls (which would
    # warn "Replacing docs" on every Revise reload and, worse, cause
    # `Core.@__doc__` to copy the parent's user docstring onto hoisted
    # inline children by walking every `Base.@__doc__` marker in the
    # expansion):
    #   1. Emit the struct definition bare.
    #   2. Install the auto-generated property-list docstring as a
    #      `Base.Docs.getdoc(::Type{T})` fallback. It's guarded to return
    #      `nothing` when a docstring is already registered for the
    #      binding, so a user docstring always wins.
    #   3. For top-level structs only (`is_child=false`), emit
    #      `Base.@__doc__ $type` as the hook that `Core.@__doc__` rewrites
    #      into `@doc "userdoc" $type` when the user wrote
    #      `"""userdoc"""\n@dynamicstruct struct X ... end`. Children omit
    #      this marker so the parent's user docstring doesn't bleed into
    #      hoisted inline child structs.
    push!(result.args, Expr(:block,
        struct_expr,
        _outer_ctor...,
        :($Base.Docs.getdoc(::Type{$type_dispatch}) = begin
            __b = $Base.Docs.Binding(parentmodule($type), nameof($type))
            __m = get($Base.Docs.meta(__b.mod), __b, nothing)
            (__m === nothing || isempty(__m.docs)) ? $docstring : nothing
        end),
        (is_child ? :($type) : :(Base.@__doc__ $type)),
        quote
            $Base.hasproperty(__self__::$type, name::Symbol) = name in $(Tuple(prop_names))
            $Base.@inline $Base.getproperty(__self__::$type, name::Symbol) =
                hasfield(typeof(__self__), name) ? getfield(__self__, name) :
                    $getorcomputeproperty(__self__, name)
            $Base.setproperty!(__self__::$type, name::Symbol, value) = $_reject_setproperty(__self__, name)
            $DynamicObjects.meta(::Type{$type_dispatch}) = $properties
            $(option_declaration_defs...)
            $carry_plan_expr
            $DynamicObjects._remount_opaque_properties(::Type{$type_dispatch}) = $(Tuple(sort!(collect(opaque_props))))
            $DynamicObjects._remount_child_reads(::Type{$type_dispatch}) = $(Tuple(
                (name, Tuple(sort!(collect(paths)))) for (name, paths) in sort!(collect(child_reads); by=first)))
            $DynamicObjects.is_generated_property(::$type, name::Symbol) = name in $generated_names
            $DynamicObjects.is_indexed_property(::$type, name::Symbol) = name in $indexed_names
            $DynamicObjects._hash_replace(__self__::$type) = __self__.__hash__
            $(versioned_defs...)
            $(state_defs...)
            $(identity_defs...)
            $([:(
                $DynamicObjects._disk_cache(::$type, ::Val{$(QuoteNode(name))}) = $varname
            ) for (name, varname) in cached_names]...)
            $([:(
                $DynamicObjects._disk_format(::$type, ::Val{$(QuoteNode(name))}) = $(Val(:mmap))
            ) for name in mmap_names]...)
            $([:(
                $DynamicObjects._disk_eltype(::$type, ::Val{$(QuoteNode(name))}) = $(something(mmap_eltypes[name], :nothing))
            ) for name in mmap_names]...)
            $([:(
                $DynamicObjects._check_mmap_annotation($(QuoteNode(type)), $(QuoteNode(name)), $(mmap_eltypes[name]))
            ) for name in mmap_names if !isnothing(mmap_eltypes[name])]...)
            $([:(
                $DynamicObjects._nested_struct_type(::Type{$type_dispatch}, ::Val{$(QuoteNode(prop_name))}) = $gen_name
            ) for (prop_name, gen_name) in inline_child_pairs]...)
            $([:(
                $DynamicObjects._source_shared_child(::Type{$type_dispatch}, ::Val{$(QuoteNode(prop_name))}) = true
            ) for prop_name in unique(source_shared_children)]...)
            $([:(
                $DynamicObjects._analysis_nested_type(::Type{$type_dispatch}, ::Val{$(QuoteNode(prop_name))}) = $gen_name
            ) for (prop_name, gen_name) in analysis_child_pairs]...)
            # Per-T `_type_description` override — delegates to a runtime
            # resolver that reads the user-attached docstring (if any). Lets
            # `@include`-emitted `_property_description` overrides bubble
            # `T`'s docstring up as the progress label when `T(args)` is
            # constructed via an IP.
            $DynamicObjects._type_description(::Type{$type_dispatch}, args...; kwargs...) =
                $DynamicObjects._resolve_type_description($type, args, (; kwargs...))
            $Base.show(io::IO, __self__::$type) = begin
                print(io, $(string(type)), "(")
                $([let sep = i == 1 ? :() : :(print(io, ", "))
                    quote; $sep; print(io, $(string(fn)), "="); show(io, getfield(__self__, $(QuoteNode(fn)))); end
                end for (i, fn) in enumerate(fixed_names)]...)
                $(isempty(fixed_names) ? :() : :(print(io, "; ")))
                show(io, getfield(__self__, :cache))
                print(io, ")")
            end
        end,
        [
            begin
                # `@fresh` marker validation (macro-time). The marker declares a
                # never-cache call form, so two combinations are contradictory and
                # rejected here rather than silently emitting an inert/wrong method:
                #   (a) on a bare scalar property — it memoizes via PropertyCache, a
                #       different mechanism the IP-call-form `_never_cache` never
                #       reaches; an unhelpful silent no-op without this guard.
                #   (b) with @cached/@mmap — "never caches" vs "disk-caches" cannot
                #       both hold; allowing it would serve a stale disk value under a
                #       never-cache marker.
                if Symbol("@fresh") in info.macros
                    info.indexed || error("@fresh on property `$name`: the never-cache marker applies only to call-form / indexed properties (`@fresh $name() = …`). A bare scalar property `$name = …` memoizes via PropertyCache (a different mechanism) — use the call form, or drop @fresh.")
                    (Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros) && error("@fresh on property `$name`: cannot combine with @cached/@mmap. `@fresh` declares the property never caches; @cached/@mmap declare a disk cache — these are contradictory. Drop one.")
                end
                # `@queued` marker validation (macro-time). The marker admits every
                # computation of the property through the job queue — memoized ones through
                # its declared executor, fresh ones as `QueuedCall`s — and DO declares an
                # executor only for call-form properties.
                if Symbol("@queued") in info.macros
                    info.indexed || error("@queued on property `$name`: the marker admits the memoized computations of a call-form / indexed property through the job queue (`@queued $name() = …`). A bare property `$name = …` memoizes via PropertyCache, never through an executor — use the call form, or drop @queued.")
                end
                # `@struct` inline-child validation (macro-time). The inline-child
                # rewrite that turns `@struct $name(…) = begin … end` into a child
                # type — with a `__parent__ = nothing` field the parent wires to
                # `__self__` at construction — runs in EARLIER passes that peel only
                # `@doc` and `@fresh` before finding `@struct`. Any OTHER wrapping
                # marker parses as `@wrapper(@struct(…))` and is skipped by those
                # passes, so `@struct` survives here in `info.macros` instead of
                # having been consumed into a child. The child type and its
                # `__parent__` field would then never be emitted, so the body's
                # `__parent__` reference would be unbound and the call form would
                # throw `UndefVarError: __parent__` the first time it is hit — a
                # clean compile that breaks only live, the same failure class the
                # bare-scalar `@fresh` guard above prevents. Reject it here.
                # (`@fresh @struct` IS supported — it is threaded through the
                # rewrite so the call form builds a fresh child per call; a
                # disk-cache marker `@cached`/`@mmap` on an inline child is not.)
                if Symbol("@struct") in info.macros
                    _wrappers = sort!(string.(collect(setdiff(info.macros, [Symbol("@struct")]))))
                    _wrapper_desc = isempty(_wrappers) ? "another macro" : join(_wrappers, ", ")
                    error("@struct on property `$name`: `@struct` must be outermost (only `@doc` and `@fresh` may wrap it), but here it is wrapped by $_wrapper_desc. A wrapping marker shadows the inline-child rewrite, so the child type and its injected `__parent__` are never emitted and the property would throw `UndefVarError: __parent__` when its call form is first hit (a clean compile that breaks only live). Write `@struct $name(…) = begin … end` (optionally `@fresh @struct $name(…) = …` for a fresh child per call). Disk-cache markers `@cached`/`@mmap` on an inline child are not supported — disk-cache a plain computed property instead.")
                end
                # An index arg may legitimately be named after the property it
                # indexes — `dataset(dataset::Dataset) = DatasetWorkspace(dataset)`
                # reads as "the workspace FOR this dataset". The self-named kwarg
                # below would then be a second argument called `dataset` in the
                # same signature, which Julia rejects outright ("function argument
                # name not unique"). Suppress it: the index arg is in `locals`, so
                # the body's bare `dataset` already resolves to the positional and
                # the kwarg was unreachable anyway. `_self_named_index` tells
                # `_computeproperty` not to pass the resume value it can no longer
                # receive.
                self_named_index = name in extractnames(collect(info.indices))
                cp_kwargs = Any[]
                self_named_index || push!(cp_kwargs,
                    Expr(:kw, name, length(info.indices) > 0 ? :(__self__.$name) : nothing))
                name != :__status__ && push!(cp_kwargs, Expr(:kw, :__status__, :nothing))
                # Build method definitions with Expr directly (not :() syntax)
                # so the parser doesn't insert DynamicObjects.jl LNNs into
                # the method body — Julia uses the body's first LNN for
                # Method.file/line, which must point at user code.
                _lnn = something(info.lnn, LineNumberNode(0, :unknown))
                # Walk kwarg defaults with kwarg names excluded from locals,
                # so that `seed=seed` correctly transforms the default `seed`
                # into `__self__.seed` rather than leaving it as a bare symbol.
                kwarg_names = Set{Symbol}()
                for idx in info.indices
                    Meta.isexpr(idx, :parameters) || continue
                    for a in idx.args
                        Meta.isexpr(a, :kw) && push!(kwarg_names, a.args[1] isa Expr ? a.args[1].args[1] : a.args[1])
                    end
                end
                defaults_locals = setdiff(info.locals, kwarg_names)
                walked_indices = map(info.indices) do idx
                    if Meta.isexpr(idx, :parameters)
                        Expr(:parameters, map(idx.args) do a
                            if Meta.isexpr(a, :kw)
                                Expr(:kw, a.args[1], walk_rhs(a.args[2]; locals=defaults_locals, properties=walk_props, lnn=info.lnn))
                            else
                                a
                            end
                        end...)
                    else
                        idx
                    end
                end
                # `__self__::Foo{Kind} … where {Kind}` rather than `__self__::Foo`
                # — dispatch-equivalent, but it BINDS the type parameters, so a
                # property body may read them the way it reads a sibling
                # (`tagged = string(base, "-", Kind)`). Identity when the struct
                # has no parameters.
                _call(f, extras...) = _where(fixcall(Expr(:call,
                    Expr(:., DynamicObjects, QuoteNode(f)),
                    :(__self__::$(_curly(type))), :(::Val{$(Meta.quot(name))}),
                    walked_indices..., Expr(:parameters, extras...),
                )))
                iscached_val = Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros
                # Per-signature documentation flag + (when documented) the
                # doc-derived label override.
                #
                # Gate on the PER-DECLARATION `info.doc`, never a name-keyed docs
                # map (which would collapse duplicate names last-doc-wins): a
                # property with multiple signatures has one `info` per signature,
                # and each must reflect ITS OWN docstring. Both the
                # `_is_property_documented` flag (the show-label-vs-inline gate
                # the Treebars ext reads) and the `_property_description` override
                # (the rendered label) are emitted per signature here, so Julia's
                # own dispatch on `args...` selects the right one at call time —
                # no parallel signature matcher.
                #
                # The flag is emitted for EVERY declaration — `true` when
                # documented, `false` when not — so a re-expanded struct never
                # falls through to the default `_is_property_documented` (the
                # historic first-sig `metafirst` gate kept for not-yet-re-expanded
                # structs): an undocumented signature of a multi-sig property must
                # read `false`, not the first declaration's doc-presence.
                has_user_kw_splat = any(walked_indices) do idx
                    Meta.isexpr(idx, :parameters) && any(a -> Meta.isexpr(a, :...), idx.args)
                end
                doc_extras = has_user_kw_splat ? () : (:(kwargs...),)
                isdoc_expr = (_lnn, Expr(:(=), _call(:_is_property_documented, doc_extras...),
                                         Expr(:block, _lnn, !isnothing(info.doc))))
                desc_expr = if !isnothing(info.doc)
                    pdoc = info.doc
                    # Walk the docstring expression so interpolated bare names
                    # resolve through the same scope rules as the property's
                    # body: sibling-property references (`$method`,
                    # `$top_chains`, …) get rewritten to `__self__.<name>`,
                    # while the property's own indices and kwargs stay as
                    # plain locals (they're in the emitted method signature).
                    # String literals with no interpolation are passed through
                    # unchanged by `walk_rhs`.
                    walked_doc = walk_rhs(pdoc; info.locals, properties=walk_props, lnn=info.lnn)
                    (_lnn, Expr(:(=), _call(:_property_description, doc_extras...), Expr(:block, _lnn, walked_doc)))
                else
                    nothing
                end
                walked_rhs = lowered_rhs[declaration_index]
                # `@dynamic_progress`-marked: emit the 2-arg form
                # `@dynamic_progress __status__ <body>`. The macro (defined
                # above) handles both the call-site rewrite AND the Tb
                # `@progress __status__ <body>` wrap that binds `__progress__`
                # inside the body. Same outside→in macro expansion order as
                # before — `@memo!` calls inside still expand after, so the
                # `maybememoize!(maybeprogress!, …)` stacking dispatch arms
                # pick them up.
                if Symbol("@dynamic_progress") in info.macros
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(@__MODULE__, Symbol("@dynamic_progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        walked_rhs)
                end
                # `@fetch!`-marked: emit `@fetch! __status__ <body>`. Sugar for a
                # thin progress-reporting pass-through property — `@fetch!`
                # rewrites every call in the body to
                # `maybefetchindex!(__status__, …)` and every property access to
                # `maybefetchproperty!(__status__, …)`, so a call down to an
                # expensive sibling IP both memoizes AND mounts its progress
                # subtree under the caller-bound `__status__`. Parallel to the
                # `@dynamic_progress` branch above, but threads the memoizing
                # `@fetch!` (cached + progress) rather than `maybeprogress!`
                # (progress only) — the right default for wrappers over cached /
                # `@mmap` work. `__status__` defaults to `nothing` (no caller
                # progress / Tb absent), in which case `@fetch!` degrades to
                # `memoize!` and Treebars stays a weakdep.
                if Symbol("@fetch!") in info.macros
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(@__MODULE__, Symbol("@fetch!")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        walked_rhs)
                end
                # `@progress`-marked (decision w0rn26 → A): wrap the body in
                # `Treebars.@progress __status__ begin … end` and rewrite the body's
                # self-property / self-IP accesses to thread `__progress__` (the var
                # that block binds). The block roots a progress context at the
                # property's `__status__` (the substatus a parent threaded in;
                # `nothing` when none → the wrap is a transparent no-op and the
                # `maybefetch*` calls degrade to `memoize!` / `getproperty`), so the
                # property's self-accesses hang under the caller's ambient phase —
                # ambient nesting, behaving like Tb's `@progress`. The self-access
                # rewrite runs FIRST (on the walked body), so `__progress__` is
                # literal in the source the `Treebars.@progress` walker then renames;
                # the wrap is emitted as a qualified `Treebars.@progress` (DO does NOT
                # export a `@progress` macro — `@progress` is only the parse-marker
                # the generic `_apply_property_macro!` captures). Direct `maybefetch*`
                # calls (NOT a nested `@fetch! __progress__ …`) avoid the `fecc238`
                # outside-in dangling-`__progress__` footgun.
                if Symbol("@progress") in info.macros
                    # Pass the rewritten body to Treebars.@progress. If it is already a
                    # block, pass it DIRECTLY — wrapping a block inside another block
                    # buries inline `@progress "phase"` markers one level deep, and Tb
                    # requires a phase marker to be a DIRECT statement of the enclosing
                    # @progress block (else: "phase marker must be a direct statement of
                    # an enclosing @progress block"). Only a bare-expr body needs a fresh
                    # block wrapper.
                    # Reads on other objects nest too (decision `0yvb74c`), through the
                    # implied rewrite; `__self__` reads keep the marker's own threading.
                    _rewritten = _progress_self_rewrite(
                        _implied_progress_rewrite(:__progress__, walked_rhs, false))
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(Treebars, Symbol("@progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        Meta.isexpr(_rewritten, :block) ? _rewritten : Expr(:block, _rewritten))
                end
                # `@PROGRESS`-marked: the "throw everything at @progress" form. Exactly
                # like `@progress` above, but rewrites the body with `_fetch_rewrite`
                # (what `@fetch!` emits — every call → `maybefetchindex!(__progress__, …)`,
                # every access → `maybefetchproperty!(__progress__, …)`) instead of the
                # self-only `_progress_self_rewrite`. So EVERY call/access threads progress
                # (and memoizes), not just bare sibling accesses. Same `Treebars.@progress
                # __status__` wrap; `__progress__` stays literal in the emitted maybefetch*
                # calls, so Tb's outside-in walker renames it — the same fecc238-footgun-free
                # path as `@progress`, and inline `@progress`/`@phases` markers in the body
                # still work (Tb expands the wrap first).
                if Symbol("@PROGRESS") in info.macros
                    _rewritten_all = _fetch_rewrite(:__progress__, walked_rhs)
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(Treebars, Symbol("@progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        Meta.isexpr(_rewritten_all, :block) ? _rewritten_all : Expr(:block, _rewritten_all))
                end
                # UNMARKED — the default, so the shape almost every property takes.
                # Progress nesting is implied (decision `0yvb74c`): every property read
                # written in the body passes the body's node along
                # (`_implied_progress_rewrite`), bound to `__progress__` here. A marker
                # above owns its body instead, and DO's own `__…__` properties
                # (`__status__`, `__substatus__`, `__hash__`, …) have no node to nest under.
                if !_is_progress_marked(info.macros) && !_is_dunder(name)
                    walked_rhs = _implied_progress_wrap(
                        _implied_progress_rewrite(:__progress__, walked_rhs), _lnn)
                end
                block = Expr(:block,
                    _lnn, Expr(:(=), _call(:compute_property, cp_kwargs...), Expr(:block, _lnn, walked_rhs)),
                    _lnn, Expr(:(=), _call(:iscached), Expr(:block, _lnn, iscached_val)),
                    _lnn, Expr(:(=), _call(:resumes), Expr(:block, _lnn, false)),
                )
                if !isnothing(info.cache_version)
                    # Don't use _call — cache_version is per-property, not per-index
                    cv_method = _where(Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:cache_version)),
                        :(__self__::$(_curly(type))), :(::Val{$(Meta.quot(name))}),
                    ))
                    cv_expr = (_lnn, Expr(:(=), cv_method, Expr(:block, _lnn, info.cache_version)))
                    push!(block.args, cv_expr...)
                end
                # `@fresh`-marked: emit `_never_cache(__self__::T, ::Val{name}) =
                # true` so the IP call form routes to the uncached `fresh` instead
                # of `memoize!`. Per-property (keyed by name only, no indices) —
                # same direct-`Expr` shape as `cache_version`, not `_call`.
                # First declaration wins: same-name repeats would emit an
                # identical method (see `_never_cache_emitted` above).
                if Symbol("@fresh") in info.macros && name ∉ _never_cache_emitted
                    push!(_never_cache_emitted, name)
                    nc_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:_never_cache)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    nc_expr = (_lnn, Expr(:(=), nc_method, Expr(:block, _lnn, true)))
                    push!(block.args, nc_expr...)
                end
                # `@queued`-marked: emit `property_executor(__self__::T, ::Val{name})`
                # returning the job queue's executor, so every computation of the
                # property — memoized or fresh — waits its turn in `job_queue()`, whoever
                # calls it. First declaration wins, as with `_never_cache` above.
                if Symbol("@queued") in info.macros && name ∉ _queued_emitted
                    push!(_queued_emitted, name)
                    pe_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:property_executor)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    pe_body = :($DynamicObjects._queued_executor($(Meta.quot(name))))
                    push!(block.args, _lnn, Expr(:(=), pe_method, Expr(:block, _lnn, pe_body)))
                end
                # See the suppression above: this property has no kwarg named
                # after itself, so the disk-cache resume value must not be passed.
                # First declaration wins, as with `_never_cache` above.
                if self_named_index && name ∉ _self_named_emitted
                    push!(_self_named_emitted, name)
                    sni_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:_self_named_index)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    push!(block.args, _lnn, Expr(:(=), sni_method, Expr(:block, _lnn, true)))
                end
                push!(block.args, isdoc_expr...)
                !isnothing(desc_expr) && push!(block.args, desc_expr...)
                block
            end
            for (declaration_index, (name, info)) in enumerate(oproperties) if !isfixed(info)
        ]...,
        # IndexableProperty wrappers for indexed properties are now created
        # directly in getorcomputeproperty (via meta check), so no zero-arg
        # compute_property methods are needed here.
    ))
    # Emit inline-method definitions collected from the struct body. These are
    # plain methods on `::type` (so standard multiple dispatch on the remaining
    # args works) — no property entry, no compute_property, not reachable via
    # getproperty. Preserve the user's complete signature, changing only a bare
    # positional `__self__` to `__self__::<type>`. The body is walked with the
    # `prop_names` set so bare references to registered property names are
    # rewritten to `__self__.<name>`, matching the property-RHS rewrite.
    for m in inline_methods
        sig = deepcopy(m.signature)
        call = something(_inline_method_call(sig))
        sig_args = call.args[2:end]
        # Type the bare `__self__` arg to `__self__::<type>`. If the user
        # already wrote `__self__::T`, leave the user's annotation alone.
        if sig_args[m.self_idx] === :__self__
            call.args[m.self_idx + 1] = :(__self__::$type)
            sig_args = call.args[2:end]
        end
        # Locals shielded from bare-name rewriting: `__self__`, every name
        # introduced by the signature args (incl. typed/destructured/kw),
        # and all `where`-clause type parameters.
        method_locals = Set{Symbol}([:__self__])
        for a in sig_args
            union!(method_locals, extractnames([a]))
        end
        for wp in m.where_params
            wp isa Symbol && push!(method_locals, wp)
            Meta.isexpr(wp, :(<:)) && wp.args[1] isa Symbol && push!(method_locals, wp.args[1])
            Meta.isexpr(wp, :comparison) && wp.args[1] isa Symbol && push!(method_locals, wp.args[1])
        end
        walked_body = walk_rhs(m.body; locals=method_locals, properties=walk_props, lnn=m.lnn)
        method_lnn = something(m.lnn, LineNumberNode(0, :unknown))
        push!(result.args, Expr(:(=), sig, Expr(:block, method_lnn, walked_body)))
    end
    esc(result)
end

# Replace only the top-level LineNumberNodes in a block, leaving nested ones intact.
# This gives Revise the source-location metadata it needs to track method changes,
# while preserving internal LineNumberNodes for useful stacktraces.
function setlnn(lnn::Union{LineNumberNode,Nothing})
    function(expr::Expr)
        isnothing(lnn) && return expr
        @assert expr.head == :block
        Expr(:block, map(x -> _replace_lnn(x, lnn), expr.args)...)
    end
end

# The `cache_type` MACRO option (a bare `:parallel`/`:serial`, or `cache_type=…`)
# was removed 2026-07-07 (decision 2canrl) — the cache is always a `ThreadsafeDict`
# now. Reject it at macro-parse with a clear message (mirrors the ctor-kwarg
# deprecation) rather than letting it fall through to an opaque unsupported-kwarg
# error. `_parse_macro_opt` is a plain function the macro calls at expansion.
# `obj.prop = value` is deliberately unsupported (user, 2026-09-05, decision
# 1srli5g): a `@dynamicstruct` instance is immutable, and its property cache is
# written only by DO's own compute/seed paths. Overrides go in at
# construction — the generated constructor seeds the cache from its kwargs —
# or through `remake`, which reconstructs with the same seeding. Before this
# the generated method wrote straight into the cache: a silent no-op for a
# fixed field (the read path serves those from `getfield`), and — since the
# cache became always-`ThreadsafeDict`, which has no `setindex!` — an opaque
# `MethodError` for everything else (snag dynamicstruct-se-7099e55c).
_reject_setproperty(o, name::Symbol) = error(
    "setproperty!: a `", nameof(typeof(o)), "` (a @dynamicstruct) is immutable — `obj.", name,
    " = value` is not supported. Override a property at construction, `", nameof(typeof(o)),
    "(…; ", name, "=value)`, or reconstruct with `remake(obj; ", name, "=value)`.")
_reject_cache_type_opt() = error("@dynamicstruct: the `cache_type` macro option was removed (2026-07-07, decision 2canrl); the cache is always threadsafe (`ThreadsafeDict`) now — drop it.")

# Parse a single positional macro arg into a (kwarg-name => value) pair.
# `name=value` Expr → `(name => value)`. String/`:string` → `(:docstring => …)`.
# Anything else is rejected with a pointer to the recognised forms.
_parse_macro_opt(a::AbstractString) = (:docstring => a)
_parse_macro_opt(a::QuoteNode) = _reject_cache_type_opt()
_parse_macro_opt(a::Expr) = if a.head === :string
    (:docstring => a)
elseif a.head === :(=) && a.args[1] isa Symbol
    a.args[1] === :cache_type && _reject_cache_type_opt()
    (a.args[1] => a.args[2])
else
    error("@dynamicstruct: unsupported option `$a` — use a docstring or `name=value`.")
end
_parse_macro_opt(a) = error("@dynamicstruct: unsupported option `$a` — use a docstring or `name=value`.")

"""
    @dynamicstruct struct Name ... end

Define a struct whose fields are constructor inputs and whose properties compute
lazily. A declaration without `=` is a fixed field; `name = expression` is a
scalar property; `name(arguments...; keywords...) = expression` is an indexed
property. Property bodies may read sibling fields and properties by bare name.
Constructor keywords override defaults and seed the instance cache.

Ordinary reads memoize. Indexed calls match argument values with `isequal`.
Treat inputs, arguments and cached results as immutable; use [`remake`](@ref)
for changed inputs and [`@clear_cache!`](@ref) for explicit invalidation.

Markers inside the struct body select additional behavior:

| Marker | Meaning |
| --- | --- |
| `@struct child = begin ... end` | Nested object, with parent properties in scope. |
| `@struct child(arguments...) = begin ... end` | Nested object per argument tuple. |
| `@cached [v"N"] name = expression` | Serialized disk storage, optionally versioned. |
| `@mmap name = expression` | Disk storage using a supported memory-mapped format. |
| `@fresh name(arguments...) = expression` | Uncached indexed computation. |
| `@state name = expression` | Instance state retained by memory clears and synchronization. |
| `@versioned name = expression` | Object-wide disk-cache version dimension. |
| `@queued name(arguments...) = expression` | Indexed work submitted through the job queue. |
| `@options(parameter) = expression` | Declared domain for an input name. |

An indexed declaration may take no arguments. Disk storage is independent of
indexing and polling. Both scalar and indexed properties support polling via
[`fetchproperty`](@ref) and [`fetchindex`](@ref). Ordinary blocking reads compute
inline unless an executor changes that policy; polling can start background work.

The default progress root is a Treebars node. Property docstrings label child
nodes. Pass `__status__ = nothing` at construction to disable progress.
`__cache_base__` selects the disk-cache directory. Use `__hash_fields__` only
when the application needs an explicit content identity.

A state initializer may read fixed fields and other state properties only.
It cannot combine with disk, fresh, version or queue markers. Reset state with
[`@clear_cache!`](@ref).
"""
macro dynamicstruct(args...)
    isempty(args) && error("@dynamicstruct: missing struct definition.")
    expr = last(args)
    kwargs = Dict{Symbol,Any}(_parse_macro_opt(a) for a in args[1:end-1])
    dynamicstruct(expr; kwargs...)
end

