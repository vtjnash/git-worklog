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

    # Nothing is written inside a hyperlink that is already there, and that
    # includes the text between its ends: a footnote row links itself, and its
    # label is the very string these patterns match.
    made = W.osc8("https://x.invalid/a", "https://x.invalid/a")
    out = W.linkify(string("[1] ", made), ["https://x.invalid/a" => "https://x.invalid/a"])
    @test out == string("[1] ", made)                 # left exactly as it was
    @test !occursin("\e]8;;\e]8;;", out)

    # Two urls where one is the head of the other - an issue and a comment on
    # that issue is the everyday case - and both too long to be shown whole.
    # The rows link themselves where they are built, so each points at its own
    # url however alike the two are drawn; and elided in the middle, they are
    # not drawn alike either.
    iss = "https://github.com/JuliaLang/PackageCompiler.jl/issues/1234#issue-comment-anchor"
    cmt = string(iss, "#issuecomment-1701494121")
    @test W.shortlink(iss, 60) != W.shortlink(cmt, 60)
    @test endswith(W.shortlink(cmt, 60), "1701494121")   # the half that differs
    @test W.awidth(W.shortlink(cmt, 60)) <= 60
    two = mkstate()
    two.nodes = W.body_nodes("alice  2026-08-01   two links",
                             string("see [the issue](", iss, ") and [the comment](", cmt, ")"),
                             "http://x", true)
    two.loaded = string(two.items[two.sel].url, ":", two.mode)
    f = W.render(two, 150, 40)
    got = [m[1] for m in eachmatch(r"\e\]8;;([^\e]+)\e", f)]
    @test iss in got && cmt in got
    @test !occursin("\e]8;;\e]8;;", f)
    for l in split(f, "\n"); @test W.awidth(l) == 150; end
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

