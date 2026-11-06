# An exception type for `test/workers.jl`: only the worker process loads this package, so the
# requesting process cannot rebuild the exception.
module WorkerOnlyFault
struct Fault <: Exception
    message::String
end
Base.showerror(io::IO, e::Fault) = print(io, e.message)
end
