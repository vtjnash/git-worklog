# The local git survey, and the join from a branch to its pull request.

@testset "the local git survey" begin
    # A real repository, because every one of these fields is git's own answer
    # to a question with a format string in it, and a mock would only assert
    # that the format string is what this file already says it is.
    g(dir, args...) = W.git(dir, args...)
    root = mktempdir()
    main = joinpath(root, "main")
    mkpath(main)
    g(main, "init", "--quiet", "--initial-branch=master", ".")
    g(main, "config", "user.email", "t@example.com")
    g(main, "config", "user.name", "t")
    write(joinpath(main, "a.txt"), "one\n")
    g(main, "add", "a.txt")
    g(main, "commit", "--quiet", "-m", "first")

    # An "upstream" without a server: a bare repo, pushed to, then moved on from
    # locally - which is what ahead/behind is measured against.
    bare = joinpath(root, "origin.git")
    g(main, "init", "--quiet", "--bare", bare)
    g(main, "remote", "add", "origin", bare)
    g(main, "push", "--quiet", "-u", "origin", "master")
    write(joinpath(main, "a.txt"), "two\n")
    g(main, "commit", "--quiet", "-am", "second")

    # One branch with a place, one without, and one whose upstream is gone -
    # which is what a merged pull request's branch looks like from here.
    g(main, "branch", "homeless")
    g(main, "branch", "placed")
    g(main, "push", "--quiet", "-u", "origin", "placed")
    wt = joinpath(root, "wt-placed")
    g(main, "worktree", "add", "--quiet", wt, "placed")
    det = joinpath(root, "wt-detached")
    g(main, "worktree", "add", "--quiet", "--detach", det, "HEAD")
    g(main, "push", "--quiet", "origin", "--delete", "placed")
    g(main, "fetch", "--quiet", "--prune", "origin")

    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        W.register_repo!("t/one", main)

        bs = Dict(b.name => b for b in W.branches("t/one", main))
        @test sort(collect(keys(bs))) == ["homeless", "master", "placed"]
        # master is one commit past what was pushed, and knows by how much.
        @test bs["master"].upstream == "origin/master"
        @test (bs["master"].ahead, bs["master"].behind) == (1, 0)
        @test !bs["master"].gone
        # A branch nothing is tracking reports no divergence rather than zero
        # divergence; the empty upstream is how to tell those apart.
        @test bs["homeless"].upstream == "" && !bs["homeless"].gone
        @test (bs["homeless"].ahead, bs["homeless"].behind) == (0, 0)
        # And one whose upstream was deleted underneath it says so.
        @test bs["placed"].gone
        # Only one of the three is checked out anywhere.
        @test bs["placed"].worktree == realpath(wt)
        @test bs["homeless"].worktree == ""
        @test startswith(bs["master"].at, "20") && length(bs["master"].head) == 40

        ws = W.worktrees(main)
        @test length(ws) == 3
        @test ws[1].main && !ws[2].main            # git lists the primary first
        byp = Dict(w.path => w for w in ws)
        @test byp[realpath(main)].branch == "master"
        @test byp[realpath(wt)].branch == "placed"
        # A detached head is a worktree with no branch, which the survey shows
        # rather than skips.
        @test byp[realpath(det)].branch == ""
        @test length(byp[realpath(det)].head) == 40

        # A new worktree is suggested beside the *main* checkout, whichever
        # copy the request came from - siblings, not a chain of them.
        @test W.main_worktree(wt) == realpath(main)
        @test W.worktree_dest(main, "homeless") == joinpath(root, "main-homeless")
        @test W.worktree_dest(wt, "jn/fix") == joinpath(root, "main-jn-fix")
        @test_throws W.GitError W.add_worktree!(main, "homeless", main)
        made = W.add_worktree!(main, "homeless", joinpath(root, "main-homeless"))
        @test made == realpath(joinpath(root, "main-homeless"))
        @test Dict(b.name => b for b in W.branches("t/one", main))["homeless"].worktree == made
        # git refuses the second one, which is what lets the branch list treat
        # a branch as having a place or having none.
        @test_throws W.GitError W.add_worktree!(main, "homeless", joinpath(root, "again"))
        W.git(main, "worktree", "remove", "--force", made)

        (sw, sb) = W.survey()
        @test length(sw) == 3 && length(sb) == 3
        @test all(w.repo == "t/one" for w in sw)
        sbyp = Dict(w.path => w for w in sw)
        # Ahead/behind is joined from the branch, so a worktree carries its
        # branch's divergence and a detached one carries none.
        @test (sbyp[realpath(main)].ahead, sbyp[realpath(main)].behind) == (1, 0)
        @test sbyp[realpath(det)].upstream == "" && sbyp[realpath(det)].at == ""
        @test all(!(w.staged || w.unstaged) for w in sw)
        write(joinpath(main, "a.txt"), "three\n")
        @test W.changes(main) == (false, true)      # edited, not staged
        @test W.dirty(main)
        # Staged and unstaged are separate bits, because a half-staged checkout
        # is in the middle of a commit - a different thing to have walked away
        # from than one that was merely edited.
        g(main, "add", "a.txt")
        @test W.changes(main) == (true, false)
        write(joinpath(main, "a.txt"), "four\n")
        @test W.changes(main) == (true, true)       # staged, then edited again
        # An untracked file is not work in progress: a build tree is full of
        # them, and counting them would report every checkout dirty forever.
        g(main, "reset", "--quiet", "--hard")
        write(joinpath(main, "untracked.txt"), "x\n")
        @test W.changes(main) == (false, false)
        @test !W.dirty(main)
        # The cheap survey skips the tree walk entirely.
        write(joinpath(main, "a.txt"), "three\n")
        @test any(w.unstaged for w in first(W.survey()))
        @test all(!(w.staged || w.unstaged) for w in first(W.survey(; withdirty = false)))
        g(main, "checkout", "--quiet", "--", "a.txt")

        # A registered repo whose folder has gone is skipped, not an error -
        # the same rule `repo_path` follows, since `repos.toml` is never pruned.
        d = W.load_repos()
        d["t/gone"] = Dict("worktree" => joinpath(root, "not-there"),
                           "gitdir" => "", "remotes" => "")
        W.save_repos(d)
        @test all(w.repo == "t/one" for w in first(W.survey(; withdirty = false)))
    finally
        W.REPOS_FILE[] = REPOS_SANDBOX
    end

    # The parse of `%(upstream:track)`, which is why git is run under LC_ALL=C.
    @test W.track_counts("[ahead 3, behind 1]") == (3, 1, false)
    @test W.track_counts("[behind 2]") == (0, 2, false)
    @test W.track_counts("[gone]") == (0, 0, true)
    @test W.track_counts("") == (0, 0, false)