@testset "a double click copies, and a mark says what will be" begin
    # OSC 8 hands a link to the terminal and hopes; owning the mouse means the
    # copy can be made here, where the whole url is known. The same applies to
    # everything else on the row: a double click is the gesture everybody
    # already makes at a word they want.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    st.nodes = W.body_nodes("alice  2026-08-01   a remark",
                            "It is in `typeinfer.jl:544`, at the widening.",
                            "https://x.invalid/c", true)
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    W.render(st, 150, 40)
    L = W.layout(150, 40, st.nmeta)
    ctrl = W.Controller()
    rs = W.rows(st.nodes, L.riw, true)
    body = findfirst(r -> occursin("typeinfer", r.src) && !r.header, rs)
    txt = W.astrip(rs[body].text)
    at_word = first(findfirst("typeinfer", txt)) + 3
    r = rs[body]
    # The word is the run of non-space around the pointer, so a path or an
    # identifier with a dot in it comes back whole. Its backticks and the comma
    # after it do not: they are what somebody wrote around the thing.
    @test W.word_at(st, r, at_word) == "typeinfer.jl:544"
    @test W.word_at(st, r, first(findfirst("at the", txt))) == "at"
    @test isempty(W.word_at(st, r, findfirst(isspace, txt)))
    # A url is a word too, and the whole of one even where the wrapping cut it.
    fn = W.Row(1, false, "[1] https://x.invalid/c", "[1] https://x.invalid/c", 0)
    @test W.word_at(st, fn, 3) == "https://x.invalid/c"

    y0 = L.ry + 1 + st.hdr
    click(x, y, at) = W.onmouse!(st, W.MouseEvent(:press, 0, x, y, 0), ctrl, at)
    st.status = ""
    click(L.rx + at_word, y0 + body - 1, 100.0)
    @test isempty(st.status)                       # one click is not a copy
    click(L.rx + at_word, y0 + body - 1, 100.2)
    @test st.status == "copied typeinfer.jl:544"
    # Two presses too far apart are two presses.
    st.status = ""
    click(L.rx + at_word, y0 + body - 1, 200.0)
    click(L.rx + at_word, y0 + body - 1, 200.0 + W.DOUBLECLICK[] + 0.1)
    @test isempty(st.status)

    # The mark is drawn at the end of a header, and only where the pane is
    # actually drawn - it is an offer to click, and `m` can hand the mouse back
    # to the terminal.
    @test endswith(W.astrip(rs[1].text), W.COPYMARK)
    @test !occursin(W.COPYMARK, W.astrip(W.rows(st.nodes, L.riw)[1].text))
    @test all(W.awidth(r.text) <= L.riw for r in rs)
    st.status = ""
    click(L.rx + L.riw, y0, 300.0)                 # the mark, at the right edge
    @test st.status == string("copied ", count(==('\n'), W.node_text(st.nodes, 1, L.riw)) + 1,
                              " lines")
    @test W.node_text(st.nodes, 1, L.riw) == "It is in `typeinfer.jl:544`, at the widening."
    # ...and the fold marker at the other end still folds rather than copies.
    # `hitpane` puts inner column 1 at `px + 2`, so both ends are two columns
    # wide here: the marker, and the mark with the space in front of it.
    click(L.rx + 2, y0, 400.0)
    @test !st.nodes[1].open

    # What the mark copies is what folding that header would hide: the node and
    # everything nested under it, bodies only. A hunk is the exception - what is
    # nested under one is a conversation about the code, not part of it.
    split_ = W.body_nodes("bob  2026-08-02   prose then code",
                          "before\n\n```julia\nx = 1\n```\n\nafter", "http://x", true)
    @test W.node_text(split_, 1, 80) == "before\n\nx = 1\n\nafter"
    @test W.node_text(split_, 2, 80) == "x = 1"

    # A fenced block is a node with a header of its own, so it has a mark of its
    # own - which is the case this is most wanted for: the code without the
    # sentence around it. It copies the same folded, since `node_text` reads the
    # node rather than the screen.
    st.nodes = W.body_nodes("bob  2026-08-02   try this",
                            "Try:\n\n```julia\nusing Downloads\nx = 1\n```\n\nand report back.",
                            "http://x", true)
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    W.render(st, 150, 40)
    for folded in (false, true)
        st.nodes[2].open = !folded
        rs2 = W.rows(st.nodes, L.riw, true)
        code = findfirst(r -> r.header && r.node == 2, rs2)
        @test endswith(W.astrip(rs2[code].text), W.COPYMARK)    # nested, at the edge
        st.status = ""
        click(L.rx + L.riw, y0 + code - 1, folded ? 600.0 : 700.0)
        @test st.status == "copied 2 lines"
        @test W.node_text(st.nodes, 2, L.riw) == "using Downloads\nx = 1"
    end
    hunk = W.Node("a.jl  @@ 1,2 @@", "-old\n+new", :diff, true)
    merge!(hunk.meta, Dict{String,Any}("file" => "a.jl", "start" => 1, "count" => 2,
                                       "ostart" => 1, "ocount" => 2,
                                       "body" => "-old\n+new", "up" => 0, "down" => 0))
    talk = W.Node("alice  2026-08-01T10:00", "a remark", :md, true, 1)
    @test W.node_text([hunk, talk], 1, 80) == "-old\n+new"

    # In the item list there is one thing worth copying, and a double click on
    # the row you are already on is how it is asked for.
    st2 = mkstate()
    W.render(st2, 150, 40)
    st2.focus = :list
    row = L.ly + 1 + 1 + st2.sel        # the import row leads, so +1
    st2.status = ""
    W.onmouse!(st2, W.MouseEvent(:press, 0, L.lx + 4, row, 0), ctrl, 500.0)
    was = st2.sel
    W.onmouse!(st2, W.MouseEvent(:press, 0, L.lx + 4, row, 0), ctrl, 500.2)
    @test st2.sel == was
    @test occursin("copied", st2.status) && occursin(st2.items[was].ref, st2.status)
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
    # the second and is new line 10. The mark is the row's gutter - drawn over
    # the pane's left border, where the eye is, and not after the text, where
    # it was and was not seen - so the text is the diff line alone.
    marked = W.attach_comments(copy([hunk("a.jl", 10, 2, 40, 2)]),
                               [cmt(1, "a.jl", 40; side = "LEFT"),
                                cmt(2, "a.jl", 10), cmt(3, "a.jl", 10; reply = 2)],
                               "http://x")
    @test W.hunk_marks(marked[1]) == Dict(1 => (1, 0), 2 => (1, 0))
    body = [r for r in W.rows(marked, 70) if r.node == 1 && !r.header]
    @test [W.astrip(r.text) for r in body] == ["-old", "+new"]
    @test [W.astrip(r.gutter) for r in body] == ["💬", "💬"]
    @test all(isempty(r.gutter) for r in W.rows(marked, 70) if r.header)
    # Two threads on one line say their count at the end of the row, since the
    # gutter has room for the mark and not for a number.
    two = W.attach_comments(copy([hunk("a.jl", 10, 2, 40, 2)]),
                            [cmt(1, "a.jl", 10), cmt(2, "a.jl", 10)], "http://x")
    tworows = [r for r in W.rows(two, 70) if r.node == 1 && !r.header]
    @test W.astrip(tworows[2].text) == "+new  💬2" && W.astrip(tworows[2].gutter) == "💬"
    @test isempty(tworows[1].gutter)
    # On screen: the mark stands where the border was on that row, and the
    # border is there on the rows around it.
    st = mkstate(); st.mode = :diff; st.nodes = marked
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    pane = W.astrip.(W.detail_pane(st, st.items[st.sel], 60, 12, true))
    at = findfirst(l -> occursin("-old", l), pane)
    @test at !== nothing && startswith(pane[at], "💬-old")
    @test startswith(pane[at + 1], "💬+new") && startswith(pane[at - 1], "│")
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

