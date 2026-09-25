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
        carry = Ref("")
        c = W.mux_open(n; onoutput = (_, b) -> append!(got, W.passthrough(carry, b)))
        @test c !== nothing
        sleep(1.0)
        W.mux_keys(c, codeunits("printf '\\033]52;c;d29ya2xvZyBjb3BpZWQ=\\007'\r"))
        sleep(1.5)
        @test length(got) == 1          # the emitted one, not the echoed text
        @test occursin("d29ya2xvZyBjb3BpZWQ=", got[1])
        # And one longer than an `%output` line: tmux cuts the stream at a few
        # kilobytes, and a copy of a few paragraphs was lost whole - it arrived
        # as a head with no terminator and a tail with no introducer, and the
        # relay kept neither. From a script, since a typed line stops at 4K.
        empty!(got)
        b64 = "QUJD"^4000
        mktempdir() do dir
            f = joinpath(dir, "copy.sh")
            write(f, "printf '\\033]52;c;$(b64)\\007'\n")
            W.mux_keys(c, codeunits("sh $f\r"))
            sleep(2.0)
        end
        @test got == ["\e]52;c;" * b64 * "\a"]
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
        # A reply that does not come kills the client - the next reply would
        # answer the wrong question - and the reason is kept, the first one:
        # a pane that says `session ended` over a late reply was read as the
        # server having gone away, which it had not.
        @test isempty(c.why)
        @test W.mux_ask(c, "display-message -p late"; timeout = 0.0) == (false, ["timed out"])
        @test c.dead && occursin("no reply in 0.0s to display-message", c.why)
        W.mux_close(c)
        @test c.why != "closed"                         # the first reason stays
        @test W.mux_ask(c, "display-message -p x")[1] === false
        W.mux_kill(n)
    end
end

@testset "a session that ends after its last words still says so" begin
    # `claude` writes its farewell and then takes a moment to exit: the
    # session ends after the last `%output`, and a pane that synced on output
    # alone kept the farewell on screen with every key going to a dead client
    # - `^]K` the one way out, where a shell closed on any key.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the ended-session test"
    else
        n = "wl-test-ended-1"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sh -c 'printf bye; sleep 1'")
        fr, deadwake = Ref{Any}(nothing), Ref(false)
        f = fr[] = W.iframe(n, "t"; onwake = () -> begin
                x = fr[]
                x === nothing || x.client === nothing || !x.client.dead || (deadwake[] = true)
            end)
        @test f !== nothing
        box = (60, 8)
        W.iframe_sync!(f, box...)
        t0 = time()
        while !f.client.dead && time() - t0 < 10
            sleep(0.1)
        end
        @test f.client.dead
        sleep(0.2)
        @test deadwake[]                   # a wake with nothing to say but that
        # Which is what a host acts on: its sync finds the client gone.
        W.iframe_sync!(f, box...)
        @test f.client === nothing && occursin("session ended", f.status)
        @test W.iframe_input!(f, UInt8['x'], (1, 1), box) === :pop

        # And where the wake is lost, the first key says it and the next leaves.
        W.mux_start(n, pwd(), "sh -c 'sleep 1'")
        g = W.iframe(n, "t")
        t0 = time()
        while !g.client.dead && time() - t0 < 10
            sleep(0.1)
        end
        @test W.iframe_input!(g, UInt8['x'], (1, 1), box) === :ok
        @test g.client === nothing && occursin("session ended", g.status)
        @test W.iframe_input!(g, UInt8['x'], (1, 1), box) === :pop
        W.mux_kill(n)
    end
end

