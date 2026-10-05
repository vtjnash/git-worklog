# Rows drawn in place under the prompt, and redrawn there.
#
# Term's apps and prompts draw where the cursor is, not on a screen of their
# own: the frame is the last few lines of the terminal and is redrawn by going
# back up over it. That is `TermInput.frame_bytes` with `inline`, which is a
# function of its arguments; what is kept here is the one thing it is told,
# how far up the last frame began.

"""
    InlineView(io)

A block of rows drawn at the cursor's line of `io`, which remembers how far
above the cursor the last one began, so that the next `draw!` goes back over
it.
"""
mutable struct InlineView
    io::IO
    above::Int         # lines the last frame left above the cursor's; 0 before any
    lines::Int         # the rows it drew; 0 before any
end
InlineView(io::IO) = InlineView(io, 0, 0)

"""
    draw!(v::InlineView, rows, cursor = nothing)

Draw `rows` over what `v` drew last, one write. `cursor`, a `(row, col)` in
`rows` (a widget's `caret`), is where the terminal's cursor is left and shown;
`nothing` leaves it hidden on the line under the block.
"""
function draw!(v::InlineView, rows::AbstractVector, cursor = nothing)
    write(v.io, frame_bytes(rows, "", cursor; inline = v.above))
    v.above = isnothing(cursor) ? length(rows) : cursor[1] - 1
    v.lines = length(rows)
    return v
end

"""
    erase!(v::InlineView)

Take the block off the screen, leaving the cursor where it started.
"""
function erase!(v::InlineView)
    v.lines == 0 && return v
    write(v.io, frame_bytes(Row[]; inline = v.above))
    v.above = v.lines = 0
    return v
end

"""
    leave!(v::InlineView)

Leave the block where it is and put the cursor on the line after it.
"""
function leave!(v::InlineView)
    v.lines == 0 && return v
    down = v.lines - v.above
    write(v.io, down > 0 ? "\e[$(down)B\r" : "\r")
    v.above = v.lines = 0
    return v
end