@testset "a control character in a diff is drawn, not obeyed" begin
    # An escape in a diff is a command to the terminal the frame is on, and gh
    # refuses to pipe one. Here it is asked for anyway, and what reaches the
    # rows is caret notation, with the count on the first row - the top, where
    # a long diff does not push it off the screen.
    txt = "diff --git a/a.jl b/a.jl\n--- a/a.jl\n+++ b/a.jl\n@@ -1,2 +1,2 @@\n" *
          " same\n-old \e[31mred\e[0m\n+new \x07bell\r\n"
    ns = W.hunk_nodes(txt, "http://x")
    @test length(ns) == 2
    @test occursin("4 control characters", W.astrip(ns[1].header))
    @test ns[1].kind === :plain && !haskey(ns[1].meta, "file")   # stepped over
    @test ns[2].raw == " same\n-old ^[[31mred^[[0m\n+new ^Gbell^M\n"
    @test ns[2].meta["body"] == ns[2].raw                        # what C measures
    @test ns[2].meta["start"] == 1 && ns[2].meta["count"] == 2   # ranges untouched
    @test !any(occursin(r"[\x00-\x08\x0b-\x1f\x7f]", r.src) for r in W.rows(ns, 80))
    # A clean diff carries no such row.
    @test !any(n -> occursin("control", W.astrip(n.header)),
               W.hunk_nodes("diff --git a/a.jl b/a.jl\n@@ -1 +1 @@\n-a\n+b\n", "u"))
    @test W.inert("a\tb\nc") == ("a\tb\nc", 0)
    @test W.inert("\x7f\u0085") == ("^?^E", 2)                    # DEL, and C1

    # The range-diff parser draws the same row for the same reason.
    rd = W.rangediff_nodes("1:  aaaaaaa ! 1:  bbbbbbb subj\n    @@ x\n    -\e[1mz\n")
    @test occursin("1 control character in", W.astrip(rd[1].header))
    @test occursin("^[[1mz", rd[2].raw)

    # And gh's refusal is answered by asking again with the flag it names,
    # through a run that captures stderr - the message is a reason on a failed
    # node, never a row printed onto the frame.
    it = W.Item(url = "u", ref = "o/r#1", repo = "o/r", number = 1, title = "t")
    calls = Vector{String}[]
    refuse(args) = (push!(calls, args);
                    "--allow-escape-sequences" in args ? (0, txt, "") :
                    (1, "", "the diff contains terminal escape sequences; pass " *
                            "--allow-escape-sequences to output it anyway\n"))
    @test W.fetch_diff(it; run = refuse) == txt
    @test length(calls) == 2 && calls[1] == ["pr", "diff", "1", "--repo", "o/r"]
    @test calls[2] == [calls[1]; "--allow-escape-sequences"]
    plain(args) = (push!(calls, args); (0, "diff --git a/a b/a\n", ""))
    empty!(calls)
    @test W.fetch_diff(it; run = plain) == "diff --git a/a b/a\n" && length(calls) == 1
    @test_throws W.FetchError W.fetch_diff(it; run = _ -> (1, "", "no pull requests found"))
    failed = W.diff_nodes(it; fresh = true, run = _ -> (1, "", "no pull requests found"))
    @test get(failed[1].meta, "failed", false) && failed[1].raw == "no pull requests found"
