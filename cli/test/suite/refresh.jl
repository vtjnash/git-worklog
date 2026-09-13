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
    keepi, keepm = W.FETCHED[], W.LOCAL[]
    d = mktempdir()
    W.FETCHED[] = joinpath(d, "fetched.json")
    W.LOCAL[] = joinpath(d, "local.toml")
    try
        u = "https://github.com/o/r/issues/3"
        W.mark_read([u], W.utcnow())          # read from some earlier life
        @test W.read_at(u) !== nothing
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
        W.mark_read([u], W.utcnow())
        thin = Dict{String,Any}("url" => u, "repo" => "o/r", "number" => 3,
                                "title" => "t", "is_pr" => false, "state" => "open",
                                "author" => "a", "updated" => "2026-09-03T00:00:00Z",
                                "comments" => 0, "labels" => String[], "mine" => false)
        @test W.Events.inbox_add!([thin]; overwrite = false) == 1
        @test length(W.Events.load_inbox()["items"]) == 1
        @test W.Events.load_inbox()["items"][u]["comments"] == 12   # the poll's
        @test W.read_at(u) === nothing                       # still unread
        # And overwriting is what a caller that knows better asks for.
        W.Events.inbox_add!([thin])
        @test W.Events.load_inbox()["items"][u]["comments"] == 0
        # The read stamp is cleared, or it would hide the thing just delivered.
        @test W.read_at(u) === nothing
        # Nothing is claimed to have been polled: no cursor moves.
        @test isempty(W.Events.load_inbox()["cursors"])
    finally
        W.FETCHED[] = keepi; W.LOCAL[] = keepm
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
    base() = Dict{String,Any}("state" => "OPEN", "bucket" => "needs-review",
                              "author" => "alice")
    look(r) = W.second_look(r, at, 2)

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

    # A floor, and only a floor.
    @test isempty(W.second_look(r3, W.DateTime(2026, 9, 2, 9), 2))   # not late yet
    # There is no ceiling any more. A pull request quiet since last January is
    # still a pull request waiting on somebody, and it used to stop being
    # reported at 20 work days - leaving the lane on a day nobody chose, with
    # nothing recorded and nothing to undo. The lane is ordered newest first, so
    # it is at the bottom rather than in the way, and `s` `1` is what takes it
    # out: a decision, in `marks.json`, undone by `z`, back when it moves.
    old = base(); old["head_at"] = "2025-01-02T00:00:00Z"
    @test occursin("alice pushed", look(old))
    @test occursin("work days", look(old))
    # And nothing fires on work that is over, or on the pile that is not a
    # to-do list.
    done_ = copy(r); done_["state"] = "MERGED"
    @test isempty(look(done_))
    # The pile is asked for by name rather than carried on the row, and it is
    # the bucket that says so - `track = "background"` was the other half of it
    # and is gone, along with the level that could never wake.
    for b in ("firehose", "mentioned")
        pile = copy(r); pile["bucket"] = b
        @test isempty(look(pile)) && W.in_pile(pile)
    end
    @test !W.in_pile(r)
    # Nothing to measure at all is not silence.
    @test isempty(look(base()))

    # It is a lane of its own in the filter pane, and it needs no enabling -
    # which is the whole difference from a snooze.
    st = mkstate()
    @test any(x -> x[1] === :second, W.TAGS)
    quiet = W.Item(url = "u", ref = "a#1", repo = "a/b", number = 1, title = "t",
                   secondlook = "alice asked, then quiet for 3 work days")
    @test :second in W.tags_of(quiet)
    @test isempty(W.tags_of(W.Item(url = "u2", ref = "a#2", repo = "a/b",
                                   number = 2, title = "t")))
    # Filed work still carries the tag, and the sleep axis is what takes it out
    # of a list: two questions, two axes, no precedence between them.
    @test :second in W.tags_of(quiet, W.Marks(archived = Dict("u" => "2026-09-01T00:00:00Z")))
    # And the reason is shown where the item's facts are.
    @test any(l -> occursin("quiet", l) && occursin("3 work days", l),
              W.astrip.(W.meta_lines(st, quiet, 60)))
end

