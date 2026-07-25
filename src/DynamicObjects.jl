"""
    DynamicObjects

Provides the `@dynamicstruct` macro for defining structs with lazily computed,
optionally disk-cached properties.

# Exports
- [`@dynamicstruct`](@ref): Define a struct with computed/cached properties.
- [`@cache_status`](@ref): Get the disk-cache status of a property (`:unstarted`, `:started`, `:ready`).
- [`@is_cached`](@ref): Check whether a property's disk cache is ready.
- [`@cache_path`](@ref): Get the file path used for a property's disk cache.
- [`@memo!`](@ref): Wrap a call site so `IndexableProperty` callees are cached (now the default; makes it explicit).
- [`memoize!`](@ref): Explicit cached call into an `IndexableProperty`.
- [`maybememoize!`](@ref): Dispatch helper behind `@memo!`; cached on IPs, plain call otherwise.
- [`@fresh`](@ref): Wrap a call site so `IndexableProperty` callees are recomputed fresh (opt out of the default caching).
- [`fresh`](@ref): Explicit uncached call into an `IndexableProperty`.
- [`maybefresh`](@ref): Dispatch helper behind `@fresh`; uncached on IPs, plain call otherwise.
- [`remake`](@ref): Create a new instance of a `@dynamicstruct` type with some fields changed.
- [`remount`](@ref): Bind fresh request/context properties while retaining unrelated cache identity.
- [`fetchindex`](@ref): Non-blocking access to `ThreadsafeDict`-backed properties with `(rv, status)` callback.
- [`getstatus`](@ref): Read the status object for an in-flight computation.
- [`@clear_cache!`](@ref): Clear the disk and in-memory cache for a property.
- [`@persist`](@ref): Manually persist a property value to disk cache.
- [`PropertyComputationError`](@ref): Exception wrapper for errors during property computation.
- [`unwrap_error`](@ref): Dig through exception wrappers to find the root cause.
- [`entries`](@ref): List all entries in a `ThreadsafeDict`-backed property with state info.
- [`cached_entries`](@ref): Iterate completed (non-Task) entries of an indexed property.
- [`clear_mem_caches!`](@ref): Clear in-memory memoized values (disk caches untouched).
- [`clear_disk_caches!`](@ref): Delete on-disk cache files (in-memory values untouched).
- [`clear_all_caches!`](@ref): Clear both in-memory and disk caches.
- [`PersistentSet`](@ref): Thread-safe, disk-persisted `Set`.
- [`LazyPersistentDict`](@ref): Thread-safe, lazily-loaded, disk-persisted `Dict`.
- [`KeyTracker`](@ref): Abstract type for pluggable accessed-keys persistence strategies.
- [`SharedFileTracker`](@ref): Default strategy — single shared `_keys.sjl` file.
- [`NoKeyTracker`](@ref): No-op strategy — never records or loads keys.
- [`key_tracker`](@ref): Override to set the tracking strategy per object type / property.
- [`record!`](@ref): Record an accessed key via a `KeyTracker`.
- [`load_keys`](@ref): Load the full set of recorded keys via a `KeyTracker`.
- [`property_descriptor`](@ref): Reflect semantic inputs, dependencies, and storage policy without execution.
- [`execute_materialization`](@ref): Framework-only governed semantic execution (applications call operations normally).
- [`release_materialization!`](@ref): Release a retained semantic root without racing active executions.
- [`materialization_gc!`](@ref): Collect only unreachable, provider-released storage with proven ownership.
"""
module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached, @cache_path, @clear_cache!, @persist, @memo!, @fresh, fresh, @fetch!, @dynamic_progress, memoize!, maybememoize!, maybefresh, maybefetchindex!, maybefetchproperty!, maybeprogress!, noprogress, remake, remount, file_version, fetchindex, fetchindex!, fetchproperty, fetchproperty!, getstatus, PropertyComputationError, unwrap_error, entries, cached_entries, clear_all_caches!, clear_mem_caches!, clear_disk_caches!, PersistentSet, LazyPersistentDict, KeyTracker, SharedFileTracker, NoKeyTracker, key_tracker, record!, load_keys, Pending

import SHA, Serialization, Mmap, Treebars

struct DiskCacheLocks
    lock::ReentrantLock
    locks::Dict{String, ReentrantLock}
end
DiskCacheLocks() = DiskCacheLocks(ReentrantLock(), Dict{String, ReentrantLock}())
get_path_lock!(d::DiskCacheLocks, path::String) = lock(d.lock) do
    get!(() -> ReentrantLock(), d.locks, path)
end

# Ordinary properties promoted by the governed executor share one process-local
# per-path lock registry. Explicit @cached/@mmap properties keep their generated
# per-property registries; this fallback exists so automatic storage does not
# require a declaration-site marker merely to obtain safe write coordination.
const _AUTOMATIC_MATERIALIZATION_DISK_LOCKS = DiskCacheLocks()

persistent_hash(x) = begin
    b = IOBuffer()
    Serialization.serialize(b, x)
    bytes2hex(SHA.sha1(take!(b)))
end

# --- Disk format extension point (D1) ---
#
# `save` / `load` are the format-agnostic disk-cache (de)serialization seam.
# The `@dynamicstruct` disk-cache read/write path dispatches both on a `Val`
# format token so it never hardcodes `Serialization`. The macro emits the
# token per property via `_disk_format` (default `Val(:serial)`; `Val(:mmap)`
# for `@mmap` properties). Public + overloadable by qualified name — register
# a new format with `DynamicObjects.save(::Val{:myfmt}, …)` /
# `DynamicObjects.load(::Val{:myfmt}, …)`. Not exported (the bare names `save`
# / `load` collide with too many packages).
#
# `load`'s third argument is an eltype hint: a `Type` when the property carried
# a `::T` annotation (type-stable fast path), or `nothing` for the
# self-describing cold path.
save(fmt::Val, path::AbstractString, x) = error("no `save` method for format $fmt")
load(fmt::Val, path::AbstractString) = load(fmt, path, nothing)
load(fmt::Val, path::AbstractString, ::Any) = error("no `load` method for format $fmt")

save(::Val{:serial}, path::AbstractString, x) = Serialization.serialize(path, x)
load(::Val{:serial}, path::AbstractString, ::Any) = Serialization.deserialize(path)

# Every disk-cache write goes through `_atomic_save`: the format payload is
# written to a unique sibling temp file, then `mv(...; force=true)` renames it
# over `path`. `tempname(dirname(path))` is guaranteed same-filesystem, so the
# `mv` is a `rename(2)` — atomic. Consequences: a reader (`get_cache_status` /
# `load`) never observes a half-written file (it sees either the prior complete
# file or the new one), a crash mid-`save` leaves the old cache intact instead
# of a truncated one, and an in-flight READONLY `@mmap` mapping keeps the old
# inode alive until unmapped (a plain in-place overwrite would corrupt it).
function _atomic_save(fmt::Val, path::AbstractString, x)
    tmp = tempname(dirname(path); cleanup=false)
    try
        r = save(fmt, tmp, x)
        mv(tmp, path; force=true)
        r
    catch
        rm(tmp; force=true)
        rethrow()
    end
end

# --- `Val{:mmap}` format (D2-v2, D3, layout) ---
#
# Single-file layout `[header][payload]`:
#   magic   :: 4×UInt8  = b"DOMM"
#   version :: UInt8    = _MMAP_VERSION
#   tag     :: UInt8    = index into _MMAP_ELTYPE_TAGS
#   ndims   :: UInt8
#   dims    :: ndims × Int64
#   payload :: raw column-major isbits bytes
# `load` reads the header, then `Mmap.mmap`s the payload READONLY at the header
# offset — Julia page-aligns the mapping internally, so any header size works.
# The mapping is opened from a read-only stream, so the returned bare
# `Array{T,N}` is backed by a PROT_READ region: mutations fault (D3).
const _MMAP_MAGIC = (UInt8('D'), UInt8('O'), UInt8('M'), UInt8('M'))
const _MMAP_VERSION = UInt8(2)
const _MMAP_ALIGN = 16
# Upper bound on the `ndims` byte accepted from a header. Guards a single corrupt
# byte turning into a 255-element `dims` read and a nonsense payload length.
const _MMAP_MAXDIMS = 32
# Stable integer tags (1-based index) for the isbits numeric eltypes the
# self-describing (un-annotated) load path supports. Append-only — never
# reorder, or existing files mis-decode. The annotated path uses the `::T`
# eltype directly and only needs the registry to write a header tag.
const _MMAP_ELTYPE_TAGS = (
    Float64, Float32, Float16,
    Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Bool, ComplexF32, ComplexF64,
)
_mmap_tag_of(::Type{T}) where {T} = let i = findfirst(==(T), _MMAP_ELTYPE_TAGS)
    i === nothing && error("@mmap: eltype $T is not in the supported isbits numeric registry $(_MMAP_ELTYPE_TAGS). Annotate with a registered eltype or register a custom `save`/`load` format.")
    UInt8(i)
end
_mmap_eltype_of(tag::UInt8) = let i = Int(tag)
    (1 <= i <= length(_MMAP_ELTYPE_TAGS)) || error("@mmap: unknown eltype tag $i in header (max $(length(_MMAP_ELTYPE_TAGS))). File written by a newer DynamicObjects?")
    _MMAP_ELTYPE_TAGS[i]
end

function save(::Val{:mmap}, path::AbstractString, x::AbstractArray)
    A = x isa Array ? x : Array(x)   # ensure dense column-major isbits payload
    isbitstype(eltype(A)) || error("@mmap: array eltype $(eltype(A)) is not isbits; only isbits arrays can be memory-mapped.")
    tag = _mmap_tag_of(eltype(A))
    offset, len = open(path, "w") do io
        write(io, _MMAP_MAGIC...)
        write(io, _MMAP_VERSION)
        write(io, tag)
        write(io, UInt8(ndims(A)))
        for d in size(A); write(io, Int64(d)); end
        pad = mod(-position(io), _MMAP_ALIGN)
        write(io, zeros(UInt8, pad))
        offset = position(io)
        write(io, A)
        (offset, sizeof(A))
    end
    # `IOStream.write` may return normally after a short write on a full disk
    # (observed on macOS). Validate after `close` has flushed the stream, before
    # `_atomic_save` renames this temp file over the cache entry. On failure,
    # `_atomic_save` removes the temp and leaves no header-only cache poison.
    _mmap_check_written_complete(path, offset, len)
    A
end
# Reached when the property's VALUE is neither an `AbstractArray` nor a type some
# extension has claimed (`DataFrame`, via `DataFramesArrowExt`). Note the gate is
# the runtime value, not the `::T` annotation — `_disk_eltype` only steers `load`.
# The wrap-on-read escape hatch is the one every non-array wrapper wants
# (`TreeData`, `AxisArray`, …): mmap the dense backing array, rebuild the wrapper
# in a plain sibling — the wrapper is views + labels, so it costs nothing.
save(::Val{:mmap}, path::AbstractString, x) = error("""
    @mmap: no `save` method for a property value of type $(typeof(x)).
    Supported payloads: an `AbstractArray` with eltype in $(_MMAP_ELTYPE_TAGS), \
    or a type an extension claims (`DataFrame` — needs `using Arrow, DataFrames`).
    For any other wrapper type, `@mmap` the dense backing array and rebuild the \
    wrapper in a plain sibling property:
        @mmap raw(i)::Matrix{Float64} = <compute>
        wrapped(i) = Wrapper(raw(i), <labels>)
    Or give the type its own format by defining `DynamicObjects.save(::Val{:mmap}, \
    ::AbstractString, ::$(nameof(typeof(x))))` + the matching `load`.""")

# Read + validate the header; return (eltype_tag::UInt8, ndims::Int, dims::Vector{Int}, offset::Int).
function _mmap_read_header(io::IO)
    magic = ntuple(_ -> read(io, UInt8), 4)
    magic == _MMAP_MAGIC || error("@mmap: bad magic $(magic) — not a DynamicObjects mmap file.")
    ver = read(io, UInt8)
    ver == _MMAP_VERSION || error("@mmap: file version $ver ≠ current v$(_MMAP_VERSION) — delete the cached file and re-run.")
    tag = read(io, UInt8)
    nd = Int(read(io, UInt8))
    0 <= nd <= _MMAP_MAXDIMS || error("@mmap: header ndims $nd outside 0:$_MMAP_MAXDIMS — corrupt header.")
    dims = [Int(read(io, Int64)) for _ in 1:nd]
    all(>=(0), dims) || error("@mmap: header dims $dims contain a negative extent — corrupt header.")
    offset = position(io) + mod(-position(io), _MMAP_ALIGN)
    (tag, nd, dims, offset)
end

# Payload byte count named by the header, overflow-checked: a corrupt `dims` must
# not wrap into a small `len` that then passes the truncation check below.
function _mmap_payload_bytes(::Type{ET}, dims::Vector{Int}, path) where {ET}
    n = 1
    for d in dims
        n, ovf = Base.Checked.mul_with_overflow(n, d)
        ovf && error("@mmap: element count overflows for dims $dims in $path — corrupt header.")
    end
    len, ovf = Base.Checked.mul_with_overflow(n, sizeof(ET))
    ovf && error("@mmap: payload size overflows for dims $dims of $ET in $path — corrupt header.")
    len
end

# `Mmap.mmap` maps BEYOND EOF. A file whose header is intact but whose payload is
# short (the disk filled mid-write, an external truncation, a writer that died)
# maps cleanly, and then touching a page past EOF raises SIGBUS — a signal, not an
# exception. The disk-cache `catch`-and-recompute below never runs and the process
# dies. So prove the payload is fully present BEFORE mapping: a short file becomes
# a catchable error that the cache layer heals by `rm` + recompute.
#
# Julia's `Mmap.mmap` happens to reject this too (it tries to grow the file and a
# read-only stream throws), but that is incidental — it depends on the stream's
# permissions, not on the payload actually being there. Check it ourselves.
function _mmap_check_complete(io::IO, path, offset::Int, len::Int)
    fsz = filesize(io)
    need = offset + len
    fsz >= need && return nothing
    error("@mmap: $path is truncated — need $need bytes (header offset $offset + payload $len) but the file holds $fsz. A partial cache file; it will be deleted and recomputed.")
end

# Validate a newly-written mmap file after the write stream has been closed.
# This is distinct from `_mmap_check_complete`, which validates a cache hit:
# here `path` is `_atomic_save`'s unique temp file, and throwing prevents the
# subsequent atomic rename from publishing a partial cache entry.
function _mmap_check_written_complete(path, offset::Int, len::Int)
    fsz = filesize(path)
    need = offset + len
    fsz == need && return nothing
    error("@mmap: incomplete write to $path — expected exactly $need bytes (header offset $offset + payload $len) but the file holds $fsz. The temporary file will be discarded; no partial cache entry will be published.")
end

# Annotated fast path: the property's `::T` array type is known → type-stable.
function load(::Val{:mmap}, path::AbstractString, ::Type{A}) where {A<:AbstractArray}
    ET = eltype(A); N = ndims(A)
    io = open(path, "r")
    try
        tag, nd, dims, offset = _mmap_read_header(io)
        nd == N || error("@mmap: header ndims $nd ≠ annotated ndims $N for $path.")
        _mmap_eltype_of(tag) === ET || error("@mmap: header eltype $(_mmap_eltype_of(tag)) ≠ annotated eltype $ET for $path.")
        _mmap_check_complete(io, path, offset, _mmap_payload_bytes(ET, dims, path))
        Mmap.mmap(io, Array{ET,N}, NTuple{N,Int}(dims), offset)
    finally
        close(io)   # mapping survives the fd close
    end
end

# Mirror of the `save` fallback above, and the exact wall that message walks you
# into: it says "define `save` … + the matching `load`", and if you define only
# the first half the generic `load(::Val, …, ::Any)` answers with `no `load`
# method for format Val{:mmap}()` — naming neither the type, nor the file, nor
# the remedy. Reached whenever a `@mmap` property's `::T` annotation names a type
# no `load` method claims.
load(::Val{:mmap}, path::AbstractString, ::Type{T}) where {T} = error("""
    @mmap: no `load` method for the annotated type $T (reading $path).
    `$T` is neither an `AbstractArray` nor a type an extension claims. If it should \
    be the latter, load that extension first (`DataFrame` needs `using Arrow, DataFrames`).
    Otherwise define BOTH halves of the format — a `save` without its `load` writes a \
    file nothing can read back:
        DynamicObjects.save(::Val{:mmap}, ::AbstractString, ::$T)
        DynamicObjects.load(::Val{:mmap}, ::AbstractString, ::Type{$T})
    Or drop the annotation and `@mmap` the dense backing array instead.""")

# `@mmap p::T` — reject an annotation `@mmap` cannot honour (D7).
#
# `save` densifies via `Array(x)` and the annotated `load` consumes `T` for its
# `eltype` and `ndims` only, then always returns a bare `Array{ET,N}`. So a
# concrete wrapper annotation (`MyArray{Float64,2}`, a `SubArray` type, …) is a
# promise DO cannot keep: the property is *declared* one type and *delivers*
# another, with nothing warning. That is `dev` §1's silent-swallow class, so
# refuse the declaration instead of quietly rewriting its meaning.
#
# The predicate is exactly "can the value DO returns satisfy the annotation?" —
# `Array{eltype(T),ndims(T)} <: T`. It admits `Matrix{Float64}` (which *is*
# `Array{Float64,2}`) and an abstract supertype like `AbstractMatrix{Float64}`
# (a `Matrix` is one, so nothing is violated), and rejects wrappers.
#
# Only CONCRETE annotations make a promise that can be broken; a non-concrete one
# (`AbstractArray`, `Array{Float64}`) pins no shape. Non-`AbstractArray`
# annotations belong to an extension (`DataFrame`) and are not checked here — an
# unclaimed one still fails loudly at `save`/`load` above.
#
# Emitted by `@dynamicstruct` as a top-level call, so it fires when the struct is
# DEFINED — before any property computes. (Not literally at macro-expansion: the
# annotation is an expression there, and the type it names may not exist yet.)
_check_mmap_annotation(type::Symbol, name::Symbol, ::Type{T}) where {T} = begin
    (T <: AbstractArray && isconcretetype(T)) || return nothing
    ET, N = eltype(T), ndims(T)
    Array{ET,N} <: T && return nothing
    error("""
        @mmap $type.$name::$T — `@mmap` cannot deliver this type.
        A memory-mapped property always loads back as a bare `Array{$ET,$N}`: `save`
        densifies the value via `Array(x)`, and the annotation supplies only eltype
        and ndims. Declaring `::$T` would be silently violated on every read.
        Annotate the dense array, and rebuild the wrapper in a plain sibling:
            @mmap raw::Array{$ET,$N} = <compute>
            $name = $(nameof(T))(raw, <labels>)""")
end
# A non-`AbstractArray` annotation, or anything that is not a type at all.
_check_mmap_annotation(::Symbol, ::Symbol, ::Any) = nothing

# Self-describing cold path for DO's own `DOMM` container: no annotation →
# eltype + ndims come from the header (type-unstable return, accepted per
# D2-v2).
function _mmap_load_domm(path::AbstractString)
    io = open(path, "r")
    try
        tag, nd, dims, offset = _mmap_read_header(io)
        ET = _mmap_eltype_of(tag)
        _mmap_check_complete(io, path, offset, _mmap_payload_bytes(ET, dims, path))
        Mmap.mmap(io, Array{ET,nd}, NTuple{nd,Int}(dims), offset)
    finally
        close(io)
    end
end

# --- `@mmap` container registry (annotation-optional loads) ---
#
# With a `::T` annotation the load routes on the type. Without one the third
# argument is `nothing` and the FILE has to say what it holds: DO's own `DOMM`
# array container, or a foreign one an extension owns (`ARROW1`, for the
# `DataFrame` path in `DataFramesArrowExt`). So the un-annotated load sniffs the
# leading magic bytes and routes on them — which is what makes `@mmap df = …`
# work without `::DataFrame`.
#
# The registry holds only the FOREIGN containers. `DOMM` is built in and is also
# the fallback, so a file nothing claims still hits `_mmap_read_header`'s
# bad-magic error, which the disk cache heals by `rm` + recompute.
#
# Extensions register from their `__init__` — a `push!` at module top level runs
# during precompilation and would not survive into the loading process:
#
#     DynamicObjects.register_mmap_container!(collect(UInt8, b"ARROW1"),
#         path -> DynamicObjects.load(Val(:mmap), path, DataFrame))
#
# Registration is idempotent per magic (re-registering replaces the loader), so
# a re-run `__init__` cannot grow the table.
const _MMAP_CONTAINERS = Vector{Tuple{Vector{UInt8},Any}}()

_has_prefix(head::AbstractVector{UInt8}, magic) =
    length(head) >= length(magic) && all(i -> head[i] === UInt8(magic[i]), eachindex(magic))

function register_mmap_container!(magic::AbstractVector{UInt8}, loader)
    m = collect(UInt8, magic)
    isempty(m) && error("register_mmap_container!: magic must be non-empty.")
    _has_prefix(m, _MMAP_MAGIC) &&
        error("register_mmap_container!: magic $m starts with DynamicObjects' own DOMM magic — a container that shadows the built-in array format can never be reached.")
    i = findfirst(e -> first(e) == m, _MMAP_CONTAINERS)
    isnothing(i) ? push!(_MMAP_CONTAINERS, (m, loader)) : (_MMAP_CONTAINERS[i] = (m, loader))
    nothing
end

# Leading bytes needed to tell the containers apart.
_mmap_sniff_length() =
    max(length(_MMAP_MAGIC), maximum(length(first(e)) for e in _MMAP_CONTAINERS; init=0))

function load(::Val{:mmap}, path::AbstractString, ::Nothing)
    head = open(io -> read(io, _mmap_sniff_length()), path, "r")
    if !_has_prefix(head, _MMAP_MAGIC)
        for (magic, loader) in _MMAP_CONTAINERS
            _has_prefix(head, magic) && return loader(path)
        end
    end
    _mmap_load_domm(path)
end

# Per-property disk-format / eltype-hint slots. `@dynamicstruct` emits an
# override for each `@mmap` property; everything else uses these defaults.
_disk_format(o, ::Val) = Val(:serial)
_disk_eltype(o, ::Val) = nothing

_automatic_mmap_eligible(::Any) = false
_automatic_mmap_eligible(value::AbstractArray) =
    isbitstype(eltype(value)) && eltype(value) in _MMAP_ELTYPE_TAGS

iscached(o, ::Val) = false
cache_version(o, ::Val) = nothing
compute_property(o, ::Val{:__hash_fields__}) = ntuple(Base.Fix1(getfield, o), fieldcount(typeof(o))-1)
compute_property(o, ::Val{:__hash__}) = persistent_hash((typeof(o), _hash_replace(o.__hash_fields__)))
# Shallow walker used only by the :__hash__ compute. Leaves non-DO values
# structurally identical so hashes stay stable for DOs that don't nest DOs,
# and substitutes any DO with its own (stable) `.__hash__` string. Per-type
# `_hash_replace(::MyType) = x.__hash__` overloads are emitted by @dynamicstruct.
_hash_replace(x::Tuple) = map(_hash_replace, x)
_hash_replace(x::NamedTuple) = map(_hash_replace, x)
_hash_replace(x) = x

# ── @versioned: identity/version split of the disk-cache path ───────────────
# A `@versioned name::T` fixed field is the *version dimension*: excluded from
# the object's cache IDENTITY and instead selecting a per-version subdir, so a
# versioned object caches under `base/<identity>/<version>/…`. All versions of
# one logical object share the identity dir (this is what lets "hold only the
# most recent" prune stale siblings); a fresh version cache-misses cleanly.
# Non-versioned types keep the byte-identical `base/<__hash__>/` layout via the
# fast path below. The per-type `has_versioned_fields` / `_identity_hash_fields`
# / `_version_hash_fields` overrides are emitted by @dynamicstruct ONLY when a
# `@versioned` field is declared, so every existing struct is unaffected.
has_versioned_fields(::Type) = false
_identity_hash_fields(o) = o.__hash_fields__   # non-versioned: identity = all fixed fields
_version_hash_fields(o) = ()                   # non-versioned: no version segment
compute_property(o, ::Val{:__identity_hash__}) =
    persistent_hash((typeof(o), _hash_replace(_identity_hash_fields(o))))
compute_property(o, ::Val{:__version_tag__}) = begin
    vhf = _version_hash_fields(o)
    isempty(vhf) ? "" : persistent_hash(_hash_replace(vhf))
end
compute_property(o, ::Val{:__cache_base__}) = "cache"
compute_property(o, ::Val{:__cache_path__}) =
    has_versioned_fields(typeof(o)) ?
        joinpath(o.__cache_base__, o.__identity_hash__, o.__version_tag__) :
        joinpath(o.__cache_base__, o.__hash__)

# "Hold only the most recent" (the user-requested automatic convenience). A
# versioned object caches under `base/<identity>/<version>/`; when it touches
# that dir, SIBLING version dirs under the same identity are pruned, so only the
# current version's entry survives on disk. This is a *targeted, version-keyed*
# cleanup — NOT the general byte-budget LRU deleted in cc84ee6. Disk only:
# in-memory caches on other live instances are untouched. Default-on for
# versioned types; opt out per-instance with `T(…; __hold_recent_version__=false)`
# (the overrideable-default idiom) or per-type by overriding this compute.
# NOTE: if two versions of one object are alive AND both compute, they take
# turns pruning each other — expected under "hold only the most recent".
compute_property(o, ::Val{:__hold_recent_version__}) = has_versioned_fields(typeof(o))
function _prune_stale_versions!(o)
    getorcomputeproperty(o, :__hold_recent_version__) || return nothing
    dir = o.__cache_path__            # base/<identity>/<version>
    keep = basename(dir)
    isempty(keep) && return nothing   # not actually versioned → nothing to prune
    identity_dir = dirname(dir)       # base/<identity>
    isdir(identity_dir) || return nothing
    entries = try readdir(identity_dir) catch; return nothing end
    length(entries) <= 1 && return nothing   # cheap guard: only the current version present
    for e in entries
        e == keep && continue
        try
            rm(joinpath(identity_dir, e); recursive = true, force = true)
        catch
            # best-effort: a concurrent writer may be creating/removing it
        end
    end
    nothing
end

"""
    file_version(path; by=:mtime) -> String

Probe a file's current state, for use as a `@versioned` field's value. This is
the "DO derives the version" half of the file-backed pattern: compute it AT THE
CALL SITE (no per-access I/O) and pass it to the constructor / `remake` at the
mutation boundary. `by` trades cost against precision:

- `:mtime` — modification time (one `stat`, cheapest; coarse: misses a
  content-preserving rewrite, and a `git checkout` bumps mtimes).
- `:hash`  — a stable hash of the file bytes (reads the whole file; exact).
- `:git`   — the file's git blob id (`git hash-object`; exact, cheap for tracked
  files), falling back to `:hash` if git is unavailable.

Returns `""` for a missing file, so a not-yet-created file has a stable version.
"""
function file_version(path; by::Symbol = :mtime)
    isfile(path) || return ""
    if by === :mtime
        string(mtime(path))
    elseif by === :hash
        persistent_hash(read(path))
    elseif by === :git
        try
            strip(read(`git hash-object $path`, String))
        catch
            persistent_hash(read(path))
        end
    else
        error("file_version: unknown probe `by=$by` — use :mtime, :hash, or :git.")
    end
end
# Progress tracking defaults IN (2026-07-09, decision 2f84ap): every DO that
# doesn't declare `__status__` gets its own `:state` root, so `htmx_render`
# never meets a `nothing` tree and no app has to remember the boilerplate.
#
# `description=""` is Treebars' sentinel for a *structural* node, NOT a
# missing one: `_is_bare_wrapper` (empty description + empty message + no
# counter) with no explicit `displayed=` makes `_renders_self` false, so the
# root emits nothing and its children hoist a level. `description=nothing`
# is NOT an option — `StateProgress.description::String`, so it throws.
# The type name was considered and rejected: it always renders a row, and
# "PKPDDraws" means nothing to the humans reading the progress tree.
#
# Like every `x = y` in a struct body, this is an OVERRIDEABLE DEFAULT: a
# constructor kwarg seeds the PropertyCache and wins. So `MyApp()` gets a root,
# `MyApp(; __status__ = nothing)` gets none, and `@include kid = Child()` hands
# the child the parent's substatus — an override, not a violation of whatever
# `Child` declares. Silence a subtree at the point of use, e.g.
# `@include kid = Child(; __status__ = nothing)`; a bare `__status__ = nothing`
# in a struct body is that struct's *standalone* default.
compute_property(o, ::Val{:__status__}) = Treebars.initialize_progress!(:state; description="")
compute_property(o, ::Val{:__strict__}) = true
compute_property(o, ::Val{:__substatus__}, name, args...; kwargs...) =
    _default_substatus(o.__status__, o, name, args...; kwargs...)
_default_substatus(status, o, name, args...; kwargs...) = nothing

# ── Magic-property deprecations (2026-07-07, decision 2canrl) ──────────────
# The data-side auto-properties were renamed to the dunder namespace and
# __cache_type__ was removed (single threadsafe cache). ONE registry drives
# BOTH the runtime access-shim (generated just below) AND the parse-time
# declaration error (in `dynamicstruct`), so the two can't drift. Remove the
# whole block once every consumer has migrated off the old names.
const _RENAMED_MAGIC = (;
    hash        = :__hash__,
    hash_fields = :__hash_fields__,
    cache_base  = :__cache_base__,
    cache_path  = :__cache_path__,
)
const _REMOVED_MAGIC = (;
    __cache_type__ = "the cache is always threadsafe (`ThreadsafeDict`) now — drop it",
)
for (old, new) in pairs(_RENAMED_MAGIC)
    msg = "`$old` was renamed to `$new` (2026-07-07, decision 2canrl); use `$new`."
    @eval compute_property(o, ::Val{$(QuoteNode(old))}) = error($msg)
end
for (old, why) in pairs(_REMOVED_MAGIC)
    msg = "`$old` was removed (2026-07-07, decision 2canrl); $why."
    @eval compute_property(o, ::Val{$(QuoteNode(old))}) = error($msg)
end

# ── Magic properties resolvable as BARE references inside a body ───────────
# So a property body may write `__hash__` (not `__self__.__hash__`) and have it
# resolved like a sibling property. The injected data-side auto-properties are
# otherwise absent from a struct's `prop_names` (they live only in the slot-
# inference topology), so `walk_rhs` would leave a bare `__hash__` as a free
# variable. NOT here: `__parent__` (children already declare it via a
# `__parent__ = nothing` prepend, so it's a real entry in their `prop_names`;
# a top-level struct has no parent) and `__status__`/`__substatus__`
# (`__status__` is threaded as a kwarg-local and must STAY the local, never
# `__self__.__status__`; `__substatus__` is an indexed call, not a value).
const _BAREREF_MAGIC = Set{Symbol}([
    :__hash__, :__hash_fields__, :__cache_base__, :__cache_path__, :__strict__,
])

# Substatus lifecycle hooks — the generic methods are no-ops so DO stays
# correct with progress disabled (`__status__===nothing`); the
# `::Treebars.ProgressNode` specializations below forward to Treebars'
# lifecycle. Called from ThreadsafeDict's spawn wrapper around `f(s)` to give
# the substatus the `with_progress` init/run/finalize symmetry it otherwise
# lacks.
_finalize_substatus!(s) = nothing
_finalize_substatus!(::Nothing) = nothing
_fail_substatus!(s, e) = nothing
_fail_substatus!(::Nothing, e) = nothing

# Disk-load reporting hook — the generic method is a no-op; the
# `::Treebars.ProgressNode` specialization below sets the substatus message to
# "from disk: <size>". Called from `_computeproperty` just before
# `Serialization.deserialize` when the cache is `:ready` so the user sees
# something flash up for big-file loads instead of a silent stall.
_report_disk_load!(s, cache_path, size_bytes) = nothing
_report_disk_load!(::Nothing, _, _) = nothing

# ── Treebars-backed progress (folded from the former weak-dep TreebarsExt;
# Treebars is now a hard dep, decision w0rn26 → A). These methods light up the
# progress tree whenever a real `Treebars.ProgressNode` is threaded; with
# `__status__===nothing` the generic no-op methods above run instead. ──

# Description of a property's substatus node: the property's docstring — the
# opt-in signal for "label this in the progress tree" — when present, else an
# empty string, which makes the Treebars node a bare wrapper the renderer
# inlines (children hoist up; no empty level). This is the `displayed =
# !isnothing(doc)` rule: undocumented properties add no labelled noise to the
# tree, documented ones do.
#
# `transient` is consumed here (default true → substatus auto-detaches on finalize);
# it does not reach the property body. Pass transient=false to keep finished substatuses
# pinned to the parent tree (e.g. for historical "N finished" pill display).
function _default_substatus(status::Treebars.ProgressNode, o, name, args...; transient=true, kwargs...)
    # Gate the label PER CALL SIGNATURE: `_is_property_documented` dispatches on
    # `args...` (one method emitted per declaration — `true` if documented,
    # `false` if not), so a property with multiple signatures resolves its OWN
    # doc-presence here — unlike the old `property_doc(metafirst(T, name))`, which
    # keyed on type+name only and always reflected the first declaration. The
    # matching `_property_description` override is likewise per-signature, so the
    # rendered label text is the right signature's docstring. (Structs expanded by
    # an older DO carry no overrides and hit the `_is_property_documented` default,
    # which reproduces that historic first-sig gate — no regression; the per-sig
    # fix rolls in as each struct is re-expanded.)
    desc = _is_property_documented(o, Val(name), args...; kwargs...) ?
        something(_property_description(o, Val(name), args...; kwargs...), "") : ""
    Treebars.initialize_progress!(status; description=desc, transient)
end

# Lifecycle hooks — give DO's ThreadsafeDict-spawned substatuses the with_progress
# init/run/finalize symmetry. Success path calls finalize (which detaches transient
# nodes from the tree); failure path calls fail (which leaves failed nodes pinned
# so they stay visible until retry_failed clears them).
_finalize_substatus!(s::Treebars.ProgressNode) = Treebars.finalize_progress!(s)
_fail_substatus!(s::Treebars.ProgressNode, e) = Treebars.fail_progress!(s, e)

# Disk-load reporting — set the substatus message to a human-readable
# "from disk: <size>" so big-file loads show up in the tree instead of
# stalling silently. Description stays as the property label; message
# is the running annotation Treebars renders alongside.
_report_disk_load!(s::Treebars.ProgressNode, cache_path, size_bytes) =
    Treebars.update_progress!(s, "from disk: " * _format_size(size_bytes))

# Format a byte count as "1.2 MB" / "850 KB" / "42 B" for human-readable
# progress messages.
function _format_size(n::Integer)
    n < 1024            && return "$n B"
    n < 1024^2          && return string(round(n / 1024,        digits=1), " KB")
    n < 1024^3          && return string(round(n / 1024^2,      digits=1), " MB")
    string(round(n / 1024^3, digits=1), " GB")
end

"""
    PropertyCache{D}(cache)

Per-DO-instance memoization cache for `@dynamicstruct` properties. `cache::D` is
the underlying `Dict` (`:serial`) or `ThreadsafeDict` (`:parallel`) holding the
memoized values for non-indexed properties.
"""
struct PropertyCache{D<:AbstractDict{Symbol,Any}}
    cache::D
    PropertyCache(D, c::NamedTuple) = new{D{Symbol,Any}}(D{Symbol,Any}(pairs(c)))
    PropertyCache(c::D) where {D<:AbstractDict{Symbol,Any}} = new{D}(c)
end


# Bare-prop path: forwards `substatus` so the inner `ThreadsafeDict.get!`
# creates a Treebars node + lifecycle just like it does for IPs. Closure
# takes `s` (the substatus the spawn wrapper passes) so the body can
# attach work to it. PropertyCache caches only the one-shot per-name
# IP-wrapper / first-compute result (no kwargs in the cache key);
# kwargs-keyed caching is the IP wrapper's job (`memoize!`).
# `getorcomputeproperty` routes around this layer when indices/kwargs are
# present (see ~L1109), so this overload only needs to handle the
# bare-name case.
Base.get!(f::Function, c::PropertyCache, key; substatus=nothing, kwargs...) =
    get!(f, c.cache, key; substatus)
Base.get!(f::Function, ::PropertyCache, key, indices...; kwargs...) = f(nothing)
Base.setindex!(c::PropertyCache, args...) = setindex!(c.cache, args...)
Base.show(io::IO, pc::PropertyCache) =
    print(io, "PropertyCache(", length(pc.cache), " properties)")

struct IndexableProperty{N,O,D<:AbstractDict}
    o::O
    cache::D
    IndexableProperty(N,o,cache=Dict()) = new{N,typeof(o),typeof(cache)}(o, cache)
end
name(::IndexableProperty{N}) where {N} = N
Base.show(io::IO, ip::IndexableProperty{N}) where {N} = print(io, "IndexableProperty :", N, " (", ip.cache, ")")
# The bare call form memoizes by default (the `4c71ccf` flip), UNLESS the
# property carries the declaration-site `@fresh` marker — `_never_cache`
# (default `false`, emitted `true` per `@fresh` prop) routes it to the uncached
# `fresh` (= `_computeproperty`) instead. `name` is a type param and
# `_never_cache` returns a constant `Bool`, so the branch constant-folds.
(ip::IndexableProperty{name})(indices...; kwargs...) where {name} =
    _never_cache(ip.o, Val(name)) ? fresh(ip, indices...; kwargs...) :
                                    memoize!(ip, indices...; kwargs...)
"""
    memoize!(ip::IndexableProperty, args...; kwargs...)

Cached call into an `IndexableProperty`'s per-key dict. Returns the cached
value if `(args, kwargs)` was seen before; otherwise computes the value
(via `_computeproperty`), stores the result, and returns it.

The bare call form `o.prop(args...; kwargs...)` now routes through `memoize!`
(caching by default), so `memoize!` is the explicit, exported equivalent of a
bare indexed-property call — and the form to use whenever you'd previously have
written `ip[args...]`, *especially* in kwargs-only call sites (`memoize!(ip; k=v)`)
which the legacy bracket syntax couldn't express at all (`ip[; k=v]` doesn't
parse as Julia). For the uncached (fresh) call, use [`fresh`](@ref) / [`@fresh`](@ref).

For two-phase access (returning a [`Pending`](@ref) handle while computing) on
`ThreadsafeDict`-backed IPs, see [`fetchindex`](@ref). Inside a
`@dynamicstruct` body, the convenience macro [`@memo!`](@ref) wraps every
call-site in `maybememoize!(callee, args...; kwargs...)` so cached IPs and
plain functions can share the same syntax.
"""
memoize!(ip::IndexableProperty{name}, args...; fetch=Base.fetch, kwargs...) where {name} = begin
    args_key = (args, (;kwargs...))
    rv = get!(ip.cache, args_key) do
        # Compute via `_computeproperty` directly, NOT the call form `ip(args...)`:
        # the bare call form `o.prop(args)` now routes THROUGH `memoize!` (cached by
        # default), so `ip(args...)` here would recurse into `memoize!` → stack
        # overflow on first use. This mirrors the `ThreadsafeDict`-backed `memoize!`
        # below, which already computes via `_computeproperty` (for the
        # 0-arg-wrapper-trap reason documented there). After this, BOTH `memoize!`
        # methods compute via `_computeproperty`, never via the call form.
        v = _computeproperty(ip.o, name, args...; kwargs...)
        v
    end
    rv
end
"""
    fresh(ip::IndexableProperty, args...; kwargs...)

Uncached call into an `IndexableProperty`: computes the value fresh on every
call, never reading or writing the per-key cache. This is the public, exported
opt-out from the now-default memoized call form — the mirror of [`memoize!`](@ref).

The bare call form `o.prop(args...; kwargs...)` caches by default; use
`fresh(o.prop, args...; kwargs...)` (or the call-site macro [`@fresh`](@ref))
when you specifically need to recompute and bypass the cache entirely (no read,
no store).
"""
fresh(ip::IndexableProperty{name}, args...; kwargs...) where {name} =
    _computeproperty(ip.o, name, args...; kwargs...)
"""
    AbstractThreadsafeDict{K,V}

Supertype for the lock-protected dicts that back `:parallel` indexed properties.
The concrete subtype `ThreadsafeDict` shares the
`(lock, cache, status, computing, errors)` shape so that `getstatus` / `fetchindex` /
`entries` and the `IndexableProperty` `getindex` dispatch generically. In-flight computes
are coordinated by the `computing` condition latch (no retained Task — the value lands in
`cache`/the slot); a failure lands in `errors`.
"""
abstract type AbstractThreadsafeDict{K,V} <: AbstractDict{K,V} end

struct ThreadsafeDict{K,V} <: AbstractThreadsafeDict{K,V}
    lock::ReentrantLock
    cache::Dict{K,V}
    status::Dict{K,Any}
    # In-flight computes. Maps an in-flight key to a `Threads.Condition` bound to `lock`.
    # The first accessor — a blocking caller computing INLINE, or a poller that spawned a
    # fire-and-forget compute — registers here; concurrent accessors see the marker and
    # either `wait` on it (blocking) or return a `Pending` handle (polling) instead of
    # recomputing → compute-at-most-once. Populated only while a compute is mid-flight;
    # the computer removes its entry + `notify`s under `lock`. We deliberately do NOT
    # retain the compute Task: the value lands in `cache`, and a failure lands in
    # `errors` (below), so the Task carries nothing we need (no value, no cancel).
    computing::Dict{K,Threads.Condition}
    # Captured exception for a compute that threw. The value never lands in `cache`, so a
    # waiter / `fetch(::Pending)` reads the failure here and rethrows it, a poll surfaces
    # `:failed`, and `retry_failed` clears it to allow a fresh compute. Replaces the former
    # "leave the failed Task in `tasks` until retry_failed clears it".
    errors::Dict{K,Any}
    ThreadsafeDict{K,V}(c) where {K,V} = new{K,V}(ReentrantLock(), Dict{K,V}(c), Dict{K,Any}(), Dict{K,Threads.Condition}(), Dict{K,Any}())
    ThreadsafeDict() = new{Any,Any}(ReentrantLock(), Dict{Any,Any}(), Dict{Any,Any}(), Dict{Any,Threads.Condition}(), Dict{Any,Any}())
end

# A remounted object needs two cache namespaces under one lock: intrinsic keys
# continue to address the retained object's dictionaries, while rebound keys and
# every property derived from them address request-local dictionaries. Keeping the
# four dictionaries (values/status/computing/errors) routed by the SAME key set is
# what preserves compute-at-most-once/Pending identity for intrinsic work without
# allowing an old request's value, latch, failure, or progress node to leak.
struct MountedDict{K,V,S<:AbstractDict{K,V},L<:AbstractDict{K,V}} <: AbstractDict{K,V}
    shared::S
    overlay::L
    local_names::Set{K}
end

@inline _mounted_dict(d::MountedDict, key) = key in d.local_names ? d.overlay : d.shared
Base.getindex(d::MountedDict, key) = getindex(_mounted_dict(d, key), key)
Base.get(d::MountedDict, key, default) = get(_mounted_dict(d, key), key, default)
Base.haskey(d::MountedDict, key) = haskey(_mounted_dict(d, key), key)
Base.setindex!(d::MountedDict, value, key) = setindex!(_mounted_dict(d, key), value, key)
Base.delete!(d::MountedDict, key) = (delete!(_mounted_dict(d, key), key); d)
Base.pop!(d::MountedDict, key) = pop!(_mounted_dict(d, key), key)
Base.eltype(::Type{<:MountedDict{K,V}}) where {K,V} = Pair{K,V}
Base.length(d::MountedDict) = length(d.overlay) + count(p -> !(first(p) in d.local_names), d.shared)

function _iterate_mounted_shared(d::MountedDict, step)
    while step !== nothing
        pair, state = step
        !(first(pair) in d.local_names) && return pair, (:shared, state)
        step = iterate(d.shared, state)
    end
    nothing
end
function Base.iterate(d::MountedDict)
    step = iterate(d.overlay)
    step === nothing || return step[1], (:local, step[2])
    _iterate_mounted_shared(d, iterate(d.shared))
end
function Base.iterate(d::MountedDict, state)
    phase, inner = state
    if phase === :local
        step = iterate(d.overlay, inner)
        step === nothing || return step[1], (:local, step[2])
        return _iterate_mounted_shared(d, iterate(d.shared))
    end
    _iterate_mounted_shared(d, iterate(d.shared, inner))
end

"""
    MountedThreadsafeDict

Internal `AbstractThreadsafeDict` view used by [`remount`](@ref). Its fields
deliberately match the abstract cache contract (`lock`, `cache`, `status`,
`computing`, `errors`), so the ordinary get/compute/Pending machinery operates
unchanged. Each field is a `MountedDict` over the retained and request-local
dictionaries.
"""
struct MountedThreadsafeDict{S<:ThreadsafeDict{Symbol,Any},O} <: AbstractThreadsafeDict{Symbol,Any}
    lock::ReentrantLock
    cache::MountedDict{Symbol,Any}
    status::MountedDict{Symbol,Any}
    computing::MountedDict{Symbol,Threads.Condition}
    errors::MountedDict{Symbol,Any}
    shared::S
    source::O
    invalidated::Set{Symbol}
    local_names::Set{Symbol}
end

# Private inner-constructor discriminator emitted by `@dynamicstruct`. A public
# call can never collide with it, and ordinary constructors keep their existing
# signature and overrideable-default behavior.
struct _RemountToken end
const _REMOUNT_TOKEN = _RemountToken()

function MountedThreadsafeDict(shared::ThreadsafeDict{Symbol,Any}, source,
                               local_names, invalidated, seed::NamedTuple)
    names = Set{Symbol}(local_names)
    union!(names, keys(seed))
    local_cache = Dict{Symbol,Any}(pairs(seed))
    local_status = Dict{Symbol,Any}()
    local_computing = Dict{Symbol,Threads.Condition}()
    local_errors = Dict{Symbol,Any}()
    MountedThreadsafeDict(
        shared.lock,
        MountedDict(shared.cache, local_cache, names),
        MountedDict(shared.status, local_status, names),
        MountedDict(shared.computing, local_computing, names),
        MountedDict(shared.errors, local_errors, names),
        shared,
        source,
        Set{Symbol}(invalidated),
        names,
    )
end

# `setproperty!` on a mounted object is always a local shadow. Computed stores
# bypass this method and write through `c.cache`, whose static routing set sends
# only proven-invalidated keys local and intrinsic keys to the retained cache.
function Base.setindex!(c::MountedThreadsafeDict, value, key::Symbol)
    lock(c.lock) do
        push!(c.local_names, key)
        c.cache.overlay[key] = value
        delete!(c.status.overlay, key)
        delete!(c.computing.overlay, key)
        delete!(c.errors.overlay, key)
    end
    value
end

Base.empty!(c::MountedThreadsafeDict) = begin
    lock(c.lock) do
        empty!(c.shared.cache); empty!(c.shared.status)
        empty!(c.shared.computing); empty!(c.shared.errors)
        empty!(c.cache.overlay); empty!(c.status.overlay)
        empty!(c.computing.overlay); empty!(c.errors.overlay)
    end
    c
end

Base.show(io::IO, c::MountedThreadsafeDict) = lock(c.lock) do
    print(io, "MountedThreadsafeDict(", length(c.cache), " cached, ",
          length(c.computing), " running; ", length(c.local_names), " local keys)")
end

Base.length(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.cache); end
Base.haskey(c::AbstractThreadsafeDict, key) = lock(c.lock) do; haskey(c.cache, key); end
Base.get(c::AbstractThreadsafeDict, key, default) = lock(c.lock) do; get(c.cache, key, default); end
# NOTE: iteration is NOT truly thread-safe — each iterate call locks independently,
# so the dict can mutate between calls. For thread-safe iteration, use
# lock(c.lock) do ... end or entries(ip) which holds the lock for the full sweep.
Base.iterate(c::AbstractThreadsafeDict) = lock(c.lock) do; iterate(c.cache); end
Base.iterate(c::AbstractThreadsafeDict, state) = lock(c.lock) do; iterate(c.cache, state); end
Base.empty!(c::ThreadsafeDict) = (lock(c.lock) do; empty!(c.cache); empty!(c.status); empty!(c.computing); empty!(c.errors); end; c)
n_running(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.computing); end
Base.show(io::IO, c::ThreadsafeDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeDict{", K, ",", V, "}(", length(c.cache), " cached, ", length(c.computing), " running)")
end
memoize!(ip::IndexableProperty{name,<:Any,<:AbstractThreadsafeDict}, indices...; fetch=Base.fetch, retry_failed=true, kwargs...) where {name} = begin
    (;o, cache) = ip
    substatus_f = if name != :__substatus__ && name != :__status__
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name, indices...; __status__=root, kwargs...)
        end
    else
        nothing
    end
    args_key = (indices, (;kwargs...))
    rv = get!(cache, args_key; fetch, substatus=substatus_f, retry_failed) do s
        # Call `_computeproperty` directly, NOT `getorcomputeproperty`:
        # the latter, when `indices` and `kwargs` are both empty AND
        # `is_indexed_property(o, name)` (we're already inside the IP wrapper,
        # so this is always true), short-circuits to return the IP wrapper
        # itself (see `getorcomputeproperty`'s IP-wrapper branch ~L1156).
        # That would cache the IP wrapper at `((), (;))` instead of running
        # the body — `@memo! o.foo()` on a 0-arg IP would never actually
        # compute anything. `_computeproperty` skips the wrapper short-circuit
        # and goes straight to the body.
        v = _computeproperty(o, name, indices...; __status__=s, kwargs...)
        v
    end
    rv
end
# `substatus()` is invoked OUTSIDE the cache lock. Calling it under the lock is unsafe:
# substatus factories can recurse into other DO properties (e.g. a user-defined
# `_property_description` reads `o.foo`) which re-enter this cache; building `s` under
# `c.lock` would deadlock. So we fast-path first, then build `s` outside the lock and
# re-take it to arbitrate; if we lose the arbitration we discard `s` via finalize.
Base.get!(f::Function, c::AbstractThreadsafeDict, key; fetch=Base.fetch, substatus=nothing, retry_failed=true) = begin
    # Fast path: a ready value returns immediately, no substatus cost. (`_missing_sentinel`
    # distinguishes "absent" from a legitimately-cached `nothing`.)
    hit = lock(c.lock) do
        v = get(c.cache, key, _missing_sentinel)
        v !== _missing_sentinel && (_on_hit!(c, key); return v)
        _missing_sentinel
    end
    hit === _missing_sentinel || return hit
    # Build the substatus OUTSIDE the lock — factories recurse into DO props on the SAME
    # lock, so building under it would deadlock.
    s = isnothing(substatus) ? nothing : substatus()
    sync = fetch === Base.fetch
    action = lock(c.lock) do
        v = get(c.cache, key, _missing_sentinel)
        v !== _missing_sentinel && (_on_hit!(c, key); return (:value, v))
        if haskey(c.errors, key)
            if retry_failed
                delete!(c.errors, key)          # clear the old failure and recompute below
            else
                return (:error, c.errors[key])  # surface the recorded failure
            end
        end
        cnd = get(c.computing, key, nothing)
        if cnd !== nothing
            # A compute is already in flight (inline, or a prior poller's fire-and-forget).
            return sync ? (:wait, cnd) : (:pending, nothing)
        end
        # Nobody computing — WE become the sole computer. Register the latch + (optional)
        # status so concurrent accessors dedup onto us and getstatus/pollers see progress.
        cnd = Threads.Condition(c.lock)
        c.computing[key] = cnd
        !isnothing(s) && (c.status[key] = s)
        return sync ? (:inline, cnd) : (:spawn, cnd)
    end
    kind = action[1]
    kind === :value && (!isnothing(s) && _finalize_substatus!(s); return action[2])
    if kind === :error
        !isnothing(s) && _finalize_substatus!(s)
        throw(action[2])
    end
    if kind === :wait
        # Blocking waiter: block on the in-flight computer's latch, then read value/error.
        # We built `s` but aren't the computer; finalize it (the winner owns the status).
        !isnothing(s) && _finalize_substatus!(s)
        return _await_cache_value!(c, key, action[2]::Threads.Condition, f; fetch, substatus, retry_failed)
    end
    if kind === :pending
        # Poller, compute already in flight elsewhere — hand back a cheap Pending, no spawn.
        !isnothing(s) && _finalize_substatus!(s)
        return fetch(Pending(c, key, nothing))
    end
    if kind === :inline
        # Blocking first-arriver: compute on THIS thread (no spawn), publish, return value.
        return _run_cache_compute!(c, key, action[2]::Threads.Condition, f, s)
    end
    # :spawn — poller first-arriver: kick the REAL compute off fire-and-forget (it writes
    # the cache, or records a failure in `c.errors`), and hand back a Pending. The Task is
    # NOT retained — its value/error both reach us through the cache/errors + the latch.
    cnd = action[2]::Threads.Condition
    Threads.@spawn try; _run_cache_compute!(c, key, cnd, f, s); catch; end  # error already recorded
    return fetch(Pending(c, key, nothing))
end

# Singleton sentinel so a single `get` lookup distinguishes "key absent" from
# "key present with value === nothing" without allowing collision with any
# user-stored value.
struct _Missing end
const _missing_sentinel = _Missing()

# Run a `c.cache`-backed compute to completion under the `cnd` latch. Compute OUTSIDE the
# lock (the RHS recurses into siblings on the same lock), then publish the value + drop the
# latch + notify; on failure record the exception in `c.errors` + drop the latch + notify,
# and rethrow. Used inline (blocking first-arriver) and inside the fire-and-forget spawn
# (poller first-arriver) alike — the value/error both reach every other accessor through
# `cache`/`errors` + the latch, so the compute Task is never retained.
function _run_cache_compute!(c::AbstractThreadsafeDict, key, cnd::Threads.Condition, f, s)
    local v
    try
        v = f(s)
    catch e
        lock(c.lock) do
            get(c.computing, key, nothing) === cnd && delete!(c.computing, key)
            c.errors[key] = e
            notify(cnd)
        end
        !isnothing(s) && _fail_substatus!(s, e)
        rethrow()
    end
    stored = lock(c.lock) do
        existing = get(c.cache, key, _missing_sentinel)
        if existing === _missing_sentinel
            c.cache[key] = v
            _on_store!(c, key)
            existing = v
        else
            _on_hit!(c, key)          # defensive: someone published first
        end
        get(c.computing, key, nothing) === cnd && delete!(c.computing, key)
        notify(cnd)                    # leave c.status[key] finalized — getstatus / "(cached)" relabel rely on it
        existing
    end
    !isnothing(s) && _finalize_substatus!(s)
    stored
end

# Blocking waiter: block on `cnd` until the value lands (return it) or the compute fails
# (rethrow the recorded exception). If the computer vanished with neither (evicted mid
# flight), recompute from scratch OUTSIDE the lock.
function _await_cache_value!(c::AbstractThreadsafeDict, key, cnd::Threads.Condition, f; fetch=Base.fetch, substatus=nothing, retry_failed=true)
    outcome = lock(c.lock) do
        while true
            v = get(c.cache, key, _missing_sentinel)
            v !== _missing_sentinel && (_on_hit!(c, key); return (:value, v))
            haskey(c.errors, key) && return (:error, c.errors[key])
            get(c.computing, key, nothing) === cnd || return (:gone, nothing)
            wait(cnd)
        end
    end
    outcome[1] === :value && return outcome[2]
    outcome[1] === :error && throw(outcome[2])
    return get!(f, c, key; fetch, substatus, retry_failed)   # :gone → recompute
end

"""
    Pending

Cheap, non-`Task` handle a poller (`fetchindex` / `fetchproperty` / `get!(…; fetch=identity)`)
gets back while a value is still being computed. It points at where the value will land — a
`Slot` (bare props) or the backing `(cache, key)` — plus the in-flight latch, so a caller can
`fetch(p)` to BLOCK for the value (rethrowing if the compute failed) or ignore it and poll
again later. Replaces the former "`rv` is a `Task` while in-flight" poll contract: callers
now branch on `rv isa Pending` (still computing) vs. the value (done). The progress/status
node stays optional and is never relied on for readiness.
"""
struct Pending{C<:AbstractThreadsafeDict, K, S}
    cache::C
    key::K
    slot::S   # a `Slot{T}` for slotted bare props; `nothing` for `cache`-backed keys
end

# Non-blocking readiness probe — a `Task`-like surface for callers migrating off `rv isa Task`.
Base.isready(p::Pending) = p.slot === nothing ? haskey(p.cache, p.key) : (@atomic :acquire p.slot.set)

# Block until the value lands (return it) or the compute fails (rethrow). Mirrors
# `fetch(::Task)` so `fetch=Base.fetch` and an explicit `fetch(::Pending)` behave alike.
function Base.fetch(p::Pending)
    c = p.cache
    if p.slot !== nothing
        slot = p.slot
        while !(@atomic :acquire slot.set)
            again = lock(c.lock) do
                (@atomic :acquire slot.set) && return false
                haskey(c.errors, p.key) && throw(c.errors[p.key])
                cnd = get(c.computing, p.key, nothing)
                cnd === nothing && return false
                wait(cnd::Threads.Condition)
                true
            end
            again || break
        end
        (@atomic :acquire slot.set) && return slot.value
        error("Pending: slot ", p.key, " is unset with no compute in flight")
    end
    while true
        step = lock(c.lock) do
            v = get(c.cache, p.key, _missing_sentinel)
            v !== _missing_sentinel && return (:value, v)
            haskey(c.errors, p.key) && return (:error, c.errors[p.key])
            cnd = get(c.computing, p.key, nothing)
            cnd === nothing && return (:gone, nothing)
            wait(cnd::Threads.Condition)
            (:retry, nothing)
        end
        step[1] === :value && return step[2]
        step[1] === :error && throw(step[2])
        step[1] === :gone && error("Pending: key ", p.key, " has no value and no compute in flight")
    end
end

# `_on_hit!` / `_on_store!` are ThreadsafeDict-layer bookkeeping hooks — no-ops.
_on_hit!(::AbstractThreadsafeDict, key) = nothing
_on_store!(::AbstractThreadsafeDict, key) = nothing
_drop_order!(::AbstractThreadsafeDict, key) = nothing

Base.pop!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        haskey(c.status, key) && pop!(c.status, key)
        _drop_order!(c, key)
        pop!(c.cache, key)
    end
end
Base.delete!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        delete!(c.status, key)
        delete!(c.computing, key)
        delete!(c.errors, key)
        _drop_order!(c, key)
        delete!(c.cache, key)
    end
    c
end

"""
    getstatus(ip::IndexableProperty, indices...; kwargs...)

Return the status object associated with an in-flight computation for the given
key, or `nothing` if no status exists (computation not started, already finished,
or no `__substatus__` defined).

Only meaningful for `IndexableProperty` backed by a `ThreadsafeDict`.
"""
getstatus(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}, indices...; kwargs...) = begin
    lock(ip.cache.lock) do
        get(ip.cache.status, (indices, (;kwargs...)), nothing)
    end
end
getstatus(::IndexableProperty, indices...; kwargs...) = nothing

# `cancel!` / `cancel_all!` were removed (2026-07): interrupting a running compute required
# the retained compute Task, which we no longer keep — the value lands in `cache`/the slot
# and failures in `errors`, so the Task carries nothing. There is no cooperative-cancellation
# replacement; cancellation is not a supported operation.

"""
    fetchindex(fetch, ip, indices...; kwargs...)

Call `memoize!(ip, indices...; kwargs...)` with a custom `fetch` function.

For `IndexableProperty` backed by a `ThreadsafeDict`, the `fetch` callback receives
`(rv, status)` where `rv` is a `Pending` handle (still computing) or the computed
result (done), and `status` is the substatus object (from `__substatus__`) or
`nothing`. `fetch(::Pending)` blocks for the value (rethrowing if the compute failed).

Pass `force=true` to unconditionally recompute: clears both the in-memory cache
entry and the on-disk cache file so the next access recomputes from scratch.

# Example
```julia
fetchindex(app.results, key) do rv, status
    if rv isa Pending
        # still computing — status is the progress node
        render_progress(status)
    else
        # done — render result
        render(rv)
    end
end
```
"""
function fetchindex(fetch, ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}, indices...;
                    force=false, retry_failed=force, kwargs...)
    if force
        maybepop!(ip.cache, (indices, (;kwargs...)))
        path = get_cache_path(ip.o, name(ip), indices...; kwargs...)
        isfile(path) && rm(path)
    end
    rv = memoize!(ip, indices...; fetch=identity, retry_failed, kwargs...)
    status = getstatus(ip, indices...; kwargs...)
    fetch(rv, status)
end
# Fallback for non-ThreadsafeDict IPs (1-arg callback, no status)
fetchindex(fetch, ip::IndexableProperty, indices...; kwargs...) = memoize!(ip, indices...; fetch, kwargs...)

"""
    fetchindex!(callback, ip, indices...; fetch=Base.fetch, kwargs...)

In-place variant of [`fetchindex`](@ref). When `callback` is `nothing`, falls
through to a plain `memoize!(ip, indices...; fetch, kwargs...)` — useful for
sites that opt out of the two-phase fetch dance without changing call shape.
"""
fetchindex!(::Nothing, ip, indices...; fetch=Base.fetch, kwargs...) = memoize!(ip, indices...; fetch, kwargs...)

"""
    fetchproperty(fetch, o, name::Symbol)

Like [`fetchindex`](@ref) but for bare (non-indexed) properties. Triggers
computation via the `PropertyCache` and calls `fetch(rv, status)` where `rv`
is a [`Pending`](@ref) handle (the compute is still in flight — `fetch` it to
block for the value) or the already-computed result, and `status` is the
substatus object or `nothing`.

For `Dict`-backed caches (serial), falls through to `getproperty` (synchronous,
no status). The two-phase dance only applies to `ThreadsafeDict`-backed caches.
"""
fetchproperty(fetch, o, name::Symbol) = begin
    if !(hasfield(typeof(o), :cache) && getfield(o, :cache) isa PropertyCache)
        return fetch(getproperty(o, name), nothing)
    end
    if hasfield(typeof(o), name)
        return fetch(getfield(o, name), nothing)
    end
    pc = getfield(o, :cache)
    c = pc.cache
    if !(c isa AbstractThreadsafeDict) || is_indexed_property(o, name)
        return fetch(getproperty(o, name), nothing)
    end
    substatus_f = _bare_substatus_f(o, name)
    rv = get!(c, name; substatus=substatus_f, fetch=identity) do s
        v = _computeproperty(o, name; __status__=s)
        v
    end
    s = lock(c.lock) do; get(c.status, name, nothing); end
    fetch(rv, s)
end

"""
    fetchproperty!(callback, o, name::Symbol)

In-place variant of [`fetchproperty`](@ref). When `callback` is `nothing`,
falls through to `getproperty(o, name)`.
"""
fetchproperty!(::Nothing, o, name::Symbol) = getproperty(o, name)

# ── Treebars-backed `fetch*!` (folded from the former weak-dep TreebarsExt;
# Treebars is now a hard dep, decision w0rn26 → A). The `::Treebars.ProgressNode`
# methods memoize AND mount the inner property's progress subtree under the
# threaded node; `fetch*!(::Nothing, …)` above are the progress-disabled
# degrade paths. ──

# In-memory cache hit rendering (decision 1it9aqq → reworked; supersedes the
# generic "read from memory cache" wrapper).
#
# `fetchindex`/`fetchproperty` follow the contract: the callback's `rv` is a
# `Pending` handle while the computation is in flight, and the VALUE once it is done.
# So at callback entry `!(rv isa Pending)` means the value was already in the
# in-memory cache — a hit. On a DOCUMENTED in-memory hit we KEEP the original
# node `s` and its ENTIRE sub-step subtree intact, and swap ONLY the subtree
# ROOT's LABEL — appending " (cached)" in place — so it renders e.g.
# "Compute subject data (cached) — done (13s)" (carrying `s`'s own frozen
# ORIGINAL-compute duration) with all of `s`'s sub-steps rendering beneath it,
# unchanged.
#
# In-place relabel (vs. a new born-finished root with the children re-homed) is
# the correct mechanism here: `s` is SHARED per cache key (`getstatus` returns
# the same node to every status tree / poll). Re-homing `s`'s children into a new
# node would EMPTY `s.children`, so a second status tree hitting the same shared
# `s` would build a CHILDLESS "(cached)" node — exactly the collapsed-subtree bug
# this corrects. Relabeling `s` itself keeps the one shared subtree intact for all
# trees, preserves children's (immutable) parent pointers, and mirrors
# `_report_disk_load!` above, which already mutates the shared `s`'s display state
# in place.
#
# UNDOCUMENTED hit (`s.impl.description` empty): no relabel — `s` stays a bare
# wrapper the renderer inlines away. Running (`rv isa Pending`) and no-substatus
# (`s === nothing`): no relabel. All four paths then attach `s` via `add_child!`
# (idempotent on the `ThreadsafeSet`; no-op on `nothing`).
const _CACHED_SUFFIX = " (cached)"

function _attach_fetched!(status::Treebars.ProgressNode, rv, s)
    if !(rv isa Pending) && !isnothing(s) && !isempty(s.impl.description)
        _mark_cached!(s)                   # documented in-memory hit → relabel root in place
    end
    Treebars.add_child!(status, s)         # keep/attach the subtree root (no-op on `nothing`)
    nothing
end

# Append the "(cached)" suffix to `s`'s description exactly once. Idempotent under
# repeat polls (web routes poll the tree repeatedly and re-fetch the same shared
# `s`) via the `endswith` guard, and locked on `s.impl.lock` so concurrent first
# hits cannot double-append. `s` is finished/frozen on a hit, so the visible
# duration stays the frozen original-compute time.
function _mark_cached!(s::Treebars.ProgressNode)
    sp = s.impl
    lock(sp.lock) do
        endswith(sp.description, _CACHED_SUFFIX) || (sp.description *= _CACHED_SUFFIX)
    end
    nothing
end

fetchindex!(status::Treebars.ProgressNode, ip, indices...; fetch=Base.fetch, kwargs...) =
    fetchindex(ip, indices...; kwargs...) do rv, s
        _attach_fetched!(status, rv, s)
        fetch(rv)
    end

fetchproperty!(status::Treebars.ProgressNode, o, name::Symbol) =
    fetchproperty(o, name) do rv, s
        _attach_fetched!(status, rv, s)
        Base.fetch(rv)
    end

maybepop!(c::AbstractDict, key) = haskey(c, key) && pop!(c, key)
maybepop!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        maybepop!(c.cache, key)
        maybepop!(c.computing, key)
        maybepop!(c.errors, key)
        maybepop!(c.status, key)
        _drop_order!(c, key)
    end
end

# Subcache factory for indexed-property dicts — the cache is always a
# `ThreadsafeDict`. The owner-aware form lets a mounted wrapper rebuild nested
# child views with the CURRENT parent while ordinary caches retain the historic
# `(ParentType, Val{name})` override seam.
subcache(pc::PropertyCache, owner, v::Val) = subcache(pc, typeof(owner), v)
subcache(pc::PropertyCache, ::Type, ::Val) = subcache(pc)
subcache(::PropertyCache{<:AbstractThreadsafeDict}) = ThreadsafeDict()
function subcache(pc::PropertyCache{<:MountedThreadsafeDict}, owner, ::Val{name}) where {name}
    mounted = pc.cache
    source_ip = getproperty(mounted.source, name)
    source_ip isa IndexableProperty || error(
        "remount: intrinsic indexed property `$name` did not resolve to an IndexableProperty on the retained source")
    if name in mounted.invalidated
        local_cache = ThreadsafeDict()
        if _nested_struct_type(typeof(owner), Val(name)) !== nothing
            # Settled indexed children become mounted child views with the current
            # parent. Their OWN intrinsic caches remain shared; an in-flight child
            # constructor is deliberately not shared because it is still bound to
            # the retained source parent.
            lock(source_ip.cache.lock) do
                for (key, value) in source_ip.cache.cache
                    _is_dynamic_object(value) || continue
                    local_cache.cache[key] = _remount_child(value, owner)
                end
            end
        end
        return local_cache
    end
    source_ip.cache
end

# --- PersistentSet ---

"""
    PersistentSet(path)

A thread-safe `Set` that persists to disk via `Serialization`. Loads existing
data from `path` on construction, or starts empty if the file doesn't exist.
"""
struct PersistentSet{P<:AbstractString,S<:AbstractSet}
    lock::ReentrantLock
    path::P
    data::S
end
PersistentSet(path) = begin
    data = isfile(path) ? Serialization.deserialize(path) : Set()
    PersistentSet(ReentrantLock(), path, data)
end
Base.push!(s::PersistentSet, item) = @lock s.lock begin
    item in s.data && return s
    isfile(s.path) && union!(s.data, Serialization.deserialize(s.path))
    Serialization.serialize(s.path, push!(s.data, item))
    s
end
Base.pop!(s::PersistentSet, item) = @lock s.lock begin
    pop!(s.data, item)
    Serialization.serialize(s.path, s.data)
    s
end
Base.in(item, s::PersistentSet) = @lock s.lock item in s.data
Base.length(s::PersistentSet) = @lock s.lock length(s.data)
Base.collect(s::PersistentSet) = @lock s.lock collect(s.data)
# NOTE: iteration is NOT truly thread-safe — each iterate call locks independently.
Base.iterate(s::PersistentSet) = @lock s.lock iterate(s.data)
Base.iterate(s::PersistentSet, state) = @lock s.lock iterate(s.data, state)
Base.show(io::IO, s::PersistentSet) = print(io, "PersistentSet(", length(s.data), " items, ", s.path, ")")

# --- LazyPersistentDict ---

"""
    LazyPersistentDict{D<:AbstractDict}(path[, empty_data]; seed!)

Threadsafe dict backed by `Serialization.serialize`/`deserialize`. The backing
file path is resolved **lazily** via a callable `path` so the constructor
itself is precompile-safe (no `mkpath`, no file I/O). The on-disk file is
loaded on the first operation (double-checked under the lock), and the
optional `seed!(data)` callback runs once after load if the dict is empty.
Mutations persist to disk synchronously under the lock.

`path` may be an `AbstractString` (fixed path) or a 0-arg function returning
a `String`. Pass an ordered backing dict (e.g. `OrderedDict{K,V}()`) to
preserve insertion order.
"""
mutable struct LazyPersistentDict{D<:AbstractDict}
    path_fn::Function
    data::D
    seed!::Function
    lock::ReentrantLock
    loaded::Bool
end

_no_seed!(_) = nothing

_path_fn(path::AbstractString) = (let p = String(path); () -> p end)
_path_fn(path) = path

function LazyPersistentDict(path, empty_data::D = Dict{Any,Any}();
        seed! = _no_seed!) where {D<:AbstractDict}
    LazyPersistentDict{D}(_path_fn(path), empty_data, seed!, ReentrantLock(), false)
end

# If the deserialized payload's concrete type matches `d.data`'s, swap the
# whole container in (cheaper, preserves identity semantics). Otherwise merge
# entries into the existing one. Kept as a single method with a runtime type
# check: a two-method `(LazyPersistentDict{D}, ::D)` / `(LazyPersistentDict,
# ::Any)` pair is ambiguous when the payload type equals `D` — Julia's
# specificity rule cannot rank a diagonal `where` against a fully generic slot.
function _ingest_loaded!(d::LazyPersistentDict, loaded)
    if loaded isa typeof(d.data)
        d.data = loaded
    else
        merge!(d.data, loaded)
    end
end

function _ensure_loaded!(d::LazyPersistentDict)
    @lock d.lock begin
        d.loaded && return
        p = d.path_fn()
        if isfile(p)
            _ingest_loaded!(d, Serialization.deserialize(p))
        end
        if isempty(d.data)
            d.seed!(d.data)
            if !isempty(d.data)
                _persist_unlocked!(d)
            end
        end
        d.loaded = true
    end
end

function _persist_unlocked!(d::LazyPersistentDict)
    p = d.path_fn()
    mkpath(dirname(p))
    Serialization.serialize(p, d.data)
end

Base.keys(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock collect(keys(d.data)))
Base.values(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock collect(values(d.data)))
Base.pairs(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock collect(pairs(d.data)))
Base.length(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock length(d.data))
Base.isempty(d::LazyPersistentDict) = (_ensure_loaded!(d); @lock d.lock isempty(d.data))
Base.haskey(d::LazyPersistentDict, k) = (_ensure_loaded!(d); @lock d.lock haskey(d.data, k))
Base.getindex(d::LazyPersistentDict, k) = (_ensure_loaded!(d); @lock d.lock d.data[k])
Base.get(d::LazyPersistentDict, k, default) = (_ensure_loaded!(d); @lock d.lock get(d.data, k, default))

function Base.iterate(d::LazyPersistentDict, st=nothing)
    if st === nothing
        _ensure_loaded!(d)
        snap = @lock d.lock collect(pairs(d.data))
        rv = iterate(snap)
        rv === nothing && return nothing
        (pair, idx) = rv
        return (pair, (snap, idx))
    end
    (snap, idx) = st
    rv = iterate(snap, idx)
    rv === nothing && return nothing
    (pair, next_idx) = rv
    (pair, (snap, next_idx))
end
Base.IteratorSize(::Type{<:LazyPersistentDict}) = Base.HasLength()
Base.eltype(::Type{LazyPersistentDict{D}}) where {D<:AbstractDict} = eltype(D)

function Base.setindex!(d::LazyPersistentDict, v, k)
    _ensure_loaded!(d)
    @lock d.lock begin
        d.data[k] = v
        _persist_unlocked!(d)
    end
    v
end

function Base.delete!(d::LazyPersistentDict, k)
    _ensure_loaded!(d)
    @lock d.lock begin
        delete!(d.data, k)
        _persist_unlocked!(d)
    end
    d
end

function Base.get!(f::Function, d::LazyPersistentDict, k)
    _ensure_loaded!(d)
    @lock d.lock begin
        haskey(d.data, k) && return d.data[k]
        rv = f()
        d.data[k] = rv
        _persist_unlocked!(d)
        rv
    end
end

# --- entries / cached_entries for IndexableProperty ---

"""
    entries(ip::IndexableProperty)

Return a vector of `(; key, state, status, value)` for all entries in a
`ThreadsafeDict`-backed `IndexableProperty`. `state` is one of `:running`,
`:failed`, or `:done`. `value` is the cached result (for `:done`), a `Pending`
handle (for `:running`), or the captured exception (for `:failed`). `status` is
the substatus object or `nothing`.
"""
function entries(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict})
    result = NamedTuple{(:key, :state, :status, :value), Tuple{Any, Symbol, Any, Any}}[]
    c = ip.cache
    lock(c.lock) do
        for (k, v) in c.cache
            push!(result, (; key=k, state=:done, status=nothing, value=v))
        end
        for (k, _cnd) in c.computing
            haskey(c.cache, k) && continue
            push!(result, (; key=k, state=:running, status=get(c.status, k, nothing), value=Pending(c, k, nothing)))
        end
        for (k, e) in c.errors
            haskey(c.cache, k) && continue
            push!(result, (; key=k, state=:failed, status=get(c.status, k, nothing), value=e))
        end
    end
    result
end

"""
    cached_entries(ip::IndexableProperty)

Return a vector of `(key, value)` pairs for completed (non-Task) entries only.
"""
function cached_entries(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict})
    lock(ip.cache.lock) do
        collect(ip.cache.cache)
    end
end
function cached_entries(ip::IndexableProperty)
    collect(ip.cache)
end

# --- cache clearing ---

"""
    clear_mem_caches!(obj)

Clear all in-memory memoized property values on a `@dynamicstruct` instance,
leaving disk caches (`@cached` files) untouched. Every derived property —
including child DOs stored as values — will be recomputed on next access.

This is useful after hot-reloading code via Revise: property values computed by
old method definitions stay memoized until the process restarts or this function
is called.
"""
function clear_mem_caches!(obj)
    empty!(getfield(obj, :cache).cache)
    nothing
end

"""
    clear_disk_caches!(obj)

Delete all on-disk cache files for `@cached` properties on a `@dynamicstruct`
instance. In-memory values are left intact (they'll be stale until
`clear_mem_caches!` is also called, or until the process restarts).
"""
function clear_disk_caches!(obj)
    m = meta(typeof(obj))
    cp = obj.__cache_path__
    isdir(cp) || return nothing
    for (name, info) in m
        isfixed(info) && continue
        prefix = string(name)
        for f in readdir(cp)
            is_cache_file = endswith(f, ".sjl") ||
                endswith(f, ".sjl" * _AUTOMATIC_MATERIALIZATION_SUFFIX)
            if is_cache_file &&
                    (f == prefix * ".sjl" ||
                     f == prefix * ".sjl" * _AUTOMATIC_MATERIALIZATION_SUFFIX ||
                     startswith(f, prefix * "_"))
                rm(joinpath(cp, f))
            end
        end
    end
    nothing
end

"""
    clear_all_caches!(obj)

Clear all `@cached` properties on a `@dynamicstruct` instance — both in-memory
and on disk. Equivalent to `clear_mem_caches!` + `clear_disk_caches!`.
"""
function clear_all_caches!(obj)
    clear_mem_caches!(obj)
    clear_disk_caches!(obj)
end

# --- KeyTracker: pluggable strategy for accessed-keys persistence ---

"""
    KeyTracker

Abstract type for pluggable accessed-keys persistence strategies. Implement
`record!(tracker, key)` and `load_keys(tracker)` for custom strategies.

Override `key_tracker(o, ::Val{name})` on your object type to select a strategy.
"""
abstract type KeyTracker end

"""
    SharedFileTracker(path)

Default strategy: all pods/processes share a single `_keys.sjl` file.
Simple, but not safe for concurrent multi-process writes to NFS.
"""
struct SharedFileTracker <: KeyTracker
    path::String
end

"""
    NoKeyTracker()

No-op strategy: never records or loads keys. Use when tracking is unwanted.
"""
struct NoKeyTracker <: KeyTracker end

# Per-path lock registry serializing `_record_key_to_path`'s read-modify-write.
# Without it, concurrent first-access to different keys of the same accessed-key
# file (the shared `_keys.sjl` behind `SharedFileTracker`) interleaves
# deserialize→push!→serialize and silently loses key-set updates. A non-const
# module global (not a struct field — `SharedFileTracker`'s shape can't change
# under Revise on 1.10) keyed by path: same file serializes, distinct files
# don't contend beyond the brief registry lookup.
_key_tracker_locks = DiskCacheLocks()
function _record_key_to_path(path, key)
    mkpath(dirname(path))
    lock(get_path_lock!(_key_tracker_locks, path)) do
        existing = isfile(path) ? Serialization.deserialize(path) : Set()
        key in existing && return
        push!(existing, key)
        Serialization.serialize(path, existing)
    end
    nothing
end

"""
    record!(tracker::KeyTracker, key)

Record that `key` was accessed, persisting according to the tracker's strategy.
"""
record!(tracker::SharedFileTracker, key) = _record_key_to_path(tracker.path, key)
record!(tracker::NoKeyTracker, key)      = nothing

"""
    load_keys(tracker::KeyTracker) -> Set

Load the full set of recorded keys according to the tracker's strategy.
"""
load_keys(tracker::SharedFileTracker) =
    isfile(tracker.path) ? Serialization.deserialize(tracker.path) : Set()
load_keys(tracker::NoKeyTracker) = Set()

"""
    key_tracker(o, ::Val{name}) -> KeyTracker

Return the `KeyTracker` to use for property `name` on object `o`.
Override this method on your type to change the tracking strategy.

```julia
# Example: disable accessed-key tracking for all properties on MyType
DynamicObjects.key_tracker(o::MyType, ::Val{name}) where {name} =
    DynamicObjects.NoKeyTracker()
```
"""
key_tracker(o, ::Val{name}) where {name} =
    SharedFileTracker(joinpath(o.__cache_path__, string(name) * "_keys.sjl"))

# --- Accessed-keys tracking for IndexableProperty ---

"""
    accessed_keys(ip::IndexableProperty)

Return the set of keys that have been accessed for this IndexableProperty,
loaded from disk. Returns an empty `Set` if no keys have been recorded.
"""
function accessed_keys(ip::IndexableProperty{name}) where {name}
    load_keys(key_tracker(ip.o, Val(name)))
end

"""
    record_access!(ip::IndexableProperty, key)

Record that `key` was accessed for this IndexableProperty, persisting to disk.
"""
function record_access!(ip::IndexableProperty{name}, key) where {name}
    record!(key_tracker(ip.o, Val(name)), key)
end

# Internal: record accessed key from getorcomputeproperty context
# Disabled: key tracking files are not concurrency-safe and cause EOFError crashes
function _record_accessed_key(o, name::Symbol, indices, kwargs)
    # record!(key_tracker(o, Val(name)), (indices, (;kwargs...)))
    nothing
end

_computeproperty(o, name, indices...; __status__=nothing, kwargs...) = begin
    vname = Val(name)
    isnothing(__status__) && name != :__status__ && (__status__ = getorcomputeproperty(o, :__status__))
    _status_kw = is_generated_property(o, name) ? (; __status__) : (;)
    try
        if iscached(o, vname, indices...; kwargs...) && !_remount_invalidated(o, name)
            cache_path = get_cache_path(o, name, indices...; kwargs...)
            mkpath(dirname(cache_path))
            _prune_stale_versions!(o)   # @versioned "hold only the most recent" (no-op for non-versioned types)
            __strict__ = getorcomputeproperty(o, :__strict__)
            _cache_context = """Object type: $(nameof(typeof(o))) (objectid: $(objectid(o)), hash: $(hash(o)))
Cache dict: ThreadsafeDict (parallel)
If multiple objects with the same hash are writing here concurrently, this may indicate a concurrency issue or a hashing collision."""
            # A failed cache READ must not reuse `_cache_context`: its
            # concurrency/hash-collision hypothesis is apt for the trylock warning it
            # was written for, but a read failure is far more often a partial or
            # stale file (the disk filled mid-write, a writer was interrupted, the
            # format changed). Asserting the wrong cause sends an operator hunting
            # for hash collisions during a disk-full. Name the file; let the
            # exception state the cause.
            _load_fail_context = """Object type: $(nameof(typeof(o))) (objectid: $(objectid(o)), hash: $(hash(o)))
Cache file: $cache_path ($(isfile(cache_path) ? string(filesize(cache_path), " bytes") : "missing"))
A truncated/partial file usually means the disk filled or a writer was interrupted. The file is deleted and the value recomputed."""
            disk_locks = _disk_cache(o, vname)
            rv = if __strict__ && !isnothing(disk_locks)
                path_lock = get_path_lock!(disk_locks, cache_path)
                # Concurrent access to the same cache file means N distinct but
                # content-equal instances of this type are racing the same disk
                # file instead of being interned to one shared instance. In-memory
                # memoization is per-instance and cannot dedup content-equal copies;
                # it is also defeated when the memo key (call args) is finer-grained
                # than the disk key (content hash) under an input-normalizing
                # constructor. `trylock` atomically rejects the second-caller race
                # (the prior `islocked` + `lock(...) do` pair was racy). On a race we
                # now WARN and block-and-read: this was a hard error under decision
                # 1hz5p6b, but the user reversed that 2026-07-01 (no longer wanted as
                # an error — still logged). After the warning we `lock(path_lock)`, so
                # the try/finally below always runs holding the lock: the racing caller
                # waits for the writer, then reads the now-ready cache (or recomputes if
                # the writer failed to save). The warning still surfaces the interning
                # gap (N content-equal instances not interned to one).
                if !trylock(path_lock)
                    @warn("""Concurrent access to disk cache $cache_path — \
                          N distinct but content-equal instances of \
                          $(nameof(typeof(o))) are racing this cache file instead \
                          of being interned to one. In-memory memoization is \
                          per-instance and cannot dedup content-equal copies; \
                          intern the object at its construction site so the value \
                          is computed once. A common subtle cause: the memo key \
                          (call args) is finer-grained than the disk key (content \
                          hash) because the constructor normalizes its inputs, so \
                          two arg-sets collapse to one cache file but stay two \
                          un-shared instances.
$_cache_context""")
                    lock(path_lock)
                end
                try
                    cache_status = get_cache_status(cache_path)
                    rv = if cache_status == :ready
                        _report_disk_load!(__status__, cache_path, filesize(cache_path))
                        try
                            load(_disk_format(o, vname), cache_path, _disk_eltype(o, vname))
                        catch e
                            # isa(e, ArgumentError) && rethrow()
                            @warn "Cache read failed for $cache_path — deleting it and recomputing.\n$_load_fail_context" exception=e
                            rm(cache_path; force=true)
                            nothing
                        end
                    else
                        cache_status == :started && @warn "Cache file $cache_path exists but has size 0 — assuming an interrupted write (e.g. the disk filled). Recomputing.\n$_load_fail_context"
                        nothing
                    end
                    if isnothing(rv) || resumes(o, vname, indices...; kwargs...)
                        @debug "Generating $cache_path...\n$_cache_context"
                        rv = compute_property(o, vname, indices...; _status_kw..., _resume_kw(o, vname, rv)..., kwargs...)
                        _atomic_save(_disk_format(o, vname), cache_path, rv)
                        if _disk_format(o, vname) == Val(:mmap)
                            rv = load(Val(:mmap), cache_path, _disk_eltype(o, vname))
                        end
                    end
                    rv
                finally
                    unlock(path_lock)
                end
            else
                # Non-strict or no disk locks: original flow
                cache_status = get_cache_status(cache_path)
                rv = if cache_status == :ready
                    _report_disk_load!(__status__, cache_path, filesize(cache_path))
                    try
                        load(_disk_format(o, vname), cache_path, _disk_eltype(o, vname))
                    catch e
                        @warn "Cache read failed for $cache_path — deleting it and recomputing.\n$_load_fail_context" exception=e
                        rm(cache_path; force=true)
                        cache_status = :unstarted
                        touch(cache_path)
                        nothing
                    end
                else
                    if cache_status == :started
                        @warn "Cache file $cache_path exists but has size 0.\nAssuming a previous run failed.\n$_cache_context\nEnable __strict__=true for disk cache locking to prevent concurrent write issues."
                    end
                    touch(cache_path)
                    nothing
                end
                if cache_status != :ready || resumes(o, vname, indices...; kwargs...)
                    @debug "Generating $cache_path...\n$_cache_context"
                    rv = compute_property(o, vname, indices...; _status_kw..., _resume_kw(o, vname, rv)..., kwargs...)
                    _atomic_save(_disk_format(o, vname), cache_path, rv)
                    if _disk_format(o, vname) == Val(:mmap)
                        rv = load(Val(:mmap), cache_path, _disk_eltype(o, vname))
                    end
                end
                rv
            end
            # Record accessed key for indexed @cached properties
            if !isempty(indices)
                _record_accessed_key(o, name, indices, kwargs)
            end
            rv
        else
            compute_property(o, vname, indices...; _status_kw..., kwargs...)
        end
    catch e
        kw_tuple = isempty(kwargs) ? () : Tuple(pairs(kwargs))
        bt = catch_backtrace()
        throw(PropertyComputationError(
            string(typeof(o).name.name),
            name,
            indices,
            kw_tuple,
            (e, bt),
        ))
    end
end
# Fast, closure-free cache peek for the bare-property hit path in
# `getorcomputeproperty`. Returns the cached value, or `_missing_sentinel` on a
# miss. Uses explicit lock/unlock (not `lock() do`) to keep the hot hit path
# allocation-free; mirrors the fast-path read in `get!(::AbstractThreadsafeDict)`.
_peek_hit(pc::PropertyCache, name::Symbol) = _peek_hit(getfield(pc, :cache), name)
function _peek_hit(c::AbstractThreadsafeDict, name::Symbol)
    lock(c.lock)
    try
        return get(c.cache, name, _missing_sentinel)
    finally
        unlock(c.lock)
    end
end
_peek_hit(c::AbstractDict, name::Symbol) = get(c, name, _missing_sentinel)

getorcomputeproperty(o, name, indices...; kwargs...) = if hasfield(typeof(o), name)
    @assert length(indices) == length(kwargs) == 0
    getfield(o, name)
elseif !isempty(indices) || !isempty(kwargs)
    # Non-empty indices/kwargs path: bypass the PropertyCache layer entirely.
    # PropertyCache keys only on `name` (it's meant to cache one-shot
    # IP-wrapper construction per property — see the IP-wrapper return
    # branch below). Forwarding `(indices, kwargs)` through `get!(::PropertyCache, …)`
    # is unsound: the cache would collide across different (indices, kwargs)
    # tuples, and the inner `Base.get!(::AbstractThreadsafeDict, …)` rejects
    # arbitrary kwargs with MethodError. The IP-wrapper / `memoize!` machinery
    # owns kwargs-keyed caching for indexed properties; we just hand off.
    _computeproperty(o, name, indices...; __status__, kwargs...)
else
    cache = getfield(o, :cache)
    # Fast hit path: a cached bare property returns WITHOUT building the
    # `substatus` factory or the `get!` do-block closure below — both allocate
    # on every access and were the dominant warm-access cost. Hit bookkeeping is
    # a no-op (`_on_hit!`), so returning the cached value
    # directly is behaviourally identical to routing through `get!`. Only misses
    # pay the closures.
    hit = _peek_hit(cache, name)
    hit === _missing_sentinel || return hit
    substatus_f = _bare_substatus_f(o, name)
    get!(cache, name; substatus=substatus_f) do s
        # When called with no indices on an indexed property (declared with
        # call/ref syntax, e.g. `x() = ...` or `x[i] = ...`), return an
        # IndexableProperty wrapper instead of calling compute_property.
        if is_indexed_property(o, name)
            return IndexableProperty(name, o, subcache(cache, o, Val(name)))
        end
        # `s` is the substatus the spawn wrapper passed (or `nothing` when
        # `substatus_f` was nothing). Pass it as `__status__` so the body
        # — and any IP/property accesses inside — attach to it.
        _computeproperty(o, name; __status__=s)
    end
end
_bare_substatus_f(o, name) =
    if name != :__substatus__ && name != :__status__ &&
       !(startswith(string(name), "__") && endswith(string(name), "__")) &&
       is_generated_property(o, name) && !is_indexed_property(o, name)
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name; __status__=root)
        end
    else
        nothing
    end

maybehash(x::Number) = x
maybehash(x::Symbol) = x
maybehash(x) = persistent_hash(x)

# POSIX per-path-component byte limit. A single file or directory name longer
# than this fails with ENAMETOOLONG on `mkpath`/`open`, no matter how short
# the total path is.
const NAME_MAX = 255
# Cap for `cache_segment` output. Kept below `NAME_MAX` so the suffixes that
# `get_cache_path` appends afterwards (`_v<version>` and `.sjl`) still leave
# the final filename within the per-component limit.
const _CACHE_SEGMENT_MAX = NAME_MAX - 55

# Truncate `s` to at most `maxbytes` UTF-8 code units, never splitting a char.
_truncate_codeunits(s::AbstractString, maxbytes::Integer) = begin
    n = 0
    io = IOBuffer()
    for c in s
        w = ncodeunits(c)
        n + w > maxbytes && break
        n += w
        print(io, c)
    end
    String(take!(io))
end

# Keep a path segment within `_CACHE_SEGMENT_MAX`. Short segments pass through
# unchanged so the on-disk layout stays human-readable; an overlong one (e.g. a
# fat IndexableProperty key over many args) is replaced by a readable prefix
# plus a SHA1 digest of the *full* segment — bounded, navigable, collision-free.
_bound_segment(seg::AbstractString) = begin
    ncodeunits(seg) <= _CACHE_SEGMENT_MAX && return String(seg)
    digest = persistent_hash(seg)
    head = _truncate_codeunits(seg, _CACHE_SEGMENT_MAX - ncodeunits(digest) - 1)
    head * "_" * digest
end

# Build a single path-segment identifier for a (name, args, kwargs) triple,
# joining the parts with "_" via `maybehash`. Used in two places:
#   1. As the file-name body of `get_cache_path` (with ".sjl" appended).
#   2. As the per-level directory name in the inline-child cache_path
#      auto-wiring, so the on-disk layout mirrors the DO hierarchy.
# Kwargs are sorted by name so callers passing the same kwargs in different
# syntactic order land in the same segment. The joined result is passed through
# `_bound_segment` so a fat key cannot blow past the filesystem's NAME_MAX.
cache_segment(name, args...; kwargs...) = begin
    parts = length(kwargs) == 0 ? (name, args...) : (name, args..., sort(collect(kwargs); by=first)...)
    _bound_segment(join(map(maybehash, parts), "_"))
end
get_cache_path(o, name, args...; kwargs...) = begin
    seg = cache_segment(name, args...; kwargs...)
    ver = cache_version(o, Val(name))
    !isnothing(ver) && (seg = seg * "_v" * string(ver))
    joinpath(o.__cache_path__, seg * ".sjl")
end
get_cache_status(o, args...; kwargs...) = get_cache_status(get_cache_path(o, args...; kwargs...)) 
get_cache_status(cache_path::AbstractString) = begin
    !isfile(cache_path) && return :unstarted
    filesize(cache_path) == 0 && return :started
    return :ready
end
cache_f_expr(x; f) = begin
    x, indices = if Meta.isexpr(x, (:ref, :call))
        x.args[1], x.args[2:end]
    else
        x, []
    end
    if Meta.isexpr(x, :$)
        # Interpolated property name: @is_cached $prop[indices...]
        name_expr = x.args[1]
        :($f(__self__, $name_expr, $(indices...))) |> fixcall
    else
        @assert Meta.isexpr(x, :.)
        o, name = x.args
        :($f($o, $(name), $(indices...))) |> fixcall
    end
end
"""
    @cache_status o.prop
    @cache_status o.prop(indices...)

Return the disk-cache status of a `@cached` property as a `Symbol`:
- `:unstarted` — no cache file exists yet.
- `:started`   — an empty placeholder file exists (previous run may have crashed).
- `:ready`     — a complete cache file exists and can be deserialized.

Can be used both outside and inside a `@dynamicstruct` body. Inside a struct
definition, omit the object prefix — just use the property name (with parens
for indexed properties).

```julia
# Outside the struct:
@cache_status e.result          # :unstarted (before first access)
e.result
@cache_status e.result          # :ready
@cache_status e.ci(2)           # for indexed properties — call syntax

# Inside the struct body:
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    status(key) = @cache_status result(key)   # :unstarted, :started, or :ready
end
```

The legacy bracket form (`@cache_status o.prop[indices...]`) still works for
backward compatibility but is discouraged in new code — prefer call syntax,
which mirrors the way the property is invoked.
"""
macro cache_status(x)
    cache_f_expr(x; f=get_cache_status) |> esc
end

"""
    @is_cached o.prop
    @is_cached o.prop(indices...)

Return `true` if the disk cache for `o.prop` (or `o.prop(indices...)`) is
`:ready`, i.e. the cached value can be loaded from disk without recomputation.

Can be used both outside and inside a `@dynamicstruct` body. Inside a struct
definition, omit the object prefix — just use the property name (with parens
for indexed properties).

```julia
# Outside the struct:
@is_cached e.result   # false before first access, true afterwards

# Inside the struct body:
@dynamicstruct struct App
    @cached result(key) = expensive(key)
    summary(key) = if @is_cached result(key)
        "cached: \$(@memo! result(key))"
    else
        "not yet computed"
    end
end
```

The legacy bracket form (`@is_cached o.prop[indices...]`) still works for
backward compatibility but is discouraged in new code.
"""
macro is_cached(x)
    :($(cache_f_expr(x; f=get_cache_status)) == :ready) |> esc
end

"""
    @cache_path o.prop
    @cache_path o.prop(indices...)

Return the file path where the disk-cached value of `o.prop` (or
`o.prop(indices...)`) is (or would be) stored.

```julia
@cache_path e.result          # e.g. "cache/<hash>/result.sjl"
@cache_path e.ci(2)           # "cache/<hash>/ci_2.sjl"
```

The legacy bracket form is still accepted but discouraged.
"""
macro cache_path(x)
    cache_f_expr(x; f=get_cache_path) |> esc
end
"""
    @persist o.prop
    @persist o.prop(indices...)

Write the in-memory value of `o.prop` (or the indexed entry `o.prop(indices...)`)
back to its disk cache. Use after mutating a value in place when the property
was declared with `@cached` and the on-disk copy is now stale relative to the
in-memory copy.

The legacy bracket form (`@persist o.prop[indices...]`) still works but is
discouraged in new code — prefer call syntax.
"""
macro persist(x)
    x, indices = if Meta.isexpr(x, (:ref, :call))
        x.args[1], x.args[2:end]
    else
        x, []
    end
    @assert Meta.isexpr(x, :.)
    o, name = x.args
    :($persist($x, $o, $(name), $(indices...))) |> fixcall |> esc
end

"""
    maybememoize!(f, args...; kwargs...)

Dispatch helper used by `@memo!`. The default just calls `f(args...; kwargs...)`,
so non-IP callees (functions, types, callable structs) behave like normal
calls. The specialization for `IndexableProperty` routes through
[`memoize!`](@ref), hitting the in-memory cache.
"""
maybememoize!(f, args...; kwargs...) = f(args...; kwargs...)
maybememoize!(p::IndexableProperty, args...; kwargs...) = memoize!(p, args...; kwargs...)
# `maybememoize!(::typeof(maybeprogress!), …)` stacking arms live below
# `maybeprogress!`'s definition — they reference `typeof(maybeprogress!)`,
# which has to exist at parse time.

"""
    maybefresh(f, args...; kwargs...)

Dispatch helper used by [`@fresh`](@ref). The default just calls
`f(args...; kwargs...)`, so non-IP callees (functions, types, callable structs)
behave like normal calls. The specialization for `IndexableProperty` routes
through [`fresh`](@ref) — the uncached call — so the indexed property is
recomputed and the cache is bypassed. The dual of [`maybememoize!`](@ref).
"""
maybefresh(f, args...; kwargs...) = f(args...; kwargs...)
maybefresh(p::IndexableProperty, args...; kwargs...) = fresh(p, args...; kwargs...)

"""
    @memo! expr

Rewrite every call inside `expr` as `maybememoize!(callee, args…)`. At
runtime `maybememoize!` dispatches: `IndexableProperty` callees go through
[`memoize!`](@ref) (cached); everything else just calls normally.

The bare call form `o.prop(i)` now caches by default, so `@memo!` is the
explicit, reader-visible equivalent of a bare indexed-property call — and is
still useful for making the caching intent obvious or for one-shot cached calls
outside a `@dynamicstruct` body (where you can also call `memoize!` directly).
To opt OUT and recompute fresh, use [`@fresh`](@ref) / [`fresh`](@ref).

Inside a `@dynamicstruct`, an indexable property `prop(i) = ...` can be
invoked these ways:

- `o.prop(i)` — caches by default (look up in the in-memory cache, compute and cache on miss).
- `@memo! o.prop(i)` — identical to the bare call, but makes the caching explicit at the call site.
- `@fresh o.prop(i)` — recompute on every call, bypassing the cache entirely.

```julia
@memo! o.prop(i)                          # cached access
@memo! o.prop(i; k=v)                     # kwargs participate in the cache key

# Chained IP calls all get memoized; intermediate non-IP calls (e.g.
# top-level helpers) just call normally:
@memo! qt.loaded(dataset; data_version).filtered(; src).eda.counts
@memo! sort(x.prop(i))
```

The bang on `@memo!` / `memoize!` / `maybememoize!` reflects that each
mutates the per-key in-memory cache. There is no bracket access on
`IndexableProperty` — `ip[args...]` and `ip[; kw...]` are unsupported
(the latter never parsed in the first place); use the function forms.
"""
macro memo!(x)
    esc(_call_rewrite(x, :maybememoize!))
end

"""
    @fresh expr

Rewrite every call inside `expr` as `maybefresh(callee, args…)` — the dual of
[`@memo!`](@ref). At runtime `maybefresh` dispatches: `IndexableProperty`
callees go through [`fresh`](@ref) (uncached, recomputed); everything else just
calls normally.

`@fresh` is the call-site opt-out from the now-default memoized call form: the
bare call `o.prop(i)` caches, and `@fresh o.prop(i)` recomputes fresh and
bypasses the cache (no read, no store). For a one-shot fresh call outside a
`@dynamicstruct` body, call [`fresh`](@ref) directly.

```julia
@fresh o.prop(i)                          # uncached access
@fresh o.prop(i; k=v)                     # kwargs forwarded, not cached
@fresh sort(x.prop(i))                    # the IP call is fresh; `sort` just calls
```
"""
macro fresh(x)
    esc(_call_rewrite(x, :maybefresh))
end

# Recursively rewrite every call site to `\$target(...)` (`maybememoize!` for
# `@memo!`, `maybefresh` for `@fresh`). Plain property accesses (`.foo`,
# `.bar.baz`) are left untouched — only `:call` heads are transformed. The
# `target` helper's dispatch decides at runtime whether to act on an IP or just
# call (everything else).
_call_rewrite(x, target::Symbol) = x
function _call_rewrite(x::Expr, target::Symbol)
    if Meta.isexpr(x, :do) && length(x.args) == 2 && Meta.isexpr(x.args[1], :call)
        call = x.args[1]
        lambda = _call_rewrite(x.args[2], target)
        rewritten = Any[_call_rewrite(a, target) for a in call.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, target), rewritten[1], lambda, rewritten[2:end]...))
    end
    if Meta.isexpr(x, :call) && length(x.args) >= 1
        rewritten = Any[_call_rewrite(a, target) for a in x.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, target), rewritten...))
    end
    Expr(x.head, Any[_call_rewrite(a, target) for a in x.args]...)
end

"""
    maybefetchindex!(progress, f, args...; kwargs...)

Dispatch helper used by `@fetch!` for call sites. The default just calls
`f(args...; kwargs...)`; the specialization for `IndexableProperty` routes
through [`fetchindex!`](@ref) (memoized + progress-tree attachment).
"""
maybefetchindex!(progress, f, args...; kwargs...) = f(args...; kwargs...)
maybefetchindex!(progress, p::IndexableProperty, args...; kwargs...) = fetchindex!(progress, p, args...; kwargs...)

"""
    maybefetchproperty!(progress, o, name::Symbol)

Dispatch helper used by `@fetch!` for property accesses. For `@dynamicstruct`
instances, routes through [`fetchproperty!`](@ref) (cached + progress-tree
attachment). For indexed properties (IPs) and non-DO objects, falls through
to `getproperty(o, name)`.
"""
maybefetchproperty!(progress, o, name::Symbol) =
    hasfield(typeof(o), :cache) && getfield(o, :cache) isa PropertyCache ?
        fetchproperty!(progress, o, name) :
        getproperty(o, name)

"""
    @fetch! progress expr

Like [`@memo!`](@ref) but also attaches progress. Rewrites every call site
to `maybefetchindex!(progress, callee, args…)` and every property access
to `maybefetchproperty!(progress, obj, :name)`.

`progress` is required — pass the progress/status variable explicitly
(typically `__progress__`, the variable bound by `Treebars.@progress`
blocks and `@dynamic_progress`). A one-argument form is intentionally not
provided: under Julia's outside-in macro expansion, `@progress` renames
`__progress__` before `@fetch!` expands, so a `@fetch!`-introduced
`__progress__` would dangle into an `UndefVarError` at runtime.

```julia
@fetch! __progress__ begin
    data = loaded(dataset; data_version)   # IP → fetchindex!
    result = data.dense_chains             # bare prop → fetchproperty!
end

@fetch! custom_progress begin
    data = loaded(dataset; data_version)
end
```
"""
macro fetch!(progress_var, x)
    esc(_fetch_rewrite(progress_var, x))
end

_fetch_rewrite(pv::Symbol, x) = x
function _fetch_rewrite(pv::Symbol, x::Expr)
    if Meta.isexpr(x, :do) && length(x.args) == 2 && Meta.isexpr(x.args[1], :call)
        call = x.args[1]
        lambda = _fetch_rewrite(pv, x.args[2])
        rewritten = Any[_fetch_rewrite(pv, a) for a in call.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybefetchindex!), pv, rewritten[1], lambda, rewritten[2:end]...))
    end
    if Meta.isexpr(x, :call) && length(x.args) >= 1
        rewritten = Any[_fetch_rewrite(pv, a) for a in x.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybefetchindex!), pv, rewritten...))
    end
    if Meta.isexpr(x, :parameters)
        # Keyword block of a fetched call (or named tuple). A keyword position
        # cannot hold a bare call, so each element must be rewritten while
        # staying valid keyword syntax — see `_fetch_rewrite_kwarg`. Routing
        # the whole `:parameters` node through the generic walker below would
        # turn a dotted shorthand `; obj.field` into a bare
        # `maybefetchproperty!(…)` call and emit `invalid keyword argument
        # syntax`.
        return Expr(:parameters, Any[_fetch_rewrite_kwarg(pv, a) for a in x.args]...)
    end
    if Meta.isexpr(x, :.) && length(x.args) == 2 && x.args[2] isa QuoteNode
        obj = _fetch_rewrite(pv, x.args[1])
        name = x.args[2].value
        return Expr(:call, GlobalRef(@__MODULE__, :maybefetchproperty!), pv, obj, QuoteNode(name))
    end
    # Named-destructure assignment `(;a, b, c) = <source>` (incl. the
    # trailing-comma `(;a, b, c,)` form — identical AST — and `::T`-typed
    # names): rewrite each forwarded name to a `maybefetchproperty!` access so
    # the forwarded properties thread progress + cache, exactly as an explicit
    # `<source>.name` access already does. This is the shape DO's inline-child
    # desugar emits as `(;forwarded...) = __parent__`; matching it here lets a
    # `@fetch!` body thread through auto-forwarded parent properties. General
    # over any source: for a non-DO source `maybefetchproperty!` degrades to
    # `getproperty`, so the rewrite stays semantically identical to the plain
    # destructure off-DO and only adds threading on a DO source. The source is
    # bound once (no double-eval) and returned, so the block keeps the
    # assignment's value (a destructure evaluates to its RHS). A `:block` does
    # not introduce scope, so the destructured names leak to the enclosing
    # scope exactly like the original destructure.
    if Meta.isexpr(x, :(=)) && Meta.isexpr(x.args[1], :tuple) &&
       length(x.args[1].args) == 1 && Meta.isexpr(x.args[1].args[1], :parameters)
        binds = _fetch_destructure_binds(x.args[1].args[1])
        if binds !== nothing
            src = gensym(:fetch_src)
            block = Expr(:block, :($src = $(_fetch_rewrite(pv, x.args[2]))))
            for (lhs, nm) in binds
                push!(block.args, :($lhs = $(Expr(:call,
                    GlobalRef(@__MODULE__, :maybefetchproperty!), pv, src, QuoteNode(nm)))))
            end
            push!(block.args, src)
            return block
        end
        # Unsupported element shape (kw-default `(;a=1)`, splat `(;xs...)`,
        # nested) — fall through to the generic recursion, which passes the
        # destructure through unchanged (today's no-threading behaviour).
    end
    Expr(x.head, Any[_fetch_rewrite(pv, a) for a in x.args]...)
end

# Extract `(binding_lhs, name_symbol)` for each element of a `(;…)` destructure's
# `:parameters` block. Each element must be a bare `Symbol` (`a`) or a `::T`-typed
# name (`Expr(:(::), sym, T)`); for the typed case the binding keeps the `n::T`
# lhs while the fetched name is the bare `n`. Any other shape (kw-default, splat,
# nested) returns `nothing` so the caller bails to the generic passthrough.
function _fetch_destructure_binds(params::Expr)
    binds = Tuple{Any,Symbol}[]
    for a in params.args
        if a isa Symbol
            push!(binds, (a, a))
        elseif Meta.isexpr(a, :(::)) && length(a.args) == 2 && a.args[1] isa Symbol
            push!(binds, (a, a.args[1]))
        else
            return nothing
        end
    end
    return binds
end

# Rewrite one element of a `:parameters` (keyword) block, keeping it valid
# keyword syntax. The only element shape that needs special care is dotted
# shorthand `; obj.field`: `walk_rhs` produces it from `; field` when `field`
# is a sibling property, and the generic `_fetch_rewrite` would turn the `:.`
# into a bare `maybefetchproperty!(…)` call — which Julia rejects in keyword
# position. Wrap it back into an explicit `field = <rewritten obj.field>`.
# Every other shape (`:kw` whose value is rewritten in place, bare-Symbol
# shorthand `; k`, splat `; xs...`, nested `:call`) is already valid under the
# generic recursion.
_fetch_rewrite_kwarg(pv::Symbol, a) = _fetch_rewrite(pv, a)
function _fetch_rewrite_kwarg(pv::Symbol, a::Expr)
    if Meta.isexpr(a, :.) && length(a.args) == 2 && a.args[2] isa QuoteNode
        return Expr(:kw, a.args[2].value, _fetch_rewrite(pv, a))
    end
    return _fetch_rewrite(pv, a)
end

# True iff `x` is a direct self-property / self-IP access `__self__.name` — the
# shape `walk_rhs` rewrites a bare sibling reference into.
_is_self_access(x) = Meta.isexpr(x, :.) && length(x.args) == 2 &&
    x.args[1] === :__self__ && x.args[2] isa QuoteNode

# `@progress` property-marker self-access rewrite (decision w0rn26 → A).
#
# A focused post-`walk_rhs` pass for the `@progress` body-wrap: rewrites ONLY the
# self-property / self-IP accesses `walk_rhs` already resolved to `__self__.X`,
# threading `__progress__` (the var the enclosing `Treebars.@progress __status__
# begin…end` binds) so each self-access hangs its progress node under the ambient
# phase. Foreign calls, locals, and accesses on other objects are left untouched —
# this is "less exhaustive than @dynamic_progress": it follows only the
# property-dependency tree, never wraps foreign work.
#
# Distinct from `_fetch_rewrite` (which wraps EVERY call/access): here a self-IP
# call keeps its `__self__.X` callee LITERAL (not itself rewritten to
# `maybefetchproperty!`), and only `__self__`-rooted accesses are touched. The
# `__progress__` references are emitted LITERALLY in source, so Treebars'
# outside-in `@progress` walker renames them — sidestepping the `fecc238`
# dangling-`__progress__` footgun that killed the 1-arg `@fetch!`.
_progress_self_rewrite(x) = x
function _progress_self_rewrite(x::Expr)
    # do-block with self-IP callee: desugar so the lambda lands after progress+callee
    if Meta.isexpr(x, :do) && length(x.args) == 2 && Meta.isexpr(x.args[1], :call) &&
       length(x.args[1].args) >= 1 && _is_self_access(x.args[1].args[1])
        call = x.args[1]
        lambda = _progress_self_rewrite(x.args[2])
        rest = Any[_progress_self_rewrite(a) for a in call.args[2:end]]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybefetchindex!),
            :__progress__, call.args[1], lambda, rest...))
    end
    # self-IP call `__self__.g(args…)` → `maybefetchindex!(__progress__, __self__.g, args…)`.
    # Keep the `__self__.g` callee literal; recurse into the args.
    if Meta.isexpr(x, :call) && length(x.args) >= 1 && _is_self_access(x.args[1])
        rest = Any[_progress_self_rewrite(a) for a in x.args[2:end]]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybefetchindex!),
            :__progress__, x.args[1], rest...))
    end
    # Keyword block: a self dotted-shorthand `; __self__.field` would become a bare
    # `maybefetchproperty!(…)` call (invalid in keyword position), so route each
    # element through the self-scoped kwarg handler. Mirrors `_fetch_rewrite`'s
    # handling of the same edge, scoped to self-accesses.
    if Meta.isexpr(x, :parameters)
        return Expr(:parameters, Any[_progress_self_rewrite_kwarg(a) for a in x.args]...)
    end
    # bare self-property access `__self__.y` → `maybefetchproperty!(__progress__, __self__, :y)`.
    if _is_self_access(x)
        return Expr(:call, GlobalRef(@__MODULE__, :maybefetchproperty!),
            :__progress__, :__self__, QuoteNode(x.args[2].value))
    end
    # Anything else: recurse, leaving foreign calls / locals untouched.
    Expr(x.head, Any[_progress_self_rewrite(a) for a in x.args]...)
end

# One `:parameters` element, kept valid keyword syntax — parallels
# `_fetch_rewrite_kwarg` but scoped to self-accesses. A dotted self-shorthand
# `; __self__.field` (what `walk_rhs` produces from `; field` for a sibling
# property) is wrapped back into `field = maybefetchproperty!(…)`; every other
# shape (incl. a non-self dotted shorthand `; obj.field`, which stays valid under
# the generic recursion) routes through `_progress_self_rewrite`.
_progress_self_rewrite_kwarg(a) = _progress_self_rewrite(a)
function _progress_self_rewrite_kwarg(a::Expr)
    if _is_self_access(a)
        return Expr(:kw, a.args[2].value, _progress_self_rewrite(a))
    end
    return _progress_self_rewrite(a)
end

"""
    noprogress(f, args...; kwargs...)

Opt out of dynamic progress wrapping at a specific call site. Inside an IP
body annotated with `@dynamic_progress`, every call is rewritten to
`maybeprogress!(__progress__, callee, args…)`. Writing `noprogress(f, args…)`
makes the rewriter emit `maybeprogress!(__progress__, noprogress, f, args…)`,
which dispatches to a method that just runs `f(args…)` without any progress
attachment.

Note the argument shape: `noprogress(f, args…)` (comma-separated callee and
its args), not `noprogress(f(args…))` — the latter would still wrap `f(args…)`
under the body-wide rewrite before `noprogress` ever sees it.

Outside a `@dynamic_progress` body, `noprogress(f, args…)` is just `f(args…)`.
"""
noprogress(f, args...; kwargs...) = f(args...; kwargs...)

"""
    maybeprogress!(progress, callee, args…; kwargs...)

Runtime dispatch arm for `@dynamic_progress`-rewritten call sites. The
rewriter wraps every call as `maybeprogress!(__progress__, callee, args…)`,
where `__progress__` resolves to the current Treebars progress context (the
enclosing IP's `__status__` at top level; a nested `@progress` block re-binds
it to that block's node). Dispatch on `callee`:

- `callee::IndexableProperty` — open a per-call substatus rooted at
  `progress`, run the IP body inside it (no caching).
- `callee::typeof(noprogress)` — opt-out, calls through (`noprogress(f, args…)`).
- anything else — plain `callee(args…; kwargs…)`.

The caching stack — `@memo! foo(x)` inside a `@dynamic_progress` body —
lands at `maybememoize!(maybeprogress!, progress, callee, args…)` after
natural macro expansion order, and is handled by the corresponding
`maybememoize!` dispatch arms (see above).

`progress === nothing` is fine throughout — the `_default_substatus` /
`fetchindex!` paths have explicit `::Nothing` fallbacks.
"""
maybeprogress!(progress, f, args...; kwargs...) = f(args...; kwargs...)

maybeprogress!(progress, ::typeof(noprogress), f, args...; kwargs...) =
    f(args...; kwargs...)

# `@memo!` expands outside `@dynamic_progress`'s `_progress_rewrite`, so a
# `@memo! foo(x)` inside a `@dynamic_progress` body lands at runtime as
# `maybememoize!(maybeprogress!, __progress__, callee, args…)` — i.e. with
# `maybeprogress!` swallowed as the first positional arg. These dispatch arms
# undo that nesting: an IP callee goes through `fetchindex!` (cached + progress);
# a plain callee runs without caching but still under the progress context.
maybememoize!(::typeof(maybeprogress!), progress, f::IndexableProperty, args...; kwargs...) =
    fetchindex!(progress, f, args...; kwargs...)
maybememoize!(::typeof(maybeprogress!), progress, f, args...; kwargs...) =
    maybeprogress!(progress, f, args...; kwargs...)

maybeprogress!(progress, ip::IndexableProperty{name}, indices...; kwargs...) where {name} = begin
    o = ip.o
    # Per-call substatus, parented under `progress` (instead of the default
    # `o.__status__`). When `progress === nothing` this returns `nothing` and
    # everything downstream falls back to the standard `o.__status__` flow
    # inside `_computeproperty`. The label/inline decision lives in
    # `_default_substatus` (gated on the property's docstring).
    s = _default_substatus(progress, o, name, indices...; kwargs...)
    try
        rv = _computeproperty(o, name, indices...; __status__=s, kwargs...)
        _finalize_substatus!(s)
        rv
    catch e
        _fail_substatus!(s, e)
        rethrow()
    end
end

# Recursively rewrite every call site to `maybeprogress!($progress_var, …)`.
# Mirrors `_call_rewrite`'s shape; orthogonal but stackable.
#
# `progress_var` is the in-scope identifier the call sites should reference
# — typically `:__progress__`. Inside a Tb `@progress label body` block
# (or anything that rebinds the identifier), `__progress__` gets the
# per-block node, so the same emitted code transparently follows the
# nesting.
#
# Stacking with `@memo!`: `@dynamic_progress`'s macro expansion runs before
# `@memo!`'s (outside→in), so `@memo! foo(x)` is still a `:macrocall` here —
# we just recurse into it like any other Expr. The inner `foo(x)` becomes
# `maybeprogress!(__progress__, foo, x)`. When `@memo!` expands later, its
# own `_call_rewrite` sees that `:call` and turns it into
# `maybememoize!(maybeprogress!, __progress__, foo, x)`. The
# `maybememoize!(::typeof(maybeprogress!), …)` dispatch arms (above) then
# do the right thing at runtime.
_progress_rewrite(progress_var::Symbol, x) = x
function _progress_rewrite(progress_var::Symbol, x::Expr)
    if Meta.isexpr(x, :do) && length(x.args) == 2 && Meta.isexpr(x.args[1], :call)
        call = x.args[1]
        lambda = _progress_rewrite(progress_var, x.args[2])
        rewritten = Any[_progress_rewrite(progress_var, a) for a in call.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybeprogress!), progress_var, rewritten[1], lambda, rewritten[2:end]...))
    end
    if Meta.isexpr(x, :call) && length(x.args) >= 1
        rewritten = Any[_progress_rewrite(progress_var, a) for a in x.args]
        return fixcall(Expr(:call, GlobalRef(@__MODULE__, :maybeprogress!), progress_var, rewritten...))
    end
    Expr(x.head, Any[_progress_rewrite(progress_var, a) for a in x.args]...)
end

"""
    @dynamic_progress progress_var body

Rewrite every `:call` inside `body` as
`maybeprogress!(progress_var, callee, args…)`. Returns the rewritten body
unchanged otherwise. **The caller is responsible for binding
`progress_var`** — e.g. via `Treebars.@progress progress_var body` — and
for keeping DO free of a hard `Treebars` dependency.

`maybeprogress!` dispatches on `progress_var`'s runtime type: a
`Treebars.ProgressNode` (when the caller has wrapped in `Tb.@progress`)
opens per-call substatuses; `noprogress` opts out; anything else
collapses to a plain `f(args…)`. The macro itself doesn't care which.

In `@dynamicstruct`, a property marker `@dynamic_progress` lowers to

    prop() = @dynamic_progress __status__ body

where `__status__` is the IP caller's bound progress context (or
`nothing`).

Standalone:

    Treebars.@progress my_status begin
        @dynamic_progress my_status begin
            a = foo(x)           # → maybeprogress!(my_status, foo, x)
            b = @memo! bar(y)    # cached + progress (see `maybememoize!`)
            a + b
        end
    end
"""
macro dynamic_progress(progress_var, body)
    progress_var isa Symbol ||
        error("@dynamic_progress: progress var must be a Symbol, got $(progress_var)")
    esc(_progress_rewrite(progress_var, body))
end

persist(v, args...; kwargs...) = begin
    Serialization.serialize(
        get_cache_path(args...; kwargs...),
        v
    )
end

# Pop a specific (indices, kwargs) entry from an IndexableProperty's cache,
# or no-op when the entry isn't an IP.
_maybepop_indexed!(v::IndexableProperty, indices, kwargs) =
    (maybepop!(v.cache, (indices, (;kwargs...))); nothing)
_maybepop_indexed!(args...) = nothing

clear_cache!(o, name::Symbol, indices...; kwargs...) = begin
    cache = getfield(o, :cache).cache
    if isempty(indices) && isempty(kwargs)
        # Clear in-memory (whole property, including IndexableProperty wrapper)
        delete!(cache, name)
        # Clear all disk cache files for this property
        cp = o.__cache_path__
        if isdir(cp)
            prefix = string(name)
            for f in readdir(cp)
                if endswith(f, ".sjl") && (f == prefix * ".sjl" || startswith(f, prefix * "_"))
                    rm(joinpath(cp, f))
                end
            end
        end
    else
        # Clear specific indexed entry from in-memory cache
        haskey(cache, name) && _maybepop_indexed!(cache[name], indices, kwargs)
        # Clear specific disk cache file
        path = get_cache_path(o, name, indices...; kwargs...)
        isfile(path) && rm(path)
        metadata_path = _automatic_materialization_path(path)
        isfile(metadata_path) && rm(metadata_path)
    end
    nothing
end
"""
    @clear_cache! o.prop
    @clear_cache! o.prop(indices...)

Clear the disk cache (and in-memory cache) for a `@cached` property.

Without indices, clears **all** cached entries for the property (both the
in-memory value and all `.sjl` files for that property on disk).
With indices, clears only the specific entry.

```julia
@clear_cache! e.result        # clear all cached entries for `result`
@clear_cache! e.ci(3)         # clear only the (3,) entry
```

The legacy bracket form is still accepted but discouraged.
"""
macro clear_cache!(x)
    cache_f_expr(x; f=clear_cache!) |> esc
end

isfixed(kv::Pair) = isfixed(kv[2])
isfixed(info::NamedTuple) = isnothing(info.rhs)

# Per-element handler for the `:local` branch of `walk_rhs` — register
# Symbol locals via dispatch instead of an `if arg isa Symbol …` chain
# inside the loop body. Tuple-Expr leaves go through `_push_if_symbol!`,
# Symbol assignment LHS through `_walk_local_assign!`.
_walk_local_arg!(arg::Symbol; locals, kwargs...) = (push!(locals, arg); arg)
_walk_local_arg!(arg; locals, properties, lnn) = walk_rhs(arg; locals, properties, lnn)
function _walk_local_arg!(arg::Expr; locals, properties, lnn)
    if Meta.isexpr(arg, :(=))
        return _walk_local_assign!(arg.args[1], arg, locals, properties, lnn)
    elseif Meta.isexpr(arg, :tuple)
        foreach(s -> _push_if_symbol!(locals, s), arg.args)
        return arg
    end
    walk_rhs(arg; locals, properties, lnn)
end
_walk_local_assign!(lhs::Symbol, arg, locals, properties, lnn) =
    (push!(locals, lhs); Expr(:(=), lhs, walk_rhs(arg.args[2]; locals, properties, lnn)))
_walk_local_assign!(_, arg, locals, properties, lnn) = walk_rhs(arg; locals, properties, lnn)
_push_if_symbol!(locals, s::Symbol) = (push!(locals, s); nothing)
_push_if_symbol!(_, _) = nothing

# Per-element handler for the trailing-else branch of `walk_rhs(::Expr)`.
# LineNumberNode arms record the LNN into a Ref so subsequent siblings
# pick it up; everything else recurses with the most recent LNN. Avoids
# the `if arg isa LineNumberNode` mutating-closure pattern.
_walk_with_lnn_tracking!(arg::LineNumberNode, ref, locals, properties) = (ref[] = arg; arg)
_walk_with_lnn_tracking!(arg, ref, locals, properties) =
    walk_rhs(arg; locals, properties, lnn=ref[])

walk_rhs(e; kwargs...) = e
walk_rhs(e::Expr; locals, properties, lnn=nothing) = if e.head == :let
    # locals = properties[dependent].locals
    ls = Set{Symbol}()
    !Meta.isexpr(e.args[1], :block) && (e.args[1] = Expr(:block, e.args[1]))
    map!(e.args[1].args, e.args[1].args) do arg
        arg = _normalize_let_binding(arg)
        @assert Meta.isexpr(arg, :(=))
        name, rhs = arg.args[1], walk_rhs(arg.args[2]; locals, properties, lnn)
        name in locals || push!(ls, name)
        push!(locals, name)
        Expr(:(=), name, rhs)
    end
    e.args[2] = walk_rhs(e.args[2]; locals, properties, lnn)
    for l in ls
        delete!(locals, l)
    end
    e
elseif e.head == :(->)
    # Lambda: first arg is parameter(s), second is body.
    # Add lambda params to locals so they are not rewritten.
    params = e.args[1]
    ls = extractnames(Meta.isexpr(params, :tuple) ? params.args : [params])
    new_locals = union(locals, ls)
    Expr(e.head, e.args[1], walk_rhs(e.args[2]; locals=new_locals, properties, lnn))
elseif e.head == :for
    # for x in range; body; end — iterator var is local in body
    # Multi-iterator: for x in xs, y in ys → args[1] is a :block of :(=)
    iter_block = e.args[1]
    iters = Meta.isexpr(iter_block, :block) ? iter_block.args : [iter_block]
    ls = mapreduce(it -> extractnames([it.args[1]]), union, iters)
    new_locals = union(locals, ls)
    walked_iters = [Expr(:(=), it.args[1], walk_rhs(it.args[2]; locals=new_locals, properties, lnn)) for it in iters]
    walked_iter_block = Meta.isexpr(iter_block, :block) ? Expr(:block, walked_iters...) : walked_iters[1]
    walked_body = walk_rhs(e.args[2]; locals=new_locals, properties, lnn)
    Expr(:for, walked_iter_block, walked_body)
elseif e.head == :generator
    # x for x in range — iterator var(s) are local in the body expression
    # args[1] = body, args[2:end] = Expr(:(=), var, range) or Expr(:filter, cond, Expr(:(=), ...) ...)
    raw_iters = e.args[2:end]
    # Extract all :(=) iterators, unwrapping :filter
    all_eq = Expr[]
    for it in raw_iters
        if Meta.isexpr(it, :filter)
            append!(all_eq, filter(a -> Meta.isexpr(a, :(=)), it.args))
        elseif Meta.isexpr(it, :(=))
            push!(all_eq, it)
        end
    end
    ls = isempty(all_eq) ? Set{Symbol}() : mapreduce(it -> extractnames([it.args[1]]), union, all_eq)
    new_locals = union(locals, ls)
    walked_body = walk_rhs(e.args[1]; locals=new_locals, properties, lnn)
    walked_iters = map(raw_iters) do it
        if Meta.isexpr(it, :filter)
            # filter args: condition, then :(=) iterators
            walked_args = map(it.args) do a
                if Meta.isexpr(a, :(=))
                    Expr(:(=), a.args[1], walk_rhs(a.args[2]; locals, properties, lnn))
                else
                    walk_rhs(a; locals=new_locals, properties, lnn)
                end
            end
            Expr(:filter, walked_args...)
        else
            Expr(:(=), it.args[1], walk_rhs(it.args[2]; locals, properties, lnn))
        end
    end
    Expr(:generator, walked_body, walked_iters...)
elseif e.head == :function
    # function g(x); body; end — func name and params are local in body
    sig = e.args[1]
    if Meta.isexpr(sig, :call)
        ls = extractnames(sig.args)  # includes func name + params
        new_locals = union(locals, ls)
        Expr(:function, sig, walk_rhs(e.args[2]; locals=new_locals, properties, lnn))
    else
        Expr(:function, sig, walk_rhs(e.args[2]; locals, properties, lnn))
    end
elseif e.head == :try
    # try; body; catch e; catch_body; [finally; finally_body;] end
    # args: [try_body, catch_var, catch_body, [finally_body]]
    walked_try = walk_rhs(e.args[1]; locals, properties, lnn)
    catch_var = e.args[2]  # Symbol or false
    catch_locals = catch_var === false ? locals : union(locals, Set([catch_var]))
    walked_catch = walk_rhs(e.args[3]; locals=catch_locals, properties, lnn)
    if length(e.args) >= 4
        walked_finally = walk_rhs(e.args[4]; locals, properties, lnn)
        Expr(:try, walked_try, catch_var, walked_catch, walked_finally)
    else
        Expr(:try, walked_try, catch_var, walked_catch)
    end
elseif e.head in (:kw, :(=))
    # For local function defs like f(x) = x + 1, add func name + params as locals in body
    if Meta.isexpr(e.args[1], :call)
        ls = extractnames(e.args[1].args)  # includes func name + params
        new_locals = union(locals, ls)
        Expr(e.head, e.args[1], walk_rhs.(e.args[2:end]; locals=new_locals, properties, lnn)...)
    else
        # Warn if assigning to a property name inside a block — likely intended as local
        lhs = e.args[1]
        if e.head == :(=)
            shadowed = _shadowed_lhs(lhs, properties, locals)
            for s in shadowed
                loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
                error("Assignment to `$s` in a property RHS shadows property `$s`$loc. This writes to the property cache, not a local variable. Declare it with `local $s` (or `local $s = ...`) or use `let $s = ...` to make it a local.")
            end
        end
        walked_lhs = Meta.isexpr(lhs, (:ref, :.)) ? walk_rhs(lhs; locals, properties, lnn) : lhs
        Expr(e.head, walked_lhs, walk_rhs.(e.args[2:end]; locals, properties, lnn)...)
    end
elseif e.head == :local
    # `local x`, `local x, y, z`, or `local x = expr` — add names to the local
    # scope so subsequent assignments don't hit the property cache.
    walked = map(arg -> _walk_local_arg!(arg; locals, properties, lnn), e.args)
    Expr(:local, walked...)
elseif e.head == :tuple
    # Named tuple: (x=1, y=2) — :(=) children are field definitions, not assignments.
    # Walk only the values, not the keys.
    walked = map(e.args) do arg
        if Meta.isexpr(arg, :(=))
            Expr(:(=), arg.args[1], walk_rhs(arg.args[2]; locals, properties, lnn))
        else
            walk_rhs(arg; locals, properties, lnn)
        end
    end
    Expr(:tuple, walked...)
else
    # Track LineNumberNodes for better warning locations. Dispatch on
    # the arg type via `_walk_with_lnn_tracking!` (LNN method updates
    # the Ref; the fallback walks the arg with the current LNN) instead
    # of branching on `isa` inside the loop body.
    ref_lnn = Ref{Any}(lnn)
    walked = map(arg -> _walk_with_lnn_tracking!(arg, ref_lnn, locals, properties), e.args)
    Expr(e.head, walked...)
end
walk_rhs(e::Symbol; locals, properties, lnn=nothing) = if (e in properties) && !(e in locals)
    :(__self__.$e)
else
    e
end

# --- Static dependency extraction (for `property_source_info` + `remake` carry-over) ---
# `walk_rhs` has already rewritten every in-scope bare property/field reference to
# `__self__.<name>`, so a property's dependencies on the object's own state are
# exactly the `__self__.<name>` accesses left in its walked RHS. `_collect_self_deps!`
# harvests those names into `deps` and returns whether the RHS reaches object state
# *opaquely* — any residual bare `__self__` (handed to a helper, `getfield(__self__,
# dynamic)`, `__self__.$(expr)`) the static scan cannot attribute to a named field.
# An opaque reach means `deps` is NOT a sound over-approximation, so callers that
# rely on soundness (carry-over) must treat the property as always-invalidated.
function _collect_self_deps!(deps::Set{Symbol}, e)
    opaque = Ref(false)
    _collect_self_deps_walk!(deps, opaque, e)
    opaque[]
end
function _collect_self_deps_walk!(deps::Set{Symbol}, opaque::Ref{Bool}, e)
    if e isa Symbol
        e === :__self__ && (opaque[] = true)
    elseif e isa Expr
        if e.head === :. && length(e.args) == 2 && e.args[1] === :__self__ && e.args[2] isa QuoteNode
            push!(deps, e.args[2].value::Symbol)   # `__self__.field` — a tracked dependency
        else
            for a in e.args
                _collect_self_deps_walk!(deps, opaque, a)
            end
        end
    end
    nothing
end

# Fixed fields that (transitively) invalidate `prop`'s value: the fixed-field
# leaves reachable from `prop` in the direct-dependency graph. An opaque reach —
# `prop` opaque, a dependency opaque, or a content-hash dunder in the closure —
# means independence from a changed field cannot be proven, so ALL fixed fields
# invalidate (conservative, keeps `remake` carry-over sound-by-construction).
const _HASH_DUNDERS = (:__hash__, :__hash_fields__, :__cache_base__, :__cache_path__)
function _carry_invalidators(prop::Symbol, direct_deps::AbstractDict, fixed_set, opaque_props)
    (prop in opaque_props) && return copy(fixed_set)
    inv = Set{Symbol}()
    seen = Set{Symbol}()
    stack = Symbol[prop]
    while !isempty(stack)
        n = pop!(stack)
        (n in seen) && continue
        push!(seen, n)
        for d in get(direct_deps, n, ())
            (d in _HASH_DUNDERS || d in opaque_props) && return copy(fixed_set)
            (d in fixed_set) && push!(inv, d)
            push!(stack, d)
        end
    end
    inv
end

# --- Linter ----------------------------------------------------------------
#
# Lints are computed by `analyze_structure(T)` — a tree-walk over `meta(T)`
# that produces a `Vector{LintMessage}`. `print_structure(T)` weaves these
# messages inline next to the affected property/struct. There is no
# automatic stderr/error emission from the macro; lints surface only when
# you render the structure.

struct LintMessage
    type::Type
    prop::Union{Symbol,Nothing}     # nothing = struct-level lint
    severity::Symbol                # :warn or :error
    short::String                   # 1-line summary for inline rendering
    long::String                    # full message
    lnn::Union{LineNumberNode,Nothing}
end

# --- Bare-rhs scanners (used by no-self-access check) ---
_contains_self_ref(e::Symbol) = e === :__self__
_contains_self_ref(e::Expr) = any(_contains_self_ref, e.args)
_contains_self_ref(_) = false

_contains_bare_prop_ref(e::Symbol, prop_names) = e in prop_names
_contains_bare_prop_ref(e::Expr, prop_names) = any(a -> _contains_bare_prop_ref(a, prop_names), e.args)
_contains_bare_prop_ref(_, _) = false

_contains_call(_) = false
_contains_call(e::Expr) = Meta.isexpr(e, :call) || any(_contains_call, e.args)

# Common short identifiers that ARE meaningful — full English words, or
# unambiguous in any code context. Anything else under 4 characters is
# almost always cryptic on a public-facing IP signature / route param.
const _OK_SHORT_NAMES = Set{Symbol}([
    :id, :to, :at, :as, :ok, :it, :in, :on, :up, :by, :of, :no,
    :url, :uri, :key, :val, :err, :tag, :now, :all, :any, :len,
])

# Indexed properties on `@dynamicstruct`/`@htmx` structs are the public
# API of those structs — IP signatures and route parameter names show up
# in URLs, docs, and call sites, so they must communicate intent. Flag
# 1-letter names (`x`, `n`, …) and 2-3 letter abbreviations (`pn`, `df`,
# `ctx`, …) on indexed property arg lists. Local loop counters
# (`for i in 1:n`) are unaffected — they live in property bodies, not
# in declared signatures.
# Forwarded inline-child props have `rhs == __parent__.x`, courtesy of the
# `(;a, b) = __parent__` destructure inserted by the inline-include desugar.
# Filter them out of struct-level lints — they're scoped views, not owned.
_is_forwarded(rhs::Expr) = rhs.head === :. && length(rhs.args) == 2 &&
                            rhs.args[1] === :__parent__
_is_forwarded(::Any) = false

# Dunders auto-injected by DO machinery — never user-state. Only `__parent__`
# is DO's (children get a `__parent__ = nothing` prepend); `__prefix__`,
# `__req__`, and `__route__` were HTMXObjects' and had leaked in here — removed
# 2026-07-07 (user directive). HTMXObjects owns those on its own side now.
const _AUTO_DUNDERS = Set([:__parent__])

# --- Per-property checks ---------------------------------------------------

# Collect every `(callee_name::Symbol, ref_expr)` pair in `e` where `ref_expr`
# is `:ref` head (i.e. `a[b...]`) and the callee resolves to a sibling
# property reference. After `walk_rhs`, in-body sibling references appear as
# either `__self__.<name>` (the common rewrite) or the bare `<name>` (when
# inside a non-shadowed scope; rare since walk_rhs rewrites those too).
# Returns the list of (callee_name, original_ref_callee_expr) hits.
_bracket_ip_callee(::Any) = nothing
function _bracket_ip_callee(e::Symbol)
    # bare sibling name in a `[...]`; resolved by caller against prop_names
    e
end
function _bracket_ip_callee(e::Expr)
    if e.head === :. && length(e.args) == 2 &&
            e.args[1] === :__self__ && e.args[2] isa QuoteNode &&
            e.args[2].value isa Symbol
        return e.args[2].value::Symbol
    end
    nothing
end

_scan_bracket_ip!(_, _, _) = nothing
function _scan_bracket_ip!(hits::Vector{Symbol}, e::Expr, prop_names)
    if Meta.isexpr(e, :ref) && length(e.args) >= 1
        callee = _bracket_ip_callee(e.args[1])
        callee isa Symbol && callee in prop_names && push!(hits, callee)
    end
    for a in e.args
        _scan_bracket_ip!(hits, a, prop_names)
    end
end

function _check_bracket_ip_access!(msgs, type, name::Symbol, info, prop_names, indexed_names)
    info.rhs === nothing && return
    info.rhs isa Expr || return
    hits = Symbol[]
    _scan_bracket_ip!(hits, info.rhs, prop_names)
    isempty(hits) && return
    seen = Set{Symbol}()
    for callee in hits
        callee in indexed_names || continue
        callee in seen && continue
        push!(seen, callee)
        short = "`o.$callee[...]`: use `o.$callee(...)` (now caches by default) — bracket access on IndexableProperty is no longer supported"
        long  = "Property `$type.$name` reads `$callee[...]` (bracket access on an `IndexableProperty`). The `ip[args...]` overload has been removed: `ip[; kwargs...]` was never valid Julia syntax (the parser rejects `[; …]`), and Niko hit the gap often enough that the bracket form is gone entirely. Use the call form instead: `o.$callee(args; kwargs...)` now caches by default (keyed by args), exactly as the bracket form did — `@memo! o.$callee(...)` / `memoize!(o.$callee, ...)` are explicit equivalents. To recompute fresh and bypass the cache, use `@fresh o.$callee(...)` / `fresh(o.$callee, ...)`."
        push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
    end
end

function _check_cryptic_arg_names!(msgs, type, name::Symbol, info)
    isempty(info.indices) && return
    bad = String[]
    for idx in info.indices
        Meta.isexpr(idx, :parameters) && continue
        a = idx
        Meta.isexpr(a, :kw) && (a = a.args[1])
        Meta.isexpr(a, :(::)) && (a = a.args[1])
        a isa Symbol || continue
        s = String(a)
        startswith(s, "_") && continue
        length(s) >= 4 && continue
        a in _OK_SHORT_NAMES && continue
        push!(bad, s)
    end
    isempty(bad) && return
    short = "cryptic arg name(s): " * join(map(s -> "`$s`", bad), ", ")
    long  = "Property `$type.$name(…)` has cryptic parameter name(s) $(join(map(s -> "`$s`", bad), ", ")). Indexed-property args are public API (URLs, IP cache keys, call sites) and must communicate intent. Rename to meaningful English names — `posterior_name` not `pn`, `dataframe` not `df`, `value` not `x`. Single-letter names belong in tight algorithmic locals, not declared signatures."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

function _check_no_self_access!(msgs, type, name::Symbol, info, prop_names,
                                bound_siblings, bound)
    isempty(info.indices) && return
    isempty(info.macros) || return
    info.rhs === nothing && return
    _contains_call(info.rhs) || return
    _contains_self_ref(info.rhs) && return
    _contains_bare_prop_ref(info.rhs, prop_names) && return
    args = _ip_positional_args(info.indices)
    argstr = join(string.(args), ", ")
    if !isempty(bound_siblings)
        slist   = join(map(s -> "`$s`", bound_siblings), ", ")
        depsstr = join(string.(bound), ", ")
        short = "stateless — body uses no sibling state; shares deps `{$depsstr}` with $slist, fold the cluster into one inline child keyed on `($depsstr)` rather than each on its own args"
    else
        short = "stateless — body uses no sibling state; fold to `@struct $name($argstr) = begin … end` if args own an identity, or accept as helper"
    end
    long  = "Property `$type.$name(…)` calls functions but reads no sibling state. This property does not belong on `$type`. Lift it to an inline-child DO that owns the underlying object/key and exposes the derivations as bare properties. (A) Args key on a 'thing' the struct isn't modelling yet → introduce `@struct entry(k) = begin …end`. (B) Args all come from one existing object → lift `$name` to be a property OF that object."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

function _check_trivial_cached_wrapper!(msgs, type, name::Symbol, info)
    Symbol("@cached") in info.macros || return
    rhs = info.rhs
    Meta.isexpr(rhs, :call) || return
    prop_arg_names = Symbol[]
    for idx in info.indices
        Meta.isexpr(idx, :parameters) && continue
        a = idx
        Meta.isexpr(a, :(::)) && (a = a.args[1])
        a isa Symbol && push!(prop_arg_names, a)
    end
    call_args = Symbol[]
    for a in rhs.args[2:end]
        Meta.isexpr(a, :parameters) && continue
        sym = a
        Meta.isexpr(sym, :(::)) && (sym = sym.args[1])
        sym isa Symbol || return
        push!(call_args, sym)
    end
    prop_arg_names == call_args || return
    callee = rhs.args[1]
    short = "thin @cached wrapper around `$callee(…)`"
    long  = "`@cached $type.$name(…)` is a thin wrapper around `$callee(…)` — body is one call passing the same args. Inline `$callee`'s body into the @cached property, or drop the wrapper and have callers `@cached`-call `$callee` directly. The current shape is doing both."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# D4: `@mmap` and `@cached` on the same property are mutually exclusive —
# `@mmap` already implies disk persistence (with the mmap format), so stacking
# `@cached` is contradictory (two formats fighting over one cache path).
function _check_mmap_cached_conflict!(msgs, type, name::Symbol, info)
    (Symbol("@mmap") in info.macros && Symbol("@cached") in info.macros) || return
    short = "`@mmap` + `@cached` are mutually exclusive — drop `@cached`"
    long  = "`$type.$name` carries both `@mmap` and `@cached`. `@mmap` already implies disk persistence using the memory-mapped format, so `@cached` is redundant and contradictory (both want to own the disk cache path with different formats). Keep `@mmap` alone for a memory-mapped read-only array, or `@cached` alone for the serialized format."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# --- Per-struct checks ----------------------------------------------------

function _check_singleton_struct!(msgs, type, oproperties)
    user = []
    for (n, info) in oproperties
        n in _AUTO_DUNDERS && continue
        s = String(n)
        startswith(s, "_tuple_") && continue
        n === :__hash_fields__ && continue
        push!(user, (n, info))
    end
    length(user) == 1 || return
    (only_name, only_info) = first(user)
    advice = only_info.indexed ?
        "Replace with `$only_name(args…) = …` on the enclosing scope." :
        "Replace with `$only_name = …` on the enclosing scope."
    short = "singleton: only one user property `$only_name`"
    long  = "`$type` has exactly one user-declared property: `$only_name`. $advice The struct shell adds nothing."
    push!(msgs, LintMessage(type, nothing, :warn, short, long, only_info.lnn))
end

function _check_repeated_prefix!(msgs, type, oproperties)
    own_names = Symbol[n for (n, info) in oproperties if !_is_forwarded(info.rhs)]
    name_set = Set(own_names)
    by_prefix = Dict{String, Vector{Symbol}}()
    for n in own_names
        s = String(n)
        startswith(s, "__") && endswith(s, "__") && continue
        startswith(s, "_tuple_") && continue
        underscore = findfirst(==('_'), s)
        isnothing(underscore) && continue
        underscore == 1       && continue
        prefix = s[1:underscore-1]
        push!(get!(by_prefix, prefix, Symbol[]), n)
    end
    for (prefix, group) in by_prefix
        length(group) >= 2 || continue
        members = join(map(g -> "`$g`", group), ", ")
        if Symbol(prefix) in name_set
            short = "$(length(group)) `$(prefix)_*` siblings ($members) + bare `$prefix` — fold into it (`@struct`/`@include` body)"
            long  = "`$type` has $(length(group)) properties named `$(prefix)_*` ($(join(group, ", "))) AND a bare `$prefix` property. Move the `$(prefix)_*` members INTO `$prefix` as bare suffixes (`$type.$prefix.<suffix>`). Use `@struct $prefix = begin …end` for data, `@include $prefix = begin …end` for routes."
            push!(msgs, LintMessage(type, nothing, :error, short, long, nothing))
        else
            short = "$(length(group)) `$(prefix)_*` siblings ($members) — group as `@struct $prefix` (or `@include $prefix` if routes)"
            long  = "`$type` has $(length(group)) properties sharing `$(prefix)_*` prefix: $(join(group, ", ")). Group inside `@struct $prefix = begin …end` (data) or `@include $prefix = begin …end` (routes) so the shared-prefix names become bare members of the child."
            push!(msgs, LintMessage(type, nothing, :warn, short, long, nothing))
        end
    end
end

function _check_shared_arg_signature!(msgs, type, oproperties, types_in_tree, parent_map, wc_cache)
    by_sig = Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}()
    info_of = Dict{Symbol, Any}()
    for (name, info) in oproperties
        _is_forwarded(info.rhs) && continue
        isempty(info.indices) && continue
        sig = Symbol[]
        for idx in info.indices
            Meta.isexpr(idx, :parameters) && continue
            a = idx
            Meta.isexpr(a, :(::)) && (a = a.args[1])
            a isa Symbol && push!(sig, a)
        end
        isempty(sig) && continue
        push!(get!(by_sig, Tuple(sig), Symbol[]), name)
        info_of[name] = info
    end
    for (sig, group) in by_sig
        length(group) >= 2 || continue
        argstr  = join(sig, ", ")
        members = join(map(g -> "`$g`", group), ", ")
        # Aggregate the worst-case bound across the group. If callers had
        # additional scope identities beyond the args themselves, the args
        # are likely derived FROM those identities. The bound names here
        # name the actual upstream keys.
        upstream = Set{Symbol}()
        for member in group
            wc = _print_struct_worst_case(types_in_tree, parent_map, type,
                                          member, info_of[member], wc_cache)
            wc !== nothing && wc[1] === :bound && union!(upstream, wc[2])
        end
        # Args themselves aren't in the bound (only caller scope is), so
        # any non-empty bound implies derived. Empty bound = proper keys.
        derived  = !isempty(upstream)
        upnames  = sort!(collect(upstream))
        upstr    = join(map(n -> "`$n`", upnames), ", ")
        short, severity = if derived
            ("$(length(group)) IPs share `($argstr)` ($members) — args derived from $upstr; refactor to key on those upstream identities instead of threading `($argstr)` through",
             :warn)
        else
            ("$(length(group)) IPs share `($argstr)` ($members) — `($argstr)` look like proper keys; fold to `@struct shared($argstr)`",
             :warn)
        end
        long = derived ?
            "`$type` has $(length(group)) indexed properties sharing the `($argstr)` signature: $(join(group, ", ")). Their worst-case bound includes $upstr, meaning every call site computes `($argstr)` from those upstream identities. Folding into `@struct shared($argstr)` just shifts the redundancy. Refactor the IPs to key on the upstream identities ($upstr) directly so callers don't have to thread the derived values through." :
            "`$type` has $(length(group)) indexed properties sharing the `($argstr)` signature: $(join(group, ", ")). Worst-case bound is empty — callers pass `($argstr)` without additional scope contributions, so they're independent identities. `@struct shared($argstr) = begin …end` is the right fold; the IP bodies become bare members."
        push!(msgs, LintMessage(type, nothing, severity, short, long, nothing))
        by_prefix = Dict{String, Vector{Symbol}}()
        for n in group
            s = String(n)
            underscore = findfirst(==('_'), s)
            (isnothing(underscore) || underscore == 1) && continue
            push!(get!(by_prefix, s[1:underscore-1], Symbol[]), n)
        end
        for (prefix, sub) in by_prefix
            length(sub) >= 2 || continue
            sub_members = join(map(g -> "`$g`", sub), ", ")
            short_e = derived ?
                "$(length(sub)) IPs share `($argstr)` AND `$(prefix)_*` ($sub_members) — args derived from $upstr; refactor to key on those upstream identities, possibly via `@struct $prefix($(join(upnames, ", "))) = begin … end`" :
                "$(length(sub)) IPs share `($argstr)` AND `$(prefix)_*` ($sub_members) — `($argstr)` look like proper keys; fold to `@struct $prefix($argstr)`"
            long_e  = derived ?
                "`$type` has $(length(sub)) indexed properties that share BOTH the `($argstr)` signature AND the `$(prefix)_*` prefix: $(join(sub, ", ")). Args derive from $upstr; refactor to key on those upstream identities and let the suffixes become bare members of the resulting child." :
                "`$type` has $(length(sub)) indexed properties that share BOTH the `($argstr)` signature AND the `$(prefix)_*` prefix: $(join(sub, ", ")). Fold them into `@struct $prefix($argstr) = begin …end` and let the suffixes become bare members."
            push!(msgs, LintMessage(type, nothing, :error, short_e, long_e, nothing))
        end
    end
end

# --- New: hierarchical placement (lint #1) -------------------------------
# For an IP at T.prop with worst-case bound {k1, k2, ...}, every name in the
# bound should be visible in T's enclosing static scope (constructor fields,
# `@param`s, IP positional args along the parent chain). Anything outside
# that scope means the IP is reaching across the tree.

function _check_hierarchical_placement!(msgs, types_in_tree, parent_map, type, name, info, wc_cache)
    isempty(_ip_positional_args(info.indices)) && return
    wc = _print_struct_worst_case(types_in_tree, parent_map, type, name, info, wc_cache)
    (wc === nothing || wc[1] !== :bound) && return
    bound = wc[2]
    scope = _enclosing_scope(type, parent_map)
    for a in _ip_positional_args(info.indices)
        push!(scope, a)
    end
    misplaced = filter(n -> n ∉ scope, bound)
    isempty(misplaced) && return
    nlist = join(map(n -> "`$n`", misplaced), ", ")
    short = "depends on $nlist (not in scope) — relocate under the subtree that introduces $(length(misplaced) == 1 ? "it" : "them"), or pass as arg of an enclosing IP"
    long  = "`$type.$name(…)` depends on $nlist, which is not in `$type`'s enclosing scope (fields, `@param`s, parent IP args). The IP is reaching across the tree. Either relocate the IP under the subtree that introduces these names, or take them as explicit args of an enclosing IP."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# --- New: redundant-args lint --------------------------------------------
# For an IP with positional args, walk every in-tree caller and collect the
# arg expressions actually passed. If at every detected call site the same
# (parent-chain-normalized) expression is passed for arg position `i`, then
# arg `i` is constant across callers — drop it and have the IP body read
# the value directly.

# Membership test for the `meta(T)` introspection vector — replaces the
# `haskey(cprops, name)` dict lookups that were correct when `meta(T)` was a
# `Dict`. With the per-declaration vector, duplicates are preserved but a
# membership check still only cares whether the name appears at all.
_cprops_has(cprops, name::Symbol) = any(p -> first(p) === name, cprops)

# Collect all `target(args…)` call sites in `expr` matching `_has_call_to`'s
# rules; return Vector of positional-arg expression lists (one per call).
function _collect_call_args!(out::Vector{Vector{Any}}, expr, target::Symbol, cprops)
    expr isa Expr || return
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        match = false
        if callee === target
            match = cprops !== nothing && _cprops_has(cprops, target)
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            match = root !== nothing &&
                    (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                     (cprops !== nothing && _cprops_has(cprops, root)))
        end
        if match
            args = Any[]
            for a in expr.args[2:end]
                Meta.isexpr(a, :parameters) && continue   # drop kwargs
                push!(args, a)
            end
            push!(out, args)
        end
    end
    for a in expr.args
        _collect_call_args!(out, a, target, cprops)
    end
end

_collect_call_args(expr, target, cprops) =
    (out = Vector{Vector{Any}}(); _collect_call_args!(out, expr, target, cprops); out)

# Inverted call index: walk every property body in the tree once and bucket
# call sites by callee target. Replaces N×P walks (one per IP target) with
# a single pass; lookups for `_check_redundant_args!` are O(1).
function _build_call_index(types_in_tree)
    out = Dict{Symbol, Vector{Tuple{Type,Symbol,Vector{Any}}}}()
    for U in types_in_tree
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (uname, uinfo) in uprops
            uinfo.rhs === nothing && continue
            _index_calls!(out, uinfo.rhs, uprops, U, uname)
        end
    end
    out
end

function _index_calls!(out, expr, cprops, caller_T::Type, caller_prop::Symbol)
    expr isa Expr || return
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        target = nothing
        if callee isa Symbol
            cprops !== nothing && _cprops_has(cprops, callee) && (target = callee)
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode
            potential = callee.args[2].value
            root = _dot_chain_root(callee.args[1])
            if root !== nothing &&
               (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                (cprops !== nothing && _cprops_has(cprops, root)))
                target = potential
            end
        end
        if target isa Symbol
            args = Any[]
            for a in expr.args[2:end]
                Meta.isexpr(a, :parameters) && continue
                push!(args, a)
            end
            push!(get!(out, target,
                       Vector{Tuple{Type,Symbol,Vector{Any}}}()),
                  (caller_T, caller_prop, args))
        end
    end
    for a in expr.args
        _index_calls!(out, a, cprops, caller_T, caller_prop)
    end
end

# Normalize a `__self__.X…` / `__parent__[.__parent__]*.X…` dot chain to
# `(BaseType, :a, :b, ...)` where BaseType is reached by walking parent_map
# off `caller_T` once per leading `__parent__`. Returns `nothing` for any
# other shape so callers fall back to comparing the raw `Expr`.
function _normalize_dot_chain(expr, caller_T::Type, parent_map)
    accessors = Symbol[]
    cur = expr
    while Meta.isexpr(cur, :., 2) && cur.args[2] isa QuoteNode &&
          cur.args[2].value isa Symbol
        pushfirst!(accessors, cur.args[2].value)
        cur = cur.args[1]
    end
    cur isa Symbol || return nothing
    root = cur
    base_T = caller_T
    if root === :__parent__
        base_T = haskey(parent_map, caller_T) ? parent_map[caller_T][1] : caller_T
        while !isempty(accessors) && accessors[1] === :__parent__
            popfirst!(accessors)
            base_T = haskey(parent_map, base_T) ? parent_map[base_T][1] : base_T
        end
    elseif root === :__self__
        base_T = caller_T
    else
        return nothing
    end
    (base_T, accessors...)
end

function _normalize_arg(expr, caller_T::Type, parent_map)
    r = _normalize_dot_chain(expr, caller_T, parent_map)
    r === nothing ? expr : r
end

_show_normalized(v::Tuple) = isempty(v[2:end]) ? string(nameof(v[1])) :
                             string(nameof(v[1]), ".", join(v[2:end], "."))
_show_normalized(v) = string(v)

# --- Top-level pollution: AppData property used only in one subtree -------
# A property of the type registered as `__appdata__` should ideally live at
# the LCA of its callers' subtree, not above. If every reference to
# `__appdata__.X` comes from a single non-root subtree, X is misplaced —
# move it under that subtree's data domain.

function _appdata_top_field(expr)
    expr isa Expr || return nothing
    cur = expr
    accessors = Symbol[]
    while Meta.isexpr(cur, :., 2) && cur.args[2] isa QuoteNode &&
          cur.args[2].value isa Symbol
        pushfirst!(accessors, cur.args[2].value)
        cur = cur.args[1]
    end
    cur === :__appdata__ || return nothing
    isempty(accessors) ? nothing : accessors[1]
end

function _collect_appdata_refs!(out::Set{Symbol}, expr)
    expr isa Expr || return
    field = _appdata_top_field(expr)
    field !== nothing && push!(out, field)
    for a in expr.args
        _collect_appdata_refs!(out, a)
    end
end

function _ancestor_chain(T, parent_map)
    chain = Type[T]
    cur = T
    while haskey(parent_map, cur)
        cur = parent_map[cur][1]
        push!(chain, cur)
    end
    chain
end

function _lca_of(types, parent_map)
    isempty(types) && return nothing
    types_arr = collect(types)
    chains = [_ancestor_chain(T, parent_map) for T in types_arr]
    common = reduce(intersect, [Set(c) for c in chains])
    isempty(common) && return nothing
    for T in chains[1]
        T in common && return T
    end
    nothing
end

function _check_appdata_placement!(msgs, root::Type, types_in_tree, parent_map)
    appdata_T = _walk_nested_type(root, :__appdata__)
    appdata_T === nothing && return
    appdata_props = try meta(appdata_T) catch; nothing end
    appdata_props === nothing && return
    # For each AppData property name, collect set of types whose property
    # bodies reference `__appdata__.<name>` (directly or via destructure).
    callers_of = Dict{Symbol, Set{Type}}()
    for U in types_in_tree
        U === appdata_T && continue
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (_, uinfo) in uprops
            uinfo.rhs === nothing && continue
            refs = Set{Symbol}()
            _collect_appdata_refs!(refs, uinfo.rhs)
            for r in refs
                push!(get!(callers_of, r, Set{Type}()), U)
            end
        end
    end
    for (name, info) in appdata_props
        # Only flag structural sub-trees (registered nested types) — primitive
        # config like `server_id::Int = …` doesn't have a "data domain" to move
        # under.
        _walk_nested_type(appdata_T, name) === nothing && continue
        callers = get(callers_of, name, Set{Type}())
        isempty(callers) && continue
        lca = _lca_of(callers, parent_map)
        (lca === nothing || lca === root) && continue
        ncallers = length(callers)
        short = "only referenced from `$(nameof(lca))`'s subtree ($(ncallers) caller$(ncallers == 1 ? "" : "s")) — move under that domain instead of `__appdata__` top"
        long  = "Property `$(nameof(appdata_T)).$name` is at the `__appdata__` top level but every reference goes through types under `$(nameof(lca))`'s subtree. Move it into `$(nameof(lca))`'s data domain (e.g. as a property of a paired data type) so placement matches actual usage."
        push!(msgs, LintMessage(appdata_T, name, :warn, short, long, info.lnn))
    end
end

function _check_redundant_args!(msgs, call_index, parent_map, type, name::Symbol, info)
    pos = _ip_positional_args(info.indices)
    isempty(pos) && return
    sites = get(call_index, name, Vector{Tuple{Type,Symbol,Vector{Any}}}())
    all_caller_args = Vector{Vector{Any}}()
    for (cT, cp, argset) in sites
        (cT === type && cp === name) && continue
        push!(all_caller_args,
              Any[_normalize_arg(a, cT, parent_map) for a in argset])
    end
    isempty(all_caller_args) && return
    redundant = Tuple{Symbol,Any}[]
    for i in eachindex(pos)
        all(length(a) >= i for a in all_caller_args) || continue
        vals = [a[i] for a in all_caller_args]
        all(v -> v == vals[1], vals) || continue
        # Only flag if the value is addressable from the IP's own scope
        # (i.e. `_normalize_dot_chain` resolved it to (BaseType, accessors...)).
        # Raw Symbols / Exprs are caller-locals — IP body can't read them.
        vals[1] isa Tuple || continue
        push!(redundant, (pos[i], vals[1]))
    end
    isempty(redundant) && return
    parts = ["`$n` always passed `$(_show_normalized(v))`" for (n, v) in redundant]
    short = "redundant arg$(length(redundant) == 1 ? "" : "s"): " * join(parts, ", ") *
            " — drop from signature, read directly in body"
    long  = "Across $(length(all_caller_args)) detected call site(s) of `$type.$name(…)`, " *
            "$(length(redundant) == 1 ? "this argument is" : "these arguments are") always " *
            "passed the same expression. Drop $(length(redundant) == 1 ? "it" : "them") from " *
            "the signature and have the body read the value directly via `__self__.…` / " *
            "`__parent__.…`. Refines the same-bound / no-self-access guidance: the bound " *
            "shows what the callers' SCOPES carry; this lint shows what they actually PASS."
    push!(msgs, LintMessage(type, name, :warn, short, long, info.lnn))
end

# --- New: identical-bound siblings (lint #3) -----------------------------
# Group IPs at the SAME scope by bound; if 2+ share a bound, they likely
# belong in one inline child keyed on that shared identity.

function _check_identical_bound_siblings!(msgs, bound_groups, types_in_tree, parent_map)
    for (T, by_bound) in bound_groups
        props = try meta(T) catch; nothing end
        props === nothing && continue
        scope = _enclosing_scope(T, parent_map)
        for (bound, group) in by_bound
            length(group) >= 2 || continue
            # Fire only when the shared bound represents a real upstream
            # identity — i.e. extend BEYOND the type's local scope. Empty
            # bound and bound fully within local scope (e.g. siblings
            # sharing only auto-forwarded `@param`s) have no identity to
            # fold around.
            isempty(bound) && continue
            all(n -> n in scope, bound) && continue
            argstr = join(string.(bound), ", ")
            for member in group
                others = filter(!=(member), group)
                olist = join(map(o -> "`$o`", others), ", ")
                short = "same deps as $olist — fold all $(length(group)) into `@struct shared($argstr) = begin … end`, callers `.shared($argstr).<member>`"
                long  = "`$T.$member(…)` has the same upstream deps `{$argstr}` as $olist. They share an identity that isn't currently modelled; fold them into one inline child keyed on `($argstr)` and expose the per-member derivations as bare properties of it."
                # `metafirst` is fine here: this lint groups properties by
                # bound, and even with future duplicate-name declarations the
                # lnn we want is the first occurrence's.
                info = metafirst(T, member)
                push!(msgs, LintMessage(T, member, :warn, short, long, info.lnn))
            end
        end
    end
end

# --- Top-level analyzer ---------------------------------------------------

"""    analyze_structure(T::Type) -> Vector{LintMessage}

Walk T's DO/HTMXO type tree and run all lint checks. Pure analysis pass —
no side effects, no logging. `print_structure(T)` calls this internally and
weaves the messages inline. Callers wanting CI-style output can iterate the
returned vector themselves.
"""
function analyze_structure(T::Type)
    msgs = LintMessage[]
    types_in_tree = _all_types_in_tree(T)
    parent_map    = _build_parent_map(T)
    wc_cache      = _WCCache()
    bound_groups  = _bound_groups(types_in_tree, parent_map, wc_cache)
    call_index    = _build_call_index(types_in_tree)

    for U in types_in_tree
        props = try meta(U) catch; nothing end
        props === nothing && continue
        oproperties = collect(props)
        prop_names  = Set(first(p) for p in props)
        indexed_names = Set{Symbol}(n for (n, info) in oproperties if info.indexed)
        type_bound  = get(bound_groups, U, Dict{Tuple{Vararg{Symbol}},Vector{Symbol}}())

        # Per-property
        for (n, info) in oproperties
            siblings, bound = _siblings_in_bound(type_bound, n)
            _check_cryptic_arg_names!(msgs, U, n, info)
            _check_no_self_access!(msgs, U, n, info, prop_names, siblings, bound)
            _check_trivial_cached_wrapper!(msgs, U, n, info)
            _check_mmap_cached_conflict!(msgs, U, n, info)
            _check_hierarchical_placement!(msgs, types_in_tree, parent_map, U, n, info, wc_cache)
            _check_redundant_args!(msgs, call_index, parent_map, U, n, info)
            _check_bracket_ip_access!(msgs, U, n, info, prop_names, indexed_names)
        end

        # Struct-level (skip forwarded entries from singleton/prefix views)
        own = [n => info for (n, info) in oproperties
               if info.rhs === nothing || !_is_forwarded(info.rhs)]
        _check_singleton_struct!(msgs, U, own)
        _check_repeated_prefix!(msgs, U, own)
        _check_shared_arg_signature!(msgs, U, own, types_in_tree, parent_map, wc_cache)
    end

    _check_identical_bound_siblings!(msgs, bound_groups, types_in_tree, parent_map)
    _check_appdata_placement!(msgs, T, types_in_tree, parent_map)
    msgs
end

# bond_groups: Type → Dict{bound::Tuple → group::Vector{Symbol}}.
# Computed once per analyze pass; reused by both `_check_no_self_access!`
# (to name same-bound siblings in its message) and
# `_check_identical_bound_siblings!` (for cluster emission).
function _bound_groups(types_in_tree, parent_map, wc_cache=_WCCache())
    out = Dict{Type, Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}}()
    for T in types_in_tree
        props = try meta(T) catch; nothing end
        props === nothing && continue
        by_bound = Dict{Tuple{Vararg{Symbol}}, Vector{Symbol}}()
        for (name, info) in props
            isempty(_ip_positional_args(info.indices)) && continue
            wc = _print_struct_worst_case(types_in_tree, parent_map, T, name, info, wc_cache)
            (wc === nothing || wc[1] !== :bound) && continue
            push!(get!(by_bound, Tuple(wc[2]), Symbol[]), name)
        end
        out[T] = by_bound
    end
    out
end

# For (type, prop), return (siblings, bound) — siblings are other props in
# the same bound group (size ≥2), or empty if prop isn't in any group.
function _siblings_in_bound(type_bonds, name::Symbol)
    for (bound, group) in type_bonds
        name in group || continue
        length(group) >= 2 || continue
        return filter(!=(name), group), collect(bound)
    end
    Symbol[], Symbol[]
end

function compute_property end
function iscached end
function resumes end
function meta end

"""
    metafirst(T, name::Symbol) -> Union{Nothing, NamedTuple}

Return the first info for `name` in `meta(T)`, or `nothing` if absent. Use when you
expect at most one entry and don't care about duplicates.
"""
metafirst(T::Type, name::Symbol) = let m = meta(T)
    for (n, info) in m
        n === name && return info
    end
    nothing
end

"""
    metaall(T, name::Symbol) -> Vector{NamedTuple}

Return all infos for `name` in `meta(T)` in declaration order. Empty if absent.
Use when duplicates are expected (e.g. coexisting route + indexed include).
"""
metaall(T::Type, name::Symbol) = NamedTuple[info for (n, info) in meta(T) if n === name]
"""    _property_description(o, ::Val{name}, args...; kwargs...)

Return a human-readable description for the property `name` with the given arguments.
Override generated per-property when a docstring is present in @dynamicstruct.
Default: "name(arg1,arg2,...; k1=v1,k2=v2)" — kwargs section is omitted when empty.
"""
_property_description(o, ::Val{name}, args...; kwargs...) where {name} = begin
    # Bubble: if `name` is a registered nested-struct property and the
    # nested type carries a user docstring, use that as the description.
    # Inline `@struct child = begin "doc" … end` declarations emit their
    # own per-prop `_property_description` override which wins; bare
    # @include externals and typed properties fall through to here.
    nested = _walk_nested_type(typeof(o), name)
    if nested !== nothing
        desc = _type_description(nested, args...; kwargs...)
        desc !== nothing && return desc
    end
    argstr = join(args, ",")
    kwstr = isempty(kwargs) ? "" : "; " * join(("$k=$v" for (k, v) in kwargs), ",")
    "$name($argstr$kwstr)"
end

"""    _type_description(::Type{T}, args...; kwargs...) -> Union{String,Nothing}

Return a description for an instance of `T` constructed with the given args.
`@dynamicstruct` emits an override for every type it defines that delegates
to `_resolve_type_description(T, args, kwargs)` — this reads the user-attached
docstring (if any) at runtime via `Base.Docs.meta`. Returns `nothing` when
`T` has no user docstring; callers (e.g. `@include`-emitted
`_property_description` overrides) should fall through to a per-property
default in that case.
"""
_type_description(::Type, args...; kwargs...) = nothing

# Runtime: read the user-registered docstring for `T` (if any) and strip it.
# Returns `nothing` when no doc is set — the auto-generated property-list
# fallback installed at line ~2556 lives in `Base.Docs.getdoc(::Type{T})`, NOT
# in `Base.Docs.meta`, so this only fires when the user explicitly attached a
# docstring via `"…"` syntax. Shared by `_resolve_type_description` (which
# formats it with construction args) and the public `type_descriptor`.
function _type_docstring(::Type{T}) where {T}
    binding  = Base.Docs.Binding(parentmodule(T), nameof(T))
    docs_meta = Base.Docs.meta(binding.mod)
    multidoc = get(docs_meta, binding, nothing)
    (multidoc === nothing || isempty(multidoc.docs)) && return nothing
    raw = first(values(multidoc.docs))
    txt = raw isa Base.Docs.DocStr ? join(raw.text, "") : string(raw)
    label = strip(txt)
    isempty(label) ? nothing : label
end

function _resolve_type_description(::Type{T}, args, kwargs) where {T}
    label = _type_docstring(T)
    label === nothing && return nothing
    argstr = join(args, ",")
    kwstr  = isempty(kwargs) ? "" : "; " * join(("$k=$v" for (k, v) in pairs(kwargs)), ",")
    "$label($argstr$kwstr)"
end
"""    _is_property_documented(o, ::Val{name}, args...; kwargs...) -> Bool

Whether the property `name`, called with `args...`, was declared with a docstring.
Used by the Treebars extension's `_default_substatus` as the show-a-label-vs-inline
gate (documented → labelled node; undocumented → bare wrapper the renderer inlines).

`@dynamicstruct` emits a per-declaration method (`true` for documented, `false`
for undocumented) alongside the matching `_property_description` override, so a
property with multiple signatures resolves the right answer PER SIGNATURE via
ordinary Julia dispatch.

The **default** below is the safety net for structs expanded by an OLDER DO that
carry no emitted overrides (Revise does not re-expand already-loaded consumers
when this macro changes): it reproduces the historic name-keyed gate
(`property_doc(metafirst(T, name))`) from the runtime `meta(T)` that every loaded
struct already has — so on those structs nothing regresses, they keep first-sig
behavior, and the per-signature fix rolls in as each is naturally re-expanded.
Distinct from `property_doc(info)`, which reads a single meta entry — this
dispatches on the actual call signature.
"""
_is_property_documented(o, ::Val{name}, args...; kwargs...) where {name} =
    !isnothing(property_doc(metafirst(typeof(o), name)))
is_generated_property(o, name) = false
is_indexed_property(o, name) = false
_disk_cache(o, name) = nothing
"""    _never_cache(o, ::Val{name})

Per-type override: `true` when property `name` carries the declaration-site
`@fresh` marker, meaning its `IndexableProperty` call form `o.name(args…)` must
**never memoize** — it recomputes on every call (the declaration-site dual of
the call-site `@fresh` / `fresh(ip, …)`). The default is `false`; the
`@dynamicstruct` macro emits a `true` method per `@fresh`-marked property. The
IP call form consults this and routes to `fresh` (the uncached `_computeproperty`)
instead of `memoize!`. Method-level, so Revise-safe; constant-foldable so the
call form's branch is free at runtime."""
_never_cache(o, ::Val) = false
"""    _self_named_index(o, ::Val{name})

Per-type override: `true` when one of property `name`'s own index args is also
called `name` — `dataset(dataset::Dataset) = …`. An indexed property normally
gets a kwarg named after itself, defaulting to `__self__.name`, which is how a
body reaches its own `IndexableProperty` (recursion) and how a `@cached` body
receives the partially-loaded disk value to resume from. When an index arg
already binds that name, the kwarg would be a duplicate argument name — a
`syntax:` error at expansion — so it is not emitted, and the resume value has
nowhere to go (the positional shadows it in the body regardless). This trait
tells [`_computeproperty`](@ref) to stop passing it. Default `false`;
constant-foldable."""
_self_named_index(o, ::Val) = false
# The resume kwarg: the loaded (possibly partial, possibly `nothing`) disk value
# handed back to the body under the property's own name, so a `resumes`-enabled
# computation can continue from it. Empty when the property has no such kwarg to
# receive it — passing it anyway is an unsupported-keyword MethodError.
_resume_kw(o, ::Val{name}, rv) where {name} =
    _self_named_index(o, Val(name)) ? NamedTuple() : NamedTuple{(name,)}((rv,))
"""    _remount_opaque_properties(::Type{T})

Names whose generated RHS reaches `__self__` in a way the static dependency
collector cannot attribute to one property. Newly expanded types emit a tuple
(possibly empty). `nothing` identifies an older expansion; [`remount`](@ref)
then conservatively treats every computed property as request-derived.
"""
_remount_opaque_properties(::Type) = nothing
"""    _nested_struct_type(::Type{T}, ::Val{name})

Return the type of the nested struct exposed under property `name` on `T`,
or `nothing` if `name` is not backed by a nested struct. Methods are emitted
by `@dynamicstruct` for every inline `@struct` child, and by `@htmx` for
each `@include` external. Used both by `print_structure` and by
HTMXObjects' route-walking machinery.
"""
_nested_struct_type(::Type, ::Val) = nothing

"""    _analysis_nested_type(::Type{T}, ::Val{name})

Like `_nested_struct_type`, but registered for `prop::T = rhs` typed
computed properties only — the analyzer's tree walk follows them while
HTMXObjects' route walker does not (so typed primitives like
`port::Int = 8080` don't crash route registration on `meta(::Type{Int})`).
"""
_analysis_nested_type(::Type, ::Val) = nothing

"""    option_declarations(::Type{T}) -> Vector{Pair{Symbol,NamedTuple}}

Every `@options(<parameter>) = <domain expression>` declaration in `T`'s body,
in declaration order. A parameter may be declared only once: duplicate
declarations are rejected where the `@dynamicstruct` is defined so reflection
and the generated `__options__(::Val{parameter})` method can never disagree.

`@options` declares *which values a parameter may take*. It is the one thing the
structural descriptors cannot infer: a finite domain is proved by the type only
for `Bool` and `Enum`, and a domain that depends on another input cannot be
proved at all. Both spellings are accepted — `@options(x) = …` (the marker binds
its parenthesized argument, so it sits on the assignment's LHS) and
`@options x = …`.

A declaration lowers to the dunder indexed property `__options__(::Val{x})`, so
the domain is an ordinary lazily computed DO value. Nothing is evaluated at
macro-expansion time and nothing is evaluated by reflection: the expression runs
only when a consumer asks for the value, via [`property_options`](@ref). That is
what lets a domain be written in terms of application functions and data DO
knows nothing about, and it is why the value memoizes and invalidates like every
other property.

This function reports the *declarations*. Each entry's NamedTuple carries:

- `parameter::Symbol` — the input this domain governs. It is matched by *name*
  against every input of `T`: a fixed field, a positional or keyword argument of
  an indexed property, or a fixed field promoted into an operation's `:context`
  inputs. One declaration therefore covers every operation that takes that name.
- `expression` — the declared expression, verbatim and unevaluated.
- `expression_string::String` — `string(expression)`, for display.
- `dependencies::Vector{Symbol}` — the sibling properties/fields the expression
  reads, from the same `dependson` walk every property RHS gets.
- `static::Bool` — `isempty(dependencies)`: `true` when the domain is fixed for
  the type, `false` when it is context-dependent and a consumer must re-read it
  whenever one of `dependencies` changes.
- `source::Symbol` — which declaration form produced this record (`:options`).
- `lnn` — the declaration's `LineNumberNode`, or `nothing`.

The same records reach consumers through the descriptor graph: an input governed
by a declaration reports `domain.kind === :declared` with the record under
`domain.declaration` (see [`property_descriptor`](@ref)). Reading them here is
for whole-type inspection — e.g. a declaration whose parameter no attached input
happens to carry.
"""
option_declarations(::Type) = Pair{Symbol,NamedTuple}[]

# First declaration per parameter name, for descriptor attachment.
function _option_declaration_map(T::Type)
    declarations = option_declarations(T)
    isempty(declarations) && return nothing
    map = Dict{Symbol,NamedTuple}()
    for (parameter, declaration) in declarations
        get!(map, parameter, declaration)
    end
    map
end

"""
    has_option_declaration(T::Type, parameter::Symbol) -> Bool

Whether `T` declares an `@options` domain for `parameter`. The cheap check a
consumer makes before [`property_options`](@ref) — it reads declarations only
and never touches an object.
"""
function has_option_declaration(T::Type, parameter::Symbol)
    declarations = _option_declaration_map(T)
    declarations !== nothing && haskey(declarations, parameter)
end

"""
    property_options(o, parameter::Symbol)

The declared domain for `parameter` **on this object** — the value of the
`@options` expression, computed against `o` and memoized like any other
property. Returns `nothing` when no declaration governs `parameter`.

This is the evaluating half of the option contract, and it needs an object for
the same reason a dependent domain exists at all: `@options(model) =
models_for(study)` is only answerable once `study` is fixed, and `study` is
fixed by `o`. Reflection ([`option_declarations`](@ref),
[`property_descriptor`](@ref)) reports the declaration without running it; this
runs it.

A domain is any value supporting `in` — a vector of nodes, a range, an
interval, a type. What a consumer does with it (membership check, control
choice, rejecting a submission made against a stale domain) is the consumer's;
DO neither interprets the value nor caches a rendering of it.
"""
property_options(o, parameter::Symbol) =
    has_option_declaration(typeof(o), parameter) ?
        getproperty(o, :__options__)(Val(parameter)) : nothing

"""
    OptionDomain

A domain that carries a human label next to each machine value. Construct one
with [`option_domain`](@ref); read the labels back with [`option_records`](@ref).

It *is* a collection of the machine values: it iterates them, `length` counts
them, and `in` compares against them. A consumer that already treats a domain as
"any value supporting `in`" therefore needs no change — the labels ride along
without entering the membership test.
"""
struct OptionDomain{V<:AbstractVector,O<:AbstractVector{<:NamedTuple}}
    values::V
    options::O
end

Base.in(value, domain::OptionDomain) = value in domain.values
Base.iterate(domain::OptionDomain, state...) = iterate(domain.values, state...)
Base.length(domain::OptionDomain) = length(domain.values)
Base.eltype(::Type{<:OptionDomain{V}}) where {V} = eltype(V)
Base.show(io::IO, domain::OptionDomain) = print(io, "option_domain([",
    join(("$(repr(option.value)) => $(repr(option.label))" for option in domain.options), ", "),
    "])")

"""
    option_domain(values) -> OptionDomain

An `@options` domain whose values carry human labels. The labels travel *with*
the values, in one declaration, so they can never disagree about how many
options there are or what order they are in.

```julia
@dynamicstruct struct Gallery
    study::Symbol
    dose::Float64

    @options(study) = option_domain([
        :synthetic_depot_v1       => "Sparse depot PK",
        :synthetic_depot_dense_v1 => "Dense depot PK",
    ])
    @options(dose) = option_domain(d => "\$(Int(d)) mg" for d in doses_for(study))
end
```

Each element is normalized to the same option record `static_domain` produces —
`(; value, label, group, help, disabled)` — from any of three spellings:

- `value => label`, the usual case;
- a `NamedTuple` with a `value` field plus any of `label`, `group`, `help`,
  `disabled` (`label` defaults to `string(value)`); or
- a bare value, which takes the default label.

Nothing else about `@options` changes. The declaration is still an ordinary
lazily computed property, so a *dependent* domain works exactly as before —
`dose`'s labels are recomputed with `dose`'s values whenever `study` changes.
Membership is still on machine values: `o.study in property_options(o, :study)`
is true for the same values a bare vector would have accepted, which is why a
domain may be labelled without touching validation.

Labels are deliberately *not* on the descriptor's `domain`: an `@options` domain
may depend on the object, so its labels are per-object too, and reflection never
evaluates a declaration ([`option_declarations`](@ref)). `domain.kind` stays
`:declared` with `options` empty; a renderer reads the labels from the evaluated
value via [`property_options`](@ref) + [`option_records`](@ref).
"""
function option_domain(values)
    options = NamedTuple[_option_descriptor(value) for value in values]
    OptionDomain(map(option -> option.value, options), options)
end

"""
    option_records(domain) -> Vector{NamedTuple} or nothing

The option records of an evaluated domain — one `(; value, label, group, help,
disabled)` per value, in domain order. This is the one call a renderer makes; it
does not care how the domain was spelled:

```julia
for option in option_records(property_options(object, :study))
    radio(option.value; label=option.label, checked=(option.value == object.study))
end
```

An [`option_domain`](@ref) returns its declared labels. Any other finite
collection — a vector, tuple, range, or `Set` — is normalized with default
labels (`string(value)`), so an unlabelled `@options` declaration still renders.
Returns `nothing` for a domain that is not a finite collection (a type, an
interval): there is no list to render, and the consumer falls back to a free
input.
"""
option_records(domain::OptionDomain) = domain.options
function option_records(domain)
    (applicable(iterate, domain) && applicable(length, domain)) || return nothing
    NamedTuple[_option_descriptor(value) for value in domain]
end

# Union of both hooks for analyzer + render code paths. `_nested_struct_type`
# wins if both are defined for the same property (shouldn't normally happen).
function _walk_nested_type(T, name::Symbol)
    t = _nested_struct_type(T, Val(name))
    t !== nothing && return t
    _analysis_nested_type(T, Val(name))
end
extractnames(x::Vector) = mapreduce(extractnames, union, x; init=Set())
extractnames(x::Symbol) = Set((x,))
extractnames(x::Expr) = if Meta.isexpr(x, :(::))
    extractnames(length(x.args) == 1 ? Symbol("") : x.args[1])
elseif Meta.isexpr(x, :kw)
    @assert length(x.args) == 2
    extractnames(x.args[1])
elseif Meta.isexpr(x, (:tuple, :parameters, :(...)))
    extractnames(x.args)
else
    dump(x)
    error("Don't know how to handle $x")
end
fixcall(x) = x
fixcall(x::Expr) = if Meta.isexpr(x, :call)
    f = x.args[1]
    # Collect keyword args in two passes: fixed kwargs first, splats (kwargs...) last.
    # This is necessary because the new Expr-based method generation may merge multiple
    # :parameters nodes (e.g. one from info.indices containing `kwargs...` and one from
    # cp_kwargs containing `name=val`). Julia requires splat kwargs to be final, so we
    # sort them to the end regardless of which :parameters node they originated from.
    pargs_fixed = []
    pargs_splat = []
    args = []
    for arg in fixcall.(x.args[2:end])
        if Meta.isexpr(arg, :parameters)
            for a in arg.args
                Meta.isexpr(a, :(...)) ? push!(pargs_splat, a) : push!(pargs_fixed, a)
            end
        else
            push!(args, arg)
        end
    end
    Expr(x.head, f, Expr(:parameters, pargs_fixed..., pargs_splat...), args...)
else
    Expr(x.head, fixcall.(x.args)...)
end
# Unwrap a `GlobalRef(M, :@name)` to its bare `:@name` Symbol. Macro names
# arrive as either form depending on whether the macrocall came through
# Julia's docstring lowering or a direct user write.
_resolve_macro_name(m::GlobalRef) = m.name
_resolve_macro_name(m) = m

# Property names introduced by an `arg`'s LHS — bare symbols, typed
# fields, and tuple destructures. Inline structs and other shapes
# contribute none. Used to assemble `parent_props` in `dynamicstruct`.
_collect_lhs_names(::Any) = ()
_collect_lhs_names(lhs::Symbol) = (lhs,)
_collect_lhs_names(lhs::Expr) =
    Meta.isexpr(lhs, :tuple) ? Tuple(_collect_destructure_names(lhs)) : ()

# Render a stored docstring back to a String for the auto-generated
# property listing. Strings pass through; anything else (an `Expr` from
# string interpolation) gets `show_unquoted` to recover the source.
_doc_to_string(doc::AbstractString) = doc
_doc_to_string(doc) = sprint(Base.show_unquoted, doc)

# Build the extraction RHS for one member of a destructuring assignment.
# Symbol source → `extract_from.source`; integer index → `extract_from[i]`.
_extract_member(extract_from, source::Symbol) = Expr(:., extract_from, QuoteNode(source))
_extract_member(extract_from, source) = :($extract_from[$source])

# Replace `LineNumberNode` markers in a block with `lnn` (used by
# `setlnn` to rewrite line tags onto user-supplied locations); leave
# everything else untouched.
_replace_lnn(::LineNumberNode, lnn) = lnn
_replace_lnn(x, _) = x

# Property-macro accumulator: doc / cache_version / macros are the
# pieces of state the body-args parser threads through the
# `while Meta.isexpr(arg, :macrocall)` peeling loop. Bundling them into a
# small mutable struct lets per-macro logic live in dispatched methods of
# `_apply_property_macro!` (one method per macro shape) instead of in
# branch arms inside the loop body.
mutable struct _PropertyMacroState
    doc::Any
    cache_version::Any
    macros::Set{Symbol}
end

# Default: register the macro name in `state.macros` and unwrap to the
# inner expression so the loop continues peeling.
_apply_property_macro!(state::_PropertyMacroState, ::Val{name}, arg) where {name} =
    (push!(state.macros, name); arg.args[end])

# `@doc "str" <def>` — silently consume (don't push to macros) and capture
# the docstring. `length(arg.args) >= 4` matches Julia's lowered shape
# (`(:macrocall, :@doc, LNN, "str", <def>)`); shorter forms fall back to
# the default behavior.
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@doc")}, arg)
    if length(arg.args) >= 4
        docexpr = arg.args[end-1]
        (docexpr isa AbstractString || Meta.isexpr(docexpr, :string)) && (state.doc = docexpr)
        return arg.args[end]
    end
    push!(state.macros, Symbol("@doc"))
    arg.args[end]
end

# Capture an optional leading version tag (`@m v"N" <prop> = …` → length 4,
# version at `arg.args[3]`). Shared by the disk-cache markers `@cached` and
# `@mmap` so `v"N"` busts the cache identically for both formats.
_capture_cache_version!(state::_PropertyMacroState, arg) =
    length(arg.args) == 4 && (state.cache_version = _parse_cache_version(arg.args[3]))

# `@cached <prop> = …` (length 3) or `@cached v"…" <prop> = …` (length 4
# with a version argument).
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@cached")}, arg)
    push!(state.macros, Symbol("@cached"))
    _capture_cache_version!(state, arg)
    arg.args[end]
end

# `@mmap <prop>::T = …` (length 3) or `@mmap v"…" <prop>::T = …` (length 4).
# Mirrors `@cached`: `@mmap` owns a disk-cache path too, so a `v"N"` tag must
# bump `cache_version` the same way (otherwise the version is silently dropped
# by the generic handler — the disk path is shared, only the format differs).
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@mmap")}, arg)
    push!(state.macros, Symbol("@mmap"))
    _capture_cache_version!(state, arg)
    arg.args[end]
end

# Semantic descriptors are inferred from the ordinary property graph.  Reject
# the former metadata macro explicitly so stale consumers get a useful error
# instead of silently carrying an inert marker.
_apply_property_macro!(::_PropertyMacroState, ::Val{Symbol("@semantic")}, _) =
    error("@semantic was removed: DynamicObjects now reflects ordinary fields, property signatures, inferred dependencies, result annotations, Bool/Enum types, and cache markers directly")

# `@options <parameter> = <domain expression>` — an option-domain declaration,
# not a property. Captured here and consumed by the body loop, which routes it
# into `option_declarations(T)` instead of emitting a property. Takes no
# argument of its own, so anything but the bare 3-arg form is a mistake.
function _apply_property_macro!(state::_PropertyMacroState, ::Val{Symbol("@options")}, arg)
    length(arg.args) == 3 ||
        error("@options takes no arguments: write `@options <parameter> = <domain expression>`, got `$arg`")
    push!(state.macros, Symbol("@options"))
    arg.args[end]
end
_parse_cache_version(v::VersionNumber) = v
function _parse_cache_version(ver_expr::Expr)
    Meta.isexpr(ver_expr, :macrocall) && ver_expr.args[1] == Symbol("@v_str") ||
        error("cache version argument must be a version string like v\"2\", got: $ver_expr")
    VersionNumber(ver_expr.args[end])
end
_parse_cache_version(x) =
    error("cache version argument must be a version string like v\"2\", got: $x")

# Body-args metadata absorber: LineNumberNode / String / `:string` Expr
# args are not properties — they update the `lnn` / `doc` accumulators
# the next real property will pick up. Per-type method dispatch replaces
# the `if arg isa LineNumberNode … end; if arg isa String || Meta.isexpr
# (arg, :string) …` chain at the top of the body-args loop. Returns
# `true` when the arg was absorbed (caller `continue`s) and `false`
# otherwise. `ctx` is a NamedTuple of `lnn::Ref` / `doc::Ref`.
_absorb_body_metadata!(_, _) = false
_absorb_body_metadata!(arg::LineNumberNode, ctx) = (ctx.lnn[] = arg; true)
_absorb_body_metadata!(arg::AbstractString, ctx) = (ctx.doc[] = arg; true)
function _absorb_body_metadata!(arg::Expr, ctx)
    arg.head === :string || return false
    ctx.doc[] = arg; true
end

# Normalise a `let` binding: a bare Symbol `x` becomes `x = x` (so the
# rest of the let-walker can treat every binding as an `Expr(:(=), …)`),
# already-`=`-shaped bindings pass through.
_normalize_let_binding(arg::Symbol) = Expr(:(=), arg, arg)
_normalize_let_binding(arg) = arg

# Names from an `lhs` that would shadow a property when assigned. Plain symbols
# match if they name a property and aren't already declared local; tuples
# expand to their symbol leaves; anything else can't shadow.
_shadowed_lhs(_, _, _) = Symbol[]
_shadowed_lhs(lhs::Symbol, properties, locals) =
    (lhs in properties) && !(lhs in locals) ? [lhs] : Symbol[]
function _shadowed_lhs(lhs::Expr, properties, locals)
    lhs.head === :tuple || return Symbol[]
    out = Symbol[]
    for s in lhs.args
        append!(out, _shadowed_lhs(s, properties, locals))
    end
    out
end

_collect_leaves(e) = error("unsupported destructuring element: $e")
_collect_leaves(e::Symbol) = Symbol[e]
function _collect_leaves(e::Expr)
    e.head === :(::) && return Symbol[e.args[1]]
    e.head === :tuple && return mapreduce(_collect_leaves, append!, e.args; init=Symbol[])
    error("unsupported destructuring element: $e")
end
_emit_positional_destructure!(oproperties, docs, elements, source_sym, lnn) = for (i, a) in enumerate(elements)
    _emit_positional_element!(oproperties, docs, a, i, source_sym, lnn)
end
_emit_positional_element!(_, _, a, _, _, _) = error("unsupported destructuring element: $a")
_emit_positional_element!(oproperties, docs, a::Symbol, i, source_sym, lnn) =
    _push_positional_leaf!(oproperties, docs, a, i, source_sym, lnn)
function _emit_positional_element!(oproperties, docs, a::Expr, i, source_sym, lnn)
    a.head === :(::) && return _push_positional_leaf!(oproperties, docs, a.args[1], i, source_sym, lnn)
    a.head === :tuple || error("unsupported destructuring element: $a")
    inner_leaves = _collect_leaves(a)
    inner_name = Symbol("_tuple_", join(inner_leaves, "_"))
    inner_locals = Set{Symbol}(inner_leaves); push!(inner_locals, inner_name)
    push!(oproperties, inner_name => (;lhs=inner_name, macros=Set{Symbol}(), rhs=:($source_sym[$i]), lnn, dependson=Set{Symbol}(), locals=inner_locals, indices=tuple(), indexed=false, cache_version=nothing, result_type=nothing, doc=nothing))
    push!(docs, (inner_name => (nothing, true)))
    _emit_positional_destructure!(oproperties, docs, a.args, inner_name, lnn)
end
function _push_positional_leaf!(oproperties, docs, leaf::Symbol, i, source_sym, lnn)
    push!(oproperties, leaf => (;lhs=leaf, macros=Set{Symbol}(), rhs=:($source_sym[$i]), lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([leaf]), indices=tuple(), indexed=false, cache_version=nothing, result_type=nothing, doc=nothing))
    push!(docs, (leaf => (nothing, true)))
end
# One element of a named-destructure LHS: either a bare Symbol leaf or a
# `target <= source` rename (Symbol or :tuple source). Anything else is
# silently ignored — the main parsing loop already errors on bad shapes.
_collect_destructure_named!(_, _) = nothing
_collect_destructure_named!(names, a::Symbol) = (push!(names, a); nothing)
function _collect_destructure_named!(names, a::Expr)
    a.head === :call && a.args[1] == :(<=) || return nothing
    _collect_destructure_renamed!(names, a.args[2], a.args[3])
    nothing
end
_collect_destructure_renamed!(_, _, _) = nothing
_collect_destructure_renamed!(names, target::Symbol, ::Symbol) = (push!(names, target); nothing)
function _collect_destructure_renamed!(names, target::Symbol, source::Expr)
    source.head === :tuple || return nothing
    prefix = string(target)
    for s in source.args
        _push_prefixed_name!(names, prefix, s)
    end
    nothing
end
_push_prefixed_name!(_, _, _) = nothing
_push_prefixed_name!(names, prefix, s::Symbol) = (push!(names, Symbol(prefix, s)); nothing)

# Body-loop sibling of the `_collect_destructure_*` family: same per-shape
# dispatch, but pushes `target => source-or-prefixed-name` pairs into the
# `members::Vector{Pair{Symbol,Any}}` accumulator the main loop hands to
# `extract_from`. Replaces the inner `if a isa Symbol … elseif Meta.isexpr(a, :call)
# && a.args[1] == :(<=) …` arms in the destructure-handling block.
_emit_named_member!(_, _) = nothing
_emit_named_member!(members, a::Symbol) = (push!(members, a => a); nothing)
function _emit_named_member!(members, a::Expr)
    a.head === :call && a.args[1] == :(<=) || return nothing
    _emit_renamed_member!(members, a.args[2], a.args[3])
    nothing
end
_emit_renamed_member!(_, _, _) = nothing
_emit_renamed_member!(members, target::Symbol, source::Symbol) =
    (push!(members, target => source); nothing)
function _emit_renamed_member!(members, target::Symbol, source::Expr)
    source.head === :tuple || return nothing
    prefix = string(target)
    for s in source.args
        _push_prefixed_member!(members, prefix, s)
    end
    nothing
end
_push_prefixed_member!(_, _, _) = nothing
_push_prefixed_member!(members, prefix, s::Symbol) =
    (push!(members, Symbol(prefix, s) => s); nothing)

# Flatten a destructuring LHS to the property names it introduces. Mirrors the
# main property-parsing loop (`:tuple` branch): positional → per-index leaves
# (recursing into nested tuples), named → per-member name with `<=` rename and
# prefix-tuple expansion. Used by `parent_props` collection so inline children
# auto-forward destructured parent properties the same way as bare ones.
_collect_destructure_names(lhs) = begin
    names = Symbol[]
    Meta.isexpr(lhs, :tuple) || return names
    named = length(lhs.args) == 1 && Meta.isexpr(lhs.args[1], :parameters)
    raw_args = named ? lhs.args[1].args : lhs.args
    if named
        for a in raw_args
            _collect_destructure_named!(names, a)
        end
    else
        append!(names, _collect_leaves(lhs))
    end
    names
end
# Name of a single kwarg in a `:parameters` block: bare `Symbol`s are
# their own name, `Expr(:kw, name, default)` carries the name as
# `args[1]`, anything else has no name. Per-type methods replace the
# `kw isa Symbol ? … : (Meta.isexpr(kw, :kw) ? … : nothing)` ternary.
_kwarg_name(kw::Symbol) = kw
_kwarg_name(kw::Expr) = Meta.isexpr(kw, :kw) ? kw.args[1] : nothing
_kwarg_name(_) = nothing

# Name of a keyword argument written BEFORE the semicolon: Julia parses
# `Child(__status__ = nothing)` as an `Expr(:kw, …)` sitting in the positional
# argument list. There, and unlike inside a `:parameters` block, a bare `Symbol`
# is a positional VALUE — `Child(x)` passes `x`, it is not the `f(; x)`
# shorthand — so only an `Expr(:kw, …)` names a kwarg.
_positional_kwarg_name(a) = Meta.isexpr(a, :kw) ? a.args[1] : nothing

function _inject_include_kwargs!(call_expr, prop_name)
    params_idx = findfirst(a -> Meta.isexpr(a, :parameters), call_expr.args)
    if params_idx === nothing
        params = Expr(:parameters)
        insert!(call_expr.args, 2, params)
    else
        params = call_expr.args[params_idx]
    end
    has_parent = false
    has_status = false
    # A kwarg can arrive in either of two places, and both mean the same thing
    # to the callee: after the semicolon (the `:parameters` block) or before it
    # (an `Expr(:kw, …)` among the positional args). Scanning only `:parameters`
    # missed `Child(__status__ = nothing)`, injected a second `__status__`, and
    # the call site died with `keyword argument "__status__" repeated` — right
    # on the escape hatch for silencing a subtree's progress.
    for name in Iterators.flatten((
            (_kwarg_name(kw) for kw in params.args),
            (_positional_kwarg_name(a) for a in call_expr.args)))
        name === :__parent__ && (has_parent = true)
        name === :__status__ && (has_status = true)
    end
    has_parent || push!(params.args, Expr(:kw, :__parent__, :__self__))
    # Mounts the child under the parent's tree by OVERRIDING whatever
    # `__status__` default the child type declares — a constructor kwarg seeds
    # the PropertyCache, and that is how every property override works here.
    # `has_status` means the call site already said what it wants, so it wins:
    # `@include kid = Child(; __status__ = nothing)` silences the subtree.
    has_status || push!(params.args, Expr(:kw, :__status__,
        Expr(:call, compute_property, :__self__, :(Val(:__substatus__)), QuoteNode(prop_name))))
    call_expr
end

function _process_include_externals!(body)
    # Returned: (prop_name, type_expr) for each `@include`'d external. Used
    # to emit `_analysis_nested_type` so `analyze_structure` walks the
    # included type's tree even when the enclosing struct is
    # `@dynamicstruct` (and therefore HTMXObjects' route walker — which
    # would otherwise emit `_nested_struct_type` — never runs). For `@htmx`
    # structs HTMXObjects also emits `_nested_struct_type`, which
    # `_walk_nested_type` queries first; the duplicate `_analysis_nested_type`
    # entry is redundant but harmless.
    externals = Pair{Symbol, Any}[]
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        expr = arg
        parent_expr = nothing
        while Meta.isexpr(expr, :macrocall) && expr.args[1] != Symbol("@include")
            parent_expr = expr
            expr = expr.args[end]
        end
        Meta.isexpr(expr, :macrocall) && expr.args[1] == Symbol("@include") || continue
        inner = expr.args[end]
        Meta.isexpr(inner, :(=)) || continue
        lhs = inner.args[1]
        rhs = inner.args[2]
        # `@include name = begin … end` (inline sub-router) is an HTMXObjects
        # construct: under `@htmx`, `_convert_include_to_struct!` replaces the
        # block form with a `prop = struct …` inline child BEFORE `dynamicstruct`
        # runs, so a block-RHS `@include` reaching here means a plain
        # `@dynamicstruct` (no routes to mount). Silently degrading it to a
        # block-RHS property is a footgun — `o.name.subfield` then fails at
        # runtime (decision 2026-06-15T00-08-54-324-u2us9y). Error with the
        # route-less fix: `@struct`, which DO already lowers to an inline child.
        if Meta.isexpr(rhs, :block)
            error("`@include $lhs = begin … end` (inline sub-router) is only supported under `@htmx`. A plain `@dynamicstruct` has no routes to mount — use `@struct $lhs = begin … end` for a route-less inline sub-struct.")
        end
        Meta.isexpr(rhs, :call) || continue
        # LHS is a bare prop name `prop` for the classic non-indexed form, or a
        # call expression `prop(args…)` for the indexed-include form
        # (`@include foo(x, y) = External(x, y)`). Either way, the LHS expression
        # is preserved verbatim in the rewritten assignment so DO sees the
        # property as either bare or indexed accordingly.
        prop_name = if lhs isa Symbol
            lhs
        elseif Meta.isexpr(lhs, :call) && lhs.args[1] isa Symbol
            lhs.args[1]
        else
            continue
        end
        type_expr = rhs.args[1]
        push!(externals, prop_name => type_expr)
        _inject_include_kwargs!(rhs, prop_name)
        assignment = :($lhs = $rhs)
        if isnothing(parent_expr)
            body.args[i] = assignment
        else
            parent_expr.args[end] = assignment
        end
    end
    externals
end

# Find the call node inside a standard method signature. Julia wraps calls in
# `:where` and/or `:(::)` for type parameters and return annotations; preserving
# those wrappers is what lets inline methods support the same signature forms as
# ordinary methods.
_inline_method_call(_) = nothing
function _inline_method_call(sig::Expr)
    Meta.isexpr(sig, :call) && return sig
    Meta.isexpr(sig, (:where, :(::))) || return nothing
    _inline_method_call(sig.args[1])
end

function _collect_inline_where_params!(params, sig)
    sig isa Expr || return params
    if Meta.isexpr(sig, :where)
        append!(params, sig.args[2:end])
        _collect_inline_where_params!(params, sig.args[1])
    elseif Meta.isexpr(sig, :(::))
        _collect_inline_where_params!(params, sig.args[1])
        length(sig.args) >= 2 && _collect_inline_where_params!(params, sig.args[2])
    end
    params
end

# Detect an inline-method signature carrying `__self__` (short or long form,
# with `where` clauses, return annotations, qualified function names such as
# `Base.show`, and `__self__` at any positional index). Returns the original
# signature plus the argument metadata needed for body walking, or `nothing`
# when this isn't a method-shaped definition with a positional `__self__`.
_detect_inline_method_lhs(_) = nothing
function _detect_inline_method_lhs(lhs::Expr)
    call = _inline_method_call(lhs)
    isnothing(call) && return nothing
    where_params = Any[]
    _collect_inline_where_params!(where_params, lhs)
    length(call.args) >= 2 || return nothing
    sig_args = collect(call.args[2:end])
    self_idx = nothing
    for (i, a) in enumerate(sig_args)
        Meta.isexpr(a, :parameters) && continue
        a_sym = a
        Meta.isexpr(a_sym, :(::)) && (a_sym = a_sym.args[1])
        if a_sym === :__self__
            self_idx = i
            break
        end
    end
    isnothing(self_idx) && return nothing
    (; signature=lhs, sig_args, where_params, self_idx)
end

dynamicstruct(expr; docstring=nothing, child_handler=nothing, is_child=false, lint=true) = begin
    # Short-form sugar: `T(arg1::T1, arg2::T2) = begin … end` is shorthand
    # for `struct T; arg1::T1; arg2::T2; … end`. Positional args become
    # fixed/constructor fields. `;`-separated kwargs become regular DO
    # properties — bare `kw` errors at access time if the construction
    # kwarg wasn't supplied; `kw=default` makes the default the property
    # RHS (overridable via the same kwarg at construction). Standard Julia
    # docstrings bind to `T` via `Base.@__doc__` exactly like the long form.
    if Meta.isexpr(expr, :(=)) && length(expr.args) == 2 &&
       Meta.isexpr(expr.args[1], :call) &&
       Meta.isexpr(expr.args[2], :block)
        call = expr.args[1]
        body_block = expr.args[2]
        type_name = call.args[1]
        type_args = call.args[2:end]
        body_extras = Any[]
        positional = Any[]
        for a in type_args
            if Meta.isexpr(a, :parameters)
                for kw in a.args
                    if kw isa Symbol
                        msg = "$(type_name)(; $kw, …): required kwarg `$kw` was not provided at construction."
                        push!(body_extras, Expr(:(=), kw, :($error($msg))))
                    elseif Meta.isexpr(kw, :kw, 2)
                        push!(body_extras, Expr(:(=), kw.args[1], kw.args[2]))
                    else
                        error("@dynamicstruct $type_name(...): unsupported kwarg form `$kw` in short-form signature. Use `name` (required) or `name=default`.")
                    end
                end
            else
                push!(positional, a)
            end
        end
        expr = Expr(:struct, false, type_name,
                    Expr(:block, positional..., body_extras..., body_block.args...))
    end
    @assert expr.head == :struct
    mut, head, body = expr.args
    type = head
    Meta.isexpr(type, :(<:)) && (type = type.args[1])
    Meta.isexpr(type, :(curly)) && (type = type.args[1])
    @assert body.head == :block
    # --- Rewrite `@struct prop[(idx...)] = begin body end` into the equivalent
    # `prop[(idx...)] = struct <auto-named> body end` so the Form 1 path picks
    # it up. `@struct` is not a real macro — it's a marker handled here.
    # Also peels a `Core.@doc "str" @struct …` wrapper so docstrings on
    # `@struct` properties survive the rewrite (Julia's parser auto-wraps
    # `"str"\n<def>` inside any `:struct` body, including @dynamicstruct's).
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        # Peel a `Core.@doc "str" <inner>` wrapper if present.
        doc_wrapper = nothing
        macro_arg = arg
        if Meta.isexpr(macro_arg, :macrocall)
            mname = macro_arg.args[1]
            mname = _resolve_macro_name(mname)
            if mname === Symbol("@doc") && length(macro_arg.args) >= 4
                doc_wrapper = macro_arg
                macro_arg = macro_arg.args[end]
            end
        end
        # Peel a leading `@fresh` wrapper. `@fresh @struct …` parses as
        # `@fresh(@struct(…))`, so without this the `@struct` marker below is
        # never seen and the inline-child rewrite is skipped. We rewrite the
        # inner `@struct` and re-attach `@fresh` (at the `rewritten` re-wrap
        # below) to the emitted `prop = struct …` form, so `@fresh` lands on the
        # constructor property and marks it never-cache — the call form then
        # builds a FRESH child on every call. Only `@fresh` is peeled here; a
        # disk-cache marker (`@cached`/`@mmap`) on `@struct` stays unsupported
        # and is rejected at the `@struct in info.macros` guard downstream.
        fresh_wrapper = nothing
        if Meta.isexpr(macro_arg, :macrocall) &&
           _resolve_macro_name(macro_arg.args[1]) === Symbol("@fresh")
            fresh_wrapper = macro_arg
            macro_arg = macro_arg.args[end]
        end
        Meta.isexpr(macro_arg, :macrocall) || continue
        macro_arg.args[1] == Symbol("@struct") || continue
        inner = macro_arg.args[end]
        Meta.isexpr(inner, :(=)) ||
            error("@struct: expected `prop = begin ... end` or `prop(idx...) = begin ... end`, got $(macro_arg)")
        lhs = inner.args[1]
        rhs = inner.args[2]
        Meta.isexpr(rhs, :block) ||
            error("@struct: RHS must be a `begin ... end` block, got $(rhs)")
        prop_sym = Meta.isexpr(lhs, :call) ? lhs.args[1] : lhs
        prop_sym isa Symbol ||
            error("@struct: LHS must be `prop` or `prop(idx...)`, got $(lhs)")
        # `@struct prop(args) = body` parses with body wrapped in `:block`,
        # so the `:block` check above passes for the short-form misuse
        # `@struct prop(args) = ExternalCtor(args)` (where the block holds a
        # single bare call). `@struct` always requires an explicit
        # `begin … end` declaring the child's properties — without this
        # check, the downstream args-parsing loop crashes on the bare call
        # with `union!(::Nothing, ::Set{Any})`.
        rhs_stmts = [a for a in rhs.args if !(a isa LineNumberNode)]
        if length(rhs_stmts) == 1 && !Meta.isexpr(rhs_stmts[1], (:(=), :macrocall, :struct, :tuple))
            error("@struct $prop_sym: body must be an explicit `begin ... end` declaring the child's properties. Got a single bare expression `$(rhs_stmts[1])` — likely a short-form misuse like `@struct $lhs = ExternalCtor(...)`. Rewrite as `@struct $lhs = begin ... end` with the child's properties inline.")
        end
        gen_child_name = Symbol(prop_sym, "_inline")
        rewritten = Expr(:(=), lhs, Expr(:struct, false, gen_child_name, rhs))
        # Re-attach `@fresh` (peeled above) so it rides the rewritten form into
        # the extraction loop and, ultimately, onto the constructor property.
        isnothing(fresh_wrapper) ||
            (rewritten = Expr(:macrocall, fresh_wrapper.args[1:end-1]..., rewritten))
        body.args[i] = isnothing(doc_wrapper) ? rewritten :
            Expr(:macrocall, doc_wrapper.args[1:end-1]..., rewritten)
    end
    # --- Process @include external structs ---
    # Returned (prop, type) pairs feed `_analysis_nested_type` so the
    # analyzer walks @include'd externals even when the enclosing struct
    # is `@dynamicstruct` (no HTMXObjects route walker = no
    # `_nested_struct_type` for these unless we add it here).
    include_externals_pairs = _process_include_externals!(body)
    # --- Extract inline struct definitions ---
    # Collect parent property names (excluding inline structs themselves)
    parent_props = Symbol[]
    for arg in body.args
        arg isa LineNumberNode && continue
        a = arg
        while Meta.isexpr(a, :macrocall); a = a.args[end]; end
        # Inline structs become regular parent properties after the
        # extraction loop below (the `prop[(idx)]` forms → an
        # IndexableProperty, the bare form → a plain property). Their
        # parent-property names MUST be collected here so a sibling inline
        # `@struct` can reference them by bare name — those names are
        # forwarded into each child scope via `(; …) = __parent__` (Bruno
        # qt/fit: `ppc_view`'s body calls `dense_view(…)`). The
        # `prop = struct …` / `prop(idx) = struct …` forms carry the name
        # on the LHS and fall through to the generic collector below; the
        # bare `struct Name … end` form carries it as the struct name.
        # (A child never forwards its OWN name — guarded at the `forwarded`
        # comprehension below, not here.)
        if Meta.isexpr(a, :struct)
            _push_if_symbol!(parent_props, a.args[2])
            continue
        end
        lhs = if Meta.isexpr(a, :(=))
            a.args[1]
        else
            a  # fixed field: bare symbol or typed symbol
        end
        Meta.isexpr(lhs, (:call, :ref)) && (lhs = lhs.args[1])
        Meta.isexpr(lhs, :(::)) && (lhs = lhs.args[1])
        # `_collect_lhs_names` dispatches: bare Symbol → (sym,), tuple
        # destructure → recursive name collection, anything else → ().
        # Each new shape is a method, not another `if` arm.
        append!(parent_props, _collect_lhs_names(lhs))
    end
    extracted_structs = Expr[]
    # Parallel record of (parent-property-name => generated-child-type-name) for
    # each inline `@struct` child, used to emit `_nested_struct_type` methods so
    # `print_structure` can walk the inline-child tree.
    inline_child_pairs = Pair{Symbol,Any}[]
    # Typed computed properties (`prop::T = rhs`) register T only with
    # `_analysis_nested_type` (not `_nested_struct_type`), so the analyzer's
    # tree walk follows them but HTMXObjects' route walker doesn't (typed
    # primitives like `port::Int = 8080` would otherwise crash route
    # registration on `meta(::Type{Int})`).
    analysis_child_pairs = Pair{Symbol,Any}[]
    append!(analysis_child_pairs, include_externals_pairs)
    for (i, arg) in enumerate(body.args)
        arg isa Expr || continue
        # Peel a `Core.@doc "str" <inner>` wrapper if present, so that
        # `"docstring"\n@struct prop(args) = …` (which pass 1 has already
        # rewritten to `Core.@doc "str" (prop(args) = struct gen … end)`)
        # is recognised as Form 1a here. The wrapper is reattached to the
        # constructor assignment at the end so the third pass picks the
        # docstring up via its `@doc` unwrap and routes it into
        # `_property_description`.
        doc_wrapper = nothing
        form_arg = arg
        if Meta.isexpr(form_arg, :macrocall)
            mname = form_arg.args[1]
            mname = _resolve_macro_name(mname)
            if mname === Symbol("@doc") && length(form_arg.args) >= 4
                doc_wrapper = form_arg
                form_arg = form_arg.args[end]
            end
        end
        # Peel a `@fresh` wrapper (pass-1 re-attached it around the rewritten
        # `prop = struct …` form). Peeling it lets Form 1/2 detection below match
        # the inline child; it is re-attached to `constructor_assignment` at the
        # end so `@fresh` reaches the property-info collector and emits
        # `_never_cache` for the constructor property (→ fresh child per call).
        fresh_wrapper = nothing
        if Meta.isexpr(form_arg, :macrocall) &&
           _resolve_macro_name(form_arg.args[1]) === Symbol("@fresh")
            fresh_wrapper = form_arg
            form_arg = form_arg.args[end]
        end
        prop_name = nothing
        child_struct = nothing
        index_params = Symbol[]
        # Parallel list to `index_params` preserving the raw positional-arg
        # expression (`:name` or `:(name::T)`). Used only when emitting the
        # parent property's method signature so `info.indices` carries the
        # type annotation for downstream readers (notably HTMXObjects'
        # `_nested_prefix_and_step`, which feeds URL-segment conversion).
        index_param_exprs = Any[]
        # (name, default_or_nothing) — `nothing` here means "no user-supplied
        # default" (required kwarg); any explicit default (even a literal
        # `nothing` written by the user) is wrapped in Some(...).
        index_kwargs = Tuple{Symbol,Any}[]
        # Form 1a: prop(idx...) = struct Name ... end  (indexed inline struct)
        # Julia parses short-form function defs with a :block wrapper around the
        # RHS — so `subject(idx) = struct Subject ... end` has args[2] = :block
        # containing a LineNumberNode + the :struct. Unwrap that case.
        if Meta.isexpr(form_arg, :(=)) && Meta.isexpr(form_arg.args[1], :call)
            rhs_expr = form_arg.args[2]
            if Meta.isexpr(rhs_expr, :block)
                inner = [a for a in rhs_expr.args if !(a isa LineNumberNode)]
                length(inner) == 1 && Meta.isexpr(inner[1], :struct) && (rhs_expr = inner[1])
            end
            if Meta.isexpr(rhs_expr, :struct)
                call_expr = form_arg.args[1]
                prop_name = call_expr.args[1]
                for p in call_expr.args[2:end]
                    if Meta.isexpr(p, :parameters)
                        for kw in p.args
                            if Meta.isexpr(kw, :kw)
                                kname = kw.args[1]
                                Meta.isexpr(kname, :(::)) && (kname = kname.args[1])
                                @assert kname isa Symbol "indexed inline struct kwarg name must be a Symbol, got $(kw.args[1])"
                                push!(index_kwargs, (kname, Some(kw.args[2])))
                            else
                                kname = Meta.isexpr(kw, :(::)) ? kw.args[1] : kw
                                @assert kname isa Symbol "indexed inline struct kwarg name must be a Symbol, got $kw"
                                push!(index_kwargs, (kname, nothing))
                            end
                        end
                    else
                        pname = Meta.isexpr(p, :(::)) ? p.args[1] : p
                        @assert pname isa Symbol "indexed inline struct: index param must be a Symbol, got $p"
                        push!(index_params, pname)
                        push!(index_param_exprs, p)
                    end
                end
                child_struct = rhs_expr
            end
        # Form 1b: prop = struct Name ... end
        elseif Meta.isexpr(form_arg, :(=)) && Meta.isexpr(form_arg.args[2], :struct)
            prop_name = form_arg.args[1]
            child_struct = form_arg.args[2]
        # Form 2: struct Name ... end (bare)
        elseif Meta.isexpr(form_arg, :struct)
            child_struct = form_arg
        end
        isnothing(child_struct) && continue
        child_name = child_struct.args[2]
        isnothing(prop_name) && (prop_name = child_name)
        # Rename child struct to Parent_Child to avoid kwarg shadowing
        gen_name = Symbol(type, "_", child_name)
        child_struct.args[2] = gen_name
        # Collect child's own property names to avoid collision
        child_props = Set{Symbol}()
        for ca in child_struct.args[3].args
            ca isa Expr || continue
            ca2 = ca
            while Meta.isexpr(ca2, :macrocall); ca2 = ca2.args[end]; end
            Meta.isexpr(ca2, :(=)) || continue
            clhs = ca2.args[1]
            Meta.isexpr(clhs, (:call, :ref)) && (clhs = clhs.args[1])
            Meta.isexpr(clhs, :(::)) && (clhs = clhs.args[1])
            _push_if_symbol!(child_props, clhs)
        end
        # Prepend __parent__, index params, __hash_fields__ override, and
        # forwarded parent properties to the child body.
        child_body = child_struct.args[3]
        kwarg_names = Symbol[n for (n, _) in index_kwargs]
        prepend_names = Set{Symbol}([:__parent__, index_params..., kwarg_names...])
        # For indexed inline structs we override __hash_fields__ to
        # (__parent__, indices..., kwargs...) so the child's disk-cache
        # namespace is tied to the parent hash AND to the kwarg values. Skip
        # if the user declared __hash_fields__ inside the child body.
        will_prepend_hash_fields = (!isempty(index_params) || !isempty(index_kwargs)) && !(:__hash_fields__ in child_props)
        will_prepend_hash_fields && push!(prepend_names, :__hash_fields__)
        # Never forward DO-internal cache/identity properties from the parent
        # into the child — they have per-instance semantics (the child has its
        # own hash/cache_path/__cache_base__) and forwarding them collides with the
        # automatic machinery (e.g. with our __hash_fields__ prepend, producing
        # duplicate compute_property method definitions).
        nonforwardable = Set{Symbol}([:__hash_fields__, :__hash__, :__cache_path__, :cache])
        # Forward parent properties that (a) aren't overridden in the child,
        # (b) aren't __status__ (scoped separately), (c) aren't DO-internal
        # cache/identity names, (d) aren't one of the names we're about
        # to prepend ourselves, and (e) aren't this child's OWN
        # parent-property name. Inline-struct names are now in `parent_props`
        # (so a sibling can forward them), but a child must never forward
        # itself into its own scope — that would prepend a self-referential
        # `name = __parent__.name` (the parent IP of this very child) and
        # recurse.
        # Dedupe: a parent can declare the same property name multiple times
        # (indexed properties with multi-method dispatch on the index type).
        # We only want one forwarding extractor per name.
        forwarded = unique!(Symbol[pp for pp in parent_props if pp != prop_name && !(pp in child_props) && pp != :__status__ && !(pp in nonforwardable) && !(pp in prepend_names)])
        prepend = Expr[]
        push!(prepend, :(__parent__ = nothing))
        for ip in index_params
            push!(prepend, :($ip = nothing))
        end
        # For kwargs: use user-supplied default if any, else `nothing`. The
        # value actually used at runtime comes from the constructor kwarg;
        # the in-body rhs is a compute_property fallback (required kwargs
        # won't hit it because the parent wrapper's call signature enforces
        # them at the call site).
        for (kname, kdefault) in index_kwargs
            rhs = kdefault === nothing ? nothing : something(kdefault)
            push!(prepend, :($kname = $rhs))
        end
        if will_prepend_hash_fields
            push!(prepend, :(__hash_fields__ = $(Expr(:tuple, :__parent__, index_params..., kwarg_names...))))
        end
        # Forward each parent prop as a `@fetch!`-marked property
        # (`@fetch! nm = __parent__.nm`) rather than one
        # `(; nm... ) = __parent__` destructure, so a bare reference to a
        # progress-annotated parent prop threads progress instead of computing
        # the parent IP with no substatus attached (the "Starting (spinner)"
        # bug). The existing @fetch! property marker (731e012) wraps each body
        # at emission as `@fetch! __status__ __parent__.nm` →
        # `maybefetchproperty!(__status__, __parent__, :nm)`. This degrades to
        # plain `getproperty(__parent__, nm)` — byte-identical to the old
        # destructure — when `__status__ === nothing` (Treebars off / no
        # progress), for serial caches, and for forwarded IPs (wrapper
        # returned); it attaches a progress substatus only in the
        # `:parallel`-non-indexed case, and only renders a node for documented
        # props (undocumented → bare wrapper Treebars inlines). No Task ever
        # leaks — `fetchproperty!`'s callback applies `Base.fetch`, blocking to
        # the same value `getproperty` returns today. The destructure is
        # already split per-member by the main `:tuple` lowering, so emitting
        # per-member markers (vs one destructure) produces the SAME child
        # properties, just `@fetch!`-marked. (decision `1vwuhqj`: user chose
        # fix-directly; @fetch! call-site destructure recognition is the
        # orthogonal sibling item (a), not used here.)
        for nm in forwarded
            push!(prepend, :(@fetch! $nm = __parent__.$nm))
        end
        # Auto-derive a hierarchical cache_path: extend the parent's path by a
        # per-child directory whose name is the same flat segment that
        # `get_cache_path` would use as the file-name body for this property.
        # On disk this nests as "base/<parent_segment>/<child_segment>/…",
        # ending at the leaf "<property>_<args>.sjl". Skipped when the child
        # body explicitly declares cache_path — explicit wins.
        if !(:__cache_path__ in child_props)
            # Expr(:call) layout: (func, [parameters], positional...). The
            # parameters expression must come right after the function, not
            # after positional args, otherwise Julia's parser rejects it.
            seg_call_args = Any[:(DynamicObjects.cache_segment)]
            !isempty(index_kwargs) && push!(seg_call_args,
                Expr(:parameters, [Expr(:kw, kn, kn) for (kn, _) in index_kwargs]...))
            push!(seg_call_args, QuoteNode(prop_name))
            append!(seg_call_args, index_params)
            seg_call = Expr(:call, seg_call_args...)
            push!(prepend, :(__cache_path__ = joinpath(__parent__.__cache_path__, $seg_call)))
        end
        child_body.args = vcat(prepend, child_body.args)
        push!(extracted_structs, child_struct)
        push!(inline_child_pairs, prop_name => gen_name)
        # Replace with parent property definition. For indexed form, emit an
        # indexed property `prop(idx...; kw=default, ...)`; for the plain
        # form, a bare `prop`.
        constructor_kwargs = Any[
            Expr(:kw, :__parent__, :__self__),
            (Expr(:kw, ip, ip) for ip in index_params)...,
            (Expr(:kw, kname, kname) for (kname, _) in index_kwargs)...,
        ]
        # Auto-wire __status__ as a substatus of the parent, UNLESS the child
        # body declares its own __status__ (opt-out). Declaring
        # `__status__ = nothing` suppresses per-access Treebar nodes; declaring
        # `__status__ = __parent__.__status__` inherits the parent's status
        # directly without creating a child progress node.
        if !(:__status__ in child_props)
            push!(constructor_kwargs,
                Expr(:kw, :__status__, Expr(:call, compute_property, :__self__, :(Val(:__substatus__)), QuoteNode(prop_name), index_params...)))
        end
        constructor = Expr(:call, gen_name, Expr(:parameters, constructor_kwargs...))
        # Use `index_param_exprs` (typed `:(name::T)` when annotated, bare
        # `:name` otherwise) for the method signature so downstream readers
        # of `info.indices` see the URL-segment Julia Type. Internal uses
        # of `index_params` above stay on bare Symbols.
        lhs_expr = if isempty(index_params) && isempty(index_kwargs)
            prop_name
        elseif isempty(index_kwargs)
            Expr(:call, prop_name, index_param_exprs...)
        else
            # Emit kwargs as an Expr(:parameters, ...) on the parent-property
            # call signature. Required kwargs stay as bare Symbols; defaulted
            # kwargs become Expr(:kw, name, default).
            kw_nodes = Any[kdefault === nothing ? kname : Expr(:kw, kname, something(kdefault))
                           for (kname, kdefault) in index_kwargs]
            Expr(:call, prop_name, Expr(:parameters, kw_nodes...), index_param_exprs...)
        end
        constructor_assignment = Expr(:(=), lhs_expr, constructor)
        # Re-attach `@fresh` (peeled above) so the constructor property is marked
        # never-cache → the call form builds a fresh child on every call.
        isnothing(fresh_wrapper) ||
            (constructor_assignment = Expr(:macrocall, fresh_wrapper.args[1:end-1]..., constructor_assignment))
        body.args[i] = isnothing(doc_wrapper) ? constructor_assignment :
            Expr(:macrocall, doc_wrapper.args[1:end-1]..., constructor_assignment)
    end
    # `lnn` / `doc` flow across iterations via the metadata context.
    # `_absorb_body_metadata!` dispatch fills it from LineNumberNode /
    # AbstractString / `:string` Expr args; "real" property args read
    # `metadata.lnn[]` / `.doc[]` at the top of each iteration and the
    # `doc` ref is reset to `nothing` once that property consumes it.
    metadata = (lnn = Ref{Any}(nothing), doc = Ref{Any}(nothing))
    docs = []
    oproperties = Pair[]
    inline_methods = Any[]
    # `@options <parameter> = <domain expression>` declarations, in body order.
    # Held as `(; parameter, expression, lnn)` until the property list is
    # complete, because the dependency walk needs the full set of sibling names.
    option_decls = Any[]
    # `@mmap` properties: name => eltype-annotation-expr (or `nothing` when
    # un-annotated). Drives the per-property `_disk_format`/`_disk_eltype`
    # emission below.
    mmap_eltypes = Dict{Symbol,Any}()
    for arg in body.args
        _absorb_body_metadata!(arg, metadata) && continue
        lnn = metadata.lnn[]
        doc = metadata.doc[]
        macros = Set{Symbol}()
        rhs = nothing
        dependson = nothing
        locals = nothing
        indices = tuple()
        indexed = false
        cache_version = nothing
        # Peel `@doc` / `@cached` / unrecognised macros from `arg` via
        # `_apply_property_macro!` dispatch (one method per macro shape).
        # The state struct mutates `doc` / `cache_version` / `macros` in
        # place — `macros` is the same Set the outer loop uses, so we read
        # it back implicitly; the other two are scalars copied back after
        # the loop.
        macro_state = _PropertyMacroState(doc, cache_version, macros)
        # `@options(x) = domain` — a PARENTHESIZED macrocall binds only its own
        # arguments, so the marker lands on the LHS of the assignment instead of
        # wrapping it. Normalize to the wrapping form the peel loop expects, so
        # both `@options(x) = …` and `@options x = …` take one path.
        if Meta.isexpr(arg, :(=)) && Meta.isexpr(arg.args[1], :macrocall) &&
                _resolve_macro_name(arg.args[1].args[1]) === Symbol("@options")
            inner = arg.args[1]
            length(inner.args) == 3 ||
                error("@options names exactly one parameter: `@options(<parameter>) = <domain expression>`, got `$arg`")
            arg = Expr(:macrocall, inner.args[1], inner.args[2],
                Expr(:(=), inner.args[end], arg.args[2]))
        end
        while Meta.isexpr(arg, :macrocall)
            # `_resolve_macro_name` collapses `GlobalRef(Core, :@doc)` (the
            # form Julia's docstring lowering surfaces) to bare `:@doc`.
            mname = _resolve_macro_name(arg.args[1])
            arg = _apply_property_macro!(macro_state, Val(mname), arg)
        end
        doc = macro_state.doc
        cache_version = macro_state.cache_version
        # `@options(<parameter>) = <domain>` declares which values an input may
        # take — the one fact the structural descriptors cannot infer. It does
        # NOT declare a property named `<parameter>` (that name is already a
        # field or an argument, and would collide); it lowers to the dunder
        # indexed property `__options__(::Val{parameter})`, so a domain is an
        # ordinary lazily computed DO value: never evaluated unless a consumer
        # asks for it, memoized and invalidated like anything else, and its
        # dependencies fall out of the same walk every other RHS gets. The
        # rewrite happens here and then falls through to ordinary property
        # classification — no separate emission path.
        if Symbol("@options") in macros
            extra = setdiff(macros, (Symbol("@options"),))
            isempty(extra) ||
                error("@dynamicstruct $type: `@options` cannot combine with $(join(sort!(string.(collect(extra))), ", ")).")
            (Meta.isexpr(arg, :(=)) && arg.args[1] isa Symbol) ||
                error("@dynamicstruct $type: `@options` must read `@options(<parameter>) = <domain expression>`, got `$arg`.")
            parameter, domain = arg.args
            any(decl -> decl.parameter === parameter, option_decls) &&
                error("@dynamicstruct $type: duplicate `@options` declaration for `$parameter`; each parameter may declare one domain.")
            push!(option_decls, (; parameter, expression=domain, lnn))
            arg = Expr(:(=),
                Expr(:call, :__options__, Expr(:(::), Expr(:curly, Val, QuoteNode(parameter)))),
                domain)
        end
        # Inline-method short form: `f(__self__, ...) = body`. Bypasses property
        # tooling — no compute_property, no getproperty entry — but the body
        # still gets bare-name → `__self__.<prop>` rewriting like a property
        # RHS. Detect before the `:(=)` LHS/RHS split so the full signature
        # (including `where` and return-type wrappers) stays intact.
        if Meta.isexpr(arg, :(=))
            method_info = _detect_inline_method_lhs(arg.args[1])
            if !isnothing(method_info)
                isempty(macros) ||
                    error("Property-level macros (@cached, …) cannot be applied to inline methods in @dynamicstruct.")
                push!(inline_methods, (; method_info..., body=arg.args[2], lnn))
                metadata.doc[] = nothing
                continue
            end
        end
        if Meta.isexpr(arg, :function)
            # Long-form methods carrying a positional `__self__` have the same
            # ordinary-method semantics as the short form above. A long-form
            # definition without `__self__` is still neither a property nor an
            # inline method and keeps the focused property-syntax diagnostic.
            method_info = _detect_inline_method_lhs(arg.args[1])
            if !isnothing(method_info)
                isempty(macros) ||
                    error("Property-level macros (@cached, …) cannot be applied to inline methods in @dynamicstruct.")
                push!(inline_methods, (; method_info..., body=arg.args[2], lnn))
                metadata.doc[] = nothing
                continue
            end
            fname = Meta.isexpr(arg.args[1], :call) ? arg.args[1].args[1] : arg.args[1]
            error("Use short-form syntax for properties in @dynamicstruct: `$fname(...) = ...` instead of `function $fname(...) ... end`. If `$fname` is a helper that doesn't depend on the struct's state, move it outside the @dynamicstruct body.")
        end
        if Meta.isexpr(arg, :(=))
            arg, rhs = arg.args
            dependson = Set{Symbol}()
            locals = Set{Symbol}()
        end
        # Multi-lhs: a, b = expr or (;a, b) = expr → hidden group property + individual extractors
        if Meta.isexpr(arg, :tuple)
            # Detect named destructuring: (;a, b) parses as Expr(:tuple, Expr(:parameters, :a, :b))
            named = length(arg.args) == 1 && Meta.isexpr(arg.args[1], :parameters)
            raw_args = named ? arg.args[1].args : arg.args
            # Nested positional destructuring: ((a, b), (c, d)) = expr
            # Handled recursively: outer group + inner group per nested tuple.
            if !named && any(a -> Meta.isexpr(a, :tuple), raw_args)
                all_leaves = _collect_leaves(arg)
                group_name = Symbol("_tuple_", join(all_leaves, "_"))
                group_locals = Set{Symbol}(all_leaves); push!(group_locals, group_name)
                push!(oproperties, group_name => (;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version, result_type=nothing, doc))
                push!(docs, (group_name => (doc, true)))
                _emit_positional_destructure!(oproperties, docs, raw_args, group_name, lnn)
                metadata.doc[] = nothing
                continue
            end
            # Build list of (property_name, extract_expr_builder) pairs
            # extract_expr_builder takes the group_name and returns the RHS expression
            members = Pair{Symbol, Any}[]  # name => source_field_or_index
            if named
                # Per-shape dispatch via `_emit_named_member!`:
                #   bare symbol     → `a => a`
                #   `target <= src` → `target => src` (Symbol src)
                #                     or `Symbol(prefix, s) => s` for each
                #                     `s` in a `:tuple` src (prefix mode).
                for a in raw_args
                    _emit_named_member!(members, a)
                end
            else
                for (i, a) in enumerate(raw_args)
                    n = Meta.isexpr(a, :(::)) ? a.args[1] : a
                    push!(members, n => i)
                end
            end
            prop_names = first.(members)
            # When RHS is a bare symbol in named destructuring, skip the hidden
            # group property and extract directly: (;a, b) = config → a = config.a
            # Otherwise, use a group property to evaluate the RHS once.
            extract_from = if named && rhs isa Symbol
                rhs
            else
                group_name = Symbol("_tuple_", join(prop_names, "_"))
                group_locals = Set{Symbol}(prop_names)
                push!(group_locals, group_name)
                push!(oproperties, group_name=>(;lhs=group_name, macros, rhs, lnn, dependson=Set{Symbol}(), locals=group_locals, indices=tuple(), indexed=false, cache_version, result_type=nothing, doc))
                push!(docs, (group_name=>(doc, true)))
                group_name
            end
            metadata.doc[] = nothing
            for (prop_name, source) in members
                extract_rhs = _extract_member(extract_from, source)
                push!(oproperties, prop_name=>(;lhs=prop_name, macros=Set{Symbol}(), rhs=extract_rhs, lnn, dependson=Set{Symbol}(), locals=Set{Symbol}([prop_name]), indices=tuple(), indexed=false, cache_version=nothing, result_type=nothing, doc=nothing))
                push!(docs, (prop_name=>(nothing, true)))
            end
            continue
        end
        if Meta.isexpr(arg, :ref)
            loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
            pname = arg.args[1]
            Meta.isexpr(pname, :(::)) && (pname = pname.args[1])
            @warn "Deprecated: `$pname` uses [] syntax which cannot combine with kwargs$loc. Use () instead: $pname($(join(arg.args[2:end], ", ")))"
        end
        if Meta.isexpr(arg, (:ref, :call))
            arg, indices... = arg.args
            indexed = true
            union!(locals, extractnames(indices))
        end
        name, ext_type = if Meta.isexpr(arg, :(::))
            arg.args[1], arg.args[2]
        else
            arg, nothing
        end
        # `foo(i)::T = rhs` — the `::` annotation wraps the call, so the
        # call/ref index strip above (which only fires on a bare `:ref`/`:call`
        # arg) never ran. Strip the indices from `name` now, mark indexed, and
        # reduce `arg` (→ the `lhs` field below) to the bare callee, matching
        # how non-annotated indexed properties store their `lhs`. `ext_type`
        # stays captured for `@mmap` load lowering.
        if Meta.isexpr(name, (:ref, :call))
            callee, post_indices... = name.args
            indexed = true
            !isnothing(locals) && union!(locals, extractnames(collect(post_indices)))
            indices = (indices..., post_indices...)
            arg = callee
            name = callee
        end
        if !(name isa Symbol)
            loc = isnothing(lnn) ? "" : " (near $(lnn.file):$(lnn.line))"
            hint = if Meta.isexpr(name, :parameters)
                "Looks like a `;`-kwargs clause leaked into the body. If you wrote `@dynamicstruct $type(...; kw, kw=default) = begin … end`, that's now supported — make sure DynamicObjects is up to date."
            elseif Meta.isexpr(name, :tuple)
                "Tuple LHS (e.g. `(a, b) = ...`) destructuring at struct-level is not supported as a property name; either split into separate property declarations or use `let` inside another property's RHS."
            else
                """\
                Each property in @dynamicstruct must have a Symbol name on the LHS — e.g. `name = rhs`, `name(idx) = rhs`, or `name::T = rhs`. \
                Looks like a side-effecting/anonymous statement at struct top-level — DO doesn't run those at construction. To keep the check, either:
                  (a) bind it to a named property and reference that property from a downstream RHS:
                      _check = $arg
                      result = (_check; …)         # forces evaluation when `result` is accessed
                  (b) fold the assertion directly into the RHS of a property that needs to enforce it:
                      result = begin
                          $arg
                          …
                      end
                """
            end
            error("@dynamicstruct $type: cannot interpret `$arg` as a property declaration$loc. $hint")
        end
        # `prop::T = rhs` (computed property with a type annotation) registers
        # T with `_analysis_nested_type` so `analyze_structure` walks into
        # T's tree alongside the enclosing struct's. Separate hook from
        # `_nested_struct_type` (which HTMXObjects walks for route mounting)
        # — typed primitives like `port::Int` would otherwise wedge route
        # registration on `meta(Int)`. Indexed properties and fixed fields
        # keep the annotation's existing semantics (Julia field type for
        # fixed, ignored for indexed).
        if ext_type !== nothing && !isnothing(rhs) && !indexed
            push!(analysis_child_pairs, name => ext_type)
        end
        # `@mmap` property: record its eltype annotation (or `nothing` when
        # un-annotated) for the `_disk_format`/`_disk_eltype` emission below.
        if Symbol("@mmap") in macros
            mmap_eltypes[name] = ext_type
        end
        push!(docs, (name=>(doc, !isnothing(rhs))))
        metadata.doc[] = nothing
        !isnothing(locals) && push!(locals, name)
        !isnothing(locals) && push!(locals, :__status__)
        # A fixed field (no rhs) may carry ONLY `@versioned` (the cache version
        # dimension); every other marker (@cached/@mmap/@fresh/@dynamic_progress)
        # acts on a computed property and is a mistake on a field.
        @assert !isnothing(rhs) || issubset(macros, (Symbol("@versioned"),)) "fixed field `$name` may not carry markers other than @versioned (got $(sort!(string.(collect(macros)))))"
        push!(oproperties, name=>(;lhs=arg, macros, rhs, lnn, dependson, locals, indices, indexed, cache_version, result_type=ext_type, doc))
    end
    # `properties` holds the per-declaration list (preserves order AND duplicate
    # names — e.g. a future `@get foo()` + `@include foo(x::String)` pair). It's
    # what `meta(T)` returns; macro-internal lookups that just need "is `x` a
    # property name?" use the `prop_names` set built from it.
    properties = collect(oproperties)
    prop_names = Set{Symbol}(first.(oproperties))
    # Bare-ref resolution set: user property names PLUS the injected magic
    # dunders, so a body may reference `__hash__`/`__cache_path__`/… bare and
    # have `walk_rhs` resolve them to `__self__.…` just like a sibling. Keep
    # `prop_names` itself user-only — the injection guard and `hasproperty`
    # below rely on it meaning "names the user actually declared".
    walk_props = union(prop_names, _BAREREF_MAGIC)

    # Struct-level lint passes: repeated-prefix and shared-arg-signature.
    # Lints have moved to `analyze_structure(T)` — run from `print_structure`,
    # not at definition time. The macro no longer emits any lint warnings.

    docstring = something(docstring, "DynamicStruct `$type`.") * "\n\n" * join([
        "* " * (isnothing(doc) ? "" : "$(_doc_to_string(doc)): ") * "`$name" * (hasrhs ? " = ..." : "") * "`"
        for (name, (doc, hasrhs)) in docs
    ], "\n")

    generated_names = Tuple(name for (name, info) in oproperties if !isfixed(info))
    indexed_names = Tuple(name for (name, info) in oproperties if info.indexed)
    # DiskCacheLocks-bearing properties: `@cached` AND `@mmap` (both persist to
    # disk and want the strict-mode per-path lock). `@mmap` implies disk
    # persistence with the mmap format (D4).
    cached_names = [(name, Symbol("_", type, "_", name, "_disk_cache")) for (name, info) in oproperties if !isfixed(info) && (Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros)]
    # `@mmap` properties → (name, eltype-annotation-expr-or-nothing) for the
    # `_disk_format`/`_disk_eltype` per-property override emission.
    mmap_names = sort!(collect(keys(mmap_eltypes)))
    fixed_fields = [(name, info.lhs) for (name, info) in oproperties if isfixed(info)]
    fixed_names = [n for (n, _) in fixed_fields]
    fixed_lhs = [lhs for (_, lhs) in fixed_fields]
    # ── @versioned: the cache version dimension (fixed field OR computed prop) ─
    # `@versioned x` tags `x` as the version dimension — excluded from the cache
    # IDENTITY, forming a per-version path segment (see `has_versioned_fields` /
    # `__cache_path__`). Two shapes share one contract (decision `b2tsvz`, opt B):
    #   • a FIXED field  → read via `getfield`; excluded from the identity hash so
    #     every version of one object shares an identity dir (what lets pruning work).
    #   • a COMPUTED prop → read via `getorcomputeproperty` (the value DO derives,
    #     e.g. `file_version(path)`); identity is UNCHANGED — a computed prop is
    #     never in `__hash_fields__`, so there is nothing to exclude and the version
    #     segment is purely additive. Acyclicity guarded once `dependson` is built.
    versioned_names = [name for (name, info) in oproperties if Symbol("@versioned") in info.macros]
    versioned_fixed = Set{Symbol}(name for (name, info) in oproperties if isfixed(info) && Symbol("@versioned") in info.macros)
    # A computed `@versioned` prop cannot ALSO be disk-cached: computing its own
    # value would need `__cache_path__` → `__version_tag__` → itself (a cycle).
    for (name, info) in oproperties
        (Symbol("@versioned") in info.macros && !isfixed(info) &&
         (Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros)) &&
            error("@versioned computed property `$name` may not also be @cached/@mmap: computing its value needs the cache path, which needs the version — a cycle. Make the version dimension a plain computed property.")
    end
    identity_fixed_names = [n for n in fixed_names if !(n in versioned_fixed)]
    versioned_defs = isempty(versioned_names) ? Any[] : Any[
        :($DynamicObjects.has_versioned_fields(::Type{$type}) = true),
        :($DynamicObjects._identity_hash_fields(__self__::$type) = $(Expr(:tuple, [:(getfield(__self__, $(QuoteNode(n)))) for n in identity_fixed_names]...))),
        :($DynamicObjects._version_hash_fields(__self__::$type) = $(Expr(:tuple, [(n in versioned_fixed ? :(getfield(__self__, $(QuoteNode(n)))) : :($DynamicObjects.getorcomputeproperty(__self__, $(QuoteNode(n))))) for n in versioned_names]...))),
    ]
    # ── Static dependency graph ──────────────────────────────────────────────
    # Populate each computed property's `dependson` set (empty until now — the
    # field was a placeholder). Walk a COPY of the RHS: `walk_rhs` mutates `:let`
    # blocks in place, and the real per-property emission re-walks `info.rhs`
    # later. The `dependson` Sets are shared by reference into the emitted `meta`
    # (below), so mutating them here ships them populated — un-stubbing
    # `property_source_info`/`reflect(T)` and feeding the `remake` carry-over bake.
    opaque_props = Set{Symbol}()
    for (name, info) in properties
        (info.rhs === nothing) && continue        # fixed fields have no RHS
        _collect_self_deps!(info.dependson,
            walk_rhs(deepcopy(info.rhs); locals=copy(info.locals), properties=walk_props, lnn=info.lnn)) &&
            push!(opaque_props, name)
    end
    # ── `@options` domain declarations ───────────────────────────────────────
    # Each declaration became an ordinary `__options__(::Val{parameter})`
    # property above, so its `dependson` was just populated by the pass above —
    # a domain that reads a sibling is context-dependent, and that is exactly
    # what `dependson` records. Declaration order is body order in both lists.
    option_infos = [info for (name, info) in properties
        if name === :__options__ && Symbol("@options") in info.macros]
    @assert length(option_infos) == length(option_decls)
    option_declaration_records = Pair{Symbol,NamedTuple}[]
    for (decl, info) in zip(option_decls, option_infos)
        dependencies = sort!(collect(info.dependson))
        push!(option_declaration_records, decl.parameter => (;
            parameter=decl.parameter,
            expression=decl.expression,
            expression_string=string(decl.expression),
            dependencies,
            static=isempty(dependencies),
            source=:options,
            lnn=decl.lnn,
        ))
    end
    option_declaration_defs = isempty(option_declaration_records) ? Any[] : Any[
        :($DynamicObjects.option_declarations(::Type{$type}) = $option_declaration_records),
    ]
    # ── @versioned computed props: acyclicity guard (decision `b2tsvz`) ───────
    # A computed version dimension must be derivable WITHOUT a cache path: the path
    # is `…/<identity>/<version_tag>`, and `__version_tag__` reads the version prop,
    # so if that prop (transitively) reads a `@cached`/`@mmap` property the read
    # needs `__cache_path__` → `__version_tag__` → the prop again (a cycle). The
    # `dependson` graph is populated just above, so reject it at macro time with a
    # precise message instead of a runtime stack overflow.
    if any(n -> !(n in versioned_fixed), versioned_names)
        _forbidden_ver_deps = union(
            Set{Symbol}(name for (name, info) in oproperties
                        if Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros),
            Set{Symbol}([:__cache_path__, :__version_tag__, :__identity_hash__]))
        # Fixed fields carry `dependson === nothing` (only computed props get a
        # populated Set above), so skip them — they're leaves in the dep walk and
        # `get(…, Set())` below already treats a missing key as no-deps.
        _ver_depmap = Dict{Symbol,Set{Symbol}}(name => info.dependson
            for (name, info) in properties if info.dependson !== nothing)
        for _vname in versioned_names
            _vname in versioned_fixed && continue
            _seen = Set{Symbol}()
            _stack = collect(get(_ver_depmap, _vname, Set{Symbol}()))
            while !isempty(_stack)
                _d = pop!(_stack)
                _d in _seen && continue
                push!(_seen, _d)
                _d in _forbidden_ver_deps && error("@versioned computed property `$_vname` (transitively) depends on `$_d`, whose value needs the cache path — computing the version would then need the version itself (a cycle). Derive the version dimension without reading any @cached/@mmap property or cache-path machinery.")
                append!(_stack, get(_ver_depmap, _d, Set{Symbol}()))
            end
        end
    end
    # ── `remake` carry-over bake (decision yf4z8x) ───────────────────────────
    # A memoized bare property may be reused verbatim by `remake` when NONE of
    # the fixed fields it (transitively) depends on is among the changed kwargs.
    # Compute each carry-eligible property's invalidating fixed fields and emit a
    # per-type `_carryover` with them baked as a literal, so the per-property
    # `isdisjoint(changed_kwargs, invalidators)` gate const-folds at each call.
    # Excluded (v1): fixed fields, indexed props (not PropertyCache-backed),
    # inline `@struct` children (they wire `__parent__` to the SOURCE object),
    # and the `__…__` machinery/status properties.
    fixed_set = Set{Symbol}(fixed_names)
    inline_child_names = Set{Symbol}(first(p) for p in inline_child_pairs)
    direct_deps = Dict{Symbol,Set{Symbol}}()
    for (name, info) in properties
        isnothing(info.dependson) && continue
        union!(get!(() -> Set{Symbol}(), direct_deps, name), info.dependson)
    end
    _carry_calls = Any[]
    _seen_carry = Set{Symbol}()
    for (name, info) in properties
        (isfixed(info) || info.indexed || name in inline_child_names ||
            name in _seen_carry || startswith(String(name), "__")) && continue
        push!(_seen_carry, name)
        inv = sort!(collect(_carry_invalidators(name, direct_deps, fixed_set, opaque_props)))
        push!(_carry_calls, :($DynamicObjects._carry1(__obj__, Val(__KW__), Val($(QuoteNode(name))),
            Val($(Expr(:tuple, (QuoteNode(f) for f in inv)...))))))
    end
    _carryover_expr = isempty(_carry_calls) ?
        :($DynamicObjects._carryover(__obj__::$type, ::Val) = (;)) :
        :($DynamicObjects._carryover(__obj__::$type, ::Val{__KW__}) where {__KW__} = merge($(_carry_calls...)))
    struct_expr = Expr(:struct, mut, head, Expr(:block,
        fixed_lhs..., :(cache::$PropertyCache),
        :(function $type($(fixed_lhs...); cache_type=nothing, kwargs...)
            isnothing(cache_type) || error("`cache_type` was removed (2026-07-07, decision 2canrl); the cache is always threadsafe now — drop this kwarg.")
            __inst__ = new(
                $(fixed_names...),
                $PropertyCache(
                    $ThreadsafeDict,
                    (;kwargs...)
                )
            )
            __inst__
        end),
        :(function $type(::$DynamicObjects._RemountToken, __cache__::$PropertyCache, $(fixed_lhs...))
            new(
                $(fixed_names...),
                __cache__
            )
        end)
    ))
    # ── Magic-property deprecation: reject an OLD name DECLARED in a body ────
    # (2026-07-07, decision 2canrl). Declaring an old data-side name would
    # silently become a plain user property (no disk-cache/content-addressing
    # behavior) now that the magic property lives under its dunder name — so
    # error at expansion. Same registry as the runtime access-shims (no drift).
    for (nm, _) in oproperties
        if haskey(_RENAMED_MAGIC, nm)
            error("`@dynamicstruct $type`: property `$nm` was renamed to " *
                  "`$(_RENAMED_MAGIC[nm])` (2026-07-07, decision 2canrl) — declare " *
                  "`$(_RENAMED_MAGIC[nm]) = …` instead of `$nm = …`.")
        elseif haskey(_REMOVED_MAGIC, nm)
            error("`@dynamicstruct $type`: property `$nm` was removed " *
                  "(2026-07-07, decision 2canrl); $(_REMOVED_MAGIC[nm]).")
        end
    end
    result = Expr(:block)
    # Emit per-cached-property DiskCacheLocks
    for (name, varname) in cached_names
        push!(result.args, :($varname = $DiskCacheLocks()))
    end
    # Prepend extracted inline child structs (processed recursively)
    _child_handler = isnothing(child_handler) ? (s -> dynamicstruct(s; is_child=true, lint)) : child_handler
    for s in extracted_structs
        child_result = _child_handler(s)
        # Unwrap esc() — parent handles escaping
        @assert Meta.isexpr(child_result, :escape)
        push!(result.args, child_result.args[1])
    end
    # Docstring precedence — without emitting two `@doc` calls (which would
    # warn "Replacing docs" on every Revise reload and, worse, cause
    # `Core.@__doc__` to copy the parent's user docstring onto hoisted
    # inline children by walking every `Base.@__doc__` marker in the
    # expansion):
    #   1. Emit the struct definition bare.
    #   2. Install the auto-generated property-list docstring as a
    #      `Base.Docs.getdoc(::Type{T})` fallback. It's guarded to return
    #      `nothing` when a docstring is already registered for the
    #      binding, so a user docstring always wins.
    #   3. For top-level structs only (`is_child=false`), emit
    #      `Base.@__doc__ $type` as the hook that `Core.@__doc__` rewrites
    #      into `@doc "userdoc" $type` when the user wrote
    #      `"""userdoc"""\n@dynamicstruct struct X ... end`. Children omit
    #      this marker so the parent's user docstring doesn't bleed into
    #      hoisted inline child structs.
    push!(result.args, Expr(:block,
        struct_expr,
        :($Base.Docs.getdoc(::Type{$type}) = begin
            __b = $Base.Docs.Binding(parentmodule($type), nameof($type))
            __m = get($Base.Docs.meta(__b.mod), __b, nothing)
            (__m === nothing || isempty(__m.docs)) ? $docstring : nothing
        end),
        (is_child ? :($type) : :(Base.@__doc__ $type)),
        quote
            $Base.hasproperty(__self__::$type, name::Symbol) = name in $(Tuple(prop_names))
            $Base.getproperty(__self__::$type, name::Symbol) = $getorcomputeproperty(__self__, name)
            $Base.setproperty!(__self__::$type, name::Symbol, value) = getfield(__self__, :cache)[name] = value
            $DynamicObjects.meta(::Type{$type}) = $properties
            $(option_declaration_defs...)
            $_carryover_expr
            $DynamicObjects._remount_opaque_properties(::Type{$type}) = $(Tuple(sort!(collect(opaque_props))))
            $DynamicObjects.is_generated_property(::$type, name::Symbol) = name in $generated_names
            $DynamicObjects.is_indexed_property(::$type, name::Symbol) = name in $indexed_names
            $DynamicObjects._hash_replace(__self__::$type) = __self__.__hash__
            $(versioned_defs...)
            $([:(
                $DynamicObjects._disk_cache(::$type, ::Val{$(QuoteNode(name))}) = $varname
            ) for (name, varname) in cached_names]...)
            $([:(
                $DynamicObjects._disk_format(::$type, ::Val{$(QuoteNode(name))}) = $(Val(:mmap))
            ) for name in mmap_names]...)
            $([:(
                $DynamicObjects._disk_eltype(::$type, ::Val{$(QuoteNode(name))}) = $(something(mmap_eltypes[name], :nothing))
            ) for name in mmap_names]...)
            $([:(
                $DynamicObjects._check_mmap_annotation($(QuoteNode(type)), $(QuoteNode(name)), $(mmap_eltypes[name]))
            ) for name in mmap_names if !isnothing(mmap_eltypes[name])]...)
            $([:(
                $DynamicObjects._nested_struct_type(::Type{$type}, ::Val{$(QuoteNode(prop_name))}) = $gen_name
            ) for (prop_name, gen_name) in inline_child_pairs]...)
            $([:(
                $DynamicObjects._analysis_nested_type(::Type{$type}, ::Val{$(QuoteNode(prop_name))}) = $gen_name
            ) for (prop_name, gen_name) in analysis_child_pairs]...)
            # Per-T `_type_description` override — delegates to a runtime
            # resolver that reads the user-attached docstring (if any). Lets
            # `@include`-emitted `_property_description` overrides bubble
            # `T`'s docstring up as the progress label when `T(args)` is
            # constructed via an IP.
            $DynamicObjects._type_description(::Type{$type}, args...; kwargs...) =
                $DynamicObjects._resolve_type_description($type, args, (; kwargs...))
            $Base.show(io::IO, __self__::$type) = begin
                print(io, $(string(type)), "(")
                $([let sep = i == 1 ? :() : :(print(io, ", "))
                    quote; $sep; print(io, $(string(fn)), "="); show(io, getfield(__self__, $(QuoteNode(fn)))); end
                end for (i, fn) in enumerate(fixed_names)]...)
                $(isempty(fixed_names) ? :() : :(print(io, "; ")))
                show(io, getfield(__self__, :cache))
                print(io, ")")
            end
        end,
        [
            begin
                # `@fresh` marker validation (macro-time). The marker declares a
                # never-cache call form, so two combinations are contradictory and
                # rejected here rather than silently emitting an inert/wrong method:
                #   (a) on a bare scalar property — it memoizes via PropertyCache, a
                #       different mechanism the IP-call-form `_never_cache` never
                #       reaches; an unhelpful silent no-op without this guard.
                #   (b) with @cached/@mmap — "never caches" vs "disk-caches" cannot
                #       both hold; allowing it would serve a stale disk value under a
                #       never-cache marker.
                if Symbol("@fresh") in info.macros
                    info.indexed || error("@fresh on property `$name`: the never-cache marker applies only to call-form / indexed properties (`@fresh $name() = …`). A bare scalar property `$name = …` memoizes via PropertyCache (a different mechanism) — use the call form, or drop @fresh.")
                    (Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros) && error("@fresh on property `$name`: cannot combine with @cached/@mmap. `@fresh` declares the property never caches; @cached/@mmap declare a disk cache — these are contradictory. Drop one.")
                end
                # `@struct` inline-child validation (macro-time). The inline-child
                # rewrite that turns `@struct $name(…) = begin … end` into a child
                # type — with a `__parent__ = nothing` field the parent wires to
                # `__self__` at construction — runs in EARLIER passes that peel only
                # `@doc` and `@fresh` before finding `@struct`. Any OTHER wrapping
                # marker parses as `@wrapper(@struct(…))` and is skipped by those
                # passes, so `@struct` survives here in `info.macros` instead of
                # having been consumed into a child. The child type and its
                # `__parent__` field would then never be emitted, so the body's
                # `__parent__` reference would be unbound and the call form would
                # throw `UndefVarError: __parent__` the first time it is hit — a
                # clean compile that breaks only live, the same failure class the
                # bare-scalar `@fresh` guard above prevents. Reject it here.
                # (`@fresh @struct` IS supported — it is threaded through the
                # rewrite so the call form builds a fresh child per call; a
                # disk-cache marker `@cached`/`@mmap` on an inline child is not.)
                if Symbol("@struct") in info.macros
                    _wrappers = sort!(string.(collect(setdiff(info.macros, [Symbol("@struct")]))))
                    _wrapper_desc = isempty(_wrappers) ? "another macro" : join(_wrappers, ", ")
                    error("@struct on property `$name`: `@struct` must be outermost (only `@doc` and `@fresh` may wrap it), but here it is wrapped by $_wrapper_desc. A wrapping marker shadows the inline-child rewrite, so the child type and its injected `__parent__` are never emitted and the property would throw `UndefVarError: __parent__` when its call form is first hit (a clean compile that breaks only live). Write `@struct $name(…) = begin … end` (optionally `@fresh @struct $name(…) = …` for a fresh child per call). Disk-cache markers `@cached`/`@mmap` on an inline child are not supported — disk-cache a plain computed property instead.")
                end
                # An index arg may legitimately be named after the property it
                # indexes — `dataset(dataset::Dataset) = DatasetWorkspace(dataset)`
                # reads as "the workspace FOR this dataset". The self-named kwarg
                # below would then be a second argument called `dataset` in the
                # same signature, which Julia rejects outright ("function argument
                # name not unique"). Suppress it: the index arg is in `locals`, so
                # the body's bare `dataset` already resolves to the positional and
                # the kwarg was unreachable anyway. `_self_named_index` tells
                # `_computeproperty` not to pass the resume value it can no longer
                # receive.
                self_named_index = name in extractnames(collect(info.indices))
                cp_kwargs = Any[]
                self_named_index || push!(cp_kwargs,
                    Expr(:kw, name, length(info.indices) > 0 ? :(__self__.$name) : nothing))
                name != :__status__ && push!(cp_kwargs, Expr(:kw, :__status__, :nothing))
                # Build method definitions with Expr directly (not :() syntax)
                # so the parser doesn't insert DynamicObjects.jl LNNs into
                # the method body — Julia uses the body's first LNN for
                # Method.file/line, which must point at user code.
                _lnn = something(info.lnn, LineNumberNode(0, :unknown))
                # Walk kwarg defaults with kwarg names excluded from locals,
                # so that `seed=seed` correctly transforms the default `seed`
                # into `__self__.seed` rather than leaving it as a bare symbol.
                kwarg_names = Set{Symbol}()
                for idx in info.indices
                    Meta.isexpr(idx, :parameters) || continue
                    for a in idx.args
                        Meta.isexpr(a, :kw) && push!(kwarg_names, a.args[1] isa Expr ? a.args[1].args[1] : a.args[1])
                    end
                end
                defaults_locals = setdiff(info.locals, kwarg_names)
                walked_indices = map(info.indices) do idx
                    if Meta.isexpr(idx, :parameters)
                        Expr(:parameters, map(idx.args) do a
                            if Meta.isexpr(a, :kw)
                                Expr(:kw, a.args[1], walk_rhs(a.args[2]; locals=defaults_locals, properties=walk_props, lnn=info.lnn))
                            else
                                a
                            end
                        end...)
                    else
                        idx
                    end
                end
                _call(f, extras...) = fixcall(Expr(:call,
                    Expr(:., DynamicObjects, QuoteNode(f)),
                    :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    walked_indices..., Expr(:parameters, extras...),
                ))
                iscached_val = Symbol("@cached") in info.macros || Symbol("@mmap") in info.macros
                # Per-signature documentation flag + (when documented) the
                # doc-derived label override.
                #
                # Gate on the PER-DECLARATION `info.doc`, never a name-keyed docs
                # map (which would collapse duplicate names last-doc-wins): a
                # property with multiple signatures has one `info` per signature,
                # and each must reflect ITS OWN docstring. Both the
                # `_is_property_documented` flag (the show-label-vs-inline gate
                # the Treebars ext reads) and the `_property_description` override
                # (the rendered label) are emitted per signature here, so Julia's
                # own dispatch on `args...` selects the right one at call time —
                # no parallel signature matcher.
                #
                # The flag is emitted for EVERY declaration — `true` when
                # documented, `false` when not — so a re-expanded struct never
                # falls through to the default `_is_property_documented` (the
                # historic first-sig `metafirst` gate kept for not-yet-re-expanded
                # structs): an undocumented signature of a multi-sig property must
                # read `false`, not the first declaration's doc-presence.
                has_user_kw_splat = any(walked_indices) do idx
                    Meta.isexpr(idx, :parameters) && any(a -> Meta.isexpr(a, :...), idx.args)
                end
                doc_extras = has_user_kw_splat ? () : (:(kwargs...),)
                isdoc_expr = (_lnn, Expr(:(=), _call(:_is_property_documented, doc_extras...),
                                         Expr(:block, _lnn, !isnothing(info.doc))))
                desc_expr = if !isnothing(info.doc)
                    pdoc = info.doc
                    # Walk the docstring expression so interpolated bare names
                    # resolve through the same scope rules as the property's
                    # body: sibling-property references (`$method`,
                    # `$top_chains`, …) get rewritten to `__self__.<name>`,
                    # while the property's own indices and kwargs stay as
                    # plain locals (they're in the emitted method signature).
                    # String literals with no interpolation are passed through
                    # unchanged by `walk_rhs`.
                    walked_doc = walk_rhs(pdoc; info.locals, properties=walk_props, lnn=info.lnn)
                    (_lnn, Expr(:(=), _call(:_property_description, doc_extras...), Expr(:block, _lnn, walked_doc)))
                else
                    nothing
                end
                walked_rhs = walk_rhs(info.rhs; info.locals, properties=walk_props, lnn=info.lnn)
                # `@dynamic_progress`-marked: emit the 2-arg form
                # `@dynamic_progress __status__ <body>`. The macro (defined
                # above) handles both the call-site rewrite AND the Tb
                # `@progress __status__ <body>` wrap that binds `__progress__`
                # inside the body. Same outside→in macro expansion order as
                # before — `@memo!` calls inside still expand after, so the
                # `maybememoize!(maybeprogress!, …)` stacking dispatch arms
                # pick them up.
                if Symbol("@dynamic_progress") in info.macros
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(@__MODULE__, Symbol("@dynamic_progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        walked_rhs)
                end
                # `@fetch!`-marked: emit `@fetch! __status__ <body>`. Sugar for a
                # thin progress-reporting pass-through property — `@fetch!`
                # rewrites every call in the body to
                # `maybefetchindex!(__status__, …)` and every property access to
                # `maybefetchproperty!(__status__, …)`, so a call down to an
                # expensive sibling IP both memoizes AND mounts its progress
                # subtree under the caller-bound `__status__`. Parallel to the
                # `@dynamic_progress` branch above, but threads the memoizing
                # `@fetch!` (cached + progress) rather than `maybeprogress!`
                # (progress only) — the right default for wrappers over cached /
                # `@mmap` work. `__status__` defaults to `nothing` (no caller
                # progress / Tb absent), in which case `@fetch!` degrades to
                # `memoize!` and Treebars stays a weakdep.
                if Symbol("@fetch!") in info.macros
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(@__MODULE__, Symbol("@fetch!")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        walked_rhs)
                end
                # `@progress`-marked (decision w0rn26 → A): wrap the body in
                # `Treebars.@progress __status__ begin … end` and rewrite the body's
                # self-property / self-IP accesses to thread `__progress__` (the var
                # that block binds). The block roots a progress context at the
                # property's `__status__` (the substatus a parent threaded in;
                # `nothing` when none → the wrap is a transparent no-op and the
                # `maybefetch*` calls degrade to `memoize!` / `getproperty`), so the
                # property's self-accesses hang under the caller's ambient phase —
                # ambient nesting, behaving like Tb's `@progress`. The self-access
                # rewrite runs FIRST (on the walked body), so `__progress__` is
                # literal in the source the `Treebars.@progress` walker then renames;
                # the wrap is emitted as a qualified `Treebars.@progress` (DO does NOT
                # export a `@progress` macro — `@progress` is only the parse-marker
                # the generic `_apply_property_macro!` captures). Direct `maybefetch*`
                # calls (NOT a nested `@fetch! __progress__ …`) avoid the `fecc238`
                # outside-in dangling-`__progress__` footgun.
                if Symbol("@progress") in info.macros
                    # Pass the rewritten body to Treebars.@progress. If it is already a
                    # block, pass it DIRECTLY — wrapping a block inside another block
                    # buries inline `@progress "phase"` markers one level deep, and Tb
                    # requires a phase marker to be a DIRECT statement of the enclosing
                    # @progress block (else: "phase marker must be a direct statement of
                    # an enclosing @progress block"). Only a bare-expr body needs a fresh
                    # block wrapper.
                    _rewritten = _progress_self_rewrite(walked_rhs)
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(Treebars, Symbol("@progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        Meta.isexpr(_rewritten, :block) ? _rewritten : Expr(:block, _rewritten))
                end
                # `@PROGRESS`-marked: the "throw everything at @progress" form. Exactly
                # like `@progress` above, but rewrites the body with `_fetch_rewrite`
                # (what `@fetch!` emits — every call → `maybefetchindex!(__progress__, …)`,
                # every access → `maybefetchproperty!(__progress__, …)`) instead of the
                # self-only `_progress_self_rewrite`. So EVERY call/access threads progress
                # (and memoizes), not just bare sibling accesses. Same `Treebars.@progress
                # __status__` wrap; `__progress__` stays literal in the emitted maybefetch*
                # calls, so Tb's outside-in walker renames it — the same fecc238-footgun-free
                # path as `@progress`, and inline `@progress`/`@phases` markers in the body
                # still work (Tb expands the wrap first).
                if Symbol("@PROGRESS") in info.macros
                    _rewritten_all = _fetch_rewrite(:__progress__, walked_rhs)
                    walked_rhs = Expr(:macrocall,
                        GlobalRef(Treebars, Symbol("@progress")),
                        something(info.lnn, LineNumberNode(0, :unknown)),
                        :__status__,
                        Meta.isexpr(_rewritten_all, :block) ? _rewritten_all : Expr(:block, _rewritten_all))
                end
                block = Expr(:block,
                    _lnn, Expr(:(=), _call(:compute_property, cp_kwargs...), Expr(:block, _lnn, walked_rhs)),
                    _lnn, Expr(:(=), _call(:iscached), Expr(:block, _lnn, iscached_val)),
                    _lnn, Expr(:(=), _call(:resumes), Expr(:block, _lnn, false)),
                )
                if !isnothing(info.cache_version)
                    # Don't use _call — cache_version is per-property, not per-index
                    cv_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:cache_version)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    cv_expr = (_lnn, Expr(:(=), cv_method, Expr(:block, _lnn, info.cache_version)))
                    push!(block.args, cv_expr...)
                end
                # `@fresh`-marked: emit `_never_cache(__self__::T, ::Val{name}) =
                # true` so the IP call form routes to the uncached `fresh` instead
                # of `memoize!`. Per-property (keyed by name only, no indices) —
                # same direct-`Expr` shape as `cache_version`, not `_call`.
                if Symbol("@fresh") in info.macros
                    nc_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:_never_cache)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    nc_expr = (_lnn, Expr(:(=), nc_method, Expr(:block, _lnn, true)))
                    push!(block.args, nc_expr...)
                end
                # See the suppression above: this property has no kwarg named
                # after itself, so the disk-cache resume value must not be passed.
                if self_named_index
                    sni_method = Expr(:call,
                        Expr(:., DynamicObjects, QuoteNode(:_self_named_index)),
                        :(__self__::$type), :(::Val{$(Meta.quot(name))}),
                    )
                    push!(block.args, _lnn, Expr(:(=), sni_method, Expr(:block, _lnn, true)))
                end
                push!(block.args, isdoc_expr...)
                !isnothing(desc_expr) && push!(block.args, desc_expr...)
                block
            end
            for (name, info) in oproperties if !isfixed(info)
        ]...,
        # IndexableProperty wrappers for indexed properties are now created
        # directly in getorcomputeproperty (via meta check), so no zero-arg
        # compute_property methods are needed here.
    ))
    # Emit inline-method definitions collected from the struct body. These are
    # plain methods on `::type` (so standard multiple dispatch on the remaining
    # args works) — no property entry, no compute_property, not reachable via
    # getproperty. Preserve the user's complete signature, changing only a bare
    # positional `__self__` to `__self__::<type>`. The body is walked with the
    # `prop_names` set so bare references to registered property names are
    # rewritten to `__self__.<name>`, matching the property-RHS rewrite.
    for m in inline_methods
        sig = deepcopy(m.signature)
        call = something(_inline_method_call(sig))
        sig_args = call.args[2:end]
        # Type the bare `__self__` arg to `__self__::<type>`. If the user
        # already wrote `__self__::T`, leave the user's annotation alone.
        if sig_args[m.self_idx] === :__self__
            call.args[m.self_idx + 1] = :(__self__::$type)
            sig_args = call.args[2:end]
        end
        # Locals shielded from bare-name rewriting: `__self__`, every name
        # introduced by the signature args (incl. typed/destructured/kw),
        # and all `where`-clause type parameters.
        method_locals = Set{Symbol}([:__self__])
        for a in sig_args
            union!(method_locals, extractnames([a]))
        end
        for wp in m.where_params
            wp isa Symbol && push!(method_locals, wp)
            Meta.isexpr(wp, :(<:)) && wp.args[1] isa Symbol && push!(method_locals, wp.args[1])
            Meta.isexpr(wp, :comparison) && wp.args[1] isa Symbol && push!(method_locals, wp.args[1])
        end
        walked_body = walk_rhs(m.body; locals=method_locals, properties=walk_props, lnn=m.lnn)
        method_lnn = something(m.lnn, LineNumberNode(0, :unknown))
        push!(result.args, Expr(:(=), sig, Expr(:block, method_lnn, walked_body)))
    end
    esc(result)
end

# Replace only the top-level LineNumberNodes in a block, leaving nested ones intact.
# This gives Revise the source-location metadata it needs to track method changes,
# while preserving internal LineNumberNodes for useful stacktraces.
function setlnn(lnn::Union{LineNumberNode,Nothing})
    function(expr::Expr)
        isnothing(lnn) && return expr
        @assert expr.head == :block
        Expr(:block, map(x -> _replace_lnn(x, lnn), expr.args)...)
    end
end

# The `cache_type` MACRO option (a bare `:parallel`/`:serial`, or `cache_type=…`)
# was removed 2026-07-07 (decision 2canrl) — the cache is always a `ThreadsafeDict`
# now. Reject it at macro-parse with a clear message (mirrors the ctor-kwarg
# deprecation) rather than letting it fall through to an opaque unsupported-kwarg
# error. `_parse_macro_opt` is a plain function the macro calls at expansion.
_reject_cache_type_opt() = error("@dynamicstruct: the `cache_type` macro option was removed (2026-07-07, decision 2canrl); the cache is always threadsafe (`ThreadsafeDict`) now — drop it.")

# Parse a single positional macro arg into a (kwarg-name => value) pair.
# `name=value` Expr → `(name => value)`. String/`:string` → `(:docstring => …)`.
# Anything else is rejected with a pointer to the recognised forms.
_parse_macro_opt(a::AbstractString) = (:docstring => a)
_parse_macro_opt(a::QuoteNode) = _reject_cache_type_opt()
_parse_macro_opt(a::Expr) = if a.head === :string
    (:docstring => a)
elseif a.head === :(=) && a.args[1] isa Symbol
    a.args[1] === :cache_type && _reject_cache_type_opt()
    (a.args[1] => a.args[2])
else
    error("@dynamicstruct: unsupported option `$a` — use a docstring or `name=value`.")
end
_parse_macro_opt(a) = error("@dynamicstruct: unsupported option `$a` — use a docstring or `name=value`.")

"""
    @dynamicstruct [docstring] struct Name
        field                     # fixed field (constructor argument)
        prop = expr               # lazily computed property
        @cached prop = expr       # lazily computed + disk-cached property
        prop(idx) = expr          # indexable property (cached per args; `@fresh` to bypass)
        prop(args...; kw...) = expr  # indexable property (cached per args; `@fresh` to bypass)
        @cached prop(idx) = expr  # indexable + disk-cached property (cached per index)
    end

Define a struct whose *fixed fields* are set at construction time and whose
*derived properties* are computed lazily on first access and then stored in an
in-memory cache.

Derived properties may reference any other field or property by name; the
reference is automatically rewritten to `__self__.<name>`.  Order of definition
does not matter — cycles will result in a stack overflow at runtime.

The in-memory cache is always a `ThreadsafeDict` — safe to access from multiple
tasks simultaneously; duplicate work is avoided by sharing in-flight `Task`s.

Properties marked `@cached` are additionally persisted to disk under
`__self__.__cache_path__` (which itself defaults to
`joinpath(__self__.__cache_base__, __self__.__hash__)`).

Keyword arguments passed to the constructor pre-populate the cache, so they act
as overrides for any computed property.

# Examples
```julia
using DynamicObjects

@dynamicstruct struct Point
    x::Float64
    y::Float64
    r     = sqrt(x^2 + y^2)
    theta = atan(y, x)
end

p = Point(3.0, 4.0)
p.r      # 5.0
p.theta  # atan(4, 3)
```

```julia
# Disk-cached expensive computation.
# cache_path defaults to joinpath("cache", hash(n)), so two Experiment(n)
# instances with the same n share the same cache directory.
@dynamicstruct struct Experiment
    n::Int
    @cached result = sum(rand(n))   # computed once, then loaded from disk
end

e = Experiment(1_000_000)
e.result   # computed on first access, cached to disk
e2 = Experiment(1_000_000)
e2.result  # loaded from disk (same n → same hash → same cache path)
```

```julia
# Indexed properties. `obj.prop(args)` caches by default; `@fresh obj.prop(args)` recomputes.
# Properties reference each other by bare name (auto-rewritten to __self__.<name>).
@dynamicstruct struct DataSet
    items = ["apple", "banana", "cherry"]
    matches(query)   = filter(x -> occursin(query, x), items)   # call: cached per query
    top(query; n=1)  = first(matches(query), n)                 # call with kwargs
end

ds = DataSet()
ds.matches("an")        # ["banana"] — cached in the per-property dict (keyed by args)
@fresh ds.matches("an")  # ["banana"] — recomputed fresh, bypassing the cache
fresh(ds.matches, "an")  # ["banana"] — explicit uncached call (outside a @dynamicstruct body)
ds.top("a"; n=2)        # ["apple", "banana"] — kwargs supported
```

# Async progress with `__status__`

Indexed properties spawn background `Task`s, and progress is wired into them
automatically: `__status__` defaults to a `Treebars.initialize_progress!(:state;
description="")` root, and the default `__substatus__` hangs a child node under
it per property compute. Declare `__status__` only to *label* the root (an empty
description makes it a structural node that renders nothing and hoists its
children), or set it to `nothing` to switch progress off.

Like any `x = y` in a struct body, that declaration is an overrideable default:
a constructor kwarg seeds the cache and wins. `@include kid = Child()` therefore
mounts the child under the parent's tree whatever `Child` declares; pass
`@include kid = Child(; __status__ = nothing)` to silence that subtree instead.

```julia
@dynamicstruct struct MyApp
    __status__ = initialize_progress!(:state; description="MyApp")  # optional: labels the root
    results(key) = expensive_computation(__status__)  # __status__ is the substatus
end
app = MyApp()

# Non-blocking access with progress:
fetchindex(app.results, key) do rv, status
    rv isa Pending ? render_progress(status) : render_result(rv)
end
```

`__substatus__` is called before each compute begins.
`name` is the property symbol, `args`/`kwargs` are the indices. The returned
object is stored in `ThreadsafeDict.status` (accessible via `getstatus`) and
passed to the computation body as the local `__status__`.

`__substatus__` fires on every generated-property compute — indexed (`memoize!`)
and bare scalar (`_bare_substatus_f`) alike. It is skipped for dunder properties
(`__hash__`, `__status__`, …) and for fixed struct fields, which have no body.

An undocumented property gets `description=""`, i.e. a structural node that
renders nothing and hoists its children; add a docstring to make it a labelled
row in the tree.
"""
macro dynamicstruct(args...)
    isempty(args) && error("@dynamicstruct: missing struct definition.")
    expr = last(args)
    kwargs = Dict{Symbol,Any}(_parse_macro_opt(a) for a in args[1:end-1])
    dynamicstruct(expr; kwargs...)
end

# --- `remake` carry-over machinery (decision yf4z8x) ---
# `_carryover(obj, Val(KW))` returns a NamedTuple of the source's memoized
# bare-property values that survive a `remake` whose changed kwargs are `KW` —
# every carry-eligible property none of whose invalidating fixed fields is in
# `KW`. `@dynamicstruct` bakes a per-type method with each property's
# invalidators as a literal, so the `isdisjoint` gate below const-folds per
# call; this generic fallback (untyped `Val`) carries nothing.
_carryover(obj, ::Val) = (;)
@inline _carry1(obj, ::Val{KW}, ::Val{P}, ::Val{INV}) where {KW,P,INV} =
    isdisjoint(KW, INV) ? _carry_if_settled(obj, Val(P)) : (;)
struct _CarryMiss end
const _CARRY_MISS = _CarryMiss()
# Peek the source cache without triggering compute/wait; carry only a settled
# value (skip an in-flight `Pending` handle from the compute-at-most-once latch).
@inline function _carry_if_settled(obj, ::Val{P}) where {P}
    v = get(getfield(obj, :cache).cache, P, _CARRY_MISS)
    (v === _CARRY_MISS || v isa Pending) ? (;) : NamedTuple{(P,)}((v,))
end

"""
    remake(obj; kwargs...)

Create a new instance of the same `@dynamicstruct` type as `obj`, copying all
fixed fields from `obj` and overriding any specified via keyword arguments.

Keyword arguments that correspond to fixed fields replace those field values in
the new instance. Any remaining keyword arguments are forwarded to the
constructor as cache pre-population overrides.

Because a `@dynamicstruct` is a pure function of its fixed fields, any already
memoized property of `obj` whose (transitive) fixed-field dependencies are all
unchanged is **carried over** to the new instance instead of being recomputed —
the per-type carry set is baked from the `dependson` graph at macro-expansion,
so the decision costs nothing at runtime. Impure properties (reading `rand`, the
clock, or external mutable state) violate this contract and must not be relied
on across `remake`.

# Example
```julia
@dynamicstruct struct Config
    n::Int
    scale::Float64
    base = sum(1:n)          # depends only on n
    result = scale * base    # depends on scale (and, transitively, n)
end

c  = Config(100, 2.0); c.result   # memoizes base + result
c2 = remake(c; scale=3.0)  # n unchanged → `base` CARRIED over; `result` recomputed
c3 = remake(c; n=200)      # n changed → both base & result recomputed
c4 = remake(c; result=0.0) # result pre-set to 0.0 (explicit override wins)
```
"""
remake(obj; kwargs...) = _remake(obj, values(kwargs))
function _remake(obj::T, nt::NamedTuple{KW}) where {T,KW}
    fixed = fieldnames(T)[1:end-1]               # all fields except :cache
    args = Any[haskey(nt, n) ? nt[n] : getfield(obj, n) for n in fixed]
    # Reuse the source's still-valid memoized properties; explicit cache
    # pre-population kwargs (non-fixed-field) override any carried value.
    carried = _carryover(obj, Val(KW))
    explicit = Base.structdiff(nt, NamedTuple{fixed})
    T(args...; carried..., explicit...)
end

# --- immutable cache remounting ------------------------------------------------

# These properties define the retained object's disk/materialization identity or
# global cache policy. Rebinding one while sharing the intrinsic cache is a
# contradiction; `remake` is the operation for constructing a new identity.
const _REMOUNT_INTRINSIC_KEYS = (
    :__hash_fields__, :__hash__, :__identity_hash__, :__version_tag__,
    :__cache_base__, :__cache_path__, :__hold_recent_version__, :__strict__,
)

function _remount_source(obj)
    hasfield(typeof(obj), :cache) || error("remount: $(typeof(obj)) is not a @dynamicstruct type")
    pc = getfield(obj, :cache)
    pc isa PropertyCache || error("remount: $(typeof(obj)) does not carry a DynamicObjects PropertyCache")
    c = pc.cache
    if c isa MountedThreadsafeDict
        return c.source, c.shared
    elseif c isa ThreadsafeDict{Symbol,Any}
        return obj, c
    end
    error("remount: $(typeof(obj)) uses unsupported cache $(typeof(c)); remount requires the current threadsafe cache")
end

function _validate_remount_keys(source, changed)
    T = typeof(source)
    fixed = Set(fieldnames(T)[1:end-1])
    changed_fixed = sort!(collect(intersect(Set(changed), fixed)))
    isempty(changed_fixed) || error(
        "remount: fixed field(s) $(join(changed_fixed, ", ")) define object identity; use remake for fixed-field changes")
    intrinsic = sort!(collect(intersect(Set(changed), Set(_REMOUNT_INTRINSIC_KEYS))))
    isempty(intrinsic) || error(
        "remount: intrinsic cache/version property(s) $(join(intrinsic, ", ")) cannot be rebound while retaining cache identity; use remake")
    unknown = sort!(Symbol[n for n in changed if !hasproperty(source, n)])
    isempty(unknown) || error(
        "remount: unknown context property/properties $(join(unknown, ", ")) on $(nameof(T))")
    versioned = Set{Symbol}()
    for (name, info) in meta(T)
        Symbol("@versioned") in get(info, :macros, Set{Symbol}()) && push!(versioned, name)
    end
    changed_versioned = sort!(collect(intersect(Set(changed), versioned)))
    isempty(changed_versioned) || error(
        "remount: @versioned property/properties $(join(changed_versioned, ", ")) define persisted content identity; use remake")
    nothing
end

# Return (invalidated values, local wrapper keys). `invalidated` is the sound
# transitive closure rooted at explicit context overrides, fresh progress state,
# opaque self-reaches, and nested children (which retain their parent object).
# Indexed wrapper KEYS are always local so their `o` is the mounted object; an
# indexed property's per-argument subcache is shared only when that property is
# absent from `invalidated` (see the mounted `subcache` method above).
function _remount_partition(source, shared::ThreadsafeDict{Symbol,Any}, changed,
                            forced_local=())
    T = typeof(source)
    dependencies = Dict{Symbol,Set{Symbol}}()
    computed = Set{Symbol}()
    indexed = Set{Symbol}()
    names = Set{Symbol}()
    for (name, info) in meta(T)
        push!(names, name)
        get(info, :rhs, nothing) === nothing || push!(computed, name)
        get(info, :indexed, false) && push!(indexed, name)
        deps = get(info, :dependson, nothing)
        deps === nothing || union!(get!(() -> Set{Symbol}(), dependencies, name), deps)
    end

    invalidated = union(Set{Symbol}(changed), Set{Symbol}(forced_local))
    # Progress/status is request-scoped state even when the caller doesn't pass
    # it explicitly. Keeping it local also prevents a mounted request from
    # relabelling/reparenting the retained graph's progress tree on cache hits.
    for name in (:__status__, :__substatus__)
        hasproperty(source, name) && push!(invalidated, name)
    end
    # Every nested child retains `__parent__`; never share a child instance whose
    # parent is the retained source object with a mounted view.
    for name in names
        _nested_struct_type(T, Val(name)) === nothing || push!(invalidated, name)
    end
    opaque = _remount_opaque_properties(T)
    opaque === nothing ? union!(invalidated, computed) : union!(invalidated, opaque)

    changed_graph = true
    while changed_graph
        changed_graph = false
        for (name, deps) in dependencies
            name in invalidated && continue
            if !isdisjoint(deps, invalidated)
                push!(invalidated, name)
                changed_graph = true
            end
        end
    end

    local_names = copy(invalidated)
    for name in indexed
        value = get(shared, name, _missing_sentinel)
        (value === _missing_sentinel || value isa IndexableProperty) && push!(local_names, name)
    end
    invalidated, local_names
end

_remount_invalidated(o, name::Symbol) = begin
    hasfield(typeof(o), :cache) || return false
    pc = getfield(o, :cache)
    pc isa PropertyCache || return false
    c = pc.cache
    c isa MountedThreadsafeDict && name in c.invalidated
end

_is_dynamic_object(value) = hasfield(typeof(value), :cache) &&
    getfield(value, :cache) isa PropertyCache

# Bind the context DO itself understands structurally. `__req__` is identical
# through a routed request and can be copied from the current parent; `__prefix__`
# is route-relative, so mask the retained value and let the child's own generated
# property recompute it from its new `__parent__`.
function _remount_child(child, parent)
    pairs = Pair{Symbol,Any}[]
    hasproperty(child, :__parent__) && push!(pairs, :__parent__ => parent)
    if hasproperty(child, :__req__) && hasproperty(parent, :__req__)
        push!(pairs, :__req__ => getproperty(parent, :__req__))
    end
    context = (; pairs...)
    forced = hasproperty(child, :__prefix__) ? (:__prefix__,) : ()
    _remount_impl(child, context, forced)
end

function _seed_nested_remounts!(mounted, source, explicit)
    T = typeof(source)
    shared = _remount_source(source)[2]
    seen = Set{Symbol}()
    for (name, _) in meta(T)
        name in seen && continue
        push!(seen, name)
        haskey(explicit, name) && continue
        _nested_struct_type(T, Val(name)) === nothing && continue
        value = get(shared, name, _missing_sentinel)
        (value === _missing_sentinel || value isa Pending || value isa IndexableProperty ||
         !_is_dynamic_object(value)) && continue
        setproperty!(mounted, name, _remount_child(value, mounted))
    end
    mounted
end

"""
    remount(obj; context...)

Return an immutable, same-type view of `obj` with fresh context properties while
retaining the cache identity of unrelated model work. This is the request/job
counterpart to [`remake`](@ref): `remake` constructs a new value and copies only
settled dependency-safe results, whereas `remount` keeps the retained cache's
settled values, in-flight latches/[`Pending`](@ref) handles, mmap values, version
identity, and indexed subcaches for every property proven independent of the
rebound context.

The keyword names are existing non-fixed properties such as `__parent__`,
`__req__`, or `__prefix__`. They, every transitive dependent in `meta(T)`, every
opaque self-dependent property, progress state, and nested child are routed to a
fresh mount-local cache. Each mounted [`IndexableProperty`](@ref) wrapper is
recreated with the mounted owner; its per-argument cache is shared only when the
property is context-independent. Context-dependent `@cached`/`@mmap` properties
bypass their intrinsic disk entry because the rebound context is intentionally
not part of the retained disk identity.

Fixed fields, `@versioned` properties, and cache/hash/path dunders are rejected:
changing any of those means the object identity changed, so use `remake`.

# Example
```julia
routed = ModelGraph(...)
request_a = remount(routed; __req__=req_a, __parent__=parent_a, __prefix__="/a")
request_b = remount(routed; __req__=req_b, __parent__=parent_b, __prefix__="/b")
```
"""
function _remount_impl(obj, nt::NamedTuple, forced_local=())
    source, shared = _remount_source(obj)
    changed = keys(nt)
    _validate_remount_keys(source, changed)
    invalidated, local_names = _remount_partition(source, shared, changed, forced_local)
    mounted = MountedThreadsafeDict(shared, source, local_names, invalidated, nt)
    pc = PropertyCache(mounted)
    T = typeof(source)
    fixed = fieldnames(T)[1:end-1]
    args = Any[getfield(source, name) for name in fixed]
    applicable(T, _REMOUNT_TOKEN, pc, args...) || error(
        "remount: $(nameof(T)) was expanded before remount support; re-expand its @dynamicstruct/@htmx definition")
    view = T(_REMOUNT_TOKEN, pc, args...)
    _seed_nested_remounts!(view, source, nt)
end

function remount(obj; kwargs...)
    _remount_impl(obj, values(kwargs))
end

# --- Error display for property computations ---

"""
    PropertyComputationError <: Exception

Wraps an error that occurred during lazy property computation, adding context
about which property failed (property name, type, indices/kwargs). The original
exception and backtrace are stored in the `cause` field.
"""
struct PropertyComputationError <: Exception
    type_name::String
    property::Symbol
    indices::Tuple
    kwargs::Tuple  # tuple of pairs
    cause::Any
end

"""
    unwrap_error(e)

Recursively unwrap `TaskFailedException`, `CompositeException`, and
`PropertyComputationError` wrappers to find the root cause exception.
"""
unwrap_error(e::Base.TaskFailedException) = unwrap_error(e.task.exception)
unwrap_error(e::CompositeException) = unwrap_error(first(e.exceptions))
unwrap_error(e::PropertyComputationError) = unwrap_error(_cause_error(e))
unwrap_error(e) = e

# Extract the exception from cause (which may be a (exception, backtrace) tuple)
_cause_error(e::PropertyComputationError) = _unwrap_cause(e.cause)
_unwrap_cause(c::Tuple) = first(c)
_unwrap_cause(c) = c
_cause_bt(c::Tuple) = length(c) >= 2 ? c[2] : nothing
_cause_bt(_) = nothing

# Compact, truncated repr for error messages — avoids dumping huge DataFrames/
# arrays that happen to be passed as property arguments. Small values (numbers,
# strings, symbols) render identically to `repr`; large/multi-line values
# collapse to a one-line `summary`-style snippet.
function _short_repr(v; limit=120)
    s = sprint(show, v; context=(:limit => true, :compact => true, :displaysize => (3, limit)))
    nl = findfirst('\n', s)
    isnothing(nl) || (s = summary(v))
    length(s) > limit ? first(s, limit - 1) * "…" : s
end

function _format_property_key(name, indices, kwargs)
    s = string(name)
    pos_parts = !isempty(indices) ? _short_repr.(collect(indices)) : String[]
    kw_parts = ["$k=$(_short_repr(v))" for (k, v) in kwargs]
    all_parts = isempty(pos_parts) && !isempty(kw_parts) ?
        ["; " * join(kw_parts, ", ")] :
        vcat(pos_parts, isempty(kw_parts) ? String[] : ["; " * join(kw_parts, ", ")])
    isempty(all_parts) ? s : s * "(" * join(all_parts, ", ") * ")"
end

function Base.showerror(io::IO, e::PropertyComputationError)
    key = _format_property_key(e.property, e.indices, e.kwargs)
    print(io, "PropertyComputationError: computing `$key` on $(e.type_name)\n")
    cause_err = _cause_error(e)
    cause_bt = _cause_bt(e.cause)
    print(io, "  Caused by: ")
    _show_cause(io, cause_err, cause_bt)
end
# PropertyComputationError prints its own filtered backtrace via the 2-arg
# showerror; nested ones must use that path. Otherwise prefer the 3-arg form
# when a backtrace is available.
_show_cause(io, err::PropertyComputationError, _bt) = showerror(io, err)
_show_cause(io, err, ::Nothing) = showerror(io, err)
_show_cause(io, err, bt) = showerror(io, err, bt)

# ---------- print_structure ----------------------------------------------------
# Programmatic rendering of a DO/HTMXO type's structure, suitable for spotting
# IPs, inline children, routes, @param decls, and constructor fields at a glance.
# Walks `meta(T)` for properties + `_nested_struct_type(T, Val(name))` for inline
# children. HTMXO-specific introspection (`_param_names`, route macro tags) is
# read defensively so DO-only types print cleanly too.

const _PRINT_STRUCT_ROUTE_MACROS = Set([
    Symbol("@get"), Symbol("@post"), Symbol("@put"),
    Symbol("@patch"), Symbol("@delete"), Symbol("@ws"),
])

# Skip auto-generated and DO-internal property names. Dunder names
# (`__self__`, `__parent__`, `__status__`, …) are normally hidden, but
# `prop::T = rhs` registrations on a dunder name (e.g. `__appdata__::AppData`)
# represent a real user-declared nested DO subtree the user wants to see —
# the registered `_nested_struct_type` is the signal.
_print_struct_skip(::Type{T}, name::Symbol) where {T} = begin
    s = String(name)
    is_dunder = startswith(s, "__") && endswith(s, "__")
    is_dunder && _walk_nested_type(T, name) !== nothing && return false
    is_dunder ||
        startswith(s, "_tuple_") ||
        name === :__hash_fields__ ||
        name === :__cache_path__ ||
        name === :__hash__ ||
        name === :cache
end

# A property whose RHS is just `__parent__.something` — auto-forwarded into an
# inline child by the macro. Not a user-authored property of the child.
_print_struct_is_forwarded(rhs) =
    Meta.isexpr(rhs, :.) && length(rhs.args) == 2 &&
    rhs.args[1] === :__parent__ && rhs.args[2] isa QuoteNode

# Compact one-line render of a default expression — chops noisy whitespace.
_print_struct_short(x) = replace(string(x), r"\s+" => " ")

# Defensive HTMXO `_param_names(T)` lookup — the function lives in HTMXObjects;
# DO-only types don't have it. Empty tuple if the binding isn't loaded.
function _print_struct_param_names(T::Type)
    htmxo = get(Base.loaded_modules,
        Base.PkgId(Base.UUID("b12ef442-5798-4353-80f3-9562b03a0cb6"),
                   "HTMXObjects"),
        nothing)
    htmxo === nothing && return ()
    isdefined(htmxo, :_param_names) || return ()
    try htmxo._param_names(T) catch; () end
end

# --- IP arg worst-case dependency bound ---------------------------------------
# For each IP, find its call sites in the DO tree. Each caller is some property
# of some type. Take the union of every caller's *static identity scope* — its
# own IP positional args, plus the ancestor types' constructor fields and
# `@param` names walking up to root. That set is an honest *upper bound*: the
# IP arg's value can be derived from no more than these names (modulo dynamic
# inputs from outside the tree, like HTTP request bodies).
#
# Static and cheap — no AST walking of caller bodies, no dataflow, no
# substitution. The annotation reads "at most depends on {names}", which is
# what `print_structure` advertises.

# Extract bare positional arg names from an `info.indices` tuple. Drops kwargs
# (the `:parameters` slot) and unwraps `name::T` annotations.
function _ip_positional_args(indices)
    names = Symbol[]
    for idx in indices
        Meta.isexpr(idx, :parameters) && continue
        n = Meta.isexpr(idx, :(::)) ? idx.args[1] : idx
        n isa Symbol && push!(names, n)
    end
    names
end

# Reachable types from a root via _nested_struct_type. Used to bound the
# call-site search so we don't chase outside the DO tree print_structure
# is rendering.
function _all_types_in_tree(root::Type)
    seen = Set{Type}([root])
    queue = Type[root]
    while !isempty(queue)
        T = popfirst!(queue)
        props = try meta(T) catch; nothing end
        props === nothing && continue
        seen_names = Set{Symbol}()
        for (name, _) in props
            name in seen_names && continue
            push!(seen_names, name)
            nested = _walk_nested_type(T, name)
            nested === nothing && continue
            nested in seen && continue
            push!(seen, nested)
            push!(queue, nested)
        end
    end
    seen
end

# Map child_type → (parent_type, prop_name_in_parent) — built by walking the
# tree from the root via `_nested_struct_type`. Lets us climb the type chain
# for static-scope lookup. The root has no entry in this map.
function _build_parent_map(root::Type)
    parents = Dict{Type, Tuple{Type, Symbol}}()
    seen = Set{Type}([root])
    queue = Type[root]
    while !isempty(queue)
        T = popfirst!(queue)
        props = try meta(T) catch; nothing end
        props === nothing && continue
        seen_names = Set{Symbol}()
        for (name, _) in props
            name in seen_names && continue
            push!(seen_names, name)
            nested = _walk_nested_type(T, name)
            nested === nothing && continue
            nested in seen && continue
            push!(seen, nested)
            push!(queue, nested)
            parents[nested] = (T, name)
        end
    end
    parents
end

# Names visible as "root identity" at a property body inside type T:
# constructor fields and `@param` names, walking parent_map up to root. If
# `T` is reached via an IP property of its parent, that IP's positional arg
# names are also in scope.
function _enclosing_scope(T::Type, parents)
    names = Set{Symbol}()
    cur = T
    while true
        for f in fieldnames(cur)
            f === :cache && continue
            s = String(f)
            (startswith(s, "__") && endswith(s, "__")) && continue
            push!(names, f)
        end
        for p in _print_struct_param_names(cur)
            push!(names, p)
        end
        haskey(parents, cur) || break
        parent_T, parent_prop = parents[cur]
        try
            # `metafirst` is fine: scope walk only needs one parent IP's positional
            # args; if duplicate declarations ever exist they share the IP signature.
            info = metafirst(parent_T, parent_prop)
            if info !== nothing
                for a in _ip_positional_args(info.indices)
                    push!(names, a)
                end
            end
        catch
        end
        cur = parent_T
    end
    names
end

# Dot-chain leftmost Symbol — `render.stan.code` → `:render`; bare `code` →
# `:code`. `nothing` for non-symbol roots.
function _dot_chain_root(expr)
    expr isa Symbol && return expr
    Meta.isexpr(expr, :., 2) && return _dot_chain_root(expr.args[1])
    nothing
end

# Conservative call-site detector: matches `target(…)` and `parent.target(…)`
# only when the leftmost symbol resolves to a property of the caller's type
# or one of the macro-injected names. Excludes unrelated namespaces (`h.code`,
# `Base.length`, …) that happen to share a property name.
function _has_call_to(expr, target::Symbol, cprops)
    expr isa Expr || return false
    if Meta.isexpr(expr, :call) && length(expr.args) >= 1
        callee = expr.args[1]
        if callee === target
            cprops !== nothing && _cprops_has(cprops, target) && return true
        elseif Meta.isexpr(callee, :., 2) && callee.args[2] isa QuoteNode &&
               callee.args[2].value === target
            root = _dot_chain_root(callee.args[1])
            if root !== nothing &&
               (root === :__self__ || root === :__parent__ || root === :__appdata__ ||
                (cprops !== nothing && _cprops_has(cprops, root)))
                return true
            end
        end
    end
    for a in expr.args
        _has_call_to(a, target, cprops) && return true
    end
    false
end

# Scope of a caller property: enclosing static scope of its type, plus its own
# IP positional args (so `name` from `@get stage(name)` flows through into the
# bound for any IP called from inside `stage`'s body).
function _caller_scope(caller_T::Type, caller_prop::Symbol, parents)
    names = _enclosing_scope(caller_T, parents)
    info = try metafirst(caller_T, caller_prop) catch; nothing end
    if info !== nothing
        for a in _ip_positional_args(info.indices)
            push!(names, a)
        end
    end
    names
end

# Raw worst-case bound — the union of callers' static identity scopes,
# possibly containing intermediate IP-arg names (like `bundle` from an
# enclosing IP). `_print_struct_worst_case` expands these to root identities.
function _raw_worst_case(types_in_tree, parents, T::Type, prop_name::Symbol, info)
    isempty(_ip_positional_args(info.indices)) && return nothing
    callers = Set{Tuple{Type,Symbol}}()
    for U in types_in_tree
        uprops = try meta(U) catch; nothing end
        uprops === nothing && continue
        for (uname, uinfo) in uprops
            uinfo.rhs === nothing && continue
            (U === T && uname === prop_name) && continue
            _has_call_to(uinfo.rhs, prop_name, uprops) || continue
            push!(callers, (U, uname))
        end
    end
    isempty(callers) && return (:none,)
    bound = Set{Symbol}()
    for (cT, cp) in callers
        union!(bound, _caller_scope(cT, cp, parents))
    end
    (:bound, sort!(collect(bound)))
end

# Expand a single name to its root identities (@param / field / unbounded
# IP arg). If the name is itself an IP arg with an in-tree caller bound,
# recurse into that bound. Cycle protection via `visited`.
function _expand_name!(out::Set{Symbol}, name::Symbol,
                      types_in_tree, parents, visited::Set{Symbol})
    name in visited && return
    push!(visited, name)
    # Root identity: @param or constructor field anywhere in the tree.
    for T in types_in_tree
        for f in fieldnames(T)
            f === name && (push!(out, name); return)
        end
        for p in _print_struct_param_names(T)
            p === name && (push!(out, name); return)
        end
    end
    # IP arg: replace with its IP's bound (recursively).
    for T in types_in_tree
        props = try meta(T) catch; nothing end
        props === nothing && continue
        for (pn, pinfo) in props
            for a in _ip_positional_args(pinfo.indices)
                a === name || continue
                raw = _raw_worst_case(types_in_tree, parents, T, pn, pinfo)
                if raw !== nothing && raw[1] === :bound
                    for n in raw[2]
                        _expand_name!(out, n, types_in_tree, parents, visited)
                    end
                else
                    # IP has no in-tree callers — treat as root.
                    push!(out, name)
                end
                return
            end
        end
    end
    # Unrecognized — keep as-is.
    push!(out, name)
end

# Public worst-case bound: returns the EXPANDED form. Every name in the
# result is a root identity (@param, field, or IP arg of an unbounded IP);
# intermediate IP-arg names are unfolded to their own bounds.
# Memoized expanded worst-case bound. `analyze_structure` / `structure(T)`
# invoke this from multiple call sites for the same (T, prop) — bound-group
# precompute, hierarchical-placement check, and render annotations. Without
# caching we re-walk the whole `types_in_tree × props_per_type` cross product
# several times.
#
# Cache is **per-call**, passed explicitly. No global state — concurrent
# requests get their own cache so there are no races on `setindex!` / shared
# entries. The default-arg form creates a fresh dict for callers that don't
# care about cross-call reuse; hot callers inside `analyze_structure` /
# `_build_structure` thread a single dict through to amortize the work.
const _WCCache = IdDict{Tuple{Type,Symbol}, Any}

_print_struct_worst_case(types_in_tree, parents, T::Type, prop_name::Symbol, info) =
    _print_struct_worst_case(types_in_tree, parents, T, prop_name, info, _WCCache())

function _print_struct_worst_case(types_in_tree, parents, T::Type,
                                  prop_name::Symbol, info, cache::_WCCache)
    key = (T, prop_name)
    haskey(cache, key) && return cache[key]
    raw = _raw_worst_case(types_in_tree, parents, T, prop_name, info)
    result = if raw === nothing
        nothing
    elseif raw[1] === :none
        raw
    else
        expanded = Set{Symbol}()
        for n in raw[2]
            _expand_name!(expanded, n, types_in_tree, parents, Set{Symbol}())
        end
        (:bound, sort!(collect(expanded)))
    end
    cache[key] = result
    result
end

# --- Identity coloring --------------------------------------------------------
# Each "scope identifier" (constructor field, @param name, IP positional arg)
# is colored deterministically by its name so the same name reads as the same
# color everywhere it appears — in `fields:` / `@param:` lists, in IP
# signatures, and in worst-case bound sets. Lets you visually trace bonds:
# spot `formula` once, then scan for matching color anywhere else.

# 32 vivid full-spectrum hues — saturation high enough that adjacent
# identities are easy to tell apart at a glance. Identity coloring is
# applied as an underline-only mark (`Semantic{:underlined}`), not as
# foreground text color, so bright/saturated values are fine — the text
# itself stays at default contrast. Stored as `#rrggbb` so they drop into
# CSS directly and need only a hex→RGB parse for the terminal's truecolor
# escape.
const _IDENT_PALETTE = (
    "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf",
    "#aec7e8", "#ffbb78", "#98df8a", "#ff9896", "#c5b0d5",
    "#c49c94", "#f7b6d2", "#c7c7c7", "#dbdb8d", "#9edae5",
    "#393b79", "#637939", "#8c6d31", "#843c39", "#7b4173",
    "#5254a3", "#8ca252", "#bd9e39", "#ad494a", "#a55194",
    "#6b6ecf", "#cedb9c",
)

# Color-by-bound: each name in the tree maps to a *fingerprint* — its upstream
# worst-case bound set if it's an IP positional arg, or its own name (treated
# as a root identity) if it's a @param / fixed field / IP arg without callers.
# Two names with the same fingerprint render in the same color, so two args
# named differently but with identical upstream identity slices (`bundle1` /
# `bundle2`) still bound visually.
#
# The fingerprint approach over-groups in the worst case (two unrelated args
# that happen to share the same upstream scope collide), but matches the
# "same identity = same color" intent the static analyzer can actually
# justify, with no dataflow cost.
function _build_color_map(root::Type)
    types_in_tree = _all_types_in_tree(root)
    parent_map = _build_parent_map(root)
    # Pass 1 — collect all names that exist in the tree and assign each its
    # fingerprint. Root identities (@params, fixed fields) fingerprint as
    # singletons; IP args with a tightenable bound fingerprint as the bound.
    fingerprint = Dict{Symbol, Any}()
    function set_root!(n::Symbol)
        # Root identities take precedence over IP-arg-bound fingerprints when
        # the same name appears in both roles — a @param IS its own identity.
        fingerprint[n] = (:name, n)
    end
    visited = Set{Type}()
    function visit_type(T)
        T in visited && return
        push!(visited, T)
        for f in fieldnames(T)
            f === :cache && continue
            s = String(f); (startswith(s, "__") && endswith(s, "__")) && continue
            set_root!(f)
        end
        for p in _print_struct_param_names(T); set_root!(p); end
        props = try meta(T) catch; nothing end
        props === nothing && return
        # Color fingerprint cares about per-name identity; iterate the unique
        # names in the order `meta(T)` declared them (sorted for stable color
        # assignment), then look up the first matching info.
        seen_names = Set{Symbol}()
        unique_names = Symbol[]
        for (n, _) in props
            n in seen_names && continue
            push!(seen_names, n); push!(unique_names, n)
        end
        for name in sort!(unique_names)
            _print_struct_skip(T, name) && continue
            info = metafirst(T, name)
            args = _ip_positional_args(info.indices)
            if !isempty(args)
                wc = _print_struct_worst_case(types_in_tree, parent_map, T, name, info)
                fp = (wc !== nothing && wc[1] === :bound) ?
                     (:bound, Tuple(wc[2])) : nothing
                for a in args
                    haskey(fingerprint, a) && continue   # @param/field wins
                    fingerprint[a] = fp === nothing ? (:name, a) : fp
                end
            end
            nested = _walk_nested_type(T, name)
            nested === nothing || visit_type(nested)
        end
    end
    visit_type(root)
    # Pass 2 — assign each unique fingerprint a hex color in stable order
    # (sorted by name of the first member to encounter it).
    fp_to_idx = Dict{Any, Int}()
    name_to_color = Dict{Symbol, String}()
    for n in sort!(collect(keys(fingerprint)))
        fp = fingerprint[n]
        idx = get!(fp_to_idx, fp, length(fp_to_idx) + 1)
        name_to_color[n] = _IDENT_PALETTE[mod1(idx, length(_IDENT_PALETTE))]
    end
    name_to_color
end

# --- Structured representation ------------------------------------------------
# A minimal HTML-tag-shaped DOM. `Tag` is a Symbol type parameter (Val-like,
# so dispatch happens at compile time); `content` is whatever the tag holds
# (string, single node, vector of nodes, or nothing); `attributes` is a
# NamedTuple of HTML-style attrs (`class="…"`, `color=…`, etc.).
#
# Generic HTML rendering is `<tag attrs>content</tag>` — overrides per tag
# when the default isn't right. Markdown / terminal fall back to "just emit
# the content" with overrides for the tags that actually carry meaning in
# those formats (`:strong` → ANSI bold / `**…**`; etc.).

abstract type AbstractNode end

struct Node{Tag, C<:Tuple, A<:NamedTuple} <: AbstractNode
    content::C
    attributes::A
    function Node(tag::Symbol, args...; kwargs...)
        a = (;kwargs...)
        new{tag, typeof(args), typeof(a)}(args, a)
    end
end

# `Semantic` mirrors `Node`'s shape but is NOT an HTML element — it carries
# our domain concepts (`:line`, `:section`, `:colored`, `:lint`) that have
# format-specific renderings but no faithful HTML tag. The split means the
# generic HTML fallback for `Node` can never accidentally produce invalid
# `<line>` / `<section>` markup for a Semantic tag.
struct Semantic{Tag, C<:Tuple, A<:NamedTuple} <: AbstractNode
    content::C
    attributes::A
    function Semantic(tag::Symbol, args...; kwargs...)
        a = (;kwargs...)
        new{tag, typeof(args), typeof(a)}(args, a)
    end
end

# Cobweb-style builders: `h.tag(args...; attrs...)` for HTML elements;
# `s.tag(args...; attrs...)` for Semantic nodes. Each `getproperty` overload
# turns any tag-name access into a constructor closure.
function h end
Base.getproperty(::typeof(h), tag::Symbol) =
    (args...; kwargs...) -> Node(tag, args...; kwargs...)
Base.propertynames(::typeof(h)) = ()

function sem end
Base.getproperty(::typeof(sem), tag::Symbol) =
    (args...; kwargs...) -> Semantic(tag, args...; kwargs...)
Base.propertynames(::typeof(sem)) = ()

# === Builder ==================================================================

# Build a single styled token from a string + style flags. Wraps innermost-out
# so the on-the-wire nesting matches CSS-style cascade ordering: span > u >
# strong > em > text.
function _tok(s::AbstractString; bold=false, italic=false, underline=false, color=nothing)
    n = String(s)
    italic    && (n = h.em(n))
    bold      && (n = h.strong(n))
    underline && (n = h.u(n))
    color === nothing || (n = sem.underlined(n; color))
    n
end
_tok_ident(name::Symbol, color_map) =
    _tok(string(name); color=get(color_map, name, nothing))

function _build_sig_arg(a, color_map)
    # Use Any[] — recursive calls mix element types (`:colored` from
    # `_tok_ident`, plain Strings from `_tok` with no styling, `:em` from
    # `_tok(...; italic=true)`), and a typed literal would lock to whichever
    # came first.
    if a isa Symbol
        Any[_tok_ident(a, color_map)]
    elseif Meta.isexpr(a, :kw)
        nodes = _build_sig_arg(a.args[1], color_map)
        push!(nodes, _tok("=" * _print_struct_short(a.args[2]); italic=true))
        nodes
    elseif Meta.isexpr(a, :(::))
        if length(a.args) == 1
            Any[_tok("::" * string(a.args[1]); italic=true)]
        else
            nodes = _build_sig_arg(a.args[1], color_map)
            push!(nodes, _tok("::" * _print_struct_short(a.args[2]); italic=true))
            nodes
        end
    else
        Any[_tok(_print_struct_short(a))]
    end
end

function _signature_nodes(indices, color_map)
    isempty(indices) && return Any[]
    out = Any[_tok("(")]
    pos = []; kw = []
    for idx in indices
        Meta.isexpr(idx, :parameters) ? append!(kw, idx.args) : push!(pos, idx)
    end
    for (i, a) in enumerate(pos)
        i == 1 || push!(out, _tok(", "))
        append!(out, _build_sig_arg(a, color_map))
    end
    if !isempty(kw)
        push!(out, _tok("; "))
        for (i, a) in enumerate(kw)
            i == 1 || push!(out, _tok(", "))
            append!(out, _build_sig_arg(a, color_map))
        end
    end
    push!(out, _tok(")"))
    out
end

function _dep_nodes(dep, color_map)
    dep === nothing && return Any[]
    out = Any[_tok("  [")]
    if dep[1] === :none
        push!(out, _tok("no callers in tree"; italic=true))
    else
        push!(out, _tok("⊆ {"))
        for (i, n) in enumerate(dep[2])
            i == 1 || push!(out, _tok(", "))
            push!(out, _tok_ident(n, color_map))
        end
        push!(out, _tok("}"))
    end
    push!(out, _tok("]"))
    out
end

function _prop_nodes(route_tag::String, cached::Bool, name::Symbol,
                     indices, dep, color_map)
    out = Any[]
    isempty(route_tag) || push!(out, _tok(route_tag; bold=true, italic=true))
    cached && push!(out, _tok("@cached "; bold=true, italic=true))
    push!(out, _tok(string(name)))
    append!(out, _signature_nodes(indices, color_map))
    append!(out, _dep_nodes(dep, color_map))
    out
end

# Build the lint index — `Dict{(Type, Union{Symbol,Nothing}), Vector{LintMessage}}` —
# from a flat lint list. `_build_section` looks up `(T, prop_name)` for IP-level
# annotations and `(T, nothing)` for struct-level ones.
function _build_lint_index(msgs::Vector{LintMessage})
    idx = Dict{Tuple{Type,Union{Symbol,Nothing}}, Vector{LintMessage}}()
    for m in msgs
        push!(get!(idx, (m.type, m.prop), LintMessage[]), m)
    end
    idx
end

# Build a `Semantic{:lint}` node for one LintMessage. The severity attribute
# drives format-specific rendering (color/icon).
_lint_node(msg::LintMessage) =
    sem.lint(msg.short; severity=msg.severity)

function _build_section(T::Type, header;
                        max_depth, types_in_tree, parent_map, color_map, lint_index, visited)
    header === nothing && (header = sem.line(_tok(string(nameof(T)); bold=true)))
    body = Any[]
    if T in visited
        push!(body, sem.line(_tok("(cycle)"; italic=true)))
        return sem.section(body...; header)
    end
    push!(visited, T)

    # Struct-level lints (prop=nothing) emitted as their own lines after the header.
    for msg in get(lint_index, (T, nothing), LintMessage[])
        push!(body, sem.line(_lint_node(msg)))
    end

    fixed = filter(n -> n !== :cache, collect(fieldnames(T)))
    if !isempty(fixed)
        toks = Any[_tok("fields: "; italic=true)]
        for (i, f) in enumerate(fixed)
            i == 1 || push!(toks, _tok(", "))
            push!(toks, _tok_ident(f, color_map))
        end
        push!(body, sem.line(toks...))
    end

    params = _print_struct_param_names(T)
    if !isempty(params)
        toks = Any[_tok("@param: "; italic=true)]
        for (i, p) in enumerate(params)
            i == 1 || push!(toks, _tok(", "))
            push!(toks, _tok_ident(p, color_map))
        end
        push!(body, sem.line(toks...))
    end

    props = try meta(T) catch; nothing end
    if props !== nothing
        # Render every declaration in declaration order — duplicates are kept,
        # since each yields its own `compute_property` method and deserves its
        # own line. Sorting by name groups duplicates together; secondary key
        # is the original index for a stable order within a group.
        pairs_with_idx = [(i, name, info) for (i, (name, info)) in enumerate(props)]
        sort!(pairs_with_idx; by=t -> (t[2], t[1]))
        for (_, name, info) in pairs_with_idx
            _print_struct_skip(T, name) && continue
            info.rhs === nothing && continue
            _print_struct_is_forwarded(info.rhs) && continue

            nested = _walk_nested_type(T, name)
            route_tag = ""
            for m in info.macros
                if m in _PRINT_STRUCT_ROUTE_MACROS
                    route_tag = String(m) * " "
                    break
                end
            end
            cached = Symbol("@cached") in info.macros
            dep = info.indexed ?
                _print_struct_worst_case(types_in_tree, parent_map, T, name, info) :
                nothing
            nodes = _prop_nodes(route_tag, cached, name, info.indices, dep, color_map)
            prop_lints = get(lint_index, (T, name), LintMessage[])

            if nested !== nothing && max_depth > 0
                push!(nodes, _tok(" = "))
                push!(nodes, _tok(string(nameof(nested)); bold=true))
                nested_sec = _build_section(nested, sem.line(nodes...);
                    max_depth=max_depth-1, types_in_tree, parent_map, color_map,
                    lint_index, visited=copy(visited))
                push!(body, nested_sec)
            else
                push!(body, sem.line(nodes...))
            end
            # One line per lint message, after the IP's line/section.
            for msg in prop_lints
                push!(body, sem.line(_lint_node(msg)))
            end
        end
    end
    sem.section(body...; header)
end

function _build_structure(T::Type;
                          max_depth=typemax(Int),
                          types_in_tree=_all_types_in_tree(T),
                          parent_map=_build_parent_map(T),
                          color_map=_build_color_map(T),
                          lint_index=_build_lint_index(analyze_structure(T)))
    sec = _build_section(T, nothing; max_depth, types_in_tree, parent_map, color_map,
                         lint_index, visited=Set{Type}())
    h.pre(sec; class="do-structure")
end

# === Rendering via Base.show / MIME ===========================================

# Parse `#rrggbb` → (R, G, B). Used for the terminal's truecolor escape.
function _hex_to_rgb(hex::AbstractString)
    @assert length(hex) == 7 && hex[1] == '#' "expected #rrggbb, got $hex"
    parse(Int, hex[2:3], base=16),
    parse(Int, hex[4:5], base=16),
    parse(Int, hex[6:7], base=16)
end
_html_escape(io::IO, s::AbstractString) = replace(io, s,
    '&'  => "&amp;",
    '<'  => "&lt;",
    '>'  => "&gt;",
    '"'  => "&quot;",
    '\'' => "&#39;")
_html_escape(io::IO, x) = _html_escape(io, string(x))

# --- Generic content emission (used by all formats) ---
# Content is always a Tuple of items — typically Strings (text leaves) or
# Nodes (children). Iterate and dispatch each via `_show_one`.
_show_content(io, m, content::Tuple) = for c in content; _show_one(io, m, c) end
_show_one(io, m, n::AbstractNode) = show(io, m, n)
_show_one(io, ::MIME"text/html", s::AbstractString) = _html_escape(io, s)
_show_one(io, m, s::AbstractString) = print(io, s)

# --- Show dispatch via `_show_node` ----------------------------------------
# Every Base.show on an AbstractNode delegates to `_show_node`. Inside
# `_show_node` there are no Base stdlib methods to disambiguate against, so
# per-tag overrides on generic MIME work without the per-(MIME, Tag) bloat
# we'd otherwise need to break Base's text/plain ambiguity.
Base.show(io::IO, m::MIME"text/plain",    n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, m::MIME"text/markdown", n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, m::MIME"text/html",     n::AbstractNode) = _show_node(io, m, n)
Base.show(io::IO, n::AbstractNode) = _show_node(io, MIME"text/plain"(), n)

# --- Defaults ---

# Node text/plain & text/markdown: emit content, no wrapping.
_show_node(io::IO, m::MIME"text/plain",    n::Node) = _show_content(io, m, n.content)
_show_node(io::IO, m::MIME"text/markdown", n::Node) = _show_content(io, m, n.content)

# Node text/html: <tag attrs>content</tag> — the only format that needs the
# tag in the output.
function _show_node(io::IO, m::MIME"text/html", n::Node{Tag}) where {Tag}
    print(io, "<", Tag)
    for (k, v) in pairs(n.attributes)
        v === nothing && continue
        print(io, " ", k, "=\"")
        _html_escape(io, v)
        print(io, "\"")
    end
    print(io, ">")
    _show_content(io, m, n.content)
    print(io, "</", Tag, ">")
end

# Semantic default: emit content with no wrapping in every format. Per-tag
# overrides on `_show_node(io, ::MIME, ::Semantic{:tag})` add format-specific
# behavior; thanks to the `_show_node` indirection, one method covers all
# three MIMEs without ambiguity.
_show_node(io::IO, m::MIME, n::Semantic) = _show_content(io, m, n.content)

# --- Tag-specific overrides ------------------------------------------------

# Inline style wrappers for terminal — emit ANSI start/end around content.
function _ansi_wrap(io, m, n, on, off)
    color = get(io, :color, false)
    color && print(io, on)
    _show_content(io, m, n.content)
    color && print(io, off)
end
_show_node(io::IO, m::MIME"text/plain", n::Node{:strong}) = _ansi_wrap(io, m, n, "\e[1m", "\e[22m")
_show_node(io::IO, m::MIME"text/plain", n::Node{:em})     = _ansi_wrap(io, m, n, "\e[3m", "\e[23m")
_show_node(io::IO, m::MIME"text/plain", n::Node{:u})      = _ansi_wrap(io, m, n, "\e[4m", "\e[24m")

function _show_node(io::IO, m::MIME"text/markdown", n::Node{:strong})
    print(io, "**"); _show_content(io, m, n.content); print(io, "**")
end
function _show_node(io::IO, m::MIME"text/markdown", n::Node{:em})
    print(io, "*"); _show_content(io, m, n.content); print(io, "*")
end

# `:colored` (Semantic) — content with the foreground in the given color.
# Used for emphasis where the whole token should pop (lint warnings).
function _show_node(io::IO, m::MIME"text/plain", n::Semantic{:colored})
    r, g, b = _hex_to_rgb(n.attributes.color)
    _ansi_wrap(io, m, n, "\e[38;2;$r;$g;$(b)m", "\e[39m")
end
function _show_node(io::IO, m::MIME"text/html", n::Semantic{:colored})
    show(io, m, Node(:span, n.content...; style="color:$(n.attributes.color)"))
end

# `:underlined` (Semantic) — default-color text with a thick colored
# underline. Used for bound identities so the bound hue marks identity
# without dominating the text. Terminal: ANSI `\e[4m` (underline on) +
# `\e[58;2;R;G;Bm` (truecolor underline color). HTML: `text-decoration:
# underline` + `text-decoration-color` + `text-decoration-thickness:2px`.
function _show_node(io::IO, m::MIME"text/plain", n::Semantic{:underlined})
    r, g, b = _hex_to_rgb(n.attributes.color)
    _ansi_wrap(io, m, n, "\e[4m\e[58;2;$r;$g;$(b)m", "\e[59m\e[24m")
end
function _show_node(io::IO, m::MIME"text/html", n::Semantic{:underlined})
    show(io, m, Node(:span, n.content...;
        style="text-decoration:underline; text-decoration-color:$(n.attributes.color); text-decoration-thickness:2px; text-underline-offset:2px"))
end

# `:line` (Semantic) — indent + content + newline. One method covers all
# three formats thanks to the `_show_node` indirection.
function _show_node(io::IO, m::MIME, n::Semantic{:line})
    print(io, "  "^get(io, :do_struct_depth, 0))
    _show_content(io, m, n.content)
    println(io)
end

# `:section` (Semantic) — render header at current depth, content one level
# deeper.
function _show_node(io::IO, m::MIME, n::Semantic{:section})
    hdr = get(n.attributes, :header, nothing)
    hdr === nothing || show(io, m, hdr)
    depth = get(io, :do_struct_depth, 0)
    body_io = IOContext(io, :do_struct_depth => hdr === nothing ? depth : depth + 1)
    _show_content(body_io, m, n.content)
end

# `:pre` (Node, real HTML element) — markdown fences. Terminal and HTML use
# the generic Node defaults (just-content / `<pre class=…>…</pre>`).
function _show_node(io::IO, m::MIME"text/markdown", n::Node{:pre})
    println(io, "```")
    _show_content(io, m, n.content)
    println(io, "```")
end

# `:lint` (Semantic) — bold + colored severity icon + message. Composes the
# existing `Node{:strong}` (bold) with `Semantic{:colored}` (bound palette
# color machinery) — no per-format rendering code here. Colors are muted
# brick / ochre that read on light and dark backgrounds.
function _show_node(io::IO, m::MIME, n::Semantic{:lint})
    icon  = n.attributes.severity === :error ? "✗"       : "⚠"
    color = n.attributes.severity === :error ? "#922b21" : "#b7791f"
    show(io, m, sem.colored(h.strong(icon, " ", n.content...); color))
end

# === Public API ===============================================================

"""    structure(T::Type; max_depth=typemax(Int)) -> Node{:pre}

Build a target-agnostic DOM-ish representation of `T`'s DO/HTMXO tree. The
root is a `Node{:pre}` so it renders as `<pre class="do-structure">…</pre>`
in HTML, fenced ` ``` ` blocks in markdown, and bare indented text in the
terminal. `display(s)` picks the right MIME for the active display.
"""
structure(T::Type; max_depth::Int=typemax(Int)) =
    _build_structure(T; max_depth)

"""    print_structure([io::IO=stdout,] T::Type; max_depth=typemax(Int))

Convenience: `show(io, MIME"text/plain"(), structure(T))`. For markdown or
HTML output, build the structure with `structure(T)` and `show` it under
the desired MIME.
"""
print_structure(T::Type; kwargs...) = print_structure(stdout, T; kwargs...)
print_structure(io::IO, T::Type; max_depth::Int=typemax(Int)) =
    show(io, MIME"text/plain"(), structure(T; max_depth))

"""    tree_children_map(root::Type) -> Dict{Type, Vector{Tuple{Symbol, Type}}}

Build a `parent → [(prop_name, child_type), …]` map for every DO/HTMXO
type reachable from `root`. Children are sorted alphabetically by `prop_name`.
The inverse of `_build_parent_map`. Pure data — no rendering.
"""
function tree_children_map(root::Type)
    parent_map = _build_parent_map(root)
    children = Dict{Type, Vector{Tuple{Symbol, Type}}}()
    for (child, (parent, prop)) in parent_map
        push!(get!(children, parent, Tuple{Symbol, Type}[]), (prop, child))
    end
    for v in values(children)
        sort!(v; by = p -> string(p[1]))
    end
    children
end

"""    lint_index(root::Type) -> Dict{Type, NamedTuple{(:warns, :errors, :msgs), …}}

Group `analyze_structure(root)` output by `LintMessage.type`. Each entry
carries warn/error counts and the underlying messages. Returns an empty
Dict if `analyze_structure` throws (e.g. partially-defined tree).
"""
function lint_index(root::Type)
    msgs = try analyze_structure(root) catch; LintMessage[] end
    out = Dict{Type, NamedTuple{(:warns, :errors, :msgs), Tuple{Int, Int, Vector{LintMessage}}}}()
    for m in msgs
        e = get!(() -> (warns=0, errors=0, msgs=LintMessage[]), out, m.type)
        push!(e.msgs, m)
        out[m.type] = (
            warns  = e.warns  + (m.severity === :warn  ? 1 : 0),
            errors = e.errors + (m.severity === :error ? 1 : 0),
            msgs   = e.msgs,
        )
    end
    out
end

"""    lookup_type(root::Type, name::AbstractString) -> Union{Type, Nothing}

Find a DO/HTMXO type in the tree rooted at `root` by its bare `nameof`
string. Returns `nothing` if no match.
"""
function lookup_type(root::Type, name::AbstractString)
    for T in _all_types_in_tree(root)
        string(nameof(T)) == name && return T
    end
    nothing
end

"""    callers_by_name(prop::Symbol, root::Type) -> Vector{Tuple{Type, Symbol, Vector{Any}}}

Return every site (caller_type, caller_prop, arg_exprs) that calls a
property *named* `prop` anywhere in the tree rooted at `root`. Matches by
callee NAME, not by resolved owner type, so cross-type name collisions
appear together. Backed by `_build_call_index`.
"""
function callers_by_name(prop::Symbol, root::Type)
    types_in_tree = _all_types_in_tree(root)
    call_index = _build_call_index(types_in_tree)
    get(call_index, prop, Vector{Tuple{Type,Symbol,Vector{Any}}}())
end

"""    property_source_info(T::Type, prop::Symbol)
        -> Union{Nothing, NamedTuple{(:rhs_string, :signature, :macros, :dependson), …}}

Extract a property's RHS expression, signature, macro chain, and
dependson set from `meta(T)`. Returns:

- `nothing` if `meta(T)` is undefined,
- `(; rhs_string=:meta_missing, signature, …)` if the prop isn't on `T`,
- otherwise a NamedTuple with:
  - `rhs_string::String` — the lnn-stripped expression as a string, or
    `"(no rhs — forwarded/typed property)"` if `info.rhs === nothing`.
  - `signature::String` — `"name"` or `"name(arg, …)"`.
  - `macros::String` — `"@cached "` etc. (trailing space if non-empty).
  - `dependson::Vector{Symbol}` — sorted dependency names.

Pure data extraction. Renderers turn this into HTML / markdown /
terminal output.
"""
function property_source_info(T::Type, prop::Symbol)
    props = try meta(T) catch; nothing end
    props === nothing && return nothing
    # `metafirst` matches the previous `props[prop]` semantics: if duplicate
    # declarations exist, callers of `property_source_info` get the first.
    info = metafirst(T, prop)
    info === nothing && return (; rhs_string="(property $prop not found on $(nameof(T)))",
                                  signature=string(prop),
                                  macros="",
                                  dependson=Symbol[])
    rhs_string = info.rhs === nothing ? "(no rhs — forwarded/typed property)" :
                 string(Base.remove_linenums!(deepcopy(info.rhs)))
    signature = isempty(info.indices) ? string(info.lhs) :
                string(info.lhs, "(", join(info.indices, ", "), ")")
    macros = isempty(info.macros) ? "" : join(string.(info.macros), " ") * " "
    dependson = isempty(info.dependson) ? Symbol[] : sort!(collect(info.dependson))
    (; rhs_string, signature, macros, dependson)
end

"""    property_signature(T::Type, prop::Symbol) -> Union{Nothing, NamedTuple}
        property_signature(info::NamedTuple, mod::Module) -> NamedTuple

Structured call signature for an indexed property, parsed from `info.indices`
(the argument list the macro captured from the LHS call). The structured
counterpart to `property_source_info`'s stringy `signature`.

Two entry points:

- `property_signature(T, prop)` — look `prop` up in `meta(T)` (first
  declaration, via `metafirst`) and parse it against `parentmodule(T)`. Returns
  `nothing` if `meta(T)` is undefined or `prop` isn't a property of `T`.
- `property_signature(info, mod)` — parse an *already-selected* `meta` info
  against module `mod`, without re-looking it up. Use this when the caller
  holds a specific declaration. The key case is **multi-verb / duplicate-name
  routes**: several declarations can share one property name (e.g. a `@get` and
  a `@post` on `user`), so `meta(T)` carries duplicates and `metafirst` would
  collapse them to the first. Walk `metaall(T, prop)` and call this per
  declaration. Always returns a (possibly empty) `(; positional, kwargs)`.

Both yield `(; positional, kwargs)`, where every entry is a NamedTuple
`(; name, type, required, default, vararg)`:

- `name::Union{Symbol,Nothing}` — the argument name (`nothing` for an anonymous
  `::T` positional).
- `type::Union{Type,Nothing}` — the annotation resolved against `mod` via
  `Core.eval`, or `nothing` when un-annotated OR unresolvable (e.g. a free
  static-parameter type-var like the `V` in `Verb{V}`). Consumers map `nothing`
  to their permissive default (HTMXObjects → `String`).
- `required::Bool` — `true` unless the arg carries a default or is a vararg.
- `default` — the default-value *expression* when `required === false`;
  `nothing` (and meaningless) when `required === true`. A literal `nothing`
  default is told apart from "no default" only by `required === false`.

- `vararg::Bool` — `true` for a splat (`x...` / `x::T...`), which is otherwise
  indistinguishable from a plain optional arg: both report `required=false`.
  Consumers that build a call template need the difference (an open-ended
  `path...` segment is not a single optional `path`).

A non-indexed property (no call signature) yields empty `positional` and
`kwargs`. A vararg is unwrapped to its inner name/type with `required=false`
and `vararg=true`.

Layering — intentionally verb-agnostic: this returns *every* positional arg,
including any framework-injected leading arg (e.g. HTMXObjects' injected
`__verb__::Verb{V}`). Filtering such args — and selecting *which* declaration a
verb maps to — is the consumer's job. `@param`-derived properties are not
indexed properties and carry no `info.indices`; their parsed shape lives in
`info.rhs` and is the consumer's concern.

Pure data extraction. See also `property_source_info`.
"""
function property_signature(T::Type, prop::Symbol)
    props = try meta(T) catch; nothing end
    props === nothing && return nothing
    # First declaration wins. Multi-verb / duplicate-name callers that must
    # disambiguate should walk `metaall(T, prop)` and call the `(info, mod)`
    # method per declaration instead.
    info = metafirst(T, prop)
    info === nothing && return nothing
    property_signature(info, parentmodule(T))
end

function property_signature(info::NamedTuple, mod::Module)
    positional = NamedTuple[]
    kwargs = NamedTuple[]
    for idx in info.indices
        if Meta.isexpr(idx, :parameters)
            # Everything after the `;` — keyword args (and any `; kw...` slurp).
            for kw in idx.args
                push!(kwargs, _parse_signature_arg(kw, mod))
            end
        else
            push!(positional, _parse_signature_arg(idx, mod))
        end
    end
    (; positional, kwargs)
end

# Parse one argument node from `info.indices` into `(; name, type, required,
# default)`. Handles every call-LHS arg shape the macro can capture:
#   x          x::T          required, untyped / typed
#   x=d        x::T=d        optional positional / defaulted kwarg
#   x...       x::T...       vararg — required=false, splat unwrapped
#   ::T                      anonymous positional — name=nothing
# Shared by positional args and the members of an `Expr(:parameters,…)` kwargs
# node; the positional-vs-keyword distinction is the caller's (by where the
# node sits), so this peels uniformly.
function _parse_signature_arg(node, mod)
    required = true
    default = nothing
    vararg = false
    if Meta.isexpr(node, :kw)            # `x = d` / `x::T = d`
        required = false
        default = node.args[2]
        node = node.args[1]
    end
    if Meta.isexpr(node, :...)           # `x...` — 0+ args, so not required
        required = false
        vararg = true
        node = node.args[1]
    end
    typeexpr = nothing
    nm = node
    if Meta.isexpr(node, :(::))
        if length(node.args) == 2        # `name::T`
            nm, typeexpr = node.args
        else                             # `::T` — anonymous arg
            nm, typeexpr = nothing, node.args[1]
        end
    end
    (; name = nm isa Symbol ? nm : nothing,
       type = _resolve_arg_type(typeexpr, mod),
       required, default, vararg)
end

# Resolve a type-annotation expression against the struct's defining module.
# `nothing` for un-annotated args, for results that aren't a `Type`, and for
# any expression that fails to evaluate (e.g. a free static-parameter type-var
# such as the `V` in `Verb{V}`). Never throws.
function _resolve_arg_type(expr, mod)
    expr === nothing && return nothing
    try
        t = Core.eval(mod, expr)
        t isa Type ? t : nothing
    catch
        nothing
    end
end

property_doc(info::NamedTuple) = get(info, :doc, nothing)

# ── Semantic property descriptors ──────────────────────────────────────────
#
# This normalization layer is deliberately built only from the public
# `meta`/`property_signature` contract. It is safe for types emitted by an older
# DynamicObjects version: every new metadata field is read through
# `get(info, key, default)`, and the public result is an additive NamedTuple.

_descriptor_result_type_expr(info::NamedTuple) = begin
    explicit = get(info, :result_type, nothing)
    explicit === nothing ? _lhs_type_expr(get(info, :lhs, nothing)) : explicit
end
_lhs_type_expr(::Any) = nothing
_lhs_type_expr(lhs::Expr) = Meta.isexpr(lhs, :(::)) ? lhs.args[end] : nothing

_option_descriptor(value; label=string(value), group=nothing,
                   help=nothing, disabled=false) = (;
    value, label, group, help, disabled,
)
function _option_descriptor(option::NamedTuple)
    haskey(option, :value) || error("an option descriptor requires a `value` field")
    defaults = _option_descriptor(option.value)
    merge(defaults, option)
end
# `value => label`, the ergonomic spelling an `option_domain` list is written in.
_option_descriptor(option::Pair) = _option_descriptor(first(option); label=string(last(option)))

_unrestricted_domain() = (;
    kind=:unrestricted,
    options=NamedTuple[],
    provider=nothing,
    dependencies=Symbol[],
    cardinality=nothing,
    multiple=false,
    allow_custom=true,
    declaration=nothing,
)

"""
    static_domain(values; multiple=false, allow_custom=false)

Normalize raw values or option records already available to a descriptor
consumer. This is a framework-facing normalization helper, not an application
authoring convention.
"""
static_domain(values; multiple=false, allow_custom=false) = let opts =
    NamedTuple[_option_descriptor(v) for v in values]
    (;
        kind=:static,
        options=opts,
        provider=nothing,
        dependencies=Symbol[],
        cardinality=length(opts),
        multiple,
        allow_custom,
        declaration=nothing,
    )
end

# Domain of an input governed by an `@options` declaration. `options` stays
# empty and `cardinality` `nothing` on purpose: DO records the declared
# expression, it never evaluates it during reflection, so it cannot know the
# values. The consumer calls `property_options(object, parameter)` when it needs
# the value and re-reads after a declared dependency changes.
_declared_domain(declaration::NamedTuple) = (;
    kind=:declared,
    options=NamedTuple[],
    provider=nothing,
    dependencies=declaration.dependencies,
    cardinality=nothing,
    multiple=false,
    allow_custom=false,
    declaration,
)

function _inferred_domain(input_type)
    input_type === Bool && return static_domain((false, true))
    input_type isa Type && input_type <: Enum && return static_domain(instances(input_type))
    _unrestricted_domain()
end

# A declaration wins over the type-inferred domain: `Bool`/`Enum` prove a domain,
# but an author who declared one for that name meant it.
_input_domain(arg::NamedTuple, ::Nothing) = _inferred_domain(arg.type)
_input_domain(arg::NamedTuple, declarations::AbstractDict) =
    let declaration = arg.name === nothing ? nothing : get(declarations, arg.name, nothing)
        declaration === nothing ? _inferred_domain(arg.type) : _declared_domain(declaration)
    end

_descriptor_input(arg::NamedTuple, kind::Symbol, declarations=nothing) = (;
    arg...,
    kind,
    domain=_input_domain(arg, declarations),
)

function _semantic_dependency_closure(T::Type, roots)
    closure = Set{Symbol}()
    seen = Set{Symbol}()
    function visit(name::Symbol)
        name in seen && return
        push!(seen, name)
        info = metafirst(T, name)
        info === nothing && return
        push!(closure, name)
        dependencies = get(info, :dependson, nothing)
        dependencies === nothing && return
        for dependency in dependencies
            dependency isa Symbol && visit(dependency)
        end
    end
    for root in roots
        root isa Symbol && visit(root)
    end
    # Declaration order is the schema/rendering order; `dependson` itself is a
    # Set and therefore cannot provide a stable public order.
    unique!(Symbol[name for (name, _) in meta(T) if name in closure])
end

function _semantic_fixed_dependencies(T::Type, roots)
    Symbol[name for name in _semantic_dependency_closure(T, roots)
        if isnothing(get(metafirst(T, name), :rhs, nothing))]
end

function _semantic_dependency_inputs(T::Type, dependencies)
    inputs = NamedTuple[]
    for name in _semantic_fixed_dependencies(T, dependencies)
        descriptor = property_descriptor(T, name)
        descriptor === nothing && continue
        input = only(descriptor.inputs)
        push!(inputs, merge(input, (;
            kind=:context,
            source=(;type=T, property=name),
            scope=:object,
        )))
    end
    inputs
end

function _merge_semantic_dependency_inputs(context_inputs, direct_inputs)
    merged = NamedTuple[]
    direct_by_name = Dict(input.name => input for input in direct_inputs)
    for context in context_inputs
        direct = get(direct_by_name, context.name, nothing)
        if direct === nothing
            push!(merged, context)
            continue
        end
        context.type !== nothing && direct.type !== nothing && context.type != direct.type &&
            error("semantic dependency input `$(context.name)` type $(context.type) conflicts with the property signature type $(direct.type)")
        push!(merged, merge(context, direct, (;domain=context.domain)))
    end
    context_names = Set(input.name for input in context_inputs)
    append!(merged, (input for input in direct_inputs if !(input.name in context_names)))
    merged
end

_descriptor_role(::Val{true}, ::Val) = :input
_descriptor_role(::Val{false}, ::Val{true}) = :operation
_descriptor_role(::Val{false}, ::Val{false}) = :output

_materialization_tier(::Val{true}, ::Val, ::Val, ::Val) = :field
_materialization_tier(::Val{false}, fresh, mmap, cached) =
    _computed_materialization_tier(mmap, cached, fresh)
_computed_materialization_tier(::Val{true}, ::Val, ::Val) = :mmap
_computed_materialization_tier(::Val{false}, ::Val{true}, ::Val) = :serialized
_computed_materialization_tier(::Val{false}, ::Val{false}, ::Val{true}) = :recompute
_computed_materialization_tier(::Val{false}, ::Val{false}, ::Val{false}) = :automatic

_progress_mode(macros) =
    Symbol("@PROGRESS") in macros || Symbol("@progress") in macros || Symbol("@dynamic_progress") in macros ? :instrumented :
    Symbol("@fetch!") in macros ? :forwarded : :automatic

_descriptor_version_dependencies(T::Type) = unique!(Symbol[
    name for (name, entry) in meta(T)
    if Symbol("@versioned") in get(entry, :macros, Set{Symbol}())
])

function property_descriptor(T::Type, prop::Symbol, info::NamedTuple)
    mod = parentmodule(T)
    fixed = isnothing(get(info, :rhs, nothing))
    indexed = get(info, :indexed, !isempty(get(info, :indices, ())))
    macros = get(info, :macros, Set{Symbol}())
    fresh = Symbol("@fresh") in macros
    cached = Symbol("@cached") in macros
    mmap = Symbol("@mmap") in macros
    declared_versioned = Symbol("@versioned") in macros
    version_dependencies = _descriptor_version_dependencies(T)
    versioned = has_versioned_fields(T) || !isempty(version_dependencies)
    computed = !fixed
    memoized = computed && !fresh
    pending = memoized
    progress = computed
    result_type = _resolve_arg_type(_descriptor_result_type_expr(info), mod)
    signature = property_signature(info, mod)
    declarations = _option_declaration_map(T)
    inferred_inputs = if fixed
        NamedTuple[_descriptor_input((;
            name=prop,
            type=result_type,
            required=true,
            default=nothing,
            vararg=false,
        ), :field, declarations)]
    else
        vcat(
            NamedTuple[_descriptor_input(arg, :positional, declarations) for arg in signature.positional],
            NamedTuple[_descriptor_input(arg, :keyword, declarations) for arg in signature.kwargs],
        )
    end
    dependencies = get(info, :dependson, nothing)
    dependencies = dependencies === nothing ? Symbol[] : sort!(collect(dependencies))
    context_inputs = fixed ? NamedTuple[] :
        _semantic_dependency_inputs(T, dependencies)
    inputs = _merge_semantic_dependency_inputs(context_inputs, inferred_inputs)
    tier = _materialization_tier(Val(fixed), Val(fresh), Val(mmap), Val(cached))
    cache_version = get(info, :cache_version, nothing)
    # `@versioned` is an object-wide cache-path dimension: a marker on one
    # field/property invalidates every persisted output of T. Keep the local
    # declaration fact separately so consumers can distinguish "defines the
    # version" from "is governed by the version" without an annotation shim.
    semantics = (;
        fresh,
        memoized,
        versioned,
        declared_versioned,
        version_dependencies,
        cache_version,
        invalidation=(; content_version=versioned, cache_version),
        cached,
        mmap,
        pending,
        progress,
        progress_mode=_progress_mode(macros),
    )
    materialization = (;tier)
    # The domain of the property's OWN value. A fixed field also reports it on
    # its single `:field` input, but the shape that needs this is the
    # overrideable default (`n_chain::Integer = 8`): it is a parameter a
    # consumer sets, yet it is a computed property with no signature, so it has
    # no `inputs` entry to hang a domain on.
    domain = _input_domain((; name=prop, type=result_type), declarations)
    (;
        name=prop,
        role=_descriptor_role(Val(fixed), Val(indexed)),
        fixed,
        indexed,
        description=property_doc(info),
        dependencies,
        domain,
        inputs,
        output=(; type=result_type, materialization),
        semantics,
    )
end

"""
    property_descriptor(T::Type, property::Symbol)

Return a backward-safe, pure-data descriptor for one DynamicObjects property,
or `nothing` when the type or property has no DO metadata. The result describes
inputs/output, lifecycle semantics, option domains, and declared
materialization without reading or computing an object property.

The descriptor's own `domain` is the domain of the property's *value*, and each
entry of `inputs` carries the domain of that argument. Read the top-level one
for a parameter a consumer sets — a fixed field, or an overrideable default like
`n_chain::Integer = 8`, which is a computed property with no signature and
therefore no `inputs` entry to hang a domain on. Every domain has one of three
`kind`s:

- `:static` — a finite domain the *type* proves (`Bool`, or an `Enum`), with the
  values in `options`.
- `:declared` — an [`@options`](@ref option_declarations) declaration governs
  this parameter name. `domain.declaration` is the record (declared expression,
  its `dependencies`, and `static`); `options` is empty because reflection
  reports the declaration without running it. Call
  [`property_options`](@ref)`(o, name)` for the domain's actual value.
- `:unrestricted` — no domain is known; the type is the only constraint.
"""
function property_descriptor(T::Type, prop::Symbol)
    applicable(meta, T) || return nothing
    info = metafirst(T, prop)
    info === nothing ? nothing : property_descriptor(T, prop, info)
end

"""
    property_descriptors(T::Type)

Return descriptors in declaration order. Duplicate property declarations are
preserved so consumers can inspect multiple indexed signatures.
"""
function property_descriptors(T::Type)
    applicable(meta, T) || return NamedTuple[]
    NamedTuple[property_descriptor(T, name, info) for (name, info) in meta(T)]
end

"""
    type_descriptor(T::Type)

Type-level counterpart to [`property_descriptor`](@ref): what a reflection
consumer needs about the node as a whole, so "what is this thing called" has
exactly one answer rather than one per consumer.

Returns `(; type, name, description, options)`.

- `description` is `T`'s own user-attached docstring, stripped, or `nothing`
  when none was attached. The auto-generated property-list docstring
  `@dynamicstruct` installs as a `?T` fallback is deliberately *not* reported:
  it is reference text, not a label.
- `options` is [`option_declarations`](@ref)`(T)` — including any declaration
  whose parameter no input of `T` happens to carry.
"""
type_descriptor(T::Type) = (;
    type=T,
    name=nameof(T),
    description=_type_docstring(T),
    options=option_declarations(T),
)

# Snapshot cache state without calling `getproperty`, `memoize!`, or a property
# body. `has_value` distinguishes a cached `nothing` from an absent entry.
_empty_cache_snapshot() = (;
    state=:unmaterialized,
    has_value=false,
    value=nothing,
    progress=nothing,
    error=nothing,
)

function _cache_snapshot(cache::AbstractThreadsafeDict, key)
    lock(cache.lock) do
        if haskey(cache.cache, key)
            return (;state=:ready, has_value=true, value=cache.cache[key],
                progress=get(cache.status, key, nothing), error=nothing)
        end
        if haskey(cache.errors, key)
            return (;state=:failed, has_value=false, value=nothing,
                progress=get(cache.status, key, nothing), error=cache.errors[key])
        end
        if haskey(cache.computing, key)
            return (;state=:pending, has_value=false, value=nothing,
                progress=get(cache.status, key, nothing), error=nothing)
        end
        _empty_cache_snapshot()
    end
end

function _cache_snapshot(cache::AbstractDict, key)
    haskey(cache, key) || return _empty_cache_snapshot()
    (;state=:ready, has_value=true, value=cache[key], progress=nothing, error=nothing)
end

function _memory_observation(o, descriptor::NamedTuple, name::Symbol, args, kwargs::NamedTuple)
    if descriptor.fixed
        (isempty(args) && isempty(kwargs)) || error("fixed property `$name` does not accept arguments")
        value = getfield(o, name)
        return (;state=:ready, has_value=true, value, progress=nothing, error=nothing)
    end
    hasfield(typeof(o), :cache) || return _empty_cache_snapshot()
    property_cache = getfield(o, :cache)
    property_cache isa PropertyCache || return _empty_cache_snapshot()
    if descriptor.indexed
        outer = _cache_snapshot(property_cache.cache, name)
        outer.state === :ready || return outer
        outer.value isa IndexableProperty || return outer
        return _cache_snapshot(outer.value.cache, (args, kwargs))
    end
    (isempty(args) && isempty(kwargs)) || error("scalar property `$name` does not accept arguments")
    _cache_snapshot(property_cache.cache, name)
end

_observed_bytes(value::AbstractString) = ncodeunits(value)
_observed_bytes(value::AbstractArray{T}) where {T} =
    isbitstype(T) ? length(value) * sizeof(T) : try
        Base.summarysize(value)
    catch
        nothing
    end
_observed_bytes(value::T) where {T} = isbitstype(T) ? sizeof(T) : try
    Base.summarysize(value)
catch
    nothing
end

const _AUTOMATIC_MATERIALIZATION_SUFFIX = ".auto"
const _AUTOMATIC_MATERIALIZATION_MIN_BYTES = 1024 * 1024
const _AUTOMATIC_MATERIALIZATION_MIN_SECONDS = 1.0

_automatic_materialization_path(cache_path::AbstractString) =
    cache_path * _AUTOMATIC_MATERIALIZATION_SUFFIX

function _effective_compute_seconds(wall_ns::Integer, compile_ns::Integer)
    # Julia's cumulative compile counter is process-global. Concurrent
    # compilation can therefore make `compile_ns` exceed this call's wall time;
    # clamp at zero so that ambiguity is conservative (keep memory) rather than
    # a false disk-promotion signal.
    noncompile_ns = wall_ns > compile_ns ? wall_ns - compile_ns : zero(wall_ns)
    Float64(noncompile_ns) / 1.0e9
end

function _automatic_materialization_metadata(cache_path::AbstractString)
    metadata_path = _automatic_materialization_path(cache_path)
    isfile(metadata_path) || return nothing
    metadata = try
        Serialization.deserialize(metadata_path)
    catch
        return nothing
    end
    metadata isa NamedTuple || return nothing
    format = get(metadata, :format, nothing)
    format in (:serial, :mmap) || return nothing
    metadata
end

function _disk_observation(o, descriptor::NamedTuple, name::Symbol, args, kwargs::NamedTuple)
    semantics = descriptor.semantics
    path = get_cache_path(o, name, args...; kwargs...)
    automatic = _automatic_materialization_metadata(path)
    (semantics.cached || semantics.mmap || automatic !== nothing) ||
        return (;state=:none, path=nothing, format=nothing)
    format = automatic === nothing ?
        (semantics.mmap ? :mmap : :serial) : automatic.format
    (;state=get_cache_status(path), path, format)
end

_observation_state(memory, disk, fresh) =
    memory.state !== :unmaterialized ? memory.state :
    disk.state === :ready ? :stored :
    disk.state === :started ? :stored_partial :
    fresh ? :fresh : :unmaterialized

"""
    materialization_observation(object, property::Symbol, args...; kwargs...)

Observe a property's current memory/disk/pending/progress state without
computing that property. For disk-backed properties this resolves the ordinary
DO cache path and inspects the file; it never creates or loads the target file.
"""
function materialization_observation(o, name::Symbol, args...; kwargs...)
    descriptor = property_descriptor(typeof(o), name)
    descriptor === nothing && error("$(typeof(o)) has no DynamicObjects property `$name`")
    property_kwargs = (;kwargs...)
    memory = _memory_observation(o, descriptor, name, args, property_kwargs)
    disk = _disk_observation(o, descriptor, name, args, property_kwargs)
    state = _observation_state(memory, disk, descriptor.semantics.fresh)
    value_type = memory.has_value ? typeof(memory.value) : descriptor.output.type
    (;
        name,
        state,
        ready=memory.state === :ready,
        pending=memory.state === :pending,
        failed=memory.state === :failed,
        stored=disk.state === :ready,
        tier=disk.state === :ready ?
            (disk.format === :mmap ? :mmap : :serialized) :
            memory.state === :ready ? :memory : descriptor.output.materialization.tier,
        memory_state=memory.state,
        disk_state=disk.state,
        path=disk.path,
        progress=memory.progress,
        error=memory.error,
        value_type,
        estimated_bytes=memory.has_value ? _observed_bytes(memory.value) : nothing,
    )
end

# --- governed semantic materialization ---------------------------------------
#
# Applications do not construct a store. A semantic framework hands DO the root
# it already retained plus a pure-data `(scope, key, retention)` context. DO
# then executes through the ordinary property machinery, so the existing
# ThreadsafeDict memoization, per-path disk locks, cache identity, @versioned
# layout, atomic serialization, and mmap validation remain the only storage
# implementation. This registry owns lifecycle metadata only; it is not a
# second value cache.

mutable struct _MaterializationOwner
    id::String
    registry_key::Tuple{UInt,Symbol,String}
    root_type::Type
    scope::Symbol
    key_digest::String
    identity::String
    version::String
    retention::Any
    handle::WeakRef
    active::Int
    released::Bool
    release_reason::Union{Nothing,Symbol}
    last_access::Float64
    owned_paths::Dict{String,String}
    unowned_paths::Set{String}
end

const _MATERIALIZATION_OWNERS_LOCK = ReentrantLock()
const _MATERIALIZATION_OWNERS = Dict{Tuple{UInt,Symbol,String},_MaterializationOwner}()
const _MATERIALIZATION_PROCESS_TOKEN = Ref{Union{Nothing,String}}(nothing)
const _MATERIALIZATION_MARKER = ".dynamicobjects-owner"

function _materialization_process_token()
    token = _MATERIALIZATION_PROCESS_TOKEN[]
    token === nothing || return token
    lock(_MATERIALIZATION_OWNERS_LOCK) do
        token = _MATERIALIZATION_PROCESS_TOKEN[]
        if token === nothing
            token = persistent_hash((getpid(), time_ns(), objectid(current_task())))
            _MATERIALIZATION_PROCESS_TOKEN[] = token
        end
        token
    end
end

function _materialization_context(context::NamedTuple)
    haskey(context, :scope) || error(
        "materialization context must contain `scope`")
    haskey(context, :key) || error(
        "materialization context must contain `key`")
    scope = context.scope
    scope isa Symbol || error(
        "materialization context `scope` must be a Symbol, got $(typeof(scope))")
    retention = get(context, :retention, nothing)
    if retention !== nothing
        retention isa NamedTuple || error(
            "materialization context `retention` must be `nothing` or a NamedTuple")
        unknown = setdiff(Set(keys(retention)), Set((:max_entries, :ttl)))
        isempty(unknown) || error(
            "unknown materialization retention fields: $(join(sort!(string.(collect(unknown))), ", "))")
        max_entries = get(retention, :max_entries, nothing)
        ttl = get(retention, :ttl, nothing)
        (max_entries === nothing || (max_entries isa Integer && max_entries > 0)) ||
            error("materialization retention `max_entries` must be a positive integer or nothing")
        (ttl === nothing || (ttl isa Real && ttl > 0)) ||
            error("materialization retention `ttl` must be a positive number of seconds or nothing")
        retention = (;max_entries, ttl)
    end
    key_digest = try
        persistent_hash(context.key)
    catch e
        error("materialization context `key` must have a stable serializable identity: $(sprint(showerror, e))")
    end
    (;scope, key_digest, retention)
end

function _materialization_handle(root)
    hasfield(typeof(root), :cache) || error(
        "governed materialization root $(typeof(root)) is not a @dynamicstruct")
    property_cache = getfield(root, :cache)
    property_cache isa PropertyCache || error(
        "governed materialization root $(typeof(root)) has no DynamicObjects PropertyCache")
    cache = property_cache.cache
    cache = cache isa MountedThreadsafeDict ? cache.shared : cache
    # ThreadsafeDict itself is immutable, so WeakRef does not track its
    # reachability reliably. Its mutable value Dict has the same lifetime and
    # is retained by every mounted view of the shared cache.
    cache isa ThreadsafeDict ? cache.cache : cache
end

function _materialization_identity(root)
    try
        (;
            identity=string(root.__identity_hash__),
            version=string(root.__version_tag__),
            path=normpath(abspath(root.__cache_path__)),
        )
    catch e
        error("governed materialization root $(typeof(root)) has no usable cache identity: $(sprint(showerror, e))")
    end
end

_materialization_marker(path::AbstractString) =
    joinpath(path, _MATERIALIZATION_MARKER)

function _read_materialization_marker(marker)
    isfile(marker) || return nothing
    try
        strip(read(marker, String))
    catch
        nothing
    end
end

function _contest_materialization_marker!(marker, existing, claimant)
    isdir(dirname(marker)) || return nothing
    try
        open(marker, "w") do io
            println(io, "contested")
            existing === nothing || println(io, existing)
            println(io, claimant)
        end
    catch
        # A marker that cannot be made explicitly contested is still unowned;
        # cleanup requires an exact token match and therefore stays fail-closed.
    end
    nothing
end

function _claim_materialization_path!(owner::_MaterializationOwner, path)
    path in owner.unowned_paths && return false
    haskey(owner.owned_paths, path) && return true
    if ispath(path)
        marker = _materialization_marker(path)
        existing = _read_materialization_marker(marker)
        if existing == owner.id
            owner.owned_paths[path] = marker
            return true
        end
        existing === nothing ||
            _contest_materialization_marker!(marker, existing, owner.id)
        push!(owner.unowned_paths, path)
        return false
    end
    marker = _materialization_marker(path)
    mkpath(dirname(path))
    try
        # Claim the data directory itself atomically. Keeping the marker inside
        # it matters for @versioned roots: stale-version pruning removes sibling
        # directories, so an out-of-tree marker would be mistaken for a stale
        # version and deleted before governance could prove ownership.
        mkdir(path)
    catch
        existing = _read_materialization_marker(marker)
        existing === nothing ||
            _contest_materialization_marker!(marker, existing, owner.id)
        push!(owner.unowned_paths, path)
        return false
    end
    open(marker, "w") do io
        write(io, owner.id)
    end
    owner.owned_paths[path] = marker
    true
end

function _new_materialization_owner(root, normalized, handle, identity)
    registry_key = (objectid(handle), normalized.scope, normalized.key_digest)
    owner_id = persistent_hash((
        _materialization_process_token(), registry_key,
        typeof(root), identity.identity, identity.version,
    ))
    _MaterializationOwner(
        owner_id, registry_key, typeof(root), normalized.scope,
        normalized.key_digest, identity.identity, identity.version,
        normalized.retention, WeakRef(handle), 0, false, nothing, time(),
        Dict{String,String}(), Set{String}(),
    )
end

function _materialization_owner_locked(root, context; create::Bool)
    normalized = _materialization_context(context)
    handle = _materialization_handle(root)
    registry_key = (objectid(handle), normalized.scope, normalized.key_digest)
    owner = get(_MATERIALIZATION_OWNERS, registry_key, nothing)
    if owner === nothing
        create || return nothing, normalized
        identity = _materialization_identity(root)
        owner = _new_materialization_owner(root, normalized, handle, identity)
        _MATERIALIZATION_OWNERS[registry_key] = owner
    else
        owner.handle.value === handle || error(
            "materialization ownership identity was reused after its root became unreachable; run `materialization_gc!()` and retry")
        isequal(owner.retention, normalized.retention) || error(
            "materialization retention changed for a live $(owner.scope) owner")
    end
    owner, normalized
end

function _cleanup_materialization_owner!(owner::_MaterializationOwner)
    deleted = String[]
    preserved = String[]
    for (path, marker) in owner.owned_paths
        if _read_materialization_marker(marker) != owner.id || islink(path)
            push!(preserved, path)
            continue
        end
        try
            ispath(path) && rm(path; recursive=true, force=true)
            push!(deleted, path)
        catch
            push!(preserved, path)
        end
    end
    append!(preserved, owner.unowned_paths)
    (;deleted, preserved)
end

function _materialization_gc_locked!()
    collected = String[]
    deleted = String[]
    preserved = String[]
    for (key, owner) in collect(_MATERIALIZATION_OWNERS)
        owner.released || continue
        owner.active == 0 || continue
        owner.handle.value === nothing || continue
        cleanup = _cleanup_materialization_owner!(owner)
        append!(deleted, cleanup.deleted)
        append!(preserved, cleanup.preserved)
        push!(collected, owner.id)
        delete!(_MATERIALIZATION_OWNERS, key)
    end
    (;collected, deleted_paths=deleted, preserved_paths=preserved)
end

"""
    materialization_gc!()

Collect storage owned by semantic roots that their provider has released and
that are no longer reachable or executing. Framework lifecycle hooks call this
opportunistically; applications do not need a cleanup loop. Cache directories
that pre-date governance, are symlinks, or have conflicting ownership markers
are preserved.
"""
materialization_gc!() = lock(_MATERIALIZATION_OWNERS_LOCK) do
    _materialization_gc_locked!()
end

function _begin_materialization!(context, root)
    lock(_MATERIALIZATION_OWNERS_LOCK) do
        _materialization_gc_locked!()
        owner, _ = _materialization_owner_locked(root, context; create=true)
        identity = _materialization_identity(root)
        (owner.identity == identity.identity && owner.version == identity.version) ||
            error("materialization cache identity/version changed for a retained root")
        _claim_materialization_path!(owner, identity.path)
        owner.active += 1
        owner.last_access = time()
        owner
    end
end

function _end_materialization!(owner::_MaterializationOwner)
    lock(_MATERIALIZATION_OWNERS_LOCK) do
        owner.active > 0 || error("materialization lease underflow")
        owner.active -= 1
        # `retention=nothing` is the HTMX fresh-request contract: there is no
        # provider-held root and therefore no later eviction callback.
        if owner.retention === nothing
            owner.released = true
            owner.release_reason = :request
        end
        _materialization_gc_locked!()
    end
    nothing
end

function _execute_materialization_target(target, name::Symbol, descriptor,
        args, kwargs::NamedTuple)
    if descriptor.indexed
        return getproperty(target, name)(args...; kwargs...)
    end
    (isempty(args) && isempty(kwargs)) || error(
        "non-indexed property `$name` does not accept operation arguments")
    getproperty(target, name)
end

function _timed_materialization_target(target, name::Symbol, descriptor,
        args, kwargs::NamedTuple)
    # This is the same compiler counter Base.@time uses. Its enable/disable
    # operations nest, so concurrent/nested governed executions do not turn
    # collection off underneath one another.
    Base.cumulative_compile_timing(true)
    compile_started = first(Base.cumulative_compile_time_ns())
    wall_started = time_ns()
    try
        value = _execute_materialization_target(
            target, name, descriptor, args, kwargs)
        wall_ns = time_ns() - wall_started
        compile_ns =
            first(Base.cumulative_compile_time_ns()) - compile_started
        (;
            value,
            elapsed_seconds=_effective_compute_seconds(wall_ns, compile_ns),
        )
    finally
        Base.cumulative_compile_timing(false)
    end
end

function _materialization_path_within(root::AbstractString, path::AbstractString)
    relative = relpath(normpath(abspath(path)), normpath(abspath(root)))
    relative == "." && return true
    isabspath(relative) && return false
    parts = splitpath(relative)
    isempty(parts) || first(parts) != ".."
end

function _automatic_materialization_allowed(owner::_MaterializationOwner,
        target, name::Symbol, descriptor, path::AbstractString)
    owner.retention === nothing && return false
    descriptor.fixed && return false
    descriptor.output.materialization.tier === :automatic || return false
    _remount_invalidated(target, name) && return false
    any(owner.owned_paths) do (root, marker)
        _read_materialization_marker(marker) == owner.id &&
            _materialization_path_within(root, path)
    end
end

function _automatic_materialization_slot(target, name::Symbol, descriptor,
        args, kwargs::NamedTuple)
    if descriptor.indexed
        property = getproperty(target, name)
        property isa IndexableProperty || return nothing
        return property.cache, (args, kwargs)
    end
    hasfield(typeof(target), :cache) || return nothing
    property_cache = getfield(target, :cache)
    property_cache isa PropertyCache || return nothing
    property_cache.cache, name
end

function _set_automatic_materialization_cache!(target, name, descriptor,
        args, kwargs, value)
    slot = _automatic_materialization_slot(
        target, name, descriptor, args, kwargs)
    slot === nothing && return false
    cache, key = slot
    if cache isa AbstractThreadsafeDict
        # Computed stores publish directly into the wrapped dictionary rather
        # than through `setindex!`: mounted caches use the same distinction to
        # preserve shared-vs-request-local routing, and plain ThreadsafeDicts do
        # not expose a public `setindex!` mutation path.
        lock(cache.lock) do
            cache.cache[key] = value
            _on_store!(cache, key)
        end
    else
        cache[key] = value
    end
    true
end

function _clear_automatic_materialization_cache!(target, name, descriptor,
        args, kwargs)
    slot = _automatic_materialization_slot(
        target, name, descriptor, args, kwargs)
    slot === nothing && return false
    cache, key = slot
    maybepop!(cache, key)
    true
end

function _drop_automatic_materialization!(cache_path)
    rm(cache_path; force=true)
    rm(_automatic_materialization_path(cache_path); force=true)
    nothing
end

function _load_automatic_materialization!(owner, target, name, descriptor,
        args, kwargs::NamedTuple)
    cache_path = get_cache_path(target, name, args...; kwargs...)
    _automatic_materialization_allowed(
        owner, target, name, descriptor, cache_path) || return nothing
    path_lock = get_path_lock!(
        _AUTOMATIC_MATERIALIZATION_DISK_LOCKS, cache_path)
    lock(path_lock) do
        metadata = _automatic_materialization_metadata(cache_path)
        metadata === nothing && return nothing
        get_cache_status(cache_path) === :ready || return nothing
        value = try
            load(Val(metadata.format), cache_path, nothing)
        catch e
            _drop_automatic_materialization!(cache_path)
            @warn "Automatic materialization cache read failed; deleting it and recomputing" cache_path exception=e
            return nothing
        end
        _set_automatic_materialization_cache!(
            target, name, descriptor, args, kwargs, value) || return nothing
        (;tier=metadata.format === :mmap ? :mmap : :serialized, value)
    end
end

function _automatic_materialization_choice(value, elapsed_seconds)
    value isa Union{Pending,Task,Channel} &&
        return (;tier=:memory, format=nothing, estimated_bytes=nothing)
    estimated_bytes = _observed_bytes(value)
    large = estimated_bytes !== nothing &&
        estimated_bytes >= _AUTOMATIC_MATERIALIZATION_MIN_BYTES
    expensive = elapsed_seconds >= _AUTOMATIC_MATERIALIZATION_MIN_SECONDS
    (large || expensive) ||
        return (;tier=:memory, format=nothing, estimated_bytes)
    format = _automatic_mmap_eligible(value) ? :mmap : :serial
    (;tier=format === :mmap ? :mmap : :serialized, format, estimated_bytes)
end

function _persist_automatic_materialization!(owner, target, name, descriptor,
        args, kwargs::NamedTuple, value, elapsed_seconds)
    cache_path = get_cache_path(target, name, args...; kwargs...)
    _automatic_materialization_allowed(
        owner, target, name, descriptor, cache_path) || return value
    choice = _automatic_materialization_choice(value, elapsed_seconds)
    choice.format === nothing && return value
    path_lock = get_path_lock!(
        _AUTOMATIC_MATERIALIZATION_DISK_LOCKS, cache_path)
    lock(path_lock) do
        existing = _automatic_materialization_metadata(cache_path)
        if existing !== nothing && get_cache_status(cache_path) === :ready
            stored = try
                load(Val(existing.format), cache_path, nothing)
            catch e
                _drop_automatic_materialization!(cache_path)
                @warn "Automatic materialization cache read failed; deleting it and recomputing" cache_path exception=e
                nothing
            end
            if stored !== nothing
                if existing.format === :mmap
                    _set_automatic_materialization_cache!(
                        target, name, descriptor, args, kwargs, stored)
                    return stored
                end
                _clear_automatic_materialization_cache!(
                    target, name, descriptor, args, kwargs)
                return value
            end
        end

        metadata_path = _automatic_materialization_path(cache_path)
        try
            mkpath(dirname(cache_path))
            _atomic_save(Val(choice.format), cache_path, value)
            metadata = (;
                format=choice.format,
                estimated_bytes=choice.estimated_bytes,
                compute_seconds=elapsed_seconds,
            )
            _atomic_save(Val(:serial), metadata_path, metadata)
            if choice.format === :mmap
                stored = load(Val(:mmap), cache_path, nothing)
                _set_automatic_materialization_cache!(
                    target, name, descriptor, args, kwargs, stored)
                return stored
            end
            _clear_automatic_materialization_cache!(
                target, name, descriptor, args, kwargs)
        catch e
            _drop_automatic_materialization!(cache_path)
            @warn "Automatic materialization persistence failed; keeping the computed value in memory" cache_path exception=e
        end
        value
    end
end

"""
    execute_materialization(context, root, target, property, args...; kwargs...)
    execute_materialization(context, object, property, args...; kwargs...)

Execute a DynamicObjects property under framework-owned storage governance.
`context` is the pure-data `(; scope, key, retention)` record supplied by a
semantic host; ordinary applications call their operations normally and never
construct a store. `root` is the retained application root and `target` is the
mounted object that owns `property`.

The executor adds an active lease around the existing DO property machinery.
For an ordinary property on a retained root it observes the actual result and
automatically keeps small/cheap values in memory, serializes large or expensive
values, and memory-maps supported large values. Fresh request roots recompute
across requests. Existing `@fresh`, `@cached`, and `@mmap` declarations remain
compatibility overrides; applications do not need them for governed execution.
"""
function execute_materialization(context::NamedTuple, root, target,
        name::Symbol, args...; kwargs...)
    descriptor = property_descriptor(typeof(target), name)
    descriptor === nothing && error(
        "$(typeof(target)) has no DynamicObjects property `$name`")
    owner = _begin_materialization!(context, root)
    try
        property_kwargs = (;kwargs...)
        automatic = _load_automatic_materialization!(
            owner, target, name, descriptor, args, property_kwargs)
        if automatic !== nothing
            value = _execute_materialization_target(
                target, name, descriptor, args, property_kwargs)
            automatic.tier === :serialized &&
                _clear_automatic_materialization_cache!(
                    target, name, descriptor, args, property_kwargs)
            return value
        end
        timed = _timed_materialization_target(
            target, name, descriptor, args, property_kwargs)
        _persist_automatic_materialization!(owner, target, name, descriptor,
            args, property_kwargs, timed.value, timed.elapsed_seconds)
    finally
        _end_materialization!(owner)
    end
end

execute_materialization(context::NamedTuple, object, name::Symbol,
        args...; kwargs...) =
    execute_materialization(context, object, object, name, args...; kwargs...)

"""
    release_materialization!(context, root; reason=:released)

Mark a retained semantic root as released by its provider. Cleanup is deferred
until active executions finish and the root's shared cache becomes unreachable.
An unknown or mismatched owner is reported as `:unowned` and nothing is deleted.
"""
function release_materialization!(context::NamedTuple, root;
        reason::Symbol=:released)
    lock(_MATERIALIZATION_OWNERS_LOCK) do
        owner, _ = _materialization_owner_locked(root, context; create=false)
        owner === nothing && return (;
            state=:unowned, released=false, reason, owner=nothing)
        owner.released = true
        owner.release_reason = reason
        owner.last_access = time()
        _materialization_gc_locked!()
        (;
            state=owner.active == 0 ? :deferred : :executing,
            released=true,
            reason,
            owner=owner.id,
        )
    end
end

"""
    materialization_ownership(context, root)

Inspect framework storage ownership without computing a property. Returns
`:unowned`, `:active`, or `:released`, including lease/reachability and the
derived cache identity/version used for fail-closed cleanup.
"""
function materialization_ownership(context::NamedTuple, root)
    lock(_MATERIALIZATION_OWNERS_LOCK) do
        _materialization_gc_locked!()
        owner, normalized = _materialization_owner_locked(
            root, context; create=false)
        owner === nothing && return (;
            state=:unowned,
            scope=normalized.scope,
            key_digest=normalized.key_digest,
        )
        (;
            state=owner.released ? :released : :active,
            owner=owner.id,
            scope=owner.scope,
            key_digest=owner.key_digest,
            identity=owner.identity,
            version=owner.version,
            retention=owner.retention,
            active=owner.active,
            reachable=owner.handle.value !== nothing,
            owned_paths=sort!(collect(keys(owner.owned_paths))),
            unowned_paths=sort!(collect(owner.unowned_paths)),
            release_reason=owner.release_reason,
        )
    end
end

export print_structure, structure
export tree_children_map, lint_index, lookup_type, callers_by_name, property_source_info, property_signature, property_doc, LintMessage
export metafirst, metaall
export static_domain, property_descriptor, property_descriptors, type_descriptor,
    option_declarations, has_option_declaration, property_options,
    option_domain, option_records
export materialization_observation
export execute_materialization, release_materialization!, materialization_ownership, materialization_gc!

end
