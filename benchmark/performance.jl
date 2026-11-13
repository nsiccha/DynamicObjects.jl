# Run in a resolved environment developing this checkout:
#   julia --startup-file=no --threads=1 --project=<env> benchmark/performance.jl
# Optional groups: scaling, runtime, bookkeeping (default: all).
# Fresh-process first-call times include compilation; warm samples do not.
# Compare allocations and size scaling before interpreting shared-host timings.
using DynamicObjects
const DO = DynamicObjects
println("Julia ", VERSION, "; threads=", Threads.nthreads(), "; source=", pathof(DO))

function sample(label, f::F; n=100, trials=3) where F
    f(); f()
    elapsed = Float64[]
    allocated = Float64[]
    for _ in 1:trials
        GC.gc()
        result = @timed for _ in 1:n
            f()
        end
        push!(elapsed, result.time / n)
        push!(allocated, result.bytes / n)
    end
    println(label, ": ns=", minimum(elapsed) * 1e9, "; bytes=", minimum(allocated))
    flush(stdout)
end

function definition(n, shape)
    fields = Any[:(input::Int)]
    for i in 1:n
        previous = shape === :chain && i > 1 ? Symbol(:p, i - 1) : :input
        push!(fields, Expr(:(=), Symbol(:p, i), :($previous + 1)))
    end
    Expr(:struct, false, gensym(:ScaleProbe), Expr(:block, fields...))
end

function astcounts(expr)
    expr isa Expr || return (0, 0)
    nodes, symbols = 1, 0
    for arg in expr.args
        n, s = astcounts(arg)
        nodes += n
        symbols += s + (arg isa QuoteNode && arg.value isa Symbol)
    end
    nodes, symbols
end

function scaling()
    DO.dynamicstruct(definition(2, :chain))
    for shape in (:wide, :chain), n in (16, 64, 128, 256)
        expr = definition(n, shape)
        expanded = DO.dynamicstruct(deepcopy(expr))
        sample("expand/$shape/$n", () -> DO.dynamicstruct(deepcopy(expr)); n=1)
        println("ast/$shape/$n: nodes/symbols=", astcounts(expanded),
                "; bytes=", Base.summarysize(expanded))
        mod = Module(gensym(:Scale))
        result = @timed Core.eval(mod, expanded.args[1])
        println("define/$shape/$n: seconds=", result.time, "; bytes=", result.bytes)
        T = getfield(mod, expr.args[2])
        Base.invokelatest(sample, "descriptors/$shape/$n", () -> property_descriptors(T); n=1)
        Base.invokelatest(sample, "dependents/$shape/$n", () -> DO.dependents(T, :input); n=30)
        n > 64 && continue
        object = Base.invokelatest(T, 1000; __status__=nothing)
        result = @timed Base.invokelatest(getproperty, object, Symbol(:p, n))
        println("first-read/$shape/$n: seconds=", result.time, "; bytes=", result.bytes)
        # Fill both shapes completely before measuring carryover.
        for i in 1:n
            Base.invokelatest(getproperty, object, Symbol(:p, i))
        end
        for changed in (false, true)
            operation = changed ? (() -> remake(object; input=2000)) : (() -> remake(object))
            result = @timed Base.invokelatest(operation)
            println("first-remake/$shape/$n/changed=$changed: seconds=", result.time,
                    "; bytes=", result.bytes)
            Base.invokelatest(sample, "warm-remake/$shape/$n/changed=$changed", operation; n=30)
        end
    end
end

@dynamicstruct struct AccessProbe
    input::Int
    bare = input + 1
    annotated::Int = input + 1
    indexed(i::Int) = input + i
end

function runtime()
    object = AccessProbe(1000; __status__=nothing)
    indexed = object.indexed
    object.bare; object.annotated; indexed(3)
    println("fixed-field inference: ", Base.return_types(o -> o.input, (typeof(object),)))
    # Function-local bindings exercise ordinary callers. A const global can
    # conceal dynamic dispatch, and an unused fixed-field read can disappear.
    sample("local/bare-hit", () -> object.bare; n=10000)
    sample("local/annotated-hit", () -> object.annotated; n=10000)
    sample("local/held-indexed-hit", () -> indexed(3); n=10000)
    sample("local/resolved-indexed-hit", () -> object.indexed(3); n=10000)
    sample("construct", () -> AccessProbe(1000; __status__=nothing))
    sample("first-value/no-progress", () -> AccessProbe(1000; __status__=nothing).bare)
    sample("first-value/progress", () -> AccessProbe(1000).bare)
end

function enqueue_blocked(n)
    queue = DO.JobQueue(; max_running=1)
    queue.running = 1 # reserve the slot; this probe starts no work
    for _ in 1:n
        DO.enqueue!(queue, nothing)
    end
    length(queue.waiting)
end

@dynamicstruct struct ChildProbe
    @struct child(i::Int) = begin
        value = i
    end
end

function bookkeeping()
    for n in (256, 1024, 4096)
        sample("enqueue-blocked/$n", () -> enqueue_blocked(n); n=5)
    end
    for n in (16, 256, 1024)
        parent = ChildProbe(; __status__=nothing)
        for i in 1:n
            parent.child(i)
        end
        child = parent.child(n)
        sample("child-step/$n", () -> DO._child_step(parent, child))
    end
end

groups = isempty(ARGS) ? ["all"] : ARGS
all(group -> group in ("all", "scaling", "runtime", "bookkeeping"), groups) ||
    error("Expected all, scaling, runtime or bookkeeping")
for (group, run) in (("scaling", scaling), ("runtime", runtime), ("bookkeeping", bookkeeping))
    ("all" in groups || group in groups) && run()
end
println("PERFORMANCE_PROBE_COMPLETE")
