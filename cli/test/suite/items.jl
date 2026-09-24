# One item: how it is aged, labelled, imported, and re-read when it is stale.

@testset "an age is worked out when it is asked for" begin
    # Stored, an age is only true at the instant it was computed, and the
    # browser holds its items for the length of a session - so it was right for
    # about a day and then quietly wrong. The timestamp is what is kept.
    it = W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1, title = "t",
                act = "2000-01-01T00:00:00Z")
    @test W.age(it, W.DateTime(2000, 1, 2)) == 1
    @test W.age(it, W.DateTime(2000, 2, 1)) == 31
    # Same item, a week later in the same session: a different answer.
    @test W.age(it, W.DateTime(2000, 1, 9)) - W.age(it, W.DateTime(2000, 1, 2)) == 7
    # Nothing to measure is zero rather than an error.
    @test W.age(W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1, title = "t"),
                W.utcnow()) == 0
    # And it comes off the real facts, newest field first.
    loaded = W.loaditems()
    @test all(!isempty(x.act) for x in loaded)
    @test W.age(loaded[1], W.utcnow()) >= 0
end

@testset "one wording for a relative time, off the clock it is asked at" begin
    # What goes beside every absolute date on screen. Never stored, for the
    # reason above; the frame hands over its `at` and the answer is for it.
    now = W.ts("2026-09-16T12:00:00Z")
    @test W.ago_str("2026-09-16T11:59:30Z", now) == "just now"
    @test W.ago_str("2026-09-16T11:15:00Z", now) == "45m ago"
    @test W.ago_str("2026-09-16T03:00:00Z", now) == "9h ago"
    @test W.ago_str("2026-09-13T12:00:00Z", now) == "3d ago"
    @test W.ago_str("2026-09-13T13:00:00Z", now) == "2d ago"     # floors, like `age`
    @test W.ago_str("2022-03-01T00:00:00Z", now) == "4y ago"
    # A snooze's wake or a milestone is ahead of the clock.
    @test W.ago_str("2026-09-18T12:00:00Z", now) == "in 2d"
    @test W.ago_str("2026-09-16T14:30:00Z", now) == "in 2h"
    @test W.ago_str("2026-09-16T12:00:20Z", now) == "just now"
    # Nothing readable is nothing, not an error: a synthetic row has no dates.
    @test W.ago_str("", now) == "" && W.ago_str("2026-09-16", now) == ""
    # The same instant a week later is a different answer, which is the whole
    # reason it is not kept on the item.
    @test W.ago_str("2026-09-13T12:00:00Z", now + W.Day(7)) == "10d ago"
end

@testset "a label shows the moment it is set" begin
    # facts.json is the item's source and the browser cannot write it, so an
    # item that changes mid-session has to be rebuilt and put back.
    st = mkstate()
    it = fixture_item("yours, open, with a branch and labels")
    l = "a-brand-new-label"
    @test !(l in st.labels)
    n = W.withlabels(it, sort(vcat(it.labels, l)))
    # Everything else about it is the same object's contents, field for field.
    @test n.url == it.url && n.title == it.title && n.act == it.act && n.state == it.state
    @test n.labels == sort(vcat(it.labels, l)) && it.labels != n.labels
    @test W.replace_item!(st, n)
    @test st.all[findfirst(x -> x.url == it.url, st.all)].labels == n.labels
    # The pane that shows labels shows it, and the axis that filters by them
    # can offer it.
    @test occursin(l, W.astrip(join(W.meta_lines(st, n, 50), "\n")))
    @test l in st.labels
    # Taking it off again is the same move.
    @test W.replace_item!(st, W.withlabels(n, it.labels))
    @test !occursin(l, W.astrip(join(W.meta_lines(st, it, 50), "\n")))
    # And nothing is put back that was never here.
    @test !W.replace_item!(st, W.withlabels(
        W.Item(url = "nope", ref = "n#1", repo = "a/b", number = 1, title = "t"), [l]))
end

