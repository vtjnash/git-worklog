# What the uppercase keys write, and which view each of them opens. None of
# it has ever been sent - see Infrastructure in TODO.md for the token.

"""The composer inside whatever was pushed.

A composer is drawn beside the thing it is about wherever the screen has room,
so what lands on the stack is the pair and not the box - and every assertion
below is about the box. `SPLIT_MIN` is 150 and these run at 160.
"""
composer(v) = v isa W.SideView ? v.inner : v

@testset "five remarks are one review" begin
    # GitHub's own answer to batching is a pending review: a draft that lives on
    # GitHub, is visible only to its author, and is submitted later as one
    # thing. Nothing here stores it, so quitting cannot lose it.
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true
    it = st.items[st.sel]
    st.batch = W.mkbatch(it.url, it.ref, "PRR_x", 3)
    # It is visible while it accumulates, in both places that say what is going
    # on: the footer count and the metadata pane.
    @test occursin("A review(3)", W.astrip(W.render(st, 160, 50)))
    @test any(l -> occursin("draft", l) && occursin("3 comments", l),
              W.astrip.(W.meta_lines(st, it, 50)))
    # And it belongs to one item, not to the browser.
    @test W.batch_of(st, it) !== nothing
    other = first(x for x in st.items if x.url != it.url)
    @test W.batch_of(st, other) === nothing

    # Walking away from it asks once. Moving within the same item does not -
    # `tab` changes pane, and `j` in the detail moves a cursor through a body.
    W.handle!(st, Int('\t'), ctrl)
    @test st.focus === :detail && isempty(ctrl.stack)
    W.handle!(st, Int('j'), ctrl)
    @test isempty(ctrl.stack)
    W.handle!(st, Int('\t'), ctrl)
    @test st.focus === :list && isempty(ctrl.stack)
    W.handle!(st, Int('j'), ctrl)
    v = last(ctrl.stack)
    @test v isa W.ConfirmView && v.title == "Draft review"
    @test any(n -> occursin("3 comments are written and not sent", n), v.notes)
    # `A` is the answer, because `A` is what submits a review from the item
    # itself: a question about a draft should not need a key of its own.
    @test occursin("A submits it now", v.hint)
    # Every other key leaves it where it is - it is durable, and this is a
    # reminder rather than a deadline. The draft is *kept*, not forgotten: this
    # program is the only thing that mentions it anywhere but the pull request
    # itself, so dropping it here is how one ends up remembered by nobody.
    @test W.handle!(v, Int('j'), ctrl) === :pop
    pop!(ctrl.stack)
    @test st.batch !== nothing && st.batch.asked
    st.status = ""                       # the status row is the keys row's own
    @test occursin("A review(3)", W.astrip(W.render(st, 160, 50)))   # still shown

    # `Esc` takes the move back. The question exists because the cursor walked
    # off the item, so the key that means "no" has to be able to undo the thing
    # it is saying no to - otherwise staying put means dismissing the box and
    # walking back by hand, past the item you just left.
    st.sel = findfirst(x -> x.url == it.url, st.items)
    st.batch = W.mkbatch(it.url, it.ref, "PRR_x", 3)
    W.handle!(st, Int('j'), ctrl)
    esc = last(ctrl.stack)
    @test esc isa W.ConfirmView && occursin("esc goes back to it", esc.hint)
    @test W.curl(st) != it.url                     # the move has happened
    @test W.handle!(esc, 27, ctrl) === :pop
    pop!(ctrl.stack)
    @test W.curl(st) == it.url                     # ...and been taken back
    # And the question is armed again, so stepping off asks a second time
    # rather than letting the draft leave in silence.
    @test !st.batch.asked
    W.handle!(st, Int('j'), ctrl)
    @test last(ctrl.stack) isa W.ConfirmView
    @test W.handle!(last(ctrl.stack), Int('j'), ctrl) === :pop
    pop!(ctrl.stack)

    # Having asked once, moving between other items asks nothing.
    W.handle!(st, Int('j'), ctrl)
    @test isempty(ctrl.stack) && st.batch.asked
    # Walking off it again is what re-arms the question, which is to say: going
    # back to the item is what says you are still working on it.
    st.sel = findfirst(x -> x.url == it.url, st.items)
    W.handle!(st, Int('j'), ctrl)
    @test last(ctrl.stack) isa W.ConfirmView
    empty!(ctrl.stack)
    @test st.batch !== nothing && st.batch.asked

    # Quitting asks its own question and asks it every time - being dismissed
    # once on the way past the item is not an answer about leaving. The draft is
    # a row in that question rather than a dialog in front of it.
    st.batch = W.mkbatch(it.url, it.ref, "PRR_x", 1; asked = true)
    st.sel = findfirst(x -> x.url == it.url, st.items)
    @test W.handle!(st, Int('q'), ctrl) === :ok
    v2 = last(ctrl.stack)
    @test v2 isa W.ConfirmView && v2.title == "Quit"
    @test any(n -> occursin("1 comment is written and not sent", n), v2.notes)
    # And `y` gets out, however often the draft has been mentioned before. This
    # is the fix: the draft question used to be asked in front of this one and
    # re-armed itself, so a held draft made quitting unreachable.
    @test W.handle!(v2, Int('y'), ctrl) === :quit
    # `A` submits instead, and goes to the verdict, which is where a draft is
    # sent from. It answers the question, so the box that asked it comes off.
    @test W.handle!(v2, Int('A'), ctrl) === :pop
    v3 = last(ctrl.stack)
    @test v3 isa W.ChooseView && occursin("draft review and its 1 comment", v3.note)
    # Including the way out of one that should never have been started.
    @test any(o -> o[2] == "DISCARD", v3.options)
    empty!(ctrl.stack)

    # A draft on an item this dashboard no longer carries is left alone rather
    # than offered against whatever happens to be first: submitting a review to
    # the wrong pull request is not a recoverable mistake. Neither question
    # mentions it, and quitting still works.
    st.batch = W.mkbatch("https://github.com/o/r/pull/9", "r#9", "PRR_y", 2)
    @test W.draft_answer(st, ctrl) === nothing
    @test !W.batch_prompt!(st, ctrl, "")
    @test isempty(ctrl.stack)
    W.quit_prompt!(st, ctrl)
    v4 = last(ctrl.stack)
    @test !any(n -> occursin("written and not sent", n), v4.notes)
    @test W.handle!(v4, Int('y'), ctrl) === :quit
    empty!(ctrl.stack)
    st.batch = nothing
