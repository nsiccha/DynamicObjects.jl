using Documenter, DocumenterVitepress, DynamicObjects
include("figures.jl")
include("lint.jl")

makedocs(
    sitename = "DynamicObjects.jl",
    modules  = [DynamicObjects],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/DynamicObjects.jl",
        devurl = "dev",
        devbranch = "pre-inference",
        build_vitepress = false,
    ),
    pages = let pages = [
        "Start" => ["First object" => "index.md"],
        "Guides" => [
            "Properties" => "guides/properties.md",
            "Cache lifetime" => "guides/caches.md",
            "Files" => "guides/files.md",
            "Polling and progress" => "guides/polling.md",
            "Reflection" => "guides/reflection.md",
        ],
        "Examples" => ["Cached signal analysis" => "examples/signal.md"],
        "Reference" => [
            "Objects" => "reference/objects.md",
            "Caches" => "reference/caches.md",
            "Execution" => "reference/execution.md",
            "Files" => "reference/files.md",
            "Reflection and hosts" => "reference/reflection.md",
        ],
    ]
        lint_docs(pages)
        pages
    end,
    checkdocs = :exports,
    warnonly = false,
)

DocsFigures.write_assets(joinpath(@__DIR__, "build", ".documenter", "public", "figures"))
DocumenterVitepress.build_docs(joinpath(@__DIR__, "build"))

# Ensure a root index.html redirect exists for when no stable version is deployed
let redirect = joinpath(@__DIR__, "build", "index.html")
    isfile(redirect) || write(redirect, """
    <!DOCTYPE html>
    <html><head>
    <meta http-equiv="refresh" content="0; url=dev/">
    </head><body>Redirecting to <a href="dev/">dev</a>...</body></html>
    """)
end

DocumenterVitepress.deploydocs(
    repo = "github.com/nsiccha/DynamicObjects.jl",
    devbranch = "pre-inference",
    push_preview = true,
)
