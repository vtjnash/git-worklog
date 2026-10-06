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
            @test W.pane_sync!(v, ctrl) === true
            @test v.child.sized == W.iframe_box(80, 24)
            @test length(v.child.frame) == 21           # the height it was just given
            @test occursin("green", join(v.child.frame))
            @test occursin("\e[", join(v.child.frame))  # colour kept, not stripped
            ls = W.render(v, 80, 24)
            @test length(ls) == 24 && all(width(l) == 80 for l in ls)
        end
        # A different size re-sizes the child, not just the box drawn round it.
        withenv("LINES" => "40", "COLUMNS" => "120") do
            W.pane_sync!(v, ctrl)
            @test v.child.sized == W.iframe_box(120, 40)
            @test length(v.child.frame) == 37
            ls = W.render(v, 120, 40)
            @test length(ls) == 40 && all(width(l) == 120 for l in ls)
        end

        # Every row is closed off when it is written, or an unterminated colour
        # would run out of the content and into the border: as tmux gave it,
        # then a reset, then the column after the pane.
        fb = String(TermInput.frame_bytes(W.render(v, 120, 40)))
        @test occursin(string(v.child.frame[1], "\e[0m\e[", 3 + v.child.sized[1], "G"), fb)

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
            strip(read(TermIFrame.mux_cmd("-L", sock, a...), String))
        catch; "" end
        killnested() = try
            run(pipeline(TermIFrame.mux_cmd("-L", sock, "kill-server"); stderr = devnull))
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
            sleep(2.5); W.pane_sync!(v, ctrl)
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
                W.pane_sync!(v, ctrl)
                v.child.history > 100 && break
                sleep(0.25)
            end
            @test v.child.wantsmouse === false        # a shell asked for nothing
            @test v.child.alt === false && v.child.history > 100
            live = unstyled(first(v.child.frame))
            ox, oy = W.pane_origin(v, 100)
            wheel(b) = collect(codeunits(string("\e[<", b, ";", ox + 5, ";", oy + 5, "M")))

            W.onraw!(v, wheel(64), ctrl)
            @test v.child.scroll == TermIFrame.WHEEL_ROWS
            @test unstyled(first(v.child.frame)) != live
            # The window moved by exactly what the wheel says it moved by.
            @test parse(Int, unstyled(first(v.child.frame))) ==
                  parse(Int, live) - TermIFrame.WHEEL_ROWS
            # No cursor while looking at the past: it is not on these rows.
            @test W.viewcursor(v, 100, 30) === nothing
            # And the note says where you are, over anything else it might say.
            v.child.status = "something happened"
            @test occursin("rows back", unstyled(last(W.pane_column(v, 70, 30))))
            v.child.status = ""

            W.onraw!(v, wheel(65), ctrl)
            @test v.child.scroll == 0 && unstyled(first(v.child.frame)) == live

            # Shift- and ctrl-wheel are the same request refined, not a
            # different one, so they scroll rather than falling through.
            for b in (64 + 4, 64 + 16)
                v.child.scroll = 0
                @test TermIFrame.iframe_wheel!(v.child, b) === true && v.child.scroll == TermIFrame.WHEEL_ROWS
            end
            v.child.scroll = 0

            # It stops at the top of the history rather than running past it.
            for _ in 1:(v.child.history ÷ TermIFrame.WHEEL_ROWS + 20)
                TermIFrame.iframe_wheel!(v.child, 64)
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

            ls = W.render(v, 100, 30)
            @test length(ls) == 30 && all(width(l) == 100 for l in ls)

            # On the alternate screen there is nothing behind the child but the
            # wreckage of its own redraws, so this refuses - which is also why
            # a nested tmux gets nothing from it.
            v.child.alt = true
            @test TermIFrame.iframe_wheel!(v.child, 64) === false && v.child.scroll == 0
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
            W.pane_sync!(v, ctrl)
            # The child has the keyboard, and that is what `wantsraw` says.
            @test v.focus === :child
            @test W.wantsraw(v) === true

            # `^]tab` hands the keys to the thread instead of leaving.
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('\t')], ctrl) === :ok
            @test v.focus === :read

            # ...and so does `^][`, which is the same move under the hand: `]`
            # and `[` are one key apart, so it is the right pinky twice with the
            # left one never leaving control, where `^]tab` sends it back up to
            # tab. It is the most-pressed key here and was the slowest to type.
            v.focus = :child
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('[')], ctrl) === :ok
            @test v.focus === :read
            @test W.mux_alive(n) === true          # and it did not leave, either
            # Both are named in `^]?`, which is the exhaustive list and has the
            # room to be one.
            @test occursin("^]tab or ^][", W.pane_keys(v, ctrl))
            # The standing row under the child carries `^][` and not `^]tab`,
            # and spends what that saves on `^]K` - which is the one key here
            # that cannot be undone and was reachable only through `^]?`. `tab`
            # is what changes sides everywhere in this program, so a reader who
            # has `^][` will try it whether or not the row says so.
            v.focus = :child
            row = unstyled(last(W.pane_column(v, 100, 12)))
            @test occursin("^][ read beside it", row) && occursin("^]K kill", row)
            @test !occursin("^]tab", row)
            # A bare `[` is still the child's - only after the prefix is it ours.
            v.focus = :child
            @test W.onraw!(v, [UInt8('[')], ctrl) === :ok
            @test v.focus === :child
            # ...and back to reading, which is where the rest of this is written.
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('[')], ctrl) === :ok
            @test v.focus === :read
            @test W.wantsraw(v) === false          # decoded keys now, not bytes
            @test W.mux_alive(n) === true          # and the child is still there
            @test st.focus === :detail             # aimed at the thread, not the list
            ls = W.render(v, 170, 40)
            @test length(ls) == 40 && all(width(l) == 170 for l in ls)

            # Keys this view does not name are the thread's: `j` walks the
            # comments rather than reaching a shell that would beep at it.
            was = st.nrow
            W.handle!(v, Int('j'), ctrl)
            @test st.nrow >= was
            W.handle!(v, Int('h'), ctrl)           # and the mode keys work too
            @test st.mode === :comments

            # And the child gets *nothing* while it does not have the focus -
            # not even the keys that reach it from the other side. `r` used to
            # re-read the child's screen from here, which is one key of the
            # pane's in the middle of a run of the browser's: the reader would
            # have had to hold a list instead of looking at which side is lit.
            # Everything, so the row stays under the cursor while it is toggled:
            # the list the browser opens on is what moved, and reading something
            # takes it out of that.
            st.filters = W.everything(); W.refilter!(st)
            it = st.items[st.sel]
            was = W.done_at(it.url)
            W.handle!(v, Int('e'), ctrl)           # the browser's read toggle
            @test W.done_at(it.url) != was
            W.handle!(v, Int('e'), ctrl)           # put it back
            @test W.done_at(it.url) == was
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
            # On the item the thread is already reading: a key about an item is
            # about the session's, which is the next testset.
            W.mux_tag!(n; item = st.items[st.sel].ref, url = st.items[st.sel].url)
            was = st.mode
            st.mode = :diff
            @test W.onraw!(v5, [W.IFRAME_PREFIX, UInt8('h')], ctrl) === :ok
            @test st.mode === :comments            # reached the browser
            @test v5.focus === :child              # without leaving the child
            @test W.wantsraw(v5) === true
            st.mode = was
            # `^]m` was the ask that made this worth doing: toggling the mouse
            # capture over the pane is the browser's `m`, and nothing here had
            # to know that.
            before = ctrl.term.mouse
            W.onraw!(v5, [W.IFRAME_PREFIX, UInt8('m')], ctrl)
            @test ctrl.term.mouse != before
            # The browser's answer shows where the key was pressed: its own
            # footer is not on screen here.
            @test occursin("mouse", v5.child.status)
            W.onraw!(v5, [W.IFRAME_PREFIX, UInt8('m')], ctrl)
            @test ctrl.term.mouse == before
            pop!(ctrl.stack)
            W.iframe_close!(v5.child)
            # With nothing beside the child there is no browser for `^]m` to
            # reach, and it said the keys instead - which left a shell in here
            # no way to the terminal's own selection. It is answered here, and
            # the browser's mirror of it kept, since that is what its footer
            # and its copy marks read.
            v6 = W.pane_view(n, "demo", ctrl; beside = nothing)
            push!(ctrl.stack, v6)
            W.onraw!(v6, [W.IFRAME_PREFIX, UInt8('m')], ctrl)
            @test ctrl.term.mouse != before && st.mouse == ctrl.term.mouse
            @test occursin("mouse", v6.child.status)
            @test W.mux_alive(n) && last(ctrl.stack) === v6
            W.onraw!(v6, [W.IFRAME_PREFIX, UInt8('m')], ctrl)
            @test ctrl.term.mouse == before && st.mouse == ctrl.term.mouse
            @test occursin("^]m", W.pane_keys(v6, ctrl))
            pop!(ctrl.stack)
            W.iframe_close!(v6.child)
        end
        # With no room for two columns there is nothing to move to, so the key
        # keeps the meaning it always had.
        withenv("LINES" => "24", "COLUMNS" => "80") do
            v4 = W.pane_view(n, "demo", ctrl)
            @test W.readable(v4, ctrl) === false
            @test W.onraw!(v4, [W.IFRAME_PREFIX, UInt8('\t')], ctrl) === :pop
        end
        W.mux_kill(n)
        pop!(ctrl.stack)
    end
