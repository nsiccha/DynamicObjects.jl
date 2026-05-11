module DynamicObjectsWeb

using HTMXObjects
using TestModules, Random

include("test/runtests.jl")

@htmx struct AppContext

    @include structure = HTMXObjects.StructureRoutes(; root=AppContext)

    __page__(content) = HTMXObjects.pico_page(content)

    @get index() = h.div(
        h.h1("DynamicObjectsWeb"),
        h.p("Edit src/DynamicObjectsWeb.jl and Revise will reload automatically."),
        h.p(h.a(href=__self__/"tests")("Tests")),
        h.p(h.a(href=__self__/"structure")("DO type structure browser")),
    )

    @include tests = TestRoutes(; __req__, test_module=@__MODULE__)
end

function __init__()
    route!(AppContext())
end

end # module DynamicObjectsWeb