@testset "what a pane keeps seeing: the forwards" begin
    # A pane is handed links, and the links are re-pointed at what this login
    # has when that is live - from its environment, never from a search of
    # `/run/user` or `/tmp`, whose newest socket is some session's and not
    # necessarily this one's. `RUN_DIR` is the suite's temp directory, and
    # every socket here is a listener of our own: liveness is a connection,
    # not a file.
    run = W.rundir()
    rt = mktempdir()
    link = joinpath(run, "agent.sock")
    a = joinpath(rt, "own.sock"); la = Sockets.listen(a)
    withenv("SSH_AUTH_SOCK" => a, "VSCODE_IPC_HOOK_CLI" => nothing, "PATH" => "") do
        # This process's own, live: the link is made and handed over.
        fw = W.forwards!()
        @test islink(link) && readlink(link) == a
        @test ("SSH_AUTH_SOCK" => link) in fw.env
        @test isempty(fw.gone)
        # The links name where your keys are, and a symlink has no mode of its
        # own: the directory is `0700`, and made so again on every call.
        @test filemode(run) & 0o777 == 0o700
        chmod(run, 0o755)
        W.forwards!()
        @test filemode(run) & 0o777 == 0o700
        # Nothing was ever forwarded for VS Code or `code`, so neither is
        # handed over: a pane on a machine without them keeps what it has.
        @test !any(p -> p.first in ("VSCODE_IPC_HOOK_CLI", "PATH"), fw.env)

        # Another login's, also live: preferred over a link that still works,
        # since the login that just ran `wl` is the one that will outlast it.
        b = joinpath(rt, "other.sock"); lb = Sockets.listen(b)
        withenv("SSH_AUTH_SOCK" => b) do
            @test isempty(W.forwards!().gone)
        end
        @test readlink(link) == b

        # A login whose forward has died - the file stays, nothing listens -
        # does not move a link that still works.
        close(la)
        @test isempty(W.forwards!().gone)
        @test readlink(link) == b

        # Nothing live anywhere: the link is left alone, still handed over -
        # its value is the path - and the pane key is told. A stale socket in
        # the runtime directory is not looked for.
        close(lb)
        c = joinpath(rt, "vscode-ssh-auth-sock-3"); lc = Sockets.listen(c)
        withenv("XDG_RUNTIME_DIR" => rt) do
            fw = W.forwards!()
            @test readlink(link) == b
            @test ("SSH_AUTH_SOCK" => link) in fw.env
            @test fw.gone == ["ssh agent"]
            @test W.gone_suffix(fw.gone) == " \u00b7 no live ssh agent"
        end

        # The classic rc trick - a value that is itself a link - is followed to
        # the socket; and a value that is *this* link cannot loop it.
        mine = joinpath(rt, "mine"); symlink(c, mine)
        withenv("SSH_AUTH_SOCK" => mine) do
            @test isempty(W.forwards!().gone)
            @test readlink(link) == c
        end
        withenv("SSH_AUTH_SOCK" => link) do
            @test isempty(W.forwards!().gone)
            @test readlink(link) == c
        end
        close(lc)

        # `code`: a link in the pane's `PATH`, in front of this process's, and
        # the socket its command line reaches the server through.
        bin = joinpath(rt, "codebin"); mkpath(bin)
        code = joinpath(bin, "code"); write(code, "#!/bin/sh\n"); chmod(code, 0o755)
        ipc = joinpath(rt, "vscode-ipc-1.sock"); li = Sockets.listen(ipc)
        withenv("PATH" => bin, "VSCODE_IPC_HOOK_CLI" => ipc) do
            fw = W.forwards!()
            @test readlink(joinpath(run, "bin", "code")) == code
            @test filemode(joinpath(run, "bin")) & 0o777 == 0o700
            @test readlink(joinpath(run, "vscode-ipc.sock")) == ipc
            @test ("PATH" => string(joinpath(run, "bin"), ":", bin)) in fw.env
            @test ("VSCODE_IPC_HOOK_CLI" => joinpath(run, "vscode-ipc.sock")) in fw.env
        end
        close(li)
        rm(code)
        # All three gone, said in the order they are listed.
        withenv("PATH" => bin, "VSCODE_IPC_HOOK_CLI" => ipc) do
            @test W.forwards!().gone == ["ssh agent", "VS Code", "code"]
        end
    end
    # A directory of the right name that is a link to somewhere else is
    # refused: nothing is handed over, and the error is logged.
    was = W.RUN_DIR[]
    try
        W.RUN_DIR[] = joinpath(rt, "squat"); symlink(rt, W.RUN_DIR[])
        withenv("SSH_AUTH_SOCK" => a) do
            @test W.forwards!() == (env = [], gone = [])
        end
        @test occursin("not a directory", read(W.errlog(), String))
    finally
        W.RUN_DIR[] = was
        rm(W.errlog(); force = true)
    end
end