end

@testset "^] keys are about the pane's own session" begin
    # From inside a pane the subject is the pane: a key after the prefix that
    # the pane does not answer went to the browser, and so acted on whatever
    # item the thread beside it was showing - which need not be the one the
    # session is working on.
    ENV["COLUMNS"], ENV["LINES"] = "170", "40"
    if W.mux_bin() === nothing
        @info "no tmux; skipping the pane subject test"
    else
        keep = W.LOCAL[]
        W.LOCAL[] = fresh_local()
        wt = mktempdir()
        run(pipeline(`git -C $wt init -q -b topic`; stdout = devnull, stderr = devnull))
        a = W.Item(url = "https://github.com/o/r/pull/7", ref = "r#7", repo = "o/r",
                   number = 7, title = "the one being read", state = "OPEN",
                   moved_at = "2026-09-01T00:00:00Z")
        b = W.Item(url = "https://github.com/o/r/pull/8", ref = "r#8", repo = "o/r",
                   number = 8, title = "the one being worked on", state = "OPEN",
                   moved_at = "2026-09-02T00:00:00Z")
        st = W.BState([a, b], "t")
        st.filters = W.everything(); W.refilter!(st)
        st.sel = findfirst(x -> x.url == a.url, st.items)
        st.focus = :detail
        # Neither thread is anything to send `gh` after: the one the key will
        # move the reader to is already "loaded", in the mode it will ask for.
        st.loaded = string(b.url, ":comments"); st.metakey = b.url
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
        n = "wl-test-subject-1"
        W.mux_kill(n)
        W.mux_start(n, wt, "sleep 120")
        W.mux_tag!(n; worktree = wt, kind = :shell, item = b.ref, url = b.url, branch = "topic")
        withenv("LINES" => "40", "COLUMNS" => "170") do
            v = W.pane_view(n, "r#8", ctrl)
            push!(ctrl.stack, v)
            # `^]h` is the history of the session's item, and the thread moves to
            # it to show it - the focus left where it was, on the thread.
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('h')], ctrl) === :ok
            @test st.items[st.sel].url == b.url && st.mode === :comments
            @test st.focus === :detail && v.focus === :child
            # `^]e` marks it, not the item that was beside it.
            st.sel = findfirst(x -> x.url == a.url, st.items)
            st.loaded = string(b.url, ":", st.mode)
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('e')], ctrl) === :ok
            @test W.done_at(b.url) !== nothing && W.done_at(a.url) === nothing
            # Keys that point at a place in the thread stay the thread's, on
            # whatever it shows: `^]j` does not move it back.
            st.sel = findfirst(x -> x.url == a.url, st.items)
            W.onraw!(v, [W.IFRAME_PREFIX, UInt8('j')], ctrl)
            @test st.items[st.sel].url == a.url
            # From the reading side every key is the reader's, which is what
            # `^]tab` is for.
            W.onraw!(v, [W.IFRAME_PREFIX, UInt8('\t')], ctrl)
            @test v.focus === :read
            W.handle!(v, Int('h'), ctrl)
            @test st.items[st.sel].url == a.url
            v.focus = :child

            # `^]t` is the shell in the session's own worktree - this one - and
            # `^]T` its agent, found there by worktree and not through an item.
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('t')], ctrl) === :ok
            @test last(ctrl.stack) === v && occursin("already in", v.child.status)
            ag = "wl-test-subject-agent"
            W.mux_kill(ag)
            W.mux_start(ag, wt, "sleep 120")
            W.mux_tag!(ag; worktree = wt, kind = :agent, item = b.ref, url = b.url)
            @test W.onraw!(v, [W.IFRAME_PREFIX, UInt8('T')], ctrl) === :ok
            top = last(ctrl.stack)
            @test top isa W.PaneView && top !== v
            s2 = W.pane_session(top)
            @test s2 !== nothing && s2.kind == "agent" && s2.worktree == wt
            @test occursin("back in", top.child.status)
            # And back again, the same way.
            @test W.onraw!(top, [W.IFRAME_PREFIX, UInt8('t')], ctrl) === :ok
            @test W.pane_session(last(ctrl.stack)).kind == "shell"
            for s in W.session_list()
                s.worktree == wt && W.mux_kill(s.name)
            end
            while last(ctrl.stack) isa W.PaneView
                W.iframe_close!(pop!(ctrl.stack).child)
            end

            # A session on no item has nothing for an item key to be about, and
            # the thread is not moved to guess one.
            W.mux_start(n, wt, "sleep 120")
            W.mux_tag!(n; worktree = wt, kind = :shell)
            v2 = W.pane_view(n, "t", ctrl)
            push!(ctrl.stack, v2)
            st.sel = findfirst(x -> x.url == a.url, st.items)
            was = st.mode
            @test W.onraw!(v2, [W.IFRAME_PREFIX, UInt8('d')], ctrl) === :ok
            @test st.mode === was && occursin("no item", v2.child.status)
            W.iframe_close!(pop!(ctrl.stack).child)
        end
        W.mux_kill(n)
        W.LOCAL[] = keep
    end