end

@testset "a draft is remembered where GitHub will not keep it" begin
    # The batch is this session's; the mark is the program's. What reconciles
    # them is the metadata of the item on screen, which is the only place a
    # pending review can be seen at all - so it is also the only thing that can
    # notice one submitted from github.com since the mark was written.
    st = mkstate()
    it = st.items[st.sel]
    @test isempty(W.load_drafts())
    st.metakey = it.url
    st.metapending = schedule(Task(() -> (meta = (pending = "PRR_z",), checks = nothing)))
    wait(st.metapending)
    @test W.collect_meta!(st)
    # Found, marked, and adopted as the batch in hand - a draft from an earlier
    # session is a draft.
    @test haskey(st.drafts, it.url)
    @test st.batch !== nothing && st.batch.url == it.url && st.batch.review == "PRR_z"
    # And gone again, when the item says it is gone.
    st.metapending = schedule(Task(() -> (meta = (pending = "",), checks = nothing)))
    wait(st.metapending)
    @test W.collect_meta!(st)
    @test !haskey(st.drafts, it.url) && st.batch === nothing
    @test isempty(W.load_drafts())
end

@testset "the one toolbar button worth having" begin
    # A suggestion is a review action - GitHub applies the block as a commit -
    # and it is unusable without the current text of the lines in front of you.
    # The rest of a markdown toolbar inserts characters anybody can type.
    ctrl = W.Controller()
    got = Ref("")
    v = W.EditorView("Comment on a.jl:10-12", "against abc1234", t -> got[] = t;
                     suggest = "```suggestion\nctx\nadded\n```")
    @test occursin("^r suggestion", W.astrip(W.render(v, 90, 16)))
    W.handle!(v, 18, ctrl)                                  # ^r
    # An empty composer takes the block whole, with a line under it to say why.
    @test W.text(v) == "```suggestion\nctx\nadded\n```\n"
    @test v.buf.row == length(v.buf.lines) && v.buf.col == 1
    @test occursin("suggestion inserted", v.status)
    # And it is ordinary text from there: the editor knows nothing about what
    # the block is, only where it went.
    for c in "why not"; W.handle!(v, W.keycode(c), ctrl); end
    @test endswith(W.text(v), "```\nwhy not")
    # A second one lands under the first rather than inside it.
    W.handle!(v, 18, ctrl)
    @test count("```suggestion", W.text(v)) == 2
    @test !occursin("suggestionwhy", W.text(v))

    # Nowhere to put one is said rather than silently doing nothing.
    v2 = W.EditorView("Comment on julia#1", "the item itself", identity)
    @test !occursin("^r", W.astrip(W.render(v2, 90, 16)))
    W.handle!(v2, 18, ctrl)
    @test occursin("nothing to suggest", v2.status) && isempty(W.text(v2))
