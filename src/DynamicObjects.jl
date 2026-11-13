"""
    DynamicObjects

Define objects with lazily computed properties using [`@dynamicstruct`](@ref).
Scalar and indexed properties share dependency tracking, memory caching, and
optional disk storage.
"""
module DynamicObjects
export @dynamicstruct, @cache_status, @is_cached, @cache_path, @clear_cache!, invalidate!, @persist, @memo!, @fresh, fresh, @fetch!, @dynamic_progress, memoize!, maybememoize!, maybefresh, maybefetchindex!, maybefetchproperty!, maybeprogress!, noprogress, remake, remount, file_version, fetchindex, fetchindex!, fetchproperty, fetchproperty!, getstatus, PropertyComputationError, unwrap_error, entries, cached_entries, clear_all_caches!, clear_mem_caches!, clear_disk_caches!, mem_cache_entries, prune_mem_caches!, PersistentSet, LazyPersistentDict, KeyTracker, SharedFileTracker, NoKeyTracker, key_tracker, record!, load_keys, Pending, Deferred, DeferredCompute, ComputeAbandoned, BackgroundCache

import SHA, Serialization, Mmap, Treebars, ScopedValues, Malt

# Treebars 0.1.1 is the floor for the three Treebars features checked below:
# 0.1.1 (`14068fa`) is the first Treebars version number that carries all of them, so Pkg
# refuses an older Treebars when it resolves. The worker mirror raises our compat floor to
# 0.1.6. The commits that brought these earlier features still say 0.1.0.
# The checks stay for an environment that loads DO without resolving against that floor, such
# as a Manifest resolved before it and loaded as it is.
#
# Every unmarked property body is wrapped in `Treebars.@progress_scope` (decision `0r44qxt`).
# Treebars has it from `bdf76d5`.
isdefined(Treebars, Symbol("@progress_scope")) || error(
    "DynamicObjects needs Treebars 0.1.1 or later; it uses `Treebars.@progress_scope` (Treebars " *
    "`bdf76d5`). The loaded Treebars, $(pathof(Treebars)), has none: update it.")
# A property read in an `@progress` label is threaded through `__progress__` like any other
# (`_implied_progress_rewrite`). Treebars binds it in labels from `3282255`; no symbol marks
# that, so check that the expansion leaves no bare `__progress__` behind.
let mentions(ex) = ex === :__progress__ || (ex isa Expr && any(mentions, ex.args))
    mentions(macroexpand(Treebars, :(@progress_scope nothing begin @progress "$(__progress__)"; nothing end))) && error(
        "DynamicObjects needs Treebars 0.1.1 or later; it relies on Treebars binding " *
        "`__progress__` in `@progress` labels (Treebars `3282255`). Without it a property read in " *
        "a phase label fails with `UndefVarError: __progress__`. The loaded Treebars, " *
        "$(pathof(Treebars)), leaves it unbound: update it.")
end
# The notes DO writes into progress nodes (`progress_notes`) are written in the language of the
# page that renders them. Treebars has `treebar_notes` from `753f826`.
isdefined(Treebars, :treebar_notes) || error(
    "DynamicObjects needs Treebars 0.1.1 or later; it uses `Treebars.treebar_notes` (Treebars " *
    "`753f826`). The loaded Treebars, $(pathof(Treebars)), has none: update it.")

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

# The bytes DO's digests hash: `x` serialized, under the header Julia 1.10 writes.
# A serialized stream opens with an 8-byte header ("JL" after a tag byte, then the
# writer's serialization-format version: 24 on Julia 1.10, 30 on 1.12 and 1.13, 31 on
# 1.14). Everything after it encodes plain data byte-identically on all of these, so
# hashing the header as written moved every digest, and with it every cache directory,
# whenever the Julia minor version changed (snag `canonical-hash-d-dfe422b5`). Pinning
# the version byte to 1.10's keeps every digest a 1.10 process computes and gives later
# Julia versions the same ones. These bytes are only hashed and compared, never
# deserialized. `test/canonical_hash.jl` pins golden digests on every CI Julia, so a
# Julia that changes the body encoding of a covered type fails there.
const _SERIALIZED_VERSION_BYTE = 4
const _DIGEST_SERIALIZATION_VERSION = 0x18
_serialized_bytes(x) = begin
    b = IOBuffer()
    Serialization.serialize(b, x)
    bytes = take!(b)
    bytes[2] == UInt8('J') && bytes[3] == UInt8('L') || error(
        "DynamicObjects: this Julia ($VERSION) writes a serialization header DynamicObjects " *
        "does not know (bytes $(bytes2hex(bytes[1:min(end, 8)]))), so its digests cannot be " *
        "made to match other Julia versions. Report it to DynamicObjects.")
    bytes[_SERIALIZED_VERSION_BYTE] = _DIGEST_SERIALIZATION_VERSION
    bytes
end
persistent_hash(x) = bytes2hex(SHA.sha1(_serialized_bytes(x)))

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

function _mmap_prepare_array(x::AbstractArray)
    A = x isa Array ? x : Array(x)   # ensure dense column-major isbits payload
    isbitstype(eltype(A)) || error("@mmap: array eltype $(eltype(A)) is not isbits; only isbits arrays can be memory-mapped.")
    ndims(A) <= _MMAP_MAXDIMS || error("@mmap: array ndims $(ndims(A)) exceeds the supported maximum $_MMAP_MAXDIMS.")
    A, _mmap_tag_of(eltype(A))
end

function _mmap_write_array(io::IO, A::Array, tag::UInt8)
    start = position(io)
    write(io, _MMAP_MAGIC...)
    write(io, _MMAP_VERSION)
    write(io, tag)
    write(io, UInt8(ndims(A)))
    for d in size(A); write(io, Int64(d)); end
    position(io) == start + 7 + 8ndims(A) || error("@mmap: incomplete numeric header write.")
    pad = mod(-position(io), _MMAP_ALIGN)
    write(io, zeros(UInt8, pad))
    offset = position(io)
    len = sizeof(A)
    write(io, A) == len || error("@mmap: incomplete numeric payload write (expected $len bytes).")
    position(io) == offset + len || error("@mmap: incomplete numeric payload write.")
    (offset, len)
end

"""
    DynamicObjects.save(Val(:mmap), io::IO, array::AbstractArray)

Write a self-describing DOMM numeric array block at `position(io)` and leave
`io` open at its end. Return the dense array written, without mutating the input.
Supports the same numeric element types as the path overload, including empty
and zero-dimensional arrays. Payload alignment is relative to the whole stream.

Composite mmap formats can record the starting and ending positions of each
block and reuse [`load`](@ref). This overload flushes and checks the block write;
the enclosing format must also validate its complete file after closing its
writer. When implementing `save(Val(:mmap), path, container)`, DO supplies an
unpublished temporary path and atomically publishes it only after `save` returns.
"""
function save(::Val{:mmap}, io::IO, x::AbstractArray)
    A, tag = _mmap_prepare_array(x)
    offset, len = _mmap_write_array(io, A, tag)
    flush(io)
    io isa IOStream && _mmap_check_complete(io, "numeric block", offset, len)
    A
end

function save(::Val{:mmap}, path::AbstractString, x::AbstractArray)
    A, tag = _mmap_prepare_array(x)
    offset, len = open(path, "w") do io
        _mmap_write_array(io, A, tag)
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
    need = _mmap_payload_end(offset, len, path)
    fsz >= need && return nothing
    error("@mmap: $path is truncated — need $need bytes (header offset $offset + payload $len) but the file holds $fsz. A partial cache file; it will be deleted and recomputed.")
end

function _mmap_payload_end(offset::Int, len::Int, path)
    need, ovf = Base.Checked.add_with_overflow(offset, len)
    ovf && error("@mmap: payload end overflows in $path — corrupt header.")
    need
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
function _mmap_array_type(::Type{A}, tag, nd, path) where {A<:AbstractArray}
    ET, N = eltype(A), ndims(A)
    nd == N || error("@mmap: header ndims $nd ≠ annotated ndims $N for $path.")
    _mmap_eltype_of(tag) === ET || error("@mmap: header eltype $(_mmap_eltype_of(tag)) ≠ annotated eltype $ET for $path.")
    Array{ET,N}
end
_mmap_array_type(::Nothing, tag, nd, path) = Array{_mmap_eltype_of(tag),nd}

function _mmap_load_array(io::IOStream, path, annotation; end_offset::Integer=filesize(io))
    0 <= position(io) <= end_offset <= filesize(io) ||
        throw(ArgumentError("@mmap: invalid numeric block bounds for $path."))
    tag, nd, dims, offset = _mmap_read_header(io)
    A = _mmap_array_type(annotation, tag, nd, path)
    len = _mmap_payload_bytes(eltype(A), dims, path)
    _mmap_check_complete(io, path, offset, len)
    stop = _mmap_payload_end(offset, len, path)
    stop <= end_offset || error("@mmap: numeric block in $path exceeds end_offset $end_offset (needs $stop bytes).")
    result = Mmap.mmap(io, A, Tuple(dims), offset)
    seek(io, stop)
    result
end

"""
    DynamicObjects.load(Val(:mmap), io::IOStream, annotation=nothing; end_offset=filesize(io))

Read a DOMM numeric array block from `position(io)` and memory-map its payload.
`io` must be a read-only file stream. Leave it open at the block's end; the array
remains valid after the caller closes the stream. An optional array type checks
the stored element type and number of dimensions; `nothing` reads them from the
header. Only numeric DOMM blocks are supported by the stream overload.

Set `end_offset` to the exclusive end of an embedded block so a corrupt header
cannot map bytes belonging to the next block. Header dimensions, byte-count
overflow, file truncation and this enclosing boundary are checked before mapping.
"""
function load(::Val{:mmap}, io::IOStream, ::Type{A}; end_offset::Integer=filesize(io)) where {A<:AbstractArray}
    iswritable(io) && throw(ArgumentError("@mmap: load requires a read-only file stream."))
    _mmap_load_array(io, "numeric block", A; end_offset)
end
function load(::Val{:mmap}, io::IOStream, ::Nothing=nothing; end_offset::Integer=filesize(io))
    iswritable(io) && throw(ArgumentError("@mmap: load requires a read-only file stream."))
    _mmap_load_array(io, "numeric block", nothing; end_offset)
end

function load(::Val{:mmap}, path::AbstractString, ::Type{A}) where {A<:AbstractArray}
    io = open(path, "r")
    try
        _mmap_load_array(io, path, A)
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
        _mmap_load_array(io, path, nothing)
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

# Automatic mmap needs a format that reloads the value's exact type. DO's own
# format does for a plain `Array` of a supported eltype. Any other type
# qualifies by defining its own path-level `save(::Val{:mmap}, ::AbstractString,
# ::T)` (TreeArrays' `TreeData`, the DataFrames extension's `DataFrame`), so a
# format package needs no second declaration. DO's generic `AbstractArray`
# writer does not count: it densifies via `Array(x)` and reloads a bare
# `Array{ET,N}`, so promoting a wrapper or lazy view (`SubArray`, a pooled view
# over other arrays) would silently hand the caller a different type — the same
# broken promise `_check_mmap_annotation` refuses for an explicit `@mmap`. The
# untyped fallback refuses outright. The round-trip type check on write backs
# all of this up; anything ineligible serializes, which keeps its type.
_automatic_mmap_eligible(value) = _has_own_mmap_save(typeof(value))
_automatic_mmap_eligible(value::Array) =
    isbitstype(eltype(value)) && eltype(value) in _MMAP_ELTYPE_TAGS

function _has_own_mmap_save(::Type{T}) where {T}
    method = try
        which(save, Tuple{Val{:mmap},String,T})
    catch
        return false   # no unique method (ambiguity): no usable format
    end
    method.sig != Tuple{typeof(save),Val{:mmap},AbstractString,AbstractArray} &&
        method.sig != Tuple{typeof(save),Val{:mmap},AbstractString,Any}
end

iscached(o, ::Val) = false
cache_version(o, ::Val) = nothing
compute_property(o, ::Val{:__hash_fields__}) =
    _with_identity_inputs(o, ntuple(Base.Fix1(getfield, o), fieldcount(typeof(o))-1))
compute_property(o, ::Val{:__hash__}) = canonical_hash((typeof(o), o.__hash_fields__))

# An object's default identity covers what it was constructed from: its fixed
# fields AND the constructor keywords its properties read — the `__parent__` an
# `@include` or inline child is mounted under, and overrides of computed
# defaults (snag `include-child-em-c6b53d27`, decision `0e4o8w2`). Before, only
# fixed fields counted, so an `@include`d child reading its parent, or two
# objects differing only in an override, shared one disk cache and served each
# other's entries. `@dynamicstruct` emits the per-type names (sorted): the
# non-indexed properties some body reads (every one when a body hands `__self__`
# to other code), plus `__parent__` when read — never a fixed field, `@state`,
# `@versioned` or another `__…__` name. A type that declares `__hash_fields__`
# or `__hash__` emits none: its override is its identity.
_identity_input_names(::Type) = ()
# The supplied inputs, as a `NamedTuple` in emitted (sorted) order; a `nothing`
# parent is no parent. A remount view shares its retained object's identity, so
# identity reads that object's seed, never the view's rebound context.
function _identity_inputs(o)
    names = _identity_input_names(typeof(o))
    isempty(names) && return (;)
    seed = _identity_seed(getfield(o, :cache))
    picked = Pair{Symbol,Any}[]
    for name in names
        haskey(seed, name) || continue
        value = seed[name]
        name === :__parent__ && value === nothing && continue
        push!(picked, name => value)
    end
    (; picked...)
end
_identity_seed(pc) = _identity_seed(pc.cache, pc.seed)
_identity_seed(_, seed) = seed
# Objects built without inputs keep the exact tuple they always had, so their
# disk keys do not move.
_with_identity_inputs(o, fields::Tuple) = let inputs = _identity_inputs(o)
    isempty(inputs) ? fields : (fields..., inputs)
end
# Replacement keeps unaffected values byte-identical. Dict/Set iteration order is
# not content: a serialization roundtrip can reorder them. Their tokens retain
# the original container type and sort on serialized keys, never on Base.hash.
# The per-walk identity table preserves aliases and terminates container cycles;
# all placeholders and sorting buffers belong to the walk, never to the input.
struct _HashDict{T}
    entries::Vector{Pair{Any,Any}}
end
struct _HashSet{T}
    elements::Vector{Any}
end
struct _HashArray{T,N}
    elements::Array{Any,N}
end
struct _HashPair{T}
    first::Any
    second::Any
end

_hash_replace(x) = x
_hash_replace(x::Union{Tuple,NamedTuple,Pair,Array,Dict,Set}) = _hash_replace(x, IdDict())
# Per-type one-argument methods are emitted by @dynamicstruct and supplied by the
# DataFrames extension. Walk their replacements too (e.g. a Dict-valued column).
function _hash_replace(x, seen)
    y = _hash_replace(x)
    y === x ? x : _hash_replace(y, seen)
end
_hash_replace(x::Tuple, seen) = map(v -> _hash_replace(v, seen), x)
_hash_replace(x::NamedTuple, seen) = map(v -> _hash_replace(v, seen), x)
function _hash_replace(x::Pair, seen)
    a, b = _hash_replace(x.first, seen), _hash_replace(x.second, seen)
    a === x.first && b === x.second ? x : _HashPair{typeof(x)}(a, b)
end
function _hash_replace(x::Array{T,N}, seen) where {T,N}
    (isbitstype(T) || T <: Union{AbstractString,Symbol,Type}) && return x
    haskey(seen, x) && return seen[x]
    elements = Array{Any,N}(undef, size(x))
    token = _HashArray{typeof(x),N}(elements)
    seen[x] = token
    changed = false
    for i in eachindex(x)
        isassigned(x, i) || continue
        elements[i] = _hash_replace(x[i], seen)
        changed |= elements[i] !== x[i]
    end
    seen[x] = changed ? token : x
end

# Serialize each sort key once. Equal canonical keys are possible (two distinct
# DO instances can have one __hash__); break just those ties by the value bytes.
# Sorting every entire key/value pair would repeatedly serialize large values.
function _sort_hash_entries!(entries)
    keys = map(p -> _serialized_bytes(p.first), entries)
    order = sortperm(keys)
    entries[:] = entries[order]
    keys = keys[order]
    i = 1
    while i <= length(entries)
        j = i
        while j < length(entries) && keys[j + 1] == keys[i]
            j += 1
        end
        if j > i
            values = [_serialized_bytes(entries[k].second) for k in i:j]
            entries[i:j] = entries[i:j][sortperm(values)]
        end
        i = j + 1
    end
    entries
end
function _hash_replace(x::Dict, seen)
    haskey(seen, x) && return seen[x]
    entries = Vector{Pair{Any,Any}}(undef, length(x))
    token = _HashDict{typeof(x)}(entries)
    seen[x] = token
    for (i, (k, v)) in enumerate(x)
        entries[i] = _hash_replace(k, seen) => _hash_replace(v, seen)
    end
    _sort_hash_entries!(entries)
    token
end
function _hash_replace(x::Set, seen)
    haskey(seen, x) && return seen[x]
    elements = Vector{Any}(undef, length(x))
    token = _HashSet{typeof(x)}(elements)
    seen[x] = token
    for (i, v) in enumerate(x)
        elements[i] = _hash_replace(v, seen)
    end
    keys = map(_serialized_bytes, elements)
    elements[:] = elements[sortperm(keys)]
    token
end

"""
    DynamicObjects.canonical_hash(x)::String

The content digest DynamicObjects uses for cache identity: a SHA-1 hex string of `x`,
serialized after supported nested `@dynamicstruct` values are replaced by their own
`__hash__` (and, with DataFrames and Arrow loaded, every `DataFrame` by its column names
and columns). It names an object's cache directory and keys its disk-cache entries, so
equal content gives the same digest in every process, however much an object has memoized.

Every default `__hash__` is `canonical_hash((typeof(o), o.__hash_fields__))`, and the
default `__hash_fields__` is what the object was constructed from: its fixed fields, plus
(as a trailing `NamedTuple`) the constructor keywords its properties read — the
`__parent__` it is mounted under and overrides of computed defaults. To choose what an
object's identity covers, override `__hash_fields__`; to also mix in constants such
as a cache-format version, override `__hash__` through `canonical_hash`:

```julia
@dynamicstruct struct Draws
    stan_code
    draws
    stripped_code = replace(stan_code, r"\\s+" => "")
    __hash__ = DynamicObjects.canonical_hash((typeof(__self__), REPLAY_VERSION, (stripped_code, draws)))
end
```

Replacement recurses through `Tuple`, `NamedTuple`, `Pair`, dense `Array`, `Dict` and `Set`.
Dict entries and Set elements are order-independent; their concrete types and scalar
value types remain part of identity. Other containers, array wrappers and arbitrary
structs are serialized as written; sparse or lazy arrays are never densified here.
Repeated references are retained, so alias structure can affect a digest. Order-independent
hashing of cyclic container graphs is not promised.

A digest is the same on every Julia version from 1.10 on: on 1.10 it is the digest
DynamicObjects computed before it made this promise, and later Julia versions compute that
same digest (see `CHANGELOG.md`). This holds for strings, numbers, symbols, chars, `nothing`, `missing`, arrays,
ranges, tuples, named tuples, pairs, Dicts, Sets, types, structs defined in packages,
`@dynamicstruct` objects and DataFrames, and for containers of these. Two kinds of value
are excluded: anonymous functions and closures, whose serialized form holds their code,
and a Dict or Set inside a value that is serialized as written (an arbitrary struct, an
array wrapper), because its iteration order changed in Julia 1.13.

Since 0.5.9, identities containing Dicts/Sets or newly replaced nested values change once:
their old disk entries miss and remain on disk until explicitly cleared. Plain scalar
and numeric array values keep their existing digests. This also lets a worker reconstruct
a Dict-bearing object and publish at the same cache path its requester reads.
"""
canonical_hash(x) = persistent_hash(_hash_replace(x, IdDict()))

# ── @versioned: identity/version split of the disk-cache path ───────────────
# A `@versioned name::T` fixed field is the *version dimension*: excluded from
# the object's cache IDENTITY and instead selecting a per-version subdir, so a
# versioned object caches under `base/<identity>/<version>/…`. All versions of
# one logical object share the identity dir (this is what lets "hold only the
# most recent" prune stale siblings); a fresh version cache-misses cleanly.
# Non-versioned types keep the byte-identical `base/<__hash__>/` layout via the
# fast path below. The per-type `has_versioned_fields` / `_identity_hash_fields`
# / `_identity_hash` / `_version_hash_fields` overrides are emitted by
# @dynamicstruct ONLY when a `@versioned` field is declared, so every existing
# struct is unaffected. A versioned type that declares `__hash__` or
# `__hash_fields__` gets `_identity_hash(o) = o.__hash__`: its override chooses
# what identity covers, as for every type (snag `cache-a-versione-5429048f`).
has_versioned_fields(::Type) = false
_identity_hash_fields(o) = o.__hash_fields__   # non-versioned: identity = all fixed fields
# A `__hash__` or `__hash_fields__` passed to the constructor overrides identity as a
# declared one does, on every shape of type: that is how a consumer reads an entry stored
# under an earlier key (snag `constructor-hash-d738b3b5`). Without this, a versioned type
# with no declaration read the keyword back from `o.__hash__` but cached under the fields,
# so such an object read, wrote and cleared the entries of its current identity.
function _identity_overridden(o)
    seed = _identity_seed(getfield(o, :cache))
    haskey(seed, :__hash__) || haskey(seed, :__hash_fields__)
