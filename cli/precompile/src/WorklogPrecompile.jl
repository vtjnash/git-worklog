"""
    WorklogPrecompile

`Worklog`, with the browser's own work already compiled into the package image.

Nothing here is a feature. It re-exports `Worklog` unchanged and exists only so
that `wl` starts in half the time: a launch that draws a comment thread was
measured at 2.36s against 1.14s with this in place, and the difference is
*compilation* that was being paid on every invocation because nothing had ever
run `render` or read a `facts.json` before the user did. `cli/test/latency.jl`
is where those numbers come from, and re-derives them on demand.

**Why a separate package and not a workload inside `Worklog`.** A workload runs
whenever the package holding it is precompiled, and `Worklog` is precompiled
every time one of its own files is touched - so putting it there would tax the
edit-test loop, which is the loop that runs most often. Downstream, the tax
lands only on `wl`, and only once per change. `cli/test/runtests.jl` uses
`Worklog` directly and never loads this at all, so the suite is exactly as fast
as it was.

**Why a hand-written workload and not the test suite.** The suite would be the
better *coverage*, and it was the first thing tried. It spawns tmux servers,
`vi` and half a dozen git repositories, all of which would then be happening
inside package precompilation - which runs in parallel, in a subprocess, with
its output captured. Worse, a failing test would stop `wl` from starting at all,
which couples the program's usability to work in progress. So the workload is
the browser's own path, written out: what the suite calls its typical harness,
minus everything that talks to a process or the network.
"""
module WorklogPrecompile

using Worklog
using Dates: DateTime
using PrecompileTools: @compile_workload, @setup_workload

# Re-exported so `using WorklogPrecompile` is a drop-in for `using Worklog`, and
# so `bin/wl` can name one module rather than two.
export Worklog

"""Run `f` somewhere it can neither read the user's dashboard nor start a process.

The data half is the discipline `runtests.jl` follows, for a stronger reason:
this runs during *precompilation*, where reading the real dashboard would make
the image depend on it and writing to it would be indefensible. Every path the
program persists through is a `Ref`, so redirecting all of them is the whole of
it.

The process half is not hygiene, it is the difference between precompiling and
hanging. `load_nodes!` and `load_meta!` start a fetch in an `@async` task the
moment the selection moves to an item they have not loaded - `gh api graphql`
for the thread and the metadata, `tmux list-panes` for the sessions - and a
package that leaves live subprocesses behind stops precompilation dead with
"waiting for IO to finish". Pinning `st.loaded` was not enough: a single `j`
moves the selection and leaves the pin behind.

So the binaries are taken away rather than the calls avoided. An empty `PATH`
makes `run` throw before it forks, and `WORKLOG_TMUX` at a path that does not
exist makes `mux_bin` answer `nothing` without looking. Every fetch then fails
instantly, in the ordinary way the program already handles, and there is nothing
left running to wait for. That is a property of the *environment* rather than of
which keys this workload happens to press, which is what makes it survive
somebody adding a key to it.

Everything is restored in a `finally`, the `Ref`s to `""` rather than to what
they held: `""` is what a freshly loaded module has, and the point is that
nothing about this workload is still set when `wl` runs.
"""
function hermetic(f)
    d = mktempdir()
    path, mux = get(ENV, "PATH", nothing), get(ENV, "WORKLOG_TMUX", nothing)
    try
        ENV["PATH"] = ""
        ENV["WORKLOG_TMUX"] = joinpath(d, "no-tmux-here")
        Worklog.DATA_DIR[] = d
        Worklog.CACHE_DIR[] = joinpath(d, "cache")
        Worklog.LOCAL[] = joinpath(d, "local.toml")
        Worklog.LOCAL[] = joinpath(d, "local.toml")
        Worklog.LOCAL[] = joinpath(d, "local.toml")
        Worklog.FETCHED[] = joinpath(d, "fetched.json")
        redirect_stdout(devnull) do
            f()
        end
    finally
        path === nothing ? delete!(ENV, "PATH") : (ENV["PATH"] = path)
        mux === nothing ? delete!(ENV, "WORKLOG_TMUX") : (ENV["WORKLOG_TMUX"] = mux)
        Worklog.LOGIN[] = ""
        Worklog.DATA_DIR[] = ""
        Worklog.CACHE_DIR[] = ""
        Worklog.LOCAL[] = ""
        Worklog.LOCAL[] = ""
        Worklog.LOCAL[] = ""
        Worklog.FETCHED[] = ""
        rm(d; recursive = true, force = true)
    end
