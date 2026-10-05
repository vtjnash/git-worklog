module Annotations

# An annotated line of text: underscores under the annotated pieces, and below
# them each annotation's message in a panel, hung from its underscore by a
# line. Every line is a row: the underscores and the lines down from them are
# placed by column with `rowcat`, and a message's panel is the `Panel`'s own
# rows behind its arrow.

import Term: TERM_THEME, cleantext, Row, row, rowcat, rowwidth, faced, pad_row
import ..Renderables: AbstractRenderable, RenderableText, Renderable, rows
import ..Segments: Segment
import ..Measures: Measure, height, width
import ..Layout: hLine
import ..Panels: Panel
import ..Style: torow, face
import ..Consoles: console_width

export Annotation

# ---------------------------------------------------------------------------- #
#                                  DECORATION                                  #
# ---------------------------------------------------------------------------- #

"""
    Decoration

A message annotating a piece of text: the underscore under the piece, and the
message in a panel hung from it. `Annotation` lays out one or more of them
under the text.

```
────┬───
    │
    │ ╭─────╮
    ╰─│ MSG │
      ╰─────╯
```
"""
struct Decoration
    nun::Int
    position::Int
    underscore::hLine
    panel::Renderable
    style::String
end

"""
    Decoration(num, position, message, underscore_width, style)

A decoration whose underscore starts `position` columns in and is
`underscore_width` wide, as Term measures it (two more than the piece it is
under), and whose message is wrapped to fit beside it on the console.
"""
function Decoration(
        num::Int,
        position::Int,
        message::String,
        underscore_width::Int,
        style::String,
    )
    underscore = hLine(underscore_width, "┬"; pad_txt = false, style = "$style dim")

    # the message, narrower where it would run off the console
    max_w = min(width(message), console_width() - position - 30)
    msg_panel = Panel(
        RenderableText(message; style = style, width = max_w);
        fit = true,
        style = "$style dim",
    )

    # hung from the underscore's line by an arrow into its second row
    line = face("$style dim")
    arrow = Row[faced("│ ", line), faced("╰─", line)]
    rs = Row[rowcat(k <= 2 ? arrow[k] : row("  "), r) for (k, r) in enumerate(rows(msg_panel))]
    return Decoration(num, position, underscore, Renderable(rs), style)
end

""" halve and round a number """
half(x) = floor(Int, x / 2)

"""
    at_columns(line, pieces) -> Row

`line` with each of `pieces`, a column and a row, added at its column, past the
end of what is there already; a piece whose column is already taken is left
out.
"""
function at_columns(line::Row, pieces)
    for (col, r) in pieces
        gap = col - rowwidth(line)
        gap < 0 && continue
        line = rowcat(line, " "^gap, r)
    end
    return line
end

"""
    overlay_decorations(decorations::Vector{Decoration}) -> Vector{Row}

The rows under the text for all of `decorations`: a row of underscores, a row
of lines down from them, and then each message in turn, from the leftmost,
with the lines of those still to come running down beside it.

```
Panel(content; fit=true)
──┬── ───┬───  ────┬───
  │      │         │
  │ ╭─────────────────────────────────╮
  ╰─│  this is the panel constructor  │
    ╰─────────────────────────────────╯
         │         │
         │ ╭───────────────────────────────────────────╮
         ╰─│  here you put what goes inside the panel  │
           ╰───────────────────────────────────────────╯
                   │
                   ...
```
"""
function overlay_decorations(decorations::Vector{Decoration})
    decorations = sort(decorations; by = d -> d.position)
    n = length(decorations)
    positions = getfield.(decorations, :position)
    uw = width.(getfield.(decorations, :underscore))
    centers = half.(uw)

    # an underscore is two narrower than Term measures it: each starts where
    # the one before ends, plus the gap between the pieces
    underscores = Row[rows(d.underscore)[1] for d in decorations]
    lines = Row[]
    line = row("")
    for i in 1:n
        lpad = i == 1 ? positions[1] : positions[i] - positions[i - 1] - uw[i - 1] + 2
        line = rowcat(line, " "^max(0, lpad), underscores[i])
    end
    push!(lines, line)

    # the line down from each underscore, under its `┬`
    vcol = [positions[i] + centers[i] - 1 for i in 1:n]
    verts = Row[faced("│", face("$(d.style) dim")) for d in decorations]
    down(js) = at_columns(row(""), ((vcol[j], verts[j]) for j in js))
    push!(lines, down(1:n))

    # each message, with the lines of those after it beside it
    for r in 1:n
        for (i, ln) in enumerate(rows(decorations[r].panel))
            push!(lines, at_columns(rowcat(" "^vcol[r], ln), ((vcol[j], verts[j]) for j in (r + 1):n)))
        end
        r < n && push!(lines, down((r + 1):n))
    end
    return lines
end

# ---------------------------------------------------------------------------- #
#                                  ANNOTATION                                  #
# ---------------------------------------------------------------------------- #

"""
    Annotation <: AbstractRenderable

A line of text with annotations: messages drawn below it, each hung from the
piece of the text it is about.

```julia
Annotation("This is the text", "text"=>"this is an annotation")
```
gives
```
This is the text
            ──┬─
              │
              │ ╭─────────────────────────╮
              ╰─│  this is an annotation  │
                ╰─────────────────────────╯
```
"""
struct Annotation <: AbstractRenderable
    segments::Vector
    measure::Measure

    function Annotation(rs::Vector{Row})
        w = min(maximum(rowwidth, rs; init = 0), console_width())
        segs = Segment[Segment(pad_row(r, w, :left)) for r in rs]
        return new(segs, Measure(segs))
    end
end

Annotation(text::String) = Annotation(Row[torow(text)])

"""
    Annotation(text::String, annotations::Pair...; kwargs...)

Annotate `text`, one line: each pair is a piece of `text` and its message,
`piece => message`, or `piece => (message, style)` to draw it in a style of its
own.
"""
function Annotation(text::String, annotations::Pair...; kwargs...)
    @assert width(text) < console_width() && height(text) == 1 "Annotation can only annotate a single line, small enough to fit in the screen."
    rawtext = cleantext(text)

    decorations = Decoration[]
    for (i, ann) in enumerate(annotations)
        match = findfirst(ann.first, rawtext)
        isnothing(match) && continue

        msg, style = if ann.second isa String
            ann.second, TERM_THEME[].annotation_color
        elseif ann.second isa Tuple
            ann.second
        else
            error("Decoration argument could not be understood: $ann")
        end

        # columns, where Term counts bytes: the same for ASCII
        position = textwidth(SubString(rawtext, 1, prevind(rawtext, first(match))))
        underscore_width = textwidth(SubString(rawtext, match)) + 2
        push!(decorations, Decoration(i, position, msg, underscore_width, style))
    end

    return Annotation(Row[torow(text); overlay_decorations(decorations)])
end

end
