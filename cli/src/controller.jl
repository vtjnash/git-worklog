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
    wantsraw(v) -> Bool                take input undecoded, as bytes
    onraw!(v, bytes, ctrl) -> Symbol   those bytes, for a view that asked
"""
abstract type View end

onwake!(::View) = false

"""Whether this view wants the bytes rather than the keys.

Decoding exists so that views deal in characters, which is right for every view
that reads input. A view that *forwards* input wants the opposite: a pane
hosting another program has to hand over what was typed, unchanged, and
re-encoding a decoded key back into bytes would be a second translation to get
wrong. Such a view takes the stream as it arrived and passes it on.
"""
wantsraw(::View) = false
onraw!(::View, ::Vector{UInt8}, ::Any) = :ok

struct KeyEvent
    code::Int
end
struct WakeEvent end

"""Input that was never decoded, for a view that asked to forward it."""
struct RawEvent
    bytes::Vector{UInt8}
end

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

# Above the last codepoint Unicode will ever have, so a key code is either a
# character or one of these and never both. They used to start at 1000, which is
# a perfectly good Greek letter - fine while nothing could type one, and a
# collision the moment the composer accepted non-ASCII input.
const K_BASE  = 0x110000
const K_LEFT  = K_BASE + 0
const K_RIGHT = K_BASE + 1
const K_UP    = K_BASE + 2
const K_DOWN  = K_BASE + 3
const K_DEL   = K_BASE + 4
const K_HOME  = K_BASE + 5
const K_END   = K_BASE + 6
const K_PGUP  = K_BASE + 7
const K_PGDN  = K_BASE + 8
const K_STAB  = K_BASE + 9     # Shift-Tab, CSI Z
const K_WORD_LEFT  = K_BASE + 10
const K_WORD_RIGHT = K_BASE + 11
const K_WORD_BACK  = K_BASE + 12    # delete the word before the cursor
const K_EDIT       = K_BASE + 13    # Alt-e, as the REPL binds it

"A key that stands for a character someone meant to type."
printable(k::Int) = (k >= 32 && k != 127 && k <= 0x10FFFF)

# Readline's editing keys, by the control bytes they arrive as.
const C_A, C_D, C_E, C_K, C_S, C_U, C_W, C_O = 1, 4, 5, 11, 19, 21, 23, 15

"""Column where the word before `col` starts, by one of readline's two rules.

Skip whatever does not count as a word immediately behind the cursor, then the
run that does. Which rule matters: `^w` is unix-word-rubout, delimited by
whitespace, and alt-backspace is backward-kill-word, delimited by anything
non-alphanumeric. On `/usr/local/lib` the first takes the whole path - there is
no whitespace to stop at - and the second takes only `lib`. Both are wanted,
which is why both keys exist, so `alnum` picks between them.
"""
function word_start(s::AbstractString, col::Int; alnum::Bool = false)
    inword(c) = alnum ? (isletter(c) || isnumeric(c)) : !isspace(c)
    cs = collect(s)
    i = min(col - 1, length(cs))
    while i >= 1 && !inword(cs[i]); i -= 1; end
    while i >= 1 && inword(cs[i]); i -= 1; end
    i + 1
end

"Column just past the word after `col`, by the same rule in the other direction."
function word_end(s::AbstractString, col::Int; alnum::Bool = false)
    inword(c) = alnum ? (isletter(c) || isnumeric(c)) : !isspace(c)
    cs = collect(s)
    i = max(col, 1)
    while i <= length(cs) && !inword(cs[i]); i += 1; end
    while i <= length(cs) && inword(cs[i]); i += 1; end
    i
end

"""Read what is there, without looking at any of it.

