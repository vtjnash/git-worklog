# Bytes arriving and becoming keys is `TermInput.readevent`, a frame written is
# its `frame_bytes`, and the key vocabulary and the editing built on it are its
# too, all tested where they live
# (`julia --project=TermInput.jl TermInput.jl/test/runtests.jl`). What is here is
# what this program does with the events, and the views it wraps the widgets in.

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

@testset "the terminal's cursor goes where typing goes" begin
    # What the screen has under it, where `viewcursor` puts it on the frame
    # just drawn: the character starting at that column.
    function under(v, w, h)
        rs = W.render(v, w, h)
        r, c = W.viewcursor(v, w, h)
        acc = 1
        for ch in unstyled(rs[r])
            acc == c && return string(ch)
            acc += textwidth(ch)
        end
        nothing
    end
    ed = W.EditorView("comment", "", identity; initial = "a remark")
    @test under(ed, 100, 30) == " "
    W.handle!(ed, TermInput.K_LEFT, W.Controller())
    @test under(ed, 100, 30) == "k"
    pr = W.PromptView("url", "", identity; initial = "https://x")
    @test under(pr, 100, 30) == " "
    # Beside a thread, the composer's caret is on its side of the split while
    # it has the keys; while the thread has them, the composer draws a block
    # and the terminal's cursor is hidden.
    st = mkstate()
    sv = W.SideView(W.EditorView("comment", "", identity; initial = "abc"), st, :inner)
    lw, _ = W.split_box(170)
    @test under(sv, 170, 40) == " " && W.viewcursor(sv, 170, 40)[2] > lw
    sv.focus = :read
    @test (W.render(sv, 170, 40); W.viewcursor(sv, 170, 40)) === nothing
    @test occursin(ansi(TermInput.faced(" ", W.Face(inverse = true))), frame(sv, 170, 40))
    # The browser's `/`, on whichever row the footer landed, and nowhere once
    # the query is kept.
    st.typing = true; st.searchin = :list
    W.safe_dispatch!(st, W.PasteEvent("juli"), W.Controller())
    TermInput.handle!(st.query, TermInput.K_LEFT)
    @test under(st, 120, 30) == "i" && W.viewcursor(st, 120, 30)[1] == 30
    st.typing = false; st.search = ""; W.refilter!(st)
    @test (W.render(st, 120, 30); W.viewcursor(st, 120, 30)) === nothing
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

    ls = split(frame(p, 90, 24), "\n")
    @test length(ls) == 24 && all(width(l) == 90 for l in ls)
end

@testset "a right or middle press turns the mouse off and on" begin
    # After one, a terminal stopped reporting drags until `m` was pressed
    # twice; the loop does that itself, and only for those presses.
    @test W.menu_press(W.MouseEvent(:press, 2, 5, 5, 0))
    @test W.menu_press(W.MouseEvent(:press, 1, 5, 5, 0))
    @test !W.menu_press(W.MouseEvent(:press, 0, 5, 5, 0))
    @test !W.menu_press(W.MouseEvent(:release, 2, 5, 5, 0))
    raw(s) = W.RawEvent(Vector{UInt8}(codeunits(s)))
    @test W.menu_press(raw("ab\e[<2;10;4Mcd"))
    @test W.menu_press(raw("\e[<18;10;4M"))                    # ctrl held
    @test !W.menu_press(raw("\e[<2;10;4m"))                    # a release
    @test !W.menu_press(raw("\e[<0;10;4M\e[<32;11;4M"))        # a left drag
    @test !W.menu_press(raw("\e[<65;10;4M"))                   # the wheel
    @test !W.menu_press(W.KeyEvent(13))
    buf = IOBuffer()
    held = W.Controller(W.enter_terminal(IOBuffer(), buf; mouse = true))
    take!(buf)
    W.rearm_mouse!(held)
    @test String(take!(buf)) == string(W.mouse_reporting(false), W.mouse_reporting(true))
    held.term.mouse = false
    W.rearm_mouse!(held)
    @test isempty(take!(buf))                                  # `m` gave it back
end

@testset "the terminal says dark or light, and the theme follows" begin
    # The report is an event of its own - `readevent`'s, which TermInput
    # tests, and from the raw path here, where it is taken out of a pane's
    # input, which goes on without it - and anything else is what it was.
    ev = W.scheme_in(Vector{UInt8}(codeunits("ab\e[?997;1ncd")))
    @test ev isa W.SchemeEvent && ev.dark && String(copy(ev.rest)) == "abcd"
    @test W.scheme_in(Vector{UInt8}(codeunits("\e[?997;2n"))).rest == UInt8[]
    @test W.scheme_in(UInt8['x']) isa W.RawEvent

    # And the background colour, the answer to `OSC 11 ?`, for the panes,
    # beside a scheme report in one read - which is how the two answers to one
    # startup arrive.
    ev = W.scheme_in(Vector{UInt8}(codeunits("a\e[?997;2n\e]11;rgb:ffff/ffff/ffff\e\\b")))
    @test ev isa W.SchemeEvent && ev.dark === false && ev.bg == "rgb:ffff/ffff/ffff"
    @test String(copy(ev.rest)) == "ab"
    ev = W.scheme_in(Vector{UInt8}(codeunits("\e]11;#000000\a")))
    @test ev.dark === nothing && ev.bg == "#000000" && isempty(ev.rest)
    # What could not be handed on to tmux intact is not a colour.
    @test W.scheme_in(Vector{UInt8}(codeunits("\e]11;a b\a"))) isa W.RawEvent

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

    # Off while the terminal is handed over, and asked again after - the
    # background too, which may have changed with it.
    buf = IOBuffer()
    W.suspend(() -> nothing, W.Controller(W.HeldTerminal(IOBuffer(), buf)))
    out = String(take!(buf))
    @test occursin("\e[?2031l", out) && endswith(out, string("\e[?2031h\e[?996n", W.BG_QUERY))
end
