# `render` is pure, so the whole screen is checked by construction: every row
# exactly `w` wide, every click landing where it looks, every copy unwrapped.

@testset "frame geometry" begin
    # Over the real snapshot, because what is being checked is the geometry: a
    # hand-built item list would not exercise the widths that actual titles do.
    for (w, h) in ((80, 24), (110, 40), (160, 50), (100, 12), (200, 60), (72, 8))
        st = mkstate()
        f = W.render(st, w, h)
        ls = split(f, "\n")
        @test length(ls) == h
        @test all(W.awidth(l) == w for l in ls)
    end
end

@testset "a hyperlink is not somewhere to write another one" begin
    # Every comment header is an OSC 8 hyperlink to its own permalink, and a url
    # written in one comment is very often the permalink of another - nanosoldier
    # replies with a link to the `runbenchmarks()` comment that asked for the
    # run. `linkify` used to `replace` over the whole finished frame, so it put a
    # second `\e]8;;` inside the first, which terminates the outer sequence early
    # and prints the rest of the url as literal characters nothing has measured:
    # a row 224 columns wide in a 150-column terminal.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    u = "https://github.com/JuliaLang/julia/pull/62396#issuecomment-5073694899"
    asked = W.Node("vtjnash  2026-07-24T19:39   @nanosoldier `runbenchmarks()`",
                   "", :md, false)
    asked.meta["url"] = u                       # its own permalink, as a header link
    answered = W.Node("nanosoldier  2026-07-25T03:37   The benchmark job",
                      string("The benchmark job [you requested](", u, ") is done."),
                      :md, false)
    answered.urls = [u]                         # ...and the same url in the body
    st.nodes = [asked, answered]
    for open in (false, true)
        answered.open = open
        f = W.render(st, 150, 40)
        for l in split(f, "\n")
            @test W.awidth(l) == 150
        end
        @test !occursin("\e]8;;\e]8;;", f)      # never one inside another
    end
    # And the substitution it was there to make still happens: a url in the body
    # is still a link, it is only the sequences around it that are left alone.
    @test occursin(string("\e]8;;", u, "\e\\\e[4m", u),
                   W.render(st, 150, 40))

    # The same tearing from the other direction. The link list is one entry per
    # url per *node*, so a url cited in four comments - nanosoldier posts one
    # report link per run - arrives here four times, and a loop of `replace`s
    # reads its own output: a url short enough to be shown whole is its own
    # display form, so the second pass found it inside the payload the first had
    # just written and hyperlinked that.
    short = W.shortlink(u, 60)
    line = string("see ", short, " twice")
    @test W.linkify(line, [short => u]) == W.linkify(line, [short => u, short => u])
    @test W.awidth(W.linkify(line, [short => u, short => u])) == W.awidth(line)
    # Longest first, so a display form that is the head of another cannot take
    # the match from it and send the reader somewhere else.
    a, b = "https://x.invalid/a", "https://x.invalid/ab"
    out = W.linkify("see https://x.invalid/ab here", [a => a, b => b])
    @test occursin(string("\e]8;;", b, "\e\\"), out)
    @test !occursin(string("\e]8;;", a, "\e\\"), out)
end

