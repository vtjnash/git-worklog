# A comment body becomes rows of styled text. `TermInput.markdown_rows` draws
# the markdown, rows and source map together; this parses it the way GitHub
# does, pulls the links out to footnotes, links the references in the rows,
# and keeps the fold state a row belongs to - and, at the end, the bordered pane
# those rows are drawn in.

"""
    inert(text) -> (text, n)

The C0 and C1 control characters of `text` drawn as caret notation - `^[` for
an escape, `^G` for a bell - and how many there were. Tab and newline are kept:
they are what a line is made of, not what one can do to the terminal.

A diff is bytes somebody else wrote, and this program prints it. An escape in
one is not a byte on the screen but a command to the terminal the frame is
drawn on: `gh pr diff` found one in a pull request (2026-09) and refused to
print the diff at all - "the diff contains terminal escape sequences; pass
--allow-escape-sequences to output it anyway" - which is the right answer for
a pipe and the wrong one for a reader, who came for the diff. So it is asked
for anyway and made inert here, the way gh itself draws it on a terminal,
and the count goes on a row at the top so that what follows is read as a
diff somebody put a control character in.

`\r` is neutralized with the rest - a CRLF file's diff shows `^M` at every
line end, which is what `git diff` in a pager shows too, and a bare `\r` on a
row of the frame would overdraw the row.
"""
function inert(s::AbstractString)
    n = 0
    io = IOBuffer()             # not `sprint() do`, whose closure would box `n`
    for c in s
        cp = UInt32(c)
        if (cp < 0x20 && c != '\t' && c != '\n') || cp == 0x7f ||
           0x80 <= cp <= 0x9f
            n += 1
            print(io, '^', cp == 0x7f ? '?' : Char((cp & 0x1f) + 0x40))
        else
            print(io, c)
        end
    end
    (String(take!(io)), n)
end

"""
    detab(line, tab = 8) -> Styled

`line` with each tab drawn as the spaces to the next stop of `tab` columns,
counted in display columns from the start of the line, the spaces in the faces
the tab was in.

A tab is the one character whose width is not its own: `textwidth('\\t')` is
0, and the terminal moves the cursor to the next stop. So a line measured
here as fitting the pane drew wider than it, and a diff of a Makefile - every
recipe line begins with one - tore the frame at each of them. Counted from
the start of the line, prefix and all, which is where `git diff` on a
terminal puts the first stop.

For what *prints* only, one line at a time: the `src` behind a row keeps the
tab, so `y` copies one and `^r`'s suggestion carries one, which for a Makefile
is the difference between a suggestion that applies and one that does not.
"""
function detab(s::AbstractString, tab::Int = 8)
    x = row(s)
    str = x.string
    occursin('\t', str) || return x
    parts = Styled[]
    col, seg = 0, 1
    for (i, c) in pairs(str)
        if c == '\t'
            i > seg && push!(parts, row(SubString(x, seg, prevind(str, i))))
            n = tab - col % tab
            push!(parts, Styled(" "^n, Ann[Ann((1:n, a.label, a.value)) for a in anns(x)
                                           if i in a.region]))
            col += n; seg = i + 1
        else
            col += textwidth(c)
        end
    end
    seg <= ncodeunits(str) && push!(parts, row(SubString(x, seg)))
    isempty(parts) ? row("") : reduce(*, parts)
end

"""One line of a diff, in the face of what it is - and, given `words`, the
ranges of it - string indices - that changed against the line it is paired
with, in the word role over the line's own face."""
function diffline(l, words::Vector{UnitRange{Int}} = UnitRange{Int}[])
    # File headers must be tested before the bare +/- cases, or `+++`/`---`
    # colour as additions and deletions.
    startswith(l, "@@") && return faced(l, THEME.diff_hunk)
    (startswith(l, "+++") || startswith(l, "---") || startswith(l, "index ")) &&
        return faced(l, THEME.diff_meta)
    startswith(l, "+") && return faced(markwords(l, words, THEME.diff_add_word), THEME.diff_add)
    startswith(l, "-") && return faced(markwords(l, words, THEME.diff_del_word), THEME.diff_del)
    row(l)
