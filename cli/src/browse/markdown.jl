# A comment body becomes rows of styled text. Term does the markdown and this
# does everything Term cannot be trusted with: escaping what would read as its
# markup, code spans, the wrap map, and the fold state a row belongs to.

"""Term reads `{...}` as markup, and comment text is not ours to trust - a
comment containing braces would otherwise be swallowed or mangled."""
esc(s) = replace(s, "{" => "{{", "}" => "}}")

"""Truncate to `w` display columns.

Term wraps content that overflows, which turns a list of items into a wall of
continuation lines and makes it unscannable. Rows that must stay one line per
entry are cut here first.
"""
function fit1(s::AbstractString, w::Int)
    w <= 1 && return ""
    textwidth(s) <= w && return s
    out, acc = IOBuffer(), 0
    for c in s
        acc + textwidth(c) > w - 1 && break
        print(out, c); acc += textwidth(c)
    end
    String(take!(out)) * "…"
end

const AB, AD, AR = "\e[1m", "\e[2m", "\e[0m"

function diffline(l)
    # File headers must be tested before the bare +/- cases, or `+++`/`---`
    # colour as additions and deletions.
    startswith(l, "@@") && return "\e[36m" * l * AR
    (startswith(l, "+++") || startswith(l, "---") || startswith(l, "index ")) &&
        return AD * l * AR
    startswith(l, "+") && return "\e[32m" * l * AR
    startswith(l, "-") && return "\e[31m" * l * AR
    String(l)
end

"""
    delink(md) -> (text, urls)

Pull the URLs out of markdown links, leaving `label [n]` behind.

Term renders a link as its label followed by the raw URL, so a single Godbolt
or CI permalink - routinely several hundred characters - crowds out the comment
it appears in. The URLs come back as footnotes instead, one short line each.

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

"Shorten for display; the full URL still rides along in the hyperlink."
function shortlink(u::AbstractString, w::Int = 58)
    length(u) <= w && return u
    u[1:prevind(u, w - 2)] * "…"
end

"""OSC 8 hyperlink, underlined so it reads as one.

Zero width in a real terminal, so it is safe to apply after layout. The
underline is not decoration: terminals differ on whether they mark hyperlinks
themselves, and an unmarked link is one nobody discovers.

Note tmux only forwards OSC 8 from tmux 3.4; older versions strip it, and the
link silently becomes plain text.
"""
osc8(url, text) = string("\e]8;;", url, "\e\\\e[4m", text, "\e[24m\e]8;;\e\\")

"""Protect text from the two markup layers that would eat it.

**Underscores inside words.** Julia's `Markdown` opens emphasis on an underscore
with letters on both sides, so `deliver_result and connect_to_peer` comes back
with `result and connect` italicised and both underscores *gone*. It takes two
to pair, so a single identifier survives and a comment mentioning two does not -
which is why this is easy to miss and why most comments hit it. CommonMark
forbids it: a `_` may open emphasis only if it is left-flanking and either not
right-flanking or preceded by punctuation, and one with a letter each side is
both and neither. GitHub renders the name intact.

**Braces.** Term's markup is `{...}`, and `apply_style` deletes anything that
looks like a tag - so `a Tuple{Type{S{N}}} sig` printed as `a Tuple sig`, with
the type silently removed. Doubling is Term's own escape (`escape_brackets`),
and a doubled brace survives `parse_md` and is collapsed by `render_md`. It
cannot be done to `parse_md`'s *output*, which is where the braces of Term's own
tags live.

Code is left alone for both, since a backslash inside a code span prints as a
backslash and `parse_md` already escapes braces there itself: fenced blocks,
indented blocks and inline spans are all skipped. An unbalanced backtick makes
the rest of its line count as code, which errs towards changing nothing.
"""
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
            elseif !incode && (c == '{' || c == '}')
                write(out, c, c)                 # Term's escape is doubling
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

# Term styles a code span's *delimiters* and not what is between them, and the
# default is a pale yellow - the loudest thing on a screen of prose, for what is
# usually a variable name. Setting the theme to a colour nothing else emits
# makes the delimiters findable afterwards, which is the only way to reach the
# span itself.
const MD_CODE_SENTINEL = "\e[38;2;255;0;255m"
const CODE_DELIM = MD_CODE_SENTINEL * "`" * "\e[39m"
const CODEBG = "\e[48;5;238m"

"""Draw a code span as a quiet background instead of loud punctuation.

The backticks stay, dimmed. They could go - the background marks the span on its
own - but they are part of what a copy produces, and pasting `Sockets.bind` back
into a comment without them loses the formatting the author put there.

