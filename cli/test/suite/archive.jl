# Work leaving without being deleted, and local work arriving: archive,
# adoption, and the branch list that is the second lens on a worktree.

@testset "archive lets work leave without deleting it" begin
    keept = W.TOUCHED[]; W.TOUCHED[] = joinpath(mktempdir(), "touched.json")
    before = read(W.statefile(), String)
    try
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true
        n(s) = (st.filters.state = s; W.refilter!(st); length(st.items))
        a0, all0 = n(:active), n(:all)
        @test n(:archived) == 0
        st.filters.state = :active; W.refilter!(st)
        it = st.items[st.sel]

        W.handle!(st, Int('x'), ctrl)
        @test st.status == string("archived ", it.ref)     # and not clobbered
        @test W.get_field(it.url, "archive") == string(Date(W.utcnow()))
        # Out of the two lanes that answer "what should I be doing", and in the
        # one that is a record. `all` is everything, so it is unchanged.
        @test n(:active) == a0 - 1
        @test n(:archived) == 1
        @test n(:all) == all0
        st.filters.state = :archived; W.refilter!(st)
        @test st.items[1].url == it.url
        # Where the item's facts are, with the way back out.
        lines = W.astrip(join(W.meta_lines(st, it, 50), "\n"))
        @test occursin("archived", lines) && occursin("takes it back out", lines)

        # A toggle, and undoable either way.
        W.handle!(st, Int('x'), ctrl)
        @test occursin("back out", st.status)
        @test W.get_field(it.url, "archive") === nothing
        W.handle!(st, Int('z'), ctrl)
        @test W.get_field(it.url, "archive") !== nothing
        W.handle!(st, Int('x'), ctrl)

        # Nothing written about it is lost - archiving is not deleting.
        W.set_fields(it.url, ["note" => "why this ended"])
        W.handle!(st, Int('x'), ctrl)
        @test W.get_field(it.url, "note") == "why this ended"
    finally
        write(W.statefile(), before)
        W.TOUCHED[] = keept
    end

    # A merge is news until it has been read, and only then is it filing.
    root = mktempdir(); main = joinpath(root, "m"); mkpath(main)
    g(a...) = W.git(main, a...)
    g("init", "--quiet", "--initial-branch=master", ".")
    g("config", "user.email", "me@e.com"); g("config", "user.name", "Me")
    write(joinpath(main, "a"), "x"); g("add", "a"); g("commit", "--quiet", "-m", "base")
    bare = joinpath(root, "o.git"); g("init", "--quiet", "--bare", bare)
    g("remote", "add", "origin", bare); g("push", "--quiet", "-u", "origin", "master")
    g("checkout", "--quiet", "-b", "landed"); write(joinpath(main, "a"), "l")
    g("commit", "--quiet", "-am", "landed work")
    g("checkout", "--quiet", "master"); g("merge", "--quiet", "--no-ff", "-m", "m", "landed")
    g("push", "--quiet", "origin", "master")
    g("checkout", "--quiet", "-b", "inflight"); write(joinpath(main, "a"), "i")
    g("commit", "--quiet", "-am", "wip"); g("checkout", "--quiet", "master")

    # However the work got there - merge, squash or rebase - every commit being
    # in the base is what says it landed.
    @test W.merged_here(main, "landed")
    @test !W.merged_here(main, "inflight")
    @test !W.merged_here(main, "")
    @test !W.merged_here(main, "landed"; base = "no-such-base")

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    keept = W.TOUCHED[]; W.TOUCHED[] = joinpath(root, "touched.json")
    before = read(W.statefile(), String)
    try
        W.register_repo!("o/m", main)
        for b in ("landed", "inflight")
            W.set_fields(W.localurl("o/m", b), ["adopted" => "2026-09-02"])
        end
        its = Dict(x.ref => x for x in W.local_items())
        @test its["m#landed"].state == "MERGED"
        @test occursin("merged into the base", its["m#landed"].why)
        @test isempty(its["m#inflight"].state)
        @test W.isdone(its["m#landed"]) && !W.isdone(its["m#inflight"])
        # An unknown state is not a closed one: a facts.json written before the
        # field existed must not offer to archive the whole dashboard.
        @test !W.isdone(W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1, title = "t"))

        st = W.BState(vcat(W.loaditems(), collect(values(its))), "worklog", Set{String}())
        l = its["m#landed"]
        says() = W.astrip(join([x for x in W.meta_lines(st, l, 50) if occursin("state", x)], " "))
        # Merged and not yet looked at is news - a merge you did not do is
        # exactly the thing to be told about, so it stays in the unread lane.
        push!(st.unread, l.url)
        @test occursin("new since you last looked", says())
        @test !occursin("x archives", says())
        # Read, and it becomes something to file. Offered, never done silently.
        delete!(st.unread, l.url)
        @test occursin("x archives it", says())
        @test W.get_field(l.url, "archive") === nothing

        # A merge you pushed yourself is not news at all, so the wait is
        # skipped: unread or not, the offer stands on the first frame.
        mine = W.Item(url = "u1", ref = "m#1", repo = "o/m", number = 1, title = "t",
                      state = "MERGED", merged_by = W.login())
        theirs = W.Item(url = "u2", ref = "m#2", repo = "o/m", number = 2, title = "t",
                        state = "MERGED", merged_by = "someone-else")
        old = W.Item(url = "u3", ref = "m#3", repo = "o/m", number = 3, title = "t",
                     state = "MERGED")
        @test W.mergedbyme(mine)
        # Not known to have been merged by you reads as not yours, which is the
        # way round that leaves an upgrade offering nothing new.
        @test !W.mergedbyme(theirs) && !W.mergedbyme(old)
        @test !W.mergedbyme(W.Item(url = "u4", ref = "m#4", repo = "o/m", number = 4,
                                   title = "t", merged_by = W.login()))
        st2 = W.BState(vcat(W.loaditems(), [mine, theirs, old]), "worklog",
                       Set(["u1", "u2", "u3"]))
        line(x) = W.astrip(join([r for r in W.meta_lines(st2, x, 50) if occursin("state", r)], " "))
        @test occursin("you merged it", line(mine)) && occursin("x archives it", line(mine))
        @test occursin("new since you last looked", line(theirs))
        @test occursin("new since you last looked", line(old))
    finally
        write(W.statefile(), before)
        W.REPOS_FILE[] = REPOS_SANDBOX
        W.TOUCHED[] = keept
    end
