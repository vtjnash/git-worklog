module TermMarkdown

# Markdown, drawn by TermInput's `markdown_rows`.
#
# `markdown_rows` draws a parsed `Markdown.MD` as rows of a given width in the
# faces of a `MarkdownStyle`; Term's theme names a style for each markdown
# element (`md_h1`, `md_code`, `md_footnote`, ...), and `mdstyle` is those, as
# faces. Every piece of text - a paragraph, a header, a list item, the body of
# a quote, an admonition or a footnote, a table - is drawn by `markdown_rows`.
#
# What Term draws around those pieces `markdown_rows` has no way to draw, and
# that is composed here, around its rows: an `h1` in a heavy panel and the
# other headers centred, a code block highlighted by TermInput's
# `highlighted_lines` in a `Panel` with its language as the subtitle, an
# admonition in a `Panel` with its title, a quote behind `>` and a heavy bar
# and inside curly quotes, lists with Term's bullets and numbers, a heavy dim
# rule, a footnote led by `[id]:`, display maths indented, and a blank line
# between each two blocks. A link's url, which `markdown_rows` leaves to its
# host, is drawn after the label as Term draws it, by rewriting the tree.

using Markdown
import Markdown: MD

import TermInput
import TermInput: markdown_rows, MarkdownStyle
import StyledStrings: Face

import Term:
    default_width,
    TERM_THEME,
    CodeTheme,
    Row,
    row,
    rowcat,
    rowpad,
    rowwidth,
    faced,
    overlaid,
    joinrows,
    reshape_rows,
    rstrip_row,
    pad_row,
    code_rows
import Term
import REPL
import ..Style: face, ansi
import ..Layout: hLine
import ..Renderables: RenderableText, Renderable, rows
import ..Renderables
import ..Segments: Segment
import ..Measures: Measure
import ..Tprint: tprint, tprintln
import ..Tprint
import ..Panels: Panel

export parse_md

# ---------------------------------------------------------------------------- #
#                                    STYLE                                     #
# ---------------------------------------------------------------------------- #

"""
    mdstyle(theme = TERM_THEME[]) -> TermInput.MarkdownStyle

Term's theme as the faces `markdown_rows` draws in: each `md_*` style read
into a face by `Style.face`. A code span is Term's code text in `md_code`'s
backticks; a link's label is white and bold, and its url (drawn as inline HTML,
see `with_urls`) dim, as Term draws them; a table is in Term's rounded box,
dim, with its header in `md_table_header`.
"""
function mdstyle(theme = TERM_THEME[])
    return MarkdownStyle(
        h1 = face(theme.md_h1),
        h2 = face(theme.md_h2),
        h3 = face(theme.md_h3),
        h4 = face(theme.md_h4),
        h5 = face(theme.md_h5),
        h6 = face(theme.md_h6),
        bold = face("bold"),
        italic = face("italic"),
        strike = face("striked"),
        code = face(CodeTheme["text"]),
        code_tick = face(theme.md_code),
        codeblock = face("on_$(theme.md_codeblock_bg)"),
        link = face("white bold"),
        blockquote = face(theme.md_quote),
        note = face(theme.md_admonition_note),
        info = face(theme.md_admonition_info),
        warning = face(theme.md_admonition_warning),
        danger = face(theme.md_admonition_danger),
        tip = face(theme.md_admonition_tip),
        table_head = face(theme.md_table_header),
        table_rule = face("dim"),
        rule = face("dim"),
        latex = face(theme.md_latex),
        footnote = face(theme.md_footnote),
        html = face("dim"),
        box = Term.Boxes.tibox(:ROUNDED),
        faces = Term.code_mdstyle().faces,
    )
end

"""
    with_urls(x)

`x` with each link followed by its url in brackets, as inline HTML - which
`mdstyle` draws dim. `markdown_rows` draws a link as its label and leaves the
url to the host; Term shows it.
"""
with_urls(x) = x
with_urls(xs::AbstractVector) = Any[y for x in xs for y in with_urls_inline(x)]
with_urls_inline(x) = (with_urls(x),)
with_urls_inline(l::Markdown.Link) =
    (Markdown.Link(with_urls(l.text), l.url), " ", Markdown.HTMLInline("($(l.url))"))
