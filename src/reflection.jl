"""    property_source_info(T::Type, prop::Symbol)
        -> Union{Nothing, NamedTuple{(:rhs_string, :signature, :macros, :dependson), …}}

Extract a property's RHS expression, signature, macro chain, and
dependson set from `meta(T)`. Returns:

- `nothing` if `meta(T)` is undefined,
- `(; rhs_string=:meta_missing, signature, …)` if the prop isn't on `T`,
- otherwise a NamedTuple with:
  - `rhs_string::String` — the lnn-stripped expression as a string, or
    `"(no rhs — forwarded/typed property)"` if `info.rhs === nothing`.
  - `signature::String` — `"name"` or `"name(arg, …)"`.
  - `macros::String` — `"@cached "` etc. (trailing space if non-empty).
  - `dependson::Vector{Symbol}` — sorted dependency names.

Pure data extraction. Renderers turn this into HTML / markdown /
terminal output.
"""
function property_source_info(T::Type, prop::Symbol)
    props = try meta(T) catch; nothing end
    props === nothing && return nothing
    # `metafirst` matches the previous `props[prop]` semantics: if duplicate
    # declarations exist, callers of `property_source_info` get the first.
    info = metafirst(T, prop)
    info === nothing && return (; rhs_string="(property $prop not found on $(nameof(T)))",
                                  signature=string(prop),
                                  macros="",
                                  dependson=Symbol[])
    rhs_string = info.rhs === nothing ? "(no rhs — forwarded/typed property)" :
                 string(Base.remove_linenums!(deepcopy(info.rhs)))
    signature = isempty(info.indices) ? string(info.lhs) :
                string(info.lhs, "(", join(info.indices, ", "), ")")
    macros = isempty(info.macros) ? "" : join(string.(info.macros), " ") * " "
    dependson = isempty(info.dependson) ? Symbol[] : sort!(collect(info.dependson))
    (; rhs_string, signature, macros, dependson)
end

"""    property_signature(T::Type, prop::Symbol) -> Union{Nothing, NamedTuple}
        property_signature(info::NamedTuple, mod::Module) -> NamedTuple

Structured call signature for an indexed property, parsed from `info.indices`
(the argument list the macro captured from the LHS call). The structured
counterpart to `property_source_info`'s stringy `signature`.

Two entry points:

- `property_signature(T, prop)` — look `prop` up in `meta(T)` (first
  declaration, via `metafirst`) and parse it against `parentmodule(T)`. Returns
  `nothing` if `meta(T)` is undefined or `prop` isn't a property of `T`.
- `property_signature(info, mod)` — parse an *already-selected* `meta` info
  against module `mod`, without re-looking it up. Use this when the caller
  holds a specific declaration. The key case is multi-verb / duplicate-name
  routes: several declarations can share one property name (e.g. a `@get` and
  a `@post` on `user`), so `meta(T)` carries duplicates and `metafirst` would
  collapse them to the first. Walk `metaall(T, prop)` and call this per
  declaration. Always returns a (possibly empty) `(; positional, kwargs)`.

Both yield `(; positional, kwargs)`, where every entry is a NamedTuple
`(; name, type, required, default, vararg)`:

- `name::Union{Symbol,Nothing}` — the argument name (`nothing` for an anonymous
  `::T` positional).
- `type::Union{Type,Nothing}` — the annotation resolved against `mod` by
  `DynamicObjects.resolve_annotation`, or `nothing` when un-annotated OR
  unresolvable (e.g. a free static-parameter type-var like the `V` in
  `Verb{V}`). Consumers map `nothing` to their permissive default
  (HTMXObjects → `String`). The answer is the same while a package image is
  written (a `@compile_workload`, or an `__init__` run while another package
  precompiles) as at run time, though `mod` is then closed to evaluation.
- `required::Bool` — `true` unless the arg carries a default or is a vararg.
- `default` — the default-value *expression* when `required === false`;
  `nothing` (and meaningless) when `required === true`. A literal `nothing`
  default is told apart from "no default" only by `required === false`.

- `vararg::Bool` — `true` for a splat (`x...` / `x::T...`), which is otherwise
  indistinguishable from a plain optional arg: both report `required=false`.
  Consumers that build a call template need the difference (an open-ended
  `path...` segment is not a single optional `path`).

A non-indexed property (no call signature) yields empty `positional` and
`kwargs`. A vararg is unwrapped to its inner name/type with `required=false`
and `vararg=true`.

Layering — intentionally verb-agnostic: this returns *every* positional arg,
including any framework-injected leading arg (e.g. HTMXObjects' injected
`__verb__::Verb{V}`). Filtering such args — and selecting *which* declaration a
verb maps to — is the consumer's job. `@param`-derived properties are not
indexed properties and carry no `info.indices`; their parsed shape lives in
`info.rhs` and is the consumer's concern.

Pure data extraction. See also `property_source_info`.
"""
function property_signature(T::Type, prop::Symbol)
    props = try meta(T) catch; nothing end
    props === nothing && return nothing
    # First declaration wins. Multi-verb / duplicate-name callers that must
    # disambiguate should walk `metaall(T, prop)` and call the `(info, mod)`
    # method per declaration instead.
    info = metafirst(T, prop)
    info === nothing && return nothing
    property_signature(info, parentmodule(T))
end

function property_signature(info::NamedTuple, mod::Module)
    positional = NamedTuple[]
    kwargs = NamedTuple[]
    for idx in info.indices
        if Meta.isexpr(idx, :parameters)
            # Everything after the `;` — keyword args (and any `; kw...` slurp).
            for kw in idx.args
                push!(kwargs, _parse_signature_arg(kw, mod))
            end
        else
            push!(positional, _parse_signature_arg(idx, mod))
        end
    end
    (; positional, kwargs)
end

# Parse one argument node from `info.indices` into `(; name, type, required,
# default)`. Handles every call-LHS arg shape the macro can capture:
#   x          x::T          required, untyped / typed
#   x=d        x::T=d        optional positional / defaulted kwarg
#   x...       x::T...       vararg — required=false, splat unwrapped
#   ::T                      anonymous positional — name=nothing
# Shared by positional args and the members of an `Expr(:parameters,…)` kwargs
# node; the positional-vs-keyword distinction is the caller's (by where the
# node sits), so this peels uniformly.
function _parse_signature_arg(node, mod)
    required = true
    default = nothing
    vararg = false
    if Meta.isexpr(node, :kw)            # `x = d` / `x::T = d`
        required = false
        default = node.args[2]
        node = node.args[1]
    end
    if Meta.isexpr(node, :...)           # `x...` — 0+ args, so not required
        required = false
        vararg = true
        node = node.args[1]
    end
    typeexpr = nothing
    nm = node
    if Meta.isexpr(node, :(::))
        if length(node.args) == 2        # `name::T`
            nm, typeexpr = node.args
        else                             # `::T` — anonymous arg
            nm, typeexpr = nothing, node.args[1]
        end
    end
    (; name = nm isa Symbol ? nm : nothing,
       type = _resolve_arg_type(typeexpr, mod),
       required, default, vararg)
end

