# The refresh: what a lane returns, what has gone quiet, and what a settled
# thread does next.

@testset "a batch in one process, not a loop of them" begin
    # `-` is the ref that means stdin. One mechanism for every command that
    # takes one, no new flag, and nothing a variadic ref list would have to be
    # told apart from the value argument.
    # The stream is an argument, so this is driven from an IOBuffer the way
    # `readevent` is rather than by taking stdin away from the test runner.
    @test W.stdin_lines(IOBuffer("julia#62841\n\n# a note\nhttps://github.com/o/r/pull/7  x\n")) ==
          ["julia#62841", "https://github.com/o/r/pull/7"]
    # A url needs no resolving, which is the difference between the two readers:
    # requiring one to be in facts.json would refuse exactly what `import` is for.
    @test W.refs("-", IOBuffer("https://github.com/o/r/pull/7\n")) ==
          ["https://github.com/o/r/pull/7"]
    # And an argument that is not `-` is still just that one ref.
    @test W.refs("https://github.com/o/r/pull/9") == ["https://github.com/o/r/pull/9"]
    # Nothing to act on says so rather than doing nothing quietly.
    @test_throws W.CliError W.refs("-", IOBuffer("\n#only comments\n"))

    # An inbox entry is how an imported item reaches the unread lane: no poll
    # will ever find one, since its repo is not watched - which is why it was
    # imported.
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml")
    try
        u = "https://github.com/o/r/issues/3"
        W.mark_read([u], W.utcnow())          # read from some earlier life
        @test W.read_at(u) !== nothing
        n = W.Events.inbox_add!([Dict{String,Any}(
            "url" => u, "repo" => "o/r", "number" => 3, "title" => "t",
            "is_pr" => false, "state" => "open", "author" => "a",
            "updated" => "2026-09-03T00:00:00Z", "comments" => 0,
            "labels" => String[], "mine" => false)])
        @test n == 1
        @test haskey(W.Events.load_inbox()["items"], u)
        # A second delivery of the same url is not a second entry, and with
        # `overwrite = false` it leaves what a *poll* wrote: much of what gets
        # imported is already in here with a comment count this caller does not
        # have, and marking it unread is the whole of what is wanted.
        rich = W.Events.load_inbox()["items"][u]
        rich["comments"] = 12
        inbox = W.Events.load_inbox(); inbox["items"][u] = rich
        W.Events.save_inbox(inbox)
        W.mark_read([u], W.utcnow())
        thin = Dict{String,Any}("url" => u, "repo" => "o/r", "number" => 3,
                                "title" => "t", "is_pr" => false, "state" => "open",
                                "author" => "a", "updated" => "2026-09-03T00:00:00Z",
                                "comments" => 0, "labels" => String[], "mine" => false)
        @test W.Events.inbox_add!([thin]; overwrite = false) == 1
        @test length(W.Events.load_inbox()["items"]) == 1
        @test W.Events.load_inbox()["items"][u]["comments"] == 12   # the poll's
        @test W.read_at(u) === nothing                       # still unread
        # And overwriting is what a caller that knows better asks for.
        W.Events.inbox_add!([thin])
        @test W.Events.load_inbox()["items"][u]["comments"] == 0
        # The read stamp is cleared, or it would hide the thing just delivered.
        @test W.read_at(u) === nothing
        # Nothing is claimed to have been polled: no cursor moves.
        @test isempty(W.Events.load_inbox()["cursors"])
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "a local ref is its own answer, as a url is" begin
    # `wl adopted local:o/r#branch DATE`, as `USAGE` has it. An adopted branch
    # is never in `fetched.json` - it is an item because `local.toml` says
    # `adopted` - so looking the ref up there refused exactly the one command
    # that takes one.
    @test W.resolve("local:o/r#topic") == "local:o/r#topic"
    @test W.resolve("local:o/r#topic") == W.localurl("o/r", "topic")
    # And the lookup still refuses a ref it cannot find, as before.
    @test_throws W.CliError W.resolve("nowhere#1")
end

@testset "the lane order is the file's, and a shape the scan cannot read degrades to sorted" begin
    # `[lanes]` is walked in file order because the first lane to claim a url
    # keeps it. Julia's TOML parser hands back a `Dict`, so the order is read
    # back out of the text - for the shapes `config.toml` actually uses.
    text = """
    [other]
    zz = 1
    [lanes]
    # a comment, and a blank line
    mine = "is:open author:@me"

    review = "is:open review-requested:@me"
    "quoted key" = "x"
    [after]
    aa = 1
    """
    @test W.table_key_order(text, "lanes") == ["mine", "review", "quoted key"]
    @test W.table_key_order(text, "nowhere") == String[]
    tbl = Dict("review" => 2, "mine" => 1, "quoted key" => 3)
    @test first.(W.ordered(tbl, text, "lanes")) == ["mine", "review", "quoted key"]

    # What it does not read: an inline table spanning lines. The parser accepts
    # it (TOML 1.1); the scan takes the continuation line for a key of its own
    # (`n`), which `ordered` drops because the parsed table has no such key, and
    # the keys the scan never saw come back appended in sorted order - "wrong
    # order", never "silently dropped". This is the documented degradation,
    # pinned so a change to the scan says so here.
    multi = """
    [lanes]
    second = { q = "b",
               n = 2 }
    first = "a"
    """
    @test W.table_key_order(multi, "lanes") == ["second", "n", "first"]
    tbl = Dict("second" => 2, "first" => 1, "zeta" => 3, "alpha" => 0)
    @test first.(W.ordered(tbl, multi, "lanes")) == ["second", "first", "alpha", "zeta"]
    # A key the file has and the table does not is not invented.
    @test first.(W.ordered(Dict("first" => 1), multi, "lanes")) == ["first"]
end

@testset "the notifications source, beside the repo polls" begin
    # A thread is one row per subject with one reason, and `subject.url` is an
    # API url in one of two shapes. Both land as the html url the inbox is
    # keyed by, `pull` singular.
    thread(url, type; reason = "mention", at = "2026-09-09T11:34:00Z") = Dict{String,Any}(
        "id" => "1", "unread" => false, "reason" => reason, "updated_at" => at,
        "last_read_at" => "2026-09-01T00:00:00Z",
        "subject" => Dict{String,Any}("title" => "t", "url" => url,
                                      "latest_comment_url" => nothing, "type" => type))
    E = W.Events
    r = E.thread_row(thread("https://api.github.com/repos/o/r/issues/469", "Issue"),
                     "me"; fetch = nothing)
    @test r["url"] == "https://github.com/o/r/issues/469"
    @test r["repo"] == "o/r" && r["number"] == 469 && r["is_pr"] == false
    @test r["lane"] == "notifications" && r["reason"] == "mention"
    @test !haskey(r, "why")              # the reason is the fact; words are the pane's
    @test r["updated"] == "2026-09-09T11:34:00Z"
    @test !haskey(r, "state")            # a thread does not know
    # `unread` and `last_read_at` are GitHub's read state, and never read.
    @test !haskey(r, "unread") && !haskey(r, "last_read_at")
    r = E.thread_row(thread("https://api.github.com/repos/o/r/pulls/7", "PullRequest";
                            reason = "review_requested"), "me"; fetch = nothing)
    @test r["url"] == "https://github.com/o/r/pull/7" && r["is_pr"] == true
    @test r["reason"] == "review_requested"
    @test E.thread_row(thread("https://api.github.com/repos/o/r/pulls/7", "PullRequest";
                              reason = "invitation"), "me"; fetch = nothing)["reason"] == "invitation"
    # Nothing here can open a release, a commit or a discussion.
    for (u, k) in (("https://api.github.com/repos/o/r/releases/5", "Release"),
                   ("https://api.github.com/repos/o/r/commits/abc", "Commit"),
                   ("https://api.github.com/repos/o/r/discussions/3", "Discussion"),
                   (nothing, "RepositoryVulnerabilityAlert"))
        @test E.thread_row(thread(u, k), "me"; fetch = nothing) === nothing
    end

    # A url new to the inbox is filled in with one GET of its subject, at the
    # issues endpoint for both kinds, and the thread's own keys win over it.
    asked = String[]
    issue = Dict{String,Any}(
        "html_url" => "https://github.com/o/r/pull/7", "number" => 7, "title" => "T",
        "repository_url" => "https://api.github.com/repos/o/r", "state" => "closed",
        "user" => Dict{String,Any}("login" => "me"), "updated_at" => "2026-09-09T00:00:00Z",
        "comments" => 3, "labels" => [Dict{String,Any}("name" => "bug")],
        "pull_request" => Dict{String,Any}())
    t = thread("https://api.github.com/repos/o/r/pulls/7", "PullRequest")
    r = E.thread_row(t, "me"; fetch = p -> (push!(asked, p); [issue]))
    @test asked == ["/repos/o/r/issues/7"]
    @test r["state"] == "closed" && r["author"] == "me" && r["mine"] == true
    @test r["labels"] == ["bug"] && r["comments"] == 3
    # The subject's clock, not the thread's: the thread's is delivery time,
    # 2-46s after the event, and the poll writes the subject's for the same
    # event on the same url.
    @test r["updated"] == "2026-09-09T00:00:00Z"
    @test r["reason"] == "mention" && r["lane"] == "notifications"
    # A fetch that fails leaves the thin row rather than losing the thread.
    r = E.thread_row(t, "me"; fetch = p -> throw(E.ApiError("404")))
    @test r["url"] == "https://github.com/o/r/pull/7" && !haskey(r, "state")

    # The loop. The notifications source goes first and rows merge, so the poll
    # of the same repo lands its state and author on top of the thread's reason.
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml")
    try
        asks = Dict{String,String}()
        srcs = [
            (label = "notifications",
             fetch = since -> (asks["notifications"] = since; [
                 thread("https://api.github.com/repos/o/r/pulls/7", "PullRequest"),
                 thread("https://api.github.com/repos/o/r/issues/9", "Issue";
                        reason = "subscribed", at = "2026-09-10T00:00:00Z"),
                 thread("https://api.github.com/repos/o/r/releases/5", "Release";
                        at = "2026-09-11T00:00:00Z")]),
             overlap = E.OVERLAP_REST,
             row = (t, _) -> E.thread_row(t, "me"; fetch = p -> [issue])),
            (label = "o/r",
             fetch = since -> (asks["o/r"] = since; [issue]),
             overlap = E.OVERLAP_REST,
             row = (r, _) -> E.issue_row(r, "me")),
        ]
        at = W.DateTime(2026, 9, 13, 12)
        items, got = E.sync!(srcs, at; now = () -> W.DateTime(2026, 9, 8, 12),
                             backfill = W.Day(1), watched = () -> Set{String}())
        @test got == 3                                   # the release is skipped
        # First sight: from GitHub's now less the backfill, less the overlap.
        @test asks["notifications"] == "2026-09-07T11:55:00Z"
        @test asks["o/r"] == "2026-09-07T11:55:00Z"
        pr = items["https://github.com/o/r/pull/7"]
        @test pr["state"] == "closed" && pr["author"] == "me"    # the poll's
        @test pr["reason"] == "mention" && pr["lane"] == "notifications"  # the thread's
        @test pr["updated"] == "2026-09-09T00:00:00Z"   # one clock, the subject's
        # The issue only the thread saw was filled in by the fetch it was owed.
        is = items["https://github.com/o/r/issues/9"]
        @test is["reason"] == "subscribed" && is["state"] == "closed"
        # The cursor is GitHub's time when the poll began - not the newest
        # row the source returned, which is only safe when the walk is
        # ascending by `updated`; the poll's start is safe in any order, and
        # the rows the walk read late are read twice, which is free.
        inbox = E.load_inbox()
        @test inbox["cursors"]["notifications"] == "2026-09-08T12:00:00Z"
        @test inbox["cursors"]["o/r"] == "2026-09-08T12:00:00Z"
        # Within the ttl nothing is asked again - and `now` is not asked
        # either, since no source is due.
        empty!(asks)
        E.sync!(srcs, at + W.Second(30); now = () -> error("not due"), watched = () -> Set{String}())
        @test isempty(asks)
        # Past it, each is asked from behind its own cursor, and the cursor
        # moves to this poll's start. Never backwards: a poll whose start is
        # before the cursor leaves it.
        E.sync!(srcs, at + W.Minute(5); now = () -> W.DateTime(2026, 9, 13, 12, 5), watched = () -> Set{String}())
        @test asks["notifications"] == "2026-09-08T11:55:00Z"
        @test asks["o/r"] == "2026-09-08T11:55:00Z"
        @test E.load_inbox()["cursors"]["o/r"] == "2026-09-13T12:05:00Z"
        E.sync!(srcs, at + W.Minute(10); now = () -> W.DateTime(2026, 9, 13, 12, 1), watched = () -> Set{String}())
        @test E.load_inbox()["cursors"]["o/r"] == "2026-09-13T12:05:00Z"
        # The cursors are local.toml's: one `cursor` per `source:` block,
        # what the poll advanced, with the inbox's copy beside them - so a
        # lost fetched.json does not cost the events of the gap.
        @test W.source_cursors()["o/r"] == "2026-09-13T12:05:00Z"
        @test W.source_cursors()["notifications"] == "2026-09-13T12:05:00Z"
        # And the file's is what the next poll asks from, over the inbox's
        # copy: set behind, the poll re-asks from there.
        W.set_source_cursors!(Dict("o/r" => "2026-09-13T11:00:00Z"))
        empty!(asks)
        E.sync!(srcs, at + W.Minute(15); now = () -> W.DateTime(2026, 9, 13, 12, 15), watched = () -> Set{String}())
        @test asks["o/r"] == "2026-09-13T10:55:00Z"
        # A source that answers with its own bound - the first request's
        # `Date` less its length - sets the cursor from that, and the clock is
        # not asked at all.
        dated = [(label = "o/r",
                  fetch = since -> ([issue], W.DateTime(2026, 9, 13, 12, 20, 30)),
                  overlap = E.OVERLAP_REST, row = (r, _) -> E.issue_row(r, "me"))]
        E.sync!(dated, at + W.Minute(30); now = () -> error("the page said when"), watched = () -> Set{String}())
        @test E.load_inbox()["cursors"]["o/r"] == "2026-09-13T12:20:30Z"
        # And a poll row arriving over an existing thread row keeps the reason.
        @test E.load_inbox()["items"]["https://github.com/o/r/pull/7"]["reason"] == "mention"
        # `poll_item` reads the lane and the reason off the row.
        it = W.poll_item(E.load_inbox()["items"]["https://github.com/o/r/pull/7"])
        @test it.lane == "notifications"
        @test it.state == "CLOSED"
        @test W.poll_item(E.issue_row(issue, "me")).lane == "activity"
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end

    # The token. `token()`'s is used when it is a person's - off the sandbox,
    # `gh auth token` - and not when it is a GitHub App's, which cannot read
    # the endpoint; then the file is read, and with neither the source is
    # skipped and every other source still polls.
    keepp, keepc, keept = E.PAT_FILE[], E._PAT[], E.TOKEN_FILE[]
    try
        E.TOKEN_FILE[] = joinpath(d, "sandbox-token"); write(E.TOKEN_FILE[], "ghu_app\n")
        E.PAT_FILE[] = joinpath(d, "no-such-token"); E._PAT[] = nothing
        cfg = Dict{String,Any}("events" => Dict{String,Any}("repos" => ["o/r", "me/*"]))
        @test E.pat() === nothing
        labels = [s.label for s in E.sources(cfg, "me"; verbose = false)]
        @test labels == ["o/r", "me/* is:issue", "me/* is:pull-request"]
        # With the file, it is first in the list.
        write(E.PAT_FILE[], "ghp_notreal\n")
        @test E.pat()[2] == E.PAT_FILE[]
        labels = [s.label for s in E.sources(cfg, "me"; verbose = false)]
        @test labels[1] == "notifications" && length(labels) == 4
        # And nothing else configured is not nothing to poll.
        @test [s.label for s in E.sources(Dict{String,Any}(), "me"; verbose = false)] ==
              ["notifications"]
        # A person's token from `token()` needs no file at all.
        rm(E.PAT_FILE[]); E._PAT[] = nothing
        write(E.TOKEN_FILE[], "gho_person\n")
        @test E.pat()[2] == E.TOKEN_FILE[]
        # On the source's first sight - the backfill - a watched repository's
        # thread stays thin rather than costing a fetch each; a thread that
        # names you is filled in. (Only the thin path is exercised here: the
        # other one is a request.)
        src = first(E.sources(Dict{String,Any}(), "me"; verbose = false))
        t = thread("https://api.github.com/repos/o/r/issues/5", "Issue"; reason = "subscribed")
        @test !haskey(src.row(t, true), "state")
        @test E.involved_reason("mention") && !E.involved_reason("subscribed")
        @test E.app_token("ghs_install") && !E.app_token("github_pat_x")
    finally
        E.PAT_FILE[] = keepp; E._PAT[] = keepc; E.TOKEN_FILE[] = keept
    end
end

