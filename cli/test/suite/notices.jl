# Notices: a notification that is not an issue or pull request is a block in
# `local.toml`, unread while it stands and gone once dismissed.

"A raw notification thread, as `/notifications` returns one."
notice_thread(type, url; id = "11", at = "2026-09-20T10:00:00Z", reason = "subscribed",
              title = "v1.12.0", comment = nothing, repo = "o/r") = Dict{String,Any}(
    "id" => id, "reason" => reason, "updated_at" => at, "unread" => true,
    "repository" => Dict{String,Any}("full_name" => repo),
    "subject" => Dict{String,Any}("title" => title, "url" => url,
                                  "latest_comment_url" => comment, "type" => type))

@testset "a notice is the thread's own facts, and a link to where it is read" begin
    E = W.Events
    api = "https://api.github.com/repos/o/r"
    web(type, url; kw...) = E.notice_row(notice_thread(type, url; kw...)).fields[end][2]
    @test web("Release", "$api/releases/5") == "https://github.com/o/r/releases"
    @test web("Commit", "$api/commits/abc123"; comment = "$api/comments/77") ==
          "https://github.com/o/r/commit/abc123#commitcomment-77"
    @test web("Commit", "$api/commits/abc123") == "https://github.com/o/r/commit/abc123"
    @test web("CheckSuite", nothing) == "https://github.com/o/r/actions"
    @test web("WorkflowRun", nothing) == "https://github.com/o/r/actions"
    @test web("RepositoryVulnerabilityAlert", nothing) == "https://github.com/o/r/security/dependabot"
    @test web("RepositoryDependabotAlertsThread", nothing) == "https://github.com/o/r/security/dependabot"
    @test web("RepositoryInvitation", nothing) == "https://github.com/o/r/invitations"
    @test web("Discussion", "$api/discussions/62980") == "https://github.com/o/r/discussions/62980"
    @test web("Discussion", nothing) == "https://github.com/o/r/discussions"
    @test web("RepositoryAdvisory", nothing) == "https://github.com/o/r/security/advisories"
    @test web("SomethingNew", nothing) == "https://github.com/o/r"
    # The repository off the subject's url, where the thread does not name it.
    t = notice_thread("Release", "$api/releases/5")
    delete!(t, "repository")
    n = E.notice_row(t)
    @test n.key == "notice:11" && n.id == "11" && n.at == "2026-09-20T10:00:00Z"
    @test Dict(n.fields)["repo"] == "o/r" && Dict(n.fields)["type"] == "Release"
    @test Dict(n.fields)["reason"] == "subscribed" && Dict(n.fields)["title"] == "v1.12.0"
    # An issue or a pull request is `thread_row`'s, and not a notice.
    @test E.notice_row(notice_thread("Issue", "$api/issues/9")) === nothing
    @test E.notice_row(notice_thread("PullRequest", "$api/pulls/9")) === nothing

    # The item. Its words are the type's; its time is the thread's throughout.
    it = W.notice_item("notice:11", Dict("type" => "CheckSuite", "repo" => "o/r",
        "title" => "CI failed", "reason" => "ci_activity", "at" => "2026-09-20T10:00:00Z",
        "web" => "https://github.com/o/r/actions"))
    @test it.ref == "r CI" && W.isnotice(it) && !W.ghitem(it) && !it.is_pr
    @test it.lane == "notifications" && it.moved_at == it.updated == it.act == "2026-09-20T10:00:00Z"
    @test W.weblink(it) == "https://github.com/o/r/actions"
    @test W.fetch_bundle(it) === nothing                 # nothing to ask GitHub
    @test W.kind_of(it) === :notice && W.over_of(it) === :closed
    @test W.kind_ok(:notice, it) && !W.kind_ok(:issue, it) && !W.kind_ok(:pr, it)
    @test W.kind_ok(:both, it)
    @test W.seen_of(it, W.Marks()) === :unread
    # The pane is its own facts, with the link on it; no fetch.
    ns = W.comment_nodes(it, W.DateTime(2026, 9, 21))
    @test length(ns) == 1 && ns[1].meta["url"] == "https://github.com/o/r/actions"
    @test startswith(ns[1].header, "CI  2026-09-20 10:00  CI failed")
    @test ns[1].meta["at"] == "2026-09-20T10:00:00Z"
    @test !occursin('\e', ns[1].raw)                    # no escapes for markdown to read
    @test occursin("check suite in o/r", ns[1].raw)
    # A type nobody has named here is words, not one run-together one.
    @test W.notice_word("RepositoryAdvisory") == "advisory"
    @test W.notice_word("SecurityAdvisoryThread") == "security advisory thread"
    @test occursin("notice", W.diff_nodes(it)[1].header)          # `d` says what it is
    m = W.Events.mention_words(Dict{String,Any}("reason" => "mention", "notified" => "2026-09-20T10:00:00Z"))
    @test !isempty(m)
    @test W.notice_item("notice:12", Dict("reason" => "mention", "at" => "2026-09-20T10:00:00Z")).mentioned == m