end

@testset "what c writes to" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    st.mode = :diff
    n = W.Node("a.jl  @@ 10,3 @@", " ctx\n-gone\n+added", :diff, true)
    merge!(n.meta, Dict{String,Any}("file" => "a.jl", "start" => 10, "count" => 3,
                                    "ostart" => 40, "ocount" => 2, "up" => 0, "down" => 0,
                                    "body" => " ctx\n-gone\n+added"))
    st.nodes = [n]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    iw = W.layout(160, 50, st.nmeta).riw

    # Header row, then one row per diff line.
    st.nrow = 2; @test W.hunk_line_at(st, 1, iw) == (10, "RIGHT")   # context
    st.nrow = 3; @test W.hunk_line_at(st, 1, iw) == (41, "LEFT")    # deletion
    st.nrow = 4; @test W.hunk_line_at(st, 1, iw) == (11, "RIGHT")   # addition
    st.nrow = 1; @test W.hunk_line_at(st, 1, iw) === nothing        # the header

    st.nrow = 4
    t = W.compose_target(st, iw)
    @test t[1] === :line
    @test (t[2].file, t[2].line, t[2].side) == ("a.jl", 11, "RIGHT")
    # One line is no range - but it is still a line, and `^r` fills in what is
    # on it: a suggestion replacing one line is the commonest kind there is.
    @test t[2].start === nothing && t[2].text == ["added"]
    st.nrow = 2
    @test W.compose_target(st, iw)[2].text == ["ctx"]
    # A deleted line has nothing to replace, so there is nothing to suggest.
    st.nrow = 3
    @test isempty(W.suggestion(W.compose_target(st, iw)[2].text))
    st.nrow = 4

    # Dragging over the hunk is already a selection - it is how `y` copies
    # several rows - so a range comment needs no new gesture, only for `c` to
    # look at what is selected.
    st.sela, st.selb = 2, 4
    t2 = W.compose_target(st, iw)[2]
    @test (t2.start, t2.line, t2.side) == (10, 11, "RIGHT")
    # What it would replace: the new side of those lines, without the marker
    # column and without the line that is being deleted.
    @test t2.text == ["ctx", "added"]
    @test W.suggestion(t2.text) == "```suggestion\nctx\nadded\n```"
    @test isempty(W.suggestion(String[]))
    # A selection that runs off the end of the hunk still says which lines of
    # it were meant.
    st.sela, st.selb = 1, 99
    t3 = W.compose_target(st, iw)[2]
    @test (t3.start, t3.line) == (10, 11)
    st.sela = 0; st.selb = 0
    # A review comment answers with its own thread instead.
    st.nodes = [W.Node("alice  2026-01-01", "a remark", :md, true)]
    st.nodes[1].meta["comment_id"] = 4242
    st.nrow = 1
    @test W.compose_target(st, iw) == (:reply, 4242)
    # Anything else is the item as a whole.
    st.nodes = [W.Node("prose", "text", :md, true)]
    @test W.compose_target(st, iw) == (:item, nothing)
