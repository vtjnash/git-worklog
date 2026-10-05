# From Term.jl (MIT, see LICENSE.Term): the Table constructor and its sizing are Term's.
module Tables

# A table is TermInput's `tablerows`: the cells are the rows of their content,
# cut, padded and styled to the column's width as Term does it, and `tablerows`
# places them in their columns, makes each row as tall as its tallest cell, and
# draws the box's lines round them. Term's sizing, its arguments and which
# rules it draws are here.

import Tables as TablesPkg

import Term: TERM_THEME, Row, row, rowcat, rowwidth, rowfit, rowlines, pad_row, TermInput
import TermInput: tablerows

import ..Renderables: AbstractRenderable, rows as renderable_rows
import ..Measures: Measure, width
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

    # ------------------------------ lay the table out --------------------------- #
    # TermInput's `tablerows` places the cells, each already as wide as its
    # column (Term pads a string with a space each side, in its style), and
    # draws the box. What is Term's is which rules it draws: no top line
    # without a header, and between two body rows a rule unless `compact` -
    # but always under the first when there is a header and a box, and that
    # one the footer's rule when there are two rows.
    nrows = length(rows_values)
    tibox = TermInput.BOXES[Symbol(box.name)]
    gaps = map(1:(nrows - 1)) do l
        if l == 1 && show_header && (box != BOXES[:NONE] || !compact)
            nrows > 2 ? tibox.row : tibox.foot_row
        else
            compact ? nothing : tibox.row
        end
    end
    footer_justify = something(footer_justify, columns_justify)
    rowcells(entries, styles, justify) =
        Any[cell(entries[i], hpad[i], widths[i], justify[i], styles[i]) for i in 1:N_cols]
    if show_header
        header_cells = rowcells(header, header_style, header_justify)
    end
    if !isnothing(footer)
        footer_style, footer_justify = expand.([footer_style, footer_justify], N_cols)
        footer_cells = rowcells(footer, footer_style, footer_justify)
    end
    body = Matrix{Any}(undef, nrows, N_cols)
    for (l, r) in enumerate(rows_values)
        body[l, :] = rowcells(r, columns_style, columns_justify)
    end
    vpads = vcat(show_header ? vpad[1:1] : Int[], vpad[2:(nrows + 1)],
        isnothing(footer) ? Int[] : vpad[end:end])
    lines = tablerows(body; header = show_header ? header_cells : nothing,
        footer = isnothing(footer) ? nothing : footer_cells, widths, pad = 0,
        justify = columns_justify, valign = vertical_justify, vpad = vpads, box = tibox,
        rule = face(style), rules = gaps, top = show_header)

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
    cell(x, hor_pad::Int, w::Int, justify::Symbol, style::String) -> Vector{Row}

A Table's cell, as its rows `w` wide. A string's lines are each cut as Term's
`str_trunc` cuts - at a word, with `...` - to the column less its padding,
justified in two less than the column with a space either side, in `style`; a
renderable's rows are as they are, for `tablerows` to justify.
"""
cell(x::AbstractString, hor_pad::Int, w::Int, justify::Symbol, style::String) = Row[
    styled(rowcat(" ", pad_row(rowfit(ln, w - hor_pad; mark = "...", word = true), w - 2,
        justify), " "), style) for ln in rowlines(torow(x))]
cell(x::AbstractRenderable, hor_pad::Int, w::Int, justify::Symbol, style::String) =
    renderable_rows(x)
cell(x, args...) = cell(string(x), args...)

end