@testset "an item nobody's lane returns" begin
    # A url is not a query, so an issue in a repo nobody watches that does not
    # mention you matches no lane by construction. Importing is the manual way
    # in, and from there it is an ordinary item.
    u(x) = W.item_url(x)
    @test u("https://github.com/JuliaLang/julia/pull/62802/files#issuecomment-1") ==
          "https://github.com/JuliaLang/julia/pull/62802"
    @test u("github.com/o/r/issues/7") == "https://github.com/o/r/issues/7"
    @test u("https://github.com/o/r/pulls/7?w=1") == "https://github.com/o/r/pull/7"
    # Not an issue and not a pull request, so not something this can hold.
    @test u("https://github.com/o/r/discussions/3") === nothing
    @test u("https://github.com/o/r") === nothing
    @test u("nonsense") === nothing
    # The url is a literal in a GraphQL query, so what is not matched is not
    # trimmed - it is refused.
    @test u("https://github.com/o/r\"){x}/issues/1") === nothing

    # Its own lane, because no search claimed it, and nothing invents a fact
    # about it: not in the pile, owing nothing, tracked loosely since it is not
    # yours.
    cfg = W.config()
    r = Dict{String,Any}("lane" => "imported", "type" => "Issue", "state" => "OPEN",
                         "labels" => String[], "mine" => false,
                         "updated" => "2026-09-01T00:00:00Z")
    W.apply_state!(r, Dict{String,Any}(), cfg, W.utcnow())
    @test !W.in_pile(r) && r["track"] == "loose"
    @test all(isempty(r[k]) for k in ("reply", "edits", "ready", "review"))
    @test r["lane"] == "imported"          # and the lane is the row's own axis

    before = read(W.localfile(), String)
    try
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true
        at = W.utcnow()
        @test isempty(W.imported_urls())
        # Nothing is written for a url that is not one.
        @test occursin("not the url", W.import_url!(st, "not a url", at))
        @test isempty(W.imported_urls())

        # The row that is not an item. It leads the drawn list, and the cursor
        # is allowed one place above item 1 to reach it - which is what keeps
        # it out of st.items, and out of every filter, sort and count.
        r = mkstate()
        @test r.sel == 1                            # a list with work opens on work
        drawn() = W.astrip(W.render(r, 160, 40))
        @test occursin("import an item by url", drawn())
        W.handle!(r, Int('k'), ctrl)
        @test r.sel == 0
        W.handle!(r, Int('k'), ctrl)
        @test r.sel == 0                            # and there is nothing above it
        # Its own text in the pane beside it, rather than the item it came from.
        @test occursin("a url is not a query", drawn())
        @test !occursin(r.items[1].title, drawn())
        # Every per-item key is inert here: this row is not an item.
        r.status = ""
        for k in (Int('x'), Int('s'), Int('e'), Int('d'), Int('h'), Int('L'))
            @test W.handle!(r, k, ctrl) === :ok
        end
        @test isempty(r.status) && r.sel == 0
        # `↵` does the one thing it is for; on an item it hands over to the
        # pane beside it, as it always did.
        @test W.handle!(r, 13, ctrl) === :ok
        @test last(ctrl.stack) isa W.PromptView
        pop!(ctrl.stack)
        @test r.focus === :list
        W.handle!(r, Int('j'), ctrl)
        @test r.sel == 1
        W.handle!(r, 13, ctrl)
        @test r.focus === :detail && isempty(ctrl.stack)
        # `g` is the top of the *list*; the row above the top is asked for.
        r.focus = :list
        W.handle!(r, Int('G'), ctrl); W.handle!(r, Int('g'), ctrl)
        @test r.sel == 1

        # Both import paths land the thing unread, and importing what is
        # already carried is the common case rather than the odd one: an old
        # issue in a repo that is tracked anyway, a pull request of yours in one
        # that is not. No second row, no second request, and unread either way.
        keepi = W.FETCHED[]
        W.FETCHED[] = joinpath(mktempdir(), "fetched.json")
        try
            here = st.all[1]
            n0 = length(st.all)
            prevread = W.done_at(here.url)
            msg = W.import_url!(st, here.url, at)
            @test occursin("already here", msg) && occursin(here.ref, msg)
            @test length(st.all) == n0                      # not twice
            @test W.done_at(here.url) === nothing           # unread again
            @test haskey(W.Events.load_inbox()["items"], here.url)
            @test W.get_field(here.url, "imported") == string(W.Date(at))
            # And the undo takes back all three writes an import makes: the
            # line in state.toml, the row in the inbox, and the done stamp that
            # was cleared to put it in the unread lane. The row is the one that
            # outlived the undo before - nothing would ever have cleared it,
            # since the repo an import is made for is by definition one no poll
            # covers - and rust#1 sat in the lane for a week because of it.
            # Not a row in `st.all` it never added, which is the other sense.
            W.handle!(st, Int('z'), ctrl)
            @test length(st.all) == n0
            @test W.get_field(here.url, "imported") === nothing
            @test !haskey(W.Events.load_inbox()["items"], here.url)
            @test W.done_at(here.url) == prevread

            # A row a *poll* wrote is not an import's to remove. Importing
            # something already in the inbox leaves the richer entry alone -
            # `overwrite = false` - and so does taking that import back.
            poll = st.all[2]
            W.Events.inbox_add!([W.inbox_row(poll, at)])
            W.set_done(poll.url, W.stamp(at))
            W.import_url!(st, poll.url, at)
            @test W.done_at(poll.url) === nothing        # it went unread
            W.handle!(st, Int('z'), ctrl)
            @test haskey(W.Events.load_inbox()["items"], poll.url)
            @test W.done_at(poll.url) == W.stamp(at)
        finally
            W.FETCHED[] = keepi
        end

        # `I` is not a key about the selected item: an empty list is where the
        # first import gets made, and every per-item key is dropped there.
        empty_ = mkstate(); empty!(empty_.items)
        @test W.handle!(empty_, Int('I'), ctrl) === :ok
        @test last(ctrl.stack) isa W.PromptView
        @test occursin("events poller", last(ctrl.stack).note)
        pop!(ctrl.stack)
        # The filter pane owns its own keys, the way it does for `z`.
        empty_.lmode = :filters
        W.handle!(empty_, Int('I'), ctrl)
        @test isempty(ctrl.stack)

        url = "https://github.com/rust-lang/rust/issues/1"
        msg = W.import_url!(st, url * "#issuecomment-99", at)
        if occursin("could not import", msg)
            @info "no network; skipping the import itself"
        else
            # Followed from now on, and said to be outside the events lane -
            # which is the one thing an import cannot have, since its repo is
            # not one of the watched ones.
            @test occursin("imported", msg) && occursin("events lane", msg)
            @test W.imported_urls() == [url]
            @test W.get_field(url, "imported") == string(W.Date(at))
            it = st.all[findfirst(x -> x.url == url, st.all)]
            @test it.repo == "rust-lang/rust" && it.number == 1 && !it.is_pr
            @test !isempty(it.title)
            @test st.items[st.sel].url == url          # and it goes to it
            @test W.seen_of(it, W.Marks(st)) === :unread   # and lands unread
            # A second import of the same thing is not a second row, and says
            # what it did do: put it back in front of you.
            n0 = length(st.all)
            @test occursin("already here", W.import_url!(st, url, at))
            @test length(st.all) == n0
            # `z` takes back what each one did, and no more. The second import
            # added no row, so undoing it removes none.
            W.handle!(st, Int('z'), ctrl)
            @test isempty(W.imported_urls())
            @test findfirst(x -> x.url == url, st.all) !== nothing
            # The first one did, so undoing that one does.
            W.handle!(st, Int('z'), ctrl)
            @test findfirst(x -> x.url == url, st.all) === nothing
        end
        # An adopted branch is not an import, however alike the two look.
        W.set_fields(W.localurl("o/r", "br"), ["imported" => "2026-09-02"])
        @test isempty(W.imported_urls())
        # And nothing is fetched for what is already here.
        @test isempty(W.imported_items(Set(x.url for x in st.all)))
    finally
        write(W.localfile(), before)
    end
