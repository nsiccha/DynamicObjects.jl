## Profile the populate-under-budget path — where the user's "spin
## forever" symptom lives. The walk is already fast post-9836d5a; the
## remaining hotspot is in the STORE bookkeeping that runs while IPs
## are being computed.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using DynamicObjects
using Profile
using Printf

include(joinpath(@__DIR__, "harness.jl"))

# JIT warmup
let app = AppData()
    DynamicObjects.set_cache_budget!(app, 8*1024^3)
    exercise!(app)
end

# Real profile run
Profile.clear()
Profile.init(n=10_000_000, delay=0.001)
app = AppData()
DynamicObjects.set_cache_budget!(app, 8*1024^3)
t0 = time_ns()
@profile exercise!(app)
elapsed = (time_ns()-t0)/1e9
@printf "[profile] exercise elapsed: %.2fs\n" elapsed

@printf "\n[profile] --- flat (sorted by count) ---\n"
Profile.print(format=:flat, sortedby=:count, mincount=20, C=false)

println("\n[profile] --- tree (top by total) ---")
Profile.print(format=:tree, mincount=50, maxdepth=30, C=false, recur=:flat)
