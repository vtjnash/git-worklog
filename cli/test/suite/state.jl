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

        # `u` is unconditional: unread stays unread.
        delete!(st.unread, it.url)
        W.handle!(st, Int('u'), ctrl)
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
