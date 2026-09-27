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
using Dates: DateTime, Day, Millisecond, Second
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
finds no `gh`, and `WORKLOG_TMUX` at a path that does not exist makes `mux_bin`
answer `nothing` without looking. Every fetch then fails instantly, in the
ordinary way the program already handles, and there is nothing left running to
wait for. That is a property of the *environment* rather than of which keys this
workload happens to press, which is what makes it survive somebody adding a key
to it.

"Nothing left running" is the half that had to be earned. A `run` that *tries*
to spawn and fails is not free: `gh_run` fed stdin from an `IOBuffer`, and the
writer task Base starts for that is reachable only through the `Process` a
failed spawn never returns - so an empty `PATH` used to leave a live pipe and a
half-closed process handle behind, and precompilation ended in "Waiting for
background task / IO / timer to finish" often enough to be noticed. `gh_run`
looks for `gh` before it spawns now; see its docstring in `gh.jl`.

An empty `PATH` stops `gh`, not the network. The item pane's own requests -
`itemmeta`, `fetch_bundle`'s `server_now` - go through GitHub.jl, and `token()`
finds a token without `gh` whenever the sandbox's token file or `GH_TOKEN` is
there: the workload could make real requests while the image was built, on
exactly the machines that have one. So the token is taken away too - the file at a
path that does not exist, the variables unset, the cached auth dropped - and
those requests fail on "no GitHub token" before they open a connection.

Everything is restored in a `finally`, the `Ref`s to `""` rather than to what
they held: `""` is what a freshly loaded module has, and the point is that
nothing about this workload is still set when `wl` runs.
"""
function hermetic(f)
    d = mktempdir()
    E = Worklog.Events
    keep = Dict(k => get(ENV, k, nothing) for k in ("PATH", "WORKLOG_TMUX", "GH_TOKEN", "GITHUB_TOKEN"))
    tokfile, patfile = E.TOKEN_FILE[], E.PAT_FILE[]
    try
        ENV["PATH"] = ""
        ENV["WORKLOG_TMUX"] = joinpath(d, "no-tmux-here")
        delete!(ENV, "GH_TOKEN"); delete!(ENV, "GITHUB_TOKEN")
        E.TOKEN_FILE[] = E.PAT_FILE[] = joinpath(d, "no-token-here")
        E._AUTH[] = E._PAT[] = nothing
        Worklog.DATA_DIR[] = d
        Worklog.CACHE_DIR[] = joinpath(d, "cache")
        Worklog.LOCAL[] = joinpath(d, "local.toml")
        Worklog.FETCHED[] = joinpath(d, "fetched.json")
        Worklog.RUN_DIR[] = joinpath(d, "run")
        redirect_stdout(devnull) do
            f()
        end
    finally
        for (k, v) in keep
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
        E.TOKEN_FILE[], E.PAT_FILE[] = tokfile, patfile
        E._AUTH[] = E._PAT[] = nothing
        Worklog.LOGIN[] = ""
        Worklog.DATA_DIR[] = ""
        Worklog.CACHE_DIR[] = ""
        Worklog.LOCAL[] = ""
        Worklog.FETCHED[] = ""
        Worklog.RUN_DIR[] = ""
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
                  lane = "review", review = "review requested",
                  author = "vtjnash", is_pr = true,
                  labels = ["bug", "domain:ci"], branch = "jn/topic",
                  state = "OPEN", ci = "SUCCESS",
                  act = "2026-09-01T12:00:00Z", milestone = "1.13"),
     Worklog.Item(url = "https://github.com/o/r/issues/2", ref = "r#2", repo = "o/r",
                  number = 2, title = "an issue", lane = "assigned",
                  author = "someone", is_pr = false, state = "OPEN",
                  act = "2026-08-20T09:30:00Z", unresolved = 3),
     Worklog.Item(url = "local:o/r#wip", ref = "r#wip", repo = "o/r", number = 0,
                  title = "an adopted branch", lane = "local",
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
a `facts.json` is parsed and every row goes through `item_of`, which is thirty
keyword arguments over a `JSON.Object` - about a third of a second of
compilation, paid on the frame the user is waiting for. Compiling it takes a
file, because the types `item_of` sees are the parser's, and a hand-built
`Dict` is not that type.

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
         "lane": "review", "track": "normal",
         "labels": ["bug", "domain:ci"],
         "branch": "jn/topic", "ci": "SUCCESS", "mergeable": "MERGEABLE",
         "unresolved": 2, "review_decision": "REVIEW_REQUIRED",
         "milestone": "1.13", "milestone_due": "2026-10-01T00:00:00Z",
         "note": "a note", "review": "review requested", "second_look": "",
         "draft": false, "new": true, "moved": false, "snoozed": false,
         "updated": "2026-09-01T12:00:00Z", "head_at": "2026-09-01T11:00:00Z",
         "last_comment_at": "2026-09-01T09:00:00Z"
       },
       "https://github.com/o/r/issues/2": {
         "url": "https://github.com/o/r/issues/2", "repo": "o/r", "number": 2,
         "title": "an issue", "type": "Issue", "author": "someone",
         "lane": "mentioned_issue", "labels": [],
         "note": null, "milestone": null,
         "updated": "2026-08-20T09:30:00Z"
       }
     },
     "points": {},
     "inbox": {
       "cursors": {}, "polled": {}, "failed": {},
       "items": {
         "https://github.com/o/r/issues/3": {
           "url": "https://github.com/o/r/issues/3", "repo": "o/r", "number": 3,
           "title": "a watched repository's traffic", "is_pr": false,
           "state": "open", "author": "someone", "updated": "2026-09-01T08:00:00Z",
           "comments": 2, "labels": [], "mine": false,
           "notified": "2026-09-01T08:00:05Z", "lane": "notifications",
           "reason": "subscribed", "why": "you watch the repository"
         }
       }
     }}
    """
