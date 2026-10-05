# Reshaping text to a width, as rows: TermInput's `rowwrap` breaks each line at
# the last space that fits (or hard, where there is none), and the faces over
# what is kept stay over it on whichever row it lands. The string functions
# Term exports read their markup into a row first and write it back out.

import .Style: torow, ansi, face
import .Measures: Measure

"""
    reshape_rows(r, width) -> Vector{Row}

Each line of `r` wrapped to rows of at most `width` columns.
"""
function reshape_rows(r::Row, width::Int)
    out = Row[]
    for ln in rowlines(r)
        if rowwidth(ln) <= width
            push!(out, ln)
        else
            append!(out, rowwrap(ln, max(width, 1)))
        end
    end
    return out
end
reshape_rows(s::AbstractString, width::Int) = reshape_rows(torow(s), width)

"`rows` joined into one row, a newline between each."
joinrows(rows::AbstractVector) =
    isempty(rows) ? row("") : foldl((a, b) -> rowcat(a, "\n", b), rows)

"""
    reshape_text(text::AbstractString, width::Int)

Reshape a text to have a given width: each line wrapped to rows of at most
`width` columns. Text with markup or escapes in it comes back as escapes.
"""
function reshape_text(text::AbstractString, width::Int; ignore_markup::Bool = false)
    r = ignore_markup ? torow(replace(text, "{" => "{{", "}" => "}}")) : torow(text)
    all(l -> rowwidth(l) <= width, rowlines(r)) && return String(text)
    return ansi(joinrows(reshape_rows(r, width)))
end

"""
    pad_row(r, width, method; bg = nothing) -> Row

`r` padded with spaces to `width` columns: on the right for `:left`, the left
for `:right`, either side for `:center`, and spread between its words for
`:justify`. The spaces are in the background `bg`, a style, when one is given.
"""
function pad_row(r::Row, width::Int, method::Symbol; bg = nothing)
    w = rowwidth(r)
    w >= width && return r
    method === :justify && return justify_row(r, width; bg)
    n = width - w
    sp(k) = k <= 0 ? row("") : faced(" "^k, face(get_bg_color(bg)))
    if method === :right
        return rowcat(sp(n), r)
    elseif method === :center
        nl, nr = get_lr_widths(n)
        return rowcat(sp(nl), r, sp(nr))
    else
        return rowcat(r, sp(n))
    end
end
pad_row(s::AbstractString, args...; kw...) = pad_row(torow(s), args...; kw...)

"""
    justify_row(r, width; bg = nothing) -> Row

The words of `r` spread to fill `width` columns, as Term's `justify` spreads
them: the same number of spaces added at every space but the last, and what is
left over at the last of those. Left alone when it is less than half the width
or has nowhere to put the spaces.
"""
function justify_row(r::Row, width::Int; bg = nothing)
    s = r.string
    w = rowwidth(r)
    n = width - w
    locs = findall(==(' '), s)
    length(locs) >= 2 && (locs = locs[1:(end - 1)])
    (n < 2 || w <= width / 2 || isempty(locs) || n ÷ length(locs) == 0) &&
        return pad_row(r, width, :left; bg)
    per = n ÷ length(locs)
    sp(k) = faced(" "^k, face(get_bg_color(bg)))
    parts = Row[]
    i = 1
    for (k, loc) in enumerate(locs)
        push!(parts, row(SubString(r, i, loc)))
        push!(parts, sp(k == length(locs) ? n - per * (length(locs) - 1) : per))
        i = loc + 1
    end
    i <= ncodeunits(s) && push!(parts, row(SubString(r, i, thisind(s, ncodeunits(s)))))
    return rowcat(parts...)
end

"""
    justify(text::AbstractString, width::Int)::String

Justify a piece of text spreading out text to fill in a given width.
"""
justify(text::AbstractString, width::Int)::String =
    ansi(joinrows([justify_row(TermInput.rowrstrip(l), width) for l in rowlines(torow(text))]))

"""
    rows_to_width(r, width, justify; background) -> Vector{Row}

`r` reshaped to `width` and each line padded to it - what a `RenderableText`
is made of. Like Term, a text that does not fit is wrapped one column short of
the width.
"""
function rows_to_width(r::Row, width::Int, justify::Symbol; background = nothing)
    lines = Measure(r).w > width ? reshape_rows(r, width - 1) : rowlines(r)
    return [pad_row(l, width, justify; bg = background) for l in lines]
end

"""
    text_to_width(text::AbstractString, width::Int, justify::Symbol)::String

Cast a text to have a given width by reshaping it and padding.
"""
text_to_width(text::AbstractString, width::Int, justify::Symbol; background = nothing)::String =
    ansi(joinrows(rows_to_width(torow(text), width, justify; background)))
