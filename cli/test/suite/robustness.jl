# What happens when something goes wrong, and the readouts that have to fit
# the space they are given.

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
            @test v.child.sized == W.iframe_box(last(W.split_box(200)), 24)
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
            @test v.child.sized == W.iframe_box(100, 24)
            ls = split(W.render(v, 100, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 100 for l in ls)
        end

        # With no browser under it a pane still renders, undivided.
        alone = W.pane_view(n, "child", ctrl; beside = nothing)
        withenv("LINES" => "24", "COLUMNS" => "200") do
            ls = split(W.render(alone, 200, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 200 for l in ls)
        end
        W.iframe_close!(alone.child); W.iframe_close!(v.child); W.mux_kill(n)
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
    isfile(W.errlog()) && rm(W.errlog())
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
    @test isfile(W.errlog())
    @test occursin("delete it to clear", W.errnote())
    # The warning has to survive being fitted to the footer, or it says that
    # something is wrong without saying what to do.
    @test W.awidth(W.errnote()) < 80
    @test occursin("render exploded", read(W.errlog(), String))
    @test occursin("handle exploded", read(W.errlog(), String))

    # A bug on the render path runs every frame, so the same error is written
    # once rather than thousands of times.
    before = filesize(W.errlog())
    W.safe_render(v, 80, 24); W.safe_render(v, 80, 24)
    @test filesize(W.errlog()) == before

    # It is what the footer shows, ahead of the status.
    st = W.BState(W.loaditems(), "worklog", Set{String}())
    st.status = "something ordinary"
    @test occursin("delete it to clear", W.render(st, 120, 40))

    rm(W.errlog())
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
    mk(cur; beside = nothing) = begin
        f = W.IFrame("n", "t")           # an iframe with no child behind it
        f.cursor = cur
        W.PaneView(f, beside, :child)
    end

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
    c = mk((0, 0, true))
    @test W.viewcursor(c, 80, 24) === nothing        # no client, nothing to show
end

@testset "shapes Term cannot render" begin
    # `parse_md(::Markdown.Table)` takes `width` and nothing else, but Term's
    # own recursion passes `inline` to whatever is inside a list or a quote. One
    # table in one bullet used to drop the whole comment back to raw text.
    isfile(W.errlog()) && rm(W.errlog())
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
    @test !isfile(W.errlog())

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
    isfile(W.errlog()) && rm(W.errlog())
    empty!(W.ERRSEEN)
    for src in ("- a\n-\n- b\n", "1. one\n2.\n3. three\n", "-\n",
                "- outer\n    -\n    - inner\n", "> - a\n> -\n")
        out = W.render_md(src, 60)
        @test !occursin("BoundsError", out)
    end
    @test !isfile(W.errlog())
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
        @test v1.child.wantsmouse === false
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
        x, y, showing = v1.child.cursor
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
        @test v2.child.wantsmouse === true

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

        W.iframe_close!(v1.child); W.iframe_close!(v2.child)
        W.mux_kill(n1); W.mux_kill(n2)
    end
end


@testset "a branch is told apart at the end of its column" begin
    # `amid` is TermIFrame's and is tested there. What is this program's is
    # which columns use it: a branch is the thing that tells two copies of one
    # repo apart, so it is the one that must not be cut at the tail.
    # `users/vtjnash/tsa-tryheld-state` and `...-other` both drew as
    # `users/vtjnash/tsa-tryheld…` in the twenty-six the chooser has.
    a, b = "users/vtjnash/tsa-tryheld-state", "users/vtjnash/tsa-tryheld-other"
    for w in (W.WT_BRANCH, W.BR_NAME, 26)
        @test W.amid(a, w) != W.amid(b, w)
    end
    mk(branch) = W.WorktreeRow("o/r", "/tmp/wt", "wt", branch, false, false, 0, 0,
                               "2026-09-01", false, false, nothing, W.SessionRow[])
    @test W.astrip(W.wt_line(mk(a), 100)) != W.astrip(W.wt_line(mk(b), 100))
    br(name) = W.BranchRow("o/r", name, "2026-09-01", 0, 0, false, "", "", nothing)
    @test W.astrip(W.br_line(br(a), 100)) != W.astrip(W.br_line(br(b), 100))
    # And `shortlink` is the same idiom over the same code.
    @test W.shortlink("x", 58) == "x"
    u = "https://x.invalid/" * "a"^80
    @test W.shortlink(u, 58) == W.amid(u, 58)
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
