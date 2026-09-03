# The refresh: what a lane returns, what has gone quiet, and what a settled
# thread does next.

@testset "a batch in one process, not a loop of them" begin
    # `-` is the ref that means stdin. One mechanism for every command that
    # takes one, no new flag, and nothing a variadic ref list would have to be
    # told apart from the value argument.
    # The stream is an argument, so this is driven from an IOBuffer the way
    # `readevent` is rather than by taking stdin away from the test runner.
    @test W.stdin_lines(IOBuffer("julia#62841\n\n# a note\nhttps://github.com/o/r/pull/7  x\n")) ==
          ["julia#62841", "https://github.com/o/r/pull/7"]
    # A url needs no resolving, which is the difference between the two readers:
    # requiring one to be in facts.json would refuse exactly what `import` is for.
    @test W.refs("-", IOBuffer("https://github.com/o/r/pull/7\n")) ==
          ["https://github.com/o/r/pull/7"]
    # And an argument that is not `-` is still just that one ref.
    @test W.refs("https://github.com/o/r/pull/9") == ["https://github.com/o/r/pull/9"]
    # Nothing to act on says so rather than doing nothing quietly.
    @test_throws W.CliError W.refs("-", IOBuffer("\n#only comments\n"))

    # An inbox entry is how an imported item reaches the unread lane: no poll
    # will ever find one, since its repo is not watched - which is why it was
    # imported.
    keepi, keepr = W.Events.INBOX[], W.Events.READ[]
    d = mktempdir()
    W.Events.INBOX[] = joinpath(d, "inbox.json")
    W.Events.READ[] = joinpath(d, "read.json")
    try
        u = "https://github.com/o/r/issues/3"
        W.Events.mark_read([u], W.utcnow())          # read from some earlier life
        @test W.Events.read_at(u) !== nothing
        n = W.Events.inbox_add!([Dict{String,Any}(
            "url" => u, "repo" => "o/r", "number" => 3, "title" => "t",
            "is_pr" => false, "state" => "open", "author" => "a",
            "updated" => "2026-09-03T00:00:00Z", "comments" => 0,
            "labels" => String[], "mine" => false)])
        @test n == 1
        @test haskey(W.Events.load_inbox()["items"], u)
        # A second delivery of the same url is not a second entry, and with
        # `overwrite = false` it leaves what a *poll* wrote: much of what gets
        # imported is already in here with a comment count this caller does not
        # have, and marking it unread is the whole of what is wanted.
        rich = W.Events.load_inbox()["items"][u]
        rich["comments"] = 12
        inbox = W.Events.load_inbox(); inbox["items"][u] = rich
        W.Events.save_inbox(inbox)
        W.Events.mark_read([u], W.utcnow())
        thin = Dict{String,Any}("url" => u, "repo" => "o/r", "number" => 3,
                                "title" => "t", "is_pr" => false, "state" => "open",
                                "author" => "a", "updated" => "2026-09-03T00:00:00Z",
                                "comments" => 0, "labels" => String[], "mine" => false)
        @test W.Events.inbox_add!([thin]; overwrite = false) == 1
        @test length(W.Events.load_inbox()["items"]) == 1
        @test W.Events.load_inbox()["items"][u]["comments"] == 12   # the poll's
        @test W.Events.read_at(u) === nothing                       # still unread
        # And overwriting is what a caller that knows better asks for.
        W.Events.inbox_add!([thin])
        @test W.Events.load_inbox()["items"][u]["comments"] == 0
        # The read stamp is cleared, or it would hide the thing just delivered.
        @test W.Events.read_at(u) === nothing
        # Nothing is claimed to have been polled: no cursor moves.
        @test isempty(W.Events.load_inbox()["cursors"])
    finally
        W.Events.INBOX[] = keepi; W.Events.READ[] = keepr
    end
end

