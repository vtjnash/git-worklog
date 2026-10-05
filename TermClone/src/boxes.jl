module Boxes

import Term: rint, chars, join_lines, loop_last, textlen, get_lr_widths, str_trunc,
    default_width, Row, rowcat, rowwidth, rowfit, faced, TermInput
import StyledStrings: Face

import ..Style: apply_style, face, torow, styled
import ..Segments: Segment

export get_row, get_title_row
export BOXES, tibox

# ---------------------------------------------------------------------------- #
#                                      BOX                                     #
# ---------------------------------------------------------------------------- #
"""
  BoxLine

Stores the characters for a line of a `Box` object.
"""
struct BoxLine
    left::Char
    mid::Char
    vertical::Char
    right::Char
end

"""
  Box

Defines characters to render boxes.

Row names:

┌─┬┐ top
│ ││ head
├─┼┤ head_row
│ ││ mid
├─┼┤ row
├─┼┤ foot_row
│ ││ foot
└─┴┘ bottom

each row is an instance of `BoxLine`
"""
struct Box
    name::String
    top::BoxLine
    head::BoxLine
    head_row::BoxLine
    mid::BoxLine
    row::BoxLine
    foot_row::BoxLine
    foot::BoxLine
    bottom::BoxLine
end

"""
    Box(string)

Construct a `Box` objet out of a box string.
"""
function Box(box_name::String, box::String)
    top, head, head_row, mid, row, foot_row, foot, bottom = split(box, "\n")
    return Box(
        box_name,
        BoxLine(chars(top)...),
        BoxLine(chars(head)...),
        BoxLine(chars(head_row)...),
        BoxLine(chars(mid)...),
        BoxLine(chars(row)...),
        BoxLine(chars(foot_row)...),
        BoxLine(chars(foot)...),
        BoxLine(chars(bottom)...),
    )
end

function Base.show(io::IO, box::Box)
    return if io ≡ stdout
        print(io, "Box ($(box.name))\n$(fit(box, [1, 3, 1]))")
    else
        print(io, "Box\e[2m($(box.name))\e[0m")
    end
end

"""
    get_row(box, [1, 2, 3], :row)

Gets characters for a row of a Box object.

The level Symbol can be used to specify the box level (:top, :footer...).
The total width will be the sum of the widths +2
"""
function get_row(box::Box, widths::Vector{Int}, level::Symbol)::String
    # get the correct level of the box
    level = getfield(box, level)

    line = level.left
    for (last, w) in loop_last(widths)
        segment = last ? level.mid^w * level.right : level.mid^w * level.vertical
        line *= segment
    end
    return line
end

"""
    get_row(box::Box, width::Int, level::Symbol)::String

Get a box's row of given width.
"""
function get_row(box::Box, width::Int, level::Symbol)::String
    level = getfield(box, level)
    return level.left * level.mid^(width - 2) * level.right
end

"""
    get_lrow(box::Box, width::Int, level::Symbol)::String

Get a box's row's left part (no righ char)

Get a box's row's right part (no left char)
See also [`get_row`](@ref), [`get_rrow`](@ref).
"""
function get_lrow(box::Box, width::Int, level::Symbol; with_left = true)::String
    level = getfield(box, level)
    return if with_left
        level.left * level.mid^(width - 1)
    else
        level.mid^(width - 1)
    end
end

"""
get_rrow(box::Box, width::Int, level::Symbol)::String

Get a box's row's right part (no left char)
See also [`get_row`](@ref), [`get_lrow`](@ref).
"""
function get_rrow(box::Box, width::Int, level::Symbol; with_right = true)::String
    level = getfield(box, level)
    return if with_right
        level.mid^(width - 1) * level.right
    else
        level.mid^(width - 1)
    end
end

"""
  get_title_row(row::Symbol, box::Box, title::Union{Nothing, AbstractString}; <keyword arguments>)

A box row with a title in it, as a `Segment`: the row's characters in `style`,
the title in `title_style` (or in no style), cut with TermInput's `rowfit`
when it does not fit.

- width::Int: width of line
- style::String: style of line
- title_style::String: style of title string
- justify::Symbol=:left: position of title string
"""
function get_title_row(
        row::Symbol,
        box,  # ::Box,
        title::Union{Nothing, AbstractString};
        width::Int = default_width(),
        style::String = "default",
        title_style::Union{Nothing, String} = nothing,
        justify::Symbol = :left,
    )::Segment
    σ(s) = styled(s, style)
    if isnothing(title) || width < 12
        return Segment(σ(get_row(box, width, row)))
    end
    t = torow(title)
    t = (rowwidth(t) < width - 12 || rowwidth(t) <= 4) ? t : rowfit(t, max(1, width - 15))
    tf = isnothing(title_style) ? Face() : face(title_style)
    tw = rowwidth(t) + 2
    boxline = getfield(box, row)
    titled(pre, post) = rowcat(σ(pre * " "), faced(t, tf), σ(" " * post))

    line = if width < 6
        σ(boxline.left * boxline.mid^(width - 2) * boxline.right)
    elseif justify ≡ :left
        pre = boxline.left * boxline.mid^4
        width - (textwidth(pre) + tw) - 1 < 1 && (pre = boxline.left * boxline.mid^2)
        used = textwidth(pre) + tw
        titled(pre, boxline.mid^(max(1, width - used - 1)) * boxline.right)
    elseif justify ≡ :right
        pre_len = width - tw - 4
        titled(get_lrow(box, pre_len, row), boxline.mid^3 * boxline.right)
    else
        tl, tr = get_lr_widths(tw)
        lw, rw = get_lr_widths(width)
        titled(get_lrow(box, lw - tl, row), get_rrow(box, rw - tr, row))
    end
    return Segment(line)
