# Qualified public contracts need an explicit inventory: Documenter's :exports
# check does not catch their removal from the reference pages.
const QUALIFIED_PUBLIC_DOCS = [
    "DynamicObjects.$name" for name in (
        "MemCacheEntry", "clear_cache!", "canonical_hash", "RemountSharedContextError",
        "save", "load", "progress_notes", "run!", "abandon!", "property_executor",
        "await_deferred", "property_settled", "configure_queue!", "queue_settings",
        "job_queue", "JobQueue", "QueuedItem", "observe_queue!", "unobserve_queue!",
        "queued_items", "queue_position", "abandon_queued!", "QueuedCall", "enqueue!",
        "QueueExecutor", "worker_status", "restart_worker!", "RemoteComputationError",
        "carry_to_worker!", "on_requester_message!", "send_to_requester",
        "ComputeTraceEvent", "ComputeTraceInvalidation",
    )
]

function lint_docs(pages)
    first.(pages) == ["Start", "Guides", "Examples", "Reference"] ||
        error("Documentation navigation must use Start, Guides, Examples, Reference.")
    listed = String[]
    documented = Set{String}()
    for (group, entries) in pages, (_, file) in entries
        push!(listed, file)
        source = read(joinpath(@__DIR__, "src", file), String)
        for block in eachmatch(r"(?ms)^```@docs\s*\n(.*?)^```", source)
            union!(documented, strip.(split(block.captures[1], '\n')))
        end
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
    missing = setdiff(QUALIFIED_PUBLIC_DOCS, documented)
    isempty(missing) || error("Missing qualified public API docstrings: " * join(missing, ", "))
    println("DOCS_QUALIFIED_API\t", length(QUALIFIED_PUBLIC_DOCS), " contracts covered")
end