@testset "mergeability is asked of one pull request, when it is looked at" begin
    # `mergeable` is what GitHub computes lazily, and asking is what makes it
    # compute: a lane page that named it took 20-33s on four runs in twelve
    # and never left 5-8s without it. So no lane asks, no row carries it, and
    # the pane asks `merge_state` for the one pull request under the cursor -
    # the same call the merge prompt makes - and says it that prompt's way.
    @test !occursin("mergeable", W.PR_FIELDS)
    @test !occursin("mergeable", W.FIREHOSE_QUERY)
    st = mkstate()
    base = (url = "https://example.invalid/pr/1", ref = "a#1", repo = "a/b",
            number = 1, title = "t", is_pr = true)
    says(it) = W.astrip(join([l for l in W.meta_lines(st, it, 60)
                              if occursin("mergeable", l)], " "))
    ms(; kw...) = (; id = "x", oid = "o", state = "OPEN", draft = false,
                     mergeable = "MERGEABLE", status = "CLEAN", base = "master",
                     commits = 1, methods = String[], text = Dict{String,Tuple{String,String}}(),
                     kw...)
    # Nothing until it has been asked, and nothing once the pull request is
    # over: a merged one has no merge left to be possible.
    @test says(W.Item(; base..., state = "OPEN")) == ""
    st.metakey = base.url; st.merge = ms()
    @test says(W.Item(; base..., state = "OPEN")) == "mergeable clean"
    st.merge = ms(; mergeable = "CONFLICTING", status = "DIRTY")
    @test says(W.Item(; base..., state = "OPEN")) == "mergeable conflicts with master"
    st.merge = ms(; status = "BEHIND")
    @test says(W.Item(; base..., state = "OPEN")) == "mergeable behind master"
    @test says(W.Item(; base..., state = "MERGED")) == ""
    @test says(W.Item(; base..., state = "CLOSED")) == ""
    # And what was fetched for one item is not said about another.
    @test says(W.Item(; base..., url = "https://example.invalid/pr/2", state = "OPEN")) == ""
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

@testset "a draft that leaves with its item" begin
    # Everything still on the dashboard is reconciled by being opened. An item
    # that has gone cannot be: the lane is items, so a mark on a url that is no
    # longer one of them can never be shown or navigated to again.
    gone = [("https://github.com/o/r/pull/1", "r#1"),
            ("https://github.com/o/r/pull/2", "r#2")]
    still = "https://github.com/o/r/pull/3"
    for (u, _) in gone
        W.draft!(u)
    end
    W.draft!(still)
    asked = String[]
    # Sent or discarded while it was closing: the mark goes with the item.
    ask(url) = (push!(asked, url); (id = "PR_x", review = "", n = 0))
    @test W.reconcile_drafts!(gone, ask) == 2
    @test sort(asked) == sort([u for (u, _) in gone])   # and nothing else asked
    @test collect(keys(W.load_drafts())) == [still]

    # Still unsent, on a pull request that has just closed: kept, and said out
    # loud, because this is the last moment anything will mention it.
    W.draft!(first(first(gone)))
    held(url) = (id = "PR_x", review = "PRR_y", n = 3)
    said = mktemp() do path, io
        redirect_stderr(() -> @test(W.reconcile_drafts!(gone, held) == 0), io)
        flush(io)
        read(path, String)
    end
    @test occursin("r#1", said) && occursin("unsent draft review", said)
    @test haskey(W.load_drafts(), first(first(gone)))

    # A question that cannot be asked is not an answer: the mark stays.
    boom(url) = error("no network")
    @test W.reconcile_drafts!(gone, boom) == 0
    @test haskey(W.load_drafts(), first(first(gone)))

    for (u, _) in gone
        W.undraft!(u)
    end
    W.undraft!(still)
    @test isempty(W.load_drafts())
end

