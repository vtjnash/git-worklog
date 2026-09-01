# The view controller: the one thing that owns stdin.
#
# Input used to be read wherever a view happened to want it, which forced a
# choice between two bad options. A dedicated reader task per view outlives its
# view - still blocked in readkey, holding stdin - and steals the next keystroke
# from whatever runs next. Polling `bytesavailable` avoids that but never
# terminates on a non-TTY, spins the CPU, and adds latency to every key.
#
# Owning stdin for the whole run removes the choice. One reader task exists for
# the lifetime of the process, and keys, mouse events and background wakeups
# arrive on the same channel, so the loop can block on `take!` - no polling, no
# sleep, and a fetch finishing redraws immediately rather than at the next tick.

"""
A screen. Implement:

    render(v, w, h) -> String          the whole frame, no trailing newline
    handle!(v, key, ctrl) -> Symbol    :ok | :pop | :quit | :redraw
    onmouse!(v, ev, ctrl) -> Symbol    the same, for a MouseEvent
    onwake!(v) -> Bool                 adopt background results; true to redraw
"""
abstract type View end

onwake!(::View) = false

struct KeyEvent
    code::Int
end
struct WakeEvent end

"""One mouse report.

`kind` is `:press`, `:drag`, `:release`, `:wheelup` or `:wheeldown`; `x` and `y`
are 1-based screen columns and rows, as the terminal counts them, so they index
the frame `render` just drew.
"""
struct MouseEvent
    kind::Symbol
    button::Int
    x::Int
    y::Int
    mods::Int          # bit 0 shift, bit 1 alt, bit 2 ctrl
end

onmouse!(::View, ::MouseEvent, ::Any) = :ok

# --- input decoding ---------------------------------------------------------
#
# Input used to come from `REPL.TerminalMenus.readkey`, which had to go for two
# reasons. It cannot see a mouse report at all - `\e[<0;40;12M` is not a key -
# and it drops any sequence it does not recognise on the floor as a bare Escape,
# leaving the tail in the buffer to arrive as separate keystrokes. That is what
# made Shift-Tab (`CSI Z`) read as Escape-then-Z and close the browser. Nothing
# else used TerminalMenus, so the dependency went with it; `REPL.Terminals` is
# still what puts the tty in raw mode.
#
# Everything here is a pure function of a byte stream, so it can be driven from
# an IOBuffer in a test rather than needing a terminal.

# Above any byte a key can deliver, so a code is either a character or one of
# these and never both.
const K_LEFT  = 1000
const K_RIGHT = 1001
const K_UP    = 1002
const K_DOWN  = 1003
const K_DEL   = 1004
const K_HOME  = 1005
const K_END   = 1006
const K_PGUP  = 1007
const K_PGDN  = 1008
const K_STAB  = 1009     # Shift-Tab, CSI Z

"""
    readevent(io) -> KeyEvent | MouseEvent

Read one input event. Blocks for the first byte, and - once `ESC [` has been
seen and a sequence is therefore certain - for the rest of that sequence.

An unrecognised sequence becomes `KeyEvent(-1)`, which no view binds. The point
is that it is *consumed*: a half-read sequence is worse than an ignored one,
because its tail arrives as plausible-looking keystrokes.
"""
function readevent(io::IO)
    b = read(io, UInt8)
    b == 0x1b || return KeyEvent(Int(b))
    # A bare 27 is Escape; 27 with bytes behind it heads a sequence.
    bytesavailable(io) == 0 && return KeyEvent(27)
    a = read(io, UInt8)
    (a == UInt8('[') || a == UInt8('O')) || return KeyEvent(-1)   # Alt-<key>
    params, fin = UInt8[], 0x00
    while true
        c = read(io, UInt8)
        if c >= 0x40 && c <= 0x7e
            fin = c
            break
        end
        push!(params, c)
        length(params) > 32 && return KeyEvent(-1)    # not a sequence we emit
    end
    decode_csi(String(params), Char(fin))
end

function decode_csi(params::String, fin::Char)
    startswith(params, "<") && (fin == 'M' || fin == 'm') &&
        return decode_mouse(params[2:end], fin == 'M')
    fin == 'A' && return KeyEvent(K_UP)
    fin == 'B' && return KeyEvent(K_DOWN)
    fin == 'C' && return KeyEvent(K_RIGHT)
    fin == 'D' && return KeyEvent(K_LEFT)
    fin == 'H' && return KeyEvent(K_HOME)
    fin == 'F' && return KeyEvent(K_END)
    fin == 'Z' && return KeyEvent(K_STAB)
    if fin == '~'
        # `CSI 5 ~` and `CSI 5 ; 2 ~` are the same key, modified.
        n = tryparse(Int, String(first(split(params, ';'))))
        n == 1 && return KeyEvent(K_HOME)
        n == 3 && return KeyEvent(K_DEL)
        n == 4 && return KeyEvent(K_END)
        n == 5 && return KeyEvent(K_PGUP)
        n == 6 && return KeyEvent(K_PGDN)
        n == 7 && return KeyEvent(K_HOME)
        n == 8 && return KeyEvent(K_END)
    end
    KeyEvent(-1)
end