"""    DynamicObjects.resolve_annotation(mod::Module, ex) -> Any

The value the annotation expression `ex` names in module `mod`: what
`Core.eval(mod, ex)` returns, found without evaluating into `mod`, so it also
works while a package image is being written. Julia then refuses `Core.eval`
into every module except the one being compiled, even for a plain name, which
is the situation of a `@compile_workload`, or of an `__init__` run while
another package precompiles, that reflects a type from a package it depends
on.

Resolved by looking names up and applying them:

- a name (`Symbol`, `Alias`), `Mod.Name`, a `GlobalRef`, a quoted value
  (`:x` in `Val{:x}`) or a literal (`2` in `NTuple{2,Int}`, a type object a
  macro interpolated);
- a parametric type `T{A, B}`, including `<:S` and `>:S` parameters
  (`AbstractVector{<:Real}`), splatted parameters, and `where` clauses with
  bounds (`Vector{T} where T<:Integer`);
- a call (`typeof(sum)`, keyword arguments included), a tuple, and a macro
  call, which is expanded in `mod` first (`@NamedTuple{a::Int}`).

Any other syntax is evaluated with `Core.eval(mod, ex)`. While a package image
is written into a module other than `mod`, that evaluation is refused and an
`ArgumentError` says to name the annotation (`const T = …` in `mod`, then
`x::T`). Everything else throws what `Core.eval` would: an `UndefVarError` for
an unbound name, such as the free type parameter `V` in `Verb{V}`.

The lookup runs in the latest world, as `Core.eval` does, so a name defined
after the calling code was compiled resolves.

See also `property_signature`, which resolves each argument's annotation with
it.
"""
resolve_annotation(mod::Module, ex) =
    Base.invokelatest(_resolve_annotation, mod, ex, _NO_TYPEVARS)

# Type variables a `where` clause (or a `<:S` parameter) bound around the
# expression being resolved, innermost last.
const _AnnotationTypeVars = Vector{Pair{Symbol,TypeVar}}
const _NO_TYPEVARS = _AnnotationTypeVars()

function _resolve_annotation(mod::Module, ex::Symbol, tvs::_AnnotationTypeVars)
    for i in length(tvs):-1:1
        first(tvs[i]) === ex && return last(tvs[i])
    end
    getglobal(mod, ex)
end
_resolve_annotation(::Module, ex::GlobalRef, ::_AnnotationTypeVars) = getglobal(ex.mod, ex.name)
_resolve_annotation(::Module, ex::QuoteNode, ::_AnnotationTypeVars) = ex.value
# A literal (`2` in `NTuple{2,Int}`, a string) or an already-resolved value a
# macro interpolated into the annotation.
_resolve_annotation(::Module, ex, ::_AnnotationTypeVars) = ex

function _resolve_annotation(mod::Module, ex::Expr, tvs::_AnnotationTypeVars)
    resolve(x) = _resolve_annotation(mod, x, tvs)
    if ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        return getproperty(resolve(ex.args[1]), ex.args[2].value)
    elseif ex.head === :curly
        params = Any[]
        bound = TypeVar[]
        for a in @view ex.args[2:end]
            if Meta.isexpr(a, :<:, 1) || Meta.isexpr(a, :>:, 1)
                # `T{<:S}` is `T{X} where X<:S` (`>:` bounds from below);
                # the `#s` name is how Julia prints an anonymous parameter.
                b = resolve(a.args[1])
                tv = a.head === :<: ? TypeVar(Symbol("#s", length(bound) + 1), b) :
                                      TypeVar(Symbol("#s", length(bound) + 1), b, Any)
                push!(bound, tv)
                push!(params, tv)
            elseif Meta.isexpr(a, :..., 1)
                append!(params, resolve(a.args[1]))
            elseif a isa Expr && a.head in (:<:, :>:)
                return _eval_annotation(mod, ex)   # `T{X<:S}` outside `where`: not a type
            else
                push!(params, resolve(a))
            end
        end
        t = Core.apply_type(resolve(ex.args[1]), params...)
        for tv in Iterators.reverse(bound)
            t = UnionAll(tv, t)
        end
        return t
    elseif ex.head === :where
        inner = copy(tvs)
        bound = TypeVar[]
        for v in @view ex.args[2:end]
            tv = _where_typevar(mod, v, inner)
            tv === nothing && return _eval_annotation(mod, ex)
            push!(bound, tv)
            push!(inner, tv.name => tv)
        end
        t = _resolve_annotation(mod, ex.args[1], inner)
        for tv in Iterators.reverse(bound)
            t = UnionAll(tv, t)
        end
        return t
    elseif ex.head === :call
        args = Any[]
        kwargs = Pair{Symbol,Any}[]
        for a in @view ex.args[2:end]
            if Meta.isexpr(a, :parameters)
                for p in a.args
                    Meta.isexpr(p, :kw, 2) && p.args[1] isa Symbol ||
                        return _eval_annotation(mod, ex)
                    push!(kwargs, p.args[1] => resolve(p.args[2]))
                end
            elseif Meta.isexpr(a, :kw, 2) && a.args[1] isa Symbol
                push!(kwargs, a.args[1] => resolve(a.args[2]))
            elseif Meta.isexpr(a, :..., 1)
                append!(args, resolve(a.args[1]))
            else
                push!(args, resolve(a))
            end
        end
        return resolve(ex.args[1])(args...; kwargs...)
    elseif ex.head === :tuple && !any(a -> a isa Expr && a.head in (:(=), :kw, :parameters, :...), ex.args)
        return Tuple(resolve(a) for a in ex.args)
    elseif ex.head === :macrocall
        return resolve(macroexpand(mod, ex; recursive=true))
    end
    _eval_annotation(mod, ex)
end

# One `where` binding — `T`, `T<:S`, `T>:S` or `L<:T<:U` — as a TypeVar whose
# bounds resolve with the bindings to its left in scope; `nothing` for a form
# that is not a binding.
function _where_typevar(mod, v, tvs)
    resolve(x) = _resolve_annotation(mod, x, tvs)
    v isa Symbol && return TypeVar(v)
    if Meta.isexpr(v, :<:, 2) && v.args[1] isa Symbol
        return TypeVar(v.args[1], resolve(v.args[2]))
    elseif Meta.isexpr(v, :>:, 2) && v.args[1] isa Symbol
        return TypeVar(v.args[1], resolve(v.args[2]), Any)
    elseif Meta.isexpr(v, :comparison, 5) && v.args[2] === :<: && v.args[4] === :<: && v.args[3] isa Symbol
        return TypeVar(v.args[3], resolve(v.args[1]), resolve(v.args[5]))
    end
    nothing
end

# The forms `_resolve_annotation` does not look up. Julia refuses this
# evaluation into any module but the one being compiled while a package image
# is written; say how to make the annotation resolvable then.
function _eval_annotation(mod::Module, ex)
    try
        Core.eval(mod, ex)
    catch err
        err isa ErrorException && ccall(:jl_generating_output, Cint, ()) != 0 &&
            occursin("closed module", err.msg) || rethrow()
        throw(ArgumentError("the type annotation `$ex` in $mod needs evaluating, and " *
            "Julia evaluates into no other package's module while a package image is " *
            "written. Name it — `const T = $ex` in $mod, then `x::T` — since " *
            "DynamicObjects.resolve_annotation resolves names, `Mod.T`, `T{…}`, " *
            "`where` clauses, calls and macro calls without evaluating."))
    end
end

# Resolve a type-annotation expression against the struct's defining module.
# `nothing` for un-annotated args, for results that aren't a `Type`, and for
# any expression that fails to resolve (e.g. a free static-parameter type-var
# such as the `V` in `Verb{V}`). Never throws. An annotation that would resolve
# at run time but needs an evaluation Julia refuses while a package image is
# written also reads `nothing`, with a warning (once per annotation) naming the
# way out, since that answer differs from the run-time one.
function _resolve_arg_type(expr, mod)
    expr === nothing && return nothing
    try
        t = resolve_annotation(mod, expr)
        t isa Type ? t : nothing
    catch err
        if err isa ArgumentError && ccall(:jl_generating_output, Cint, ()) != 0
            @warn "DynamicObjects reads this annotation as untyped while the package image is written" exception=err maxlog=1 _id=(mod, expr)
        end
        nothing
    end
end

"""
    property_doc(info::NamedTuple)

Return the property's declared docstring, or `nothing`. Obtain the declaration
record with [`metafirst`](@ref) or [`metaall`](@ref); this accessor computes no
property value.
"""
property_doc(info::NamedTuple) = get(info, :doc, nothing)