end

"""Two rows as GitHub's GraphQL answers them, for the road `fetch_bundle`
takes after its request - which is the one the cursor takes whenever it lands
on a row whose bundle is stale.

Inside an object, and read back out of it, because a node in an answer is
nested, which JSON3 typed apart from a top-level object. The pull request has
what `normalize` branches on - a timeline, reviews, a head commit with its
checks, and a bundle in the cache to be derived against; the issue has every
list empty, and no row before it.
"""
function sample_graphql()
    login(l) = Dict{String,Any}("login" => l)
    ev(kind, at; kw...) = Dict{String,Any}("__typename" => kind, "createdAt" => at,
                                           "actor" => login("someone"),
                                           (String(k) => v for (k, v) in kw)...)
    pr = Dict{String,Any}(
        "__typename" => "PullRequest", "url" => "https://github.com/o/r/pull/1",
        "number" => 1, "title" => "a pull request with a reasonably long title",
        "state" => "OPEN", "isDraft" => false, "repository" => Dict("nameWithOwner" => "o/r"),
        "createdAt" => "2026-08-30T12:00:00Z", "updatedAt" => "2026-09-02T12:00:00Z",
        "author" => login("vtjnash"), "milestone" => Dict("title" => "1.13", "dueOn" => nothing),
        "assignees" => Dict("nodes" => [login("vtjnash")]),
        "labels" => Dict("nodes" => [Dict("name" => "bug")]),
        "timelineItems" => Dict("nodes" => [
            ev("AssignedEvent", "2026-08-30T13:00:00Z"; assignee = login("vtjnash")),
            ev("ReviewRequestedEvent", "2026-08-30T13:05:00Z"; requestedReviewer = login("alice")),
            ev("ClosedEvent", "2026-09-02T12:30:00Z")]),
        "comments" => Dict("nodes" => [Dict("author" => login("alice"),
                                            "createdAt" => "2026-08-31T09:00:00Z")]),
        "reviews" => Dict("nodes" => [Dict("author" => login("bob"), "state" => "CHANGES_REQUESTED",
                                           "submittedAt" => "2026-09-01T10:00:00Z")]),
        "reviewThreads" => Dict("nodes" => [Dict("isResolved" => false, "isOutdated" => false)]),
        "headRefName" => "jn/topic", "headRefOid" => "b"^40, "baseRefName" => "master",
        "baseRefOid" => "c"^40, "headRepository" => Dict("nameWithOwner" => "o/r"),
        "mergedBy" => nothing, "reviewDecision" => "CHANGES_REQUESTED",
        "commits" => Dict("nodes" => [Dict("commit" => Dict(
            "committedDate" => "2026-09-01T11:05:00Z", "oid" => "b"^40,
            "committer" => Dict("user" => login("vtjnash")),
            "author" => Dict("user" => login("vtjnash")),
            "statusCheckRollup" => Dict("state" => "FAILURE")))]))
    issue = Dict{String,Any}(
        "__typename" => "Issue", "url" => "https://github.com/o/r/issues/4", "number" => 4,
        "title" => "an issue", "state" => "OPEN", "repository" => Dict("nameWithOwner" => "o/r"),
        "createdAt" => "2026-08-20T09:00:00Z", "updatedAt" => "2026-08-20T09:30:00Z",
        "author" => login("someone"), "milestone" => nothing,
        "assignees" => Dict("nodes" => []), "labels" => Dict("nodes" => []),
        "timelineItems" => Dict("nodes" => []), "comments" => Dict("nodes" => []))
    Worklog.JSON.parse(Worklog.json_dumps(Dict("nodes" => [pr, issue]))).nodes
