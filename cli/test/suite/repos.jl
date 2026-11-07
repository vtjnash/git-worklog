# `repos.toml`, which invites hand-editing at the top of itself.

@testset "a path written by hand still means what it says" begin
    # `register_repo!` expands on the way in, so anything this program wrote is
    # absolute already - but repos.toml invites editing at the top of itself,
    # and read raw a hand-written `~/src/julia` is not a directory at all: the
    # repo reads as unregistered and the browser asks for the path again.
    @test W.userpath("~/x") == joinpath(homedir(), "x")
    @test W.userpath("/already/absolute") == "/already/absolute"
    @test W.userpath("relative/on/purpose") == "relative/on/purpose"   # not abspath
    @test W.userpath("") == ""

    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "config", "user.email", "t@e.com"); W.git(main, "config", "user.name", "t")
    write(joinpath(main, "a"), "x")
    W.git(main, "add", "a"); W.git(main, "commit", "--quiet", "-m", "first")

    keepr, keeph = W.LOCAL[], get(ENV, "HOME", "")
    W.LOCAL[] = joinpath(root, "local.toml")
    try
        # Written the way a person writes it, not the way the program does.
        write(W.LOCAL[], "[\"repo:o/r\"]\nworktree = \"~/main\"\n")
        ENV["HOME"] = root
        @test W.repo_path("o/r") == main
        # And the survey sees it too, which is what the worktree list is built
        # from - the two used to disagree with each other about the same file.
        ws, _ = W.survey(; withdirty = false)
        @test any(w -> w.repo == "o/r", ws)
    finally
        ENV["HOME"] = keeph
        W.LOCAL[] = keepr
    end

    # WORKLOG_DATA is not always set by a shell, and an unexpanded `~` there
    # would have mkpath create a directory *called* `~`.
    keepd, keepe = W.DATA_DIR[], get(ENV, "WORKLOG_DATA", nothing)
    try
        W.DATA_DIR[] = ""
        ENV["HOME"] = root
        ENV["WORKLOG_DATA"] = "~/somewhere"
        @test W.datadir() == joinpath(root, "somewhere")
        @test !ispath(joinpath(pwd(), "~"))
    finally
        ENV["HOME"] = keeph
        keepe === nothing ? delete!(ENV, "WORKLOG_DATA") : (ENV["WORKLOG_DATA"] = keepe)
        W.DATA_DIR[] = keepd
    end
end

@testset "a pinned checkout that is gone is forgotten only when asked" begin
    # An entry can be missing because the directory was deleted, or because an
    # external disk is unplugged and will be back this afternoon. `repo_path`
    # already ignores what is not there, so nothing is broken by a stale entry -
    # which is exactly why removing one waits to be asked for.
    root = mktempdir()
    here = joinpath(root, "here"); mkpath(here)
    keepr = W.LOCAL[]
    W.LOCAL[] = joinpath(root, "local.toml")
    try
        write(W.LOCAL[], """
              ["repo:o/here"]
              worktree = $(repr(here))

              ["repo:o/gone"]
              worktree = $(repr(joinpath(root, "not-there")))
              """)
        rs = W.pinned_repos()
        @test [r.name for r in rs] == ["o/gone", "o/here"]      # sorted
        @test [r.there for r in rs] == [false, true]
        # The path comes back as written, not as resolved: a `~` somebody typed
        # is their text and worth showing back to them unchanged.
        write(W.LOCAL[], """
              ["repo:o/tilde"]
              worktree = "~/nowhere-at-all"
              """)
        @test first(W.pinned_repos()).path == "~/nowhere-at-all"
        @test !first(W.pinned_repos()).there

        # Pruning takes the missing ones and leaves the rest.
        write(W.LOCAL[], """
              ["repo:o/here"]
              worktree = $(repr(here))

              ["repo:o/gone"]
              worktree = $(repr(joinpath(root, "not-there")))
              """)
        @test W.prune_repos!() == ["o/gone"]
        @test [r.name for r in W.pinned_repos()] == ["o/here"]
        @test W.repo_path("o/here") !== nothing
        # And nothing to do is not an error.
        @test isempty(W.prune_repos!())
    finally
        W.LOCAL[] = keepr
    end