@testset "a click on a url copies it" begin
    # Owning the mouse is what makes this possible: a link can be acted on here
    # rather than handed to a terminal that may or may not know what an OSC 8
    # hyperlink is. `y` and this are the same copy.
    st = mkstate()
    u = "https://github.com/JuliaLang/julia/issues/18004#issuecomment-372112478"
    # A footnote row shows an elided url and carries the whole one in its
    # source, so anywhere on it is that link.
    fn = W.Row(1, false, string("[1] ", W.shortlink(u, 30)), string("[1] ", u), 0)
    @test W.link_at(st, fn, 1) == u
    @test W.link_at(st, fn, 20) == u
    # A url in prose is where it prints, and a click has to land inside it -
    # the rest of the row is text somebody may want to select instead.
    line = "see https://example.com/a here"
    r = W.Row(1, false, line, line, 0)
    @test W.link_at(st, r, 6) == "https://example.com/a"
    @test W.link_at(st, r, 4) == ""                 # the space before it
    @test W.link_at(st, r, 27) == ""                # "here"
    # Wrapping cuts a long url in half, and half a url is useless pasted - so
    # the answer comes off the written line rather than off the row.
    cut = "the fix is in https://github.com/JuliaLang/"
    r2 = W.Row(1, false, cut, string(cut, "julia/pull/17113 which landed"), 0)
    @test W.link_at(st, r2, 20) == "https://github.com/JuliaLang/julia/pull/17113"
    # Prose that merely contains a slash is not a link.
    r3 = W.Row(1, false, "and/or something", "and/or something", 0)
    @test isempty(W.link_at(st, r3, 4))

    # End to end, through the geometry a real click goes through.
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st2 = mkstate()
    st2.nodes = [W.Node("someone  2026-09-02", "see https://example.com/x here", :md, true)]
    st2.loaded = string(st2.items[st2.sel].url, ":", st2.mode)
    W.render(st2, 160, 50)
    L = W.layout(160, 50, st2.nmeta)
    ctrl = W.Controller()
    rs = W.rows(st2.nodes, L.riw)
    i = findfirst(x -> occursin("https://example.com/x", W.astrip(x.text)), rs)
    @test i !== nothing
    c = first(findfirst("https://", W.astrip(rs[i].text))) + 4
    W.onmouse!(st2, W.MouseEvent(:press, 0, L.rx + c, L.ry + 1 + st2.hdr + i - 1, 0), ctrl)
    @test occursin("copied", st2.status) && occursin("example.com/x", st2.status)
    # Copying is not the start of a selection: a drag from here selects nothing.
    @test st2.anchor == 0
    # And a click on the prose beside it still starts one, as it always did.
    st2.status = ""
    W.onmouse!(st2, W.MouseEvent(:press, 0, L.rx + 2, L.ry + 1 + st2.hdr + i - 1, 0), ctrl)
    @test isempty(st2.status) && st2.anchor == i
end

@testset "click maps to the row under it" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    W.render(st, 160, 50)
    L = W.layout(160, 50, st.nmeta)
    ctrl = W.Controller()

    # A click on the list pane's third content row selects the second item: the
    # import row is drawn in front of item 1, so the drawn rows are one ahead
    # of the item indices.
    press(x, y) = W.onmouse!(st, W.MouseEvent(:press, 0, x, y, 0), ctrl)
    press(L.lx + 3, L.ly + 3)
    @test st.focus === :list && st.sel == st.top + 1
    # And the first row is that import row, which is selection zero.
    press(L.lx + 3, L.ly + 1)
    @test st.focus === :list && st.sel == 0
    press(L.lx + 3, L.ly + 2)
    @test st.sel == 1

    # Clicking the detail pane's first content row lands on the first title row,
    # which is header, not content - so nrow stays put and focus moves.
    st2 = mkstate()
    W.render(st2, 160, 50)
    L = W.layout(160, 50, st2.nmeta)
    press2(x, y) = W.onmouse!(st2, W.MouseEvent(:press, 0, x, y, 0), ctrl)
    press2(L.rx + 10, L.ry + 1 + st2.hdr)          # first node row (its header)
    @test st2.focus === :detail && st2.nrow == 1

    # Column 1-2 of a header row is the fold marker.
    @test st2.nodes[1].open
    press2(L.rx + 2, L.ry + 1 + st2.hdr)
    @test !st2.nodes[1].open
    press2(L.rx + 2, L.ry + 1 + st2.hdr)
    @test st2.nodes[1].open

    # Clicking past the end of the content, or on a border, changes nothing.
    W.render(st2, 160, 50)
    before = (st2.nrow, st2.sel, st2.focus)
    press2(L.rx + 10, L.ry + L.rh - 3)      # blank rows below the last node
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx, L.ry + 4)                  # the pane border
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx + 10, 1)                    # the title bar
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx + 10, 50)                   # the footer
    @test (st2.nrow, st2.sel, st2.focus) == before
end

