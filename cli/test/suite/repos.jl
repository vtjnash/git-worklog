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