with_urls(p::Markdown.Paragraph) = Markdown.Paragraph(with_urls(p.content))
with_urls(h::Markdown.Header{l}) where {l} = Markdown.Header{l}(with_urls(h.text))
with_urls(b::Markdown.Bold) = Markdown.Bold(with_urls(b.text))
with_urls(i::Markdown.Italic) = Markdown.Italic(with_urls(i.text))
with_urls(t::Markdown.Table) =
    Markdown.Table(Any[Any[with_urls(c isa AbstractVector ? c : Any[c]) for c in r] for r in t.rows], t.align)

"""
    md_rows(blocks, width; strip = true) -> Vector{Row}

`blocks` drawn by `markdown_rows` at `width`, in Term's theme: a blank row
between each two blocks. `markdown_rows` pads every row to the width; Term's
text is not padded, so the padding is taken off unless `strip` is false.
"""
function md_rows(blocks::AbstractVector, width::Int; strip::Bool = true)
    rs = markdown_rows(
        MD(Any[with_urls(b) for b in blocks]), max(width, 1); style = mdstyle(),
    )
    return Row[strip ? rstrip_row(r.text) : r.text for r in rs]
end
md_rows(x, width::Int; kwargs...) = md_rows(Any[x], width; kwargs...)

"`r` with `f` over the first `n` bytes from where `needle` starts in it, if it does."
function marked(r::Row, needle::AbstractString, f::Face; last::Bool = false)
    k = (last ? findlast : findfirst)(needle, r.string)
    return isnothing(k) ? r : overlaid(r, k, f)
end

"`rs` with `prefix` before each row, and `rest` before every row after the first."
prefixed(rs, first, rest = first) =
    Row[rowcat(k == 1 ? first : rest, r) for (k, r) in enumerate(rs)]

# ---------------------------------------------------------------------------- #
#                                    BLOCKS                                    #
# ---------------------------------------------------------------------------- #

"""
    block_rows(x, width) -> Vector{Row}

A markdown element as Term draws it, as rows. Anything without a method of its
own is drawn by `markdown_rows` alone.
"""
block_rows(x, width::Int; kwargs...) = md_rows(x, width)

block_rows(md::MD, width::Int; kwargs...) = blocks_rows(md.content, width)

"The rows of `xs`, a blank row between each two, as Term joins them."
function blocks_rows(xs::AbstractVector, width::Int)
    out = Row[]
    for (k, x) in enumerate(xs)
        k > 1 && push!(out, row(""))
        append!(out, block_rows(x, width))
    end
    return out
end

"""
A header: `markdown_rows`'s, in the level's face, and centred (levels 2 and 3)
or left in one column less than the width; a first-level header in a heavy dim
panel eight narrower than the width.
"""
function block_rows(h::Markdown.Header{l}, width::Int; kwargs...) where {l}
    rs = md_rows(h, width - 1)
    if l > 1
        return Row[pad_row(r, width - 1, l <= 3 ? :center : :left) for r in rs]
    end
    p = Panel(
        Renderable(rs);
        box = :HEAVY,
        style = "dim",
        width = width - 8,
        justify = :center,
        padding = (2, 2, 0, 0),
        fit = false,
    )
    return rows(p)
end

"""
A code block: TermInput's `highlighted_lines` in Term's code theme, each line
wrapped twenty columns in from the width, on the code background, in a square
panel twelve narrower than the width with the language as its subtitle - set
four columns in.
"""
function block_rows(code::Markdown.Code, width::Int; kwargs...)
    theme = TERM_THEME[]
    bg = "on_$(theme.md_codeblock_bg)"
    lines = Row[faced(l, face(bg)) for r in code_rows(code.code; lang = code.language)
        for l in reshape_rows(r, width - 20)]
    p = Panel(
        Renderable(lines);
        style = "white $bg",
        box = :SQUARE,
        subtitle = isempty(code.language) ? nothing : code.language,
        width = width - 12,
        background = bg,
        subtitle_justify = :right,
        fit = false,
    )
    return prefixed(rows(p), "    ")
end