end

@testset "the poll makes notices, and a dismissed one stays gone until it notifies again" begin
    E = W.Events
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml")
    write(W.LOCAL[], "")
    try
        api = "https://api.github.com/repos/o/r"
        threads = Ref(Any[])
        srcs = [(label = "notifications", fetch = since -> threads[],
                 overlap = E.OVERLAP_REST, row = (t, _) -> E.thread_row(t, "me"; fetch = nothing))]
        now_ = Ref(W.DateTime(2026, 9, 20, 12))
        poll(at) = (now_[] = at;
                    W.reporting(() -> E.sync!(srcs, at; now = () -> now_[],
                                              watched = () -> Set{String}()), devnull))
        rel = notice_thread("Release", "$api/releases/5"; id = "11", at = "2026-09-20T12:10:00Z")
        ci = notice_thread("CheckSuite", nothing; id = "12", at = "2026-09-20T12:11:00Z",
                           title = "CI failed", reason = "ci_activity")
        iss = notice_thread("Issue", "$api/issues/9"; id = "13", at = "2026-09-20T12:12:00Z",
                            reason = "mention")
        threads[] = Any[rel, ci, iss]
        said = IOBuffer()
        W.reporting(() -> E.sync!(srcs, W.DateTime(2026, 9, 20, 12); now = () -> now_[],
                                  watched = () -> Set{String}()), said)
        out = String(take!(said))
        @test occursin("2 notices", out) && !occursin("skipped", out)
        bs = W.notice_blocks()
        @test Set(keys(bs)) == Set(["notice:11", "notice:12"])
        @test bs["notice:11"]["type"] == "Release" && bs["notice:11"]["at"] == "2026-09-20T12:10:00Z"
        @test bs["notice:12"]["web"] == "https://github.com/o/r/actions"
        # Neither is an inbox row: nothing that reads those asks GitHub about one.
        @test collect(keys(E.load_inbox()["items"])) == ["https://github.com/o/r/issues/9"]
        @test E.load_inbox()["noticed"] == Dict("11" => "2026-09-20T12:10:00Z",
                                                "12" => "2026-09-20T12:11:00Z")
        # On the lists: `wl unread` and `wl done all`'s, and the browser's.
        at = W.DateTime(2026, 9, 20, 13)
        un = W.unread_items(at, values(E.load_inbox()["items"]))
        @test count(W.isnotice, un) == 2

        # Dismissed, and read again inside the overlap: it stays gone.
        @test length(W.dismiss_notices!(["notice:11"])) == 1
        poll(W.DateTime(2026, 9, 20, 12, 5))
        @test !haskey(W.notice_blocks(), "notice:11") && haskey(W.notice_blocks(), "notice:12")
        # A re-notify while the block stands updates it in place.
        threads[] = Any[notice_thread("CheckSuite", nothing; id = "12", at = "2026-09-20T12:20:00Z",
                                      title = "CI passed", reason = "ci_activity")]
        before = read(W.LOCAL[], String)
        poll(W.DateTime(2026, 9, 20, 12, 10))
        bs = W.notice_blocks()
        @test bs["notice:12"]["title"] == "CI passed" && bs["notice:12"]["at"] == "2026-09-20T12:20:00Z"
        @test count("[\"notice:12\"]", read(W.LOCAL[], String)) == 1
        # And the dismissed one, notifying again, is back.
        threads[] = Any[notice_thread("Release", "$api/releases/6"; id = "11",
                                      at = "2026-09-20T12:30:00Z", title = "v1.12.1")]
        poll(W.DateTime(2026, 9, 20, 12, 15))
        @test W.notice_blocks()["notice:11"]["title"] == "v1.12.1"
        # `noticed` is pruned once under the widest ask, a day behind the cursor.
        threads[] = Any[]
        poll(W.DateTime(2026, 9, 22, 12))
        @test isempty(E.load_inbox()["noticed"])
        # A source that is not the notifications makes no notice of a row it
        # cannot read: it is skipped, as before.
        other = [(label = "o/r", fetch = since -> Any[rel], overlap = E.OVERLAP_REST,
                  row = (r, _) -> nothing)]
        said = IOBuffer()
        W.reporting(() -> E.sync!(other, W.DateTime(2026, 9, 22, 13); now = () -> W.DateTime(2026, 9, 22, 13),
                                  watched = () -> Set{String}()), said)
        @test occursin("skipped", String(take!(said)))

        # `wl done <key>` dismisses, and `wl done all` dismisses the rest.
        @test redirect_stdout(() -> W.dispatch(["done", "notice:12"], at), devnull) == 0
        @test !haskey(W.notice_blocks(), "notice:12")
        @test_throws W.CliError W.dispatch(["snooze", "notice:11", "3d"], at)
        @test_throws W.CliError W.dispatch(["archive", "notice:11"], at)
        @test_throws W.CliError W.dispatch(["unread", "notice:11"], at)
        @test haskey(W.notice_blocks(), "notice:11")
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
    end
