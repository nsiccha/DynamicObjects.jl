module DynamicObjectsWeb

using HTMXObjects
import DynamicObjects
# Load Treebars before importing RecordingRoutes — Treebars activates
# HTMXObjectsTreebarsExt, which injects `RecordingRoutes` into the
# HTMXObjects namespace and gives it a live polling_fetchindex progress UI.
using Treebars
using HTMXObjects: RecordingRoutes

# --- AppData: one DO global holding the on-disk gallery + recording inputs.
@dynamicstruct struct DOAppData
    gallery_dir = joinpath(dirname(dirname(@__DIR__)), "web", "gallery")
    gallery     = Gallery(gallery_dir)

    # Recording flow (HTMXObjectsTreebarsExt's `RecordingRoutes`). The
    # docs site under `docs/src/public/live-do/` consumes these — keep
    # `record_base` aligned with VitePress's `proxyPrefix` (see
    # docs/.vitepress/theme/index.ts and `live-do` in config.mts).
    recording_dir  = joinpath(dirname(dirname(@__DIR__)), "docs", "src", "public", "live-do")
    recording_base = get(ENV, "RECORD_BASE_PREFIX", "/DynamicObjects.jl/dev/live-do")
    recording_paths = let ids = [it.id for it in gallery.items]
        ["/", "/gallery", ["/entries/$id" for id in ids]...]
    end
end

const APPDATA = DOAppData()

@htmx struct AppContext
    __appdata__ = APPDATA

    __page__(content) = HTMXObjects.pico_page(content)

    @get index() = h.div(
        h.h1("DynamicObjectsWeb"),
        h.p("Edit src/DynamicObjectsWeb.jl and Revise will reload automatically."),
        h.p(h.a(href=__self__/"gallery")("DO concept gallery")),
        h.p(h.a(href=__self__/"tests")("Tests")),
        h.p(h.a(href=__self__/"structure")("DO type structure browser")),
        h.p(h.a(href=__self__/"record_gallery")("Record gallery")),
    )

    # --- Live gallery surface (consumed by the docs site via htmxo-embed).
    @get gallery() = let g = __appdata__.gallery
        h.div(; data_layout="wide")(
            gallery_grid(g.items; section_titles=g.section_titles),
        )
    end

    # Per-id detail route — what each gallery card links to.
    @include entries(id::String) = begin
        item = find_item(__parent__.__appdata__.gallery, id)

        @get index() = if isnothing(item)
            h.article("No gallery item with id $(id).")
        else
            # `Base.include` re-evals the file's body and returns its last
            # top-level expression (an `h.article(...)` node by convention).
            body = Base.include(@__MODULE__, item.path)
            h.div(
                h.header(h.h2(item.title)),
                isempty(item.description) ? h.span() : h.p(item.description),
                body,
                h.details(
                    h.summary("Source"),
                    h.pre(h.code(item.code_string; class="language-julia")),
                ),
                h.footer(h.small("section: $(item.section); path: $(item.path)")),
            )
        end
    end

    @include record_gallery = RecordingRoutes(;
        app_type    = AppContext,
        paths       = __appdata__.recording_paths,
        record_dir  = __appdata__.recording_dir,
        record_base = __appdata__.recording_base,
        label       = "Recording DynamicObjects gallery",
    )

    @include structure = HTMXObjects.StructureRoutes(; root=AppContext)
    @include tests     = TestRoutes(; project=pkgdir(DynamicObjects))
end

function __init__()
    route!(AppContext())
end

end # module DynamicObjectsWeb