end
_identity_hash(o) = _identity_overridden(o) ? o.__hash__ : canonical_hash((typeof(o), _identity_hash_fields(o)))
_version_hash_fields(o) = ()                   # non-versioned: no version segment
compute_property(o, ::Val{:__identity_hash__}) = _identity_hash(o)
compute_property(o, ::Val{:__version_tag__}) = begin
    vhf = _version_hash_fields(o)
    isempty(vhf) ? "" : canonical_hash(vhf)
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
# variable. `__parent__` is here too: an external struct mounted with
# `@include` receives its parent as a constructor keyword without declaring it,
# so a bare `__parent__` (e.g. `__hash_fields__ = (__parent__,)`) was an
# `UndefVarError` (snag `include-child-em-c6b53d27`); inline children declare
# it anyway. NOT here: `__status__`/`__substatus__` (`__status__` is threaded
# as a kwarg-local and must STAY the local, never `__self__.__status__`;
# `__substatus__` is an indexed call, not a value).
const _BAREREF_MAGIC = Set{Symbol}([
    :__hash__, :__hash_fields__, :__cache_base__, :__cache_path__, :__strict__,
    :__parent__,
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
# Start a substatus created pending (`__pending__=true`) when its computation begins.
_start_substatus!(s) = nothing
# Running message of a substatus (a queued computation's "queued · #k").
_note_substatus!(s, text) = nothing

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

# Docstring section separators (snag property-progres-3d8a7460, user-resolved
# 2026-09-23): a line of 3+ dashes splits summary from details, a line of 3+
# equals splits the progress part from the OpenAPI part. Surrounding whitespace
# is tolerated (source-indented docstrings, CRLF). The 3+ runs are deliberate:
# any long run works, so there is no magic dash count to remember — the
# resolving comment's `--------------` / `=================` are instances.
# Julia `?` help rendering of these lines is explicitly not a concern (same
# resolution); every structured consumer splits first, so the delimiters never
# reach a renderer.
const _SUMMARY_SEP = r"^\s*-{3,}\s*$"
const _OPENAPI_SEP = r"^\s*={3,}\s*$"

# Split a docstring into its (summary, details, openapi) sections. The FIRST
# `===` line ends the progress part (everything below feeds OpenAPI/schema
# only, never progress); the FIRST `---` line *within the progress part* ends
# the summary (everything between feeds the expanded progress details, once
# Treebars renders them). `---` below `===` is OpenAPI content, not a summary
# split. `explicit_summary` reports whether a `---` split fired — the label
# policy below needs it. All parts are stripped; absent parts are `""`.
function _docstring_sections(doc::AbstractString)
    lines = split(doc, '\n')
    api_at = findfirst(l -> occursin(_OPENAPI_SEP, l), lines)
    progress_lines = api_at === nothing ? lines : lines[1:api_at-1]
    openapi_lines = api_at === nothing ? similar(lines, 0) : lines[api_at+1:end]
    sum_at = findfirst(l -> occursin(_SUMMARY_SEP, l), progress_lines)
    summary_lines = sum_at === nothing ? progress_lines : progress_lines[1:sum_at-1]
    details_lines = sum_at === nothing ? similar(lines, 0) : progress_lines[sum_at+1:end]
    (;
        summary=strip(join(summary_lines, "\n")),
        details=strip(join(details_lines, "\n")),
        openapi=strip(join(openapi_lines, "\n")),
        explicit_summary=sum_at !== nothing,
    )
end

# Docstring summary core — the progress label for a docstring. An EXPLICIT
# summary (author delimited with `---`) is used verbatim: the author drew the
# line, so there is no further magic. Without one, the minimal magic the
# resolution accepted: the progress part's first non-blank line (which keeps
# every existing separator-less docstring rendering sanely). Single-line labels
# shed a leading ATX `#` sigil (heading-led docstrings); multi-line explicit
# summaries pass verbatim. Returns `nothing` when no usable line exists.
#
# This DIVERGES from HTMXObjects' same-named pair (HTMXObjects fa92501) by
# direction of the resolution: the poller header / semantic title / OpenAPI
# summary stay first-line until the HTMXO OpenAPI half of this contract lands,
# at which point the `===` part feeds OpenAPI description and `# Arguments`
# parsing there.
function _docstring_first_line(doc::AbstractString)
    for line in split(doc, '\n')
        stripped = strip(line)
        isempty(stripped) || return stripped
    end
    nothing
end

function _docstring_summary(description)
    description isa AbstractString || return nothing
    sec = _docstring_sections(description)
    text = sec.explicit_summary ? sec.summary : _docstring_first_line(sec.summary)
    text === nothing && return nothing
    isempty(text) && return nothing
    value = occursin('\n', text) ? text : strip(replace(text, r"^#{1,6}\s+" => ""))
    isempty(value) ? nothing : value
end

# Description of a property's substatus node: the property's docstring SUMMARY —
# the docstring is the opt-in signal for "label this in the progress tree", but
# the node shows only the summary section (snag property-progres-3d8a7460). An
# explicit `---`-delimited summary is used verbatim; without one the progress
# part's first line is the label. Everything below `===` is OpenAPI/API
# reference for schema readers, never progress. An undocumented property gets
# an empty string, which makes the Treebars node a bare wrapper the renderer
# inlines (children hoist up; no empty level). This is the
# `displayed = !isnothing(doc)` rule: undocumented properties add no labelled
# noise to the tree, documented ones do — concisely.
#
# `transient` is consumed here (default true → substatus auto-detaches on finalize);
# it does not reach the property body. Pass transient=false to keep finished substatuses
# pinned to the parent tree (e.g. for historical "N finished" pill display).
#
# `__pending__` is consumed here too: `true` creates the node pending (`·`, no clock), for a
# node made before its computation runs — DO's compute paths pass it and start the node
# (`_start_substatus!`) when the body begins, so a computation waiting for an executor or a
# job-queue slot does not look like running work. The default creates a running node.
function _default_substatus(status::Treebars.ProgressNode, o, name, args...; transient=true, __pending__=false, kwargs...)
    # Gate the label PER CALL SIGNATURE: `_is_property_documented` dispatches on
    # `args...` (one method emitted per declaration — `true` if documented,
    # `false` if not), so a property with multiple signatures resolves its OWN
    # doc-presence here — unlike the old `property_doc(metafirst(T, name))`, which
    # keyed on type+name only and always reflected the first declaration. The
    # matching `_property_description` override is likewise per-signature, so the
    # rendered label text derives from the right signature's docstring. (Structs
    # expanded by an older DO carry no overrides and hit the
    # `_is_property_documented` default, which reproduces that historic first-sig
    # gate — no regression; the per-sig fix rolls in as each struct is re-expanded.)
    #
    # Summarize AFTER `_property_description` evaluates: interpolated docstrings
    # (`$kwarg` against call-site values) can inject newlines, and the summary
    # must truncate those too. The full text stays on `_property_description`
    # for reflection (`property_doc`, descriptors, schema/OpenAPI). A docstring
    # with no usable line summaries to `nothing` → `""`, so the node inlines
    # exactly like an undocumented property's. A non-string override result
    # (exotic custom `_property_description` methods) passes through untouched,
    # preserving today's behavior for those.
    desc = if _is_property_documented(o, Val(name), args...; kwargs...)
        full = _property_description(o, Val(name), args...; kwargs...)
        full isa AbstractString ? something(_docstring_summary(full), "") : something(full, "")
    else
        ""
    end
    __pending__ ? Treebars.prepare_progress!(status; description=desc, transient) :
                  Treebars.initialize_progress!(status; description=desc, transient)
end

# Lifecycle hooks — give DO's ThreadsafeDict-spawned substatuses the with_progress
# init/run/finalize symmetry. Success path calls finalize (which detaches transient
# nodes from the tree); failure path calls fail (which leaves failed nodes pinned
# so they stay visible until retry_failed clears them).
_finalize_substatus!(s::Treebars.ProgressNode) = Treebars.finalize_progress!(s)
_fail_substatus!(s::Treebars.ProgressNode, e) = Treebars.fail_progress!(s, e)
_note_substatus!(s::Treebars.ProgressNode, text) = Treebars.update_progress!(s, text)
_start_substatus!(s::Treebars.ProgressNode) = (Treebars.start_progress!(s); nothing)

"""
    DynamicObjects.progress_notes

The words DynamicObjects writes into progress nodes, in English and German: `from_disk`, the
running message of an explicit `@cached`/`@mmap` value read back from disk; `cached`, the note on a
documented property's node when a reader finds its value already in memory; and, for a
computation sent to the job queue's worker process (`configure_queue!(; workers=1)`), the two
phases it waits on before the worker runs it: `starting_worker` while the worker process starts,
and `loading_packages` while the worker loads the packages the computation needs (`{packages}`,
their names). A node is shared
by every viewer, and a computation often runs on a background task, so DynamicObjects writes a
`Treebars.TreebarNote` and each page renders it in its own language (`__lang__`, see Treebars'
`treebar_texts`). An app rewords them by passing this table to `Treebars.treebar_texts`, e.g.
`treebar_texts(:de, DynamicObjects.progress_notes => (from_disk = "von der Festplatte ({size})",))`.
"""
const progress_notes = Treebars.treebar_notes(
    en = (from_disk = "from disk: {size}", cached = "(cached)",
          starting_worker = "Starting the worker process",
          loading_packages = "Loading packages: {packages}"),
    de = (from_disk = "aus dem Zwischenspeicher ({size})", cached = "(zwischengespeichert)",
          starting_worker = "Rechenprozess wird gestartet",
          loading_packages = "Pakete werden geladen: {packages}"))

# Disk-load reporting — set the substatus message to "from disk: <size>" so
# big-file loads show up in the tree instead of stalling silently. Description
# stays as the property label; message is the running annotation Treebars
# renders alongside.
_report_disk_load!(s::Treebars.ProgressNode, cache_path, size_bytes) =
    Treebars.update_progress!(s, progress_notes(:from_disk; size = Treebars.ByteSize(size_bytes)))

"""
    PropertyCache{D}(cache)

Per-DO-instance memoization cache for `@dynamicstruct` properties. `cache::D` is
the underlying `Dict` (`:serial`) or `ThreadsafeDict` (`:parallel`) holding the
memoized values for non-indexed properties. `seed` is the exact kwargs the
instance (or, for a [`remount`](@ref) view, the view) was created with: instance
inputs, not derived memos. [`clear_mem_caches!`](@ref) drops the memos and
restores the seeds, so constructor wiring (`__parent__`, index params, property
overrides, request context) survives a clear instead of recomputing from a
fallback or throwing `MethodError` for an undeclared name.
"""
struct PropertyCache{D<:AbstractDict{Symbol,Any}}
    cache::D
    seed::NamedTuple
    PropertyCache(D, c::NamedTuple) = new{D{Symbol,Any}}(D{Symbol,Any}(pairs(c)), c)
    PropertyCache(c::D) where {D<:AbstractDict{Symbol,Any}} = new{D}(c, (;))
    PropertyCache(c::D, seed::NamedTuple) where {D<:AbstractDict{Symbol,Any}} = new{D}(c, seed)
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
Base.get!(f::Function, c::PropertyCache, key; substatus=nothing, link=nothing, kwargs...) =
    get!(f, c.cache, key; substatus, link)
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

# --- Memo keys ---------------------------------------------------------------------------
#
# An indexed property memoizes per `(args, kwargs)`: two calls share an entry exactly when
# their arguments are `isequal`. Hashing that tuple directly hashes every container argument
# by its full contents, and a cache miss touches the key several times (lookup, latch,
# status, publish), so a large shared argument — a context `Dict` passed to a per-row render
# helper — cost several full content hashes per call (snag `memo-key-hashing-28c8f3be`).
#
# `_MemoKey` carries the hash, computed once per call, and computes each mutable argument's
# content hash once per object: `_content_hash` remembers it by identity in a weak table, so
# later calls passing the same object pay a table lookup. Equality is unchanged (`===`, then
# `isequal`), so equal but distinct containers still share an entry. A remembered hash goes
# stale only if its object is mutated after it was passed as an argument, which do-use §0
# already rules out (and which already corrupted a content-hashed memo dict).
#
# A key iterates and indexes as the tuple `(args, kwargs)`, so `(indices, kwargs) = key`
# keeps working; public surfaces (`entries`, `cached_entries`) report `_plain_key(key)`.
struct _MemoKey{A<:Tuple,K<:NamedTuple}
    args::A
    kwargs::K
    hash::UInt
end
_memo_key(args::Tuple, kwargs::NamedTuple) =
    _MemoKey(args, kwargs, _key_hash(kwargs, _key_hash(args, 0x6d656d6f5f6b6579 % UInt)))
Base.hash(k::_MemoKey, h::UInt) = hash(k.hash, h)
Base.isequal(a::_MemoKey, b::_MemoKey) =
    a.hash == b.hash && _key_isequal(a.args, b.args) && _key_isequal(a.kwargs, b.kwargs)
Base.length(::_MemoKey) = 2
Base.iterate(k::_MemoKey, state::Int=1) =
    state == 1 ? (k.args, 2) : state == 2 ? (k.kwargs, 3) : nothing
Base.getindex(k::_MemoKey, i::Int) =
    i == 1 ? k.args : i == 2 ? k.kwargs : throw(BoundsError(k, i))
Base.show(io::IO, k::_MemoKey) = show(io, _plain_key(k))
_plain_key(k::_MemoKey) = (k.args, k.kwargs)
_plain_key(key) = key

# Tuples and named tuples are walked, so a container inside them is hashed once per object
# too; every other argument contributes `hash(_content_hash(x))`, uniformly, so `isequal`
# arguments of different types (a `Vector` and a range) still hash alike.
_key_hash(t::Tuple, h::UInt) = _key_hash_elements(t, hash(length(t), h))
_key_hash_elements(::Tuple{}, h::UInt) = h
_key_hash_elements(t::Tuple, h::UInt) = _key_hash_elements(Base.tail(t), _key_hash(first(t), h))
_key_hash(nt::NamedTuple, h::UInt) = _key_hash(values(nt), hash(keys(nt), h))
_key_hash(x, h::UInt) = hash(_content_hash(x), h)

_key_isequal(a::Tuple, b::Tuple) = length(a) == length(b) && _key_isequal_elements(a, b)
_key_isequal_elements(::Tuple{}, ::Tuple{}) = true
_key_isequal_elements(a::Tuple, b::Tuple) =
    _key_isequal(first(a), first(b)) && _key_isequal_elements(Base.tail(a), Base.tail(b))
_key_isequal(a::NamedTuple, b::NamedTuple) = keys(a) == keys(b) && _key_isequal(values(a), values(b))
_key_isequal(a, b) = a === b || isequal(a, b)

# `hash(x)`, remembered per mutable object. Strings and symbols compare by content (`===`
# included), so an identity table cannot help them. The table holds weak references, never
# keeps an object alive, and checks `===` before trusting an entry; dead entries are swept
# whenever it doubles.
const _CONTENT_HASHES = Dict{UInt,Tuple{WeakRef,UInt}}()
const _CONTENT_HASHES_LOCK = ReentrantLock()
const _CONTENT_HASHES_SWEEP_AT = Ref(1024)
_content_hash(x) = ismutable(x) && !(x isa Union{AbstractString,Symbol}) ? _remembered_hash(x) : hash(x)
function _remembered_hash(x)
    id = objectid(x)
    known = lock(_CONTENT_HASHES_LOCK) do
        entry = get(_CONTENT_HASHES, id, nothing)
        entry !== nothing && entry[1].value === x ? entry[2] : nothing
    end
    known === nothing || return known
    h = hash(x)   # outside the lock: a large container takes a while
    lock(_CONTENT_HASHES_LOCK) do
        _CONTENT_HASHES[id] = (WeakRef(x), h)
        if length(_CONTENT_HASHES) >= _CONTENT_HASHES_SWEEP_AT[]
            filter!(entry -> last(entry)[1].value !== nothing, _CONTENT_HASHES)
            _CONTENT_HASHES_SWEEP_AT[] = max(1024, 2 * length(_CONTENT_HASHES))
        end
    end
    h
end

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

Calls share an entry when their arguments are `isequal`. A mutable argument is
content-hashed once per object and remembered by identity, so repeated calls
passing the same large container do not re-hash it; never mutate an argument
after passing it.

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
    args_key = _memo_key(args, (;kwargs...))
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
    _fresh_through(property_executor(ip.o, Val(name)),
                   _FreshCompute(ip.o, name, args, (; kwargs...), nothing))
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

# An invalidation retracts the in-flight latch of `key` from a `computing` dict, under
# the latch's lock. The retracted computation publishes nothing (`_run_cache_compute!`),
# so the latch is notified here rather than when that computation ends: waiters parked
# on it wake now, find it gone, and re-resolve — they join a computation started since,
# or start one — however long the retracted computation still runs.
function _retract!(computing::AbstractDict, key)
    cnd = get(computing, key, nothing)
    cnd === nothing && return nothing
    delete!(computing, key)
    notify(cnd)
    nothing
end
function _retract_all!(computing::AbstractDict)
    latches = collect(values(computing))
    empty!(computing)
    foreach(notify, latches)
    nothing
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

# Opaque properties (a bare `__self__` escapes into code the static dependency
# scan cannot follow) are context-dependent only if they actually READ request
# context. Remount views that rebind the same context share one namespace per
# retained cache: an opaque property computes there once, under a guarded
# `__self__` (`_OpaqueProbe`), and its value — and its in-flight latch — serve
# every such view. A computation that reads context through the guard is
# context-dependent: its value goes to the requesting view alone and the key is
# marked `tainted`, so later views compute it view-locally as before.
struct _OpaqueNamespace
    lock::ReentrantLock
    cache::ThreadsafeDict{Symbol,Any}
    subcaches::Dict{Symbol,ThreadsafeDict}
    tainted::Set{Any}   # bare names, or `(name, (indices, kwargs))` for indexed keys
end
_OpaqueNamespace() = _OpaqueNamespace(ReentrantLock(),
    ThreadsafeDict{Symbol,Any}(Dict{Symbol,Any}()), Dict{Symbol,ThreadsafeDict}(), Set{Any}())

_ns_tainted(ns::_OpaqueNamespace, key) = lock(() -> key in ns.tainted, ns.lock)
_ns_taint!(ns::_OpaqueNamespace, key) = lock(() -> (push!(ns.tainted, key); nothing), ns.lock)
_ns_subcache(ns::_OpaqueNamespace, name::Symbol) =
    lock(() -> get!(ThreadsafeDict, ns.subcaches, name), ns.lock)
function Base.empty!(ns::_OpaqueNamespace)
    subcaches = lock(ns.lock) do
        empty!(ns.tainted)
        collect(values(ns.subcaches))
    end
    empty!(ns.cache)
    foreach(empty!, subcaches)
    ns
end

# The namespaces of a retained cache, keyed by the context set they guard, live
# in that cache's own status dictionary under a key no property name can take,
# so they are collected with it. Emptying the cache empties them in place,
# which reaches every live view holding one (`clear_mem_caches!`).
const _REMOUNT_NAMESPACES_KEY = Symbol("#remount-namespaces")

_opaque_namespace(shared::ThreadsafeDict{Symbol,Any}, context_names) = lock(shared.lock) do
    byset = get!(Dict{Any,_OpaqueNamespace}, shared.status, _REMOUNT_NAMESPACES_KEY)
    get!(_OpaqueNamespace, byset, Tuple(sort!(collect(context_names))))
end

function _empty_status!(status::AbstractDict)
    namespaces = pop!(status, _REMOUNT_NAMESPACES_KEY, nothing)
    empty!(status)
    namespaces === nothing && return status
    status[_REMOUNT_NAMESPACES_KEY] = namespaces
    foreach(empty!, values(namespaces))
    status
end

# One guarded computation of an opaque key on behalf of `requester` (a view).
# Context reads through the guard are served from the requester and taint the
# computation. Once sealed, an untainted computation's value is shared, so its
# retained `__self__` must not reach any request's context afterwards.
mutable struct _OpaqueProbe
    const lock::ReentrantLock
    const requester::Any
    const property::Symbol
    tainted::Bool
    sealed::Bool
end
_OpaqueProbe(requester, property::Symbol) = _OpaqueProbe(ReentrantLock(), requester, property, false, false)

"""
    RemountSharedContextError(property, context)

Thrown when request context `context` is read through the `__self__` that a
remount-shared opaque property retained after it finished computing. The
property read no request context while computing, so its value is shared by
every remount view; the retained `__self__` belongs to no request.
"""
struct RemountSharedContextError <: Exception
    property::Symbol
    context::Symbol
end
Base.showerror(io::IO, e::RemountSharedContextError) = print(io,
    "RemountSharedContextError: `", e.property, "` read no request context while it ",
    "computed, so remount views share its value; the `__self__` it retained cannot ",
    "read request context `", e.context, "` afterwards. Read `", e.context,
    "` while computing, or pass it as an argument.")

function _taint!(probe::_OpaqueProbe, context::Symbol)
    lock(probe.lock) do
        probe.sealed && !probe.tainted && throw(RemountSharedContextError(probe.property, context))
        probe.tainted = true
    end
    nothing
end
_seal!(probe::_OpaqueProbe) = lock(() -> (probe.sealed = true; probe.tainted), probe.lock)

# Recorded on the shared latch by a context-dependent guarded computation: every
# accessor computes the key in its own view instead, except the requesting view
# (`token`, its value overlay), which already holds the value — or, when the
# computation failed, rethrows `error`.
struct _RemountContextDependent <: Exception
    property::Symbol
    token::WeakRef
    error::Any
end
Base.showerror(io::IO, e::_RemountContextDependent) = print(io,
    "remount: `", e.property, "` read request context through an escaped `__self__`, ",
    "so each remount view computes it separately")

"""
    MountedThreadsafeDict

Internal `AbstractThreadsafeDict` view used by [`remount`](@ref). Its fields
deliberately match the abstract cache contract (`lock`, `cache`, `status`,
`computing`, `errors`), so the ordinary get/compute/Pending machinery operates
unchanged. Each field is a `MountedDict` over the retained and request-local
dictionaries. `opaque` names the view-local opaque properties that first try
the shared `namespace`; `probe` is set only on the guarded `__self__` of one
such computation.
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
    opaque::Set{Symbol}
    namespace::Union{Nothing,_OpaqueNamespace}
    probe::Union{Nothing,_OpaqueProbe}
    # Shared parent aliases (`_shared_parent_aliases`) => the parent name each copies.
    aliases::Dict{Symbol,Symbol}
end

# Private inner-constructor discriminator emitted by `@dynamicstruct`. A public
# call can never collide with it, and ordinary constructors keep their existing
# signature and overrideable-default behavior.
struct _RemountToken end
const _REMOUNT_TOKEN = _RemountToken()

function MountedThreadsafeDict(shared::ThreadsafeDict{Symbol,Any}, source,
                               local_names, invalidated, seed::NamedTuple,
                               opaque=(), namespace=nothing, aliases=Dict{Symbol,Symbol}())
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
        Set{Symbol}(opaque),
        namespace,
        nothing,
        Dict{Symbol,Symbol}(aliases),
    )
end

# The guarded `__self__` of one opaque computation shares the requester's
# dictionaries. Reads go through `_probe_read`, which serves context from the
# requester; any access that reaches the view-local side directly instead
# (a cache peek, an internal helper) taints the computation the same way.
_probe_dict(c::MountedThreadsafeDict, probe::_OpaqueProbe) = MountedThreadsafeDict(
    c.lock, _tainting(c.cache, probe), _tainting(c.status, probe),
    _tainting(c.computing, probe), _tainting(c.errors, probe), c.shared, c.source,
    c.invalidated, c.local_names, c.opaque, c.namespace, probe, c.aliases)
_tainting(d::MountedDict, probe::_OpaqueProbe) =
    MountedDict(d.shared, _TaintingDict(d.overlay, probe), d.local_names)

struct _TaintingDict{K,V,D<:AbstractDict{K,V}} <: AbstractDict{K,V}
    inner::D
    probe::_OpaqueProbe
end
_touch(d::_TaintingDict, key) = (key in _REMOUNT_STATUS_NAMES || _taint!(d.probe, key); d.inner)
_touch(d::_TaintingDict) = (_taint!(d.probe, Symbol("<view-local cache>")); d.inner)
Base.getindex(d::_TaintingDict, key) = getindex(_touch(d, key), key)
Base.get(d::_TaintingDict, key, default) = get(_touch(d, key), key, default)
Base.haskey(d::_TaintingDict, key) = haskey(_touch(d, key), key)
Base.setindex!(d::_TaintingDict, value, key) = (setindex!(_touch(d, key), value, key); d)
Base.delete!(d::_TaintingDict, key) = (delete!(_touch(d, key), key); d)
Base.pop!(d::_TaintingDict, key) = pop!(_touch(d, key), key)
Base.length(d::_TaintingDict) = length(_touch(d))
Base.iterate(d::_TaintingDict, state...) = iterate(_touch(d), state...)
Base.empty!(d::_TaintingDict) = (empty!(_touch(d)); d)

_remount_probe(o) = _remount_probe(getfield(o, :cache).cache)
_remount_probe(c::MountedThreadsafeDict) = c.probe
_remount_probe(::AbstractDict) = nothing

# An explicit store on a mounted object (the public `setproperty!` is refused)
# is always a local shadow. Computed stores bypass this method and write through
# `c.cache`, whose static routing set sends only proven-invalidated keys local
# and intrinsic keys to the retained cache.
function Base.setindex!(c::MountedThreadsafeDict, value, key::Symbol)
    lock(c.lock) do
        push!(c.local_names, key)
        c.cache.overlay[key] = value
        delete!(c.status.overlay, key)
        _retract!(c.computing.overlay, key)
        delete!(c.errors.overlay, key)
    end
    value
end

# A view's copy of a shared parent alias is current only while the parent still
# holds the very value it copied: once a `sync!` or `clear_cache!` dropped or
# replaced it, the next read re-reads it through the parent. A view kept across
# the drop then never computes shared work from its stale copy. Every read checks:
# the hit fast path (`_peek_hit`) and `get!`.
function Base.get!(f::Function, c::MountedThreadsafeDict, key; kwargs...)
    _revalidate_alias!(c, key)
    invoke(get!, Tuple{Function,AbstractThreadsafeDict,Any}, f, c, key; kwargs...)
end

function _revalidate_alias!(c::MountedThreadsafeDict, key)
    target = get(c.aliases, key, nothing)
    target === nothing || _revalidate_alias!(c, key, target)
    nothing
end

function _revalidate_alias!(c::MountedThreadsafeDict, key::Symbol, target::Symbol)
    held, parent = lock(c.lock) do
        (get(c.cache.overlay, key, _missing_sentinel), get(c.cache.overlay, :__parent__, nothing))
    end
    (held === _missing_sentinel || !_is_dynamic_object(parent)) && return nothing
    _same_value(held, _peek(parent, getfield(parent, :cache).cache, target)) && return nothing
    lock(c.lock) do
        get(c.cache.overlay, key, _missing_sentinel) === held && maybepop!(c, key)
    end
    nothing
end

Base.empty!(c::MountedThreadsafeDict) = begin
    lock(c.lock) do
        empty!(c.shared.cache); _empty_status!(c.shared.status)
        _retract_all!(c.shared.computing); empty!(c.shared.errors)
        empty!(c.cache.overlay); empty!(c.status.overlay)
        _retract_all!(c.computing.overlay); empty!(c.errors.overlay)
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
Base.empty!(c::ThreadsafeDict) = (lock(c.lock) do; empty!(c.cache); _empty_status!(c.status); _retract_all!(c.computing); empty!(c.errors); end; c)
n_running(c::AbstractThreadsafeDict) = lock(c.lock) do; length(c.computing); end
Base.show(io::IO, c::ThreadsafeDict{K,V}) where {K,V} = lock(c.lock) do
    print(io, "ThreadsafeDict{", K, ",", V, "}(", length(c.cache), " cached, ", length(c.computing), " running)")
end
memoize!(ip::IndexableProperty{name,<:Any,<:AbstractThreadsafeDict}, indices...; fetch=Base.fetch, retry_failed=true, kwargs...) where {name} =
    _memoize_linked!(nothing, ip, indices...; fetch, retry_failed, kwargs...)
# `memoize!` whose blocking computation or wait also shows under `link` (see `get!`): the
# memoized call a threaded read makes (`_call_threaded`).
_memoize_linked!(link, ip::IndexableProperty, indices...; kwargs...) = memoize!(ip, indices...; kwargs...)
_memoize_linked!(link, ip::IndexableProperty{name,<:Any,<:AbstractThreadsafeDict}, indices...; fetch=Base.fetch, retry_failed=true, kwargs...) where {name} = begin
    (;o, cache) = ip
    t0 = _trace_clock()   # traced hits include key construction and hashing
    args_key = _memo_key(indices, (;kwargs...))
    fetch = _declared_fetch(fetch, o, Val(name))
    hit = _peek_hit(cache, args_key)
    if hit !== _missing_sentinel
        t0 == 0 || _trace_read!(o, name, _trace_args(indices, args_key.kwargs), Val(:hit), t0)
        _link_hit!(link, cache, args_key, hit)
        return hit
    end
    # Only a miss needs the computation and progress factories. `get!` still
    # arbitrates under its lock if another caller publishes after this peek.
    substatus_f = if name != :__substatus__ && name != :__status__
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name, indices...; __status__=root, __pending__=true, kwargs...)
        end
    else
        nothing
    end
    compute = _Settling(o, name, indices, args_key.kwargs) do s
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
        _adopt_source_child(o, name, args_key, v)
    end
    get!(compute, cache, args_key; fetch, substatus=substatus_f, retry_failed, trace_t0=t0, link)
end
# The substatus is created pending and started by `_run_cache_compute!` when the compute
# runs, so a compute waiting in an executor, a job queue or for a `:default` thread does not
# render as running work and its clock covers only its run.
#
# `substatus()` is invoked OUTSIDE the cache lock. Calling it under the lock is unsafe:
# substatus factories can recurse into other DO properties (e.g. a user-defined
# `_property_description` reads `o.foo`) which re-enter this cache; building `s` under
# `c.lock` would deadlock. So we fast-path first, then build `s` outside the lock and
# re-take it to arbitrate; if we lose the arbitration we discard `s` via finalize.
#
# A selector carrying an executor (`Deferred`, or `_BlockingDeferred` for a blocking call
# of a property with a declared executor) starts a first-arriving compute through it
# instead of inline / `Threads.@spawn`; a blocking caller then waits for it, as for an
# already in-flight compute, through `await_deferred`.
#
# `trace_t0` is when a traced read began (`_trace_clock()`, `0` untraced). A caller that
# builds `key` first (`memoize!` hashes it in `_memo_key`) passes the clock from before, so
# a traced hit's time includes hashing the key.
#
# `link` is the progress node of the code that wrote the read, passed by a read the
# property-body rewrite threads (`_read_threaded` / `_call_threaded`). While a blocking
# access computes the entry or waits for it, the computation's node also shows under
# `link` (`_linked`). Hits and polls never link. An `_Attached` link (`@fetch!` /
# `@progress`) keeps the node there and shows hits too (`_link_hit!`).
Base.get!(f::Function, c::AbstractThreadsafeDict, key; fetch=Base.fetch, substatus=nothing, retry_failed=true,
          trace_t0=_trace_clock(), link=nothing) = begin
    # Fast path: a ready value returns immediately, no substatus cost. (`_missing_sentinel`
    # distinguishes "absent" from a legitimately-cached `nothing`.)
    t0 = trace_t0
    hit = lock(c.lock) do
        v = get(c.cache, key, _missing_sentinel)
        v !== _missing_sentinel && (_on_hit!(c, key); return v)
        _missing_sentinel
    end
    if hit !== _missing_sentinel
        t0 == 0 || _trace_read!(f, Val(:hit), t0)
        _link_hit!(link, c, key, hit)
        return hit
    end
    # Build the substatus OUTSIDE the lock — factories recurse into DO props on the SAME
    # lock, so building under it would deadlock.
    s = isnothing(substatus) ? nothing : substatus()
    sync = _is_blocking(fetch)
    executor = _selector_executor(fetch)
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
        return sync && executor === nothing ? (:inline, cnd) : (:start, cnd)
    end
    kind = action[1]
    if kind === :value
        !isnothing(s) && _finalize_substatus!(s)
        t0 == 0 || _trace_read!(f, Val(:hit), t0)
        _link_hit!(link, c, key, action[2])
        return action[2]
    end
    if kind === :error
        !isnothing(s) && _finalize_substatus!(s)
        t0 == 0 || _trace_read!(f, Val(:failed), t0)
        throw(action[2])
    end
    if kind === :wait
        # Blocking waiter: block on the in-flight computer's latch, then read value/error.
        # We built `s` but aren't the computer; finalize it (the winner owns the status).
        !isnothing(s) && _finalize_substatus!(s)
        return _linked(link, link === nothing ? nothing : _status_of(c, key)) do
            _await_cache_value!(c, key, action[2]::Threads.Condition, f; fetch, substatus, retry_failed, link)
        end
    end
    if kind === :pending
        # Poller, compute already in flight elsewhere — hand back a cheap Pending, no spawn.
        !isnothing(s) && _finalize_substatus!(s)
        t0 == 0 || _trace_read!(f, Val(:pending), t0)
        return fetch(Pending(c, key, nothing, executor, _resolver(f, c, key, fetch, substatus, retry_failed)))
    end
    if kind === :inline
        # Blocking first-arriver: compute on THIS thread (no spawn), publish, return value.
        return _linked(link, s) do
            _run_cache_compute!(c, key, action[2]::Threads.Condition, f, s)
        end
    end
    # :start — first-arriver of a poller, or of any caller with an executor: kick the
    # REAL compute off (it writes the cache, or records a failure in `c.errors`). The Task
    # is NOT retained — its value/error both reach us through the cache/errors + the
    # latch. Without an executor it spawns on the `:default` pool; the selector's
    # executor (a caller's `Deferred`, or a declared `property_executor`) receives it
    # instead.
    cnd = action[2]::Threads.Condition
    _start_compute(executor, DeferredCompute(c, key, cnd, f, s))
    # A blocking caller waits for the compute it started, as for one already in flight.
    sync && return _linked(link, s) do
        _await_cache_value!(c, key, cnd, f; fetch, substatus, retry_failed, link)
    end
    p = Pending(c, key, nothing, executor, _resolver(f, c, key, fetch, substatus, retry_failed))
    # An executor may have run the compute synchronously: hand back the value.
    executor !== nothing && isready(p) && return Base.fetch(p)
    t0 == 0 || _trace_read!(f, Val(:pending), t0)
    return fetch(p)
end

# What a `Pending` handle runs when its computation was retracted mid-flight: the same
# access, blocking.
_resolver(f, c, key, fetch, substatus, retry_failed) =
    () -> get!(f, c, key; fetch=_blocking_selector(fetch), substatus, retry_failed)

# --- Deferred compute starts -------------------------------------------------------------

"""
    ComputeAbandoned(reason)

Recorded as a key's failure when an executor `abandon!`s a queued compute instead of
running it, or when the worker process running it (see
`configure_queue!`) exited or was restarted
(`started` is then `true`). Waiters and pollers see it like any other failure; with the
default `retry_failed=true` the next access starts a fresh compute.
"""
struct ComputeAbandoned <: Exception
    reason::String
    started::Bool
end
ComputeAbandoned(reason::AbstractString) = ComputeAbandoned(String(reason), false)
Base.showerror(io::IO, e::ComputeAbandoned) = e.started ?
    print(io, "ComputeAbandoned: the compute was abandoned while it ran: ", e.reason) :
    print(io, "ComputeAbandoned: the queued compute was abandoned before it started: ", e.reason)

# Deferred work runs as its requester — whoever created the `DeferredCompute` or `QueuedCall`
# — would have run it. A task does not inherit task-local storage, and inherits its scoped
# values and logger from the task that spawns it: an executor's worker, or the job whose
# released slot admits the work. So the requester's dynamic scope and logger are captured
# where the work is created and re-entered on whichever task runs it, with one exception:
# the job queue's slot (`_QUEUE_HOLDER`) stays the running task's own, since it belongs to
# the computation running, not to whoever asked for it. On Julia 1.10 ScopedValues.jl keeps
# the scope inside the task's logger, so the logger is captured on its own (unwrapped).
mutable struct _RequesterRun
    const logger::Any
    work::Any     # what `run!` runs; set when it runs
    holder::Any   # the running task's queue slot; read when it runs
end
(r::_RequesterRun)() =
    _in_logger(() -> ScopedValues.with(r.work, _QUEUE_HOLDER => r.holder), r.logger)

struct _Requester
    run::_RequesterRun
    in_scope::ScopedValues.ScopedThunk{_RequesterRun}   # `run` in the requester's scope
end
function _Requester()
    run = _RequesterRun(_requester_logger(), nothing, nothing)
    _Requester(run, ScopedValues.ScopedThunk(run))
end

_requester_logger() = ScopedValues.current_logger()
_in_logger(f, logger) =
    logger === ScopedValues.current_logger() ? f() : ScopedValues.with_logger(f, logger)

# Run `f()` on the calling task as `r`'s requester would have. Once per requester: `run!`
# claims its work before it gets here.
function _as_requested(f, r::_Requester)
    r.run.work = f
    r.run.holder = _QUEUE_HOLDER[]
    r.in_scope()
end

"""
    DeferredCompute

One first-arriving compute, handed to a [`Deferred`](@ref) executor. Its in-flight latch is
already registered, so concurrent accessors of the same key already dedupe onto it — blocking
callers wait for it, pollers receive a `Pending` — for as long as it sits in the executor's
queue. Its progress node stays pending (`·`, no elapsed time) until `run!` starts it.

The executor must eventually call exactly one of:

- `run!(d)` — run the compute on the calling task. Call it from a worker to run
  in the background; calling it synchronously inside the executor makes the originating
  `get!` behave like a blocking accessor — the value, not a `Pending`, comes back (the escape
  hatch for a compute started from inside one of the executor's own workers, where queueing
  behind yourself would deadlock).
- `abandon!(d, reason)` — never run it; the key fails with
  [`ComputeAbandoned`](@ref).

Only the first of the two takes effect. Dropping a `DeferredCompute` without calling either
leaves the key in flight forever.

Whichever task calls `run!`, the compute runs as an undeferred compute would where it was
started: under the logger current there, and with every `ScopedValue` set there (a layer's
own request context, a [`with_compute_trace`](@ref) scope). Only the job queue's slot is the
running task's own.
"""
mutable struct DeferredCompute
    const cache::AbstractThreadsafeDict
    const key::Any
    const latch::Threads.Condition
    const f::Any
    const status::Any
    @atomic claimed::Bool
    const requester::_Requester   # the scope and logger it was started in
end
DeferredCompute(c, key, cnd, f, s) = DeferredCompute(c, key, cnd, f, s, false, _Requester())

_claim!(d::DeferredCompute) = (@atomicswap d.claimed = true) === false

"""
    run!(d::DeferredCompute) -> Bool

Run a deferred compute on the calling task, publishing its value (or recording its failure)
exactly as an undeferred compute would. Returns `false` without running if `d` was already
run or abandoned. Failures are recorded for waiters/pollers, not rethrown.
"""
function run!(d::DeferredCompute)
    _claim!(d) || return false
    try
        _as_requested(d.requester) do
            _run_cache_compute!(d.cache, d.key, d.latch, d.f, d.status)
        end
    catch
        # recorded in `d.cache.errors` and the substatus by `_run_cache_compute!`
    end
    true
end

"""
    abandon!(d::DeferredCompute, reason="abandoned") -> Bool

Fail a queued compute without running it: records [`ComputeAbandoned`](@ref) for the key,
releases its latch (waking blocked accessors) and fails its substatus. Returns `false` if `d`
was already run or abandoned.
"""
function abandon!(d::DeferredCompute, reason::AbstractString="abandoned")
    _claim!(d) || return false
    err = ComputeAbandoned(String(reason))
    c = d.cache
    # Failed before waiters wake, as in `_run_cache_compute!`.
    !isnothing(d.status) && _fail_substatus!(d.status, err)
    lock(c.lock) do
        # A latch an invalidation retracted is not this key's failure (`_run_cache_compute!`).
        if get(c.computing, d.key, nothing) === d.latch
            delete!(c.computing, d.key)
            c.errors[d.key] = err
        end
        notify(d.latch)
    end
    true
end

"""
    Deferred(executor)

A nonblocking fetch selector that schedules work through
`executor(work::DeferredCompute)`. The first caller receives a [`Pending`](@ref)
handle while the work waits or runs. Use it where `fetch=identity` is accepted.

The executor is called after registering the in-flight entry, with no cache lock
held. It should enqueue promptly, then eventually run or abandon the work under
the [`DeferredCompute`](@ref) contract. A deliberately inline executor may run
it immediately. Declaration-level scheduling uses
`DynamicObjects.property_executor`; blocking waits cooperate through
`DynamicObjects.await_deferred`.
"""
struct Deferred{E}
    executor::E
end

# As a selector a `Deferred` is `identity`: the handle it is applied to is returned as is.
(::Deferred)(x) = x

"""
    DynamicObjects.property_executor(o, ::Val{name}) -> executor or nothing

Declaration-site executor of indexed property `name`. When it returns an executor, every
memoized computation of the property starts through `executor(d::DeferredCompute)`, whichever
task triggers it and however it is called: a blocking call `o.name(args...)`, a
progress-threaded call under `@progress` / `@fetch!` (both computed inline otherwise), or a
poll (`fetchindex`, `fetch=identity`). It is `fetch=Deferred(executor)` chosen
by the declaration instead of by each caller; a caller's own `fetch=Deferred(other)` takes
precedence. The default, `nothing`, keeps the per-call behavior.

A macro layered on `@dynamicstruct` declares it next to the property:

```julia
DynamicObjects.property_executor(::Jobs, ::Val{:item}) = JOB_QUEUE
```

Memoization is unchanged: a cached value never reaches the executor, and concurrent callers
with the same arguments share one `DeferredCompute`, whether it is queued or running. A
blocking caller waits for it through [`await_deferred`](@ref DynamicObjects.await_deferred);
when the executor runs the compute synchronously, the call returns the value without waiting.
`@fresh` calls (declaration- or call-site) bypass the cache, its in-flight latch and hence
the executor — except a job queue's [`QueueExecutor`](@ref DynamicObjects.QueueExecutor)
(`@queued`), which admits each fresh computation too, as a
[`QueuedCall`](@ref DynamicObjects.QueuedCall) the caller waits for. See
[`DeferredCompute`](@ref) for the executor contract.
"""
property_executor(o, ::Val) = nothing

"""
    DynamicObjects.await_deferred(wait, executor)

Wraps every blocking wait of a call that carries `executor` (any call of a property whose
[`property_executor`](@ref DynamicObjects.property_executor) returns it, or a call with
`fetch=Deferred(executor)`), including a blocking `fetch` of a [`Pending`](@ref) such a call
returned. For a property with a
declared executor that is every blocking wait on it: a caller waiting for the compute it
handed to the executor, and a caller that finds the computation already queued or running.
Waits that would not block (the value or failure is already recorded) do not call it.

`wait()` blocks the calling task until the computation settles and returns its value or
throws its failure. The default just calls `wait()`. An executor's owner overloads it for
its executor type to learn when a task starts and stops blocking, for example to give a
job's runner slot back while that job waits:

```julia
function DynamicObjects.await_deferred(wait, q::JobQueue)
    release_slot!(q)
    try
        wait()
    finally
        reacquire_slot!(q)
    end
end
```

An overload must call `wait()` exactly once, on the calling task, and return its result.
"""
await_deferred(wait, executor) = wait()

"""
    DynamicObjects.property_settled(o, ::Val{name}, value, args...; kwargs...)

Settlement hook of memoized property `name`. DO calls it each time a computation of the
property stores its result in memory: the body ran, or an explicit `@cached` / `@mmap` entry
was read from disk. `value` is the stored value; for an indexed property, `args` and `kwargs`
are the call's. The default does nothing.

Define it as an ordinary method, or as a member method in the struct body, where sibling
names read as they do in a property body:

```julia
@dynamicstruct struct Table
    root::String
    subscriptions::KeySubscriptions
    runs = TrackedDirectory(root)
    snapshot = build_snapshot(runs)
    DynamicObjects.property_settled(__self__, ::Val{:snapshot}, value) =
        foreach(key -> invalidate_key!(subscriptions, key), value.changed_keys)
end
```

It runs once per stored value: after the store, after every caller waiting for that
computation has been released, outside every cache lock, on the task that ran the
computation, which returns only after the hook does. Reading the property inside the hook
returns `value` unless something dropped it meanwhile. It does not run for a cache hit, for a
caller that waited for the computation, for a failed computation, for a `@fresh` call (it
stores nothing), for a computation an invalidation retracted while it ran (it stores nothing
either), or for a value seeded by a constructor, `remake` or `clear_mem_caches!`. A
governed host's automatic storage, which may swap the stored value for its persisted copy or
reload it later, does not call it either. A throwing hook is logged with its backtrace; the
value stays stored and is returned to the caller.

`o` is the object whose read ran the computation: a `remount` view when one did. A view
whose computation reads request context reports its own value.

Notify from here, not from the property's body: inside the body the value is not stored
yet, the computation can still fail, and reading the property waits for itself. Keep the
hook short and start heavy work on another task. Unlike `BackgroundCache`'s `on_settle`
there is no `old` value, because a dropped value is gone before its replacement is computed:
carry whatever a consumer compares in the value itself.
"""
property_settled(o, ::Val, value, args...; kwargs...) = nothing

# A compute closure that reports what it stores to `property_settled`.
# `_run_cache_compute!` calls `_settled!` only when this computation stored its value.
# `local_value` (a `Ref`, else `nothing`) holds the requester's own value of an opaque
# remount computation that read request context: it is stored view-locally while the
# shared computation fails, and is reported from `_failed!` once the failure is recorded.
struct _Settling{F,O,A<:Tuple,K<:NamedTuple,L<:Union{Nothing,Base.RefValue{Any}}} <: Function
    f::F
    o::O
    name::Symbol
    args::A
    kwargs::K
    local_value::L
end
_Settling(f, o, name::Symbol, args::Tuple=(), kwargs::NamedTuple=(;)) =
    _Settling(f, o, name, args, kwargs, nothing)
(s::_Settling)(status) = s.f(status)

_settled!(f, value) = nothing
_settled!(s::_Settling, value) = _property_settled!(s.o, s.name, value, s.args, s.kwargs)
_failed!(f) = nothing
_failed!(s::_Settling) = _settled_local!(s, s.local_value)
# A producer that mirrors another process's node owns its terminal progress state.
_finish_compute_status!(f, status) = _finalize_substatus!(status)
_fail_compute_status!(f, status, err) = _fail_substatus!(status, err)
_finish_compute_status!(s::_Settling, status) = _finish_compute_status!(s.f, status)
_fail_compute_status!(s::_Settling, status, err) = _fail_compute_status!(s.f, status, err)
_settled_local!(s::_Settling, ::Nothing) = nothing
function _settled_local!(s::_Settling, local_value::Base.RefValue{Any})
    value = local_value[]
    value === _missing_sentinel || _property_settled!(s.o, s.name, value, s.args, s.kwargs)
    nothing
end

function _property_settled!(o, name::Symbol, value, args, kwargs)
    try
        property_settled(o, Val(name), value, args...; kwargs...)
    catch e
        @error "property_settled hook threw; the computed value stays stored" type = typeof(o) property = name exception = (e, catch_backtrace())
    end
    nothing
end

# Internal selectors whose compute starts through `executor`, chosen for a call of a
# property with a declared executor: `_DeferredSelect` applies the caller's asynchronous
# selector to the handle (`identity` for a poll), `_BlockingDeferred` blocks for the value
# in place of `Base.fetch`.
struct _DeferredSelect{E,F}
    executor::E
    select::F
end
(sel::_DeferredSelect)(x) = sel.select(x)
struct _BlockingDeferred{E}
    executor::E
end
const _ExecutorSelector = Union{Deferred,_DeferredSelect,_BlockingDeferred}

_is_blocking(fetch) = fetch === Base.fetch || fetch isa _BlockingDeferred
_selector_executor(sel::_ExecutorSelector) = sel.executor
_selector_executor(_) = nothing
# The blocking form of a selector (an opaque remount guard reads values, never handles).
_blocking_selector(sel::_ExecutorSelector) = _BlockingDeferred(sel.executor)
_blocking_selector(_) = Base.fetch

# The selector a call of property `name` runs with: a caller's executor selector as is;
# otherwise the declared `property_executor`, if any, starts the compute.
_declared_fetch(fetch, o, name::Val) = _declared_fetch(property_executor(o, name), fetch)
_declared_fetch(::Nothing, fetch) = fetch
_declared_fetch(executor, fetch) = _executor_fetch(executor, fetch)
_executor_fetch(executor, fetch::_ExecutorSelector) = fetch
_executor_fetch(executor, ::typeof(Base.fetch)) = _BlockingDeferred(executor)
_executor_fetch(executor, fetch) = _DeferredSelect(executor, fetch)

_start_compute(::Nothing, d::DeferredCompute) = (Threads.@spawn run!(d); nothing)
_start_compute(executor, d::DeferredCompute) = (executor(d); nothing)

# Singleton sentinel so a single `get` lookup distinguishes "key absent" from
# "key present with value === nothing" without allowing collision with any
# user-stored value.
struct _Missing end
const _missing_sentinel = _Missing()

include("compute_trace.jl")

include("job_queue.jl")

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
        _retract!(c.computing, key)
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
        get(ip.cache.status, _memo_key(indices, (;kwargs...)), nothing)
    end
end
getstatus(::IndexableProperty, indices...; kwargs...) = nothing

# `cancel!` / `cancel_all!` were removed (2026-07): interrupting a running compute required
# the retained compute Task, which we no longer keep — the value lands in `cache`/the slot
# and failures in `errors`, so the Task carries nothing. There is no cooperative-cancellation
# replacement; cancellation is not a supported operation.

"""
    invalidate!(ip::IndexableProperty, indices...; kwargs...)

Drop exactly one indexed-property cache entry — the in-memory value (plus any
in-flight latch, recorded error, and status node) and the on-disk payload
(`@cached` / `@mmap` / auto-materialized) — for the key
`(indices, (;kwargs...))`. Sibling entries are untouched. The next access
recomputes and re-caches.

This is the same primitive `fetchindex(...; force=true)` runs before
recomputing, also reachable as `@clear_cache! obj.prop(indices...)`.

In-flight semantics (there is no cancellation — DynamicObjects retains no
compute handle): invalidating while a compute runs does not stop it, and its
caller gets its value. But the value may derive from what was invalidated, so
the compute stores nothing — no memory value, no `@cached`/`@mmap` entry, no
automatic entry. Blocking waiters and a [`Pending`](@ref) handle taken before
re-resolve: they wait for a compute started since, or start one. They do so at
the invalidation, not when the invalidated compute ends, so one that never
finishes holds up nobody but its own caller. So a re-access
after `invalidate!`, and `force=true`, always serve a post-invalidation value.
This holds wherever the invalidation is issued from, including the body of a
computation of the same object.
"""
function invalidate!(ip::IndexableProperty, indices...; kwargs...)
    key = _memo_key(indices, (;kwargs...))
    traced = _trace_scope() !== nothing
    held = traced && haskey(ip.cache, key)
    maybepop!(ip.cache, key)
    on_disk = _remove_disk_entry!(ip.o, name(ip), indices...; kwargs...)
    traced && _trace_invalidation!(:invalidate!, ip.o, held || on_disk ? (name(ip),) : (), _plain_key(key))
    _forward_entry_invalidation(ip.o, name(ip), indices, (; kwargs...))
    nothing
end

# Remove one entry's disk payload (explicit `@cached`/`@mmap` or automatic) and
# its automatic-materialization metadata, if present. Returns whether a payload was removed.
function _remove_disk_entry!(o, name::Symbol, indices...; kwargs...)
    path = get_cache_path(o, name, indices...; kwargs...)
    removed = isfile(path)
    removed && rm(path)
    metadata_path = _automatic_materialization_path(path)
    isfile(metadata_path) && rm(metadata_path)
    removed
end

# --- Stale-while-revalidate background cache -------------------------------------------
#
# A standalone keyed cache for values refreshed from slow external sources (remote
# APIs, filesystem scans). Deliberately NOT built on `ThreadsafeDict`: that machinery
# is compute-at-most-once with blocking waiters / `Pending` handles and rethrown
# failures, while this contract is serve-stale-never-block with logged failures —
# sharing the implementation would couple two different policies.

"""
    BackgroundCache{K,V}(build; ttl, unbuilt, maxsize=0, backoff_base=1.0, backoff_max=60.0, on_settle=(key, old, new) -> nothing)
    BackgroundCache{K,V}(build_many; batch, ttl, unbuilt, maxsize=0, backoff_base=1.0, backoff_max=60.0, on_settle=(key, old, new) -> nothing)

Keyed stale-while-revalidate cache.

Reads (`c[key]`) never block and never throw for cache reasons:

- a fresh value (settled less than `ttl` seconds ago) is returned as is;
- a stale value is returned immediately while a background refresh is kicked
  off — at most one refresh per key is ever in flight, so concurrent readers of
  a stale key share it;
- a key with no settled value reads as `unbuilt` (declared at construction —
  there is no default) while its first build runs in the background.

A refresh that throws keeps the previous value (or `unbuilt`), logs an error
with a backtrace, and gates the key behind an exponential backoff
(`backoff_base * 2^(n-1)` seconds after the `n`th consecutive failure, capped
at `backoff_max`): reads during the gate serve the old value without kicking
another refresh. A success clears the failure count.

With `maxsize > 0` the cache holds at most `maxsize` settled entries; storing
past the bound evicts settled keys with the oldest settle time first (an
`O(n)` scan — this is a small policy cache, not a store). `ttl=Inf` never goes
stale; `ttl=0` revalidates on every idle read.

By default `build(key)::V` builds one key per background task. Pass `batch=N`
(a positive integer) to refresh up to `N` wanted keys with one call instead:
the first positional argument is then `build_many(keys::Vector{K})::AbstractDict`,
one background drain task per cache feeds it batches of at most `N` keys, and
each key in a batch settles (or fails with backoff) individually. A thrown
batch call fails every key in that batch; a key missing from the returned dict
— or holding a value that is not a `V` — fails that key alone while present
keys still settle. Extra keys in the result are ignored.

After each successful store — once per settled key in batch mode too — the
cache invokes `on_settle(key, old, new)` outside the lock, so a re-entrant
read inside the callback observes the new value. `old` is the previously
settled value, or `unbuilt` when the key had none (first build,
post-`invalidate!`, or eviction). Failures never invoke it. It fires even when
`new == old` — compare them to skip unchanged values. A throwing callback is
logged with its key and backtrace and never breaks the refresh or the drain.
The refresh stays in flight until the callback returns: reads of that key
meanwhile, the callback's own included, serve the new value without kicking
another refresh, even at `ttl=0`. Callbacks for one key therefore never
overlap.

Every background refresh task, and the batch drain before each claim, yields
to the scheduler, so a refresh storm (say, other tasks that re-request each key
as it settles at `ttl=0`) wastes builds but never starves the other tasks,
timers or I/O on its thread.

Timestamps use the monotonic clock. Treat returned values (including `unbuilt`)
as read-only, and likewise the `old`/`new` values handed to `on_settle`.
See also [`invalidate!`](@ref).
"""
struct BackgroundCache{K,V,F,S}
    lock::ReentrantLock
    values::Dict{K,V}
    stamps::Dict{K,UInt64}
    refreshing::Set{K}
    failures::Dict{K,Int}
    not_before::Dict{K,UInt64}
    build::F
    on_settle::S
    ttl_ns::UInt64
    unbuilt::V
    maxsize::Int
    backoff_base::Float64
    backoff_max::Float64
    batched::Bool
    batch_size::Int
    pending::Vector{K}
    batch_running::Ref{Bool}
    function BackgroundCache{K,V}(build::F; ttl::Real, unbuilt::V, maxsize::Integer=0,
                                  backoff_base::Real=1.0, backoff_max::Real=60.0,
                                  batch::Union{Nothing,Integer}=nothing,
                                  on_settle=(key, old, new) -> nothing) where {K,V,F}
        ttl >= 0 || throw(ArgumentError("BackgroundCache ttl must be non-negative or Inf, got $ttl"))
        maxsize >= 0 || throw(ArgumentError("BackgroundCache maxsize must be non-negative, got $maxsize"))
        backoff_base >= 0 || throw(ArgumentError("BackgroundCache backoff_base must be non-negative, got $backoff_base"))
        backoff_max >= 0 || throw(ArgumentError("BackgroundCache backoff_max must be non-negative, got $backoff_max"))
        if batch !== nothing
            batch >= 1 || throw(ArgumentError("BackgroundCache batch must be a positive integer, got $batch"))
        end
        ttl_ns = isinf(ttl) ? typemax(UInt64) : round(UInt64, Float64(ttl) * 1e9)
        S = typeof(on_settle)
        new{K,V,F,S}(ReentrantLock(), Dict{K,V}(), Dict{K,UInt64}(), Set{K}(),
                     Dict{K,Int}(), Dict{K,UInt64}(), build, on_settle, ttl_ns, unbuilt,
                     Int(maxsize), Float64(backoff_base), Float64(backoff_max),
                     batch !== nothing, batch === nothing ? 1 : Int(batch),
                     K[], Ref(false))
    end
end

Base.show(io::IO, c::BackgroundCache{K,V}) where {K,V} = lock(c.lock) do
    print(io, "BackgroundCache{", K, ",", V, "}(", length(c.values), " settled, ",
          length(c.refreshing), " refreshing)")
end

_backoff_ns(c::BackgroundCache, n::Int) = begin
    delay = min(c.backoff_base * 2.0^(n - 1), c.backoff_max)
    isfinite(delay) ? round(UInt64, delay * 1e9) : typemax(UInt64)
end

# Drop every settled/gate record for `key`. The in-flight marker is owned by the
# refresh task and is never cleared here. Call under `c.lock`.
function _drop_swr_key!(c::BackgroundCache, key)
    delete!(c.values, key)
    delete!(c.stamps, key)
    delete!(c.failures, key)
    delete!(c.not_before, key)
    nothing
end

# Evict stalest-settled keys until within `maxsize`. Call under `c.lock`.
function _enforce_swr_bound!(c::BackgroundCache)
    c.maxsize <= 0 && return nothing
    while length(c.values) > c.maxsize
        oldest = first(keys(c.values))
        oldest_t = c.stamps[oldest]
        for k in keys(c.values)
            t = c.stamps[k]
            if t < oldest_t
                oldest = k
                oldest_t = t
            end
        end
        _drop_swr_key!(c, oldest)
    end
    nothing
end

# Invoke the settle callback OUTSIDE the lock, after the value is published —
# a re-entrant read inside the callback observes the new value. A throwing
# callback is logged, never rethrown: the store already succeeded.
function _notify_swr_settle!(c::BackgroundCache{K,V}, key::K, old::V, new::V) where {K,V}
    try
        c.on_settle(key, old, new)
    catch e
        @error "BackgroundCache on_settle callback failed" key = key exception = (e, catch_backtrace())
    end
    nothing
end

# Publish a built value, then notify the settle callback. The key's in-flight
# marker is released only once the callback returns: until then reads — the
# callback's own re-entrant read included — serve the new value and kick
# nothing, even at `ttl=0`, where a callback that re-reads its key would
# otherwise rebuild it forever.
function _settle_swr_key!(c::BackgroundCache{K,V}, key::K, v::V) where {K,V}
    old = lock(c.lock) do
        prev = get(c.values, key, c.unbuilt)
        c.values[key] = v
        c.stamps[key] = time_ns()
        delete!(c.failures, key)
        delete!(c.not_before, key)
        _enforce_swr_bound!(c)
        prev
    end
    try
        _notify_swr_settle!(c, key, old, v)
    finally
        lock(c.lock) do
            delete!(c.refreshing, key)
        end
    end
    nothing
end

# Run one refresh to completion: build OUTSIDE the lock, then settle (or, on
# any failure, gate behind backoff and log with a backtrace — never rethrow, so
# the background task carries nothing out).
function _run_swr_refresh!(c::BackgroundCache{K,V}, key::K) where {K,V}
    try
        _settle_swr_key!(c, key, c.build(key)::V)
    catch e
        n = lock(c.lock) do
            delete!(c.refreshing, key)
            n = get(c.failures, key, 0) + 1
            c.failures[key] = n
            c.not_before[key] = time_ns() + _backoff_ns(c, n)
            n
        end
        @error "BackgroundCache refresh failed; keeping the previous value" key = key attempt = n exception = (e, catch_backtrace())
    end
    nothing
end

# Every background refresh unit (this task, each drain iteration) yields before
# building. A task started from another task's exit never polls libuv, so a
# chain of refreshes that each kick the next — e.g. an `on_settle` feedback
# loop at `ttl=0` — would otherwise keep the run queue non-empty forever and
# starve its thread's timers, I/O and other tasks. The resumed yield processes
# pending events, so such a storm costs CPU, never the thread.
function _kick_swr_refresh!(c::BackgroundCache{K,V}, key::K) where {K,V}
    errormonitor(Threads.@spawn begin
        yield()
        _run_swr_refresh!(c, key)
    end)
    nothing
end

# Mark `key` wanted by the batch drain, starting the drain when idle. The
# caller has already pushed `key` to `refreshing`. Call under `c.lock`; returns
# `:settled` when a drain is already running (the key rides it) or `:batch_kick`
# when the caller must spawn one outside the lock.
function _enqueue_swr_batch!(c::BackgroundCache{K,V}, key::K) where {K,V}
    push!(c.pending, key)
    c.batch_running[] && return :settled
    c.batch_running[] = true
    :batch_kick
end

function _kick_swr_batch_drain!(c::BackgroundCache)
    errormonitor(Threads.@spawn _run_swr_batch_drain!(c))
    nothing
end

# Drain loop: exactly one runs per cache at a time (guarded by `batch_running`
# under the lock). Each iteration claims up to `batch_size` wanted keys and
# feeds them to one `build_many` call; keys arriving mid-build ride the next
# iteration. Exits (clearing the flag) only on an empty queue observed under
# the lock, so no wakeup is lost: an enqueue after the check finds the flag
# clear and spawns the successor. Yields before every claim (see
# `_kick_swr_refresh!`): a drain kept busy by its own settles never pins its
# thread, and same-thread readers get to enqueue before the next claim.
function _run_swr_batch_drain!(c::BackgroundCache{K,V}) where {K,V}
    while true
        yield()
        batch_keys = lock(c.lock) do
            if isempty(c.pending)
                c.batch_running[] = false
                return nothing
            end
            splice!(c.pending, 1:min(c.batch_size, length(c.pending)))
        end
        batch_keys === nothing && return nothing
        _run_swr_batch!(c, batch_keys)
    end
end

# Run one batch build to completion: build OUTSIDE the lock, then settle each
# key individually, notifying the settle callback per settled key (or, on any
# failure, gate behind backoff and log with a backtrace — never rethrow, so
# the background task carries nothing out). A thrown call fails every key in
# the batch but logs once for the whole batch (one exception/backtrace shared
# by every key); a key missing from the result (or holding a non-`V` value)
# fails that key alone and logs per key. The builder gets a copy of the
# claimed keys, so a builder that mutates its input cannot strand keys in
# `refreshing`.
function _run_swr_batch!(c::BackgroundCache{K,V}, batch_keys::Vector{K}) where {K,V}
    local results
    try
        results = c.build(copy(batch_keys))::AbstractDict
    catch e
        bt = catch_backtrace()
        attempts = lock(c.lock) do
            ns = Dict{K,Int}()
            for k in batch_keys
                delete!(c.refreshing, k)
                n = get(c.failures, k, 0) + 1
                c.failures[k] = n
                c.not_before[k] = time_ns() + _backoff_ns(c, n)
                ns[k] = n
            end
            ns
        end
        # One record for the whole batch: a thrown call is a single failure
        # event, so every key shares one exception/backtrace. (Per-key records
        # stay for keys missing from, or mistyped in, a successful result.)
        @error "BackgroundCache batch refresh failed; keeping the previous values" batch_size = length(batch_keys) keys = batch_keys attempts = attempts exception = (e, bt)
        return nothing
    end
    for k in batch_keys
        try
            _settle_swr_key!(c, k, results[k]::V)
        catch e
            bt = catch_backtrace()
            n = lock(c.lock) do
                delete!(c.refreshing, k)
                nn = get(c.failures, k, 0) + 1
                c.failures[k] = nn
                c.not_before[k] = time_ns() + _backoff_ns(c, nn)
                nn
            end
            @error "BackgroundCache batch refresh failed; keeping the previous value" key = k attempt = n exception = (e, bt)
        end
    end
    nothing
end

function Base.getindex(c::BackgroundCache{K,V}, key::K) where {K,V}
    outcome = lock(c.lock) do
        # Sampled under the lock: a timestamp taken before the lock can
        # predate a stamp published under it, and the staleness subtraction
        # below would underflow (UInt64) into a spurious stale plus a
        # phantom kick.
        now = time_ns()
        v = get(c.values, key, _missing_sentinel)
        if v === _missing_sentinel
            # The backoff gate applies before the first build too: without it a
            # failing build would re-kick on every read instead of backing off.
            if key in c.refreshing || now < get(c.not_before, key, UInt64(0))
                return (:settled, c.unbuilt)
            end
            push!(c.refreshing, key)
            c.batched && return (_enqueue_swr_batch!(c, key), c.unbuilt)
            return (:kick, c.unbuilt)
        end
        # A missing stamp (impossible by construction — stamps track values at
        # every writer) reads as infinitely old rather than throwing: the read
        # path stays total and the refresh re-settles the key. A stamp newer
        # than `now` reads as just-settled, never stale: with `now` sampled
        # under this same lock that ordering only arises via clock weirdness,
        # and the subtraction would underflow into a phantom kick.
        if haskey(c.stamps, key)
            stamp = c.stamps[key]
            (stamp > now || now - stamp < c.ttl_ns) && return (:settled, v)
        end
        if key in c.refreshing || now < get(c.not_before, key, UInt64(0))
            return (:settled, v)
        end
        push!(c.refreshing, key)
        c.batched && return (_enqueue_swr_batch!(c, key), v)
        (:kick, v)
    end
    outcome[1] === :kick && _kick_swr_refresh!(c, key)
    outcome[1] === :batch_kick && _kick_swr_batch_drain!(c)
    outcome[2]
end

"""
    invalidate!(c::BackgroundCache, key)

Drop the settled value (and any failure/backoff record) for `key`; the next
read serves the cache's `unbuilt` value and kicks a fresh background build. A
refresh already in flight is not stopped — its value still lands.
"""
function invalidate!(c::BackgroundCache{K,V}, key::K) where {K,V}
    lock(c.lock) do
        _drop_swr_key!(c, key)
    end
    nothing
end

"""
    fetchindex(callback, ip, indices...; force=false, retry_failed=force, kwargs...)

Request an indexed property without blocking. The callback receives
`(result, status)`: `result` is a [`Pending`](@ref) handle while work is in flight,
or the completed value; `status` is its progress node or `nothing`.
Calling `fetch` on the handle blocks and rethrows a computation failure.

`force=true` first calls [`invalidate!`](@ref) for the requested entry, removing
its memory and disk value. See that function for in-flight behavior.
"""
function fetchindex(fetch, ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}, indices...;
                    force=false, retry_failed=force, kwargs...)
    if force
        invalidate!(ip, indices...; kwargs...)
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

When `callback` is a `Treebars.ProgressNode`, the call blocks for the value. It
computes inline on the caller's task, as a plain call does, and attaches the
computation's node under `callback`, where it stays once finished; a documented
cache hit attaches the entry's node noted "(cached)". With `fetch=identity`
it polls instead and returns a [`Pending`](@ref) while the computation runs.
[`fetchproperty!`](@ref) with a progress node is the blocking form for a bare
property; `@fetch!` and `@progress` thread their reads through both.
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
    if c isa MountedThreadsafeDict && (c.probe !== nothing || name in c.opaque)
        return _mounted_fetchproperty(fetch, c, o, name)
    end
    substatus_f = _bare_substatus_f(o, name)
    rv = get!(_bare_compute(o, name), c, name; substatus=substatus_f, fetch=identity)
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
# node `s` and its ENTIRE sub-step subtree intact, and set ONLY the subtree
# ROOT's note to `progress_notes(:cached)` in place — so it renders e.g.
# "Compute subject data — (cached)" (carrying `s`'s own frozen ORIGINAL-compute
# duration) with all of `s`'s sub-steps rendering beneath it, unchanged. The note
# replaces a disk load's "from disk: …".
#
# In-place marking (vs. a new born-finished root with the children re-homed) is
# the correct mechanism here: `s` is SHARED per cache key (`getstatus` returns
# the same node to every status tree / poll). Re-homing `s`'s children into a new
# node would EMPTY `s.children`, so a second status tree hitting the same shared
# `s` would build a CHILDLESS "(cached)" node — exactly the collapsed-subtree bug
# this corrects. Marking `s` itself keeps the one shared subtree intact for all
# trees, preserves children's (immutable) parent pointers, and mirrors
# `_report_disk_load!` above, which already mutates the shared `s`'s display state
# in place. Because `s` is shared and a hit can come from a background task, the
# note is a `TreebarNote`, rendered in each viewer's page language.
#
# UNDOCUMENTED hit (`s.impl.description` empty): no note — `s` stays a bare
# wrapper the renderer inlines away. Running (`rv isa Pending`) and no-substatus
# (`s === nothing`): no note. All four paths then attach `s` via `add_child!`
# (idempotent on the `ThreadsafeSet`; no-op on `nothing`).
function _attach_fetched!(status::Treebars.ProgressNode, rv, s)
    if !(rv isa Pending) && !isnothing(s) && !isempty(s.impl.description)
        _mark_cached!(s)                   # documented in-memory hit → note the root in place
    end
    Treebars.add_child!(status, s)         # keep/attach the subtree root (no-op on `nothing`)
    nothing
end

# Set `s`'s note to the cached marker. Repeat polls (web routes poll the tree repeatedly and
# re-fetch the same shared `s`) set the same note again. `s` is finished/frozen on a hit,
# so the visible duration stays the frozen original-compute time.
_mark_cached!(s::Treebars.ProgressNode) = (Treebars.update_progress!(s, progress_notes(:cached)); nothing)

fetchindex!(status::Treebars.ProgressNode, ip, indices...; fetch=Base.fetch, kwargs...) =
    fetchindex(ip, indices...; kwargs...) do rv, s
        _attach_fetched!(status, rv, s)
        fetch(rv)
    end
# A blocking read computes inline, on the reader's task, as a plain read does: a
# computation run on a spawned task while the reader waits for it would deadlock on any
# lock the reader holds (todo `1o2uih6`). A poll (`fetch=identity`) still starts it in the
# background and returns a `Pending`.
function fetchindex!(status::Treebars.ProgressNode, ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict},
                     indices...; fetch=Base.fetch, force=false, retry_failed=force, kwargs...)
    _is_blocking(fetch) || return invoke(fetchindex!, Tuple{Treebars.ProgressNode,Any,Vararg{Any}},
                                         status, ip, indices...; fetch, force, retry_failed, kwargs...)
    force && invalidate!(ip, indices...; kwargs...)
    _memoize_linked!(_Attached(status), ip, indices...; fetch, retry_failed, kwargs...)
end

fetchproperty!(status::Treebars.ProgressNode, o, name::Symbol) =
    _is_dynamic_object(o) ? _getorcompute_linked(o, name, _Attached(status)) : getproperty(o, name)

maybepop!(c::AbstractDict, key) = haskey(c, key) && pop!(c, key)
maybepop!(c::AbstractThreadsafeDict, key) = begin
    lock(c.lock) do
        maybepop!(c.cache, key)
        _retract!(c.computing, key)
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
    name in mounted.opaque &&
        return _OpaqueSubcache(mounted.namespace, name, owner, _ns_subcache(mounted.namespace, name), ThreadsafeDict())
    # A nested child's key is resolved on first access: by `_inline_child` on the
    # source, or by the view's own constructor call (`_adopt_source_child`).
    name in mounted.invalidated && return ThreadsafeDict()
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
file path is resolved lazily via a callable `path` so the constructor
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

const _Entry = NamedTuple{(:key, :state, :status, :value), Tuple{Any, Symbol, Any, Any}}

"""
    entries(ip::IndexableProperty)

Return a vector of `(; key, state, status, value)` for all entries in a
`ThreadsafeDict`-backed `IndexableProperty`. `state` is one of `:running`,
`:failed`, or `:done`. `value` is the cached result (for `:done`), a `Pending`
handle (for `:running`), or the captured exception (for `:failed`). `status` is
the substatus object or `nothing`.
"""
entries(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}) =
    _Entry[(; key=_plain_key(e.key), e.state, e.status, e.value) for e in _raw_entries(ip)]
# The entries keyed as the subcache stores them (`_MemoKey`s).
function _raw_entries(ip::IndexableProperty{N,<:Any,<:AbstractThreadsafeDict}) where {N}
    result = _Entry[]
    c = ip.cache
    executor = property_executor(ip.o, Val(N))
    lock(c.lock) do
        for (k, v) in c.cache
            push!(result, (; key=k, state=:done, status=nothing, value=v))
        end
        for (k, _cnd) in c.computing
            haskey(c.cache, k) && continue
            push!(result, (; key=k, state=:running, status=get(c.status, k, nothing), value=Pending(c, k, nothing, executor)))
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

Return a vector of `(key, value)` pairs for completed entries only.
"""
function cached_entries(ip::IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict})
    lock(ip.cache.lock) do
        Pair{Any,Any}[_plain_key(k) => v for (k, v) in ip.cache.cache]
    end
end
function cached_entries(ip::IndexableProperty)
    Pair{Any,Any}[_plain_key(k) => v for (k, v) in ip.cache]
end

# --- cache clearing ---

"""
    clear_mem_caches!(object)

Remove derived in-memory values while keeping disk files, constructor inputs,
and settled or in-flight `@state` values. A later read recomputes a derived value
or reloads its disk entry. Constructor overrides and mounted request context
are restored, so clearing does not change the object's inputs.

Indexed wrappers remain attached and their subcaches are emptied in place.
Held handles and remount views therefore observe subsequent computations and
clears. Derived child objects are dropped and recreated on demand.

Dropping derived values advances the object's version. Holders invalidate what
they derived from it on their next [`sync!`](@ref). To free memory without that
invalidation, use [`prune_mem_caches!`](@ref).

In-flight computations that were retracted cannot publish a value; their
original callers may still receive it and waiters resolve against the current
entry. The progress root is also dropped unless supplied as a constructor input.
Inside a computation, prefer a narrower property clear or `sync!`.
"""
function clear_mem_caches!(obj)
    forward = _invalidation_address(obj)   # while `obj`'s parent still holds it
    pc = getfield(obj, :cache)
    c = pc.cache
    state = _state_names(typeof(obj))
    held = _trace_scope() === nothing ? nothing : _trace_held(c, state)
    # The object's indexed-property wrappers are kept, their subcaches emptied in place,
    # as `clear_cache!`/`sync!` do: a per-argument subcache outlives the
    # top-level entry through every alias — a mounted request view shares it by
    # design, a destructured handle holds it, and so does a waiter or `Pending`
    # of a computation the clear retracts — so a wrapper dropped here would
    # leave those holders on a detached subcache that later reads and clears
    # never reach. `@state` values (an indexed one's subcache too) are kept
    # untouched. So is a `@state` computation in flight: its initializer reads
    # no derived value, so nothing it computes is stale, and its caller already
    # holds the object it is about to store (a retracted computation would store
    # nothing, `_run_cache_compute!`). Everything kept is put back within the
    # same critical section, so no reader finds it missing, and each subcache
    # is then emptied under its own lock.
    inputs = _seed_names(pc)
    dropped, subcaches = lock(c.lock) do
        parts = _clear_parts(c)
        kept = [(cache, name, value) for (cache, _, _) in parts for (name, value) in cache
                if !(value isa Pending) && (name in state || _own_wrapper(obj, name, value))]
        running = [(status, computing, name, computing[name], get(status, name, nothing))
                   for (_, status, computing) in parts for name in state if haskey(computing, name)]
        subcaches = [(name, value.cache) for (cache, _, _) in parts for (name, value) in cache
                     if value isa IndexableProperty && !(name in state)]
        # What a holder may have derived from: the values dropped here, except the
        # inputs `_restore_seeds!` puts back and DO's own `__…__` entries.
        dropped = Symbol[name for (cache, _, _) in parts for (name, value) in cache
                         if !(value isa Pending || name in state || name in inputs ||
                              _own_wrapper(obj, name, value) || _is_dunder(name))]
        empty!(c)
        for (cache, name, value) in kept
            cache[name] = value
        end
        for (status, computing, name, latch, node) in running
            computing[name] = latch
            node === nothing || (status[name] = node)
        end
        dropped, subcaches
    end
    for (name, subcache) in subcaches
        _holds_entries(subcache) && !_is_dunder(name) && push!(dropped, name)
        empty!(subcache)
    end
    _restore_seeds!(pc)
    isempty(dropped) || _object_cleared!(obj, unique!(dropped))
    held === nothing || _trace_invalidation!(:clear_mem_caches!, obj, _trace_cleared(held, c, state))
    _forward_invalidation(forward, :clear_mem_caches!)
    nothing
end

# What a whole-object clear finds, for a compute trace: the names holding a value, and the
# indexed ones whose wrapper holds entries (a clear empties those, except `@state` ones).
function _trace_held(c, state)
    entries = lock(c.lock) do
        [(name, value) for (cache, _, _) in _clear_parts(c) for (name, value) in cache]
    end
    (Set{Symbol}(first(e) for e in entries),
     Symbol[name for (name, value) in entries
            if value isa IndexableProperty && !(name in state) && length(value.cache) > 0])
end
# The names a clear dropped: gone afterwards (seeds come back), or emptied wrappers.
_trace_cleared((names, filled), c, state) = union(setdiff(names, first(_trace_held(c, state))), filled)

# The raw `(values, status, computing)` dictionaries a whole-object clear
# empties: a remount view's own and those of its retained object, including
# entries the view's routing masks (`empty!` of a view clears both).
_clear_parts(c::ThreadsafeDict) = ((c.cache, c.status, c.computing),)
_clear_parts(c::MountedThreadsafeDict) = ((c.shared.cache, c.shared.status, c.shared.computing),
    (c.cache.overlay, c.status.overlay, c.computing.overlay))

# Whether `value`, cached under `name`, is the wrapper of `obj`'s own indexed property
# `name` — not a value that a bare property computed, which a clear drops.
_own_wrapper(obj, name::Symbol, value) =
    value isa IndexableProperty{name} && is_indexed_property(obj, name)

# The constructor inputs a whole-object clear puts back (`_restore_seeds!`): for a
# remount view, its request context and its retained object's own inputs.
_seed_names(pc::PropertyCache) = pc.cache isa MountedThreadsafeDict ?
    union(keys(pc.seed), keys(getfield(pc.cache.source, :cache).seed)) : keys(pc.seed)

# Whether an indexed-property subcache holds a settled entry, as `_drop_property!` counts one.
_holds_entries(subcache) = lock(() -> !isempty(subcache.cache), subcache.lock)

# Names of `T`'s `@state` properties: per-instance state that whole-object
# clears keep and `sync!` never drops. `@dynamicstruct` emits a method for each
# type that declares one.
_state_names(::Type) = ()

# Markers whose meaning contradicts state kept in memory for the instance's life.
const _STATE_CONFLICTING_MARKERS = (
    Symbol("@cached"), Symbol("@mmap"), Symbol("@fresh"), Symbol("@versioned"), Symbol("@queued"),
)

# Internal unconditional store into a cache dict, for seed restoration and
# `remake` carry-over writes. The public `setproperty!` stays refused; these
# are DO's own instance-input writes. A `ThreadsafeDict` has no `setindex!`
# (stores normally publish through the `get!` machinery), so write the backing
# dict under the lock directly.
_seed_store!(c::ThreadsafeDict, key::Symbol, value) = lock(c.lock) do
    c.cache[key] = value
end
_seed_store!(c::AbstractDict, key::Symbol, value) = setindex!(c, value, key)

# Restore the creation inputs (`PropertyCache.seed`) after `empty!` dropped
# everything. For a remounted view the seed is the request context, which
# routes back into the view-local overlay via the mounted `setindex!` (always
# a local shadow); the retained object's own inputs are restored into the
# shared cache alongside, since `empty!` on a view clears both.
function _restore_seeds!(pc::PropertyCache)
    c = pc.cache
    if c isa MountedThreadsafeDict
        for (key, value) in pairs(pc.seed)
            c[key] = value
        end
        for (key, value) in pairs(getfield(c.source, :cache).seed)
            _seed_store!(c.shared, key, value)
        end
    else
        for (key, value) in pairs(pc.seed)
            _seed_store!(c, key, value)
        end
    end
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
    removed = Symbol[]
    isdir(cp) && for (name, info) in m
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
                push!(removed, name)
            end
        end
    end
    _trace_invalidation!(:clear_disk_caches!, obj, removed)
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
    key_tracker(object, ::Val{property}) -> KeyTracker

Select the strategy for explicitly recorded disk-cache keys. The default is
[`SharedFileTracker`](@ref) at the property's `_keys.sjl` path. Override this
method for an object type and property to return [`NoKeyTracker`](@ref) or a
custom tracker. Automatic property access does not currently record keys;
[`record!`](@ref) remains available for explicit recording.
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

# Publish a computed disk entry unless an invalidation retracted the computation (`guard`):
# not before the save, and if one lands during it, the entry is removed again — invalidations
# retract the latch before removing disk entries, so either side sees the other. Returns
# whether the entry stands; if not, the caller keeps the computed value itself.
function _save_if_publishable!(guard, fmt::Val, path::AbstractString, value)
    if !_publishable(guard)
        # The non-strict flow's empty placeholder would read as an interrupted write.
        get_cache_status(path) === :started && rm(path; force=true)
        return false
    end
    _atomic_save(fmt, path, value)
    _publishable(guard) && return true
    rm(path; force=true)
    false
end

# Every computation of a property goes through here: memoized, fresh, or loaded from disk.
# Under an active compute trace it runs as a traced computation (`_traced_compute`); a
# publish guard on this task means a memoized computation.
_computeproperty(o, name, indices...; __status__=nothing, kwargs...) = begin
    scope = _trace_scope()
    (scope === nothing || !_traced_name(name)) &&
        return _computeproperty_body(o, name, indices...; __status__, kwargs...)
    _traced_compute(scope, o, name, indices, (;kwargs...), _publish_guard() !== nothing) do
        _computeproperty_body(o, name, indices...; __status__, kwargs...)
    end
end
_computeproperty_body(o, name, indices...; __status__=nothing, kwargs...) = begin
    vname = Val(name)
    guard = _publish_guard(; take=true)   # this computation's own, if memoized
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
                        _trace_disk!(o, name, true)
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
                        _trace_disk!(o, name, false)
                        rv = compute_property(o, vname, indices...; _status_kw..., _resume_kw(o, vname, rv)..., kwargs...)
                        if _save_if_publishable!(guard, _disk_format(o, vname), cache_path, rv) &&
                                _disk_format(o, vname) == Val(:mmap)
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
                    _trace_disk!(o, name, true)
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
                    _trace_disk!(o, name, false)
                    rv = compute_property(o, vname, indices...; _status_kw..., _resume_kw(o, vname, rv)..., kwargs...)
                    if _save_if_publishable!(guard, _disk_format(o, vname), cache_path, rv) &&
                            _disk_format(o, vname) == Val(:mmap)
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
function _peek_hit(c::AbstractThreadsafeDict, key)
    lock(c.lock)
    try
        value = get(c.cache, key, _missing_sentinel)
        value === _missing_sentinel || _on_hit!(c, key)
        return value
    finally
        unlock(c.lock)
    end
end
_peek_hit(c::AbstractDict, key) = get(c, key, _missing_sentinel)
_peek_hit(c::MountedThreadsafeDict, name::Symbol) =
    (_revalidate_alias!(c, name); invoke(_peek_hit, Tuple{AbstractThreadsafeDict,Symbol}, c, name))

Base.@constprop :aggressive getorcomputeproperty(o, name, indices...; kwargs...) = if hasfield(typeof(o), name)
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
    _getorcompute_bare(getfield(o, :cache), o, name)
end
function _getorcompute_bare(cache::PropertyCache, o, name::Symbol; link=nothing)
    # Fast hit path: a cached bare property returns WITHOUT building the
    # `substatus` factory or the `get!` do-block closure below — both allocate
    # on every access and were the dominant warm-access cost. Hit bookkeeping is
    # a no-op (`_on_hit!`), so returning the cached value
    # directly is behaviourally identical to routing through `get!`. Only misses
    # pay the closures.
    t0 = _trace_clock()
    hit = _peek_hit(cache, name)
    if hit !== _missing_sentinel
        # Reading an indexed property's wrapper is not a read of its value.
        t0 == 0 || _own_wrapper(o, name, hit) || _trace_read!(o, name, nothing, Val(:hit), t0)
        _link_hit!(link, getfield(cache, :cache), name, hit)
        return hit
    end
    substatus_f = _bare_substatus_f(o, name)
    # When called with no indices on an indexed property (declared with
    # call/ref syntax, e.g. `x() = ...` or `x[i] = ...`), return an
    # IndexableProperty wrapper instead of calling compute_property. The
    # wrapper is not a computed value: only its entries settle (`memoize!`).
    is_indexed_property(o, name) && return get!(cache, name; substatus=substatus_f) do s
        IndexableProperty(name, o, subcache(cache, o, Val(name)))
    end
    get!(_bare_compute(o, name), cache, name; substatus=substatus_f, link)
end
# The computation of bare property `name`, reported to `property_settled` when it stores.
# `s` is the substatus the spawn wrapper passed (or `nothing` when there is none). It is
# passed as `__status__` so the body — and any IP/property accesses inside — attach to it.
# On a remount view a nested child it builds may be the retained source's (`_adopt_source_child`).
_bare_compute(o, name::Symbol) = _Settling(o, name) do s
    _adopt_source_child(o, name, nothing, _computeproperty(o, name; __status__=s))
end
# A remount view first tries the shared namespace for an untainted opaque
# property; the guarded `__self__` of an opaque computation intercepts every
# read (`_probe_read`).
function _getorcompute_bare(cache::PropertyCache{<:MountedThreadsafeDict}, o, name::Symbol; link=nothing)
    c = cache.cache
    c.probe === nothing || return _probe_read(c, c.probe, o, name; link)
    name in c.opaque && !is_indexed_property(o, name) &&
        return _opaque_bare!(o, name, nothing; link)
    invoke(_getorcompute_bare, Tuple{PropertyCache,Any,Symbol}, cache, o, name; link)
end
_bare_substatus_f(o, name) =
    if name != :__substatus__ && name != :__status__ &&
       !(startswith(string(name), "__") && endswith(string(name), "__")) &&
       is_generated_property(o, name) && !is_indexed_property(o, name)
        () -> begin
            root = o.__status__
            compute_property(o, Val(:__substatus__), name; __status__=root, __pending__=true)
        end
    else
        nothing
    end

# --- Disk keys of `isequal` arguments ---------------------------------------------------
#
# A memo key matches arguments by `isequal`, so `f(-50)` and `f(-50.0)` share one memory
# entry. A disk key is built from how an argument prints or serializes, which differs for
# those two, so whichever spelling computed first was the only one persisted and a restart
# recomputed the other (snag `memo-key-isequal-1b4ae3b0`). The reverse held too: `0.1f0` and
# `0.1` are not `isequal`, print alike, and shared one file, so one served the other's value.
#
# `_disk_key(x)` is one representative of `x`'s `isequal` class: `isequal(a, b)` gives
# `_disk_key(a)` and `_disk_key(b)` the same key, and values that are not `isequal` never
# get one. It only names the disk entry; a body still receives the caller's argument.
#
# It returns an already canonical value unchanged, so that value's disk key does not move:
# `Int`, `String`, non-integer `Float64`, `Vector{Int}` and float vectors holding a
# non-integer keep their keys. That is why integers are the canonical spelling of an
# integer-valued float rather than the reverse, and why a float vector stays `Float64`
# unless every element is integer-valued.
#
# A type left to the fallback keeps its own serialization. Equal values of two such types
# then get two entries, which costs a recompute and never serves a wrong value:
# - `Bool` stays apart from numbers. `f(true)` keeps `f_true.sjl` rather than renaming every
#   flag's entry to `f_1.sjl` for a crossing callers have no reason to make.
# - Array wrappers other than ranges, bit arrays and views of an `Array` stay as they are:
#   making a sparse or lazy array dense here could cost quadratic memory. An array with
#   offset axes does too, because it is not `isequal` to its dense copy.
# - Only `Dict` and `Set` are sorted: another `AbstractDict`'s `isequal` may depend on order.
# - Types with their own cross-type `isequal` (`Day(1)`, `Hour(24)`) are not known here.
# - An argument holding one array twice (`[v, v]`) serializes with a back-reference, so it
#   keeps a different key from one holding two equal arrays.
_disk_key(x) = x
_disk_key(x::Bool) = x
_disk_key(x::Int) = x
_disk_key(x::Union{Base.BitInteger,BigInt,Base.IEEEFloat,BigFloat,Rational}) = begin
    _is_int_valued(x) && return Int(x)
    # Keeps NaN (every NaN is `isequal`), the infinities and -0.0 (not `isequal` to 0).
    float = Float64(x)
    isequal(float, x) && return float
    isinteger(x) ? BigInt(x) : Rational{BigInt}(x)
end
_is_int_valued(x) =
    isfinite(x) && isinteger(x) && !(iszero(x) && signbit(x)) && typemin(Int) <= x <= typemax(Int)
_disk_key(z::Complex) = begin
    re, ie = _disk_key(real(z)), _disk_key(imag(z))
    # `Complex(1.0, -0.0)` is `isequal` to neither 1.0 nor `Complex(1.0, 0.0)`.
    ie === 0 && return re
    re isa Int && ie isa Int && return Complex{Int}(re, ie)
    _is_exact_float(re) && _is_exact_float(ie) && return ComplexF64(re, ie)
    z
end
_is_exact_float(x::Union{Int,Float64}) = isequal(Float64(x), x)
_is_exact_float(_) = false
_disk_key(x::AbstractString) = String(x)
_disk_key(x::Tuple) = map(_disk_key, x)
_disk_key(x::NamedTuple) = map(_disk_key, x)
_disk_key(x::Pair) = _disk_key(x.first) => _disk_key(x.second)
# A range is a few fields however long it is, so collecting a huge one here could exhaust
# memory for a key that used to cost nothing. Past this length it keeps its own key.
const _RANGE_DISK_KEY_MAX = 2^24
_disk_key(x::AbstractRange) = length(x) > _RANGE_DISK_KEY_MAX ? x : _dense_disk_key(x)
_disk_key(x::BitArray) = _dense_disk_key(x)
_disk_key(x::SubArray{<:Any,<:Any,<:Array}) = _dense_disk_key(x)
_dense_disk_key(x) = Base.has_offset_axes(x) ? x : _disk_key(collect(x))
# An empty array is `isequal` to any other of its size, whatever its element type.
function _disk_key(x::Array{T,N}) where {T,N}
    isempty(x) && return Array{Int,N}(undef, size(x))
    (T === Int || T === Bool || T === String || T === Symbol) && return x
    T === Float64 && return all(_is_int_valued, x) ? Int.(x) : x
    elements = Any[_disk_key(element) for element in x]
    all(element -> element isa Int, elements) && return Array{Int,N}(elements)
    all(_is_exact_float, elements) && return Array{Float64,N}(elements)
    S = typeof(first(elements))
    all(element -> typeof(element) === S, elements) ? Array{S,N}(elements) : elements
end
# A `Dict` iterates in an order its insertion history decides, and `isequal` ignores order.
# Each entry's digest is computed once and then sorted on: a `by=` digest would serialize
# on every comparison.
struct _DictDiskKey
    pairs::Vector{Pair{Any,Any}}
end
struct _SetDiskKey
    elements::Vector{Any}
end
function _disk_key(x::Dict)
    entries = Vector{Pair{String,Pair{Any,Any}}}(undef, length(x))
    for (i, (k, v)) in enumerate(x)
        key = _disk_key(k)
        entries[i] = canonical_hash(key) => (key => _disk_key(v))
    end
    sort!(entries; by=first)
    _DictDiskKey(Pair{Any,Any}[last(entry) for entry in entries])
end
function _disk_key(x::Set)
    entries = Vector{Pair{String,Any}}(undef, length(x))
    for (i, element) in enumerate(x)
        key = _disk_key(element)
        entries[i] = canonical_hash(key) => key
    end
    sort!(entries; by=first)
    _SetDiskKey(Any[last(entry) for entry in entries])
end

maybehash(x::Number) = _disk_key(x)
maybehash(x::Symbol) = x
# Route through `canonical_hash` — the same digest the `__hash__` compute uses —
# so a `@dynamicstruct` argument hashes by its stable `__hash__` (per-type
# overloads emitted by the macro) instead of serializing the whole object
# including its PropertyCache. Without this the segment grew with whatever was
# memoized on the argument and changed across restarts, so a disk cache written
# with a cold argument never hit with a warm one. Plain values are unaffected:
# `_hash_replace` is the identity there (modulo rebuilding an equal
# Tuple/NamedTuple, which serializes identically).
maybehash(x) = canonical_hash(_disk_key(x))

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
# syntactic order land in the same segment. A keyword's value is canonicalized
# before its pair is built, so the pair keeps the type it always had when nothing
# moved. The joined result is passed through `_bound_segment` so a fat key cannot
# blow past the filesystem's NAME_MAX, after `_path_safe` so an argument printing
# a `/` (`1//3`, `Symbol("a/b")`) cannot turn the entry into a nested file that
# `clear_disk_caches!` never reaches, and on Windows cannot make an illegal name.
cache_segment(name, args...; kwargs...) = begin
    parts = map(maybehash, (name, args...))
    keyword_parts = length(kwargs) == 0 ? () :
        map(canonical_hash, Tuple(sort(collect(pairs(map(_disk_key, NamedTuple(kwargs)))); by=first)))
    _bound_segment(_path_safe(join((parts..., keyword_parts...), "_")))
end
_path_safe(seg::AbstractString) = begin
    flat = occursin('/', seg) ? replace(seg, "//" => "over", "/" => "over") : seg
    Sys.iswindows() ? _windows_file_name(flat) : flat
end
# Windows refuses these in a file name, so a property with such an argument computed and
# then failed to save (`*` from `1//3 + 1//7*im`), and it reads `:` as a stream of the file
# before it. They are percent-encoded rather than replaced by one character, so two
# different arguments keep two names. Only on Windows, so keys elsewhere do not move.
_is_windows_reserved(c::Char) = c in ('\\', ':', '*', '?', '"', '<', '>', '|') || c < ' '
_windows_file_name(seg::AbstractString) = any(_is_windows_reserved, seg) ?
    join(_is_windows_reserved(c) ? "%" * uppercase(string(UInt32(c); base=16, pad=2)) : c for c in seg) : seg
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
    @cache_status object.property
    @cache_status object.property(arguments...)

Report the disk entry's state: `:unstarted`, `:started`, or `:ready`.
Use a call expression for one indexed entry and a dot expression for a scalar.
This inspects disk state, not the in-memory memo table. Inside a
`@dynamicstruct` body the object prefix may be omitted.
"""
macro cache_status(x)
    cache_f_expr(x; f=get_cache_status) |> esc
end

"""
    @is_cached object.property
    @is_cached object.property(arguments...)

Return whether the selected disk entry is ready, equivalent to comparing
[`@cache_status`](@ref) with `:ready`. This is not a test for an in-memory hit.
Inside a `@dynamicstruct` body the object prefix may be omitted.
"""
macro is_cached(x)
    :($(cache_f_expr(x; f=get_cache_status)) == :ready) |> esc
end

"""
    @cache_path object.property
    @cache_path object.property(arguments...)

Return the selected property's disk-cache path without computing its value.
An indexed call selects one argument tuple. The path depends on the object's
identity and version. Inside a `@dynamicstruct` body the object prefix may be
omitted.
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
    @memo! expression

Rewrite calls in `expression` through [`maybememoize!`](@ref): indexed
properties use their memoized path and other callables keep ordinary call
behavior. This is redundant for ordinary indexed calls, which already memoize.
Quoted code is left unchanged. Use [`@fresh`](@ref) to bypass the selected cache.
"""
macro memo!(x)
    esc(_call_rewrite(x, :maybememoize!))
end

"""
    @fresh expression

Rewrite calls in `expression` through [`maybefresh`](@ref). An indexed property
computes without reading or writing its cache; other callables are called
normally. Quoted code is left unchanged. This does not recursively bypass the
caches of dependencies read inside the selected property's body.

A declaration marked `@fresh` uses uncached access on every call. The function
form [`fresh`](@ref) selects one indexed property explicitly.
"""
macro fresh(x)
    esc(_call_rewrite(x, :maybefresh))
end

# Quoted code is data for whoever evaluates it later, not an evaluation of this body,
# so no body rewriter touches it: a name inside `:(…)` / `quote … end` stays the symbol
# it is. Only an interpolation the quote evaluates when it is built is code of the body,
# and `f` maps that code. Levels count as in Julia's own quasi-quote: each nested quote
# takes one more `$` to reach the enclosing code, so the `$x` of `:(:($x))` is data here
# and the `$($x)` of `:(:($($x)))` is code.
_map_interpolations(f, x, level::Int=0) = x
function _map_interpolations(f, x::Expr, level::Int=0)
    Meta.isexpr(x, :$) && return Expr(:$,
        Any[level == 1 ? f(a) : _map_interpolations(f, a, level - 1) for a in x.args]...)
    Expr(x.head, Any[_map_interpolations(f, a, level + Meta.isexpr(x, :quote)) for a in x.args]...)
end
# What of `x`'s subexpressions the body evaluates, for scanners that only read.
_evaluated_args(x::Expr) = Meta.isexpr(x, :quote) ? _interpolations(x) : x.args
function _interpolations(x::Expr)
    code = Any[]
    _map_interpolations(a -> push!(code, a), x)
    code
end

# Recursively rewrite every call site to `\$target(...)` (`maybememoize!` for
# `@memo!`, `maybefresh` for `@fresh`). Plain property accesses (`.foo`,
# `.bar.baz`) are left untouched — only `:call` heads are transformed. The
# `target` helper's dispatch decides at runtime whether to act on an IP or just
# call (everything else).
_call_rewrite(x, target::Symbol) = x
function _call_rewrite(x::Expr, target::Symbol)
    Meta.isexpr(x, :quote) && return _map_interpolations(a -> _call_rewrite(a, target), x)
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
`f(args...; kwargs...)`; the specialization for `IndexableProperty` preserves
the property's declaration-site cache policy while attaching progress:
ordinary properties route through [`fetchindex!`](@ref) (memoized + progress),
while `@fresh` properties route through [`maybeprogress!`](@ref) (fresh +
progress, with no cache read or write).
"""
maybefetchindex!(progress, f, args...; kwargs...) = f(args...; kwargs...)
maybefetchindex!(progress, p::IndexableProperty{name}, args...; kwargs...) where {name} =
    _never_cache(p.o, Val(name)) ? maybeprogress!(progress, p, args...; kwargs...) :
                                   fetchindex!(progress, p, args...; kwargs...)

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

# ── Implied progress (decision `0yvb74c`) ──────────────────────────────────────
#
# An unmarked property body is rewritten (`_implied_progress_rewrite`) so that every
# property read written in it — `obj.name`, `obj.ip(args…)`, and a bare sibling, which
# `walk_rhs` has made `__self__.name` — passes along the body's progress node
# (`__progress__`). The read is the ordinary read: it computes inline, a cache hit costs
# what it did, and nothing is spawned. When it computes or waits for a computation, that
# computation's node also shows under `progress` meanwhile (`get!`'s `link`); it keeps its
# place in its owner's tree.
#
# One method each, branching inside, so a call resolves statically even when `progress`
# or the receiver is untyped: a field read in a loop stays a field read.
@inline function _read_threaded(progress, o, ::Val{name}) where {name}
    progress isa Treebars.ProgressNode && _is_dynamic_object(o) || return getproperty(o, name)
    _getorcompute_linked(o, name, progress)
end

@inline function _call_threaded(progress, f, args...; kwargs...)
    f isa IndexableProperty && progress isa Treebars.ProgressNode || return f(args...; kwargs...)
    _call_threaded_ip(progress, f, args...; kwargs...)
end
# What the call form `ip(args…)` does, with the computation shown under `progress`: a
# memoized call links it while it computes or waits; a `@fresh` property's call gets its
# own node under `progress`, as under `@fetch!`.
_call_threaded_ip(progress, ip::IndexableProperty{name}, args...; kwargs...) where {name} =
    _never_cache(ip.o, Val(name)) ? maybeprogress!(progress, ip, args...; kwargs...) :
                                    _memoize_linked!(progress, ip, args...; kwargs...)

# `getorcomputeproperty(o, name)` (what the generated `getproperty` calls) for a bare
# name, its computation shown under `link`.
_getorcompute_linked(o, name::Symbol, link) =
    hasfield(typeof(o), name) ? getfield(o, name) :
                                _getorcompute_bare(getfield(o, :cache), o, name; link)

# Call-site `@memo!` / `@fresh` inside a rewritten body expand after the rewrite, so they
# see `_call_threaded(progress, callee, args…)`. Keep their meaning.
maybememoize!(::typeof(_call_threaded), progress, ip::IndexableProperty, args...; kwargs...) =
    progress isa Treebars.ProgressNode ? _memoize_linked!(progress, ip, args...; kwargs...) :
                                         memoize!(ip, args...; kwargs...)
maybememoize!(::typeof(_call_threaded), progress, f, args...; kwargs...) =
    _call_threaded(progress, f, args...; kwargs...)
maybefresh(::typeof(_call_threaded), progress, ip::IndexableProperty, args...; kwargs...) =
    maybeprogress!(progress, ip, args...; kwargs...)
maybefresh(::typeof(_call_threaded), progress, f, args...; kwargs...) =
    _call_threaded(progress, f, args...; kwargs...)

"""
    @fetch! progress expression

Thread property reads in `expression` through the progress-aware fetch helpers.
Indexed reads use [`fetchindex!`](@ref), scalar reads use [`fetchproperty!`](@ref),
and declaration-marked fresh properties retain their uncached policy through
[`maybeprogress!`](@ref). Non-property functions keep their ordinary call behavior.

With a Treebars progress node these reads block and attach the computation's
node beneath it. With `nothing` they use the ordinary access path. Property
bodies already attach their source-visible reads automatically.
"""
macro fetch!(progress_var, x)
    esc(_fetch_rewrite(progress_var, x))
end

_fetch_rewrite(pv::Symbol, x) = x
function _fetch_rewrite(pv::Symbol, x::Expr)
    Meta.isexpr(x, :quote) && return _map_interpolations(a -> _fetch_rewrite(pv, a), x)
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
    # destructure off-DO and only adds threading on a DO source. The shape per
    # position (statement, `local`, `let`, `for`, comprehension) is
    # `_destructure_rewrite`'s.
    rewritten = _destructure_rewrite(x, a -> _fetch_rewrite(pv, a),
        (src, nm) -> Expr(:call, GlobalRef(@__MODULE__, :maybefetchproperty!), pv, src, QuoteNode(nm)))
    rewritten === nothing || return rewritten
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

# Named destructuring `(; a, b::T) = src` reads properties during lowering, so the
# body rewriters (`_fetch_rewrite`, `_implied_progress_rewrite`) make each read
# explicit as `read(s, name)`, with `rw` rewriting the source. Only a statement can
# become a block, so the destructure's position picks the shape:
#
#   (; a, b) = src            begin s = src; a = read(s, :a); b = read(s, :b); s end
#   local (; a, b) = src      begin local a, b; <the statement form> end   (and `global`)
#   let (; a, b) = src        let (a, b) = (s -> (read(s, :a), read(s, :b)))(src)
#   for (; a, b) in itr       for (a, b) in Generator(s -> (read(s, :a), read(s, :b)), itr)
#   [… for (; a, b) in itr]   the same per element; a filter keeps reading `a`, `b`
#
# Each keeps the plain destructure's scope, read order and value: the source is
# evaluated once, and the statement form returns it. `expand(src)` says whether a
# destructure of that source is rewritten at all. Another element shape (kw-default,
# splat, nested) or source keeps its target as written and only its source is
# rewritten. Returns `nothing` when `x` is none of these forms.
function _destructure_rewrite(x::Expr, rw, read, expand=Returns(true))
    binds = _named_destructure_binds(x, expand)
    binds === nothing || return _destructure_statement(binds, rw(x.args[2]), read)
    if Meta.isexpr(x, (:local, :global))
        any(a -> _named_destructure_binds(a, expand) !== nothing, x.args) || return nothing
        return Expr(:block, Any[_destructure_declaration(x.head, a, rw, read, expand) for a in x.args]...)
    elseif Meta.isexpr(x, :let) && length(x.args) == 2
        return Expr(:let, _destructure_header(x.args[1], rw, read, expand, _bind_reads), rw(x.args[2]))
    elseif Meta.isexpr(x, :for) && length(x.args) == 2
        return Expr(:for, _destructure_header(x.args[1], rw, read, expand, _iterate_reads), rw(x.args[2]))
    elseif Meta.isexpr(x, :generator)
        return Expr(:generator, rw(x.args[1]),
            Any[_destructure_header(a, rw, read, expand, _iterate_reads) for a in x.args[2:end]]...)
    end
    nothing
end
_bind_reads(reads, value) = Expr(:call, reads, value)
_iterate_reads(reads, itr) = Expr(:call, GlobalRef(Base, :Generator), reads, itr)
_named_destructure_binds(x, expand) = nothing
function _named_destructure_binds(x::Expr, expand)
    Meta.isexpr(x, :(=)) && Meta.isexpr(x.args[1], :tuple) && length(x.args[1].args) == 1 &&
        Meta.isexpr(x.args[1].args[1], :parameters) && expand(x.args[2]) || return nothing
    _fetch_destructure_binds(x.args[1].args[1])
end
function _destructure_statement(binds, src_value, read)
    src = gensym(:destructure_src)
    block = Expr(:block, :($src = $src_value))
    for (lhs, nm) in binds
        push!(block.args, :($lhs = $(read(src, nm))))
    end
    push!(block.args, src)
    block
end
# One argument of `local` / `global`: the names are declared before the statement form.
function _destructure_declaration(head, arg, rw, read, expand)
    binds = _named_destructure_binds(arg, expand)
    binds === nothing && return Expr(head, rw(arg))
    Expr(:block, Expr(head, Any[nm for (_, nm) in binds]...), _destructure_statement(binds, rw(arg.args[2]), read))
end
# A binding of a `let`, `for` or comprehension header: the target is a declaration,
# only the value is rewritten. A named destructure binds the tuple of its reads,
# which `wrap(reads, value)` applies to the bound value or to each iterated element.
_destructure_header(x, rw, read, expand, wrap) = x
function _destructure_header(x::Expr, rw, read, expand, wrap)
    header(a) = _destructure_header(a, rw, read, expand, wrap)
    Meta.isexpr(x, :block) && return Expr(:block, Any[header(a) for a in x.args]...)
    Meta.isexpr(x, :filter) && return Expr(:filter, rw(x.args[1]), Any[header(a) for a in x.args[2:end]]...)
    Meta.isexpr(x, :(=)) && length(x.args) == 2 || return x
    binds = _named_destructure_binds(x, expand)
    binds === nothing && return Expr(:(=), x.args[1], rw(x.args[2]))
    s = gensym(:destructure_src)
    reads = Expr(:(->), s, Expr(:tuple, Any[read(s, nm) for (_, nm) in binds]...))
    Expr(:(=), Expr(:tuple, Any[lhs for (lhs, _) in binds]...), wrap(reads, rw(x.args[2])))
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
    Meta.isexpr(x, :quote) && return _map_interpolations(_progress_self_rewrite, x)
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

# ── Implied progress: the unmarked-body rewrite (decision `0yvb74c`) ──────────
#
# Every property read written in an unmarked body nests under the body's progress
# node. After `walk_rhs` (bare siblings are already `__self__.name`):
#
#   obj.name         -> _read_threaded(__progress__, obj, Val(:name))
#   obj.ip(args...)  -> _call_threaded(__progress__, obj.ip, args...)
#
# Any receiver, not only `__self__`: another object's property (`model.fit()`)
# nests too. Ordinary calls (`sum`, arithmetic, helpers, constructors) stay calls,
# with only their arguments walked; a read inside a helper is the helper's own
# business. Syntax that is not an evaluation is left alone: assignment and local
# function targets, quoted code (bar its interpolations), type positions. Keyword
# shorthand, `do` blocks, broadcast calls and named destructuring keep their meaning.
# Ported from the
# isolated lane `kb-impl/DynamicObjects-snag.semantic-app-req-fafc83a2`
# (`3b2f9e7`..`1203b44c`), which emitted the spawning `maybefetch*` helpers.
# `self=false` (an `@progress` body, whose marker already threads `__self__` reads
# through `_progress_self_rewrite`) leaves `__self__`-rooted reads as written and
# rewrites only reads on other objects.
_implied_progress_rewrite(pv::Symbol, x, self::Bool=true) = x
function _implied_progress_rewrite(pv::Symbol, x::Expr, self::Bool=true)
    rw(a) = _implied_progress_rewrite(pv, a, self)
    threads(access) = _is_property_access(access) && (self || access.args[1] !== :__self__)
    Meta.isexpr(x, :quote) && return _map_interpolations(rw, x)
    Meta.isexpr(x, (:inert, :curly, :where, :meta)) && return x
    if Meta.isexpr(x, :(::))
        return length(x.args) == 2 ? Expr(:(::), rw(x.args[1]), x.args[2]) : x
    end

    # A macro's arguments are only walked when it evaluates them as ordinary code;
    # anything else may read its arguments as syntax (`@.` would broadcast the
    # inserted helper call, `@ccall` parses a signature), so it is left as written.
    if Meta.isexpr(x, :macrocall)
        (length(x.args) <= 2 || !_implied_progress_macro(x.args[1])) && return x
        return Expr(:macrocall, x.args[1], x.args[2], Any[rw(a) for a in x.args[3:end]]...)
    end

    # Local function and lambda signatures are declarations: rewrite the body only.
    if Meta.isexpr(x, (:function, :(->))) && length(x.args) == 2
        return Expr(x.head, x.args[1], rw(x.args[2]))
    end

    # Named destructuring reads properties during lowering. Evaluate the source once
    # and make each read explicit, in statements, declarations and binding headers.
    rewritten = _destructure_rewrite(x, rw, (src, nm) -> _read_threaded_expr(pv, src, nm),
        src -> self || src !== :__self__)
    rewritten === nothing || return rewritten

    # Never rewrite an assignment target (including short-form method signatures and
    # dotted or compound assignment); the right-hand side is an evaluation.
    if length(x.args) >= 2 && _is_assignment_head(x.head)
        return Expr(x.head, x.args[1], Any[rw(a) for a in x.args[2:end]]...)
    end

    # `obj.f(args...) do … end`: the lambda is the first argument after the callee.
    if Meta.isexpr(x, :do) && length(x.args) == 2 && Meta.isexpr(x.args[1], :call)
        call = x.args[1]
        lambda = rw(x.args[2])
        if !isempty(call.args) && threads(call.args[1])
            rest = Any[rw(a) for a in call.args[2:end]]
            return fixcall(Expr(:call, GlobalRef(@__MODULE__, :_call_threaded),
                pv, _implied_progress_callee(pv, call.args[1], self), lambda, rest...))
        end
        callee = _is_property_access(call.args[1]) ? call.args[1] : rw(call.args[1])
        return Expr(:do, fixcall(Expr(:call, callee, Any[rw(a) for a in call.args[2:end]]...)), lambda)
    end

    # Broadcast `obj.f.(args...)`: the progress node and the callee are scalars (a
    # `ProgressNode` is iterable); a `:parameters` block stays first in the tuple.
    if Meta.isexpr(x, :.) && length(x.args) == 2 && Meta.isexpr(x.args[2], :tuple)
        callee = x.args[1]
        args = Any[rw(a) for a in x.args[2].args]
        if threads(callee)
            params = Any[a for a in args if Meta.isexpr(a, :parameters)]
            positional = Any[a for a in args if !Meta.isexpr(a, :parameters)]
            return Expr(:., GlobalRef(@__MODULE__, :_call_threaded),
                Expr(:tuple, params...,
                    Expr(:call, GlobalRef(Core, :Ref), pv),
                    Expr(:call, GlobalRef(Core, :Ref), _implied_progress_callee(pv, callee, self)),
                    positional...))
        end
        _is_property_access(callee) || (callee = rw(callee))
        return Expr(:., callee, Expr(:tuple, args...))
    end

    # `obj.f(args...)`: keep the callee `obj.f` itself, so the helper receives the
    # `IndexableProperty`; its receiver and the arguments are walked.
    if Meta.isexpr(x, :call) && !isempty(x.args)
        if threads(x.args[1])
            rest = Any[rw(a) for a in x.args[2:end]]
            return fixcall(Expr(:call, GlobalRef(@__MODULE__, :_call_threaded),
                pv, _implied_progress_callee(pv, x.args[1], self), rest...))
        end
        callee = _is_property_access(x.args[1]) ? x.args[1] : rw(x.args[1])
        return fixcall(Expr(:call, callee, Any[rw(a) for a in x.args[2:end]]...))
    end

    # Keyword shorthand `; obj.field` stays keyword syntax: `field = <read>`.
    if Meta.isexpr(x, :parameters)
        return Expr(:parameters, Any[threads(a) ? Expr(:kw, a.args[2].value, rw(a)) : rw(a)
                                     for a in x.args]...)
    end
    if Meta.isexpr(x, :kw) && length(x.args) == 2
        return Expr(:kw, x.args[1], rw(x.args[2]))
    end

    threads(x) && return _read_threaded_expr(pv, rw(x.args[1]), x.args[2].value)

    Expr(x.head, Any[rw(a) for a in x.args]...)
end

_read_threaded_expr(pv::Symbol, receiver, name::Symbol) =
    Expr(:call, GlobalRef(@__MODULE__, :_read_threaded), pv, receiver,
         Expr(:call, Expr(:curly, GlobalRef(Base, :Val), QuoteNode(name))))

# The callee of `obj.f(...)` with its receiver walked and `.f` itself kept literal.
_implied_progress_callee(pv::Symbol, x::Expr, self::Bool=true) =
    Expr(:., _implied_progress_rewrite(pv, x.args[1], self), x.args[2])

# A syntactic property access `obj.name`, as opposed to broadcast `f.(xs)`.
_is_property_access(x) = Meta.isexpr(x, :.) && length(x.args) == 2 && x.args[2] isa QuoteNode

_is_assignment_head(head) = head isa Symbol && head !== :kw && endswith(String(head), "=")

# A progress-family marker on a declaration owns its body; the implied rewrite stands down.
_is_progress_marked(macros) = any(m -> m in macros,
    (Symbol("@progress"), Symbol("@PROGRESS"), Symbol("@fetch!"), Symbol("@dynamic_progress")))

# The unmarked body inside `Treebars.@progress_scope __status__ …` (decision `0r44qxt`): it
# binds `__progress__` to the body's node for the rewritten reads and runs inline
# `@progress "phase"` lines, while loops stay plain. An explicit
# `@progress "label" for …` still counts.
_implied_progress_wrap(body, lnn) =
    Expr(:macrocall, GlobalRef(Treebars, Symbol("@progress_scope")), lnn, :__status__,
         _progress_body_block(body))

# The body as a block the Treebars walker can safely lower. A string in statement position
# would read as a phase label, so it becomes `identity("…")` (same value). A non-block
# body is block-wrapped, so a bare comprehension stays a value. A block body is rebuilt in
# place, keeping inline phase markers direct statements of the scope (`1ce8892`).
_progress_safe_stmt(x) = x
_progress_safe_stmt(x::String) = Expr(:call, GlobalRef(Base, :identity), x)
_progress_safe_stmt(x::Expr) =
    Meta.isexpr(x, :string) ? Expr(:call, GlobalRef(Base, :identity), x) : x
_progress_body_block(rhs) = Meta.isexpr(rhs, :block) ?
    Expr(:block, Any[_progress_safe_stmt(a) for a in rhs.args]...) :
    Expr(:block, _progress_safe_stmt(rhs))

# Macros whose arguments are evaluated as ordinary code, so reads in them nest.
# `@memo!` / `@fresh` keep their meaning through their `_call_threaded` arms.
_implied_progress_macro(head) = _macro_basename(head) in (
    Symbol("@memo!"), Symbol("@fresh"), Symbol("@progress"), Symbol("@phases"),
    Symbol("@inbounds"), Symbol("@views"), Symbol("@view"), Symbol("@simd"),
    Symbol("@fastmath"), Symbol("@inline"), Symbol("@noinline"),
    Symbol("@spawn"), Symbol("@async"), Symbol("@sync"), Symbol("@threads"), Symbol("@lock"),
    Symbol("@assert"), Symbol("@show"), Symbol("@time"), Symbol("@timed"),
    Symbol("@elapsed"), Symbol("@allocated"),
    Symbol("@info"), Symbol("@debug"), Symbol("@warn"), Symbol("@error"), Symbol("@logmsg"))
_macro_basename(head::Symbol) = head
_macro_basename(head::GlobalRef) = head.name
_macro_basename(head::Expr) = _is_property_access(head) ? head.args[2].value : nothing
_macro_basename(head) = nothing

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
    # `_default_substatus` (gated on the property's docstring). The node is created
    # pending and started by `_fresh_through` when the computation runs, so a call
    # waiting for a job-queue slot does not render as running.
    s = _default_substatus(progress, o, name, indices...; __pending__=true, kwargs...)
    compute = _FreshCompute(o, name, indices, (; kwargs...), s)
    try
        rv = _fresh_through(property_executor(o, Val(name)), compute, s)
        _finish_compute_status!(compute, s)
        rv
    catch e
        _fail_compute_status!(compute, s, e)
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
    Meta.isexpr(x, :quote) && return _map_interpolations(a -> _progress_rewrite(progress_var, a), x)
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
unchanged otherwise. The caller is responsible for binding
`progress_var` — e.g. via `Treebars.@progress progress_var body` — and
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

"""
    DynamicObjects.clear_cache!(o, name::Symbol) -> Vector{Symbol}
    DynamicObjects.clear_cache!(o, name::Symbol, indices...; kwargs...)

The function behind [`@clear_cache!`](@ref), for a property name only known at
run time (`DynamicObjects.clear_cache!(prep, stage_root)`). Not exported.

With a name alone it drops the whole property **and everything derived from
it**: `name` and its transitive `dependents` — the memory value (every
entry of an indexed property), every disk entry of a `@cached` / `@mmap` one
(including entries an earlier process wrote), and shared remount work — so the
next read of any of them recomputes. Every other property keeps its value.
Returns the names that held a value in memory or on disk, sorted.

With indices or kwargs it drops exactly that one entry, as
[`invalidate!`](@ref) does, and returns `nothing`.
"""
clear_cache!(o, name::Symbol; kwargs...) =
    isempty(kwargs) ? _clear_property!(o, name) : _clear_cache_entry!(o, name; kwargs...)
function _clear_property!(o, name::Symbol)
    forward = _invalidation_address(o)
    names = _invalidate_property!(o, name)
    _forward_invalidation(forward, :clear_cache!, name)
    names
end
clear_cache!(o, name::Symbol, index, indices...; kwargs...) =
    _clear_cache_entry!(o, name, index, indices...; kwargs...)

# Clear one indexed entry — the shared per-entry primitive when the wrapper is
# resident; disk files alone when it is not.
function _clear_cache_entry!(o, name::Symbol, indices...; kwargs...)
    v = get(getfield(o, :cache).cache, name, nothing)
    if v isa IndexableProperty
        invalidate!(v, indices...; kwargs...)
    else
        on_disk = _remove_disk_entry!(o, name, indices...; kwargs...)
        _trace_invalidation!(:invalidate!, o, on_disk ? (name,) : (), (indices, (;kwargs...)))
        _forward_entry_invalidation(o, name, indices, (; kwargs...))
    end
    nothing
end
"""
    @clear_cache! object.property
    @clear_cache! object.property(arguments...)

The dot form clears the whole property and its transitive declared dependents,
including memory values and disk files. The call form clears only the selected
indexed entry, as [`invalidate!`](@ref) does. Inside a `@dynamicstruct` body the
object prefix may be omitted.

A clear retracts in-flight entries without cancelling their running bodies.
Their original callers may still receive a result, but those computations cannot
publish into the cleared cache; waiters resolve against the current entry.
Clearing an indexed property retains its wrapper and empties its subcache in place.

An explicit whole-property clear also resets state or constructor-seeded values
for that property. By contrast, [`clear_mem_caches!`](@ref) retains instance state
and restores constructor inputs. Use [`prune_mem_caches!`](@ref) for memory
reclamation that does not invalidate dependents.
"""
macro clear_cache!(x)
    cache_f_expr(x; f=clear_cache!) |> esc
end

isfixed(kv::Pair) = isfixed(kv[2])
isfixed(info::NamedTuple) = isnothing(info.rhs)

# Per-element handler for the `:local` branch of `walk_rhs` — register
# Symbol locals via dispatch instead of an `if arg isa Symbol …` chain
# inside the loop body. Tuple-Expr leaves go through `_push_if_symbol!`,
# assignments through `_walk_local_assign!`.
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
# `local x::T = …`, `local (a, b) = …`, `local (; a, b) = …`: every name the target
# binds is declared local, so the assignment is no cache write and later reads stay local.
_walk_local_assign!(lhs, arg, locals, properties, lnn) =
    (union!(locals, extractnames([lhs])); walk_rhs(arg; locals, properties, lnn))
_push_if_symbol!(locals, s::Symbol) = (push!(locals, s); nothing)
_push_if_symbol!(_, _) = nothing

# A local method definition is an ordinary Julia binding: `name(args) = …` and
# `function name(args) … end` make `name` local in the ENCLOSING scope, and the
# parameters (plus `where` type parameters) local in the body. Returns
# `(; name, params)` — `name === nothing` for an anonymous `function (x) … end`
# or a qualified / callable-object name, which binds nothing — or `nothing` when
# `sig` is not a method signature (a plain, typed or destructuring assignment
# LHS). Only `function` admits the `:tuple` (anonymous) signature: in an
# assignment a tuple LHS destructures.
_method_signature(sig; anonymous=false) = nothing
function _method_signature(sig::Expr; anonymous=false)
    if Meta.isexpr(sig, :where)
        inner = _method_signature(sig.args[1]; anonymous)
        isnothing(inner) && return nothing
        return (; inner.name, params=union(inner.params, _where_names(sig.args[2:end])))
    elseif Meta.isexpr(sig, :(::)) && length(sig.args) == 2
        return _method_signature(sig.args[1]; anonymous)   # return-type annotation
    elseif Meta.isexpr(sig, :call)
        return (; name=_local_method_name(sig.args[1]), params=extractnames(sig.args[2:end]))
    elseif anonymous && Meta.isexpr(sig, :tuple)
        return (; name=nothing, params=extractnames(sig.args))
    end
    nothing
end
_local_method_name(name::Symbol) = name
_local_method_name(_) = nothing
_where_names(args) = mapreduce(_where_name, union, args; init=Set{Symbol}())
_where_name(T::Symbol) = Set((T,))
_where_name(T::Expr) = Meta.isexpr(T, (:<:, :>:)) && T.args[1] isa Symbol ? Set((T.args[1],)) : Set{Symbol}()
_where_name(_) = Set{Symbol}()
# Bind a local method's name in the enclosing scope (mutating `locals`, as
# `local name` does) and return its body's scope.
function _bind_local_method!(locals, sig)
    _push_if_symbol!(locals, sig.name)
    union(locals, sig.params)
end

# Per-element handler for the trailing-else branch of `walk_rhs(::Expr)`.
# LineNumberNode arms record the LNN into a Ref so subsequent siblings
# pick it up; everything else recurses with the most recent LNN. Avoids
# the `if arg isa LineNumberNode` mutating-closure pattern.
_walk_with_lnn_tracking!(arg::LineNumberNode, ref, locals, properties) = (ref[] = arg; arg)
_walk_with_lnn_tracking!(arg, ref, locals, properties) =
    walk_rhs(arg; locals, properties, lnn=ref[])

walk_rhs(e; kwargs...) = e
walk_rhs(e::Expr; locals, properties, lnn=nothing) = if e.head == :let
    # `let` opens a new scope: its bindings, and whatever its body binds
    # (`local x`, a local method), stay inside it.
    inner = copy(locals)
    !Meta.isexpr(e.args[1], :block) && (e.args[1] = Expr(:block, e.args[1]))
    map!(e.args[1].args, e.args[1].args) do arg
        arg = _normalize_let_binding(arg)
        @assert Meta.isexpr(arg, :(=))
        name = arg.args[1]
        sig = _method_signature(name)
        rhs = if isnothing(sig)
            walk_rhs(arg.args[2]; locals=inner, properties, lnn)
        else
            walk_rhs(arg.args[2]; locals=_bind_local_method!(inner, sig), properties, lnn)
        end
        isnothing(sig) && union!(inner, extractnames([name]))   # `x`, `x::T`, `(a, b)`
        Expr(:(=), name, rhs)
    end
    e.args[2] = walk_rhs(e.args[2]; locals=inner, properties, lnn)
    e
elseif e.head == :while
    # A `while` body is a new scope; its condition is evaluated outside it.
    Expr(:while, walk_rhs(e.args[1]; locals, properties, lnn),
        walk_rhs(e.args[2]; locals=copy(locals), properties, lnn))
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
    # `function g(x) … end` (any signature shape): `g` is local in the enclosing
    # scope, `g` and the params in the body. `function g end` declares a local
    # generic function; an anonymous `function (x) … end` binds only `x`.
    sig = _method_signature(e.args[1]; anonymous=true)
    if length(e.args) == 1
        _push_if_symbol!(locals, e.args[1])
        e
    elseif isnothing(sig)
        Expr(:function, e.args[1], walk_rhs(e.args[2]; locals, properties, lnn))
    else
        Expr(:function, e.args[1], walk_rhs(e.args[2]; locals=_bind_local_method!(locals, sig), properties, lnn))
    end
elseif e.head == :try
    # try; body; catch e; catch_body; [finally; finally_body;] [else; else_body;] end
    # args: [try_body, catch_var, catch_body, [finally_body or false, [else_body]]]
    # Every block is its own scope; the catch variable is local to the catch block.
    catch_var = e.args[2]  # Symbol or false
    catch_locals = catch_var === false ? copy(locals) : union(locals, Set([catch_var]))
    walked = Any[walk_rhs(e.args[1]; locals=copy(locals), properties, lnn), catch_var,
        walk_rhs(e.args[3]; locals=catch_locals, properties, lnn)]
    for block in e.args[4:end]
        push!(walked, walk_rhs(block; locals=copy(locals), properties, lnn))
    end
    Expr(:try, walked...)
elseif e.head in (:kw, :(=))
    sig = _method_signature(e.args[1])
    if !isnothing(sig)
        # Local method definition `f(x) = …` (also `f(x)::T = …`, `f(x) where T = …`):
        # `f` is local in the enclosing scope, `f` and the params in the body.
        Expr(e.head, e.args[1], walk_rhs.(e.args[2:end]; locals=_bind_local_method!(locals, sig), properties, lnn)...)
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
        Expr(e.head, _walk_assign_target(lhs; locals, properties, lnn),
            walk_rhs.(e.args[2:end]; locals, properties, lnn)...)
    end
elseif e.head == :quote
    _map_interpolations(a -> walk_rhs(a; locals, properties, lnn), e)
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
            for a in _evaluated_args(e)
                _collect_self_deps_walk!(deps, opaque, a)
            end
        end
    end
    nothing
end

# The names read along `__self__.a(args).b.c(args)` and the arguments of its calls,
# or `nothing` when `e` is not such a chain.
function _self_chain(e)
    path = Symbol[]
    args = Any[]
    while true
        if e === :__self__
            return reverse!(path), args
        elseif Meta.isexpr(e, :., 2) && e.args[2] isa QuoteNode && e.args[2].value isa Symbol
            push!(path, e.args[2].value)
            e = e.args[1]
        elseif Meta.isexpr(e, :call) && !isempty(e.args)
            append!(args, @view e.args[2:end])
            e = e.args[1]
        else
            return nothing
        end
    end
end

# Harvest what a walked RHS reads of the inline `children` (`_remount_child_reads`).
# A child read any other way than through a named member, a bare `__self__.child`
# or a call of it with no member after, leaves the one-name path that means the
# body holds the instance.
function _collect_child_reads!(paths, e, children)
    e isa Expr || return paths
    if e.head === :(=) && length(e.args) == 2 && Meta.isexpr(e.args[1], :tuple, 1) &&
       Meta.isexpr(e.args[1].args[1], :parameters)
        chain = _self_chain(e.args[2])
        if chain !== nothing && !isempty(first(chain)) && first(first(chain)) in children
            for name in e.args[1].args[1].args
                push!(paths, name isa Symbol ? (first(chain)..., name) : Tuple(first(chain)))
            end
            foreach(a -> _collect_child_reads!(paths, a, children), last(chain))
            return paths
        end
    end
    chain = _self_chain(e)
    if chain !== nothing && !isempty(first(chain)) && first(first(chain)) in children
        push!(paths, Tuple(first(chain)))
        foreach(a -> _collect_child_reads!(paths, a, children), last(chain))
        return paths
    end
    foreach(a -> _collect_child_reads!(paths, a, children), _evaluated_args(e))
    paths
end

# --- Linter ----------------------------------------------------------------
#
# Lints are computed by `analyze_structure(T)` — a tree-walk over `meta(T)`
# that produces a `Vector{LintMessage}`. `print_structure(T)` weaves these
# messages inline next to the affected property/struct. There is no
# automatic stderr/error emission from the macro; lints surface only when
# you render the structure.

"""
    LintMessage

A declaration diagnostic returned by [`lint_index`](@ref). Fields identify the
`type`, optional `prop`, `severity` (`:warn` or `:error`), `short` and `long`
messages, and optional source line node `lnn`. Rendering a structure exposes
these diagnostics; defining a type does not print them automatically.
"""
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
_contains_self_ref(e::Expr) = any(_contains_self_ref, _evaluated_args(e))
_contains_self_ref(_) = false

_contains_bare_prop_ref(e::Symbol, prop_names) = e in prop_names
_contains_bare_prop_ref(e::Expr, prop_names) = any(a -> _contains_bare_prop_ref(a, prop_names), _evaluated_args(e))
_contains_bare_prop_ref(_, _) = false

_contains_call(_) = false
_contains_call(e::Expr) = Meta.isexpr(e, :call) || any(_contains_call, _evaluated_args(e))

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
    for a in _evaluated_args(e)
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

include("declaration_analysis.jl")

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

"""    _source_shared_child(::Type{T}, ::Val{name})

`true` when the inline child under `name` is built through [`_inline_child`],
so a [`remount`](@ref) view resolves it on the retained source on first
access. `@dynamicstruct` emits it for every non-`@fresh` inline `@struct`
child; external `@include` children and older expansions keep the default
`false`: a view builds them with its own constructor call and reuses a child
already settled on the source only when that call constructs it alike
(`_adopt_source_child`).
"""
_source_shared_child(::Type, ::Val) = false

"""    _remount_child_reads(::Type{T})

What each property of `T` reads of its inline `@struct` children, as
`(property, paths)` pairs. A path is the chain of names read from `__self__`,
starting at the child: `(:pins, :ap3)` for `pins.ap3`, and `(:pins,)` when the
body uses the child itself, which hands out an instance that holds a request's
view. [`remount`](@ref) uses it to decide a sibling of a child by what it reads.
A property with no entry, as in an older expansion, is context if it depends on
a child.
"""
_remount_child_reads(::Type) = ()

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

The declared domain for `parameter` on this object — the value of the
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
    option_domain(values)

Wrap a finite collection as a domain with presentation metadata. Each entry may
be a bare value, a `value => label` pair, or a record with `value`, `label`,
`group`, `help` and `disabled` fields. Missing labels default to `string(value)`.
Membership is defined on the machine values, independently of their labels.

Use the result in an `@options` declaration. A dependent declaration recomputes
when its inputs change. Reflection reports the declaration without evaluating
it; read the evaluated domain through [`property_options`](@ref), then use
[`option_records`](@ref) for its per-value metadata.
"""
function option_domain(values)
    options = NamedTuple[_option_descriptor(value) for value in values]
    OptionDomain(map(option -> option.value, options), options)
end

"""
    option_records(domain) -> Vector{NamedTuple} or nothing

The option records of an evaluated domain — one `(; value, label, group, help,
disabled)` per value, in domain order. Use these records to render an evaluated domain.

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
# Every Symbol appearing in a type annotation — `value::Vector{T}` mentions `T`.
# Used to decide whether a struct's type parameters are solvable from its fields.
_type_symbols(_) = Set{Symbol}()
_type_symbols(x::Symbol) = Set{Symbol}((x,))
_type_symbols(x::Expr) = mapreduce(_type_symbols, union, x.args; init=Set{Symbol}())
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
# Make a built call valid: its keyword block goes first, wherever arguments were spliced.
# A call with no keyword block gets none, and a single block keeps its written order: an
# empty `;` changes the call a macro reads (Treebars' `@progress … map(…) do` splices
# `map`'s arguments), and keyword order is precedence (`f(; nt..., a=2)` passes `a=2`).
fixcall(x) = x
fixcall(x::Expr) = if Meta.isexpr(x, :call)
    f = x.args[1]
    args = fixcall.(x.args[2:end])
    blocks = filter(a -> Meta.isexpr(a, :parameters), args)
    positional = filter(a -> !Meta.isexpr(a, :parameters), args)
    length(blocks) <= 1 && return Expr(x.head, f, blocks..., positional...)
    # Several blocks only arise in Expr-based method generation (e.g. one from
    # info.indices containing `kwargs...` and one from cp_kwargs containing `name=val`).
    # A signature requires splat kwargs to be final, so merge them, splats last,
    # regardless of which :parameters node they originated from.
    pargs = Any[a for b in blocks for a in b.args]
    Expr(x.head, f, Expr(:parameters, filter(a -> !Meta.isexpr(a, :(...)), pargs)...,
                                      filter(a -> Meta.isexpr(a, :(...)), pargs)...),
         positional...)
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

# An assignment target with its reads walked. A bound name stays as it is; the
# container of a field or index target (`a.b = …`, `a[i] = …`) and a type
# annotation (`x::T = …`) are reads, walked at any depth of a destructuring
# (`a.b, c[i] = …`, `(a.b, (c, d...)) = …`).
_walk_assign_target(lhs; kwargs...) = lhs
_walk_assign_target(lhs::Expr; kwargs...) = _walk_assign_target(Val(lhs.head), lhs; kwargs...)
_walk_assign_target(::Val, lhs; kwargs...) = lhs
_walk_assign_target(::Union{Val{:.}, Val{:ref}}, lhs; kwargs...) = walk_rhs(lhs; kwargs...)
_walk_assign_target(::Union{Val{:tuple}, Val{:...}}, lhs; kwargs...) =
    Expr(lhs.head, Any[_walk_assign_target(a; kwargs...) for a in lhs.args]...)
_walk_assign_target(::Val{:(::)}, lhs; kwargs...) = length(lhs.args) == 2 ?
    Expr(:(::), _walk_assign_target(lhs.args[1]; kwargs...), walk_rhs(lhs.args[2]; kwargs...)) : lhs

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

include("struct_macro.jl")

include("remake.jl")

# The keyword arguments `obj` was constructed with. A remount view's own seed
# is its context, layered over the retained object's seed: `_restore_seeds!`
# restores both.
_construction_seed(obj) = _construction_seed(getfield(obj, :cache))
_construction_seed(pc::PropertyCache) = _construction_seed(pc.cache, pc.seed)
_construction_seed(c::MountedThreadsafeDict, seed) = merge(getfield(c.source, :cache).seed, seed)
_construction_seed(_, seed) = seed
# Identity is the retained object's (`_REMOUNT_INTRINSIC_KEYS` are shared), so a
# view's rebound context never enters it.
_identity_seed(c::MountedThreadsafeDict, _) = _identity_seed(getfield(c.source, :cache))

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

# A property whose RHS is exactly `__parent__.<name>` — every name an inline
# child forwards from its parent, and any authored equivalent — is an alias of
# that parent property.
_parent_alias(rhs::Expr) =
    Meta.isexpr(rhs, :., 2) && rhs.args[1] === :__parent__ && rhs.args[2] isa QuoteNode ?
        rhs.args[2].value : nothing
_parent_alias(_) = nothing

# Aliases that stay context-independent when `__parent__` is rebound to
# `parent_view`, a view of this object's OWN retained parent (`_remount_child`):
# the alias then reads the identical shared value through either parent unless
# the parent view itself routes the target locally. No parent view (an explicit
# `__parent__=` rebinding to an arbitrary object) proves nothing.
_shared_parent_aliases(::Type, ::Nothing) = Dict{Symbol,Symbol}()
function _shared_parent_aliases(::Type{T}, parent_context::Set{Symbol}) where {T}
    aliases = Dict{Symbol,Symbol}()
    for (name, info) in meta(T)
        target = _parent_alias(get(info, :rhs, nothing))
        target === nothing || target in parent_context || (aliases[name] = target)
    end
    aliases
end

# Return (invalidated values, local wrapper keys, opaque). `invalidated` is the
# sound transitive closure rooted at explicit context overrides, fresh progress
# state, opaque self-reaches, and nested children (which retain their parent
# object). `opaque` is the part of it reached only through opaque self-reaches:
# those properties MAY read context, so they stay view-local values, but they
# first try the remount namespace, which shares them while they provably read
# none (`_opaque_get!`). Indexed wrapper KEYS are always local so their `o` is
# the mounted object; an indexed property's per-argument subcache is shared only
# when that property is absent from `invalidated` (see the mounted `subcache`
# method above). Shared parent aliases (`_shared_parent_aliases`) are likewise
# local keys — re-read through the current parent — that join neither closure.
function _remount_partition(source, shared::ThreadsafeDict{Symbol,Any}, changed,
                            forced_local=(), parent_view=nothing)
    T = typeof(source)
    parent_context = parent_view === nothing ? nothing : _remount_context_names(parent_view)
    invalidated, opaque, aliases = _remount_context(T, changed, forced_local, parent_context)
    local_names = union(invalidated, keys(aliases))
    for (name, info) in meta(T)
        get(info, :indexed, false) || continue
        value = get(shared, name, _missing_sentinel)
        (value === _missing_sentinel || value isa IndexableProperty) && push!(local_names, name)
    end
    invalidated, local_names, opaque, aliases
end

# The static part of the partition, which a type and its rebound names decide.
# A nested child instance is always per view, because it holds its parent. What
# depends on the child is not, when it is an inline child whose memoized cache
# every view shares: a sibling reading `pins.ap3` is per view exactly when that
# member reaches context (`_child_read_is_context`). That can depend on what the
# parent already routes per view, through a forwarded name, and adding a sibling
# can make another read context, so the two closures alternate until settled.
#
# The answer depends only on the type and on which names are rebound, a small fixed
# set for an app, so it is computed once per process: `remount` runs per request
# and per child read. The result is shared, so no caller may mutate it. It is held
# per `meta(T)` object, which a re-expanded struct replaces.
const _REMOUNT_CONTEXTS = IdDict{Any,Dict{Any,Any}}()
const _REMOUNT_CONTEXTS_LOCK = ReentrantLock()
function _remount_context(::Type{T}, changed, forced_local, parent_context) where {T}
    declaration = meta(T)
    key = (sort!(collect(Symbol, changed)), sort!(collect(Symbol, forced_local)), parent_context)
    known = lock(_REMOUNT_CONTEXTS_LOCK) do
        contexts = get(_REMOUNT_CONTEXTS, declaration, nothing)
        contexts === nothing ? nothing : get(contexts, key, nothing)
    end
    known === nothing || return known
    # Outside the lock: computing recurses into child types. A race computes twice.
    context = _compute_remount_context(T, changed, forced_local, parent_context)
    stored = (first(key), key[2], parent_context === nothing ? nothing : copy(parent_context))
    lock(_REMOUNT_CONTEXTS_LOCK) do
        get!(() -> Dict{Any,Any}(), _REMOUNT_CONTEXTS, declaration)[stored] = context
    end
    context
end

function _compute_remount_context(::Type{T}, changed, forced_local, parent_context) where {T}
    dependencies = Dict{Symbol,Set{Symbol}}()
    computed = Set{Symbol}()
    names = Set{Symbol}()
    for (name, info) in meta(T)
        push!(names, name)
        get(info, :rhs, nothing) === nothing || push!(computed, name)
        deps = get(info, :dependson, nothing)
        deps === nothing || union!(get!(() -> Set{Symbol}(), dependencies, name), deps)
    end

    invalidated = union(Set{Symbol}(changed), Set{Symbol}(forced_local))
    # Progress/status is request-scoped state even when the caller doesn't pass
    # it explicitly. Keeping it local also prevents a mounted request from
    # relabelling/reparenting the retained graph's progress tree on cache hits.
    for name in (:__status__, :__substatus__)
        name in names && push!(invalidated, name)
    end
    # Every nested child retains `__parent__`; never share a child instance whose
    # parent is the retained source object with a mounted view.
    for name in names
        _nested_struct_type(T, Val(name)) === nothing || push!(invalidated, name)
    end
    declared_opaque = _remount_opaque_properties(T)
    # An older expansion carries no opacity data: every computed property is context.
    declared_opaque === nothing && union!(invalidated, computed)
    aliases = filter!(p -> !(first(p) in invalidated), _shared_parent_aliases(T, parent_context))
    shared_aliases = keys(aliases)
    # A property whose reads of a child are recorded is decided by those reads, so
    # the child's name is no dependency of it here. `sync!` keeps the full graph.
    child_reads = _remount_child_reads(T)
    for (name, paths) in child_reads
        deps = get(dependencies, name, nothing)
        deps === nothing || foreach(path -> delete!(deps, first(path)), paths)
    end
    graph = _DependencyGraph(dependencies)
    while true
        _close_dependents!(invalidated, graph, shared_aliases)
        grew = false
        for (name, paths) in child_reads
            (name in invalidated || name in shared_aliases) && continue
            any(path -> _child_read_is_context(T, path, invalidated), paths) || continue
            push!(invalidated, name)
            grew = true
        end
        grew || break
    end
    opaque = declared_opaque === nothing ? Set{Symbol}() :
        setdiff!(Set{Symbol}(declared_opaque), invalidated)
    _close_dependents!(opaque, graph, union(invalidated, shared_aliases))
    union!(invalidated, opaque)
    invalidated, opaque, aliases
end

# Does reading `path` from the inline child `first(path)` of a `T` view reach
# context, given the `T` names routed per view? Uses the partition the child's own
# view gets (`_remount_child`), so the answer and the routing cannot disagree.
# Holding the instance itself, a name the child does not declare, and anything
# opaque count as context.
function _child_read_is_context(::Type{T}, path, parent_names) where {T}
    length(path) == 1 && return true
    _source_shared_child(T, Val(first(path))) || return true
    C = _nested_struct_type(T, Val(first(path)))
    C === nothing && return true
    member = path[2]
    child_names = Set{Symbol}(first(p) for p in meta(C))
    member in child_names || return true
    changed = Symbol[]
    :__parent__ in child_names && push!(changed, :__parent__)
    :__req__ in child_names && any(p -> first(p) === :__req__, meta(T)) && push!(changed, :__req__)
    forced = (:__status__, (:__prefix__ in child_names ? (:__prefix__,) : ())...)
    context, = _remount_context(C, changed, forced, parent_names)
    if _source_shared_child(C, Val(member)) && length(path) > 2
        return _child_read_is_context(C, path[2:end], context)
    end
    member in context
end

# The names a parent routes per view: none unless it is itself a remount view.
const _NO_CONTEXT_NAMES = Set{Symbol}()
_remount_context_names(o) = begin
    hasfield(typeof(o), :cache) || return _NO_CONTEXT_NAMES
    pc = getfield(o, :cache)
    pc isa PropertyCache || return _NO_CONTEXT_NAMES
    c = pc.cache
    c isa MountedThreadsafeDict ? c.invalidated : _NO_CONTEXT_NAMES
end
_remount_invalidated(o, name::Symbol) = name in _remount_context_names(o)

# --- opaque remount sharing ----------------------------------------------------

# Progress state is observational: reading it never makes a value context-dependent.
const _REMOUNT_STATUS_NAMES = (:__status__, :__substatus__)

# A remount view is identified by its value overlay, which only it owns.
_requester_token(view) = getfield(view, :cache).cache.cache.overlay
_own_failure(e::_RemountContextDependent, requester) =
    e.error !== nothing && e.token.value === _requester_token(requester)

"""
    _OpaqueSubcache

The remount-namespace latch of one opaque property as one view (`requester`)
sees it. Its `AbstractThreadsafeDict` fields are the namespace's dictionaries,
so the ordinary get/`Pending` machinery runs every view on one computation;
`local_dict` holds the requester's own values for keys that read context — the
requester's value cache for a bare property, a per-argument subcache for an
indexed one. A `Pending` on it resolves to the requester's own value instead of
surfacing another view's context dependence.
"""
struct _OpaqueSubcache{L<:AbstractThreadsafeDict} <: AbstractThreadsafeDict{Any,Any}
    lock::ReentrantLock
    cache::Dict
    status::Dict
    computing::Dict
    errors::Dict
    shared::ThreadsafeDict
    local_dict::L
    ns::_OpaqueNamespace
    name::Symbol
    requester::Any
end
_OpaqueSubcache(ns::_OpaqueNamespace, name::Symbol, requester, shared::ThreadsafeDict,
                local_dict::AbstractThreadsafeDict) =
    _OpaqueSubcache(shared.lock, shared.cache, shared.status, shared.computing, shared.errors,
                    shared, local_dict, ns, name, requester)

# A bare property is keyed by its name, an indexed one by `(indices, kwargs)`.
const _OpaqueBare = _OpaqueSubcache{<:MountedThreadsafeDict}
_taint_key(oc::_OpaqueBare, key) = oc.name
_taint_key(oc::_OpaqueSubcache, key) = (oc.name, key)
_opaque_compute(oc::_OpaqueBare, view, key, s) = _computeproperty(view, oc.name; __status__=s)
_opaque_compute(oc::_OpaqueSubcache, view, key, s) =
    _computeproperty(view, oc.name, key[1]...; __status__=s, key[2]...)
_opaque_substatus_f(oc::_OpaqueBare, key) = _bare_substatus_f(oc.requester, oc.name)
function _opaque_substatus_f(oc::_OpaqueSubcache, (indices, kwargs))
    o, name = oc.requester, oc.name
    () -> compute_property(o, Val(:__substatus__), name, indices...; __status__=o.__status__, __pending__=true, kwargs...)
end
_opaque_local!(oc::_OpaqueBare, key; fetch=Base.fetch, retry_failed=true, link=nothing) =
    _local_bare!(oc.requester, oc.name; fetch, retry_failed, link)
_opaque_local!(oc::_OpaqueSubcache, (indices, kwargs); fetch=Base.fetch, retry_failed=true, link=nothing) =
    _memoize_linked!(link, IndexableProperty(oc.name, oc.requester, oc.local_dict), indices...;
                     fetch, retry_failed, kwargs...)
# Opaque names are view-local, so a bare value lands in the requester's overlay.
# Returns whether it stored `value` (a value already there is kept).
_store_local!(oc::_OpaqueBare, key, value) =
    _store_new!(oc.local_dict.cache.overlay, oc.name, value, oc.local_dict.lock)
_store_local!(oc::_OpaqueSubcache, key, value) =
    _store_new!(oc.local_dict.cache, key, value, oc.local_dict.lock)
_store_new!(dict, key, value, dict_lock) = lock(dict_lock) do
    haskey(dict, key) && return false
    dict[key] = value
    true
end

_local_bare!(o, name::Symbol; fetch=Base.fetch, retry_failed=true, link=nothing) =
    get!(_bare_compute(o, name), getfield(o, :cache).cache, name;
         substatus=_bare_substatus_f(o, name), fetch, retry_failed, link)

# The call an opaque key stands for, as `property_settled` reports it.
_opaque_call(oc::_OpaqueBare, key) = ((), (;))
_opaque_call(oc::_OpaqueSubcache, (indices, kwargs)) = (indices, kwargs)

# The guarded `__self__` of one opaque computation for `requester`.
function _probe_view(requester, probe::_OpaqueProbe)
    T = typeof(requester)
    pc = getfield(requester, :cache)
    args = Any[getfield(requester, name) for name in fieldnames(T)[1:end-1]]
    T(_REMOUNT_TOKEN, PropertyCache(_probe_dict(pc.cache, probe), pc.seed), args...)
end

# Compute `key` at most once for every view on the shared latch, under a fresh
# guard. A computation that read context taints the key, gives its value to the
# requester alone, and fails the latch with `_RemountContextDependent`, so every
# other accessor computes the key in its own view.
function _opaque_shared!(oc::_OpaqueSubcache, key; fetch=Base.fetch, retry_failed=true, trace_t0=_trace_clock(), link=nothing)
    t0 = trace_t0
    hit = get(oc, key, _missing_sentinel)
    args, kwargs = _opaque_call(oc, key)
    if hit !== _missing_sentinel
        t0 == 0 || _trace_read!(oc.requester, oc.name, _trace_args(args, kwargs), Val(:hit), t0)
        _link_hit!(link, oc, key, hit)
        return hit
    end
    local_value = Ref{Any}(_missing_sentinel)
    compute = _Settling(oc.requester, oc.name, args, kwargs, local_value) do s
        guard = _publish_guard()   # read before `_opaque_compute` takes it
        probe = _OpaqueProbe(oc.requester, oc.name)
        context_dependent(error) = (_ns_taint!(oc.ns, _taint_key(oc, key));
            _RemountContextDependent(oc.name, WeakRef(_requester_token(oc.requester)), error))
        value = try
            _opaque_compute(oc, _probe_view(oc.requester, probe), key, s)
        catch e
            _seal!(probe) && throw(context_dependent(e))
            rethrow()
        end
        if _seal!(probe)
            # The requester's own value; reported once the latch has failed (`_failed!`).
            # Not stored if an invalidation retracted the computation meanwhile.
            _publishable(guard) && _store_local!(oc, key, value) && (local_value[] = value)
            throw(context_dependent(nothing))
        end
        value
    end
    get!(compute, oc, key; fetch, retry_failed, substatus=_opaque_substatus_f(oc, key), trace_t0=t0, link)
end

# The latch records a context-dependent computation as a failure; its progress
# node reflects what the computation itself did.
_fail_substatus!(s::Treebars.ProgressNode, e::_RemountContextDependent) =
    e.error === nothing ? _finalize_substatus!(s) : _fail_substatus!(s, e.error)

# Read opaque `key` through `oc`, on behalf of `reader` — the guard of an
# enclosing opaque computation, or `nothing` for the view itself.
function _opaque_get!(oc::_OpaqueSubcache, key, reader; fetch=Base.fetch, retry_failed=true,
                      trace_t0=_trace_clock(), link=nothing)
    # A guard reads values, never handles: a handle could resolve to the
    # requester's context-dependent value after the guard stopped watching.
    reader === nothing || (fetch = _blocking_selector(fetch))
    if !_ns_tainted(oc.ns, _taint_key(oc, key))
        try
            return _opaque_shared!(oc, key; fetch, retry_failed, trace_t0, link)
        catch e
            e isa _RemountContextDependent || rethrow()
            if _own_failure(e, oc.requester)
                reader === nothing || _taint!(reader, oc.name)
                throw(e.error)
            end
        end
    end
    # Context-dependent: the requester's own value, which is context to a guard.
    reader === nothing || _taint!(reader, oc.name)
    _opaque_local!(oc, key; fetch, retry_failed, link)
end

_opaque_bare!(requester, name::Symbol, reader; fetch=Base.fetch, link=nothing) = begin
    c = getfield(requester, :cache).cache
    _opaque_get!(_OpaqueSubcache(c.namespace, name, requester, c.namespace.cache, c), name, reader; fetch, link)
end

function _opaque_status(oc::_OpaqueSubcache, key)
    c = _ns_tainted(oc.ns, _taint_key(oc, key)) ? oc.local_dict : oc
    lock(() -> get(c.status, key, nothing), c.lock)
end

# Every read through the guard of an opaque computation. Opaque state is read
# through the namespace on the requester's behalf. Context — anything the
# remount routes view-locally — is served from the requester and taints the
# computation. Everything else is provably context-independent.
function _probe_read(c::MountedThreadsafeDict, probe::_OpaqueProbe, o, name::Symbol; link=nothing)
    requester = probe.requester
    if name in c.opaque
        is_indexed_property(o, name) &&
            return IndexableProperty(name, o, getproperty(requester, name).cache)
        return _opaque_bare!(requester, name, probe; link)
    end
    name in c.invalidated && !(name in _REMOUNT_STATUS_NAMES) && _taint!(probe, name)
    link === nothing ? getproperty(requester, name) : _getorcompute_linked(requester, name, link)
end

function _mounted_fetchproperty(fetch, c::MountedThreadsafeDict, o, name::Symbol)
    probe = c.probe
    if probe !== nothing
        name in c.opaque && return fetch(_opaque_bare!(probe.requester, name, probe), nothing)
        name in c.invalidated && !(name in _REMOUNT_STATUS_NAMES) && _taint!(probe, name)
        return fetchproperty(fetch, probe.requester, name)
    end
    oc = _OpaqueSubcache(c.namespace, name, o, c.namespace.cache, c)
    rv = _opaque_get!(oc, name, nothing; fetch=identity)
    fetch(rv, _opaque_status(oc, name))
end

memoize!(ip::IndexableProperty{name,<:Any,<:_OpaqueSubcache}, indices...;
         fetch=Base.fetch, retry_failed=true, kwargs...) where {name} =
    _memoize_linked!(nothing, ip, indices...; fetch, retry_failed, kwargs...)
_memoize_linked!(link, ip::IndexableProperty{name,<:Any,<:_OpaqueSubcache}, indices...;
                 fetch=Base.fetch, retry_failed=true, kwargs...) where {name} = begin
    t0 = _trace_clock()   # before the key, so a traced hit's time includes hashing it
    _opaque_get!(ip.cache, _memo_key(indices, (;kwargs...)), _remount_probe(ip.o);
                 fetch=_declared_fetch(fetch, ip.o, Val(name)), retry_failed, trace_t0=t0, link)
end

getstatus(ip::IndexableProperty{<:Any,<:Any,<:_OpaqueSubcache}, indices...; kwargs...) =
    _opaque_status(ip.cache, _memo_key(indices, (;kwargs...)))

function Base.fetch(p::Pending{<:_OpaqueSubcache})
    try
        invoke(Base.fetch, Tuple{Pending}, p)
    catch e
        e isa _RemountContextDependent || rethrow()
        _own_failure(e, p.cache.requester) && throw(e.error)
        _opaque_local!(p.cache, p.key; fetch=_blocking_selector(p))
    end
end
Base.isready(p::Pending{<:_OpaqueSubcache}) = haskey(p.cache, p.key) ||
    (_ns_tainted(p.cache.ns, _taint_key(p.cache, p.key)) && haskey(p.cache.local_dict, p.key))

# Observers see each key where it lives: shared until it read context, then local.
function _raw_entries(ip::IndexableProperty{<:Any,<:Any,<:_OpaqueSubcache})
    oc = ip.cache
    shared = invoke(_raw_entries, Tuple{IndexableProperty{<:Any,<:Any,<:AbstractThreadsafeDict}}, ip)
    filter!(e -> !_ns_tainted(oc.ns, _taint_key(oc, e.key)), shared)
    vcat(shared, _raw_entries(IndexableProperty(oc.name, oc.requester, oc.local_dict)))
end
cached_entries(ip::IndexableProperty{<:Any,<:Any,<:_OpaqueSubcache}) =
    [e.key => e.value for e in entries(ip) if e.state === :done]
maybepop!(oc::_OpaqueSubcache, key) = begin
    invoke(maybepop!, Tuple{AbstractThreadsafeDict,Any}, oc, key)
    maybepop!(oc.local_dict, key)
end
Base.empty!(oc::_OpaqueSubcache) = (empty!(oc.shared); empty!(oc.local_dict); oc)

_is_dynamic_object(value) = hasfield(typeof(value), :cache) &&
    getfield(value, :cache) isa PropertyCache

_retained_object(obj) = _is_dynamic_object(obj) ? first(_remount_source(obj)) : obj

# Bind the context DO itself understands structurally. `__req__` is identical
# through a routed request and can be copied from the current parent; `__prefix__`
# is route-relative, so mask the retained value and let the child's own generated
# property recompute it from its new `__parent__`. `seed` adds view-local
# construction context (an inline child's request progress node). When `parent`
# is a view of the child's own retained parent, aliases of parent properties
# that view shares stay shared (`_shared_parent_aliases`).
function _remount_child(child, parent, seed::NamedTuple=(;))
    bindings = Pair{Symbol,Any}[]
    hasproperty(child, :__parent__) && push!(bindings, :__parent__ => parent)
    if hasproperty(child, :__req__) && hasproperty(parent, :__req__)
        push!(bindings, :__req__ => getproperty(parent, :__req__))
    end
    context = (; bindings...)
    forced = hasproperty(child, :__prefix__) ? (:__prefix__,) : ()
    retained = _retained_object(child)
    parent_view = hasproperty(retained, :__parent__) &&
        getproperty(retained, :__parent__) === _retained_object(parent) ? parent : nothing
    _remount_impl(child, context, forced, parent_view, seed)
end

"""    _inline_child(owner, ::Val{name}, ::Val{indexed}, args, kwargs, C, ctor)

Construct the inline `@struct` child `name` of `owner`: `C(; ctor...)` on an
ordinary object. On a [`remount`](@ref) view the child is instead resolved on
the retained source — `source.name` or `source.name(args...; kwargs...)`,
realizing and memoizing it there on first access and awaiting an in-flight
construction — and rebound to the view with `_remount_child`. Every view thus
shares one child cache, including in-flight work, rather than each building a
private copy. The view's own progress node from `ctor` seeds the rebound child,
so its progress still hangs under the request.
"""
_inline_child(owner, name::Val, indexed::Val, args, kwargs, ::Type{C}, ctor) where {C} =
    _inline_child(getfield(owner, :cache).cache, owner, name, indexed, args, kwargs, C, ctor)
_inline_child(::AbstractThreadsafeDict, owner, ::Val, ::Val, args, kwargs, ::Type{C}, ctor) where {C} =
    C(; ctor...)
function _inline_child(c::MountedThreadsafeDict, owner, ::Val{name}, indexed::Val, args, kwargs,
                       ::Type, ctor) where {name}
    child = _source_child(getproperty(c.source, name), indexed, args, kwargs)
    _remount_child(child, owner, _inline_child_seed(ctor))
end
_source_child(child, ::Val{false}, args, kwargs) = child
_source_child(ip, ::Val{true}, args, kwargs) = ip(args...; kwargs...)
_inline_child_seed(ctor::NamedTuple{names}) where {names} =
    :__status__ in names ? (; __status__=ctor.__status__) : (;)

"""    _adopt_source_child(o, name, key, child)

The nested child `o` stores for property `name` (memo `key` for an indexed one,
`nothing` for a bare one), given the `child` its own constructor call just
built. On an ordinary object that is `child`. On a `remount` view, a child
registered through `_nested_struct_type` (an external `@include`) is the
retained source's settled child for the same key, rebound to the view with
`_remount_child`, when the two were constructed alike (`_same_construction`):
the view then shares that child's caches. A child that the view's context
constructs differently — a constructor argument read rebound context — stays
the view's own. Inline `@struct` children are resolved on the source by
`_inline_child` instead.
"""
_adopt_source_child(o, name, key, child) = hasfield(typeof(o), :cache) ?
    _adopt_source_child(getfield(o, :cache), o, name, key, child) : child
_adopt_source_child(_, o, name, key, child) = child
_adopt_source_child(pc::PropertyCache{<:MountedThreadsafeDict}, o, name::Symbol, key, child) =
    _adopt_source_child(pc, o, Val(name), key, child)
function _adopt_source_child(pc::PropertyCache{<:MountedThreadsafeDict}, o, ::Val{name}, key,
                             child) where {name}
    T = typeof(o)
    (_nested_struct_type(T, Val(name)) === nothing || _source_shared_child(T, Val(name))) &&
        return child
    c = pc.cache
    settled = _settled_source_child(c, name, key)
    settled === _missing_sentinel && return child
    _same_construction(child, settled, o, c.source) || return child
    _discard_progress!(child, settled)
    _remount_child(settled, o, _child_context_seed(child))
end

# The retained source's settled child for `name`: a value, never an in-flight
# construction, which is still bound to the source parent.
function _settled_source_child(c::MountedThreadsafeDict, name::Symbol, key)
    value = _source_entry(c, name, key)
    _is_dynamic_object(value) ? value : _missing_sentinel
end
_source_entry(c::MountedThreadsafeDict, name::Symbol, ::Nothing) = get(c.shared, name, _missing_sentinel)
function _source_entry(c::MountedThreadsafeDict, name::Symbol, key::_MemoKey)
    ip = get(c.shared, name, _missing_sentinel)
    ip isa IndexableProperty ? get(ip.cache, key, _missing_sentinel) : _missing_sentinel
end

# Request-scoped creation kwargs, which are not part of a child's construction
# identity. `_remount_child` routes `__req__` and `__prefix__` view-locally
# together with everything derived from them, and an adopted child keeps the
# view's own. Progress stays the source child's, as for any view reading it.
const _CHILD_CONTEXT_SEEDS = (:__status__, :__req__, :__prefix__)
_child_context_seed(child) = let seed = getfield(child, :cache).seed
    (; (name => seed[name] for name in (:__req__, :__prefix__) if haskey(seed, name))...)
end

# Detach the progress node the view's constructor call made for the child it
# adopts in place of `fresh`: a view whose progress tree is the retained root's
# would otherwise leave one running node there per request.
_discard_progress!(fresh, settled) = begin
    node = get(getfield(fresh, :cache).seed, :__status__, nothing)
    node === get(getfield(settled, :cache).seed, :__status__, nothing) || _finalize_substatus!(node)
    nothing
end

# Whether `fresh`, built by a view's own constructor call, and the source's
# `settled` child were constructed alike: the same type, fixed fields and
# creation kwargs, where `__parent__` names the view and the source respectively.
function _same_construction(fresh, settled, view, source)
    T = typeof(fresh)
    typeof(settled) === T || return false
    for name in fieldnames(T)[1:end-1]
        _same_input(getfield(fresh, name), getfield(settled, name)) || return false
    end
    a, b = getfield(fresh, :cache).seed, getfield(settled, :cache).seed
    names = Set{Symbol}(name for name in keys(a) if !(name in _CHILD_CONTEXT_SEEDS))
    names == Set{Symbol}(name for name in keys(b) if !(name in _CHILD_CONTEXT_SEEDS)) ||
        return false
    all(names) do name
        name === :__parent__ ? a[name] === view && b[name] === source : _same_input(a[name], b[name])
    end
end
_same_input(a, b) = a === b || isequal(a, b)

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
`__req__`, or `__prefix__`. They, every transitive dependent in `meta(T)`,
progress state, and nested child are routed to a fresh mount-local cache. Each
mounted `IndexableProperty` wrapper is recreated with the mounted owner; its
per-argument cache is shared only when the property is context-independent.
Context-dependent `@cached`/`@mmap` properties bypass their intrinsic disk entry
because the rebound context is intentionally not part of the retained disk
identity.

What reads a nested child is decided by the read. Reading a member of a memoized
inline `@struct` child, `pins.ap3`, makes a property per view only when that member
reaches rebound context, directly, through a forwarded parent name, or through a
nested child; otherwise the property is shared like any other. Holding the child
itself (`f(pins)`) is per view, because the instance holds its view, and so is
reading an opaque member.

An opaque property — one that hands a bare `__self__` to code the dependency
scan cannot follow, such as `fit(key) = run(__self__, key)` — and its dependents
are decided by what they actually read. Views that rebind the same context
names share one computation of each such key, including an in-flight one, so a
poll from a later view awaits the first view's work. That computation receives
a guarded `__self__`: reading rebound context through it (or anything derived
from that context) makes the key context-dependent, so the requesting view keeps
the value it computed and every other view, now and later, computes the key
itself. A shared value that retained its `__self__` cannot read request context
through it afterwards (`RemountSharedContextError`). The retained
object's own computations stay separate from its views'.

A nested child instance is view-local because it holds its parent, but its own
cache is shared: the view's child is the retained source's child remounted onto
the view. A memoized inline `@struct` child read first through a view is
realized on the retained source, so later views reuse it and its settled and
in-flight work; a `@fresh` child stays a fresh view-local child per call. An
external `@include` child is what its constructor call builds under the view:
the view runs that call on first access and reuses the retained source's
settled child only when both calls passed the same arguments (the parent and
request-scoped `__status__`, `__req__` and `__prefix__` aside), so a constructor
argument derived from rebound context gives the view its own child. Inside the remounted
child, a `__parent__.<name>` alias (every bare parent name an inline child
reads) of a parent property the view shares is still shared, so child work
built on context-independent parent state is reused too.

Fixed fields, `@versioned` properties, and cache/hash/path dunders are rejected:
changing any of those means the object identity changed, so use `remake`.

"""
function _remount_impl(obj, nt::NamedTuple, forced_local=(), parent_view=nothing,
                      local_seed::NamedTuple=(;))
    source, shared = _remount_source(obj)
    changed = keys(nt)
    _validate_remount_keys(source, changed)
    # `local_seed` is internal view-local construction state (`_remount_child`'s
    # progress node). It is not a declared property, so it skips validation, but
    # like forced keys it is view-specific: local and invalidated.
    invalidated, local_names, opaque, aliases = _remount_partition(source, shared, changed,
        (forced_local..., keys(local_seed)...), parent_view)
    # Views rebinding the same context share one namespace for their opaque work.
    namespace = isempty(opaque) ? nothing :
        _opaque_namespace(shared, setdiff(invalidated, opaque))
    seed = merge(nt, local_seed)
    mounted = MountedThreadsafeDict(shared, source, local_names, invalidated, seed,
                                    opaque, namespace, aliases)
    # The request context is this view's creation input: record it as the
    # seed so `clear_mem_caches!` on the view restores it into the overlay.
    pc = PropertyCache(mounted, seed)
    T = typeof(source)
    fixed = fieldnames(T)[1:end-1]
    args = Any[getfield(source, name) for name in fixed]
    applicable(T, _REMOUNT_TOKEN, pc, args...) || error(
        "remount: $(nameof(T)) was expanded before remount support; re-expand its @dynamicstruct/@htmx definition")
    T(_REMOUNT_TOKEN, pc, args...)
end

function remount(obj; kwargs...)
    _remount_impl(obj, values(kwargs))
end
@doc (@doc _remount_impl) remount

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
`PropertyComputationError` wrappers to find the root cause exception. For a
computation that ran in a worker process (`configure_queue!(; workers=1)`) that
is the worker's exception itself, of its type and with its fields. An exception
that could not cross returns a `DynamicObjects.RemoteComputationError` holding
the worker's printout, which says why.
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

include("structure.jl")

include("reflection.jl")

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
        owner.active += 1
        owner.last_access = time()
        owner
    end
end

# The root's cache directory is claimed only when an automatic value is about
# to be written into it. An execution that stores nothing — a fresh request
# root, a callback-form operation, a memory-tier result — must not create the
# directory or its marker: the default `__cache_base__` is relative to the
# process cwd, and a claim made by an owner that never stores would contest the
# directory against a later owner that does.
function _claim_materialization_root!(owner::_MaterializationOwner, root)
    path = _materialization_identity(root).path
    lock(_MATERIALIZATION_OWNERS_LOCK) do
        _claim_materialization_path!(owner, path)
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

function _with_materialization_owner(f::F, context::NamedTuple, root) where {F}
    owner = _begin_materialization!(context, root)
    try
        f(owner)
    finally
        _end_materialization!(owner)
    end
end

function _execute_materialization_target(target, name::Symbol, descriptor,
        args, kwargs::NamedTuple, fetch)
    if descriptor.indexed
        return fetch === Base.fetch ?
            getproperty(target, name)(args...; kwargs...) :
            getproperty(target, name)(args...; fetch, kwargs...)
    end
    fetch === Base.fetch || error(
        "non-indexed property `$name` does not accept a fetch selector")
    (isempty(args) && isempty(kwargs)) || error(
        "non-indexed property `$name` does not accept operation arguments")
    getproperty(target, name)
end

function _timed_materialization_target(target, name::Symbol, descriptor,
        args, kwargs::NamedTuple, fetch)
    # This is the same compiler counter Base.@time uses. Its enable/disable
    # operations nest, so concurrent/nested governed executions do not turn
    # collection off underneath one another.
    Base.cumulative_compile_timing(true)
    compile_started = first(Base.cumulative_compile_time_ns())
    wall_started = time_ns()
    try
        value = _execute_materialization_target(
            target, name, descriptor, args, kwargs, fetch)
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

function _automatic_materialization_eligible(owner::_MaterializationOwner,
        target, name::Symbol, descriptor)
    owner.retention === nothing && return false
    descriptor.fixed && return false
    descriptor.output.materialization.tier === :automatic || return false
    !_remount_invalidated(target, name)
end

_automatic_materialization_owned(owner::_MaterializationOwner,
        path::AbstractString) =
    any(owner.owned_paths) do (root, marker)
        _read_materialization_marker(marker) == owner.id &&
            _materialization_path_within(root, path)
    end

_automatic_materialization_allowed(owner::_MaterializationOwner,
        target, name::Symbol, descriptor, path::AbstractString) =
    _automatic_materialization_eligible(owner, target, name, descriptor) &&
        _automatic_materialization_owned(owner, path)

function _automatic_materialization_slot(target, name::Symbol, descriptor,
        args, kwargs::NamedTuple)
    if descriptor.indexed
        property = getproperty(target, name)
        property isa IndexableProperty || return nothing
        return property.cache, _memo_key(Tuple(args), kwargs)
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

# Replace the memory value of `name(args...; kwargs...)` with `replacement` — or drop it
# (`_missing_sentinel`) so it reloads from disk — only while it still holds `value`.
# Returns whether it did (`true` when the slot cannot be located: nothing to guard).
function _swap_automatic_slot!(target, name, descriptor, args, kwargs, value, replacement)
    slot = _automatic_materialization_slot(target, name, descriptor, args, kwargs)
    slot === nothing && return true
    cache, key = slot
    swap() = begin
        _holds_value(cache, key, value) || return false
        if replacement === _missing_sentinel
            maybepop!(cache, key)
        elseif replacement !== value
            if cache isa AbstractThreadsafeDict
                cache.cache[key] = replacement
                _on_store!(cache, key)
            else
                cache[key] = replacement
            end
        end
        true
    end
    cache isa AbstractThreadsafeDict ? lock(swap, cache.lock) : swap()
end

_holds_value(cache, key, value) = get(cache, key, _missing_sentinel) === value
_holds_value(cache::AbstractThreadsafeDict, key, value) =
    get(cache.cache, key, _missing_sentinel) === value
# On a remount view a bare opaque value is shared through the view's namespace, not the
# retained object's cache (a context-dependent one, held by the view alone, is not shared).
_holds_value(cache::MountedThreadsafeDict, key::Symbol, value) =
    key in cache.opaque && cache.namespace !== nothing ?
        get(cache.namespace.cache, key, _missing_sentinel) === value :
        get(cache.cache, key, _missing_sentinel) === value

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

# Automatic storage may change where a value lives, never its type: a reload
# must have exactly the computed value's type. Metadata records that type at
# write time, and an entry that reloads as anything else is deleted so the
# caller recomputes. A legacy mmap entry written before the type was recorded
# may hold a densified wrapper, so it is not trusted either; legacy serialized
# entries are, since serialization round-trips types. A usable value comes back
# wrapped in `Some` so a stored `nothing` stays distinguishable from "unusable".
function _read_automatic_materialization!(metadata, cache_path)
    expected = get(metadata, :value_type, nothing)
    value = try
        expected === nothing && metadata.format === :mmap ? nothing :
            Some(load(Val(metadata.format), cache_path, nothing))
    catch e
        _drop_automatic_materialization!(cache_path)
        @warn "Automatic materialization cache read failed; deleting it and recomputing" cache_path exception=e
        return nothing
    end
    if value === nothing ||
            (expected !== nothing && typeof(something(value)) !== expected)
        _drop_automatic_materialization!(cache_path)
        @warn "Automatic materialization entry does not reload as its computed type; deleting it and recomputing" cache_path recorded_type=expected
        return nothing
    end
    value
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
        read = _read_automatic_materialization!(metadata, cache_path)
        read === nothing && return nothing
        value = something(read)
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
    # Memory-mapping pays off only for a large value: pages load lazily and are
    # shared through the OS page cache instead of copied into the heap. A small
    # value promoted only for being slow is read back whole either way, and a
    # mapping per tiny file just costs mapping slots, so it serializes.
    format = large && _automatic_mmap_eligible(value) ? :mmap : :serial
    (;tier=format === :mmap ? :mmap : :serialized, format, estimated_bytes)
end

function _persist_automatic_materialization!(owner, root, target, name,
        descriptor, args, kwargs::NamedTuple, value, elapsed_seconds)
    _automatic_materialization_eligible(owner, target, name, descriptor) ||
        return value
    choice = _automatic_materialization_choice(value, elapsed_seconds)
    choice.format === nothing && return value
    # A value an invalidation dropped, or whose computation it retracted, is stale: not
    # persisted, and the memory slot is replaced or dropped only while it still holds it.
    holds() = _swap_automatic_slot!(target, name, descriptor, args, kwargs, value, value)
    holds() || return value
    cache_path = get_cache_path(target, name, args...; kwargs...)
    _claim_materialization_root!(owner, root)
    _automatic_materialization_owned(owner, cache_path) || return value
    path_lock = get_path_lock!(
        _AUTOMATIC_MATERIALIZATION_DISK_LOCKS, cache_path)
    lock(path_lock) do
        existing = _automatic_materialization_metadata(cache_path)
        if existing !== nothing && get_cache_status(cache_path) === :ready
            read = _read_automatic_materialization!(existing, cache_path)
            if read !== nothing
                if existing.format === :mmap
                    stored = something(read)
                    _swap_automatic_slot!(
                        target, name, descriptor, args, kwargs, value, stored) || return value
                    return stored
                end
                _swap_automatic_slot!(
                    target, name, descriptor, args, kwargs, value, _missing_sentinel)
                return value
            end
        end

        metadata_path = _automatic_materialization_path(cache_path)
        try
            holds() || return value
            mkpath(dirname(cache_path))
            format = choice.format
            stored = nothing
            if format === :mmap
                _atomic_save(Val(:mmap), cache_path, value)
                stored = load(Val(:mmap), cache_path, nothing)
                if typeof(stored) !== typeof(value)
                    # The type's mmap format does not round-trip this value's
                    # exact type (e.g. a `TreeData` whose leaves are views).
                    # Serialization does, so use it; warn once per type pair.
                    @warn "Automatic mmap would reload $(typeof(value)) as $(typeof(stored)); serializing instead" cache_path _id=hash((typeof(value), typeof(stored))) maxlog=1
                    finalize(stored)   # unmap before replacing the file
                    stored = nothing
                    format = :serial
                end
            end
            format === :serial && _atomic_save(Val(:serial), cache_path, value)
            metadata = (;
                format,
                estimated_bytes=choice.estimated_bytes,
                compute_seconds=elapsed_seconds,
                value_type=typeof(value),
            )
            _atomic_save(Val(:serial), metadata_path, metadata)
            # Invalidated while saving: the entry would outlive the invalidation.
            if !_swap_automatic_slot!(target, name, descriptor, args, kwargs, value,
                    format === :mmap ? stored : _missing_sentinel)
                stored === nothing || finalize(stored)   # unmap before removing the file
                _drop_automatic_materialization!(cache_path)
                return value
            end
            format === :mmap && return stored
        catch e
            _drop_automatic_materialization!(cache_path)
            @warn "Automatic materialization persistence failed; keeping the computed value in memory" cache_path exception=e
        end
        value
    end
end

"""
    execute_materialization(f, context, root)
    execute_materialization(context, root) do
        # explicitly selected DynamicObjects access mode
    end
    execute_materialization(context, root, target, property, args...; kwargs...)
    execute_materialization(context, object, property, args...; kwargs...)

Execute a DynamicObjects property under framework-owned storage governance.
`context` is the pure-data `(; scope, key, retention)` record supplied by a
semantic host; ordinary applications call their operations normally and never
construct a store. `root` is the retained application root and `target` is the
mounted object that owns `property`.
For indexed properties, `fetch` selects synchronous or deferred execution;
it reaches the property cache without entering the application argument key
or automatic storage path.

The executor adds an active lease around the existing DO property machinery.
For an ordinary property on a retained root it observes the actual result and
automatically keeps small/cheap values in memory, serializes large or expensive
values, and memory-maps large plain `Array`s of supported isbits eltypes. Fresh
request roots recompute across requests. The root's cache directory and its
ownership marker are created only when a value is actually written to disk, so
an execution that stores nothing — any fresh request root, the callback form, a
result kept in memory — touches no files. Existing `@fresh`, `@cached`, and
`@mmap` declarations remain compatibility overrides; applications do not need
them for governed execution.

Governance covers exactly the executed `property` on `target`. Properties it
reads while computing — siblings, nested DO objects, `@struct` children — run
through their ordinary declaration-site semantics and are never automatically
promoted; only the executed property's own returned value is observed.

The callback form applies the same active lease and root ownership while
leaving value access to the semantic host. It performs no automatic storage
read or write itself. Hosts use it with an explicit access mode such as
`fresh(property, args...)` or `maybeprogress!(progress, property, args...)`
when one operation must recompute without changing the property's declaration
or its ordinary memoized value. The callback's return value is passed through,
and its lease is released even if the callback throws.
"""
function execute_materialization(f::F, context::NamedTuple, root) where {F}
    _with_materialization_owner(context, root) do _
        f()
    end
end

function execute_materialization(context::NamedTuple, root, target,
        name::Symbol, args...; fetch=Base.fetch, kwargs...)
    descriptor = property_descriptor(typeof(target), name)
    descriptor === nothing && error(
        "$(typeof(target)) has no DynamicObjects property `$name`")
    _with_materialization_owner(context, root) do owner
        property_kwargs = (;kwargs...)
        automatic = _load_automatic_materialization!(
            owner, target, name, descriptor, args, property_kwargs)
        if automatic !== nothing
            value = _execute_materialization_target(
                target, name, descriptor, args, property_kwargs, fetch)
            automatic.tier === :serialized &&
                _clear_automatic_materialization_cache!(
                    target, name, descriptor, args, property_kwargs)
            return value
        end
        timed = _timed_materialization_target(
            target, name, descriptor, args, property_kwargs, fetch)
        _persist_automatic_materialization!(owner, root, target, name,
            descriptor, args, property_kwargs, timed.value,
            timed.elapsed_seconds)
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

# --- tracked file values and in-place invalidation -----------------------------
#
# A file-backed input needs no marker at its declaration site. It is an ordinary
# property whose VALUE is a `TrackedFile` or a `TrackedDirectory`; each owns its
# lock, its version and its observers, and reading it polls the filesystem, so a
# change made by another process is observed without a watcher. `sync!` turns an
# observed change into cache invalidation for exactly the properties that read the
# changed value — transitively, through nested objects and indexed entries.
#
# Version-and-sync rather than a push from the write site: a file another process
# rewrote has no write site in this one, and a tracked value cannot know which
# objects hold it. Comparing one number per tracked value at a request boundary
# leaves the property read path untouched.
#
# This is in-place invalidation. `remake`/`remount` build a NEW object and carry
# over the entries a change provably cannot affect; `sync!` keeps the object and
# drops the entries a tracked value provably CAN affect, using the same
# `dependson` graph inverted.

mutable struct _TrackedState
    lock::ReentrantLock
    version::UInt64
    # The version at the value's first observation, 0 until then. Every reader saw
    # at least this version, so it is the baseline `sync!` compares against for a
    # holder it has not stamped yet: a change landing between a dependent's compute
    # and the holder's first sync is a change, never "nothing to compare against".
    observed::UInt64
    observers::Vector{Any}
end

# Set when the first tracked value is constructed, or when an invalidation
# (`clear_cache!`, `clear_mem_caches!`) first moves an object's version
# (`_version_moved!`). Until then no `sync!` can observe anything (object
# versions move only through those drops), so it returns at once and an
# application that uses none of them pays nothing.
const _TRACKED_IN_USE = Threads.Atomic{Bool}(false)

function _TrackedState()
    _TRACKED_IN_USE[] = true
    _TrackedState(ReentrantLock(), UInt64(1), UInt64(0), Any[])
end

# Bump under the lock, notify outside it: an observer that reads the value it was
# notified about must not deadlock against the writer, and a throwing observer
# must not undo a change that already happened.
function _bump!(state::_TrackedState)
    version, observers = lock(state.lock) do
        state.version += UInt64(1)
        state.version, copy(state.observers)
    end
    for observer in observers
        try
            observer()
        catch err
            @error "tracked-value observer threw; the change it was told about already happened" exception=(err, catch_backtrace())
        end
    end
    version
end

_note_observed!(state::_TrackedState) = lock(state.lock) do
    state.observed == 0 && (state.observed = state.version)
    nothing
end

"""
    TrackedFile(path; read=Base.read, version=:mtime)

One file, observed rather than re-read.

`read(file)` returns `read(path)`'s result, memoized until the file changes. Pass
`read=JSON.parsefile` (any `path -> value`) to track parsed content instead of
bytes. `version` selects the change probe, run on every access:

- `:mtime` — one `stat`; the stamp is the file's mtime, ctime, size and inode, so
  an in-place rewrite and an atomic replace (a new inode) both register;
- `:hash` — the hash of the file's bytes (reads the file; exact);
- `:git` — the file's git blob id, falling back to `:hash` without git.

A missing file is not an error: it stamps as absent, has a stable version, and
starts producing changes when it appears. `read` on a missing file throws, as
`Base.read` would.

There is no watcher: the probe runs when someone reads the file or asks for its
[`tracked_version`](@ref) — [`sync!`](@ref) does, once per call.
"""
mutable struct TrackedFile
    state::_TrackedState
    path::String
    reader::Any
    probe::Symbol
    stamp::String
    value::Any
    has_value::Bool
end
function TrackedFile(path::AbstractString; read=Base.read, version::Symbol=:mtime)
    _check_tracked_probe(version, "TrackedFile")
    TrackedFile(_TrackedState(), String(path), read, version, "", nothing, false)
end

"""
    TrackedDirectory(path; match=Returns(true), key=path -> Symbol(basename(path)),
                     read=identity, version=:mtime)

The entries of one directory, as an `AbstractDict` that observes membership and
content as ONE version: an entry appearing, disappearing or changing all move
[`tracked_version`](@ref) the same way, so a listing never disagrees with the
contents.

`match` filters absolute entry paths (`isdir` selects subdirectories), `key`
names each entry, and `read` turns a path into the value — the default
`identity` yields the path. Values are memoized per entry and dropped only for
entries that changed; a value that is itself a `@dynamicstruct` object (e.g.
`read = path -> Run(; path)`) is reached by [`sync!`](@ref), so tracked files
inside it are observed too.

Each matched entry is probed like a [`TrackedFile`](@ref). A subdirectory's
`:mtime` stamp moves when an entry inside it is added, removed or renamed (an
atomic write-and-rename included), not when a nested file is rewritten in place:
track a nested file you rewrite in place with its own `TrackedFile`. A missing
directory is empty, not an error. Keys iterate in sorted path order.
"""
mutable struct TrackedDirectory <: AbstractDict{Any,Any}
    state::_TrackedState
    path::String
    match::Any
    key::Any
    reader::Any
    probe::Symbol
    stamps::Dict{String,String}
    order::Vector{Any}
    paths::Dict{Any,String}
    values::Dict{Any,Any}
end
function TrackedDirectory(path::AbstractString;
        match=Returns(true), key=path -> Symbol(basename(path)),
        read=identity, version::Symbol=:mtime)
    _check_tracked_probe(version, "TrackedDirectory")
    TrackedDirectory(_TrackedState(), String(path), match, key, read, version,
        Dict{String,String}(), Any[], Dict{Any,String}(), Dict{Any,Any}())
end

const TrackedValue = Union{TrackedFile,TrackedDirectory}

_check_tracked_probe(version::Symbol, what) = version in (:mtime, :hash, :git) ||
    throw(ArgumentError("$what: unknown version probe `$(repr(version))` — use :mtime, :hash or :git."))

# What a probe stamps. A directory (a TrackedDirectory entry selected by `isdir`)
# is stamped by its metadata whatever the probe: there are no bytes to hash.
function _tracked_stamp(path::AbstractString, probe::Symbol)
    info = stat(path)
    ispath(info) || return ""
    if probe === :mtime || isdir(info)
        string(info.mtime, ':', info.ctime, ':', info.size, ':', info.inode)
    else
        file_version(path; by=probe)
    end
end

_tracked_state(t::TrackedValue) = t.state

function _poll!(f::TrackedFile)
    stamp = _tracked_stamp(f.path, f.probe)
    changed = lock(f.state.lock) do
        stamp == f.stamp && return false
        f.stamp = stamp
        f.value = nothing
        f.has_value = false
        true
    end
    changed && _bump!(f.state)
    _note_observed!(f.state)
    nothing
end

function _poll!(d::TrackedDirectory)
    entries = isdir(d.path) ? sort!(readdir(d.path; join=true)) : String[]
    matched = filter(d.match, entries)
    stamps = Dict{String,String}(path => _tracked_stamp(path, d.probe) for path in matched)
    changed = lock(d.state.lock) do
        stamps == d.stamps && return false
        # Keep the memoized value of every entry that did not change; drop the
        # ones that did and the ones that are gone.
        for (key, path) in d.paths
            get(stamps, path, nothing) == get(d.stamps, path, nothing) || delete!(d.values, key)
        end
        d.stamps = stamps
        d.order = Any[d.key(path) for path in matched]
        d.paths = Dict{Any,String}(d.key(path) => path for path in matched)
        keep = Set{Any}(d.order)
        for key in collect(keys(d.values))
            key in keep || delete!(d.values, key)
        end
        true
    end
    changed && _bump!(d.state)
    _note_observed!(d.state)
    nothing
end

"""
    tracked_version(x) -> Union{UInt64,Nothing}

Observable version of a [`TrackedFile`](@ref) or [`TrackedDirectory`](@ref), or
`nothing` for a value that is not tracked. Polls the filesystem first.

Monotone: any observed change produces a strictly greater number. Equal versions
mean "nothing this value can see has changed"; the number is not comparable
across values.
"""
tracked_version(::Any) = nothing
tracked_version(t::TrackedValue) = (_poll!(t); lock(t.state.lock) do; t.state.version; end)

"""
    tracked_path(tracked) -> String

The path a [`TrackedFile`](@ref) or [`TrackedDirectory`](@ref) observes. A
different path is a different tracked value, not a mutation of this one.
"""
tracked_path(t::TrackedValue) = t.path

"""
    on_change!(f, tracked) -> f

Register a zero-argument `f` to run after `tracked` changes — when a poll
observes a change, or on [`notify_change!`](@ref).

Runs outside the value's lock, so `f` may read the value. A throwing `f` is
logged with its backtrace and skipped: the change already happened. Observers
are never removed; register them once, at wiring time. This is the push
counterpart to [`sync!`](@ref)'s poll, and it fires only when something polls.
"""
function on_change!(f, tracked)
    state = _tracked_state(tracked)
    lock(state.lock) do
        push!(state.observers, f)
    end
    f
end

"""
    notify_change!(tracked) -> UInt64

Bump `tracked`'s version and run its observers, returning the new version.

For a writer that knows it changed a file and does not want to rely on the
probe — a rewrite that preserves size within one mtime tick, for instance. The
next [`sync!`](@ref) drops everything derived from `tracked`, and a memoized
`read` is dropped too, so the next read re-reads the file.
"""
function notify_change!(t::TrackedValue)
    lock(t.state.lock) do
        _forget_contents!(t)
    end
    _bump!(t.state)
end
_forget_contents!(f::TrackedFile) = (f.value = nothing; f.has_value = false; nothing)
_forget_contents!(d::TrackedDirectory) = (empty!(d.values); nothing)

"""
    read(file::TrackedFile)

The file's content through its reader, memoized until the file changes. Polls
first, so a change since the last read is picked up here.
"""
function Base.read(f::TrackedFile)
    _poll!(f)
    lock(f.state.lock) do
        f.has_value && return f.value
        # Under the lock: two tasks must not both run the reader and disagree about
        # which result is the memoized one.
        f.value = f.reader(f.path)
        f.has_value = true
        f.value
    end
end
Base.stat(f::TrackedFile) = stat(f.path)
Base.isfile(f::TrackedFile) = isfile(f.path)
Base.ispath(f::TrackedFile) = ispath(f.path)
Base.show(io::IO, f::TrackedFile) =
    print(io, "TrackedFile(", repr(f.path), "; version=", repr(f.probe), ")")
Base.show(io::IO, ::MIME"text/plain", f::TrackedFile) = show(io, f)

Base.length(d::TrackedDirectory) = (_poll!(d); lock(d.state.lock) do; length(d.order); end)
Base.isempty(d::TrackedDirectory) = length(d) == 0
# `identity.` narrows the element type to what `key` produced (`Vector{Symbol}`).
Base.keys(d::TrackedDirectory) = (_poll!(d); lock(d.state.lock) do; identity.(d.order); end)
Base.haskey(d::TrackedDirectory, key) = (_poll!(d); lock(d.state.lock) do; haskey(d.paths, key); end)
Base.stat(d::TrackedDirectory) = stat(d.path)
Base.isdir(d::TrackedDirectory) = isdir(d.path)

function Base.getindex(d::TrackedDirectory, key)
    _poll!(d)
    lock(d.state.lock) do
        haskey(d.values, key) && return d.values[key]
        haskey(d.paths, key) || throw(KeyError(key))
        d.values[key] = d.reader(d.paths[key])
    end
end
Base.get(d::TrackedDirectory, key, default) = haskey(d, key) ? d[key] : default
Base.values(d::TrackedDirectory) = [d[key] for key in keys(d)]

"""
    tracked_paths(dir::TrackedDirectory) -> Dict

Each key's path, for a consumer that needs the entry rather than its value.
"""
tracked_paths(d::TrackedDirectory) = (_poll!(d); lock(d.state.lock) do; copy(d.paths); end)

# Sorted-key snapshot, then a read per key: an entry appearing mid-sweep does not
# change what this sweep yields.
function Base.iterate(d::TrackedDirectory)
    snapshot = keys(d)
    isempty(snapshot) && return nothing
    (snapshot[1] => d[snapshot[1]]), (snapshot, 2)
end
function Base.iterate(d::TrackedDirectory, state::Tuple{Vector,Int})
    snapshot, i = state
    i > length(snapshot) && return nothing
    (snapshot[i] => d[snapshot[i]]), (snapshot, i + 1)
end

Base.show(io::IO, d::TrackedDirectory) =
    print(io, "TrackedDirectory(", repr(d.path), "; version=", repr(d.probe), ")")
Base.show(io::IO, ::MIME"text/plain", d::TrackedDirectory) = show(io, d)

include("invalidation.jl")

# --- Walking and pruning in-memory caches --------------------------------------------------
#
# `mem_cache_entries` lists what a graph of objects holds in memory; `prune_mem_caches!` evicts
# the derived entries a caller does not want kept. Eviction is not invalidation: an evicted
# value is still correct, so nothing derived from it is dropped, no disk entry is touched and
# `object_version` does not move. The next read recomputes it, or reloads an explicit
# `@cached`/`@mmap` entry from disk.

"""
    DynamicObjects.MemCacheEntry

The element type of [`mem_cache_entries`](@ref): a `NamedTuple`
`(; object, property, key, value, path, role)`.
"""
const MemCacheEntry = NamedTuple{(:object, :property, :key, :value, :path, :role),
                                 Tuple{Any,Symbol,Any,Any,Tuple,Symbol}}

# Where a listed entry is stored: the dictionaries `lock` guards (a `ThreadsafeDict`'s own,
# or a remount view's overlay) and the key the entry is stored under there.
struct _MemSlot
    lock::ReentrantLock
    cache::AbstractDict
    computing::AbstractDict
    status::AbstractDict
    key::Any
end

# The walk: objects still to visit (each queued once, with its path), the entries of the one
# being listed, and every property cache and subcache already queued or listed.
mutable struct _MemWalk
    const queue::Vector{Tuple{Any,Tuple}}
    head::Int
    const entries::Vector{Tuple{MemCacheEntry,_MemSlot}}
    next::Int
    const seen::Base.IdSet{Any}
    objects::Int
end

function _mem_walk(root, caller::Symbol)
    _is_dynamic_object(root) ||
        throw(ArgumentError("$caller: $(typeof(root)) is not a @dynamicstruct object"))
    walk = _MemWalk(Tuple{Any,Tuple}[], 1, Tuple{MemCacheEntry,_MemSlot}[], 1, Base.IdSet{Any}(), 0)
    _enqueue!(walk, root, ())
    walk
end

function _enqueue!(walk::_MemWalk, o, path::Tuple)
    pc = getfield(o, :cache)
    pc in walk.seen && return nothing
    push!(walk.seen, pc)
    push!(walk.queue, (o, path))
    nothing
end

# The next `(entry, slot)`, listing the next queued object when the current one is done.
function _next_entry!(walk::_MemWalk)
    while walk.next > length(walk.entries)
        walk.head > length(walk.queue) && return nothing
        o, path = walk.queue[walk.head]
        walk.queue[walk.head] = (nothing, ())
        walk.head += 1
        empty!(walk.entries)
        walk.next = 1
        _visit!(walk, o, path)
    end
    item = walk.entries[walk.next]
    walk.next += 1
    item
end

function _visit!(walk::_MemWalk, o, path::Tuple)
    walk.objects += 1
    pc = getfield(o, :cache)
    c = pc.cache
    T = typeof(o)
    roles = (; inputs=keys(pc.seed), state=_state_names(T), versions=_computed_version_names(T))
    if c isa MountedThreadsafeDict
        # A view serves its retained object's entries, except the ones it holds itself.
        _enqueue!(walk, c.source, path)
        _visit_store!(walk, o, path, (c.lock, c.cache.overlay, c.computing.overlay, c.status.overlay), roles)
    elseif c isa ThreadsafeDict
        _visit_store!(walk, o, path, (c.lock, c.cache, c.computing, c.status), roles)
        # The opaque work this object's remount views share is held here.
        for ns in _remount_namespaces(c)
            shared = ns.cache
            _visit_store!(walk, o, path, (shared.lock, shared.cache, shared.computing, shared.status), roles)
            for (name, sub) in lock(() -> collect(ns.subcaches), ns.lock)
                _visit_subcache!(walk, o, path, name, sub, _indexed_role(roles, name))
            end
        end
    else
        throw(ArgumentError("mem_cache_entries: $T uses unsupported cache $(typeof(c))"))
    end
    nothing
end

# A computation in flight is not an entry: its key is skipped until it settles.
function _visit_store!(walk::_MemWalk, o, path::Tuple, (lk, cache, computing, status), roles)
    settled = lock(lk) do
        Pair{Any,Any}[name => value for (name, value) in cache if !haskey(computing, name)]
    end
    for (name, value) in settled
        if _own_wrapper(o, name, value)
            # The wrapper stays: holders share its subcache. Its entries are listed instead.
            _visit_subcache!(walk, o, path, name, value.cache, _indexed_role(roles, name))
        else
            entry = MemCacheEntry((o, name, nothing, value, path, _bare_role(roles, name)))
            _push_entry!(walk, entry, _MemSlot(lk, cache, computing, status, name))
        end
    end
    nothing
end

function _visit_subcache!(walk::_MemWalk, o, path::Tuple, name::Symbol, sub, role::Symbol)
    # A view's opaque subcache: its shared half is the retained object's namespace subcache.
    sub isa _OpaqueSubcache && return _visit_subcache!(walk, o, path, name, sub.local_dict, role)
    sub isa ThreadsafeDict || throw(ArgumentError(
        "mem_cache_entries: indexed property `$name` of $(typeof(o)) uses unsupported subcache $(typeof(sub))"))
    sub in walk.seen && return nothing
    push!(walk.seen, sub)
    settled = lock(sub.lock) do
        Pair{Any,Any}[key => value for (key, value) in sub.cache if !haskey(sub.computing, key)]
    end
    for (key, value) in settled
        entry = MemCacheEntry((o, name, _plain_key(key), value, path, role))
        _push_entry!(walk, entry, _MemSlot(sub.lock, sub.cache, sub.computing, sub.status, key))
    end
    nothing
end

# Objects held by derived values and state are walked next; inputs (`__parent__` among them)
# and DO's own entries are not followed.
function _push_entry!(walk::_MemWalk, entry::MemCacheEntry, slot::_MemSlot)
    push!(walk.entries, (entry, slot))
    entry.role in (:derived, :state) || return nothing
    path = (entry.path..., (entry.property, entry.key))
    _foreach_held_object(held -> _enqueue!(walk, held, path), entry.value)
    nothing
end

function _bare_role(roles, name::Symbol)
    name in roles.inputs && return :input
    _indexed_role(roles, name)
end
function _indexed_role(roles, name::Symbol)
    name in roles.state && return :state
    (_is_dunder(name) || name in roles.versions) && return :internal
    :derived
end

_is_dunder(name::Symbol) = (s = String(name); ncodeunits(s) > 4 && startswith(s, "__") && endswith(s, "__"))

# The objects a cached value holds, by the rule `sync!` reaches nested objects with: the value
# itself, the memoized values of a `TrackedDirectory`, or either as an element of an array,
# tuple or dict (one level). A `TrackedFile`'s memoized read is data and is not followed.
function _foreach_held_object(f, value)
    if _is_dynamic_object(value) || value isa TrackedValue
        _foreach_held_element(f, value)
    else
        foreach(element -> _foreach_held_element(f, element), _container_elements(value))
    end
    nothing
end
_foreach_held_element(f, value) = (_is_dynamic_object(value) && f(value); nothing)
function _foreach_held_element(f, d::TrackedDirectory)
    memoized = lock(() -> collect(values(d.values)), d.state.lock)
    foreach(value -> _is_dynamic_object(value) && f(value), memoized)
    nothing
end

# Evict `value` from its slot unless the slot moved on since it was listed: a computation
# started there, or it now holds a different value.
function _evict!(slot::_MemSlot, value)
    lock(slot.lock) do
        haskey(slot.computing, slot.key) && return false
        get(slot.cache, slot.key, _missing_sentinel) === value || return false
        delete!(slot.cache, slot.key)
        delete!(slot.status, slot.key)
        true
    end
end

"""
    mem_cache_entries(root)

Iterate the settled in-memory cache entries of `root` and of every `@dynamicstruct` object it
derived, without computing anything. Each element is a `DynamicObjects.MemCacheEntry`
`(; object, property, key, value, path, role)`:

- `object`: the object holding the entry, `property` its property name, `value` the
  memoized value;
- `key`: `nothing` for a bare property, `(args, kwargs)` for an indexed-property entry (as
  [`cached_entries`](@ref) reports it);
- `path`: how the walk reached `object` from `root`, one `(property, key)` step per entry that
  held the next object; `()` for `root`'s own entries;
- `role`, what the entry is to its object:
  - `:derived`: a memoized derivation, which [`prune_mem_caches!`](@ref) may evict;
  - `:input`: a constructor input (`__parent__` wiring, an inline child's index arguments, a
    constructor or [`remake`](@ref) override, a [`remount`](@ref) view's request context);
  - `:state`: an `@state` value;
  - `:internal`: DO's own `__…__` entries (progress root, hash, cache path, `@options`
    domains, …) and computed `@versioned` properties, from which the disk cache path derives.

An indexed property is listed entry by entry, never as its wrapper.

Which objects are walked: `root`, then every `@dynamicstruct` object held by a `:derived` or
`:state` entry, recursively. An entry holds an object directly, as a memoized
`TrackedDirectory` value, or as an element of an array, tuple or dict (one level; deep data
is never walked). Constructor inputs and fixed fields are not followed, so neither
`__parent__` back-references nor objects an object was merely given are walked. Each object
is listed once, so aliases and cycles terminate. `root`'s own entries come first, then
breadth-first.

A [`remount`](@ref) view lists its own entries and walks its retained object, which also
lists the opaque work its views share.

The walk is lazy: each object's entries are read under that object's cache lock when the walk
reaches it, so `first`, `Iterators.take` or a `break` stop it early. A computation in flight
is not an entry.
"""
function mem_cache_entries(root)
    _is_dynamic_object(root) ||
        throw(ArgumentError("mem_cache_entries: $(typeof(root)) is not a @dynamicstruct object"))
    MemCacheEntries(root)
end

# The lazy iterator `mem_cache_entries` returns; each `iterate` from the start walks afresh.
struct MemCacheEntries
    root::Any
end
Base.IteratorSize(::Type{MemCacheEntries}) = Base.SizeUnknown()
Base.eltype(::Type{MemCacheEntries}) = MemCacheEntry
function Base.iterate(entries::MemCacheEntries, walk::_MemWalk=_mem_walk(entries.root, :mem_cache_entries))
    item = _next_entry!(walk)
    item === nothing ? nothing : (first(item), walk)
end
Base.show(io::IO, entries::MemCacheEntries) =
    print(io, "mem_cache_entries(::", typeof(entries.root), ")")

"""
    prune_mem_caches!(keep, root) -> (objects, kept, evicted)

Walk already materialized memory entries and evict derived entries for which
`keep(entry)` is false. The entry record is the same as in
[`mem_cache_entries`](@ref). Inputs, state, progress roots and in-flight work are
kept. The traversal computes nothing and does not force disk or lazy loads.

Eviction leaves disk files and dependency versions unchanged: this is memory
reclamation, not semantic invalidation. Values may still be referenced elsewhere,
so eviction does not guarantee an immediate reduction in process memory.
Removing an indexed value leaves its wrapper attached. Use
[`@clear_cache!`](@ref) when dependents must also be invalidated.
"""
function prune_mem_caches!(keep, root)
    walk = _mem_walk(root, :prune_mem_caches!)
    kept = evicted = 0
    while (item = _next_entry!(walk)) !== nothing
        entry, slot = item
        entry.role === :derived || continue
        if keep(entry)
            kept += 1
        elseif _evict!(slot, entry.value)
            evicted += 1
        end
    end
    (; objects=walk.objects, kept, evicted)
end

export print_structure, structure
export tree_children_map, lint_index, lookup_type, callers_by_name, property_source_info, property_signature, property_doc, LintMessage
export metafirst, metaall
export static_domain, property_descriptor, property_descriptors, type_descriptor,
    option_declarations, has_option_declaration, property_options,
    option_domain, option_records
export declaration_metadata, declaration_graph, declaration_selection, declaration_node_id,
    declaration_observations
export materialization_observation
export with_compute_trace, ComputeTrace, compute_trace_rows
export execute_materialization, release_materialization!, materialization_ownership, materialization_gc!
export TrackedFile, TrackedDirectory, tracked_version, tracked_path, tracked_paths,
    on_change!, notify_change!, sync!, object_version, dependents

include("workers.jl")

include("precompile.jl")

end