end

@testset "the write keys open the right views" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller()
    W.push_view!(ctrl, st)

    W.handle!(st, Int('C'), ctrl)          # capitals change things
    # 160 columns is room for both, so the composer arrives beside the diff it
    # is about rather than over it. `composer` is what reaches through the pair.
    @test last(ctrl.stack) isa W.SideView
    @test composer(last(ctrl.stack)) isa W.EditorView
    @test occursin(st.items[st.sel].ref, composer(last(ctrl.stack)).title)
    pop!(ctrl.stack)

    # A deleted line has nowhere to post yet, and says so instead of opening.
    st.mode = :diff
    n = W.Node("a.jl", " ctx\n-gone", :diff, true)
    merge!(n.meta, Dict{String,Any}("file" => "a.jl", "start" => 10, "count" => 2,
                                    "ostart" => 40, "ocount" => 2, "up" => 0, "down" => 0))
    st.nodes = [n]; st.nrow = 3
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    W.handle!(st, Int('C'), ctrl)
    @test length(ctrl.stack) == 1 && occursin("deleted line", st.status)

    # ...and lowercase still only looks: `c` is the checks pane now.
    W.handle!(st, Int('c'), ctrl)
    @test st.mode === :checks && length(ctrl.stack) == 1

    # Review: the picker opens, and picking pushes the composer *and keeps it* -
    # the picker pops itself, not whatever ended up on top.
    st.mode = :comments
    W.handle!(st, Int('A'), ctrl)
    ch = last(ctrl.stack)
    @test ch isa W.ChooseView
    @test [o[2] for o in W.shown(ch)] == ["APPROVE", "REQUEST_CHANGES", "COMMENT"]
    @test W.handle!(ch, 13, ctrl) === :pop
    at = findlast(x -> x === ch, ctrl.stack); deleteat!(ctrl.stack, at)   # what run! does
    # The verdict is a question and stays a question; the body it opens is a
    # page to write on, and goes beside the diff with the other two.
    @test composer(last(ctrl.stack)) isa W.EditorView
    @test composer(last(ctrl.stack)).allow_empty                    # approve needs no words
    pop!(ctrl.stack)

    W.handle!(st, Int('L'), ctrl)
    lv = last(ctrl.stack)
    @test lv isa W.ChooseView && !isempty(W.shown(lv))
    @test all(startswith(o[1], "[x] ") || startswith(o[1], "[ ] ") for o in W.shown(lv))
end

