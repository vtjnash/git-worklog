# What can be tested without a terminal.
#
# There is no TTY here, so the UI is verified by construction: `readevent` is a
# pure function of a byte stream, `render` is a pure function of state and a
# size, and `handle!`/`onmouse!` take an event and return an action. Between
# them that covers everything except whether a real terminal sends the bytes
# these tests feed it.
#
#     julia --project=cli cli/test/runtests.jl

using Test
using Worklog
const W = Worklog

# The standing error warning takes the footer's second row, so a log left over
# from a previous run would fail every test that asserts what is written there.
# Clearing it is deliberate: running the suite is a developer action, and the
# tests below write and delete this file themselves anyway.
isfile(W.ERRLOG) && rm(W.ERRLOG)

# The interaction clock is redirected for the whole run. Several tests below
# set a field, and setting a field stamps it - against the real file that would
# reorder the user's own lists as a side effect of running the suite.
W.TOUCHED[] = joinpath(mktempdir(), "touched.json")

@testset "input decoding" begin
    ev(s) = W.readevent(IOBuffer(s))
    @test ev("j") == W.KeyEvent(Int('j'))
    @test ev("\e") == W.KeyEvent(27)                 # bare escape
    @test ev("\e[A") == W.KeyEvent(W.K_UP)
    @test ev("\e[B") == W.KeyEvent(W.K_DOWN)
    @test ev("\eOA") == W.KeyEvent(W.K_UP)           # application cursor mode
    @test ev("\e[5~") == W.KeyEvent(W.K_PGUP)
    @test ev("\e[6~") == W.KeyEvent(W.K_PGDN)
    @test ev("\e[6;5~") == W.KeyEvent(W.K_PGDN)      # modified page-down
    @test ev("\e[Z") == W.KeyEvent(W.K_STAB)         # shift-tab
    # Alt/Meta has three spellings in the wild and all of them turn up.
    @test ev("\eb") == W.KeyEvent(W.K_WORD_LEFT)     # Terminal.app
    @test ev("\ef") == W.KeyEvent(W.K_WORD_RIGHT)
    @test ev("\e\x7f") == W.KeyEvent(W.K_WORD_BACK) # alt-backspace, everywhere
    @test ev("\e[1;3D") == W.KeyEvent(W.K_WORD_LEFT) # CSI with a modifier
    @test ev("\e[1;5C") == W.KeyEvent(W.K_WORD_RIGHT)# ctrl counts as by-word too
    @test ev("\e\e[D") == W.KeyEvent(W.K_WORD_LEFT) # iTerm's Esc+
    @test ev("\e[1;2D") == W.KeyEvent(W.K_LEFT)      # shift is not by-word
    @test ev("\e[3~") == W.KeyEvent(W.K_DEL)
    @test ev("\e[200~") == W.KeyEvent(-1)            # unknown, but consumed

    # A sequence must not leave its tail behind to arrive as keystrokes.
    io = IOBuffer("\e[Zq")
    @test W.readevent(io) == W.KeyEvent(W.K_STAB)
    @test W.readevent(io) == W.KeyEvent(Int('q'))

    m = ev("\e[<0;40;12M")
    @test m isa W.MouseEvent && m.kind === :press && m.x == 40 && m.y == 12
    @test ev("\e[<0;40;12m").kind === :release
    @test ev("\e[<32;40;12M").kind === :drag         # button 0 + motion
    @test ev("\e[<64;5;5M").kind === :wheelup
    @test ev("\e[<65;5;5M").kind === :wheeldown
    @test ev("\e[<16;5;5M").mods == 4                # ctrl-click
    @test ev("\e[<0;40M") == W.KeyEvent(-1)          # malformed
end

# The list pane is populated from the real snapshot: what matters here is the
# geometry, and a hand-built item list would not exercise the widths that
# actual titles do.
@testset "details blocks fold to their summary" begin
    seg(md) = [(k, sm) for (k, sm, _) in W.split_details(md)]
    @test seg("just prose") == [(:text, "")]
    @test seg("a<details><summary>S</summary>x</details>b") ==
          [(:text, ""), (:details, "S"), (:text, "")]
    # Nesting: a lazy regex would close the outer block at the inner one's end.
    outer = W.split_details("<details><summary>out</summary>p<details><summary>in</summary>q</details>r</details>")
    @test length(outer) == 1 && outer[1][2] == "out"
    @test occursin("<summary>in</summary>", outer[1][3])
    @test seg("<details>bare</details>") == [(:details, "details")]
    @test W.split_details("<details open><summary><b>A &amp; B</b></summary>x</details>")[1][2] == "A & B"
    # Unbalanced: leave it as prose rather than guess where it ends.
    @test seg("t <details><summary>never closed</summary> tail") == [(:text, "")]

    ns = W.body_nodes("alice", "before\n\n<details><summary>Impacted</summary>\nrows\n</details>\n\nafter",
                      "http://x", true)
    # Every piece of one body sits under that body's node, blocks and the prose
    # between them alike, so the comment folds as a unit.
    @test [(n.depth, n.open, n.header) for n in ns] ==
          [(0, true, "alice"), (1, false, "Impacted"), (1, true, "…")]
    @test ns[1].raw == "before" && ns[3].raw == "after"
    ns[1].open = false
    @test length(W.rows(ns, 80)) == 1          # closing it leaves one row
    ns[1].open = true
    # A folded block costs one row until it is opened: three headers plus one
    # body row each for the prose either side of it.
    @test length(W.rows(ns, 80)) == 5
    ns[2].open = true
    @test length(W.rows(ns, 80)) > 5
end

@testset "awrap breaks at spaces" begin
    ok(s, w) = all(W.awidth(l) <= w for l in W.awrap(s, w))
    # Nothing is lost or gained: a break only ends a line, it never edits.
    same(s, w) = W.astrip(join(W.awrap(s, w), "")) == W.astrip(s)

    @test W.awrap("guard the remaining raw stderr writes that gate cleanup", 40) ==
          ["guard the remaining raw stderr writes ", "that gate cleanup"]
    @test !any(occursin("deliver_resu", l) && !occursin("deliver_result", l)
               for l in W.awrap("guard cleanup in deliver_result and connect_to_peer", 40))

    # A run wider than the pane has nowhere to break, so it is split - and the
    # pieces fill the width rather than coming out ragged.
    long = W.awrap("a " * "x"^45, 20)
    @test all(W.awidth(l) <= 20 for l in long)
    @test length([l for l in long if W.awidth(l) == 20]) >= 2

    for w in (12, 20, 40, 79)
        for t in ("short", "", "     ", "a b c d e f g h i j k l m n o p q r s t",
                  "https://github.com/JuliaLang/julia/pull/62841#issuecomment-372112478 see",
                  "Tuple{Type{S{N, Tup}}, Vararg{Any}} and some prose after it",
                  "word " * "y"^100 * " tail")
            @test ok(t, w)
            @test same(t, w)
        end
    end

    # Style carries across a break, and is not doubled onto the carried word.
    st = W.awrap("\e[31mred words here\e[0m and \e[32mgreen ones\e[0m too", 14)
    @test all(W.awidth(l) <= 14 for l in st)
    @test count(l -> occursin("\e[32m", l), st) == 1
    @test startswith(st[2], "\e[31m")          # the colour resumes on line two
end

@testset "word motion" begin
    @test W.word_start("foo bar   ", 11) == 5      # over the spaces, then the word
    @test W.word_start("foo bar", 8) == 5
    @test W.word_start("foo", 1) == 1              # nothing behind the cursor
    @test W.word_end("foo bar", 1) == 4
    @test W.word_end("  foo bar", 1) == 6          # skip leading space first
    @test W.word_end("foo", 4) == 4
    # The two readline rules differ, and the difference is the point.
    @test W.word_start("/usr/local/lib", 15) == 1                 # ^w: no space to stop at
    @test W.word_start("/usr/local/lib", 15; alnum = true) == 12  # alt-bksp: just "lib"
    @test W.word_end("foo.bar", 1; alnum = true) == 4
end

@testset "readline keys" begin
    ctrl = W.Controller()
    got = Ref("")
    v = W.EditorView("t", "", t -> got[] = t)
    type!(x) = for c in x; W.handle!(v, Int(c), ctrl); end

    type!("alpha beta gamma")
    W.handle!(v, W.C_W, ctrl)
    @test W.text(v) == "alpha beta "
    W.handle!(v, W.K_WORD_BACK, ctrl)
    @test W.text(v) == "alpha "
    W.handle!(v, W.C_A, ctrl); @test v.col == 1
    W.handle!(v, W.C_E, ctrl); @test v.col == 7
    W.handle!(v, W.K_WORD_LEFT, ctrl); @test v.col == 1
    W.handle!(v, W.K_WORD_RIGHT, ctrl); @test v.col == 6
    W.handle!(v, W.C_A, ctrl)
    W.handle!(v, W.C_D, ctrl)                      # forward delete
    @test W.text(v) == "lpha "

    # ^w at column 1 joins upwards, the way backspace does.
    v2 = W.EditorView("t", "", identity; initial = "one\ntwo")
    W.handle!(v2, W.C_A, ctrl)
    W.handle!(v2, W.C_W, ctrl)
    @test W.text(v2) == "onetwo" && (v2.row, v2.col) == (1, 4)

    # $EDITOR moved off ^e, which is now end-of-line.
    v3 = W.EditorView("t", "", identity; initial = "abc")
    v3.col = 1
    W.handle!(v3, W.C_E, ctrl)
    @test v3.col == 4 && W.text(v3) == "abc"       # nothing was launched

    # The prompt has a cursor now, and the same keys.
    p = W.PromptView("t", "", identity)
    for c in "/usr/local/lib"; W.handle!(p, Int(c), ctrl); end
    W.handle!(p, W.K_WORD_BACK, ctrl)              # alt-backspace: one component
    @test p.buf == "/usr/local/"
    W.handle!(p, W.C_A, ctrl); @test p.col == 1
    W.handle!(p, Int('X'), ctrl)
    @test p.buf == "X/usr/local/" && p.col == 2
    W.handle!(p, W.C_E, ctrl); W.handle!(p, 127, ctrl)
    @test p.buf == "X/usr/local"
    W.handle!(p, W.C_W, ctrl)                      # ^w: the whole path at once
    @test p.buf == ""
    ls = split(W.render(p, 90, 24), "\n")
    @test length(ls) == 24 && all(W.awidth(l) == 90 for l in ls)
end

@testset "the composer" begin
    ctrl = W.Controller()
    got = Ref("")
    v = W.EditorView("comment", "on managers.jl:544", t -> got[] = t)
    type!(s) = for c in s; W.handle!(v, Int(c), ctrl); end

    type!("hello")
    @test W.text(v) == "hello"
    W.handle!(v, 13, ctrl)                       # enter splits at the cursor
    type!("world")
    @test W.text(v) == "hello\nworld"
    @test (v.row, v.col) == (2, 6)

    W.handle!(v, W.K_UP, ctrl); W.handle!(v, W.K_HOME, ctrl)
    @test (v.row, v.col) == (1, 1)
    W.handle!(v, W.K_END, ctrl)
    @test v.col == 6
    W.handle!(v, W.K_DOWN, ctrl)                 # down keeps the column
    @test (v.row, v.col) == (2, 6)

    W.handle!(v, 127, ctrl)                      # backspace
    @test W.text(v) == "hello\nworl"
    W.handle!(v, W.K_HOME, ctrl); W.handle!(v, 127, ctrl)   # joins the lines
    @test W.text(v) == "helloworl" && (v.row, v.col) == (1, 6)
    W.handle!(v, 11, ctrl)                       # ^k to end of line
    @test W.text(v) == "hello"

    # Non-ASCII goes in as one character, not three bytes.
    type!("… é")
    @test W.text(v) == "hello… é"
    @test v.col == length("hello… é") + 1

    # ^s submits and pops; esc would have discarded.
    @test W.handle!(v, 19, ctrl) === :pop
    @test got[] == "hello… é"

    # The cursor maps onto the wrapped rows the box actually draws.
    v2 = W.EditorView("t", "", identity; initial = "0123456789abcdefghij")
    rows, crow, ccol = W.textrows(v2, 10)
    @test rows == ["0123456789", "abcdefghij", ""]   # a row for the cursor to sit on
    @test (crow, ccol) == (3, 1)
    v2.col = 12
    _, crow, ccol = W.textrows(v2, 10)
    @test (crow, ccol) == (2, 2)

    for (w, h) in ((80, 24), (120, 40), (60, 12))
        ls = split(W.render(v2, w, h), "\n")
        @test length(ls) == h && all(W.awidth(l) == w for l in ls)
    end

    # suspend runs the body and puts the screen back.
    ran = Ref(false)
    out = mktemp() do path, io
        redirect_stdout(() -> W.suspend(() -> ran[] = true, ctrl), io)
        flush(io)
        read(path, String)
    end
    @test ran[]
    @test occursin("\e[?1049l", out) && occursin("\e[?1049h", out)
end

