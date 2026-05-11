# title: Disk-cached property (@cached)
# description: Orthogonal to in-memory IPs — purely an I/O concern.
# tags: cached, disk, axes

# `@cached` writes the computed value to `joinpath(cache_base, hash, "<prop>.sjl")`.
# It is independent of IP-ness and `cache_type` (the three axes). A fresh
# `ExperimentDemo(1)` constructed later loads the value from disk instead
# of recomputing — even across process restarts.
@dynamicstruct struct ExperimentDemo
    n::Int
    cache_base = joinpath(tempdir(), "do-gallery-cache")
    @cached result = (sleep(0.05); sum(1:n))
end

let e = ExperimentDemo(100)
    t1 = @elapsed e.result          # first access: computes + writes to disk
    t2 = @elapsed e.result          # second access: in-memory hit
    e2 = ExperimentDemo(100)
    t3 = @elapsed e2.result         # fresh instance: reads from disk
    h.article(
        h.h4("ExperimentDemo(100)"),
        h.p("Cache path: ", h.code(e.cache_path)),
        h.ul(
            h.li("First access (compute + disk write): ",
                 h.code("$(round(t1*1000; digits=1)) ms")),
            h.li("Second access (in-memory): ",
                 h.code("$(round(t2*1000; digits=3)) ms")),
            h.li("Fresh instance, same hash (disk read): ",
                 h.code("$(round(t3*1000; digits=3)) ms")),
        ),
        h.p(h.small(
            "Disk caching is orthogonal to IP-ness and ",
            h.code("cache_type"), " — it's purely I/O. Bump ",
            h.code("@cached v\"2\" result = …"), " to invalidate stale files.",
        )),
    )
end
