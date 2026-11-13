# Direct edges and their reverse, shared by reflection and invalidation. Keep only
# the declared edges: storing every node's transitive closure grows quadratically
# even for a chain. These objects are local to one analysis, never a global cache
# of mutable metadata or annotation resolutions.
struct _DependencyGraph
    reverse::Dict{Symbol,Vector{Symbol}}
    function _DependencyGraph(dependencies)
        reverse = Dict{Symbol,Vector{Symbol}}()
        for (name, deps) in dependencies, dependency in deps
            push!(get!(() -> Symbol[], reverse, dependency), name)
        end
        new(reverse)
    end
end

_close_dependents!(names::Set{Symbol}, dependencies, excluded=()) =
    _close_dependents!(names, _DependencyGraph(dependencies), excluded)

function _close_dependents!(names::Set{Symbol}, graph::_DependencyGraph, excluded=())
    queue = collect(names)
    cursor = 1
    while cursor <= length(queue)
        name = queue[cursor]
        cursor += 1
        for dependent in get(graph.reverse, name, ())
            (dependent in names || dependent in excluded) && continue
            push!(names, dependent)
            push!(queue, dependent)
        end
    end
    names
end

# A multi-source traversal must distinguish a root reached only from itself
# (including through a cycle) from one reached from a different root. A node's
# provenance changes at most twice: unseen -> one source -> multiple sources.
# This preserves the union-of-single-root-closures contract without walking the
# entire graph once for every changed input.
_dependents_in(dependencies, names) = _dependents_in(_DependencyGraph(dependencies), names)
function _dependents_in(graph::_DependencyGraph, names)
    sources = Dict{Symbol,Symbol}(name => name for name in names)
    multiple = Set{Symbol}()
    queue = collect(keys(sources))
    cursor = 1
    while cursor <= length(queue)
        name = queue[cursor]
        cursor += 1
        source = sources[name]
        mixed = name in multiple
        for dependent in get(graph.reverse, name, ())
            if !haskey(sources, dependent)
                sources[dependent] = source
                mixed && push!(multiple, dependent)
                push!(queue, dependent)
            elseif !(dependent in multiple) && (mixed || sources[dependent] !== source)
                push!(multiple, dependent)
                push!(queue, dependent)
            end
        end
    end
    Set{Symbol}(name for (name, source) in sources if name !== source || name in multiple)
end

struct _DeclarationAnalysis
    type::Type
    entries::Vector{Pair{Symbol,NamedTuple}}
    first::Dict{Symbol,NamedTuple}
    order::Dict{Symbol,Int}
    fixed_dependencies::Dict{Symbol,Vector{Symbol}}
    fixed_inputs::Dict{Symbol,NamedTuple}
    versions::Vector{Symbol}
    options::Union{Nothing,Dict{Symbol,NamedTuple}}
end

function _DeclarationAnalysis(T::Type)
    entries = applicable(meta, T) ?
        Pair{Symbol,NamedTuple}[name => info for (name, info) in meta(T)] :
        Pair{Symbol,NamedTuple}[]
    first = Dict{Symbol,NamedTuple}()
    order = Dict{Symbol,Int}()
    dependencies = Dict{Symbol,Set{Symbol}}()
    fixed = Symbol[]
    versions = Symbol[]
    for (name, info) in entries
        Symbol("@versioned") in get(info, :macros, ()) && push!(versions, name)
        haskey(first, name) && continue
        first[name] = info
        order[name] = length(order) + 1
        deps = get(info, :dependson, nothing)
        dependencies[name] = deps === nothing ? Set{Symbol}() :
            Set{Symbol}(dep for dep in deps if dep isa Symbol)
        get(info, :rhs, nothing) === nothing && push!(fixed, name)
    end
    # Reflection follows the FIRST declaration of a dependency, as metafirst
    # always did. Invalidation instead unions duplicate declarations' edges.
    # Propagate only fixed input names, not all intermediate dependencies. For a
    # chain with one input this visits the graph once, with linear-size output.
    graph = _DependencyGraph(dependencies)
    fixed_dependencies = Dict{Symbol,Vector{Symbol}}()
    for input in fixed
        reached = _close_dependents!(Set{Symbol}((input,)), graph)
        for name in reached
            push!(get!(() -> Symbol[], fixed_dependencies, name), input)
        end
    end
    _DeclarationAnalysis(T, entries, first, order, fixed_dependencies,
                         Dict{Symbol,NamedTuple}(), unique!(versions), _option_declaration_map(T))
end

function _semantic_fixed_dependencies(analysis::_DeclarationAnalysis, roots)
    names = Set{Symbol}()
    for root in roots
        union!(names, get(analysis.fixed_dependencies, root, ()))
    end
    sort!(collect(names); by=name -> analysis.order[name])
end

function _semantic_dependency_inputs(analysis::_DeclarationAnalysis, dependencies)
    inputs = NamedTuple[]
    for name in _semantic_fixed_dependencies(analysis, dependencies)
        input = get!(analysis.fixed_inputs, name) do
            only(property_descriptor(analysis, name, analysis.first[name]).inputs)
        end
        push!(inputs, merge(input, (;
            kind=:context,
            source=(;type=analysis.type, property=name),
            scope=:object,
        )))
    end
    inputs
end
