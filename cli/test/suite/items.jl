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

@testset "a label shows the moment it is set" begin
    # facts.json is the item's source and the browser cannot write it, so an
    # item that changes mid-session has to be rebuilt and put back.
    st = mkstate()
    it = first(x for x in st.items if !isempty(x.labels))
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

    # Its own bucket, because no lane claimed it and no rule should invent a
    # reason for it being here.
    cfg = W.config()
    r = Dict{String,Any}("lane" => "imported", "type" => "Issue", "state" => "OPEN",
                         "labels" => String[], "mine" => false,
                         "updated" => "2026-09-01T00:00:00Z")
    b, why = W.derive_bucket(r, Dict{String,Any}(), cfg, W.utcnow())
    @test b == "imported" && occursin("url", why)
    # Except that finishing still wins: an import that merged is done.
    r["state"] = "MERGED"
    @test first(W.derive_bucket(r, Dict{String,Any}(), cfg, W.utcnow())) == "done"

    before = read(W.statefile(), String)
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
        for k in (Int('x'), Int('s'), Int('r'), Int('d'), Int('o'), Int('L'))
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
            prevread = W.read_at(here.url)
            msg = W.import_url!(st, here.url, at)
            @test occursin("already here", msg) && occursin(here.ref, msg)
            @test length(st.all) == n0                      # not twice
            @test here.url in st.unread
            @test haskey(W.Events.load_inbox()["items"], here.url)
            @test W.get_field(here.url, "imported") == string(W.Date(at))
            # And the undo takes back all three writes an import makes: the
            # line in state.toml, the row in the inbox, and the read stamp that
            # was cleared to put it in the unread lane. The row is the one that
            # outlived the undo before - nothing would ever have cleared it,
            # since the repo an import is made for is by definition one no poll
            # covers - and rust#1 sat in the lane for a week because of it.
            # Not a row in `st.all` it never added, which is the other sense.
            W.handle!(st, Int('z'), ctrl)
            @test !(here.url in st.unread) && length(st.all) == n0
            @test W.get_field(here.url, "imported") === nothing
            @test !haskey(W.Events.load_inbox()["items"], here.url)
            @test W.read_at(here.url) == prevread

            # A row a *poll* wrote is not an import's to remove. Importing
            # something already in the inbox leaves the richer entry alone -
            # `overwrite = false` - and so does taking that import back.
            poll = st.all[2]
            W.Events.inbox_add!([W.inbox_row(poll, at)])
            W.set_read(poll.url, W.stamp(at))
            W.import_url!(st, poll.url, at)
            @test W.read_at(poll.url) === nothing        # it went unread
            W.handle!(st, Int('z'), ctrl)
            @test haskey(W.Events.load_inbox()["items"], poll.url)
            @test W.read_at(poll.url) == W.stamp(at)
        finally
            W.FETCHED[] = keepi
        end

        # `i` is not a key about the selected item: an empty list is where the
        # first import gets made, and every per-item key is dropped there.
        empty_ = mkstate(); empty!(empty_.items)
        @test W.handle!(empty_, Int('i'), ctrl) === :ok
        @test last(ctrl.stack) isa W.PromptView
        @test occursin("events poller", last(ctrl.stack).note)
        pop!(ctrl.stack)
        # The filter pane owns its own keys, the way it does for `z`.
        empty_.lmode = :filters
        W.handle!(empty_, Int('i'), ctrl)
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
            @test url in st.unread                     # and lands unread
            # A second import of the same thing is not a second row, and says
            # what it did do: put it back in front of you.
            n0 = length(st.all)
            @test occursin("already here", W.import_url!(st, url, at))
            @test length(st.all) == n0
            # `z` takes back what each one did, and no more. The second import
            # added no row, so undoing it removes none.
            W.handle!(st, Int('z'), ctrl)
            @test isempty(W.imported_urls()) && !(url in st.unread)
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
        write(W.statefile(), before)
    end
end