end

@testset "a stale entry goes up while it is re-read" begin
    # Two thresholds rather than one: a browser that opens should not be a
    # browser that waits, and what was on the page ten minutes ago is a better
    # answer than a spinner. Past the second one it is not, and the fetch blocks.
    keepdir = W.CACHE_DIR[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    keepttl, keepkeep = W.CACHE_FRESH[], W.CACHE_KEEP[]
    try
        W.cache_put("a", "v")
        @test W.cache_get("a", 60.0)[1] == "v"
        @test W.cache_get("a", -1.0) === nothing              # one number: a miss
        h = W.cache_get("a", -1.0; keep_s = 60.0)             # two: old, still shown
        @test h !== nothing && h[1] == "v" && h[2] >= 0
        @test W.cache_get("a", -1.0; keep_s = -1.0) === nothing   # past both

        # The sweep only ever collects what nothing would have shown.
        @test W.CACHE_SWEEP[] > W.CACHE_KEEP[]
        W.cache_put("b", "w")
        @test W.cache_clear(; older_than = 3600.0) == 0
        @test W.cache_clear(; older_than = 0.0) == 2
        @test W.cache_get("a", 60.0) === nothing

        # A thread out of date but worth showing goes up marked stale, which is
        # what arms the re-read; inside the TTL nothing is marked at all.
        it = W.Item(url = "https://github.com/o/r/pull/1", ref = "r#1", repo = "o/r",
                    number = 1, title = "t")
        W.cache_put("thread:" * it.url,
                    (body = Dict("user" => Dict("login" => "a"), "body" => "hello",
                                 "html_url" => it.url),
                     comments = []))
        W.CACHE_FRESH[] = -1.0
        ns = W.comment_nodes(it, W.utcnow())
        @test get(ns[1].meta, "stale", false) === true
        @test occursin("hello", ns[1].raw)
        W.CACHE_FRESH[] = 600.0
        @test get(W.comment_nodes(it, W.utcnow())[1].meta, "stale", false) === false
    finally
        W.CACHE_FRESH[], W.CACHE_KEEP[] = keepttl, keepkeep
        W.CACHE_DIR[] = keepdir
    end

    # The debounce is a second of the item actually being on screen: holding `j`
    # down passes twenty stale entries and must not fire twenty requests.
    st = mkstate()
    n = W.Node("cached", "body", :plain, true); n.meta["stale"] = true
    st.nodes = [n]; st.loaded = "u:comments"; st.pendkey = ""; st.wake = nothing
    @test W.arm_refresh!(st, 100.0)
    @test st.refreshkey == "u:comments" && st.refreshat == 100.0 + W.REFRESH_AFTER[]
    @test !W.due_refresh!(st, 100.0)                  # not yet
    @test st.refreshkey == "u:comments"
    # By the time the timer fires the selection may have moved, and the re-read
    # belongs to whatever is on screen then rather than to what armed it.
    st.loaded = "other:comments"
    @test !W.due_refresh!(st, 200.0)
    @test isempty(st.refreshkey)
    # A load already in flight is not something to race.
    st.loaded = "u:comments"
    W.arm_refresh!(st, 100.0)
    st.pendkey = "u:comments"
    @test !W.due_refresh!(st, 200.0) && isempty(st.refreshkey)
    # And a fresh entry arms nothing at all.
    st.nodes = [W.Node("fresh", "b", :plain, true)]
    @test !W.arm_refresh!(st, 100.0)
    # Nor is anything re-read that is not what is loaded.
    st.pendkey = ""; st.loaded = "nothing-like-this"
    @test !W.refresh_nodes!(st)

    # What lands from a refresh keeps the reader's place; what lands from a load
    # they asked for goes back to the top.
    st2 = mkstate()
    st2.nodes = [W.Node("cached", "b", :plain, true)]
    st2.nrow = 5; st2.ntop = 3
    fin(t) = (wait(t); t)
    st2.quiet = true; st2.pendkey = "k"
    st2.pending = fin(@async [W.failednode("could not load thread", "boom")])
    @test W.collect_pending!(st2)
    @test st2.nodes[1].header == "cached"          # the cached copy stayed up
    @test st2.nrow == 5 && st2.ntop == 3
    # Said on the pane's border, beside when the copy on screen was read.
    @test st2.reloadfailed
    st2.quiet = true; st2.pendkey = "k"
    st2.pending = fin(@async [W.Node("re-read", "b", :plain, true)])
    @test W.collect_pending!(st2)
    @test st2.nodes[1].header == "re-read" && st2.nrow == 5 && st2.ntop == 3
    @test !st2.reloadfailed && st2.loadedat > 0
    st2.quiet = false; st2.pendkey = "k"
    st2.pending = fin(@async [W.Node("asked for", "b", :plain, true)])
    @test W.collect_pending!(st2)
    @test st2.nodes[1].header == "asked for" && st2.nrow == 1 && st2.ntop == 1

    # ...to the top of it the first time. After that it goes back to wherever
    # the reader was, which is what `place` is: the line you were on, per item
    # and per mode, since a thread and a diff are two readings of one item.
    st3 = mkstate()
    st3.nodes = [W.Node("thread", "b", :plain, true)]
    thread = string(st3.items[1].url, ":comments")
    diff = string(st3.items[1].url, ":diff")
    st3.nkey = thread; st3.nrow = 40; st3.ntop = 35
    W.place!(st3, diff)
    @test st3.place[thread] == (40, 35)
    @test (st3.nrow, st3.ntop) == (1, 1)          # never been in the diff
    st3.nrow = 7; st3.ntop = 4
    W.place!(st3, thread)
    @test st3.place[diff] == (7, 4) && (st3.nrow, st3.ntop) == (40, 35)
    # An empty pane is not a place: between a fetch starting and its nodes
    # landing the frame clamps the cursor to the top, and remembering *that*
    # would lose the line the reader left.
    st3.nodes = W.Node[]; st3.nrow = 1; st3.ntop = 1
    W.place!(st3, diff)
    @test st3.place[thread] == (40, 35)
    # Which is why the load landing restores it a second time.
    st3.quiet = false; st3.pendkey = thread
    st3.pending = fin(@async [W.Node("thread", "b", :plain, true)])
    @test W.collect_pending!(st3)
    @test st3.nkey == thread && (st3.nrow, st3.ntop) == (40, 35)
end

@testset "an operation is measured from when it started" begin
    # There is no global clock any more. The instant is an argument, so a test
    # can hand in one that is obviously not now and see it come back out - the
    # thing a frozen global could never distinguish from a clock read halfway
    # through the work.
    then = W.DateTime(2000, 1, 2, 3, 4, 5)
    @test W.stamp(then) == "2000-01-02T03:04:05Z"
    @test startswith(W.now_isoformat(then), "2000-01-02T03:04:05")
    @test W.days_since("2000-01-01T03:04:05Z", then) == 1
    @test W.days_since("2000-01-03T03:04:05Z", then) == -1     # floors, so future is negative
    @test W.days_since(nothing, then) === nothing
    @test W.utcnow() > W.DateTime(2020)

    # A thread says what it showed you up to: the newest event in it, which
    # is a time GitHub wrote and not anything a clock here says - so `at` is
    # not in it, cold or warm, and a comment that arrived while the reads
    # were in flight is either on screen or newer than the stamp.
    st = mkstate()
    it = st.items[st.sel]
    seenat(x, at) = let ns = W.comment_nodes(x, at)
        i = findfirst(n -> haskey(n.meta, "seen_up_to"), ns)
        i === nothing ? nothing : ns[i].meta["seen_up_to"]
    end
    subject = nothing
    for x in first(st.items, 6)
        # Cold, so this is the path that actually talks to GitHub.
        rm(W._slot("thread:" * x.url); force = true)
        seenat(x, then) === nothing || (subject = x; break)
    end
    if subject === nothing
        @info "no thread could be fetched; skipping the seen-up-to check"
    else
        rm(W._slot("thread:" * subject.url); force = true)
        cold = seenat(subject, then)
        @test cold != "2000-01-02T03:04:05Z"
        @test W.ts(cold) !== nothing && W.ts(cold) <= W.utcnow() + W.Minute(1)
        @test cold >= subject.created
        # Warm, it is the same: the newest thing in the thread is the newest
        # thing in the thread.
        @test seenat(subject, W.DateTime(2030)) == cold
    end

    # And `e`'s fallback, for a thread carrying no fetch time at all: the
    # last movement on record, which is GitHub's time by construction.
    before = isfile(W.localfile()) ? read(W.localfile(), String) : ""
    try
        st.nodes = W.Node[]
        W.set_done(it.url, nothing); st.done = W.field_marks(W.load_marks(), "done")
        ctrl = W.Controller()
        W.handle!(st, Int('e'), ctrl, then)
        @test W.done_at(it.url) == W.moved_of(it)
        @test W.done_at(it.url) != "2000-01-02T03:04:05Z"
        # Left to itself a keystroke is its own operation, and the mark is the
        # same: it does not depend on the clock at all.
        W.handle!(st, Int('e'), ctrl)          # unread again
        W.handle!(st, Int('e'), ctrl)          # and read
        @test W.done_at(it.url) == W.moved_of(it)
    finally
        isempty(before) ? rm(W.localfile(); force = true) :
                          write(W.localfile(), before)
    end

    # A refresh measures its whole run against one instant, so it cannot
    # straddle midnight - which is what the global was for and what threading
    # keeps.
    r = Dict{String,Any}("head_at" => W.stamp(then - Dates.Day(3)),
                         "updated" => W.stamp(then - Dates.Day(9)))
    @test W.activity_age(r, then) == 3
    @test W.activity_age(r, then + Dates.Day(1)) == 4
end

@testset "an uncached item is not asked about until the cursor has stayed" begin
    # Holding `j` down passes twenty entries the poll just found, and a request
    # for each would spend the whole point of the cache on items nobody read.
    # A quarter of a second of the item being on screen is the difference. A
    # cached entry, current or stale, is never held: it costs no request.
    keepdir = W.CACHE_DIR[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    keepfresh = W.CACHE_FRESH[]
    try
        st = mkstate()
        it = st.items[st.sel]
        key = string(it.url, ":comments")
        st.loaded = ""; st.nodes = W.Node[]
        # Nothing cached: the pane empties and says so, the key is claimed, and
        # no fetch is in the air.
        W.load_nodes!(st)
        @test st.selurl == it.url && st.selat > 0
        @test st.pendkey == key && st.pending === nothing
        # On the pane's border, and not in the status, which is the keys'.
        @test W.pane_stamp(st, W.utcnow()) == "loading \u2026"
        @test !occursin("loading", st.status)
        @test W.holding(st, key)
        # Again, a moment later, still inside the dwell: nothing changes.
        W.load_nodes!(st)
        @test st.pending === nothing
        # And the metadata is held by the same dwell, saying "loading…" rather
        # than "—" meanwhile.
        W.load_meta!(st)
        @test isempty(st.metakey) && st.metapending === nothing
        @test W.meta_waiting(st, it)
        pr = W.Item(; url = it.url, ref = it.ref, repo = it.repo, number = it.number,
                      title = it.title, is_pr = true, state = "OPEN")
        said = W.astrip(join(W.meta_lines(st, pr, 60), "\n"))
        @test occursin("loading", said) && !occursin("—", said)
        # Past the dwell, both start. `sleep` rather than a clock passed in,
        # because `load_nodes!` reads the clock itself: the debounce is measured
        # against when the cursor landed, which is what `selat` records.
        st.selat -= W.LOAD_AFTER[]
        W.load_nodes!(st); W.load_meta!(st)
        @test st.pending !== nothing && st.pendkey == key
        @test st.metakey == it.url && st.metapending !== nothing
        # A stale entry goes up at once - held is for what has nothing to show.
        st2 = mkstate()
        it2 = st2.items[st2.sel]
        W.cache_put(W.thread_key(it2.url),
                    (body = Dict("user" => Dict("login" => "a"), "body" => "hello",
                                 "html_url" => it2.url), comments = []))
        W.CACHE_FRESH[] = -1.0
        st2.loaded = ""; st2.nodes = W.Node[]
        @test W.mode_cached(:comments, it2)
        W.load_nodes!(st2)
        @test st2.pending !== nothing
        # The wake is armed once per selection, not once per key while it waits.
        st3 = mkstate()
        woke = Ref(0); st3.wake = () -> (woke[] += 1)
        st3.selurl = ""; st3.selat = 0.0
        @test W.held!(st3, false, 100.0) == false          # selat is long ago
        st3.selat = 100.0
        @test W.held!(st3, false, 100.0) && st3.heldat == 100.0
        @test W.held!(st3, false, 100.1) && st3.heldat == 100.0
        @test !W.held!(st3, true, 100.0)                   # cached: never held
        @test !W.held!(st3, false, 100.0 + W.LOAD_AFTER[])
    finally
        W.CACHE_FRESH[] = keepfresh
        W.CACHE_DIR[] = keepdir
    end
end

@testset "stale metadata is re-read under itself" begin
    # The reviewers and the checks go up from an old entry the way the thread
    # does, and are re-read behind after the same second on screen. What lands
    # replaces them in place; what fails leaves them.
    keepdir = W.CACHE_DIR[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    keepfresh = W.CACHE_FRESH[]
    try
        st = mkstate()
        it = st.items[st.sel]
        st.selurl = it.url; st.selat = 0.0
        st.metakey = it.url
        # The bundle behind the row was asked for this selection already, or
        # the fixture row - which has none - would arm a re-read of its own
        # and the quiet read below would reach for the network.
        st.bundletried = it.url
        W.cache_put(W.Events.meta_key(it.url), Dict("x" => 1))
        # And the checks, which are the other half a pull request's metadata
        # is old by; which row is first depends on the order the list opens
        # in, and this is not a test of that.
        it.is_pr && W.cache_put(W.checks_key(it.repo, it.number), Dict("x" => 1))
        meta = (pending = "", reviews = [], requested = String[], teams = String[],
                assignees = String[])
        fin(t) = (wait(t); t)
        # Current: lands, and nothing is armed.
        st.metapending = fin(@async (meta = meta, checks = nothing))
        @test W.collect_meta!(st)
        @test st.meta === meta && !st.metastale && isempty(st.refreshkey)
        # Old: lands, and the re-read is armed for a second from now.
        W.CACHE_FRESH[] = -1.0
        st.metapending = fin(@async (meta = meta, checks = nothing))
        @test W.collect_meta!(st)
        @test st.metastale && st.refreshat > 0
        # Not due yet; then due, and the re-read starts with the pane still up.
        @test !W.due_refresh!(st, st.refreshat - 0.5)
        @test st.metastale && st.metapending === nothing
        @test !W.due_refresh!(st, st.refreshat)
        @test !st.metastale && st.metapending !== nothing
        @test st.meta === meta                                # still on screen
        # A re-read that fails leaves what was there, and arms nothing: the
        # entry that failed to re-read is still old and would only fail again.
        st.metapending = fin(@async (meta = nothing, checks = nothing, err = "boom"))
        @test W.collect_meta!(st)
        @test st.meta === meta && !st.metastale
        # The cursor moving off it drops the arming.
        st.metastale = true; st.metakey = "elsewhere"
        @test !W.due_refresh!(st, st.refreshat + 5)
        @test !st.metastale

        # The merge answer: a conflict past the window is old like the rest and
        # is re-asked with it; a failed re-read of it leaves it up, and arms
        # nothing.
        st.metakey = it.url
        W.cache_put(W.Events.merge_key(it.url), Dict("mergeable" => "CONFLICTING"))
        ms = (; id = "x", oid = "o", state = "OPEN", draft = false,
                mergeable = "CONFLICTING", status = "DIRTY", base = "master",
                commits = 1, methods = String[],
                text = Dict{String,Tuple{String,String}}())
        st.mergepending = fin(@async ms)
        @test W.collect_meta!(st)
        @test st.merge === ms && st.metastale
        st.metastale = false
        st.mergepending = fin(@async nothing)
        @test W.collect_meta!(st)
        @test st.merge === ms && !st.metastale
        # The checks pane is the same entry the tally reads, and goes up stale
        # the same way - which is what arms its re-read, rather than the pane
        # pausing on a two-minute TTL.
        pr = W.Item(url = "https://github.com/o/r/pull/9", ref = "r#9", repo = "o/r",
                    number = 9, title = "t", is_pr = true)
        W.cache_put(W.checks_key("o/r", 9), (state = "SUCCESS", contexts = []))
        ns = W.check_nodes(pr)
        @test get(ns[1].meta, "stale", false) === true
        W.CACHE_FRESH[] = 600.0
        @test get(W.check_nodes(pr)[1].meta, "stale", false) === false
    finally
        W.CACHE_FRESH[] = keepfresh
        W.CACHE_DIR[] = keepdir
    end
end

@testset "the branch is on the pane, in the form git takes" begin
    st = mkstate()
    row(l) = something(findfirst(x -> startswith(x, "branch"), l), 0)
    says(it) = (ls = W.astrip.(W.meta_lines(st, it, 60)); i = row(ls); i == 0 ? "" : ls[i])
    pr = W.Item(url = "https://example.invalid/pr/1", ref = "a#1", repo = "a/b", number = 1,
                title = "t", is_pr = true, branch = "jn/fix", base = "master")
    # The lanes' half alone: the branch and where it is going.
    @test says(pr) == "branch    jn/fix → master"
    # With the metadata fetched, a head in a fork is named `owner/repo:branch`,
    # which is what `gh pr checkout` and a `git fetch` would be told.
    st.metakey = pr.url
    st.meta = (pending = "", reviews = [], requested = String[], teams = String[],
               assignees = String[], fork = "c/b")
    @test says(pr) == "branch    c/b:jn/fix → master"
    # A head in the same repository says nothing about where; a meta built
    # before the field existed - a cache hit from then - is the same.
    st.meta = (pending = "", reviews = [], requested = String[], teams = String[],
               assignees = String[], fork = "")
    @test says(pr) == "branch    jn/fix → master"
    st.meta = (pending = "", reviews = [], requested = String[], teams = String[],
               assignees = String[])
    @test says(pr) == "branch    jn/fix → master"
    # A base that is not the repository's default branch is said, and coloured
    # as a thing waiting: it is where the change will not land.
    st.meta = (pending = "", reviews = [], requested = String[], teams = String[],
               assignees = String[], fork = "", default = "master")
    @test says(pr) == "branch    jn/fix → master"
    v1 = W.Item(url = pr.url, ref = "a#1", repo = "a/b", number = 1, title = "t",
                is_pr = true, branch = "jn/fix", base = "v1.x")
    @test says(v1) == "branch    jn/fix → v1.x  not master"
    raw = W.meta_lines(st, v1, 60)[row(W.astrip.(W.meta_lines(st, v1, 60)))]
    @test occursin(string(W.THEME.waiting, "v1.x"), raw)
    # Unknown - a cache entry from before the field, or no base repo - says
    # nothing rather than marking every base.
    st.meta = (pending = "", reviews = [], requested = String[], teams = String[],
               assignees = String[], fork = "", default = "")
    @test says(v1) == "branch    jn/fix → v1.x"
    # An adopted branch has one and no base; an issue has neither.
    @test says(W.Item(url = "local:a/b#wip", ref = "b#wip", repo = "a/b", number = 0,
                      title = "t", branch = "wip")) == "branch    wip"
    @test says(W.Item(url = "https://example.invalid/issues/2", ref = "a#2", repo = "a/b",
                      number = 2, title = "t")) == ""
    # The fork comes off the REST head, and only when it is not this repository.
    v = Dict{String,Any}("requested" => [], "teams" => [], "assignees" => [], "pending" => "",
                         "reviews" => [], "fork" => "c/b")
    @test W.Events._meta_shape(v).fork == "c/b"
    delete!(v, "fork")
    @test W.Events._meta_shape(v).fork == ""
    # So does the default branch, off `base.repo` of the same answer.
    @test W.Events._meta_shape(v).default == ""
    v["default"] = "main"
    @test W.Events._meta_shape(v).default == "main"
end

@testset "an adopted branch's panes do not ask GitHub" begin
    # A `local:` url is not a GitHub one, and splitting it as if it were was a
    # BoundsError in the thread pane. Nothing about the branch is on GitHub, so
    # every pane answers from here: the thread is the note, and the others say
    # what the row is rather than calling it an issue.
    wip = W.Item(url = "local:a/b#wip", ref = "b#wip", repo = "a/b", number = 0,
                 title = "t", is_pr = false, branch = "wip", note = "half done\n\nnext: tests")
    ns = W.comment_nodes(wip, W.utcnow())
    @test startswith(ns[1].header, "local branch wip")
    @test !get(ns[1].meta, "failed", false)
    @test ns[2].header == "your note" && occursin("half done", ns[2].raw)
    bare = W.Item(url = "local:a/b#wip", ref = "b#wip", repo = "a/b", number = 0,
                  title = "t", is_pr = false, branch = "wip")
    @test occursin("`v`", W.comment_nodes(bare, W.utcnow())[2].header)
    for f in (W.diff_nodes, W.pushed_nodes, W.check_nodes)
        h = f(bare)[1].header
        @test occursin("local branch", h) && !occursin("issue", h)
    end
    @test occursin("issue", W.diff_nodes(W.Item(url = "https://example.invalid/issues/2",
                                                ref = "a#2", repo = "a/b", number = 2,
                                                title = "t", is_pr = false))[1].header)
end

@testset "the pane follows the cursor however it moved" begin
    # A dialog's answer moves the browser's cursor while the dialog is on top,
    # and no key of the browser's is about to finish. `settle_all!`, which the
    # controller runs after every event, reaches it underneath.
    st = mkstate()
    ctrl = W.Controller()
    push!(ctrl.stack, st)
    W.settle!(st)
    push!(ctrl.stack, W.ChooseView("t", "", Tuple{String,Any}[("a", 1)], _ -> nothing))
    st.sel = st.sel == 1 ? 2 : 1                 # what an answer does
    key = string(st.items[st.sel].url, ":", st.mode)
    @test st.pendkey != key
    @test W.settle_all!(ctrl)                    # the frame changed
    @test st.pendkey == key
    @test W.pane_stamp(st, W.utcnow()) == "loading \u2026"
    # And again is nothing: the loaders are idempotent.
    @test !W.settle_all!(ctrl)
    # A key the browser handles itself settles at the end of `handle!`,
    # whichever of its paths returned.
    pop!(ctrl.stack)
    W.handle!(st, Int('j'), ctrl)
    @test st.pendkey == string(st.items[st.sel].url, ":", st.mode)
end
