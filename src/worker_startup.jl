# Entry point for a cold queue worker with explicit preloads. Malt appends its
# worker program as the last argument. Use its normal message server and give
# it a listening socket before application initializers can write to stdout.
module DynamicObjectsWorkerStartup

function run()
    malt_program = pop!(ARGS)
    ready_file = popfirst!(ARGS)
    packages = Base.PkgId[]
    for (uuid, name) in Iterators.partition(ARGS, 2)
        push!(packages, Base.PkgId(Base.UUID(uuid), name))
    end
    empty!(ARGS)
    Base.include(Main, malt_program)
    Base.invokelatest(serve, ready_file, packages)
end

function serve(ready_file, packages)
    sockets = Main.Sockets
    port, server = sockets.listenany(0)
    try
        sockets.nagle(server, false)
        sockets.quickack(server, true)
        touch(ready_file)
        println(stdout, port)
        flush(stdout)

        do_id = popfirst!(packages)
        do_module = Base.require(do_id)
        Base.invokelatest(do_module._init_preloaded_worker!, packages)
        Main.serve(server)
    finally
        close(server)
    end
end

end

DynamicObjectsWorkerStartup.run()
