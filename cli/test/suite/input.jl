# Bytes arriving and becoming keys. `readevent` is a pure function of a stream,
# so this needs no terminal.
#
# The vocabulary it produces is `TermInput.Keys` and the editing built on it is
# `TermInput`'s too, so the word rules, the buffer and the wrapping are tested
# where they live (`julia --project=TermInput.jl TermInput.jl/test/runtests.jl`).
# What is here is the decoder, and the two views this program wraps them in.

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

    # The two spaces do not touch, with the whole four-byte range left over -
    # which is the property the decoder relies on and `TermInput` asserts in
    # full.
    @test W.K_BASE == 1 << 32
    @test !W.printable(W.K_LEFT) && !W.printable(W.K_BASE)
    @test all(raw(b...) < W.K_BASE for b in ((0xF4,0x90,0x80,0x80), (0xFF,), (0xF8,)))
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

@testset "the two views the widgets are wrapped in" begin
    ctrl = W.Controller()

    # The editing is `TermInput`'s and is tested there. What is asserted here is
    # that a key reaches it through the view, and that the view is the one place
    # that knows what an answer means to this program.
    v = W.EditorView("t", "", identity)
    type!(x) = for c in x; W.handle!(v, W.keycode(c), ctrl); end
    type!("alpha beta gamma")
    W.handle!(v, W.C_W, ctrl)
    @test W.text(v) == "alpha beta "
    W.handle!(v, W.K_WORD_BACK, ctrl)
    @test W.text(v) == "alpha "
    W.handle!(v, W.C_A, ctrl); @test v.buf.col == 1
    W.handle!(v, W.C_D, ctrl)                      # forward delete
    @test W.text(v) == "lpha "
    # $EDITOR moved off ^e, which is end-of-line.
    W.handle!(v, W.C_E, ctrl)
    @test v.buf.col == 6 && W.text(v) == "lpha " # nothing was launched

    # A prompt submits what was typed, stripped, and only when there is
    # something to submit.
    got = Ref("")
    p = W.PromptView("t", "", s -> got[] = s)
    for c in "/usr/local/lib"; W.handle!(p, W.keycode(c), ctrl); end
    W.handle!(p, W.K_WORD_BACK, ctrl)              # alt-backspace: one component
    @test W.handle!(p, 13, ctrl) === :pop
    @test got[] == "/usr/local/"

    empty = W.PromptView("t", "", s -> got[] = "should not run")
    @test W.handle!(empty, 13, ctrl) === :pop      # nothing typed is not an answer
    @test got[] == "/usr/local/"
    @test W.handle!(W.PromptView("t", "", identity), 27, ctrl) === :pop

    ls = split(W.render(p, 90, 24), "\n")
    @test length(ls) == 24 && all(W.awidth(l) == 90 for l in ls)
end
