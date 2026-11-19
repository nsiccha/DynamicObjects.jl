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
