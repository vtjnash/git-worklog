# `state.toml` and what is keyed by url: undo, snooze, and the metadata pane.

@testset "z undoes local actions" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    ctrl = W.Controller()

    # The stack itself, with nothing touching a file.
    st = mkstate()
    @test isempty(st.undos)
    W.handle!(st, Int('z'), ctrl)
    @test st.status == "nothing to undo"
    hits = Int[]
    push!(st.undos, W.Undo("first", () -> push!(hits, 1)))
    push!(st.undos, W.Undo("second", () -> push!(hits, 2)))
    W.handle!(st, Int('z'), ctrl)
    @test hits == [2] && occursin("second", st.status)     # newest first
    W.handle!(st, Int('z'), ctrl)
    @test hits == [2, 1] && isempty(st.undos)
    # A failing undo reports rather than throwing over the frame.
    push!(st.undos, W.Undo("bad", () -> error("boom")))
    W.handle!(st, Int('z'), ctrl)
    @test occursin("could not undo", st.status) && isempty(st.undos)

    # And it works on an empty list, which is exactly when it is wanted:
    # archiving or snoozing the last row of a lane empties it, and `z` used to
    # be swallowed along with every per-item key.
    empty = mkstate()
    # Emptied at the source, not just in the filtered list: `undo!` rebuilds the
    # membership lanes, so a list emptied only downstream comes straight back.
    empty.all = W.Item[]; W.refilter!(empty)
    @test isempty(empty.items) && empty.sel == 0    # nothing to be on but the
                                                    # row that is not an item
    hit = false
    push!(empty.undos, W.Undo("gone", () -> (hit = true)))
    W.handle!(empty, Int('z'), ctrl)
    @test hit && occursin("undid: gone", empty.status)
    W.handle!(empty, Int('z'), ctrl)
    @test empty.status == "nothing to undo"

    # r/u against the marks file, put back afterwards either way - and "put
    # back" includes the file not existing yet, which is what a dashboard that
    # has never been read has.
    marks() = isfile(W.localfile()) ? read(W.localfile(), String) : ""
    before = marks()
    try
        # Everything, so the row stays under the cursor: in the list the browser
        # opens on - unread, awake and open - `r` takes the row it marks read
        # out of the list, which is the behaviour the filter suite tests. The
        # cursor goes to an unread row, since a toggle needs somewhere to start.
        st = mkstate()
        st.filters = W.everything(); W.refilter!(st)
        # A row of its own rather than "the first unread one": what is read by
        # now depends on which files ran before this, and a cursor that lands
        # somewhere different every run is not a test of `r`.
        st.sel = findfirst(x -> x.url == fixture_item("unresolved review threads").url,
                           st.items)
        @test W.seen_of(st.items[st.sel], W.Marks(st)) === :unread
        it = st.items[st.sel]
        prev = W.read_at(it.url)
        # `r` toggles against the stamp, which is the axis and the one answer
        # to "is it unread" - there is no second set beside it any more.
        @test W.seen_of(it, W.Marks(st)) === :unread
        W.handle!(st, Int('r'), ctrl)
        @test st.status == "marked read"
        @test W.read_at(it.url) !== nothing
        @test W.seen_of(it, W.Marks(st)) === :read
        W.handle!(st, Int('r'), ctrl)                   # ...and back again
        @test st.status == "marked unread" && W.seen_of(it, W.Marks(st)) === :unread
        @test W.read_at(it.url) === nothing
        W.handle!(st, Int('z'), ctrl); W.handle!(st, Int('z'), ctrl)
        @test W.read_at(it.url) == prev          # exactly what was there
        @test marks() == before          # byte for byte

        # Read is stamped to what the thread showed, or to the last movement
        # on record, whichever is later - never to now. A comment that arrived
        # while you were reading was in neither and stays unread.
        st.nodes = [W.Node("h", "b", :md, true)]
        st.nodes[1].meta["seen_up_to"] = "2099-01-02T03:04:05Z"
        W.handle!(st, Int('r'), ctrl)
        @test W.read_at(it.url) == "2099-01-02T03:04:05Z"
        W.handle!(st, Int('z'), ctrl)
        st.nodes[1].meta["seen_up_to"] = "2020-01-02T03:04:05Z"
        W.handle!(st, Int('r'), ctrl)
        @test W.read_at(it.url) == W.moved_of(it)
        @test W.read_at(it.url) > "2020-01-02T03:04:05Z"
        W.handle!(st, Int('z'), ctrl)
        st.nodes = W.Node[]

        # A run of them unwinds in order.
        for _ in 1:3
            W.handle!(st, Int('r'), ctrl)
            st.sel = min(st.sel + 1, length(st.items))
        end
        @test length(st.undos) == 3
        for _ in 1:3; W.handle!(st, Int('z'), ctrl); end
        @test isempty(st.undos) && marks() == before
    finally
        isempty(before) ? rm(W.localfile(); force = true) :
                          write(W.localfile(), before)
    end

    # The footer counts what is pending.
    st = mkstate()
    push!(st.undos, W.Undo("x", () -> nothing))
    @test occursin("z undo(1)", W.astrip(W.render(st, 165, 40)))
