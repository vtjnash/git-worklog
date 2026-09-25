# Where things are on screen. Pane widths, the split, hit-testing a click back
# to a pane, the selection, highlighting, and finding the url under a column.

"""The widest the item list is ever drawn.

Refs and titles, and neither gets longer on a bigger screen. Past this the
column is padding, and padding taken from the thread beside it.
"""
const LIST_MAX = 52

"""The widest the thread is drawn *beside a child*.

Half again the list's own cap, which is enough for a comment to read as prose
and not so much that a line runs the width of a page. Only `split_box` uses it:
with no child there, the thread is the column that fills.
"""
const DETAIL_MAX = 78

"""
    panewidths(w) -> (side, lw, rw)

How wide the two columns are. `side` is false below the width where two columns
are worth having, and then each pane is the full screen with the panes stacked.

**The left column is the one with a cap; the right fills what is left.** The
list is bounded twice - never past half the screen, and never past `LIST_MAX` -
because refs and titles do not get longer on a bigger display, and every column
past that is padding taken from the thread. The thread has no cap here: it is
what a wider screen is *for*, and giving it the remainder is what keeps the
frame exactly as wide as the terminal.

`split_box` divides on the same rule one level out, with the thread as the
capped column and the terminal as the one that fills.
"""
function panewidths(w::Int)
    w >= 110 || return (false, w, w)
    lw = min(w ÷ 2, LIST_MAX)
    (true, lw, w - lw)
end

leftw(w::Int) = panewidths(w)[2]

"""
    layout(w, h, nmeta) -> NamedTuple

Where the three panes sit, in screen coordinates.

Shared by `render_frame` and the mouse handler because the two must agree
exactly: a click only maps to the row under it if the geometry it is measured
against is the geometry that was drawn. This used to be worked out twice, and
the copies had drifted - the key handler measured the detail pane six columns
narrower than the renderer did, so long lines wrapped differently in the two and
`n`, `↵` and `[`/`]` acted on the wrong node once a thread ran past a screenful.

The metadata pane goes under the item list rather than beside the detail: ten
item numbers at a time is plenty, and the thing being read is the one that wants
the full height. `nmeta` is how many lines it has to show, so it takes what it
needs and the list keeps the rest.
"""
function layout(w::Int, h::Int, nmeta::Int = 0)
    side, lw, rw = panewidths(w)
    # Row 1 is the title bar and the last two the footer; panes fill the rest.
    # The key help outgrew one line, and letting it truncate hid half of it.
    bodyh = max(6, h - 3)          # title bar, panes, then two rows of footer
    if side
        # The detail keeps the full height; the left column is split between the
        # list and the metadata, which takes what it needs and leaves the rest.
        mh = clamp(nmeta + 2, 3, max(3, bodyh - 5))
        lh, rh = bodyh - mh, bodyh
    else
        lh = clamp(bodyh ÷ 3, 3, 12)
        rest = bodyh - lh
        # Three stacked panes need the room to be three panes. Below that the
        # metadata goes rather than squeezing what is being read.
        mh = rest >= 9 ? clamp(nmeta + 2, 3, rest - 6) : 0
        rh = rest - mh
    end
    (side = side,
     lw = lw, lh = lh, lx = 1, ly = 2,
     mw = lw, mh = mh, mx = 1, my = 2 + lh,
     rw = rw, rh = rh, rx = side ? lw + 1 : 1, ry = side ? 2 : 2 + lh + mh,
     liw = lw - 4, miw = lw - 4, riw = rw - 4,   # inner: 1 border + 1 pad a side
     page = max(1, rh - 3), lpage = max(1, lh - 3))
end

"""
    beside_layout(lw, h) -> NamedTuple

The geometry of the detail pane drawn as the left column beside a hosted pane
or a composer: `lw` columns and the full height, starting at the top left,
with no list and no metadata pane. The same shape `layout` gives, so `hitpane`
and the mouse handler read either; the two absent panes are zero wide, which
is a rectangle nothing lands in.
"""
beside_layout(lw::Int, h::Int) =
    (side = true,
     lw = 0, lh = 0, lx = 1, ly = 1,
     mw = 0, mh = 0, mx = 1, my = 1,
     rw = lw, rh = h, rx = 1, ry = 1,
     liw = 0, miw = 0, riw = lw - 4,
     page = max(1, h - 3), lpage = 1)

