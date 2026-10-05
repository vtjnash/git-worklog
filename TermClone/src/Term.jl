"""
    Term

An API-compatible clone of [Term.jl](https://github.com/FedeClaudi/Term.jl)
drawn with [TermInput.jl](../TermInput.jl): every renderable is rows of
StyledStrings faces (`TermInput.Row`), measured, cut, padded and wrapped by
TermInput's row functions, and written as escapes by StyledStrings only when a
string is asked for. The interactive parts - prompts, the live widgets, the
pager - are TermInput's widgets and its key reader.

Markup (`"{bold red}text{/bold red}"`) and ANSI escapes are both read into
faces on the way in, so anything Term accepts is accepted here; what comes back
out is the same picture in StyledStrings' spelling of the escapes, which is not
byte-for-byte Term's. The test suite says which outputs are the same bytes,
which are the same terminal cells, and which only the same text.
"""
module Term

using Unicode
import TermInput
import TermInput: Row, row, rowwidth, rowfit, rowpad, rowwrap, rowcat, faced, rowhead,
    rowtail, rowlines, overlaid, linked
import StyledStrings
import StyledStrings: Face, SimpleColor

const STACKTRACE_HIDDEN_MODULES = Ref(String[])
const STACKTRACE_HIDE_FRAMES = Ref(true)

const DEBUG_ON = Ref(false)

const ACTIVE_CONSOLE_WIDTH = Ref{Union{Nothing, Int}}(nothing)
const ACTIVE_CONSOLE_HEIGHT = Ref{Union{Nothing, Int}}(nothing)
const DEFAULT_CONSOLE_WIDTH = Ref{Int}(88)
const DEFAULT_STACKTRACE_WIDTH = Ref{Int}(140)
const NOCOLOR = Ref{Bool}(false)

default_width(io = stdout)::Int =
    min(DEFAULT_CONSOLE_WIDTH[], something(ACTIVE_CONSOLE_WIDTH[], displaysize(io)[2]))
default_stacktrace_width(io = stderr)::Int =
    min(DEFAULT_STACKTRACE_WIDTH[], something(ACTIVE_CONSOLE_WIDTH[], displaysize(io)[2]))

const DEFAULT_ASPECT_RATIO = Ref(4 / 3)  # 4:3 - 16:9 - 21:9

# general utils: the markup language and plain-string helpers
include("ansi_tables.jl")
include("text_utils.jl")

include("measures.jl")
include("colors.jl")
include("theme.jl")
include("highlight.jl")

const TERM_THEME = Ref(Theme())

# used to disable links in stacktraces for testing
const TERM_SHOW_LINK_IN_STACKTRACE = Ref(true)

function update! end

# faces: markup and ANSI read into rows, rows written back as ANSI
include("style.jl")
include("segments.jl")
include("text_reshape.jl")
include("macros.jl")
include("code.jl")

# renderables
include("boxes.jl")
include("console.jl")
include("renderables.jl")
include("layout.jl")
include("link.jl")
include("panels.jl")
include("errors.jl")
include("tprint.jl")
include("trees.jl")
include("dendograms.jl")
include("tables.jl")
include("markdown.jl")
include("repr.jl")
include("compositors.jl")
include("grid.jl")

# interactive
include("Live/live.jl")
include("introspection.jl")
include("progress.jl")
include("logs.jl")
include("prompt.jl")
include("annotations.jl")

export RenderableText, Panel, TextBox, @nested_panels
export TERM_THEME, highlight
export @red, @black, @green, @yellow, @blue, @magenta, @cyan, @white, @default
export @bold, @dim, @italic, @underline, @style
export tprint, tprintln
export install_term_stacktrace,
    install_term_logger, uninstall_term_logger, install_term_repr
export vLine, hLine
export @with_repr, termshow, @showme
export Compositor
export grid
export inspect
export Pager

# ----------------------------------- base ----------------------------------- #
using .Measures

# ----------------------------------- style ---------------------------------- #

using .Colors: NamedColor, BitColor, RGBColor, get_color

using .Style: apply_style

using .Segments: Segment

# -------------------------------- renderables ------------------------------- #
using .Boxes

using .Consoles: console_height, console_width

using .Renderables: AbstractRenderable, Renderable, RenderableText

using .Layout

using .Links

using .Panels: Panel, TextBox, @nested_panels

Measures.width(seg::Segment) = seg.measure.w
Measures.width(ren::AbstractRenderable) = ren.measure.w

Measures.height(seg::Segment) = seg.measure.h
Measures.height(ren::AbstractRenderable) = ren.measure.h

"""
    Measure(seg::Segment)

gives the measure of a segment
"""
Measures.Measure(seg::Segment) = seg.measure

"""
    Measure(segments::AbstractVector)

gives the measure of a vector of segments
"""
Measures.Measure(segments::AbstractVector) =
if length(segments) == 0
    Measure(0, 0)
else
    Measure(sum(Measures.height.(segments)), maximum(Measures.width.(segments)))
end

# ---------------------------------- others ---------------------------------- #
using .Errors: install_term_stacktrace, render_backtrace, StacktraceContext

using .Logs: install_term_logger, uninstall_term_logger, TermLogger

using .Tprint: tprint, tprintln

using .Trees: Tree

using .Dendograms: Dendogram

using .Tables: Table

using .Compositors: Compositor

using .TermMarkdown: parse_md

using .Repr: @with_repr, termshow, install_term_repr, @showme

using .Grid

# -------------------------------- interactive ------------------------------- #
using .LiveWidgets

using .Progress: ProgressBar, ProgressJob, with, @track

using .Introspection: inspect, typestree, expressiontree, inspect

using .Prompts

end
