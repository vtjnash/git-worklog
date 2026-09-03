# The multi-line composer, and handing the terminal to a child while it runs.

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