"""
    hitpane(L, x, y) -> (pane, row, col) or nothing

Turn a screen position into a pane and a position inside its content area.
`row` is 1-based within the pane's content, so it indexes the window that pane
last drew; `col` likewise. Borders, the title bar and the footer return nothing.
"""
function hitpane(L, x::Int, y::Int)
    for (which, px, py, pw, ph, iw) in ((:list, L.lx, L.ly, L.lw, L.lh, L.liw),
                                        (:meta, L.mx, L.my, L.mw, L.mh, L.miw),
                                        (:detail, L.rx, L.ry, L.rw, L.rh, L.riw))
        (px <= x <= px + pw - 1 && py + 1 <= y <= py + ph - 2) || continue
        c = x - px - 1
        return 1 <= c <= iw ? (which, y - py, c) : nothing
    end
    nothing
end

"The selected rows in `nrow` coordinates, low to high, or nothing."
selrange(st::BState) = (st.sela == 0 || st.selb == 0) ? nothing :
                       (min(st.sela, st.selb), max(st.sela, st.selb))

clearsel!(st::BState) = (st.sela = 0; st.selb = 0; st.anchor = 0; nothing)

"""Carry the cursor and the selection across a change of pane width.

`nrow`, `anchor`, `sela` and `selb` are indices into the rows, and the rows are
made again at whatever width the pane is drawn at: the thread wrapped to half
the screen beside a composer has other rows than the same thread wrapped to
the browser's own pane, and an index taken against one names some other line
in the other. That is what put the highlight on the wrong rows once `C` was
open - the comment itself was right, resolved before the pane moved.

Each index is turned back into what it stood on - a node and the written line
within it, the way `hunk_line_at` counts - at the width it was taken at, and
forward into a row at the new one. The low end of a selection lands on the
first row of its line and the high end on the last, so a line the new width
wraps across more rows is still covered whole, which is what `y` copies and
`c` comments on either way.
"""
function rewrap!(st::BState, from::Int, to::Int)
    (from <= 0 || from == to) && return
    old, new = rows(st.nodes, from), rows(st.nodes, to)
    (isempty(old) || isempty(new)) && return
    st.nrow = samerow(old, new, st.nrow, false)
    st.anchor > 0 && (st.anchor = samerow(old, new, st.anchor, false))
    if st.sela > 0 && st.selb > 0
        a, b = st.sela, st.selb
        st.sela = samerow(old, new, a, a > b)
        st.selb = samerow(old, new, b, b >= a)
    end
    nothing
end

"""Where row `j` of `from` stands in `to`: the first row of the same written
line of the same node - or its last, with `last`. The rows of a node at either
width run over the same written lines, each starting a `part == 0` row, so the
line is its ordinal among those; ordinal zero is the spacer row above a
top-level header, which is the node's first row."""
function samerow(from::Vector{Row}, to::Vector{Row}, j::Int, last::Bool)
    j = clamp(j, 1, length(from))
    node = from[j].node
    k = count(i -> from[i].node == node && from[i].part == 0, 1:j)
    idx = findall(r -> r.node == node, to)
    isempty(idx) && return clamp(j, 1, length(to))
    starts = filter(i -> to[i].part == 0, idx)
    (k == 0 || isempty(starts)) && return first(idx)
    k = min(k, length(starts))
    last || return starts[k]
    k < length(starts) ? starts[k + 1] - 1 : idx[end]
end

"""Rebuild the selected text from the nodes rather than from the screen.

One line out per *logical* line covered: a paragraph the pane wrapped across
five rows comes back as the single line it was written as, without the borders
between panes and without the colours. A selection that begins partway into a
wrapped line still takes the whole line, because the wrap point is ours.
"""
function selection_text(st::BState, w::Int)
    r = selrange(st)
    r === nothing && return ""
    rs = rows(st.nodes, w)
    isempty(rs) && return ""
    a, b = clamp(r[1], 1, length(rs)), clamp(r[2], 1, length(rs))
    out = String[]
    for i in a:b
        (i == a || rs[i].part == 0) && push!(out, rs[i].src)
    end
    join(out, "\n")
end

"""Lay a background over a whole row, re-arming it after every reset.

A row carries its own colours, and the `\\e[0m` that ends one of them ends the
background too - so a highlight applied naively stops at the first styled word
on the line. `rearm` is the general form; the background going back to the
default counts as an ending here as much as a reset does, which is what lets a
search hit inside the cursor's row end without taking the cursor with it.
"""
hlrow(s::AbstractString, bg::AbstractString) =
    isempty(bg) ? String(s) :
    string(bg, rearm(s, bg, (THEME.reset, THEME.no_bg)), THEME.reset)

