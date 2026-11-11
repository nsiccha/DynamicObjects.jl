# Files

Refresh an object's file-backed values and invalidate their dependents with
`TrackedFile` and `sync!`. Reading an ordinary path string does not establish
this relationship; the dependency is the tracked value read by a property.

## Tracked input

This object retains a tracked file and derives text from it. Hash-based
versioning detects content changes even when file size is unchanged.

```@example files
using DynamicObjects

directory = mktempdir()
path = joinpath(directory, "message.txt")
write(path, "first")

@dynamicstruct struct Message
    path::String
    source = TrackedFile(path; read = path -> read(path, String), version = :hash)
    text = read(source)
    uppercase_text = uppercase(text)
end

message = Message(path)
__docs_output__ = begin # hide
message.uppercase_text
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

A subsequent property read reuses the cached text until the object is
synchronized. `sync!` checks materialized tracked inputs, then drops their
transitive derived values. It does not run every unmaterialized property.

```@example files
write(path, "other")
before = message.uppercase_text
invalidated = sync!(message)
@assert before == "FIRST" && message.uppercase_text == "OTHER" # hide
@assert :text in invalidated && :uppercase_text in invalidated # hide
__docs_output__ = begin # hide
(before = before, after = message.uppercase_text,
 dropped = sort(invalidated))
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

The output distinguishes an unchanged cache read from a read after
synchronization. Use `sync!` at the boundary where your application intends to
observe external changes, such as before rendering a refreshed view. A tracked
file is not a background file watcher.

## Directories

`TrackedDirectory` represents a collection of paths. Its `match`, `key`, and
`read` functions choose which entries participate, how they are named, and how
their values are loaded. A key should uniquely identify an entry.

```@example files
write(joinpath(directory, "second.txt"), "second")

@dynamicstruct struct Library
    path::String
    files = TrackedDirectory(path;
        match = path -> endswith(path, ".txt"), key = basename,
        read = path -> read(path, String), version = :hash)
    names = sort(collect(keys(files)))
end

library = Library(directory)
__docs_output__ = begin # hide
library.names
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

Create, remove, or edit entries, then synchronize the holder before reading
its derived listing. `tracked_paths` and `tracked_version` inspect the tracked
value. [`notify_change!`](@ref) supports an application that already knows an
input changed; [`on_change!`](@ref) registers change listeners.

## Disk identity

Tracked inputs update a retained object's memory values. A disk cache also
needs an identity that distinguishes file contents across object instances
and processes. Declare a computed `@versioned` property with `file_version`
when persisted outputs depend on a file.

```@example files
@dynamicstruct struct StoredMessage
    path::String
    source = TrackedFile(path; read = path -> read(path, String), version = :hash)
    @versioned content_version = file_version(path; by = :hash)
    @cached text = read(source)
end

cache_directory = mktempdir()
first_object = StoredMessage(path; __cache_base__ = cache_directory)
first_text = first_object.text
first_cache = @cache_path first_object.text
write(path, "third")
second_object = StoredMessage(path; __cache_base__ = cache_directory)
@assert first_text == "other" && second_object.text == "third" # hide
@assert first_cache != (@cache_path second_object.text) # hide
__docs_output__ = begin # hide
(first_text = first_text, second_text = second_object.text,
 different_disk_entry = first_cache != (@cache_path second_object.text))
end # hide
show(stdout, MIME"text/plain"(), __docs_output__) # hide
println() # hide
```

A version marker applies to the object's persisted outputs. It does not replace
`sync!` for an instance that is already retained. The default mtime version is
less expensive to probe; hash mode reads the file contents. Choose the mode
that matches how your input files change.

```@example files
rm(directory; recursive = true) # hide
rm(cache_directory; recursive = true) # hide
nothing # hide
```

[Cached signal analysis](../examples/signal.md) shows how to inspect the
recomputation caused by invalidation before introducing external files.
