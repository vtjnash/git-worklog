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
    @test ev("\ed") == W.KeyEvent(W.K_WORD_KILL)    # alt-d, its mirror
    @test ev("\e[1;3D") == W.KeyEvent(W.K_WORD_LEFT) # CSI with a modifier
    @test ev("\e[1;5C") == W.KeyEvent(W.K_WORD_RIGHT)# ctrl counts as by-word too
    @test ev("\e\e[D") == W.KeyEvent(W.K_WORD_LEFT) # iTerm's Esc+
    @test ev("\e[1;2D") == W.KeyEvent(W.K_LEFT)      # shift is not by-word
    @test ev("\e[3~") == W.KeyEvent(W.K_DEL)
    @test ev("\e[299~") == W.KeyEvent(-1)            # unknown, but consumed

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

    # A paste is a key per character with the rest already waiting, which is
    # what holds the frame until the last of them; a key typed alone is not.
    io = IOBuffer("hi\e[A")
    @test W.readevent(io) == W.KeyEvent(Int('h')) && W.input_waiting(io)
    W.readevent(io)
    @test W.readevent(io) == W.KeyEvent(W.K_UP) && !W.input_waiting(io)

    # A bracketed paste is one event and text, whatever keys it spells; the
    # key after it is a key again.
    io = IOBuffer("\e[200~q\tx\ry\e[201~j")
    @test W.readevent(io) == W.PasteEvent("q\tx\ry")
    @test W.readevent(io) == W.KeyEvent(Int('j'))
    # And a terminal that went away mid-paste gives what did arrive.
    @test ev("\e[200~half") == W.PasteEvent("half")
end

@testset "a paste goes where text goes, and nowhere else" begin
    ctrl = W.Controller()
    paste!(v, s) = W.safe_dispatch!(v, W.PasteEvent(s), ctrl)
    ed = W.EditorView("comment", "", identity)
    @test paste!(ed, "one\rtwo\t") === :ok
    @test W.text(ed) == "one\ntwo\t"
    pr = W.PromptView("url", "", identity)
    paste!(pr, "https://github.com/a/b/pull/1\n")
    @test W.text(pr) == "https://github.com/a/b/pull/1"
    # Beside a thread, the side with the keys takes it.
    st = mkstate()
    sv = W.SideView(W.EditorView("comment", "", identity), st, :inner)
    paste!(sv, "hi")
    @test W.text(sv.inner) == "hi"
    # The browser has no text to put it in unless a query is being typed:
    # a pasted `q` does not quit and a pasted `e` marks nothing.
    sel = st.sel
    @test paste!(st, "qe") === :ok
    @test st.sel == sel && occursin("not keys", st.status)
    st.typing = true; st.searchin = :list
    paste!(st, "juli\na\n")
    @test st.search == "juli a"
    st.typing = false; st.search = ""; W.refilter!(st)
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

@testset "a frame is one write, cursor hidden first and shown last" begin
    b = String(W.frame_bytes("ab\ncd", "", (2, 1)))
    # Held by the terminal until the closing sequence, drawn with the cursor
    # hidden, and the cursor put where the view said and shown only then.
    @test startswith(b, "\e[?2026h\e[?25l\e[H")
    @test endswith(b, "\e[J\e[2;1H\e[?25h\e[?2026l")
    @test occursin("ab\e[K\ncd\e[J", b)                  # rows cleared to the end
    # No cursor to show: it stays hidden, and nothing moves it.
    n = String(W.frame_bytes("ab", "", nothing))
    @test endswith(n, "\e[J\e[?2026l") && !occursin("?25h", n)
    # The title goes after the frame and before the caret, inside the hold.
    t = String(W.frame_bytes("x", "\e]2;wl o/r#1\e\\", (1, 1)))
    @test occursin("\e[J\e]2;wl o/r#1\e\\\e[1;1H\e[?25h", t)
    # A row that filled its width gets no erase after it: the cursor is in
    # the pending-wrap state, which Terminal.app keeps on the last column,
    # and an erase from there took the border off. A short row keeps its
    # erase, and a short last row the final one.
    f = String(W.frame_bytes("ab\ncd", "", nothing; w = 2))
    @test occursin("\e[Hab\ncd\e[?2026l", f) && !occursin("\e[K", f) && !occursin("\e[J", f)
    f = String(W.frame_bytes("ab\nc", "", nothing; w = 2))
    @test occursin("\e[Hab\nc\e[J", f)
    f = String(W.frame_bytes("a\ncd", "", nothing; w = 2))
    @test occursin("\e[Ha\e[K\ncd\e[?2026l", f)
    # Measured as drawn: an SGR is no column.
    f = String(W.frame_bytes("\e[1mab\e[0m\ncd", "", nothing; w = 2))
    @test !occursin("\e[K", f)
