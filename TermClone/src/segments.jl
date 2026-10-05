module Segments

import Term: unescape_brackets, Row, rowcat
import ..Style: torow, ansi, styled
import ..Measures: Measure
using Term: Term

export Segment

# ---------------------------------------------------------------------------- #
#                                    SEGMENT                                   #
# ---------------------------------------------------------------------------- #

"""
    Segment

One line of a renderable: a row of faces and its measure. `seg.text` is the
row written out as ANSI, which is what Term stores; here the row is what is
kept, and the escapes are written only when they are asked for.
"""
struct Segment
    row::Row
    measure::Measure
end

function Base.getproperty(seg::Segment, f::Symbol)
    f === :text && return ansi(getfield(seg, :row))
    return getfield(seg, f)
end
Base.propertynames(::Segment) = (:text, :row, :measure)

# ------------------------------- constructors ------------------------------- #

"""
    Segment(text)

A segment out of a string with markup or ANSI escapes in it, or a row.
"""
function Segment(text)
    r = torow(text)
    return Segment(r, Measure(r))
end

"""
    Segment(text, markup::AbstractString)

A segment out of some text and a style for all of it, as markup words.
"""
Segment(text, markup::String) = (r = styled(text, markup); Segment(r, Measure(r)))

# --------------------------------- printing --------------------------------- #
Base.show(io::IO, seg::Segment) = print(io, unescape_brackets(seg.text))

Base.show(io::IO, ::MIME"text/plain", seg::Segment) =
    print(io, "Segment{$(typeof(seg.text))} \e[2m(size: $(seg.measure))\e[0m")

# ---------------------------------------------------------------------------- #
#                                    LAYOUT                                    #
# ---------------------------------------------------------------------------- #
Base.:*(seg::Segment, str::AbstractString) = Segment(rowcat(seg.row, torow(str)))
Base.:*(str::AbstractString, seg::Segment) = Segment(rowcat(torow(str), seg.row))
Base.:*(seg1::Segment, seg2::Segment) = Segment(rowcat(seg1.row, seg2.row))

end
