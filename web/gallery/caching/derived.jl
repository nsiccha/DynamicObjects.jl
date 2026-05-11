# title: Derived properties
# description: Bare-name resolution and lazy memoisation on a per-instance cache.
# tags: dynamicstruct, derived, basics

# The classic shape: `x` / `y` are fixed fields (constructor args), `r` and
# `theta` are derived properties whose bodies reference `x` / `y` by bare
# name — they get rewritten to `__self__.x` / `__self__.y` automatically.
# Each is computed once per instance and cached in memory.
@dynamicstruct struct PointDemo
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
end

let p = PointDemo(3.0, 4.0)
    h.article(
        h.h4("PointDemo(3.0, 4.0)"),
        h.p("Two derived properties, computed lazily on first access:"),
        h.ul(
            h.li(h.code("p.r"), " = ", h.code(string(p.r))),
            h.li(h.code("p.theta"), " = ", h.code(string(round(p.theta; digits=4)))),
        ),
        h.p(h.small(
            "Bare names ", h.code("x"), " / ", h.code("y"),
            " in the property body resolve to ", h.code("__self__.x"),
            " / ", h.code("__self__.y"), " via DO's macro rewrite.",
        )),
    )
end