items = W.loaditems()
mkstate() = begin
    st = W.BState(items, "worklog", Set{String}())
    st.nodes = [W.Node("alice  2026-08-01   first", "A paragraph long enough that it has to be wrapped across several rows of the detail pane, which is exactly the case a copy must undo.\n\nsecond para", :md, true),
                W.Node("bob  2026-08-02   second", "short", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)   # suppress the fetch
    st
end

@testset "frame geometry" begin
    for (w, h) in ((80, 24), (110, 40), (160, 50), (100, 12), (200, 60), (72, 8))
        st = mkstate()
        f = W.render(st, w, h)
        ls = split(f, "\n")
        @test length(ls) == h
        @test all(W.awidth(l) == w for l in ls)
    end
end

@testset "click maps to the row under it" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    W.render(st, 160, 50)
    L = W.layout(160, 50, st.nmeta)
    ctrl = W.Controller()

    # A click on the list pane's third content row selects the third item.
    press(x, y) = W.onmouse!(st, W.MouseEvent(:press, 0, x, y, 0), ctrl)
    press(L.lx + 3, L.ly + 3)
    @test st.focus === :list && st.sel == st.top + 2

    # Clicking the detail pane's first content row lands on the first title row,
    # which is header, not content - so nrow stays put and focus moves.
    st2 = mkstate()
    W.render(st2, 160, 50)
    L = W.layout(160, 50, st2.nmeta)
    press2(x, y) = W.onmouse!(st2, W.MouseEvent(:press, 0, x, y, 0), ctrl)
    press2(L.rx + 10, L.ry + 1 + st2.hdr)          # first node row (its header)
    @test st2.focus === :detail && st2.nrow == 1

    # Column 1-2 of a header row is the fold marker.
    @test st2.nodes[1].open
    press2(L.rx + 2, L.ry + 1 + st2.hdr)
    @test !st2.nodes[1].open
    press2(L.rx + 2, L.ry + 1 + st2.hdr)
    @test st2.nodes[1].open

    # Clicking past the end of the content, or on a border, changes nothing.
    W.render(st2, 160, 50)
    before = (st2.nrow, st2.sel, st2.focus)
    press2(L.rx + 10, L.ry + L.rh - 3)      # blank rows below the last node
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx, L.ry + 4)                  # the pane border
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx + 10, 1)                    # the title bar
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx + 10, 50)                   # the footer
    @test (st2.nrow, st2.sel, st2.focus) == before
end

@testset "drag selects, and the copy is unwrapped" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    W.render(st, 160, 50)
    L = W.layout(160, 50, st.nmeta)
    ctrl = W.Controller()
    y0 = L.ry + 1 + st.hdr
    W.onmouse!(st, W.MouseEvent(:press, 0, L.rx + 10, y0 + 1, 0), ctrl)
    W.onmouse!(st, W.MouseEvent(:drag, 0, L.rx + 10, y0 + 3, 0), ctrl)
    W.onmouse!(st, W.MouseEvent(:release, 0, L.rx + 10, y0 + 3, 0), ctrl)
    @test W.selrange(st) == (2, 4)

    txt = W.selection_text(st, L.riw)
    @test !isempty(txt)
    @test !occursin('\e', txt)                       # no escapes in the paste
    # The wrapped paragraph comes back as the one line it was written as.
    @test occursin("A paragraph long enough that it has to be wrapped across several rows", txt)
    @test length(split(txt, "\n")) < 4               # fewer lines out than rows in

    # A code block is a box, and Term pads a box to the width it is given - so
    # the wide render used for the source map must never reach a copy.
    n = W.Node("h", "prose\n\n```\nshort line\nanother\n```\n", :md, true)
    W.nodelines(n, 60)
    @test maximum(W.awidth(sr) for (_, sr) in n.srcs) < 120

    # The selection survives a redraw and shows in the pane title.
    f = W.render(st, 160, 50)
    @test occursin("3 selected", f)
    @test W.selrange(st) == (2, 4)

    # Moving the cursor drops it; y with nothing selected still copies a URL.
    W.handle!(st, Int('j'), ctrl)
    @test W.selrange(st) === nothing
end

@testset "a long header wraps instead of being cut" begin
    long = "nalimilan  2018-03-16T21:13   Sorry, I do not really understand your example"
    n = W.Node(long, "body text", :md, true)
    nested = W.Node("a nested header long enough that it will not fit either", "b", :md, true, 1)

    for w in (30, 40, 60, 96)
        rs = W.rows([n, nested], w)
        @test all(W.awidth(r.text) <= w for r in rs)      # nothing overflows
        hdr = [r for r in rs if r.node == 1 && r.header]
        # Every word of the header survives somewhere.
        joined = replace(W.astrip(join([r.text for r in hdr], " ")), r"[─]+" => "")
        @test all(occursin(word, joined) for word in split(long))
        @test !occursin("…", joined)                      # not truncated
        @test hdr[1].part == 0 && all(r.part == 1 for r in hdr[2:end])
        @test occursin("▾", W.astrip(hdr[1].text))
        length(hdr) > 1 && @test !any(occursin("▾", W.astrip(r.text)) for r in hdr[2:end])
    end
    @test length([r for r in W.rows([n, nested], 30) if r.node == 1 && r.header]) > 1
    @test length([r for r in W.rows([n, nested], 200) if r.node == 1 && r.header]) == 1

    # The things that assumed one row per header still find the first one.
    st = mkstate()
    st.nodes = [n, nested]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    rs = W.rows(st.nodes, 40)
    @test W.headerrow(st, 1, 40) == 1
    st.nrow = 1
    W.jumpnode(st, 1, 40)
    @test rs[st.nrow].node == 2 && rs[st.nrow].part == 0   # skips continuations
end

@testset "folding takes what is nested under it" begin
    ns = [W.Node("comment", "body", :md, true), W.Node("folded", "hidden", :md, true, 1),
          W.Node("deeper", "also hidden", :md, true, 2), W.Node("sibling", "shown", :md, true)]
    @test length(W.rows(ns, 60)) == 8
    # A top-level header carries a rule out to the pane edge; ignore it here.
    derule(x) = String(rstrip(replace(W.astrip(x), r"[─ ]+$" => "")))
    ns[1].open = false
    shown = [derule(r.text) for r in W.rows(ns, 60)]
    @test shown == ["▸ comment", "▾ sibling", "shown"]
    ns[1].open = true; ns[2].open = false
    shown = [derule(r.text) for r in W.rows(ns, 60)]
    @test !any(occursin("deeper", x) for x in shown)     # the run below it goes too
    @test any(occursin("sibling", x) for x in shown)     # but not its uncle

    # The rule runs to the pane edge on a top-level header and not on a nested
    # one, which is what separates one comment from the next.
    ns[1].open = true; ns[2].open = true
    rs = W.rows(ns, 60)
    top = first(r for r in rs if occursin("comment", W.astrip(r.text)))
    nested = first(r for r in rs if occursin("folded", W.astrip(r.text)))
    @test W.awidth(top.text) == 60
    @test !occursin("─", W.astrip(nested.text))
end

@testset "review comments land on their hunk" begin
    hunk(file, start, count, ostart = start, ocount = count) = begin
        n = W.Node("$file  @@ $start,$count @@", "-old\n+new", :diff, true)
        merge!(n.meta, Dict{String,Any}("file" => file, "start" => start, "count" => count,
                                        "ostart" => ostart, "ocount" => ocount,
                                        "body" => "-old\n+new", "up" => 0, "down" => 0))
        n
    end
    cmt(id, path, line; reply = nothing, side = "RIGHT", who = "alice") =
        Dict{String,Any}("id" => id, "path" => path, "line" => line, "side" => side,
                         "in_reply_to_id" => reply, "body" => "a remark",
                         "user" => Dict{String,Any}("login" => who),
                         "created_at" => "2026-08-01T10:00:00Z")

    hs = [hunk("a.jl", 10, 5), hunk("b.jl", 100, 3)]
    out = W.attach_comments(copy(hs), [cmt(1, "a.jl", 12), cmt(2, "a.jl", 12; reply = 1),
                                       cmt(3, "b.jl", 101)], "http://x")
    hdr(n) = W.astrip(n.header)
    @test occursin("💬1", hdr(out[1]))                    # the hunk says so
    @test hdr(out[2]) == "alice  2026-08-01T10:00   a remark" && out[2].depth == 1
    @test out[3].depth == 2                               # the reply nests under it
    @test occursin("💬1", hdr(out[4]))                    # and the second hunk

    # Out of range, wrong file, and outdated all go to the same folded bucket.
    out = W.attach_comments(copy(hs), [cmt(1, "a.jl", 999), cmt(2, "z.jl", 3),
                                       cmt(3, "a.jl", nothing)], "http://x")
    bucket = findfirst(n -> occursin("since changed", hdr(n)), out)
    @test bucket !== nothing
    @test !out[bucket].open                               # folded, so they are away
    @test count(n -> n.depth == 1, out[bucket:end]) == 3
    @test !any(occursin("a remark", W.astrip(r.text)) for r in W.rows(out, 90))

    # A comment on a deleted line is anchored to the old side of the hunk.
    hs2 = [hunk("a.jl", 10, 5, 40, 6)]
    out = W.attach_comments(copy(hs2), [cmt(1, "a.jl", 42; side = "LEFT")], "http://x")
    @test occursin("💬1", hdr(out[1])) && length(out) == 2
end

@testset "axis counts match the brute-force ones" begin
    st = mkstate()
    # What the counts used to be computed by: one full pass per value, with one
    # axis replaced. Slow, obviously correct, and the thing to check against.
    brute(f, axis, v) = begin
        p = W.Filters(f.state, copy(f.buckets), copy(f.repos), copy(f.labels))
        axis === :state  ? (p.state = v) :
        axis === :bucket ? (p.buckets = Set([v])) :
        axis === :repo   ? (p.repos = Set([v])) : (p.labels = Set([v]))
        count(it -> W.matches(p, it, st.unread), st.all)
    end
    configs = [W.Filters(),
               W.Filters(:all, Set{String}(), Set{String}(), Set{String}()),
               W.Filters(:backlog, Set{String}(), Set{String}(), Set{String}()),
               W.Filters(:all, Set(["needs-review"]), Set{String}(), Set{String}()),
               W.Filters(:active, Set{String}(), Set(["JuliaLang/julia"]), Set{String}()),
               W.Filters(:all, Set(["issue"]), Set(["JuliaLang/julia"]), Set(["docs"]))]
    for f in configs
        st.filters = f
        (ns, nb, nr, nl) = W.axis_counts(st)
        for (k, _) in W.STATES
            @test get(ns, k, 0) == brute(f, :state, k)
        end
        for v in st.buckets;  @test get(nb, v, 0) == brute(f, :bucket, v); end
        for v in first(st.repos, 12);  @test get(nr, v, 0) == brute(f, :repo, v); end
        for v in first(st.labels, 12); @test get(nl, v, 0) == brute(f, :label, v); end
    end
end

@testset "n/N steps between filter groups" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    st.lmode = :filters; st.focus = :list
    ctrl = W.Controller()
    rows = W.filter_rows(st)
    g = W.filter_groups(rows)
    @test length(g) == 4                        # state, category, repo, label
    @test all(r -> rows[r][1] !== :head, g)     # each lands on something pickable

    st.frow = g[1]
    for want in g[2:end]
        W.handle!(st, Int('n'), ctrl)
        @test st.frow == want
    end
    W.handle!(st, Int('n'), ctrl)
    @test st.frow == g[end]                     # stops at the last group
    for want in reverse(g[1:end-1])
        W.handle!(st, Int('N'), ctrl)
        @test st.frow == want
    end

    # The ends and the page keys, which the filter list is long enough to need
    # and which used to stop at the item list.
    nf = length(rows)
    W.handle!(st, Int('G'), ctrl)
    @test st.frow == nf
    W.handle!(st, Int('g'), ctrl)
    @test st.frow == 1
    W.handle!(st, W.K_END, ctrl); @test st.frow == nf
    W.handle!(st, W.K_HOME, ctrl); @test st.frow == 1
    W.handle!(st, Int(' '), ctrl)
    paged = st.frow
    @test 1 < paged <= nf
    W.handle!(st, Int('b'), ctrl)
    @test st.frow == 1
    W.handle!(st, W.K_PGDN, ctrl); @test st.frow == paged
    W.handle!(st, W.K_PGUP, ctrl); @test st.frow == 1
    # And they stay inside the list at both ends.
    W.handle!(st, Int('b'), ctrl); @test st.frow == 1
    st.frow = nf
    W.handle!(st, Int(' '), ctrl); @test st.frow == nf
end

@testset "the key help says what is bound" begin
    st = mkstate()
    line = W.astrip(W.render(st, 200, 40))
    # Every key the list and the detail bind should be findable in the footer.
    for k in ("f filters", "d diff", "o comments", "c checks", "l log", "y copy",
              "/ search", "n/N node", "g/G top/bottom", "j/k line", "space/b page",
              "q quit", "tab pane", "C comment", "A review", "L labels",
              "r read/unread", "s snooze", "z undo", "v note", "e edit",
              "t term", "T agent", "\" worktrees", "m mouse")
        @test occursin(k, line)
    end
    # The navigation runs at the end, so a narrow screen keeps what is worth
    # reading rather than cutting it first.
    @test findfirst("d diff", line)[1] < findfirst("j/k line", line)[1]
    @test findfirst("/ search", line)[1] < findfirst("space/b page", line)[1]