"""Lay `quiet` over a whole row, re-arming after every reset - the list while
the keys are on the reading side. The cursor stays under it, and so does the
weight where the theme gives `quiet_bold` one: the row is drawn with that in
place of `bold` first, since `bold` in a 256-colour theme carries the full
foreground and would come out white over any grey laid under it, and `bold`
over the `dim` attribute is the pair terminals disagree about. So the list says
the same things, quieter, and that it is not where the keys go."""
quietrow(s::AbstractString) =
    isempty(THEME.quiet) ? String(s) :
    string(THEME.quiet, rearm(s, THEME.quiet, (THEME.reset, THEME.quiet_off)), THEME.reset)

"""Lay a background over given ranges of a row's *plain* characters.

The row carries escapes, so a character offset in the text it prints is not an
offset into the string. This walks it, counting only what would appear, and ends
each span with `\\e[49m` rather than a reset - so a match inside coloured text
keeps its colour, and `hlrow` can still lay the cursor's background over the top.
"""
function hlspan(s::AbstractString, ranges::Vector{UnitRange{Int}}, bg::AbstractString;
               off::AbstractString = THEME.no_bg)
    isempty(ranges) && return s
    io, i, n, open_ = IOBuffer(), firstindex(s), 0, false
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            write(io, m.match); i += ncodeunits(m.match); continue
        end
        n += 1
        inspan = any(r -> n in r, ranges)
        inspan && !open_ && write(io, bg)
        !inspan && open_ && write(io, off)
        open_ = inspan
        write(io, s[i]); i = nextind(s, i)
    end
    open_ && write(io, off)
    String(take!(io))
end

"""Character range of a row's own text within the line it came from.

A row shows a *contiguous* piece of `src`: the wrapping only ever cut the line,
it never rewrote it. So the piece can be found by looking for it, and neither
`awrap` nor `unwrap_map` has to be taught to report offsets - which for
`unwrap_map` would have meant recording spans through an alignment that compares
whitespace-collapsed text, where the offsets do not survive.

`from` carries a cursor along the logical line so that a row repeating text from
earlier in the same line lands on its own copy. `indent` is the depth padding
`rows` added, which is not part of the source. Trailing space is not either:
`src` is stripped of it and a row may be padded out to the pane.

`nothing` when the row is not a piece of its source at all - a footnote row
shows an elided URL; a row with a tab in it shows the tab as spaces (`detab`)
- and the caller falls back to marking what is visible.
"""
function row_span(row::Row, indent::Int, from::Int)
    full = collect(astrip(row.text))
    length(full) > indent || return nothing
    body = collect(rstrip(String(full[(indent + 1):end])))
    hay, m = collect(row.src), length(body)
    m == 0 && return nothing
    for i in max(1, from):(length(hay) - m + 1)
        ok = true
        for j in 1:m
            hay[i + j - 1] == body[j] || (ok = false; break)
        end
        ok && return i:(i + m - 1)
    end
    nothing
end

"""A url written in text. Deliberately not a parser: what is wanted is the run
of characters somebody would have clicked on, and the closers are the ones that
end a url in prose rather than the ones a url may not contain."""
const URL_RE = r"https?://[^\s<>\"'`\)\]}]+"

"""Where in a row's written line a click at display column `col` landed, as a
character index into `src`, or 0.

The answer comes out of `src` and not off the row, because wrapping cuts a long
line in half and half of one is not what anybody pointed at. That is the same
reason `row_span` exists, and it is what maps the column back.
"""
function src_at(st::BState, r::Row, col::Int)
    txt = astrip(r.text)
    isempty(txt) && return 0
    ind = 2 * st.nodes[clamp(r.node, 1, length(st.nodes))].depth
    # Display column to character index, walking widths rather than counting
    # characters: one wide character earlier on the row moves everything after it.
    ci, acc = 0, 0
    for (k, c) in enumerate(txt)
        acc += textwidth(c)
        acc >= col && (ci = k; break)
    end
    ci == 0 && return 0
    sp = row_span(r, ind, 1)
    # Through the span when the row is a piece of its source, and straight
    # across when it is not.
    j = sp === nothing ? ci : first(sp) + (ci - ind) - 1
    (j < 1 || j > length(r.src)) ? 0 : j
end