@testset "drag selects, and the copy is unwrapped" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    W.render(st, 160, 50)
    L = W.layout(160, 50, st.nmeta)
    ctrl = W.Controller()
    y0 = L.ry + 1 + st.hdr
    W.onmouse!(st, W.MouseEvent(:press, 0, L.rx + 10, y0 + 1, 0), ctrl)
    W.onmouse!(st, W.MouseEvent(:drag, 0, L.rx + 10, y0 + 3, 0), ctrl)
    W.onmouse!(st, W.MouseEvent(:release, 0, L.rx + 10, y0 + 3, 0), ctrl)
    @test W.selrange(st) == (2, 4)

    txt = W.selection_text(st, L.riw)
    @test !isempty(txt)
    @test !occursin('\e', txt)                       # no escapes in the paste
    # The wrapped paragraph comes back as the one line it was written as.
    @test occursin("A paragraph long enough that it has to be wrapped across several rows", txt)
    @test length(split(txt, "\n")) < 4               # fewer lines out than rows in

    # A code block is a box, and Term pads a box to the width it is given - so
    # the wide render used for the source map must never reach a copy.
    n = W.Node("h", "prose\n\n```\nshort line\nanother\n```\n", :md, true)
    W.nodelines(n, 60)
    @test maximum(W.awidth(sr) for (_, sr) in n.srcs) < 120

    # The selection survives a redraw and shows in the pane title.
    f = W.render(st, 160, 50)
    @test occursin("3 selected", f)
    @test W.selrange(st) == (2, 4)

    # Moving the cursor drops it; y with nothing selected still copies a URL.
    W.handle!(st, Int('j'), ctrl)
    @test W.selrange(st) === nothing

    # The keyboard half of the same thing, which is what the mouse could do and
    # nothing else could: shift on the arrows, and `J`/`K` under the hand that
    # is already on `j`/`k`.
    st.focus = :detail
    st.nrow = 2
    W.handle!(st, Int('J'), ctrl)
    @test W.selrange(st) == (2, 3) && st.nrow == 3
    W.handle!(st, W.K_SDOWN, ctrl)
    @test W.selrange(st) == (2, 4) && st.nrow == 4
    # Back through the anchor and out the other side, the way a drag does.
    for _ in 1:4; W.handle!(st, Int('K'), ctrl); end
    @test W.selrange(st) == (1, 2) && st.nrow == 1
    @test occursin("rows selected", st.status)
    # An unshifted arrow still drops it.
    W.handle!(st, W.K_DOWN, ctrl)
    @test W.selrange(st) === nothing
    # In the list there is no selection to extend, so they are the arrows.
    st.focus = :list
    was = st.sel
    W.handle!(st, W.K_SDOWN, ctrl)
    @test st.sel == was + 1 && W.selrange(st) === nothing
end

@testset "a long header wraps instead of being cut" begin
    long = "nalimilan  2018-03-16T21:13   Sorry, I do not really understand your example"
    n = W.Node(long, "body text", :md, true)
    nested = W.Node("a nested header long enough that it will not fit either", "b", :md, true, 1)

    for w in (30, 40, 60, 96)
        rs = W.rows([n, nested], w)
        @test all(W.awidth(r.text) <= w for r in rs)      # nothing overflows
        hdr = [r for r in rs if r.node == 1 && r.header]
        # Every word of the header survives somewhere.
        joined = replace(W.astrip(join([r.text for r in hdr], " ")), r"[─]+" => "")
        @test all(occursin(word, joined) for word in split(long))
        @test !occursin("…", joined)                      # not truncated
        @test hdr[1].part == 0 && all(r.part == 1 for r in hdr[2:end])
        @test occursin("▾", W.astrip(hdr[1].text))
        length(hdr) > 1 && @test !any(occursin("▾", W.astrip(r.text)) for r in hdr[2:end])
    end
    @test length([r for r in W.rows([n, nested], 30) if r.node == 1 && r.header]) > 1
    @test length([r for r in W.rows([n, nested], 200) if r.node == 1 && r.header]) == 1

    # The things that assumed one row per header still find the first one.
    st = mkstate()
    st.nodes = [n, nested]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    rs = W.rows(st.nodes, 40)
    @test W.headerrow(st, 1, 40) == 1
    st.nrow = 1
    W.jumpnode(st, 1, 40)
    @test rs[st.nrow].node == 2 && rs[st.nrow].part == 0   # skips continuations
end

