"""
    LiveWidgets

Term's live widgets (MIT, see LICENSE.Term) on TermInput's: the state of an
`InputBox` is a `TermInput.TextArea`, of a menu a `TermInput.Choice`, a pager
scrolls with `listmove`/`listwindow`, and keys come from `TermInput.readevent`
rather than `REPL.TerminalMenus.readkey`. What a widget's `frame` returns is
still a Term renderable - a `Panel`, a stack of `RenderableText` - made of
rows, so an `App` lays them out with its `Compositor` as before.
"""
module LiveWidgets

using Dates
import Base.Docs: doc as getdocs
using Markdown
import MyterialColors: Palette, blue, pink

import TermInput
import TermInput: Row, row, rowcat, rowwidth, rowpad, rowfit, faced, overlaid,
    KeyEvent, PasteEvent, EndEvent, readevent, enter_terminal, leave_terminal,
    InputReader, arm!, input_waiting, HeldTerminal, listmove, listwindow,
    TextArea, Choice, handle!, picked, selected, select!, markdown_rows, MarkdownStyle, Keys,
    frame_bytes, drawcursor
import TermInput.Keys: K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
    K_PGDN, K_BASE, keycode, keychar, printable
import StyledStrings: Face

import Term: default_width, reshape_text, reshape_rows, joinrows, rows_to_width, highlight,
    TERM_THEME, fint, remove_ansi
import ..Renderables: AbstractRenderable, RenderableText, Renderable
import ..Segments: Segment
import ..Panels: Panel
import ..Measures: Measure
import ..Measures: width as get_width
import ..Measures: height as get_height
using ..Consoles
import ..Style: apply_style, torow, ansi, face
import ..Layout: Spacer, vLine, vstack, hLine, hstack, PlaceHolder
import ..Compositors: Compositor, render, update!
import ..Repr: @with_repr, termshow
import ..Tprint: tprint

export AbstractWidget, refresh!, play, key_press, shouldupdate, frame, stop!
export Pager
export SimpleMenu, ButtonsMenu, MultiSelectMenu
export InputBox, TextWidget, Button, ToggleButton
export Gallery
export App
export ArrowDown,
    ArrowUp,
    ArrowLeft,
    ArrowRight,
    DelKey,
    HomeKey,
    EndKey,
    PageUpKey,
    PageDownKey,
    Enter,
    SpaceBar,
    Esc,
    Del

const LIVE_DEBUG = Ref(false)

# ----------------------------- keyboard controls ---------------------------- #
abstract type KeyInput end

struct ArrowLeft <: KeyInput end
struct ArrowRight <: KeyInput end
struct ArrowUp <: KeyInput end
struct ArrowDown <: KeyInput end
struct DelKey <: KeyInput end
struct HomeKey <: KeyInput end
struct EndKey <: KeyInput end
struct PageUpKey <: KeyInput end
struct PageDownKey <: KeyInput end
struct Enter <: KeyInput end
struct SpaceBar <: KeyInput end
struct Esc <: KeyInput end
struct Del <: KeyInput end

"""
Term's table, by the codes `REPL.TerminalMenus.readkey` answers. Kept for
anything that still has such a code; the keys arrive here as TermInput's codes,
see [`KEYCODES`](@ref).
"""
KEYs = Dict{Int, KeyInput}(
    13 => Enter(),
    27 => Esc(),
    32 => SpaceBar(),
    127 => Del(),
    1000 => ArrowLeft(),
    1001 => ArrowRight(),
    1002 => ArrowUp(),
    1003 => ArrowDown(),
    1004 => DelKey(),
    1005 => HomeKey(),
    1006 => EndKey(),
    1007 => PageUpKey(),
    1008 => PageDownKey(),
)

"""
    KEYCODES

Term's named keys by the `TermInput.Keys` code each arrives as from
`readevent`. Shift-Up/Down are the plain arrows here (`Keys.unshift`), since no
Term widget extends a selection.
"""
const KEYCODES = Dict{Int, KeyInput}(
    13 => Enter(),
    10 => Enter(),
    27 => Esc(),
    32 => SpaceBar(),
    127 => Del(),
    8 => Del(),
    K_LEFT => ArrowLeft(),
    K_RIGHT => ArrowRight(),
    K_UP => ArrowUp(),
    K_DOWN => ArrowDown(),
    K_DEL => DelKey(),
    K_HOME => HomeKey(),
    K_END => EndKey(),
    K_PGUP => PageUpKey(),
    K_PGDN => PageDownKey(),
)

"""
    keyinput(code) -> Union{KeyInput, Char, Nothing}

What a Term control table is keyed by, for a TermInput key code: one of the
named keys, a `Char` for anything typed (control bytes included, as Term's
`readkey` gave them), or `nothing` for a key Term has no name for - a word
motion, `⌥e` - which only a widget's own TermInput handling can take.
"""
function keyinput(code::Int)
    code = Keys.unshift(code)
    haskey(KEYCODES, code) && return KEYCODES[code]
    0 <= code < K_BASE && return keychar(code)
    return nothing
end

const _CODEOF = Dict{KeyInput, Int}(
    Enter() => 13, Esc() => 27, SpaceBar() => 32, Del() => 127,
    ArrowLeft() => K_LEFT, ArrowRight() => K_RIGHT, ArrowUp() => K_UP,
    ArrowDown() => K_DOWN, DelKey() => K_DEL, HomeKey() => K_HOME,
    EndKey() => K_END, PageUpKey() => K_PGUP, PageDownKey() => K_PGDN,
)
"""
    tikey(k::KeyInput) -> Int

The TermInput code of one of Term's named keys: what a control function hands
to a TermInput widget's `handle!`.
"""
tikey(k::KeyInput) = _CODEOF[k]

"""
The terminal a running app holds, for a widget that hands it to `\$EDITOR`
(an `InputBox` on `⌥e`): `nothing` when no app is playing.
"""
const ACTIVE_TERMINAL = Ref{Union{Nothing, HeldTerminal}}(nothing)

# ------------------------------- base widgets ------------------------------- #
include("abstract_widget.jl")
include("inline.jl")
include("help.jl")
include("widgets.jl")
include("pager.jl")
include("buttons.jl")
include("menus.jl")

# -------------------------------- containers -------------------------------- #
include("abstract_container.jl")
include("gallery.jl")
include("app.jl")

include("keyboard_input.jl")

end