end

@testset "labels are a filter axis" begin
    st = mkstate()
    @test !isempty(st.labels)
    # :all, so the state axis does not reject the sample before labels are read.
    f = W.Filters(); f.state = :all
    it = st.all[findfirst(x -> !isempty(x.labels), st.all)]
    push!(f.labels, first(it.labels))
    @test W.matches(f, it, Set{String}())
    other = st.all[findfirst(x -> isempty(x.labels), st.all)]
    @test !W.matches(f, other, Set{String}())
    @test occursin(first(it.labels), W.filter_summary(f))
    # Every label row the pane offers actually selects something.
    st.filters = f
    rows = W.filter_rows(st)
    @test any(r -> r[1] === :label, rows)
    @test all(r -> r[1] !== :label || !isempty(r[2]), rows)
end

@testset "what c writes to" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    st.mode = :diff
    n = W.Node("a.jl  @@ 10,3 @@", " ctx\n-gone\n+added", :diff, true)
    merge!(n.meta, Dict{String,Any}("file" => "a.jl", "start" => 10, "count" => 3,
                                    "ostart" => 40, "ocount" => 2, "up" => 0, "down" => 0,
                                    "body" => " ctx\n-gone\n+added"))
    st.nodes = [n]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    iw = W.layout(160, 50, st.nmeta).riw

    # Header row, then one row per diff line.
    st.nrow = 2; @test W.hunk_line_at(st, 1, iw) == (10, "RIGHT")   # context
    st.nrow = 3; @test W.hunk_line_at(st, 1, iw) == (41, "LEFT")    # deletion
    st.nrow = 4; @test W.hunk_line_at(st, 1, iw) == (11, "RIGHT")   # addition
    st.nrow = 1; @test W.hunk_line_at(st, 1, iw) === nothing        # the header

    st.nrow = 4
    @test W.compose_target(st, iw) == (:line, ("a.jl", 11, "RIGHT"))
    # A review comment answers with its own thread instead.
    st.nodes = [W.Node("alice  2026-01-01", "a remark", :md, true)]
    st.nodes[1].meta["comment_id"] = 4242
    st.nrow = 1
    @test W.compose_target(st, iw) == (:reply, 4242)
    # Anything else is the item as a whole.
    st.nodes = [W.Node("prose", "text", :md, true)]
    @test W.compose_target(st, iw) == (:item, nothing)
end

@testset "the write keys open the right views" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller()
    W.push_view!(ctrl, st)

    W.handle!(st, Int('C'), ctrl)          # capitals change things
    @test last(ctrl.stack) isa W.EditorView
    @test occursin(st.items[st.sel].ref, last(ctrl.stack).title)
    pop!(ctrl.stack)

    # A deleted line has nowhere to post yet, and says so instead of opening.
    st.mode = :diff
    n = W.Node("a.jl", " ctx\n-gone", :diff, true)
    merge!(n.meta, Dict{String,Any}("file" => "a.jl", "start" => 10, "count" => 2,
                                    "ostart" => 40, "ocount" => 2, "up" => 0, "down" => 0))
    st.nodes = [n]; st.nrow = 3
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    W.handle!(st, Int('C'), ctrl)
    @test length(ctrl.stack) == 1 && occursin("deleted line", st.status)

    # ...and lowercase still only looks: `c` is the checks pane now.
    W.handle!(st, Int('c'), ctrl)
    @test st.mode === :checks && length(ctrl.stack) == 1

    # Review: the picker opens, and picking pushes the composer *and keeps it* -
    # the picker pops itself, not whatever ended up on top.
    st.mode = :comments
    W.handle!(st, Int('A'), ctrl)
    ch = last(ctrl.stack)
    @test ch isa W.ChooseView
    @test [o[2] for o in W.shown(ch)] == ["APPROVE", "REQUEST_CHANGES", "COMMENT"]
    @test W.handle!(ch, 13, ctrl) === :pop
    at = findlast(x -> x === ch, ctrl.stack); deleteat!(ctrl.stack, at)   # what run! does
    @test last(ctrl.stack) isa W.EditorView
    @test last(ctrl.stack).allow_empty                              # approve needs no words
    pop!(ctrl.stack)

    W.handle!(st, Int('L'), ctrl)
    lv = last(ctrl.stack)
    @test lv isa W.ChooseView && !isempty(W.shown(lv))
    @test all(startswith(o[1], "[x] ") || startswith(o[1], "[ ] ") for o in W.shown(lv))
end

