# Which checkout an item's work is in, and the list of every one of them.

@testset "what T runs, and why it is not a bare name" begin
    # `claude` is more often a shell alias than a file on PATH, and both halves
    # of `-ic` are load-bearing. Measured against bash 5.1 rather than assumed:
    #
    #   bash -c  'claude'        expand_aliases off, no .bashrc read
    #   bash -ic 'claude'        the alias runs
    #   bash -ic 'exec claude'   the alias does NOT run
    #
    # The last one is the trap: aliases expand in command position only, so in
    # `exec claude` the command is `exec` and `claude` is an argument to it.
    cmd = W.agent_cmd()
    @test occursin("-ic", cmd)
    @test !occursin("exec", cmd)
    @test occursin("claude", cmd)
    # Quoted, because `$SHELL` is a path and a path is one `mktempdir` away from
    # being two arguments.
    @test startswith(cmd, "'")
    withenv("SHELL" => "/opt/weird path/zsh") do
        @test occursin("'/opt/weird path/zsh'", W.agent_cmd())
    end
    # And it is what the worktree list runs too, so the two cannot drift.
    @test occursin("claude", W.agent_cmd())
end

@testset "t asks which checkout, unless something has already said" begin
    # Three questions in order, and only the last one asks. The point of the
    # first two is that the answer is already on disk or already running, and
    # asking about something that is not in doubt is worse than guessing.
    items = W.loaditems()
    shown = W.BState(items, "worklog", Set{String}())
    pr = first(it for it in shown.items if it.is_pr && !isempty(it.branch))
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")

    # Same repo, no branch of its own: an issue is the case rule 1 cannot see.
    issue = W.Item(url = "https://example.invalid/i/9", ref = "wt#9",
                   repo = pr.repo, number = 9, title = "an issue", is_pr = false)

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    keept = W.MARKS[]; W.MARKS[] = joinpath(root, "marks.json")
    try
        W.register_repo!(pr.repo, main)

        # Rule 3: nothing on disk and nothing running says where, so the main
        # checkout is a guess - and the flag is how the caller knows to ask.
        t, b, ask = W.item_worktree(pr)
        @test W.wtkey(t) == W.wtkey(main) && b == pr.branch && ask
        t, b, ask = W.item_worktree(issue)
        @test W.wtkey(t) == W.wtkey(main) && isempty(b) && ask

        # Rule 1: a worktree on the branch is the copy the work is in, and no
        # answer beats it.
        side = joinpath(root, "side")
        W.git(main, "worktree", "add", "--quiet", "-b", pr.branch, side)
        t, b, ask = W.item_worktree(pr)
        @test W.wtkey(t) == W.wtkey(side) && b == pr.branch && !ask
        # `e` reads the same rules, so the two cannot disagree about one item.
        @test W.item_checkout(pr) == (t, b)
        # The issue still has nothing to go on: a worktree on somebody else's
        # branch is not a claim about this item.
        t, b, ask = W.item_worktree(issue)
        @test W.wtkey(t) == W.wtkey(main) && isempty(b) && ask

        # The prompt behind the last row of the chooser. Its prefill is the
        # suggestion the branch list makes, and the main checkout for an item
        # with no branch to check out - the only honest offer there.
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, shown)
        @test W.ask_worktree_for(pr, ctrl, :shell, (_, _) -> "sleep 120",
                                 _ -> nothing) == ""
        pv = pop!(ctrl.stack)
        @test pv isa W.PromptView && W.text(pv) == W.worktree_dest(main, pr.branch)
        @test W.ask_worktree_for(issue, ctrl, :shell, (_, _) -> "sleep 120",
                                 _ -> nothing) == ""
        pv = pop!(ctrl.stack)
        @test pv isa W.PromptView && W.wtkey(W.text(pv)) == W.wtkey(main)
        # And a path that would have to be made cannot be, without a branch.
        @test occursin("no branch",
                       W.make_checkout!(issue, ctrl, :shell, (_, _) -> "sleep 120",
                                        _ -> nothing, joinpath(root, "nope")))

        if W.mux_bin() === nothing
            @info "no tmux; skipping the chooser and the session rule"
        else
            # The chooser: every worktree, main first as git lists them, plus
            # the row that makes a new one.
            said = Ref{Any}(nothing)
            say = x -> (said[] = x)
            @test W.enter_session(issue, ctrl, :shell,
                                  (_, _) -> "sleep 120", say) == ""
            ch = last(ctrl.stack)
            @test ch isa W.ChooseView && length(ch.options) == 3
            @test occursin("main", ch.options[1][1])
            @test occursin("side", ch.options[2][1])
            # The branch is on the row, at both ends. Which pull request `pr` is
            # comes from the live list, so its branch may be longer than the
            # column - and then what has to survive is the tail, since branches
            # under one owner prefix agree at the front. Asserting the whole
            # string instead made this pass or fail on whichever item happened
            # to sort first that day.
            @test occursin(first(pr.branch, 6), ch.options[2][1])
            @test occursin(last(pr.branch, 6), ch.options[2][1])
            @test occursin("new worktree", ch.options[end][1])
            for (w, h) in ((80, 24), (165, 50))
                ls = split(W.render(ch, w, h), "\n")
                @test length(ls) == h && all(W.awidth(l) == w for l in ls)
            end

            # Picking a row works there, and says so through `say`: the answer
            # arrives long after the key press that asked for it returned.
            ch.sel = 2
            W.handle!(ch, 13, ctrl)
            @test last(ctrl.stack) isa W.PaneView
            @test occursin("side", string(said[]))
            pop!(ctrl.stack)

            # Rule 2: the session it started is tagged with the item, so the
            # next press knows where the work is and does not ask again - even
            # though no branch here ever mentioned this issue.
            t, b, ask = W.item_worktree(issue)
            @test W.wtkey(t) == W.wtkey(side) && b == pr.branch && !ask
            @test W.item_checkout(issue) == (t, b)
            said[] = nothing
            @test W.enter_session(issue, ctrl, :shell,
                                  (_, _) -> "sleep 120", say) isa String
            @test last(ctrl.stack) isa W.PaneView
            @test said[] === nothing         # nothing was asked, so nothing reported
            pop!(ctrl.stack)

            # A typed path that is already a worktree is a way of picking it,
            # not an error - which is what makes the list's overflow reachable.
            said[] = nothing
            r = W.make_checkout!(issue, ctrl, :shell, (_, _) -> "sleep 120", say, main)
            @test r isa String && occursin("main", r)
            @test last(ctrl.stack) isa W.PaneView
            pop!(ctrl.stack)

            for r in W.mux_list()
                r.item == issue.ref && W.mux_kill(r.name)
            end
        end
    finally
        W.REPOS_FILE[] = REPOS_SANDBOX
        W.MARKS[] = keept
    end