# ── Semantic property descriptors ──────────────────────────────────────────
#
# This normalization layer is deliberately built only from the public
# `meta`/`property_signature` contract. It is safe for types emitted by an older
# DynamicObjects version: every new metadata field is read through
# `get(info, key, default)`, and the public result is an additive NamedTuple.

_descriptor_result_type_expr(info::NamedTuple) = begin
    explicit = get(info, :result_type, nothing)
    explicit === nothing ? _lhs_type_expr(get(info, :lhs, nothing)) : explicit
end
_lhs_type_expr(::Any) = nothing
_lhs_type_expr(lhs::Expr) = Meta.isexpr(lhs, :(::)) ? lhs.args[end] : nothing

_option_descriptor(value; label=string(value), group=nothing,
                   help=nothing, disabled=false) = (;
    value, label, group, help, disabled,
)
function _option_descriptor(option::NamedTuple)
    haskey(option, :value) || error("an option descriptor requires a `value` field")
    defaults = _option_descriptor(option.value)
    merge(defaults, option)
end
# `value => label`, the ergonomic spelling an `option_domain` list is written in.
_option_descriptor(option::Pair) = _option_descriptor(first(option); label=string(last(option)))

_unrestricted_domain() = (;
    kind=:unrestricted,
    options=NamedTuple[],
    provider=nothing,
    dependencies=Symbol[],
    cardinality=nothing,
    multiple=false,
    allow_custom=true,
    declaration=nothing,
)

"""
    static_domain(values; multiple=false, allow_custom=false)

Normalize raw values or option records already available to a descriptor
consumer. This is a framework-facing normalization helper, not an application
authoring convention.
"""
static_domain(values; multiple=false, allow_custom=false) = let opts =
    NamedTuple[_option_descriptor(v) for v in values]
    (;
        kind=:static,
        options=opts,
        provider=nothing,
        dependencies=Symbol[],
        cardinality=length(opts),
        multiple,
        allow_custom,
        declaration=nothing,
    )
end

# Domain of an input governed by an `@options` declaration. `options` stays
# empty and `cardinality` `nothing` on purpose: DO records the declared
# expression, it never evaluates it during reflection, so it cannot know the
# values. The consumer calls `property_options(object, parameter)` when it needs
# the value and re-reads after a declared dependency changes.
_declared_domain(declaration::NamedTuple) = (;
    kind=:declared,
    options=NamedTuple[],
    provider=nothing,
    dependencies=declaration.dependencies,
    cardinality=nothing,
    multiple=false,
    allow_custom=false,
    declaration,
)

function _inferred_domain(input_type)
    input_type === Bool && return static_domain((false, true))
    input_type isa Type && input_type <: Enum && return static_domain(instances(input_type))
    _unrestricted_domain()
end

# A vector input holds several values, each drawn from the one domain: the
# domain (declared or type-inferred) governs its ELEMENTS, and `multiple` tells
# a consumer to check every element and offer a multiple-choice control.
_domain_element(input_type) = (input_type, false)
_domain_element(input_type::Type{<:AbstractVector}) = (eltype(input_type), true)

_option_declaration(arg::NamedTuple, ::Nothing) = nothing
_option_declaration(arg::NamedTuple, declarations::AbstractDict) =
    arg.name === nothing ? nothing : get(declarations, arg.name, nothing)

# A declaration wins over the type-inferred domain: `Bool`/`Enum` prove a domain,
# but an author who declared one for that name meant it.
_element_domain(element, ::Nothing) = _inferred_domain(element)
_element_domain(element, declaration::NamedTuple) = _declared_domain(declaration)

_input_domain(arg::NamedTuple, declarations) =
    let (element, multiple) = _domain_element(arg.type)
        merge(_element_domain(element, _option_declaration(arg, declarations)), (; multiple))
    end

_descriptor_input(arg::NamedTuple, kind::Symbol, declarations=nothing) = (;
    arg...,
    kind,
    domain=_input_domain(arg, declarations),
)

function _merge_semantic_dependency_inputs(context_inputs, direct_inputs)
    merged = NamedTuple[]
    direct_by_name = Dict(input.name => input for input in direct_inputs)
    for context in context_inputs
        direct = get(direct_by_name, context.name, nothing)
        if direct === nothing
            push!(merged, context)
            continue
        end
        context.type !== nothing && direct.type !== nothing && context.type != direct.type &&
            error("semantic dependency input `$(context.name)` type $(context.type) conflicts with the property signature type $(direct.type)")
        push!(merged, merge(context, direct, (;domain=context.domain)))
    end
    context_names = Set(input.name for input in context_inputs)
    append!(merged, (input for input in direct_inputs if !(input.name in context_names)))
    merged
end

_descriptor_role(::Val{true}, ::Val) = :input
_descriptor_role(::Val{false}, ::Val{true}) = :operation
_descriptor_role(::Val{false}, ::Val{false}) = :output

_materialization_tier(::Val{true}, ::Val, ::Val, ::Val) = :field
_materialization_tier(::Val{false}, fresh, mmap, cached) =
    _computed_materialization_tier(mmap, cached, fresh)
_computed_materialization_tier(::Val{true}, ::Val, ::Val) = :mmap
_computed_materialization_tier(::Val{false}, ::Val{true}, ::Val) = :serialized
_computed_materialization_tier(::Val{false}, ::Val{false}, ::Val{true}) = :recompute
_computed_materialization_tier(::Val{false}, ::Val{false}, ::Val{false}) = :automatic

_progress_mode(macros) =
    Symbol("@PROGRESS") in macros || Symbol("@progress") in macros || Symbol("@dynamic_progress") in macros ? :instrumented :
    Symbol("@fetch!") in macros ? :forwarded : :automatic

property_descriptor(T::Type, prop::Symbol, info::NamedTuple) =
    property_descriptor(_DeclarationAnalysis(T), prop, info)

function property_descriptor(analysis::_DeclarationAnalysis, prop::Symbol, info::NamedTuple)
    T = analysis.type
    mod = parentmodule(T)
    fixed = isnothing(get(info, :rhs, nothing))
    indexed = get(info, :indexed, !isempty(get(info, :indices, ())))
    macros = get(info, :macros, Set{Symbol}())
    fresh = Symbol("@fresh") in macros
    state = Symbol("@state") in macros
    cached = Symbol("@cached") in macros
    mmap = Symbol("@mmap") in macros
    declared_versioned = Symbol("@versioned") in macros
    version_dependencies = copy(analysis.versions)
    versioned = has_versioned_fields(T) || !isempty(version_dependencies)
    computed = !fixed
    memoized = computed && !fresh
    pending = memoized
    progress = computed
    result_type = _resolve_arg_type(_descriptor_result_type_expr(info), mod)
    signature = property_signature(info, mod)
    declarations = analysis.options
    inferred_inputs = if fixed
        NamedTuple[_descriptor_input((;
            name=prop,
            type=result_type,
            required=true,
            default=nothing,
            vararg=false,
        ), :field, declarations)]
    else
        vcat(
            NamedTuple[_descriptor_input(arg, :positional, declarations) for arg in signature.positional],
            NamedTuple[_descriptor_input(arg, :keyword, declarations) for arg in signature.kwargs],
        )
    end
    dependencies = get(info, :dependson, nothing)
    dependencies = dependencies === nothing ? Symbol[] : sort!(collect(dependencies))
    context_inputs = fixed ? NamedTuple[] :
        _semantic_dependency_inputs(analysis, dependencies)
    inputs = _merge_semantic_dependency_inputs(context_inputs, inferred_inputs)
    # `@state` lives in memory for the instance's life: never promoted to disk.
    tier = state ? :memory : _materialization_tier(Val(fixed), Val(fresh), Val(mmap), Val(cached))
    cache_version = get(info, :cache_version, nothing)
    # `@versioned` is an object-wide cache-path dimension: a marker on one
    # field/property invalidates every persisted output of T. Keep the local
    # declaration fact separately so consumers can distinguish "defines the
    # version" from "is governed by the version" without an annotation shim.
    semantics = (;
        fresh,
        state,
        memoized,
        versioned,
        declared_versioned,
        version_dependencies,
        cache_version,
        invalidation=(; content_version=versioned, cache_version),
        cached,
        mmap,
        pending,
        progress,
        progress_mode=_progress_mode(macros),
    )
    materialization = (;tier)
    # The domain of the property's OWN value. A fixed field also reports it on
    # its single `:field` input, but the shape that needs this is the
    # overrideable default (`n_chain::Integer = 8`): it is a parameter a
    # consumer sets, yet it is a computed property with no signature, so it has
    # no `inputs` entry to hang a domain on.
    domain = _input_domain((; name=prop, type=result_type), declarations)
    (;
        name=prop,
        role=_descriptor_role(Val(fixed), Val(indexed)),
        fixed,
        indexed,
        description=property_doc(info),
        dependencies,
        domain,
        inputs,
        output=(; type=result_type, materialization),
        semantics,
    )
