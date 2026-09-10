# The view stack: what replaces what, what stacks on what, and what may only
# ever be in the air once.

@testset "one fetch in the air per thing being fetched" begin
    # A view holds one `pending`, and the next load overwrites it - so holding
    # `j` down the list started a `gh api graphql` per row and abandoned all but
    # the last: a process each, a rate limit spent on answers nobody reads, and
    # the winner decided by whichever finished last. It is also what stopped
    # package precompilation dead, because nothing held a handle on any of them.
    # Drained first, because the map is the whole process's: testsets above
    # have driven `load_nodes!` and left their fetches in the air, and that is
    # the state this is about.
    W.drain_fetches!()
    @test isempty(W.INFLIGHT)

    started = Ref(0)
    slow(key) = W.fetching(key) do
        started[] += 1
        sleep(0.3)
        key
    end

    # Asking five times for something already in the air joins it.
    ts = [slow("a") for _ in 1:5]
    @test all(t -> t === ts[1], ts)
    @test length(W.INFLIGHT) == 1
    W.drain_fetches!()
    @test isempty(W.INFLIGHT)          # the task takes itself out when it ends
    @test istaskdone(ts[1]) && fetch(ts[1]) == "a"
    @test started[] == 1

    # A different key is a different fetch, and once one is done, asking again
    # starts a new one rather than handing back the finished task.
    slow("b"); W.drain_fetches!()
    t3 = slow("a"); W.drain_fetches!()
    @test started[] == 3 && t3 !== ts[1]

    # A failure is logged rather than swallowed - an abandoned task's value is
    # never fetched, so this is the last place it could be noticed at all - and
    # it does not wedge the map.
    isfile(W.errlog()) && rm(W.errlog())
    bad = W.fetching("boom") do; error("nope"); end
    try; wait(bad); catch; end
    W.drain_fetches!()
    @test isempty(W.INFLIGHT)
    @test isfile(W.errlog()) && occursin("nope", read(W.errlog(), String))
    rm(W.errlog())

    # Draining nothing is not an error, and is what the precompile workload
    # calls when the keys it pressed happened to start nothing.
    @test W.drain_fetches!() === nothing
end

@testset "another window's writes arrive on their own" begin
    # `wl set` in another terminal, a second browser, the refresh on a timer:
    # each writes a file this process is holding a copy of, and the copy used to
    # stand until the browser was restarted.
    st = mkstate()
    it = st.items[st.sel]
    # A write of our own is not news, which is what stops a keystroke that
    # archives from rebuilding the list a moment later.
    W.draft!(it.url)
    @test W.ours(W.marksfile())
    @test W.reload_data!(st) === false
    # The same file, changed by somebody else: the mark is theirs, and the lane
    # is membership in the file rather than in what we read at startup.
    delete!(W.OURS, abspath(W.marksfile()))
    @test !W.ours(W.marksfile())
    st.reload = true
    @test W.reload_data!(st) === true
    @test haskey(st.drafts, it.url)
    W.undraft!(it.url)

    # A refresh landing is the one change that adds and removes rows, so it is
    # the one that rebuilds the list - and the rows that came from the unread
    # poll rather than from `facts.json` are carried across, since a refresh
    # that does not mention them is not evidence that they are gone.
    ghost = W.Item(url = "https://github.com/o/r/issues/1", repo = "o/r", number = 1,
                   ref = "r#1", title = "unread and untracked", bucket = "unread",
                   backlog = true)
    push!(st.all, ghost)
    push!(st.unread, ghost.url)
    W.rebuild_axes!(st)
    st.factsat, st.reload = 0.0, true
    @test W.reload_data!(st) === true
    @test st.factsat != 0.0
    @test any(x -> x.url == ghost.url, st.all)
    @test any(x -> x.url == it.url, st.all)
    @test "o/r" in st.repos                 # the axes are rebuilt with the list
    delete!(st.unread, ghost.url)
end

@testset "the watch is on the directory, and only wakes for what is read" begin
    # A watch rather than a poll: this directory changes a few times an hour,
    # and polling it would be a wakeup a second for the life of the session.
    d = mktempdir()
    was = W.DATA_DIR[]
    try
        W.DATA_DIR[] = d
        write(joinpath(d, "facts.json"), "{}")
        st = W.BState(W.Item[], "watched")
        woke = Ref(0)
        st.wake = () -> (woke[] += 1)
        W.watch_data!(st)
        # Not every file in there is on screen: the cache and the inbox cursors
        # change on every fetch this program makes.
        write(joinpath(d, "bulk.json"), "{}")
        # ...and one that is.
        write(joinpath(d, "marks.json"), "{}")
        t0 = time()
        while !st.reload && time() - t0 < 10
            sleep(0.1)
        end
        @test st.reload && woke[] >= 1
    finally
        W.DATA_DIR[] = was
    end
