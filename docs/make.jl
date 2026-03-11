using Documenter, DynamicObjects

makedocs(
    sitename = "DynamicObjects.jl",
    modules  = [DynamicObjects],
    format   = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
    ),
    pages = [
        "Home"      => "index.md",
        "API"       => "api.md",
    ],
    checkdocs = :none,
)

deploydocs(
    repo = "github.com/nsiccha/DynamicObjects.jl",
    devbranch = "main",
)