@testset "merging, on the message GitHub would have written" begin
    # The state is put in the cache rather than fetched, which is the whole of
    # what makes this testable without a network: `merge_state` reads a hit back
    # through exactly the shape a fetch writes, so what the composer sees here
    # is what it would see off the wire. Nothing below sends anything - the last
    # question is answered with `esc` every time, and see Infrastructure.
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller(); W.push_view!(ctrl, st)
    it = st.items[st.sel]
    text2 = Dict{String,Any}(
        "SQUASH" => Dict{String,Any}("headline" => "a fix (#7)",
                                     "body" => "why it is a fix"),
        "MERGE" => Dict{String,Any}("headline" => "Merge pull request #7 from o/b",
                                    "body" => "a fix"),
        "REBASE" => Dict{String,Any}("headline" => "", "body" => ""))
    put(; methods = ["SQUASH", "MERGE"], status = "CLEAN", state = "OPEN") =
        W.cache_put(string("merge:", it.url), Dict{String,Any}(
            "id" => "PR_x", "oid" => "abc1234def", "state" => state, "draft" => false,
            "mergeable" => "MERGEABLE", "status" => status, "base" => "master",
            "commits" => 3, "methods" => methods,
            "text" => Dict{String,Any}(m => text2[m] for m in methods)))

    # `M` opens the composer straight away. No picker in front of it: the
    # operation and the message it decides belong on one screen.
    put()
    W.handle!(st, Int('M'), ctrl)
    ev = composer(last(ctrl.stack))
    @test ev isa W.EditorView
    @test ev.title == string("Merge ", it.ref)
    # Squash, because this program prefers it where the repo allows it - not
    # because GitHub said so, which it cannot: `viewerDefaultMergeMethod` is
    # what *you* last merged with there. See TODO.md.
    @test W.text(ev) == "a fix (#7)\n\nwhy it is a fix"
    # The note is the whole of what is about to happen, so that finding out
    # never means reading a refusal.
    @test occursin("squash and merge", ev.note)
    @test occursin("3 commits into master", ev.note)
    @test occursin("clean", ev.note)
    @test occursin("^x: create a merge commit", ev.note)
    @test occursin("^x cycles", W.astrip(W.render(ev, 90, 20)))

    # `tab` is the choice. Silently, because the message in the buffer is still
    # the one this program put there a keystroke ago.
    @test W.handle!(ev, W.C_X, ctrl) === :ok
    @test W.text(ev) == "Merge pull request #7 from o/b\n\na fix"
    # The note goes with the buffer, because it is the only thing on this screen
    # that says which merge `^s` would send.
    @test occursin("create a merge commit · 3 commits into master", ev.note)
    @test occursin("^x: squash and merge", ev.note)
    @test occursin("now: create a merge commit", ev.status)
    @test length(ctrl.stack) == 2                       # no question asked
    # ...and round again, since one key can only say forwards. Two operations
    # here, so the second press is the way back.
    @test W.handle!(ev, W.C_X, ctrl) === :ok
    @test W.text(ev) == "a fix (#7)\n\nwhy it is a fix"
    @test occursin("squash and merge · 3 commits into master", ev.note)

    # Words that were typed exist in this buffer and in no other place, so the
    # key that would replace them asks first - the same rule `esc` follows.
    for c in " and why"; W.handle!(ev, W.keycode(c), ctrl); end
    @test endswith(W.text(ev), "and why")
    W.handle!(ev, W.C_X, ctrl)
    q = last(ctrl.stack)
    @test q isa W.ConfirmView && q.title == "Change the operation?"
    # Declining leaves the operation alone as well as the words: "no" to what
    # `tab` was going to do is no to the whole of it.
    @test W.handle!(q, Int('n'), ctrl) === :pop
    pop!(ctrl.stack)
    @test endswith(W.text(ev), "and why")
    W.handle!(ev, W.C_X, ctrl)
    q2 = last(ctrl.stack)
    @test W.handle!(q2, Int('y'), ctrl) === :pop
    pop!(ctrl.stack)
    @test W.text(ev) == "Merge pull request #7 from o/b\n\na fix"

    # `^s` does not merge. It asks, and the question can say what the composer
    # could not until the message was written.
    @test W.handle!(ev, W.C_S, ctrl) === :pop
    deleteat!(ctrl.stack, findlast(x -> composer(x) === ev, ctrl.stack))
    cv = last(ctrl.stack)
    @test cv isa W.ConfirmView && cv.title == string("Merge ", it.ref, "?")
    @test any(n -> occursin("create a merge commit", n) &&
                   occursin("3 commits into master", n), cv.notes)
    @test any(n -> occursin("Merge pull request #7", n), cv.notes)
    @test occursin("esc goes back to the message", cv.hint)
    # And `esc` goes back to it with the words still in it. A question that cost
    # you what you had written would be the worse mistake of the two.
    @test W.handle!(cv, 27, ctrl) === :pop
    # By identity and not off the top, which is what `run!` does and what this
    # answer needs: it put the composer back before saying it was finished.
    deleteat!(ctrl.stack, findlast(x -> x === cv, ctrl.stack))
    back = composer(last(ctrl.stack))
    @test back isa W.EditorView && W.text(back) == "Merge pull request #7 from o/b\n\na fix"
    empty!(ctrl.stack); W.push_view!(ctrl, st)

    # A rebase has no message at all - GitHub answers with two empty strings for
    # one even where it is allowed, because the commits are replayed as they
    # were written. So the composer empties, says why, and lets `^s` through.
    put(methods = ["REBASE"])
    W.handle!(st, Int('M'), ctrl)
    rv = composer(last(ctrl.stack))
    @test isempty(W.text(rv)) && rv.allow_empty
    @test occursin("no message to write", rv.note)
    # One way to merge is no choice, so `tab` is not bound at all.
    @test rv.cycle === nothing
    @test !occursin("^x cycles", W.astrip(W.render(rv, 90, 20)))
    @test !occursin("^x:", rv.note)
    # Onto and not into, in the composer and in the question alike: a rebase is
    # the one operation that makes no commit on the base branch.
    @test occursin("3 commits onto master", rv.note)
    @test W.handle!(rv, W.C_S, ctrl) === :pop         # nothing written, and allowed
    deleteat!(ctrl.stack, findlast(x -> composer(x) === rv, ctrl.stack))
    rc = last(ctrl.stack)
    @test any(n -> occursin("3 commits onto master", n), rc.notes)
    @test any(n -> occursin("replayed as they were written", n), rc.notes)
    @test !any(n -> occursin("“", n), rc.notes)       # there is no message to quote
    empty!(ctrl.stack); W.push_view!(ctrl, st)

    # What GitHub would refuse is said instead of attempted, because a refusal
    # arrives after the message has been written rather than instead of it.
    for (state, said) in (("MERGED", "is already merged"), ("CLOSED", "is closed"))
        put(state = state)
        W.handle!(st, Int('M'), ctrl)
        @test length(ctrl.stack) == 1 && occursin(said, st.status)
    end
    put(methods = String[])
    W.handle!(st, Int('M'), ctrl)
    @test length(ctrl.stack) == 1 && occursin("no way to merge", st.status)

    # An issue has nothing to merge, and neither has an adopted branch.
    iss = findfirst(x -> !x.is_pr, st.items)
    if iss !== nothing
        st.sel = iss
        W.handle!(st, Int('M'), ctrl)
        @test length(ctrl.stack) == 1 && occursin("not a pull request", st.status)
    end
    empty!(ctrl.stack)
