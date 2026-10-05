# From Term.jl (MIT, see LICENSE.Term): the Table constructor and its sizing are Term's.
module Tables

# A table is rows: each cell is the rows of its content, cut, padded and
# styled to the column's width with TermInput's row functions and stacked to the
# row's height; a line of the table is its cells' rows between the box's
# characters, joined with `rowcat`. The box characters are Term's eight-line
# boxes (`Boxes.BOXES`), which have a footer rule that TermInput's do not.

import Tables as TablesPkg

import Term: TERM_THEME, get_lr_widths, Row, row, rowcat, rowwidth, rowwrap, rowhead,
    rowlines, pad_row

import ..Renderables: AbstractRenderable, RenderableText, rows as renderable_rows
import ..Measures: Measure, width, height
import ..Style: styled, torow, face
import ..Segments: Segment
import ..Tprint: tprintln
using ..Boxes

export Table

theme = TERM_THEME[]
include("_tables.jl")

"""
    Table

A Table renderable.

# Examples
```julia

t = 1:3
data = hcat(t, rand(Int8, length(t)))
Table(data)

┌───────────┬───────────┐
│  Column1  │  Column2  │
├───────────┼───────────┤
│     1     │    -95    │
├───────────┼───────────┤
│     2     │    -85    │
├───────────┼───────────┤
│     3     │    115    │
└───────────┴───────────┘
```
"""
mutable struct Table <: AbstractRenderable
    segments::Vector{Segment}
    measure::Measure
end

