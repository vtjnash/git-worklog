"""
    WorklogPrecompile

`Worklog`, with the browser's own work already compiled into the package image.

Nothing here is a feature. It re-exports `Worklog` unchanged and exists only so
that `wl` starts in a fifth of the time: opening the navigator costs about two
and a half seconds of *compilation* on top of the second it takes to load the
module, and that cost was being paid on every invocation because nothing had
ever run `render` before the user did.

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

"""Run `f` against a disposable data directory, and put the real one back.

The same discipline `runtests.jl` follows, and for a stronger reason: this runs
during *precompilation*, where reading the user's dashboard would make the image
depend on it and writing to it would be indefensible. Every path the program
persists through is a `Ref`, so redirecting all of them is the whole of it.

Restored to `""` rather than to what they were, because `""` is what they hold
in a freshly loaded module: the point is that nothing about this workload is
still set when `wl` runs.
"""
function hermetic(f)
    d = mktempdir()
    try
        Worklog.DATA_DIR[] = d
        Worklog.CACHE_DIR[] = joinpath(d, "cache")
        Worklog.STATE[] = joinpath(d, "state.toml")
        Worklog.TOUCHED[] = joinpath(d, "touched.json")
        Worklog.REPOS_FILE[] = joinpath(d, "repos.toml")
        Worklog.Events.READ[] = joinpath(d, "read.json")
        Worklog.Events.INBOX[] = joinpath(d, "inbox.json")
        redirect_stdout(devnull) do
            f()
        end
    finally
        Worklog.DATA_DIR[] = ""
        Worklog.CACHE_DIR[] = ""
        Worklog.STATE[] = ""
        Worklog.TOUCHED[] = ""
        Worklog.REPOS_FILE[] = ""
        Worklog.Events.READ[] = ""
        Worklog.Events.INBOX[] = ""
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

@setup_workload begin
    items = sample_items()
    nodes = sample_nodes()
    @compile_workload begin
        try
            hermetic() do
                st = Worklog.BState(items, "worklog", Set{String}([items[2].url]))
                # Both layouts: side by side above the split width, stacked below.
                for (w, h) in ((170, 50), (150, 40), (100, 30), (80, 24))
                    Worklog.render(st, w, h)
                end
                Worklog.refilter!(st)
                Worklog.apply_view!(st, Dict("state" => "all"))
                Worklog.apply_view!(st, Dict("state" => "active", "kind" => "pr"))
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

                # Keys, with the two loads that end every one of them already
                # satisfied: `load_nodes!` and `load_meta!` would otherwise start
                # a fetch, and a workload that talks to GitHub is a workload that
                # hangs. Only keys that move neither the selection nor the mode,
                # so the keys stay satisfied.
                ctrl = Worklog.Controller()
                st.loaded = string(items[1].url, ":", st.mode)
                st.metakey = items[1].url
                for k in (Int('j'), Int('k'), Int('w'), Int('g'), Int('G'),
                          9, Int('f'), Int('f'), Int('m'), Int('`'))
                    Worklog.handle!(st, k, ctrl)
                end

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