@testset "being asked to review is a move" begin
    # A *re*-request is the only kind you get on something you have already
    # read, and until the request was fetched nothing about it changed:
    # `reviewDecision` stays where it was, `review_count` stays where it was,
    # and GitHub's re-request button posts no comment. So the item stayed read.
    now_ = W.ts("2026-09-12T11:00:00Z")
    rec(; kw...) = merge(Dict{String,Any}("track" => "normal",
                                         "review_decision" => "REVIEW_REQUIRED",
                                         "ci" => "SUCCESS",
                                         "head_at" => "2026-09-01T00:00:00Z",
                                         "their_comment_at" => "2026-09-01T00:00:00Z",
                                         "human_comment_at" => "2026-09-01T00:00:00Z",
                                         "moved_at" => "2026-09-01T00:00:00Z",
                                         "unresolved" => 0),
                         Dict{String,Any}(String(k) => v for (k, v) in kw))
    was(d) = NamedTuple(Symbol(k) => v for (k, v) in d)
    quiet = rec()
    asked = rec(; review_requested = true, review_requested_at = "2026-09-02T14:02:00Z")
    # Both levels, because there is no level at which being named is noise -
    # `loose` ignores a stranger's CI and a bot's comment, and this is neither.
    for lvl in ("normal", "loose")
        q = rec(; track = lvl); a = merge(asked, Dict("track" => lvl))
        @test W.moved_stamp(was(q), a, now_) == "2026-09-02T14:02:00Z"
    end

    # **The key is the time and not the bool.** Being asked is an event, and
    # the timeline says when; the standing `reviewRequests` connection says
    # only whether you are asked now, and says it to the change list, not to
    # the wake table. So the bool flipping on its own - true, absent, or
    # written by a hand that did not know better, false - is not a movement.
    for b in (true, nothing, false)
        @test W.moved_stamp(was(asked), rec(; review_requested = b,
                                            review_requested_at = "2026-09-02T14:02:00Z"), now_) ==
              "2026-09-01T00:00:00Z"
    end

    # And nothing else about the item had to change for that to be true, which
    # is the whole complaint: the two records differ in the request alone.
    @test setdiff(keys(asked), keys(quiet)) == Set(["review_requested", "review_requested_at"])
    @test all(quiet[k] == asked[k] for k in keys(quiet))

    # A re-request is a newer time on the same standing bool, and moves.
    again = rec(; review_requested = true, review_requested_at = "2026-09-05T09:00:00Z")
    @test W.moved_stamp(was(asked), again, now_) == "2026-09-05T09:00:00Z"

    # Withdrawing it does not. This said the opposite once - that being off
    # the hook was what `r` on it was waiting to hear - and was decided the
    # other way on 2026-09-12: being let off is the end of a claim on your
    # attention, not a claim on it. The standing bool clears and the time
    # stays, and the time is the key.
    off = rec(; review_requested = nothing, review_requested_at = "2026-09-02T14:02:00Z")
    @test W.moved_stamp(was(asked), off, now_) == "2026-09-01T00:00:00Z"
end

@testset "nothing ages out of being unread" begin
    # A row is an item because a lane returned it, and every active lane is
    # `is:open` - so the merge that took it out of the lanes used to take it
    # out of the snapshot, unread mark and all, once the closed lanes' window
    # had passed. A row that was in front of you and that no lane returns is
    # fetched by url and kept while it is unread; this is the keep.
    r = Dict{String,Any}("moved_at" => "2026-09-12T20:53:03Z")
    st(; kw...) = Dict{String,Any}(String(k) => v for (k, v) in kw)
    @test W.still_unread(r, st())                                    # never read
    @test W.still_unread(r, st(read = "2026-09-12T00:00:00Z"))       # read before it moved
    @test !W.still_unread(r, st(read = "2026-09-12T20:53:03Z"))      # read up to the move
    @test !W.still_unread(r, st(read = "2026-09-13T00:00:00Z"))
    # Filed is dealt with, read or not.
    @test !W.still_unread(r, st(archived = "2026-09-13T00:00:00Z"))
    # And the pile is not in front of you: a closed row leaving it is not
    # carried, or a thousand pull requests nobody will read would be fetched
    # by url on every refresh for good.
    @test W.in_pile(Dict{String,Any}("bucket" => "firehose"))
    @test !W.in_pile(Dict{String,Any}("bucket" => "done"))
    # Exercised live on 2026-09-13 with julia#61767, merged by somebody else
    # in May and returned by no lane: carried, seen merged, `moved_at` dated
    # by the merge, kept as unread through two refreshes, and let go on the
    # one after `wl read`.
end

