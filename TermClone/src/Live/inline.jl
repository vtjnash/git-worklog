# Rows drawn in place under the prompt, and redrawn there.
#
# Term's apps and prompts draw where the cursor is, not on a screen of their
# own: the frame is the last few lines of the terminal and is redrawn by going
# back up over it. `TermInput.frame_bytes` writes a full-screen frame - each row
# at its absolute line - so it is the alternate screen's, not this; what is
# shared with it is the rows, written by `Style.ansi` and nothing else.

"""
    InlineView(io)

A block of rows drawn at the cursor's line of `io`, which remembers what it drew
so that the next `draw!` goes back over it and rewrites only the lines that
changed.
"""
mutable struct InlineView
    io::IO
    lines::Vector{Row}
    crow::Int          # the line of the block the terminal's cursor was left on; 0 before any
end
InlineView(io::IO) = InlineView(io, Row[], 0)

"""
    draw!(v::InlineView, rows, cursor = nothing)

Draw `rows` over what `v` drew last, one write. `cursor`, a `(row, col)` in
`rows` (a widget's `caret`), is where the terminal's cursor is left and shown;
`nothing` leaves it hidden at the block's last line.
"""
function draw!(v::InlineView, rows::AbstractVector, cursor = nothing)
    buf = IOBuffer()
    print(buf, "\e[?25l")
    v.crow > 1 && print(buf, "\e[", v.crow - 1, "A")
    print(buf, "\r")
    old = v.lines
    for (i, r) in enumerate(rows)
        i > 1 && print(buf, "\r\n")
        (i <= length(old) && old[i] == r) && continue
        print(buf, "\e[2K", ansi(r))
    end
    n = length(rows)
    if length(old) > n
        # the block got shorter: clear what is left of the old one below it
        print(buf, "\r\n\e[J\e[A")
    end
    if cursor === nothing
        v.crow = n
    else
        r, c = cursor
        n - r > 0 && print(buf, "\e[", n - r, "A")
        print(buf, "\e[", c, "G\e[?25h")
        v.crow = r
    end
    v.lines = Row[row(r) for r in rows]
    write(v.io, take!(buf))
    return v
end

"""
    erase!(v::InlineView)

Take the block off the screen, leaving the cursor where it started.
"""
function erase!(v::InlineView)
    v.crow == 0 && return v
    buf = IOBuffer()
    v.crow > 1 && print(buf, "\e[", v.crow - 1, "A")
    print(buf, "\r\e[J")
    write(v.io, take!(buf))
    v.lines = Row[]
    v.crow = 0
    return v
end

"""
    leave!(v::InlineView)

Leave the block where it is and put the cursor on the line after it.
"""
function leave!(v::InlineView)
    v.crow == 0 && return v
    n = length(v.lines)
    buf = IOBuffer()
    n - v.crow > 0 && print(buf, "\e[", n - v.crow, "B")
    print(buf, "\r\n")
    write(v.io, take!(buf))
    v.lines = Row[]
    v.crow = 0
    return v
end

"""
    widget_rows(widget, w) -> (rows, cursor)

A TermInput widget drawn `w` wide and only as tall as it is: `render` gives a
whole screen with the box in the middle of it, so the blank rows above and
below are taken off, and `caret` moved to match. For a widget drawn inline.
"""
function widget_rows(widget, w::Int)
    H = 200
    rs = TermInput.render(widget, w, H)
    cur = TermInput.caret(widget, w, H)
    blank(r) = isempty(strip(String(r)))
    a = something(findfirst(!blank, rs), 1)
    b = something(findlast(!blank, rs), length(rs))
    cur = cur === nothing ? nothing : (cur[1] - a + 1, cur[2])
    return rs[a:b], cur
end