end

@testset "the keys measure against the width the frame was drawn at" begin
    # Reading a thread beside a hosted pane, `n`/`N` and the highlight landed on
    # the wrong lines. `render` drew the detail at half the screen; `handle_key!`
    # asked `layout` what width it would have had *alone* and indexed rows
    # against that. At 170 columns those are 114 and 74, and the same comment
    # wraps to eight rows or twelve depending which you ask.
    ENV["COLUMNS"], ENV["LINES"] = "170", "40"
    st = mkstate()
    long = repeat("a long sentence that has to wrap several times over ", 6)
    st.nodes = [W.Node("alice  2026-09-01   first", long, :md, true),
                W.Node("bob  2026-09-02   second", long, :md, true)]
    st.metakey = st.items[st.sel].url
    st.focus = :detail                # or the keys below move the list instead
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)

    L = W.layout(170, 40, st.nmeta)
    lw, _ = W.split_box(170)
    wide, narrow = length(W.rows(st.nodes, L.riw)), length(W.rows(st.nodes, lw - 4))
    @test wide != narrow              # or this test proves nothing

    # Drawn alone, the keys measure against the browser's own width.
    W.render(st, 170, 40)
    @test st.diw == L.riw
    W.handle!(st, Int('G'), ctrl)
    @test st.nrow == wide

    # Drawn beside a pane, they measure against what the reader is looking at.
    W.detail_pane(st, st.items[st.sel], lw, 40, true)
    @test st.diw == lw - 4 && st.dpage == 40 - 3
    W.handle!(st, Int('G'), ctrl)
    @test st.nrow == narrow

    # And a page is the pane's height, not the height the detail would have had
    # stacked under a metadata pane.
    st.nrow = 1
    W.detail_pane(st, st.items[st.sel], lw, 40, true)
    W.handle!(st, Int(' '), ctrl)
    @test st.nrow == min(narrow, 1 + (40 - 3))
    pop!(ctrl.stack)
end

@testset "a place replaces a place; a dialog stacks on one" begin
    # `t` from `"` used to leave four views between the shell and the dashboard,
    # so getting back out was ^]tab, esc, esc, ^]tab, esc. Two terminals - or a
    # terminal on top of the worktree list - is not a state anybody meant to be
    # in: a place is somewhere you work, and going somewhere means leaving where
    # you were. A dialog is the exception, because answering a question is the
    # one thing that does return to what asked.
    @test W.isdialog(W.PromptView("t", "", identity)) === true
    @test W.isdialog(W.ChooseView("t", "", Tuple{String,Any}[], identity)) === true

    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
    v = W.worktree_view(W.Item[])
    @test W.isdialog(v) === false
    W.push_place!(ctrl, v)
    @test length(ctrl.stack) == 2
    # A second place takes the first one's slot rather than covering it.
    W.push_place!(ctrl, W.worktree_view(W.Item[]))
    @test length(ctrl.stack) == 2 && last(ctrl.stack) !== v
    # A dialog over a place keeps the place, which is what makes it a dialog.
    W.push_view!(ctrl, W.PromptView("t", "", identity))
    @test length(ctrl.stack) == 3
    # ...and a place opened from under a dialog still only replaces places.
    W.push_place!(ctrl, W.worktree_view(W.Item[]))
    @test length(ctrl.stack) == 4
    # The root is never a place: it is what every place is somewhere from.
    while length(ctrl.stack) > 1; pop!(ctrl.stack); end
    W.push_place!(ctrl, W.worktree_view(W.Item[]))
    @test length(ctrl.stack) == 2 && first(ctrl.stack) === st

    if W.mux_bin() === nothing
        @info "no tmux; skipping the pane-replaces-pane test"
    else
        n = "wl-test-place"
        W.mux_kill(n)
        W.mux_start(n, pwd(), "sleep 120")
        pv = W.pane_view(n, "sh", ctrl)
        @test W.isdialog(pv) === false
        W.push_place!(ctrl, pv)
        @test length(ctrl.stack) == 2       # took the worktree list's slot
        # Escape after the prefix leaves, the same as `q`: a key that means
        # "out of here" everywhere else should not be the one the prefix has no
        # answer for.
        @test W.onraw!(pv, [W.IFRAME_PREFIX, 0x1b], ctrl) === :pop
        @test W.mux_alive(n) === true       # left running, not killed
        W.mux_kill(n)
        pop!(ctrl.stack)
    end
