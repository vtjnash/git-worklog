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

    # r/u against the real read.json, put back afterwards either way.
    readfile = W.Events.readfile()
    before = read(readfile, String)
    try
        st = mkstate()
        it = st.items[st.sel]
        prev = W.Events.read_at(it.url)
        # `r` toggles against what is on screen.
        push!(st.unread, it.url)
        W.handle!(st, Int('r'), ctrl)
        @test st.status == "marked read"
        @test W.Events.read_at(it.url) !== nothing
        @test !(it.url in st.unread)
        W.handle!(st, Int('r'), ctrl)                   # ...and back again
        @test st.status == "marked unread" && it.url in st.unread
        W.handle!(st, Int('z'), ctrl); W.handle!(st, Int('z'), ctrl)
        @test W.Events.read_at(it.url) == prev          # exactly what was there
        @test read(readfile, String) == before          # byte for byte

        # `r` on something already read puts it back, which is the half `u`
        # used to do unconditionally before it became the refresh.
        delete!(st.unread, it.url)
        W.handle!(st, Int('r'), ctrl)
        @test st.status == "marked unread" && it.url in st.unread
        @test W.Events.read_at(it.url) === nothing
        W.handle!(st, Int('z'), ctrl)
        @test W.Events.read_at(it.url) == prev
        @test read(readfile, String) == before

        # Read is stamped to when the thread was fetched, not to now.
        st.nodes = [W.Node("h", "b", :md, true)]
        st.nodes[1].meta["fetched"] = "2020-01-02T03:04:05Z"
        push!(st.unread, it.url)
        W.handle!(st, Int('r'), ctrl)
        @test W.Events.read_at(it.url) == "2020-01-02T03:04:05Z"
        W.handle!(st, Int('z'), ctrl)
        st.nodes = W.Node[]

        # A run of them unwinds in order.
        for _ in 1:3
            push!(st.unread, st.items[st.sel].url)
            W.handle!(st, Int('r'), ctrl)
            st.sel = min(st.sel + 1, length(st.items))
        end
        @test length(st.undos) == 3
        for _ in 1:3; W.handle!(st, Int('z'), ctrl); end
        @test isempty(st.undos) && read(readfile, String) == before
    finally
        write(readfile, before)
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

@testset "snooze" begin
    using Dates
    # One instant, handed in. Threading it is what lets a test say when "now"
    # is without reaching into the module to set a global first.
    now = W.utcnow()
    ago(d) = Dates.format(now - Day(d), "yyyy-mm-ddTHH:MM:SS") * "Z"
    act(sv, snz, fp; cap = nothing) =
        W.snooze_active("u", Dict("snooze" => sv), fp, snz, now, cap)

    @test W.parse_snooze("on-change").mode === :onchange
    @test W.parse_snooze("on-change/30d") == (mode = :onchange, days = 30, until = nothing)
    @test W.parse_snooze("2w").days == 14
    @test W.parse_snooze("6mo").days == 180
    @test W.parse_snooze("2026-09-15").mode === :date
    @test W.parse_snooze("3days") === nothing
    @test W.parse_snooze("") === nothing

    # on-change: arm, hold, wake on movement, then stay awake.
    snz = Dict{String,Any}()
    @test act("on-change", snz, "FP1") == (true, "until it moves")
    @test W.snooze_entry(snz["u"])[1] == "FP1"
    @test act("on-change", snz, "FP1")[1]
    @test act("on-change", snz, "FP2") == (false, "woke: it moved")
    @test act("on-change", snz, "FP2")[1] == false          # stays awake

    # A cap wakes one that never moves - the whole point.
    snz = Dict{String,Any}("u" => W.snooze_record("FP1", ago(45)))
    @test act("on-change", snz, "FP1"; cap = 30)[1] == false
    @test occursin("asleep 45d", act("on-change", Dict{String,Any}(
        "u" => W.snooze_record("FP1", ago(45))), "FP1"; cap = 30)[2])
    # ...and the item's own cap beats the config default, either way.
    snz = Dict{String,Any}("u" => W.snooze_record("FP1", ago(45)))
    @test act("on-change/60d", snz, "FP1"; cap = 30)[1] == true
    snz = Dict{String,Any}("u" => W.snooze_record("FP1", ago(10)))
    @test act("on-change", snz, "FP1"; cap = 30)[1] == true

    # Relative: counted from when it was armed, and blind to movement.
    snz = Dict{String,Any}()
    @test act("2w", snz, "FP1") == (true, "for 2w")
    snz = Dict{String,Any}("u" => W.snooze_record("FP1", ago(5)))
    @test act("2w", snz, "FP1") == (true, "for 2w, 9d left")
    snz = Dict{String,Any}("u" => W.snooze_record("FP1", ago(20)))
    @test act("2w", snz, "FP1") == (false, "woke: 2w elapsed")
    @test act("2w", snz, "FPX")[1] == false

    # The shape written before arming times existed is adopted, not woken: an
    # upgrade must not wake every long-standing snooze at once.
    snz = Dict{String,Any}("u" => "FP1")
    @test act("on-change", snz, "FP1"; cap = 30)[1] == true
    @test W.snooze_entry(snz["u"])[2] !== nothing
    @test W.snooze_entry("WOKE") == ("WOKE", nothing)
    @test W.snooze_entry(nothing) == (nothing, nothing)

    @test act("2099-01-01", Dict{String,Any}(), "FP1")[1] == true
    @test act("2020-01-01", Dict{String,Any}(), "FP1") == (false, "woke: snooze expired")
    @test act("3days", Dict{String,Any}(), "FP1") == (false, "bad snooze value '3days'")
    @test W.snooze_active("u", Dict{String,Any}(), "FP1", Dict{String,Any}(), now) ==
          (false, nothing)
    # An expiry is measured against the instant the run began, so a refresh
    # cannot straddle midnight and wake half its snoozes against another day.
    yesterday = Dates.format(Date(now) - Day(1), "yyyy-mm-dd")
    @test act(yesterday, Dict{String,Any}(), "FP1")[1] == false
    @test W.snooze_active("u", Dict("snooze" => yesterday), "FP1", Dict{String,Any}(),
                          now - Day(2))[1] == true