end

"""What the browser finds in the cache for the first row, which is most of
what the pane beside the list draws from.

A bundle newer than the file's row, so `loaditems` reads the row off the
cache; the thread, with what `comment_nodes` branches on - a comment of
markdown with a table in it, a line comment, a run of pushes, a review and a
close - so the pane is built from GitHub's shapes and not from invented
`Node`s; and the metadata, the merge state and the checks, so `load_meta!`
reads the three of them back through `_meta_shape`, `_merge_shape` and the
checks pane. Each written with `cache_put`, as the fetches write them, and in
the types they write, so that call is compiled for those too. The diff, its
line comments and the Buildkite jobs behind the failed check are the `d` and
`c` panes of the same row.

JSON3 typed an empty array apart from one of objects - `JSON3.Array{Union{}}` -
and a real thread's pushes and state changes are empty more often than not.
There were two more threads here in those shapes, for `comment_nodes` to be
compiled over each; the thread readers are `@nospecialize` now, and a trace of
drawing both after the image loaded compiles nothing of theirs without them.
"""
function seed_cache(u::String)
    who(l) = Dict{String,Any}("login" => l)
    Worklog.cache_put(Worklog.bundle_key(u), Dict{String,Any}(
        "url" => u, "repo" => "o/r", "number" => 1, "type" => "PullRequest",
        "title" => "a pull request with a reasonably long title", "author" => "vtjnash",
        "state" => "OPEN", "lane" => "review", "track" => "normal",
        "labels" => ["bug"], "branch" => "jn/topic", "ci" => "SUCCESS",
        "review" => "review requested", "mine" => true, "new" => false,
        "created" => "2026-08-30T12:00:00Z", "updated" => "2026-09-02T12:00:00Z",
        "moved_at" => "2026-09-02T12:00:00Z", "moved_by" => "human_comment_at",
        "human_comment_at" => "2026-09-02T12:00:00Z", "last_comment_by" => "alice",
        "fetched_at" => "2026-09-02T12:05:00Z", "milestone" => nothing, "note" => nothing))
    comment(id, by, at, body; kw...) = Dict{String,Any}(
        "id" => id, "user" => who(by), "created_at" => at, "body" => body,
        "html_url" => string(u, "#issuecomment-", id), (String(k) => v for (k, v) in kw)...)
    Worklog.cache_put(Worklog.thread_key(u), (
        body = Dict{String,Any}("user" => who("vtjnash"), "html_url" => u,
                                "created_at" => "2026-08-30T12:00:00Z",
                                "body" => "Why this is here, with a [link](https://example.com) " *
                                          "and a mention of @alice.\n\nFixes #2."),
        comments = [comment(11, "alice", "2026-08-31T09:00:00Z",
                            "| case | before | after |\n|---|:-:|--:|\n" *
                            "| one | `1.0s` | 0.5s |\n| two | slow | **fast** |\n\n" *
                            "> quoted, and then\n\n1. a numbered\n2. list"),
                    comment(12, "bob", "2026-09-01T10:00:00Z", "`nothing` here?";
                            path = "src/a.jl", line = 10),
                    comment(13, "vtjnash", "2026-09-02T12:00:00Z", "Done, thanks.")],
        commits = [Dict{String,Any}("oid" => "a"^40, "at" => "2026-09-01T11:00:00Z",
                                    "by" => "vtjnash", "headline" => "address review"),
                   Dict{String,Any}("oid" => "b"^40, "at" => "2026-09-01T11:05:00Z",
                                    "by" => "vtjnash", "headline" => "and a test")],
        events = [Dict{String,Any}("kind" => "review", "state" => "changes_requested",
                                   "by" => "bob", "at" => "2026-09-01T10:00:00Z",
                                   "body" => "One thing."),
                  Dict{String,Any}("kind" => "closed", "by" => "alice",
                                   "at" => "2026-09-02T12:30:00Z", "reason" => "completed")]))
    Worklog.cache_put(Worklog.Events.meta_key(u), Dict{String,Any}(
        "requested" => ["alice"], "teams" => String[], "assignees" => ["vtjnash"],
        "pending" => "", "fork" => "someone/r", "default" => "master",
        "reviews" => [Dict{String,Any}("by" => "bob", "state" => "CHANGES_REQUESTED",
                                       "at" => "2026-09-01T10:00:00Z")]))
    Worklog.cache_put(Worklog.Events.merge_key(u), Dict{String,Any}(
        "id" => "PR_x", "oid" => "b"^40, "state" => "OPEN", "draft" => false,
        "mergeable" => "MERGEABLE", "status" => "CLEAN", "base" => "master",
        "commits" => 2, "methods" => ["SQUASH"],
        "text" => Dict{String,Any}("SQUASH" => Dict{String,Any}("headline" => "a", "body" => ""))))
    Worklog.cache_put(Worklog.checks_key("o/r", 1),
        (state = "FAILURE",
         contexts = [(name = "tests", state = "FAILURE",
                      url = "https://buildkite.com/o/r/builds/1#job"),
                     (name = "docs", state = "SUCCESS", url = "https://example.com")]))
    Worklog.cache_put("bkjobs:o/r/1",
        [(name = "tests", state = "failed", exit = 1, id = "j1"),
         (name = "docs", state = "passed", exit = 0, id = "j2")])
    Worklog.cache_put("diff:o/r#1",
        "diff --git a/src/a.jl b/src/a.jl\n--- a/src/a.jl\n+++ b/src/a.jl\n" *
        "@@ -8,4 +8,4 @@ function f(x)\n ctx\n ctx\n-    nothing\n+    x\n ctx\n")
    Worklog.cache_put(string("reviewcomments:", u),
        [Worklog.OrderedDict{String,Any}("id" => 12, "user" => who("bob"), "path" => "src/a.jl",
                                         "line" => 10, "original_line" => 10, "body" => "`nothing` here?",
                                         "created_at" => "2026-09-01T10:00:00Z",
                                         "html_url" => string(u, "#discussion_r12")),
         Worklog.OrderedDict{String,Any}("id" => 14, "user" => who("vtjnash"), "path" => "src/a.jl",
                                         "line" => 10, "in_reply_to_id" => 12, "body" => "fixed",
                                         "created_at" => "2026-09-01T11:10:00Z",
                                         "html_url" => string(u, "#discussion_r14"))])