end

"""
  fit(box::Box, widths::Vector{Int})::String

Creates a box.

The box has one of each level type with columns
widths specified by a vector of widhts.
"""
fit(box::Box, widths::Vector{Int}) = join_lines(
    [
        get_row(box, widths, :top),
        get_row(box, widths, :head),
        get_row(box, widths, :head_row),
        get_row(box, widths, :mid),
        get_row(box, widths, :row),
        get_row(box, widths, :foot_row),
        get_row(box, widths, :foot),
        get_row(box, widths, :bottom),
    ]
)

# ---------------------------------------------------------------------------- #
#                                   Box types                                  #
# ---------------------------------------------------------------------------- #

const BOXES = (
    NONE = Box(
        "NONE",
        """
            
            
            
            
            
            
            
            
        """,
    ),
    ASCII = Box(
        "ASCII",
        """
        +--+
        | ||
        |-+|
        | ||
        |-+|
        |-+|
        | ||
        +--+
        """,
    ),
    ASCII2 = Box(
        "ASCII2",
        """
        +-++
        | ||
        +-++
        | ||
        +-++
        +-++
        | ||
        +-++
        """,
    ),
    ASCII_DOUBLE_HEAD = Box(
        "ASCII_DOUBLE_HEAD",
        """
        +-++
        | ||
        +=++
        | ||
        +-++
        +-++
        | ||
        +-++
        """,
    ),
    SQUARE = Box(
        "SQUARE",
        """
        ┌─┬┐
        │ ││
        ├─┼┤
        │ ││
        ├─┼┤
        ├─┼┤
        │ ││
        └─┴┘
        """,
    ),
    SQUARE_DOUBLE_HEAD = Box(
        "SQUARE_DOUBLE_HEAD",
        """
        ┌─┬┐
        │ ││
        ╞═╪╡
        │ ││
        ├─┼┤
        ├─┼┤
        │ ││
        └─┴┘
        """,
    ),
    MINIMAL = Box(
        "MINIMAL",
        """
          ╷ 
          │ 
        ╶─┼╴
          │ 
        ╶─┼╴
        ╶─┼╴
          │ 
          ╵ 
        """,
    ),
    MINIMAL_HEAVY_HEAD = Box(
        "MINIMAL_HEAVY_HEAD",
        """
          ╷ 
          │ 
        ╺━┿╸
          │ 
        ╶─┼╴
        ╶─┼╴
          │ 
          ╵ 
        """,
    ),
    MINIMAL_DOUBLE_HEAD = Box(
        "MINIMAL_DOUBLE_HEAD",
        """
          ╷ 
          │ 
         ═╪ 
          │ 
         ─┼ 
         ─┼ 
          │ 
          ╵ 
        """,
    ),
    SIMPLE = Box(
        "SIMPLE",
        """
            
            
         ── 
            
            
         ── 
            
            
        """,
    ),
    SIMPLE_HEAD = Box(
        "SIMPLE_HEAD",
        """
            
            
         ── 
            
            
            
            
            
        """,
    ),
    SIMPLE_HEAVY = Box(
        "SIMPLE_HEAVY",
        """
            
            
         ━━ 
            
            
         ━━ 
            
            
        """,
    ),
    HORIZONTALS = Box(
        "HORIZONTALS",
        """
         ── 
            
         ── 
            
         ── 
         ── 
            
         ── 
        """,
    ),
    ROUNDED = Box(
        "ROUNDED",
        """
        ╭─┬╮
        │ ││
        ├─┼┤
        │ ││
        ├─┼┤
        ├─┼┤
        │ ││
        ╰─┴╯
        """,
    ),
    HEAVY = Box(
        "HEAVY",
        """
        ┏━┳┓
        ┃ ┃┃
        ┣━╋┫
        ┃ ┃┃
        ┣━╋┫
        ┣━╋┫
        ┃ ┃┃
        ┗━┻┛
        """,
    ),
    HEAVY_EDGE = Box(
        "HEAVY_EDGE",
        """
        ┏━┯┓
        ┃ │┃
        ┠─┼┨
        ┃ │┃
        ┠─┼┨
        ┠─┼┨
        ┃ │┃
        ┗━┷┛
        """,
    ),
    HEAVY_HEAD = Box(
        "HEAVY_HEAD",
        """
        ┏━┳┓
        ┃ ┃┃
        ┡━╇┩
        │ ││
        ├─┼┤
        ├─┼┤
        │ ││
        └─┴┘
        """,
    ),
    DOUBLE = Box(
        "DOUBLE",
        """
        ╔═╦╗
        ║ ║║
        ╠═╬╣
        ║ ║║
        ╠═╬╣
        ╠═╬╣
        ║ ║║
        ╚═╩╝
        """,
    ),
    DOUBLE_EDGE = Box(
        "DOUBLE_EDGE",
        """
        ╔═╤╗
        ║ │║
        ╟─┼╢
        ║ │║
        ╟─┼╢
        ╟─┼╢
        ║ │║
        ╚═╧╝
        """,
    ),
)


"""
    tibox(b::Box) -> TermInput.Box

The same box as TermInput's `Box`, for a TermInput widget to be drawn in. Term's
box has a footer rule and a footer line TermInput's has no room for; they are
left out.
"""
tibox(b::Box) = TermInput.Box(Symbol(b.name),
    (TermInput.BoxLine(l.left, l.mid, l.vertical, l.right) for l in
        (b.top, b.head, b.head_row, b.mid, b.row, b.bottom))...)
tibox(name::Symbol) = tibox(BOXES[name])

end
