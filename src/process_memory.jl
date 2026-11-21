# Current process memory, including private pages that have left RAM. A peak
# (such as Sys.maxrss()) cannot tell us whether releasing entries helped.
@static if Sys.isapple()
    # Darwin's fixed RUSAGE_INFO_V0 layout, from <sys/resource.h>.
    struct _RUsageInfoV0
        uuid::NTuple{16,UInt8}
        user_time::UInt64
        system_time::UInt64
        pkg_idle_wkups::UInt64
        interrupt_wkups::UInt64
        pageins::UInt64
        wired_size::UInt64
        resident_size::UInt64
        phys_footprint::UInt64
        proc_start_abstime::UInt64
        proc_exit_abstime::UInt64
    end
    function _process_memory_bytes()
        usage = Ref{_RUsageInfoV0}()
        rc = ccall((:proc_pid_rusage, "/usr/lib/libproc.dylib"), Cint,
                   (Cint, Cint, Ref{_RUsageInfoV0}), getpid(), 0, usage)
        rc == 0 ? Int(usage[].phys_footprint) : nothing
    end
elseif Sys.islinux()
    function _process_memory_bytes()
        try
            open("/proc/self/status") do io
                rss = swap = nothing
                for line in eachline(io)
                    if startswith(line, "VmRSS:")
                        rss = parse(Int, split(line)[2])
                    elseif startswith(line, "VmSwap:")
                        swap = parse(Int, split(line)[2])
                    end
                    if rss !== nothing && swap !== nothing
                        return (rss + swap) * 1024
                    end
                end
                nothing
            end
        catch err
            err isa SystemError || err isa Base.IOError || rethrow()
            nothing
        end
    end
else
    _process_memory_bytes() = nothing
end

# glibc keeps memory that `free` returned in its arenas. Julia's collector
# trims them only when the peak resident set grew by a quarter since its last
# trim, so once a process has peaked, released results stay resident and the
# footprint check measures memory the process no longer uses. The symbol is
# looked up at load: other C libraries (musl) have no such call.
const _MALLOC_TRIM = Ref(C_NULL)
function _init_malloc_trim!()
    Sys.islinux() || return
    libc = Base.Libc.Libdl.dlopen_e("libc.so.6")
    libc == C_NULL || (_MALLOC_TRIM[] = Base.Libc.Libdl.dlsym_e(libc, :malloc_trim))
    nothing
end
function _return_free_memory!()
    f = _MALLOC_TRIM[]
    f == C_NULL || ccall(f, Cint, (Csize_t,), 0)
    nothing
end
# Where freed pages are returned, the footprint read after a collection shows
# what a release freed. Elsewhere (macOS) that is not measured yet.
_footprint_follows_releases() = _MALLOC_TRIM[] != C_NULL
