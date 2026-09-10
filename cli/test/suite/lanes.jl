# The lanes that decide what is on the dashboard at all.

@testset "two more lanes, and an order of their own" begin
    keept = W.MARKS[]
    W.MARKS[] = joinpath(mktempdir(), "marks.json")
    try
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true
        st.filters = W.Filters(); W.refilter!(st)
        n = length(st.items)

        # Everything you have actually done something to. Nothing but an action
        # writes to the clock, so this is work rather than browsing.
        # Chosen by what GitHub last said about them rather than by position:
        # `b`'s clock has to be the later of the two readings for the pair of
        # them to differ, and `a`'s the earlier.
        a = first(x for x in st.all if !isempty(x.act) && x.act > "2026-01")
        b = first(x for x in st.all if !isempty(x.act) && x.act < "2026-09-02" &&
                                       x.url != a.url)
        c = first(x for x in st.all if !isempty(x.act) && x.act < "2024-06-01" &&
                                       !(x.url in (a.url, b.url)))
        W.set_touched(a.url, "2020-01-01T00:00:00Z")
        W.set_touched(b.url, "2026-09-02T12:00:00Z")
        W.set_touched(c.url, "2024-06-01T00:00:00Z")
        st.filters = W.Filters(tags = Set([:touched])); W.refilter!(st)
        @test length(st.items) == 3
        @test Set(x.url for x in st.items) == Set([a.url, b.url, c.url])
        # Looking at one does not put it in the lane.
        W.handle!(st, Int('j'), ctrl); W.handle!(st, Int('\t'), ctrl)
        W.refilter!(st)
        @test length(st.items) == 3

        # Yours is the *author* axis and not a lane of its own. `mine` was one,
        # and it said `author == login()` in the state axis - the author axis
        # written twice, in the place it does not belong. Which work is yours
        # and what state that work is in are two questions.
        #
        # Author **or assignee**: an issue GitHub put on you is yours to do
        # however it reached the dashboard, and a mention or a review request
        # is not - that makes it unread, which is a different question again.
        mine = Set([W.AUTHOR_ME])
        st.filters = W.Filters(); st.filters.authors = copy(mine)
        W.refilter!(st)
        @test !isempty(st.items)
        @test all(x.author == W.login() || W.login() in x.assignees || W.islocal(x)
                  for x in st.items)
        @test any(x.author != W.login() && W.login() in x.assignees for x in st.items)
        # An adopted branch has no author at all and is still yours, which is a
        # thing the axis knows and the lane had to special-case.
        local_it = W.Item(url = "local:a/b#x", ref = "b#x", repo = "a/b", number = 0,
                          title = "t", is_pr = false, branch = "x", bucket = "local")
        W.add_item!(st, local_it)
        st.filters = W.Filters(); st.filters.authors = copy(mine)
        W.refilter!(st)
        @test any(x.url == local_it.url for x in st.items)
        # A pull request that is somebody else's is not.
        theirs = first(x for x in st.all if x.is_pr && x.author != W.login() &&
                       !(W.login() in x.assignees) && !x.snoozed)
        @test !any(x.url == theirs.url for x in st.items)
        # ...and it is in the other mode, which is the same axis said the other
        # way round. Between them they are the two lists the work divides into.
        st.filters = W.Filters(); st.filters.authors = Set([W.AUTHOR_OTHERS])
        W.refilter!(st)
        @test any(x.url == theirs.url for x in st.items)
        @test !any(x.url == local_it.url for x in st.items)
        W.drop_item!(st, local_it.url)
        st.filters = W.Filters(); W.refilter!(st)

        # All three modes are a view, so each is one keystroke from `\'`.
        vs = W.views()
        @test any(v -> occursin("my work", v[1]), vs)
        @test any(v -> occursin("what moved", v[1]), vs)
        @test any(v -> occursin("open items", v[1]), vs)

        # The order is its own control: any of it makes sense over any of the
        # lanes, so it sits beside the filter rather than inside it.
        st.filters = W.Filters()
        st.sort = :none; W.refilter!(st)
        # The url order, descending: owner, project, number. It keeps the
        # grouping `facts.json` is written in and reads from the newest of each
        # repo rather than from two thousand rows ago.
        @test issorted([W.urlkey(x) for x in st.items]; rev = true)
        @test length(st.items) == n
        # And the number is a number. Sorted as the text it is written in,
        # `#6661` lands above `#62836` - it compares a character at a time -
        # which is the one thing this order used to get wrong.
        mk(n) = W.Item(url = "https://github.com/JuliaLang/julia/pull/$n",
                       ref = "julia#$n", repo = "JuliaLang/julia", number = n,
                       title = "t")
        @test W.urlkey(mk(6661)) < W.urlkey(mk(62836))
        # Owner first, then project: one owner's repos stay together, and one
        # repo's items do.
        @test W.urlkey(mk(1)) > W.urlkey(W.Item(url = "u", ref = "a#9", repo = "JuliaIO/a",
                                                number = 9, title = "t"))
        # An adopted branch has no number and does not tie with another one.
        b1 = W.Item(url = "local:o/r#one", ref = "r#one", repo = "o/r", number = 0, title = "t")
        b2 = W.Item(url = "local:o/r#two", ref = "r#two", repo = "o/r", number = 0, title = "t")
        @test W.urlkey(b1) != W.urlkey(b2)
        @test length(st.items) == n
        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :touched && occursin("by when", st.status)
        keys = [W.sortkey(x, st.touched) for x in st.items]
        @test issorted(keys; rev = true)
        @test length(st.items) == n                    # an order, not a filter
        # Touched and untouched interleave by their timestamps: a branch
        # committed to this morning belongs above a pull request touched in
        # March, and two blocks would bury it.
        pos(u) = findfirst(x -> x.url == u, st.items)
        @test pos(b.url) < pos(c.url) < pos(a.url)
        @test W.sortkey(b, st.touched) == "2026-09-02T12:00:00Z"     # the clock
        untouched = first(x for x in st.all if !haskey(st.touched, x.url) &&
                                               !isempty(x.act))
        @test W.sortkey(untouched, st.touched) == untouched.act      # the fallback
        # And it says so where the filter says what it is.
        @test occursin("by when you acted", W.filter_summary(st.filters, st.sort))
        @test occursin("w sort", W.astrip(W.render(st, 200, 40)))

        # The other reading of "when": the later of the two, which is what
        # anything happening to an item sorts by. They differ exactly where
        # both exist - `a` was acted on in 2020 and has moved since, so the
        # first reading leaves it at the bottom and the second does not.
        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :latest && occursin("anything last happened", st.status)
        # ...which is the order this lane opens in, so the summary stops naming
        # it: the default said on every screen is a phrase the reader stops
        # seeing. It is named wherever it is not the lane's own.
        @test !occursin("by when", W.filter_summary(st.filters, st.sort))
        let f = W.Filters(tags = Set([:touched]))
            @test occursin("by when it moved", W.filter_summary(f, :latest))
        end
        @test length(st.items) == n
        keys2 = [W.sortkey(x, st.touched, :latest) for x in st.items]
        @test issorted(keys2; rev = true)
        @test W.sortkey(a, st.touched, :latest) == max(a.act, "2020-01-01T00:00:00Z")
        @test W.sortkey(a, st.touched, :latest) != W.sortkey(a, st.touched)
        # Your own work still counts under it: the clock on `b` is later than
        # anything GitHub said about it, and it is what `b` sorts by.
        @test W.sortkey(b, st.touched, :latest) == "2026-09-02T12:00:00Z"
        pos2(u) = findfirst(x -> x.url == u, st.items)
        @test pos2(a.url) < pos2(c.url)          # where precedence had it last

        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :none
        @test !occursin("by when", W.filter_summary(st.filters, st.sort))

        # Both are tags in the filter pane, with their counts.
        st.lmode = :filters
        rows = W.filter_rows(st)
        txt = W.astrip(join([string(r[3]) for r in rows], "\n"))
        @test occursin("touched", txt) && occursin("second look", txt)
        @test W.axis_counts(st).tags[:touched] == 3

        for (w, h) in ((80, 24), (200, 50))
            ls = split(W.render(st, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
    finally
        W.MARKS[] = keept
    end
end

@testset "all activity on a whole owner" begin
    # An entry is a repo, polled exactly, or `owner/*`, swept with a search.
    # `vtjnash/*` is two hundred repos, and two hundred requests on every launch
    # is not a thing to do for a handful of comments.
    E = W.Events
    ex, ow, bad = E.event_sources(["JuliaLang/julia", "vtjnash/*", "libuv/*",
                                   "libuv/libuv"])
    @test ex == ["JuliaLang/julia", "libuv/libuv"]
    @test ow == ["vtjnash", "libuv"]
    @test isempty(bad)
    # Only `owner/*` is a pattern; anything else is reported rather than guessed.
    _, _, bad2 = E.event_sources(["a/b*", "*/c", "ok/*"])
    @test Set(bad2) == Set(["a/b*", "*/c"])
    # One owner named twice is one sweep.
    @test E.event_sources(["x/*", "x/*"])[2] == ["x"]

    # A search result names its repo only by the API url it came from, and a
    # glob covers many repos - so the repo has to come off the item.
    @test E.item_repo(Dict("repository_url" => "https://api.github.com/repos/a/b")) == "a/b"
    @test E.item_repo(Dict{String,Any}()) == ""

    # Forks are kept unless the config says otherwise, because keeping them is
    # the free direction: the sweep is one REST search either way and spends no
    # GraphQL points, while skipping them costs a repo listing per owner a day.
    @test E.keep_forks(Dict{String,Any}())
    @test E.keep_forks(Dict{String,Any}("include_forks" => true))
    @test !E.keep_forks(Dict{String,Any}("include_forks" => false))

    # And when it is asked for, a glob is where a fork arrives and so a glob is
    # where one is dropped: 171 of the repos under `vtjnash/*` are forks.
    row(r) = Dict{String,Any}("repository_url" => "https://api.github.com/repos/$r")
    rows = [row("o/mine"), row("o/theirs"), row("o/also")]
    @test length(E.drop_forks(rows, Set(["o/theirs"]))) == 2
    @test E.item_repo(E.drop_forks(rows, Set(["o/theirs"]))[2]) == "o/also"
    # Nothing known to be a fork is nothing dropped, and the rows come back as
    # they were rather than as a copy.
    @test E.drop_forks(rows, Set{String}()) === rows

    # The listing is one request a day, and unknown is not a fork: a repo the
    # listing does not mention keeps its items, because this only hides things.
    keepdir = W.CACHE_DIR[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    try
        W.cache_put("forks:o", ["o/theirs"])
        @test E.owner_forks("o") == Set(["o/theirs"])       # read, not fetched
        @test !("o/mine" in E.owner_forks("o"))
    finally
        W.CACHE_DIR[] = keepdir
    end

    # The inbox is incremental: a cursor per source, and what has been seen and
    # not yet read. A source seen for the first time starts at now, so turning
    # one on is inbox zero rather than a month of history to dismiss.
    keep = W.FETCHED[]
    W.FETCHED[] = joinpath(mktempdir(), "fetched.json")
    try
        d = E.load_inbox()
        @test isempty(d["cursors"]) && isempty(d["items"]) && isempty(d["polled"])
        d["cursors"]["r"] = "2026-09-02T13:00:10Z"
        d["polled"]["r"] = "2026-09-02T13:00:10Z"
        d["items"]["u"] = Dict{String,Any}("url" => "u", "updated" => "2026-09-02T12:00:00Z")
        E.save_inbox(d)
        back = E.load_inbox()
        @test back["cursors"]["r"] == "2026-09-02T13:00:10Z"
        @test back["items"]["u"]["updated"] == "2026-09-02T12:00:00Z"
        # A damaged inbox is an empty one: the cursors reset to now, which loses
        # one poll of history rather than every poll after it.
        write(W.FETCHED[], "{not json")
        empty = E.load_inbox()
        @test isempty(empty["cursors"]) && isempty(empty["items"])
    finally
        W.FETCHED[] = keep
    end
end

@testset "work that has already landed is still seen" begin
    # Every open lane is `is:open`, so a pull request that merges between two
    # refreshes stops being returned and the merge goes unnoticed. The closed
    # lanes are what catch it, bounded by a date that has to move with the run.
    at = W.DateTime(2026, 9, 2)
    @test W.expand_lane("is:pr is:closed closed:>{since:21}", at) ==
          "is:pr is:closed closed:>2026-08-12"
    @test W.expand_lane("a {since} b", at) == "a 2026-08-19 b"     # 14 by default
    @test W.expand_lane("nothing to fill", at) == "nothing to fill"
    @test W.expand_lane("{since:1}", at) == "2026-09-01"
    # It moves with the run, which is the whole reason it is not written into
    # config.toml as a literal date.
    @test W.expand_lane("{since:1}", at + Dates.Day(5)) == "2026-09-06"

    # Over, whichever lane found it: none of the rules about what to do next
    # apply to a merged pull request.
    cfg = W.config()
    base = Dict{String,Any}("lane" => "mine", "type" => "PullRequest", "mine" => true,
                            "labels" => String[], "head_at" => W.stamp(at - Dates.Day(2)),
                            "updated" => W.stamp(at - Dates.Day(2)))
    for (state, word) in (("MERGED", "merged"), ("CLOSED", "closed"))
        r = merge(base, Dict("state" => state))
        b, why = W.derive_bucket(r, Dict{String,Any}(), cfg, at)
        @test b == "done" && occursin(word, why) && occursin("2d ago", why)
    end
    # An open one is bucketed by the rules as before, and an unknown state is
    # not treated as closed.
    @test W.derive_bucket(merge(base, Dict("state" => "OPEN")), Dict{String,Any}(),
                          cfg, at)[1] != "done"
    @test W.derive_bucket(base, Dict{String,Any}(), cfg, at)[1] != "done"
    # An explicit bucket still wins, and nothing about finished work should wake
    # you, so it tracks loosely.
    @test W.derive_bucket(merge(base, Dict("state" => "MERGED")),
                          Dict{String,Any}("bucket" => "needs-review"), cfg, at)[1] ==
          "needs-review"
    @test W.resolve_track(Dict{String,Any}(), "done") == "loose"
    # And it is a value on the bucket axis, which is where finished work is read
    # now that nothing renders a page of sections.
    @test "done" in mkstate().buckets

    # First sighting is news even where the event poller does not reach: the
    # unread lane only covers `[events].repos`, and a merge in any other repo
    # would otherwise be offered for filing before it had been seen.
    st = mkstate()
    done = W.Item(url = "https://example.invalid/x/y/pull/1", ref = "y#1", repo = "x/y",
                  number = 1, title = "t", state = "MERGED", new = true)
    says(it) = W.astrip(join([l for l in W.meta_lines(st, it, 52)
                              if occursin("state", l)], " "))
    @test occursin("new since you last looked", says(done))
    seen = W.Item(; (f => getfield(done, f) for f in fieldnames(W.Item))..., new = false)
    @test occursin("x archives it", says(seen))
    push!(st.unread, seen.url)
    @test occursin("new since you last looked", says(seen))
end