@testset "folding takes what is nested under it" begin
    ns = [W.Node("comment", "body", :md, true), W.Node("folded", "hidden", :md, true, 1),
          W.Node("deeper", "also hidden", :md, true, 2), W.Node("sibling", "shown", :md, true)]
    # Eight rows of content and one blank, which is the gap above the second
    # top-level header: the rule it draws needs something to be a rule under.
    rs0 = W.rows(ns, 60)
    @test length(rs0) == 9
    @test count(r -> isempty(W.astrip(r.text)), rs0) == 1
    # And it is a header continuation, so nothing that counts a node's body rows
    # counts the spacing it is drawn with.
    blank = first(r for r in rs0 if isempty(W.astrip(r.text)))
    @test blank.header && blank.part == 1 && isempty(blank.src)
    # A top-level header carries a rule out to the pane edge; ignore it here.
    derule(x) = String(rstrip(replace(W.astrip(x), r"[─ ]+$" => "")))
    ns[1].open = false
    shown = [derule(r.text) for r in W.rows(ns, 60)]
    @test shown == ["▸ comment", "", "▾ sibling", "shown"]
    ns[1].open = true; ns[2].open = false
    shown = [derule(r.text) for r in W.rows(ns, 60)]
    @test !any(occursin("deeper", x) for x in shown)     # the run below it goes too
    @test any(occursin("sibling", x) for x in shown)     # but not its uncle

    # The rule runs to the pane edge on a top-level header and not on a nested
    # one, which is what separates one comment from the next.
    ns[1].open = true; ns[2].open = true
    rs = W.rows(ns, 60)
    top = first(r for r in rs if occursin("comment", W.astrip(r.text)))
    nested = first(r for r in rs if occursin("folded", W.astrip(r.text)))
    @test W.awidth(top.text) == 60
    @test !occursin("─", W.astrip(nested.text))
end

@testset "review comments land on their hunk" begin
    hunk(file, start, count, ostart = start, ocount = count) = begin
        n = W.Node("$file  @@ $start,$count @@", "-old\n+new", :diff, true)
        merge!(n.meta, Dict{String,Any}("file" => file, "start" => start, "count" => count,
                                        "ostart" => ostart, "ocount" => ocount,
                                        "body" => "-old\n+new", "up" => 0, "down" => 0))
        n
    end
    cmt(id, path, line; reply = nothing, side = "RIGHT", who = "alice") =
        Dict{String,Any}("id" => id, "path" => path, "line" => line, "side" => side,
                         "in_reply_to_id" => reply, "body" => "a remark",
                         "user" => Dict{String,Any}("login" => who),
                         "created_at" => "2026-08-01T10:00:00Z")

    hs = [hunk("a.jl", 10, 5), hunk("b.jl", 100, 3)]
    out = W.attach_comments(copy(hs), [cmt(1, "a.jl", 12), cmt(2, "a.jl", 12; reply = 1),
                                       cmt(3, "b.jl", 101)], "http://x")
    hdr(n) = W.astrip(n.header)
    @test occursin("💬1", hdr(out[1]))                    # the hunk says so
    @test hdr(out[2]) == "alice  2026-08-01T10:00   a remark" && out[2].depth == 1
    # The peek is what makes a folded comment readable, and what makes an open
    # one say itself twice - so open, the header is the byline alone and the
    # words are on the row underneath it, once.
    open_ = W.astrip(first(r.text for r in W.rows(out, 90) if r.node == 2))
    @test occursin("alice  2026-08-01T10:00", open_) && !occursin("a remark", open_)
    out[2].open = false
    @test occursin("a remark",
                   W.astrip(first(r.text for r in W.rows(out, 90) if r.node == 2)))
    out[2].open = true
    @test out[3].depth == 2                               # the reply nests under it
    @test occursin("💬1", hdr(out[4]))                    # and the second hunk

    # Out of range, wrong file, and outdated all go to the same folded bucket.
    out = W.attach_comments(copy(hs), [cmt(1, "a.jl", 999), cmt(2, "z.jl", 3),
                                       cmt(3, "a.jl", nothing)], "http://x")
    bucket = findfirst(n -> occursin("since changed", hdr(n)), out)
    @test bucket !== nothing
    @test !out[bucket].open                               # folded, so they are away
    @test count(n -> n.depth == 1, out[bucket:end]) == 3
    @test !any(occursin("a remark", W.astrip(r.text)) for r in W.rows(out, 90))

    # A comment on a deleted line is anchored to the old side of the hunk.
    hs2 = [hunk("a.jl", 10, 5, 40, 6)]
    out = W.attach_comments(copy(hs2), [cmt(1, "a.jl", 42; side = "LEFT")], "http://x")
    @test occursin("💬1", hdr(out[1])) && length(out) == 2

    # And the hunk says *where* it is being talked about, not only that it is:
    # the row each thread hangs off carries the same mark its header counts.
    # `-old` is the first line of this hunk's body and is old line 40; `+new` is
    # the second and is new line 10.
    marked = W.attach_comments(copy([hunk("a.jl", 10, 2, 40, 2)]),
                               [cmt(1, "a.jl", 40; side = "LEFT"),
                                cmt(2, "a.jl", 10), cmt(3, "a.jl", 10; reply = 2)],
                               "http://x")
    @test W.hunk_marks(marked[1]) == Dict(1 => (1, 0), 2 => (1, 0))
    drawn = [W.astrip(r.text) for r in W.rows(marked, 70) if r.node == 1 && !r.header]
    @test drawn == ["-old  💬", "+new  💬"]
    # Two threads on the hunk, one on each of its two lines - and the reply is
    # not a third of either: the thread is what hangs off a line, which is what
    # the header has always counted. A lone thread's mark carries no number,
    # since `💬1` is `💬` said twice.
    @test occursin("💬2", hdr(marked[1]))
    # The mark is drawn on the row and is not part of the diff, so a copy of the
    # row is the line as it was written.
    @test [r.src for r in W.rows(marked, 70) if r.node == 1 && !r.header] ==
          ["-old", "+new"]
    # A settled thread is marked the way the header marks it.
    done_ = W.attach_comments(copy([hunk("a.jl", 10, 2, 40, 2)]),
                              [cmt(1, "a.jl", 10)], "http://x", Set([1]))
    @test W.hunk_marks(done_[1]) == Dict(2 => (0, 1))
    @test occursin("✓", [W.astrip(r.text) for r in W.rows(done_, 70) if r.node == 1][3])
    # `[`/`]` widens the hunk upwards, which moves every row and no line number
    # - so the marks are kept as line numbers and worked out against the hunk as
    # it now stands. Two rows of context above turn row 2 into row 4.
    wide = marked[1]
    wide.raw = string(" ctx\n ctx\n", wide.meta["body"])
    wide.meta["up"] = 2; wide.cw = -1
    @test W.hunk_marks(wide) == Dict(3 => (1, 0), 4 => (1, 0))
    # And the tally survives that rebuild, which throws the header away.
    wide.header = string(wide.meta["file"], "  @@ 10,2 @@", get(wide.meta, "tally", ""))
    @test occursin("💬2", W.astrip(wide.header))