end

@testset "q asks whether it meant it" begin
    # One key, no modifier, and what it ends is the whole program - the fetch
    # that filled the list, where you were in it, and any pane on the screen.
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
    @test W.handle!(st, Int('q'), ctrl) === :ok
    v = last(ctrl.stack)
    @test v isa W.ConfirmView && v.title == "Quit"
    # It is a dialog: the browser underneath is still there to go back to.
    @test W.isdialog(v) === true && length(ctrl.stack) == 2
    # Everything except `y` is no - including `q` again, which a doubled
    # keystroke would otherwise answer, and the enter a picker would have taken.
    for k in (Int('q'), 13, 10, 27, Int('n'), Int('j'))
        @test W.handle!(v, k, ctrl) === :pop
    end
    @test W.handle!(v, Int('y'), ctrl) === :quit
    @test W.handle!(v, Int('Y'), ctrl) === :quit
    # An arrow is not a printable key and must not be read as one.
    @test W.handle!(v, W.K_DOWN, ctrl) === :pop
    # And the key is named on the screen, since a dialog nobody can answer is
    # worse than no dialog.
    fr = W.astrip(W.render(v, 80, 24))
    @test occursin("Quit", fr) && occursin("y quits", fr)
    @test count(==('\n'), fr) == 23        # a whole frame, like every other view
    pop!(ctrl.stack)
end

@testset "one view on one session, however you get to it" begin
    # `^]t` and `^]T` reach `enter_session` from inside a pane, which is how a
    # shell gets to the agent on the same item and back. The press that names
    # the kind already showing must not open a second view onto one session and
    # leave two `^]q`s between there and the browser.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the one-view-per-session test"
    else
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
        wt = mktempdir()
        out = W.enter_session(wt, "master", "a#1", "1", "a#1", ctrl, :shell,
                              (_, _) -> "sleep 120")
        @test occursin("started", out)
        @test last(ctrl.stack) isa W.PaneView
        depth = length(ctrl.stack)

        # The same kind again, from the pane it is already showing in.
        out2 = W.enter_session(wt, "master", "a#1", "1", "a#1", ctrl, :shell,
                               (_, _) -> "sleep 120")
        @test occursin("already in", out2)
        @test length(ctrl.stack) == depth

        # The other kind is a different session, so it opens - but as a place
        # rather than on top: two terminals on the stack at once is not a state
        # anybody meant to be in, and it is how `t` from `"` left four views
        # between the shell and the dashboard.
        out3 = W.enter_session(wt, "master", "a#1", "1", "a#1", ctrl, :agent,
                               (_, _) -> "sleep 120")
        @test occursin("started", out3)
        @test length(ctrl.stack) == depth
        @test last(ctrl.stack) isa W.PaneView

        for r in W.mux_list()
            r.worktree == wt && W.mux_kill(r.name)
        end
        while length(ctrl.stack) > 1
            W.closeview!(pop!(ctrl.stack))
        end
    end
end

@testset "R re-reads the item on screen" begin
    # Everything else here decides for itself when to re-read, and each of those
    # windows is a guess about how fast the thing changes. `R` is for when the
    # guess is wrong - you pushed a moment ago, and what is wanted is the answer
    # GitHub has now.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
    it = st.items[st.sel]
    # The metadata is asked for again by clearing the key that decides whether
    # it needs asking for, and this starts it rather than leaving it to the
    # `load_meta!` at the end of the key loop.
    W.load_meta!(st)
    @test st.metakey == it.url
    msg = W.refresh_item!(st)
    @test occursin("re-reading", msg) && occursin(it.ref, msg)
    @test st.metakey == it.url && st.metapending !== nothing
    # It is in the footer, because a key nobody can find is a key nobody uses.
    @test occursin("R reload", W.astrip(W.render(st, 150, 40)))
    # Nothing selected is not a failure, it is nothing to do.
    st.sel = 0
    @test occursin("nothing selected", W.refresh_item!(st))
end