end

@testset "adoption is explicit, and guarded" begin
    # `gh pr checkout` leaves other people's branches in your checkout, so
    # opening a terminal in one must not quietly claim their work. The guard is
    # one question: is there a commit of yours on it?
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    g(a...) = W.git(main, a...)
    g("init", "--quiet", "--initial-branch=master", ".")
    g("config", "user.email", "me@example.com"); g("config", "user.name", "Me")
    write(joinpath(main, "a"), "x"); g("add", "a"); g("commit", "--quiet", "-m", "base")
    bare = joinpath(root, "o.git"); g("init", "--quiet", "--bare", bare)
    g("remote", "add", "origin", bare); g("push", "--quiet", "-u", "origin", "master")

    g("checkout", "--quiet", "-b", "mine"); write(joinpath(main, "a"), "m")
    g("commit", "--quiet", "-am", "my work")
    g("checkout", "--quiet", "master"); g("checkout", "--quiet", "-b", "theirs")
    write(joinpath(main, "a"), "t")
    g("-c", "user.email=s@e.example", "-c", "user.name=S", "commit", "--quiet",
      "-am", "their work")
    g("checkout", "--quiet", "master"); g("checkout", "--quiet", "-b", "joint")
    write(joinpath(main, "a"), "j")
    g("-c", "user.email=s@e.example", "-c", "user.name=S", "commit", "--quiet",
      "-am", "joint\n\nCo-authored-by: Me <me@example.com>")
    g("checkout", "--quiet", "master")

    ids = W.git_ids(main, "mylogin")
    @test "me@example.com" in ids && "me" in ids && "mylogin" in ids
    @test W.default_base(main) == "origin/master"
    @test W.mine_on_branch(main, "mine", ids)
    @test !W.mine_on_branch(main, "theirs", ids)
    # Co-authored counts: a commit you wrote with someone else is work you did,
    # and the trailer is the only record of it.
    @test W.mine_on_branch(main, "joint", ids)
    # Nothing on the branch, nothing to own.
    @test !W.mine_on_branch(main, "master", ids)
    # Every uncertainty refuses, because this only ever grants adoption.
    @test !W.mine_on_branch(main, "mine", String[])
    @test !W.mine_on_branch(main, "", ids)
    @test !W.mine_on_branch(main, "mine", ids; base = "no-such-base")
    # The tip's subject rides along, since it is the only title a branch has.
    bs = Dict(b.name => b for b in W.branches("a/b", main))
    @test bs["mine"].subject == "my work"

    # The key is repo and branch, not the worktree: a branch with no worktree
    # is exactly the case adoption is for.
    @test W.localurl("a/b", "x/y") == "local:a/b#x/y"
    @test W.localparts("local:a/b#x/y") == ("a/b", "x/y")
    @test W.localref("a/b", "x/y") == "b#x/y"
    @test W.islocal("local:a/b#c") && !W.islocal("https://github.com/a/b/pull/1")

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    keept = W.TOUCHED[]; W.TOUCHED[] = joinpath(root, "touched.json")
    state = read(W.statefile(), String)
    try
        W.register_repo!("o/main", main)
        items = W.loaditems()
        st = W.BState(items, "worklog", Set{String}())
        ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)
        n0 = length(st.all)
        W.handle!(st, Int('"'), ctrl)
        v = last(ctrl.stack)
        W.handle!(v, 9, ctrl)
        @test v.mode === :branches
        pick(n) = (v.bsel = findfirst(b -> b.name == n, v.brows))

        # `a` is asking for it, which is the deliberate act the guard requires -
        # so it works on someone else's branch too.
        pick("theirs"); W.handle!(v, Int('a'), ctrl)
        @test occursin("adopted", v.status)
        W.handle!(v, Int('a'), ctrl)                    # and toggles back
        @test occursin("released", v.status)

        pick("mine"); W.handle!(v, Int('a'), ctrl)
        @test v.status == "adopted main#mine"
        u = W.localurl("o/main", "mine")
        @test W.get_field(u, "adopted") !== nothing
        @test length(st.all) == n0 + 1
        it = first(x for x in st.all if W.islocal(x))
        # The tip's subject is its title, and it joins the branch list.
        @test it.ref == "main#mine" && it.title == "my work"
        @test it.bucket == "local" && !it.is_pr && it.branch == "mine"
        @test W.branch_index(st.all)[("o/main", "mine")].url == u
        # The row it came from now carries it, so `a` reads as a toggle.
        @test v.brows[findfirst(b -> b.name == "mine", v.brows)].item !== nothing

        # Undone, it stops being an item and stops being adopted.
        W.handle!(st, Int('z'), ctrl)
        @test occursin("undid", st.status)
        @test W.get_field(u, "adopted") === nothing
        @test count(W.islocal, st.all) == 0

        # Whatever was written about it outlives the release: deciding the work
        # is not yours does not undo a note.
        W.handle!(v, Int('a'), ctrl)                    # re-adopt
        W.set_fields(u, ["note" => "keep me"])
        W.handle!(v, Int('a'), ctrl)                    # release
        @test occursin("released", v.status)
        @test W.get_field(u, "adopted") === nothing
        @test W.get_field(u, "note") == "keep me"

        # A branch that already has a pull request is refused: a second item
        # keyed on it would be the same work listed twice.
        pr = first(x for x in items if x.is_pr && !isempty(x.branch))
        fake = W.BranchRow(pr.repo, pr.branch, "", 0, 0, false, "", "", pr)
        @test occursin("pull request already", W.adopt_row(v, fake))
        # And a detached head has no branch to adopt.
        det = W.BranchRow("o/main", "", "", 0, 0, false, "", "", nothing)
        @test occursin("no branch", W.adopt_row(v, det))

        # Working in something is a deliberate enough act to claim it - but
        # only your own work, which is what the guard is between.
        if W.mux_bin() === nothing
            @info "no tmux; skipping the automatic adoption test"
        else
            for br in ("mine", "theirs")
                W.set_fields(W.localurl("o/main", br), ["adopted" => nothing])
            end
            for br in ("mine", "theirs")
                g("worktree", "add", "--quiet", joinpath(root, "wt-" * br), br)
            end
            W.worktree_reload!(v)
            v.mode = :worktrees
            for br in ("mine", "theirs")
                v.sel = findfirst(r -> r.name == "wt-" * br, v.rows)
                W.handle!(v, Int('t'), ctrl)
                if last(ctrl.stack) isa W.PaneView
                    W.mux_kill(last(ctrl.stack).child.name); pop!(ctrl.stack)
                end
            end
            @test W.get_field(W.localurl("o/main", "mine"), "adopted") !== nothing
            @test W.get_field(W.localurl("o/main", "theirs"), "adopted") === nothing
            # And it is said, rather than done behind the status line.
            v.sel = findfirst(r -> r.name == "wt-mine", v.rows)
            W.worktree_reload!(v)
            @test v.rows[v.sel].item !== nothing
            for br in ("mine", "theirs")
                g("worktree", "remove", "--force", joinpath(root, "wt-" * br))
                W.set_fields(W.localurl("o/main", br), ["adopted" => nothing])
            end
            v.mode = :branches
            W.worktree_reload!(v)
            pick("mine"); W.handle!(v, Int('a'), ctrl)   # adopted, for what follows
            @test occursin("adopted", v.status)
        end

        # Adopted branches come back as items on the next start, and one whose
        # branch has gone is shown rather than dropped - it is still something
        # a note was written on. Stated rather than toggled into place, so this
        # does not depend on how many times `a` has been pressed above.
        pick("mine")
        W.get_field(u, "adopted") === nothing && W.handle!(v, Int('a'), ctrl)
        @test W.get_field(u, "adopted") !== nothing
        # Only this branch's row: `state.toml` is seeded from the real one, so
        # whatever the user has adopted is in this list too and is none of this
        # test's business.
        ours() = [x for x in W.local_items() if x.url == u]
        @test length(ours()) == 1
        g("branch", "-D", "mine")
        gone = ours()
        @test length(gone) == 1 && occursin("gone", gone[1].why)
        @test gone[1].title == "mine"          # the name, with no tip to read
    finally
        write(W.statefile(), state)
        W.REPOS_FILE[] = REPOS_SANDBOX
        W.TOUCHED[] = keept
    end