end

"`l` with `face` over each of `ranges` - index ranges into `l`, in order."
function markwords(l::AbstractString, ranges::Vector{UnitRange{Int}}, face::Face)
    x = row(l)
    face == Face() && return x
    for r in ranges
        isempty(r) && continue
        x = overlaid(x, first(r):(last(r) + ncodeunits(l[last(r)]) - 1), face)
    end
    x
end

# --- what changed inside a line ---------------------------------------------
#
# GitHub marks, inside a changed line, the words that differ from the line it
# replaced - and a review is mostly that: the one identifier renamed in a
# line of forty, which `-` and `+` in two colours leave the reader to find by
# eye. So a run of deletions followed by a run of the same number of additions
# is taken as line-for-line replacements, as GitHub takes it, and each pair
# is diffed by word.
#
# A pair is compared as tokens - a word, a run of spaces, one other character
# - by longest common subsequence, which is the diff itself at the grain of
# tokens, and cheap at the size of a line. A pair with little in common is a
# line rewritten rather than edited, and marking most of it would be noise
# over the two colours that already say so: nothing is marked there.

"""
    word_marks(a, b) -> (score, ranges_a, ranges_b)

How alike two lines are, 0 to 1, and the ranges of `a` and of `b` - string
indices into each - that are not common to both, by token. A score under a
half is a rewrite rather than an edit of one line into the other, and the
ranges are then empty: marking most of both would be noise over what the two
colours already say.

The likeness is the share of the *shorter* line's *words* - identifiers and
numbers, not punctuation - that the two have in common. The shorter, so
that `else` becoming `else # a long remark` is the edit it is (an append is
the clearest edit there is) and not a line one-fifteenth alike; words, so
that `=`, `(` and `,` in common between two unrelated lines do not make
them alike. A line with no words at all - `}` against `};` - is measured
on what it has.
"""
function word_marks(a::AbstractString, b::AbstractString)
    none = (0.0, UnitRange{Int}[], UnitRange{Int}[])
    ta = collect(eachmatch(r"\w+|\s+|[^\w\s]", a))
    tb = collect(eachmatch(r"\w+|\s+|[^\w\s]", b))
    n, m = length(ta), length(tb)
    (n == 0 || m == 0 || n * m > 250_000) && return none
    # One function and a flag, not a closure assigned twice: `weight` below
    # calls it in the table's inner loop, and a variable a closure captures
    # and that is then assigned again is boxed, a dynamic call every cell.
    isword(t) = isletter(t.match[1]) || isdigit(t.match[1]) || t.match[1] == '_'
    marks_only = !(any(isword, ta) && any(isword, tb))
    word = t -> marks_only ? !all(isspace, t.match) : isword(t)
    # The LCS table, weighted: a word in common is worth three of a space or
    # a mark, so that between matching `frame` and matching the `.` beside
    # it - `frame.linfo` against `StackTraces.frame_mi(frame)` - the word
    # wins, which is what a reader would pair. Then walked back for which
    # tokens are shared.
    weight = t -> word(t) ? Int32(3) : Int32(1)
    L = zeros(Int32, n + 1, m + 1)
    for i in n:-1:1, j in m:-1:1
        L[i, j] = ta[i].match == tb[j].match ? L[i + 1, j + 1] + weight(ta[i]) :
                  max(L[i + 1, j], L[i, j + 1])
    end
    ina, inb = falses(n), falses(m)
    i = j = 1
    while i <= n && j <= m
        if ta[i].match == tb[j].match
            ina[i] = inb[j] = true; i += 1; j += 1
        elseif L[i + 1, j] >= L[i, j + 1]
            i += 1
        else
            j += 1
        end
    end
    shared = count(k -> ina[k] && word(ta[k]), 1:n)
    wa, wb = count(word, ta), count(word, tb)
    score = shared == 0 ? 0.0 : shared / min(wa, wb)
    score < 0.5 && return none
    (score, changed(ta, ina), changed(tb, inb))
end

