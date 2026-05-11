using Documenter, DocumenterVitepress, DynamicObjects
import HTMXObjects

# Sync the canonical htmxo-embed.ts (+ companion CSS) from HTMXObjects'
# assets into the docs theme dir before DocumenterVitepress runs. The
# theme's index.ts imports it via `import { setupHtmxoEmbed } from './htmxo-embed'`.
HTMXObjects.vitepress_theme_install(joinpath(@__DIR__, "src", ".vitepress", "theme"))

makedocs(
    sitename = "DynamicObjects.jl",
    modules  = [DynamicObjects],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/DynamicObjects.jl",
        devurl = "dev",
        devbranch = "dev",
    ),
    pages = [
        "Home"    => "index.md",
        "Gallery" => "gallery.md",
        "API"     => "api.md",
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
    devbranch = "dev",
    push_preview = true,
)