end

@testset "a session whose command failed shows why" begin
    # `T` with an agent command that could not run said only "could not
    # attach": the session had ended before anything looked at it. The server
    # keeps a failed child's pane now, and it opens as it died.
    ENV["COLUMNS"], ENV["LINES"] = "170", "40"
    if W.mux_bin() === nothing
        @info "no tmux; skipping the failed session test"
    else
        wt = mktempdir()
        run(pipeline(`git -C $wt init -q -b topic`; stdout = devnull, stderr = devnull))
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
        withenv("LINES" => "40", "COLUMNS" => "170") do
            r = W.enter_session(wt, "topic", "", "", "", "failing", ctrl, :shell,
                                (_, _) -> "echo boom; exit 3")
            v = last(ctrl.stack)
            @test v isa W.PaneView && v.child.exited == 3
            @test occursin("status 3", r) && occursin("q clears it", r)
            @test any(l -> occursin("boom", unstyled(l)), v.child.frame)
            name = v.child.name
            @test W.mux_alive(name)
            # Leaving it is the end of it: nothing is running to come back to.
            @test W.handle!(v, Int('q'), ctrl) === :pop
            pop!(ctrl.stack)
            @test !W.mux_alive(name)
        end
        pop!(ctrl.stack)
    end
end

@testset "a session whose child exited is kept until it is seen and cleared" begin
    # An agent that finished with nobody watching ended its session, and with
    # it went whatever it had said last; a shell's `exit` did the same. The
    # pane is kept now, whatever the status, and the session says `exited`
    # wherever it is drawn until `T` has opened it and `q` closed it. That is
    # a state, not a bell: nothing rings, the item is not unread for it, and
    # looking does not clear it.
    ENV["COLUMNS"], ENV["LINES"] = "170", "40"
    if W.mux_bin() === nothing
        @info "no tmux; skipping the exited session test"
    else
        wt = mktempdir()
        run(pipeline(`git -C $wt init -q -b topic`; stdout = devnull, stderr = devnull))
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
        url = "https://github.com/someone/else/pull/1"
        withenv("LINES" => "40", "COLUMNS" => "170") do
            # With nobody looking: started as `T` starts one, and never entered.
            n = W.mux_name(W.SESSION_PREFIX, basename(wt), "topic", ""; kind = :agent)
            W.mux_kill(n)
            @test first(W.mux_start(n, wt, "echo farewell"))
            @test W.mux_tag!(n; worktree = wt, kind = :agent, item = "someone/else#1", url = url)
            row() = only(filter(r -> r.name == n, W.session_list()))
            @test timedwait(() -> row().dead, 5.0) === :ok
            @test !row().bell && isempty(W.rang_urls())
            @test unstyled(W.session_words(row(), :agent)) == "exited"
            # `T` finds it rather than starting another, and shows it as it went.
            r = W.enter_session(wt, "topic", "someone/else#1", "", url, "agent", ctrl, :agent,
                                (_, _) -> "sleep 120")
            v = last(ctrl.stack)
            @test v isa W.PaneView && v.child.name == n && v.child.exited == 0
            @test occursin("exited with status 0", r) && occursin("q clears it", r)
            @test any(l -> occursin("farewell", unstyled(l)), v.child.frame)
            # Looked at, it is still there and still says so; `q` is the end.
            @test W.mux_alive(n) && row().dead
            @test W.handle!(v, Int('q'), ctrl) === :pop
            pop!(ctrl.stack)
            @test !W.mux_alive(n)
        end
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
    @test W.forward!(v, Int('h'), ctrl) === :ok
    @test st.mode === :comments