One blocking byte so the task parks rather than spins, then whatever else has
already arrived. The draining is safe in a way that polling for input is not:
it never waits, so it cannot hang on a stream that will send nothing more. It
matters because an escape sequence, a paste and a mouse report are each several
bytes that must reach the child together and in order.
"""
function readraw(io::IO)
    b = read(io, UInt8)
    buf = UInt8[b]
    n = bytesavailable(io)
    n > 0 && append!(buf, read(io, n))
    RawEvent(buf)
end

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
    if b >= 0x80
        # A typed character outside ASCII arrives as its UTF-8 bytes. Assembling
        # it here keeps every view dealing in characters rather than in bytes;
        # left as bytes, an accented letter inserted three separate nothings.
        n, mask = b >= 0xf0 ? (3, 0x07) : b >= 0xe0 ? (2, 0x0f) :
                  b >= 0xc0 ? (1, 0x1f) : (0, 0x00)
        n == 0 && return KeyEvent(-1)              # a stray continuation byte
        cp = UInt32(b & mask)
        for _ in 1:n
            c = read(io, UInt8)
            (c & 0xc0) == 0x80 || return KeyEvent(-1)
            cp = (cp << 6) | UInt32(c & 0x3f)
        end
        return KeyEvent(Int(cp))
    end
    b == 0x1b || return KeyEvent(Int(b))
    # A bare 27 is Escape; 27 with bytes behind it heads a sequence.
    bytesavailable(io) == 0 && return KeyEvent(27)
    a = read(io, UInt8)
    if a != UInt8('[') && a != UInt8('O')
        # ESC-prefixed: the terminal is sending Meta/Alt as "escape, then the
        # key". Which of the three spellings below arrives depends on the
        # terminal and its settings, and they are all in use - Terminal.app
        # sends `ESC b` for Alt-Left, iTerm in Esc+ mode sends `ESC ESC [ D`,
        # and everything sends `ESC DEL` for Alt-Backspace.
        a == 0x7f && return KeyEvent(K_WORD_BACK)
        a == UInt8('b') && return KeyEvent(K_WORD_LEFT)
        a == UInt8('f') && return KeyEvent(K_WORD_RIGHT)
        # The REPL binds `\ee` to edit_input - the same move this makes, so the
        # same key. (`^Q` there opens a numbered frame from the last backtrace,
        # which is a different thing entirely.)
        a == UInt8('e') && return KeyEvent(K_EDIT)
        if a == 0x1b && bytesavailable(io) > 0
            # `ESC ESC [ D`: the second ESC opens the arrow's own sequence, so
            # it is the head of a CSI and not a byte to step over.
            c = read(io, UInt8)
            if c == UInt8('[') || c == UInt8('O')
                ev = read_csi(io)
                ev isa KeyEvent && ev.code == K_LEFT && return KeyEvent(K_WORD_LEFT)
                ev isa KeyEvent && ev.code == K_RIGHT && return KeyEvent(K_WORD_RIGHT)
            end
        end
        return KeyEvent(-1)
    end
    read_csi(io)
end

"The body of a CSI sequence, with its `ESC [` already read."
function read_csi(io::IO)
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
    # `CSI 1;3D` is Alt-Left: the second parameter carries the modifiers, as
    # 1 + shift + 2·alt + 4·ctrl. Either alt or ctrl on an arrow means the word,
    # which is what both of them do everywhere else.
    parts = split(params, ';')
    mod = length(parts) >= 2 ? something(tryparse(Int, String(parts[2])), 1) : 1
    byword = (mod - 1) & 0x06 != 0
    fin == 'A' && return KeyEvent(K_UP)
    fin == 'B' && return KeyEvent(K_DOWN)
    fin == 'C' && return KeyEvent(byword ? K_WORD_RIGHT : K_RIGHT)
    fin == 'D' && return KeyEvent(byword ? K_WORD_LEFT : K_LEFT)
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
    ready::Channel{Bool}        # loop -> reader: "read one event now", raw or not
    reader::Union{Nothing,Task}
    stack::Vector{View}
    running::Bool
    mouse::Bool
end
Controller() = Controller(nothing, Channel{Any}(64), Channel{Bool}(1), nothing,
                          View[], false, false)

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
    suspend(f, ctrl)

Give the terminal back for the duration of `f`, then take it again.

For handing stdin to a child process - `\$EDITOR`, mainly. Everything the
controller has done to the terminal is undone in order and redone after: mouse
reporting off, raw mode off, the alternate screen released, so the child gets a
terminal that looks untouched and its own scrollback.

**Only safe to call from the event loop.** The reader task is parked between
events rather than sitting in `read`, which is what makes this work at all - a
reader blocked in `read(stdin)` would race the child for every keystroke the
user typed into it. The loop does not re-arm the reader until it has finished
handling the event, and running the editor happens inside that handling.
"""
function suspend(f, ctrl::Controller)
    mouse = ctrl.mouse
    mouse && mouse!(ctrl, false)
    ctrl.term === nothing || REPL.Terminals.raw!(ctrl.term, false)
    print("\e[?25h\e[?1049l")
    try
        f()
    finally
        print("\e[?1049h\e[?25l")
        ctrl.term === nothing || REPL.Terminals.raw!(ctrl.term, true)
        mouse && mouse!(ctrl, true)
    end
