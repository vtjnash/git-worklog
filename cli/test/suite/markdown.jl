# Term, and the four shapes it renders wrongly or not at all. Every one of
# these was a real comment that came out mangled.

@testset "fenced code blocks are lifted out of Term" begin
    segs = W.split_fences("before\n\n```julia\nf(x)\n  g\n```\n\nafter")
    @test [(k, sm) for (k, sm, _) in segs] == [(:text, ""), (:code, "julia"), (:text, "")]
    @test segs[2][3] == "f(x)\n  g"
    @test W.split_fences("no code here") == [(:text, "", "no code here")]
    # An unclosed fence gives its lines back rather than swallowing them.
    @test occursin("dangling", W.split_fences("a\n```\ndangling")[1][3])
    @test W.split_fences("~~~\nx\n~~~")[1][1] === :code

    ns = W.body_nodes("alice", "before\n\n```julia\nf(x)\n```\n\nafter", "http://x", true)
    code = [n for n in ns if n.kind === :plain]
    @test length(code) == 1
    @test code[1].depth == 1 && occursin("julia", code[1].header)
    @test code[1].open                                  # short blocks stay open
    long = W.body_nodes("a", string("```\n", join(["l$i" for i in 1:40], "\n"), "\n```"),
                        "", true)
    @test !first(n for n in long if n.kind === :plain).open   # long ones fold away

    # No box, and nothing wider than the pane - the whole point.
    wide = W.body_nodes("a", string("```\n", "x"^250, "\n```"), "", true)
    for n in wide; n.kind === :plain && (n.open = true); end
    rs = W.rows(wide, 96)
    @test all(W.awidth(r.text) <= 96 for r in rs)
    @test !any(occursin("│", W.astrip(r.text)) || occursin("└", W.astrip(r.text)) for r in rs)

    # A plain node must not double its braces: it never reaches Term.
    n = W.Node("h", "f() { Dict{String,Int}() }", :plain, true)
    @test W.astrip(join(W.nodelines(n, 80), "")) == "f() { Dict{String,Int}() }"
end

@testset "inline code is a background, not a shout" begin
    lines(t, w) = W.nodelines(W.Node("h", t, :md, true), w)
    plain(t, w) = strip(join([W.astrip(l) for l in lines(t, w)], " "))

    ls = lines("call `Sockets.bind` and `false` here", 70)
    @test count(l -> occursin(W.CODEBG, l), ls) >= 1
    @test sum(count(W.CODEBG, l) for l in ls) == 2          # one per span
    # The backticks stay, so a copy keeps the formatting the author wrote.
    @test plain("call `Sockets.bind` and `false` here", 70) ==
          "call `Sockets.bind` and `false` here"
    # Nothing leaks the sentinel colour, at any width.
    for w in (24, 40, 70, 120)
        for t in ("call `Sockets.bind` here",
                  "a `span with several words that will not fit on one line at all` yes",
                  "unclosed `backtick here", "no code at all here")
            @test !any(occursin(W.MD_CODE_SENTINEL, l) for l in lines(t, w))
        end
    end
    # A span Term split has no pair on one line, so it falls back quietly.
    split_ = lines("a `span with several words that will not fit on one line at all` yes", 30)
    @test !any(occursin(W.MD_CODE_SENTINEL, l) for l in split_)
    @test occursin("`span with several words", plain("a `span with several words that will not fit on one line at all` yes", 30))
    # And the background never reaches the plain text.
    @test !occursin("[48;5;238m", plain("call `x` here", 70))
end