end

@testset "an emoji in a note does not unpin every checkout" begin
    # JSON spells an emoji as a surrogate pair and TOML refuses surrogates, so
    # one in any field made the file unparseable - and `load_repos`, which is
    # the one reader that parses it, answered "nothing pinned" for every repo:
    # `t` asked for the checkout again on every item, forever.
    @test W.fmt("a 😀 é \"q\" \\ \n") == "\"a \\U0001f600 \\u00e9 \\\"q\\\" \\\\ \\n\""
    @test W.fmt(["😀"]) == "[\"\\U0001f600\"]"
    root = mktempdir()
    keepr = W.LOCAL[]
    W.LOCAL[] = joinpath(root, "local.toml")
    try
        write(W.LOCAL[], "[\"repo:o/r\"]\nworktree = \"$root\"\n")
        W.set_blocks!(["https://x/1" => ["note" => "done 🎉"]])
        @test W.repo_path("o/r") == root
        @test W.parse_local()["https://x/1"]["note"] == "done 🎉"
        # And a file written before the fix is read as it was meant: the pair
        # is one character, and an escaped backslash ahead of `u` is text.
        write(W.LOCAL[], "[\"repo:o/r\"]\nworktree = \"$root\"\n\n" *
                         "[\"https://x/1\"]\nnote = \"\\ud83c\\udf89 \\\\ud83c\\\\udf89\"\n")
        @test W.repo_path("o/r") == root
        @test W.parse_local()["https://x/1"]["note"] == "🎉 \\ud83c\\udf89"
        @test W.load_state()["https://x/1"]["note"] == "🎉 \\ud83c\\udf89"
    finally
        W.LOCAL[] = keepr
    end
end

@testset "a checkout that is some other repository is asked about twice" begin
    # One checkout was pinned for two unrelated repositories, with a warning
    # after the fact nobody saw, and every worktree of it was listed twice. A
    # path whose remotes do not name the repository is asked about again, and
    # kept only when entered again - forks and mirrors are still allowed.
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    W.git(main, "init", "--quiet", "--initial-branch=master", ".")
    W.git(main, "remote", "add", "origin", "https://github.com/some/other.git")
    # `o` opens VS Code once the pin is made; a `code` ahead of the real one
    # that does nothing keeps that from being a window.
    bin = mktempdir(); write(joinpath(bin, "code"), "#!/bin/sh\n"); chmod(joinpath(bin, "code"), 0o755)
    path = string(bin, ":", ENV["PATH"])
    # And `forwards!` records that `code` as the one to hand on, so it does
    # that somewhere of its own rather than where the forwards tests look.
    keepr, keeprun = W.LOCAL[], W.RUN_DIR[]
    W.RUN_DIR[] = mktempdir()
    W.LOCAL[] = joinpath(root, "local.toml"); write(W.LOCAL[], "")
    try
        st = mkstate(); ctrl = W.Controller()
        it = st.items[st.sel]
        withenv("PATH" => path) do
            W.handle!(st, Int('o'), ctrl)
            pv = last(ctrl.stack)
            @test pv isa W.PromptView && occursin(it.repo, pv.title)
            # And it says what answering does, and where it is kept.
            @test occursin("from now on", pv.note) && occursin("local.toml", pv.note)
            pv.onsubmit(main)
            pv2 = last(ctrl.stack)
            @test pv2 !== pv && W.text(pv2) == main
            @test occursin("some/other", pv2.note) && occursin("anyway", pv2.note)
            @test W.repo_path(it.repo) === nothing
            pv2.onsubmit(main)
            @test last(ctrl.stack) === pv2          # nothing more was asked
            @test W.repo_path(it.repo) == main
        end
        # One whose remote is the repository is kept at once.
        W.save_repo!(it.repo, nothing)
        W.git(main, "remote", "set-url", "origin", string("git@github.com:", it.repo, ".git"))
        empty!(ctrl.stack)
        withenv("PATH" => path) do
            W.handle!(st, Int('o'), ctrl)
            pv = last(ctrl.stack)
            pv.onsubmit(main)
            @test last(ctrl.stack) === pv
            @test W.repo_path(it.repo) == main
        end
    finally
        W.LOCAL[], W.RUN_DIR[] = keepr, keeprun
    end