end

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
    # The reader reads one event per token and then waits for the next, rather
    # than looping on `read`. That is what lets `suspend` hand stdin to a child:
    # between events this task is parked on `ready`, not on the tty.
    ctrl.reader = @async while ctrl.running
        try
            raw = take!(ctrl.ready)
            ctrl.running || break
            put!(ctrl.events, raw ? readraw(stdin) : readevent(stdin))
        catch
            break
        end
    end
    try
        dirty, armed = true, false
        while !isempty(ctrl.stack)
            v = last(ctrl.stack)
            if dirty
                h, w = displaysize(stdout)
                print("\e[H", replace(render(v, w, h), "\n" => "\e[K\n"), "\e[J")
                dirty = false
            end
            # Arm only when the previous event is fully handled. A wakeup does
            # not consume the token: the reader is still waiting on the key it
            # was armed for, and arming twice would put it back on the tty
            # while the loop is busy.
            # The mode is decided here, where the top view is known, and not
            # in the reader, which is parked between events and would be
            # deciding it against whatever was on top last time.
            armed || (put!(ctrl.ready, wantsraw(v)); armed = true)
            ev = take!(ctrl.events)                 # blocks; no polling
            if ev isa WakeEvent
                dirty = onwake!(v)
            else
                armed = false
                act = ev isa MouseEvent ? onmouse!(v, ev, ctrl) :
                      ev isa RawEvent   ? onraw!(v, ev.bytes, ctrl) :
                                          handle!(v, ev.code, ctrl)
                act === :quit && break
                # Pop the view that asked, not whatever is on top: a view may
                # push its successor while handling the key it pops on - the
                # picker that opens a composer does exactly that - and popping
                # the top would throw away the one just pushed.
                if act === :pop
                    at = findlast(x -> x === v, ctrl.stack)
                    at === nothing || deleteat!(ctrl.stack, at)
                end
                dirty = true
            end
        end
    finally
        ctrl.running = false
        isopen(ctrl.ready) && close(ctrl.ready)    # release the parked reader
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
    col::Int                 # cursor, 1 = before the first character
    onsubmit::Any            # (String) -> Nothing; not called when cancelled
end
PromptView(title, note, onsubmit) = PromptView(title, note, "", 1, onsubmit)

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
    v.col = clamp(v.col, 1, length(v.buf) + 1)
    pre = String(first(v.buf, v.col - 1))
    at = v.col <= length(v.buf) ? string(collect(v.buf)[v.col]) : " "
    post = v.col < length(v.buf) ? String(SubString(v.buf, nextind(v.buf, 0, v.col + 1))) : ""
    push!(lines, frame(string("> ", pre, "\e[7m", at, "\e[0m", post)))
    push!(lines, string(" "^pad, "\e[2m╰", "─"^(box - 2), "╯\e[0m"))
    push!(lines, string(" "^pad, "\e[2m  enter accept · ^w word · ^a/^e line · esc cancel\e[0m"))
    while length(lines) < h; push!(lines, " "^w); end
    join([apad(l, w) for l in lines[1:h]], "\n")