@testset "a source the poll cannot get an answer from stands in the footer until it does" begin
    # The launch poll runs before there is a frame and reports to nobody, so
    # the one line of its report the reader has to act on - a lane that
    # FAILED - is written down beside the stamp, and the footer reads it back
    # as a standing note: ahead of a theme complaint, behind a logged error,
    # and gone the moment the source answers.
    E = W.Events
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml")
    write(W.LOCAL[], "")
    isfile(W.errlog()) && rm(W.errlog())
    try
        broken = Ref(true)
        srcs = [(label = "o/r",
                 fetch = since -> broken[] ? throw(E.ApiError("401 Bad credentials")) : [],
                 overlap = E.OVERLAP_REST, row = (r, _) -> nothing),
                (label = "p/q", fetch = since -> [], overlap = E.OVERLAP_REST,
                 row = (r, _) -> nothing)]
        at = W.DateTime(2026, 9, 17, 9, 0)
        said = IOBuffer()
        _, r = W.reporting(() -> E.sync!(srcs, at; now = () -> at, watched = () -> Set{String}()), said)
        @test r.warnings == 1 && occursin("o/r", String(take!(said)))
        # When, then why; the source that answered is not here.
        fs = E.failing()
        @test length(fs) == 1
        @test fs[1].label == "o/r" && fs[1].since == "2026-09-17T09:00:00Z" &&
              fs[1].why == "401 Bad credentials"
        # The note: what to do first, GitHub's words last, where a cut at the
        # edge takes the part that can run long.
        note = W.failnote(fs, at + W.Minute(3))
        @test startswith(note, "o/r: the poll FAILED 3m ago")
        @test occursin("until it answers", note) && endswith(note, "401 Bad credentials")
        @test W.standing_note(at, fs) == W.failnote(fs, at)
        push!(W.THEME_NOTES, "no such colour")
        try
            @test W.standing_note(at, fs) == W.failnote(fs, at)      # ahead of the theme
            @test W.standing_note(at, ()) == "theme: no such colour"
        finally
            pop!(W.THEME_NOTES)
        end
        W.logerror!(ErrorException("x"), backtrace(), "test")
        @test occursin("delete it to clear", W.standing_note(at, fs))  # behind an error
        rm(W.errlog())
        # A second failing source is counted, not listed.
        E.sync!([(label = "z/z", fetch = since -> throw(E.ApiError("500")),
                  overlap = E.OVERLAP_REST, row = (r, _) -> nothing)],
                at + W.Minute(1); now = () -> at, watched = () -> Set{String}())
        fs2 = E.failing()
        @test [f.label for f in fs2] == ["o/r", "z/z"]
        @test occursin("(and 1 more)", W.failnote(fs2, at + W.Minute(1)))
        # An entry from before the reason was kept is a stamp alone.
        inbox = E.load_inbox()
        inbox["failed"]["old/one"] = "2026-09-16T00:00:00Z"
        E.save_inbox(inbox)
        old = only(f for f in E.failing() if f.label == "old/one")
        @test old.why == "" && old.since == "2026-09-16T00:00:00Z"
        @test !occursin("\u00b7", W.failnote([old], at))
        # The browser holds the table as the item list was built, and takes
        # it again when `fetched.json` lands - not at every frame.
        st = W.BState(W.Item[], "worklog")
        @test [f.label for f in st.failing] == ["o/r", "old/one", "z/z"]
        @test occursin("the poll FAILED", W.render(st, 120, 40))
        # The next answer clears the source, and the reload carries that in.
        broken[] = false
        E.sync!(srcs, at + W.Minute(5); now = () -> at, watched = () -> Set{String}())
        @test [f.label for f in E.failing()] == ["old/one", "z/z"]
        @test [f.label for f in st.failing] == ["o/r", "old/one", "z/z"]   # not yet
        st.factsat = 0.0; st.reload = true
        @test W.reload_data!(st)
        @test [f.label for f in st.failing] == ["old/one", "z/z"]
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
        isfile(W.errlog()) && rm(W.errlog())
    end
end

@testset "the corpus is asked by url when a clock says it moved" begin
    # The open work is searched for whole; everything else is kept as it was
    # until the notifications source or the repo poll says it moved, and then
    # asked for by url. The clock is compared against when the bundle was
    # fetched - both GitHub's time - and not against the row's own `updated`,
    # which is a different clock for the same event: a thread's `updated_at`
    # is delivery time, 2 to 46 seconds after the subject's.
    # The old row is the file's, which is JSON3 and keyed by symbol - as it is
    # in the refresh, where `old` is what `fetched.json` holds.
    J(d) = W.JSON3.read(W.json_dumps(d))
    old = J(Dict{String,Any}("url" => "u", "updated" => "2026-09-13T10:00:00Z",
                             "fetched_at" => "2026-09-13T10:05:00Z", "lane" => "mine"))
    e(at) = Dict{String,Any}("url" => "u", "updated" => at)
    @test !W.stale_by(nothing, old)                                # no clock saw it
    @test !W.stale_by(e("2026-09-13T10:00:20Z"), old)              # delivery lag
    @test !W.stale_by(e("2026-09-13T10:05:00Z"), old)
    @test W.stale_by(e("2026-09-13T10:05:01Z"), old)
    # A row from before there was a stamp is stale once.
    @test W.stale_by(e("2026-01-01T00:00:00Z"), J(Dict{String,Any}("url" => "u")))

    # Which threads are brought in on first sight: the ones that name you. A
    # watched repository's traffic, and the poll's own rows, stay light.
    for reason in ("mention", "team_mention", "review_requested", "assign",
                   "author", "comment", "state_change", "manual")
        @test W.involved(reason)
    end
    @test !W.involved("subscribed") && !W.involved(nothing) && !W.involved("")
    # The lanes retired on 2026-09-13, whose rows a file from before still
    # carries and which nothing will ever return again.
    @test W.retired_lane("firehose") && W.retired_lane("mentioned_team_pr") &&
          W.retired_lane("commented_issue")
    @test !W.retired_lane("mine") && !W.retired_lane("notifications") &&
          !W.retired_lane("carried")
    # What the thread contributes to the row built for it.
    r = W.thread_facts!(Dict{String,Any}("url" => "u"),
                        Dict{String,Any}("reason" => "mention"))
    @test r["reason"] == "mention"
    @test W.thread_facts!(Dict{String,Any}("url" => "u"), nothing) == Dict{String,Any}("url" => "u")
    # And off the row being replaced when the inbox has no thread any more: a
    # mention that was read and then moved in a way only the poll saw.
    r = W.thread_facts!(Dict{String,Any}("url" => "u"), Dict{String,Any}("url" => "u"),
                        J(Dict{String,Any}("reason" => "mention")))
    @test r["reason"] == "mention"
    # First sight is the newest thing GitHub says happened, not only a push
    # or a comment: the review request that brought the row is on it.
    @test W.first_seen_at(Dict{String,Any}("updated" => "2026-09-01T00:00:00Z",
        "last_comment_at" => "2026-09-02T00:00:00Z",
        "review_requested_at" => "2026-09-03T00:00:00Z")) == "2026-09-03T00:00:00Z"
    @test W.first_seen_at(Dict{String,Any}("updated" => "2026-09-01T00:00:00Z")) == "2026-09-01T00:00:00Z"

    # A kept row is derived against itself, and nothing about it moves: the
    # mark stays, the carried keys stay, and only what depends on the clock -
    # the second look - is re-read.
    cfg = W.config()
    at = W.DateTime(2026, 9, 13, 12)
    row = Dict{String,Any}(
        "url" => "https://github.com/a/b/pull/1", "type" => "PullRequest",
        "lane" => "review", "state" => "OPEN", "mine" => false, "author" => "alice",
        "created" => "2026-09-01T00:00:00Z", "updated" => "2026-09-10T10:00:00Z",
        "labels" => String[], "head_sha" => "abc", "head_by" => "alice",
        "head_at" => "2026-09-10T10:00:00Z", "last_comment_at" => nothing,
        "last_comment_by" => nothing, "their_head" => "abc",
        "their_comment_at" => nothing, "human_comment_at" => nothing,
        "moved_at" => "2026-09-10T10:00:00Z", "fetched_at" => "2026-09-10T10:01:00Z",
        "track" => "loose")
    kept = W.kept_row(J(row))
    @test kept == row
    W.derive!(kept, J(row), Dict{String,Any}(), cfg, at)
    @test kept["moved_at"] == "2026-09-10T10:00:00Z" && kept["new"] == false
    @test kept["their_head"] == "abc" && kept["fetched_at"] == "2026-09-10T10:01:00Z"
    @test isempty(W.change_of(J(row), kept))
    @test kept["slept"] == false
    # The key that moved it is kept beside the stamp. A row from before there
    # was one has none to keep, and is caught up off the stamp: here the head's
    # time is the stamp, so it was the push.
    @test kept["moved_by"] == "their_head"
    @test W.moved_key(Dict{String,Any}("track" => "normal", "moved_at" => "2026-09-10T10:00:00Z",
                                       "head_at" => "2026-09-10T09:00:00Z")) == ""
    @test W.moved_key(Dict{String,Any}("track" => "normal", "moved_at" => "2026-09-10T10:00:00Z",
                                       "review_at" => "2026-09-10T10:00:00Z")) == "review_at"
    @test W.moved_key(Dict{String,Any}("track" => "loose", "moved_at" => "2026-09-10T10:00:00Z",
                                       "their_comment_at" => "2026-09-10T10:00:00Z")) == ""
    # First sight: the mark is what GitHub says, and the row is new.
    fresh = W.kept_row(row); delete!(fresh, "moved_at")
    W.derive!(fresh, nothing, Dict{String,Any}(), cfg, at)
    @test fresh["new"] == true && fresh["moved_at"] == "2026-09-10T10:00:00Z"
    @test fresh["moved_by"] == "new"
    # And a push by somebody else since is a movement, said as one.
    pushed = W.kept_row(J(row)); pushed["head_sha"] = "def"; pushed["head_at"] = "2026-09-12T09:00:00Z"
    W.derive!(pushed, J(row), Dict{String,Any}(), cfg, at)
    @test pushed["moved_at"] == "2026-09-12T09:00:00Z"
    @test pushed["moved_by"] == "their_head"
    @test W.change_of(J(row), pushed) == "new push"
    # A refresh that finds nothing moved keeps the key with the stamp.
    still = W.kept_row(J(pushed))
    W.derive!(still, J(pushed), Dict{String,Any}(), cfg, at)
    @test still["moved_at"] == "2026-09-12T09:00:00Z" && still["moved_by"] == "their_head"
    # A hand-typed snooze with no read stamp is reported for stamping, once
    # for all of them, by the caller.
    W.derive!(kept, J(row), Dict{String,Any}("snooze" => "2026-09-20"), cfg, at)
    @test kept["slept"] == true && kept["woken"] == false
    # And one whose wake has passed is reported for writing down as unread,
    # the snooze gone, the same way.
    W.derive!(kept, J(row), Dict{String,Any}("snooze" => "2026-09-01", "read" => "2026-09-10T10:00:00Z"), cfg, at)
    @test kept["slept"] == false && kept["woken"] == true
end