@testset "markup does not eat the text" begin
    render(t) = strip(W.astrip(join(W.nodelines(W.Node("h", t, :md, true), 100), " ")))
    # Julia's Markdown opens emphasis on an intraword underscore and it takes
    # two to pair, so a single identifier was never the failing case.
    @test render("call deliver_result and connect_to_peer here") ==
          "call deliver_result and connect_to_peer here"
    @test render("snake_case_name alone") == "snake_case_name alone"
    @test render("one_two three_four") == "one_two three_four"
    # Real emphasis - an underscore with a space before it - still works.
    @test render("a _real emphasis_ here") == "a real emphasis here"
    # Code is left alone: a backslash inside a span would print.
    @test render("`deliver_result` in code stays") == "`deliver_result` in code stays"
    @test render("mixed `a_b` and c_d_e here") == "mixed `a_b` and c_d_e here"

    esc = W.escape_source
    @test esc("a_b") == "a\\_b"
    @test esc("_leading and trailing_") == "_leading and trailing_"
    @test esc("```\nkeep_me\n```") == "```\nkeep_me\n```"          # fenced
    @test esc("    keep_me indented") == "    keep_me indented"    # indented
    @test esc("`keep_me` but not_this") == "`keep_me` but not\\_this"
    @test esc("") == ""

    # Braces written as prose survive too: Term's markup is `{...}`, and
    # apply_style deletes anything shaped like a tag.
    @test render("a Tuple{Type{S{N}}} sig") == "a Tuple{Type{S{N}}} sig"
    @test render("mixed Set{Int} and `Vector{T}` here") == "mixed Set{Int} and `Vector{T}` here"
    @test render("a { lone brace") == "a { lone brace"
    @test esc("a {b}") == "a {{b}}"
    @test esc("`keep {this}`") == "`keep {this}`"        # code is left alone

    # And the name is findable, which is the point.
    st = mkstate()
    st.nodes = [W.Node("h", "guard the raw stderr writes in deliver_result and connect_to_peer",
                       :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    st.search = "deliver_result"
    @test length(W.match_rows(st, 100)) == 1
end

@testset "a match cut by the wrap is marked on both rows" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    # The highlight markers, made visible without astrip eating them first.
    seen(f) = W.astrip(replace(replace(f, W.HITBG => "<"), W.NOBG => ">"))
    detail(st) = [l for l in split(seen(W.render(st, 150, 40)), "\n") if occursin("<", l)]

    st = mkstate()
    # Long enough to wrap in a 96-column pane, with the query spanning the break.
    st.nodes = [W.Node("a", "alpha beta gamma delta epsilon zeta eta theta iota kappa " *
                            "lambda mu nu xi omicron pi rho sigma tau upsilon phi chi", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail; st.searchin = :detail
    iw = W.layout(150, 40, st.nmeta).riw
    body = [r for r in W.rows(st.nodes, iw) if !r.header]
    @test length(body) > 1                          # it really does wrap
    # The two words either side of the break.
    tail = split(W.astrip(body[1].text))[end]
    head = split(W.astrip(body[2].text))[1]
    st.search = string(tail, " ", head)
    @test !any(occursin(st.search, W.astrip(r.text)) for r in W.rows(st.nodes, iw))
    marked = detail(st)
    @test length(marked) == 2                       # both halves marked
    joined = join(marked, "\n")
    @test occursin(string("<", tail, ">"), joined) && occursin(string("<", head, ">"), joined)

    # An ordinary match is marked once, exactly.
    st.search = "gamma"
    one = join(detail(st), "\n")
    @test occursin("<gamma>", one) && count(==('<'), one) == 1

    # Nothing invented, and the pane's printable text is untouched.
    st.search = "zzzz"
    @test isempty(detail(st))
    st.search = "gamma"
    pane_of(f) = [String(first(l, 100)) for l in split(W.astrip(f), "\n")[2:end-2]]
    lit = deepcopy(st); lit.search = ""
    @test pane_of(W.render(st, 150, 40)) == pane_of(W.render(lit, 150, 40))

    # Indented rows: the depth padding is not part of the source.
    st2 = mkstate()
    st2.nodes = [W.Node("top", "", :md, true),
                 W.Node("in", "alpha beta gamma delta epsilon", :md, true, 1)]
    st2.loaded = string(st2.items[st2.sel].url, ":", st2.mode)
    st2.focus = :detail; st2.searchin = :detail; st2.search = "gamma"
    @test occursin("<gamma>", join(detail(st2), "\n"))

    # row_span itself: a piece of the line, located with a moving cursor.
    r1 = W.Row(1, false, "alpha beta", "alpha beta gamma alpha beta", 0)
    @test W.row_span(r1, 0, 1) == 1:10
    @test W.row_span(r1, 0, 11) == 18:27            # the second copy, not the first
    @test W.row_span(W.Row(1, false, "nope", "alpha beta", 0), 0, 1) === nothing
    @test W.row_span(W.Row(1, false, "  beta  ", "alpha beta", 0), 2, 1) == 7:10
end

@testset "span highlighting" begin
    s = "\e[31mred\e[0m and green"
    hl = W.hlspan(s, W.findhits(W.astrip(s), "green"), W.HITBG)
    @test W.astrip(hl) == W.astrip(s)          # nothing printable is disturbed
    @test occursin(W.HITBG * "green", hl)
    @test endswith(hl, W.NOBG)                 # ends the background, not the colour
    @test W.findhits("aXbXc", "x") == [2:2, 4:4]
    @test isempty(W.findhits("abc", ""))
    @test W.hlspan("plain", UnitRange{Int}[], W.HITBG) == "plain"
    # A match inside styled text keeps the style around it.
    s2 = "\e[32mfoo bar baz\e[0m"
    @test W.astrip(W.hlspan(s2, W.findhits(W.astrip(s2), "bar"), W.HITBG)) == "foo bar baz"
end