"""The ranges of the tokens not marked common, adjacent ones joined - as
string indices, first character to last, which is what a `SubString` takes.
The last *byte* is not that for a token ending in `₃`: three bytes wide, and
an index into its middle is an error at the draw. So adjacency is judged by
the byte after, which is where the next token's offset lands."""
function changed(ts, common)
    out = UnitRange{Int}[]
    after = 0                   # the byte past the last range pushed
    for (k, t) in enumerate(ts)
        common[k] && continue
        r = t.offset:(t.offset + lastindex(t.match) - 1)
        (!isempty(out) && after == t.offset) ? (out[end] = first(out[end]):last(r)) :
            push!(out, r)
        after = t.offset + ncodeunits(t.match)
    end
    out
end

"""
    hunk_words(lines) -> Vector{Vector{UnitRange{Int}}}

For each line of a hunk, the ranges [`diffline`](@ref) is to mark. A run of
`-` lines followed by a run of `+` lines is one change: as many lines of
each, and they are paired line for line, as GitHub pairs them; otherwise
each `-` line takes the `+` line most like it that is still free and later
than the last one taken, so the pairs read in order - the one line that
became two is marked against the one of the two it became. A line whose
best match is a rewrite is left unmarked, and so is every line outside a
change. The ranges are into the whole line, marker included, so they go
straight back onto it.
"""
function hunk_words(lines::AbstractVector{<:AbstractString})
    out = [UnitRange{Int}[] for _ in lines]
    shift = rs -> [(first(r) + 1):(last(r) + 1) for r in rs]
    i, n = 1, length(lines)
    while i <= n
        startswith(lines[i], "-") || (i += 1; continue)
        d = i
        while d <= n && startswith(lines[d], "-"); d += 1; end
        a = d
        while a <= n && startswith(lines[a], "+"); a += 1; end
        dels, adds = i:(d - 1), d:(a - 1)
        if length(dels) == length(adds)
            for (x, y) in zip(dels, adds)
                _, ra, rb = word_marks(SubString(lines[x], 2), SubString(lines[y], 2))
                out[x], out[y] = shift(ra), shift(rb)
            end
        elseif !isempty(adds) && length(dels) * length(adds) <= 400
            from = first(adds)
            for x in dels
                best, at = 0.0, 0
                ma = mb = UnitRange{Int}[]
                for y in from:last(adds)
                    sc, ra, rb = word_marks(SubString(lines[x], 2), SubString(lines[y], 2))
                    sc > best && ((best, at, ma, mb) = (sc, y, ra, rb))
                end
                at == 0 && continue
                out[x], out[at] = shift(ma), shift(mb)
                from = at + 1
            end
        end
        i = a
    end
    out
end

"""
    delink(md) -> (text, urls)

Pull the URLs out of markdown links, leaving `label [n]` behind.

Term renders a link as its label followed by the raw URL, so a single Godbolt
or CI permalink - routinely several hundred characters - crowds out the comment
it appears in. The URLs come back as footnotes instead, one short line each.

**Numbered per node, and deliberately not deduplicated across a thread.**
julia#43994 draws eight footnote rows of which four are the same Nanosoldier
report - one for each nanosoldier comment. That is the way it stays: a comment
is a unit that has to read on its own, so `[1]` inside one has to mean the same
thing wherever it is drawn, and thread-wide numbering would make a marker depend
on which other comments happen to be loaded. The repetition is what exposed the
`linkify` tearing bug, but that was a substitution reading its own output and is
fixed there, in the one pass.

Scanned rather than matched with a regex: link targets nest parentheses, and
Godbolt in particular emits URLs full of them. A `[^)]+` target stops at the
first one and spills the rest of the URL into the prose as literal text.
"""
function delink(md::AbstractString)
    urls = String[]
    io = IOBuffer()
    i, n = firstindex(md), lastindex(md)
    while i <= n
        c = md[i]
        if c != '['
            write(io, c); i = nextind(md, i); continue
        end
        # label
        j = nextind(md, i); depth = 0; close = 0
        while j <= n
            md[j] == '[' && (depth += 1)
            if md[j] == ']'
                depth == 0 && (close = j; break)
                depth -= 1
            end
            j = nextind(md, j)
        end
        k = close == 0 ? 0 : nextind(md, close)
        if close == 0 || k > n || md[k] != '('
            write(io, c); i = nextind(md, i); continue
        end
        # target, with balanced parentheses
        d, m = 1, nextind(md, k)
        while m <= n && d > 0
            md[m] == '(' && (d += 1)
            md[m] == ')' && (d -= 1)
            d == 0 && break
            m = nextind(md, m)
        end
        if d != 0
            write(io, c); i = nextind(md, i); continue
        end
        label = strip(String(md[nextind(md, i):prevind(md, close)]))
        url = String(md[nextind(md, k):prevind(md, m)])
        if startswith(url, "http")
            push!(urls, url)
            write(io, isempty(label) ? "link" : label, " [", string(length(urls)), "]")
        else
            write(io, "[", label, "](", url, ")")
        end
        i = nextind(md, m)
    end
    (String(take!(io)), urls)
