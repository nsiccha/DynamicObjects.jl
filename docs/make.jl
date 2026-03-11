using Documenter, DocumenterVitepress, DynamicObjects

makedocs(
    sitename = "DynamicObjects.jl",
    modules  = [DynamicObjects],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "https://github.com/nsiccha/DynamicObjects.jl",
        devurl = "dev",
        deploy_url = "nsiccha.github.io/DynamicObjects.jl",
    ),
    pages = [
        "Home"      => "index.md",
        "API"       => "api.md",
    ],
    checkdocs = :none,
    warnonly = true,
)

DocumenterVitepress.deploydocs(
    repo = "github.com/nsiccha/DynamicObjects.jl",
    devbranch = "main",
    push_preview = true,
)