@testset "work that has gone quiet on somebody" begin
    # Two days of silence over a weekend is not silence, it is a weekend.
    @test W.workdays_since("2026-08-28T17:00:00Z", W.DateTime(2026, 8, 31, 17)) == 1
    @test W.workdays_since("2026-08-28T17:00:00Z", W.DateTime(2026, 9, 1, 9)) == 2
    @test W.workdays_since("2026-08-31T09:00:00Z", W.DateTime(2026, 9, 2, 9)) == 2
    # By day and not by hour: the answer must not depend on the hour somebody
    # happened to be typing.
    @test W.workdays_since("2026-08-31T09:00:00Z", W.DateTime(2026, 9, 2, 23)) ==
          W.workdays_since("2026-08-31T23:00:00Z", W.DateTime(2026, 9, 2, 9))
    @test W.workdays_since(nothing, W.DateTime(2026, 9, 3)) == 0
    @test W.workdays_since("2026-09-03T09:00:00Z", W.DateTime(2026, 9, 3, 17)) == 0

    at = W.DateTime(2026, 9, 3, 12)
    base() = Dict{String,Any}("state" => "OPEN", "backlog" => false, "author" => "alice")
    look(r) = W.second_look(r, at, 2, 20)

    # The author spoke and nobody answered.
    r = base(); r["last_comment_by"] = "alice"
    r["last_comment_at"] = "2026-08-28T17:00:00Z"
    r["head_at"] = "2026-08-20T00:00:00Z"
    @test occursin("alice asked", look(r)) && occursin("4 work days", look(r))
    # Somebody did answer, so nobody is waiting on anybody.
    r2 = copy(r); r2["last_comment_by"] = "bob"
    @test isempty(look(r2))
    # A push with nothing said since is the same silence.
    r3 = base(); r3["head_at"] = "2026-09-01T00:00:00Z"
    @test occursin("alice pushed", look(r3))
    # An approval that is the last thing to have happened outranks both: that is
    # not waiting on review, it is waiting on a button.
    r4 = copy(r); r4["approved_at"] = "2026-08-31T10:00:00Z"
    @test occursin("approved", look(r4))
    # An older approval does not, since something happened after it.
    r5 = copy(r); r5["approved_at"] = "2026-08-01T10:00:00Z"
    @test occursin("alice asked", look(r5))

    # A window and not a floor, at both ends.
    @test isempty(W.second_look(r3, W.DateTime(2026, 9, 2, 9), 2, 20))   # not late yet
    old = base(); old["head_at"] = "2025-01-02T00:00:00Z"
    @test isempty(look(old))                                   # not news any more
    # And nothing fires on work that is over, or on the pile that is not a
    # to-do list.
    done_ = copy(r); done_["state"] = "MERGED"
    @test isempty(look(done_))
    pile = copy(r); pile["backlog"] = true
    @test isempty(look(pile))
    # Nothing to measure at all is not silence.
    @test isempty(look(base()))

    # It is a lane of its own in the filter pane, and it needs no enabling -
    # which is the whole difference from a snooze.
    st = mkstate()
    @test any(x -> x[1] === :second, W.STATES)
    quiet = W.Item(url = "u", ref = "a#1", repo = "a/b", number = 1, title = "t",
                   secondlook = "alice asked, then quiet for 3 work days")
    @test W.state_ok(:second, quiet, Set{String}())
    @test !W.state_ok(:second, W.Item(url = "u2", ref = "a#2", repo = "a/b",
                                      number = 2, title = "t"), Set{String}())
    # Archived work is not waiting on anybody.
    @test !W.state_ok(:second, quiet, Set{String}(), W.EMPTY_TOUCHED,
                      Dict("u" => "2026-09-01"))
    # And the reason is shown where the item's facts are.
    @test any(l -> occursin("quiet", l) && occursin("3 work days", l),
              W.astrip.(W.meta_lines(st, quiet, 60)))
end

@testset "a settled thread is out of the way, not gone" begin
    # Comments are placed against the hunk they point into. Resolution is a
    # property of the *thread* and REST carries no trace of it, so a
    # conversation settled six weeks ago arrived in the shape of one waiting for
    # an answer.
    hunk = W.Node("a.jl  @@ 10,3 @@", " ctx\n+added", :diff, true)
    merge!(hunk.meta, Dict{String,Any}("file" => "a.jl", "start" => 10, "count" => 3,
                                       "ostart" => 40, "ocount" => 2))
    cs = [Dict{String,Any}("id" => 1, "path" => "a.jl", "line" => 11, "side" => "RIGHT",
                           "body" => "still wondering", "user" => Dict("login" => "a"),
                           "created_at" => "2026-01-01T00:00:00Z"),
          Dict{String,Any}("id" => 2, "path" => "a.jl", "line" => 11, "side" => "RIGHT",
                           "body" => "settled long ago", "user" => Dict("login" => "b"),
                           "created_at" => "2026-01-02T00:00:00Z")]
    # With nothing known to be resolved, both are inline, as before.
    ns = W.attach_comments([deepcopy(hunk)], cs, "u")
    @test occursin("💬2", ns[1].header) && !occursin("✓", ns[1].header)
    @test length(ns) > 2

    ns2 = W.attach_comments([deepcopy(hunk)], cs, "u", Set([2]))
    # Two marks, because they say different things: what is waiting for an
    # answer is why you are reading the hunk, what was answered is why you can
    # stop.
    @test occursin("💬1", ns2[1].header) && occursin("✓1", ns2[1].header)
    # The open one is inline; the settled one is under a closed node of its own,
    # beneath the hunk it belongs to rather than in a pile at the end.
    txt = [W.astrip(n.header) for n in ns2]
    i = findfirst(h -> occursin("resolved", h), txt)
    @test i !== nothing && !ns2[i].open
    @test any(n -> occursin("still wondering", n.raw), ns2[1:i-1])
    @test all(!occursin("settled long ago", n.raw) for n in ns2[1:i])
    @test any(n -> occursin("settled long ago", n.raw), ns2[i+1:end])
    @test ns2[i+1].depth > ns2[i].depth          # so folding the node hides it
    # Everything resolved is a hunk with nothing waiting on it.
    ns3 = W.attach_comments([deepcopy(hunk)], cs, "u", Set([1, 2]))
    @test !occursin("💬", ns3[1].header) && occursin("✓2", ns3[1].header)

    # A comment whose line is gone has nowhere to be placed, and the same split
    # applies to those: settled *and* outdated is over twice over, while an open
    # one is a remark nobody answered and the line moving did not make it moot.
    gone = [Dict{String,Any}("id" => 3, "path" => "a.jl", "line" => nothing,
                             "body" => "open, and adrift", "user" => Dict("login" => "a"),
                             "created_at" => "2026-01-03T00:00:00Z"),
            Dict{String,Any}("id" => 4, "path" => "a.jl", "line" => nothing,
                             "body" => "settled, and adrift", "user" => Dict("login" => "b"),
                             "created_at" => "2026-01-04T00:00:00Z")]
    ns4 = W.attach_comments([deepcopy(hunk)], gone, "u", Set([4]))
    heads = [W.astrip(n.header) for n in ns4]
    j = findfirst(h -> occursin("on lines that have since changed", h) &&
                       !occursin("resolved", h), heads)
    k = findfirst(h -> occursin("resolved, on lines", h), heads)
    @test j !== nothing && k !== nothing && j < k
    @test !ns4[j].open && !ns4[k].open              # both put away
    @test occursin("1 comment on lines", heads[j])
end