end

"""`local.toml` with what the list reads off it: a notice, which is a row of
its own, and a done stamp, which puts the rule in the first row's thread."""
function seed_local(at)
    write(Worklog.localfile(), """
        ["notice:11"]
        type = "Release"
        repo = "o/r"
        reason = "subscribed"
        title = "v1.0.0"
        at = "2026-09-01T07:00:00Z"
        web = "https://github.com/o/r/releases"
        """)
    Worklog.mark_done(["https://github.com/o/r/pull/1"], Worklog.DateTime(2026, 8, 31, 12))
end

"""One turn of `run!`'s loop, which cannot itself run here - it wants a TTY -
and one turn is most of what it compiles: the event to the view on top
through `safe_dispatch!`, a `:pop` taken off the stack, `settle_all!`, the
background work adopted by `onwake!`, and the frame through `safe_render`
and `frame_bytes`. A key that opens a dialog is then answered by the dialog,
which is why this goes through the stack and not straight to the browser.

`drain_fetches!` before the wake, so the load a key started has landed by
the time the wake looks for it, and the thread drawn is the one read from
the cache rather than an empty pane waiting for one.
"""
function step!(ctrl, ev; w = 170, h = 50)
    v = last(ctrl.stack)
    act = Worklog.safe_dispatch!(v, ev, ctrl)
    act === :quit && return
    if act === :pop
        i = findlast(x -> x === v, ctrl.stack)
        i === nothing || deleteat!(ctrl.stack, i)
    end
    Worklog.settle_all!(ctrl)
    Worklog.drain_fetches!()
    top = last(ctrl.stack)
    Worklog.onwake!(top)
    Worklog.frame_bytes(Worklog.safe_render(top, w, h), "", Worklog.viewcursor(top, w, h); w)
    nothing
end

# What only an answer from GitHub, or a terminal, reaches - which the workload
# cannot have - named by signature instead: the launch poll, which is
# `event_sources`, `sync!` and `api_get_dated`, with its rows as `inbox_items`'s
# second argument; and the terminal the keys are read from. Each is from a
# `--trace-compile` of a browser session over the real dashboard, as what it
# still compiled after the workload. `precompile` answers `false` rather than
# failing, so each is checked: a signature that stops matching is a line doing
# nothing, and says so while the image is built.
for (f, sig) in (
        (Worklog.inbox_items, (Set{String}, Vector{Worklog.OrderedDict{String,Any}})),
        (Worklog.Events.event_sources, (Vector{String},)),
        (Core.kwcall, (NamedTuple{(:login, :ttl, :backfill),Tuple{String,Millisecond,Day}},
                       typeof(Worklog.Events.sync!), Vector{Worklog.Events.Source}, DateTime)),
        (Core.kwcall, (NamedTuple{(:params, :auth),Tuple{Dict{String,Any},Worklog.Events.GitHub.OAuth2}},
                       typeof(Worklog.Events.api_get_dated), String)),
        (Worklog.readevent, (Base.TTY,)))
    precompile(f, sig) || @warn "worklog: precompile matched nothing" f sig
