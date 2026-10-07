using TestItemRunner

@testmodule PropertyInvalidationFixtures begin
using DynamicObjects
export Ladder, CachedLadder, LadderApp, VersionedLadder, PI_CALLS, PI_BUILD, PI_CACHE_BASE

const PI_CALLS = Dict{Any,Int}()
_pi!(key) = (PI_CALLS[key] = get(PI_CALLS, key, 0) + 1)
# What a rebuild produces: a forced property reads it again, a kept one does not.
const PI_BUILD = Ref(1)
const PI_CACHE_BASE = Ref("")

# Two preparation branches over one specification; `request` is remount context.
@dynamicstruct struct Ladder
    model::String
    request = "retained"
    specification = (_pi!(:specification); "spec($model)")
    sb = (_pi!(:sb); "sb[$specification]")
    stan_source = (_pi!(:stan_source); "stan[$sb]")
    native_build = (_pi!(:native_build); "build#$(PI_BUILD[])[$specification]")
    native_query = (_pi!(:native_query); "query[$native_build]")
    gradient(order::Int) = (_pi!((:gradient, order)); "grad$order[$native_query]")
    reference_check = (_pi!(:reference_check); "check[$(gradient(1))|$stan_source]")
    banner = string(request, ":", native_query)
end

# The same graph on disk. `fit_summary`'s file name starts with `fit_`, like an
# entry of `fit`, but it is a different property.
@dynamicstruct struct CachedLadder
    model::String
    __cache_base__ = PI_CACHE_BASE[]
    @cached sb = (_pi!(:cached_sb); "sb($model)")
    @cached native_build = (_pi!(:cached_native_build); "build#$(PI_BUILD[])")
    @cached fit(seed::Int) = (_pi!((:fit, seed)); "fit$seed[$native_build]")
    @cached fit_summary = (_pi!(:fit_summary); "summary[$sb]")
end

# One child per model; the parent derives a table from every child.
@dynamicstruct struct LadderApp
    models::Vector{String}
    @struct model(name::String) = begin
        sb = (_pi!((:app_sb, name)); "sb[$name]")
        native_build = (_pi!((:app_build, name)); "build#$(PI_BUILD[])[$name]")
        native_query = (_pi!((:app_query, name)); "query[$native_build]")
    end
    table = (_pi!(:app_table); [model(name).native_query for name in models])
end

@dynamicstruct struct VersionedLadder
    path::String
    __cache_base__ = PI_CACHE_BASE[]
    @versioned content_version = file_version(path; by = :hash)
    @cached native_build = (_pi!(:versioned_build); "build#$(PI_BUILD[])")
end
end

@testitem "clear_cache! drops a property and its dependents, keeping other branches" setup=[PropertyInvalidationFixtures] begin
using DynamicObjects

empty!(PI_CALLS); PI_BUILD[] = 1
l = Ladder("m")
@test l.reference_check == "check[grad1[query[build#1[spec(m)]]]|stan[sb[spec(m)]]]"
@test l.gradient(2) == "grad2[query[build#1[spec(m)]]]"

PI_BUILD[] = 2
@test DynamicObjects.clear_cache!(l, :native_build) ==
    [:gradient, :native_build, :native_query, :reference_check]
@test l.reference_check == "check[grad1[query[build#2[spec(m)]]]|stan[sb[spec(m)]]]"
@test l.gradient(2) == "grad2[query[build#2[spec(m)]]]"   # every indexed entry went
@test PI_CALLS[:native_build] == 2
@test PI_CALLS[:native_query] == 2
@test PI_CALLS[(:gradient, 2)] == 2
# The other branch and the shared upstream were not recomputed.
@test PI_CALLS[:specification] == 1
@test PI_CALLS[:sb] == 1
@test PI_CALLS[:stan_source] == 1

# The macro is the same operation; a leaf drops only itself.
@test (@clear_cache! l.reference_check) == [:reference_check]
@test l.reference_check isa String
@test PI_CALLS[:reference_check] == 3
@test PI_CALLS[:native_query] == 2

# An indexed property as the target: all of its entries and what reads it.
@test DynamicObjects.clear_cache!(l, :gradient) == [:gradient, :reference_check]
@test l.native_query == "query[build#2[spec(m)]]"
@test PI_CALLS[:native_query] == 2

# Nothing in memory: nothing dropped, nothing to report.
@test DynamicObjects.clear_cache!(Ladder("fresh"), :native_build) == Symbol[]
end

@testitem "clear_cache! keeps inputs and refuses fixed or unknown names" setup=[PropertyInvalidationFixtures] begin
using DynamicObjects

