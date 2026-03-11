using Documenter, DocumenterVitepress, DynamicObjects

makedocs(
    sitename = "DynamicObjects.jl",
    modules  = [DynamicObjects],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/DynamicObjects.jl",
        devurl = "dev",
    ),
    pages = [
        "Home"      => "index.md",
        "API"       => "api.md",
    ],
    checkdocs = :none,
    warnonly = true,
)

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
    devbranch = "main",
    push_preview = true,
)
