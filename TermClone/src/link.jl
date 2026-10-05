module Links

import ..Measures: Measure, width
import ..Measures
import ..Segments
import ..Segments: Segment
import ..Style: apply_style, face, torow, ansi
import ..Renderables: RenderableText, AbstractRenderable
import ..Renderables
import ..Layout: pad
import Term: textlen, TERM_THEME, cleantext, excise_link_display_text, remove_ansi, Row,
    linked, faced, rowwidth, pad_row
import Term

export Link

"""
    LinkString

A link as a string: the escapes that draw it, and the width it is drawn in.
Kept for Term's API; a `Link`'s segment is a row with a `:link` over its text,
which TermInput measures by the text alone, so nothing here has to correct a
width.
"""
struct LinkString <: AbstractString
    link::String
    width::Int
end

LinkString(s::String) = LinkString(s, width(s))
LinkString(r::Row) = LinkString(ansi(r), rowwidth(r))
LinkString(l::LinkString) = l

Base.:*(s::Union{SubString, String}, l::LinkString) =
    LinkString(s * l.link, textlen(s) + l.width)
Base.:*(l::LinkString, s::Union{SubString, String}) =
    LinkString(l.link * s, textlen(s) + l.width)
Base.:/(s::Union{SubString, String}, l::LinkString) =
    LinkString(s * "\n" * l.link, max(textlen(s), l.width))
Base.:/(l::LinkString, s::Union{SubString, String}) =
    LinkString(l.link * "\n" * s, max(textlen(s), l.width))

Base.ncodeunits(l::LinkString) = ncodeunits(l.link)
Base.codeunit(l::LinkString) = codeunit(l.link)
Base.codeunit(l::LinkString, i::Integer) = codeunit(l.link, i)
Base.isvalid(l::LinkString, i::Integer) = isvalid(l.link, i)
Base.iterate(l::LinkString, i::Integer = 1) = iterate(l.link, i)
Term.textlen(l::LinkString) = l.width
Term.split_lines(l::LinkString) = Term.split_lines(l.link)
Base.textwidth(l::LinkString) = l.width
Base.string(l::LinkString) = l
Base.print(io::IO, s::LinkString) = print(io, s.link)
Base.show(io::IO, ::MIME"text/plain", l::LinkString) = print(io, l.link)

"""
    Link

A link renderable: a path or url, and the text it is drawn as - clickable on
most terminals. Its one segment is TermInput's `linked` row.
"""
struct Link <: AbstractRenderable
    segments::Vector{Segment}
    measure::Measure
    link::LinkString
    style::String
    display_text::String
    link_dest::String
end

"""
    Link(file_path, line_number = nothing, display_text = nothing; style)

Build a link given a file path and line number.
"""
function Link(
        file_path::AbstractString,
        line_number::Union{Nothing, Integer} = nothing,
        display_text::Union{Nothing, String} = nothing;
        style = TERM_THEME[].link,
    )
    link_dest =
        isnothing(line_number) ? "file://" * file_path : "file://$file_path#$line_number"
    isnothing(display_text) &&
        (display_text = isnothing(line_number) ? file_path : "$file_path:$line_number")
    r = linked(faced(torow(display_text), face(style)), link_dest)
    seg = Segment(r)
    return Link([seg], seg.measure, LinkString(r), style, display_text, link_dest)
end

function Renderables.RenderableText(
        link::Link,
        args...;
        style::Union{Nothing, String} = link.style,
        width::Int = link.measure.w,
        background::Union{Nothing, String} = nothing,
        justify::Symbol = :left,
    )
    r = linked(faced(torow(link.display_text), face(style)), link.link_dest)
    r = pad_row(r, width, justify; bg = background)
    return RenderableText(Segment[Segment(r)], Measure(1, rowwidth(r)), style)
end

end