end

# --- a picker, as a view ----------------------------------------------------

"""Pick one of a list, narrowing by typing.

The filter is what makes it usable rather than a nicety: there are a couple of
hundred labels across these repos, and scrolling to one is not picking it.
"""
mutable struct ChooseView <: View
    title::String
    note::String
    options::Vector{Tuple{String,Any}}    # (what is shown, what is returned)
    query::String
    sel::Int
    top::Int
    onpick::Any                           # (value) -> Nothing; not called on cancel
end
ChooseView(title, note, options, onpick) =
    ChooseView(String(title), String(note), options, "", 1, 1, onpick)

shown(v::ChooseView) = isempty(v.query) ? v.options :
    [o for o in v.options if occursin(lowercase(v.query), lowercase(o[1]))]

function render(v::ChooseView, w::Int, h::Int)
    opts = shown(v)
    box = min(w - 4, 76)
    pad = (w - box) ÷ 2
    iw = box - 4
    bh = clamp(length(opts), 1, max(1, h - 10))
    v.sel = clamp(v.sel, 1, max(1, length(opts)))
    v.top = clamp(v.top, 1, max(1, length(opts)))
    v.sel < v.top && (v.top = v.sel)
    v.sel > v.top + bh - 1 && (v.top = v.sel - bh + 1)
    v.top = clamp(v.top, 1, max(1, length(opts) - bh + 1))

    frame(s, style = "") = string(" "^pad, "\e[2m│\e[0m ", style,
                                  apad(afit(s, iw), iw), "\e[0m \e[2m│\e[0m")
    out = [string(" "^pad, "\e[2m╭─ \e[0m\e[1m", afit(v.title, iw - 2), "\e[0m\e[2m ",
                  "─"^max(0, box - 5 - awidth(afit(v.title, iw - 2))), "╮\e[0m")]
    isempty(v.note) || push!(out, frame(v.note, "\e[2m"))
    push!(out, frame(string("/ ", v.query, "\e[7m \e[0m")))
    for i in v.top:(v.top + bh - 1)
        if i > length(opts)
            push!(out, frame(""))
        else
            push!(out, frame(opts[i][1], i == v.sel ? "\e[1;37m" : "\e[2m"))
        end
    end
    isempty(opts) && (out[end] = frame("nothing matches", "\e[2m"))
    push!(out, string(" "^pad, "\e[2m╰", "─"^(box - 2), "╯\e[0m"))
    push!(out, string(" "^pad, "\e[2m", afit("↑/↓ move · ↵ pick · esc cancel", box), "\e[0m"))
    top = max(0, (h - length(out)) ÷ 2)
    all = vcat([" "^w for _ in 1:top], out)
    while length(all) < h; push!(all, " "^w); end
    join([apad(l, w) for l in all[1:h]], "\n")
end

function handle!(v::ChooseView, k::Int, ctrl::Controller)
    opts = shown(v)
    if k == 27
        return :pop
    elseif k in (13, 10)
        isempty(opts) && return :ok
        v.onpick(opts[clamp(v.sel, 1, length(opts))][2])
        return :pop
    elseif k in (K_DOWN, 14)
        v.sel = min(length(opts), v.sel + 1)
    elseif k in (K_UP, 16)
        v.sel = max(1, v.sel - 1)
    elseif k in (127, 8)
        isempty(v.query) || (v.query = v.query[1:prevind(v.query, end)]; v.sel = 1)
    elseif k == C_U
        v.query = ""; v.sel = 1
    elseif k in (C_W, K_WORD_BACK)
        v.query = String(first(v.query, word_start(v.query, length(v.query) + 1) - 1))
        v.sel = 1
    elseif printable(k)
        v.query *= Char(k); v.sel = 1
    end
    :ok
end

# --- a multi-line composer, as a view ---------------------------------------

