# ------------------------------- constructors ------------------------------- #
"""
A `Pager` is a widget for visualizing long texts a few lines at the time.
It shows a few lines of a longer text and allows users to move up and down the text
using keys such as arrow up and arrow down.

Its lines are rows, and it moves with `TermInput.listmove` and shows the window
`TermInput.listwindow` gives: Term's keys (`]` `[` `.` `,`, the arrows, home and
end) and a pager's (`j` `k`, space and `b`, `g` and `G`, `^f` `^b`, page up and
down).
"""
@with_repr mutable struct Pager <: AbstractWidget
    internals::WidgetInternals
    controls::AbstractDict
    text::AbstractString
    content::Vector{String}
    lines::Vector{Row}
    title::Union{Nothing, String}
    line_numbers::Bool
    tot_lines::Int
    curr_line::Int
    page_lines::Int
end

# --------------------------------- controls --------------------------------- #
"The last line the page can start at: a top, as `listmove` moves a cursor."
lasttop(p::Pager) = p.tot_lines - p.page_lines

"Move the top line of `p` as `TermInput.listmove` moves a cursor for `code`."
function pager_move!(p::Pager, code::Int)
    to = listmove(code, p.curr_line, lasttop(p), p.page_lines)
    isnothing(to) && return :unhandled
    p.curr_line = to
    return :ok
end

"""
move to the next line
"""
next_line(p::Pager, ::Union{Char, ArrowDown}) = (pager_move!(p, K_DOWN); p.curr_line)

"""
move to the previous line
"""
prev_line(p::Pager, ::Union{Char, ArrowUp}) = (pager_move!(p, K_UP); p.curr_line)

"""
move to the next page
"""
next_page(p::Pager, ::Union{PageDownKey, ArrowRight, Char}) =
    (pager_move!(p, K_PGDN); p.curr_line)

"""
move to the previous page
"""
prev_page(p::Pager, ::Union{PageUpKey, ArrowLeft, Char}) =
    (pager_move!(p, K_PGUP); p.curr_line)

"""
move to first line
"""
home(p::Pager, ::HomeKey) = (pager_move!(p, K_HOME); p.curr_line)

"""
move to the last line
"""
toend(p::Pager, ::EndKey) = (pager_move!(p, K_END); p.curr_line)

# a pager's own keys, which Term's table does not name
on_key(p::Pager, code::Int) = pager_move!(p, code)

pager_controls = Dict(
    ArrowRight() => next_page,
    ']' => next_page,
    ArrowLeft() => prev_page,
    '[' => prev_page,
    ArrowDown() => next_line,
    '.' => next_line,
    ArrowUp() => prev_line,
    ',' => prev_line,
    HomeKey() => home,
    EndKey() => toend,
    PageDownKey() => next_page,
    PageUpKey() => prev_page,
    Esc() => quit,
    'q' => quit,
)

"""
    pager_rows(content, line_numbers, width) -> Vector{Row}

A text as the rows a pager shows: highlighted as Term highlights text (its
numbers, strings, symbols - `Term.highlight`, not Julia's syntax, as Term's
`reshape_code_string` does), wrapped and padded to the width inside the
pager's panel.

`line_numbers` is accepted and, as in Term, has no effect: Term numbers the
lines and then reshapes the text without the numbers.
"""
function pager_rows(content::AbstractString, line_numbers::Bool, width::Int)
    w = width - 6
    code = joinrows(reshape_rows(torow(highlight(content; ignore_ansi = false)), w))
    return rows_to_width(code, w, :left)
end