end

@testset "worktrees, with the sessions folded in" begin
    items = W.loaditems()
    ctrl = W.Controller(); ctrl.running = true

    # A repo with two worktrees, one of them on a branch that has a pull
    # request in the real facts.json - which is the join this view is for.
    # Taken from what the browser is actually showing, since `i` goes to the
    # row in that list and an item outside it is a different case, tested below.
    shown = W.BState(items, "worklog", Set{String}())
    # The shortest branch among them, not the first: the narrow render below
    # asserts that the branch column is legible at 80 columns, and which item
    # happens to sort first is not this test's business - it changed under it
    # once already, when the list stopped opening in url order.
    cands = [it for it in shown.items if it.is_pr && !isempty(it.branch)]
    pr = cands[argmin(map(it -> length(it.branch), cands))]
    root = mktempdir()
    main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    side = joinpath(root, "side")
    W.git(main, "worktree", "add", "--quiet", "-b", pr.branch, side)

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        W.register_repo!(pr.repo, main)
        rows = W.worktree_rows(items)
        byname = Dict(r.name => r for r in rows)
        @test sort(collect(keys(byname))) == ["main", "side"]
        @test byname["main"].main && !byname["side"].main
        # The branch carries its pull request, and the one with no branch of
        # its own carries none.
        @test byname["side"].item !== nothing && byname["side"].item.url == pr.url
        @test byname["main"].item === nothing
        @test all(isempty(r.sessions) for r in rows)

        v = W.worktree_view(items)
        @test length(v.rows) == 2
        for (w, h) in ((80, 24), (120, 40), (165, 50))
            ls = split(W.render(v, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
        # The row says which pull request the work in it is.
        @test occursin(pr.ref, W.astrip(W.render(v, 165, 24)))

        # `tTv` and `+*` are as much as a three-column header can say, so the
        # legend under the list says the rest - and stays there. The letters are
        # the keys that open each slot, so the column is its own key.
        for (w, h) in ((80, 24), (165, 50))
            leg = W.astrip(W.render(v, w, h))
            @test occursin("tTv", leg)
            @test occursin("t shell", leg) && occursin("T agent", leg)
            @test occursin("v note", leg) && occursin("* unstaged", leg)
        end
        # It is not the status line: a message does not take it away.
        v.status = "something happened"
        shown = W.astrip(W.render(v, 165, 24))
        @test occursin("t shell", shown) && occursin("something happened", shown)
        v.status = ""

        # The tip date is drawn where there is room for it, and dropped where
        # taking eleven columns would cost the title instead.
        wide = W.astrip(W.render(v, 165, 24))
        @test occursin("tip", wide)
        @test occursin(first(W.worktree_rows(items)[1].at, 10), wide)
        narrow = W.astrip(W.render(v, 80, 24))
        @test !occursin("tip", narrow)
        # What the room bought - and the tail of it, for the reason above.
        @test occursin(last(pr.branch, 6), narrow)

        # Dirty arrives behind the list rather than holding it up: the first
        # pass skips the tree walk entirely.
        @test all(!(r.staged || r.unstaged) for r in W.worktree_rows(items; withdirty = false))
        write(joinpath(main, "a.txt"), "two\n")
        v2 = W.worktree_view(items)
        @test all(!(r.staged || r.unstaged) for r in v2.rows)          # not walked yet
        wait(v2.pending)
        @test W.onwake!(v2)
        @test W.worktree_rows(items)[1].unstaged         # and now it is known
        @test any((r.staged || r.unstaged) for r in v2.rows)
        @test !W.onwake!(v2)                          # nothing left pending
        W.git(main, "checkout", "--quiet", "--", "a.txt")

        # `i` leaves for the item, and reports rather than moving when the
        # list underneath is not showing it.
        st = W.BState(items, "worklog", Set{String}())
        v3 = W.worktree_view(items; onitem = x -> W.select_item!(st, x))
        v3.sel = findfirst(r -> r.name == "side", v3.rows)
        @test W.handle!(v3, Int('i'), ctrl) === :pop
        @test st.items[st.sel].url == pr.url
        v3.sel = findfirst(r -> r.name == "main", v3.rows)
        @test W.handle!(v3, Int('i'), ctrl) === :ok
        @test occursin("no pull request", v3.status)
        # Asking to go to an item is asking to *see* it, so a filter hiding it
        # is the thing in the way and not the answer. It used to refuse with
        # "filtered out", which is a refusal to do the one thing that was asked.
        st2 = W.BState(items, "worklog", Set{String}())
        st2.filters.repos = Set(["nothing/here"])
        st2.search = "zzzz-no-such-item"; st2.searchin = :list
        W.refilter!(st2)
        @test isempty(st2.items)
        v4 = W.worktree_view(items; onitem = x -> W.select_item!(st2, x))
        v4.sel = findfirst(r -> r.name == "side", v4.rows)
        @test W.handle!(v4, Int('i'), ctrl) === :pop
        @test st2.items[st2.sel].url == pr.url
        @test W.isdefault(st2.filters) || st2.filters.state === :all
        @test isempty(st2.search)
        # And `\`` is the way back, the same as from every other jump.
        @test st2.prev !== nothing && st2.prev.repos == Set(["nothing/here"])
        @test occursin("cleared the filter", st2.status)
        # An item that is not in the dashboard at all is still a message: there
        # is no filter to clear that would bring it.
        gone = W.Item(url = "https://example.invalid/x/y/pull/9", ref = "y#9",
                      repo = "x/y", number = 9, title = "not here")
        @test occursin("not in this dashboard", W.select_item!(st2, gone))

        if W.mux_bin() === nothing
            @info "no tmux; skipping the live worktree session test"
        else
            # A session is a column of the worktree it is in, not a list of its
            # own: starting one from the row puts it on that row.
            v5 = W.worktree_view(items)
            v5.sel = findfirst(r -> r.name == "side", v5.rows)
            @test isempty(v5.rows[v5.sel].sessions)
            W.handle!(v5, Int('t'), ctrl)
            @test last(ctrl.stack) isa W.PaneView
            pop!(ctrl.stack)
            row = v5.rows[findfirst(r -> r.name == "side", v5.rows)]
            @test length(row.sessions) == 1 && row.sessions[1].kind === :shell
            @test occursin("s", W.astrip(W.render(v5, 165, 24)))
            # And the same worktree reached from its item is the same session,
            # because a session is keyed by where it is and not by what asked.
            n = length(W.mux_list())
            W.open_terminal(pr, ctrl)
            pop!(ctrl.stack)
            @test length(W.mux_list()) == n

            # `K` ends what is running on the row, and nothing else.
            W.handle!(v5, Int('K'), ctrl)
            @test isempty(v5.rows[findfirst(r -> r.name == "side", v5.rows)].sessions)
            @test occursin("ended", v5.status)
            W.handle!(v5, Int('K'), ctrl)
            @test occursin("nothing running", v5.status)

            # A session whose worktree has gone is an orphan row rather than a
            # hidden one: it is still holding a process, and K is still how to
            # be rid of it.
            gone = mktempdir()
            name = W.mux_name(basename(gone), "master", ""; kind = :shell)
            W.mux_start(name, gone, "sleep 120")
            W.mux_tag!(name; worktree = gone, kind = :shell, item = "")
            rm(gone; recursive = true)
            v6 = W.worktree_view(items)
            orph = findfirst(r -> r.orphan, v6.rows)
            @test orph !== nothing && v6.rows[orph].name == basename(gone)
            @test occursin("gone", W.astrip(W.render(v6, 120, 24)))
            v6.sel = orph
            # Nothing can be started in a directory that is not there.
            W.handle!(v6, Int('t'), ctrl)
            @test occursin("gone", v6.status)
            W.handle!(v6, Int('K'), ctrl)
            @test W.mux_alive(name) === false
        end

        @test W.handle!(W.worktree_view(items), Int('q'), ctrl) === :pop
    finally
        W.REPOS_FILE[] = REPOS_SANDBOX
    end
end