"""Split a line into fixed-width pieces, exactly as the composer draws it.

Not `awrap`: that one carries ANSI state across the break and its wrap points
are its own business. Here the wrap has to be predictable in the other
direction - from a character offset to the row and column it lands on - so the
rule is the simplest one there is, and the composer owns it.
"""
function chunks(s::AbstractString, w::Int)
    w <= 0 && return [String(s)]
    isempty(s) && return [""]
    out, io, acc = String[], IOBuffer(), 0
    for c in s
        cw = textwidth(c)
        if acc + cw > w
            push!(out, String(take!(io))); acc = 0
        end
        write(io, c); acc += cw
    end
    push!(out, String(take!(io)))
    out
end

"""A small multi-line text area.

Enough to write a review comment without leaving the program - insert,
backspace, the arrows, home and end, and the readline keys people's fingers
already know - and no more. Alt-e hands the buffer to `\$EDITOR` for everything
past that, which is where undo, search and your own keymap already live and are
not worth reimplementing here; that is the key the REPL uses for the same move.
`^o` does it too, because a terminal that treats Option as a compose key sends
no Meta at all and would leave the editor unreachable.
"""
mutable struct EditorView <: View
    title::String
    note::String
    lines::Vector{String}
    row::Int                 # cursor line
    col::Int                 # cursor column, 1 = before the first character
    top::Int                 # first display row shown
    status::String
    onsubmit::Any            # (String) -> Nothing; not called when cancelled
    allow_empty::Bool        # an approval needs no words; a comment does
end
function EditorView(title, note, onsubmit; initial::AbstractString = "",
                    allow_empty::Bool = false)
    ls = isempty(initial) ? [""] : String.(split(replace(initial, "\r\n" => "\n"), "\n"))
    EditorView(String(title), String(note), ls, length(ls),
               length(last(ls)) + 1, 1, "", onsubmit, allow_empty)
end

text(v::EditorView) = join(v.lines, "\n")

"""Display rows for the whole buffer, and where the cursor sits among them.

Returns `(rows, crow, ccol)` with `crow` an index into `rows` and `ccol` a
1-based column within it.
"""
function textrows(v::EditorView, w::Int)
    rows, crow, ccol = String[], 1, 1
    for (i, l) in enumerate(v.lines)
        cs = chunks(l, w)
        if i == v.row
            pre = textwidth(String(first(l, max(0, v.col - 1))))
            # A line whose width is an exact multiple of the wrap needs one more
            # row for the cursor to stand on, the way any editor gives you one.
            pre > 0 && pre % w == 0 && length(cs) == pre ÷ w && push!(cs, "")
            crow = length(rows) + pre ÷ w + 1
            ccol = pre % w + 1
        end
        append!(rows, cs)
    end
    (rows, crow, ccol)
end

function render(v::EditorView, w::Int, h::Int)
    box = min(w - 4, 100)
    pad = (w - box) ÷ 2
    iw = box - 4
    bh = max(3, h - 8)                 # rows of text inside the box
    rows, crow, ccol = textrows(v, iw)
    v.top = clamp(v.top, 1, max(1, length(rows)))
    crow < v.top && (v.top = crow)
    crow > v.top + bh - 1 && (v.top = crow - bh + 1)
    v.top = clamp(v.top, 1, max(1, length(rows) - bh + 1))

    frame(s, style = "") = string(" "^pad, "\e[2m│\e[0m ", style,
                                  apad(afit(s, iw), iw), "\e[0m \e[2m│\e[0m")
    out = [string(" "^pad, "\e[2m╭─ \e[0m\e[1m", afit(v.title, iw - 2), "\e[0m\e[2m ",
                  "─"^max(0, box - 5 - awidth(afit(v.title, iw - 2))), "╮\e[0m")]
    for l in awrap(v.note, iw)
        push!(out, frame(l, "\e[2m"))
    end
    push!(out, frame(""))
    for i in v.top:(v.top + bh - 1)
        line = i <= length(rows) ? rows[i] : ""
        if i == crow
            # The cursor is drawn rather than placed: the terminal's own cursor
            # is hidden for the whole run, and turning it on here would leave it
            # to be put back by every path out of this view.
            pre = String(first(line, ccol - 1))
            at = ccol <= length(line) ? string(line[ccol]) : " "
            post = ccol < length(line) ? String(line[(ccol + 1):end]) : ""
            line = string(pre, "\e[7m", at, "\e[0m", post)
        end
        push!(out, frame(line))
    end
    push!(out, string(" "^pad, "\e[2m╰", "─"^(box - 2), "╯\e[0m"))
    foot = isempty(v.status) ?
           "^s submit · ⌥e/^o \$EDITOR · ^w word · ^a/^e line · esc cancel" : v.status
    push!(out, string(" "^pad, "\e[2m", afit(foot, box), "\e[0m"))
    top = max(0, (h - length(out)) ÷ 2)
    all = vcat([" "^w for _ in 1:top], out)
    while length(all) < h; push!(all, " "^w); end
    join([apad(l, w) for l in all[1:h]], "\n")