end

"""
    property_descriptor(T::Type, property::Symbol)

Return a backward-safe, pure-data descriptor for one DynamicObjects property,
or `nothing` when the type or property has no DO metadata. The result describes
inputs/output, lifecycle semantics, option domains, and declared
materialization without reading or computing an object property.

The descriptor's own `domain` is the domain of the property's *value*, and each
entry of `inputs` carries the domain of that argument. Read the top-level one
for a parameter a consumer sets — a fixed field, or an overrideable default like
`n_chain::Integer = 8`, which is a computed property with no signature and
therefore no `inputs` entry to hang a domain on. Every domain has one of three
`kind`s:

- `:static` — a finite domain the *type* proves (`Bool`, or an `Enum`), with the
  values in `options`.
- `:declared` — an `@options` declaration governs this parameter name; see
  [`option_declarations`](@ref). `domain.declaration` is the record (declared
  expression, its `dependencies`, and `static`); `options` is empty because
  reflection reports the declaration without running it. Call
  [`property_options`](@ref)`(o, name)` for the domain's actual value.
- `:unrestricted` — no domain is known; the type is the only constraint.

A domain's `multiple` is `true` exactly when the input is an `AbstractVector`
(`tags::Vector{String}`): its value holds several elements, and the domain —
declared or type-inferred — governs each ELEMENT. An `@options(tags)`
declaration lists the allowed elements, and `stages::Vector{Stage}` for an
`Enum` `Stage` reports the `Stage` instances as a `:static` domain. A consumer
checks every element and offers a multiple-choice control.
"""
function property_descriptor(T::Type, prop::Symbol)
    applicable(meta, T) || return nothing
    analysis = _DeclarationAnalysis(T)
    info = get(analysis.first, prop, nothing)
    info === nothing ? nothing : property_descriptor(analysis, prop, info)
end

"""
    property_descriptors(T::Type)

Return descriptors in declaration order. Duplicate property declarations are
preserved so consumers can inspect multiple indexed signatures.
"""
function property_descriptors(T::Type)
    applicable(meta, T) || return NamedTuple[]
    analysis = _DeclarationAnalysis(T)
    NamedTuple[property_descriptor(analysis, name, info) for (name, info) in analysis.entries]
end

"""
    type_descriptor(T::Type)

Type-level counterpart to [`property_descriptor`](@ref): what a reflection
consumer needs about the node as a whole, so "what is this thing called" has
exactly one answer rather than one per consumer.

Returns `(; type, name, description, options)`.

- `description` is `T`'s own user-attached docstring, stripped, or `nothing`
  when none was attached. The auto-generated property-list docstring
  `@dynamicstruct` installs as a `?T` fallback is deliberately *not* reported:
  it is reference text, not a label.
- `options` is [`option_declarations`](@ref)`(T)` — including any declaration
  whose parameter no input of `T` happens to carry.
"""
type_descriptor(T::Type) = (;
    type=T,
    name=nameof(T),
    description=_type_docstring(T),
    options=option_declarations(T),
)

# ── Application declaration graph ──────────────────────────────────────────

const _DECLARATION_GRAPH_SCHEMA = "dynamicobjects.declaration-graph/v1"
const _DECLARATION_OBSERVATIONS_SCHEMA =
    "dynamicobjects.declaration-observations/v1"
const _DECLARATION_FRAGMENT = "dynamicobjects"

"""
    declaration_metadata(T::Type) -> NamedTuple
    declaration_metadata(T::Type, ::Val{property}) -> NamedTuple
    declaration_metadata(T::Type, ::Val{property}, ::Val{declaration}) -> NamedTuple

Extension hook for declaration-site metadata that belongs on a type or property
node in [`declaration_graph`](@ref). The default is an empty `NamedTuple`.

A declaration macro in another package can emit a method beside the declaration
it expands, just as a docstring attaches information to a binding. The
three-argument form distinguishes duplicate declarations with the same property
name; by default it falls back to the two-argument property method. Return only
pure data. DynamicObjects stores the result verbatim under
`node.metadata.extensions` and does not interpret its keys.
"""
declaration_metadata(::Type) = (;)
declaration_metadata(::Type, ::Val) = (;)
declaration_metadata(T::Type, property::Val, ::Val) =
    declaration_metadata(T, property)

function _checked_declaration_metadata(value, subject)
    value isa NamedTuple || error(
        "declaration_metadata for $subject must return a NamedTuple, got $(typeof(value))")
    value
end

function _declaration_parameter_key(value::Type)
    _declaration_type_key(value)
end
_declaration_parameter_key(value::TypeVar) = string(
    value.name, ">:", _declaration_parameter_key(value.lb),
    "<:", _declaration_parameter_key(value.ub))
_declaration_parameter_key(value) = repr(value)

function _declaration_type_key(T::Type)
    mod = join(string.(Base.fullname(parentmodule(T))), ".")
    base = isempty(mod) ? string(nameof(T)) : string(mod, ".", nameof(T))
    T isa DataType || return base
    isempty(T.parameters) && return base
    string(base, "{", join(_declaration_parameter_key.(T.parameters), ","), "}")
end

function _declaration_id(kind::AbstractString, parts...)
    encoded = join((string(ncodeunits(string(part)), ":", part) for part in parts), "|")
    digest = bytes2hex(SHA.sha1(Vector{UInt8}(codeunits(encoded))))
    string("do:", kind, ":", first(digest, 24))
end

_declaration_type_id(T::Type) =
    _declaration_id("type", _declaration_type_key(T))
_declaration_property_id(owner::AbstractString, name::Symbol, declaration::Integer) =
    _declaration_id("property", owner, name, declaration)
_declaration_domain_id(owner::AbstractString, parameter::Symbol) =
    _declaration_id("domain", owner, parameter)
_declaration_edge_id(kind::Symbol, from::AbstractString, to::AbstractString, slot) =
    _declaration_id("edge", kind, from, to, slot)

_declaration_properties(T::Type) = applicable(meta, T) ? meta(T) : Pair[]

# Declaration-order breadth-first traversal. Unlike `_all_types_in_tree`, the
# public result must never inherit Set iteration order.
function _declaration_types(root::Type)
    types = Type[root]
    seen = Set{Type}((root,))
    cursor = 1
    while cursor <= length(types)
        T = types[cursor]
        cursor += 1
        seen_names = Set{Symbol}()
        for (name, _) in _declaration_properties(T)
            name in seen_names && continue
            push!(seen_names, name)
            nested = _walk_nested_type(T, name)
            nested isa Type || continue
            applicable(meta, nested) || continue
            nested in seen && continue
            push!(seen, nested)
            push!(types, nested)
        end
    end
    types
end

function _declaration_expression_string(expression)
    expression === nothing && return nothing
    normalized = expression isa Expr ?
        Base.remove_linenums!(deepcopy(expression)) : expression
    string(normalized)
end