"""The url a click at display column `col` landed on, or empty.

Two kinds of link are answered for here and neither is an OSC 8 hyperlink: a
node header is one of those and the terminal follows it itself, but a url
written in a body is not, and owning the mouse means it can be *acted on*
rather than handed to a terminal that may or may not know what to do with it.

A footnote row shows an elided url and carries the whole one in its source, so
anywhere on that row is that link. Anything else is a url written in the text,
where a click has to land inside it - the rest of the row is prose somebody may
want to select instead.

The answer comes out of `src` and not off the row, because wrapping cuts a long
url in half and half a url is the one thing that is useless once pasted. That is
the same reason `row_span` exists, and it is what maps the column back.
"""
function link_at(st::BState, r::Row, col::Int)
    fn = match(r"^\[\d+\]\s+(\S+)\s*$", r.src)
    fn === nothing || return String(fn[1])
    j = src_at(st, r, col)
    j == 0 && return ""
    for m in eachmatch(URL_RE, r.src)
        lo = length(SubString(r.src, 1, prevind(r.src, m.offset))) + 1
        lo <= j <= lo + length(m.match) - 1 && return String(m.match)
    end
    ""
end

"""The word a double click landed on: the run of non-space around it.

Whitespace-delimited rather than by letters, because what gets double-clicked
here is a path, an identifier with a dot in it, a `repo#1234`, a sha - and a
"word" that stops at the punctuation inside those is one that has to be
reassembled by hand after pasting. A url is a word too, and the whole of one:
`link_at` answers first, so a click inside one copies past the wrapping.

Sentence punctuation is trimmed off the end and a code span's backticks off
both: `typeinfer.jl:544,` is a comma somebody wrote after the thing they meant,
and the backticks say the thing is code rather than being part of it. A copy of
a whole line keeps them, deliberately - see the code-span note in `markdown.jl`
- because there the formatting is what is being copied. One word is not.
"""
function word_at(st::BState, r::Row, col::Int)
    u = link_at(st, r, col)
    isempty(u) || return u
    j = src_at(st, r, col)
    (j == 0 || isspace(r.src[j])) && return ""
    lo = hi = j
    while lo > firstindex(r.src)
        p = prevind(r.src, lo)
        isspace(r.src[p]) && break
        lo = p
    end
    while hi < lastindex(r.src)
        q = nextind(r.src, hi)
        isspace(r.src[q]) && break
        hi = q
    end
    String(strip(c -> c == '`', rstrip(c -> c in ".,;:!?", r.src[lo:hi])))
end

"""What the copy mark on a header copies: the node as written, and everything
nested under it - which is exactly what folding that header hides.

Bodies and not headers: a comment's header is a byline and a peek at the words
below it, and a code block's is `julia  9 lines`. Neither is anything anybody
wants in a paste.

A hunk is the exception, and copies only its own lines. What is nested under one
is a conversation *about* the code rather than part of it: `attach_comments`
puts the review comments there so that they fold with the hunk, which is a
choice about the screen and not a claim that they are the same thing.
"""
function node_text(nodes::Vector{Node}, i::Int, w::Int)
    n = nodes[i]
    idx = [i]
    if n.kind !== :diff
        for j in (i + 1):length(nodes)
            nodes[j].depth > n.depth || break
            push!(idx, j)
        end
    end
    out = String[]
    for j in idx
        nj = nodes[j]
        nodelines(nj, max(20, w - 2 * nj.depth))    # which is what fills `srcs`
        isempty(out) || push!(out, "")
        for (part, src) in nj.srcs
            part == 0 && push!(out, src)
        end
    end
    join(out, "\n")
end

"""Put text on the clipboard.

OSC 52, which is the one copy that works from inside a terminal somebody else
owns - over ssh, and through tmux. It is disabled by default in some terminals,
which is why every caller also says in the footer what it put there.
"""
clip(text::AbstractString) = print("\e]52;c;", Base64.base64encode(text), "\a")

"""Every place `q` appears in `text`, as ranges of plain characters.

A string is a substring (the list's search); a `Regex` is the detail pane's
(`searchre`), and a match of nothing marks nothing."""
function findhits(text::AbstractString, re::Regex)
    out = UnitRange{Int}[]
    isempty(text) && return out
    for m in eachmatch(re, text)
        isempty(m.match) && continue
        lo = length(text, 1, prevind(text, m.offset)) + 1
        push!(out, lo:(lo + length(m.match) - 1))
    end
    out
end
function findhits(text::AbstractString, q::AbstractString)
    out = UnitRange{Int}[]
    (isempty(q) || isempty(text)) && return out
    hay, needle = lowercase(text), lowercase(q)
    n = length(needle)
    start = 1
    cs = collect(hay)
    while start + n - 1 <= length(cs)
        if String(cs[start:(start + n - 1)]) == needle
            push!(out, start:(start + n - 1))
            start += n
        else
            start += 1
        end
    end
    out
end
