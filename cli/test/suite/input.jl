# Bytes arriving and becoming keys, and the line editing built on them.
# `readevent` is a pure function of a stream, so this needs no terminal.

@testset "a key code is the bytes that arrived, and nothing is thrown away" begin
    # A key code used to be a codepoint, and the keys began at `0x110000`, one
    # past the last one. Both halves of that were wrong. A lead byte of `0xF0`
    # or above carries three bits and each continuation six, so a malformed
    # four-byte sequence assembles to as much as `0x1FFFFF`: `F4 90 80 80` came
    # out as exactly `K_LEFT` and `F4 90 80 82` as `K_UP`, and a paste of
    # arbitrary bytes moved the cursor.
    #
    # Rejecting the malformed ones would have fixed that and still been wrong.
    # Julia does not need us to: a `Char` is four bytes of UTF-8 held as they
    # came, and arbitrary binary survives a round trip through a `String`
    # intact - it is only `codepoint` that refuses. So the bytes are carried and
    # `keychar` hands them back.
    raw(bs...) = W.readevent(IOBuffer(UInt8[bs...])).code
    kept(bs...) = collect(codeunits(string(W.keychar(raw(bs...))))) == collect(UInt8[bs...])

    # Every one of these has no codepoint, or has one that was never typed:
    # `Int` throws on a lone `0x80`, turns `C0 80` into a NUL and `F4 90 80 80`
    # into `1114112`. All of them come back as the bytes they were.
    @test kept(0xF4, 0x90, 0x80, 0x80)      # out of range
    @test kept(0xED, 0xA0, 0x80)            # a surrogate half
    @test kept(0xC0, 0x80)                  # an overlong NUL
    @test kept(0x80)                        # a continuation with no lead
    @test kept(0xF8)                        # never a lead byte at all
    @test kept(0xFF)
    # And so does everything that is a character, at every width.
    @test kept(0xC3, 0xA9) && kept(0xE2, 0x82, 0xAC) && kept(0xF0, 0x9F, 0x98, 0x80)

    # One byte is its own code, so the bindings are what they always were.
    @test raw(UInt8('j')) == Int('j')
    @test W.readevent(IOBuffer("\r")) == W.KeyEvent(13)
    # Above that is the sequence, in order - always past `0xFF`, since the lead
    # byte of a multi-byte one is at least `0xC0`.
    @test raw(0xC3, 0xA9) == 0xC3A9
    @test raw(0xF0, 0x9F, 0x98, 0x80) == 0xF09F9880
    @test all(raw(b...) > 0xFF for b in ((0xC3,0xA9), (0xE2,0x82,0xAC), (0xF0,0x9F,0x98,0x80)))

    # The framing is Julia's own, so a sequence stored in a buffer is read back
    # out of it as the same one `Char`. `0xF8` leads nothing: those are four
    # keys, not one, and Julia reads those bytes back as four characters.
    io = IOBuffer(UInt8[0xF8, 0x80, 0x80, 0x80])
    @test [W.readevent(io).code for _ in 1:4] == [0xF8, 0x80, 0x80, 0x80]
    @test length(collect(String(UInt8[0xF8, 0x80, 0x80, 0x80]))) == 4
    # A sequence whose continuation never came is its lead byte alone, and the
    # byte that is not a continuation is left for the key it belongs to.
    io = IOBuffer(UInt8[0xE0, UInt8('A')])
    @test W.readevent(io).code == 0xE0
    @test W.readevent(io) == W.KeyEvent(Int('A'))

    # Typed into a buffer and taken back out, byte for byte - which is the whole
    # claim, since that is where a pasted sequence actually ends up.
    buf = string("ab", W.keychar(raw(0xF4, 0x90, 0x80, 0x80)), "cd")
    @test collect(codeunits(buf)) ==
          vcat(collect(codeunits("ab")), UInt8[0xF4,0x90,0x80,0x80], collect(codeunits("cd")))
    @test length(collect(buf)) == 5           # one character, not four
    @test W.awidth(buf) == 5                  # and the layout survives it

    # The two spaces do not touch, with the whole four-byte range left over.
    @test W.K_BASE == 1 << 32
    @test !W.printable(W.K_LEFT) && !W.printable(W.K_BASE)
    for k in (W.K_LEFT, W.K_RIGHT, W.K_UP, W.K_DOWN, W.K_DEL, W.K_HOME, W.K_END,
              W.K_PGUP, W.K_PGDN, W.K_STAB, W.K_WORD_LEFT, W.K_WORD_RIGHT,
              W.K_WORD_BACK, W.K_EDIT, W.K_SUP, W.K_SDOWN)
        @test k > 0xFFFFFFFF
    end
    # `keychar` and `keycode` are inverses, over every width and over sequences
    # that are not characters at all.
    for bs in ((0x61,), (0xC3,0xA9), (0xE2,0x82,0xAC), (0xF0,0x9F,0x98,0x80),
               (0xF4,0x90,0x80,0x80), (0xED,0xA0,0x80), (0xC0,0x80), (0x80,), (0xF8,))
        k = raw(bs...)
        @test W.keycode(W.keychar(k)) == k
    end
    for c in ('a', 'é', '€', '😀', '\0', '\x7f')
        @test W.keychar(W.keycode(c)) === c
    end

    # The vocabulary is a module of its own, and reaching it either way is the
    # same constant.
    @test W.Keys.K_LEFT === W.K_LEFT
    @test W.Keys.unshift(W.K_SUP) === W.K_UP