Only a pair on one line is rewritten. Term wraps before this sees the text, so a
span it split has one delimiter on each of two lines and no background could be
drawn across the break; a lone delimiter becomes a dim backtick, which is what
it would have been with none of this.
"""
function style_code_spans(str::AbstractString)
    occursin(CODE_DELIM, str) || return String(str)
    tick = "\e[2m`\e[22m"                   # dim, without resetting the background
    out = IOBuffer()
    for (i, line) in enumerate(split(str, '\n'))
        i == 1 || write(out, '\n')
        parts = split(line, CODE_DELIM)
        nd = length(parts) - 1
        write(out, parts[1])
        d = 1
        while d <= nd
            if d + 1 <= nd
                write(out, CODEBG, tick,
                      replace(String(parts[d + 1]), AR => AR * CODEBG), tick, NOBG)
                write(out, parts[d + 2])
                d += 2
            else
                write(out, "\e[2m`\e[0m", parts[d + 1])
                d += 1
            end
        end
    end
    # Term can also wrap *between* the colour and the backtick it applies to,
    # leaving the sentinel alone on a line with no pair to find. Anything still
    # carrying it becomes dim, so a stray delimiter is quiet rather than
    # magenta.
    replace(String(take!(out)), MD_CODE_SENTINEL => "\e[2m")
end

"""Rewrite the parsed markdown into what Term can actually render.

One walk of the tree, because both of the things it fixes are Term crashing on
a shape Julia's parser produces perfectly happily - and each one takes the
*whole* comment down to raw text, since `render_md` can only catch the throw,
not the node that caused it.

**A table inside a list or a block quote.**
`Term.TermMarkdown.parse_md(::Markdown.Table)` accepts `width` and nothing else,
but Term's own recursion passes `inline` to whatever it finds nested. A table
there is a `MethodError`. Keyword arguments take no part in dispatch, so this
cannot be fixed by adding a method: any definition for `Markdown.Table` would
replace Term's rather than extend it. The table is moved instead - nested, it
becomes a code block of its own markdown source, which keeps every cell and
loses only the box drawing; at the top level, where Term renders it properly, it
is left alone. Upstream the fix is one `inline = false` in a signature.

**An empty list item.** `parse_md(::Markdown.List)` indexes `[1]` on every item,
and `- a` / `-` / `- b` parses to items of length `[1, 0, 1]`, so a lone `-`
is a `BoundsError`. The empty item is filled with an empty paragraph rather than
dropped: the bullet was typed, so it should appear, and dropping one out of an
ordered list would renumber everything after it.
"""
for_term(x, nested::Bool = false) = x
for_term(t::Markdown.Table, nested::Bool) =
    nested ? Markdown.Code("", strip(sprint(Markdown.plain, Markdown.MD(t)))) : t
for_term(md::Markdown.MD, nested::Bool = false) =
    Markdown.MD([for_term(c, nested) for c in md.content])
for_term(l::Markdown.List, nested::Bool) =
    Markdown.List([isempty(item) ? Any[Markdown.Paragraph(Any[""])] :
                   Any[for_term(b, true) for b in item] for item in l.items],
                  l.ordered, l.loose)
for_term(q::Markdown.BlockQuote, nested::Bool) =
    Markdown.BlockQuote([for_term(c, true) for c in q.content])
for_term(a::Markdown.Admonition, nested::Bool) =
    Markdown.Admonition(a.category, a.title, [for_term(c, true) for c in a.content])

"""Markdown to ANSI at one width.

Term is handed *markup*, not ANSI: `apply_style` here would bake in escape codes
that Term then counts toward the line width, wrapping content that already fits.
Its brace doubling is undone afterwards - `parse_md` escapes `{` as `{{` and
nothing downstream collapses it, so Julia type signatures reach the screen as
`Tuple{{Type{{S{{N, Tup}}}`. That is safe here only because `apply_style` has
already consumed the markup.

A bad comment must not take the pane down, but the reason has to be visible:
swallowing it once hid that markdown was not rendering at all, for want of an
`import Term`. It goes to `errors.log` rather than the footer, which only ever
had room for the first sentence - long enough to say a `MethodError` had
happened and not which method, and gone again on the next status. The log keeps
the backtrace, and the standing warning keeps pointing at it.
"""
function render_md(body::AbstractString, w::Int)
    try
        a = apply_style(string(Term.TermMarkdown.parse_md(
                for_term(Markdown.parse(escape_source(body))); width = max(20, w))))
        style_code_spans(replace(a, "{{" => "{", "}}" => "}"))
    catch e
        logerror!(e, catch_backtrace(), "render_md")
        String(body)          # the raw text; this path bypasses Term entirely
    end
end

"Wide enough that no paragraph wraps, narrow enough that a padded box is cheap."
const WIDE_MD = 2000

"""
    unwrap_map(narrow, wide) -> Vector{Tuple{Bool,String}}