end

@testset "branches, the second lens" begin
    # Worktrees are places that exist; branches are work that exists without
    # one. Same key, same rows underneath, one `tab` apart.
    items = W.loaditems()
    ctrl = W.Controller(); ctrl.running = true
    shown = W.BState(items, "worklog", Set{String}())
    pr = first(it for it in shown.items if it.is_pr && !isempty(it.branch))

    root = mktempdir()
    main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@example.com")
    W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    W.git(main, "add", "a.txt"); W.git(main, "commit", "--quiet", "-m", "first")
    side = joinpath(root, "side")
    W.git(main, "worktree", "add", "--quiet", "-b", pr.branch, side)
    W.git(main, "branch", "homeless")

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        W.register_repo!(pr.repo, main)
        v = W.worktree_view(items)
        @test v.mode === :worktrees
        @test length(v.brows) == 3
        # The place column is the difference between the two lists: two of
        # these are checked out and one is only a ref.
        byname = Dict(b.name => b for b in v.brows)
        @test byname[pr.branch].worktree == realpath(side)
        @test isempty(byname["homeless"].worktree)
        @test byname[pr.branch].item !== nothing && byname[pr.branch].item.url == pr.url
        @test byname["homeless"].item === nothing

        @test W.handle!(v, 9, ctrl) === :ok && v.mode === :branches
        for (w, h) in ((80, 24), (120, 40), (165, 50))
            ls = split(W.render(v, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end
        @test occursin("branches", W.astrip(W.render(v, 120, 24)))
        # The branch list has marks of its own, so it has a legend of its own.
        blegend = W.astrip(W.render(v, 120, 24))
        @test occursin("checked out somewhere", blegend)
        @test !occursin("s shell", blegend)
        @test occursin(pr.ref, W.astrip(W.render(v, 165, 24)))

        # Each lens keeps its own cursor, so `tab` returns to where you were.
        v.sel = 2
        W.handle!(v, Int('G'), ctrl)
        @test v.bsel == length(v.brows) && v.sel == 2
        W.handle!(v, 9, ctrl)
        @test v.mode === :worktrees && v.sel == 2
        W.handle!(v, 9, ctrl)
        @test v.bsel == length(v.brows)

        # A branch is not a place: enter goes to the worktree that has it out.
        v.bsel = findfirst(b -> b.name == pr.branch, v.brows)
        W.handle!(v, 13, ctrl)
        @test v.mode === :worktrees && v.rows[v.sel].name == "side"
        # And offers to make one where there is none, which is the only thing
        # this list could see and not act on. The suggestion is beside the main
        # checkout, already typed and with the cursor after it.
        W.handle!(v, 9, ctrl)
        v.bsel = findfirst(b -> b.name == "homeless", v.brows)
        @test W.handle!(v, 13, ctrl) === :ok
        @test v.mode === :branches
        pv = last(ctrl.stack)
        @test pv isa W.PromptView
        @test W.text(pv) == joinpath(root, "main-homeless")
        @test pv.buf.col == length(W.text(pv)) + 1     # and the cursor after it
        # Nothing runs on a branch either.
        W.handle!(v, Int('K'), ctrl)
        @test occursin("nothing runs on a branch", v.status)

        # A path git refuses asks again rather than losing what was typed, with
        # git's own complaint where the note was.
        pv.onsubmit(main)
        pv2 = last(ctrl.stack)
        @test pv2 isa W.PromptView && pv2 !== pv
        @test W.text(pv2) == main && occursin("exists", lowercase(pv2.note))
        @test v.mode === :branches
        empty!(ctrl.stack)
        # And one it accepts lands on the row it just made.
        made = joinpath(root, "made")
        pv.onsubmit(made)
        @test isempty(ctrl.stack)
        @test v.mode === :worktrees
        @test v.rows[v.sel].name == "made" && v.rows[v.sel].branch == "homeless"
        @test occursin("made", v.status)
        @test ispath(joinpath(made, ".git"))
        @test !isempty(first(b for b in v.brows if b.name == "homeless").worktree)
        # Nowhere left to suggest: a second one is refused by git, not by us.
        W.handle!(v, 9, ctrl)
        v.bsel = findfirst(b -> b.name == "homeless", v.brows)
        W.handle!(v, 13, ctrl)
        @test v.mode === :worktrees && v.rows[v.sel].name == "made"

        # `i` works from either lens.
        st = W.BState(items, "worklog", Set{String}())
        v2 = W.worktree_view(items; onitem = x -> W.select_item!(st, x))
        W.handle!(v2, 9, ctrl)
        v2.bsel = findfirst(b -> b.name == pr.branch, v2.brows)
        @test W.handle!(v2, Int('i'), ctrl) === :pop
        @test st.items[st.sel].url == pr.url
        v2.bsel = findfirst(b -> b.name == "homeless", v2.brows)
        @test W.handle!(v2, Int('i'), ctrl) === :ok
        @test occursin("no pull request", v2.status)

        # Newest tip first, across every repo at once.
        ats = [b.at for b in v.brows]
        @test issorted(ats; rev = true)

        # An empty list still renders and says which one is empty.
        e = W.WorktreeView(items, W.WorktreeRow[], W.BranchRow[], :branches,
                           1, 1, 1, 1, "", nothing, nothing, nothing, nothing, nothing)
        ls = split(W.render(e, 80, 24), "\n")
        @test length(ls) == 24 && all(W.awidth(l) == 80 for l in ls)
        @test occursin("no branches", join(ls, "\n"))
    finally
        W.REPOS_FILE[] = REPOS_SANDBOX
    end

    # With nothing registered the view still renders, and says so.
    W.REPOS_FILE[] = joinpath(mktempdir(), "none.toml")
    try
        v = W.worktree_view(items)
        @test isempty(v.rows)
        ls = split(W.render(v, 80, 24), "\n")
        @test length(ls) == 24 && all(W.awidth(l) == 80 for l in ls)
        @test occursin("no worktrees", join(ls, "\n"))
    finally
        W.REPOS_FILE[] = REPOS_SANDBOX
    end
end