end

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
    # Shift is the one modifier the vertical arrows carry a key of their own
    # for, since it is what extends a selection. Alt and ctrl are not it.
    @test ev("\e[1;2A") == W.KeyEvent(W.K_SUP)
    @test ev("\e[1;2B") == W.KeyEvent(W.K_SDOWN)
    @test ev("\e[1;5A") == W.KeyEvent(W.K_UP)
    # And a view with no selection to extend reads them as the arrows they are
    # drawn on, rather than as keys that do nothing at all.
    @test W.unshift(W.K_SUP) == W.K_UP && W.unshift(W.K_SDOWN) == W.K_DOWN
    @test W.unshift(Int('j')) == Int('j')
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
    # between them alike, so the comment folds as a unit. The prose after the
    # block has no header of its own - it is the comment carrying on, and a
    # foldable `…` over it read as a thing to open.
    @test [(n.depth, n.open, n.header) for n in ns] ==
          [(0, true, "alice"), (1, false, "Impacted"), (1, true, "")]
    @test ns[3] |> W.isbare
    @test W.parentnode(ns, 3) == 1             # what `↵` in it folds
    @test ns[1].raw == "before" && ns[3].raw == "after"
    ns[1].open = false
    @test length(W.rows(ns, 80)) == 1          # closing it leaves one row
    ns[1].open = true
    # A folded block costs one row until it is opened: two headers, one body row
    # for the prose above it, and one for the prose below that has no header.
    @test length(W.rows(ns, 80)) == 4
    ns[2].open = true
    @test length(W.rows(ns, 80)) > 4
    # And CRLF never reaches a node: GitHub writes it, the markdown path used to
    # be the only thing that dropped it, and a fenced block came out with a
    # carriage return on the end of every line.
    crlf = W.body_nodes("alice", "prose\r\n\r\n```julia\r\nx = 1\r\n```\r\n\r\ntail\r\n",
                        "http://x", true)
    @test !any(occursin('\r', n.raw) for n in crlf)
    @test [n.header for n in crlf] == ["alice", "julia  1 line", ""]
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
    type!(x) = for c in x; W.handle!(v, W.keycode(c), ctrl); end

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
    for c in "/usr/local/lib"; W.handle!(p, W.keycode(c), ctrl); end
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