function Pager(
        text::String;
        controls::AbstractDict = pager_controls,
        height = 30,
        width = console_width(),
        title::Union{Nothing, String} = nothing,
        line_numbers::Bool = false,
        on_draw::Union{Nothing, Function} = nothing,
        on_activated::Function = on_activated,
        on_deactivated::Function = on_deactivated,
        page_lines::Integer = 0,
    )
    lines = pager_rows(text, line_numbers, width)
    page_lines = page_lines == 0 ? max(height - 5, 1) : page_lines
    return Pager(
        WidgetInternals(
            Measure(height, width),
            nothing,
            on_draw,
            on_activated,
            on_deactivated,
            false,
        ),
        controls,
        text,
        String[ansi(r) for r in lines],
        lines,
        title,
        line_numbers,
        length(lines),
        1,
        page_lines,
    )
end

function on_layout_change(p::Pager, m::Measure)
    p.page_lines = max(m.h - 5, 1)
    p.lines = pager_rows(p.text, p.line_numbers, m.w)
    p.content = String[ansi(r) for r in p.lines]
    p.tot_lines = length(p.lines)
    p.curr_line = min(p.curr_line, p.tot_lines - p.page_lines)
    return p.internals.measure = m
end

# ---------------------------------- frame  ---------------------------------- #

"""
    make_page_content(pager::Pager, i::Int, Δi::Int)::Renderable

The lines of the page: `Δi + 1` of them from line `i`, as `listwindow` lays a
page of `tot_lines` one-line rows into that many.
"""
function make_page_content(pager, i, Δi)
    _, _, win = listwindow(pager.tot_lines, i, i, Δi + 1)
    return Renderable(pager.lines[win])
end

"A column `n` rows tall and one wide, in `style`."
scroll_column(n::Int, style) = Renderable(fill(faced(" ", face(style)), max(n, 0)))

"""
    make_scrollbar(pager::Pager, i::Int, Δi::Int)

Generate a scrollbar display to show progress in the pager's content.
"""
function make_scrollbar(pager, i, Δi)
    page_lines = pager.page_lines
    scrollbar_lines = min(pager.page_lines, 6)
    scrollbar_lines_half = scrollbar_lines // 2
    scrollbar = vLine(scrollbar_lines; style = "white on_white")

    p = (i) / (pager.tot_lines - Δi)  # progress in the file
    scrollbar_center = p * (page_lines) |> round |> Int
    nspaces_above = max(0, scrollbar_center - scrollbar_lines_half) |> round |> Int
    nspaces_below = max(0, page_lines - scrollbar_lines - nspaces_above) |> round |> Int

    # Term's track is a `RenderableText` of `n` lines of " \n": `n + 1` rows
    if nspaces_above == 0
        return scrollbar / scroll_column(nspaces_below + 2, "on_gray23")
    elseif nspaces_below == 0
        return scroll_column(nspaces_above + 2, "on_gray23") / scrollbar
    else
        above = scroll_column(nspaces_above + 1, "on_gray23")
        below = scroll_column(nspaces_below + 1, "on_gray23")
        return above / scrollbar / below
    end
end

function make_page(pager, i, Δi)
    page_content = make_page_content(pager, i, Δi)
    scrollbar = make_scrollbar(pager, i, Δi)
    return page_content * scrollbar
end

"""
    frame(pager::Pager)::AbstractRenderable

Create a Panel with, as content, the currently visualized lines in the Pager.
"""
function frame(pager::Pager; omit_panel = false)::AbstractRenderable
    isnothing(pager.internals.on_draw) || pager.internals.on_draw(pager)

    i, Δi = pager.curr_line, pager.page_lines
    page = make_page(pager, i, Δi)

    style = isactive(pager) ? pink : "blue dim"

    # return content
    omit_panel && return "  " * page
    return Panel(
        page,
        fit = false,
        width = pager.internals.measure.w,
        height = pager.internals.measure.h,
        padding = (2, 0, 1, 0),
        subtitle = "Lines: $(max(1, i)):$(min(i + Δi, pager.tot_lines)) of $(pager.tot_lines)",
        subtitle_style = "bold dim",
        subtitle_justify = :right,
        style = style,
        title = pager.title,
        title_style = "bold white",
    )
end