"""
    Table(
        tb::TablesPkg.AbstractColumns;
        box::Symbol = :SQUARE,
        style::String = "default",
        hpad::Union{Vector,Int} = 2,
        vpad::Union{Vector,Int} = 0,
        vertical_justify::Symbol = :center,
        show_header::Bool = true,
        header::Union{Nothing,Vector,Tuple} = nothing,
        header_style::Union{String,Vector,Tuple} = "default",
        header_justify::Union{Nothing,Symbol,Vector,Tuple} = nothing,
        columns_style::Union{String,Vector,Tuple} = "default",
        columns_justify::Union{Symbol,Vector,Tuple} = :center,
        columns_widths::Union{Nothing,Int,Vector} = nothing,
        footer::Union{Function,Nothing,Vector,Tuple} = nothing,
        footer_style::Union{String,Vector,Tuple} = "default",
        footer_justify::Union{Nothing,Symbol,Vector,Tuple} = :center,
        compact::Bool = false,
    )

Generic constructor for a Table renderable.

!!! tip
    Arguments such as `header_style`, `columns_style` and `footer_style` can 
    either be passed a single value, which will be applied to all columns, or
    a vector of values, which will be applied to each column.
"""
function Table(
        tb::TablesPkg.AbstractColumns;
        box::Symbol = TERM_THEME[].tb_box,
        style::String = TERM_THEME[].tb_style,
        hpad::Union{Vector, Int} = 2,
        vpad::Union{Vector, Int} = 0,
        vertical_justify::Symbol = :center,
        show_header::Bool = true,
        header::Union{Nothing, Vector, Tuple} = nothing,
        header_style::Union{String, Vector, Tuple} = TERM_THEME[].tb_header,
        header_justify::Union{Nothing, Symbol, Vector, Tuple} = nothing,
        columns_style::Union{String, Vector, Tuple} = TERM_THEME[].tb_columns,
        columns_justify::Union{Symbol, Vector, Tuple} = :center,
        columns_widths::Union{Nothing, Int, Vector} = nothing,
        footer::Union{Function, Nothing, Vector, Tuple} = nothing,
        footer_style::Union{String, Vector, Tuple} = TERM_THEME[].tb_footer,
        footer_justify::Union{Nothing, Symbol, Vector, Tuple} = :center,
        compact::Bool = false,
    )

    # prepare some variables
    header_justify = something(header_justify, columns_justify)
    box = BOXES[box]

    # table info
    rows = TablesPkg.rows(tb)
    sch = TablesPkg.schema(rows)
    N_cols = length(sch.names)
    N_rows = length(rows) + 2

    # make sure arguemnts combination is valud
    assert_table_arguments(
        N_cols,
        N_rows,
        show_header,
        header,
        header_style,
        header_justify,
        columns_style,
        columns_justify,
        columns_widths,
        footer,
        footer_style,
        footer_justify,
        hpad,
        vpad,
    ) || return nothing

    # columns style
    columns_style, columns_justify, hpad =
        expand.([columns_style, columns_justify, hpad], N_cols)
    vpad = expand(vpad, N_rows)

    # headers and headers style
    if show_header
        header = isnothing(header) ? string.(sch.names) : header
        header_style, header_justify = expand.([header_style, header_justify], N_cols)
    end

    # get footer (if it's a function)
    if footer isa Function
        try
            footer_entries = footer.(map(c -> tb[c], sch.names))
            footer = string(footer) * ": " .* string.(footer_entries)
        catch
            @warn "Could not apply function $footer to table - types mismatch?"
            footer = fill("couldn't apply", N_cols)
        end
    end

    # get the max-width of each column
    widths = calc_columns_widths(
        N_cols,
        N_rows,
        columns_widths,
        show_header,
        header,
        tb,
        sch,
        footer,
        hpad,
    )

    # get the table values as vectors of strings
    rows_values = []
    for row in rows
        _row::Vector = []
        TablesPkg.eachcolumn(sch, row) do val, i, nm
            push!(_row, val isa AbstractRenderable ? val : string(val))
        end
        push!(rows_values, _row)
    end

    # get the height of each row
    heights = rows_heights(N_rows, show_header, header, rows_values, footer, vpad)
    # @info "sizes" widths heights  tb sch

    # ----------------------------- create table rows ---------------------------- #
    nrows = length(rows_values)
    lines::Vector{Row} = []
    # @info "creating table" heights widths

    # create a row for the header
    show_header && append!(
        lines,
        table_row(
            make_row_cells(
                header,
                header_style,
                header_justify,
                widths,
                hpad,
                heights[1],
                vertical_justify,
            ),
            widths,
            box,
            :top,
            :head,
            :head_row,
            style,
            heights[1]
            # compact = true
        ),
    )

    # add one row at the time
    for (l, row) in enumerate(rows_values)
        # get the row's content
        I = l + 1
        row = make_row_cells(
            row,
            columns_style,
            columns_justify,
            widths,
            hpad,
            heights[I],
            vertical_justify,
        )

        # prep row params based on line number, header etc...
        if l == 1 && show_header
            bottom = if nrows < 2
                :bottom
            elseif nrows > 2
                :row
            else
                :foot_row
            end
            top = show_header ? nothing : :top
            mid = :mid
            _compact = (show_header && (box != BOXES[:NONE])) ? false : compact

            # add additional rows
        elseif l == nrows
            top, mid, bottom, _compact =
                nothing, :mid, isnothing(footer) ? :bottom : :foot_row, false
        else
            top, mid, bottom, _compact = nothing, :mid, :row, compact
        end

        # add it in
        append!(
            lines,
            table_row(
                row,
                widths,
                box,
                top,
                mid,
                bottom,
                style,
                heights[I];
                compact = _compact,
            ),
        )
    end

    # add footer
    if !isnothing(footer)
        # get footer style
        footer_justify = something(footer_justify, columns_justify)
        footer_style, footer_justify = expand.([footer_style, footer_justify], N_cols)

        append!(
            lines,
            table_row(
                make_row_cells(
                    footer,
                    footer_style,
                    footer_justify,
                    widths,
                    hpad,
                    heights[end],
                    vertical_justify,
                ),
                widths,
                box,
                nothing,
                :foot,
                :bottom,
                style,
                heights[end],
            ),
        )
    end

    # every line as wide as the widest, as Term's `fillin` makes them
    w = maximum(rowwidth, lines; init = 0)
    segments = Segment[Segment(pad_row(l, w, :left)) for l in lines]
    return Table(segments, Measure(segments))
end

""" 
    Table(data::Union{AbstractVector, AbstractMatrix}; kwargs...)

Construct `Table` from `Vector` and `Matrix`
"""
Table(data::Union{AbstractVector, AbstractMatrix}; kwargs...) =
    Table(TablesPkg.table(data); kwargs...)

""" 
Table(data::AbstractDict; kwargs...)

Construct `Table` from a `Dict`.
The Dict's keys make up the table header if none is assigned.
"""
Table(data::AbstractDict; header = nothing, kwargs...) = Table(
    hcat(values(data)...);
    header = isnothing(header) ? string.(collect(keys(data))) : header,
    kwargs...,
)

