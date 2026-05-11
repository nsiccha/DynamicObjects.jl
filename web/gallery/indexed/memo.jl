# title: Indexed properties — fresh vs @memo
# description: Call-syntax `prop(args...) = …` makes a property an IndexableProperty.
# tags: indexed, IP, memo

# `filter(pred)` is declared with call syntax — so it's an IP, not a scalar
# property. Two access shapes:
#   `app.filter(iseven)`        → recomputes every call (no caching).
#   `@memo app.filter(iseven)`  → looks up `(iseven,)` in the per-property dict.
# The bracket form `app.filter[iseven]` is the legacy equivalent of `@memo`;
# prefer `@memo` so the caching is visible at the call site.
@dynamicstruct struct FilterDemo
    items = [1, 2, 3, 4, 5, 6]
    filter(pred) = (sleep(0.02); Base.filter(pred, items))
end

let app = FilterDemo()
    t1 = @elapsed app.filter(iseven)         # fresh
    t2 = @elapsed app.filter(iseven)         # fresh again — recomputes
    t3 = @elapsed @memo app.filter(iseven)   # cached path: spawn Task, await
    t4 = @elapsed @memo app.filter(iseven)   # hit the per-property dict
    h.article(
        h.h4("FilterDemo()"),
        h.p(h.code("items"), " = ", h.code("[1,2,3,4,5,6]"),
            "; ", h.code("filter(pred)"), " is an indexed property."),
        h.ul(
            h.li(h.code("app.filter(iseven)"), " #1 — fresh: ",
                 h.code("$(round(t1*1000; digits=1)) ms")),
            h.li(h.code("app.filter(iseven)"), " #2 — fresh again: ",
                 h.code("$(round(t2*1000; digits=1)) ms")),
            h.li(h.code("@memo app.filter(iseven)"), " #1 — cached path: ",
                 h.code("$(round(t3*1000; digits=1)) ms")),
            h.li(h.code("@memo app.filter(iseven)"), " #2 — dict hit: ",
                 h.code("$(round(t4*1000; digits=3)) ms")),
        ),
        h.p(h.small(
            "Bare ", h.code("app.filter"), " (no call) returns the ",
            h.code("IndexableProperty"), " wrapper itself — useful for ",
            h.code("fetchindex"), ", ", h.code("cancel!"), ", ",
            h.code("entries"), ".",
        )),
    )
end
