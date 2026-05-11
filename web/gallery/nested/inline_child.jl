# title: Inline child struct via @struct
# description: Children get __parent__ auto-wired; parent props forward by bare name.
# tags: nested, struct, parent

# `@struct sub = begin … end` declares an inline singleton child DO. The
# child gets a `__parent__` field auto-wired and may reference any parent
# property by bare name — DO's macro rewrites those to `__parent__.x` etc.
# Compare with the indexed form `@struct weighted(id; scale=2)` which gives
# a per-(id, scale) cached child.
@dynamicstruct struct ParentDemo
    x::Float64
    y = x + 1

    @struct sub = begin
        z = x + y           # x, y forwarded from parent
        label = "sub of x=$x"
    end

    @struct weighted(id; scale=2) = begin
        total = x * id * scale
    end
end

let p = ParentDemo(3.0)
    h.article(
        h.h4("ParentDemo(3.0)"),
        h.ul(
            h.li(h.code("p.y"), " = ", h.code(string(p.y))),
            h.li(h.code("p.sub.z"), " = ", h.code(string(p.sub.z)),
                 " (forwards ", h.code("x"), " + ", h.code("y"), " from parent)"),
            h.li(h.code("p.sub.label"), " = ", h.code(repr(p.sub.label))),
            h.li(h.code("p.weighted(10).total"), " = ",
                 h.code(string(p.weighted(10).total)),
                 " (fresh per call)"),
            h.li(h.code("@memo p.weighted(10; scale=5).total"), " = ",
                 h.code(string((@memo p.weighted(10; scale=5)).total)),
                 " (cached by (10, scale=5) tuple)"),
        ),
        h.p(h.small(
            "Children inherit ", h.code("cache_type"),
            " from the parent and the parent's progress tree (",
            h.code("__substatus__"), ").",
        )),
    )
end