For each display line, whether it starts a written line and what that line says.

Term wraps prose itself, at whatever width it is handed, so a paragraph is
already in pieces before `awrap` ever sees it - `awrap` only ever gets the lines
Term declined to wrap. Rendering a second time at a width nothing reaches gives
the unwrapped form, but that render cannot be shown: a code block or a table is
a box, and Term pads the box out to the full width.

So render twice and align the two. Each wide line is matched against as many
narrow lines as it takes to reproduce it, ignoring where the spaces fell. What
fails to match - the boxes, which are the same shape at both widths - stands for
itself, and the walk carries on in step.
"""
function unwrap_map(narrow::Vector{String}, wide::Vector{String})
    norm(s) = replace(strip(astrip(s)), r"\s+" => " ")
    plain(s) = rstrip(astrip(s))
    out = Vector{Tuple{Bool,String}}(undef, length(narrow))
    i, j = 1, 1
    while i <= length(narrow)
        if isempty(norm(narrow[i]))
            # A blank row stands for itself, and takes a blank on the wide side
            # with it: letting one be swallowed into the next paragraph's group
            # puts the two walks out of step for the rest of the comment.
            out[i] = (true, ""); i += 1
            j <= length(wide) && isempty(norm(wide[j])) && (j += 1)
            continue
        end
        if j > length(wide)
            out[i] = (true, plain(narrow[i])); i += 1; continue
        end
        target = norm(wide[j])
        if isempty(target)
            j += 1; continue
        end
        acc, k, hit = "", i, false
        while k <= length(narrow)
            piece = norm(narrow[k])
            isempty(piece) && break
            # Term breaks a long token - a URL, usually - with no space at the
            # break, so rejoining with one does not reproduce the wide line.
            # Try it both ways and take whichever the wide line agrees with.
            cand = if isempty(acc)
                piece
            elseif startswith(target, string(acc, " ", piece))
                string(acc, " ", piece)
            else
                string(acc, piece)
            end
            startswith(target, cand) || break
            acc = cand; k += 1
            acc == target && (hit = true; break)
        end
        if hit
            # The wide line is only worth having when it *joined* several narrow
            # ones - that is the unwrapping. Matched one-to-one they are the
            # same content, and the narrow one is the copy without the padding:
            # a code block is a box, and Term pads the box out to whatever width
            # it was given, so the wide side of a gdb log was handing a yank
            # nineteen hundred columns of spaces with a border on the end.
            src = k - i == 1 ? plain(narrow[i]) : plain(wide[j])
            for t in i:(k - 1)
                out[t] = (t == i, src)
            end
            i = k; j += 1
        else
            out[i] = (true, plain(narrow[i])); i += 1; j += 1
        end
    end
    out
end

"Render a node's body at width `w`, cached - markdown is too slow to redo per frame."
function nodelines(n::Node, w::Int)
    n.cw == w && return n.cache
    local txt::String
    srcline = Tuple{Bool,String}[]     # per line of txt: starts a written line?
    if n.kind === :md
        body, urls = delink(n.raw)
        n.urls = urls
        if isempty(strip(body))
            txt = ""
        else
            txt = render_md(body, w)
            srcline = unwrap_map(String.(split(txt, "\n")),
                                 String.(split(render_md(body, WIDE_MD), "\n")))
        end
    elseif n.kind === :diff
        txt = join((diffline(l) for l in split(n.raw, "\n")), "\n")
    else
        # Not `esc`: a plain node never reaches Term, so doubling its braces is
        # doubling them on screen. It showed `Dict{{String,Int}}` in a code
        # block, and had been doing the same to Buildkite logs all along.
        txt = String(n.raw)
    end
    lines = isempty(txt) ? String[] : String.(split(txt, "\n"))
    # A diff or a plain block is already one line per line of its source, so
    # only markdown needs the alignment above.
    isempty(srcline) && (srcline = [(true, rstrip(astrip(l))) for l in lines])

    # Wrap here rather than trusting Term, which emitted 232 display columns for
    # a requested width of 90 on any line holding inline code.
    #
    # Every row records the written line behind it, and whether it is the first
    # row of it. Both wraps - Term's and ours - are ours to undo when copying;
    # neither is something the reader chose.
    out, srcs = String[], Tuple{Int,String}[]
    for (idx, l) in enumerate(lines)
        (first_of, src) = srcline[idx]
        ws = awidth(l) <= w ? [l] : awrap(l, w)
        for (j, x) in enumerate(ws)
            push!(out, x)
            push!(srcs, (first_of && j == 1 ? 0 : 1, src))
        end
    end
    if n.kind === :md && !isempty(n.urls)
        push!(out, ""); push!(srcs, (0, ""))
        for (i, u) in enumerate(n.urls)
            push!(out, string(AD, "[", i, "]", AR, " \e[34m",
                              shortlink(u, max(20, w - 8)), AR))
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

`text` is what prints. `src` is the written line behind it with the escapes
removed, and `part` is 0 on the first display row of that line and 1 on every
continuation of it.

Those last two are the whole point of owning the mouse. The terminal only ever
saw the wrapped fragments and the pane borders, so a selection made with the
terminal's own copy gives you those. A selection made here is turned back into
the lines as they were written.
"""
struct Row
    node::Int
    header::Bool
    text::String
    src::String
    part::Int
