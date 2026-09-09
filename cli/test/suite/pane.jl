# A child program drawn in a pane, beside the thread it is working on.
#
# The iframe itself - the screen, the cursor, the mouse, the scrollback and the
# prefix - is `TermIFrame`'s and is tested there against a real server. What is
# left here is what this program puts round one: the split, which side has the
# keyboard, and which keys belong to which side.

@testset "a child program in a pane" begin
    # Sized to its own column and not to the screen: with nothing beside it the
    # child has the width, and beside a thread it has what the split leaves.
    @test W.split_box(80) == (0, 80)
    @test W.split_box(170) == (78, 92)
    @test W.split_box(150) == (75, 75)

    if W.mux_bin() === nothing
        @info "no tmux; skipping the pane view test"
    else
        n = "wl-test-paneview-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf \"\\033[1;32mgreen\\033[0m plain\\n\"; sleep 120'")
        ctrl = W.Controller(); ctrl.running = true
        v = W.pane_view(n, "demo", ctrl)
        @test v !== nothing

        # `displaysize` is what the child is sized from, and with no tty that
        # is LINES and COLUMNS, so the resize path is drivable here.
        withenv("LINES" => "24", "COLUMNS" => "80") do
            @test W.pane_sync!(v) === true
            @test v.child.sized == W.iframe_box(80, 24)
            @test length(v.child.frame) == 21           # the height it was just given
            @test occursin("green", join(v.child.frame))
            @test occursin("\e[", join(v.child.frame))  # colour kept, not stripped
            ls = split(W.render(v, 80, 24), "\n")
            @test length(ls) == 24 && all(W.awidth(l) == 80 for l in ls)
        end
        # A different size re-sizes the child, not just the box drawn round it.
        withenv("LINES" => "40", "COLUMNS" => "120") do
            W.pane_sync!(v)
            @test v.child.sized == W.iframe_box(120, 40)
            @test length(v.child.frame) == 37
            ls = split(W.render(v, 120, 40), "\n")
            @test length(ls) == 40 && all(W.awidth(l) == 120 for l in ls)
        end

        # Every row is closed off, or an unterminated colour would run out of
        # the content and into the border.
        @test all(endswith(l, "\e[0m") for l in v.child.frame)

        # `q` leaves the session running - that is what a session is for.
        @test W.handle!(v, Int('q'), ctrl) === :pop
        @test W.mux_alive(n) === true

        # `K` ends it.
        v2 = W.pane_view(n, "demo", ctrl)
        @test v2 !== nothing
        @test W.handle!(v2, Int('K'), ctrl) === :pop
        @test W.mux_alive(n) === false
    end
end