end

"""Shorten for display; the full URL still rides along in the hyperlink.

Elided in the *middle*, because urls in one thread differ at the end and agree
at the front: an issue and a comment on that issue, two jobs of one build, two
lines of one file. Cut at the tail, a pair like that draws as the same string
twice - which tells the reader nothing about which is which, and left `linkify`
with one display form and two targets, so both rows pointed at whichever came
first.

Two thirds head and one third tail: the head is the site, the repo and the
number, and the tail is the anchor that says which of them this one is.
"""
shortlink(u::AbstractString, w::Int = 58) = String(rowmid(u, w))

"""A hyperlink, in `link` so it reads as one: `text` with a `:link` over it,
which StyledStrings writes as OSC 8.

Zero width in a real terminal, and an annotation here, so it takes no columns
in any measure. The face is not decoration: terminals differ on whether they
mark hyperlinks themselves, and an unmarked link is one nobody discovers.

Note tmux only forwards OSC 8 from tmux 3.4; older versions strip it, and the
link silently becomes plain text.
"""
osc8(url, text) = linkrange(text, 1:ncodeunits(String(text)), url)

"""What GitHub links in prose without being asked: `#123`, `owner/repo#123`,
a sha, `owner/repo@sha`. One pattern, so one pass cannot read its own output.

A sha is seven to forty hex digits standing alone. GitHub links one only when
the commit exists, which cannot be asked here, so it has to have a digit and
a letter both: `1234567` is a number and `defaced` a word, and neither is a
commit anybody wrote down. Not after `/`, `@`, `#`, `.`, `-` or `&`, which is
where a sha sits inside a path, a url, a colour or an entity rather than in
the prose.
"""
const AUTOREF = r"(?<![\w/@.#&-])(?:([A-Za-z0-9][\w.-]*/[\w.-]+)(?:#(\d+)|@([0-9a-f]{7,40}))|#(\d+)|([0-9a-f]{7,40}))(?![\w-])"

"A url written out, left for `linkify`: a sha inside one is part of its path."
const BAREURL = r"https?://[^\s]+"

"""The url GitHub would give a reference `AUTOREF` matched, in `repo` unless
it names its own - or `nothing` for a hex run that is not a sha."""
function autoref_url(m::RegexMatch, repo::AbstractString)
    own, num, osha, lnum, lsha = m.captures
    sha = something(osha, lsha, "")
    !isempty(sha) && !(occursin(r"[0-9]", sha) && occursin(r"[a-f]", sha)) && return nothing
    where = something(own, repo)
    isempty(sha) ? string("https://github.com/", where, "/issues/", something(num, lnum)) :
                   string("https://github.com/", where, "/commit/", sha)
end