end

@testset "a branch knows its pull request" begin
    # The join the survey is for: the lanes carry `headRefName`, so the whole
    # mapping is known without a request per row.
    mk(n, repo, br) = W.Item(url = "u$n", ref = "$repo#$n", repo = repo, number = n,
                             title = "t", branch = br)
    items = [mk(1, "a/b", "topic"), mk(2, "c/d", "topic"), mk(3, "a/b", "")]
    ix = W.branch_index(items)
    # Keyed by repo as well as name: every one of these repos has a `master`.
    @test ix[("a/b", "topic")].number == 1
    @test ix[("c/d", "topic")].number == 2
    @test length(ix) == 2                      # the one with no branch is out
    # A reused name resolves to the newer pull request, not to whichever was
    # seen first.
    ix2 = W.branch_index([mk(9, "a/b", "topic"), mk(4, "a/b", "topic")])
    @test ix2[("a/b", "topic")].number == 9
    @test W.branch_index([W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1,
                                 title = "t", branch = "x", is_pr = false)] ) |> isempty

    # An item that came from a facts.json written before the field existed has
    # no branch, and `pr_branch` is what falls back for it.
    @test W.pr_branch(mk(1, "a/b", "topic")) == "topic"
    @test W.pr_branch(W.Item(url = "u", ref = "r#1", repo = "a/b", number = 1,
                             title = "t", is_pr = false)) == ""
end

@testset "the data directory commits itself, once a day" begin
    # It is a git repository of its own so that the record of what you have done
    # has a history, and nothing was ever committing to it.
    was = W.DATA_DIR[]
    d = mktempdir()
    try
        W.DATA_DIR[] = d
        # Not a repository: nothing to do, and nothing said about it.
        write(joinpath(d, "marks.json"), "{}")
        @test W.commit_data!() == ""
        W.git(d, "init", "-q")
        W.git(d, "config", "user.email", "test@example.com")
        W.git(d, "config", "user.name", "test")
        said = W.commit_data!()
        @test occursin("committed 1 file", said)
        @test occursin("marks.json", W.git(d, "log", "-1", "--format=%s"))
        # Once a day: the same day again is a no-op, however dirty it gets.
        write(joinpath(d, "inbox.json"), "{}")
        @test W.commit_data!() == ""
        @test length(split(strip(W.git(d, "log", "--format=%h")), '\n')) == 1
        # A clean tree is nothing to commit even when the day has turned.
        W.git(d, "add", "-A"); W.git(d, "commit", "-q", "-m", "by hand")
        # Committer date, not author date: what is being asked is when this
        # repository last had something recorded in it, which is `%cd`.
        withenv("GIT_COMMITTER_DATE" => "2020-01-01T09:00:00") do
            W.git(d, "commit", "-q", "--amend", "--no-edit")
        end
        @test W.commit_data!() == ""
        # Dirty and a day old: committed, and the message names what moved.
        write(joinpath(d, "state.toml"), "# hello\n")
        said = W.commit_data!()
        @test occursin("first run since 2020-01-01", said)
        @test occursin("state.toml", W.git(d, "log", "-1", "--format=%s"))
    finally
        W.DATA_DIR[] = was
    end
end
