using TestItemRunner

# Selective @testitem runner. Filters are passed as CLI args (also used by the
# `/tests` web route via HTMXObjects' `TestRoutes(project=...)`):
#   --htmxo-test=<file>::<name>   run one exact item
#   --name=<name>                 run items whose name matches
#   --tag=<tag>                   run items carrying a tag
#   --file=<relpath>              run items in a file
#   --list                        list matching items, run none
# No filter args → run the whole suite.
const _HTMXO_TEST_PREFIX = "--htmxo-test="
const _HTMXO_NAME_PREFIX = "--name="
const _HTMXO_TAG_PREFIX = "--tag="
const _HTMXO_FILE_PREFIX = "--file="
const _HTMXO_REQUESTED_TESTS = Set(
    arg[length(_HTMXO_TEST_PREFIX) + 1:end]
    for arg in ARGS if startswith(arg, _HTMXO_TEST_PREFIX)
)
const _HTMXO_REQUESTED_NAMES = Set(
    arg[length(_HTMXO_NAME_PREFIX) + 1:end]
    for arg in ARGS if startswith(arg, _HTMXO_NAME_PREFIX)
)
const _HTMXO_REQUESTED_TAGS = Set(Symbol(
    arg[length(_HTMXO_TAG_PREFIX) + 1:end]
) for arg in ARGS if startswith(arg, _HTMXO_TAG_PREFIX))
const _HTMXO_REQUESTED_FILES = Set(replace(
    arg[length(_HTMXO_FILE_PREFIX) + 1:end], '\\' => '/'
) for arg in ARGS if startswith(arg, _HTMXO_FILE_PREFIX))
const _HTMXO_LIST_ONLY = "--list" in ARGS
const _HTMXO_PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const _HTMXO_AVAILABLE_TESTS = Set{String}()
const _HTMXO_AVAILABLE_NAMES = Set{String}()
const _HTMXO_AVAILABLE_TAGS = Set{Symbol}()
const _HTMXO_AVAILABLE_FILES = Set{String}()
const _HTMXO_SELECTED_TESTS = Set{String}()

function _htmxo_test_identity(item)
    file = replace(relpath(item.filename, _HTMXO_PROJECT_ROOT), '\\' => '/')
    file, file * "::" * item.name
end

function _htmxo_test_filter(item)
    file, key = _htmxo_test_identity(item)
    push!(_HTMXO_AVAILABLE_TESTS, key)
    push!(_HTMXO_AVAILABLE_NAMES, item.name)
    push!(_HTMXO_AVAILABLE_FILES, file)
    union!(_HTMXO_AVAILABLE_TAGS, item.tags)

    selected = (isempty(_HTMXO_REQUESTED_TESTS) || key in _HTMXO_REQUESTED_TESTS) &&
        (isempty(_HTMXO_REQUESTED_NAMES) || item.name in _HTMXO_REQUESTED_NAMES) &&
        (isempty(_HTMXO_REQUESTED_TAGS) || !isdisjoint(_HTMXO_REQUESTED_TAGS, item.tags)) &&
        (isempty(_HTMXO_REQUESTED_FILES) || file in _HTMXO_REQUESTED_FILES)
    selected && push!(_HTMXO_SELECTED_TESTS, key)
    !_HTMXO_LIST_ONLY && selected
end

@run_package_tests filter=_htmxo_test_filter verbose=true

function _htmxo_require_known(label, requested, available)
    missing = setdiff(requested, available)
    isempty(missing) || error("Unknown $label selection(s): " * join(sort!(string.(collect(missing))), ", "))
end

_htmxo_require_known("test", _HTMXO_REQUESTED_TESTS, _HTMXO_AVAILABLE_TESTS)
_htmxo_require_known("name", _HTMXO_REQUESTED_NAMES, _HTMXO_AVAILABLE_NAMES)
_htmxo_require_known("tag", _HTMXO_REQUESTED_TAGS, _HTMXO_AVAILABLE_TAGS)
_htmxo_require_known("file", _HTMXO_REQUESTED_FILES, _HTMXO_AVAILABLE_FILES)

if _HTMXO_LIST_ONLY
    for key in sort!(collect(_HTMXO_SELECTED_TESTS))
        println(key)
    end
elseif (!isempty(_HTMXO_REQUESTED_TESTS) || !isempty(_HTMXO_REQUESTED_NAMES) ||
        !isempty(_HTMXO_REQUESTED_TAGS) || !isempty(_HTMXO_REQUESTED_FILES)) &&
        isempty(_HTMXO_SELECTED_TESTS)
    error("The requested selection matched zero tests.")
end