end

@testset "a tab is drawn as the columns it takes" begin
    # `textwidth('\t')` is 0, so a Makefile's diff - a tab at the head of every
    # recipe line - measured narrower than it drew, and the terminal's own
    # expansion tore the row. What prints has the spaces; the source behind
    # the row keeps the tab, for `y` and for a suggestion.
    @test W.detab("a\tb") == "a       b"
    @test W.detab("\tgcc\t-o") == "        gcc     -o"
    @test W.detab("abcdefgh\tx") == "abcdefgh        x"         # at a stop: a full one
    @test W.detab("\e[31mab\e[0m\tc") == "\e[31mab\e[0m      c"   # escapes take no columns
    @test W.detab("日本\tx") == "日本    x"                     # wide characters count two
    @test W.detab("plain") == "plain"
    txt = "diff --git a/Makefile b/Makefile\n@@ -1,2 +1,2 @@\n all:\n-\tgcc a.c\n+\tgcc -O2 a.c\n"
    ns = W.hunk_nodes(txt, "http://x")
    rs = [r for r in W.rows(ns, 80) if r.node == 1 && !r.header]
    # The marker is column 0, as `git diff` on a terminal has it, so the stop
    # is seven spaces on.
    @test W.astrip(rs[2].text) == "-       gcc a.c"
    @test W.astrip(rs[3].text) == "+       gcc -O2 a.c"
    @test rs[3].src == "+\tgcc -O2 a.c"
    # The word marks are byte ranges of the line as written, and survive the
    # expansion that follows them.
    @test occursin(string(W.THEME.diff_add_word, "-O2 ", W.THEME.diff_add_word_off), rs[3].text)
    # And the widths agree with what the terminal will draw.
    @test W.awidth(rs[3].text) == length("+       gcc -O2 a.c")
    # A plain node - a log, a range-diff - is drawn the same way and copies
    # the same way.
    p = W.Node("h", "x\ty\n\tz", :plain, true)
    ls = W.nodelines(p, 80)
    @test ls == ["x       y", "        z"] && [s for (_, s) in p.srcs] == ["x\ty", "\tz"]
    # The suggestion `^r` fills in carries the tab, not the spaces.
    st = mkstate()
    st.nodes = ns; st.mode = :diff
    @test W.hunk_text(st, 1, 80, 4, 4) == ["\tgcc -O2 a.c"]     # row 1 is the header
end