"""
    autolink(row, repo) -> Styled

A drawn row with its `#123`s and shas made hyperlinks, the way GitHub draws the
same prose - a list of commits, "fixed by #52011", "reverted in 3f2a9c1".

Made on the row after it is wrapped, like the footnotes and for the same
reason: `nodelines` is where the text and the repository it is about are both
in hand, and a pane hosted beside the thread never reaches `linkify`. Per row,
because a link cannot cross a row - the border and the padding would carry
it - and a reference wrapped in half is one that was not linked. Matched on
text, which `linkify` is warned off: but a reference is the whole of its own
display form, so two targets cannot share one.

Nothing inside a hyperlink already there, and nothing inside a url, which is
`linkify`'s to make whole. `repo` empty is a node that is not about a
repository's prose - a CI log, whose hex runs are tree hashes - and is left
alone.
"""
function autolink(r::AbstractString, repo::AbstractString)
    x = row(r)
    isempty(repo) && return x
    str = x.string
    occursin(r"[#0-9]", str) || return x
    urls = UnitRange{Int}[matchbytes(str, u) for u in eachmatch(BAREURL, str)]
    for m in eachmatch(AUTOREF, str)
        any(u -> m.offset in u, urls) && continue
        inlink(x, m.offset) && continue
        u = autoref_url(m, repo)
        u === nothing && continue
        x = linkrange(x, matchbytes(str, m), u)
    end
    x
end

"""Protect text from the markup that would eat it, and spell what GitHub
spells.

**Underscores inside words.** Julia's `Markdown` opens emphasis on an underscore
with letters on both sides, so `deliver_result and connect_to_peer` comes back
with `result and connect` italicised and both underscores *gone*. It takes two
to pair, so a single identifier survives and a comment mentioning two does not -
which is why this is easy to miss and why most comments hit it. CommonMark
forbids it: a `_` may open emphasis only if it is left-flanking and either not
right-flanking or preceded by punctuation, and one with a letter each side is
both and neither. GitHub renders the name intact.

**Not braces.** Term's markup is `{...}`, and before 2.2.1 `apply_style`
deleted anything in prose that looked like a tag, so this doubled them - Term's
own escape. Term escapes every leaf itself now (FedeClaudi/Term.jl#304), and a
brace doubled here as well came out doubled on screen.

**Emoji shortcodes.** GitHub draws `:robot:` as the character, from the table
in `emoji.jl`, and nothing downstream knows the names. One that follows a letter
or digit is left as typed, as is a name not in the table - `12:30:45` is a time.
The emoji is written without its U+FE0F, the selector asking for the picture:
`textwidth` counts `⚠️` as one column and a terminal honouring the selector
draws two, which pushes every column after it along by one; without it the
terminal draws the one column that was counted.

Code is left alone for both, since a backslash inside a code span prints as
a backslash and `:robot:` in code is what was meant: fenced blocks, indented blocks and inline spans are all
skipped. An unbalanced backtick makes
the rest of its line count as code, which errs towards changing nothing.
"""
const SHORTCODE = r"\G:([a-z0-9_+-]+):"
function escape_source(md::AbstractString)
    isword(c) = isletter(c) || isdigit(c) || c == '_'
    out = IOBuffer()
    fenced = false
    for (li, line) in enumerate(split(md, '\n'))
        li == 1 || write(out, '\n')
        if occursin(r"^\s*(```|~~~)", line)
            fenced = !fenced
            write(out, line); continue
        end
        if fenced || occursin(r"^(    |\t)", line)
            write(out, line); continue
        end
        incode, i = false, firstindex(line)
        while i <= lastindex(line)
            c = line[i]
            if c == '`'
                incode = !incode
                write(out, c)
            elseif !incode && c == ':' &&
                   (i == firstindex(line) || !isword(line[prevind(line, i)])) &&
                   (m = match(SHORTCODE, line, i)) !== nothing && haskey(EMOJI, m[1])
                write(out, replace(EMOJI[m[1]], '\ufe0f' => ""))
                i += ncodeunits(m.match)
                continue
            elseif !incode && c == '_' &&
                   i > firstindex(line) && isword(line[prevind(line, i)]) &&
                   nextind(line, i) <= lastindex(line) && isword(line[nextind(line, i)])
                write(out, "\\_")
            else
                write(out, c)
            end
            i = nextind(line, i)
        end
    end
    String(take!(out))
end