end

@setup_workload begin
    items = sample_items()
    nodes = sample_nodes()
    @compile_workload begin
        try
            hermetic() do
                # The launch, the way `ui` makes it: the dashboard - a parse
                # and an `item_of` per row, one of them off the bundle
                # cache - then the adopted branches, the inbox's light rows and
                # the notices, and where the last session left off.
                write(Worklog.fetchedfile(), sample_facts())
                seed_cache("https://github.com/o/r/pull/1")
                seed_local(Worklog.utcnow())
                its = vcat(Worklog.loaditems(), Worklog.local_items())
                append!(its, Worklog.inbox_items(Set(x.url for x in its)))
                append!(its, Worklog.notice_items())
                st = Worklog.BState(vcat(its, items), "worklog")
                Worklog.restore_view!(st)
                # Both layouts: side by side above the split width, stacked below.
                for (w, h) in ((170, 50), (150, 40), (100, 30), (80, 24))
                    Worklog.render(st, w, h)
                end
                Worklog.refilter!(st)
                Worklog.apply_view!(st, Dict("show" => ["not-done", "done"], "state" => ["open"]))
                Worklog.apply_view!(st, Dict("show" => ["snoozed"], "kind" => "pr"))
                Worklog.filter_summary(st.filters, st.sort)
                Worklog.view_toml(st.filters, st.sort, "a name")

                # The filter pane is a second renderer over the same box.
                st.lmode = :filters
                Worklog.filter_rows(st)
                Worklog.filter_groups(Worklog.filter_rows(st))
                Worklog.render(st, 150, 40)
                Worklog.toggle_filter!(st)
                st.lmode = :items

                # A row the cursor re-read: `fetch_bundle` after its request.
                let cfg = Worklog.config(), file = Worklog.fetched("items")
                    for n in sample_graphql()
                        u = String(n.url)
                        old = Worklog.bundled(u, Worklog.jget(file, Symbol(u)))
                        r = Worklog.normalize(n, "review", cfg["login"])
                        Worklog.derive!(r, old, Dict{String,Any}(), cfg, Worklog.utcnow())
                        Worklog.item_of(Worklog.JSON.parse(Worklog.json_dumps(r)))
                    end
                end

                # The node kinds the cached thread does not have - a diff hunk,
                # a plain line - at the widths a pane is drawn at.
                st.nodes = nodes
                for w in (140, 96, 60)
                    Worklog.rows(st.nodes, w)
                end
                Worklog.detail_pane(st, items[1], 100, 30, true)
                Worklog.meta_lines(st, items[1], 44)
                Worklog.selrange(st)

                # A session, a key at a time through the loop's own turn
                # (`step!`): the thread, diff and checks of the first row, the
                # dialogs the keys open and the keys that answer them, the
                # marks, a search, the history, the worktree list, a click and
                # a wheel, a paste, and the quit question left unanswered.
                # Every move ends in `load_nodes!` and `load_meta!`, which
                # start a fetch for whatever the cache does not have - so this
                # is only safe because `hermetic` has taken the binaries and
                # the token away, and each such fetch fails before it forks
                # or connects.
                ctrl = Worklog.Controller()
                Worklog.push_view!(ctrl, st)
                Worklog.settle_all!(ctrl)
                for k in ("j", "k", "G", "g", "\e[B", "\e[A", "G", "w", "h", "\t", "n", "N",
                          "\t", "d", "[", "\e", "]", "\e", "c", "p", "h", "?", "\e",
                          "f", "j", "\r", "f", "'", "2", "'", "1", ";", "\e", "s", "\e",
                          "e", "z", "Z", "x", "x", "/", "r", "#", "\r", "/", :paste, "\e",
                          "`", "~", "\"", "\t", "j", "\e", "\e[<0;40;12M", "\e[<64;5;5M",
                          "q", "n")
                    step!(ctrl, k === :paste ? Worklog.PasteEvent("a paste") :
                                               Worklog.readevent(IOBuffer(k)))
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