end

@testset "the list says what has been read" begin
    # Weight is the only thing on a row that can say this without costing a
    # column, and the list is two thousand rows of things somebody may or may
    # not have looked at. Unread is bold, read is plain, and the whole list was
    # dim before - which is what made the unread rows invisible among them.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    st.sel = 2                              # so the cursor is on neither below
    unread, read_ = st.items[3], st.items[4]
    push!(st.unread, unread.url)
    f = W.render(st, 150, 40)
    lines = split(f, "\n")
    # Inside the list pane and nowhere else. The frame is drawn bold, the detail
    # beside it carries every weight there is, and the title bar names the
    # selected item too - so a row asked about the whole screen line would be
    # answered by any of the three. `│` is what a body row starts with, and the
    # cut at `leftw - 1` leaves the pane's own right border out of the answer.
    row(it) = last(split(W.afit(first(l for l in lines if startswith(W.astrip(l), "│") &&
                                      occursin(it.ref, first(W.astrip(l), W.leftw(150)))),
                                W.leftw(150) - 1), W.AR; limit = 2))
    @test occursin(W.AB, row(unread))
    @test !occursin(W.AB, row(read_))
    @test !occursin(W.AD, row(read_))       # nor dim, which is the whole point
    # The cursor is a background now, the way the reading pane's line is: bold
    # is spoken for, and a bright-white bold row among bold rows is not a
    # cursor. It covers the row rather than the words on it.
    @test occursin(W.CURBG, row(st.items[st.sel]))
    @test !occursin(W.CURBG, row(unread)) && !occursin(W.CURBG, row(read_))
    @test W.awidth(first(l for l in lines if occursin(W.CURBG, l))) == 150
    # The import row keeps its dim, being the one row that is not an item.
    @test occursin(W.AD, first(l for l in lines if occursin("import an item",
                                                           W.astrip(l))))
end
