using Revise
using DynamicObjectsWeb

begin
    DynamicObjectsWeb.terminate()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8100
    DynamicObjectsWeb.serve(; host="0.0.0.0", revise=:lazy, port, async=true)
end
