using Documenter
push!(LOAD_PATH,"src/")
using DynamicObjects

makedocs(
    sitename = "DynamicObjects",
    format = Documenter.HTML(),
    modules = [DynamicObjects]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "github.com/nsiccha/DynamicObjects.jl.git"
)