end

@testset "a commit message is one thing to write and two to send" begin
    # GitHub stores a headline and a body; git has always taken both from one
    # text split at the first blank line, which is what anybody actually writes.
    @test W.merge_split("just a headline") == ("just a headline", "")
    @test W.merge_split("head\n\nbody\n\nmore") == ("head", "body\n\nmore")
    @test W.merge_split("") == ("", "")
    # A single newline is not the separator - it is a wrapped headline, which is
    # git's reading of the same bytes.
    @test W.merge_split("head\nstill head") == ("head\nstill head", "")
    @test W.merge_split("  head  \n\n  body  ") == ("head", "body")

    # And the note is `mergeStateStatus`, which knows more than `mergeable`
    # does: nothing conflicts here and it still cannot be merged.
    ms(; status = "CLEAN", mergeable = "MERGEABLE", draft = false) =
        (draft = draft, status = status, mergeable = mergeable, base = "main")
    @test W.merge_note(ms()) == "clean"
    @test W.merge_note(ms(status = "BEHIND")) == "behind main"
    @test occursin("required", W.merge_note(ms(status = "BLOCKED")))
    @test occursin("conflicts with main", W.merge_note(ms(status = "DIRTY")))
    @test occursin("none of them required", W.merge_note(ms(status = "UNSTABLE")))
    @test occursin("draft", W.merge_note(ms(draft = true)))
    # `UNKNOWN` is GitHub still working it out, which it does lazily on being
    # asked - so `mergeable` is the second opinion rather than nothing at all.
    @test W.merge_note(ms(status = "UNKNOWN")) == "mergeable"
    @test occursin("conflicts", W.merge_note(ms(status = "UNKNOWN",
                                                mergeable = "CONFLICTING")))
    @test occursin("still working", W.merge_note(ms(status = "UNKNOWN",
                                                    mergeable = "UNKNOWN")))
end
