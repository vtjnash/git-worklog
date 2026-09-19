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
    # The hooks that ring the pane's bell ride on the alias's own line as the
    # JSON itself - a path is not the same inside a sandbox as outside it -
    # quoted once for the `-ic` shell and once more for the string inside it.
    @test occursin("--settings", cmd)
    @test isfile(W.AGENT_SETTINGS)
    j = W.agent_settings()
    @test startswith(j, "{") && !occursin('\n', j)
    @test W.JSON3.read(j) == W.JSON3.read(read(W.AGENT_SETTINGS, String))
    @test cmd == string("'", ENV["SHELL"], "' -ic ",
                        W.shquote(string("claude --settings ", W.shquote(j))))
    @test !occursin(W.AGENT_SETTINGS, cmd)
    # What the file says: a `Stop` and a permission prompt, each a ring, and
    # nothing that could block the turn.
    hooks = W.JSON3.read(read(W.AGENT_SETTINGS, String))[:hooks]
    @test haskey(hooks, :Stop) && haskey(hooks, :Notification)
    @test hooks[:Notification][1][:matcher] == "permission_prompt"
    for ev in (:Stop, :Notification), h in hooks[ev][1][:hooks]
        @test h[:type] == "command"
        @test occursin("printf '\\a'", h[:command]) && endswith(h[:command], "exit 0")
    end
end

@testset "t asks which checkout, unless something has already said" begin
    # Three questions in order, and only the last one asks. The point of the
    # first two is that the answer is already on disk or already running, and
    # asking about something that is not in doubt is worse than guessing.
    items = W.loaditems()
    shown = W.BState(items, "worklog")
    pr = fixture_item("yours, open, with a branch and labels")
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")

    # Same repo, no branch of its own: an issue is the case rule 1 cannot see.
    issue = W.Item(url = "https://example.invalid/i/9", ref = "wt#9",
                   repo = pr.repo, number = 9, title = "an issue", is_pr = false)

    keept = W.LOCAL[]; W.LOCAL[] = joinpath(root, "local.toml")
    write(W.localfile(), "")
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

            # The chooser says what is already running in each copy, and on
            # what: the worktree list's own marks in a column of their own,
            # with the item beside them - not a phrase off the end of the row,
            # which the box cut at "she".
            issue2 = W.Item(url = "https://example.invalid/i/10", ref = "wt#10",
                            repo = pr.repo, number = 10, title = "another", is_pr = false)
            said[] = nothing
            @test W.enter_session(issue2, ctrl, :shell, (_, _) -> "sleep 120", say) == ""
            ch = last(ctrl.stack)
            @test ch isa W.ChooseView
            row = W.astrip(ch.options[2][1])
            # `wt#9` whole: the ref is not this repository's spelling, and a
            # ref from another repository keeps its name. One of this
            # repository's is the number alone, `#9`.
            @test occursin("side", row) && occursin(" t ", row) && occursin(" wt#9 ", row)
            @test occursin(" #9 ", W.astrip(W.checkout_option(
                (path = side, branch = pr.branch, main = false), W.mux_list(), "o/wt")))
            @test !occursin("running", row) && W.awidth(row) <= 72
            @test !occursin("#9", W.astrip(ch.options[1][1]))
            # Picking it re-points the shell: the session is on this item now
            # and not on the last one, so rule 2 answers for this one alone and
            # the other is back to asking.
            ch.sel = 2
            W.handle!(ch, 13, ctrl)
            @test last(ctrl.stack) isa W.PaneView
            pop!(ctrl.stack)
            @test any(r -> r.item == issue2.ref, W.mux_list())
            @test !any(r -> r.item == issue.ref, W.mux_list())
            @test W.wtkey(W.item_worktree(issue2)[1]) == W.wtkey(side)
            t, b, ask = W.item_worktree(issue)
            @test W.wtkey(t) == W.wtkey(main) && ask

            # A typed path that is already a worktree is a way of picking it,
            # not an error - which is what makes the list's overflow reachable.
            said[] = nothing
            r = W.make_checkout!(issue, ctrl, :shell, (_, _) -> "sleep 120", say, main)
            @test r isa String && occursin("main", r)
            @test last(ctrl.stack) isa W.PaneView
            pop!(ctrl.stack)

            for r in W.mux_list()
                r.item in (issue.ref, issue2.ref) && W.mux_kill(r.name)
            end
        end
    finally
        W.LOCAL[] = keept
    end