end

@testset "a write lands whole, or not at all" begin
    # Every file in `data/` is rewritten from what was read a moment ago, and
    # none of it can be asked for again - so the write that matters is the one
    # that fails halfway. A reader sees the old file or the new one.
    d = mktempdir()
    p = joinpath(d, "x.json")
    W.write_atomic(p, "one")
    @test read(p, String) == "one"
    W.write_atomic(p, "two")
    @test read(p, String) == "two"
    # In the same directory and cleaned up, or the data repository fills with
    # the litter of every write.
    @test readdir(d) == ["x.json"]
    # A write that throws leaves what was there, and leaves nothing else.
    @test_throws MethodError W.write_atomic(p, nothing)
    @test read(p, String) == "two" && readdir(d) == ["x.json"]
    # The directory is made when it is missing: the first write of a fresh
    # checkout is `data/` itself.
    q = joinpath(d, "sub", "y.json")
    W.write_atomic(q, "hello")
    @test read(q, String) == "hello"
end

@testset "reading one field of state.toml" begin
    # Read-only: this is the file the refresh promises never to write.
    lines = W.load_lines()
    blocks = [strip(l, ['[', ']', '"']) for l in lines if startswith(l, "[\"")]
    if !isempty(blocks)
        u = String(first(blocks))
        @test W.get_field(u, "no-such-key") === nothing
        # Whatever it has, it comes back unquoted.
        for k in ("snooze", "track", "note")
            v = W.get_field(u, k)
            v === nothing || @test !startswith(v, "\"")
        end
    end
    @test W.get_field("https://example.invalid/nope", "track") === nothing
end

@testset "a snooze is a wake time" begin
    using Dates
    # One instant, handed in. Threading it is what lets a test say when "now"
    # is without reaching into the module to set a global first.
    now = W.ts("2026-09-12T12:00:00Z")

    # The shapes, and what each means now that a snooze is a wake time and
    # nothing else: a span, a date, a moment. "Until it moves" and "forever"
    # are not shapes - they are `r` and `x` - and do not parse.
    @test W.parse_snooze("2w") == (mode = :days, days = 14, until = nothing)
    @test W.parse_snooze("6mo").days == 180
    @test W.parse_snooze("2026-09-15") == (mode = :at, days = nothing, until = "2026-09-15T00:00:00Z")
    @test W.parse_snooze("2026-09-15T20:00:00Z").until == "2026-09-15T20:00:00Z"
    @test W.parse_snooze("on-change") === nothing
    @test W.parse_snooze("on-change/30d") === nothing
    @test W.parse_snooze("forever") === nothing
    @test W.parse_snooze("3days") === nothing
    @test W.parse_snooze("") === nothing

    # Resolved against the moment it is counted from - what `wl snooze` and
    # `s` write, and what a span typed by hand is counted from the read stamp
    # beside it as.
    @test W.wake_of("2w", W.stamp(now)) == "2026-09-26T12:00:00Z"
    @test W.wake_of("2026-09-15", W.stamp(now)) == "2026-09-15T00:00:00Z"
    @test W.wake_of("2026-09-15T20:00:00Z", nothing) == "2026-09-15T20:00:00Z"
    # A span with nothing to count from has no answer, and neither does a
    # value with no wake in it.
    @test W.wake_of("2w", nothing) === nothing
    @test W.wake_of("on-change", W.stamp(now)) === nothing
    @test W.wake_of("forever", W.stamp(now)) === nothing
    @test W.wake_of("3days", W.stamp(now)) === nothing
    @test W.wake_of(nothing, W.stamp(now)) === nothing
    @test W.wake_of("", W.stamp(now)) === nothing

    # Whether it has come is a comparison against one instant - the run's, or
    # the frame's - so a refresh cannot straddle midnight and wake half its
    # snoozes against another day.
    @test W.woken("2026-09-12T11:59:59Z", now)
    @test W.woken("2026-09-12T12:00:00Z", now)
    @test !W.woken("2026-09-12T12:00:01Z", now)
    @test !W.woken(nothing, now)
end