"""
A quote: its blocks drawn five narrower than the width and inside curly quotes,
behind a `>` and then a heavy dim bar in `md_quote`, two in.
"""
function block_rows(qt::Markdown.BlockQuote, width::Int; kwargs...)
    theme = TERM_THEME[]
    content = Any[qt.content...]
    isempty(content) && (content = Any[Markdown.Paragraph(Any[""])])
    quoted(p, before) =
        p isa Markdown.Paragraph ?
        Markdown.Paragraph(before ? Any["“", p.content...] : Any[p.content..., "”"]) : p
    content[1] = quoted(content[1], true)
    content[end] = quoted(content[end], false)
    rs = md_rows(content, width - 5; strip = false)
    accent = face(theme.text_accent)
    rs[1] = marked(rs[1], "“", accent)
    k = findlast(r -> occursin("”", r.string), rs)
    isnothing(k) || (rs[k] = marked(rs[k], "”", accent; last = true))
    gt = rowcat("  ", faced(">", face(theme.md_quote)), " ")
    bar = rowcat("  ", faced("┃", face("$(theme.md_quote) dim")), " ")
    return prefixed(rs, gt, bar)
end

"A horizontal rule: a heavy dim line one narrower than the width."
block_rows(::Markdown.HorizontalRule, width::Int; kwargs...) =
    rows(hLine(width - 1; style = "dim", box = :HEAVY))

"""
A list: each item behind Term's bullet, `•` in the accent colour or its number
in bold, two in, and a list inside an item three further in. An item's text
that wraps is hung beside its bullet. A list ends in a blank row, as Term's
does.
"""
function block_rows(list::Markdown.List, width::Int; space::String = "", kwargs...)
    theme = TERM_THEME[]
    out = Row[]
    for (i, item) in enumerate(list.items)
        bullet = if Markdown.isordered(list)
            rowcat(space, faced("  $(i + list.ordered - 1). ", face("bold")))
        else
            rowcat(space, faced("  • ", face(theme.text_accent)))
        end
        bw = rowwidth(bullet)
        text = Any[x for x in item if !(x isa Markdown.List)]
        rs = isempty(text) ? Row[row("")] : md_rows(text, width - bw)
        append!(out, prefixed(rs, bullet, " "^bw))
        for x in item
            x isa Markdown.List && append!(out, block_rows(x, width; space = "   "))
        end
    end
    push!(out, row(""))
    return out
end

"""
An admonition: its blocks in a panel eight narrower than the width, set four
in, the border dim and the title in the category's colour.
"""
function block_rows(ad::Markdown.Admonition, width::Int; kwargs...)
    theme = TERM_THEME[]
    title_styles = Dict(
        "note" => theme.md_admonition_note,
        "info" => theme.md_admonition_info,
        "warning" => theme.md_admonition_warning,
        "danger" => theme.md_admonition_danger,
        "tip" => theme.md_admonition_tip,
    )
    style = get(title_styles, ad.category, theme.text)
    has_title = length(ad.title) > 0
    p = Panel(
        Renderable(md_rows(ad.content, width - 14));
        title = has_title ? ad.title : "",
        title_style = has_title ? style * " default" : "",
        style = style * " dim",
        width = width - 8,
        fit = false,
    )
    return prefixed(rows(p), "    ")
end

"""
A table: `markdown_rows`'s, in a rounded dim box with the header in
`md_table_header`, centred in eight less than the width.
"""
block_rows(tb::Markdown.Table, width::Int; kwargs...) =
    Row[pad_row(r, width - 8, :center) for r in md_rows(tb, width - 8)]

"""
A footnote: a reference, `[id]` in `md_footnote`; a definition, its text led
by the reference and a colon, padded to the width.
"""
function block_rows(note::Markdown.Footnote, width::Int; kwargs...)
    theme = TERM_THEME[]
    id = "[$(note.id)]"
    isnothing(note.text) && return Row[faced(id, face(theme.md_footnote))]
    content = Any[note.text...]
    if !isempty(content) && content[1] isa Markdown.Paragraph
        content[1] = Markdown.Paragraph(Any["$id: ", content[1].content...])
    else
        pushfirst!(content, Markdown.Paragraph(Any["$id:"]))
    end
    rs = md_rows(content, width - 1)
    rs[1] = overlaid(rs[1], 1:ncodeunits(id), face(theme.md_footnote))
    return Row[rowpad(r, width) for r in rs]
end

"""
Display maths: the formula five in, in `md_latex`, between blank rows - in
unicode where every command in it has a character (`\\alpha`, `^2`), as it was
written otherwise. It is never wrapped, as Term does not wrap it.
"""
function block_rows(ltx::Markdown.LaTeX, width::Int; kwargs...)
    f = face(TERM_THEME[].md_latex)
    lines = split(latex_unicode(ltx.formula), '\n')
    return Row[row(""), (rowcat("     ", faced(l, f)) for l in lines)..., row("")]