end

@testset "t looks at the branch before it opens, and offers the checkout" begin
    # A copy on some other branch is where a session used to open without a
    # word. Now the branch is looked at first: when the place is new to the
    # item - started, taken over, or picked by hand - the question says what
    # is checked out there and offers `gh pr checkout`; and a copy that has
    # been reused for another item is not this item's place any more.
    items = W.loaditems()
    shown = W.BState(items, "worklog")
    pr = fixture_item("yours, open, with a branch and labels")
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    # Two more pull requests of the same repository, on branches of their own:
    # one to reuse the copy for, one from a fork whose branch is nowhere here.
    pr2 = W.Item(url = "https://example.invalid/o/wt/pull/21", ref = "wt#21",
                 repo = pr.repo, number = 21, title = "another", branch = "jn/other")
    pr3 = W.Item(url = "https://example.invalid/o/wt/pull/22", ref = "wt#22",
                 repo = pr.repo, number = 22, title = "from a fork", branch = "them/theirs")
    known = vcat(items, [pr2, pr3])

    # A `gh` that checks out whichever branch `want` names, in the directory
    # it is run in, and writes down what it was asked - or refuses, with git's
    # own words for a changed file in the way, while `fail` exists.
    bin = joinpath(root, "bin"); mkpath(bin)
    log = joinpath(root, "gh.log"); want = joinpath(root, "want"); fail = joinpath(root, "fail")
    write(joinpath(bin, "gh"),
          string("#!/bin/sh\nprintf '%s\\n' \"\$@\" > ", log, "\n",
                 "[ \"\$1 \$2\" = 'pr checkout' ] || exit 2\n",
                 "if [ -e ", fail, " ]; then echo 'error: Your local changes would be overwritten' >&2; exit 1; fi\n",
                 "exec git checkout -q -B \"\$(cat ", want, ")\"\n"))
    chmod(joinpath(bin, "gh"), 0o755)
    asked() = isfile(log) ? split(read(log, String), '\n'; keepempty = false) : String[]

    keept = W.LOCAL[]; W.LOCAL[] = joinpath(root, "local.toml")
    write(W.localfile(), "")
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, shown)
    said = Ref{Any}(nothing); say = x -> (said[] = x)
    sleep120 = (_, _) -> "sleep 120"
    top() = last(ctrl.stack)
    # The dialogs pop themselves by identity in the loop; here the loop is
    # this test, so what a key left on top is taken off by hand.
    drop!(v) = W.pop_view!(ctrl, v)
    try
        W.register_repo!(pr.repo, main)
        write(want, pr.branch)

        # Nothing to ask without a branch, or on the branch already.
        issue = W.Item(url = "https://example.invalid/i/9", ref = "wt#9",
                       repo = pr.repo, number = 9, title = "an issue", is_pr = false)
        @test W.checkout_offer(issue, main, "master", ctrl, :shell, sleep120, say;
                               picked = true, items = known) === nothing
        @test W.checkout_offer(pr, main, pr.branch, ctrl, :shell, sleep120, say;
                               picked = true, items = known) === nothing
        @test top() === shown

        if W.mux_bin() === nothing
            @info "no tmux; skipping the checkout offer"
        else
            # Not `withenv` with a block: a closure over this many `@test`s
            # took the compiler a minute, and the same lines at this level
            # take it a second.
            keptpath = get(ENV, "PATH", "")
            ENV["PATH"] = string(bin, ":", keptpath)
            try
                # Rule 3 asks which copy; picking the main checkout, which is
                # on master, asks the second question rather than opening on
                # master. The question shows the branch and `git status`.
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1
                W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top()
                @test cv isa W.ConfirmView
                @test cv.title == string("Check out ", pr.branch, " in main?")
                @test cv.notes[1] == "main is on master"
                @test "clean" in cv.notes
                @test occursin(string("gh pr checkout ", pr.number), cv.notes[end])
                @test occursin("w another place", cv.hint)
                for (w, h) in ((80, 24), (165, 50))
                    ls = split(W.render(cv, w, h), "\n")
                    @test length(ls) == h && all(W.awidth(l) == w for l in ls)
                end
                @test isempty(asked())
                # Anything but the three named keys is no shell at all.
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)
                @test top() === shown && said[] in (nothing, "")
                @test !any(r -> r.item == pr.ref, W.mux_list())

                # A changed file is on the question, since it is what a
                # checkout trips on. `n` goes in as it is: a shell on master,
                # tagged with the item, and nothing run.
                write(joinpath(main, "a.txt"), "two\n")
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test any(n -> occursin("M a.txt", n), cv.notes)
                @test W.handle!(cv, Int('n'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView
                @test occursin("started", string(said[]))
                @test isempty(asked())
                @test any(r -> r.item == pr.ref && W.wtkey(r.worktree) == W.wtkey(main),
                          W.mux_list())
                drop!(top())
                W.git(main, "checkout", "--quiet", "--", "a.txt")

                # Going back to that session is not asked again: `n` was the
                # answer, and rule 2 finds the session without a question.
                said[] = nothing
                r = W.enter_session(pr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("back in", r)
                @test top() isa W.PaneView && said[] === nothing
                drop!(top())
                # But an agent there is a session being started, and is asked.
                @test W.enter_session(pr, ctrl, :agent, sleep120, say; items = known) == ""
                cv = top(); @test cv isa W.ConfirmView
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)

                # The copy is reused: a `gh pr checkout` in that shell put
                # another pull request's branch under it. With the list to
                # join through, the session's tag no longer places the item
                # and `t` asks again; without it the old answer stands.
                W.git(main, "checkout", "--quiet", "-b", pr2.branch)
                t, b, ask = W.item_worktree(pr; items = known)
                @test W.wtkey(t) == W.wtkey(main) && ask
                t, b, ask = W.item_worktree(pr)
                @test W.wtkey(t) == W.wtkey(main) && b == pr2.branch && !ask
                @test W.item_checkout(pr; items = known) == W.item_worktree(pr; items = known)[1:2]
                # Picking it anyway says whose it is now, and `w` is the way
                # to another place.
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.notes[1] == string("main is on ", pr2.branch, " \u00b7 ", pr2.ref, "'s")
                @test W.handle!(cv, Int('w'), ctrl) === :pop; drop!(cv)
                @test top() isa W.ChooseView
                drop!(top())

                # `y` runs the checkout there and goes in: the copy is on the
                # branch, the session is this item's, and the report says both.
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView
                @test asked() == ["pr", "checkout", pr.url]
                @test occursin("checked out", string(said[])) && occursin("back in", string(said[]))
                @test first(W.worktrees(main)).branch == pr.branch
                drop!(top())
                # And now rule 1 answers, with nothing to ask.
                t, b, ask = W.item_worktree(pr; items = known)
                @test W.wtkey(t) == W.wtkey(main) && b == pr.branch && !ask
                rm(log)

                # Taking the session over for another item asks the same
                # question - a checkout that fails still opens the shell,
                # since the shell is where the file in the way gets dealt
                # with, and gh's words lead the report.
                @test W.enter_session(pr2, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                @test occursin(string("#", pr.number), W.astrip(ch.options[1][1]))
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.notes[1] == string("main is on ", pr.branch, " \u00b7 ", pr.ref, "'s")
                touch(fail); said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView
                @test startswith(string(said[]), string("could not check out ", pr2.branch))
                @test occursin("local changes", string(said[]))
                @test occursin("was on " * pr.ref, string(said[]))
                @test first(W.worktrees(main)).branch == pr.branch
                @test any(r -> r.item == pr2.ref, W.mux_list())
                drop!(top())
                rm(fail)

                # A new worktree for a branch this repository has never had:
                # made detached and checked out by gh, and taken away again
                # when gh refuses - the prompt comes back with why.
                dest = joinpath(root, "main-them-theirs")
                write(want, pr3.branch)
                touch(fail)
                @test W.make_checkout!(pr3, ctrl, :shell, sleep120, say, dest; items = known) == ""
                pv = top(); @test pv isa W.PromptView
                @test occursin("local changes", pv.note) && W.text(pv) == dest
                @test !isdir(dest)
                @test length(W.worktrees(main)) == 1
                drop!(pv)
                rm(fail)
                r = W.make_checkout!(pr3, ctrl, :shell, sleep120, say, dest; items = known)
                @test r isa String && occursin("made", r) && occursin("started", r)
                @test top() isa W.PaneView
                @test asked() == ["pr", "checkout", pr3.url]
                ws = Dict(w.path => w for w in W.worktrees(main))
                @test haskey(ws, realpath(dest)) && ws[realpath(dest)].branch == pr3.branch
                drop!(top())
                # A branch that is here is still git's to check out, not gh's.
                rm(log)
                W.git(main, "branch", "--quiet", "local-only", "master")
                pr4 = W.Item(url = "https://example.invalid/o/wt/pull/23", ref = "wt#23",
                             repo = pr.repo, number = 23, title = "local", branch = "local-only")
                dest4 = joinpath(root, "main-local-only")
                r = W.make_checkout!(pr4, ctrl, :shell, sleep120, say, dest4; items = known)
                @test r isa String && occursin("made", r)
                @test isempty(asked())
                drop!(top())
            finally
                ENV["PATH"] = keptpath
            end
            for r in W.mux_list()
                r.item in (pr.ref, pr2.ref, pr3.ref, "wt#23") && W.mux_kill(r.name)
            end
        end
    finally
        W.LOCAL[] = keept
        while top() !== shown
            pop!(ctrl.stack)
        end
    end
end

@testset "worktrees, with the sessions folded in" begin
    items = W.loaditems()
    ctrl = W.Controller(); ctrl.running = true

    # A repo with two worktrees, one of them on a branch that has a pull
    # request in the real facts.json - which is the join this view is for.
    # Taken from what the browser is actually showing, since `i` goes to the
    # row in that list and an item outside it is a different case, tested below.
    shown = W.BState(items, "worklog")
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

    W.LOCAL[] = joinpath(root, "local.toml")
    write(W.localfile(), "")
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
        st = W.BState(items, "worklog")
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
        st2 = W.BState(items, "worklog")
        st2.filters.repos = Set(["nothing/here"])
        st2.search = "zzzz-no-such-item"; st2.searchin = :list
        W.refilter!(st2)
        @test isempty(st2.items)
        v4 = W.worktree_view(items; onitem = x -> W.select_item!(st2, x))
        v4.sel = findfirst(r -> r.name == "side", v4.rows)
        @test W.handle!(v4, Int('i'), ctrl) === :pop
        @test st2.items[st2.sel].url == pr.url
        # Everything, since the row being jumped to may be filed or closed: the
        # jump clears the axes *and* turns the four disposition boxes on.
        @test st2.filters.show == W.everything().show
        @test isempty(st2.filters.repos) && isempty(st2.filters.tags)
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
        W.LOCAL[] = REPOS_SANDBOX
    end
end

@testset "e opens the checkout, and a diff line in it" begin
    pr = fixture_item("yours, open, with a branch and labels")
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    side = joinpath(root, "side")
    W.git(main, "worktree", "add", "--quiet", "-b", pr.branch, side)

    # A `code` that writes down what it was asked, and a socket for it to be
    # "live" through - the same two things `forwards!` looks for. Its answer
    # to `--list-extensions` is a file, so the extension can be installed
    # part way through.
    bin = joinpath(root, "bin"); mkpath(bin)
    log = joinpath(root, "code.log"); exts = joinpath(root, "extensions")
    write(exts, "")
    write(joinpath(bin, "code"),
          string("#!/bin/sh\n[ \"\$1\" = --list-extensions ] && exec cat ", exts, "\n",
                 "printf '%s\\n' \"\$@\" > ", log, "\n"))
    chmod(joinpath(bin, "code"), 0o755)
    ipc = joinpath(root, "ipc.sock"); li = Sockets.listen(ipc)
    args() = (sleep(0.2); readlines(log))
    path = string(bin, ":", ENV["PATH"])       # in front, and git still found

    # The fixture's pull request, with a base this repository has.
    first_ = strip(W.git(main, "rev-parse", "HEAD"))
    mine = W.Item(url = pr.url, ref = pr.ref, repo = pr.repo, number = pr.number,
                  title = pr.title, branch = pr.branch, base = "master",
                  head = "0123456789012345678901234567890123456789")

    keept, keeprun = W.LOCAL[], W.RUN_DIR[]
    W.LOCAL[] = joinpath(root, "local.toml"); write(W.localfile(), "")
    W.RUN_DIR[] = joinpath(root, "run")
    try
        @test W.open_editor(pr) === :needs_repo
        W.register_repo!(pr.repo, main)
        withenv("PATH" => path, "VSCODE_IPC_HOOK_CLI" => ipc) do
            # The folder is the worktree on the branch - `t`'s answer too.
            r = W.open_editor(pr)
            @test occursin("opened", r) && occursin(pr.branch, r)
            @test args() == [side]
            # A line: the folder stays on the command line, so the file opens
            # in that folder's window, and the file is named as it is there.
            r = W.open_editor(pr, ("a.txt", 1))
            @test occursin("a.txt:1", r)
            @test args() == ["--goto", side, joinpath(side, "a.txt") * ":1"]
            # A file the diff names that the checkout lacks: the folder, said.
            r = W.open_editor(pr, ("gone.txt", 3))
            @test occursin("no gone.txt", r)
            @test args() == [side]

            # The diff at the line wants the extension. Without it, the file
            # at the line, and the status says what is missing.
            empty!(W.HAS_WORKLOG_EXT)
            r = W.open_editor(mine, ("a.txt", 1); mode = :diff)
            @test occursin("a.txt:1", r) && occursin("no worklog extension", r)
            @test args() == ["--goto", side, joinpath(side, "a.txt") * ":1"]
            # The same without a base to measure against is not a shortfall
            # of the extension's, and is not blamed on it.
            nobase = W.Item(url = pr.url, ref = pr.ref, repo = pr.repo, number = pr.number,
                            title = pr.title, branch = pr.branch)
            r = W.open_editor(nobase, ("a.txt", 1); mode = :diff)
            @test occursin("a.txt:1", r) && !occursin("extension", r)
            @test W.urlenc("a b&c/é~") == "a%20b%26c%2F%C3%A9~"

            # With it: a url to the extension. Under `d` the left side is the
            # merge base with the base branch, and the right side is the
            # working tree, since the checkout is on the branch.
            write(exts, "ms-vscode.something\nvtjnash.worklog\n")
            empty!(W.HAS_WORKLOG_EXT)
            r = W.open_editor(mine, ("a.txt", 1); mode = :diff)
            @test occursin("the diff of a.txt:1", r)
            a = args()
            @test a[1] == "--open-url" && length(a) == 2
            @test a[2] == string("vscode://vtjnash.worklog/diff?root=", W.urlenc(side),
                                 "&path=", W.urlenc(joinpath(side, "a.txt")),
                                 "&line=1&left=", first_)
            # Under `p`, the head you last read.
            W.set_read_mark(mine.url, "2026-09-01T00:00:00Z", first_)
            r = W.open_editor(mine, ("a.txt", 1); mode = :pushed)
            @test occursin("the diff of", r) && endswith(args()[2], "&left=" * first_)
            # A checkout that is not on the branch has the wrong file in its
            # working tree, so the right side is the head GitHub reports - and
            # the merge base cannot be measured against a commit that is not
            # here, so the left is the base ref itself.
            other = W.Item(url = pr.url * "x", ref = "wt#7", repo = pr.repo, number = 7,
                           title = "elsewhere", branch = "nowhere-local", base = "master",
                           head = mine.head)
            r = W.open_editor(other, ("a.txt", 1); mode = :diff)
            @test occursin("the diff of", r)
            @test endswith(args()[2], string("&left=", W.urlenc("refs/heads/master"),
                                             "&right=", mine.head))
            # The head is what GitHub reports, and the checkout on some other
            # branch is asked whether it has it - here it does, so the merge
            # base is measured and the head goes on the right.
            write(joinpath(side, "a.txt"), "two\n")
            W.git(side, "commit", "--quiet", "-am", "second")
            pushed = strip(W.git(side, "rev-parse", "HEAD"))
            real = W.Item(url = pr.url * "y", ref = "wt#8", repo = pr.repo, number = 8,
                          title = "pushed", branch = "nowhere-local", base = "master",
                          head = pushed)
            @test W.diff_refs(real, main, :diff) == (first_, pushed)
            # And the branch that decides "on the branch" is the pull
            # request's: the main checkout is not on it, whatever a session
            # there was opened for.
            @test W.diff_refs(mine, side, :diff) == (first_, "")
            @test W.diff_refs(real, side, :diff) == (first_, pushed)
            # Under `o` there is no diff, and the line is just a line.
            r = W.open_editor(mine, ("a.txt", 1); mode = :comments)
            @test args()[1] == "--goto"
        end
        # The server's CLI - what a Remote-SSH terminal has - spells the url
        # option differently, and an Insiders server answers to its own
        # scheme; both are read off the path the link resolves to.
        rcli = joinpath(root, ".vscode-server-insiders", "bin", "remote-cli"); mkpath(rcli)
        cp(joinpath(bin, "code"), joinpath(rcli, "code"))
        withenv("PATH" => string(rcli, ":", ENV["PATH"]), "VSCODE_IPC_HOOK_CLI" => ipc) do
            r = W.open_editor(mine, ("a.txt", 1); mode = :diff)
            a = args()
            @test a[1] == "--openExternal" && startswith(a[2], "vscode-insiders://vtjnash.worklog/diff?")
        end
        # Nothing live to open it in - the link's socket gone too - is said,
        # and nothing is run.
        rm(log); close(li)
        withenv("PATH" => path, "VSCODE_IPC_HOOK_CLI" => joinpath(root, "dead.sock")) do
            @test W.open_editor(pr) == "no live VS Code to open it in"
            @test !isfile(log)
        end
    finally
        close(li)
        W.LOCAL[] = keept; W.RUN_DIR[] = keeprun
    end
end

@testset "d is the checkout's diff, and gh's only without one" begin
    # Two repositories: `remote`, which stands for GitHub, and `main`, the
    # pinned checkout, cloned from it - so a fetch has somewhere to go.
    root = mktempdir()
    remote = joinpath(root, "remote"); mkpath(remote)
    W.git(remote, "init", "--quiet", "--initial-branch=master", ".")
    W.git(remote, "config", "user.email", "t@example.com")
    W.git(remote, "config", "user.name", "t")
    write(joinpath(remote, "a.txt"), "one\ntwo\n")
    W.git(remote, "add", "a.txt"); W.git(remote, "commit", "--quiet", "-m", "first")
    base1 = strip(W.git(remote, "rev-parse", "HEAD"))
    main = joinpath(root, "main")
    run(pipeline(`git clone --quiet $remote $main`; stdout = devnull, stderr = devnull))
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    # The pull request: a branch on the remote, and its head where GitHub
    # serves one, under refs/pull/N/head.
    W.git(remote, "checkout", "--quiet", "-b", "topic")
    write(joinpath(remote, "a.txt"), "one\ntwo\nthree\n")
    W.git(remote, "commit", "--quiet", "-am", "add three")
    head = strip(W.git(remote, "rev-parse", "HEAD"))
    W.git(remote, "update-ref", "refs/pull/5/head", head)
    W.git(remote, "checkout", "--quiet", "master")
    offline() = W.git(main, "remote", "set-url", "origin", joinpath(root, "nowhere"))
    online() = W.git(main, "remote", "set-url", "origin", remote)
    # Move master on the remote and rebase topic onto it; the new head is
    # served, and where master now is comes back for the record.
    function rebase!(file)
        write(joinpath(remote, file), "base moved\n")
        W.git(remote, "add", file); W.git(remote, "commit", "--quiet", "-m", "on master")
        b = strip(W.git(remote, "rev-parse", "HEAD"))
        W.git(remote, "checkout", "--quiet", "topic")
        W.git(remote, "rebase", "--quiet", "master")
        h = strip(W.git(remote, "rev-parse", "HEAD"))
        W.git(remote, "update-ref", "refs/pull/5/head", h)
        W.git(remote, "checkout", "--quiet", "master")
        (b, h)
    end
    pr(; kw...) = W.Item(url = "https://example.invalid/pull/5", ref = "o/r#5", repo = "o/r",
                         number = 5, title = "t", base = "master", branch = "topic"; kw...)

    keept, keepdir = W.LOCAL[], W.CACHE_DIR[]
    W.LOCAL[] = joinpath(root, "local.toml"); write(W.localfile(), "")
    W.CACHE_DIR[] = joinpath(root, "cache")
    asked = Ref(0)
    gh = _ -> (asked[] += 1; (0, "diff --git a/gh b/gh\n@@ -1 +1 @@\n-x\n+y\n", ""))
    it = pr(head = head, base_sha = base1)
    try
        # No checkout pinned: gh, under its key by number.
        ns = W.diff_nodes(it; run = gh)
        @test asked[] == 1 && ns[1].meta["file"] == "gh"
        @test W.cache_has(W.diff_key(it)) && !(string(it.url, "@", head) in W.DIFFED)

        # Pinned: the checkout's diff, the head fetched from `refs/pull/5/head`
        # since the clone has never seen it, and gh not asked.
        W.register_repo!(it.repo, main)
        @test !W.have_commit(main, head)
        ns = W.diff_nodes(it; run = gh)
        @test asked[] == 1
        @test length(ns) == 1 && ns[1].meta["file"] == "a.txt"
        @test ns[1].meta["start"] == 1 && ns[1].meta["count"] == 3
        @test occursin("+three", ns[1].raw)
        @test W.have_commit(main, head) && string(it.url, "@", head) in W.DIFFED
        @test W.mode_cached(:diff, it)

        # With both shas here nothing goes over the network: the remote can
        # be gone and the answer is the same.
        offline()
        @test W.diff_nodes(it; run = gh)[1].meta["file"] == "a.txt" && asked[] == 1
        online()

        # Rebased past the base the checkout has. The record carries where
        # master is now, the checkout does not have it, and one fetch of the
        # branch brings it: the diff is the pull request's commit alone, not
        # master's new one with it.
        base2, head2 = rebase!("b.txt")
        it2 = pr(head = head2, base_sha = base2)
        ns = W.diff_nodes(it2; run = gh)
        @test asked[] == 1
        @test length(ns) == 1 && ns[1].meta["file"] == "a.txt"
        @test !any(n -> n.meta["file"] == "b.txt", ns)
        @test W.have_commit(main, base2)

        # A record with no base sha - from before the lanes carried one - is
        # the branch, fetched every time. Offline, with a copy the head has
        # been rebased past, the checkout cannot tell its copy is stale and
        # says nothing rather than a diff with master's commits in it; gh's
        # copy by number, still inside its two minutes, answers.
        base3, head3 = rebase!("c.txt")
        W.git(main, "fetch", "--quiet", "origin", string(head3, ":refs/heads/topic-local"))
        offline()
        it3 = pr(head = head3)
        ns = W.diff_nodes(it3; run = gh)
        @test asked[] == 1 && ns[1].meta["file"] == "gh"
        @test !(string(it3.url, "@", head3) in W.DIFFED)
        # The same record online is the branch fetched, and the right diff.
        online()
        ns = W.diff_nodes(it3; run = gh)
        @test asked[] == 1 && length(ns) == 1 && ns[1].meta["file"] == "a.txt"
        @test string(it3.url, "@", head3) in W.DIFFED

        # A head nobody serves: the checkout cannot answer, and gh does.
        it4 = pr(head = "0123456789012345678901234567890123456789", base_sha = base3)
        ns = W.diff_nodes(it4; fresh = true, run = gh)
        @test asked[] == 2 && ns[1].meta["file"] == "gh"
    finally
        W.LOCAL[] = keept; W.CACHE_DIR[] = keepdir
    end
end
