function lint_docs(pages)
    first.(pages) == ["Start", "Guides", "Examples", "Reference"] ||
        error("Documentation navigation must use Start, Guides, Examples, Reference.")
    listed = String[]
    for (group, entries) in pages, (_, file) in entries
        push!(listed, file)
        source = read(joinpath(@__DIR__, "src", file), String)
        occursin(r"(?m)^```(?:julia|jldoctest)\b", source) &&
            error("Runnable static fence in $file; use @example, @eval or @repl.")
        prose = replace(source, r"(?ms)^```.*?^```" => "")
        occursin(r"(?i)\b(seamless|robust|powerful|leverage|delve|crucial|comprehensive|unlock|simply)\b|it's worth noting", prose) &&
            error("Banned prose in $file.")
        words = length(split(prose))
        group == "Guides" && words >= 1500 && error("Guide $file has $words prose words.")
        if group == "Examples"
            800 <= words <= 1500 || error("Example $file has $words prose words; expected 800–1500.")
            occursin("```@example", source) || error("No executed example in $file.")
            occursin("DocsFigures.figure(", source) || error("No generated figure in $file.")
        end
        println("DOCS_PAGE\t", file, '\t', words, " prose words")
    end
    actual = [relpath(joinpath(root, file), joinpath(@__DIR__, "src"))
              for (root, _, files) in walkdir(joinpath(@__DIR__, "src"))
              for file in files if endswith(file, ".md")]
    Set(actual) == Set(listed) || error("The navigation and docs/src page inventory differ.")
end