end

"""Hand the buffer to `\$EDITOR`, and take back whatever comes out.

`InteractiveUtils.edit` is used rather than spawning `\$EDITOR` directly so that
`JULIA_EDITOR` and the `define_editor` hooks apply - the same editor `edit()`
would open at the REPL. It only waits for editors Julia knows to be blocking, so
a non-blocking one (`code` without `--wait`) returns immediately and the file is
read back unchanged; that is reported rather than silently posting nothing.
"""
function compose_external(ctrl::Controller, initial::AbstractString)
    path = string(tempname(), ".md")
    write(path, initial)
    before = read(path, String)
    err = ""
    suspend(ctrl) do
        try
            InteractiveUtils.edit(path)
        catch e
            err = first(sprint(showerror, e), 100)
        end
    end
    txt = try
        read(path, String)
    catch
        before
    end
    rm(path; force = true)
    isempty(err) ? (txt, txt == before ? "editor made no change" : "") : (before, err)
end

function handle!(v::EditorView, k::Int, ctrl::Controller)
    l = v.lines[v.row]
    n = length(l)
    v.status = ""
    if k == 27
        return :pop
    elseif k == 19                                  # ^s
        t = strip(text(v))
        if isempty(t) && !v.allow_empty
            v.status = "nothing to send — esc cancels"
            return :ok
        end
        v.onsubmit(String(t))
        return :pop
    elseif k in (K_EDIT, C_O)                       # hand it to $EDITOR
        (txt, note) = compose_external(ctrl, text(v))
        v.lines = isempty(txt) ? [""] : String.(split(replace(txt, "\r\n" => "\n"), "\n"))
        v.row = length(v.lines); v.col = length(last(v.lines)) + 1
        v.status = note
    elseif k in (13, 10)                            # split the line here
        head, tail = String(first(l, v.col - 1)), String(l[nextind(l, 0, v.col):end])
        v.lines[v.row] = head
        insert!(v.lines, v.row + 1, tail)
        v.row += 1; v.col = 1
    elseif k in (127, 8)
        if v.col > 1
            v.lines[v.row] = string(first(l, v.col - 2), l[nextind(l, 0, v.col):end])
            v.col -= 1
        elseif v.row > 1
            prev = v.lines[v.row - 1]
            v.col = length(prev) + 1
            v.lines[v.row - 1] = string(prev, l)
            deleteat!(v.lines, v.row)
            v.row -= 1
        end
    elseif k in (K_DEL, C_D)
        if v.col <= n
            v.lines[v.row] = string(first(l, v.col - 1), l[nextind(l, 0, v.col + 1):end])
        elseif v.row < length(v.lines)
            v.lines[v.row] = string(l, v.lines[v.row + 1])
            deleteat!(v.lines, v.row + 1)
        end
    elseif k == C_K
        v.col <= n ? (v.lines[v.row] = String(first(l, v.col - 1))) :
                     (v.row < length(v.lines) && (v.lines[v.row] = string(l, v.lines[v.row + 1]);
                                                  deleteat!(v.lines, v.row + 1)))
    elseif k == C_U
        v.lines[v.row] = ""; v.col = 1
    elseif k in (C_W, K_WORD_BACK)
        ws = word_start(l, v.col; alnum = k == K_WORD_BACK)
        if ws < v.col
            v.lines[v.row] = string(first(l, ws - 1), l[nextind(l, 0, v.col):end])
            v.col = ws
        elseif v.row > 1                            # at column 1: join upwards
            prev = v.lines[v.row - 1]
            v.col = length(prev) + 1
            v.lines[v.row - 1] = string(prev, l)
            deleteat!(v.lines, v.row)
            v.row -= 1
        end
    elseif k == K_WORD_LEFT
        v.col > 1 ? (v.col = word_start(l, v.col; alnum = true)) :
        v.row > 1 && (v.row -= 1; v.col = length(v.lines[v.row]) + 1)
    elseif k == K_WORD_RIGHT
        v.col <= n ? (v.col = word_end(l, v.col; alnum = true)) :
        v.row < length(v.lines) && (v.row += 1; v.col = 1)
    elseif k == C_A
        v.col = 1
    elseif k == C_E
        v.col = n + 1
    elseif k == K_LEFT
        v.col > 1 ? (v.col -= 1) :
        v.row > 1 && (v.row -= 1; v.col = length(v.lines[v.row]) + 1)
    elseif k == K_RIGHT
        v.col <= n ? (v.col += 1) :
        v.row < length(v.lines) && (v.row += 1; v.col = 1)
    elseif k == K_UP
        v.row > 1 && (v.row -= 1; v.col = min(v.col, length(v.lines[v.row]) + 1))
    elseif k == K_DOWN
        v.row < length(v.lines) && (v.row += 1; v.col = min(v.col, length(v.lines[v.row]) + 1))
    elseif k == K_HOME
        v.col = 1
    elseif k == K_END
        v.col = n + 1
    elseif printable(k)
        v.lines[v.row] = string(first(l, v.col - 1), Char(k), l[nextind(l, 0, v.col):end])
        v.col += 1
    end
    :ok
