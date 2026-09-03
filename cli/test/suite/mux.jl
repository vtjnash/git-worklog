# tmux itself: sessions, and the control-mode protocol read back as text.
# The protocol half is a pure function of lines and needs no tmux at all.

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

@testset "multiplexer sessions" begin
    # Naming is pure, so it is tested whether or not a tmux exists here. All
    # three parts are in it: which copy of the repo, which state of it, and
    # what was in view.
    @test W.mux_name("julia", "master", "62841") == "wl-julia-master-62841"
    @test W.mux_name("julia", "master", "62841", :agent) == "wl-julia-master-62841-agent"

    # A branch keeps its owner prefix: tmux leaves `/` alone.
    @test W.mux_name("julia-wt2", "vtjnash/fix", "1") == "wl-julia-wt2-vtjnash/fix-1"

    # tmux does not reject `.` or `:` in a session name, it rewrites them to
    # `_` and says nothing. A name that did not do the same substitution would
    # create a session and then never find it again.
    @test W.mux_name("Distributed.jl", "release-1.12", "198") == "wl-Distributed_jl-release-1_12-198"
    @test !occursin('.', W.mux_name("y.z.jl", "a.b", "3"))
    @test !occursin(':', W.mux_name("a:b", "c:d", "4"))

    # A worktree with no branch known still gets a usable name.
    @test W.mux_name("julia", "", "62841") == "wl-julia-62841"

    # A child starts as its own session. Only what this process actually
    # inherited is scrubbed, so on a machine where the browser was not started
    # from inside an agent this is the identity and costs nothing.
    withenv("CLAUDE_CODE_MESSAGING_TOKEN" => "x", "CLAUDE_CODE_CHILD_SESSION" => "y") do
        w = W.standalone("claude")
        @test startswith(w, "env -u ") && endswith(w, " claude")
        @test occursin("-u CLAUDE_CODE_MESSAGING_TOKEN", w)
        @test occursin("-u CLAUDE_CODE_CHILD_SESSION", w)
    end
    withenv((k => nothing for k in filter(x -> startswith(x, "CLAUDE"), collect(keys(ENV))))...) do
        @test W.standalone("claude") == "claude"
    end

    # A missing binary has to be an answer, not an exception: every caller is
    # on a keystroke path.
    withenv("WORKLOG_TMUX" => "/nonexistent/tmux") do
        @test W.mux_bin() === nothing
        @test W.mux("list-sessions") == (false, "no tmux on PATH")
        @test W.mux_alive("wl-nothing") === false
        @test W.mux_sessions() == String[]
    end

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
        # what is actually shared.
        wt = mktempdir()
        @test W.mux_tag!(n, wt, :shell, "julia#62841") === true
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

@testset "control-mode protocol" begin
    # The parser is a pure function of one line and the state before it, so the
    # protocol is driven from strings the way `readevent` is driven from bytes.
    p = W.MuxProto()
    @test W.mux_feed!(p, "%begin 1788 42 1") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "hello") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "%end 1788 42 1") == (:reply, true, ["hello"])

    # A failed command closes its block with %error, and the lines it did emit
    # are the error text.
    @test W.mux_feed!(p, "%begin 1788 43 1") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "unknown command: nope") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "%error 1788 43 1") == (:reply, false, ["unknown command: nope"])

    # A line inside a block is content, never protocol. A capture-pane of a
    # screen with a percent sign at the start of a line would otherwise be
    # parsed as a notification and vanish from the reply.
    W.mux_feed!(p, "%begin 1788 44 1")
    @test W.mux_feed!(p, "%output is just text here") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "100%") == (:more, nothing, nothing)
    @test W.mux_feed!(p, "%end 1788 44 1") == (:reply, true, ["%output is just text here", "100%"])

    # Outside a block, notifications are themselves.
    @test W.mux_feed!(p, "%output %10 abc") == (:output, "%10", "abc")
    @test W.mux_feed!(p, "%session-changed \$1 wl") == (:notice, "session-changed", "\$1 wl")
    @test W.mux_feed!(p, "%exit")[1] === :notice

    # tmux escapes bytes below 0x20 and the backslash as three octal digits,
    # and passes everything from 0x20 up through raw.
    @test W.mux_unescape("a\\011b") == "a\tb"
    @test W.mux_unescape("back\\134slash") == "back\\slash"
    @test W.mux_unescape("\\033[1m") == "\e[1m"
    @test W.mux_unescape("\\015\\012") == "\r\n"
    @test W.mux_unescape("plain") == "plain"
    @test W.mux_unescape("e-é del\x7f pct-%") == "e-é del\x7f pct-%"
    @test W.mux_unescape("\\9zz") == "\\9zz"           # not octal; left alone
    @test W.mux_unescape("tail\\01") == "tail\\01"     # truncated; left alone
    @test W.mux_feed!(p, "%output %3 \\033[H")[3] == "\e[H"

    if W.mux_bin() === nothing
        @info "no tmux; skipping the live control-mode test"
    else
        n = "wl-test-control-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf READY; sleep 120'")
        woke = Ref(0)
        c = W.mux_open(n; onoutput = _ -> (woke[] += 1))
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