end

@testset "a base the remote has not got is said, not measured from" begin
    # `origin/HEAD` is set by `clone` and moved by nothing after - not by
    # `fetch`, not by `remote set-url` - so a remote whose url was changed
    # keeps naming a branch of the repository it used to be, and every branch
    # of the checkout is then measured from wherever that forked off: the
    # llvm checkout whose `origin/HEAD` still said `julia-main`, 132,528
    # commits back (2026-10-15). The name is wrong, not old, and the fetch
    # of it is what tells the two apart.
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    g(a...) = W.git(main, a...)
    g("init", "--quiet", "--initial-branch=master", ".")
    g("config", "user.email", "me@example.com"); g("config", "user.name", "Me")
    write(joinpath(main, "a"), "x"); g("add", "a"); g("commit", "--quiet", "-m", "base")
    old = strip(g("rev-parse", "HEAD"))
    bare = joinpath(root, "o.git"); g("init", "--quiet", "--bare", bare)
    g("remote", "add", "origin", bare); g("push", "--quiet", "-u", "origin", "master")
    for i in 1:3
        write(joinpath(main, "a"), "m$i"); g("commit", "--quiet", "-am", "master $i")
    end
    g("push", "--quiet", "origin", "master")
    # The remote this used to be had a `stale` branch; the ref is still here.
    g("update-ref", "refs/remotes/origin/stale", old)
    g("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/stale")
    g("checkout", "--quiet", "-b", "mine"); write(joinpath(main, "b"), "y"); g("add", "b")
    g("commit", "--quiet", "-m", "my work")
    head = strip(g("rev-parse", "HEAD"))

    # The checkout's guess is the trap.
    @test W.default_base(main) == "origin/stale"
    @test W.fetch_base!(main, "o/r", "stale") === :missing
    @test W.fetch_base!(main, "o/r", "master") === :fetched
    @test W.fetch_base!(main, "o/r", "") === :failed
    @test W.branch_diff(main, "o/r", "stale", head) === :missing
    d = W.branch_diff(main, "o/r", "master", head)
    @test d isa String && occursin("+y", d)

    keept = W.LOCAL[]; W.LOCAL[] = joinpath(root, "local.toml"); write(W.localfile(), "")
    url = W.localurl("o/r", "mine")
    try
        W.register_repo!("o/r", main)
        @test W.repo_default("o/r") === nothing
        it = W.local_item(url)
        @test it.base == "origin/stale"
        ns = W.local_diff_nodes(it)
        @test length(ns) == 1 && get(ns[1].meta, "failed", false) === true
        @test occursin("origin has no branch origin/stale", ns[1].header)
        @test occursin("remote set-head origin -a", ns[1].raw)

        # GitHub's word, once a pull request of the repository has said it,
        # overrules the guess: the base, the diff, and whether the branch has
        # landed all follow it.
        W.cache_put(W.repo_default_key("o/r"), "master")
        @test W.repo_default("O/R") == "master"
        @test W.base_rev(main, "o/r") == "refs/remotes/origin/master"
        it = W.local_item(url)
        @test it.base == "master" && it.state == ""
        @test endswith(it.web, "/compare/master...mine?expand=1")
        ns = W.local_diff_nodes(it)
        @test any(n -> n.kind === :diff && occursin("+y", n.raw), ns)
        g("checkout", "--quiet", "master"); g("merge", "--quiet", "mine")
        g("push", "--quiet", "origin", "master")
        @test W.local_item(url).state == "MERGED"

        # A default GitHub named that the checkout has no copy of is nothing
        # to measure against - not a reason to fall back to the guess the
        # name already overruled.
        W.cache_put(W.repo_default_key("o/r"), "develop")
        @test W.base_rev(main, "o/r") === nothing
        it = W.local_item(url)
        @test it.base == "develop" && it.state == ""
        @test W.branch_source(main, "o/r", "new") == ("", "HEAD")
        @test !W.mine_on_branch(main, "mine", W.git_ids(main); base = "")

        # No network at all is `:failed`, which is only ever too old.
        g("remote", "set-url", "origin", joinpath(root, "gone.git"))
        @test W.fetch_base!(main, "o/r", "master") === :failed
        @test W.branch_diff(main, "o/r", "master", head) isa String
    finally
        W.cache_drop(W.repo_default_key("o/r"))
        W.LOCAL[] = keept
    end