"""
    table_row(
        cells::Vector,
        widths::Vector,
        box,
        top_level::Symbol,
        mid_level::Symbol,
        bottom_level::Symbol,
        box_style::String,
        row_height::Int;
        compact = false,
    ) -> Vector{Row}

The lines of a single row of a `Table`: a rule of the box's `top_level` (when
there is one), the cells' rows side by side between the characters of its
`mid_level`, and a rule of its `bottom_level` (unless `compact`), the box drawn
in `box_style`.
"""
function table_row(
        cells::Vector,
        widths::Vector,
        box,
        top_level::Union{Nothing, Symbol},
        mid_level::Symbol,
        bottom_level::Symbol,
        box_style,
        row_height::Int;
        compact::Bool = false,
    )
    level = getfield(box, mid_level)
    σ(c) = styled(string(c), box_style)
    l, m, r = σ(level.left), σ(level.vertical), σ(level.right)

    mid = Row[rowcat(l, foldl((a, b) -> rowcat(a, m, b), (c[i] for c in cells)), r)
        for i in 1:row_height]
    rule(lv) = styled(get_row(box, widths, lv), box_style)

    out = isnothing(top_level) ? Row[] : Row[rule(top_level)]
    append!(out, mid)
    compact || push!(out, rule(bottom_level))
    return out
end

"""
    trunc_row(r, width) -> Row

`r` cut to `width` columns as Term's `str_trunc` cuts a string: the first row of
it wrapped to three columns less, and `...` after it.
"""
function trunc_row(r::Row, width::Int)
    (width < 0 || rowwidth(r) <= width) && return r
    out = width > 3 ? first(rowwrap(r, width - 3)) : rowhead(r, 0)
    rowwidth(out) == 0 && return out
    return rowcat(out, "...")
end

"""
    vertical_pad_rows(rs, h, method) -> Vector{Row}

`rs` with lines of spaces as wide as the widest above and below it, to `h`
lines, placed by `method` ∈ (`:top`, `:center`, `:bottom`).
"""
function vertical_pad_rows(rs::Vector{Row}, h::Int, method::Symbol)
    n = h - length(rs)
    n <= 0 && return rs
    above, below = method ≡ :bottom ? (n, 0) : method ≡ :top ? (0, n) : get_lr_widths(n)
    blank = row(" "^maximum(rowwidth, rs; init = 0))
    return vcat(fill(blank, above), rs, fill(blank, below))
end

"""
    cell(x::AbstractString, hor_pad::Int, h::Int, w::Int, justify::Symbol, style::String, vertical_justify::Symbol)

A Table's cell from a string, as rows: each of its lines cut to the column
less its padding, padded to `w` with a space either side, in `style`, and the
whole placed in `h` lines.
"""
function cell(
        x::AbstractString,
        hor_pad::Int,
        h::Int,
        w::Int,
        justify::Symbol,
        style::String,
        vertical_justify::Symbol,
    )
    content = Row[
        styled(rowcat(" ", pad_row(trunc_row(ln, w - hor_pad), w - 2, justify), " "), style)
        for ln in rowlines(torow(x))
    ]
    return vertical_pad_rows(content, h, vertical_justify)
end

"""
    cell(x::AbstractRenderable, hor_pad::Int, h::Int, w::Int, justify::Symbol, style::String, vertical_justify::Symbol)

A Table's cell from a renderable: its rows padded to `w` and placed in `h` lines.
"""
cell(
    x::AbstractRenderable,
    hor_pad::Int,
    h::Int,
    w::Int,
    justify::Symbol,
    style::String,
    vertical_justify::Symbol,
) = vertical_pad_rows(Row[pad_row(r, w, justify) for r in renderable_rows(x)], h,
    vertical_justify)

"""
    make_row_cells(
        entries::Union{Tuple, Vector},
        style::Vector{String},
        justify::Vector{Symbol},
        widths::Vector{Int},
        height::Int,
        vertical_justify::Symbol,
    )

Create a row's cell from a vector of 'entries' (renderables or strings).
"""
make_row_cells(
    entries::Union{Tuple, Vector},
    style::Vector{String},
    justify::Vector{Symbol},
    widths::Vector{Int},
    hor_pad::Vector{Int},
    height::Int,
    vertical_justify::Symbol,
) = map(
    i -> cell(
        entries[i] isa AbstractRenderable ? entries[i] : string(entries[i]),
        hor_pad[i],
        height,
        widths[i],
        justify[i],
        style[i],
        vertical_justify,
    ),
    1:length(entries),
)

end