end

"""A dashboard's worth of rows, written down rather than read.

Invented and not loaded from `facts.json`, so what gets compiled does not depend
on what happened to be in the user's dashboard the day the image was built - and
so this works on a machine that has never run a refresh. Varied on the axes the
code actually branches on: pull request against issue, labelled against not,
with a branch and without, one of yours and one of somebody else's.
"""
function sample_items()
    [Worklog.Item(url = "https://github.com/o/r/pull/1", ref = "r#1", repo = "o/r",
                  number = 1, title = "a pull request with a reasonably long title",
                  bucket = "needs-review", author = "vtjnash", is_pr = true,
                  labels = ["bug", "domain:ci"], branch = "jn/topic",
                  state = "OPEN", ci = "SUCCESS", mergeable = "MERGEABLE",
                  act = "2026-09-01T12:00:00Z", milestone = "1.13"),
     Worklog.Item(url = "https://github.com/o/r/issues/2", ref = "r#2", repo = "o/r",
                  number = 2, title = "an issue", bucket = "issue",
                  author = "someone", is_pr = false, state = "OPEN",
                  act = "2026-08-20T09:30:00Z", unresolved = 3),
     Worklog.Item(url = "local:o/r#wip", ref = "r#wip", repo = "o/r", number = 0,
                  title = "an adopted branch", bucket = "needs-edits",
                  author = "vtjnash", is_pr = true, branch = "wip",
                  act = "2026-09-02T18:00:00Z", draft = true)]
end

"""A thread's worth of nodes, likewise invented.

The markdown renderer is the expensive half of the browser - `nodelines` hands a
body to Term - so a comment with a code span, a list and a long paragraph is
worth more here than ten plain ones. The diff node is its own path.
"""
function sample_nodes()
    body = Worklog.Node("alice  2026-09-01T10:00   the first comment",
                        "A paragraph long enough to wrap across a pane, with " *
                        "`inline_code` and a `Tuple{Type{S{N,T}}}` in it.\n\n" *
                        "- a list item\n- and another\n\n" *
                        "```julia\nf(x) = x + 1\n```\n", :md, true)
    reply = Worklog.Node("bob  2026-09-02T11:00   a reply", "short", :md, false)
    hunk = Worklog.Node("src/a.jl  @@ 10,3 @@", " context\n-gone\n+added\n", :diff, true)
    hunk.meta["file"] = "src/a.jl"
    hunk.meta["start"] = 10
    hunk.meta["count"] = 3
    hunk.meta["up"] = 0
    hunk.meta["down"] = 0
    hunk.meta["body"] = hunk.raw
    plain = Worklog.Node("no checks reported", "", :plain, true)
    [body, reply, hunk, plain]
end

"""The same dashboard as `sample_items`, in the form it is actually read from.

`loaditems` is the first thing the browser does and none of it was in the image:
a `facts.json` is parsed by JSON3 and every row goes through `item_of`, which is
thirty keyword arguments over a `JSON3.Object` - about a third of a second of
compilation, paid on the frame the user is waiting for. Compiling it takes a
file, because the types `item_of` sees carry the buffer the object was parsed
from, and a hand-built `Dict` is not that type.

Written out rather than copied from the real one for the reason the items are
invented: the image must not depend on what was in the dashboard the day it was
built. Two rows, because the missing half of the second one is a different path
through `jget` and `nz` than the present half of the first.
"""
function sample_facts()
    """
    {"fetched_at": "2026-09-01T12:00:00Z",
     "items": {
       "https://github.com/o/r/pull/1": {
         "url": "https://github.com/o/r/pull/1", "repo": "o/r", "number": 1,
         "title": "a pull request with a reasonably long title",
         "type": "PullRequest", "author": "vtjnash", "state": "OPEN",
         "bucket": "needs-review", "track": "normal",
         "labels": ["bug", "domain:ci"], "blocked_on": [],
         "branch": "jn/topic", "ci": "SUCCESS", "mergeable": "MERGEABLE",
         "unresolved": 2, "review_decision": "REVIEW_REQUIRED",
         "milestone": "1.13", "milestone_due": "2026-10-01T00:00:00Z",
         "note": "a note", "why": "review requested", "second_look": "",
         "draft": false, "new": true, "moved": false, "snoozed": false,
         "updated": "2026-09-01T12:00:00Z", "head_at": "2026-09-01T11:00:00Z",
         "last_comment_at": "2026-09-01T09:00:00Z"
       },
       "https://github.com/o/r/issues/2": {
         "url": "https://github.com/o/r/issues/2", "repo": "o/r", "number": 2,
         "title": "an issue", "type": "Issue", "author": "someone",
         "bucket": "mentioned", "labels": [],
         "note": null, "deadline": null, "milestone": null,
         "updated": "2026-08-20T09:30:00Z"
       }
     },
     "points": {}}
    """
