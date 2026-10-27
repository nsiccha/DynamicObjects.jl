using TestItemRunner

# A landing that adds or changes public API bumps the patch version and adds its
# entry under a new heading at the top of CHANGELOG.md (user decision 0uokyy9,
# the general policy), so a dependant can state that version as its [compat]
# floor. Two landings that bump at once then collide on that heading, never on a
# shared number.
@testitem "CHANGELOG.md's newest version is Project.toml's version" tags=[:core] begin
    # pkgversion reads Project.toml; TOML is not a test target (Pkg.test hides @stdlib).
    version = pkgversion(DynamicObjects)
    root = pkgdir(DynamicObjects)
    # eachline strips "\n" and "\r\n" alike: a Windows checkout writes CRLF.
    matches = (match(r"^## (\d+\.\d+\.\d+)\s*$", line) for line in eachline(joinpath(root, "CHANGELOG.md")))
    headings = [VersionNumber(m[1]) for m in matches if m !== nothing]
    @test !isempty(headings)
    @test first(headings) == version
    @test allunique(headings)
    @test issorted(headings; rev=true)
end