end

"""
    latex_unicode(formula) -> String

`formula` with each `\\command`, `^x` and `_x` as the character the REPL's
tab completion gives it, if every one of them has one, or as it is.
"""
function latex_unicode(formula::AbstractString)
    symbols = REPL.REPLCompletions.latex_symbols
    ok = true
    out = replace(String(formula), r"\\+[a-zA-Z]+|[\^_][a-zA-Z0-9+\-=()]" => function (m)
        key = "\\" * lstrip(m, '\\')
        c = get(symbols, key, nothing)
        isnothing(c) && (ok = false)
        something(c, m)
    end)
    return ok && !occursin(r"[{}]", out) ? out : String(formula)
end

# ---------------------------------------------------------------------------- #
#                                   PARSE MD                                   #
# ---------------------------------------------------------------------------- #

"""
    parse_md

Parse a Markdown element (Paragraph, List...) into a string.

A `width` keyword argument can be used to control the width of
the string representation and an `inline` boolean argument specifies
when an element (e.g. a code snippet) is in-line within a larger element
(e.g. a paragraph).
"""
function parse_md end

parse_md(text::String; kwargs...) = parse_md(Markdown.parse(text); kwargs...)
parse_md(x; kwargs...)::String = string(x)

const BLOCKS = Union{
    MD,
    Markdown.Paragraph,
    Markdown.Header,
    Markdown.Code,
    Markdown.BlockQuote,
    Markdown.HorizontalRule,
    Markdown.List,
    Markdown.Admonition,
    Markdown.Table,
    Markdown.Footnote,
    Markdown.LaTeX,
}

const INLINES = Union{
    Markdown.Bold,
    Markdown.Italic,
    Markdown.Link,
    Markdown.Image,
    Markdown.LineBreak,
}

"""
    parse_md(x; width = default_width(), inline = false)::String

A markdown element as Term draws it: its rows, written out as ANSI. An inline
element (bold, a link, a code span with `inline = true`) is drawn as the text
it is inside a paragraph.
"""
function parse_md(x::BLOCKS; width = default_width(), inline = false, kwargs...)::String
    inline && x isa Union{Markdown.Code, Markdown.LaTeX} && return inline_md(x)
    return ansi(joinrows(block_rows(x, width; kwargs...)))
end
parse_md(x::INLINES; kwargs...)::String = inline_md(x)

"An inline element as `markdown_rows` draws it inside a paragraph, unpadded."
function inline_md(x)
    p = Markdown.Paragraph(Any[x])
    w = textwidth(sprint(Markdown.plaininline, p.content)) + 16   # room for backticks and a url
    return ansi(joinrows(md_rows(p, w)))
end

function parse_md(content::Vector; kwargs...)::String
    content = parse_md.(content; kwargs...)
    return length(content) == 1 ? content[1] : join(content)
end

# ---------------------------------------------------------------------------- #
#                              RENDERABLE & TPRINT                             #
# ---------------------------------------------------------------------------- #

"""
---
    RenderableText(md::Markdown.MD; width = console_width() - 2, kwargs...)

Create a `RenderableText` from a markdown string.
"""
function Renderables.RenderableText(md::Markdown.MD; width = default_width() - 2, kwargs...)
    rs = Row[rowwidth(r) < width ? pad_row(r, width, :left) : r for r in block_rows(md, width)]
    segs = Segment.(rs)
    return RenderableText(segs, Measure(segs), nothing)
end

"""
---
    tprint(md::Markdown.MD; kwargs...)

Print a parsed markdown string.
"""
Tprint.tprint(md::Markdown.MD; kwargs...) = tprint(parse_md(md); kwargs...)
Tprint.tprint(io::IO, md::Markdown.MD; kwargs...) = tprint(io, parse_md(md); kwargs...)

"""
---
    tprintln(md::Markdown.MD; kwargs...)

Print a parsed markdown string.
"""
Tprint.tprintln(md::Markdown.MD; kwargs...) = tprintln(parse_md(md); kwargs...)
Tprint.tprintln(io::IO, md::Markdown.MD; kwargs...) = tprintln(io, parse_md(md); kwargs...)

end
