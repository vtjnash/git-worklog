# What a person actually waits for, measured rather than remembered.
#
#     julia --project=cli cli/test/latency.jl
#
# Startup is the number this program is judged by, and until this file there was
# nothing that measured it: the wrapper's "4.33s to 1.36s" was taken by hand,
# once, and `Worklog.jl`'s `precompile` block was filled in the same way. Both
# were several sessions of changes out of date by the time anybody checked.
#
# Not a testset, and deliberately not part of `runtests.jl`, for two reasons.
# A ceiling asserted on a shared machine is a flaky test - what moves these
# numbers between runs is bigger than the difference they are measuring, so the
# threshold that never fires spuriously is also the one that never fires. And
# the suite runs against `Worklog` (`--project=cli`) precisely so that the
# edit-test loop never pays for the wrapper's image; this file builds that
# image, so running it from the suite would hand every `runtests.jl` a
# twenty-second bill.
#
# What it does instead is print a table. That is enough to notice a regression
# the next time somebody looks, and it costs nothing when nobody does.

using Printf

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# A comment with the shapes the markdown renderer branches on - an inline span,
# a list, a fence, and a paragraph long enough to wrap - because a thread of ten
# plain lines measures none of the work drawing a real one does.
const BODY = """
A paragraph long enough to wrap across a pane, with `inline_code` and a
`Tuple{Type{S{N,T}}}` in it.

- a list item
- and another

```julia
f(x) = x + 1
```
"""

"""The three waits, as julia to run after the module is loaded.

Each is a prefix of the next, because that is the order a launch goes in: the
command surface infers on the first `dispatch`, the list pane cannot draw before
`facts.json` is read, and the thread is drawn after that. Timed as whole waits
rather than per call - the phases move a lot between runs (whichever compiles
first pays for warming the compiler, and it is not always the same one), while
what a person sits through does not.
"""
const PROBES = Dict(
    # `--help` walks the whole command surface, which is what makes it the
    # measurement for every `wl <command>` and not just for the help text.
    "help" => """
        Worklog.dispatch(["--help"], Worklog.utcnow())
        """,
    # Over the real dashboard, not an invented one: two thousand rows is the
    # size the first frame is actually drawn at, and the parse is part of the
    # wait.
    "frame" => """
        items = Worklog.loaditems()
        st = Worklog.BState(items, "worklog", Set{String}())
        Worklog.render(st, 170, 50)
        """,
    "thread" => """
        items = Worklog.loaditems()
        st = Worklog.BState(items, "worklog", Set{String}())
        Worklog.render(st, 170, 50)
        st.nodes = [Worklog.Node("alice  2026-09-01T10:00   the first comment",
                                 BODY, :md, true),
                    Worklog.Node("bob  2026-09-02T11:00   a reply",
                                 "short", :md, false)]
        Worklog.rows(st.nodes, 96)
        Worklog.detail_pane(st, st.items[st.sel], 100, 30, true)
        """)

const ORDER = ["help", "frame", "thread"]

# The two environments, in the sense the question is asked: `wl` runs the first
# and the suite runs the second, and the difference between them is the whole
# claim the wrapper makes.
const ENVS = [("wrapper", joinpath(ROOT, "cli", "precompile"), "WorklogPrecompile"),
              ("plain", joinpath(ROOT, "cli"), "Worklog")]

"""One cold process: load the module, then do the work, and print both.

The data directory is left pointing at the real one - the dashboard being read
is the point - but every path the program *writes* through is redirected first,
which is the same rule `runtests.jl` follows and for the same reason: measuring
must not stamp an item as read or reorder the user's lists.
"""
function child(mod::String, probe::String)
    """
    t0 = time_ns()
    using $mod
    load = (time_ns() - t0) / 1e9
    let d = mktempdir()
        for (r, name) in ((Worklog.STATE, "state.toml"), (Worklog.MARKS, "marks.json"),
                          (Worklog.Events.INBOX, "inbox.json"),
                          (Worklog.REPOS_FILE, "repos.toml"))
            r[] = joinpath(d, name)
        end
        Worklog.CACHE_DIR[] = joinpath(d, "cache")
    end
    const BODY = $(repr(BODY))
    work = @elapsed redirect_stdout(devnull) do
        $(PROBES[probe])
    end
    println(stderr, load, " ", work)
    """
end

"Run one probe in one environment, and answer `(load, work)` in seconds."
function measure(project::String, mod::String, probe::String)
    err = IOBuffer()
    cmd = `julia --startup-file=no --project=$project -e $(child(mod, probe))`
    run(pipeline(cmd; stdout = devnull, stderr = err))
    parse.(Float64, split(strip(String(take!(err)))))
end

# Both images have to exist before anything is timed, or the first run reports
# the twenty seconds it took to build one as though a user had waited for it.
# Two more things this warm-up settles, both of them worth a second or more of
# the first measurement and neither of them anything to do with this program:
# the page cache under `facts.json`, and the depot.
#
# **What the depot has to do with it.** Julia 1.14 writes code compiled during a
# run back into the caches of whichever packages own it, so the *second* launch
# after a change is faster than the first and every launch after that is the
# same as the second. Measured on the thread path with no wrapper: 4.97s the
# first time, 2.46s every time after. So there are two honest numbers, and this
# file reports the one a person meets over and over - what `wl` costs on an
# ordinary launch. The other one, the launch straight after an edit to
# `cli/src`, is roughly twice it, and no run of this file can show it twice:
# the write-back that made the first launch slow has already happened.
for (_, project, mod) in ENVS
    print(stderr, "warming $mod ... ")
    @printf(stderr, "%.1fs\n", @elapsed measure(project, mod, "thread"))
end

# Interleaved, so a machine that gets busy halfway through spoils both columns
# rather than deciding the comparison, and reported as the minimum of the runs:
# a busy machine only ever adds, so the smallest total seen is the one with the
# least of somebody else's work in it.
const REPS = 3
results = Dict{Tuple{String,String},Vector{Vector{Float64}}}()
for _ in 1:REPS, probe in ORDER, (name, project, mod) in ENVS
    push!(get!(results, (probe, name), Vector{Float64}[]), measure(project, mod, probe))
end

best(probe, env) = minimum(sum, results[(probe, env)])
split_of(probe, env) = results[(probe, env)][argmin(map(sum, results[(probe, env)]))]

println()
println("startup, best of $REPS cold runs, seconds")
@printf("  %-12s %7s  %7s  %7s      %s\n",
        "", "wrapper", "plain", "saved", "wrapper split")
for probe in ORDER
    w, p = best(probe, "wrapper"), best(probe, "plain")
    l, k = split_of(probe, "wrapper")
    @printf("  %-12s %7.2f  %7.2f  %7.2f      %.2f load + %.2f work\n",
            probe, w, p, p - w, l, k)
end
println("  help    `wl --help`, which infers the whole command surface")
println("  frame   the list pane, over the real facts.json")
println("  thread  the first comment thread drawn beside it")
println()
println("  An ordinary launch. The one straight after a change to cli/src costs")
println("  about twice it, because the runtime's own write-back cache is cold for")
println("  whatever the change touched; see the note above the warm-up here.")
