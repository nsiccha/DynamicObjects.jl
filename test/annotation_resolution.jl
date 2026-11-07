using TestItemRunner

# snag read-dynamicobje-c95d1b9a: `property_signature` resolved each annotation
# with `Core.eval(mod, expr)`. While a package image is written Julia refuses
# evaluation into every module but the one being compiled, so a
# `@compile_workload` (or an `__init__` run while another package precompiles)
# that reflected a dependency's type read every argument type as `nothing`, and
# HTMXObjects then warmed `/detail/prewarm` instead of `/detail/1`.
# `resolve_annotation` looks annotations up instead.

@testitem "resolve_annotation finds what Core.eval does, by lookup" tags=[:core] begin
    using DynamicObjects
    M = Module(:AnnotationForms)
    Core.eval(M, quote
        const Alias = Vector{String}
        struct Box{T} end
        g(x; k=1) = x + k
    end)
    forms = Any[
        :Symbol, GlobalRef(Base, :Int), :(Base.RefValue{Int}), :Alias, :(Box{Int}),
        :(Vector{<:Real}), :(Type{>:Int}), :(Dict{<:AbstractString,<:Real}),
        :(Vector{Vector{<:Real}}), :(Val{:x}), :(NTuple{2,Int}), :(Tuple{Vararg{Int}}),
        :(Union{}), :(Union{Nothing,Int}), :(Tuple{(Int, String)...}),
        :(Vector{T} where T<:Integer), :(Dict{K,V} where {K,V<:K}),
        :((Pair{A,B} where A<:Real) where B), :(Ref{T} where Int<:T<:Real),
        :(Ref{T} where T>:Int), :(typeof(sum)), :(Val{g(1; k=2)}), :(Val{g(1, k=3)}),
        :(Val{(1, :a)}), :(@NamedTuple{a::Int, b::String}),
        # Not a lookup form: evaluated, as before.
        :(true ? Int : String), 3,
    ]
    for ex in forms
        @test DynamicObjects.resolve_annotation(M, ex) == Core.eval(M, ex)
    end
    @test_throws UndefVarError DynamicObjects.resolve_annotation(M, :(Ref{V}))
    @test_throws UndefVarError DynamicObjects.resolve_annotation(M, :Undefined)

    # A free type parameter (HTMXObjects' injected `__verb__::Verb{V}`) stays
    # `nothing`; the documented `(info, mod)` entry point resolves the rest.
    info = (; indices=(:(name::Symbol), :(verb::Ref{V}), Expr(:parameters, Expr(:kw, :(n::Int), 1))))
    sig = property_signature(info, M)
    @test Any[a.type for a in sig.positional] == Any[Symbol, nothing]
    @test Any[a.type for a in sig.kwargs] == Any[Int]
end

@testitem "argument types read the same while a package image is written" tags=[:core] begin
    using DynamicObjects
    fixtures = normpath(joinpath(dirname(pathof(DynamicObjects)), "..", "test", "fixtures", "annotations"))
    project = dirname(Base.active_project())
    # A fresh first depot, so the fixture packages are precompiled here rather
    # than loaded from an image an earlier run wrote; later depots still serve
    # DynamicObjects and its dependencies.
    depot = mktempdir()
    code = "pushfirst!(LOAD_PATH, $(repr(fixtures))); using AnnotationProbe; " *
        "println(\"GENERATING \", AnnotationProbe.GENERATING); AnnotationProbe.report()"
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`,
        "JULIA_DEPOT_PATH" => join([depot; DEPOT_PATH], Sys.iswindows() ? ';' : ':'))
    out, err = IOBuffer(), IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    output, errors = String(take!(out)), String(take!(err))
    @test success(proc)
    success(proc) || println(errors)
    # The reads ran while the image was written (not vacuously at load).
    @test occursin("GENERATING 1", output)
    lines = Dict(split(l)[2] => split(l; limit=4)[3:4] for l in eachline(IOBuffer(output)) if startswith(l, "ANNOTATION "))
    for p in ("item", "detail", "qualified", "bounded", "tagged", "aliased", "named", "called", "bound", "output")
        @test get(lines, p, ["missing", ""])[1] == "true"
    end
    @test startswith(lines["item"][2], "(Any[Symbol], Any[])")
    @test startswith(lines["detail"][2], "(Any[$Int], Any[$Int])")
    @test startswith(lines["output"][2], "$Int")
    # An annotation only evaluation resolves reads untyped then, and says so.
    @test lines["picked"][1] == "false"
    @test startswith(lines["picked"][2], "(Any[nothing], Any[])")
    @test occursin("reads this annotation as untyped while the package image is written", errors)
    @test occursin("const T = ", errors)
end
