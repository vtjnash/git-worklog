# The lanes that decide what is on the dashboard at all.

@testset "two more lanes, and an order of their own" begin
    keept = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true
        # Everything, since this counts the corpus and then checks that an
        # order is not a filter: the list the browser opens on leaves out the
        # read, the snoozed, the filed and the closed by construction.
        st.filters = W.everything(); W.refilter!(st)
        n = length(st.items)

        # Everything you have actually done something to. Nothing but an action
        # writes to the clock, so this is work rather than browsing.
        # Chosen by what GitHub last said about them rather than by position:
        # `b`'s clock has to be the later of the two readings for the pair of
        # them to differ, and `a`'s the earlier.
        a = fixture_item("yours, open, with a branch and labels")
        b = fixture_item("quiet since the spring")
        c = fixture_item("quiet since 2024")
        W.set_touched(a.url, "2020-01-01T00:00:00Z")
        W.set_touched(b.url, "2026-09-02T12:00:00Z")
        W.set_touched(c.url, "2024-06-01T00:00:00Z")
        st.filters = W.everything(); st.filters.tags = Set([:touched])
        W.refilter!(st)
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
        st.filters = W.everything(); st.filters.authors = copy(mine)
        W.refilter!(st)
        @test !isempty(st.items)
        @test all(x.author == W.login() || W.login() in x.assignees || W.islocal(x)
                  for x in st.items)
        @test any(x.author != W.login() && W.login() in x.assignees for x in st.items)
        # An adopted branch has no author at all and is still yours, which is a
        # thing the axis knows and the lane had to special-case.
        local_it = W.Item(url = "local:a/b#x", ref = "b#x", repo = "a/b", number = 0,
                          title = "t", is_pr = false, branch = "x", lane = "local")
        W.add_item!(st, local_it)
        st.filters = W.everything(); st.filters.authors = copy(mine)
        W.refilter!(st)
        @test any(x.url == local_it.url for x in st.items)
        # A pull request that is somebody else's is not.
        theirs = fixture_item("somebody else's, open, awake")
        @test !any(x.url == theirs.url for x in st.items)
        # ...and it is in the other mode, which is the same axis said the other
        # way round. Between them they are the two lists the work divides into.
        st.filters = W.everything(); st.filters.authors = Set([W.AUTHOR_OTHERS])
        W.refilter!(st)
        @test any(x.url == theirs.url for x in st.items)
        @test !any(x.url == local_it.url for x in st.items)
        W.drop_item!(st, local_it.url)
        st.filters = W.everything(); W.refilter!(st)

        # All three modes are a view, so each is one keystroke from `\'`.
        vs = W.views()
        @test any(v -> occursin("my work", v[1]), vs)
        # My work is the open work - read or not, and never the closed rows,
        # which the default `show` would have brought in beside the unread.
        mine = vs[findfirst(v -> occursin("my work", v[1]), vs)][2]
        @test sort(mine["show"]) == ["base", "read"]
        W.apply_view!(st, mine)
        @test st.filters.show == Set([:base, :read])
        @test st.filters.authors == Set([W.AUTHOR_ME])
        st.filters = W.everything(); W.refilter!(st)
        @test any(v -> occursin("notification firehose", v[1]), vs)
        @test any(v -> occursin("open items", v[1]), vs)

        # The order is its own control: any of it makes sense over any of the
        # lanes, so it sits beside the filter rather than inside it.
        st.filters = W.everything()
        st.sort = :name; W.refilter!(st)
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
        # The url order is not this selection's own, so the summary names it.
        @test occursin("by url", W.filter_summary(st.filters, st.sort))

        # GitHub's clock alone: when it moved, whoever moved it, which is the
        # firehose's order and the one this selection opens in - so the
        # summary stops naming it: the default said on every screen is a
        # phrase the reader stops seeing. It is named wherever it is not the
        # selection's own.
        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :moved && occursin("by when it moved", st.status)
        @test !occursin("by when", W.filter_summary(st.filters, st.sort))
        let f = W.Filters(tags = Set([:touched]))
            @test occursin("by when it moved", W.filter_summary(f, :moved))
        end
        @test length(st.items) == n                    # an order, not a filter
        keys0 = [W.sortkey(x, st.touched, :moved) for x in st.items]
        @test issorted(keys0; rev = true)
        # Nothing of yours counts under it: `b` was acted on this morning and
        # sorts by what GitHub last said about it all the same.
        @test W.sortkey(b, st.touched, :moved) == b.act
        @test W.sortkey(b, st.touched, :moved) != "2026-09-02T12:00:00Z"
        @test occursin("w sort", W.astrip(W.render(st, 200, 40)))

        # The later of the two clocks, which is what anything happening to an
        # item sorts by - your own work folded in - and the order your work
        # opens in. Not this selection's own, so the summary says so.
        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :latest && occursin("anything last happened", st.status)
        @test occursin("by when anything happened", W.filter_summary(st.filters, st.sort))
        @test length(st.items) == n
        keys2 = [W.sortkey(x, st.touched, :latest) for x in st.items]
        @test issorted(keys2; rev = true)
        @test W.sortkey(a, st.touched, :latest) == max(a.act, "2020-01-01T00:00:00Z")
        # Your own work counts under it: the clock on `b` is later than
        # anything GitHub said about it, and it is what `b` sorts by.
        @test W.sortkey(b, st.touched, :latest) == "2026-09-02T12:00:00Z"
        pos2(u) = findfirst(x -> x.url == u, st.items)
        @test pos2(a.url) < pos2(c.url)          # where precedence had it last

        # Your clock alone, with GitHub's standing in where it is empty. They
        # differ from the last exactly where both exist - `a` was acted on in
        # 2020 and has moved since, so this reading leaves it at the bottom
        # and the last did not.
        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :touched && occursin("by when you", st.status)
        keys = [W.sortkey(x, st.touched) for x in st.items]
        @test issorted(keys; rev = true)
        @test length(st.items) == n
        @test W.sortkey(a, st.touched, :latest) != W.sortkey(a, st.touched)
        # Touched and untouched interleave by their timestamps: a branch
        # committed to this morning belongs above a pull request touched in
        # March, and two blocks would bury it.
        pos(u) = findfirst(x -> x.url == u, st.items)
        @test pos(b.url) < pos(c.url) < pos(a.url)
        @test W.sortkey(b, st.touched) == "2026-09-02T12:00:00Z"     # the clock
        untouched = fixture_item("an issue")
        @test W.sortkey(untouched, st.touched) == untouched.act      # the fallback
        # And it says so where the filter says what it is.
        @test occursin("by when you acted", W.filter_summary(st.filters, st.sort))

        W.handle!(st, Int('w'), ctrl)
        @test st.sort === :name
        @test occursin("by url", W.filter_summary(st.filters, st.sort))

        # A tie on any clock falls through to the url order. An import stamps
        # every url it was given with the one `at` it ran under, so a batch of
        # them agree to the second under both orders that read the clock -
        # and under all three where nothing has a time at all.
        tied = [W.Item(url = "https://github.com/o/r/pull/$n", ref = "r#$n",
                       repo = "o/r", number = n, title = "t", act = "2026-09-01T00:00:00Z")
                for n in (3, 30, 4)]
        stamp = Dict(x.url => "2026-09-02T00:00:00Z" for x in tied)
        for order in (:moved, :latest, :touched)
            @test [x.number for x in W.sortitems(tied, order, stamp)] == [30, 4, 3]
            @test [x.number for x in W.sortitems(tied, order, Dict{String,String}())] == [30, 4, 3]
        end
        # And the clock still comes first where it says something.
        stamp[tied[1].url] = "2026-09-03T00:00:00Z"
        @test [x.number for x in W.sortitems(tied, :touched, stamp)] == [3, 30, 4]
        @test [x.number for x in W.sortitems(tied, :moved, stamp)] == [30, 4, 3]

        # Both are tags in the filter pane, with their counts.
        st.lmode = :filters
        rows = W.filter_rows(st)
        txt = W.astrip(join([string(r[3]) for r in rows], "\n"))
        @test occursin("touched", txt) && occursin("waiting on an answer", txt)
        @test W.axis_counts(st).tags[:touched] == 3

        for (w, h) in ((80, 24), (200, 50))
            ls = split(W.render(st, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
    finally
        W.LOCAL[] = keept
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

    # Over, whichever lane found it: none of the facts about what to do next
    # hold on a merged pull request, and it tracks loosely whoever's it is.
    cfg = W.config()
    base = Dict{String,Any}("lane" => "mine", "type" => "PullRequest", "mine" => true,
                            "labels" => String[], "head_at" => W.stamp(at - Dates.Day(2)),
                            "updated" => W.stamp(at - Dates.Day(2)),
                            "review_decision" => "APPROVED", "ci" => "SUCCESS")
    for state in ("MERGED", "CLOSED")
        r = merge(base, Dict("state" => state))
        W.apply_state!(r, Dict{String,Any}(), cfg, at)
        @test W.isover(r) && isempty(r["ready"]) && isempty(r["edits"]) &&
              r["track"] == "loose"
    end
    # An open one carries them, and an unknown state is not a closed one.
    for r in (merge(base, Dict("state" => "OPEN")), copy(base))
        W.apply_state!(r, Dict{String,Any}(), cfg, at)
        @test !W.isover(r) && r["ready"] == "approved and green" && r["track"] == "normal"
    end
    # The facts are not exclusive, which is the whole reason they are not a
    # bucket: a pull request can want edits and owe you a review at once.
    theirs = merge(base, Dict("state" => "OPEN", "mine" => false, "author" => "alice",
                              "review_decision" => "CHANGES_REQUESTED", "ci" => "FAILURE",
                              "review_requested_at" => W.stamp(at - Dates.Day(1))))
    W.apply_state!(theirs, Dict{String,Any}(), cfg, at)
    @test theirs["edits"] == "changes requested" && theirs["review"] == "review requested"
    @test isempty(theirs["ready"])
    # Reviewed after their last push: nothing owed. Pushed after your review:
    # owed again.
    theirs["my_last_review_at"] = W.stamp(at - Dates.Hour(1))
    @test isempty(W.review_owed(theirs))
    theirs["my_last_review_at"] = W.stamp(at - Dates.Day(3))
    @test W.review_owed(theirs) == "they pushed after your review"
    # Never on your own, and never unasked.
    @test isempty(W.review_owed(merge(theirs, Dict("mine" => true))))
    unasked = copy(theirs); delete!(unasked, "review_requested_at")
    @test isempty(W.review_owed(unasked))
    # Edits, in the order the reasons are checked: the verdict, the threads,
    # the run, the label. A draft is never ready.
    e = merge(base, Dict("state" => "OPEN"))
    @test isempty(W.edits_owed(e))
    e["labels"] = ["status: waiting for PR author"]
    @test W.edits_owed(e) == "labelled waiting for author"
    e["ci"] = "FAILURE";                       @test W.edits_owed(e) == "CI failure"
    e["unresolved"] = 2;                       @test W.edits_owed(e) == "2 unresolved thread(s)"
    e["review_decision"] = "CHANGES_REQUESTED"; @test W.edits_owed(e) == "changes requested"
    @test isempty(W.ready_to_merge(merge(base, Dict("state" => "OPEN", "draft" => true))))
    # Nothing about finished work should wake you, so it tracks loosely - and
    # what you said by hand wins.
    @test W.resolve_track(Dict{String,Any}(), Dict("state" => "MERGED", "mine" => true)) == "loose"
    # Whose it is decides the rest, which is the whole of "closely on mine, not
    # on anyone else's": your own pull request wakes on a failing CI and on any
    # comment, theirs wakes on a review, a human reply and a push and not on a
    # bot or its CI.
    yours = Dict{String,Any}("state" => "OPEN", "mine" => true)
    theirs = Dict{String,Any}("state" => "OPEN", "mine" => false)
    @test W.resolve_track(Dict{String,Any}(), yours) == "normal"
    @test W.resolve_track(Dict{String,Any}(), theirs) == "loose"
    for k in ("ci_failed", "their_comment_at")
        @test k in W.TRACK_KEYS["normal"] && !(k in W.TRACK_KEYS["loose"])
    end
    @test "human_comment_at" in W.TRACK_KEYS["loose"]
    # A review is in both, and it is a *time* rather than a verdict and a count:
    # the verdict only ever moves because a review arrived, and the arrival is
    # the thing that has a clock. So is a push, since 2026-09-12 - somebody
    # else's, at either level - and so is somebody else finishing the item.
    for k in ("review_at", "their_head", "state_at", "review_requested_at", "assigned_at")
        @test all(k in ks for ks in values(W.TRACK_KEYS))
    end
    # Every key but the CI bool is a time, and the bool is not hashed - it is
    # an edge, and `moved_stamp` is what says so.
    @test all(k == "ci_failed" || haskey(W.TIMED_KEYS, k)
              for ks in values(W.TRACK_KEYS) for k in ks)
    @test !any("review_decision" in ks || "review_count" in ks || "mergeable" in ks
               for ks in values(W.TRACK_KEYS))
    # And what you said by hand wins over both.
    @test W.resolve_track(Dict{String,Any}("track" => "normal"), theirs) == "normal"
    # Two levels, and there were four: a value that is no longer one is not a
    # level, and the default answers instead of it.
    @test W.TRACK == ("normal", "loose")
    @test W.resolve_track(Dict{String,Any}("track" => "background"), theirs) == "loose"
    # Two, and there is no third: the `all` level was every key there is, hashed
    # into an `fp_full` that set a `moved` field nothing ever read.
    @test Set(keys(W.TRACK_KEYS)) == Set(W.TRACK)
    # And finished work is the `done` box on the show axis, not a value on any
    # other: the lane axis says how a row got here, never what state it is in.
    @test !("done" in mkstate().lanes) && "landed" in mkstate().lanes

    # A merge not yet looked at is news, wherever it is: `seen_of` says so
    # of a row with no stamp and no floor, and `new` - "arrived this
    # refresh" - is not read here at all. Said on the `why` row, in the
    # word for what moved; the state row offers the filing either way.
    st = mkstate()
    done = W.Item(url = "https://example.invalid/x/y/pull/1", ref = "y#1", repo = "x/y",
                  number = 1, title = "t", state = "MERGED", lane = "nowhere",
                  moved_by = "state_at")
    says(it) = W.astrip(join([l for l in W.meta_lines(st, it, 52)
                              if occursin("state", l) || occursin("why", l)], " "))
    @test occursin("unread: new", says(done)) && occursin("x archives it", says(done))
    @test occursin("unread: new", says(W.with(done; new = true)))
    # Read past its last movement: something to file. Unread is `seen_of` -
    # no stamp, or a stamp from before it moved - and nothing else: a row
    # under its source's floor is read by construction, new or not.
    seen = W.with(done; moved_at = "2026-09-01T00:00:00Z", state_at = "2026-09-01T00:00:00Z")
    st.read = Dict(seen.url => "2026-09-02T00:00:00Z")
    @test occursin("why       read", says(seen)) && occursin("x archives it", says(seen))
    st.read = Dict(seen.url => "2026-08-31T00:00:00Z")
    @test occursin("unread: merged", says(seen))
    st.read = Dict{String,String}()
    st.sources = Dict("nowhere" => "2026-09-02T00:00:00Z")
    @test occursin("why       read", says(W.with(seen; new = true)))
end