@testset "the list says what is done" begin
    # Weight is the only thing on a row that can say this without costing a
    # column, and the list is two thousand rows of things somebody may or may
    # not have looked at. Unread is bold, read is plain, and the whole list was
    # dim before - which is what made the unread rows invisible among them.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    st.sel = 2                              # so the cursor is on neither below
    unread, read_ = st.items[3], st.items[4]
    # Unread is what `seen_of` says: no stamp, or one from before it moved.
    st.done = Dict(read_.url => "2099-01-01T00:00:00Z")
    f = W.render(st, 150, 40)
    lines = split(f, "\n")
    # Inside the list pane and nowhere else. The frame is drawn bold, the detail
    # beside it carries every weight there is, and the title bar names the
    # selected item too - so a row asked about the whole screen line would be
    # answered by any of the three. `│` is what a body row starts with, and the
    # cut at `leftw - 1` leaves the pane's own right border out of the answer.
    row(it) = last(split(W.afit(first(l for l in lines if startswith(W.astrip(l), "│") &&
                                      occursin(it.ref, first(W.astrip(l), W.leftw(150)))),
                                W.leftw(150) - 1), W.THEME.reset; limit = 2))
    @test occursin(W.THEME.bold, row(unread))
    @test !occursin(W.THEME.bold, row(read_))
    @test !occursin(W.THEME.dim, row(read_))       # nor dim, which is the whole point
    # The cursor is a background now, the way the reading pane's line is: bold
    # is spoken for, and a bright-white bold row among bold rows is not a
    # cursor. It covers the row rather than the words on it.
    @test occursin(W.THEME.cursor_bg, row(st.items[st.sel]))
    @test !occursin(W.THEME.cursor_bg, row(unread)) &&
          !occursin(W.THEME.cursor_bg, row(read_))
    @test W.awidth(first(l for l in lines if occursin(W.THEME.cursor_bg, l))) == 150
    # And it stays lit with the keys on the reading side: it says which item
    # is being read, and the border says which side has the keys - as does the
    # whole list going dim, weight and cursor still under it.
    st.focus = :detail
    lines = split(W.render(st, 150, 40), "\n")
    @test occursin(W.THEME.cursor_bg, row(st.items[st.sel]))
    @test occursin(W.THEME.quiet, row(read_)) && occursin(W.THEME.quiet, row(unread))
    @test occursin(W.THEME.quiet, row(st.items[st.sel]))
    # The ANSI theme has no `quiet_bold`: bold over dim is the pair terminals
    # disagree about, so the weight goes rather than being drawn wrong. A
    # 256-colour theme names one, and the unread row keeps it in place of
    # `bold`, which there carries a foreground of its own.
    @test isempty(W.THEME.quiet_bold) && !occursin(W.THEME.bold, row(unread))
    W.load_theme!(joinpath(W.ROOT, "themes", "github-dark-256.toml"))
    try
        lines = split(W.render(st, 150, 40), "\n")
        @test !isempty(W.THEME.quiet_bold) && W.THEME.quiet_bold != W.THEME.bold
        @test occursin(W.THEME.quiet_bold, row(unread)) && !occursin(W.THEME.bold, row(unread))
        @test !occursin(W.THEME.quiet_bold, row(read_)) && occursin(W.THEME.quiet, row(read_))
    finally
        W.load_theme!(THEME_DEFAULT)
    end
    st.focus = :list
    lines = split(W.render(st, 150, 40), "\n")
    # The import row keeps its dim, being the one row that is not an item.
    @test occursin(W.THEME.dim, first(l for l in lines if occursin("import an item",
                                                           W.astrip(l))))
end

