# The composer, as this program wraps it.
#
# The buffer, the keys, the wrapping and the box are `TermInput.TextArea` and
# are tested in that package. What is asserted here is the three things the
# wrapper adds: escape asks before throwing words away, `^s` submits to the
# callback that opened it, and `^r` drops in the block the caller handed over.

@testset "the composer" begin
    ctrl = W.Controller()
    got = Ref("")
    v = W.EditorView("comment", "on managers.jl:544", t -> got[] = t)
    type!(s) = for c in s; W.handle!(v, W.keycode(c), ctrl); end

    type!("hello")
    W.handle!(v, 13, ctrl)                       # enter splits at the cursor
    type!("world")
    @test W.text(v) == "hello\nworld"

    # ^s submits and pops, and what the callback gets is stripped.
    W.handle!(v, 13, ctrl)
    @test W.handle!(v, 19, ctrl) === :pop
    @test got[] == "hello\nworld"

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

    # `^r` is the caller's key, not the composer's: `TextArea` hands it back
    # unhandled and this is what binds it. The block goes in whole under an
    # empty buffer, and the footer says so.
    s = W.EditorView("t", "", identity; suggest = "```suggestion\nfixed = 1\n```")
    @test W.handle!(s, W.C_R, ctrl) === :ok
    @test W.text(s) == "```suggestion\nfixed = 1\n```\n"
    @test occursin("suggestion inserted", s.status)
    # And where there is nothing to suggest, the footer says that instead of
    # the key doing nothing at all.
    n = W.EditorView("t", "", identity)
    W.handle!(n, W.C_R, ctrl)
    @test occursin("nothing to suggest", n.status) && isempty(W.text(n))
    # The next keystroke clears it, so a message never outlives what it was
    # about.
    W.handle!(n, W.keycode('x'), ctrl)
    @test isempty(n.status)

    # An empty buffer will not submit unless the caller said it may - an
    # approval needs no words, a comment does.
    e = W.EditorView("t", "", t -> got[] = "should not run")
    @test W.handle!(e, 19, ctrl) === :ok && occursin("nothing to send", e.status)
    ok = Ref("")
    a = W.EditorView("t", "", t -> ok[] = "ran"; allow_empty = true)
    @test W.handle!(a, 19, ctrl) === :pop && ok[] == "ran"

    # Whatever the state, the frame is the size it was asked for.
    v2 = W.EditorView("t", "", identity; initial = "0123456789abcdefghij")
    for (w, h) in ((80, 24), (120, 40), (60, 12))
        ls = split(W.render(v2, w, h), "\n")
        @test length(ls) == h && all(W.awidth(l) == w for l in ls)
    end

    # suspend runs the body and puts the screen back. The sequences are
    # `TermInput`'s; what is asserted here is that the controller's terminal and
    # its mouse are what get handed over.
    ran = Ref(false)
    out = mktemp() do path, io
        redirect_stdout(() -> W.suspend(() -> ran[] = true, ctrl), io)
        flush(io)
        read(path, String)
    end
    @test ran[]
    @test occursin("\e[?1049l", out) && occursin("\e[?1049h", out)
end
