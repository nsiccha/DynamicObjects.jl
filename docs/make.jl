using Documenter, DocumenterVitepress, DynamicObjects
include("figures.jl")
include("pages.jl")
include("lint.jl")

# Pages register figure assets while their examples run. This step writes them into
# the build directory after ExpandTemplates; rendering then moves `public/` into the
# VitePress source, so `vitepress build` publishes them beside the pages.
abstract type WriteFigureAssets <: Documenter.Builder.DocumentPipeline end
Documenter.Selectors.order(::Type{WriteFigureAssets}) = 5.5
function Documenter.Selectors.runner(::Type{WriteFigureAssets}, doc::Documenter.Document)
    build = isabspath(doc.user.build) ? doc.user.build : joinpath(doc.user.root, doc.user.build)
    DocsFigures.write_assets(joinpath(build, "public", "figures"))
end

makedocs(
    sitename = "DynamicObjects.jl",
    modules  = [DynamicObjects],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/DynamicObjects.jl",
        devurl = "dev",
        devbranch = "pre-inference",
    ),
    pages = let pages = DOCS_PAGES
        lint_docs(pages)
        pages
    end,
    checkdocs = :exports,
    warnonly = false,
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
    devbranch = "pre-inference",
    push_preview = true,
)
