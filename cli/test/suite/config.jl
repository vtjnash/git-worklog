# The configuration in two layers: the shared file beside the code and the
# per-user one in `data/`, read as one.

@testset "the two layers merge two levels deep, and no deeper" begin
    common = Dict{String,Any}(
        "login" => "", "theme" => "light.toml",
        "thresholds" => Dict{String,Any}("reply_days" => 30, "second_look_days" => 2),
        "events" => Dict{String,Any}("repos" => ["a/b"], "include_forks" => true),
        "views" => Dict{String,Any}("quiet" => Dict{String,Any}("tag" => ["second"], "repo" => ["a/b"])))
    user = Dict{String,Any}(
        "login" => "me",
        "thresholds" => Dict{String,Any}("reply_days" => 7),
        "events" => Dict{String,Any}("repos" => ["c/d", "e/*"]),
        "views" => Dict{String,Any}("quiet" => Dict{String,Any}("tag" => ["reply"]),
                                    "mine" => Dict{String,Any}("author" => ["@me"])),
        "agent" => Dict{String,Any}("command" => "x"))
    m = W.merge_config(common, user)
    # A top-level value replaces; one the user file does not name stays.
    @test m["login"] == "me" && m["theme"] == "light.toml"
    # A table merges key by key...
    @test m["thresholds"] == Dict("reply_days" => 7, "second_look_days" => 2)
    @test m["events"]["include_forks"] === true
    # ...and what is under a key replaces whole: the list is the user's list,
    # and a view of the same name is the user's view, not a merge of axes.
    @test m["events"]["repos"] == ["c/d", "e/*"]
    @test m["views"]["quiet"] == Dict("tag" => ["reply"])
    @test m["views"]["mine"] == Dict("author" => ["@me"])
    # A table only the user names is added; neither input is touched.
    @test m["agent"]["command"] == "x"
    @test common["thresholds"]["reply_days"] == 30 && !haskey(common, "agent")
    # A user value where the shared file has a table replaces it outright
    # rather than erroring; that is a misconfiguration the parser will not
    # catch, and the rule stays one rule.
    @test W.merge_config(common, Dict{String,Any}("events" => 1))["events"] == 1
end

@testset "config() is the shared file with the user's on top, in file order" begin
    d = mktempdir()
    keep = W.USER_CONFIG[]
    try
        # No user file: the shared file alone, whose defaults name nobody.
        W.USER_CONFIG[] = joinpath(d, "none.toml")
        cfg = W.config()
        @test cfg["login"] == ""
        @test isempty(cfg["events"]["repos"]) && isempty(cfg["filters"]["pinned_repos"])
        # Every lane is shareable as it stands: `@me`, not a login.
        for (_, q) in cfg["lanes"]
            @test occursin("@me", q)
        end
        # With one: the merge, and the lanes walked in the shared order with
        # the user's addition after them - `ordered` reads both texts end to
        # end, and a lane both name sits where the shared file put it.
        W.USER_CONFIG[] = joinpath(d, "config.toml")
        write(W.USER_CONFIG[], """
            login = "me"
            [lanes]
            extra = "is:open is:issue mentions:@me sort:created-asc"
            review = "is:open is:pr review-requested:@me label:x sort:created-asc"
            [events]
            repos = ["o/r"]
            """)
        cfg = W.config()
        @test cfg["login"] == "me" && cfg["events"]["repos"] == ["o/r"]
        @test cfg["events"]["include_forks"] === true       # the shared default, kept
        @test occursin("label:x", cfg["lanes"]["review"])
        @test first.(W.ordered(cfg["lanes"], W.config_text(), "lanes")) ==
              ["mine", "review", "assigned", "extra"]
    finally
        W.USER_CONFIG[] = keep
    end
end

@testset "the first launch writes the user's file from the template, once" begin
    d = mktempdir()
    keep = W.USER_CONFIG[]
    try
        W.USER_CONFIG[] = joinpath(d, "sub", "config.toml")
        io = IOBuffer()
        @test W.seed_config!(; io = io, whoami = () -> "somebody")
        t = read(W.USER_CONFIG[], String)
        # A copy of the template with one line changed, comments and all, so
        # the file that lands is the manual for its own keys.
        tmpl = read(W.configtemplate(), String)
        @test occursin("login = \"somebody\"", t)
        @test replace(t, "login = \"somebody\"" => "login = \"\"") == tmpl
        @test count(==('#'), t) == count(==('#'), tmpl)
        @test occursin("for somebody", String(take!(io)))
        @test W.config()["login"] == "somebody"
        # Never again: a second launch, even with a different answer from
        # `gh`, leaves the file alone.
        @test !W.seed_config!(; io = io, whoami = () -> "other")
        @test read(W.USER_CONFIG[], String) == t

        # `gh` with nothing to say: the file is still written, `login` stays
        # empty, the line says to set it, and `dispatch` refuses to run
        # anything but help until it is.
        W.USER_CONFIG[] = joinpath(d, "blank.toml")
        @test W.seed_config!(; io = io, whoami = () -> "")
        @test occursin("set `login`", String(take!(io)))
        @test W.config()["login"] == ""
        @test_throws W.CliError W.dispatch(["log"], W.DateTime(2026, 9, 17))
        @test redirect_stdout(() -> W.dispatch(["help"]), devnull) == 0
    finally
        W.USER_CONFIG[] = keep
    end
end