empty!(PI_CALLS); PI_BUILD[] = 1
l = Ladder("m"; native_build = "pinned")
@test l.native_query == "query[pinned]"
# A construction override is an input: it stays, what derives from it goes.
@test DynamicObjects.clear_cache!(l, :native_build) == [:native_query]
@test l.native_build == "pinned"
@test l.native_query == "query[pinned]"
@test PI_CALLS[:native_query] == 2
@test !haskey(PI_CALLS, :native_build)

err = try DynamicObjects.clear_cache!(l, :model); nothing catch e; e end
@test err isa ArgumentError
@test occursin("fixed field", sprint(showerror, err))
@test occursin("remake", sprint(showerror, err))
@test_throws ArgumentError DynamicObjects.clear_cache!(l, :no_such_property)
@test l.model == "m"
end

@testitem "clear_cache! removes disk entries of the property and its dependents" setup=[PropertyInvalidationFixtures] begin
using DynamicObjects

PI_CACHE_BASE[] = mktempdir()
empty!(PI_CALLS); PI_BUILD[] = 1
a = CachedLadder("m")
@test a.fit(1) == "fit1[build#1]"
@test a.fit(2) == "fit2[build#1]"
@test a.fit_summary == "summary[sb(m)]"
@test @is_cached a.native_build
@test @is_cached a.fit(1)

# A second instance with the same identity holds nothing in memory: the entries
# it forces are the ones an earlier process wrote.
PI_BUILD[] = 2
b = CachedLadder("m")
@test DynamicObjects.clear_cache!(b, :native_build) == [:fit, :native_build]
@test @cache_status(b.native_build) == :unstarted
@test @cache_status(b.fit(1)) == :unstarted
@test @cache_status(b.fit(2)) == :unstarted
@test @is_cached b.sb
@test @is_cached b.fit_summary          # not an entry of `fit`
@test b.fit(1) == "fit1[build#2]"
@test b.fit_summary == "summary[sb(m)]"
@test PI_CALLS[:cached_native_build] == 2
@test PI_CALLS[:fit_summary] == 1
@test PI_CALLS[:cached_sb] == 1
end

@testitem "a holder drops what it derived from a cleared child on its next sync!" setup=[PropertyInvalidationFixtures] begin
using DynamicObjects

empty!(PI_CALLS); PI_BUILD[] = 1
app = LadderApp(["a", "b"])
@test app.table == ["query[build#1[a]]", "query[build#1[b]]"]
@test app.model("a").sb == "sb[a]"
@test sync!(app) == Symbol[]

PI_BUILD[] = 2
@test DynamicObjects.clear_cache!(app.model("a"), :native_build) == [:native_build, :native_query]
@test sync!(app) == [:table]
@test app.table == ["query[build#2[a]]", "query[build#1[b]]"]
@test PI_CALLS[(:app_build, "a")] == 2
@test PI_CALLS[(:app_build, "b")] == 1     # the other model's preparation is kept
@test PI_CALLS[(:app_sb, "a")] == 1        # and so is the other branch of this one
@test sync!(app) == Symbol[]
end

@testitem "clear_cache! through a remount view drops shared and view-local work" setup=[PropertyInvalidationFixtures] begin
using DynamicObjects

empty!(PI_CALLS); PI_BUILD[] = 1
l = Ladder("m")
view = remount(l; request = "req-1")
@test view.banner == "req-1:query[build#1[spec(m)]]"
@test l.native_query == "query[build#1[spec(m)]]"   # shared with the view
@test PI_CALLS[:native_query] == 1

PI_BUILD[] = 2
@test DynamicObjects.clear_cache!(view, :native_build) == [:banner, :native_build, :native_query]
@test l.native_query == "query[build#2[spec(m)]]"
@test view.banner == "req-1:query[build#2[spec(m)]]"
@test PI_CALLS[:native_query] == 2
@test !haskey(PI_CALLS, :sb)            # never read, so never computed
end

@testitem "clear_cache! re-derives a computed @versioned version" setup=[PropertyInvalidationFixtures] begin
using DynamicObjects

PI_CACHE_BASE[] = mktempdir()
empty!(PI_CALLS); PI_BUILD[] = 1
path = joinpath(mktempdir(), "input.txt")
write(path, "first")
v = VersionedLadder(path)
@test v.native_build == "build#1"
old = @cache_path v.native_build

write(path, "second")
PI_BUILD[] = 2
@test :native_build in DynamicObjects.clear_cache!(v, :native_build)
@test v.native_build == "build#2"
new = @cache_path v.native_build
@test new != old
@test dirname(dirname(new)) == dirname(dirname(old))   # same identity, new version
@test PI_CALLS[:versioned_build] == 2
end
