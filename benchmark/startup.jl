# Run once per fresh process after resolving and precompiling the environment:
#   julia --startup-file=no --threads=1 --project=<env> benchmark/startup.jl
# The type is new to this process, not the package's private precompile fixture.
# invokelatest keeps first-call compilation inside each measured interval.
result = @timed @eval using DynamicObjects
println("load: seconds=", result.time, "; bytes=", result.bytes)
const DO = DynamicObjects
println("Julia ", VERSION, "; threads=", Threads.nthreads(), "; source=", pathof(DO))
function report(label, f)
    result = @timed Base.invokelatest(f)
    println(label, ": seconds=", result.time, "; bytes=", result.bytes)
    flush(stdout)
    result.value
end
expr = :(struct StartupProbe
    input::Int
    value = input + 1
    indexed(i::Int) = input + i
end)
expanded = report("expand", () -> DO.dynamicstruct(expr))
report("define", () -> Core.eval(Main, expanded.args[1]))
object = report("construct", () -> StartupProbe(1000; __status__=nothing))
report("first-value", () -> object.value)
report("first-indexed", () -> object.indexed(3))
report("descriptors", () -> property_descriptors(StartupProbe))
report("declaration-graph", () -> declaration_graph(StartupProbe))
report("remake", () -> remake(object))
report("remake-changed", () -> remake(object; input=2000))
println("STARTUP_PROBE_COMPLETE")