function _declaration_source(name::Symbol, info::NamedTuple)
    indices = get(info, :indices, ())
    lhs = get(info, :lhs, name)
    signature = isempty(indices) ? string(lhs) :
        string(lhs, "(", join(indices, ", "), ")")
    macros = sort!(string.(collect(get(info, :macros, Set{Symbol}()))))
    expression = get(info, :rhs, nothing)
    rhs = _declaration_expression_string(expression)
    prefix = isempty(macros) ? "" : string(join(macros, " "), " ")
    code = expression === nothing ? string(prefix, signature) :
        string(prefix, signature, " = ", rhs)
    lnn = get(info, :lnn, nothing)
    location = lnn isa LineNumberNode ? (;
        file=string(lnn.file),
        line=lnn.line,
    ) : (;
        file=nothing,
        line=nothing,
    )
    (;
        location,
        signature,
        macros,
        code,
        lhs,
        expression,
        rhs,
    )
end

_declaration_node(id, kind, label, metadata) = (;
    id=String(id),
    kind,
    label=String(label),
    metadata,
    fragment=_DECLARATION_FRAGMENT,
)

_declaration_edge(id, kind, from, to, metadata) = (;
    id=String(id),
    kind,
    from=String(from),
    to=String(to),
    metadata,
    fragment=_DECLARATION_FRAGMENT,
)

function _base_declaration_graph(root::Type)
    types = _declaration_types(root)
    type_ids = Dict(T => _declaration_type_id(T) for T in types)
    nodes = NamedTuple[]
    edges = NamedTuple[]
    property_records = NamedTuple[]
    domain_records = NamedTuple[]
    property_ids = Dict{Tuple{String,Symbol},Vector{String}}()

    type_lookup = NamedTuple[]
    property_lookup = NamedTuple[]
    domain_lookup = NamedTuple[]

    for T in types
        type_id = type_ids[T]
        analysis = _DeclarationAnalysis(T)
        type_key = _declaration_type_key(T)
        opaque = _remount_opaque_properties(T)
        declared_names = Set(first(entry) for entry in analysis.entries)
        nested_names = Set(name for name in declared_names
            if haskey(type_ids, _walk_nested_type(T, name)))
        extensions = _checked_declaration_metadata(
            declaration_metadata(T), "type $T")
        push!(nodes, _declaration_node(type_id, :type, string(nameof(T)), (;
            type_key,
            descriptor=type_descriptor(T),
            extensions,
        )))
        push!(type_lookup, (;type_key, id=type_id))

        occurrences = Dict{Symbol,Int}()
        for (name, info) in analysis.entries
            declaration = get(occurrences, name, 0) + 1
            occurrences[name] = declaration
            property_id = _declaration_property_id(type_id, name, declaration)
            push!(get!(() -> String[], property_ids, (type_id, name)), property_id)
            descriptor = property_descriptor(analysis, name, info)
            source = _declaration_source(name, info)
            extensions = _checked_declaration_metadata(
                declaration_metadata(T, Val(name), Val(declaration)),
                "property $T.$name declaration $declaration")
            metadata = (;
                owner=type_id,
                owner_type_key=type_key,
                name,
                declaration,
                descriptor,
                signature=property_signature(info, parentmodule(T)),
                source,
                extensions,
                dependency_analysis=(;
                    opaque=descriptor.fixed ? false :
                        opaque === nothing ? nothing : name in opaque,
                    missing=Symbol[dependency for dependency in descriptor.dependencies
                        if !(dependency in declared_names)],
                    nested=Symbol[dependency for dependency in descriptor.dependencies
                        if dependency === :__parent__ || dependency in nested_names],
                ),
            )
            push!(nodes, _declaration_node(
                property_id, :property, source.signature, metadata))
            push!(property_records, (;
                type=T,
                owner=type_id,
                owner_type_key=type_key,
                name,
                declaration,
                id=property_id,
                descriptor,
            ))
            push!(property_lookup, (;
                owner=type_id,
                owner_type_key=type_key,
                name,
                declaration,
                id=property_id,
            ))
        end

        for (parameter, declaration) in option_declarations(T)
            domain_id = _declaration_domain_id(type_id, parameter)
            push!(nodes, _declaration_node(
                domain_id, :domain, "@options($parameter)", (;
                    owner=type_id,
                    owner_type_key=type_key,
                    parameter,
                    declaration,
                    dependency_analysis=(;
                        opaque=opaque === nothing ? nothing : :__options__ in opaque,
                        missing=Symbol[dependency for dependency in declaration.dependencies
                            if !(dependency in declared_names)],
                        nested=Symbol[dependency for dependency in declaration.dependencies
                            if dependency === :__parent__ || dependency in nested_names],
                    ),
                )))
            push!(domain_records, (;
                type=T,
                owner=type_id,
                owner_type_key=type_key,
                parameter,
                id=domain_id,
                declaration,
            ))
            push!(domain_lookup, (;
                owner=type_id,
                owner_type_key=type_key,
                parameter,
                id=domain_id,
            ))
        end
    end

    domain_ids = Dict((record.owner, record.parameter) => record.id
        for record in domain_records)

    for record in property_records
        contains_id = _declaration_edge_id(
            :contains, record.owner, record.id,
            (:property, record.name, record.declaration))
        push!(edges, _declaration_edge(
            contains_id, :contains, record.owner, record.id, (;role=:property)))

        nested = _walk_nested_type(record.type, record.name)
        if nested isa Type && haskey(type_ids, nested)
            child_id = type_ids[nested]
            edge_id = _declaration_edge_id(
                :contains, record.id, child_id,
                (:nested_type, record.name, record.declaration))
            push!(edges, _declaration_edge(
                edge_id, :contains, record.id, child_id, (;role=:nested_type)))
        end

        for dependency in record.descriptor.dependencies
            # A sibling read names a property, not a dispatch signature. Keep
            # every declaration of that name; choosing only the first loses
            # requirements of other methods before a selector can see them.
            for dependency_id in get(property_ids, (record.owner, dependency), String[])
                edge_id = _declaration_edge_id(
                    :depends_on, record.id, dependency_id, dependency)
                push!(edges, _declaration_edge(
                    edge_id, :depends_on, record.id, dependency_id,
                    (;declared=true)))
            end
        end

        domain_sites = Dict{String,Vector{NamedTuple}}()
        if record.descriptor.domain.kind === :declared
            parameter = record.descriptor.domain.declaration.parameter
            domain_id = get(domain_ids, (record.owner, parameter), nothing)
            domain_id === nothing || push!(get!(
                domain_sites, domain_id, NamedTuple[]),
                (;scope=:value, parameter))
        end
        for input in record.descriptor.inputs
            input.domain.kind === :declared || continue
            parameter = input.domain.declaration.parameter
            domain_id = get(domain_ids, (record.owner, parameter), nothing)
            domain_id === nothing && continue
            push!(get!(domain_sites, domain_id, NamedTuple[]), (;
                scope=:input,
                parameter,
                input=input.name,
                input_kind=input.kind,
            ))
        end
        for domain_id in sort!(collect(keys(domain_sites)))
            edge_id = _declaration_edge_id(
                :describes, record.id, domain_id, domain_sites[domain_id])
            push!(edges, _declaration_edge(
                edge_id, :describes, record.id, domain_id,
                (;sites=domain_sites[domain_id])))
        end
    end

    for record in domain_records
        contains_id = _declaration_edge_id(
            :contains, record.owner, record.id, (:domain, record.parameter))
        push!(edges, _declaration_edge(
            contains_id, :contains, record.owner, record.id, (;role=:domain)))
        for dependency in record.declaration.dependencies
            for dependency_id in get(property_ids, (record.owner, dependency), String[])
                edge_id = _declaration_edge_id(
                    :depends_on, record.id, dependency_id, dependency)
                push!(edges, _declaration_edge(
                    edge_id, :depends_on, record.id, dependency_id,
                    (;declared=true, source=:options)))
            end
        end
    end

    lookup = (;
        types=type_lookup,
        properties=property_lookup,
        domains=domain_lookup,
    )
    root_id = type_ids[root]
    (;root=root_id, nodes, edges, lookup)
