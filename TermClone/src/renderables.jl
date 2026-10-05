module Renderables

import Term:
    unescape_brackets_with_space,
    DEBUG_ON,
    NOCOLOR,
    cleantext,
    Row,
    row,
    rowwidth,
    rowfit,
    rowwrap,
    rows_to_width,
    pad_row,
    faced

import Term
import ..Consoles: console_width
import ..Measures: Measure, width as get_width
import ..Segments: Segment
import ..Style: torow, face

export AbstractRenderable, Renderable, RenderableText

# ------------------------------- abstract type ------------------------------ #

"""
    AbstractRenderable

Anything made of `segments`, one per line, each a row of faces, and a
`measure`.
"""
abstract type AbstractRenderable end

Measure(renderable::AbstractRenderable) = renderable.measure

info(r::AbstractRenderable)::String =
    "\e[38;5;117m$(typeof(r)) <: AbstractRenderable\e[0m \e[2m(h:$(r.measure.h), w:$(r.measure.w))\e[0m"

"""
    rows(r::AbstractRenderable) -> Vector{Row}

The renderable as TermInput rows, one per line.
"""
rows(r::AbstractRenderable) = isnothing(r.segments) ? Row[] : Row[s.row for s in r.segments]

"""
    Base.string(r::AbstractRenderable)::String

The renderable's lines written out as ANSI, a newline between each.
"""
function Base.string(r::AbstractRenderable)
    isnothing(r.segments) && return ""
    return join((s.text for s in r.segments), "\n")
end
Base.String(r::AbstractRenderable) = Base.string(r)

"""
    print(io::IO, renderable::AbstractRenderable)

Print a renderable to an IO
"""
function Base.print(io::IO, renderable::AbstractRenderable; highlight = true)
    ren = unescape_brackets_with_space(string(renderable))
    NOCOLOR[] && (ren = cleantext(ren))
    return println(io, ren)
end

Base.show(io::IO, renderable::AbstractRenderable) = print(io, info(renderable))

function Base.show(io::IO, ::MIME"text/plain", renderable::AbstractRenderable)
    println(io, string(renderable))
    return DEBUG_ON[] && println(io, info(renderable))
end

RenderablesUnion = Union{AbstractString, AbstractRenderable}

# ------------------------- generic renderable object ------------------------ #

"""
    Renderable

Generic `Renderable` object.
"""
mutable struct Renderable <: AbstractRenderable
    segments::Vector{Segment}
    measure::Measure
end

Renderable(str::AbstractString) = RenderableText(str)
Renderable(ren::AbstractRenderable) = ren
Renderable() = Renderable(Segment[], Measure(0, 0))

"""
    Renderable(rows::Vector{Row})

A renderable made of rows, one per line.
"""
function Renderable(rs::AbstractVector{Row})
    segs = Segment.(rs)
    return Renderable(segs, Measure(segs))
end

# ---------------------------------------------------------------------------- #
#                                TEXT RENDERABLE                               #
# ---------------------------------------------------------------------------- #

"""
    RenderableText

`Renderable` representing a text.
"""
mutable struct RenderableText <: AbstractRenderable
    segments::Vector{Segment}
    measure::Measure
    style::Union{Nothing, String}
end

"""
    RenderableText(text::String; width::Union{Nothing, Int, Symbol}=nothing)

Construct a `RenderableText` out of a string: its markup read into faces, its
lines wrapped to `width` with TermInput's `rowwrap` and padded to it.
Optionally `justify` can be used to set the text justification style ∈
(:left, :center, :right, :justify).
"""
function RenderableText(
        text::AbstractString;
        style::Union{Nothing, String} = nothing,
        width::Int = min(get_width(text), console_width(stdout)),
        background::Union{Nothing, String} = nothing,
        justify::Symbol = :left,
    )
    r = torow(text)
    endswith(r.string, '\n') && (r = row(SubString(r, 1, prevind(r.string, ncodeunits(r.string)))))
    lines = rows_to_width(r, width, justify; background = background)
    f = face(style)
    segments = Segment[Segment(faced(l, f)) for l in lines]
    return RenderableText(segments, Measure(segments), something(style, ""))
end

function RenderableText(
        rt::RenderableText;
        style::Union{Nothing, String} = nothing,
        width::Int = min(get_width(rt), console_width(stdout)),
        kwargs...,
    )
    return if rt.style == style && rt.measure.w == width
        rt
    else
        RenderableText(join_rows(rows(rt)); style, width, kwargs...)
    end
end

function RenderableText(
        ren::AbstractRenderable,
        args...;
        width = min(get_width(ren), console_width(stdout)),
        kwargs...,
    )
    if ren.measure.w ≤ width
        return RenderableText(ren.segments, ren.measure, nothing)
    else
        # A renderable's rows are laid out already: they are cut where they
        # overflow, as TermInput's `hard` wrap does, never reflowed at spaces.
        # Like a text, they are cut one column short of the width.
        justify = get(kwargs, :justify, :left)
        background = get(kwargs, :background, nothing)
        lines = Row[r for l in rows(ren) for r in rowwrap(l, max(width - 1, 1); hard = true)]
        segments = Segment[Segment(pad_row(l, width, justify; bg = background)) for l in lines]
        return RenderableText(segments, Measure(segments), nothing)
    end
end

"`rs` joined into one row, a newline between each."
join_rows(rs::AbstractVector) = Term.joinrows(rs)

# ---------------------------------------------------------------------------- #
#                                     MISC.                                    #
# ---------------------------------------------------------------------------- #

"""
    trim_renderable(ren::Union{String, AbstractRenderable}, width::Int)

Trim a string or renderable to a max width, each line cut by TermInput's
`rowfit`.
"""
function trim_renderable(ren::AbstractRenderable, width::Int)::AbstractRenderable
    segs = Segment[Segment(rowwidth(r) > width ? rowfit(r, width) : r) for r in rows(ren)]
    return Renderable(segs, Measure(segs))
end

function trim_renderable(ren::RenderableText, width::Int)::RenderableText
    return RenderableText(join_rows(rows(ren)); width)
end

end