@testset "? is the footer's other half" begin
    # A dialog on the stack, from wherever the cursor is: the filter pane, the
    # import row and an empty list are the places a key that needs telling is
    # most wanted, and every other per-item key is behind the guard that
    # swallows them there.
    for setup in (identity, s -> (s.lmode = :filters; s), s -> (s.sel = 0; s),
                  s -> (s.focus = :detail; s))
        st = setup(mkstate())
        ctrl = W.Controller()
        @test W.handle!(st, Int('?'), ctrl) === :ok
        @test last(ctrl.stack) isa W.HelpView
        empty!(ctrl.stack)
    end
    ctrl = W.Controller()
    v = W.HelpView()
    # The box is a whole frame like every render, and every key in the
    # README's table is in it - the table is the same list, kept by hand, and
    # this is what notices one falling behind the other.
    for (w, h) in ((80, 24), (120, 60), (200, 50), (60, 10))
        f = W.render(v, w, h)
        ls = split(f, "\n")
        @test length(ls) == h
        @test all(W.awidth(l) == w for l in ls)
    end
    said = join((e isa String ? e : string(e[1], " ", e[2]) for e in W.HELP), "\n")
    table = false
    for line in eachline(joinpath(W.ROOT, "README.md"))
        table |= line == "| key | |"
        table && isempty(line) && break
        m = match(r"^\| (.*?) \| ", line)
        (table && m !== nothing) || continue
        for key in eachmatch(r"`([^`]+)`", m[1])
            @test occursin(key[1], said)
        end
    end
    @test table
    # Tall enough to hold it all, any key closes it - `q` included, which here
    # is the key most likely to be pressed by accident and must not end the
    # program from inside a box about keys.
    ENV["COLUMNS"], ENV["LINES"] = "120", "60"
    for k in (Int('q'), Int('?'), 27, 13, Int('x'))
        @test W.handle!(W.HelpView(), k, ctrl) === :pop
    end
    # On a short screen it scrolls, and the scroll keys are the browser's own.
    ENV["COLUMNS"], ENV["LINES"] = "120", "20"
    n = length(W.help_rows(W.dialogbox(120; width = 96).iw))
    @test n > W.help_page(20)
    @test W.handle!(v, Int('j'), ctrl) === :ok && v.top == 2
    @test W.handle!(v, Int('G'), ctrl) === :ok && v.top == n - W.help_page(20) + 1
    @test occursin(string(n, " of ", n), W.astrip(W.render(v, 120, 20)))
    @test W.handle!(v, Int('g'), ctrl) === :ok && v.top == 1
    @test W.handle!(v, Int(' '), ctrl) === :ok && v.top == 1 + W.help_page(20)
    @test W.handle!(v, Int('k'), ctrl) === :ok && v.top == W.help_page(20)
    @test W.onmouse!(v, W.MouseEvent(:wheelup, 0, 1, 1, 0), ctrl) === :ok && v.top == W.help_page(20) - 3
    @test W.onmouse!(v, W.MouseEvent(:press, 0, 1, 1, 0), ctrl) === :pop
    @test W.handle!(v, Int('x'), ctrl) === :pop
end