end

_declaration_contributions(contribution::NamedTuple) = (contribution,)
_declaration_contributions(contributions) = contributions

function _normalize_declaration_node(node::NamedTuple, namespace::String)
    id = get(node, :id, nothing)
    kind = get(node, :kind, nothing)
    label = get(node, :label, nothing)
    metadata = get(node, :metadata, nothing)
    id isa AbstractString || error(
        "declaration contribution `$namespace` has a node without a String `id`")
    kind isa Symbol || error(
        "declaration contribution `$namespace` node `$id` needs a Symbol `kind`")
    label isa AbstractString || error(
        "declaration contribution `$namespace` node `$id` needs a String `label`")
    haskey(node, :metadata) || error(
        "declaration contribution `$namespace` node `$id` needs `metadata`")
    merge((;id=String(id), kind, label=String(label), metadata,
           fragment=namespace), node,
          (;id=String(id), kind, label=String(label), metadata,
           fragment=namespace))
end

function _normalize_declaration_edge(edge::NamedTuple, namespace::String)
    id = get(edge, :id, nothing)
    kind = get(edge, :kind, nothing)
    from = get(edge, :from, nothing)
    to = get(edge, :to, nothing)
    metadata = get(edge, :metadata, nothing)
    id isa AbstractString || error(
        "declaration contribution `$namespace` has an edge without a String `id`")
    kind isa Symbol || error(
        "declaration contribution `$namespace` edge `$id` needs a Symbol `kind`")
    from isa AbstractString || error(
        "declaration contribution `$namespace` edge `$id` needs a String `from`")
    to isa AbstractString || error(
        "declaration contribution `$namespace` edge `$id` needs a String `to`")
    haskey(edge, :metadata) || error(
        "declaration contribution `$namespace` edge `$id` needs `metadata`")
    merge((;id=String(id), kind, from=String(from), to=String(to), metadata,
           fragment=namespace), edge,
          (;id=String(id), kind, from=String(from), to=String(to), metadata,
           fragment=namespace))
end

function _validate_declaration_graph(root, nodes, edges)
    owners = Dict{String,String}()
    for item in Iterators.flatten((nodes, edges))
        id = item.id
        previous = get(owners, id, nothing)
        previous === nothing || error(
            "duplicate declaration id `$id` in fragments `$previous` and `$(item.fragment)`")
        owners[id] = item.fragment
    end
    node_ids = Set(node.id for node in nodes)
    root in node_ids || error("declaration graph root `$root` is not a node")
    for edge in edges
        edge.from in node_ids || error(
            "declaration edge `$(edge.id)` has unknown `from` node `$(edge.from)`")
        edge.to in node_ids || error(
            "declaration edge `$(edge.id)` has unknown `to` node `$(edge.to)`")
    end
    nothing
end

"""
    declaration_graph(root::Type; contributions=())
    declaration_graph(object; contributions=())

Build a deterministic, non-evaluating application declaration graph from
DynamicObjects metadata. The object overload reflects `typeof(object)`; it does
not read the object. The result is pure Julia data:

`(; schema="dynamicobjects.declaration-graph/v1", root, nodes, edges, metadata)`

`root` is the stable ID of the root `:type` node. Every node has at least
`(;id::String, kind::Symbol, label::String, metadata, fragment::String)` and
every edge at least
`(;id::String, kind::Symbol, from::String, to::String, metadata,
fragment::String)`. DynamicObjects emits `:type`, `:property`, and `:domain`
nodes, connected only by explicit `:contains`, direct `:depends_on`, and
`:describes` relations. Property metadata includes its owner type ID, semantic
name, duplicate-declaration occurrence, normalized semantic descriptor,
structured signature, declaration extensions, and full captured source AST,
code, and file/line provenance. Property and domain metadata also include
`dependency_analysis=(;opaque, missing, nested)` for unresolved declared reads.
Sibling dependency edges target every same-name declaration conservatively;
the graph does not determine runtime dispatch. Use [`declaration_selection`](@ref)
to select requirements and explicit boundaries without computing properties.

Each contribution is a pure-data
`(;namespace::String, nodes, edges)` fragment using the same envelopes. Base DO
data comes first; fragments and the node/edge vectors inside each fragment keep
caller order. The namespace is recorded as `fragment` for provenance but never
rewrites IDs. IDs must be globally unique across all nodes and edges; collisions
(including with DO IDs) and dangling endpoints are rejected after every
fragment is present, so cross-fragment edges may target later fragments.

Use [`declaration_node_id`](@ref) to connect external nodes to a DO declaration
without depending on the spelling of DO IDs. Runtime state is deliberately not
part of this graph; see [`declaration_observations`](@ref).
"""
function declaration_graph(root::Type; contributions=())
    base = _base_declaration_graph(root)
    nodes = copy(base.nodes)
    edges = copy(base.edges)
    fragments = NamedTuple[(;
        namespace=_DECLARATION_FRAGMENT,
        nodes=length(nodes),
        edges=length(edges),
    )]

    for contribution in _declaration_contributions(contributions)
        contribution isa NamedTuple || error(
            "a declaration contribution must be a NamedTuple, got $(typeof(contribution))")
        namespace = get(contribution, :namespace, nothing)
        namespace isa AbstractString || error(
            "a declaration contribution requires a String `namespace`")
        namespace = String(namespace)
        contribution_nodes = get(contribution, :nodes, nothing)
        contribution_edges = get(contribution, :edges, nothing)
        contribution_nodes === nothing && error(
            "declaration contribution `$namespace` requires `nodes`")
        contribution_edges === nothing && error(
            "declaration contribution `$namespace` requires `edges`")
        normalized_nodes = NamedTuple[
            _normalize_declaration_node(node, namespace)
            for node in contribution_nodes
        ]
        normalized_edges = NamedTuple[
            _normalize_declaration_edge(edge, namespace)
            for edge in contribution_edges
        ]
        append!(nodes, normalized_nodes)
        append!(edges, normalized_edges)
        push!(fragments, (;
            namespace,
            nodes=length(normalized_nodes),
            edges=length(normalized_edges),
        ))
    end

    _validate_declaration_graph(base.root, nodes, edges)
    (;
        schema=_DECLARATION_GRAPH_SCHEMA,
        root=base.root,
        nodes,
        edges,
        metadata=(;
            namespace=_DECLARATION_FRAGMENT,
            fragments,
            lookup=base.lookup,
        ),
    )
end

declaration_graph(object; contributions=()) =
    declaration_graph(typeof(object); contributions)

function _declaration_selection_ids(ids, known, label)
    selected = Set{String}()
    for id in (ids isa AbstractString ? (ids,) : ids)
        id isa AbstractString || throw(ArgumentError("$label must contain node ID strings"))
        haskey(known, id) || throw(ArgumentError("unknown $label node `$id`"))
        push!(selected, String(id))
    end
    selected
end

function _declaration_selection_diagnostics!(unresolved, node)
    node.fragment == _DECLARATION_FRAGMENT && node.kind in (:property, :domain) || return
    metadata = node.metadata
    analysis = metadata isa NamedTuple ? get(metadata, :dependency_analysis, nothing) : nothing
    if analysis === nothing
        push!(unresolved, (;node=node.id, kind=:unavailable_analysis, dependency=nothing))
        return
    end
    opaque = analysis.opaque
    if opaque !== false
        push!(unresolved, (;node=node.id,
            kind=opaque === true ? :opaque_dependencies : :unavailable_analysis,
            dependency=nothing))
    end
    for dependency in analysis.missing
        push!(unresolved, (;node=node.id, kind=:missing_dependency, dependency))
    end
    for dependency in analysis.nested
        push!(unresolved, (;node=node.id, kind=:nested_dependency, dependency))
    end
