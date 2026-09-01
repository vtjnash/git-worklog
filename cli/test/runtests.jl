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
        W.handle!(st, Int('r'), ctrl)
        @test st.status == "marked read"
        @test W.Events.read_at(it.url) !== nothing
        @test !(it.url in st.unread)
        W.handle!(st, Int('z'), ctrl)
        @test W.Events.read_at(it.url) == prev          # exactly what was there
        @test read(readfile, String) == before          # byte for byte

        W.handle!(st, Int('u'), ctrl)
        @test st.status == "marked unread" && it.url in st.unread
        @test W.Events.read_at(it.url) === nothing
        W.handle!(st, Int('z'), ctrl)
        @test W.Events.read_at(it.url) == prev
        @test read(readfile, String) == before

        # A run of them unwinds in order.
        for _ in 1:3
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