"""Decode the body of an SGR mouse report (`CSI < b ; x ; y M|m`).

The button byte packs the button in its low two bits, the modifiers above them,
motion at 32 and the wheel at 64 - so a wheel notch is button 64/65 and a drag
is the button number plus 32. `m` as the final byte means release; the wheel
only ever reports `M`.
"""
function decode_mouse(body::AbstractString, pressed::Bool)
    p = split(body, ';')
    length(p) == 3 || return KeyEvent(-1)
    b, x, y = tryparse(Int, p[1]), tryparse(Int, p[2]), tryparse(Int, p[3])
    (b === nothing || x === nothing || y === nothing) && return KeyEvent(-1)
    kind = if b & 64 != 0
        (b & 3) == 0 ? :wheelup : (b & 3) == 1 ? :wheeldown : :other
    elseif !pressed
        :release
    elseif b & 32 != 0
        :drag
    else
        :press
    end
    kind === :other && return KeyEvent(-1)
    mods = ((b & 4) != 0 ? 1 : 0) | ((b & 8) != 0 ? 2 : 0) | ((b & 16) != 0 ? 4 : 0)
    MouseEvent(kind, b & 3, x, y, mods)
end

mutable struct Controller
    term::Any
    events::Channel{Any}
    reader::Union{Nothing,Task}
    stack::Vector{View}
    running::Bool
    mouse::Bool
end
Controller() = Controller(nothing, Channel{Any}(64), nothing, View[], false, false)

"Called from a background task to ask for a redraw once its work has landed."
wake!(ctrl::Controller) = ctrl.running && isopen(ctrl.events) &&
                          put!(ctrl.events, WakeEvent())

"""Turn mouse reporting on or off.

`1006` asks for SGR coordinates, without which columns past 223 are unreportable;
`1002` reports presses, releases and motion *while a button is held*, which is
exactly a drag and nothing more - `1003` would deliver a report per cell of idle
pointer movement.

Owning the mouse costs the terminal's own selection, so this is a toggle rather
than a setting: `m` gives it back when you want to select with the terminal, or
when a terminal turns out not to speak SGR at all.
"""
function mouse!(ctrl::Controller, on::Bool)
    ctrl.mouse = on
    print(on ? "\e[?1006h\e[?1002h" : "\e[?1002l\e[?1006l")
    on
end

push_view!(ctrl::Controller, v::View) = push!(ctrl.stack, v)

"""
    run!(ctrl, root)

Own the terminal, then dispatch events until the stack empties.

The reader task lives as long as the controller, which lives as long as the
program - so it is never left running behind a view that has gone away. It is
blocked in `readevent` at exit; the process is ending, so it is left to die with
it rather than being interrupted mid-read.
"""
function run!(ctrl::Controller, root::View)
    if !(stdin isa Base.TTY)
        println(stderr, "wl: this view needs a terminal; stdin is not a TTY")
        return 1
    end
    push_view!(ctrl, root)
    ctrl.term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm"), stdin, stdout, stderr)
    print("\e[?1049h\e[?25l")                       # alt screen, hide cursor
    REPL.Terminals.raw!(ctrl.term, true)
    mouse!(ctrl, true)
    ctrl.running = true
    ctrl.reader = @async while ctrl.running
        try
            put!(ctrl.events, readevent(stdin))
        catch
            break
        end
    end
    try
        dirty = true
        while !isempty(ctrl.stack)
            v = last(ctrl.stack)
            if dirty
                h, w = displaysize(stdout)
                print("\e[H", replace(render(v, w, h), "\n" => "\e[K\n"), "\e[J")
                dirty = false
            end
            ev = take!(ctrl.events)                 # blocks; no polling
            if ev isa WakeEvent
                dirty = onwake!(v)
            else
                act = ev isa MouseEvent ? onmouse!(v, ev, ctrl) :
                                          handle!(v, ev.code, ctrl)
                act === :quit && break
                act === :pop && pop!(ctrl.stack)
                dirty = true
            end
        end
    finally
        ctrl.running = false
        ctrl.mouse && mouse!(ctrl, false)
        REPL.Terminals.raw!(ctrl.term, false)
        print("\e[?25h\e[?1049l")
    end
    0
end

# --- a line prompt, as a view ----------------------------------------------

"""Ask for one line of text.

A view rather than a readline: the controller holds the terminal in raw mode
for the whole run, so anything that wants input has to go through the same
event stream instead of reaching for stdin itself.
"""
mutable struct PromptView <: View
    title::String
    note::String
    buf::String
    onsubmit::Any            # (String) -> Nothing; not called when cancelled
end
PromptView(title, note, onsubmit) = PromptView(title, note, "", onsubmit)

function render(v::PromptView, w::Int, h::Int)
    box = min(w - 4, 100)
    pad = (w - box) ÷ 2
    top = (h - 7) ÷ 2
    lines = [" "^w for _ in 1:top]
    frame(s, style = "") = string(" "^pad, "\e[2m│\e[0m ", style,
                                  apad(afit(s, box - 4), box - 4), "\e[0m \e[2m│\e[0m")
    push!(lines, string(" "^pad, "\e[2m╭", "─"^(box - 2), "╮\e[0m"))
    push!(lines, frame(v.title, "\e[1m"))
    push!(lines, frame(""))
    for l in awrap(v.note, box - 4)
        push!(lines, frame(l, "\e[2m"))
    end
    push!(lines, frame(string("> ", v.buf, "\e[7m \e[0m")))
    push!(lines, string(" "^pad, "\e[2m╰", "─"^(box - 2), "╯\e[0m"))
    push!(lines, string(" "^pad, "\e[2m  enter accept · esc cancel\e[0m"))
    while length(lines) < h; push!(lines, " "^w); end
    join([apad(l, w) for l in lines[1:h]], "\n")
end

function handle!(v::PromptView, k::Int, ctrl::Controller)
    if k in (13, 10)
        isempty(strip(v.buf)) || v.onsubmit(strip(v.buf))
        return :pop
    elseif k == 27
        return :pop
    elseif k in (127, 8)
        isempty(v.buf) || (v.buf = v.buf[1:prevind(v.buf, end)])
    elseif k == 21                       # ctrl-u
        v.buf = ""
    elseif k >= 32 && k < 127
        v.buf *= Char(k)
    end
    :ok
end