end

"""
    declaration_selection(graph, roots; boundaries=())

Select declarations without reading properties or executing their bodies. `graph`
is a [`declaration_graph`](@ref) result; `roots` and `boundaries` are node ID
strings (a single string is also accepted). Use [`declaration_node_id`](@ref)
to identify DO declarations, and the contributed IDs for framework nodes.

Follow outgoing `:depends_on` and `:describes` edges. A reached explicit boundary
is reported but its outgoing edges are not followed. For `A → B → C`, selecting
`A` with boundary `B` requires `A`, reports `B`, and omits `C`; a separate local
path to `C` still retains it. A root cannot also be a boundary. Boundary IDs
which are not reached are omitted. Selections may overlap and need not exhaust
the graph. Duplicate IDs in either input are harmless; unknown IDs are errors.

Return pure data with schema `"dynamicobjects.declaration-selection/v1"`:

- `graph`: the original graph's root ID; `roots`: normalized root IDs.
- `required`: IDs of the roots and their transitive local requirements.
- `boundaries`: IDs of the reached explicit boundaries, excluded from `required`.
- `context`: additional ancestor IDs reached by following `:contains` backwards.
  These preserve owner/mount context, not an assertion that their computations
  are selected. Containment never selects siblings or descendants, even for a
  type root. Select an owning/mount property as a root too when its computation
  must be included, rather than merely described.
- `nodes`: original records for the union of those three disjoint ID sets;
  `edges`: original edges whose endpoints are in that union. Their source,
  metadata and fragment provenance are preserved, with no rewriting of IDs.
- `reasons`: `(;node, kind, from, edge)` records for roots, traversed requirement
  edges, and containing context. A root has `from=edge=nothing`; other reasons
  cite an original edge. These distinguish traversal from merely retained edges.
- `unresolved`: `(;node, kind, dependency)` diagnostics on local requirements.
  DO reports opaque self access, unrepresented dependency names, known nested/parent
  reads whose member-level requirements are not in the graph, and unavailable
  analysis from older graphs. Explicit boundaries suppress these diagnostics
  for the external node. Arbitrary helpers, runtime dispatch and effects are
  not inferred: an empty vector is not a proof of purity or whole-program
  completeness. Contributed nodes are governed by their supplied edges.

ID vectors, nodes and edges keep graph order, independent of input order.
Reasons keep root order then edge order. Work is linear in graph size plus
diagnostics; cycles terminate. Inputs are never mutated. Node and edge metadata
remain shared read-only data; this is a plan, not executable source pruning or
automatic remote-call rewriting. Same-name dependency declarations are retained
conservatively because a declared edge does not determine runtime dispatch.
"""
function declaration_selection(graph, roots; boundaries=())
    get(graph, :schema, nothing) == _DECLARATION_GRAPH_SCHEMA ||
        throw(ArgumentError("expected a dynamicobjects.declaration-graph/v1 graph"))
    _validate_declaration_graph(graph.root, graph.nodes, graph.edges)
    known = Dict(node.id => node for node in graph.nodes)
    root_ids = _declaration_selection_ids(roots, known, "root")
    stops = _declaration_selection_ids(boundaries, known, "boundary")
    isdisjoint(root_ids, stops) ||
        throw(ArgumentError("a selection root cannot also be an explicit boundary"))

    requirements = Dict{String,Vector{String}}()
    parents = Dict{String,Vector{String}}()
    for edge in graph.edges
        if edge.kind in (:depends_on, :describes)
            push!(get!(() -> String[], requirements, edge.from), edge.to)
        elseif edge.kind === :contains
            push!(get!(() -> String[], parents, edge.to), edge.from)
        end
    end
    ordered_roots = String[node.id for node in graph.nodes if node.id in root_ids]
    queue = copy(ordered_roots)
    reached = copy(root_ids)
    cursor = 1
    while cursor <= length(queue)
        id = queue[cursor]
        cursor += 1
        id in stops && continue
        for dependency in get(requirements, id, ())
            dependency in reached && continue
            push!(reached, dependency)
            push!(queue, dependency)
        end
    end
    boundary_ids = intersect(reached, stops)
    required = setdiff(reached, boundary_ids)

    # Ancestors supply structural context only. Never feed them back into the
    # requirement queue: that would silently select unrelated local work.
    retained = copy(reached)
    cursor = 1
    while cursor <= length(queue)
        id = queue[cursor]
        cursor += 1
        for parent in get(parents, id, ())
            parent in retained && continue
            push!(retained, parent)
            push!(queue, parent)
        end
    end
    context = setdiff(retained, reached)
    reasons = NamedTuple[(;node=id, kind=:root, from=nothing, edge=nothing)
        for id in ordered_roots]
    for edge in graph.edges
        if edge.kind in (:depends_on, :describes) && edge.from in required
            push!(reasons, (;node=edge.to, kind=edge.kind, from=edge.from, edge=edge.id))
        elseif edge.kind === :contains && edge.to in retained
            push!(reasons, (;node=edge.from, kind=:context, from=edge.to, edge=edge.id))
        end
    end
    unresolved = NamedTuple[]
    for node in graph.nodes
        node.id in required || continue
        _declaration_selection_diagnostics!(unresolved, node)
    end
    (;
        schema="dynamicobjects.declaration-selection/v1",
        graph=graph.root,
        roots=ordered_roots,
        required=String[node.id for node in graph.nodes if node.id in required],
        boundaries=String[node.id for node in graph.nodes if node.id in boundary_ids],
        context=String[node.id for node in graph.nodes if node.id in context],
        nodes=NamedTuple[node for node in graph.nodes if node.id in retained],
        edges=NamedTuple[edge for edge in graph.edges
            if edge.from in retained && edge.to in retained],
        reasons,
        unresolved,
    )
end

"""
    declaration_node_id(graph, T::Type) -> Union{String,Nothing}
    declaration_node_id(graph, T::Type, property::Symbol; declaration=1)
        -> Union{String,Nothing}

Look up stable DO node IDs without depending on their encoded spelling. The
property form selects the one-based occurrence among same-name declarations.
"""
function declaration_node_id(graph, T::Type)
    type_key = _declaration_type_key(T)
    for record in graph.metadata.lookup.types
        record.type_key == type_key && return record.id
    end
    nothing
end

function declaration_node_id(
    graph, T::Type, property::Symbol; declaration::Integer=1)
    declaration > 0 || error("declaration occurrence must be positive")
    owner = declaration_node_id(graph, T)
    owner === nothing && return nothing
    for record in graph.metadata.lookup.properties
        record.owner == owner && record.name === property &&
            record.declaration == declaration && return record.id
    end
    nothing
end

_declaration_observation_calls(call::NamedTuple) = (call,)
_declaration_observation_calls(calls) = calls

