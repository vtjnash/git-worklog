# The multi-line composer, and handing the terminal to a child while it runs.

@testset "the composer" begin
    ctrl = W.Controller()
    got = Ref("")
    v = W.EditorView("comment", "on managers.jl:544", t -> got[] = t)
    type!(s) = for c in s; W.handle!(v, W.keycode(c), ctrl); end

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

    # ^s submits and pops.
    @test W.handle!(v, 19, ctrl) === :pop
    @test got[] == "hello… é"

    # Esc asks first. What is in this buffer is the one thing in the program
    # that is nowhere else - a note is on disk as it is typed, a draft review is
    # on GitHub - so the key that throws it away is the one key here that
    # confirms.
    sent = Ref("")
    w = W.EditorView("Comment on r#1", "", t -> sent[] = t)
    W.push_view!(ctrl, w)
    # Nothing written is nothing to lose, and asking would put a dialog in front
    # of every composer opened by mistake.
    @test W.handle!(w, 27, ctrl) === :pop
    @test length(ctrl.stack) == 1                # no question, just the editor
    for c in "half a comment"; W.handle!(w, W.keycode(c), ctrl); end
    @test W.handle!(w, 27, ctrl) === :ok         # the editor stays put
    q = last(ctrl.stack)
    @test q isa W.ConfirmView && occursin("Discard", q.title)
    @test any(n -> occursin("Comment on r#1", n), q.notes)
    # Any other key goes back to writing, with every character still there.
    @test W.handle!(q, Int('n'), ctrl) === :pop
    pop!(ctrl.stack)
    @test W.text(w) == "half a comment" && w in ctrl.stack
    # `y` is what discards, and it takes the editor with it rather than itself:
    # the answer runs while the question is still the view on top.
    @test W.handle!(w, 27, ctrl) === :ok
    @test W.handle!(last(ctrl.stack), Int('y'), ctrl) === :pop
    pop!(ctrl.stack)
    @test !(w in ctrl.stack) && sent[] == ""     # and nothing was submitted
    empty!(ctrl.stack)

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
