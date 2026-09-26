# What Aqua can prove about the package as a package.
#
#     julia --project=cli/precompile cli/test/aqua.jl
#
# Method ambiguities, unbound type parameters, exports that name nothing, type
# piracy, dependencies nothing loads, and a `[compat]` for every one that is -
# over `Worklog`. And the rule of DESIGN's "The precompile wrapper", that it
# **must not leave a process running**, which until this file was noticed
# only when precompilation hung.
#
# Not in `runtests.jl`, for the reason `latency.jl` is not: the last check
# builds the wrapper's image, which is the twenty seconds the suite runs
# against `Worklog` to avoid. And Aqua is no dependency of the program, so the
# suite's `--project=cli` cannot load it: it has an environment of its own,
# `cli/test/aqua/`, stacked on the wrapper's here, so that `Worklog` and its
# dependencies are the ones in the manifests `wl` runs.

pushfirst!(LOAD_PATH, joinpath(@__DIR__, "aqua"))
using Test, Aqua
using Worklog

"""Build `WorklogPrecompile`'s image in a child, as `wl` does after a change,
and answer `(ok, stderr)`.

Not `Aqua.test_persistent_tasks`, which was the first thing tried: it watches
what *loading* a package leaves running, and loading this one runs nothing -
the workload runs while its image is built. Handed the workload to run, it
hung rather than failed, because what it waits for without a limit is the
dependency's own build, and that is exactly what a leftover task stops.

So the build is watched directly. A process left behind makes the child print
"Waiting for background task / IO / timer" with the handles it is waiting on,
and wait for ever; that line is the failure, and the handles are its message.
`limit` is only for a build that neither finishes nor says so."""
function build_wrapper(; limit = 600)
    err = tempname()
    pkg = "Base.identify_package(\"WorklogPrecompile\")"
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project())
           -e "Base.compilecache($pkg)"`
    p = run(pipeline(cmd; stdout = devnull, stderr = err); wait = false)
    stuck() = isfile(err) && occursin("Waiting for background task", read(err, String))
    timedwait(() -> !process_running(p) || stuck(), limit; pollint = 0.5)
    process_running(p) && kill(p, Base.SIGKILL)
    wait(p)
    txt = isfile(err) ? read(err, String) : ""
    (success(p) && !occursin("Waiting for background task", txt), txt)
end

@testset "Aqua" begin
    @testset "ambiguities" Aqua.test_ambiguities(Worklog)
    @testset "unbound type parameters" Aqua.test_unbound_args(Worklog)
    @testset "undefined exports" Aqua.test_undefined_exports(Worklog)
    @testset "piracy" Aqua.test_piracies(Worklog)
    @testset "stale dependencies" Aqua.test_stale_deps(Worklog)
    @testset "compat" Aqua.test_deps_compat(Worklog)
    @testset "test target" Aqua.test_project_extras(Worklog)
    # The wrapper loads `Worklog` while its image is built, so anything its
    # `__init__` starts is left running there too.
    @testset "loading leaves nothing running" Aqua.test_persistent_tasks(Worklog)
    @testset "the workload leaves nothing running" begin
        ok, txt = build_wrapper()
        ok || print(stderr, txt)
        @test ok
    end
end