end

@testset "a notice is in the firehose, dismissed by e and x, and not snoozed" begin
    keept = W.LOCAL[]; W.LOCAL[] = fresh_local()
    try
        W.set_blocks!(["notice:21" => Pair{String,Any}[
            "type" => "Release", "repo" => "o/r", "title" => "v2 \"final\"",
            "reason" => "subscribed", "at" => "2026-09-25T10:00:00Z",
            "web" => "https://github.com/o/r/releases"]])
        nt = only(W.notice_items())
        @test nt.title == "v2 \"final\""                 # parsed, not scanned
        st = W.BState(vcat(items, [nt]), "worklog")
        ctrl = W.Controller(); ctrl.running = true
        # The firehose has it; my work and the backlog do not.
        views = Dict(W.VIEWS)
        inview(name) = (W.apply_view!(st, views[name]); any(W.isnotice, st.items))
        @test inview("notification firehose — unread, open or closed")
        @test !inview("my work — mine, open, done ones too")
        @test !inview("open items — the backlog, done ones too")
        @test occursin("notices", W.apply_view!(st, Dict("kind" => "notice")))
        @test all(W.isnotice, st.items) && length(st.items) == 1
        @test occursin("no kind", W.apply_view!(st, Dict("kind" => "banana")))
        W.apply_view!(st, Dict{String,Any}())
        st.sel = findfirst(W.isnotice, st.items)
        # The pane says what it is; no request is made for one.
        lines = W.astrip(join(W.meta_lines(st, nt, 60), "\n"))
        @test occursin("release", lines) && occursin("subscribed", lines)
        @test !occursin("track", lines)
        # `s` is refused, and the block stands.
        W.handle!(st, Int('s'), ctrl)
        @test occursin("no snooze", st.status)
        @test haskey(W.notice_blocks(), "notice:21")
        W.handle!(st, Int('C'), ctrl)
        @test occursin("nothing to C", st.status)
        # `e` dismisses it: the block goes, and so does the row.
        W.handle!(st, Int('e'), ctrl)
        @test st.status == "dismissed r release"
        @test !haskey(W.notice_blocks(), "notice:21")
        @test !any(W.isnotice, st.all)
        @test W.touched_at("notice:21") === nothing
        # `z` writes it back, row and all; `Z` takes it again.
        @test W.undo!(st) == "undid: dismiss r release"
        @test W.notice_blocks()["notice:21"]["title"] == "v2 \"final\""
        @test any(W.isnotice, st.items)
        @test W.redo!(st) == "redid: dismiss r release"
        @test !haskey(W.notice_blocks(), "notice:21") && !any(W.isnotice, st.all)
        W.undo!(st)
        # `x` is a dismissal too: there is no filed box for it to be in.
        st.sel = findfirst(W.isnotice, st.items)
        W.handle!(st, Int('x'), ctrl)
        @test st.status == "dismissed r release" && !haskey(W.notice_blocks(), "notice:21")
        @test W.get_field("notice:21", "archived") === nothing
        W.undo!(st)
        # Dismissed from another shell: the next refilter drops the row.
        W.dismiss_notices!(["notice:21"])
        W.refilter!(st)
        @test !any(W.isnotice, st.all)
    finally
        W.LOCAL[] = keept
    end
end

@testset "a notice holds no floor down" begin
    keept = W.LOCAL[]; W.LOCAL[] = fresh_local()
    try
        at = W.DateTime(2026, 9, 26)
        corpus = W.corpus_items(Any[])
        # The oldest movement in the corpus, stamped read: the one point every
        # floor can rise to while nothing stampless is older.
        first_ = argmin(it -> something(W.moved_of(it), "~"), corpus)
        mv = W.moved_of(first_)
        W.set_done(first_.url, mv)
        c1 = W.consolidate!(at; dry_run = true, rows = Any[])
        @test c1.since == mv
        # A notice older than all of it, unread and stampless, changes nothing.
        W.set_blocks!(["notice:31" => Pair{String,Any}["type" => "Release", "repo" => "o/r",
                                                       "at" => "2000-01-01T00:00:00Z"]])
        c2 = W.consolidate!(at; dry_run = true, rows = Any[])
        @test c1 == c2
        @test W.seen_of(only(W.notice_items()), W.unread_marks(at)) === :unread
    finally
        W.LOCAL[] = keept
    end
end
