# What this program asks of a multiplexer, over `TermIFrame`.
#
# The protocol, the naming rules, the escaping and the clipboard relay are the
# package's and are tested there - `TermIFrame/test/runtests.jl` drives them
# from strings, with no tmux and no tty. What is left here is this program's
# use of it: the names *it* builds, the tags it files sessions under, and that
# a session outlives the view of it.

@testset "arrow keys and shift-tab" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller()
    st.focus = :list
    W.handle!(st, W.K_DOWN, ctrl)
    @test st.sel == 2
    W.handle!(st, W.K_UP, ctrl)
    @test st.sel == 1

    # Detail pane: shift-tab cycles focus, and the arrows move by row. Fresh
    # state, because moving the list selection above started a fetch that
    # cleared the nodes - which is exactly what it should do.
    st = mkstate()
    W.handle!(st, W.K_STAB, ctrl)
    @test st.focus === :detail
    W.handle!(st, W.K_DOWN, ctrl)
    @test st.nrow == 2
    W.handle!(st, W.K_PGDN, ctrl)
    @test st.nrow == length(W.rows(st.nodes, W.layout(160, 50, st.nmeta).riw))
    W.handle!(st, W.K_HOME, ctrl)
    @test st.nrow == 1
end

@testset "the sessions this program owns" begin
    # A name says which copy of the repo, which state of it, and what was in
    # view - all three, because each answers a different question and the list
    # is unreadable without any one of them. The rewriting of `.` and `:`, and
    # the parts being optional, are `mux_name`'s and are tested with it.
    @test W.mux_name("julia", "master", "62841") == "wl-julia-master-62841"
    @test W.mux_name("julia", "master", "62841"; kind = :agent) ==
          "wl-julia-master-62841-agent"
    @test W.mux_name("julia", "", "62841") == "wl-julia-62841"
    # Every one of them is under this program's prefix, which is what makes a
    # session ours to list and to kill.
    @test all(startswith(n, "wl-") for n in W.mux_sessions())

    if W.mux_bin() === nothing
        @info "no tmux; skipping the session lifecycle test"
    else
        n = "wl-test-lifecycle-1"
        W.mux_kill(n)                                   # from an earlier run
        @test W.mux_alive(n) === false
        @test first(W.mux_start(n, pwd(), "sleep 120")) === true
        @test W.mux_alive(n) === true
        @test first(W.mux_start(n, pwd(), "sleep 120")) === true   # idempotent
        @test n in W.mux_sessions()

        # What a session *is* lives in its options, so that the name is free to
        # change under it. The worktree is the identity because the worktree is
        # what is actually shared, and the kind because a shell and an agent in
        # one checkout are two different things.
        wt = mktempdir()
        @test W.mux_tag!(n; worktree = wt, kind = :shell, item = "julia#62841")
        found = W.mux_find(wt, :shell)
        @test found !== nothing && found.name == n && found.item == "julia#62841"
        @test W.mux_find(wt, :agent) === nothing        # a separate slot

        # Renaming is what keeps the label current without starting anything
        # new: same session, different name, still found by the same key.
        n3 = "wl-test-lifecycle-renamed"
        @test W.mux_rename(n, n3) === true
        @test W.mux_alive(n) === false && W.mux_alive(n3) === true
        again = W.mux_find(wt, :shell)
        @test again !== nothing && again.name == n3

        @test W.mux_kill(n3) === true
        @test W.mux_alive(n3) === false
    end
end

@testset "the clipboard reaches the terminal a person is looking at" begin
    # `capture-pane` reads the grid, and a grid is made of cells - so a sequence
    # that paints no cell is not in it and never can be. OSC 52 is the one that
    # matters: an agent several terminals down that copies something has no
    # other way to reach the terminal a person is looking at. Finding it in the
    # stream is `passthrough`'s and is tested with it; that it is really in the
    # stream was measured, and is what this checks.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the live clipboard relay"
    else
        n = "wl-test-osc52"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh")
        got = String[]
        c = W.mux_open(n; onoutput = (_, b) -> append!(got, W.passthrough(b)))
        @test c !== nothing
        sleep(1.0)
        W.mux_keys(c, codeunits("printf '\\033]52;c;d29ya2xvZyBjb3BpZWQ=\\007'\r"))
        sleep(1.5)
        @test length(got) == 1          # the emitted one, not the echoed text
        @test occursin("d29ya2xvZyBjb3BpZWQ=", got[1])
        W.mux_close(c)
        W.mux_kill(n)
    end
end

@testset "one client, driving a real session" begin
    # The parser is a pure function of one line and is tested in the package.
    # This is the rest of it: that a real tmux answers in that shape, that the
    # reply stream is lined up with the commands, and that an error is an answer
    # the client keeps working after.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the live control-mode test"
    else
        n = "wl-test-control-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf READY; sleep 120'")
        woke = Ref(0)
        # Two arguments: the pane, and what it wrote. The bytes are what the
        # clipboard relay above reads; a redraw only needs to know it happened.
        c = W.mux_open(n; onoutput = (_, _) -> (woke[] += 1))
        @test c !== nothing
        # Attaching emits a reply block of its own; if it were left in the
        # queue every command here would return the previous one's answer.
        @test W.mux_resize(c, 60, 8) === true
        scr = W.mux_capture(c; escapes = false)
        @test length(scr) == 8                          # the size just asked for
        @test first(scr) == "READY"
        @test W.mux_keys(c, "xyz") === true
        sleep(0.5)
        @test occursin("xyz", join(W.mux_capture(c; escapes = false)))
        @test woke[] > 0                                # %output arrived unasked
        # An error is an answer, and the client keeps working after one.
        ok, lines = W.mux_ask(c, "no-such-command")
        @test ok === false && occursin("unknown command", join(lines))
        @test W.mux_ask(c, "display-message -p still-here") == (true, ["still-here"])
        W.mux_close(c)
        @test W.mux_ask(c, "display-message -p x")[1] === false
        W.mux_kill(n)
    end
end