@testset "a stale entry goes up while it is re-read" begin
    # Two thresholds rather than one: a browser that opens should not be a
    # browser that waits, and what was on the page ten minutes ago is a better
    # answer than a spinner. Past the second one it is not, and the fetch blocks.
    keepdir = W.CACHE_DIR[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    keepttl, keepkeep = W.DETAIL_TTL[], W.DETAIL_KEEP[]
    try
        W.cache_put("a", "v")
        @test W.cache_get("a", 60.0)[1] == "v"
        @test W.cache_get("a", -1.0) === nothing              # one number: a miss
        h = W.cache_get("a", -1.0; keep_s = 60.0)             # two: old, still shown
        @test h !== nothing && h[1] == "v" && h[2] >= 0
        @test W.cache_get("a", -1.0; keep_s = -1.0) === nothing   # past both

        # The sweep only ever collects what nothing would have shown.
        @test W.CACHE_SWEEP[] > W.DETAIL_KEEP[]
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
        W.DETAIL_TTL[] = -1.0
        ns = W.comment_nodes(it, W.utcnow())
        @test get(ns[1].meta, "stale", false) === true
        @test occursin("hello", ns[1].raw)
        W.DETAIL_TTL[] = 600.0
        @test get(W.comment_nodes(it, W.utcnow())[1].meta, "stale", false) === false
    finally
        W.DETAIL_TTL[], W.DETAIL_KEEP[] = keepttl, keepkeep
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
    @test occursin("cached copy", st2.status)
    st2.quiet = true; st2.pendkey = "k"
    st2.pending = fin(@async [W.Node("re-read", "b", :plain, true)])
    @test W.collect_pending!(st2)
    @test st2.nodes[1].header == "re-read" && st2.nrow == 5 && st2.ntop == 3
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

    # A thread is stamped with when its fetch *began*, not when it returned.
    # A comment that arrived while the request was in flight was never on
    # screen, so `r` must not be able to mark it seen.
    st = mkstate()
    it = st.items[st.sel]
    fetchedat(x, at) = let ns = W.comment_nodes(x, at)
        i = findfirst(n -> haskey(n.meta, "fetched"), ns)
        i === nothing ? nothing : ns[i].meta["fetched"]
    end
    subject = nothing
    for x in first(st.items, 6)
        # Cold, so this is the path that actually talks to GitHub.
        rm(W._slot("thread:" * x.url); force = true)
        fetchedat(x, then) === nothing || (subject = x; break)
    end
    if subject === nothing
        @info "no thread could be fetched; skipping the fetched-at check"
    else
        rm(W._slot("thread:" * subject.url); force = true)
        # Exactly what was handed in - not a clock read inside the fetch, and
        # not the moment it came back.
        @test fetchedat(subject, then) == "2000-01-02T03:04:05Z"
        # Warm, it reports when the entry was really written, measured back
        # from the same instant - so it errs early rather than claiming the
        # thread is as fresh as this read of it.
        warm = fetchedat(subject, then)
        @test warm < "2000-01-02T03:04:05Z"
        @test startswith(warm, "2000-01-02")
    end

    # And `r`'s fallback, for a thread carrying no fetch time at all.
    before = isfile(W.marksfile()) ? read(W.marksfile(), String) : ""
    try
        st.nodes = W.Node[]
        push!(st.unread, it.url)
        ctrl = W.Controller()
        W.handle!(st, Int('r'), ctrl, then)
        @test W.read_at(it.url) == "2000-01-02T03:04:05Z"
        # Left to itself a keystroke is its own operation, starting now.
        W.handle!(st, Int('r'), ctrl)
        push!(st.unread, it.url)
        W.handle!(st, Int('r'), ctrl)
        @test W.read_at(it.url) > "2020"
    finally
        isempty(before) ? rm(W.marksfile(); force = true) :
                          write(W.marksfile(), before)
    end

    # A refresh measures its whole run against one instant, so it cannot
    # straddle midnight - which is what the global was for and what threading
    # keeps.
    r = Dict{String,Any}("head_at" => W.stamp(then - Dates.Day(3)),
                         "updated" => W.stamp(then - Dates.Day(9)))
    @test W.activity_age(r, then) == 3
    @test W.activity_age(r, then + Dates.Day(1)) == 4
end
