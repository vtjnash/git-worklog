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

    keepr, keeph = W.REPOS_FILE[], get(ENV, "HOME", "")
    W.REPOS_FILE[] = joinpath(root, "repos.toml")
    try
        # Written the way a person writes it, not the way the program does.
        write(W.REPOS_FILE[], "[\"o/r\"]\nworktree = \"~/main\"\n")
        ENV["HOME"] = root
        @test W.repo_path("o/r") == main
        # And the survey sees it too, which is what the worktree list is built
        # from - the two used to disagree with each other about the same file.
        ws, _ = W.survey(; withdirty = false)
        @test any(w -> w.repo == "o/r", ws)
    finally
        ENV["HOME"] = keeph
        W.REPOS_FILE[] = keepr
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