@testset "a movement is dated by the thing that moved" begin
    # The refresh clock is the honest answer for a state with no clock of its
    # own and the wrong one for a comment: `r` stamps you read at the moment the
    # thread was fetched, which is fresher than any refresh, so a comment posted
    # at 09:55 and read at 10:00 was dated 11:00 by the refresh that first saw
    # it, and the item came back unread for something you had already read.
    now_ = W.ts("2026-09-12T11:00:00Z")
    row(; kw...) = merge(Dict{String,Any}("track" => "normal",
                                          "their_head" => "a1b2c3",
                                          "head_at" => "2026-09-12T08:00:00Z",
                                          "their_comment_at" => "2026-09-12T09:00:00Z",
                                          "human_comment_at" => "2026-09-12T09:00:00Z",
                                          "review_at" => "2026-09-12T08:30:00Z",
                                          "moved_at" => "2026-09-12T09:00:00Z"),
                         Dict{String,Any}(String(k) => v for (k, v) in kw))
    # The shape the snapshot is read back in: a row `jget` can be asked about.
    was(d = row()) = NamedTuple(Symbol(k) => v for (k, v) in d)
    old = was()
    # And nothing moving is an answer it gives, not a case it never sees: it
    # is the one arbiter now, asked about every row, and the mark stays put.
    @test W.moved_stamp(old, row(), now_) == "2026-09-12T09:00:00Z"
    @test W.moved_stamp(old, row(; their_comment_at = "2026-09-12T09:55:00Z",
                                 human_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          "2026-09-12T09:55:00Z"
    # Being handed the item has the shape of being asked to review it.
    @test W.moved_stamp(old, row(; assigned_at = "2026-09-12T10:05:00Z"), now_) ==
          "2026-09-12T10:05:00Z"
    # A review says when it was submitted, by the same rule.
    @test W.moved_stamp(old, row(; review_at = "2026-09-12T10:15:00Z"), now_) ==
          "2026-09-12T10:15:00Z"

    # **A push is a sha and the sha has no time**, so it is dated by `head_at` -
    # the committer date of the commit the branch now points at, which is the
    # closest thing GitHub offers.
    @test W.moved_stamp(old, row(; their_head = "ffff", head_at = "2026-09-12T10:30:00Z"),
                        now_) == "2026-09-12T10:30:00Z"
    # And `head_at` moving on its own is not a movement at all any more: a
    # rebase rewrites it, and whether there is anything new to look at is what
    # the sha says.
    @test W.moved_stamp(old, row(; head_at = "2026-09-12T10:30:00Z"), now_) ==
          "2026-09-12T09:00:00Z"

    # Being asked is dated by the asking: a timeline event naming you, with a
    # time of its own.
    @test W.moved_stamp(old, row(; review_requested = true,
                                 review_requested_at = "2026-09-12T10:20:00Z"), now_) ==
          "2026-09-12T10:20:00Z"
    # And so is somebody else finishing it, which is a thing GitHub mails about
    # and a thing there is no point sleeping through.
    @test W.moved_stamp(old, row(; state = "MERGED", state_at = "2026-09-12T10:40:00Z"), now_) ==
          "2026-09-12T10:40:00Z"
    # The standing bool is not a key, so it flipping on its own - the timeline
    # truncated past the event that flipped it - is not a movement.
    @test W.moved_stamp(old, row(; review_requested = true), now_) == "2026-09-12T09:00:00Z"

    # The CI bool has no clock anywhere, so the refresh that saw it is the
    # only date there is.
    @test W.moved_stamp(old, row(; ci_failed = true), now_) == W.stamp(now_)
    # Mixed is now: dating the pair by the comment would say the item moved
    # before the CI failure that moved it beside it did.
    @test W.moved_stamp(old, row(; ci_failed = true,
                                 their_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          W.stamp(now_)
    # **And a bool moves on one edge.** It going red is the event; it going
    # green is not - the green arrived as the push that fixed it, or is a
    # rerun of the same commit - and a rerun that passes through pending would
    # otherwise wake the item twice for one failure. A hash of the value
    # differs on both edges, which is why a bool is not hashed any more.
    red = was(row(; ci_failed = true))
    @test W.moved_stamp(red, row(; ci_failed = nothing), now_) == "2026-09-12T09:00:00Z"
    @test W.moved_stamp(red, row(; ci_failed = true), now_) == "2026-09-12T09:00:00Z"
    # It clearing beside a comment is the comment's movement, dated by it.
    @test W.moved_stamp(red, row(; ci_failed = nothing,
                                 their_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          "2026-09-12T09:55:00Z"

    # Never backwards. `head_at` is a committer date, so a force-push of an
    # older commit carries an older one - and there is something to show for
    # that, since the sha says the branch is not what you last saw. A time that
    # cannot account for the change does not get to explain it.
    @test W.moved_stamp(old, row(; their_head = "ffff",
                                 head_at = "2026-09-12T07:00:00Z"), now_) == W.stamp(now_)
    # A deleted comment moves `last_comment_at` back to the one before it, and
    # that one is fine either way: what moved the key is gone, so missing it
    # costs nothing and catching it costs an unread item with nothing new in it.
    # It falls out the same way rather than being asked for - what the rule is
    # really protecting is that `moved_at` only goes forward, since an item
    # unread since an 11:00 CI failure would otherwise be marked read by a
    # deletion at 09:00, losing the change nobody looked at rather than the
    # comment nobody can.
    @test W.moved_stamp(old, row(; their_comment_at = "2026-09-12T08:30:00Z",
                                 human_comment_at = "2026-09-12T08:30:00Z"), now_) ==
          W.stamp(now_)

    # **A key that was not there before is not an event.** A row the bulk lanes
    # returned carries no reviews at all, so `review_at` arrives the day an
    # active lane claims it; a key added to `TRACK_KEYS` arrives on every row at
    # once. Either would read as movement on every row it lands on - which is
    # the wave that made `review_requested` have to be true-or-absent.
    husk = was(row(; review_at = nothing, their_head = nothing))
    @test W.moved_stamp(husk, row(), now_) == "2026-09-12T09:00:00Z"
    # Arriving with a *newer* time is a genuine first review, or a first
    # comment, and counts.
    @test W.moved_stamp(husk, row(; review_at = "2026-09-12T10:45:00Z"), now_) ==
          "2026-09-12T10:45:00Z"
    # The request that was a bool on the old row and is a time on the new one
    # is the same arrival: a request made before the item last moved is the
    # record catching up, and one made after it is the request you were never
    # told about while the bool was silent on a row that had already moved.
    bool_row = was(row(; review_requested = true))
    @test W.moved_stamp(bool_row, row(; review_requested = true,
                                      review_requested_at = "2026-09-12T08:45:00Z"), now_) ==
          "2026-09-12T09:00:00Z"
    @test W.moved_stamp(bool_row, row(; review_requested = true,
                                      review_requested_at = "2026-09-12T09:30:00Z"), now_) ==
          "2026-09-12T09:30:00Z"

    # The level decides which keys are asked about, here as everywhere else.
    # `loose` watches the human comment and not the CI; it does watch the head
    # since 2026-09-12, because a push on something you are watching loosely
    # is the item being active, which is what you are watching it to know.
    loose = was(row(; track = "loose"))
    @test W.moved_stamp(loose, row(; track = "loose", their_head = "ffff",
                                  head_at = "2026-09-12T10:30:00Z"), now_) ==
          "2026-09-12T10:30:00Z"
    @test W.moved_stamp(loose, row(; track = "loose",
                                  human_comment_at = "2026-09-12T09:55:00Z",
                                  their_comment_at = "2026-09-12T09:55:00Z"), now_) ==
          "2026-09-12T09:55:00Z"
    @test W.moved_stamp(loose, row(; track = "loose", ci_failed = true), now_) ==
          "2026-09-12T09:00:00Z"
end

@testset "your own keystrokes are not news" begin
    # One rule for everything the timeline says: an event is news when
    # somebody else was the actor, and - for the ones that name somebody -
    # when the somebody named is you.
    me = "vtjnash"
    ev(kind, at, actor; who = nothing, field = :requestedReviewer) =
        Dict{Symbol,Any}(:__typename => kind, :createdAt => at,
                         :actor => Dict{Symbol,Any}(:login => actor),
                         field => who === nothing ? nothing : Dict{Symbol,Any}(:login => who))
    req = ("ReviewRequestedEvent",)
    evs = [ev("ReviewRequestedEvent", "2026-09-01T10:00:00Z", "them"; who = me),
           ev("ReviewRequestedEvent", "2026-09-01T10:00:01Z", "them"; who = "other"),
           ev("ReviewRequestedEvent", "2026-09-01T10:00:02Z", me; who = me),
           ev("ReviewRequestRemovedEvent", "2026-09-02T10:00:00Z", "them"; who = me),
           ev("ReviewDismissedEvent", "2026-09-03T10:00:00Z", "them"),
           ev("MergedEvent", "2026-09-04T10:00:00Z", me),
           ev("ClosedEvent", "2026-09-04T10:00:00Z", me)]
    # Their request of you counts; their request of somebody else does not, one
    # you somehow made yourself is your own keystroke, and being let off is not
    # asked about - a kind this is not asked for is not a kind it sees.
    @test W.event_at(evs, me, req, :requestedReviewer) == "2026-09-01T10:00:00Z"
    # A dismissal names nobody, so only the actor is asked about.
    @test W.event_at(evs, me, ("ReviewDismissedEvent",), nothing) == "2026-09-03T10:00:00Z"
    @test W.event_at(evs, me, ("AssignedEvent",), :assignee) === nothing
    # You pressing merge on your own pull request is not somebody finishing it.
    @test W.event_at(evs, me, ("ClosedEvent", "MergedEvent", "ReopenedEvent"), nothing) === nothing
    @test W.event_at([ev("MergedEvent", "2026-09-05T10:00:00Z", "them")], me,
                     ("ClosedEvent", "MergedEvent", "ReopenedEvent"), nothing) == "2026-09-05T10:00:00Z"
    # A deleted account names nobody either - julia#62245 has one - and a row
    # with no timeline at all is a bulk row.
    @test W.event_at([ev("ReviewRequestedEvent", "2026-09-04T10:00:00Z", "them")], me,
                     req, :requestedReviewer) === nothing
    @test W.event_at(nothing, me, req, :requestedReviewer) === nothing

    # A comment the same way, carried across your own because
    # `comments(last: 1)` cannot see past it - and for the `loose` key, across
    # a bot's, which used to take the key to nothing and wake the item for
    # exactly the comment that level exists to ignore.
    r(at, by) = Dict{String,Any}("last_comment_at" => at, "last_comment_by" => by)
    old = (their_comment_at = "2026-09-01T00:00:00Z", human_comment_at = "2026-09-01T00:00:00Z")
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", "them"), old, me, "their_comment_at"; human = false) ==
          "2026-09-02T00:00:00Z"
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", me), old, me, "their_comment_at"; human = false) ==
          "2026-09-01T00:00:00Z"
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", "nanosoldier[bot]"), old, me, "their_comment_at"; human = false) ==
          "2026-09-02T00:00:00Z"
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", "nanosoldier[bot]"), old, me, "human_comment_at"; human = true) ==
          "2026-09-01T00:00:00Z"
    # Nothing to carry and nothing to see is nothing; every comment deleted
    # keeps what there was rather than going backwards.
    @test W.their_comment_at(r("2026-09-02T00:00:00Z", me), nothing, me, "their_comment_at"; human = false) === nothing
    @test W.their_comment_at(r(nothing, nothing), old, me, "human_comment_at"; human = true) ==
          "2026-09-01T00:00:00Z"
end

@testset "a push of your own is not news" begin
    # The sha is the exact answer to whether the branch moved; who put it there
    # decides whether that is worth being told. Your own push is the dashboard
    # reporting your own keystrokes back to you.
    me = "vtjnash"
    r(sha, by) = Dict{String,Any}("head_sha" => sha, "head_by" => by)
    @test W.their_head(r("aaa", "someone"), nothing, me) == "aaa"
    # Yours carries the previous value forward rather than clearing it, because
    # clearing would be a change like any other and the item would go unread for
    # the thing this exists to ignore.
    @test W.their_head(r("bbb", me), (their_head = "aaa",), me) == "aaa"
    # They push after you and it moves; you push after them and it does not
    # move back.
    @test W.their_head(r("ccc", "someone"), (their_head = "aaa",), me) == "ccc"
    @test W.their_head(r("ddd", me), (their_head = "ccc",), me) == "ccc"
    # A pull request only ever pushed to by you has nothing here at all, and
    # neither has an issue or a row no lane fetched commits for.
    @test W.their_head(r("bbb", me), nothing, me) === nothing
    @test W.their_head(Dict{String,Any}(), nothing, me) === nothing
end