"""
    declaration_observations(
        object, graph=declaration_graph(typeof(object)); calls=())

Return a separate, non-computing runtime-state overlay:

`(;schema="dynamicobjects.declaration-observations/v1", graph=graph.root,
observations)`

Each observation is keyed by a stable property node ID as
`(;node, call, observation)`. Fixed and scalar properties owned by the root type
are observed automatically. Indexed properties are omitted unless `calls`
contains an explicit `(;node, args=(), kwargs=(;))` record; this avoids
inventing a call key. Nodes owned by nested types and contributed nodes are
omitted unless a future composer binds an object for them.

The implementation only calls [`materialization_observation`](@ref), which
inspects fields, memory caches, pending state, and existing disk paths without
calling `getproperty`, an indexed property, or a property body.
"""
function declaration_observations(
    object, graph=declaration_graph(typeof(object)); calls=())
    owner = declaration_node_id(graph, typeof(object))
    owner == graph.root || error(
        "observation object type $(typeof(object)) is not the declaration graph root")

    calls_by_node = Dict{String,Vector{NamedTuple}}()
    for call in _declaration_observation_calls(calls)
        call isa NamedTuple || error(
            "an observation call must be a NamedTuple, got $(typeof(call))")
        node = get(call, :node, nothing)
        node isa AbstractString || error(
            "an observation call requires a String `node`")
        args = get(call, :args, ())
        args = args isa Tuple ? args : Tuple(args)
        kwargs = get(call, :kwargs, (;))
        kwargs isa NamedTuple || error(
            "observation call `$node` requires NamedTuple `kwargs`")
        push!(get!(calls_by_node, String(node), NamedTuple[]), (;args, kwargs))
    end

    node_by_id = Dict(node.id => node for node in graph.nodes)
    for node_id in keys(calls_by_node)
        node = get(node_by_id, node_id, nothing)
        node === nothing && error("observation call names unknown node `$node_id`")
        node.kind === :property || error(
            "observation call node `$node_id` is not a property")
        node.metadata.owner == owner || error(
            "observation call node `$node_id` is not owned by the root object")
        node.metadata.descriptor.indexed || error(
            "explicit observation calls are only needed for indexed properties")
    end

    observations = NamedTuple[]
    for node in graph.nodes
        node.kind === :property || continue
        node.fragment == _DECLARATION_FRAGMENT || continue
        node.metadata.owner == owner || continue
        descriptor = node.metadata.descriptor
        name = node.metadata.name
        if descriptor.indexed
            for call in get(calls_by_node, node.id, NamedTuple[])
                observation = materialization_observation(
                    object, name, call.args...; call.kwargs...)
                push!(observations, (;
                    node=node.id,
                    call,
                    observation,
                ))
            end
        else
            observation = materialization_observation(object, name)
            push!(observations, (;
                node=node.id,
                call=nothing,
                observation,
            ))
        end
    end

    (;
        schema=_DECLARATION_OBSERVATIONS_SCHEMA,
        graph=graph.root,
        observations,
    )
end

# Snapshot cache state without calling `getproperty`, `memoize!`, or a property
# body. `has_value` distinguishes a cached `nothing` from an absent entry.
_empty_cache_snapshot() = (;
    state=:unmaterialized,
    has_value=false,
    value=nothing,
    progress=nothing,
    error=nothing,
)

function _cache_snapshot(cache::AbstractThreadsafeDict, key)
    lock(cache.lock) do
        if haskey(cache.cache, key)
            return (;state=:ready, has_value=true, value=cache.cache[key],
                progress=get(cache.status, key, nothing), error=nothing)
        end
        if haskey(cache.errors, key)
            return (;state=:failed, has_value=false, value=nothing,
                progress=get(cache.status, key, nothing), error=cache.errors[key])
        end
        if haskey(cache.computing, key)
            return (;state=:pending, has_value=false, value=nothing,
                progress=get(cache.status, key, nothing), error=nothing)
        end
        _empty_cache_snapshot()
    end
end

function _cache_snapshot(cache::AbstractDict, key)
    haskey(cache, key) || return _empty_cache_snapshot()
    (;state=:ready, has_value=true, value=cache[key], progress=nothing, error=nothing)
end

function _memory_observation(o, descriptor::NamedTuple, name::Symbol, args, kwargs::NamedTuple)
    if descriptor.fixed
        (isempty(args) && isempty(kwargs)) || error("fixed property `$name` does not accept arguments")
        value = getfield(o, name)
        return (;state=:ready, has_value=true, value, progress=nothing, error=nothing)
    end
    hasfield(typeof(o), :cache) || return _empty_cache_snapshot()
    property_cache = getfield(o, :cache)
    property_cache isa PropertyCache || return _empty_cache_snapshot()
    if descriptor.indexed
        outer = _cache_snapshot(property_cache.cache, name)
        outer.state === :ready || return outer
        outer.value isa IndexableProperty || return outer
        return _cache_snapshot(outer.value.cache, _memo_key(Tuple(args), kwargs))
    end
    (isempty(args) && isempty(kwargs)) || error("scalar property `$name` does not accept arguments")
    _cache_snapshot(property_cache.cache, name)
end

_observed_bytes(value::AbstractString) = ncodeunits(value)
_observed_bytes(value::AbstractArray{T}) where {T} =
    isbitstype(T) ? length(value) * sizeof(T) : try
        Base.summarysize(value)
    catch
        nothing
    end
_observed_bytes(value::T) where {T} = isbitstype(T) ? sizeof(T) : try
    Base.summarysize(value)
catch
    nothing
end

const _AUTOMATIC_MATERIALIZATION_SUFFIX = ".auto"
const _AUTOMATIC_MATERIALIZATION_MIN_BYTES = 1024 * 1024
const _AUTOMATIC_MATERIALIZATION_MIN_SECONDS = 1.0

_automatic_materialization_path(cache_path::AbstractString) =
    cache_path * _AUTOMATIC_MATERIALIZATION_SUFFIX

function _effective_compute_seconds(wall_ns::Integer, compile_ns::Integer)
    # Julia's cumulative compile counter is process-global. Concurrent
    # compilation can therefore make `compile_ns` exceed this call's wall time;
    # clamp at zero so that ambiguity is conservative (keep memory) rather than
    # a false disk-promotion signal.
    noncompile_ns = wall_ns > compile_ns ? wall_ns - compile_ns : zero(wall_ns)
    Float64(noncompile_ns) / 1.0e9
end

function _automatic_materialization_metadata(cache_path::AbstractString)
    metadata_path = _automatic_materialization_path(cache_path)
    isfile(metadata_path) || return nothing
    metadata = try
        Serialization.deserialize(metadata_path)
    catch
        return nothing
    end
    metadata isa NamedTuple || return nothing
    format = get(metadata, :format, nothing)
    format in (:serial, :mmap) || return nothing
    metadata
end

function _disk_observation(o, descriptor::NamedTuple, name::Symbol, args, kwargs::NamedTuple)
    semantics = descriptor.semantics
    path = get_cache_path(o, name, args...; kwargs...)
    automatic = _automatic_materialization_metadata(path)
    (semantics.cached || semantics.mmap || automatic !== nothing) ||
        return (;state=:none, path=nothing, format=nothing)
    format = automatic === nothing ?
        (semantics.mmap ? :mmap : :serial) : automatic.format
    (;state=get_cache_status(path), path, format)
end

_observation_state(memory, disk, fresh) =
    memory.state !== :unmaterialized ? memory.state :
    disk.state === :ready ? :stored :
    disk.state === :started ? :stored_partial :
    fresh ? :fresh : :unmaterialized

"""
    materialization_observation(object, property::Symbol, args...; kwargs...)

Observe a property's current memory/disk/pending/progress state without
computing that property. For disk-backed properties this resolves the ordinary
DO cache path and inspects the file; it never creates or loads the target file.
"""
function materialization_observation(o, name::Symbol, args...; kwargs...)
    descriptor = property_descriptor(typeof(o), name)
    descriptor === nothing && error("$(typeof(o)) has no DynamicObjects property `$name`")
    property_kwargs = (;kwargs...)
    memory = _memory_observation(o, descriptor, name, args, property_kwargs)
    disk = _disk_observation(o, descriptor, name, args, property_kwargs)
    state = _observation_state(memory, disk, descriptor.semantics.fresh)
    value_type = memory.has_value ? typeof(memory.value) : descriptor.output.type
    (;
        name,
        state,
        ready=memory.state === :ready,
        pending=memory.state === :pending,
        failed=memory.state === :failed,
        stored=disk.state === :ready,
        tier=disk.state === :ready ?
            (disk.format === :mmap ? :mmap : :serialized) :
            memory.state === :ready ? :memory : descriptor.output.materialization.tier,
        memory_state=memory.state,
        disk_state=disk.state,
        path=disk.path,
        progress=memory.progress,
        error=memory.error,
        value_type,
        estimated_bytes=memory.has_value ? _observed_bytes(memory.value) : nothing,
    )
end