@testset "the words that changed inside a line are marked" begin
    # Tokens, by longest common subsequence: the renamed identifier and
    # nothing else, on both sides, as byte ranges into each line.
    sc, a, b = W.word_marks("    foo(bar, baz)", "    foo(qux, baz)")
    @test a == [9:11] && b == [9:11] && sc > 0.5
    # Adjacent changed tokens are one range; a change at the end is found.
    _, a, b = W.word_marks("x = a + b", "x = a - b + c")
    @test a == [7:7] && b == [7:7, 10:13]
    # A rewrite is not an edit: two lines with little in common mark nothing
    # rather than most of both.
    @test W.word_marks("return nothing", "for i in 1:n") == (0.0, [], [])
    @test W.word_marks("", "anything") == (0.0, [], [])
    # Likeness is by words, over the shorter line: JuliaLang/julia#63192.
    # An append is the clearest edit there is, and punctuation in common
    # does not make two lines alike - nor does it stop these two being so.
    sc, a, b = W.word_marks("        else",
                            "        else # this branch may not be needed, from before current keyword argument handling")
    @test sc == 1.0 && a == [] && b == [13:91]
    sc, a, b = W.word_marks("        code = frame.linfo", "        code = StackTraces.frame_mi(frame)")
    @test sc >= 0.5 && a == [21:26] && b == [16:36, 42:42]
    @test W.word_marks("}", "};")[1] == 1.0                 # no words: on what it has
    # String indices, not bytes: a token ending in a three-byte character -
    # JuliaLang/julia#63006 has `x₃` - ends at the index of that character,
    # where `markwords` can cut; its last byte is the middle of it, and the
    # diff view of that PR threw on every frame.
    a, b = "f(x₃) + x₃", "f(x₃) - y₃"
    _, ra, rb = W.word_marks(a, b)
    @test ra == [9:9, 11:12] && rb == [9:9, 11:12]
    @test W.astrip(W.markwords(a, ra, "<", ">")) == "f(x₃) <+> <x₃>"
    @test W.astrip(W.markwords(b, rb, "<", ">")) == "f(x₃) <-> <y₃>"
    _, ra, rb = W.word_marks("s = x₃", "s = x₃y")
    @test ra == [5:6] && rb == [5:9]                         # `x₃` ends at 6, not byte 8

    # A run of deletions and a run of as many additions pair up line for
    # line; context gets nothing.
    lines = [" ctx", "-a = 1", "-b = 2", "+a = 10", "+b = 2", " more"]
    ws = W.hunk_words(lines)
    @test ws[2] == [6:6] && ws[4] == [6:7]         # `1` → `10`, past the marker
    @test isempty(ws[3]) && isempty(ws[5])          # `b = 2` did not change
    @test all(isempty, ws[[1, 6]])
    # Unequal runs pair by likeness, in order: the one line that became
    # two is marked against the one of the two it became, and a line with
    # no line like it - `-gone` against `+x`, `+y` - is left alone.
    lines = ["-gone", "+x", "+y", " ctx",
             "-total = sum(xs)", "+n = length(xs)", "+total = sum(xs) / n"]
    ws = W.hunk_words(lines)
    @test all(isempty, ws[1:4])
    @test isempty(ws[6])                                # `n = length(xs)` is new
    @test ws[5] == [] && ws[7] == [17:20]               # ` / n` added at the end
    # And the other way about: two lines that became one.
    ws = W.hunk_words(["-a = f(x)", "-b = g(y)", "+b = g(y, z)"])
    @test isempty(ws[1]) && ws[2] == [] && ws[3] == [9:11]

    # Drawn in the word role inside the line's colour, and closed by what
    # ends a background alone, so the cursor's background over the row is
    # re-armed by `hlrow` and the line's own colour runs on.
    keep = W.THEME.diff_add, W.THEME.diff_add_word, W.THEME.diff_add_word_off, W.THEME.reset
    W.THEME.diff_add = "\e[32m"; W.THEME.diff_add_word = "\e[48;5;22m"
    W.THEME.diff_add_word_off = "\e[49m"; W.THEME.reset = "\e[0m"
    try
        @test W.diffline("+a = 10", [6:7]) == "\e[32m+a = \e[48;5;22m10\e[49m\e[0m"
        @test W.diffline("+a = 10") == "\e[32m+a = 10\e[0m"
        @test W.astrip(W.diffline("+a = 10", [6:7])) == "+a = 10"
    finally
        W.THEME.diff_add, W.THEME.diff_add_word, W.THEME.diff_add_word_off, W.THEME.reset = keep
    end
    # A node of the two lines renders with the marks and copies without them.
    n = W.Node("a.jl  @@ 1,2 @@", "-a = 1\n+a = 10", :diff, true)
    merge!(n.meta, Dict{String,Any}("file" => "a.jl", "start" => 1, "count" => 2,
                                    "ostart" => 1, "ocount" => 2, "up" => 0, "down" => 0))
    rs = W.rows([n], 60)
    @test any(r -> r.src == "+a = 10", rs)
end