end

@testset "the terminal says dark or light, and the theme follows" begin
    # The report is an event of its own, from the decoded path and from the
    # raw one - where it is taken out of a pane's input, which goes on without
    # it - and anything else is what it was.
    ev = W.readevent(IOBuffer("\e[?997;1n"))
    @test ev isa W.SchemeEvent && ev.dark && isempty(ev.rest)
    ev = W.readevent(IOBuffer("\e[?997;2n"))
    @test ev isa W.SchemeEvent && !ev.dark
    @test W.readevent(IOBuffer("\e[?997;3n")) == W.KeyEvent(-1)
    ev = W.scheme_in(Vector{UInt8}(codeunits("ab\e[?997;1ncd")))
    @test ev isa W.SchemeEvent && ev.dark && String(copy(ev.rest)) == "abcd"
    @test W.scheme_in(Vector{UInt8}(codeunits("\e[?997;2n"))).rest == UInt8[]
    @test W.scheme_in(UInt8['x']) isa W.RawEvent

    # Paired by name, and a theme that names neither is the terminal's own.
    th(n) = joinpath(W.ROOT, "themes", n)
    @test W.scheme_theme(th("github-light-256.toml"), true) == th("github-dark-256.toml")
    @test W.scheme_theme(th("github-dark-256.toml"), false) == th("github-light-256.toml")
    @test W.scheme_theme(th("github-dark-256.toml"), true) == th("github-dark-256.toml")
    @test W.scheme_theme(th("default-ansi.toml"), true) == th("default-ansi.toml")
    @test W.scheme_theme(th("my-light.toml"), true) == th("my-light.toml")   # no pair on disk
    @test W.scheme_theme("", true) == ""

    # Switching loads the pair of the theme the config names, once, and again
    # only when the scheme changes.
    ctrl = W.Controller()
    try
        W.load_theme!(W.themefile())
        want = W.scheme_theme(W.themefile(), true)
        @test W.scheme!(ctrl, true) == (want != W.themefile())
        @test W.LOADED_THEME[] == want
        @test !W.scheme!(ctrl, true)                       # already so
        W.scheme!(ctrl, false)
        @test W.LOADED_THEME[] == W.scheme_theme(W.themefile(), false)
    finally
        W.load_theme!(THEME_DEFAULT)
    end

    # The browser's nodes carry the old escapes, and are built again quietly:
    # the ones on screen stay until the new ones land, and it is the cache
    # that is read, not GitHub.
    keepdir, keepfresh = W.CACHE_DIR[], W.CACHE_FRESH[]
    W.CACHE_DIR[] = joinpath(mktempdir(), "cache")
    W.CACHE_FRESH[] = 600.0
    try
        st = mkstate()
        st.mode = :comments
        u = st.items[st.sel].url
        W.cache_put(W.thread_key(u), (body = Dict("user" => Dict("login" => "a"),
                                                 "body" => "hello", "html_url" => u),
                                      comments = []))
        st.nodes = [W.Node("a", "body", :md, true)]
        st.loaded = string(u, ":", st.mode)
        W.retheme!(st)
        @test st.quiet && st.pending !== nothing && length(st.nodes) == 1
        ns = fetch(st.pending)
        @test occursin("hello", ns[1].raw)
    finally
        W.CACHE_DIR[], W.CACHE_FRESH[] = keepdir, keepfresh
    end

    # Off while the terminal is handed over, and asked again after.
    out = mktemp() do path, io
        redirect_stdout(() -> W.suspend(() -> nothing, ctrl), io)
        flush(io)
        read(path, String)
    end
    @test occursin("\e[?2031l", out) && endswith(out, "\e[?2031h\e[?996n")
end
