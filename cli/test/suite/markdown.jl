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
    @test count(l -> occursin(W.THEME.code_bg, l), ls) >= 1
    @test sum(count(W.THEME.code_bg, l) for l in ls) == 2          # one per span
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

    # A span Term split carries its background onto the next line, and the
    # spans after it on that line stay right side out. Paired line by line,
    # the closing delimiter of `ErrorEx|ception` opened a span and the prose up
    # to the next one was drawn on the background (julia#63360).
    function shaded(ls)             # (text on the background, text off it)
        on, off, bg = IOBuffer(), IOBuffer(), false
        for l in ls, m in eachmatch(r"(\e\[[0-9;]*m)|([^\e]+)", l)
            if m[1] !== nothing
                m[1] == W.THEME.code_bg && (bg = true)
                m[1] in (W.THEME.code_bg_off, W.THEME.reset) && (bg = false)
            else
                write(bg ? on : off, m[2])
            end
        end
        String(take!(on)), String(take!(off))
    end
    para = "An invalid memory ordering passed to an atomic intrinsic throws " *
           "`ConcurrencyViolationError`, but `intrinsic_exct` had no case for " *
           "`atomic_fence` or the `atomic_pointer*` intrinsics. They fell through " *
           "to the checks for math intrinsics, which reject the `Symbol` ordering " *
           "argument with `ErrorException`, so inference concluded that only " *
           "`ErrorException` could be thrown."
    spans = join(m.match for m in eachmatch(r"`[^`]*`", para))
    for w in 24:4:140
        on, off = shaded(lines(para, w))
        @test replace(on, r"\s" => "") == replace(spans, r"\s" => "")
        @test !occursin('`', off)
    end
    # Some width in that range does split a span, or the loop proved nothing.
    @test any(w -> any(l -> isodd(count('`', W.astrip(l))), lines(para, w)), 24:4:140)
    # A blank line ends a paragraph, and a span left open does not cross it.
    d = W.CODE_DELIM
    on, off = shaded(split(W.style_code_spans("a $(d)b\n\nc $(d)d$(d) e"), '\n'))
    @test on == "`b`d`" && off == "a c  e"
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
    # apply_style deletes anything shaped like a tag. Term escapes them itself
    # since 2.2.1, so `escape_source` leaves them be: escaped twice, they
    # printed doubled.
    @test render("a Tuple{Type{S{N}}} sig") == "a Tuple{Type{S{N}}} sig"
    @test render("mixed Set{Int} and `Vector{T}` here") == "mixed Set{Int} and `Vector{T}` here"
    @test render("a { lone brace") == "a { lone brace"
    @test esc("a {b}") == "a {b}"
    @test startswith(render("**bold {x}** _it {y}_ [link {l}](http://x)"), "bold {x} it {y} link {l} ")
    # A code span in emphasis is a code span, not the `Markdown.Code(...)` it
    # printed as before Term 2.2.1 recursed into bold and italic (seen on
    # julia#62889).
    @test render("**Why `JL_GC_PUSHARGS` frames are the hard case.**") ==
          "Why `JL_GC_PUSHARGS` frames are the hard case."
    @test render("_a `b` c_") == "a `b` c"
    # And `wl show`, which is Term without the pane.
    @test W.astrip(W.term_md(W.for_term(W.parse_gfm("a Dict{String,Int} and `T{S}`")), 80)) ==
          "a Dict{String,Int} and `T{S}`"
    @test esc("`keep {this}`") == "`keep {this}`"        # code is left alone

    # GitHub's shortcodes are the characters it draws for them - not in code,
    # not after a letter, not a name it does not know - and without the
    # presentation selector, whose second column `textwidth` does not count.
    @test render("thanks :tada: from :robot: :+1:") == "thanks 🎉 from 🤖 👍"
    @test render("`:robot:` stays") == "`:robot:` stays"
    @test esc("```\n:robot:\n```") == "```\n:robot:\n```"
    @test esc("at 12:30:45 or a:tada: or :nosuchname:") == "at 12:30:45 or a:tada: or :nosuchname:"
    @test esc(":white_check_mark: done") == "✅ done"               # the underscores are the name's
    @test esc(":warning:") == "⚠" && !occursin('\ufe0f', esc(":hash:"))
    @test W.EMOJI["robot"] == "🤖"

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
    seen(f) = W.astrip(replace(replace(f, W.THEME.match_bg => "<"), W.THEME.no_bg => ">"))
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
    hl = W.hlspan(s, W.findhits(W.astrip(s), "green"), W.THEME.match_bg)
    @test W.astrip(hl) == W.astrip(s)          # nothing printable is disturbed
    @test occursin(W.THEME.match_bg * "green", hl)
    @test endswith(hl, W.THEME.no_bg)                 # ends the background, not the colour
    @test W.findhits("aXbXc", "x") == [2:2, 4:4]
    @test isempty(W.findhits("abc", ""))
    @test W.hlspan("plain", UnitRange{Int}[], W.THEME.match_bg) == "plain"
    # A match inside styled text keeps the style around it.
    s2 = "\e[32mfoo bar baz\e[0m"
    @test W.astrip(W.hlspan(s2, W.findhits(W.astrip(s2), "bar"),
                            W.THEME.match_bg)) == "foo bar baz"
end

@testset "a comment is drawn as GitHub draws a comment" begin
    lines(t, w = 80) = [rstrip(W.astrip(l)) for l in W.nodelines(W.Node("h", t, :md, true), w)]
    # A newline is a line break, which is what GitHub's own renderer makes of
    # it in a comment (`<br>`); Term 2.2.1 made it a space, and a comment
    # wrapped by hand was reflowed.
    @test filter(!isempty, lines("the quick brown fox\njumps over\nthe **lazy\ndog**")) ==
          ["the quick brown fox", "jumps over", "the lazy", "dog"]
    # A blank line is still a paragraph, and a long line still wraps.
    @test count(isempty, lines("one\n\ntwo")) >= 1
    @test length(filter(!isempty, lines("word "^30, 40))) > 1

    # A column with no colon is drawn left, as GitHub draws it; the stdlib
    # reads it as `:r`. One with colons keeps what they say.
    t = W.parse_gfm("| a | b | c | d |\n|---|:--|--:|:-:|\n| 1 | 2 | 3 | 4 |").content[1]
    @test t.align == [:l, :l, :r, :c]
    @test W.parse_gfm("a | b\n--- | ---:\n1 | 2").content[1].align == [:l, :r]
    # Anything else parses as it did.
    @test W.parse_gfm("# h\n\n- a\n- b").content[2] isa W.Markdown.List
    @test W.parse_gfm("not | a table").content[1] isa W.Markdown.Paragraph
    rows = lines("| Advisory | CVSS |\n|---|---|\n| JLSEC-2026-1275 | 9.4 |")
    head = only(filter(l -> occursin("Advisory", l), rows))
    @test occursin(r"│ Advisory +│", head)                      # left, not right

    # What Term 2.2.1 fixed, which `for_term` used to work around: an empty
    # list item keeps its bullet, and a code span in a header stays one row.
    @test count(l -> occursin("•", l), lines("- a\n-\n- b")) == 3
    rows = filter(l -> occursin("│", l), lines("| `code` | b |\n|---|---|\n| 1 | 2 |"))
    @test length(rows) == 2 && occursin("`code`", rows[1])
    # And a table in a list is still its source, not a box beside the bullet.
    @test any(l -> occursin(r"\|\s+a\s+\|", l), lines("- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |"))
end