end

"""Flatten open/closed nodes into rows, so selection and scrolling share one space.

Closing a node takes everything nested under it: the list is flat, so "nested"
means the run of nodes deeper than it that follows it. That is what makes a
folded `<details>` disappear with the comment it was written in, and the
outdated review comments disappear with the header that counts them.
"""
function rows(nodes::Vector{Node}, w::Int)
    out = Row[]
    hide = -1                 # while >= 0, skip anything deeper than this
    for (i, n) in enumerate(nodes)
        if hide >= 0
            n.depth > hide && continue
            hide = -1
        end
        pad = " "^(2 * n.depth)
        iw = max(20, w - 2 * n.depth)
        full = string(n.open ? "▾ " : "▸ ", n.header)
        # Wrapped, not cut: a header is a byline plus a peek at the body, and on
        # a narrow pane cutting it loses the half that says what the comment is
        # about. Continuations are indented under the text, so the fold marker
        # still reads as belonging to one row.
        hls = awidth(full) <= iw ? [full] : awrap(full, iw - 2)
        hsrc = get(n.meta, "src", astrip(n.header))
        u = get(n.meta, "url", "")
        for (k, hl) in enumerate(hls)
            txt = k == 1 ? hl : string("  ", hl)
            core = string(AB, isempty(u) ? txt : osc8(u, txt), AR)
            # A rule out to the edge of the pane on the last row of the header,
            # so where one comment ends and the next begins is visible at a
            # glance rather than found by reading. Only at the top level: a
            # nested block stays subordinate to the comment it was written in.
            if n.depth == 0 && k == length(hls)
                gap = iw - awidth(txt) - 1
                gap > 2 && (core = string(core, " ", AD, "─"^gap, AR))
            end
            push!(out, Row(i, true, string(pad, core), hsrc, k == 1 ? 0 : 1))
        end
        if !n.open
            hide = n.depth
            continue
        end
        ls = nodelines(n, iw)                # fills n.srcs alongside n.cache
        for (j, l) in enumerate(ls)
            (part, src) = n.srcs[j]
            push!(out, Row(i, false, string(pad, l), src, part))
        end
    end
    out
end

"Vertical slice with the cursor's node kept in view."
function window(rs::Vector{Row}, cur, top, h)
    isempty(rs) && return (String[], 1)
    top = clamp(top, 1, max(1, length(rs)))
    if cur !== nothing
        cur < top && (top = cur)
        cur > top + h - 1 && (top = cur - h + 1)
    end
    top = clamp(top, 1, max(1, length(rs) - h + 1))
    ([r.text for r in rs[top:min(end, top + h - 1)]], top)
end

"""
    pane(lines, w, h, title, focused) -> Vector{String}

Draw one bordered pane, every row exactly `w` display columns.

Done by hand rather than with Term.Panel, which measures markup instead of what
prints: escaped braces and embedded ANSI both inflated its width accounting, so
content that fit was wrapped and the pane then elided its own tail.
"""
function pane(lines::Vector{String}, w::Int, h::Int, title::AbstractString, focused::Bool)
    bw = focused ? "\e[1m" : "\e[2m"
    R = "\e[0m"
    inner = w - 4
    t = afit(String(title), max(0, inner - 4))
    # "╭─ " + title + " " + bar + "╮" must total w, so the filler is w-5-|title|.
    bar = "─"^max(0, w - 5 - awidth(t))
    out = [string(bw, "╭─ ", R, focused ? "\e[1m" : "\e[2m", t, R, bw, " ", bar, "╮", R)]
    for i in 1:(h - 2)
        c = i <= length(lines) ? lines[i] : ""
        push!(out, string(bw, "│", R, " ", apad(afit(c, inner), inner), " ", bw, "│", R))
    end
    push!(out, string(bw, "╰", "─"^(w - 2), "╯", R))
    out
end