end

@testset "a composer is drawn beside what it is about" begin
    # A comment is written *at* a diff, a review message at the commits it
    # lands, a note at the item it is a note on - and each of them used to take
    # the whole screen and put that behind it. So writing a sentence, checking
    # the hunk and starting over was: escape, read, press the key again.
    #
    # The split already existed for `t` and `T` and none of it is about a child
    # process, so a composer goes where the iframe goes.
    ENV["COLUMNS"], ENV["LINES"] = "170", "40"
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true; W.push_view!(ctrl, st)
    it = st.items[st.sel]

    W.handle!(st, Int('C'), ctrl)
    v = last(ctrl.stack)
    @test v isa W.SideView && v.inner isa W.EditorView && v.beside === st
    # A question that hands the keys back, not a place - so `t` from here must
    # not clear it the way it clears a pane.
    @test W.isdialog(v)
    # Decoded keys, not bytes: there is no child on either side of this one.
    @test W.wantsraw(v) === false
    # Both columns, a row at a time, and the frame is exactly the screen.
    ls = W.render(v, 170, 40)
    @test length(ls) == 40 && all(width(l) == 170 for l in ls)
    # The left is the detail pane and the right is the composer, so the item is
    # readable while the message about it is written.
    @test occursin("alice", unstyled(join(ls, "\n")))
    @test occursin(it.ref, unstyled(join(ls, "\n")))

    # `tab` moves the keyboard across, which is what `tab` means everywhere in
    # this program - and is why the merge composer's cycle is `^x` and not this.
    @test W.handle!(v, 9, ctrl) === :ok
    @test v.focus === :read && st.focus === :detail
    # Keys the reading side does not name are the browser's, exactly as beside a
    # hosted pane: `j` walks the thread and the mode keys change what is shown.
    was = st.nrow
    W.handle!(v, Int('j'), ctrl)
    @test st.nrow >= was
    W.handle!(v, Int('h'), ctrl)
    @test st.mode === :comments
    # What the browser said goes under the composer, since the browser's own
    # footer is not on screen - the composer took the columns it would be in.
    @test !isempty(v.inner.status)

    # **Four keys come back, not one.** `q` and escape are what the fingers
    # produce in a screen that is not the one being worked in, and `q` in the
    # browser ends the program - quitting out from under a half-written comment
    # is the one thing this view exists to make impossible.
    for k in (9, W.K_STAB, 27, Int('q'))
        v.focus = :read
        @test W.handle!(v, k, ctrl) === :ok
        @test v.focus === :inner
    end
    @test length(ctrl.stack) == 2                 # and none of them quit
    # And `f` is refused here for the reason it is refused beside a pane: it
    # opens the filter pane and aims the browser at the list, which is not drawn.
    v.focus = :read
    W.handle!(v, Int('f'), ctrl)
    @test st.lmode !== :filters
    v.focus = :inner

    # The composer answers exactly as it would full screen, so what comes back
    # from the pair is what comes back from the box.
    for c in "a remark"; W.handle!(v, W.keycode(c), ctrl); end
    @test W.text(v.inner) == "a remark"
    # Escape asks before throwing words away, and the question names the
    # composer - which is not itself on the stack. Answering it has to reach the
    # pair, or `y` to "discard what you have written?" keeps it.
    @test W.handle!(v, 27, ctrl) === :ok
    q = last(ctrl.stack)
    @test q isa W.ConfirmView && occursin("Discard", q.title)
    @test W.handle!(q, Int('y'), ctrl) === :pop
    @test !any(x -> x === v, ctrl.stack)
    empty!(ctrl.stack); W.push_view!(ctrl, st)

    # Below the split there is no room for two columns, and the composer takes
    # the screen the way it always did. A composer is the half that has to stay
    # usable, which is the same rule the hosted pane follows.
    ENV["COLUMNS"] = "120"
    W.handle!(st, Int('C'), ctrl)
    @test last(ctrl.stack) isa W.EditorView
    ENV["COLUMNS"] = "170"
    empty!(ctrl.stack)
end