end

@testset "a snooze takes the item out of the unread lane" begin
    # "Not now" and "unread" are the same answer twice, so falling asleep marks
    # it read and waking marks it unread again. Both edges and only the edges:
    # every refresh in between would either bury a comment that arrived while it
    # slept, or make a woken item impossible to file.
    @test W.snooze_edge(false, true, "until it moves") === :slept
    @test W.snooze_edge(true, false, "woke: it moved") === :woke
    @test W.snooze_edge(true, false, "woke: 2w elapsed") === :woke
    @test W.snooze_edge(true, true, "for 2w, 9d left") === nothing
    @test W.snooze_edge(false, false, nothing) === nothing
    # A snooze cleared by hand is not a wake. You did it a moment ago, on an
    # item in front of you, and it has no business coming back as news.
    @test W.snooze_edge(true, false, nothing) === nothing

    # The row a wake hands to the inbox is the shape a poll writes, because that
    # is what `unread()` reads - hand-delivered, since the item may be in a repo
    # no lane polls and then nothing would ever put it back in front of you.
    r = Dict{String,Any}("url" => "https://github.com/o/r/pull/1", "repo" => "o/r",
                         "number" => 1, "title" => "a pull request", "type" => "PullRequest",
                         "state" => "OPEN", "author" => "someone",
                         "updated" => "2026-09-01T12:00:00Z", "labels" => ["bug"],
                         "mine" => false)
    row = W.woke_row(r, W.utcnow())
    @test row["is_pr"] && row["state"] == "open" && row["updated"] == "2026-09-01T12:00:00Z"
    @test row["labels"] == ["bug"] && row["comments"] == 0 && row["mine"] == false
    # An issue with nothing else filled in still answers every key the poll's
    # own row has, because a missing one reads as a corrupt entry downstream.
    bare = W.woke_row(Dict{String,Any}("url" => "u", "repo" => "o/r", "number" => 2,
                                       "title" => "t", "type" => "Issue"), W.utcnow())
    @test !bare["is_pr"] && bare["state"] == "open" && bare["author"] == ""
    @test bare["labels"] == String[] && !isempty(bare["updated"])
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

@testset "a snooze says what it is waiting for" begin
    # "snoozed: yes" answered a question nobody was asking - the row is in the
    # snoozed lane either way. What is wanted is the trigger, and the refresh
    # already wrote one: `snooze_active`'s sentence, carried on the item as
    # `snooze_why`.
    st = mkstate()
    says(it) = W.astrip(join([l for l in W.meta_lines(st, it, 60)
                              if occursin("snoozed", l)], " "))
    base = (url = "https://example.invalid/pr/1", ref = "r#1", repo = "o/r",
            number = 1, title = "a snoozed pull request")
    @test says(W.Item(; base..., snoozed = true,
                      snooze_why = "for 2w, 9d left")) == "snoozed   for 2w, 9d left"
    @test says(W.Item(; base..., snoozed = true,
                      snooze_why = "until it moves")) == "snoozed   until it moves"
    # A snapshot written before the field existed still says the one thing it
    # knows, rather than an empty row.
    @test says(W.Item(; base..., snoozed = true)) == "snoozed   yes"
    # And an item that is not snoozed says nothing, whatever it carries: the
    # reason outlives the snooze in `facts.json` when one is cleared.
    @test says(W.Item(; base..., snooze_why = "until it moves")) == ""

    # The trigger comes off the item and not off a clock, which is the whole of
    # how two browsers on one dashboard stay agreed: waking is a decision only
    # `refresh` makes, by calling `snooze_active`, which arms and writes as it
    # goes. A relative snooze that ran out an hour ago is still snoozed here,
    # and stays that way until somebody runs `wl refresh`.
    elapsed = W.Item(; base..., snoozed = true, snooze_why = "for 1d, 0d left")
    @test W.state_ok(:snoozed, elapsed, Set{String}())
    @test !W.state_ok(:active, elapsed, Set{String}())
end