@testset "u rebuilds the whole dashboard" begin
    # `R` is the item under the cursor; `u` is everything - the fetch that used
    # to mean leaving the browser, or running `wl refresh` in another terminal
    # and waiting for the watcher to notice. It took the key `u` had, which was
    # the unconditional half of the read toggle: two presses of `r` reach either
    # state, and nothing at all could ask for a refresh.
    #
    # The refresh itself is a subprocess and is not started here - a testset
    # that spends half a minute against GitHub is not one anybody would run -
    # so what is checked is everything around it.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    @test occursin("u update all", W.astrip(W.render(st, 150, 40)))

    # A second `u` joins the one in flight instead of starting a second refresh
    # against the same files.
    c = Channel{Nothing}(1)
    t = @async take!(c)
    lock(W.INFLIGHT_LOCK) do; W.INFLIGHT["refresh"] = t; end
    try
        @test W.refresh_all!(st) == "already refreshing"
    finally
        put!(c, nothing); wait(t)
        lock(W.INFLIGHT_LOCK) do; delete!(W.INFLIGHT, "refresh"); end
    end

    # And what it reported is what the reload says. A write from anywhere else
    # still says whose it was, which is the whole point of that line.
    st.refreshsaid = "2135 items, 3 changes, 4200 rate-limit points"
    st.reload = true
    @test W.reload_data!(st)
    @test st.status == "2135 items, 3 changes, 4200 rate-limit points"
    @test isempty(st.refreshsaid)
    st.reload = true
    @test W.reload_data!(st)
    @test occursin("something else wrote", st.status)
end

@testset "raw input pass-through" begin
    # `readraw` is a pure function of a byte stream, like `readevent`.
    @test W.readraw(IOBuffer("j")).bytes == UInt8['j']
    # A sequence must reach the child whole and in order: one blocking byte,
    # then whatever else had already arrived.
    @test W.readraw(IOBuffer("\e[A")).bytes == UInt8['\e', '[', 'A']
    @test W.readraw(IOBuffer("\e[<0;40;12M")).bytes == collect(codeunits("\e[<0;40;12M"))
    @test W.readraw(IOBuffer("pasted text")).bytes == collect(codeunits("pasted text"))

    # Only a view that asks gets bytes; everything else still gets characters.
    @test W.wantsraw(W.PromptView("t", "", _ -> nothing)) === false

    if W.mux_bin() === nothing
        @info "no tmux; skipping the raw forwarding test"
    else
        n = "wl-test-raw-1"
        W.mux_kill(n)
        tmp = joinpath(mktempdir(), "edit-me.txt")
        write(tmp, "first line\n")
        W.mux_start(n, dirname(tmp), "vi $tmp")
        ctrl = W.Controller(); ctrl.running = true
        v = W.pane_view(n, "vi", ctrl)
        @test v !== nothing
        @test W.wantsraw(v) === true
        sleep(1.5)

        # Bytes as typed, and nothing here knows what any of them mean: `G`,
        # `o`, text, a literal escape and `:wq` drive an editor this code has
        # no model of.
        for s in ("G", "o", "typed through the pane", "\e", ":wq\r")
            @test W.onraw!(v, collect(codeunits(s)), ctrl) === :ok
            sleep(0.5)
        end
        sleep(1.0)
        @test read(tmp, String) == "first line\ntyped through the pane\n"
        @test W.mux_alive(n) === false            # vi quit, so the session ended

        # Ctrl-] is a prefix, not an escape: with every other key forwarded it
        # is the only way left to reach anything this view can do.
        n2 = "wl-test-raw-2"
        W.mux_kill(n2)
        W.mux_start(n2, pwd(), "sh -c 'sleep 120'")
        v2 = W.pane_view(n2, "sh", ctrl)

        # Alone it commits to nothing and waits for its key, which may arrive
        # in the same read or the next one.
        @test W.onraw!(v2, UInt8[W.IFRAME_PREFIX], ctrl) === :ok
        @test v2.child.pending === true
        @test W.onraw!(v2, UInt8[UInt8('r')], ctrl) === :ok     # reread
        @test v2.child.pending === false

        # Doubled, it is a literal Ctrl-] for the child, and the pane stays.
        @test W.onraw!(v2, [W.IFRAME_PREFIX, W.IFRAME_PREFIX], ctrl) === :ok

        # A prefix inside a burst still only takes the byte after it; what came
        # before is the child's and is sent first.
        @test W.onraw!(v2, UInt8[0x61, W.IFRAME_PREFIX, UInt8('r'), 0x62], ctrl) === :ok
        sleep(0.4)
        @test occursin("ab", join(W.mux_capture(v2.child.client; escapes = false)))

        # With no browser underneath there is nowhere to pass a key on to, so
        # an unknown one after the prefix says what the prefix takes instead.
        @test v2.beside === nothing
        W.onraw!(v2, [W.IFRAME_PREFIX, UInt8('Z')], ctrl)
        @test occursin("kill", v2.child.status)
        # And `^]?` asks for that list wherever it is pressed.
        v2.child.status = ""
        W.onraw!(v2, [W.IFRAME_PREFIX, UInt8('?')], ctrl)
        @test occursin("full screen", v2.child.status)

        # tab leaves it running; the browser already uses tab to change pane.
        @test W.onraw!(v2, [W.IFRAME_PREFIX, UInt8('\t')], ctrl) === :pop
        @test W.mux_alive(n2) === true             # left running, not killed

        # K is the one that ends it.
        v3 = W.pane_view(n2, "sh", ctrl)
        @test W.onraw!(v3, [W.IFRAME_PREFIX, UInt8('K')], ctrl) === :pop
        @test W.mux_alive(n2) === false
    end