"""
    render_md(body, w) -> Vector{TermInput.MDRow}

A comment body as rows of exactly `w` columns, each with the line it was
written as: parsed as GitHub would (`escape_source`, `parse_gfm`) and drawn by
`markdown_rows` in the theme's `MD_STYLE`, with a newline in a paragraph a line break, as GitHub draws
one in a comment.

A bad comment must not take the pane down, but the reason has to be visible:
swallowing it once hid that markdown was not rendering at all, for want of an
`import Term`. It goes to `errors.log` rather than the footer, which only ever
had room for the first sentence - long enough to say a `MethodError` had
happened and not which method, and gone again on the next status. The log keeps
the backtrace, and the standing warning keeps pointing at it. The rows are then
the raw text, wrapped.
"""
function render_md(body::AbstractString, w::Int)
    try
        markdown_rows(parse_gfm(escape_source(body)), w; style = MD_STYLE[], breaks = true)
    catch e
        logerror!(e, catch_backtrace(), "render_md")
        rs = TermInput.MDRow[]
        for l in split(String(body), '\n'), (k, x) in enumerate(rowwrap(String(l), w))
            push!(rs, TermInput.MDRow(rowpad(x, w), rstrip(l), k == 1))
        end
        rs
    end
end

"Render a node's body at width `w`, cached - markdown is too slow to redo per frame."
function nodelines(n::Node, w::Int)
    n.cw == w && return n.cache
    lines = Styled[]
    srcline = Tuple{Bool,String}[]     # per line: starts a written line?
    mdrows = TermInput.MDRow[]
    if n.kind === :md
        body, urls = delink(n.raw)
        n.urls = urls
        # Rows already, at this width and each with its line: nothing below
        # wraps them again.
        isempty(strip(body)) || (mdrows = render_md(body, w))
    elseif n.kind === :diff
        # The marks go on here rather than into the node's text: the line a
        # review comment hangs off is worth seeing in the hunk, and it is not
        # part of the diff - so `srcline` is taken from the raw lines and a copy
        # of a marked row is the line as it was written. What goes on here is
        # the tail - a count past one, and the settled threads; the mark
        # itself stands in the gutter, which `rows` fills off the same table.
        raw = String.(split(n.raw, "\n"))
        marks = hunk_marks(n)
        words = hunk_words(raw)
        # `detab` after the words are marked, since the ranges index
        # the line as written; and on the styled line, under its faces.
        lines = Styled[detab(diffline(l, words[k])) * markof(get(marks, k, nothing))
                       for (k, l) in enumerate(raw)]
        srcline = [(true, rstrip(l)) for l in raw]
    else
        # A tab is drawn as its columns here too - a log, a range-diff - and
        # `src` is taken off the raw line, with the tab, the same as a diff's.
        # A fenced block lifted out of a comment carries its language, and is
        # coloured as the same block inside markdown would be; `src` stays
        # the raw line.
        raw = String.(split(n.raw, "\n"))
        lang = jstr(n.meta, :lang, "")
        drawn = haskey(n.meta, "lang") ?
            TermInput.highlighted_lines(lang, n.raw, MD_STYLE[]) :
            get(n.meta, "range", false) === true ? rangeline.(raw) : row.(raw)
        lines = Styled[detab(l) for l in drawn]
        srcline = [(true, rstrip(l)) for l in raw]
    end
    # An empty body is no rows, not one empty one.
    (length(lines) == 1 && isempty(lines[1])) && (lines = Styled[]; srcline = srcline[1:0])

    # A diff or a plain block is one line per line of its source, wrapped here.
    # Every row records the written line behind it, and whether it is the first
    # row of it: the wrap is ours to undo when copying, not something the
    # reader chose.
    #
    # The references in it are links, row by row, once the rows are final:
    # prose and plain text, never a diff, whose lines are code.
    repo = n.kind === :diff ? "" : jstr(n.meta, :repo, "")
    out, srcs = Styled[], Tuple{Int,String}[]
    for r in mdrows
        push!(out, autolink(r.text, repo))
        push!(srcs, (r.first ? 0 : 1, r.src))
    end
    for (idx, l) in enumerate(lines)
        (first_of, src) = srcline[idx]
        ws = rowwidth(l) <= w ? [l] : rowwrap(l, w)
        for (j, x) in enumerate(ws)
            push!(out, autolink(x, repo))
            push!(srcs, (first_of && j == 1 ? 0 : 1, src))
        end
    end
    if n.kind === :md && !isempty(n.urls)
        push!(out, row("")); push!(srcs, (0, ""))
        for (i, u) in enumerate(n.urls)
            # The hyperlink is made *here*, where the url and the text standing
            # for it are both in hand, rather than by matching that text in the
            # finished frame. A match cannot tell two urls apart once they elide
            # to the same string, and it has to be told not to write a link
            # inside a link; identity has neither problem. It is also the only
            # way these are links at all beside a hosted pane, which draws the
            # detail on its own and never reaches `linkify`.
            push!(out, faced(string("[", i, "]"), THEME.dim) * " " *
                       faced(osc8(u, shortlink(u, max(20, w - 8))), THEME.url))
            # The whole URL, not the elided form on screen: a shortened link is
            # the one thing on the row that is useless once pasted.
            push!(srcs, (0, string("[", i, "] ", u)))
        end
    end
    n.cache = out
    n.srcs = srcs
    n.cw = w
    n.cache