@testset "a tmux inside a pane is reached with one prefix, not two" begin
    # Reported as "^b^b[ doesn't seem to reach there either", of a tmux running
    # inside a pane. It reaches; two prefixes is one layer too many. `onraw!`
    # writes bytes into the pane's pty with `send-keys -H`, so the hosting
    # session never sees them as keys of its own - there is no outer prefix to
    # escape, and this program's own prefix is `^]`, not `^b`.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the nested tmux test"
    else
        # Through `mux_cmd` rather than `mux_bin`: the bundled binary needs its
        # own libraries on the loader path, and the `Cmd` is what carries them.
        sock = "wlnested"
        nested(a...) = try
            strip(read(W.mux_cmd("-L", sock, a...), String))
        catch; "" end
        killnested() = try
            run(pipeline(W.mux_cmd("-L", sock, "kill-server"); stderr = devnull))
        catch; end
        killnested()
        n = "wl-test-nestedtmux"
        W.mux_kill(n)
        sc = string(Char(0x5c), Char(0x3b))     # an escaped `;` for tmux
        # Plain `tmux` inside the pane: the server this starts it in was itself
        # started from the multiplexer's own `Cmd`, so the pane inherits the
        # `PATH` and `LD_LIBRARY_PATH` that make the bundled binary runnable.
        W.mux_start(n, pwd(), string(
            "TERM=screen-256color tmux -L ", sock,
            " new-session -s in 'seq 1 500; sh' ",
            sc, " set -g mouse on ", sc, " set -g status off"))
        ctrl = W.Controller(); ctrl.running = true
        v = W.pane_view(n, "nested", ctrl)
        withenv("LINES" => "30", "COLUMNS" => "100") do
            sleep(2.5); W.pane_sync!(v)
            inmode() = nested("display-message", "-p", "-t", "=in:", "#{pane_in_mode}")
            if nested("show", "-gv", "mouse") != "on"
                @info "nested tmux did not come up; skipping"
            else
                @test inmode() == "0"
                # One prefix reaches it.
                W.onraw!(v, UInt8[0x02, UInt8('[')], ctrl); sleep(0.8)
                @test inmode() == "1"
                W.onraw!(v, UInt8[UInt8('q')], ctrl); sleep(0.5)
                @test inmode() == "0"
                # Two do not: the second is `send-prefix`, so a literal ^b goes
                # to the shell inside and `[` follows it there.
                W.onraw!(v, UInt8[0x02, 0x02, UInt8('[')], ctrl); sleep(0.8)
                @test inmode() == "0"

                # The mouse half of the same report. A tmux with `mouse on` sets
                # button and SGR tracking on the pane it is drawn in, so the
                # outer sees a child that wants the mouse and hands the wheel
                # over - and the inner tmux answers it by entering copy mode.
                # With `mouse off` it sets nothing on its own behalf, only on
                # behalf of what runs inside it: that is why the mouse works in
                # an editor in there and does nothing in the tmux itself.
                @test v.child.wantsmouse === true
                ox, oy = W.pane_origin(v, 100)
                W.onraw!(v, collect(codeunits(
                    string("\e[<64;", ox + 5, ";", oy + 5, "M"))), ctrl)
                sleep(0.8)
                @test inmode() == "1"
                @test v.child.scroll == 0             # answered in there, not here
            end
        end
        W.mux_kill(n)
        killnested()
    end
end

@testset "the wheel over a pane the child ignores" begin
    # `capture-pane` reads the grid, so a pane had no scrollback at all: a shell
    # that had just printed a build log could not be looked back at. The wheel
    # reports were arriving and being dropped, because a report forwarded to a
    # program that never asked for one prints as the control characters it is -
    # so the ones nobody wanted are the ones this answers.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the pane scrollback test"
    else
        n = "wl-test-scrollback"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'seq 1 500; sh'")
        ctrl = W.Controller(); ctrl.running = true
        v = W.pane_view(n, "sh", ctrl)
        @test v !== nothing
        withenv("LINES" => "30", "COLUMNS" => "100") do
            # Waited for rather than slept through: a fixed sleep was long
            # enough until it was not, and a `seq` that had not finished left
            # every assertion below measuring an empty history.
            for _ in 1:40
                W.pane_sync!(v)
                v.child.history > 100 && break
                sleep(0.25)
            end
            @test v.child.wantsmouse === false        # a shell asked for nothing
            @test v.child.alt === false && v.child.history > 100
            live = W.astrip(first(v.child.frame))
            ox, oy = W.pane_origin(v, 100)
            wheel(b) = collect(codeunits(string("\e[<", b, ";", ox + 5, ";", oy + 5, "M")))

            W.onraw!(v, wheel(64), ctrl)
            @test v.child.scroll == W.WHEEL_ROWS
            @test W.astrip(first(v.child.frame)) != live
            # The window moved by exactly what the wheel says it moved by.
            @test parse(Int, W.astrip(first(v.child.frame))) ==
                  parse(Int, live) - W.WHEEL_ROWS
            # No cursor while looking at the past: it is not on these rows.
            @test W.viewcursor(v, 100, 30) === nothing
            # And the note says where you are, over anything else it might say.
            v.child.status = "something happened"
            @test occursin("rows back", W.astrip(last(W.pane_column(v, 70, 30))))
            v.child.status = ""

            W.onraw!(v, wheel(65), ctrl)
            @test v.child.scroll == 0 && W.astrip(first(v.child.frame)) == live

            # Shift- and ctrl-wheel are the same request refined, not a
            # different one, so they scroll rather than falling through.
            for b in (64 + 4, 64 + 16)
                v.child.scroll = 0
                @test W.iframe_wheel!(v.child, b) === true && v.child.scroll == W.WHEEL_ROWS
            end
            v.child.scroll = 0

            # It stops at the top of the history rather than running past it.
            for _ in 1:(v.child.history ÷ W.WHEEL_ROWS + 20)
                W.iframe_wheel!(v.child, 64)
            end
            @test v.child.scroll == v.child.history

            # Typing snaps back to the live screen, the way a terminal does:
            # what you type is going to the bottom of it.
            W.onraw!(v, UInt8[UInt8(' ')], ctrl)
            @test v.child.scroll == 0

            # A click is not a wheel, and is still dropped when nothing wants it.
            @test isempty(W.retarget_mouse(v, collect(codeunits(
                string("\e[<0;", ox + 5, ";", oy + 5, "M"))), 100, 30))
            @test v.child.scroll == 0

            ls = split(W.render(v, 100, 30), "\n")
            @test length(ls) == 30 && all(W.awidth(l) == 100 for l in ls)

            # On the alternate screen there is nothing behind the child but the
            # wreckage of its own redraws, so this refuses - which is also why
            # a nested tmux gets nothing from it.
            v.child.alt = true
            @test W.iframe_wheel!(v.child, 64) === false && v.child.scroll == 0
            v.child.alt = false

            # And a child that *did* ask still gets the report, unchanged in
            # meaning and moved into its own coordinates.
            v.child.wantsmouse = true
            @test W.retarget_mouse(v, wheel(64), 100, 30) ==
                  collect(codeunits("\e[<64;6;6M"))
            @test v.child.scroll == 0                 # answered there, not here
        end
        W.mux_kill(n)
    end
