# What the uppercase keys write, and which view each of them opens. None of
# it has ever been sent - see Infrastructure in TODO.md for the token.

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
    @test v isa W.ChooseView && occursin("Draft review on", v.title)
    @test occursin("3 comments are written and not sent", v.note)
    # Taking no for an answer leaves it where it is - it is durable, and this is
    # a reminder rather than a deadline. The draft is *kept*, not forgotten:
    # this program is the only thing that mentions it anywhere but the pull
    # request itself, so dropping it here is how one ends up remembered by
    # nobody.
    v.onpick(:no); pop!(ctrl.stack)
    @test st.batch !== nothing && st.batch.asked
    @test occursin("draft kept", st.status) && occursin(it.ref, st.status)
    st.status = ""                       # the status row is the keys row's own
    @test occursin("A review(3)", W.astrip(W.render(st, 160, 50)))   # still shown

    # Having answered once, moving between other items asks nothing.
    W.handle!(st, Int('j'), ctrl)
    @test isempty(ctrl.stack) && st.batch.asked
    # Walking off it again is what re-arms the question, which is to say: going
    # back to the item is what says you are still working on it.
    st.sel = findfirst(x -> x.url == it.url, st.items)
    W.handle!(st, Int('j'), ctrl)
    @test last(ctrl.stack) isa W.ChooseView
    last(ctrl.stack).onpick(:no); pop!(ctrl.stack)
    @test st.batch !== nothing && st.batch.asked

    # `q` asks whatever has been answered before - it is the last moment there
    # is - and quits on the next press.
    st.batch = W.mkbatch(it.url, it.ref, "PRR_x", 1; asked = true)
    st.sel = findfirst(x -> x.url == it.url, st.items)
    @test W.handle!(st, Int('q'), ctrl) === :ok
    v2 = last(ctrl.stack)
    @test v2 isa W.ChooseView && occursin("1 comment is", v2.note)
    # Saying yes goes to the verdict, which is where a draft is sent from.
    v2.onpick(:yes)
    v3 = last(ctrl.stack)
    @test v3 isa W.ChooseView && occursin("draft review and its 1 comment", v3.note)
    # Including the way out of one that should never have been started.
    @test any(o -> o[2] == "DISCARD", v3.options)
    empty!(ctrl.stack)
    st.batch = nothing
    @test W.handle!(st, Int('q'), ctrl) === :quit

    # A draft on an item this dashboard no longer carries is left alone rather
    # than offered against whatever happens to be first: submitting a review to
    # the wrong pull request is not a recoverable mistake.
    st.batch = W.mkbatch("https://github.com/o/r/pull/9", "r#9", "PRR_y", 2)
    @test !W.batch_prompt!(st, ctrl, "")
    @test isempty(ctrl.stack)
    st.batch = nothing
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
    @test v.row == length(v.lines) && v.col == 1
    @test occursin("suggestion inserted", v.status)
    # And it is ordinary text from there: the editor knows nothing about what
    # the block is, only where it went.
    for c in "why not"; W.handle!(v, Int(c), ctrl); end
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
    @test last(ctrl.stack) isa W.EditorView
    @test occursin(st.items[st.sel].ref, last(ctrl.stack).title)
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
    @test last(ctrl.stack) isa W.EditorView
    @test last(ctrl.stack).allow_empty                              # approve needs no words
    pop!(ctrl.stack)

    W.handle!(st, Int('L'), ctrl)
    lv = last(ctrl.stack)
    @test lv isa W.ChooseView && !isempty(W.shown(lv))
    @test all(startswith(o[1], "[x] ") || startswith(o[1], "[ ] ") for o in W.shown(lv))
end
