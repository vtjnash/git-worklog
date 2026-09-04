# Bytes arriving and becoming keys, and the line editing built on them.
# `readevent` is a pure function of a stream, so this needs no terminal.

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