end

@testset "a merged branch is diffed from its heads, not from the base that has them" begin
    # julia#63818: read at one head, pushed to once more, merged. The base has
    # both heads then, so measured from it each side was a head to itself,
    # and `range-diff old..old new..new` is `fatal: need two commit ranges`
    # and eight thousand characters of usage - of which the pane showed two
    # hundred.
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    g(a...) = W.git(main, a...)
    g("init", "--quiet", "--initial-branch=master", ".")
    g("config", "user.email", "me@example.com"); g("config", "user.name", "Me")
    write(joinpath(main, "a"), "x\n"); g("add", "a"); g("commit", "--quiet", "-m", "base")
    g("checkout", "--quiet", "-b", "pr")
    write(joinpath(main, "b"), "one\n"); g("add", "b"); g("commit", "--quiet", "-m", "first")
    old = strip(g("rev-parse", "HEAD"))
    write(joinpath(main, "b"), "one\ntwo\n"); g("commit", "--quiet", "-am", "second")
    new = strip(g("rev-parse", "HEAD"))
    g("checkout", "--quiet", "master")
    write(joinpath(main, "a"), "x\ny\n"); g("commit", "--quiet", "-am", "master moves")
    g("merge", "--quiet", "--no-ff", "-m", "merge pr", "pr")

    mv = W.branch_moved(main, old, new; base = "master")
    @test mv.kind === :diff && occursin("+two", mv.text)
    @test mv.now - mv.then == 1
    # Before the merge it was the same answer, measured from the base.
    pre = W.branch_moved(main, old, new; base = "master~1")
    @test pre.kind === :diff && occursin("+two", pre.text)

    # A branch reset back to a head inside the one you saw. From a base it is
    # a range like any other, the commit taken off unpaired; from the heads'
    # own merge base the new side is empty, nothing for `range-diff` to pair,
    # and the diff is what was taken off.
    @test W.branch_moved(main, new, old; base = "master~1").kind === :range
    back = W.branch_moved(main, new, old)
    @test back.kind === :diff && occursin("-two", back.text) && back.now < back.then

    # And what git says when it refuses is the command and its own line, not
    # its usage, with the shas cut to what the panes show.
    e = try
        W.git(main, "range-diff", string(old, "..", old), string(new, "..", new)); nothing
    catch err
        err
    end
    @test e isa W.GitError
    o8, n8 = first(string(old), 8), first(string(new), 8)
    @test W.git_said(e) ==
          "\$ git range-diff $o8..$o8 $n8..$n8\nfatal: need two commit ranges"
    @test W.git_said(W.GitError("not a git checkout: /x")) == "not a git checkout: /x"
end

@testset "a criss-cross history counts the branch's commits, not a merge base's" begin
    # The base and the branch each merged the other, so they have two merge
    # bases and `git merge-base` names one. Measured from it, the commit only
    # the other base reaches - already on the base - is counted and paired as
    # the pull request's own; `base..head` is the set itself.
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    g(a...) = W.git(main, a...)
    g("init", "--quiet", "--initial-branch=master", ".")
    g("config", "user.email", "me@example.com"); g("config", "user.name", "Me")
    write(joinpath(main, "a"), "x\n"); g("add", "a"); g("commit", "--quiet", "-m", "base")
    g("checkout", "--quiet", "-b", "pr")
    write(joinpath(main, "b"), "pr\n"); g("add", "b"); g("commit", "--quiet", "-m", "pr side")
    g("checkout", "--quiet", "master")
    write(joinpath(main, "c"), "master\n"); g("add", "c"); g("commit", "--quiet", "-m", "master side")
    master_side = strip(g("rev-parse", "HEAD"))
    g("merge", "--quiet", "--no-ff", "-m", "master takes pr", "pr")
    g("checkout", "--quiet", "pr")
    g("merge", "--quiet", "--no-ff", "-m", "pr takes master", master_side)
    @test length(split(strip(g("merge-base", "--all", "master", "pr")), '\n')) == 2
    write(joinpath(main, "b"), "pr\nmore\n"); g("commit", "--quiet", "-am", "the change")
    old = strip(g("rev-parse", "HEAD"))
    g("commit", "--quiet", "--amend", "-m", "the change, amended")
    new = strip(g("rev-parse", "HEAD"))

    mv = W.branch_moved(main, old, new; base = "master")
    @test mv.kind === :range
    @test (mv.then, mv.now) == (2, 2)    # "pr takes master" and the change
    @test !occursin("pr side", mv.text) && !occursin("master side", mv.text)
    @test occursin("the change, amended", mv.text)