end

"""One row of a pane.

`text` is what prints, in its faces. `src` is the written line behind it, plain,
and `part` is 0 on the first display row of that line and 1 on every
continuation of it.

Those last two are the whole point of owning the mouse. The terminal only ever
saw the wrapped fragments and the pane borders, so a selection made with the
terminal's own copy gives you those. A selection made here is turned back into
the lines as they were written.
"""
struct Row
    node::Int
    header::Bool
    text::Styled
    src::String
    part::Int
    gutter::Styled   # a mark drawn over the pane's left border on this row,
                     # or nothing: a comment hanging off a line of a diff
end
Row(node, header, text, src, part) = Row(node, header, text, src, part, row(""))

"""The mark drawn at the right-hand end of a header, and clicked to copy the
node whole. Two joined squares, which is what everything else draws for this."""
const COPYMARK = "⧉"

"""Flatten open/closed nodes into rows, so selection and scrolling share one space.

Closing a node takes everything nested under it: the list is flat, so "nested"
means the run of nodes deeper than it that follows it. That is what makes a
folded `<details>` disappear with the comment it was written in, and the
outdated review comments disappear with the header that counts them.

`marks` draws the copy mark on each header. It is display only - the number of
rows, and every row's node, header flag, part and `src`, are the same either way
- so the callers that ask for rows in order to index them need not care which
they got. It is off by default and on where the pane is actually drawn, since a
mark is an offer to click and the mouse can be handed back to the terminal.

`at` is the same kind of thing: given, a header whose node carries the time of
what it heads (`meta["at"]` - a comment, a push, the body) gets how long ago
that was, dim, after its words. Taken out of the rule like the mark, so the
header wraps the same with it and without it and no row moves; and worked out
here, per frame, because an age kept on the node would be the age at the moment
the thread was fetched.
"""
function rows(nodes::Vector{Node}, w::Int, marks::Bool = false;
              at::Union{Nothing,DateTime} = nothing)
    out = Row[]
    hide = -1                 # while >= 0, skip anything deeper than this
    for (i, n) in enumerate(nodes)
        if hide >= 0
            n.depth > hide && continue
            hide = -1
        end
        pad = " "^(2 * n.depth)
        iw = max(20, w - 2 * n.depth)
        # Prose carrying on after a block gets no header and no fold: it is the
        # comment above it still talking, and everything below is what it has
        # instead of a header of its own.
        if isbare(n)
            for (j, l) in enumerate(nodelines(n, iw))
                (part, src) = n.srcs[j]
                push!(out, Row(i, false, pad * l, src, part))
            end
            continue
        end
        # A blank row above each top-level header, except the first. The header
        # draws a rule out to the edge of the pane, and without this the body of
        # the comment before it ends flush against that rule and the eye has
        # nothing to stop on. It is a header row, and a continuation of one, so
        # that everything which counts body rows - `hunk_line_at` maps them to
        # diff lines - counts what it did before, and so a copy taken across it
        # is the text as written rather than the spacing it is drawn with.
        (n.depth == 0 && !isempty(out)) && push!(out, Row(i, true, "", "", 1))
        # Open, the header loses its peek: the same words are on the row
        # underneath it, and reading them twice is how a comment looks when it
        # has been said twice. `byline` is what is left - who and when, and
        # where a review comment was pointing - and only the two headers that
        # carry a peek have one.
        full = n.open ? "▾ " * row(get(n.meta, "byline", n.header)) : "▸ " * n.header
        # Wrapped, not cut: a header is a byline plus a peek at the body, and on
        # a narrow pane cutting it loses the half that says what the comment is
        # about. Continuations are indented under the text, so the fold marker
        # still reads as belonging to one row.
        hls = rowwidth(full) <= iw ? [full] : rowwrap(full, iw - 2)
        hsrc = jstr(n.meta, :src, String(n.header))
        u = jstr(n.meta, :url, "")
        # Room kept for the mark, and taken out of the rule rather than out of
        # the header: the words are the row.
        markw = marks ? textwidth(COPYMARK) + 1 : 0
        ago = at === nothing ? "" : ago_str(jstr(n.meta, :at, ""), at)
        for (k, hl) in enumerate(hls)
            txt = k == 1 ? hl : "  " * hl
            core = faced(isempty(u) ? txt : osc8(u, txt), THEME.bold)
            width = rowwidth(txt)
            if k == length(hls)
                # How long ago, after the words and before the rule, where
                # there is room for it: a header that fills the pane keeps its
                # words and says the date alone.
                if !isempty(ago) && iw - width - markw >= textwidth(ago) + 1
                    core = core * " " * faced(ago, THEME.dim)
                    width += 1 + textwidth(ago)
                end
                # A rule out to the edge of the pane on the last row of the
                # header, so where one comment ends and the next begins is
                # visible at a glance rather than found by reading. Only at the
                # top level: a nested block stays subordinate to the comment it
                # was written in.
                if n.depth == 0
                    gap = iw - width - 1 - markw
                    gap > 2 && (core = core * " " * faced("─"^gap, THEME.dim);
                                width += 1 + gap)
                end
                # And the mark, right-aligned on the row a click has to land on.
                # Only where it fits: a header that fills the pane keeps its
                # words, and loses the offer.
                if markw > 0 && iw - width >= markw
                    core = core * " "^(iw - width - markw) * " " * faced(COPYMARK, THEME.dim)
                end
            end
            push!(out, Row(i, true, pad * core, hsrc, k == 1 ? 0 : 1))
        end
        if !n.open
            hide = n.depth
            continue
        end
        ls = nodelines(n, iw)                # fills n.srcs alongside n.cache
        # The line a thread hangs off gets its mark in the gutter - over the
        # pane's border, where a margin note goes and the eye already is -
        # rather than after the text, where it was and was not seen. The row
        # is counted back to its diff line the way `hunk_line_at` counts, so
        # the mark lands on the first row of a wrapped line, once.
        hm = n.kind === :diff ? hunk_marks(n) : nothing
        k = 0
        for (j, l) in enumerate(ls)
            (part, src) = n.srcs[j]
            part == 0 && (k += 1)
            m = (hm === nothing || part != 0) ? nothing : get(hm, k, nothing)
            g = (m === nothing || m[1] == 0) ? row("") : faced("💬", THEME.accent)
            push!(out, Row(i, false, pad * l, src, part, g))
        end
    end
    out
end

"Vertical slice with the cursor's node kept in view: the rows, and the top."
function window(rs::Vector{Row}, cur, top, h)
    isempty(rs) && return (Row[], 1)
    top = clamp(top, 1, max(1, length(rs)))
    if cur !== nothing
        cur < top && (top = cur)
        cur > top + h - 1 && (top = cur - h + 1)
    end
    top = clamp(top, 1, max(1, length(rs) - h + 1))
    (rs[top:min(end, top + h - 1)], top)
end