@testset "a woken snooze is over: unread implies no snooze" begin
    # The browser shows a row unread from the moment its wake passes, per
    # frame; but every mark stamps the last movement, which is under the
    # wake, so a snooze left standing would keep the row unread whatever was
    # pressed. So the refresh writes a woken row down - `read = ""`, the
    # snooze gone, the head kept - and `r`, `x` and `wl read` on one the
    # refresh has not reached drop the snooze with the stamp they write.
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    try
        u = "https://github.com/o/r/pull/7"
        row = Dict{String,Any}("url" => u, "type" => "PullRequest", "lane" => "mine",
            "state" => "OPEN", "mine" => true, "author" => "vtjnash", "title" => "t",
            "number" => 7, "repo" => "o/r", "labels" => String[],
            "created" => "2026-09-01T00:00:00Z", "updated" => "2026-09-01T00:00:00Z",
            "moved_at" => "2026-09-01T00:00:00Z", "fetched_at" => "2026-09-02T00:00:00Z",
            "track" => "normal", "ref" => "r#7")
        W.save_fetched(Dict{String,Any}("items" => Dict(u => row)))
        W.set_read_mark(u, "2026-09-01T00:00:00Z", "cafe")
        W.set_fields(u, ["snooze" => "2026-09-05T00:00:00Z"])
        it = W.item_of(W.fetched("items")[Symbol(u)])
        m(at) = W.Marks(read = W.load_read(), wake = W.wake_map(), now = W.stamp(at))
        @test W.seen_of(it, m(W.DateTime(2026, 9, 4))) === :read
        @test W.seen_of(it, m(W.DateTime(2026, 9, 10))) === :unread     # woken
        # The refresh writes it down.
        srch(q) = (Any[], 4, 0)
        # Into a buffer, and the summary is its last line: no warnings, so it
        # says none - the count is the refresh's own, off its report.
        said = IOBuffer()
        @test W.refresh(String[], W.DateTime(2026, 9, 10); io = said, search = srch,
                        fetch_url_map = x -> W.OrderedDict{String,Any}(), poll = (a...) -> Any[],
                        open_list = (a...; kw...) -> []) == 0
        summary = last(filter(!isempty, split(String(take!(said)), "\n")))
        @test occursin(r"^  \d+ items, \d+ changes, \d+ rate-limit points$", summary)
        @test W.mark_at(u, "read") == "" && W.get_field(u, "snooze") === nothing
        @test W.read_head(u) == "cafe"                         # still where you were
        @test W.seen_of(it, m(W.DateTime(2026, 9, 10))) === :unread
        # And the wake is remembered, so the pane can say what woke it.
        @test W.get_field(u, "last_snooze") == "2026-09-05T00:00:00Z"
        # `r` on a woken row the refresh has not reached: read, the snooze
        # gone; `z` puts it back, and the row is unread again for the wake.
        W.set_read(u, "2026-09-01T00:00:00Z")
        W.set_fields(u, ["snooze" => "2026-09-05T00:00:00Z"])
        st = W.BState([it], "t"); st.filters = W.everything(); W.refilter!(st)
        st.sel = 1; st.loaded = string(u, ":", st.mode); st.metakey = u; st.nodes = W.Node[]
        ctrl = W.Controller()
        now = W.DateTime(2026, 9, 10)
        W.set_fields(u, ["last_snooze" => nothing])
        W.handle!(st, Int('r'), ctrl, now)
        @test st.status == "marked read" && W.get_field(u, "snooze") === nothing
        @test W.get_field(u, "last_snooze") == "2026-09-05T00:00:00Z"
        @test W.seen_of(it, W.Marks(st, now)) === :read
        W.handle!(st, Int('z'), ctrl, now)
        @test W.get_field(u, "snooze") == "2026-09-05T00:00:00Z"
        @test W.get_field(u, "last_snooze") === nothing
        @test W.seen_of(it, W.Marks(st, now)) === :unread
        # The pane says what brought the row back: the wake, a movement
        # before it, or that the snooze was cleared by hand - and it says
        # there was a snooze whether or not the wake has arrived.
        # The row and what wrapped under it, at the test's clock rather than
        # the machine's: the wake is asleep or woken by `at`, and the pane
        # says how far off it is.
        snoozeline(x) = begin
            W.refilter!(st)
            ls = W.astrip.(W.meta_lines(st, x, 60, now))
            i = findfirst(l -> startswith(l, "snoozed"), ls)
            i === nothing && return ""
            j = i
            while j < length(ls) && startswith(ls[j + 1], " "^10)
                j += 1
            end
            join(strip.(ls[i:j]), " ")
        end
        @test occursin("woke 2026-09-05", snoozeline(it))              # woken, snooze still on file
        W.mark_read_moved([u], now)                                    # `wl read`: ends it, remembers it
        @test W.get_field(u, "snooze") === nothing && W.get_field(u, "last_snooze") == "2026-09-05T00:00:00Z"
        @test occursin("woke 2026-09-05", snoozeline(it))              # woken, snooze gone
        W.set_fields(u, ["snooze" => "2026-09-20T00:00:00Z", "last_snooze" => "2026-09-20T00:00:00Z"])
        @test occursin("until 2026-09-20", snoozeline(it)) && !occursin("moved", snoozeline(it))
        moved = W.with(it; moved_at = "2026-09-08T00:00:00Z")
        # Unread under the snooze is the `why` row's to say, with what moved.
        @test occursin("until 2026-09-20", snoozeline(moved)) && !occursin("moved", snoozeline(moved))
        W.set_fields(u, ["snooze" => nothing])
        @test occursin("until 2026-09-20", snoozeline(it)) && occursin("cleared", snoozeline(it))
        W.set_fields(u, ["snooze" => "2026-09-05T00:00:00Z", "last_snooze" => nothing]); W.refilter!(st)
        # A snooze still to come is left alone by `r`: the row is read, the
        # wake stands.
        W.set_fields(u, ["snooze" => "2026-09-20T00:00:00Z"]); W.refilter!(st)
        W.handle!(st, Int('r'), ctrl, now)                    # unread
        W.handle!(st, Int('r'), ctrl, now)                    # read
        @test W.get_field(u, "snooze") == "2026-09-20T00:00:00Z"
        # `x` on a woken row files it read, and undo restores the snooze.
        W.set_read(u, "2026-09-01T00:00:00Z")
        W.set_fields(u, ["snooze" => "2026-09-05T00:00:00Z"]); W.refilter!(st)
        W.archive!(st, it, now)
        @test W.get_field(u, "snooze") === nothing && W.seen_of(it, W.Marks(st, now)) === :read
        W.handle!(st, Int('z'), ctrl, now)
        @test W.get_field(u, "snooze") == "2026-09-05T00:00:00Z" && W.get_field(u, "archived") === nothing
        # And `wl read`, which reads the wake map itself.
        @test W.mark_read_moved([u], now) == 1
        @test W.get_field(u, "snooze") === nothing && W.read_at(u) == it.moved_at
        @test W.seen_of(it, m(now)) === :read
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "the row under the cursor is made exact from the cache, not the file" begin
    # The refresh writes `items` whole at the end of a minute of network, so a
    # row the browser fetched by url goes into `cache/` under `bundle:<url>`,
    # and whoever reads `items` takes the cached row when it is the newer.
    keepdir = W.CACHE_DIR[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    try
        u = "https://github.com/a/b/pull/9"
        file = W.JSON3.read("""{"url":"$u","fetched_at":"2026-09-13T10:00:00Z","title":"old"}""")
        @test W.bundle_of(u) === nothing
        @test W.bundled(u, file) === file
        @test W.bundled(u, nothing) === nothing
        W.cache_put(W.bundle_key(u), Dict("url" => u, "fetched_at" => "2026-09-13T11:00:00Z",
                                          "title" => "new"))
        @test W.bundled(u, file)["title"] == "new"
        @test W.bundled(u, nothing)["title"] == "new"       # a light row, promoted
        # Older than the file: the file wins, and the cache is left alone.
        W.cache_put(W.bundle_key(u), Dict("url" => u, "fetched_at" => "2026-09-13T09:00:00Z",
                                          "title" => "stale"))
        @test W.bundled(u, file) === file
        # How old the bundle behind an item is, and `Inf` for a light row.
        it = W.Item(url = u, ref = "b#9", repo = "a/b", number = 9, title = "t",
                    fetched = "2026-09-13T10:00:00Z")
        @test W.bundle_age(it, W.DateTime(2026, 9, 13, 10, 2)) == 120.0
        @test W.bundle_age(W.Item(url = u, ref = "b#9", repo = "a/b", number = 9,
                                  title = "t")) == Inf
        # The bundle rides on the quiet re-read, once per selection, and never
        # on the load that puts the row up: the gate, without the network.
        st = mkstate()
        it2 = st.items[st.sel]
        @test isempty(it2.fetched) || W.bundle_age(it2) >= 0
        st.bundletried = it2.url
        st.metakey = it2.url
        @test !W.refresh_meta!(st) || st.bundlepending === nothing
    finally
        W.CACHE_DIR[] = keepdir
    end
end

@testset "the refresh keeps, asks and lets go, by clock" begin
    # The loop itself, driven through its three seams - the lane search, the
    # by-url fetch, the clock - against a corpus in a disposable file.
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    node(url, n; kw...) = W.JSON3.read(W.json_dumps(merge(Dict{String,Any}(
        "__typename" => "Issue", "url" => url, "number" => n, "title" => "t$n",
        "createdAt" => "2026-09-01T00:00:00Z", "updatedAt" => "2026-09-10T00:00:00Z",
        "state" => "OPEN", "repository" => Dict("nameWithOwner" => "o/r"),
        "author" => Dict("login" => "alice"), "milestone" => nothing,
        "assignees" => Dict("nodes" => []), "labels" => Dict("nodes" => []),
        "timelineItems" => Dict("nodes" => []), "comments" => Dict("nodes" => [])),
        Dict{String,Any}(String(k) => v for (k, v) in kw))))
    U(n) = "https://github.com/o/r/issues/$n"
    at = W.DateTime(2026, 9, 13, 12)
    row(n; kw...) = merge(Dict{String,Any}(
        "url" => U(n), "type" => "Issue", "lane" => "mine", "state" => "OPEN",
        "mine" => true, "author" => "vtjnash", "title" => "t$n", "number" => n,
        "repo" => "o/r", "labels" => String[], "created" => "2026-09-01T00:00:00Z",
        "updated" => "2026-09-10T00:00:00Z", "moved_at" => "2026-09-10T00:00:00Z",
        "fetched_at" => "2026-09-12T00:00:00Z", "track" => "normal", "ref" => "r#$n"),
        Dict{String,Any}(String(k) => v for (k, v) in kw))
    keeppat = W.Events._PAT[]
    try
        W.Events._PAT[] = ("a person's token", "test")
        # The corpus from last time: 1 is open work; 2 is carried, quiet and
        # over; 3 is carried and a clock says it moved; 4 is from a retired
        # lane, kept as it was like anything else; 5 is carried, moved, and
        # the fetch will not answer for it.
        W.save_fetched(Dict{String,Any}("items" => Dict(
            U(1) => row(1), U(2) => row(2; lane = "landed", state = "MERGED"),
            U(3) => row(3; lane = "landed"),
            U(4) => row(4; lane = "commented_issue"), U(5) => row(5; lane = "reviewed"))))
        asked = String[]
        srch(q) = occursin("author:", q) ? ([node(U(1), 1)], 4, 1) : (Any[], 4, 0)
        function byurl(urls)
            append!(asked, urls)
            out = W.OrderedDict{String,Any}(u => nothing for u in urls)
            U(3) in urls && (out[U(3)] = node(U(3), 3; updatedAt = "2026-09-13T10:00:00Z",
                comments = Dict("nodes" => [Dict("author" => Dict("login" => "bob"),
                                                 "createdAt" => "2026-09-13T10:00:00Z")])))
            # 6 is a thread that names you, new to the corpus; 7 a watched
            # repository's traffic, which stays light and is never asked.
            U(6) in urls && (out[U(6)] = node(U(6), 6; updatedAt = "2026-09-13T09:00:00Z",
                comments = Dict("nodes" => [Dict("author" => Dict("login" => "bob"),
                                                 "createdAt" => "2026-09-13T09:00:00Z")])))
            out
        end
        clock(cfg, login, at) = [
            Dict{String,Any}("url" => U(3), "updated" => "2026-09-13T10:00:20Z"),
            Dict{String,Any}("url" => U(5), "updated" => "2026-09-13T11:00:00Z"),
            Dict{String,Any}("url" => U(2), "updated" => "2026-09-11T23:59:00Z"),  # before fetched_at
            Dict{String,Any}("url" => U(6), "updated" => "2026-09-13T09:00:10Z",
                             "lane" => "notifications", "reason" => "mention"),
            Dict{String,Any}("url" => U(7), "updated" => "2026-09-13T09:00:10Z",
                             "lane" => "notifications", "reason" => "subscribed")]
        @test W.refresh(String[], at; search = srch, fetch_url_map = byurl, poll = clock, open_list = (a...; kw...) -> []) == 0
        @test sort(asked) == [U(3), U(5), U(6)]
        its = W.fetched("items")
        have = sort(String.(collect(keys(its))))
        @test have == [U(1), U(2), U(3), U(4), U(5), U(6)]  # 7 never in: nobody asked
        @test its[Symbol(U(4))].lane == "commented_issue" && W.in_pile(its[Symbol(U(4))])
        # The open work, fetched and stamped this run.
        @test its[Symbol(U(1))].fetched_at >= "2026-09-13T12:00:00Z" && its[Symbol(U(1))].lane == "mine"
        # Kept as it was: the stamp and the mark it had.
        @test its[Symbol(U(2))].fetched_at == "2026-09-12T00:00:00Z"
        @test its[Symbol(U(2))].moved_at == "2026-09-10T00:00:00Z" && its[Symbol(U(2))].new == false
        # Asked, answered, moved: bob's comment dates it, the lane stays.
        @test its[Symbol(U(3))].moved_at == "2026-09-13T10:00:00Z"
        @test its[Symbol(U(3))].lane == "landed" && its[Symbol(U(3))].fetched_at >= "2026-09-13T12:00:00Z"
        # Asked and not answered: kept as it was, not dropped.
        @test its[Symbol(U(5))].fetched_at == "2026-09-12T00:00:00Z"
        # Brought in with what the thread said, and the reply owed read off it.
        @test its[Symbol(U(6))].reason == "mention" && its[Symbol(U(6))].lane == "notifications"
        @test its[Symbol(U(6))].new == true && !isempty(its[Symbol(U(6))].reply)

        # A url that answers under another name - the repository moved - is a
        # row under the new name, with the old row as what it replaces, and
        # the old name goes: no clock will ever say it again.
        asked = String[]
        moved(urls) = W.OrderedDict{String,Any}(U(3) => node("https://github.com/o/moved/issues/3", 3;
                            repository = Dict("nameWithOwner" => "o/moved"),
                            updatedAt = "2026-09-13T11:30:00Z"))
        clock2(cfg, login, at) = [Dict{String,Any}("url" => U(3), "updated" => "2026-09-13T13:00:00Z")]
        # And the inbox row under the old name goes with it: no corpus row
        # will ever be under that name to consume it, and kept it would be
        # asked by url on every run and follow the same redirect each time.
        inbox = W.Events.load_inbox()
        inbox["items"][U(3)] = Dict{String,Any}("url" => U(3), "updated" => "2026-09-13T13:00:00Z")
        W.Events.save_inbox(inbox)
        @test W.refresh(String[], W.DateTime(2026, 9, 13, 14); search = srch,
                        fetch_url_map = moved, poll = clock2, open_list = (a...; kw...) -> []) == 0
        its = W.fetched("items")
        @test haskey(its, Symbol("https://github.com/o/moved/issues/3")) && !haskey(its, Symbol(U(3)))
        @test its[Symbol("https://github.com/o/moved/issues/3")].lane == "landed"
        @test its[Symbol("https://github.com/o/moved/issues/3")].new == false
        @test !haskey(W.Events.load_inbox()["items"], U(3))

        # The whole fetch failing keeps every asked row as it was.
        boom(urls) = throw(W.FetchError("secondary rate limit"))
        clock3(cfg, login, at) = [Dict{String,Any}("url" => U(2), "updated" => "2026-09-13T15:00:00Z")]
        @test W.refresh(String[], W.DateTime(2026, 9, 13, 16); search = srch,
                        fetch_url_map = boom, poll = clock3, open_list = (a...; kw...) -> []) == 0
        @test haskey(W.fetched("items"), Symbol(U(2)))

        # The refresh derives against the browser's bundle when that is the
        # newer, so a bool that became true is dated once - by whoever saw it.
        keepdir = W.CACHE_DIR[]
        W.CACHE_DIR[] = joinpath(d, "cache")
        try
            b = row(2; lane = "landed", fetched_at = "2026-09-13T17:00:00Z",
                    moved_at = "2026-09-13T16:30:00Z", type = "PullRequest",
                    state = "MERGED", ci = "FAILURE", ci_failed = true)
            W.cache_put(W.bundle_key(U(2)), b)
            @test W.refresh(String[], W.DateTime(2026, 9, 13, 18); search = srch,
                            fetch_url_map = byurl, poll = (a...) -> Any[], open_list = (a...; kw...) -> []) == 0
            @test W.fetched("items")[Symbol(U(2))].moved_at == "2026-09-13T16:30:00Z"
        finally
            W.CACHE_DIR[] = keepdir
        end
        # A carried row in a repository the poll does not cover has no clock
        # over a push, your own reply, an unassignment or a label - the
        # notifications source fires for participation only - so while it is
        # open and in front of you it is asked every run, the way every
        # carried row was before the clocks; over, or the pile, it is left.
        @test !W.covered(U(2), Dict{String,Any}("repos" => ["x/y", "z/*"]))
        @test W.covered(U(2), Dict{String,Any}("repos" => ["o/r"]))
        @test W.covered(U(2), Dict{String,Any}("repos" => ["o/*"]))
        asked = String[]
        @test W.refresh(String[], W.DateTime(2026, 9, 13, 19); search = srch,
                        fetch_url_map = byurl, poll = (a...) -> Any[], open_list = (a...; kw...) -> []) == 0
        @test U(6) in asked && !(U(2) in asked) && !(U(4) in asked)
        # A mark is proof a row was in front of you: a light row with a block
        # in local.toml joins the corpus - off the bundle the browser cached
        # when you looked, or asked by url when it was only marked from the
        # list and the inbox still has it.
        keepdir = W.CACHE_DIR[]
        W.CACHE_DIR[] = joinpath(d, "cache2")
        try
            W.cache_put(W.bundle_key(U(8)), row(8; lane = "notifications",
                        fetched_at = "2026-09-13T18:00:00Z"))
            W.set_read(U(8), "2026-09-13T18:30:00Z")
            W.set_read(U(9), "2026-09-13T18:30:00Z")
            asked = String[]
            light9(cfg, login, at) = [Dict{String,Any}("url" => U(9), "lane" => "activity",
                                                        "updated" => "2026-09-13T18:20:00Z")]
            @test W.refresh(String[], W.DateTime(2026, 9, 13, 20); search = srch,
                            fetch_url_map = byurl, poll = light9, open_list = (a...; kw...) -> []) == 0
            its = W.fetched("items")
            @test haskey(its, Symbol(U(8))) && its[Symbol(U(8))].lane == "notifications"
            @test U(9) in asked
            # And a read stamp past the bundle is a clock too: `r` from the
            # list on a row whose inbox entry the poll then dropped. 2 is over
            # and would not be asked for any other reason.
            @test !(U(2) in asked)
            W.set_read(U(2), "2026-09-13T23:00:00Z")
            asked = String[]
            @test W.refresh(String[], W.DateTime(2026, 9, 13, 21); search = srch,
                            fetch_url_map = byurl, poll = (a...) -> Any[], open_list = (a...; kw...) -> []) == 0
            @test U(2) in asked
        finally
            W.CACHE_DIR[] = keepdir
        end
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm; W.Events._PAT[] = keeppat
    end
end

@testset "a lane is walked by creation time, and a second with a page in it is drained" begin
    # A fake GitHub: 130 open issues, 50 of them created in one second, the
    # rest one a second, answering the query the way search does - sorted by
    # creation, `created:` qualifiers honoured, fifty a page by offset.
    stamp_(i) = "2026-09-01T00:00:" * lpad(string(i), 2, '0') * "Z"
    made = vcat([stamp_(0) for _ in 1:50], [stamp_(i) for i in 1:80])   # 130 rows
    urls = ["https://github.com/o/r/issues/$i" for i in 1:130]
    asked = String[]
    function fake(args, body)
        d = W.JSON3.read(body)
        q = String(d.variables.q)
        push!(asked, q)
        cursor = d.variables.cursor
        off = cursor === nothing ? 0 : parse(Int, String(cursor))
        ge = match(r"created:>=(\S+)", q); gt = match(r"created:>(\S+)", q)
        rg = match(r"created:(\S+)\.\.(\S+)", q)
        keep = [i for i in 1:130 if
                (ge === nothing || made[i] >= ge[1]) &&
                (gt === nothing || ge !== nothing || made[i] > gt[1]) &&
                (rg === nothing || (made[i] >= rg[1] && made[i] <= rg[2]))]
        pg = keep[off+1:min(off+50, end)]
        nodes = [Dict("__typename" => "Issue", "url" => urls[i], "createdAt" => made[i],
                      "number" => i) for i in pg]
        (0, W.json_dumps(Dict("data" => Dict(
            "rateLimit" => Dict("cost" => 1),
            "search" => Dict("issueCount" => length(keep), "nodes" => nodes,
                             "pageInfo" => Dict("hasNextPage" => off + 50 < length(keep),
                                                "endCursor" => string(off + 50)))))), "")
    end
    nodes, pts, total = W.search("is:open is:issue x sort:created-asc"; run = fake)
    @test total == 130 && length(nodes) == 130
    @test sort(String[n.url for n in nodes]) == sort(urls)      # every row, once
    # Page one is the bare query; the whole first page was one second, which
    # the `>=X` ask after it shows by answering the same page - once, never
    # twice - so that second was drained by offset (`X..X`) and the walk went
    # on from `>X`.
    @test asked[1] == "is:open is:issue x sort:created-asc"
    @test count(q -> endswith(q, "created:>=2026-09-01T00:00:00Z"), asked) == 1
    @test count(q -> occursin("created:2026-09-01T00:00:00Z..2026-09-01T00:00:00Z", q), asked) == 1
    @test count(q -> endswith(q, "created:>2026-09-01T00:00:00Z"), asked) == 1
    # After that, keyset: each ask is `>=` the last row read, first page only.
    later = [q for q in asked if occursin("created:>=", q)]
    @test !isempty(later) && all(q -> occursin("created:>=2026-09-01T00:00:", q), later)
    # And a lane without the sort walks by offset, as before - as does one
    # with a `created:` qualifier of its own, which GitHub would OR with the
    # floor's, so the floor could never narrow it and the walk never end.
    empty!(asked)
    nodes, _, total = W.search("is:open is:issue x"; run = fake)
    @test length(nodes) == 130 && all(q -> q == "is:open is:issue x", asked)
    empty!(asked)
    q2 = "is:open is:issue x created:>2020-01-01 sort:created-asc"
    nodes, _, _ = W.search(q2; run = fake)
    @test length(nodes) == 130 && all(q -> q == q2, asked)
    # A page of nothing usable ends the walk with what it has, on a budget.
    empty!(asked)
    nulls(args, body) = (0, W.json_dumps(Dict("data" => Dict(
        "rateLimit" => Dict("cost" => 1),
        "search" => Dict("issueCount" => 5, "nodes" => [nothing, nothing],
                         "pageInfo" => Dict("hasNextPage" => true, "endCursor" => "2"))))), "")
    nodes, _, _ = W.search("is:open is:issue x sort:created-asc"; run = nulls)
    @test isempty(nodes) && length(asked) <= 3
end

@testset "a window is walked by stamp, and a row that moves mid-walk is read again, not skipped" begin
    # A fake list ascending by `updated_at`: 100 rows in one second, then one
    # a second - and one row, read on page one, that is updated once the walk
    # is past the tie and going by stamp, which moves it to the end and shifts
    # everything behind it up. (Moved during the tie's own drain it would be
    # the offset's hole in miniature, which the docstring owns up to.)
    st_(i) = "2026-09-01T00:" * lpad(string(i ÷ 60), 2, '0') * ":" * lpad(string(i % 60), 2, '0') * "Z"
    upd = Dict(i => (i <= 100 ? st_(0) : st_(i - 100)) for i in 1:230)
    asks = Tuple{String,Int}[]
    moved = Ref(false)
    function page(floor_, n)
        push!(asks, (floor_, n))
        # The mover: row 5, read on page one, is touched during the walk.
        if !moved[] && length(asks) == 3
            upd[5] = st_(200); moved[] = true
        end
        keep = sort([i for i in 1:230 if upd[i] >= floor_]; by = i -> (upd[i], i))
        [Dict{String,Any}("id" => i, "updated_at" => upd[i]) for i in keep[(n-1)*100+1:min(n*100, end)]]
    end
    rows = W.Events.walk_updated(page, "2026-09-01T00:00:00Z")
    ids = sort([r["id"] for r in rows])
    @test ids == collect(1:230)                     # every row, once, the mover included
    # Page one from `since`; the second in it did not advance the floor, so
    # page two was asked from the same floor by offset; then by stamp.
    @test asks[1] == ("2026-09-01T00:00:00Z", 1)
    @test asks[2] == ("2026-09-01T00:00:00Z", 2)
    @test all(n == 1 for (_, n) in asks[3:end])
    @test issorted([f for (f, _) in asks[3:end]])
    # And the mover is what the last page held: read again past the floor.
    @test any(r -> r["id"] == 5 && r["updated_at"] == st_(200), rows)
    # A page that answers with its bound: the walk's is the first request's.
    st = Ref{Any}(nothing)
    n = Ref(0)
    W.Events.walk_updated("2026-09-01T00:00:00Z"; started = st) do floor_, k
        n[] += 1
        (page(floor_, k), W.DateTime(2026, 9, 1, 0, 0, n[]))
    end
    @test st[] == W.DateTime(2026, 9, 1, 0, 0, 1)
    # A walk that runs out of pages answers with its floor, not its start: the
    # rows past the cut are unread, and a cursor at the start would step past
    # them for good. Two pages here: the tie second, and the page after it.
    st = Ref{Any}(W.DateTime(2026, 9, 2))
    rows = W.Events.walk_updated("2026-09-01T00:00:00Z"; started = st, max_pages = 2) do floor_, k
        (page(floor_, k), W.DateTime(2026, 9, 2))
    end
    @test length(rows) == 199                           # row 5 is at the end now
    @test st[] == W.DateTime(2026, 9, 1, 0, 1, 40)     # the newest stamp read
    # And one that ends on a short page keeps the start it was given.
    st = Ref{Any}(nothing)
    W.Events.walk_updated("2026-09-01T00:00:00Z"; started = st) do floor_, k
        (page(floor_, k), W.DateTime(2026, 9, 2))
    end
    @test st[] == W.DateTime(2026, 9, 2)
end

@testset "the open list is the backlog, read by construction, unread when it moves" begin
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    try
        # A REST issue and a REST pull request, as the open list hands them
        # over, become corpus rows in the shape a lane's rows have.
        rest(n; pr = false) = Dict{String,Any}(
            "html_url" => "https://github.com/o/r/$(pr ? "pull" : "issues")/$n",
            "repository_url" => "https://api.github.com/repos/o/r", "number" => n,
            "title" => "t$n", "state" => "open", "user" => Dict("login" => "alice"),
            "created_at" => "2026-08-01T00:00:00Z", "updated_at" => "2026-08-0$(n)T00:00:00Z",
            "labels" => [Dict("name" => "bug")], "assignees" => [Dict("login" => "vtjnash")],
            "milestone" => Dict("title" => "1.0", "due_on" => nothing), "comments" => 2,
            (pr ? ("pull_request" => Dict(),) : ())...)
        r = W.backlog_row(rest(1), "vtjnash")
        @test r["type"] == "Issue" && r["lane"] == "backlog" && r["state"] == "OPEN"
        @test r["mine"] == true && r["labels"] == ["bug"] && r["milestone"] == "1.0"
        @test W.backlog_row(rest(2; pr = true), "me")["type"] == "PullRequest"
        @test W.in_pile(r)
        # Imported once, the rows are in the corpus, `new`, and read by
        # construction: the day the source was named is on record in
        # local.toml - one block per source, the one fact a rebuild could
        # not get from GitHub - and a backlog row is read up to it.
        W.save_fetched(Dict{String,Any}("items" => Dict{String,Any}()))
        rows = [W.backlog_row(rest(1), "vtjnash"), W.backlog_row(rest(2; pr = true), "vtjnash")]
        srch(q) = (Any[], 4, 0)
        @test isempty(W.source_since())
        @test W.refresh(["--backlog"], W.DateTime(2026, 9, 13, 12); search = srch,
                        fetch_url_map = u -> W.OrderedDict{String,Any}(), poll = (a...) -> Any[],
                        open_list = (cfge, login; only = nothing, spent = Ref(0)) -> (@test only === nothing; rows)) == 0
        its = W.fetched("items")
        u1, u2 = rows[1]["url"], rows[2]["url"]
        @test haskey(its, Symbol(u1)) && haskey(its, Symbol(u2))
        @test its[Symbol(u1)].lane == "backlog" && its[Symbol(u1)].new == true
        named = W.source_since()
        @test !isempty(named) && all(v -> startswith(v, "2026-09-13T12:00"), values(named))
        @test !haskey(W.load_fetched(), "baseline")          # nothing per row in fetched
        # `o/r` is not a source in config.toml; give the rows one to be read
        # up to, the way a named repository's rows have.
        W.name_source!("o/r", "2026-09-10T00:00:00Z")
        @test W.floor_of("backlog", "o/r", W.source_since()) == "2026-09-10T00:00:00Z"
        @test W.floor_of("backlog", "o/other", Dict("o/*" => "x")) == "x"      # the glob answers
        @test W.floor_of("backlog", "o/r", Dict("o/*" => "x", "o/r" => "y")) == "y"  # named outright wins
        @test W.floor_of("backlog", "p/q", W.source_since()) === nothing
        @test W.read_at(u1) === nothing                      # nothing said
        it = W.item_of(its[Symbol(u1)])
        m() = W.Marks(read = W.load_read(), sources = W.source_since(), now = "2026-09-13T12:00:00Z")
        @test W.seen_of(it, m()) === :read                   # read, by construction
        # Moved past the day it was named, it is unread like any other row;
        # read for real, the stamp is on top; said unread by hand, it stays
        # unread whatever the baseline answers - and an undo puts back what
        # was said, not what the baseline would have said.
        later = W.with(it; moved_at = "2026-09-13T00:00:00Z")
        @test W.seen_of(later, m()) === :unread
        W.set_read(u1, "2026-09-14T00:00:00Z")
        @test W.read_at(u1) == "2026-09-14T00:00:00Z" && W.seen_of(later, m()) === :read
        @test W.mark_unread([u1]) == 1
        @test W.read_at(u1) === nothing && W.mark_at(u1, "read") == ""
        @test W.seen_of(it, m()) === :unread                 # said, so the baseline does not answer
        @test W.seen_of(W.with(it; lane = "mine"), W.Marks(read = W.load_read(), now = "x")) === :unread
        # **The floor answers in every lane**, and a lane is a source: a row
        # of a lane with no `source:` block is unread, and read up to the
        # day the lane was named once it has one - however it got there.
        it2 = W.item_of(its[Symbol(u2)])
        for lane in ("notifications", "mine", "imported", "firehose", "carried")
            @test W.source_of(lane, "o/r", W.source_since()) == lane
            @test W.seen_of(W.with(it2; lane = lane), m()) === :unread
        end
        @test W.source_of("activity", "o/r", W.source_since()) == "o/r"
        @test W.source_of("activity", "o/other", Dict("o/*" => "x")) == "o/*"
        @test W.source_of("backlog", "p/q", W.source_since()) == "p/q"   # no block: unread
        @test W.floor_of("backlog", "p/q", W.source_since()) === nothing
        W.name_source!("notifications", "2026-09-10T00:00:00Z")
        W.name_source!("mine", "2026-09-12T00:00:00Z")
        @test W.seen_of(W.with(it2; lane = "notifications"), m()) === :read
        @test W.seen_of(W.with(it2; lane = "mine"), m()) === :read
        @test W.seen_of(W.with(it2; lane = "activity"), m()) === :read       # the repo's block
        @test W.seen_of(W.with(it2; lane = "firehose"), m()) === :unread     # still no block
        # Moved past the lane's day, unread; said unread, unread whatever the
        # floor says - `read = ""` beats it in every lane, as in the backlog.
        @test W.seen_of(W.with(it2; lane = "mine", moved_at = "2026-09-13T00:00:00Z"), m()) === :unread
        @test W.seen_of(W.with(it2; lane = "notifications", moved_at = "2026-09-11T00:00:00Z"), m()) === :unread
        W.mark_unread([u2])
        @test W.seen_of(W.with(it2; lane = "mine"), m()) === :unread
        # And a plain read mark on a row the floor already answers for folds
        # the key away rather than stamping it: the block says nothing again,
        # and `seen_of` answers the same. `wl read` and `r` alike; a snooze
        # and an archive keep their stamp, since the refresh reads either
        # with no stamp as put away by hand.
        @test W.folded("2026-09-01T00:00:00Z", "2026-09-10T00:00:00Z") === nothing
        @test W.folded("2026-09-11T00:00:00Z", "2026-09-10T00:00:00Z") == "2026-09-11T00:00:00Z"
        @test W.folded("2026-09-01T00:00:00Z", nothing) == "2026-09-01T00:00:00Z"
        @test W.mark_read_moved([u2], W.DateTime(2026, 9, 13, 12); fold = true) == 1
        @test W.mark_at(u2, "read") === nothing && W.seen_of(it2, m()) === :read
        W.mark_read_moved([u2], W.DateTime(2026, 9, 13, 12))
        @test W.mark_at(u2, "read") == it2.moved_at
        W.mark_unread([u1])
        ctrl = W.Controller()
        st = W.BState([it], "t"); st.filters = W.everything(); W.refilter!(st)
        st.sel = 1; st.loaded = string(it.url, ":", st.mode); st.metakey = it.url
        st.nodes = W.Node[]
        W.handle!(st, Int('r'), ctrl, W.DateTime(2026, 9, 13, 12))
        @test st.status == "marked read" && W.mark_at(u1, "read") === nothing
        @test W.seen_of(it, W.Marks(st)) === :read
        W.handle!(st, Int('z'), ctrl)
        @test W.mark_at(u1, "read") == ""
        W.apply_snooze!(st, it, "3d", W.DateTime(2026, 9, 13, 12))
        @test W.mark_at(u1, "read") == it.moved_at
        W.apply_snooze!(st, it, nothing, W.DateTime(2026, 9, 13, 12))
        W.mark_unread([u1])                                  # said unread, as above
        # A second import leaves rows the corpus has alone, and adds none.
        @test W.refresh(["--backlog"], W.DateTime(2026, 9, 13, 13); search = srch,
                        fetch_url_map = u -> W.OrderedDict{String,Any}(), poll = (a...) -> Any[],
                        open_list = (cfge, login; only = nothing, spent = Ref(0)) -> rows) == 0
        @test W.fetched("items")[Symbol(u1)].new == false && W.mark_at(u1, "read") == ""
        # Without the flag, only a source not yet named is asked for its
        # list: every source has been, above, so none is - and a fresh file,
        # every one. The record is local.toml, not fetched.json, so losing
        # the latter does not bring the lists in again as if new.
        seen = Ref{Any}(:unset)
        W.refresh(String[], W.DateTime(2026, 9, 13, 14); search = srch,
                  fetch_url_map = u -> W.OrderedDict{String,Any}(), poll = (a...) -> Any[],
                  open_list = (cfge, login; only = nothing, spent = Ref(0)) -> (seen[] = only; []))
        @test seen[] === :unset                          # not asked at all
        write(W.LOCAL[], "")
        W.refresh(String[], W.DateTime(2026, 9, 13, 15); search = srch,
                  fetch_url_map = u -> W.OrderedDict{String,Any}(), poll = (a...) -> Any[],
                  open_list = (cfge, login; only = nothing, spent = Ref(0)) -> (seen[] = only; []))
        @test seen[] isa Vector && !isempty(seen[])
        @test Set(keys(W.source_since())) == Set(seen[])
        # **Every lane names itself too**, the first time a corpus row carries
        # it, and a fresh local.toml names every source on the first run and
        # nothing on the second: the retired lanes once, for the rows they
        # left, and never a repository's own lanes, which the repository
        # answers for.
        its = W.load_fetched()
        its["items"] = Dict{String,Any}(String(k) => v for (k, v) in pairs(its["items"]))
        for (u, lane) in (("https://github.com/o/r/pull/20", "mine"),
                          ("https://github.com/o/r/issues/21", "firehose"),
                          ("https://github.com/o/r/issues/22", "activity"))
            its["items"][u] = Dict{String,Any}("url" => u, "repo" => "o/r", "number" => 20,
                                               "title" => "t", "lane" => lane, "state" => "OPEN",
                                               "updated" => "2026-09-01T00:00:00Z",
                                               "fetched_at" => "2026-09-13T00:00:00Z")
        end
        W.save_fetched(its)
        write(W.LOCAL[], "")
        run(at) = W.refresh(String[], at; search = srch,
                            fetch_url_map = u -> W.OrderedDict{String,Any}(), poll = (a...) -> Any[],
                            open_list = (cfge, login; only = nothing, spent = Ref(0)) -> [])
        run(W.DateTime(2026, 9, 13, 16))
        named = W.source_since()
        @test haskey(named, "mine") && haskey(named, "firehose") && haskey(named, "backlog") == false
        @test !haskey(named, "activity") && !haskey(named, "o/r")   # the repository's: not a lane
        @test all(v -> startswith(v, "2026-09-13T16:00"), (named["mine"], named["firehose"]))
        before = read(W.LOCAL[], String)
        run(W.DateTime(2026, 9, 13, 17))
        @test read(W.LOCAL[], String) == before                    # nothing to name
        # So the rows are read by construction, whatever their lane, and
        # unread once they move past the day.
        m2 = W.Marks(read = W.load_read(), sources = W.source_since(), now = "2026-09-13T18:00:00Z")
        mine = W.item_of(W.fetched("items")[Symbol("https://github.com/o/r/pull/20")])
        @test mine.lane == "mine" && W.seen_of(mine, m2) === :read
        @test W.seen_of(W.with(mine; moved_at = "2026-09-13T17:00:00Z"), m2) === :unread
        # And the notifications source names itself where its cursor starts.
        E = W.Events
        E.sync!([(label = "notifications", fetch = since -> Any[], overlap = E.OVERLAP_REST,
                  row = (t, _) -> nothing)], W.DateTime(2026, 9, 13, 18);
                now = () -> W.DateTime(2026, 9, 13, 18), watched = () -> Set{String}())
        @test W.source_since()["notifications"] == "2026-09-13T18:00:00Z"
        @test W.source_cursors()["notifications"] == "2026-09-13T18:00:00Z"
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "the inbox is a clock: a row leaves once it is asked about and read" begin
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    U(n) = "https://github.com/o/r/issues/$n"
    row(n; kw...) = merge(Dict{String,Any}(
        "url" => U(n), "type" => "Issue", "lane" => "mine", "state" => "OPEN",
        "mine" => true, "author" => "vtjnash", "title" => "t$n", "number" => n,
        "repo" => "o/r", "labels" => String[], "created" => "2026-09-01T00:00:00Z",
        "updated" => "2026-09-10T00:00:00Z", "moved_at" => "2026-09-10T00:00:00Z",
        "fetched_at" => "2026-09-12T00:00:00Z", "track" => "normal", "ref" => "r#$n"),
        Dict{String,Any}(String(k) => v for (k, v) in kw))
    light(n, updated; kw...) = merge(W.OrderedDict{String,Any}(
        "url" => U(n), "repo" => "o/r", "number" => n, "title" => "t$n", "is_pr" => false,
        "state" => "open", "author" => "bob", "updated" => updated, "comments" => 1,
        "labels" => String[], "mine" => false, "lane" => "activity"),
        Dict{String,Any}(String(k) => v for (k, v) in kw))
    node(u, n; kw...) = W.JSON3.read(W.json_dumps(merge(Dict{String,Any}(
        "__typename" => "Issue", "url" => u, "number" => n, "title" => "t$n", "state" => "OPEN",
        "repository" => Dict("nameWithOwner" => "o/r"), "createdAt" => "2026-09-01T00:00:00Z",
        "updatedAt" => "2026-09-10T00:00:00Z", "author" => Dict("login" => "bob"),
        "milestone" => nothing, "assignees" => Dict("nodes" => []), "labels" => Dict("nodes" => []),
        "timelineItems" => Dict("nodes" => []), "comments" => Dict("nodes" => [])),
        Dict{String,Any}(String(k) => v for (k, v) in kw))))
    try
        # 1 is read and consumed; 2 is consumed and unread; 3 has moved past
        # its bundle, is asked, and is not answered; 4 is a light row; 5 is
        # the 366: moved_at under a read stamp nothing could write while the
        # inbox pruned on `updated`.
        W.save_fetched(Dict{String,Any}("items" => Dict(
            U(1) => row(1), U(2) => row(2), U(3) => row(3),
            U(5) => row(5; updated = "2026-09-11T00:00:00Z", fetched_at = "2026-09-11T00:00:00Z"))))
        inbox = W.Events.load_inbox()
        inbox["items"][U(1)] = light(1, "2026-09-11T00:00:00Z")
        inbox["items"][U(2)] = light(2, "2026-09-11T00:00:00Z")
        inbox["items"][U(3)] = light(3, "2026-09-13T00:00:00Z")
        inbox["items"][U(4)] = light(4, "2026-09-11T00:00:00Z")
        inbox["items"][U(5)] = light(5, "2026-09-11T00:00:00Z")
        W.Events.save_inbox(inbox)
        # The lane named before any of them moved, so that no stamp means
        # unread here rather than read by construction.
        W.name_source!("mine", "2026-09-01T00:00:00Z")
        W.set_read(U(1), "2026-09-10T00:00:00Z")
        asked = String[]
        byurl(urls) = (append!(asked, urls);
                       W.OrderedDict{String,Any}(u => u == U(4) ? node(u, 4) : nothing for u in urls))
        srch(q) = (Any[], 4, 0)
        clock(a...) = collect(values(W.Events.load_inbox()["items"]))
        run(at) = W.refresh(String[], at; search = srch, fetch_url_map = byurl, poll = clock,
                            open_list = (a...; kw...) -> [])
        @test run(W.DateTime(2026, 9, 13, 12)) == 0
        left = Set(keys(W.Events.load_inbox()["items"]))
        @test !(U(1) in left)                      # read and consumed: gone
        @test U(2) in left                         # consumed, unread: kept
        @test U(3) in left && U(3) in asked        # asked, unanswered: kept, asked again
        @test U(4) in left && !(U(4) in asked)     # light: nobody asked, nothing to consume
        @test U(5) in left                         # unread, as it stands
        # `wl read` on the light row promotes it - asked by url, in the
        # corpus from here - and once asked and read it leaves; and the 366
        # leave the same way, which nothing could make them do before.
        W.set_read(U(4), "2026-09-11T00:00:00Z")           # `r` from the list
        @test W.dispatch(["read", U(5)], W.DateTime(2026, 9, 13, 13)) == 0
        @test W.read_at(U(5)) == "2026-09-10T00:00:00Z"    # `moved_at`, under `updated`
        asked = String[]
        @test run(W.DateTime(2026, 9, 13, 14)) == 0
        left = Set(keys(W.Events.load_inbox()["items"]))
        @test U(4) in asked && haskey(W.fetched("items"), Symbol(U(4)))
        @test !(U(4) in left) && !(U(5) in left)
        @test U(2) in left && U(3) in left
        # The clock is re-read on every run, so an unread row stays a row:
        # a third run changes nothing.
        @test run(W.DateTime(2026, 9, 13, 15)) == 0
        @test Set(keys(W.Events.load_inbox()["items"])) == left
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "wl unread and wl read all are seen_of over the corpus and the light rows" begin
    # 2026-09-16, as a fixture: "mark everything read" took three passes and
    # 2277 stamps because the unread list was the inbox listing, pruned on
    # `updated <= read`, while the marks stamped `moved_at`. One list now,
    # `unread_items`, and one `read all` over it finds nothing the second
    # time by construction.
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    U(n) = "https://github.com/o/r/issues/$n"
    row(n; kw...) = merge(Dict{String,Any}(
        "url" => U(n), "type" => "Issue", "lane" => "mine", "state" => "OPEN",
        "mine" => true, "author" => "vtjnash", "title" => "t$n", "number" => n,
        "repo" => "o/r", "labels" => String[], "created" => "2026-09-01T00:00:00Z",
        "updated" => "2026-09-10T00:00:00Z", "moved_at" => "2026-09-10T00:00:00Z",
        "fetched_at" => "2026-09-15T00:00:00Z", "track" => "normal", "ref" => "r#$n"),
        Dict{String,Any}(String(k) => v for (k, v) in kw))
    try
        at = W.DateTime(2026, 9, 16, 12)
        W.save_fetched(Dict{String,Any}("items" => Dict(
            U(1) => row(1; updated = "2026-09-15T00:00:00Z"),   # the 366: a label after
            U(2) => row(2; lane = "firehose", moved_at = "2026-09-08T00:00:00Z"),  # the 1915: no floor
            U(3) => row(3; lane = "backlog"),                    # under the floor: read
            U(5) => row(5; moved_at = "2026-09-09T00:00:00Z"), U(6) => row(6))))
        light = W.OrderedDict{String,Any}("url" => U(4), "repo" => "o/r", "number" => 4,
            "title" => "t4", "is_pr" => false, "state" => "open", "author" => "bob",
            "updated" => "2026-09-14T00:00:00Z", "comments" => 1, "labels" => String[],
            "mine" => false, "lane" => "activity")
        inbox = W.Events.load_inbox(); inbox["items"][U(4)] = light; W.Events.save_inbox(inbox)
        W.name_source!("mine", "2026-09-01T00:00:00Z")
        W.name_source!("o/r", "2026-09-12T00:00:00Z")
        W.set_read(U(5), "2026-09-09T00:00:00Z")                          # woken below
        W.set_fields(U(5), ["snooze" => "2026-09-11T00:00:00Z"])
        W.set_read(U(6), "2026-09-10T00:00:00Z")                          # read
        polled(a...; kw...) = collect(values(W.Events.load_inbox()["items"]))
        @test [it.url for it in W.unread_items(at)] == [U(4), U(1), U(5), U(2)]  # newest movement first
        # The JSON dump is that list.
        said(args, when) = mktemp() do path, io
            redirect_stdout(() -> W.dispatch(args, when; poll = polled), io)
            flush(io)
            read(path, String)
        end
        js = W.JSON3.read(said(["unread"], at))
        @test [String(j.url) for j in js] == [U(4), U(1), U(5), U(2)]
        @test js[1].lane == "activity" && js[2].moved_at == "2026-09-10T00:00:00Z"
        @test js[2].updated == "2026-09-15T00:00:00Z" && js[2].state == "open"
        # One pass reads everything; the stamps are the movements.
        @test occursin("marked 4 threads read", said(["read"], at))
        @test W.read_at(U(1)) == "2026-09-10T00:00:00Z"        # moved_at, under updated
        @test W.read_at(U(2)) == "2026-09-08T00:00:00Z"
        @test W.read_at(U(4)) == "2026-09-14T00:00:00Z"        # the light row's clock
        @test W.read_at(U(5)) == "2026-09-09T00:00:00Z" && W.get_field(U(5), "snooze") === nothing
        @test W.mark_at(U(3), "read") === nothing              # never touched: the floor answers
        @test isempty(W.unread_items(at))
        # And the second pass finds nothing, by construction.
        @test occursin("marked 0 threads read", said(["read"], at + W.Minute(1)))
        # With nothing fetched at all the list is what the inbox says, and
        # not an error.
        rm(W.FETCHED[])
        @test isempty(W.unread_items(at, []))
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "a filed row keeps its stamp, and a light row is stamped by the inbox's clock" begin
    # Three ways a mark and the list disagreed on 2026-09-17. A filed row
    # that moved is unread in the `filed` box and nowhere else, so `wl
    # unread` leaves it out and `wl read all` does not read it; a plain read
    # mark on a filed row stamps rather than folds, and `--consolidate`
    # leaves the stamp alone, since the refresh reads a filed row with no
    # stamp as put away by hand and stamps it at its own clock - over the
    # movement. And a light row with a cached bundle from before the inbox's
    # clock is stamped by the clock, which is what `wl unread` listed it
    # against, or `wl read all` would find it again.
    keepi, keepm, keepdir = W.FETCHED[], W.LOCAL[], W.CACHE_DIR[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    W.CACHE_DIR[] = joinpath(d, "cache")
    U(n) = "https://github.com/o/r/issues/$n"
    day(n) = "2026-09-$(lpad(n, 2, '0'))T00:00:00Z"
    row(n; kw...) = merge(Dict{String,Any}(
        "url" => U(n), "type" => "Issue", "lane" => "mine", "state" => "OPEN",
        "mine" => true, "author" => "vtjnash", "title" => "t$n", "number" => n,
        "repo" => "o/r", "labels" => String[], "created" => day(1),
        "updated" => day(10), "moved_at" => day(10),
        "fetched_at" => day(15), "track" => "normal", "ref" => "r#$n"),
        Dict{String,Any}(String(k) => v for (k, v) in kw))
    light(n, updated) = W.OrderedDict{String,Any}("url" => U(n), "repo" => "o/r", "number" => n,
        "title" => "t$n", "is_pr" => false, "state" => "open", "author" => "bob",
        "updated" => updated, "comments" => 1, "labels" => String[], "mine" => false,
        "lane" => "activity")
    at = W.DateTime(2026, 9, 16, 12)
    try
        # 1 is filed and moved past its stamp; 2 is filed, read, and under
        # the floor; 3 is read and under the floor; 4 is a light row looked
        # at once - a bundle cached on the 12th - and moved on the 14th.
        W.name_source!("mine", day(11))
        W.name_source!("o/r", day(11))
        W.save_fetched(Dict{String,Any}("items" => Dict(
            U(1) => row(1; moved_at = day(14), updated = day(14)),
            U(2) => row(2; moved_at = day(9)), U(3) => row(3; moved_at = day(9)))))
        inbox = W.Events.load_inbox(); inbox["items"][U(4)] = light(4, day(14))
        W.Events.save_inbox(inbox)
        W.cache_put(W.bundle_key(U(4)), row(4; lane = "activity", moved_at = day(12),
                                               updated = day(12), fetched_at = day(12)))
        W.set_read(U(1), day(10)); W.set_archived(U(1), day(10))
        W.set_read(U(2), day(9)); W.set_archived(U(2), day(9))
        W.set_read(U(3), day(9))
        # Unread in the filed box, and not on the list.
        m = W.Marks(read = W.load_read(), sources = W.source_since(), now = W.stamp(at))
        @test W.seen_of(only(it for it in W.corpus_items() if it.url == U(1)), m) === :unread
        @test [it.url for it in W.unread_items(at)] == [U(4)]
        # The light row is stamped by the inbox's clock, and the list is empty.
        @test W.mark_read_moved([U(4)], at; fold = true) == 1
        @test W.read_at(U(4)) == day(14)
        @test isempty(W.unread_items(at))
        # A plain read mark on the filed rows stamps; on the plain one it folds.
        @test W.mark_read_moved([U(1), U(2), U(3)], at; fold = true) == 3
        @test W.read_at(U(1)) == day(14) && W.read_at(U(2)) == day(9)
        @test W.mark_at(U(3), "read") === nothing
        # And consolidating leaves the filed stamps alone.
        c = W.consolidate!(at)
        @test !(U(1) in c.dropped) && !(U(2) in c.dropped)
        @test W.read_at(U(1)) == day(14) && W.read_at(U(2)) == day(9)
        # `r` in the browser: the same on a filed row, and `z` after a folded
        # `r` puts back the head the fold kept, not the head the unread
        # dropped. The list is one row and every box on, so it stays under
        # the cursor either way, and there is no thread to fetch.
        ctrl = W.Controller()
        st = W.BState([W.with(W.item_of(W.fetched("items")[Symbol(U(3))]); head = "cafe")], "t")
        st.filters = W.everything(); W.refilter!(st)
        st.nodes = W.Node[]; st.loaded = string(U(3), ":", st.mode)
        W.set_read(U(3), "")                           # said unread, under the floor
        st.read = W.field_marks(W.load_marks(), "read")
        W.handle!(st, Int('r'), ctrl, at)              # folds: no stamp, the head kept
        @test W.mark_at(U(3), "read") === nothing && W.read_head(U(3)) == "cafe"
        W.handle!(st, Int('r'), ctrl, at)              # unread: both go
        @test W.mark_at(U(3), "read") == "" && W.read_head(U(3)) === nothing
        W.handle!(st, Int('z'), ctrl, at)
        @test W.mark_at(U(3), "read") === nothing && W.read_head(U(3)) == "cafe"
        st = W.BState([W.with(W.item_of(W.fetched("items")[Symbol(U(2))]); head = "beef")], "t")
        st.filters = W.everything(); W.refilter!(st)
        st.nodes = W.Node[]; st.loaded = string(U(2), ":", st.mode)
        W.set_read(U(2), ""); st.read = W.field_marks(W.load_marks(), "read")
        W.handle!(st, Int('r'), ctrl, at)              # filed: stamped, not folded
        @test W.read_at(U(2)) == day(9) && W.read_head(U(2)) == "beef"
        # And on a snoozed row that moved under its wake: the span counts
        # from the stamp, so a fold would have been the end of the snooze.
        W.set_read(U(3), day(8)); W.set_fields(U(3), ["snooze" => "30d"])
        st = W.BState([W.with(W.item_of(W.fetched("items")[Symbol(U(3))]); head = "cafe")], "t")
        st.filters = W.everything(); W.refilter!(st)
        st.nodes = W.Node[]; st.loaded = string(U(3), ":", st.mode)
        @test W.seen_of(st.items[1], W.Marks(st)) === :unread
        W.handle!(st, Int('r'), ctrl, at)
        @test W.read_at(U(3)) == day(9) && W.get_field(U(3), "snooze") == "30d"
        @test haskey(W.wake_map(), U(3))
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm; W.CACHE_DIR[] = keepdir
    end
end

@testset "wl read --consolidate raises the floors together and never lowers them" begin
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    U(n) = "https://github.com/o/r/issues/$n"
    row(n; kw...) = merge(Dict{String,Any}(
        "url" => U(n), "type" => "Issue", "lane" => "mine", "state" => "OPEN",
        "mine" => true, "author" => "vtjnash", "title" => "t$n", "number" => n,
        "repo" => "o/r", "labels" => String[], "created" => "2026-09-01T00:00:00Z",
        "updated" => "2026-09-10T00:00:00Z", "moved_at" => "2026-09-10T00:00:00Z",
        "fetched_at" => "2026-09-15T00:00:00Z", "track" => "normal", "ref" => "r#$n"),
        Dict{String,Any}(String(k) => v for (k, v) in kw))
    light(n, updated) = W.OrderedDict{String,Any}("url" => U(n), "repo" => "o/r", "number" => n,
        "title" => "t$n", "is_pr" => false, "state" => "open", "author" => "bob",
        "updated" => updated, "comments" => 1, "labels" => String[], "mine" => false,
        "lane" => "activity")
    day(n) = "2026-09-$(lpad(n, 2, '0'))T00:00:00Z"
    at = W.DateTime(2026, 9, 16, 12)
    mk() = W.Marks(read = W.load_read(), sources = W.source_since(), wake = W.wake_map(),
                   now = W.stamp(at))
    answers() = Dict(it.url => W.seen_of(it, mk()) for it in W.corpus_items())
    try
        # Two sources named on different days; rows read by stamp at every
        # movement from the 4th to the 14th; one stampless unread row moved
        # on the 12th, which is the bound; one unread against its own stamp;
        # one said unread; one snoozed; one light row read; one light row
        # unread and stampless.
        W.name_source!("mine", day(3))
        W.name_source!("o/r", day(6))
        W.save_fetched(Dict{String,Any}("items" => Dict(
            U(1) => row(1; moved_at = day(4)), U(2) => row(2; moved_at = day(8)),
            U(3) => row(3; moved_at = day(11)), U(4) => row(4; moved_at = day(14)),
            U(5) => row(5; moved_at = day(12)),                 # stampless, unread: the bound
            U(6) => row(6; moved_at = day(9)),                  # unread against its stamp
            U(7) => row(7; moved_at = day(5)),                  # said unread
            U(8) => row(8; moved_at = day(7)),                  # snoozed
            U(9) => row(9; lane = "backlog", moved_at = day(5)))))  # stampless, read by the floor
        inbox = W.Events.load_inbox()
        inbox["items"][U(10)] = light(10, day(10))              # read
        inbox["items"][U(11)] = light(11, day(13))              # stampless, unread
        W.Events.save_inbox(inbox)
        for (n, when) in ((1, day(4)), (2, day(8)), (3, day(11)), (4, day(14)), (10, day(10)))
            W.set_read(U(n), when)
        end
        W.set_read_mark(U(2), day(8), "cafe")
        W.set_read(U(6), day(8))
        W.mark_unread([U(7)])
        W.set_read(U(8), day(7)); W.set_fields(U(8), ["snooze" => day(30)])
        before = answers()
        @test before[U(5)] === :unread && before[U(9)] === :read && before[U(11)] === :unread
        @test before[U(6)] === :unread && before[U(7)] === :unread && before[U(8)] === :read
        # Dry run: says what it would do and writes nothing.
        file = read(W.LOCAL[], String)
        c = W.consolidate!(at; dry_run = true)
        @test c.since == day(11)                       # the newest read movement under the 12th
        @test c.raised == Dict("mine" => day(11), "o/r" => day(11))
        @test Set(c.dropped) == Set([U(1), U(2), U(3), U(10)])
        @test read(W.LOCAL[], String) == file
        # For real: the floors rise together, the stamps the floor answers
        # for go, and every row answers the same as before.
        c = W.consolidate!(at)
        @test W.source_since() == Dict("mine" => day(11), "o/r" => day(11))
        @test answers() == before
        @test W.mark_at(U(1), "read") === nothing && W.mark_at(U(3), "read") === nothing
        @test W.mark_at(U(10), "read") === nothing
        @test W.mark_at(U(2), "read") === nothing && W.read_head(U(2)) == "cafe"   # the head stays
        @test W.read_at(U(4)) == day(14)               # past the floor: kept
        @test W.read_at(U(6)) == day(8)                # unread against its stamp: kept
        @test W.mark_at(U(7), "read") == ""            # a statement: kept
        @test W.read_at(U(8)) == day(7)                # snoozed: kept
        # Again: nothing to do, and nothing lowered.
        c = W.consolidate!(at)
        @test isempty(c.raised) && isempty(c.dropped)
        @test W.source_since() == Dict("mine" => day(11), "o/r" => day(11))
        # A light row pins the floor as a corpus row does: read the light
        # row 11 and the bound moves to the 14th; drop 5's claim on it
        # first, and the newest read movement under 13 is 11 still.
        W.set_read(U(5), day(12))
        c = W.consolidate!(at; dry_run = true)
        @test c.since == day(12)
        W.set_read(U(11), day(13))
        c = W.consolidate!(at)
        @test c.since == day(14) && W.source_since()["mine"] == day(14)
        @test answers() == merge(before, Dict(U(5) => :read, U(11) => :read))
        @test W.mark_at(U(4), "read") === nothing && W.mark_at(U(11), "read") === nothing
        # The 2026-09-16 file: thousands of blocks each carrying one stamp
        # fold to the source lines, and the rows that have to keep one.
        write(W.LOCAL[], "")
        W.name_source!("mine", day(14))
        many = Dict{String,Any}(U(n) => row(n; moved_at = day(1 + n % 12)) for n in 100:2376)
        many[U(5000)] = row(5000; moved_at = day(15))     # moved past the floor: said unread
        many[U(5001)] = row(5001; moved_at = day(15))     # and read past it
        W.save_fetched(Dict{String,Any}("items" => many))
        W.set_marks!(collect(keys(many)), "read", "2026-09-16T15:41:54Z")
        W.mark_unread([U(5000)])
        @test count(l -> startswith(l, "read = "), readlines(W.LOCAL[])) == 2279
        before = answers()
        c = W.consolidate!(at)
        @test c.since == day(15) && c.raised == Dict("mine" => day(15))
        @test length(c.dropped) == 2278
        @test answers() == before
        ls = readlines(W.LOCAL[])
        @test count(l -> startswith(l, "read = "), ls) == 1       # the one statement
        @test count(l -> startswith(l, "[\""), ls) == 2          # the source, and that row
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "the poll is a witness for the notifications, and a late one widens the ask" begin
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml"); write(W.LOCAL[], "")
    E = W.Events
    try
        issue(n, comments, state = "open"; by = "alice") = Dict{String,Any}(
            "html_url" => "https://github.com/o/r/issues/$n", "number" => n, "title" => "t$n",
            "repository_url" => "https://api.github.com/repos/o/r", "state" => state,
            "user" => Dict{String,Any}("login" => by),
            "updated_at" => "2026-09-13T12:0$(comments):00Z", "comments" => comments,
            "labels" => Any[])
        thread(n, at; reason = "subscribed") = Dict{String,Any}(
            "id" => "$n", "unread" => true, "reason" => reason, "updated_at" => at,
            "subject" => Dict{String,Any}("title" => "t", "type" => "Issue",
                "url" => "https://api.github.com/repos/o/r/issues/$n", "latest_comment_url" => nothing))
        U(n) = "https://github.com/o/r/issues/$n"
        polls = Ref(Any[]); threads = Ref(Any[]); asks = String[]
        srcs = [
            (label = "notifications", fetch = (since, ctx) -> (push!(asks, since); (threads[], nothing)),
             overlap = E.OVERLAP_REST, row = (t, _) -> E.thread_row(t, "me"; fetch = nothing)),
            (label = "o/r", fetch = since -> polls[], overlap = E.OVERLAP_REST,
             row = (r, _) -> E.issue_row(r, "me")),
        ]
        watched = () -> Set(["o/r"])
        # The last comment's author is the one thing the settling asks
        # GitHub for; unknown here, which is "not yours".
        run(at; kw...) = E.sync!(srcs, at; now = () -> at, watched = watched, login = "me",
                                 lastby = _ -> nothing, kw...)
        at = W.DateTime(2026, 9, 13, 12, 10)
        # A new issue by somebody else in a watched, polled repo, and no
        # thread yet: expected. One by you: not.
        polls[] = [issue(1, 0), issue(2, 0; by = "me")]
        run(at)
        ex = E.load_inbox()["expect"]
        @test haskey(ex, U(1)) && !haskey(ex, U(2))
        @test ex[U(1)]["event"] == "2026-09-13T12:00:00Z"
        # The thread arrives on the next poll, stamped 20s after: met, and
        # nothing said, since nothing was late.
        threads[] = [thread(1, "2026-09-13T12:00:20Z")]
        run(at + W.Minute(3))
        @test !haskey(E.load_inbox(), "expect") && !haskey(E.load_inbox(), "wide")
        @test E.load_inbox()["items"][U(1)]["notified"] == "2026-09-13T12:00:20Z"
        # A comment by somebody else (the count rose) with no thread behind
        # it: expected; unmet past the grace, the lag is declared and the ask
        # goes wide - a day behind the cursor.
        threads[] = Any[]
        polls[] = [issue(1, 1)]
        run(at + W.Minute(6))
        @test E.load_inbox()["expect"][U(1)]["event"] == "2026-09-13T12:01:00Z"
        @test !haskey(E.load_inbox(), "wide")
        asks_before = length(asks)
        run(at + W.Minute(25))                 # > EXPECT_GRACE later; last comment unknown -> not yours
        @test haskey(E.load_inbox(), "wide")
        run(at + W.Minute(28))
        @test length(asks) == asks_before + 2
        @test W.ts(asks[end]) == W.DateTime(2026, 9, 12, 12, 35)   # a day behind the cursor
        # It arrives, an hour late, stamped with the event's time: met, the
        # lag reported, and the ask narrow again.
        threads[] = [thread(1, "2026-09-13T12:01:00Z")]
        run(at + W.Minute(70))
        @test !haskey(E.load_inbox(), "wide") && !haskey(E.load_inbox(), "expect")
        # And the user's word ends the waiting whatever is still awaited.
        polls[] = [issue(3, 0)]; threads[] = Any[]
        run(at + W.Minute(75))
        run(at + W.Minute(95))
        @test haskey(E.load_inbox(), "wide")
        @test E.caught_up!() == 1
        @test !haskey(E.load_inbox(), "wide") && !haskey(E.load_inbox(), "expect")
        # A label edit - updated moved, nothing else - is not evidence.
        polls[] = [merge(issue(3, 0), Dict("updated_at" => "2026-09-13T13:00:00Z"))]
        run(at + W.Minute(100))
        @test !haskey(E.load_inbox(), "expect")
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "work that has gone quiet on somebody" begin
    # Two days of silence over a weekend is not silence, it is a weekend.
    @test W.workdays_since("2026-08-28T17:00:00Z", W.DateTime(2026, 8, 31, 17)) == 1
    @test W.workdays_since("2026-08-28T17:00:00Z", W.DateTime(2026, 9, 1, 9)) == 2
    @test W.workdays_since("2026-08-31T09:00:00Z", W.DateTime(2026, 9, 2, 9)) == 2
    # By day and not by hour: the answer must not depend on the hour somebody
    # happened to be typing.
    @test W.workdays_since("2026-08-31T09:00:00Z", W.DateTime(2026, 9, 2, 23)) ==
          W.workdays_since("2026-08-31T23:00:00Z", W.DateTime(2026, 9, 2, 9))
    @test W.workdays_since(nothing, W.DateTime(2026, 9, 3)) == 0
    @test W.workdays_since("2026-09-03T09:00:00Z", W.DateTime(2026, 9, 3, 17)) == 0

    at = W.DateTime(2026, 9, 3, 12)
    base() = Dict{String,Any}("state" => "OPEN", "lane" => "review",
                              "author" => "alice", "created" => "2026-08-20T00:00:00Z")
    look(r) = W.second_look(r, at, 2)

    # The author spoke and nobody answered.
    r = base(); r["last_comment_by"] = "alice"
    r["last_comment_at"] = "2026-08-28T17:00:00Z"
    r["head_at"] = "2026-08-20T00:00:00Z"
    @test occursin("asked, then quiet", look(r)) && occursin("4 work days", look(r))
    # Somebody did answer, so nobody is waiting on anybody.
    r2 = copy(r); r2["last_comment_by"] = "bob"
    @test isempty(look(r2))
    # A review is an answer too - anybody's, whatever it said.
    for k in ("review_at", "my_last_review_at")
        r2 = copy(r); r2[k] = "2026-08-31T10:00:00Z"
        @test isempty(look(r2))
        # ...but only one that came after the author spoke.
        r2[k] = "2026-08-01T10:00:00Z"
        @test occursin("asked, then quiet", look(r2))
    end
    # Opened, and nothing said at all: the other reading of the same silence,
    # measured from the opening.
    r3 = base()
    @test occursin("opened, then quiet", look(r3)) && occursin("10 work days", look(r3))
    # A push is not an action and it used to be: the author working on their
    # own branch says nothing about whether anybody is waiting. It neither
    # fires on its own nor moves the clock.
    r4 = base(); r4["head_at"] = "2026-09-01T00:00:00Z"
    @test look(r4) == look(r3)
    r5 = copy(r); r5["head_at"] = "2026-09-02T00:00:00Z"
    @test occursin("4 work days", look(r5))

    # A floor, and only a floor.
    @test isempty(W.second_look(r, W.DateTime(2026, 8, 31, 9), 2))   # not late yet
    # There is no ceiling any more. A pull request quiet since last January is
    # still a pull request waiting on somebody, and it used to stop being
    # reported at 20 work days - leaving the lane on a day nobody chose, with
    # nothing recorded and nothing to undo. The lane is ordered newest first, so
    # it is at the bottom rather than in the way, and `s` `1` is what takes it
    # out: a decision, in `marks.json`, undone by `z`, back when it moves.
    old = base(); old["created"] = "2025-01-02T00:00:00Z"
    @test occursin("opened, then quiet", look(old))
    @test occursin("work days", look(old))
    # And nothing fires on work that is over, or on the pile that is not a
    # to-do list.
    done_ = copy(r); done_["state"] = "MERGED"
    @test isempty(look(done_))
    # The pile is asked for by name rather than carried on the row, and it is
    # the lane that says so - `track = "background"` was the other half of it
    # and is gone, along with the level that could never wake. The pile is
    # what the clocks brought in; the retired lanes still count, so a file
    # from before is let go of cleanly.
    for l in ("notifications", "activity", "firehose", "mentioned_pr", "commented_issue")
        pile = copy(r); pile["lane"] = l
        @test isempty(look(pile)) && W.in_pile(pile)
    end
    @test !W.in_pile(r)
    # Nothing to measure at all is not silence.
    nothing_ = base(); delete!(nothing_, "created")
    @test isempty(look(nothing_))

    # It is a lane of its own in the filter pane, and it needs no enabling -
    # which is the whole difference from a snooze.
    st = mkstate()
    @test any(x -> x[1] === :second, W.TAGS)
    quiet = W.Item(url = "u", ref = "a#1", repo = "a/b", number = 1, title = "t",
                   secondlook = "asked, then quiet for 3 work days")
    @test :second in W.tags_of(quiet)
    @test isempty(W.tags_of(W.Item(url = "u2", ref = "a#2", repo = "a/b",
                                   number = 2, title = "t")))
    # Filed work still carries the tag, and the sleep axis is what takes it out
    # of a list: two questions, two axes, no precedence between them.
    @test :second in W.tags_of(quiet, W.Marks(archived = Dict("u" => "2026-09-01T00:00:00Z")))
    # And the reason is shown where the item's facts are.
    @test any(l -> occursin("quiet", l) && occursin("3 work days", l),
              W.astrip.(W.meta_lines(st, quiet, 60)))
end

@testset "a reply owed is a fact about the thread, not about its state" begin
    cfg = W.config()
    at = W.DateTime(2026, 9, 13)
    me = cfg["login"]
    # Read off the notification `reason`, which is GitHub saying you were
    # named - it was the lane while the mention searches existed.
    r = Dict{String,Any}("lane" => "notifications", "reason" => "mention",
                         "type" => "Issue", "state" => "OPEN",
                         "mine" => false, "labels" => String[],
                         "last_comment_at" => "2026-09-10T10:00:00Z",
                         "last_comment_by" => "alice",
                         "updated" => "2026-09-10T10:00:00Z")
    why = W.reply_owed(r, cfg, at)
    @test occursin("mentioned you 2d ago", why) && occursin("theirs", why)
    # On a closed one the fact is still the fact. That is the whole reason it
    # is a fact and not a bucket: the question on a closed thread was the one
    # nothing here could see, because "over" answered first.
    closed = copy(r); closed["state"] = "CLOSED"
    @test W.reply_owed(closed, cfg, at) == why
    st_ = Dict{String,Any}()
    W.apply_state!(closed, st_, cfg, at)
    @test closed["reply"] == why && W.isover(closed)
    # And a mention that owes a reply is in front of you, not in the pile.
    @test !W.in_pile(closed)
    # A team mention asks the same way; GitHub says which.
    team = copy(r); team["reason"] = "team_mention"
    @test W.reply_owed(team, cfg, at) == why
    # Your own last word answers it; a bot's or nobody's is nothing to answer.
    mine = copy(r); mine["last_comment_by"] = me
    @test isempty(W.reply_owed(mine, cfg, at))
    nobody = copy(r); nobody["last_comment_by"] = nothing
    @test isempty(W.reply_owed(nobody, cfg, at))
    # Past `reply_days` it is history, not a question.
    old = copy(r); old["last_comment_at"] = "2026-01-10T10:00:00Z"
    old["updated"] = old["last_comment_at"]
    @test isempty(W.reply_owed(old, cfg, at))
    # And only a mention asks: a thread you commented on where a stranger
    # spoke last is every thread on a repo you maintain, and a watched
    # repository's traffic is nobody asking anything.
    for reason in ("comment", "subscribed", "author", nothing)
        spoke = copy(r); spoke["reason"] = reason
        @test isempty(W.reply_owed(spoke, cfg, at))
        @test W.in_pile(spoke)
    end

    # A tag in the browser, whatever the state, and the reason where the
    # item's facts are - and the `unanswered` view is that tag over the
    # default show, which has the closed news in it.
    st = mkstate()
    @test any(x -> x[1] === :reply, W.TAGS)
    owed = W.Item(url = "u", ref = "a#1", repo = "a/b", number = 1, title = "t",
                  state = "CLOSED", reply = why)
    @test :reply in W.tags_of(owed)
    @test any(l -> occursin("reply", l) && occursin("2d ago", l),
              W.astrip.(W.meta_lines(st, owed, 60)))
    v = first(d for (n, d) in W.views() if startswith(n, "unanswered"))
    @test v == Dict("tag" => ["reply"])
    W.apply_view!(st, v)
    @test st.filters.show == W.SHOW_DEFAULT && st.filters.tags == Set([:reply])
    @test isempty(st.filters.lanes)
end

@testset "mergeability is asked of one pull request, when it is looked at" begin
    # `mergeable` is what GitHub computes lazily, and asking is what makes it
    # compute: a lane page that named it took 20-33s on four runs in twelve
    # and never left 5-8s without it. So no lane asks, no row carries it, and
    # the pane asks `merge_state` for the one pull request under the cursor -
    # the same call the merge prompt makes - and says it that prompt's way.
    @test !occursin("mergeable", W.PR_FIELDS)
    @test !occursin("mergeable", W.QUERY)
    st = mkstate()
    base = (url = "https://example.invalid/pr/1", ref = "a#1", repo = "a/b",
            number = 1, title = "t", is_pr = true)
    says(it) = W.astrip(join([l for l in W.meta_lines(st, it, 60)
                              if occursin("mergeable", l)], " "))
    ms(; kw...) = (; id = "x", oid = "o", state = "OPEN", draft = false,
                     mergeable = "MERGEABLE", status = "CLEAN", base = "master",
                     commits = 1, methods = String[], text = Dict{String,Tuple{String,String}}(),
                     kw...)
    # Nothing until it has been asked, and nothing once the pull request is
    # over: a merged one has no merge left to be possible.
    @test says(W.Item(; base..., state = "OPEN")) == ""
    st.metakey = base.url; st.merge = ms()
    @test says(W.Item(; base..., state = "OPEN")) == "mergeable clean"
    st.merge = ms(; mergeable = "CONFLICTING", status = "DIRTY")
    @test says(W.Item(; base..., state = "OPEN")) == "mergeable conflicts with master"
    st.merge = ms(; status = "BEHIND")
    @test says(W.Item(; base..., state = "OPEN")) == "mergeable behind master"
    @test says(W.Item(; base..., state = "MERGED")) == ""
    @test says(W.Item(; base..., state = "CLOSED")) == ""
    # And what was fetched for one item is not said about another.
    @test says(W.Item(; base..., url = "https://example.invalid/pr/2", state = "OPEN")) == ""
    # A value wider than the pane wraps under itself at the value column
    # rather than being cut at the edge: "blocked — a required review or check
    # is missing" is 46 columns, and the pane is often 40.
    st.merge = ms(; status = "BLOCKED")
    ls = W.astrip.(W.meta_lines(st, W.Item(; base..., state = "OPEN"), 40))
    i = findfirst(l -> startswith(l, "mergeable"), ls)
    @test i !== nothing && startswith(ls[i + 1], " "^10 * "or check")
    @test all(W.awidth(l) <= 40 for l in ls)
    @test occursin("check is missing", ls[i + 1])
end

@testset "a settled thread is out of the way, not gone" begin
    # Comments are placed against the hunk they point into. Resolution is a
    # property of the *thread* and REST carries no trace of it, so a
    # conversation settled six weeks ago arrived in the shape of one waiting for
    # an answer.
    hunk = W.Node("a.jl  @@ 10,3 @@", " ctx\n+added", :diff, true)
    merge!(hunk.meta, Dict{String,Any}("file" => "a.jl", "start" => 10, "count" => 3,
                                       "ostart" => 40, "ocount" => 2))
    cs = [Dict{String,Any}("id" => 1, "path" => "a.jl", "line" => 11, "side" => "RIGHT",
                           "body" => "still wondering", "user" => Dict("login" => "a"),
                           "created_at" => "2026-01-01T00:00:00Z"),
          Dict{String,Any}("id" => 2, "path" => "a.jl", "line" => 11, "side" => "RIGHT",
                           "body" => "settled long ago", "user" => Dict("login" => "b"),
                           "created_at" => "2026-01-02T00:00:00Z")]
    # With nothing known to be resolved, both are inline, as before.
    ns = W.attach_comments([deepcopy(hunk)], cs, "u")
    @test occursin("💬2", ns[1].header) && !occursin("✓", ns[1].header)
    @test length(ns) > 2

    ns2 = W.attach_comments([deepcopy(hunk)], cs, "u", Set([2]))
    # Two marks, because they say different things: what is waiting for an
    # answer is why you are reading the hunk, what was answered is why you can
    # stop.
    @test occursin("💬1", ns2[1].header) && occursin("✓1", ns2[1].header)
    # The open one is inline; the settled one is under a closed node of its own,
    # beneath the hunk it belongs to rather than in a pile at the end.
    txt = [W.astrip(n.header) for n in ns2]
    i = findfirst(h -> occursin("resolved", h), txt)
    @test i !== nothing && !ns2[i].open
    @test any(n -> occursin("still wondering", n.raw), ns2[1:i-1])
    @test all(!occursin("settled long ago", n.raw) for n in ns2[1:i])
    @test any(n -> occursin("settled long ago", n.raw), ns2[i+1:end])
    @test ns2[i+1].depth > ns2[i].depth          # so folding the node hides it
    # Everything resolved is a hunk with nothing waiting on it.
    ns3 = W.attach_comments([deepcopy(hunk)], cs, "u", Set([1, 2]))
    @test !occursin("💬", ns3[1].header) && occursin("✓2", ns3[1].header)

    # A comment whose line is gone has nowhere to be placed, and the same split
    # applies to those: settled *and* outdated is over twice over, while an open
    # one is a remark nobody answered and the line moving did not make it moot.
    gone = [Dict{String,Any}("id" => 3, "path" => "a.jl", "line" => nothing,
                             "body" => "open, and adrift", "user" => Dict("login" => "a"),
                             "created_at" => "2026-01-03T00:00:00Z"),
            Dict{String,Any}("id" => 4, "path" => "a.jl", "line" => nothing,
                             "body" => "settled, and adrift", "user" => Dict("login" => "b"),
                             "created_at" => "2026-01-04T00:00:00Z")]
    ns4 = W.attach_comments([deepcopy(hunk)], gone, "u", Set([4]))
    heads = [W.astrip(n.header) for n in ns4]
    j = findfirst(h -> occursin("on lines that have since changed", h) &&
                       !occursin("resolved", h), heads)
    k = findfirst(h -> occursin("resolved, on lines", h), heads)
    @test j !== nothing && k !== nothing && j < k
    @test !ns4[j].open && !ns4[k].open              # both put away
    @test occursin("1 comment on lines", heads[j])
end

@testset "a draft that leaves with its item" begin
    # Everything still on the dashboard is reconciled by being opened. An item
    # that has gone cannot be: the lane is items, so a mark on a url that is no
    # longer one of them can never be shown or navigated to again.
    gone = [("https://github.com/o/r/pull/1", "r#1"),
            ("https://github.com/o/r/pull/2", "r#2")]
    still = "https://github.com/o/r/pull/3"
    for (u, _) in gone
        W.draft!(u)
    end
    W.draft!(still)
    asked = String[]
    # Sent or discarded while it was closing: the mark goes with the item.
    ask(url) = (push!(asked, url); (id = "PR_x", review = "", n = 0))
    @test W.reconcile_drafts!(gone, ask) == 2
    @test sort(asked) == sort([u for (u, _) in gone])   # and nothing else asked
    @test collect(keys(W.load_drafts())) == [still]

    # Still unsent, on a pull request that has just closed: kept, and said out
    # loud, because this is the last moment anything will mention it.
    W.draft!(first(first(gone)))
    held(url) = (id = "PR_x", review = "PRR_y", n = 3)
    said = mktemp() do path, io
        redirect_stderr(() -> @test(W.reconcile_drafts!(gone, held) == 0), io)
        flush(io)
        read(path, String)
    end
    @test occursin("r#1", said) && occursin("unsent draft review", said)
    @test haskey(W.load_drafts(), first(first(gone)))

    # A question that cannot be asked is not an answer: the mark stays.
    boom(url) = error("no network")
    @test W.reconcile_drafts!(gone, boom) == 0
    @test haskey(W.load_drafts(), first(first(gone)))

    for (u, _) in gone
        W.undraft!(u)
    end
    W.undraft!(still)
    @test isempty(W.load_drafts())
end

@testset "being asked to review is a move" begin
    # A *re*-request is the only kind you get on something you have already
    # read, and until the request was fetched nothing about it changed:
    # `reviewDecision` stays where it was, `review_count` stays where it was,
    # and GitHub's re-request button posts no comment. So the item stayed read.
    now_ = W.ts("2026-09-12T11:00:00Z")
    rec(; kw...) = merge(Dict{String,Any}("track" => "normal",
                                         "review_decision" => "REVIEW_REQUIRED",
                                         "ci" => "SUCCESS",
                                         "head_at" => "2026-09-01T00:00:00Z",
                                         "their_comment_at" => "2026-09-01T00:00:00Z",
                                         "human_comment_at" => "2026-09-01T00:00:00Z",
                                         "moved_at" => "2026-09-01T00:00:00Z",
                                         "unresolved" => 0),
                         Dict{String,Any}(String(k) => v for (k, v) in kw))
    was(d) = NamedTuple(Symbol(k) => v for (k, v) in d)
    quiet = rec()
    asked = rec(; review_requested = true, review_requested_at = "2026-09-02T14:02:00Z")
    # Both levels, because there is no level at which being named is noise -
    # `loose` ignores a stranger's CI and a bot's comment, and this is neither.
    for lvl in ("normal", "loose")
        q = rec(; track = lvl); a = merge(asked, Dict("track" => lvl))
        @test W.moved_stamp(was(q), a, now_) == "2026-09-02T14:02:00Z"
    end

    # **The key is the time and not the bool.** Being asked is an event, and
    # the timeline says when; the standing `reviewRequests` connection says
    # only whether you are asked now, and says it to the change list, not to
    # the wake table. So the bool flipping on its own - true, absent, or
    # written by a hand that did not know better, false - is not a movement.
    for b in (true, nothing, false)
        @test W.moved_stamp(was(asked), rec(; review_requested = b,
                                            review_requested_at = "2026-09-02T14:02:00Z"), now_) ==
              "2026-09-01T00:00:00Z"
    end

    # And nothing else about the item had to change for that to be true, which
    # is the whole complaint: the two records differ in the request alone.
    @test setdiff(keys(asked), keys(quiet)) == Set(["review_requested", "review_requested_at"])
    @test all(quiet[k] == asked[k] for k in keys(quiet))

    # A re-request is a newer time on the same standing bool, and moves.
    again = rec(; review_requested = true, review_requested_at = "2026-09-05T09:00:00Z")
    @test W.moved_stamp(was(asked), again, now_) == "2026-09-05T09:00:00Z"

    # Withdrawing it does not. This said the opposite once - that being off
    # the hook was what `r` on it was waiting to hear - and was decided the
    # other way on 2026-09-12: being let off is the end of a claim on your
    # attention, not a claim on it. The standing bool clears and the time
    # stays, and the time is the key.
    off = rec(; review_requested = nothing, review_requested_at = "2026-09-02T14:02:00Z")
    @test W.moved_stamp(was(asked), off, now_) == "2026-09-01T00:00:00Z"
end

@testset "nothing ages out of being unread, and nothing leaves at all" begin
    # A row is an item because a lane returned it, and every lane is
    # `is:open` - so the merge that took it out of the lanes used to take it
    # out of the snapshot, unread mark and all, once the closed lanes' window
    # had passed. A row that was in front of you and that no lane returns is
    # carried: kept as it was until a clock says it moved, then asked by url.
    # And since 2026-09-14 it is kept *for good*, read or not - the corpus is
    # the index of everything that was ever in front of you, the `read` and
    # `filed` boxes are what hold the read and the filed, and a snooze on a
    # row that had left would be a wake with nothing to wake. It used to be
    # let go once read, which was right while the closed lanes and the bulk
    # searches re-returned whatever moved, and wrong the day they went.
    @test W.in_pile(Dict{String,Any}("lane" => "firehose"))
    @test !W.in_pile(Dict{String,Any}("lane" => "mine"))
    # Exercised live on 2026-09-13 with julia#61767, merged by somebody else
    # in May and returned by no lane: carried, seen merged, `moved_at` dated
    # by the merge, kept as unread through two refreshes.
end
@testset "a movement is dated by the thing that moved" begin
    # The refresh clock is the honest answer for a state with no clock of its
    # own and the wrong one for a comment: `r` stamps you read at the moment the
    # thread was fetched, which is fresher than any refresh, so a comment posted
    # at 09:55 and read at 10:00 was dated 11:00 by the refresh that first saw
    # it, and the item came back unread for something you had already read.
    now_ = W.ts("2026-09-12T11:00:00Z")
    row(; kw...) = merge(Dict{String,Any}("track" => "normal",
                                          "their_head" => "a1b2c3",
                                          "head_at" => "2026-09-12T08:00:00Z",
                                          "their_comment_at" => "2026-09-12T09:00:00Z",
                                          "human_comment_at" => "2026-09-12T09:00:00Z",
                                          "review_at" => "2026-09-12T08:30:00Z",
                                          "moved_at" => "2026-09-12T09:00:00Z"),
                         Dict{String,Any}(String(k) => v for (k, v) in kw))
    # The shape the snapshot is read back in: a row `jget` can be asked about.
    was(d = row()) = NamedTuple(Symbol(k) => v for (k, v) in d)
    old = was()
    # And nothing moving is an answer it gives, not a case it never sees: it
    # is the one arbiter now, asked about every row, and the mark stays put.
    @test W.moved_stamp(old, row(), now_) == "2026-09-12T09:00:00Z"
    @test W.moved_stamp(old, row(; their_comment_at = "2026-09-12T09:55:00Z",
                                 human_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          "2026-09-12T09:55:00Z"
    # Being handed the item has the shape of being asked to review it.
    @test W.moved_stamp(old, row(; assigned_at = "2026-09-12T10:05:00Z"), now_) ==
          "2026-09-12T10:05:00Z"
    # A review says when it was submitted, by the same rule.
    @test W.moved_stamp(old, row(; review_at = "2026-09-12T10:15:00Z"), now_) ==
          "2026-09-12T10:15:00Z"

    # **A push is a sha and the sha has no time**, so it is dated by `head_at` -
    # the committer date of the commit the branch now points at, which is the
    # closest thing GitHub offers.
    @test W.moved_stamp(old, row(; their_head = "ffff", head_at = "2026-09-12T10:30:00Z"),
                        now_) == "2026-09-12T10:30:00Z"
    # And `head_at` moving on its own is not a movement at all any more: a
    # rebase rewrites it, and whether there is anything new to look at is what
    # the sha says.
    @test W.moved_stamp(old, row(; head_at = "2026-09-12T10:30:00Z"), now_) ==
          "2026-09-12T09:00:00Z"

    # Being asked is dated by the asking: a timeline event naming you, with a
    # time of its own.
    @test W.moved_stamp(old, row(; review_requested = true,
                                 review_requested_at = "2026-09-12T10:20:00Z"), now_) ==
          "2026-09-12T10:20:00Z"
    # And so is somebody else finishing it, which is a thing GitHub mails about
    # and a thing there is no point sleeping through.
    @test W.moved_stamp(old, row(; state = "MERGED", state_at = "2026-09-12T10:40:00Z"), now_) ==
          "2026-09-12T10:40:00Z"
    # The standing bool is not a key, so it flipping on its own - the timeline
    # truncated past the event that flipped it - is not a movement.
    @test W.moved_stamp(old, row(; review_requested = true), now_) == "2026-09-12T09:00:00Z"

    # The CI bool has no clock anywhere, so the refresh that saw it is the
    # only date there is.
    @test W.moved_stamp(old, row(; ci_failed = true), now_) == W.stamp(now_)
    # Mixed is now: dating the pair by the comment would say the item moved
    # before the CI failure that moved it beside it did.
    @test W.moved_stamp(old, row(; ci_failed = true,
                                 their_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          W.stamp(now_)
    # **And a bool moves on one edge.** It going red is the event; it going
    # green is not - the green arrived as the push that fixed it, or is a
    # rerun of the same commit - and a rerun that passes through pending would
    # otherwise wake the item twice for one failure. A hash of the value
    # differs on both edges, which is why a bool is not hashed any more.
    red = was(row(; ci_failed = true))
    @test W.moved_stamp(red, row(; ci_failed = nothing), now_) == "2026-09-12T09:00:00Z"
    @test W.moved_stamp(red, row(; ci_failed = true), now_) == "2026-09-12T09:00:00Z"
    # It clearing beside a comment is the comment's movement, dated by it.
    @test W.moved_stamp(red, row(; ci_failed = nothing,
                                 their_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          "2026-09-12T09:55:00Z"

    # Never backwards. `head_at` is a committer date, so a force-push of an
    # older commit carries an older one - and there is something to show for
    # that, since the sha says the branch is not what you last saw. A time that
    # cannot account for the change does not get to explain it.
    @test W.moved_stamp(old, row(; their_head = "ffff",
                                 head_at = "2026-09-12T07:00:00Z"), now_) == W.stamp(now_)
    # A deleted comment moves `last_comment_at` back to the one before it, and
    # that one is fine either way: what moved the key is gone, so missing it
    # costs nothing and catching it costs an unread item with nothing new in it.
    # It falls out the same way rather than being asked for - what the rule is
    # really protecting is that `moved_at` only goes forward, since an item
    # unread since an 11:00 CI failure would otherwise be marked read by a
    # deletion at 09:00, losing the change nobody looked at rather than the
    # comment nobody can.
    @test W.moved_stamp(old, row(; their_comment_at = "2026-09-12T08:30:00Z",
                                 human_comment_at = "2026-09-12T08:30:00Z"), now_) ==
          W.stamp(now_)

    # **A key that was not there before is not an event.** A row the bulk lanes
    # returned carries no reviews at all, so `review_at` arrives the day an
    # active lane claims it; a key added to `TRACK_KEYS` arrives on every row at
    # once. Either would read as movement on every row it lands on - which is
    # the wave that made `review_requested` have to be true-or-absent.
    husk = was(row(; review_at = nothing, their_head = nothing))
    @test W.moved_stamp(husk, row(), now_) == "2026-09-12T09:00:00Z"
    # Arriving with a *newer* time is a genuine first review, or a first
    # comment, and counts.
    @test W.moved_stamp(husk, row(; review_at = "2026-09-12T10:45:00Z"), now_) ==
          "2026-09-12T10:45:00Z"
    # The request that was a bool on the old row and is a time on the new one
    # is the same arrival: a request made before the item last moved is the
    # record catching up, and one made after it is the request you were never
    # told about while the bool was silent on a row that had already moved.
    bool_row = was(row(; review_requested = true))
    @test W.moved_stamp(bool_row, row(; review_requested = true,
                                      review_requested_at = "2026-09-12T08:45:00Z"), now_) ==
          "2026-09-12T09:00:00Z"
    @test W.moved_stamp(bool_row, row(; review_requested = true,
                                      review_requested_at = "2026-09-12T09:30:00Z"), now_) ==
          "2026-09-12T09:30:00Z"

    # The level decides which keys are asked about, here as everywhere else.
    # `loose` watches the human comment and not the CI; it does watch the head
    # since 2026-09-12, because a push on something you are watching loosely
    # is the item being active, which is what you are watching it to know.
    loose = was(row(; track = "loose"))
    @test W.moved_stamp(loose, row(; track = "loose", their_head = "ffff",
                                  head_at = "2026-09-12T10:30:00Z"), now_) ==
          "2026-09-12T10:30:00Z"
    @test W.moved_stamp(loose, row(; track = "loose",
                                  human_comment_at = "2026-09-12T09:55:00Z",
                                  their_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          "2026-09-12T09:55:00Z"
    @test W.moved_stamp(loose, row(; track = "loose", ci_failed = true), now_) ==
          "2026-09-12T09:00:00Z"

    # **And which key it was**, kept for the pane's one word: the key whose
    # time is the stamp, the bool that rose, the key whose time could not
    # account for the change; none when the mark stayed.
    @test W.movement(old, row(), now_) == ("2026-09-12T09:00:00Z", "")
    @test W.movement(old, row(; their_comment_at = "2026-09-12T09:55:00Z",
                              human_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          ("2026-09-12T09:55:00Z", "their_comment_at")
    @test W.movement(loose, row(; track = "loose", their_comment_at = "2026-09-12T09:55:00Z",
                                human_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          ("2026-09-12T09:55:00Z", "human_comment_at")
    @test W.movement(old, row(; their_head = "ffff", head_at = "2026-09-12T10:30:00Z"), now_) ==
          ("2026-09-12T10:30:00Z", "their_head")
    @test W.movement(old, row(; ci_failed = true), now_) == (W.stamp(now_), "ci_failed")
    @test W.movement(old, row(; their_head = "ffff", head_at = "2026-09-12T07:00:00Z"), now_) ==
          (W.stamp(now_), "their_head")
    # Two in one refresh: the later one is the word, since it is the stamp.
    @test W.movement(old, row(; review_at = "2026-09-12T10:15:00Z",
                              their_comment_at = "2026-09-12T09:55:00Z",
                              human_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          ("2026-09-12T10:15:00Z", "review_at")
    @test W.movement(old, row(; state = "MERGED", state_at = "2026-09-12T10:40:00Z"), now_)[2] ==
          "state_at"
    @test W.movement(husk, row(), now_)[2] == ""                # arriving is not an event
    @test W.movement(husk, row(; review_at = "2026-09-12T10:45:00Z"), now_)[2] == "review_at"
end

@testset "why says what moved, a word each" begin
    # The stamp says when, the bold says that; neither says what. The pane
    # reads the wake table's keys off the item against the read stamp - so
    # every movement since you looked is a word, newest first, with no
    # refresh between - and the refresh's own answer for the last one, which
    # is the one a key cannot always date. Under `local`, with the reason
    # GitHub gave dim after it.
    st = mkstate()
    mk(; kw...) = W.with(st.items[1]; url = "https://github.com/o/r/pull/9", ref = "r#9",
                         moved_at = "2026-09-12T10:00:00Z", updated = "2026-09-12T10:00:00Z",
                         state = "OPEN", track = "normal", moved_by = "", head_at = "",
                         head_by = "", their_comment_at = "", human_comment_at = "",
                         review_at = "", review_requested_at = "", assigned_at = "",
                         state_at = "", kw...)
    at = W.ts("2026-09-13T00:00:00Z")
    marks(read; wake = nothing, rang = false) =
        W.Marks(read = read === nothing ? Dict{String,String}() : Dict(mk().url => read),
                wake = wake === nothing ? Dict{String,String}() : Dict(mk().url => wake),
                now = W.stamp(at), rang = rang ? Set([mk().url]) : Set{String}())
    read = marks("2026-09-12T08:00:00Z")
    # The words, one per key.
    @test W.moved_words(mk(; their_comment_at = "2026-09-12T09:00:00Z"), read) == ["comment"]
    @test W.moved_words(mk(; head_at = "2026-09-12T09:00:00Z", head_by = "alice"), read) == ["pushed"]
    @test W.moved_words(mk(; review_at = "2026-09-12T09:00:00Z"), read) == ["reviewed"]
    @test W.moved_words(mk(; review_requested_at = "2026-09-12T09:00:00Z"), read) == ["review requested"]
    @test W.moved_words(mk(; assigned_at = "2026-09-12T09:00:00Z"), read) == ["assigned"]
    @test W.moved_words(mk(; state_at = "2026-09-12T09:00:00Z", state = "MERGED"), read) == ["merged"]
    @test W.moved_words(mk(; state_at = "2026-09-12T09:00:00Z", state = "CLOSED"), read) == ["closed"]
    @test W.moved_words(mk(; state_at = "2026-09-12T09:00:00Z"), read) == ["reopened"]
    # All of them, newest first, and each once: the comment and the push
    # since the stamp, not the review before it.
    @test W.moved_words(mk(; their_comment_at = "2026-09-12T09:00:00Z",
                            head_at = "2026-09-12T09:30:00Z", head_by = "alice",
                            review_at = "2026-09-12T07:00:00Z"), read) == ["pushed", "comment"]
    @test W.moved_words(mk(; their_comment_at = "2026-09-12T09:00:00Z",
                            moved_by = "their_comment_at"), read) == ["comment"]
    # `r` empties it, with no refresh between.
    @test isempty(W.moved_words(mk(; their_comment_at = "2026-09-12T09:00:00Z"),
                                marks("2026-09-12T10:00:00Z")))
    # The level decides which keys are read: loosely, a bot's comment is not
    # one - the stamp alone says the row moved - and the human key is.
    @test W.moved_words(mk(; track = "loose", their_comment_at = "2026-09-12T09:00:00Z"), read) == ["moved"]
    @test W.moved_words(mk(; track = "loose", human_comment_at = "2026-09-12T09:00:00Z"), read) == ["comment"]
    # Your own push after theirs dates the head and is not news; theirs
    # before it is the refresh's to remember.
    me = W.login()
    @test W.moved_words(mk(; head_at = "2026-09-12T09:30:00Z", head_by = me), read) == ["moved"]
    @test W.moved_words(mk(; head_at = "2026-09-12T09:30:00Z", head_by = me,
                            moved_by = "their_head"), read) == ["pushed"]
    # What no key can date: the bool that rose, and the force-push of an
    # older commit, both dated by the refresh and named by it - listed
    # first, since the stamp they set is the newest thing on the row.
    @test W.moved_words(mk(; moved_by = "ci_failed", their_comment_at = "2026-09-12T09:00:00Z"),
                        read) == ["CI failed", "comment"]
    @test W.moved_words(mk(; moved_by = "their_head", head_at = "2026-09-12T07:00:00Z",
                            head_by = "alice"), read) == ["pushed"]
    # A row never in front of you is new, whatever is on it; one that
    # arrived with things on it since the floor says those.
    @test W.moved_words(mk(; moved_by = "new", their_comment_at = "2026-09-12T09:00:00Z"),
                        marks(nothing)) == ["new"]
    @test W.moved_words(mk(; moved_by = "new"), read) == ["new"]
    @test W.moved_words(mk(; moved_by = "new", their_comment_at = "2026-09-12T09:00:00Z"), read) == ["comment"]
    # A light row has the poll's clock and no table; a woken snooze is the
    # wake and not the table; an adopted branch has neither.
    @test W.moved_words(mk(; moved_at = ""), read) == ["updated"]
    @test W.moved_words(mk(; their_comment_at = "2026-09-12T09:00:00Z"),
                        marks("2026-09-12T08:00:00Z"; wake = "2026-09-12T12:00:00Z")) == ["woke", "comment"]
    @test W.moved_words(mk(; url = "local:o/r/wip", moved_by = "their_head"), read) == String[]
    # An agent's bell is first, whatever else moved when: it is standing now.
    # And it is the one movement an adopted branch can have.
    @test W.moved_words(mk(; their_comment_at = "2026-09-12T09:00:00Z"),
                        marks("2026-09-12T08:00:00Z"; rang = true)) == ["agent", "comment"]
    @test W.moved_words(mk(), marks("2026-09-12T10:00:00Z"; rang = true)) == ["agent"]
    @test W.moved_words(mk(; moved_by = "new"), marks(nothing; rang = true)) == ["agent", "new"]
    @test W.moved_words(mk(; url = "local:o/r/wip"),
                        W.Marks(now = W.stamp(at), rang = Set(["local:o/r/wip"]))) == ["agent"]
    # On the pane: under `local`, unread with the words, read without.
    it = mk(; review_at = "2026-09-12T10:00:00Z", their_comment_at = "2026-09-12T09:00:00Z")
    st.read = Dict{String,String}(); st.sources = Dict{String,String}()
    plain = W.astrip(join(W.meta_lines(st, it, 60, at), "\n"))
    @test occursin("why       unread: new\n", plain)
    st.read = Dict(it.url => "2026-09-12T08:00:00Z")
    plain = W.astrip(join(W.meta_lines(st, it, 60, at), "\n"))
    @test occursin("why       unread: reviewed, comment\n", plain)
    @test first(findfirst("local", plain)) < first(findfirst("why  ", plain))
    st.read = Dict(it.url => "2026-09-12T10:00:00Z")
    plain = W.astrip(join(W.meta_lines(st, it, 60, at), "\n"))
    @test occursin("why       read\n", plain)
    @test !occursin("unread", plain)
    # And `wl unread` says the same words to an outside reader, against the
    # same marks.
    @test W.item_json(it, marks("2026-09-12T08:00:00Z"))["why"] == ["reviewed", "comment"]
    @test W.item_json(it, marks("2026-09-12T10:00:00Z"))["why"] == String[]
    @test !haskey(W.item_json(it, read), "moved_by")

    # The tags that only restate the pane are the word alone; the level is
    # the word and the command.
    tagged = W.with(it; edits = "changes requested", ready = "approved and green",
                    reply = "mentioned you 2d ago; last word is theirs")
    plain = W.astrip(join(W.meta_lines(st, tagged, 60, at), "\n"))
    @test occursin("\nedits\n", plain) && occursin("\nready\n", plain)
    @test !occursin("changes requested\n", plain) && !occursin("approved and green", plain)
    @test occursin("reply     mentioned you 2d ago; last word is theirs", plain)
    @test occursin("why       read\n", plain)
    @test endswith(plain, "track     normal  wl track")
end

@testset "your own keystrokes are not news" begin
    # One rule for everything the timeline says: an event is news when
    # somebody else was the actor, and - for the ones that name somebody -
    # when the somebody named is you.
    me = "vtjnash"
    ev(kind, at, actor; who = nothing, field = :requestedReviewer) =
        Dict{Symbol,Any}(:__typename => kind, :createdAt => at,
                         :actor => Dict{Symbol,Any}(:login => actor),
                         field => who === nothing ? nothing : Dict{Symbol,Any}(:login => who))
    req = ("ReviewRequestedEvent",)
    evs = [ev("ReviewRequestedEvent", "2026-09-01T10:00:00Z", "them"; who = me),
           ev("ReviewRequestedEvent", "2026-09-01T10:00:01Z", "them"; who = "other"),
           ev("ReviewRequestedEvent", "2026-09-01T10:00:02Z", me; who = me),
           ev("ReviewRequestRemovedEvent", "2026-09-02T10:00:00Z", "them"; who = me),
           ev("ReviewDismissedEvent", "2026-09-03T10:00:00Z", "them"),
           ev("MergedEvent", "2026-09-04T10:00:00Z", me),
           ev("ClosedEvent", "2026-09-04T10:00:00Z", me)]
    # Their request of you counts; their request of somebody else does not, one
    # you somehow made yourself is your own keystroke, and being let off is not
    # asked about - a kind this is not asked for is not a kind it sees.
    @test W.event_at(evs, me, req, :requestedReviewer) == "2026-09-01T10:00:00Z"
    # A dismissal names nobody, so only the actor is asked about.
    @test W.event_at(evs, me, ("ReviewDismissedEvent",), nothing) == "2026-09-03T10:00:00Z"
    @test W.event_at(evs, me, ("AssignedEvent",), :assignee) === nothing
    # You pressing merge on your own pull request is not somebody finishing it.
    @test W.event_at(evs, me, ("ClosedEvent", "MergedEvent", "ReopenedEvent"), nothing) === nothing
    @test W.event_at([ev("MergedEvent", "2026-09-05T10:00:00Z", "them")], me,
                     ("ClosedEvent", "MergedEvent", "ReopenedEvent"), nothing) == "2026-09-05T10:00:00Z"
    # A deleted account names nobody either - julia#62245 has one - and a row
    # with no timeline at all is a bulk row.
    @test W.event_at([ev("ReviewRequestedEvent", "2026-09-04T10:00:00Z", "them")], me,
                     req, :requestedReviewer) === nothing
    @test W.event_at(nothing, me, req, :requestedReviewer) === nothing

    # A comment the same way, carried across your own because
    # `comments(last: 1)` cannot see past it - and for the `loose` key, across
    # a bot's, which used to take the key to nothing and wake the item for
    # exactly the comment that level exists to ignore.
    r(at, by) = Dict{String,Any}("last_comment_at" => at, "last_comment_by" => by)
    old = (their_comment_at = "2026-09-01T00:00:00Z", human_comment_at = "2026-09-01T00:00:00Z")
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", "them"), old, me, "their_comment_at"; human = false) ==
          "2026-09-02T00:00:00Z"
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", me), old, me, "their_comment_at"; human = false) ==
          "2026-09-01T00:00:00Z"
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", "nanosoldier[bot]"), old, me, "their_comment_at"; human = false) ==
          "2026-09-02T00:00:00Z"
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", "nanosoldier[bot]"), old, me, "human_comment_at"; human = true) ==
          "2026-09-01T00:00:00Z"
    # Nothing to carry and nothing to see is nothing; every comment deleted
    # keeps what there was rather than going backwards.
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", me), nothing, me, "their_comment_at"; human = false) === nothing
    @test W.their_comment_at(r(nothing, nothing), old, me, "human_comment_at"; human = true) ==
          "2026-09-01T00:00:00Z"
end

@testset "a push of your own is not news" begin
    # The sha is the exact answer to whether the branch moved; who put it there
    # decides whether that is worth being told. Your own push is the dashboard
    # reporting your own keystrokes back to you.
    me = "vtjnash"
    r(sha, by) = Dict{String,Any}("head_sha" => sha, "head_by" => by)
    @test W.their_head(r("aaa", "someone"), nothing, me) == "aaa"
    # Yours carries the previous value forward rather than clearing it, because
    # clearing would be a change like any other and the item would go unread for
    # the thing this exists to ignore.
    @test W.their_head(r("bbb", me), (their_head = "aaa",), me) == "aaa"
    # They push after you and it moves; you push after them and it does not
    # move back.
    @test W.their_head(r("ccc", "someone"), (their_head = "aaa",), me) == "ccc"
    @test W.their_head(r("ddd", me), (their_head = "ccc",), me) == "ccc"
    # A pull request only ever pushed to by you has nothing here at all, and
    # neither has an issue or a row no lane fetched commits for.
    @test W.their_head(r("bbb", me), nothing, me) === nothing
    @test W.their_head(Dict{String,Any}(), nothing, me) === nothing
end

@testset "an adopted branch hands its words to the pull request opened from it" begin
    keepm = W.LOCAL[]
    W.LOCAL[] = joinpath(mktempdir(), "local.toml"); write(W.LOCAL[], "")
    try
        lu = W.localurl("o/r", "jn/fix")
        pu = "https://github.com/o/r/pull/7"
        W.set_fields(lu, ["adopted" => "2026-09-10", "note" => "half done",
                          "deadline" => "2026-09-20", "track" => "loose",
                          "blocked_on" => ["o/r#3"]], W.DateTime(2026, 9, 11, 9))
        W.set_read(lu, "2026-09-11T09:00:00Z")
        # The pull request already has a note of its own, which stays.
        W.set_fields(pu, ["note" => "on the PR"], W.DateTime(2026, 9, 12, 9))
        # A second adopted branch with no pull request, and a stranger's pull
        # request from a branch of the same name as a third.
        ou = W.localurl("o/r", "other"); W.set_fields(ou, ["adopted" => "2026-09-10"])
        tu = W.localurl("o/r", "master"); W.set_fields(tu, ["adopted" => "2026-09-10"])
        pr(u, n, who, br) = Dict{String,Any}("url" => u, "type" => "PullRequest", "number" => n,
                                             "repo" => "o/r", "author" => who, "branch" => br)
        items = W.OrderedDict{String,Any}(
            pu => pr(pu, 7, "me", "jn/fix"),
            "https://github.com/o/r/pull/8" => pr("https://github.com/o/r/pull/8", 8, "them", "master"),
            "https://github.com/o/r/issues/9" => Dict{String,Any}("url" => "x", "type" => "Issue",
                                                                  "repo" => "o/r", "author" => "me"))
        state = W.load_state()
        @test W.adopt_pull_requests!(items, state, "me") == ["r#7"]
        # Moved, not copied: the branch keeps only what was not about the work
        # - its read mark - and is no longer adopted, so it is no longer a row.
        @test W.get_field(lu, "adopted") === nothing && W.get_field(lu, "note") === nothing
        @test W.get_field(lu, "deadline") === nothing && W.get_field(lu, "track") === nothing
        @test W.read_at(lu) == "2026-09-11T09:00:00Z"
        @test !(lu in W.adopted_urls())
        # What the pull request lacked it has; what it had it keeps.
        @test W.get_field(pu, "note") == "on the PR"
        @test W.get_field(pu, "deadline") == "2026-09-20" && W.get_field(pu, "track") == "loose"
        @test W.get_field(pu, "blocked_on") == "[\"o/r#3\"]"
        # The interaction clock is the later of the two, not this run's.
        @test W.touched_at(pu) == "2026-09-12T09:00:00Z"
        # And `state` in hand says the same, for the rows derived after it.
        @test state[pu]["track"] == "loose" && state[pu]["note"] == "on the PR"
        @test !haskey(state[lu], "adopted")
        # The other two are untouched: no pull request, and not your pull request.
        @test W.get_field(ou, "adopted") == "2026-09-10"
        @test W.get_field(tu, "adopted") == "2026-09-10"
        # Nothing to do is no write.
        before = read(W.LOCAL[], String)
        @test W.adopt_pull_requests!(items, W.load_state(), "me") == String[]
        @test read(W.LOCAL[], String) == before
    finally
        W.LOCAL[] = keepm
    end
end