end

@testset "a squash is the whole branch then against now, and each gone commit is its own diff" begin
    # Commits paired one to one say nothing about a squash: the new commit
    # pairs with one of the old ones or with none, the rest are gone, and the
    # change between the two branches is on no row. So the whole branch is
    # one more thing - the plain diff while the base stands still, a diff of
    # the two diffs once it has moved - and nothing of it lands in the
    # checkout's own objects.
    root = mktempdir(); main = joinpath(root, "main"); mkpath(main)
    g(a...) = W.git(main, a...)
    g("init", "--quiet", "--initial-branch=master", ".")
    g("config", "user.email", "me@example.com"); g("config", "user.name", "Me")
    write(joinpath(main, "f"), "a\nb\nc\n"); g("add", "f"); g("commit", "--quiet", "-m", "base")
    g("checkout", "--quiet", "-b", "pr")
    write(joinpath(main, "f"), "a\nb\nc\none\n"); g("commit", "--quiet", "-am", "add one")
    g("checkout", "--quiet", "master")
    write(joinpath(main, "g"), "z\n"); g("add", "g"); g("commit", "--quiet", "-m", "master moves")
    g("checkout", "--quiet", "pr")
    g("merge", "--quiet", "--no-ff", "-m", "merge master", "master")
    write(joinpath(main, "f"), "a\nb\nc\none\ntwo\n"); g("commit", "--quiet", "-am", "add two")
    old = strip(g("rev-parse", "HEAD"))
    g("reset", "--quiet", "--soft", "master")
    write(joinpath(main, "f"), "a\nb\nc\none\nTWO\n"); g("commit", "--quiet", "-am", "all in one")
    new = strip(g("rev-parse", "HEAD"))
    objects() = sort(readdir(joinpath(main, ".git", "objects"); join = true))
    before = objects()

    mv = W.branch_moved(main, old, new; base = "master")
    @test mv.kind === :range && mv.moved == 0
    whole = W.branch_whole(main, old, new; base = "master", moved = mv.moved)
    @test whole.kind === :diff
    @test occursin("    -two", whole.text) && occursin("    +TWO", whole.text)
    # Each commit gone with the squash carries its own diff; `range-diff`
    # leaves the merge of the base out altogether.
    lone = W.lone_patches(main, mv.text)
    @test occursin("< -:  ------- add two\n    diff --git a/f b/f", lone)
    @test !occursin("merge master", lone)

    # The base moves and the squash is rebased onto it: the plain diff would
    # be the base's commit as much as the branch's, so it is the diff of diffs.
    g("checkout", "--quiet", "master")
    write(joinpath(main, "g"), "z\ny\n"); g("commit", "--quiet", "-am", "master again")
    g("checkout", "--quiet", "pr"); g("rebase", "--quiet", "master")
    newer = strip(g("rev-parse", "HEAD"))
    before = objects()
    mv = W.branch_moved(main, old, newer; base = "master")
    @test mv.kind === :range && mv.moved == 1
    whole = W.branch_whole(main, old, newer; base = "master", moved = mv.moved)
    @test whole.kind === :range
    @test occursin("    -+two", whole.text) && occursin("    ++TWO", whole.text)
    @test !occursin("+y", whole.text)               # the base's own change
    @test all(l -> startswith(l, "    "), split(whole.text, '\n'))
    @test objects() == before
    n = W.whole_node(main, old, newer, "master", mv, mv.text)
    @test n.open && n.meta["range"] === true
end