@testset "what the refresh does with a snooze, which is almost nothing" begin
    # Nothing arms and nothing wakes: the browser reads the wake off
    # `local.toml` per frame. What the refresh does is carry the resolved wake
    # on the row - for `wl next`, and for the second look - and stamp read an
    # item that was put away by hand and never read, since "not now" on an
    # unread item would otherwise say nothing at all.
    now = W.ts("2026-09-12T12:00:00Z")
    st(; kw...) = Dict{String,Any}(String(k) => v for (k, v) in kw)
    held(s) = (w = W.wake_of(get(s, "snooze", nothing), get(s, "read", nothing));
               (w !== nothing && !W.woken(w, now)) || W.truthy(get(s, "archived", nothing)))
    @test held(st(snooze = "2026-09-20T00:00:00Z"))
    @test !held(st(snooze = "2026-09-10T00:00:00Z"))
    @test held(st(snooze = "3d", read = "2026-09-11T00:00:00Z"))
    @test !held(st(snooze = "3d", read = "2026-09-01T00:00:00Z"))
    @test !held(st(snooze = "3d"))                    # nothing to count from
    @test held(st(archived = "2026-09-01T00:00:00Z"))
    @test !held(st(snooze = "on-change"))             # not a snooze at all
    @test !held(st())
end

@testset "the metadata pane" begin
    st = mkstate()
    it = st.items[st.sel]
    lines = W.meta_lines(st, it, 44)
    plain = W.astrip(join(lines, "\n"))
    # Everything cheap comes from facts.json and is there before any fetch.
    @test occursin("tracking", plain)
    @test occursin(it.track, plain)
    isempty(it.labels) || @test occursin(first(it.labels), plain)
    isempty(it.author) || @test occursin(it.author, plain)
    # How old it is and when it last changed at all, to the minute: the age of
    # what you are reading had to be guessed from the comment dates before, and
    # a pull request opened in 2022 reads nothing like one opened on Tuesday.
    @test W.when_str("2026-09-08T01:36:18Z") == "2026-09-08 01:36"
    @test W.when_str("") == "" && W.when_str("2026-09-08") == ""
    isempty(it.created) || @test occursin(W.when_str(it.created), plain)
    isempty(it.updated) || @test occursin(W.when_str(it.updated), plain)
    # A row with no timestamps - an unread thread the poll found, an adopted
    # branch - prints neither, rather than an empty pair of rows.
    bare = W.Item(url = "local:o/r#wip", ref = "r#wip", repo = "o/r", number = 0,
                  title = "an adopted branch")
    @test !occursin("created", W.astrip(join(W.meta_lines(st, bare, 44), "\n")))
    # Per-person review state needs a request; until it lands, it says so.
    @test st.meta === nothing
    it.is_pr && @test occursin("reviews", plain)
    @test all(W.awidth(l) <= 44 for l in lines)

    # It sits under the list, and the detail keeps the full height.
    L = W.layout(160, 50, length(lines))
    @test L.ly + L.lh == L.my              # meta directly under the list
    @test L.mw == L.lw                     # same column
    @test L.rh == L.lh + L.mh              # detail spans both
    @test L.ry == 2                        # ...starting at the top
    # It grows with its content, and the list gives way.
    wide = W.layout(160, 50, 30)
    @test wide.mh > L.mh && wide.lh < L.lh
    # Stacked, it is dropped rather than squeezing what is being read.
    @test W.layout(80, 14).mh == 0
end

@testset "the pane says when a snooze wakes, and when a thing was filed" begin
    # Both off the marks in `local.toml`, and neither off the item: a snooze
    # that ran out at lunch says it woke by dinner, without a refresh - and
    # goes on saying there was one after it is cleared (`last_snooze`).
    st = mkstate()
    it = st.items[st.sel]
    says(key) = W.astrip(join([l for l in W.meta_lines(st, it, 60)
                               if occursin(key, l)], " "))
    keep = W.LOCAL[]; W.LOCAL[] = fresh_local()
    before = read(W.localfile(), String)
    try
        @test says("snoozed") == ""
        W.apply_snooze!(st, it, "2099-01-01", W.utcnow())
        @test says("snoozed") == "snoozed   until 2099-01-01 00:00"
        W.apply_snooze!(st, it, "2020-01-01", W.utcnow())
        @test says("snoozed") == "snoozed   woke 2020-01-01 00:00"     # not asleep: woke
        W.apply_snooze!(st, it, nothing, W.utcnow())
        @test says("snoozed") == "snoozed   woke 2020-01-01 00:00"     # remembered
        W.apply_snooze!(st, it, "2099-01-01", W.utcnow())
        W.apply_snooze!(st, it, nothing, W.utcnow())
        @test says("snoozed") == "snoozed   until 2099-01-01 00:00  cleared"
        @test says("archived") == ""
        W.archive!(st, it, W.ts("2026-09-12T12:00:00Z"))
        @test occursin("2026-09-12 12:00", says("archived"))
        @test occursin("takes it back out", says("archived"))
    finally
        write(W.localfile(), before)
        W.LOCAL[] = keep
    end
end
