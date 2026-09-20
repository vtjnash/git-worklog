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
    # Without its head: the fixture's is a real commit that is nowhere in the
    # repository made here, and a name here whose head nothing can find is
    # taken (`pr_branch_here`), which is the case for the rows made below
    # for it, not for this one, which stands for a pull request whose branch
    # is simply its name.
    pr = W.with(fixture_item("yours, open, with a branch and labels"); head = "")
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    # Said in the repo, so the questions below read the same whatever the
    # machine's own git config says; the lease block flips it.
    W.git(main, "config", "push.useForceIfIncludes", "true")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    # Two more pull requests of the same repository, on branches of their own:
    # one of yours to reuse the copy for, one from a fork whose branch is
    # nowhere here.
    pr2 = W.Item(url = "https://example.invalid/o/wt/pull/21", ref = "wt#21",
                 repo = pr.repo, number = 21, title = "another", branch = "jn/other",
                 author = W.login())
    pr3 = W.Item(url = "https://example.invalid/o/wt/pull/22", ref = "wt#22",
                 repo = pr.repo, number = 22, title = "from a fork", branch = "them/theirs")
    known = vcat(items, [pr2, pr3])
    # And a stranger's, from their fork's `master`: a name the main checkout
    # is on, and not a claim to it.
    stranger = W.Item(url = "https://example.invalid/o/wt/pull/30", ref = "wt#30",
                      repo = pr.repo, number = 30, title = "from their master",
                      branch = "master", author = "somebody-else")
    withstranger = vcat(known, [stranger])

    # A `gh` that checks out whichever branch `want` names - or the one
    # `--branch` names, as the real one does - in the directory it is run in,
    # and writes down what it was asked; or refuses, with git's own words for
    # a changed file in the way, while `fail` exists.
    bin = joinpath(root, "bin"); mkpath(bin)
    log = joinpath(root, "gh.log"); want = joinpath(root, "want"); fail = joinpath(root, "fail")
    write(joinpath(bin, "gh"),
          string("#!/bin/sh\nprintf '%s\\n' \"\$@\" > ", log, "\n",
                 "[ \"\$1 \$2\" = 'pr checkout' ] || exit 2\n",
                 "if [ -e ", fail, " ]; then echo 'error: Your local changes would be overwritten' >&2; exit 1; fi\n",
                 "b=\"\$(cat ", want, ")\"; [ \"\$4\" = --branch ] && b=\"\$5\"\n",
                 "exec git checkout -q -B \"\$b\"\n"))
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
        atmain = (path = main, branch = "master", main = true)
        @test W.checkout_offer(issue, atmain, "", ctrl, :shell, sleep120, say;
                               picked = true, items = known) === nothing
        @test W.checkout_offer(pr, (path = main, branch = pr.branch, main = true), pr.branch,
                               ctrl, :shell, sleep120, say;
                               picked = true, items = known) === nothing
        @test top() === shown

        # Whose branch a checkout is on is one answer for the list and the
        # key alike, refusal included: a stranger's pull request from their
        # `master` does not own the main checkout, which is on `master` for
        # its own reasons - though it does own a worktree made for it, and
        # one of yours from `master` owns either.
        ix = W.branch_index(withstranger)
        @test W.branch_owner(pr, atmain, ix) === nothing
        @test W.branch_owner(pr, (branch = "master", main = false), ix) === stranger
        @test W.branch_carrier(ix, pr.repo, atmain) === nothing
        @test W.branch_owner(stranger, (branch = "master", main = false), ix) === nothing
        yours = W.Item(url = "https://example.invalid/o/wt/pull/31", ref = "wt#31",
                       repo = pr.repo, number = 31, title = "from your master",
                       branch = "master", author = W.login())
        @test W.branch_owner(pr, atmain, W.branch_index(vcat(known, [yours]))) === yours
        # An item that is nobody's branch sees nothing, and an empty index too.
        @test W.branch_owner(pr, (branch = "nowhere", main = false), ix) === nothing
        @test W.branch_owner(pr, atmain, W.branch_index(W.Item[])) === nothing
        # Rule 1 makes the same refusal: main on `master` is not the
        # stranger's place by the name alone, list or no list, so `t` on
        # their pull request asks rather than opening the project's own
        # main checkout on the project's own `master`. Yours from `master`
        # is found there.
        @test W.item_worktree(stranger; items = withstranger).ask
        @test W.item_worktree(stranger).ask
        r = W.item_worktree(yours)
        @test !r.ask && W.wtkey(r.path) == W.wtkey(main) && r.main

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
                # Nor when a stranger's pull request from their `master` is in
                # the list: main being on `master` is not main being theirs,
                # so the copy is not reused and the answer still stands.
                r = W.item_worktree(pr; items = withstranger)
                @test W.wtkey(r.path) == W.wtkey(main) && !r.ask && r.main && r.pr == pr.branch
                @test r.rows !== nothing && any(x -> x.item == pr.ref, r.rows)
                said[] = nothing
                r = W.enter_session(pr, ctrl, :shell, sleep120, say; items = withstranger)
                @test r isa String && occursin("back in", r)
                @test top() isa W.PaneView && said[] === nothing
                drop!(top())
                # Nor is an agent there: the question was about the place,
                # and the shell's `n` answered it for the agent too.
                said[] = nothing
                r = W.enter_session(pr, ctrl, :agent, sleep120, say; items = known)
                @test r isa String && occursin("started", r)
                @test top() isa W.PaneView && said[] === nothing
                @test isempty(asked())
                drop!(top())

                # The copy is reused: a `gh pr checkout` in that shell put
                # another pull request's branch under it. With the list to
                # join through, the copy is theirs; without it, it has still
                # moved off the branch the sessions were entered on. Either
                # way the tag no longer places the item and `t` asks again.
                W.git(main, "checkout", "--quiet", "-b", pr2.branch)
                t, b, ask = W.item_worktree(pr; items = known)
                @test W.wtkey(t) == W.wtkey(main) && ask
                t, b, ask = W.item_worktree(pr)
                @test W.wtkey(t) == W.wtkey(main) && ask
                r = W.item_worktree(pr; items = known)
                @test W.item_checkout(pr; items = known) == (r.path, r.branch)
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
                # `n` here is an answer about the place as it is, not for
                # good: the copy is still another item's, so the next `t`
                # asks again rather than opening on their branch on the
                # strength of an old answer.
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test W.handle!(cv, Int('n'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView && occursin("back in", string(said[]))
                drop!(top())
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
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

                # Parking. The copy is put on master under the item's own
                # shell - a branch that is nobody's, the way a worktree is
                # marked free - and going back is asked, with or without the
                # list: the copy has moved since the shell was last entered.
                @test any(r -> r.item == pr.ref && r.kind == "shell" && r.branch == pr.branch,
                          W.mux_list())
                W.git(main, "checkout", "--quiet", "master")
                @test W.item_worktree(pr; items = known).ask
                @test W.item_worktree(pr).ask
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.notes[1] == "main is on master"
                said[] = nothing
                @test W.handle!(cv, Int('n'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView && occursin("back in", string(said[]))
                drop!(top())
                # `n` re-tags the shell with master, so while the copy stays
                # put the answer holds, for the agent too; detaching it is a
                # move again, and so is any other branch.
                r = W.item_worktree(pr; items = known)
                @test W.wtkey(r.path) == W.wtkey(main) && r.branch == "master" && !r.ask
                said[] = nothing
                r = W.enter_session(pr, ctrl, :agent, sleep120, say; items = known)
                @test r isa String && occursin("back in", r) && said[] === nothing
                drop!(top())
                W.git(main, "checkout", "--quiet", "--detach", "master")
                @test W.item_worktree(pr; items = known).ask
                W.git(main, "checkout", "--quiet", "-b", "scratch", "master")
                @test W.item_worktree(pr; items = known).ask
                W.git(main, "checkout", "--quiet", "master")
                @test !W.item_worktree(pr; items = known).ask
                W.git(main, "branch", "--quiet", "-D", "scratch")
                # A tag from before there was one knows nothing, and sees no
                # move until the item is put there again, which writes one -
                # `@` for a detached head, so that staying detached is not a
                # move and leaving it is.
                for r in W.mux_list()
                    (r.item == pr.ref && W.wtkey(r.worktree) == W.wtkey(main)) &&
                        W.mux_tag!(r.name; branch = "")
                end
                W.git(main, "checkout", "--quiet", "--detach", "master")
                @test !W.item_worktree(pr; items = known).ask
                said[] = nothing
                r = W.enter_session(pr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("back in", r) && said[] === nothing
                drop!(top())
                tags = [r.branch for r in W.mux_list()
                        if r.item == pr.ref && W.wtkey(r.worktree) == W.wtkey(main)]
                @test length(tags) == 2 && all(==("@"), tags)
                @test !W.item_worktree(pr; items = known).ask
                W.git(main, "checkout", "--quiet", "master")
                @test W.item_worktree(pr; items = known).ask
                # An issue has no right branch, so its shell is wherever it is.
                @test W.enter_session(issue, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                @test top() isa W.PaneView; drop!(top())
                W.git(main, "checkout", "--quiet", "--detach", "master")
                @test !W.item_worktree(issue; items = known).ask
                # Back on the branch, and the shell is pr's again for the
                # moves below.
                W.git(main, "checkout", "--quiet", pr.branch)
                r = W.enter_session(pr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("back in", r)
                drop!(top())

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

                # A session is keyed to its worktree, and taking it over moves
                # it between items; each move onto a copy that is on the other
                # item's branch is asked about, in either direction. Taking it
                # back while the copy is still on this item's branch is not:
                # rule 1 has the answer, and the shell is re-pointed with a word.
                # The agent in main from before stays pr's throughout: a
                # session is its worktree *and* its kind.
                shell_of() = [r.item for r in W.mux_list()
                              if W.wtkey(r.worktree) == W.wtkey(main) && r.kind == "shell"]
                said[] = nothing
                r = W.enter_session(pr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("back in", r) && occursin("was on " * pr2.ref, r)
                @test top() isa W.PaneView && said[] === nothing
                @test shell_of() == [pr.ref]
                @test any(r -> r.item == pr.ref && r.kind == "agent", W.mux_list())
                drop!(top())
                # pr2 takes it, and this time the checkout lands.
                write(want, pr2.branch)
                @test W.enter_session(pr2, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.notes[1] == string("main is on ", pr.branch, " \u00b7 ", pr.ref, "'s")
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView && occursin("checked out " * pr2.branch, string(said[]))
                @test first(W.worktrees(main)).branch == pr2.branch
                @test shell_of() == [pr2.ref]
                drop!(top())
                # Back to pr: the copy is on pr2's branch now, so it is asked.
                write(want, pr.branch)
                @test W.enter_session(pr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                @test occursin(string("#", pr2.number), W.astrip(ch.options[1][1]))
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.notes[1] == string("main is on ", pr2.branch, " \u00b7 ", pr2.ref, "'s")
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView && occursin("checked out " * pr.branch, string(said[]))
                @test first(W.worktrees(main)).branch == pr.branch
                @test shell_of() == [pr.ref]
                drop!(top())
                # And pr2 again: the third move is asked like the first two.
                @test W.enter_session(pr2, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.notes[1] == string("main is on ", pr.branch, " \u00b7 ", pr.ref, "'s")
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)
                @test top() === shown
                @test shell_of() == [pr.ref]
                rm(log)

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

                # Unless it is only a branch of the same *name*: a fork's pull
                # request from its `shared` is not the `shared` here, and the
                # head sha says so. One whose head is on the branch here is.
                W.git(main, "branch", "--quiet", "shared", "master")
                tip = strip(W.git(main, "rev-parse", "shared"))
                theirs = W.Item(url = "https://example.invalid/o/wt/pull/24", ref = "wt#24",
                                repo = pr.repo, number = 24, title = "theirs", branch = "shared",
                                head = "0123456789012345678901234567890123456789")
                ours = W.Item(url = "https://example.invalid/o/wt/pull/25", ref = "wt#25",
                              repo = pr.repo, number = 25, title = "ours", branch = "shared",
                              head = tip)
                @test W.pr_branch_here(main, theirs, "shared") === :taken
                @test W.pr_branch_here(main, ours, "shared") === :local
                @test W.pr_branch_here(main, pr4, "local-only") === :local  # no sha: the name
                @test W.pr_branch_here(main, W.with(pr3; branch = "them/nowhere"), "them/nowhere") === :none
                # A name that is taken is gh's under a name of its own, since
                # gh handed the taken one would fetch the pull request *into*
                # the branch that is here. That branch is left as it was.
                write(want, "shared")
                dest5 = joinpath(root, "main-shared")
                r = W.make_checkout!(theirs, ctrl, :shell, sleep120, say, dest5; items = known)
                @test r isa String && occursin("made", r)
                @test asked() == ["pr", "checkout", theirs.url, "--branch", "pr24/shared"]
                ws = Dict(w.path => w for w in W.worktrees(main))
                @test haskey(ws, realpath(dest5)) && ws[realpath(dest5)].branch == "pr24/shared"
                @test strip(W.git(main, "rev-parse", "shared")) == tip
                drop!(top())
                rm(log)

                # The project's own copy of a branch is what tells one of
                # yours that has moved from a stranger's of the same name.
                # `other` stands in for the project: main's `origin`, and its
                # `upstream` too, since a checkout of somebody else's project
                # has both and they carry the same release branches.
                other = joinpath(root, "other")
                W.git(root, "clone", "--quiet", main, other)
                W.git(other, "config", "user.email", "t@example.com")
                W.git(other, "config", "user.name", "t")
                W.git(other, "checkout", "--quiet", "-b", "moved", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "pushed from elsewhere")
                moved1 = strip(W.git(other, "rev-parse", "moved"))
                W.git(main, "remote", "add", "origin", other)
                W.git(main, "remote", "add", "upstream", other)
                W.git(main, "fetch", "--quiet", "origin")
                W.git(main, "fetch", "--quiet", "upstream")
                # Your local `moved` is behind the head; the remote's copy has
                # it, so it is yours - the old rule sent it to gh's ff-only
                # merge, which refuses exactly the branch with your work on it.
                W.git(main, "branch", "--quiet", "moved", "master")
                mine1 = W.Item(url = "https://example.invalid/o/wt/pull/26", ref = "wt#26",
                               repo = pr.repo, number = 26, title = "moved", branch = "moved",
                               head = moved1)
                @test W.pr_branch_here(main, mine1, "moved") === :local
                # And when the remote's copy is stale the branch is fetched
                # before the name is disowned - into a ref of the program's
                # own, not the remote-tracking one, which is the user's
                # force-with-lease lease and stays where they last saw it.
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "and again")
                moved2 = strip(W.git(other, "rev-parse", "moved"))
                mine2 = W.with(mine1; url = "https://example.invalid/o/wt/pull/27", ref = "wt#27",
                               number = 27, head = moved2)
                @test !W.have_commit(main, moved2)
                @test W.pr_branch_here(main, mine2, "moved") === :local
                @test strip(W.git(main, "rev-parse", "refs/remotes/origin/moved")) == moved1
                @test strip(W.git(main, "rev-parse", "refs/worklog/origin/moved")) == moved2
                # A stranger's `moved` - a head the project's copy has never
                # heard of - is still taken, fetch or no fetch.
                @test W.pr_branch_here(main, W.with(mine1; head = theirs.head), "moved") === :taken
                # A branch that once had the head and was rewound is yours by
                # its own reflog, with nothing asked of the network: the
                # remote has no such branch, and no private copy is made.
                W.git(main, "branch", "--quiet", "rewound", moved2)
                W.git(main, "branch", "--quiet", "-f", "rewound", "master")
                rw = W.with(mine1; url = "https://example.invalid/o/wt/pull/29", ref = "wt#29",
                            number = 29, branch = "rewound")
                @test W.branch_included(main, "rewound", moved2)
                @test !W.branch_included(main, "moved", moved2)
                @test W.pr_branch_here(main, W.with(rw; head = moved2), "rewound") === :local
                @test !W.has_rev(main, "refs/worklog/origin/rewound")

                # A branch on the remote only is made from the remote's copy,
                # said by name: two remotes carry it, and left to guess git
                # refuses with `invalid reference`.
                W.git(other, "checkout", "--quiet", "-b", "remote-only", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "on the remote")
                W.git(main, "fetch", "--quiet", "origin")
                W.git(main, "fetch", "--quiet", "upstream")
                rtip = strip(W.git(main, "rev-parse", "refs/remotes/origin/remote-only"))
                remo = W.Item(url = "https://example.invalid/o/wt/pull/28", ref = "wt#28",
                              repo = pr.repo, number = 28, title = "remote", branch = "remote-only",
                              head = rtip)
                @test W.pr_branch_here(main, remo, "remote-only") === :remote
                @test_throws W.GitError W.add_worktree!(main, "remote-only", joinpath(root, "nope"))
                dest6 = joinpath(root, "main-remote-only")
                r = W.make_checkout!(remo, ctrl, :shell, sleep120, say, dest6; items = known)
                @test r isa String && occursin("made", r) && occursin("started", r)
                @test isempty(asked())
                ws = Dict(w.path => w for w in W.worktrees(main))
                @test haskey(ws, realpath(dest6)) && ws[realpath(dest6)].branch == "remote-only"
                @test strip(W.git(dest6, "rev-parse", "--abbrev-ref", "@{u}")) == "origin/remote-only"
                drop!(top())

                # Upstream moved while nobody here was looking. `other` has two
                # commits on `ff`; the local `ff` is at the first, never had
                # the second, and the pull request's head is the second. A
                # fresh landing on it offers the fast-forward, and says why.
                W.git(other, "checkout", "--quiet", "-b", "ff", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "ff one")
                f1 = strip(W.git(other, "rev-parse", "ff"))
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "ff two")
                f2 = strip(W.git(other, "rev-parse", "ff"))
                W.git(main, "fetch", "--quiet", "origin")
                W.git(main, "branch", "--quiet", "ff", f1)
                W.git(main, "branch", "--quiet", "-u", "origin/ff", "ff")
                ffpr = W.Item(url = "https://example.invalid/o/wt/pull/40", ref = "wt#40",
                              repo = pr.repo, number = 40, title = "moved on", branch = "ff",
                              head = f2)
                @test W.branch_lag(main, "ff", f2) == (ahead = 0, behind = 1)
                dest7 = joinpath(root, "main-ff")
                # With the lease setting off, the question ends on the line
                # about it: a branch somebody else pushed to is what a lease
                # is about, and the user's own gh moves it as much as ours.
                W.git(main, "config", "push.useForceIfIncludes", "false")
                @test W.make_checkout!(ffpr, ctrl, :shell, sleep120, say, dest7; items = known) == ""
                cv = top(); @test cv isa W.ConfirmView
                @test cv.title == "Fast-forward ff in main-ff?"
                @test cv.notes[1] == "ff is 1 commit behind wt#40's head, pushed from somewhere else"
                @test cv.notes[end - 1] == "y runs git merge --ff-only there"
                @test cv.notes[end] == "push.useForceIfIncludes is not set \u00b7 any fetch moves origin/ff, which is all --force-with-lease checks"
                @test isempty(asked())
                W.git(main, "config", "push.useForceIfIncludes", "true")
                # `n` goes in as it is, and the place is looked at: the agent
                # one key later is not asked, nor is going back.
                said[] = nothing
                @test W.handle!(cv, Int('n'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView && occursin("started", string(said[]))
                @test strip(W.git(dest7, "rev-parse", "ff")) == f1
                drop!(top())
                # Picked by hand, the copy is a fresh look, session or not.
                @test W.make_checkout!(ffpr, ctrl, :shell, sleep120, say, dest7; items = known) == ""
                cv = top(); @test cv isa W.ConfirmView && cv.title == "Fast-forward ff in main-ff?"
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)
                @test top() isa W.BState
                said[] = nothing
                r = W.enter_session(ffpr, ctrl, :agent, sleep120, say; items = known)
                @test r isa String && occursin("started", r) && top() isa W.PaneView
                drop!(top())
                r = W.enter_session(ffpr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("back in", r)
                drop!(top())
                # A new session some time later is a new look: `y` fast-forwards
                # and goes in, and the branch is at the head.
                for r in W.mux_list()
                    W.wtkey(r.worktree) == W.wtkey(dest7) && W.mux_kill(r.name)
                end
                @test W.enter_session(ffpr, ctrl, :shell, sleep120, say; items = known) == ""
                cv = top(); @test cv isa W.ConfirmView
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView
                @test occursin("fast-forwarded ff", string(said[])) && occursin("started", string(said[]))
                @test strip(W.git(dest7, "rev-parse", "ff")) == f2
                drop!(top())
                # And nothing more to ask, with or without a session there.
                for r in W.mux_list()
                    W.wtkey(r.worktree) == W.wtkey(dest7) && W.mux_kill(r.name)
                end
                r = W.enter_session(ffpr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("started", r) && top() isa W.PaneView
                drop!(top())
                # The lease stayed put through all of it.
                @test strip(W.git(main, "rev-parse", "refs/remotes/origin/ff")) == f2

                # Diverged unseen: a commit of the branch's own on top of the
                # first, and the head on neither. No fast-forward to offer; the
                # status line says so and the shell is where the rebase is.
                W.git(other, "checkout", "--quiet", "-b", "div", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "div one")
                d1 = strip(W.git(other, "rev-parse", "div"))
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "div two")
                d2 = strip(W.git(other, "rev-parse", "div"))
                W.git(main, "fetch", "--quiet", "origin")
                tree = strip(W.git(main, "rev-parse", string(d1, "^{tree}")))
                dl = strip(W.git(main, "commit-tree", tree, "-p", d1, "-m", "local"))
                W.git(main, "branch", "--quiet", "div", dl)
                W.git(main, "branch", "--quiet", "-u", "origin/div", "div")
                divpr = W.Item(url = "https://example.invalid/o/wt/pull/41", ref = "wt#41",
                               repo = pr.repo, number = 41, title = "diverged", branch = "div",
                               head = d2)
                @test W.branch_lag(main, "div", d2) == (ahead = 1, behind = 1)
                @test W.pr_branch_here(main, divpr, "div") === :local
                dest8 = joinpath(root, "main-div")
                r = W.make_checkout!(divpr, ctrl, :shell, sleep120, say, dest8; items = known)
                @test r isa String && occursin("made", r) && occursin("started", r)
                @test occursin("div has 1 commit not in wt#41's head, and is 1 behind it", r)
                @test top() isa W.PaneView && strip(W.git(dest8, "rev-parse", "div")) == dl
                drop!(top())

                # Rewound on purpose: the branch once had the head, so being
                # behind it is no news, and the landing says nothing.
                W.git(main, "branch", "--quiet", "rw", f2)
                W.git(main, "branch", "--quiet", "-f", "rw", f1)
                W.git(main, "branch", "--quiet", "-u", "origin/ff", "rw")
                rwpr = W.Item(url = "https://example.invalid/o/wt/pull/42", ref = "wt#42",
                              repo = pr.repo, number = 42, title = "rewound", branch = "rw",
                              head = f2)
                dest9 = joinpath(root, "main-rw")
                r = W.make_checkout!(rwpr, ctrl, :shell, sleep120, say, dest9; items = known)
                @test r isa String && occursin("made", r) && occursin("started", r)
                @test !occursin("behind", r) && top() isa W.PaneView
                @test strip(W.git(dest9, "rev-parse", "rw")) == f1
                drop!(top())

                # A branch on the remote only, whose tracking ref here is
                # stale: the private copy says the head is the project's, the
                # worktree is made off the tracking ref as it stands, and the
                # landing offers the fast-forward that closes the gap. The
                # tracking ref - the lease - never moves.
                W.git(other, "checkout", "--quiet", "-b", "stale", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "stale one")
                W.git(main, "fetch", "--quiet", "origin")
                s1 = strip(W.git(main, "rev-parse", "refs/remotes/origin/stale"))
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "stale two")
                s2 = strip(W.git(other, "rev-parse", "stale"))
                stpr = W.Item(url = "https://example.invalid/o/wt/pull/46", ref = "wt#46",
                              repo = pr.repo, number = 46, title = "stale", branch = "stale",
                              head = s2)
                @test W.pr_branch_here(main, stpr, "stale") === :remote
                @test strip(W.git(main, "rev-parse", "refs/remotes/origin/stale")) == s1
                @test strip(W.git(main, "rev-parse", "refs/worklog/origin/stale")) == s2
                dest12 = joinpath(root, "main-stale")
                @test W.make_checkout!(stpr, ctrl, :shell, sleep120, say, dest12; items = known) == ""
                cv = top(); @test cv isa W.ConfirmView
                @test cv.title == "Fast-forward stale in main-stale?"
                @test cv.notes[1] == "stale is 1 commit behind wt#46's head, pushed from somewhere else"
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView && occursin("fast-forwarded stale", string(said[]))
                @test strip(W.git(dest12, "rev-parse", "stale")) == s2
                @test strip(W.git(dest12, "rev-parse", "--abbrev-ref", "@{u}")) == "origin/stale"
                @test strip(W.git(main, "rev-parse", "refs/remotes/origin/stale")) == s1
                @test isempty(asked())
                drop!(top())

                # A branch's own upstream is its word for whose copy it is: one
                # tracking the project's copy of the name is yours whatever
                # head the lanes last saw, with nothing fetched; one with no
                # upstream and a head nothing here has is taken.
                W.git(other, "checkout", "--quiet", "-b", "own", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "owned")
                W.git(main, "fetch", "--quiet", "origin")
                W.git(main, "branch", "--quiet", "own", "origin/own")
                @test W.upstream_of(main, "own") == "origin/own"
                ownpr = W.Item(url = "https://example.invalid/o/wt/pull/47", ref = "wt#47",
                               repo = pr.repo, number = 47, title = "own", branch = "own",
                               head = theirs.head)
                @test W.pr_branch_here(main, ownpr, "own") === :local
                W.git(main, "branch", "--quiet", "--no-track", "own2", "origin/own")
                @test W.upstream_of(main, "own2") == ""
                @test W.pr_branch_here(main, W.with(ownpr; branch = "own2"), "own2") === :taken

                # A copy detached for a rebase reports the branch it will
                # return to, and is found by it - but the fast-forward is not
                # offered there, since it would move the detached head under
                # the rebase and leave the branch where it was. Once the
                # rebase is over and the branch is checked out, it is.
                W.git(main, "branch", "--quiet", "rb", f1)
                W.git(main, "branch", "--quiet", "-u", "origin/ff", "rb")
                dest13 = joinpath(root, "main-rb")
                W.add_worktree!(main, "rb", dest13)
                W.git(dest13, "checkout", "--quiet", "--detach")
                gd = strip(W.git(dest13, "rev-parse", "--absolute-git-dir"))
                mkpath(joinpath(gd, "rebase-merge"))
                write(joinpath(gd, "rebase-merge", "head-name"), "refs/heads/rb\n")
                rbpr = W.Item(url = "https://example.invalid/o/wt/pull/48", ref = "wt#48",
                              repo = pr.repo, number = 48, title = "rebasing", branch = "rb",
                              head = f2)
                r = W.item_worktree(rbpr; items = known)
                @test W.wtkey(r.path) == W.wtkey(dest13) && r.branch == "rb" && !r.ask
                @test W.place_branch(dest13) == "rb" && W.head_branch(dest13) == ""
                said[] = nothing
                r = W.enter_session(rbpr, ctrl, :shell, sleep120, say; items = known)
                @test r isa String && occursin("started", r) && top() isa W.PaneView
                @test strip(W.git(main, "rev-parse", "rb")) == f1
                drop!(top())
                rm(joinpath(gd, "rebase-merge"); recursive = true)
                W.git(dest13, "checkout", "--quiet", "rb")
                for r in W.mux_list()
                    W.wtkey(r.worktree) == W.wtkey(dest13) && W.mux_kill(r.name)
                end
                @test W.enter_session(rbpr, ctrl, :shell, sleep120, say; items = known) == ""
                cv = top(); @test cv isa W.ConfirmView && cv.title == "Fast-forward rb in main-rb?"
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)

                # `y` on the checkout question, for a name this repository
                # has that is not the pull request's: gh is handed a name of
                # its own, the branch in the way is left alone, and the tag
                # and the report say the branch the copy is on afterwards.
                W.git(main, "branch", "--quiet", "dup", "master")
                mtip = strip(W.git(main, "rev-parse", "master"))
                duppr = W.Item(url = "https://example.invalid/o/wt/pull/45", ref = "wt#45",
                               repo = pr.repo, number = 45, title = "dup", branch = "dup",
                               head = theirs.head)
                @test W.enter_session(duppr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView && cv.title == "Check out dup in main?"
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView
                @test asked() == ["pr", "checkout", duppr.url, "--branch", "pr45/dup"]
                @test occursin("checked out pr45/dup", string(said[]))
                @test first(W.worktrees(main)).branch == "pr45/dup"
                @test strip(W.git(main, "rev-parse", "dup")) == mtip
                @test any(r -> r.item == duppr.ref && r.branch == "pr45/dup" &&
                               W.wtkey(r.worktree) == W.wtkey(main), W.mux_list())
                drop!(top()); rm(log)
                W.git(main, "checkout", "--quiet", pr.branch)
                W.git(main, "branch", "--quiet", "-D", "pr45/dup")

                # The lease line on the checkout question: about the setting,
                # not about any one fetch, since the user's own `gh pr
                # checkout` moves the tracking ref as much as `y`'s does.
                W.git(other, "checkout", "--quiet", "-b", "lease", "origin/master")
                W.git(other, "commit", "--quiet", "--allow-empty", "-m", "leased")
                W.git(main, "fetch", "--quiet", "origin")
                ltip = strip(W.git(main, "rev-parse", "refs/remotes/origin/lease"))
                leasepr = W.Item(url = "https://example.invalid/o/wt/pull/43", ref = "wt#43",
                                 repo = pr.repo, number = 43, title = "leased", branch = "lease",
                                 head = ltip)
                W.git(main, "config", "push.useForceIfIncludes", "false")
                @test occursin("any fetch moves origin/lease", W.lease_note(main, pr.repo, "lease"))
                @test W.enter_session(leasepr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.title == "Check out lease in main?"
                @test occursin("gh pr checkout 43", cv.notes[end - 1])
                @test cv.notes[end] == "push.useForceIfIncludes is not set \u00b7 any fetch moves origin/lease, which is all --force-with-lease checks"
                for (w, h) in ((80, 24), (165, 50))
                    ls = split(W.render(cv, w, h), "\n")
                    @test length(ls) == h && all(W.awidth(l) == w for l in ls)
                end
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)
                # With the setting on, nothing is said, and the question ends
                # on what `y` runs.
                W.git(main, "config", "push.useForceIfIncludes", "true")
                @test W.lease_note(main, pr.repo, "lease") == ""
                @test W.enter_session(leasepr, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test occursin("gh pr checkout 43", cv.notes[end])
                @test W.handle!(cv, 27, ctrl) === :pop; drop!(cv)

                # An adopted branch is nobody's to fetch: the question names
                # `git checkout`, and `y` runs it, with gh never asked.
                W.git(main, "branch", "--quiet", "mine", "master")
                mine = W.local_item(W.localurl(pr.repo, "mine"))
                @test !mine.is_pr && mine.branch == "mine"
                @test W.enter_session(mine, ctrl, :shell, sleep120, say; items = known) == ""
                ch = top(); @test ch isa W.ChooseView
                ch.sel = 1; W.handle!(ch, 13, ctrl); drop!(ch)
                cv = top(); @test cv isa W.ConfirmView
                @test cv.title == "Check out mine in main?"
                @test cv.notes[end] == "y runs git checkout mine there"
                said[] = nothing
                @test W.handle!(cv, Int('y'), ctrl) === :pop; drop!(cv)
                @test top() isa W.PaneView
                @test occursin("checked out mine", string(said[]))
                @test first(W.worktrees(main)).branch == "mine"
                @test isempty(asked())
                drop!(top())
            finally
                ENV["PATH"] = keptpath
                # In the `finally`, so a run that errors out leaves nothing
                # behind for the next one to trip over.
                for r in W.mux_list()
                    startswith(r.worktree, realpath(root)) && W.mux_kill(r.name)
                end
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
