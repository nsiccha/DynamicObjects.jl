using Documenter
push!(LOAD_PATH,"src/")
using DynamicObjects

makedocs(
    sitename = "DynamicObjects",
    format = Documenter.HTML(),
    modules = [DynamicObjects]
)

deploydocs(
    repo = "github.com/nsiccha/DynamicObjects.jl.git"
)