end

@testset "an agent in a session" begin
    # A shell and an agent in one worktree are two different things, so they
    # are two slots, distinguished by kind rather than by anything in the name.
    @test W.mux_name("julia", "master", "62841"; kind = :agent) == "wl-julia-master-62841-agent"

    st = W.BState(W.loaditems(), "worklog", Set{String}())
    ctrl = W.Controller(); ctrl.running = true
    it = st.items[1]

    # An agent needs nothing set up. An unregistered repo is the only thing that
    # stops it - where there is a tmux to start one in at all. Guarded like
    # every other session test in this file, and for a stronger reason than
    # theirs: a testset that *fails* here takes the whole run down with it, and
    # every file included after this one silently stops being run. That is how
    # the adoption testset hid behind `archive.jl` for several sessions.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the unregistered-repo guard test"
        @test W.open_agent(it, ctrl) == "no tmux on PATH"
    else
        @test W.open_agent(it, ctrl) === :needs_repo
    end

    # The metadata pane reports a session from the cached list, never by asking
    # for one per frame: `render` is pure and listing them costs a process.
    tasked = it
    if W.mux_bin() !== nothing
        # Two items in one checkout share one session, whichever kind: the
        # second renames and re-tags what is there rather than starting a
        # second one beside it. An agent is a place too - it can be cleared and
        # pointed somewhere else exactly as a shell can be `cd`-ed.
        for kind in (:shell, :agent)
            wt = mktempdir()
            n1 = W.mux_name(wt, "main", "1"; kind = kind)
            W.mux_start(n1, wt, "sleep 120")
            W.mux_tag!(n1; worktree = wt, kind = kind, item = "a#1")
            @test W.mux_find(wt, kind).item == "a#1"
            n2 = W.mux_name(wt, "main", "2"; kind = kind)
            W.mux_rename(W.mux_find(wt, kind).name, n2)
            W.mux_tag!(n2; worktree = wt, kind = kind, item = "b#2")
            @test count(r -> r.worktree == wt, W.mux_list()) == 1
            @test W.mux_find(wt, kind).item == "b#2"
            @test W.mux_find(wt, kind).name == n2
            W.mux_kill(n2)
        end
    end

    # A tag comes back from tmux as the string it was set with, so that is what
    # a row carries and what the pane reads.
    row(kind, ref) = (name = "wl-x", command = "sh", attached = false,
                      worktree = "/tmp/x", kind = String(kind), item = ref)
    st.sessions = NamedTuple[]
    @test !occursin("running", join(W.meta_lines(st, tasked, 40), "\n"))
    # Matched on the item the session was tagged with, so the pane never has to
    # work out which worktree the item would land in.
    st.sessions = [row(:agent, tasked.ref)]
    lines = join(W.meta_lines(st, tasked, 40), "\n")
    @test occursin("running", lines) && occursin("agent", lines)
    st.sessions = [row(:shell, tasked.ref)]
    @test occursin("shell", join(W.meta_lines(st, tasked, 40), "\n"))
    st.sessions = [row(:shell, "someone/else#1")]
    @test !occursin("running", join(W.meta_lines(st, tasked, 40), "\n"))
end