end

@testset "^]tab moves between the child and what is beside it" begin
    # An agent worth watching is one you want to read the pull request against
    # while it works, and every key belonged to the child - so watching it meant
    # not reading, and reading meant leaving. `^]tab` used to be the leaving.
    ENV["COLUMNS"], ENV["LINES"] = "170", "40"
    if W.mux_bin() === nothing
        @info "no tmux; skipping the pane focus test"
    else
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
        n = "wl-test-focus-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sleep 120")
        v = W.pane_view(n, "demo", ctrl)
        @test v !== nothing && v.beside === st
        push!(ctrl.stack, v)
        withenv("LINES" => "40", "COLUMNS" => "170") do
            W.pane_sync!(v)
            # The child has the keyboard, and that is what `wantsraw` says.
            @test v.focus === :child
            @test W.wantsraw(v) === true

            # `^]tab` hands the keys to the thread instead of leaving.
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('\t')], ctrl) === :ok
            @test v.focus === :read
            @test W.wantsraw(v) === false          # decoded keys now, not bytes
            @test W.mux_alive(n) === true          # and the child is still there
            @test st.focus === :detail             # aimed at the thread, not the list
            ls = split(W.render(v, 170, 40), "\n")
            @test length(ls) == 40 && all(W.awidth(l) == 170 for l in ls)

            # Keys this view does not name are the thread's: `j` walks the
            # comments rather than reaching a shell that would beep at it.
            was = st.nrow
            W.handle!(v, Int('j'), ctrl)
            @test st.nrow >= was
            W.handle!(v, Int('o'), ctrl)           # and the mode keys work too
            @test st.mode === :comments

            # And the child gets *nothing* while it does not have the focus -
            # not even the keys that reach it from the other side. `r` used to
            # re-read the child's screen from here, which is one key of the
            # pane's in the middle of a run of the browser's: the reader would
            # have had to hold a list instead of looking at which side is lit.
            it = st.items[st.sel]
            was_unread = it.url in st.unread
            W.handle!(v, Int('r'), ctrl)           # the browser's read toggle
            @test (it.url in st.unread) != was_unread
            W.handle!(v, Int('r'), ctrl)           # put it back
            @test (it.url in st.unread) == was_unread
            # `K` is the pane's, so from here it is the browser's - and the
            # browser does not bind it, so nothing happens and nothing dies.
            @test W.handle!(v, Int('K'), ctrl) === :ok
            @test W.mux_alive(n) === true
            @test v.focus === :read

            # `tab` goes back to the child, the way `^]tab` came out of it.
            @test W.handle!(v, 9, ctrl) === :ok
            @test v.focus === :child && W.wantsraw(v) === true

            # Escape restores the list view - from the reading side only, since
            # on the child's side escape is the child's.
            W.onraw!(v, [W.IFRAME_PREFIX, UInt8('\t')], ctrl)
            @test W.handle!(v, 27, ctrl) === :pop
            @test W.mux_alive(n) === true

            # And so do `t` and `T`: the key that put the pane on the screen is
            # the one that takes it off again.
            for k in (Int('t'), Int('T'))
                v2 = W.pane_view(n, "demo", ctrl)
                W.onraw!(v2, [W.IFRAME_PREFIX, UInt8('\t')], ctrl)
                @test v2.focus === :read
                @test W.handle!(v2, k, ctrl) === :pop
                @test W.mux_alive(n) === true
            end

            # And `q`, which is what leaves a view everywhere else in this
            # program: the worktree list, a pane whose child has gone, and the
            # browser - where the view being left is the one every other view is
            # a view from, so leaving it is leaving the program and is the one
            # place it stops to ask. It used to be forwarded, so the same key
            # ended the session from one side of the split and closed a pane
            # from the other.
            v6 = W.pane_view(n, "demo", ctrl)
            W.onraw!(v6, [W.IFRAME_PREFIX, UInt8('\t')], ctrl)
            @test v6.focus === :read
            @test W.handle!(v6, Int('q'), ctrl) === :pop
            @test W.mux_alive(n) === true          # the session keeps running
            @test !any(x -> x isa W.ConfirmView, ctrl.stack)   # and nothing asked

            # `^]q` is the one that leaves from the child's side.
            v3 = W.pane_view(n, "demo", ctrl)
            @test W.onraw!(v3, [W.IFRAME_PREFIX, UInt8('q')], ctrl) === :pop
            @test W.mux_alive(n) === true

            # Six keys are the prefix's own and the rest are the browser's:
            # having said "this one is not the child's", the sensible place for
            # a key this layer has no use for is the other side of the screen.
            v5 = W.pane_view(n, "demo", ctrl)
            push!(ctrl.stack, v5)
            was = st.mode
            st.mode = :diff
            @test W.onraw!(v5, [W.IFRAME_PREFIX, UInt8('o')], ctrl) === :ok
            @test st.mode === :comments            # reached the browser
            @test v5.focus === :child              # without leaving the child
            @test W.wantsraw(v5) === true
            st.mode = was
            # `^]m` was the ask that made this worth doing: toggling the mouse
            # capture over the pane is the browser's `m`, and nothing here had
            # to know that.
            before = ctrl.mouse
            W.onraw!(v5, [W.IFRAME_PREFIX, UInt8('m')], ctrl)
            @test ctrl.mouse != before
            # The browser's answer shows where the key was pressed: its own
            # footer is not on screen here.
            @test occursin("mouse", v5.child.status)
            W.onraw!(v5, [W.IFRAME_PREFIX, UInt8('m')], ctrl)
            @test ctrl.mouse == before
            pop!(ctrl.stack)
            W.iframe_close!(v5.child)
        end
        # With no room for two columns there is nothing to move to, so the key
        # keeps the meaning it always had.
        withenv("LINES" => "24", "COLUMNS" => "80") do
            v4 = W.pane_view(n, "demo", ctrl)
            @test W.readable(v4) === false
            @test W.onraw!(v4, [W.IFRAME_PREFIX, UInt8('\t')], ctrl) === :pop
        end
        W.mux_kill(n)
        pop!(ctrl.stack)
    end
end

@testset "a key whose subject is not on screen" begin
    # `f` opens the filter pane *and* moves the browser's focus to the list, and
    # the list is not drawn beside a child - the pane took those columns. So a
    # forwarded `f` handed the keys to a pane nobody could see, with `f` again
    # toggling the mode back and leaving the focus where it was.
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
    v = W.PaneView(W.IFrame("n", "t"), st, :read)
    was = (st.lmode, st.focus)
    @test W.forward!(v, Int('f'), ctrl) === :ok
    @test (st.lmode, st.focus) == was
    @test occursin("not on screen", v.child.status) && occursin("q leaves", v.child.status)
    # Everything else is still the browser's, which is the rule this is the one
    # exception to.
    st.mode = :thread
    @test W.forward!(v, Int('o'), ctrl) === :ok
    @test st.mode === :comments
end