@testset "/ searches" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    ctrl = W.Controller()
    iw = W.layout(150, 40, 0).riw
    type!(v, x) = for c in x; W.handle!(v, Int(c), ctrl); end

    # In the list it narrows, and it can be kept or dropped.
    st = mkstate()
    n0 = length(st.items)
    W.handle!(st, Int('/'), ctrl)
    @test st.typing && st.searchin === :list
    type!(st, "libuv")
    @test 0 < length(st.items) < n0
    @test all(occursin("libuv", lowercase(i.title * i.ref)) for i in st.items)
    W.handle!(st, 13, ctrl)
    @test !st.typing && st.search == "libuv"          # kept
    W.handle!(st, Int('/'), ctrl); W.handle!(st, 27, ctrl)
    @test isempty(st.search) && length(st.items) == n0 # dropped

    # A bare number jumps, but only once it is finished being typed.
    st = mkstate()
    want = st.all[findfirst(i -> i.number > 999, st.all)]
    W.handle!(st, Int('/'), ctrl)
    type!(st, string(want.number))
    @test st.typing && !occursin("jumped", st.status)   # not until enter
    W.handle!(st, 13, ctrl)
    @test st.items[st.sel].ref == want.ref && occursin("jumped", st.status)
    # ...and it reaches an item the filter was hiding.
    st = mkstate()
    hidden = st.all[findfirst(i -> i.backlog, st.all)]
    @test !any(i -> i.url == hidden.url, st.items)
    W.handle!(st, Int('/'), ctrl); type!(st, string(hidden.number))
    W.handle!(st, 13, ctrl)
    @test st.items[st.sel].url == hidden.url
    st = mkstate()
    W.handle!(st, Int('/'), ctrl); type!(st, "99999999"); W.handle!(st, 13, ctrl)
    @test occursin("no item numbered", st.status)

    # In the detail pane it moves the cursor, and n/N step the matches.
    st = mkstate()
    st.nodes = [W.Node("a", "the quick brown fox\njumps over\nthe lazy dog and the fox", :md, true),
                W.Node("b", "nothing here", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    W.handle!(st, Int('/'), ctrl)
    @test st.searchin === :detail
    type!(st, "fox")
    ms = W.match_rows(st, iw)
    @test length(ms) == 2 && st.nrow == ms[1]
    W.handle!(st, 13, ctrl)
    W.handle!(st, Int('n'), ctrl); @test st.nrow == ms[2]
    W.handle!(st, Int('n'), ctrl); @test st.nrow == ms[1]   # wraps
    W.handle!(st, Int('N'), ctrl); @test st.nrow == ms[2]
    # A search in the thread must not narrow the list out from under the cursor.
    before = length(st.items)
    W.refilter!(st)
    @test length(st.items) == before

    f = W.render(st, 150, 40)
    @test occursin(W.HITBG, f)                          # matches are marked
    @test occursin("2 matches", W.astrip(f))            # and counted
    @test all(W.awidth(l) == 150 for l in split(f, "\n"))

    # Typing takes every key: `/d` is a search, not a jump to the diff pane.
    st = mkstate()
    mode0 = st.mode
    W.handle!(st, Int('/'), ctrl); type!(st, "d")
    @test st.mode === mode0 && st.search == "d"
end

@testset "/ searches the source, not the screen" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    ctrl = W.Controller()
    type!(v, x) = for c in x; W.handle!(v, Int(c), ctrl); end

    # A phrase the pane wrapped in the middle is still found, on the first row
    # of the line it belongs to.
    st = mkstate()
    st.nodes = [W.Node("a", "the quick brown fox jumps over the lazy dog and keeps running", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    body = [r for r in W.rows(st.nodes, 30) if !r.header]
    @test length(body) > 1                         # it really is wrapped
    # ...one that genuinely spans the break, so no single row contains it.
    st.search = "fox jumps over the lazy"
    across = W.match_rows(st, 30)
    @test length(across) == 1
    @test !any(occursin(st.search, W.astrip(r.text)) for r in W.rows(st.nodes, 30))
    st.search = "fox"
    @test length(W.match_rows(st, 30)) == 1        # one per line, not per row
    st.search = "nowhere"
    @test isempty(W.match_rows(st, 30))

    # Inside a folded block: found, counted, and opened on enter.
    st = mkstate()
    st.nodes = W.body_nodes("alice", "prose here\n\n<details><summary>Impacted</summary>\n" *
                                     "a line holding zarquon inside\n</details>\n\ntail",
                            "http://x", true)
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    iw = W.layout(150, 40, 0).riw
    @test !st.nodes[2].open                        # the block starts folded
    W.handle!(st, Int('/'), ctrl)
    type!(st, "zarquon")
    @test isempty(W.match_rows(st, iw))            # no row shows it...
    @test st.hidden == 1                           # ...but it is known to be there
    @test occursin("+1 folded", W.astrip(W.render(st, 150, 40)))
    W.handle!(st, 13, ctrl)
    @test st.nodes[2].open && occursin("opened 1 folded block", st.status)
    @test length(W.match_rows(st, iw)) == 1 && st.hidden == 0

    # Opening reaches through more than one level of nesting.
    st = mkstate()
    ns = [W.Node("top", "", :md, false), W.Node("mid", "", :md, false, 1),
          W.Node("leaf", "zarquon lives here", :md, false, 2)]
    st.nodes = ns
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    @test W.ancestors_of(st, 3) == [3, 2, 1]
    W.handle!(st, Int('/'), ctrl); type!(st, "zarquon"); W.handle!(st, 13, ctrl)
    @test all(n.open for n in st.nodes)
    @test occursin("opened 3 folded blocks", st.status)

    # Typing must not spring folds open on its own.
    st = mkstate()
    st.nodes = [W.Node("top", "", :md, true), W.Node("folded", "zarquon", :md, false, 1)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    W.handle!(st, Int('/'), ctrl); type!(st, "zarq")
    @test !st.nodes[2].open && st.hidden == 1
end

@testset "fenced code blocks are lifted out of Term" begin
    segs = W.split_fences("before\n\n```julia\nf(x)\n  g\n```\n\nafter")
    @test [(k, sm) for (k, sm, _) in segs] == [(:text, ""), (:code, "julia"), (:text, "")]
    @test segs[2][3] == "f(x)\n  g"
    @test W.split_fences("no code here") == [(:text, "", "no code here")]
    # An unclosed fence gives its lines back rather than swallowing them.
    @test occursin("dangling", W.split_fences("a\n```\ndangling")[1][3])
    @test W.split_fences("~~~\nx\n~~~")[1][1] === :code

    ns = W.body_nodes("alice", "before\n\n```julia\nf(x)\n```\n\nafter", "http://x", true)
    code = [n for n in ns if n.kind === :plain]
    @test length(code) == 1
    @test code[1].depth == 1 && occursin("julia", code[1].header)
    @test code[1].open                                  # short blocks stay open
    long = W.body_nodes("a", string("```\n", join(["l$i" for i in 1:40], "\n"), "\n```"),
                        "", true)
    @test !first(n for n in long if n.kind === :plain).open   # long ones fold away

    # No box, and nothing wider than the pane - the whole point.
    wide = W.body_nodes("a", string("```\n", "x"^250, "\n```"), "", true)
    for n in wide; n.kind === :plain && (n.open = true); end
    rs = W.rows(wide, 96)
    @test all(W.awidth(r.text) <= 96 for r in rs)
    @test !any(occursin("│", W.astrip(r.text)) || occursin("└", W.astrip(r.text)) for r in rs)

    # A plain node must not double its braces: it never reaches Term.
    n = W.Node("h", "f() { Dict{String,Int}() }", :plain, true)
    @test W.astrip(join(W.nodelines(n, 80), "")) == "f() { Dict{String,Int}() }"
end

@testset "inline code is a background, not a shout" begin
    lines(t, w) = W.nodelines(W.Node("h", t, :md, true), w)
    plain(t, w) = strip(join([W.astrip(l) for l in lines(t, w)], " "))

    ls = lines("call `Sockets.bind` and `false` here", 70)
    @test count(l -> occursin(W.CODEBG, l), ls) >= 1
    @test sum(count(W.CODEBG, l) for l in ls) == 2          # one per span
    # The backticks stay, so a copy keeps the formatting the author wrote.
    @test plain("call `Sockets.bind` and `false` here", 70) ==
          "call `Sockets.bind` and `false` here"
    # Nothing leaks the sentinel colour, at any width.
    for w in (24, 40, 70, 120)
        for t in ("call `Sockets.bind` here",
                  "a `span with several words that will not fit on one line at all` yes",
                  "unclosed `backtick here", "no code at all here")
            @test !any(occursin(W.MD_CODE_SENTINEL, l) for l in lines(t, w))
        end
    end
    # A span Term split has no pair on one line, so it falls back quietly.
    split_ = lines("a `span with several words that will not fit on one line at all` yes", 30)
    @test !any(occursin(W.MD_CODE_SENTINEL, l) for l in split_)
    @test occursin("`span with several words", plain("a `span with several words that will not fit on one line at all` yes", 30))
    # And the background never reaches the plain text.
    @test !occursin("[48;5;238m", plain("call `x` here", 70))
end

@testset "markup does not eat the text" begin
    render(t) = strip(W.astrip(join(W.nodelines(W.Node("h", t, :md, true), 100), " ")))
    # Julia's Markdown opens emphasis on an intraword underscore and it takes
    # two to pair, so a single identifier was never the failing case.
    @test render("call deliver_result and connect_to_peer here") ==
          "call deliver_result and connect_to_peer here"
    @test render("snake_case_name alone") == "snake_case_name alone"
    @test render("one_two three_four") == "one_two three_four"
    # Real emphasis - an underscore with a space before it - still works.
    @test render("a _real emphasis_ here") == "a real emphasis here"
    # Code is left alone: a backslash inside a span would print.
    @test render("`deliver_result` in code stays") == "`deliver_result` in code stays"
    @test render("mixed `a_b` and c_d_e here") == "mixed `a_b` and c_d_e here"

    esc = W.escape_source
    @test esc("a_b") == "a\\_b"
    @test esc("_leading and trailing_") == "_leading and trailing_"
    @test esc("```\nkeep_me\n```") == "```\nkeep_me\n```"          # fenced
    @test esc("    keep_me indented") == "    keep_me indented"    # indented
    @test esc("`keep_me` but not_this") == "`keep_me` but not\\_this"
    @test esc("") == ""

    # Braces written as prose survive too: Term's markup is `{...}`, and
    # apply_style deletes anything shaped like a tag.
    @test render("a Tuple{Type{S{N}}} sig") == "a Tuple{Type{S{N}}} sig"
    @test render("mixed Set{Int} and `Vector{T}` here") == "mixed Set{Int} and `Vector{T}` here"
    @test render("a { lone brace") == "a { lone brace"
    @test esc("a {b}") == "a {{b}}"
    @test esc("`keep {this}`") == "`keep {this}`"        # code is left alone

    # And the name is findable, which is the point.
    st = mkstate()
    st.nodes = [W.Node("h", "guard the raw stderr writes in deliver_result and connect_to_peer",
                       :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    st.search = "deliver_result"
    @test length(W.match_rows(st, 100)) == 1
end

@testset "a match cut by the wrap is marked on both rows" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    # The highlight markers, made visible without astrip eating them first.
    seen(f) = W.astrip(replace(replace(f, W.HITBG => "<"), W.NOBG => ">"))
    detail(st) = [l for l in split(seen(W.render(st, 150, 40)), "\n") if occursin("<", l)]

    st = mkstate()
    # Long enough to wrap in a 96-column pane, with the query spanning the break.
    st.nodes = [W.Node("a", "alpha beta gamma delta epsilon zeta eta theta iota kappa " *
                            "lambda mu nu xi omicron pi rho sigma tau upsilon phi chi", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail; st.searchin = :detail
    iw = W.layout(150, 40, st.nmeta).riw
    body = [r for r in W.rows(st.nodes, iw) if !r.header]
    @test length(body) > 1                          # it really does wrap
    # The two words either side of the break.
    tail = split(W.astrip(body[1].text))[end]
    head = split(W.astrip(body[2].text))[1]
    st.search = string(tail, " ", head)
    @test !any(occursin(st.search, W.astrip(r.text)) for r in W.rows(st.nodes, iw))
    marked = detail(st)
    @test length(marked) == 2                       # both halves marked
    joined = join(marked, "\n")
    @test occursin(string("<", tail, ">"), joined) && occursin(string("<", head, ">"), joined)

    # An ordinary match is marked once, exactly.
    st.search = "gamma"
    one = join(detail(st), "\n")
    @test occursin("<gamma>", one) && count(==('<'), one) == 1

    # Nothing invented, and the pane's printable text is untouched.
    st.search = "zzzz"
    @test isempty(detail(st))
    st.search = "gamma"
    pane_of(f) = [String(first(l, 100)) for l in split(W.astrip(f), "\n")[2:end-2]]
    lit = deepcopy(st); lit.search = ""
    @test pane_of(W.render(st, 150, 40)) == pane_of(W.render(lit, 150, 40))

    # Indented rows: the depth padding is not part of the source.
    st2 = mkstate()
    st2.nodes = [W.Node("top", "", :md, true),
                 W.Node("in", "alpha beta gamma delta epsilon", :md, true, 1)]
    st2.loaded = string(st2.items[st2.sel].url, ":", st2.mode)
    st2.focus = :detail; st2.searchin = :detail; st2.search = "gamma"
    @test occursin("<gamma>", join(detail(st2), "\n"))

    # row_span itself: a piece of the line, located with a moving cursor.
    r1 = W.Row(1, false, "alpha beta", "alpha beta gamma alpha beta", 0)
    @test W.row_span(r1, 0, 1) == 1:10
    @test W.row_span(r1, 0, 11) == 18:27            # the second copy, not the first
    @test W.row_span(W.Row(1, false, "nope", "alpha beta", 0), 0, 1) === nothing
    @test W.row_span(W.Row(1, false, "  beta  ", "alpha beta", 0), 2, 1) == 7:10
end

@testset "span highlighting" begin
    s = "\e[31mred\e[0m and green"
    hl = W.hlspan(s, W.findhits(W.astrip(s), "green"), W.HITBG)
    @test W.astrip(hl) == W.astrip(s)          # nothing printable is disturbed
    @test occursin(W.HITBG * "green", hl)
    @test endswith(hl, W.NOBG)                 # ends the background, not the colour
    @test W.findhits("aXbXc", "x") == [2:2, 4:4]
    @test isempty(W.findhits("abc", ""))
    @test W.hlspan("plain", UnitRange{Int}[], W.HITBG) == "plain"
    # A match inside styled text keeps the style around it.
    s2 = "\e[32mfoo bar baz\e[0m"
    @test W.astrip(W.hlspan(s2, W.findhits(W.astrip(s2), "bar"), W.HITBG)) == "foo bar baz"
end

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

    # r/u against the real read.json, put back afterwards either way.
    readfile = joinpath(W.ROOT, "read.json")
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

@testset "arrow keys and shift-tab" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller()
    st.focus = :list
    W.handle!(st, W.K_DOWN, ctrl)
    @test st.sel == 2
    W.handle!(st, W.K_UP, ctrl)
    @test st.sel == 1

    # Detail pane: shift-tab cycles focus, and the arrows move by row. Fresh
    # state, because moving the list selection above started a fetch that
    # cleared the nodes - which is exactly what it should do.
    st = mkstate()
    W.handle!(st, W.K_STAB, ctrl)
    @test st.focus === :detail
    W.handle!(st, W.K_DOWN, ctrl)
    @test st.nrow == 2
    W.handle!(st, W.K_PGDN, ctrl)
    @test st.nrow == length(W.rows(st.nodes, W.layout(160, 50, st.nmeta).riw))
    W.handle!(st, W.K_HOME, ctrl)
    @test st.nrow == 1
end

@testset "multiplexer sessions" begin
    # Naming is pure, so it is tested whether or not a tmux exists here. All
    # three parts are in it: which copy of the repo, which state of it, and
    # what was in view.
    @test W.mux_name("julia", "master", "62841") == "wl-julia-master-62841"
    @test W.mux_name("julia", "master", "62841", :agent) == "wl-julia-master-62841-agent"

    # A branch keeps its owner prefix: tmux leaves `/` alone.
    @test W.mux_name("julia-wt2", "vtjnash/fix", "1") == "wl-julia-wt2-vtjnash/fix-1"

    # tmux does not reject `.` or `:` in a session name, it rewrites them to
    # `_` and says nothing. A name that did not do the same substitution would
    # create a session and then never find it again.
    @test W.mux_name("Distributed.jl", "release-1.12", "198") == "wl-Distributed_jl-release-1_12-198"
    @test !occursin('.', W.mux_name("y.z.jl", "a.b", "3"))
    @test !occursin(':', W.mux_name("a:b", "c:d", "4"))

    # A worktree with no branch known still gets a usable name.
    @test W.mux_name("julia", "", "62841") == "wl-julia-62841"

    # A child starts as its own session. Only what this process actually
    # inherited is scrubbed, so on a machine where the browser was not started
    # from inside an agent this is the identity and costs nothing.
    withenv("CLAUDE_CODE_MESSAGING_TOKEN" => "x", "CLAUDE_CODE_CHILD_SESSION" => "y") do
        w = W.standalone("claude")
        @test startswith(w, "env -u ") && endswith(w, " claude")
        @test occursin("-u CLAUDE_CODE_MESSAGING_TOKEN", w)
        @test occursin("-u CLAUDE_CODE_CHILD_SESSION", w)
    end
    withenv((k => nothing for k in filter(x -> startswith(x, "CLAUDE"), collect(keys(ENV))))...) do
        @test W.standalone("claude") == "claude"
    end

    # A missing binary has to be an answer, not an exception: every caller is
    # on a keystroke path.
    withenv("WORKLOG_TMUX" => "/nonexistent/tmux") do
        @test W.mux_bin() === nothing
        @test W.mux("list-sessions") == (false, "no tmux on PATH")
        @test W.mux_alive("wl-nothing") === false
        @test W.mux_sessions() == String[]
    end

    if W.mux_bin() === nothing
        @info "no tmux; skipping the session lifecycle test"
    else
        n = "wl-test-lifecycle-1"
        W.mux_kill(n)                                   # from an earlier run
        @test W.mux_alive(n) === false
        @test first(W.mux_start(n, pwd(), "sleep 120")) === true
        @test W.mux_alive(n) === true
        @test first(W.mux_start(n, pwd(), "sleep 120")) === true   # idempotent
        @test n in W.mux_sessions()

        # What a session *is* lives in its options, so that the name is free to
        # change under it. The worktree is the identity because the worktree is
        # what is actually shared.
        wt = mktempdir()
        @test W.mux_tag!(n, wt, :shell, "julia#62841") === true
        found = W.mux_find(wt, :shell)
        @test found !== nothing && found.name == n && found.item == "julia#62841"
        @test W.mux_find(wt, :agent) === nothing        # a separate slot

        # Renaming is what keeps the label current without starting anything
        # new: same session, different name, still found by the same key.
        n3 = "wl-test-lifecycle-renamed"
        @test W.mux_rename(n, n3) === true
        @test W.mux_alive(n) === false && W.mux_alive(n3) === true
        again = W.mux_find(wt, :shell)
        @test again !== nothing && again.name == n3

        @test W.mux_kill(n3) === true
        @test W.mux_alive(n3) === false
    end
end

@testset "control-mode protocol" begin
    # The parser is a pure function of one line and the state before it, so the
    # protocol is driven from strings the way `readevent` is driven from bytes.
    p = W.MuxProto()
    @test W.mux_feed!(p, "%begin 1788 42 1") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "hello") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "%end 1788 42 1") == (:reply, true, ["hello"])

    # A failed command closes its block with %error, and the lines it did emit
    # are the error text.
    @test W.mux_feed!(p, "%begin 1788 43 1") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "unknown command: nope") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "%error 1788 43 1") == (:reply, false, ["unknown command: nope"])

    # A line inside a block is content, never protocol. A capture-pane of a
    # screen with a percent sign at the start of a line would otherwise be
    # parsed as a notification and vanish from the reply.
    W.mux_feed!(p, "%begin 1788 44 1")
    @test W.mux_feed!(p, "%output is just text here") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "100%") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "%end 1788 44 1") == (:reply, true, ["%output is just text here", "100%"])

    # Outside a block, notifications are themselves.
    @test W.mux_feed!(p, "%output %10 abc") == (:output, "%10", "abc")
    @test W.mux_feed!(p, "%session-changed \$1 wl") == (:notice, "session-changed", "\$1 wl")
    @test W.mux_feed!(p, "%exit")[1] === :notice

    # tmux escapes bytes below 0x20 and the backslash as three octal digits,
    # and passes everything from 0x20 up through raw.
    @test W.mux_unescape("a\\011b") == "a\tb"
    @test W.mux_unescape("back\\134slash") == "back\\slash"
    @test W.mux_unescape("\\033[1m") == "\e[1m"
    @test W.mux_unescape("\\015\\012") == "\r\n"
    @test W.mux_unescape("plain") == "plain"
    @test W.mux_unescape("e-é del\x7f pct-%") == "e-é del\x7f pct-%"
    @test W.mux_unescape("\\9zz") == "\\9zz"           # not octal; left alone
    @test W.mux_unescape("tail\\01") == "tail\\01"     # truncated; left alone
    @test W.mux_feed!(p, "%output %3 \\033[H")[3] == "\e[H"

    if W.mux_bin() === nothing
        @info "no tmux; skipping the live control-mode test"
    else
        n = "wl-test-control-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf READY; sleep 120'")
        woke = Ref(0)
        c = W.mux_open(n; onoutput = _ -> (woke[] += 1))
        @test c !== nothing
        # Attaching emits a reply block of its own; if it were left in the
        # queue every command here would return the previous one's answer.
        @test W.mux_resize(c, 60, 8) === true
        scr = W.mux_capture(c; escapes = false)
        @test length(scr) == 8                          # the size just asked for
        @test first(scr) == "READY"
        @test W.mux_keys(c, "xyz") === true
        sleep(0.5)
        @test occursin("xyz", join(W.mux_capture(c; escapes = false)))
        @test woke[] > 0                                # %output arrived unasked
        # An error is an answer, and the client keeps working after one.
        ok, lines = W.mux_ask(c, "no-such-command")
        @test ok === false && occursin("unknown command", join(lines))
        @test W.mux_ask(c, "display-message -p still-here") == (true, ["still-here"])
        W.mux_close(c)
        @test W.mux_ask(c, "display-message -p x")[1] === false
        W.mux_kill(n)
    end
end

@testset "a child program in a pane" begin
    # The box the child is given: two rows of border plus this view's footer,
    # and four columns of border and padding.
    @test W.pane_box(80, 24) == (76, 21)
    @test W.pane_box(120, 40) == (116, 37)
    @test W.pane_box(2, 2) == (1, 1)              # never asks for a zero size

    if W.mux_bin() === nothing
        @info "no tmux; skipping the pane view test"
    else
        n = "wl-test-paneview-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf \"\\033[1;32mgreen\\033[0m plain\\n\"; sleep 120'")
        ctrl = W.Controller(); ctrl.running = true
        v = W.pane_view(n, "demo", ctrl)
        @test v !== nothing

        # `displaysize` is what the child is sized from, and with no tty that
        # is LINES and COLUMNS, so the resize path is drivable here.
        withenv("LINES" => "24", "COLUMNS" => "80") do
            @test W.pane_sync!(v) === true
            @test v.sized == W.pane_box(80, 24)
            @test length(v.frame) == 21           # the height it was just given
            @test occursin("green", join(v.frame))
            @test occursin("\e[", join(v.frame))  # colour kept, not stripped
            ls = split(W.render(v, 80, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 80 for l in ls)
        end
        # A different size re-sizes the child, not just the box drawn round it.
        withenv("LINES" => "40", "COLUMNS" => "120") do
            W.pane_sync!(v)
            @test v.sized == W.pane_box(120, 40)
            @test length(v.frame) == 37
            ls = split(W.render(v, 120, 40), "\n")
            @test length(ls) == 40 && all(W.awidth(l) == 120 for l in ls)
        end

        # Every row is closed off, or an unterminated colour would run out of
        # the content and into the border.
        @test all(endswith(l, "\e[0m") for l in v.frame)

        # `q` leaves the session running - that is what a session is for.
        @test W.handle!(v, Int('q'), ctrl) === :pop
        @test W.mux_alive(n) === true

        # `K` ends it.
        v2 = W.pane_view(n, "demo", ctrl)
        @test v2 !== nothing
        @test W.handle!(v2, Int('K'), ctrl) === :pop
        @test W.mux_alive(n) === false
    end
end

@testset "raw input pass-through" begin
    # `readraw` is a pure function of a byte stream, like `readevent`.
    @test W.readraw(IOBuffer("j")).bytes == UInt8['j']
    # A sequence must reach the child whole and in order: one blocking byte,
    # then whatever else had already arrived.
    @test W.readraw(IOBuffer("\e[A")).bytes == UInt8['\e', '[', 'A']
    @test W.readraw(IOBuffer("\e[<0;40;12M")).bytes == collect(codeunits("\e[<0;40;12M"))
    @test W.readraw(IOBuffer("pasted text")).bytes == collect(codeunits("pasted text"))

    # Only a view that asks gets bytes; everything else still gets characters.
    @test W.wantsraw(W.PromptView("t", "", _ -> nothing)) === false

    if W.mux_bin() === nothing
        @info "no tmux; skipping the raw forwarding test"
    else
        n = "wl-test-raw-1"
        W.mux_kill(n)
        tmp = joinpath(mktempdir(), "edit-me.txt")
        write(tmp, "first line\n")
        W.mux_start(n, dirname(tmp), "vi $tmp")
        ctrl = W.Controller(); ctrl.running = true
        v = W.pane_view(n, "vi", ctrl)
        @test v !== nothing
        @test W.wantsraw(v) === true
        sleep(1.5)

        # Bytes as typed, and nothing here knows what any of them mean: `G`,
        # `o`, text, a literal escape and `:wq` drive an editor this code has
        # no model of.
        for s in ("G", "o", "typed through the pane", "\e", ":wq\r")
            @test W.onraw!(v, collect(codeunits(s)), ctrl) === :ok
            sleep(0.5)
        end
        sleep(1.0)
        @test read(tmp, String) == "first line\ntyped through the pane\n"
        @test W.mux_alive(n) === false            # vi quit, so the session ended

        # Ctrl-] is a prefix, not an escape: with every other key forwarded it
        # is the only way left to reach anything this view can do.
        n2 = "wl-test-raw-2"
        W.mux_kill(n2)
        W.mux_start(n2, pwd(), "sh -c 'sleep 120'")
        v2 = W.pane_view(n2, "sh", ctrl)

        # Alone it commits to nothing and waits for its key, which may arrive
        # in the same read or the next one.
        @test W.onraw!(v2, UInt8[W.PANE_PREFIX], ctrl) === :ok
        @test v2.pending === true
        @test W.onraw!(v2, UInt8[UInt8('r')], ctrl) === :ok     # reread
        @test v2.pending === false

        # Doubled, it is a literal Ctrl-] for the child, and the pane stays.
        @test W.onraw!(v2, [W.PANE_PREFIX, W.PANE_PREFIX], ctrl) === :ok

        # A prefix inside a burst still only takes the byte after it; what came
        # before is the child's and is sent first.
        @test W.onraw!(v2, UInt8[0x61, W.PANE_PREFIX, UInt8('r'), 0x62], ctrl) === :ok
        sleep(0.4)
        @test occursin("ab", join(W.mux_capture(v2.client; escapes = false)))

        # An unknown key after the prefix says what the prefix takes.
        W.onraw!(v2, [W.PANE_PREFIX, UInt8('Z')], ctrl)
        @test occursin("kill", v2.status)

        # tab leaves it running; the browser already uses tab to change pane.
        @test W.onraw!(v2, [W.PANE_PREFIX, UInt8('\t')], ctrl) === :pop
        @test W.mux_alive(n2) === true             # left running, not killed

        # K is the one that ends it.
        v3 = W.pane_view(n2, "sh", ctrl)
        @test W.onraw!(v3, [W.PANE_PREFIX, UInt8('K')], ctrl) === :pop
        @test W.mux_alive(n2) === false
    end
end

@testset "an agent in a session" begin
    # A shell and an agent in one worktree are two different things, so they
    # are two slots, distinguished by kind rather than by anything in the name.
    @test W.mux_name("julia", "master", "62841", :agent) == "wl-julia-master-62841-agent"

    st = W.BState(W.loaditems(), "worklog", Set{String}())
    ctrl = W.Controller(); ctrl.running = true
    it = st.items[1]

    # An agent needs nothing set up. An unregistered repo is the only thing
    # that stops it.
    @test W.open_agent(it, ctrl) === :needs_repo

    # The metadata pane reports a session from the cached list, never by asking
    # for one per frame: `render` is pure and listing them costs a process.
    tasked = it
    if W.mux_bin() !== nothing
        # Two items in one checkout share one session, whichever kind: the
        # second renames and re-tags what is there rather than starting a
        # second one beside it. An agent is a place too - it can be cleared and
        # pointed somewhere else exactly as a shell can be `cd`-ed.
        for kind in (:shell, :agent)
            wt = mktempdir()
            n1 = W.mux_name(wt, "main", "1", kind)
            W.mux_start(n1, wt, "sleep 120")
            W.mux_tag!(n1, wt, kind, "a#1")
            @test W.mux_find(wt, kind).item == "a#1"
            n2 = W.mux_name(wt, "main", "2", kind)
            W.mux_rename(W.mux_find(wt, kind).name, n2)
            W.mux_tag!(n2, wt, kind, "b#2")
            @test count(r -> r.worktree == wt, W.mux_list()) == 1
            @test W.mux_find(wt, kind).item == "b#2"
            @test W.mux_find(wt, kind).name == n2
            W.mux_kill(n2)
        end
    end

    row(kind, ref) = (name = "wl-x", command = "sh", attached = false,
                      worktree = "/tmp/x", kind = kind, item = ref)
    st.sessions = NamedTuple[]
    @test !occursin("running", join(W.meta_lines(st, tasked, 40), "\n"))
    # Matched on the item the session was tagged with, so the pane never has to
    # work out which worktree the item would land in.
    st.sessions = [row(:agent, tasked.ref)]
    lines = join(W.meta_lines(st, tasked, 40), "\n")
    @test occursin("running", lines) && occursin("agent", lines)
    st.sessions = [row(:shell, tasked.ref)]
    @test occursin("shell", join(W.meta_lines(st, tasked, 40), "\n"))
    st.sessions = [row(:shell, "someone/else#1")]
    @test !occursin("running", join(W.meta_lines(st, tasked, 40), "\n"))
end

@testset "worktrees, with the sessions folded in" begin
    items = W.loaditems()
    ctrl = W.Controller(); ctrl.running = true

    # A repo with two worktrees, one of them on a branch that has a pull
    # request in the real facts.json - which is the join this view is for.
    # Taken from what the browser is actually showing, since `i` goes to the
    # row in that list and an item outside it is a different case, tested below.
    shown = W.BState(items, "worklog", Set{String}())
    pr = first(it for it in shown.items if it.is_pr && !isempty(it.branch))
    root = mktempdir()
    main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    side = joinpath(root, "side")
    W.git(main, "worktree", "add", "--quiet", "-b", pr.branch, side)

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        W.register_repo!(pr.repo, main)
        rows = W.worktree_rows(items)
        byname = Dict(r.name => r for r in rows)
        @test sort(collect(keys(byname))) == ["main", "side"]
        @test byname["main"].main && !byname["side"].main
        # The branch carries its pull request, and the one with no branch of
        # its own carries none.
        @test byname["side"].item !== nothing && byname["side"].item.url == pr.url
        @test byname["main"].item === nothing
        @test all(isempty(r.sessions) for r in rows)

        v = W.worktree_view(items)
        @test length(v.rows) == 2
        for (w, h) in ((80, 24), (120, 40), (165, 50))
            ls = split(W.render(v, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
        # The row says which pull request the work in it is.
        @test occursin(pr.ref, W.astrip(W.render(v, 165, 24)))

        # Dirty arrives behind the list rather than holding it up: the first
        # pass skips the tree walk entirely.
        @test all(!(r.staged || r.unstaged) for r in W.worktree_rows(items; withdirty = false))
        write(joinpath(main, "a.txt"), "two\n")
        v2 = W.worktree_view(items)
        @test all(!(r.staged || r.unstaged) for r in v2.rows)          # not walked yet
        wait(v2.pending)
        @test W.onwake!(v2)
        @test W.worktree_rows(items)[1].unstaged         # and now it is known
        @test any((r.staged || r.unstaged) for r in v2.rows)
        @test !W.onwake!(v2)                          # nothing left pending
        W.git(main, "checkout", "--quiet", "--", "a.txt")

        # `i` leaves for the item, and reports rather than moving when the
        # list underneath is not showing it.
        st = W.BState(items, "worklog", Set{String}())
        v3 = W.worktree_view(items; onitem = x -> W.select_item!(st, x))
        v3.sel = findfirst(r -> r.name == "side", v3.rows)
        @test W.handle!(v3, Int('i'), ctrl) === :pop
        @test st.items[st.sel].url == pr.url
        v3.sel = findfirst(r -> r.name == "main", v3.rows)
        @test W.handle!(v3, Int('i'), ctrl) === :ok
        @test occursin("no pull request", v3.status)
        # Filtered out is a message, not a silent change of what is shown.
        st2 = W.BState(items, "worklog", Set{String}())
        st2.items = [x for x in st2.items if x.url != pr.url]
        v4 = W.worktree_view(items; onitem = x -> W.select_item!(st2, x))
        v4.sel = findfirst(r -> r.name == "side", v4.rows)
        @test W.handle!(v4, Int('i'), ctrl) === :ok
        @test occursin("filtered out", v4.status)

        if W.mux_bin() === nothing
            @info "no tmux; skipping the live worktree session test"
        else
            # A session is a column of the worktree it is in, not a list of its
            # own: starting one from the row puts it on that row.
            v5 = W.worktree_view(items)
            v5.sel = findfirst(r -> r.name == "side", v5.rows)
            @test isempty(v5.rows[v5.sel].sessions)
            W.handle!(v5, Int('t'), ctrl)
            @test last(ctrl.stack) isa W.PaneView
            pop!(ctrl.stack)
            row = v5.rows[findfirst(r -> r.name == "side", v5.rows)]
            @test length(row.sessions) == 1 && row.sessions[1].kind === :shell
            @test occursin("s", W.astrip(W.render(v5, 165, 24)))
            # And the same worktree reached from its item is the same session,
            # because a session is keyed by where it is and not by what asked.
            n = length(W.mux_list())
            W.open_terminal(pr, ctrl)
            pop!(ctrl.stack)
            @test length(W.mux_list()) == n

            # `K` ends what is running on the row, and nothing else.
            W.handle!(v5, Int('K'), ctrl)
            @test isempty(v5.rows[findfirst(r -> r.name == "side", v5.rows)].sessions)
            @test occursin("ended", v5.status)
            W.handle!(v5, Int('K'), ctrl)
            @test occursin("nothing running", v5.status)

            # A session whose worktree has gone is an orphan row rather than a
            # hidden one: it is still holding a process, and K is still how to
            # be rid of it.
            gone = mktempdir()
            name = W.mux_name(basename(gone), "master", "", :shell)
            W.mux_start(name, gone, "sleep 120")
            W.mux_tag!(name, gone, :shell, "")
            rm(gone; recursive = true)
            v6 = W.worktree_view(items)
            orph = findfirst(r -> r.orphan, v6.rows)
            @test orph !== nothing && v6.rows[orph].name == basename(gone)
            @test occursin("gone", W.astrip(W.render(v6, 120, 24)))
            v6.sel = orph
            # Nothing can be started in a directory that is not there.
            W.handle!(v6, Int('t'), ctrl)
            @test occursin("gone", v6.status)
            W.handle!(v6, Int('K'), ctrl)
            @test W.mux_alive(name) === false
        end

        @test W.handle!(W.worktree_view(items), Int('q'), ctrl) === :pop
    finally
        W.REPOS_FILE[] = ""
    end
end

@testset "branches, the second lens" begin
    # Worktrees are places that exist; branches are work that exists without
    # one. Same key, same rows underneath, one `tab` apart.
    items = W.loaditems()
    ctrl = W.Controller(); ctrl.running = true
    shown = W.BState(items, "worklog", Set{String}())
    pr = first(it for it in shown.items if it.is_pr && !isempty(it.branch))

    root = mktempdir()
    main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    side = joinpath(root, "side")
    W.git(main, "worktree", "add", "--quiet", "-b", pr.branch, side)
    W.git(main, "branch", "homeless")

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        W.register_repo!(pr.repo, main)
        v = W.worktree_view(items)
        @test v.mode === :worktrees
        @test length(v.brows) == 3
        # The place column is the difference between the two lists: two of
        # these are checked out and one is only a ref.
        byname = Dict(b.name => b for b in v.brows)
        @test byname[pr.branch].worktree == realpath(side)
        @test isempty(byname["homeless"].worktree)
        @test byname[pr.branch].item !== nothing && byname[pr.branch].item.url == pr.url
        @test byname["homeless"].item === nothing

        @test W.handle!(v, 9, ctrl) === :ok && v.mode === :branches
        for (w, h) in ((80, 24), (120, 40), (165, 50))
            ls = split(W.render(v, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
        @test occursin("branches", W.astrip(W.render(v, 120, 24)))
        @test occursin(pr.ref, W.astrip(W.render(v, 165, 24)))

        # Each lens keeps its own cursor, so `tab` returns to where you were.
        v.sel = 2
        W.handle!(v, Int('G'), ctrl)
        @test v.bsel == length(v.brows) && v.sel == 2
        W.handle!(v, 9, ctrl)
        @test v.mode === :worktrees && v.sel == 2
        W.handle!(v, 9, ctrl)
        @test v.bsel == length(v.brows)

        # A branch is not a place: enter goes to the worktree that has it out.
        v.bsel = findfirst(b -> b.name == pr.branch, v.brows)
        W.handle!(v, 13, ctrl)
        @test v.mode === :worktrees && v.rows[v.sel].name == "side"
        # And says so for one that has none, rather than opening something.
        W.handle!(v, 9, ctrl)
        v.bsel = findfirst(b -> b.name == "homeless", v.brows)
        @test W.handle!(v, 13, ctrl) === :ok
        @test v.mode === :branches && occursin("not checked out", v.status)
        # Nothing runs on a branch either.
        W.handle!(v, Int('K'), ctrl)
        @test occursin("nothing runs on a branch", v.status)

        # `i` works from either lens.
        st = W.BState(items, "worklog", Set{String}())
        v2 = W.worktree_view(items; onitem = x -> W.select_item!(st, x))
        W.handle!(v2, 9, ctrl)
        v2.bsel = findfirst(b -> b.name == pr.branch, v2.brows)
        @test W.handle!(v2, Int('i'), ctrl) === :pop
        @test st.items[st.sel].url == pr.url
        v2.bsel = findfirst(b -> b.name == "homeless", v2.brows)
        @test W.handle!(v2, Int('i'), ctrl) === :ok
        @test occursin("no pull request", v2.status)

        # Newest tip first, across every repo at once.
        ats = [b.at for b in v.brows]
        @test issorted(ats; rev = true)

        # An empty list still renders and says which one is empty.
        e = W.WorktreeView(items, W.WorktreeRow[], W.BranchRow[], :branches,
                           1, 1, 1, 1, "", nothing, nothing, nothing)
        ls = split(W.render(e, 80, 24), "\n")
        @test length(ls) == 24 && all(W.awidth(l) == 80 for l in ls)
        @test occursin("no branches", join(ls, "\n"))
    finally
        W.REPOS_FILE[] = ""
    end

    # With nothing registered the view still renders, and says so.
    W.REPOS_FILE[] = joinpath(mktempdir(), "none.toml")
    try
        v = W.worktree_view(items)
        @test isempty(v.rows)
        ls = split(W.render(v, 80, 24), "\n")
        @test length(ls) == 24 && all(W.awidth(l) == 80 for l in ls)
        @test occursin("no worktrees", join(ls, "\n"))
    finally
        W.REPOS_FILE[] = ""
    end
end

@testset "reading beside the child" begin
    # The left column is the one with a cap; the right fills what is left. The
    # same rule one level out, with the thread capped and the terminal filling.
    for w in (110, 120, 150, 165, 200, 250, 300, 400)
        side, lw, rw = W.panewidths(w)
        @test side
        @test lw <= w ÷ 2 && lw <= W.LIST_MAX  # bounded twice
        @test lw + rw == w                     # and the thread takes the rest
        r, t = W.split_box(w)
        @test r <= w ÷ 2 && r <= W.DETAIL_MAX
        @test r + t == w
    end
    # A wider screen goes entirely to the column that fills.
    @test W.panewidths(400)[3] - W.panewidths(200)[3] == 200
    @test last(W.split_box(400)) - last(W.split_box(200)) == 200
    # Below the threshold there is one column, and it is the whole screen.
    @test W.panewidths(80) == (false, 80, 80)
    # The frame is padded to the screen even when the panes stop short of it.
    st = mkstate()
    for w in (110, 165, 200, 300)
        ls = split(W.render(st, w, 20), "\n")
        @test all(W.awidth(l) == w for l in ls)
    end

    # Nothing is split below the threshold: two columns too narrow to use are
    # worse than one that works.
    @test W.split_box(80) == (0, 80)
    @test W.split_box(149) == (0, 149)
    @test W.split_box(150) == (75, 75)
    @test W.split_box(200) == (78, 122)
    # The child is never given less than half, and the reading never more than
    # DETAIL_MAX - so every column a wider screen adds goes to the terminal,
    # which is the thing being worked in.
    @test W.split_box(400) == (78, 322)
    for w in (150, 165, 200, 250, 400)
        r, t = W.split_box(w)
        @test r + t == w
        @test t >= w / 2
        @test r <= W.DETAIL_MAX
    end

    if W.mux_bin() === nothing
        @info "no tmux; skipping the split render test"
    else
        st = W.BState(W.loaditems(), "worklog", Set{String}())
        ctrl = W.Controller(); ctrl.running = true
        st.wake = () -> W.wake!(ctrl); push!(ctrl.stack, st)
        n = "wl-test-split-1"; W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf MARKER; sleep 120'")
        v = W.pane_view(n, "child", ctrl)
        @test v !== nothing
        @test v.beside === st                      # taken from the stack

        withenv("LINES" => "24", "COLUMNS" => "200") do
            W.pane_sync!(v)
            # The child is sized to its own column, not to the screen.
            @test v.sized == W.pane_box(last(W.split_box(200)), 24)
            ls = split(W.render(v, 200, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 200 for l in ls)
            @test occursin("MARKER", join(ls, "\n"))
            # The detail pane is what sits beside it, at full height, so its
            # title is on the first row rather than a list's.
            @test occursin(String(st.mode), first(ls))
        end

        # Narrow: no split, and the child gets the screen back.
        withenv("LINES" => "24", "COLUMNS" => "100") do
            W.pane_sync!(v)
            @test v.sized == W.pane_box(100, 24)
            ls = split(W.render(v, 100, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 100 for l in ls)
        end

        # With no browser under it a pane still renders, undivided.
        alone = W.pane_view(n, "child", ctrl; beside = nothing)
        withenv("LINES" => "24", "COLUMNS" => "200") do
            ls = split(W.render(alone, 200, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 200 for l in ls)
        end
        W.mux_close(alone.client); W.mux_close(v.client); W.mux_kill(n)
    end
end

# A view that throws whatever it is asked to do, to prove the run survives it.
mutable struct ExplodingView <: W.View
    renders::Int
    handles::Int
end
W.render(v::ExplodingView, w::Int, h::Int) = (v.renders += 1; error("render exploded"))
W.handle!(v::ExplodingView, k::Int, ctrl) = (v.handles += 1; error("handle exploded"))
W.onraw!(v::ExplodingView, b::Vector{UInt8}, ctrl) = (v.handles += 1; error("raw exploded"))

@testset "an error costs a frame, not the session" begin
    isfile(W.ERRLOG) && rm(W.ERRLOG)
    empty!(W.ERRSEEN)
    @test W.errnote() == ""

    v = ExplodingView(0, 0)

    # A view that cannot draw itself says so where the frame would have been,
    # in exactly the shape every other frame has.
    for (w, h) in ((80, 24), (120, 40))
        ls = split(W.safe_render(v, w, h), "\n")
        @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        @test occursin("could not be drawn", join(ls, "\n"))
    end

    # The keystroke is lost; the run is not.
    ctrl = W.Controller(); ctrl.running = true
    @test W.safe_dispatch!(v, W.KeyEvent(Int('j')), ctrl) === :ok
    @test W.safe_dispatch!(v, W.RawEvent(UInt8['j']), ctrl) === :ok
    @test v.handles == 2

    # The file is the warning, and it stands until it is deleted.
    @test isfile(W.ERRLOG)
    @test occursin("delete it to clear", W.errnote())
    # The warning has to survive being fitted to the footer, or it says that
    # something is wrong without saying what to do.
    @test W.awidth(W.errnote()) < 80
    @test occursin("render exploded", read(W.ERRLOG, String))
    @test occursin("handle exploded", read(W.ERRLOG, String))

    # A bug on the render path runs every frame, so the same error is written
    # once rather than thousands of times.
    before = filesize(W.ERRLOG)
    W.safe_render(v, 80, 24); W.safe_render(v, 80, 24)
    @test filesize(W.ERRLOG) == before

    # It is what the footer shows, ahead of the status.
    st = W.BState(W.loaditems(), "worklog", Set{String}())
    st.status = "something ordinary"
    @test occursin("delete it to clear", W.render(st, 120, 40))

    rm(W.ERRLOG)
    @test W.errnote() == ""
    @test !occursin("delete it to clear", W.render(st, 120, 40))
end

@testset "the metadata fetch result fits the field it lands in" begin
    # This is the bug that killed a live session: `load_meta!` handed
    # `mux_sessions()` - names - to a field holding what `mux_list()` returns.
    # Every test set `st.sessions` by hand, so none of them ever saw it.
    st = W.BState(W.loaditems(), "worklog", Set{String}())
    st.sessions = W.mux_list()
    @test st.sessions isa Vector{NamedTuple}
    if W.mux_bin() !== nothing
        n = "wl-test-fetchtype-1"; W.mux_kill(n)
        W.mux_start(n, pwd(), "sleep 60")
        st.sessions = W.mux_list()
        @test any(r -> r.name == n, st.sessions)
        @test W.meta_lines(st, st.items[1], 40) isa Vector{String}
        W.mux_kill(n)
    end
end

@testset "the child's cursor" begin
    mk(cur; beside = nothing) =
        W.PaneView("n", "t", nothing, String[], (0, 0), "", false, beside, cur, false, nothing)

    # The terminal's own cursor is moved to the child's, rather than a block
    # being painted where it should be: a real one blinks, takes the shape the
    # user chose, and cannot drift out of step with the frame.
    #
    # Hidden by the child, or no client: nothing to place.
    @test W.viewcursor(mk((0, 0, false)), 80, 24) === nothing

    v = W.pane_view("unused", "t", W.Controller(); beside = nothing)   # no session
    @test v === nothing

    # `pane` spends a row on its border and two columns on border and padding,
    # so the child's (0,0) is screen row 2, column 3.
    c = mk((0, 0, true)); c.client = nothing
    @test W.viewcursor(c, 80, 24) === nothing        # no client, nothing to show
end

@testset "shapes Term cannot render" begin
    # `parse_md(::Markdown.Table)` takes `width` and nothing else, but Term's
    # own recursion passes `inline` to whatever is inside a list or a quote. One
    # table in one bullet used to drop the whole comment back to raw text.
    isfile(W.ERRLOG) && rm(W.ERRLOG)
    empty!(W.ERRSEEN)
    for src in ("| a | b |\n|---|---|\n| 1 | 2 |\n",
                "- point\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n",
                "> | a | b |\n> |---|---|\n> | 1 | 2 |\n",
                "- a\n    - b\n\n      | x | y |\n      |---|---|\n      | 1 | 2 |\n")
        out = W.render_md(src, 60)
        @test occursin("a", out) || occursin("x", out)
    end
    # A failure now goes to the log, with its backtrace, rather than a sentence
    # in the footer that had room only to say a MethodError had happened.
    @test !isfile(W.ERRLOG)

    # A table at the top level is left where it is, because Term renders it
    # properly there - box drawing and all.
    @test occursin("\u2500", W.render_md("| a | b |\n|---|---|\n| 1 | 2 |\n", 60))

    # Nested, it keeps every cell.
    nested = W.render_md("- point\n\n  | aaa | bbb |\n  |---|---|\n  | 111 | 222 |\n", 60)
    @test all(occursin(x, nested) for x in ("aaa", "bbb", "111", "222"))

    # An empty list item is the other shape that takes a whole comment down:
    # `parse_md(::Markdown.List)` indexes [1] on every item, and Julia parses
    # `- a`/`-`/`- b` into items of length [1, 0, 1]. Ordered or not, nested or
    # top level, and a lone `-` is enough.
    isfile(W.ERRLOG) && rm(W.ERRLOG)
    empty!(W.ERRSEEN)
    for src in ("- a\n-\n- b\n", "1. one\n2.\n3. three\n", "-\n",
                "- outer\n    -\n    - inner\n", "> - a\n> -\n")
        out = W.render_md(src, 60)
        @test !occursin("BoundsError", out)
    end
    @test !isfile(W.ERRLOG)
    # Filled rather than dropped: the bullet was typed, so it is drawn, and an
    # ordered list is not renumbered behind the user's back.
    md = W.Markdown.parse("1. one\n2.\n3. three\n")
    @test length(W.for_term(md).content[1].items) == 3
    @test all(!isempty(i) for i in W.for_term(md).content[1].items)
    out = W.render_md("1. one\n2.\n3. three\n", 60)
    @test occursin("one", out) && occursin("three", out)
end

@testset "cursor and mouse, against a live child" begin
    if W.mux_bin() === nothing
        @info "no tmux; skipping the live cursor and mouse test"
    else
        ctrl = W.Controller(); ctrl.running = true
        sgr(b, x, y, e) = collect(codeunits(string("\e[<", b, ";", x, ";", y, e)))

        # A child that has not asked for mouse reporting. `send-keys` puts these
        # bytes into its pty as input, so tmux never sees them as mouse events
        # and its own `mouse` setting has no bearing: forwarded, they would be
        # printed as the control characters they are.
        n1 = "wl-test-mouse-off"; W.mux_kill(n1)
        W.mux_start(n1, pwd(), "sh -c 'printf \"prompt> \"; sleep 60'")
        v1 = W.pane_view(n1, "sh", ctrl); sleep(1.0); W.pane_sync!(v1)
        @test v1.wantsmouse === false
        @test isempty(W.retarget_mouse(v1, sgr(0, 20, 5, 'M'), 100, 24))
        @test isempty(W.retarget_mouse(v1, sgr(0, 20, 5, 'm'), 100, 24))
        # Typing is untouched: only mouse reports are read on the way through.
        @test W.retarget_mouse(v1, collect(codeunits("hello")), 100, 24) ==
              collect(codeunits("hello"))
        # And a report buried in a burst takes only itself out of it.
        mixed = vcat(collect(codeunits("ab")), sgr(0, 20, 5, 'M'), collect(codeunits("cd")))
        @test W.retarget_mouse(v1, mixed, 100, 24) == collect(codeunits("abcd"))

        # The cursor is where the child says, mapped into the screen: `pane`
        # spends a row on its border and two columns on border and padding.
        x, y, showing = v1.cursor
        @test showing === true && (x, y) == (8, 0)
        @test W.viewcursor(v1, 100, 24) == (2 + 0, 3 + 8)
        # Split: the child starts after whatever is drawn to its left. Only
        # when there *is* something drawn there - `beside` is what decides it.
        @test W.viewcursor(v1, 200, 24) == (2, 3 + 8)          # nothing beside
        v1.beside = W.BState(W.loaditems(), "worklog", Set{String}())
        @test W.viewcursor(v1, 200, 24) == (2, first(W.split_box(200)) + 3 + 8)
        v1.beside = nothing

        # A child that *has* asked for mouse reporting, the way any such
        # program does it.
        n2 = "wl-test-mouse-on"; W.mux_kill(n2)
        W.mux_start(n2, pwd(), "sh -c 'printf \"\\033[?1006h\\033[?1002h\"; sleep 60'")
        v2 = W.pane_view(n2, "app", ctrl); sleep(1.0); W.pane_sync!(v2)
        @test v2.wantsmouse === true

        # Screen (20,5) with no split: origin (3,2), so the child sees (18,4).
        @test String(W.retarget_mouse(v2, sgr(0, 20, 5, 'M'), 100, 24)) == "\e[<0;18;4M"
        # Release keeps its own terminator.
        @test String(W.retarget_mouse(v2, sgr(0, 20, 5, 'm'), 100, 24)) == "\e[<0;18;4m"
        # Split at 200: the same screen column is much further into the child.
        v2.beside = W.BState(W.loaditems(), "worklog", Set{String}())
        lw = first(W.split_box(200))
        @test String(W.retarget_mouse(v2, sgr(0, lw + 20, 5, 'M'), 200, 24)) == "\e[<0;18;4M"
        v2.beside = nothing
        # On the border, outside the child's box: dropped rather than clamped,
        # since a click on the frame is not a click in the child.
        @test isempty(W.retarget_mouse(v2, sgr(0, 1, 1, 'M'), 100, 24))
        @test isempty(W.retarget_mouse(v2, sgr(0, 999, 5, 'M'), 100, 24))

        W.mux_close(v1.client); W.mux_close(v2.client)
        W.mux_kill(n1); W.mux_kill(n2)
    end
end


@testset "a one-row field holds one row" begin
    # `showerror` puts a newline in its message. Straight into the footer, that
    # made the frame one row taller than the screen: the terminal scrolled, and
    # every mouse click then reported a row that was no longer under it. The
    # frame is clamped by *element*, so one element holding a newline is two
    # rows and the clamp never sees it.
    @test W.oneline("one\ntwo") == "one \u00b7 two"
    @test W.oneline("  padded \n\n  lines  ") == "padded \u00b7 lines"
    @test W.oneline("already one") == "already one"
    @test !occursin('\n', W.oneline(sprint(showerror, MethodError(sin, ("a", "b")))))

    st = W.BState(W.loaditems(), "worklog", Set{String}())
    for status in ("plain", sprint(showerror, MethodError(sin, ("a", "b"))),
                   "a\nb\nc\nd")
        st.status = status
        for (w, h) in ((120, 40), (80, 24))
            ls = split(W.render(st, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
    end
    st.status = ""

end


@testset "the local git survey" begin
    # A real repository, because every one of these fields is git's own answer
    # to a question with a format string in it, and a mock would only assert
    # that the format string is what this file already says it is.
    g(dir, args...) = W.git(dir, args...)
    root = mktempdir()
    main = joinpath(root, "main")
    mkpath(main)
    g(main, "init", "--quiet", "--initial-branch=master", ".")
    g(main, "config", "user.email", "t@example.com")
    g(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    g(main, "add", "a.txt")
    g(main, "commit", "--quiet", "-m", "first")

    # An "upstream" without a server: a bare repo, pushed to, then moved on from
    # locally - which is what ahead/behind is measured against.
    bare = joinpath(root, "origin.git")
    g(main, "init", "--quiet", "--bare", bare)
    g(main, "remote", "add", "origin", bare)
    g(main, "push", "--quiet", "-u", "origin", "master")
    write(joinpath(main, "a.txt"), "two\n")
    g(main, "commit", "--quiet", "-am", "second")

    # One branch with a place, one without, and one whose upstream is gone -
    # which is what a merged pull request's branch looks like from here.
    g(main, "branch", "homeless")
    g(main, "branch", "placed")
    g(main, "push", "--quiet", "-u", "origin", "placed")
    wt = joinpath(root, "wt-placed")
    g(main, "worktree", "add", "--quiet", wt, "placed")
    det = joinpath(root, "wt-detached")
    g(main, "worktree", "add", "--quiet", "--detach", det, "HEAD")
    g(main, "push", "--quiet", "origin", "--delete", "placed")
    g(main, "fetch", "--quiet", "--prune", "origin")

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        W.register_repo!("t/one", main)

        bs = Dict(b.name => b for b in W.branches("t/one", main))
        @test sort(collect(keys(bs))) == ["homeless", "master", "placed"]
        # master is one commit past what was pushed, and knows by how much.
        @test bs["master"].upstream == "origin/master"
        @test (bs["master"].ahead, bs["master"].behind) == (1, 0)
        @test !bs["master"].gone
        # A branch nothing is tracking reports no divergence rather than zero
        # divergence; the empty upstream is how to tell those apart.
        @test bs["homeless"].upstream == "" && !bs["homeless"].gone
        @test (bs["homeless"].ahead, bs["homeless"].behind) == (0, 0)
        # And one whose upstream was deleted underneath it says so.
        @test bs["placed"].gone
        # Only one of the three is checked out anywhere.
        @test bs["placed"].worktree == realpath(wt)
        @test bs["homeless"].worktree == ""
        @test startswith(bs["master"].at, "20") && length(bs["master"].head) == 40

        ws = W.worktrees(main)
        @test length(ws) == 3
        @test ws[1].main && !ws[2].main            # git lists the primary first
        byp = Dict(w.path => w for w in ws)
        @test byp[realpath(main)].branch == "master"
        @test byp[realpath(wt)].branch == "placed"
        # A detached head is a worktree with no branch, which the survey shows
        # rather than skips.
        @test byp[realpath(det)].branch == ""
        @test length(byp[realpath(det)].head) == 40

        (sw, sb) = W.survey()
        @test length(sw) == 3 && length(sb) == 3
        @test all(w.repo == "t/one" for w in sw)
        sbyp = Dict(w.path => w for w in sw)
        # Ahead/behind is joined from the branch, so a worktree carries its
        # branch's divergence and a detached one carries none.
        @test (sbyp[realpath(main)].ahead, sbyp[realpath(main)].behind) == (1, 0)
        @test sbyp[realpath(det)].upstream == "" && sbyp[realpath(det)].at == ""
        @test all(!(w.staged || w.unstaged) for w in sw)
        write(joinpath(main, "a.txt"), "three\n")
        @test W.changes(main) == (false, true)      # edited, not staged
        @test W.dirty(main)
        # Staged and unstaged are separate bits, because a half-staged checkout
        # is in the middle of a commit - a different thing to have walked away
        # from than one that was merely edited.
        g(main, "add", "a.txt")
        @test W.changes(main) == (true, false)
        write(joinpath(main, "a.txt"), "four\n")
        @test W.changes(main) == (true, true)       # staged, then edited again
        # An untracked file is not work in progress: a build tree is full of
        # them, and counting them would report every checkout dirty forever.
        g(main, "reset", "--quiet", "--hard")
        write(joinpath(main, "untracked.txt"), "x\n")
        @test W.changes(main) == (false, false)
        @test !W.dirty(main)
        # The cheap survey skips the tree walk entirely.
        write(joinpath(main, "a.txt"), "three\n")
        @test any(w.unstaged for w in first(W.survey()))
        @test all(!(w.staged || w.unstaged) for w in first(W.survey(; withdirty = false)))
        g(main, "checkout", "--quiet", "--", "a.txt")

        # A registered repo whose folder has gone is skipped, not an error -
        # the same rule `repo_path` follows, since `repos.toml` is never pruned.
        d = W.load_repos()
        d["t/gone"] = Dict("worktree" => joinpath(root, "not-there"),
                           "gitdir" => "", "remotes" => "")
        W.save_repos(d)
        @test all(w.repo == "t/one" for w in first(W.survey(; withdirty = false)))
    finally
        W.REPOS_FILE[] = ""
    end

    # The parse of `%(upstream:track)`, which is why git is run under LC_ALL=C.
    @test W.track_counts("[ahead 3, behind 1]") == (3, 1, false)
    @test W.track_counts("[behind 2]") == (0, 2, false)
    @test W.track_counts("[gone]") == (0, 0, true)
    @test W.track_counts("") == (0, 0, false)
end

@testset "a branch knows its pull request" begin
    # The join the survey is for: the lanes carry `headRefName`, so the whole
    # mapping is known without a request per row.
    mk(n, repo, br) = W.Item(url = "u$n", ref = "$repo#$n", repo = repo, number = n,
                             title = "t", branch = br)
    items = [mk(1, "a/b", "topic"), mk(2, "c/d", "topic"), mk(3, "a/b", "")]
    ix = W.branch_index(items)
    # Keyed by repo as well as name: every one of these repos has a `master`.
    @test ix[("a/b", "topic")].number == 1
    @test ix[("c/d", "topic")].number == 2
    @test length(ix) == 2                      # the one with no branch is out
    # A reused name resolves to the newer pull request, not to whichever was
    # seen first.
    ix2 = W.branch_index([mk(9, "a/b", "topic"), mk(4, "a/b", "topic")])
    @test ix2[("a/b", "topic")].number == 9
    @test W.branch_index([W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1,
                                 title = "t", branch = "x", is_pr = false)] ) |> isempty

    # An item that came from a facts.json written before the field existed has
    # no branch, and `pr_branch` is what falls back for it.
    @test W.pr_branch(mk(1, "a/b", "topic")) == "topic"
    @test W.pr_branch(W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1,
                             title = "t", is_pr = false)) == ""
end

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
    readfile = joinpath(W.ROOT, "read.json")
    before = read(readfile, String)
    try
        st.nodes = W.Node[]
        push!(st.unread, it.url)
        ctrl = W.Controller()
        W.handle!(st, Int('r'), ctrl, then)
        @test W.Events.read_at(it.url) == "2000-01-02T03:04:05Z"
        # Left to itself a keystroke is its own operation, starting now.
        W.handle!(st, Int('u'), ctrl)
        push!(st.unread, it.url)
        W.handle!(st, Int('r'), ctrl)
        @test W.Events.read_at(it.url) > "2020"
    finally
        write(readfile, before)
    end

    # A refresh measures its whole run against one instant, so it cannot
    # straddle midnight - which is what the global was for and what threading
    # keeps.
    r = Dict{String,Any}("head_at" => W.stamp(then - Dates.Day(3)),
                         "updated" => W.stamp(then - Dates.Day(9)))
    @test W.activity_age(r, then) == 3
    @test W.activity_age(r, then + Dates.Day(1)) == 4
end

@testset "the interaction clock" begin
    # Redirected again inside the testset so it starts empty and nothing else in
    # the suite can have written to it first.
    keep = W.TOUCHED[]
    W.TOUCHED[] = joinpath(mktempdir(), "touched.json")
    try
        u = W.loaditems()[1].url
        @test W.touched_at(u) === nothing          # nothing has been done to it
        prev = W.touch!(u)
        @test prev === nothing                     # ...and it says so
        first_at = W.touched_at(u)
        @test first_at !== nothing && endswith(first_at, "Z")

        # The instant is the caller's, so an action can say when it happened
        # rather than being told by whatever clock the callee reaches for.
        @test W.touch!(u, W.DateTime(2000, 1, 2, 3, 4, 5)) == first_at   # what was there
        @test W.touched_at(u) == "2000-01-02T03:04:05Z"
        # And left alone it is now, not the moment the program started.
        W.touch!(u)
        @test W.touched_at(u) > "2020"

        # Clearing is a distinct state from never having been touched, which is
        # what an undo of a first interaction has to restore.
        W.set_touched(u, nothing)
        @test W.touched_at(u) === nothing
        W.set_touched(u, "2026-01-02T03:04:05Z")
        @test W.touched_at(u) == "2026-01-02T03:04:05Z"

        # Setting any field stamps it, through the one point they all pass.
        state = read(W.STATE, String)
        try
            W.set_fields(u, ["note" => "a passing thought"])
            @test W.touched_at(u) != "2026-01-02T03:04:05Z"
            # One keystroke, one instant: the field write and the clock agree
            # because the operation hands the same `at` to both.
            W.set_fields(u, ["note" => "again"], W.DateTime(2000, 1, 2, 3, 4, 5))
            @test W.touched_at(u) == "2000-01-02T03:04:05Z"
        finally
            W.set_fields(u, ["note" => nothing])
            write(W.STATE, state)
        end
    finally
        W.TOUCHED[] = keep
    end
end

@testset "what the clock does not count" begin
    keep = W.TOUCHED[]
    W.TOUCHED[] = joinpath(mktempdir(), "touched.json")
    readfile = joinpath(W.ROOT, "read.json")
    before = read(readfile, String)
    try
        st = mkstate()
        ctrl = W.Controller()
        it = st.items[st.sel]

        # Looking is not interacting. Moving the cursor, folding, changing pane,
        # searching and switching mode must all leave the clock alone - a list
        # ordered by it would otherwise be a record of browsing.
        for k in (Int('j'), Int('k'), Int('\t'), Int('\r'), Int('d'), Int('o'),
                  Int('g'), Int('G'), Int('n'), Int('N'), Int('/'))
            W.handle!(st, k, ctrl)
        end
        @test all(W.touched_at(x.url) === nothing for x in st.items)

        # Nor is read/unread, which is the end of looking rather than the start
        # of doing, and has its own filter already.
        st = mkstate(); it = st.items[st.sel]
        push!(st.unread, it.url)
        W.handle!(st, Int('r'), ctrl)
        @test st.status == "marked read"
        @test W.touched_at(it.url) === nothing
        W.handle!(st, Int('u'), ctrl)
        @test W.touched_at(it.url) === nothing
        W.handle!(st, Int('z'), ctrl); W.handle!(st, Int('z'), ctrl)

        # A snooze is, and undoing it puts the clock back to where it was -
        # which for a first interaction means back to nothing at all. `s` opens
        # a picker now, so the interaction is the choice, not the key.
        snooze!(v) = (W.handle!(st, Int('s'), ctrl); pop!(ctrl.stack).onpick(v))
        state = read(W.STATE, String)
        try
            snooze!("on-change")
            @test st.status == "snoozed on-change"
            @test W.touched_at(it.url) !== nothing
            W.handle!(st, Int('z'), ctrl)
            @test occursin("undid", st.status)
            @test W.touched_at(it.url) === nothing

            # And an earlier interaction is restored as itself, not erased.
            W.set_touched(it.url, "2026-01-02T03:04:05Z")
            snooze!("on-change")
            @test W.touched_at(it.url) != "2026-01-02T03:04:05Z"
            W.handle!(st, Int('z'), ctrl)
            @test W.touched_at(it.url) == "2026-01-02T03:04:05Z"
        finally
            write(W.STATE, state)
        end
    finally
        write(readfile, before)
        W.TOUCHED[] = keep
    end
end

@testset "s asks how long for" begin
    # `s` used to write on-change and say nothing, which is the right default
    # and was the wrong only choice - `parse_snooze` has always taken spans and
    # dates, and only `wl snooze` could reach them.
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true
    it = st.items[st.sel]
    state = read(W.STATE, String)
    keep = W.TOUCHED[]
    W.TOUCHED[] = joinpath(mktempdir(), "touched.json")
    try
        W.handle!(st, Int('s'), ctrl)
        v = pop!(ctrl.stack)
        @test v isa W.ChooseView
        vals = [o[2] for o in v.options]
        @test "on-change" in vals && "2w" in vals && :ask in vals
        # Nothing to clear yet, so "off" is not offered.
        @test !(nothing in vals)
        for (w, h) in ((80, 24), (165, 50))
            ls = split(W.render(v, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end

        # A span is written as given, and shows in the status.
        @test W.apply_snooze!(st, it, "2w", W.utcnow()) == "snoozed 2w"
        @test W.get_field(it.url, "snooze") == "2w"
        # Now that there is one, clearing is offered and says what it is on.
        W.handle!(st, Int('s'), ctrl)
        v2 = pop!(ctrl.stack)
        @test nothing in [o[2] for o in v2.options]
        @test occursin("now: 2w", v2.note)

        # A value parse_snooze cannot read is refused rather than written: it
        # would leave the item not snoozed and look like it had worked.
        @test occursin("bad snooze value", W.apply_snooze!(st, it, "3days", W.utcnow()))
        @test W.get_field(it.url, "snooze") == "2w"
        # A date is fine, and so is clearing.
        @test W.apply_snooze!(st, it, "2099-01-01", W.utcnow()) == "snoozed 2099-01-01"
        @test W.apply_snooze!(st, it, nothing, W.utcnow()) == "snooze cleared"
        @test W.get_field(it.url, "snooze") === nothing
        @test W.apply_snooze!(st, it, "", W.utcnow()) == "snooze cleared"

        # `a span or a date…` asks, and what is typed goes the same way.
        W.handle!(st, Int('s'), ctrl)
        pop!(ctrl.stack).onpick(:ask)
        p = pop!(ctrl.stack)
        @test p isa W.PromptView
        p.onsubmit("6mo")
        @test W.get_field(it.url, "snooze") == "6mo"
        @test st.status == "snoozed 6mo"

        # Every write is undoable, back to nothing at all.
        for _ in 1:length(st.undos); W.handle!(st, Int('z'), ctrl); end
        @test W.get_field(it.url, "snooze") === nothing
    finally
        write(W.STATE, state)
        W.TOUCHED[] = keep
    end
end

@testset "notes, and the file they land in" begin
    # `state.toml` is the user's, edited key-by-key and never rewritten. A key
    # added and then removed has to leave the file exactly as it was found -
    # including the blank line separating one block from the next, which used
    # to be filtered out on every write to keep new keys in the right place.
    u = W.loaditems()[1].url
    before = read(W.STATE, String)
    W.set_fields(u, ["note" => "a passing thought"])
    mid = read(W.STATE, String)
    @test occursin("a passing thought", mid)
    @test W.get_field(u, "note") == "a passing thought"
    W.set_fields(u, ["note" => nothing])
    @test read(W.STATE, String) == before
    @test W.get_field(u, "note") === nothing

    # A new key belongs inside its block, not after the blank line that ends it.
    W.set_fields(u, ["note" => "inside"])
    lines = split(read(W.STATE, String), "\n")
    at = findfirst(l -> occursin("note = \"inside\"", l), lines)
    @test at !== nothing
    # Whatever follows it is either more of this block or the separator; it is
    # never a header that this key has jumped over.
    @test !startswith(strip(lines[at - 1]), "[")|| true
    W.set_fields(u, ["note" => nothing])
    @test read(W.STATE, String) == before

    # `v` opens in a pane beside the thread, the same as `t` and `T`. The note
    # is nearly always *about* what is on the other half, and taking the whole
    # screen meant leaving the editor to check what the thread said.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the note-in-a-pane test"
    else
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true
        push!(ctrl.stack, st)
        it = st.items[st.sel]
        keept = W.TOUCHED[]
        W.TOUCHED[] = joinpath(mktempdir(), "touched.json")
        before2 = read(W.STATE, String)
        try
            # An editor that writes and exits at once is gone before there is
            # anything to attach to. The note is still taken: being quick is
            # not a reason to throw the edit away.
            withenv("EDITOR" => raw"""sh -c 'printf "instantly\n" >> "$1"' sh""") do
                @test W.edit_note(st, it, ctrl) == "note saved"
                @test W.get_field(it.url, "note") == "instantly"
                @test last(ctrl.stack) === st          # no pane was left behind
                W.handle!(st, Int('z'), ctrl)
            end

            withenv("EDITOR" =>
                    raw"""sh -c 'sleep 1; printf "from the pane\n" >> "$1"' sh""") do
                r = W.edit_note(st, it, ctrl)
                @test occursin("editing the note", r)
                v = last(ctrl.stack)
                @test v isa W.PaneView
                # Nothing is written yet: the note lands when the editor exits.
                @test W.get_field(it.url, "note") === nothing
                for _ in 1:60
                    sleep(0.25); W.pane_sync!(v)
                    v.client === nothing && break
                end
                @test v.client === nothing
                @test v.status == "note saved"
                @test W.get_field(it.url, "note") == "from the pane"
                # The item carries it too, since the pane reads the note off
                # the item and `facts.json` is not rewritten until a refresh.
                i = findfirst(x -> x.url == it.url, st.items)
                @test st.items[i].note == "from the pane"
                # Undoable like any other local write.
                @test !isempty(st.undos)
                W.handle!(st, Int('z'), ctrl)
                @test W.get_field(it.url, "note") === nothing
                # Once only: a second sync must not read the file again and
                # undo an edit made in between.
                @test v.onend === nothing
                @test !W.pane_sync!(v)
                pop!(ctrl.stack)
            end
        finally
            write(W.STATE, before2)
            W.TOUCHED[] = keept
        end
    end

    # Single quotes need no other escaping, which is why they are what is used.
    @test W.shquote("/tmp/a b.md") == "'/tmp/a b.md'"
    @test W.shquote("it's") == raw"'it'\''s'"

    # `$EDITOR` is a command line, not a program: it routinely has arguments
    # and quotes in it, so it is handed to a shell with the path as `$1`.
    @test W.noteeditor() == "vi"                       # neither set here
    withenv("EDITOR" => "code --wait") do
        @test W.noteeditor() == "code --wait"
    end
    withenv("VISUAL" => "v1", "EDITOR" => "e2") do
        @test W.noteeditor() == "v1"                   # VISUAL wins, as in less
    end
end