end

@setup_workload begin
    items = sample_items()
    nodes = sample_nodes()
    @compile_workload begin
        try
            hermetic() do
                # The dashboard, read the way the browser reads it: the first
                # thing between the user and a frame is a JSON3 parse and a row
                # of `item_of` per item, and neither was in the image while the
                # only items here were constructed in Julia.
                write(Worklog.fetchedfile(), sample_facts())
                st = Worklog.BState(vcat(Worklog.loaditems(), items), "worklog",
                                    Set{String}([items[2].url]))
                # Both layouts: side by side above the split width, stacked below.
                for (w, h) in ((170, 50), (150, 40), (100, 30), (80, 24))
                    Worklog.render(st, w, h)
                end
                Worklog.refilter!(st)
                Worklog.apply_view!(st, Dict("seen" => ["unread"]))
                Worklog.apply_view!(st, Dict("sleep" => ["awake"], "kind" => "pr"))
                Worklog.filter_summary(st.filters, st.sort)
                Worklog.view_toml(st.filters, st.sort, "a name")

                # The filter pane is a second renderer over the same box.
                st.lmode = :filters
                Worklog.filter_rows(st)
                Worklog.filter_groups(Worklog.filter_rows(st))
                Worklog.render(st, 150, 40)
                Worklog.toggle_filter!(st)
                st.lmode = :items

                # The thread, which is where the time actually goes: `nodelines`
                # hands each body to Term and that is the slow half of a frame.
                st.nodes = nodes
                for w in (140, 96, 60)
                    Worklog.rows(st.nodes, w)
                end
                Worklog.detail_pane(st, items[1], 100, 30, true)
                Worklog.meta_lines(st, items[1], 44)
                Worklog.selrange(st)

                # Keys. Every one of these ends in `load_nodes!` and
                # `load_meta!`, which start a fetch whenever the selection has
                # moved - so this is only safe because `hermetic` has taken the
                # binaries away and the fetch fails before it forks.
                ctrl = Worklog.Controller()
                for k in (Int('j'), Int('k'), Int('w'), Int('g'), Int('G'),
                          9, Int('f'), Int('f'), Int('m'), Int('`'))
                    Worklog.handle!(st, k, ctrl)
                end
                # And nothing outlives the workload. `INFLIGHT` is what knows
                # which fetches are still in the air - a view only ever holds
                # the last one it started - so this is the whole of it however
                # many keys are pressed above.
                Worklog.drain_fetches!()

                # Input decoding, which is a pure function of a byte stream.
                for s in ("j", "\e", "\e[A", "\e[6;5~", "\e[Z", "\eb", "\e\x7f",
                          "\e[<0;40;12M", "\e[<64;5;5M")
                    Worklog.readevent(IOBuffer(s))
                end
                Worklog.readraw(IOBuffer("\e[A"))

                # The views that open over the browser.
                Worklog.render(Worklog.ChooseView("Views", "note",
                    Tuple{String,Any}[("one", :a), ("two", :b)], identity), 120, 34)
                Worklog.render(Worklog.PromptView("Name", "note", identity), 120, 34)

                # And the command surface, which `--help` walks the whole of.
                Worklog.dispatch(["--help"], Worklog.utcnow())
            end
        catch e
            # Never fatal. A workload is an optimisation, and an optimisation
            # that can stop the program from being installed is not one.
            @warn "worklog precompile workload did not finish" exception = e
        end
    end
end

end # module WorklogPrecompile