end

function handle!(v::PromptView, k::Int, ctrl::Controller)
    if k in (13, 10)
        isempty(strip(v.buf)) || v.onsubmit(strip(v.buf))
        return :pop
    elseif k == 27
        return :pop
    elseif k in (127, 8)
        if v.col > 1
            v.buf = string(first(v.buf, v.col - 2), v.buf[nextind(v.buf, 0, v.col):end])
            v.col -= 1
        end
    elseif k in (K_DEL, C_D)
        v.col <= length(v.buf) &&
            (v.buf = string(first(v.buf, v.col - 1), v.buf[nextind(v.buf, 0, v.col + 1):end]))
    elseif k == C_U
        v.buf = ""; v.col = 1
    elseif k in (C_W, K_WORD_BACK)
        ws = word_start(v.buf, v.col; alnum = k == K_WORD_BACK)
        v.buf = string(first(v.buf, ws - 1), v.buf[nextind(v.buf, 0, v.col):end])
        v.col = ws
    elseif k == C_K
        v.buf = String(first(v.buf, v.col - 1))
    elseif k == K_WORD_LEFT
        v.col = word_start(v.buf, v.col; alnum = true)
    elseif k == K_WORD_RIGHT
        v.col = word_end(v.buf, v.col; alnum = true)
    elseif k == K_LEFT
        v.col = max(1, v.col - 1)
    elseif k == K_RIGHT
        v.col = min(length(v.buf) + 1, v.col + 1)
    elseif k in (C_A, K_HOME)
        v.col = 1
    elseif k in (C_E, K_END)
        v.col = length(v.buf) + 1
    elseif printable(k)
        v.buf = string(first(v.buf, v.col - 1), Char(k), v.buf[nextind(v.buf, 0, v.col):end])
        v.col += 1
    end
    :ok
end
