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
A screen. `render` and `handle!` are required; everything else has a default,
and each is explained where it is defined.

    render(v, w, h) -> String          the whole frame, no trailing newline
    handle!(v, key, ctrl) -> Symbol    :ok | :pop | :quit
    onmouse!(v, ev, ctrl) -> Symbol    the same, for a MouseEvent
    onwake!(v) -> Bool                 adopt background results; true to redraw
    wantsraw(v) -> Bool                take input undecoded, as bytes
    onraw!(v, bytes, ctrl) -> Symbol   those bytes, for a view that asked
    viewcursor(v, w, h)                where the terminal's cursor goes, or nothing
    isdialog(v) -> Bool                a question to answer, or a place to be
    closeview!(v)                      let go of whatever it owns
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

"""Where the real cursor belongs on screen, 1-based `(row, col)`, or `nothing`.

The terminal's cursor is hidden for the whole run because most views draw their
own - a block in a query line owes nothing to where the terminal thinks it is.
A view hosting another program is the exception: the child has a real cursor,
and putting the terminal's own there beats painting a facsimile, which cannot
blink, ignores whatever shape the user chose, and is one more thing to keep in
step with the frame.
"""
viewcursor(::View, ::Int, ::Int) = nothing

struct KeyEvent
    code::Int
end
struct WakeEvent end

"""Input has ended: the terminal went away and nothing more will ever arrive.

Its own event and not an exception, because the loop is parked on a channel and
an exception in the reader task would leave it parked there forever - which is
what a closed terminal used to do. The process is being wound up either way; the
difference is whether the alternate screen, the mouse mode and raw mode are
handed back on the way out.
"""
struct EndEvent end

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

# The key codes themselves are `TermInput.Keys` - the vocabulary went with the
# widgets that bind it, and this is the half that produces it. `C_W`, the two
# word rules and everything a composer is made of come back the same way.


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
        # Whatever arrived, carried as the bytes it was. Assembling the sequence
        # here - rather than handing each byte on separately - is what keeps
        # every view dealing in characters: left as bytes, an accented letter
        # inserted three separate nothings. But it is assembled and not
        # *decoded*, because a codepoint cannot hold what a terminal can send:
        # see `K_BASE`.
        #
        # The framing is Julia's, so a sequence stored in a buffer is read back
        # out of it as the same one `Char`. `0xF8` and above lead nothing, a
        # continuation byte with no lead is itself, and a sequence whose
        # continuation never came is its lead byte alone - which is why the next
        # byte is looked at and not taken.
        n = b >= 0xf8 ? 0 : b >= 0xf0 ? 3 : b >= 0xe0 ? 2 : b >= 0xc0 ? 1 : 0
        k = Int(b)
        for _ in 1:n
            eof(io) && break
            (peek(io, UInt8) & 0xc0) == 0x80 || break
            k = (k << 8) | Int(read(io, UInt8))
        end
        return KeyEvent(k)
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
        # `ESC d` is kill-word, the mirror of alt-backspace. The composer binds
        # both, and the difference between them is the whole reason readline
        # has two.
        a == UInt8('d') && return KeyEvent(K_WORD_KILL)
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
    # Shift is the one modifier the vertical arrows carry a meaning for, and it
    # is the same one it has in every list anybody has ever selected in.
    shifted = (mod - 1) & 0x01 != 0
    fin == 'A' && return KeyEvent(shifted ? K_SUP : K_UP)
    fin == 'B' && return KeyEvent(shifted ? K_SDOWN : K_DOWN)
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

Owning the mouse costs the terminal's own selection, so this is a toggle rather
than a setting: `m` gives it back when you want to select with the terminal, or
when a terminal turns out not to speak SGR at all.

The two sequences are `TermInput.mouse_reporting`, which is also what `suspend`
puts back - a second copy here would be one to keep in step.
"""
function mouse!(ctrl::Controller, on::Bool)
    ctrl.mouse = on
    print(mouse_reporting(on))
    on
end

"""Is this view a dialog, or a place?

A **dialog** answers a question and hands the keys back to whatever asked - a
picker, a prompt, a composer - so it stacks on top of what is underneath and
that is the whole of what it is for.

A **place** is somewhere you work: a terminal, an agent, the worktree list. Two
of those on the stack at once is not a state anybody meant to be in, and it is
how `t` from `"` left four views between the shell and the dashboard - so a
place replaces the place you were in rather than covering it.

Dialogs are the default, because a view that has not thought about this is one
that returns to its caller.
"""
isdialog(::View) = true

"""What a view has to let go of when it is closed out from under itself.

Only a hosted pane has anything: its control-mode client is a process and a
pipe pair, and dropping the view without closing it leaks both.
"""
closeview!(::View) = nothing

push_view!(ctrl::Controller, v::View) = push!(ctrl.stack, v)

"""Take one view off the stack, by identity and wherever it sits.

For a dialog that closes the view which *asked* it: the answer runs while the
question is still on top, so `pop!` would take the question and leave what it
was about. The same `findlast` the loop uses for `:pop`, and for the same
reason.
"""
function pop_view!(ctrl::Controller, v::View)
    at = findlast(x -> x === v || holds(x, v), ctrl.stack)
    at === nothing && return false
    deleteat!(ctrl.stack, at)
    true
end

"""Does this view hold `v` inside it, so that closing one closes the other?

A composer drawn beside the diff it is about is on the stack as the pair, not as
itself - so the question it asks before throwing away what was written names the
composer and has to reach the pair. Without this the answer found nothing, and
`y` to "discard what you have written?" kept it.
"""
holds(::View, ::View) = false

"""Go somewhere, leaving wherever you were.

The root is never a place in this sense - it is the thing every place is
somewhere *from* - so it is the one view this will not close.
"""
function push_place!(ctrl::Controller, v::View)
    while length(ctrl.stack) > 1 && !isdialog(last(ctrl.stack))
        closeview!(pop!(ctrl.stack))
    end
    push!(ctrl.stack, v)
end

"""
    suspend(f, ctrl)

Give the terminal back for the duration of `f`, then take it again - the
controller's terminal and its mouse, handed to `TermInput.suspend`, which is
where the sequences live because anything holding raw mode has this problem.

**Only safe to call from the event loop.** The reader task is parked between
events rather than sitting in `read`, which is what makes this work at all - a
reader blocked in `read(stdin)` would race the child for every keystroke the
user typed into it. The loop does not re-arm the reader until it has finished
handling the event, and running the editor happens inside that handling.
"""
suspend(f, ctrl::Controller) = suspend(f, ctrl.term; mouse = ctrl.mouse)

# --- surviving a bug ---------------------------------------------------------
#
# An exception out of `handle!` or `render` used to end the run, taking the
# terminal's raw mode and alternate screen with it and leaving a backtrace over
# whatever was on screen. That is the wrong trade for a dashboard: nearly every
# such bug costs one frame, and losing the session costs everything that was
# open - including, now, the multiplexer panes being watched.
#
# So it is caught, appended to a file, and the run continues. The file is the
# warning: while it exists the footer says so, and deleting it is how the
# warning is dismissed, which means a bug cannot be silently lived with.

"""Where uncaught errors go. Deleting it clears the warning in the footer."""
const ERRLOG = Ref("")
errlog() = isempty(ERRLOG[]) ? datapath("errors.log") : ERRLOG[]

"""Errors already written this run, so a bug on the render path - which runs
every frame - writes one entry rather than thousands."""
const ERRSEEN = Set{UInt64}()

"""Record an error and carry on. Returns the one-line summary."""
function logerror!(e, bt, what::AbstractString)
    line = oneline(first(sprint(showerror, e), 200))
    key = hash((line, what))
    if !(key in ERRSEEN)
        push!(ERRSEEN, key)
        try
            open(errlog(), "a") do io
                println(io, "\n=== ", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"),
                        "  in ", what, " ===")
                showerror(io, e, bt)
                println(io)
            end
        catch
            # A log that cannot be written must not be the thing that ends the
            # run either.
        end
    end
    line
end

"""Draw `v`, or a frame saying why it could not be drawn.

Split out of the loop so it can be tested: a view that throws is the case that
matters and there is no terminal here to drive the loop with.
"""
function safe_render(v::View, w::Int, h::Int)
    try
        render(v, w, h)
    catch e
        line = logerror!(e, catch_backtrace(), "render")
        rows = vcat(["\e[31mthis view could not be drawn\e[0m"], awrap(line, w),
                    [""], awrap(errnote(), w))
        while length(rows) < h
            push!(rows, "")
        end
        join([apad(r, w) for r in rows[1:h]], "\n")
    end
end

"""Hand `ev` to `v`, or log and carry on. Returns the view's action.

A lost keystroke is a smaller loss than a lost session, which is what an
exception out of here used to cost - and now costs every pane that was open
under it as well.
"""
function safe_dispatch!(v::View, ev, ctrl)
    try
        ev isa MouseEvent ? onmouse!(v, ev, ctrl) :
        ev isa RawEvent   ? onraw!(v, ev.bytes, ctrl) :
                            handle!(v, ev.code, ctrl)
    catch e
        logerror!(e, catch_backtrace(), "handle!")
        :ok
    end
end

"""The footer's standing warning, or `""` when the log has been deleted."""
# Named relatively, and the useful half first. The absolute path is long enough
# that `afit` cut the sentence before "delete", leaving a warning that said
# something was wrong and not what to do about it - and the file sits in the
# directory `wl` is run from, so its name is enough to find it.
errnote() = isfile(errlog()) ?
    string("errors logged in ", basename(errlog()), " \u2014 read it, then delete it to clear this") : ""

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
    ctrl.reader = @async begin
        while ctrl.running
            try
                raw = take!(ctrl.ready)
                ctrl.running || break
                put!(ctrl.events, raw ? readraw(stdin) : readevent(stdin))
            catch
                break
            end
        end
        # Whatever ended the reading - EOF because the terminal closed, EIO
        # because the pty is gone, a `ready` closed at shutdown - the loop is
        # blocked on its channel and nothing else is coming. Say so. Only when
        # the controller still thinks it is running: at shutdown the loop has
        # already left and there is nobody to tell.
        ctrl.running && try
            put!(ctrl.events, EndEvent())
        catch
        end
    end
    try
        dirty, armed = true, false
        while !isempty(ctrl.stack)
            v = last(ctrl.stack)
            if dirty
                h, w = displaysize(stdout)
                print("\e[H", replace(safe_render(v, w, h), "\n" => "\e[K\n"), "\e[J")
                # After the frame, or drawing it would move the cursor again.
                cur = try
                    viewcursor(v, w, h)
                catch e
                    logerror!(e, catch_backtrace(), "viewcursor")
                    nothing
                end
                print(cur === nothing ? "\e[?25l" :
                      string("\e[", cur[1], ";", cur[2], "H\e[?25h"))
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
            if ev isa EndEvent
                # Nothing to ask and nobody to ask: leave through the `finally`
                # below, which is what hands the terminal back.
                break
            elseif ev isa WakeEvent
                dirty = try
                    onwake!(v)
                catch e
                    logerror!(e, catch_backtrace(), "onwake!")
                    true                      # redraw, to show the warning
                end
            else
                armed = false
                act = safe_dispatch!(v, ev, ctrl)
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
        # Guarded, because the commonest way to get here is the terminal having
        # gone away - and then every one of these writes to a descriptor that is
        # closed. An exception thrown from a `finally` replaces whatever brought
        # us here with a stack trace about giving back a terminal that no longer
        # exists.
        try
            ctrl.mouse && mouse!(ctrl, false)
            REPL.Terminals.raw!(ctrl.term, false)
            print("\e[?25h\e[?1049l")
        catch
        end
    end
    0
end

# --- a line prompt, as a view ----------------------------------------------

"""Ask for one line of text.

A view rather than a readline: the controller holds the terminal in raw mode
for the whole run, so anything that wants input has to go through the same
event stream instead of reaching for stdin itself.

The line and its editing are `TermInput.LineInput`. What is here is the two
things that are this program's: the callback the answer goes to, and being a
`View` the stack can hold.
"""
mutable struct PromptView <: View
    li::LineInput
    onsubmit::Any            # (String) -> Nothing; not called when cancelled
    # Spelled out so the default three-of-`Any` one is not generated, since
    # that is the signature the constructor below wants.
    PromptView(li::LineInput, onsubmit) = new(li, onsubmit)
end

"""
    PromptView(title, note, onsubmit; initial = "")

`initial` is what the field starts with and the cursor starts after - the path a
worktree would go to, the value a field already has. A prompt whose answer is
usually a small edit of something the program already knows should offer it:
it is faster to correct than to type, and it says what shape the answer takes.
"""
PromptView(title, note, onsubmit; initial::AbstractString = "") =
    PromptView(LineInput(title, note; initial = initial,
                         hint = "enter accept · ^w word · ^a/^e line · esc cancel"),
               onsubmit)

text(v::PromptView) = TermInput.text(getfield(v, :li))

# A field the wrapper does not have is the widget's. `v.title`, `v.status` and
# `v.hint` are the composer's own and are read and written all over this
# program; spelling `v.li` in front of each of them would say nothing except
# that a wrapper exists. The wrapper's own fields still come first, so the
# delegation can never be mistaken for a second copy of the state.
Base.getproperty(v::PromptView, f::Symbol) =
    f in fieldnames(PromptView) ? getfield(v, f) : getproperty(getfield(v, :li), f)
Base.setproperty!(v::PromptView, f::Symbol, x) =
    f in fieldnames(PromptView) ? setfield!(v, f, x) : setproperty!(getfield(v, :li), f, x)

render(v::PromptView, w::Int, h::Int) = TermInput.render(getfield(v, :li), w, h)

function handle!(v::PromptView, k::Int, ctrl::Controller)
    TermInput.handle!(getfield(v, :li), k) === :ok && return :ok
    # A text box edits text and does not decide when you are done, so the keys
    # that finish one are bound here. An answer of nothing is somebody changing
    # their mind in front of the question, not a submission of nothing.
    if k in (13, 10)
        isblank(getfield(v, :li)) || v.onsubmit(submission(getfield(v, :li)))
        return :pop
    elseif k == 27 || k == C_G
        return :pop
    end
    :ok
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
    numbered::Bool                        # are the first ten on keys of their own?
end
ChooseView(title, note, options, onpick; numbered::Bool = false) =
    ChooseView(String(title), String(note), options, "", 1, 1, onpick, numbered)

"""The key that picks row `i` straight off, or `' '` for a row past the tenth.

`1`-`9` and then `0`, which is where a decade of terminals put the tenth of
anything. Only for a list that is the same list every time and is reached by
memory rather than by reading - the views - and it costs those ten the ability
to be narrowed by typing a digit, which is a trade the built-in names can
afford.
"""
numkey(i::Int) = i < 1 || i > 10 ? ' ' : i == 10 ? '0' : Char('0' + i)

shown(v::ChooseView) = isempty(v.query) ? v.options :
    [o for o in v.options if occursin(lowercase(v.query), lowercase(o[1]))]

# The box the two dialogs below are drawn in is `TermInput.dialogbox`: the same
# `head`/`row`/`foot`/`hint` a composer is built out of, so a picker and a
# composer on the same screen cannot end up 76 and 72 columns wide. `centred`
# puts one in the middle of the screen and pads it out to a whole frame.

function render(v::ChooseView, w::Int, h::Int)
    opts = shown(v)
    b = dialogbox(w; width = 76)
    bh = clamp(length(opts), 1, max(1, h - 10))
    v.sel = clamp(v.sel, 1, max(1, length(opts)))
    v.top = clamp(v.top, 1, max(1, length(opts)))
    v.sel < v.top && (v.top = v.sel)
    v.sel > v.top + bh - 1 && (v.top = v.sel - bh + 1)
    v.top = clamp(v.top, 1, max(1, length(opts) - bh + 1))

    out = [b.head(v.title)]
    isempty(v.note) || push!(out, b.row(v.note, "\e[2m"))
    push!(out, b.row(string("/ ", v.query, "\e[7m \e[0m")))
    for i in v.top:(v.top + bh - 1)
        if i > length(opts)
            push!(out, b.row(""))
        else
            # The digit, or a space where it has run out, so the names stay
            # in one column whether or not the row has a key of its own.
            label = v.numbered ? string(numkey(i), "  ", opts[i][1]) : opts[i][1]
            push!(out, b.row(label, i == v.sel ? "\e[1;37m" : "\e[2m"))
        end
    end
    isempty(opts) && (out[end] = b.row("nothing matches", "\e[2m"))
    push!(out, b.foot())
    push!(out, b.hint(v.numbered ? "0-9 picks · ↑/↓ move · ↵ pick · esc cancel" :
                                   "↑/↓ move · ↵ pick · esc cancel"))
    centred(out, w, h)
end

function handle!(v::ChooseView, k::Int, ctrl::Controller)
    k = unshift(k)
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
    elseif v.numbered && Int('0') <= k <= Int('9')
        # Above `printable`, so the digit picks rather than narrowing. Nothing
        # happens where there is no tenth row to pick.
        i = k == Int('0') ? 10 : k - Int('0')
        i <= length(opts) || return :ok
        v.onpick(opts[i][2])
        return :pop
    elseif k in (127, 8)
        isempty(v.query) || (v.query = v.query[1:prevind(v.query, end)]; v.sel = 1)
    elseif k == C_U
        v.query = ""; v.sel = 1
    elseif k in (C_W, K_WORD_BACK)
        v.query = String(first(v.query, word_start(v.query, length(v.query) + 1) - 1))
        v.sel = 1
    elseif printable(k)
        v.query *= keychar(k); v.sel = 1
    end
    :ok
end

# --- a yes or no, as a view -------------------------------------------------

"""Ask a question that named keys answer, and nothing else does.

Not a `ChooseView` of two entries: there the answer is already under the cursor
and `↵` takes it, which is exactly the reflex a question like this exists to
interrupt. Here the answering key is one you would not be holding - `y` by
default, named on screen - and *everything* else is no, including the key that
opened the question and the enter that would have picked something in a picker.

An answer is `"keys" => f`, where the string is every key that gives that answer
(`"yY"`, so shift does not matter) and `f` says what it was worth: `:quit` ends
the run, anything else closes the question and goes back to what asked it. More
than one answer is how a question offers the thing you would rather do than say
yes - and each is a key you have to reach for on purpose.

`notes` is a line or several: what is at stake, one fact to a row.
"""
struct ConfirmView <: View
    title::String
    notes::Vector{String}
    hint::String
    answers::Vector{Pair{String,Any}}
end
noterows(s::AbstractString) = isempty(s) ? String[] : [String(s)]
noterows(v) = String[String(r) for r in v if !isempty(r)]
ConfirmView(title, notes, answers::AbstractVector{<:Pair};
            hint::AbstractString = "y confirms \u00b7 any other key cancels") =
    ConfirmView(String(title), noterows(notes), String(hint),
                Pair{String,Any}[String(k) => f for (k, f) in answers])
ConfirmView(title, notes, onyes; kw...) =
    ConfirmView(title, notes, ["yY" => onyes]; kw...)

function render(v::ConfirmView, w::Int, h::Int)
    b = dialogbox(w; width = 76)
    out = [b.head(v.title)]
    for n in v.notes
        push!(out, b.row(n, "\e[2m"))
    end
    push!(out, b.foot())
    push!(out, b.hint(v.hint))
    centred(out, w, h)
end

function handle!(v::ConfirmView, k::Int, ctrl::Controller)
    # Escape is an answer when a question names one for it, and not otherwise.
    # It is the key a dialog appearing produces from the fingers, so a question
    # that means something particular by it - the draft question means "put me
    # back where I was" - has to say so in its hint; every other question here
    # takes it as the dismissal it looks like.
    (printable(k) || k == 27) || return :pop
    for (keys, answer) in v.answers
        keychar(k) in keys && return answer() === :quit ? :quit : :pop
    end
    :pop
end

# --- a multi-line composer, as a view ---------------------------------------

"""A small multi-line text area, as a view.

The buffer, the keys, the wrapping and the box are `TermInput.TextArea`. Three
things are left here because they are this program's rather than a composer's:

  * **Escape asks first.** Words that were typed are the one thing in this
    program that exists nowhere else - a note is on disk as it is written, a
    snooze is a field, a draft review is on GitHub - and a comment
    half-composed is in this buffer and in no other place. So the key that
    throws it away confirms, which nothing else in here needs to do. An empty
    buffer is not something to lose, and a question about it would be a dialog
    in front of every composer opened by mistake.
  * **`^r` drops a block in.** The composer knows nothing about what it is -
    the caller does, and hands it over already written. `TextArea` hands the
    key back as `:unhandled`, which is what makes it the caller's to bind.
  * **The terminal `⌥e` hands over is the controller's**, and is only known
    once an event is being handled in it.
"""
mutable struct EditorView <: View
    ta::TextArea
    onsubmit::Any            # (String) -> Nothing; not called when cancelled
    suggest::String          # a block `^r` drops in, empty when there is none
    allow_empty::Bool        # an approval needs no words; a comment does
    # Spelled out so that the default one - three arguments of `Any` - is not
    # generated, because that is the signature the constructor below wants.
    EditorView(ta::TextArea, onsubmit, suggest::AbstractString, allow_empty::Bool) =
        new(ta, onsubmit, String(suggest), allow_empty)
end

function EditorView(title, note, onsubmit; initial::AbstractString = "",
                    allow_empty::Bool = false, suggest::AbstractString = "")
    hint = string("^s submit · ", isempty(suggest) ? "" : "^r suggestion · ",
                  "⌥e/^o \$EDITOR · ^w word · ^a/^e line · esc cancel")
    EditorView(TextArea(title, note; initial = initial, hint = hint),
               onsubmit, String(suggest), allow_empty)
end

text(v::EditorView) = TermInput.text(getfield(v, :ta))

# The same delegation as `PromptView` above, and for the same reason: `v.title`
# and `v.status` are the composer's. The buffer is one step further down and
# stays spelled out - `v.buf.row` is where the cursor is, and a view that
# looked like it had a cursor of its own would be a view somebody kept a second
# copy in.
Base.getproperty(v::EditorView, f::Symbol) =
    f in fieldnames(EditorView) ? getfield(v, f) : getproperty(getfield(v, :ta), f)
Base.setproperty!(v::EditorView, f::Symbol, x) =
    f in fieldnames(EditorView) ? setfield!(v, f, x) : setproperty!(getfield(v, :ta), f, x)

render(v::EditorView, w::Int, h::Int) = TermInput.render(getfield(v, :ta), w, h)

function handle!(v::EditorView, k::Int, ctrl::Controller)
    # Which terminal to give away is not known when the view is built, and is
    # known here: a composer is only ever driven from the loop that owns one.
    ta = getfield(v, :ta)
    ta.suspend = f -> suspend(f, ctrl)
    TermInput.handle!(ta, k) === :ok && return :ok
    # What is left is every key that does not edit text, which the composer
    # hands back because none of it is a text box's to answer.
    if k == C_S                                     # submit
        if isblank(ta) && !v.allow_empty
            ta.status = "nothing to send — esc cancels"
            return :ok
        end
        v.onsubmit(submission(ta))
        return :pop
    elseif k == 27 || k == C_G                      # give up, and ask first
        isblank(ta) && return :pop
        ls = length(ta.buf.lines)
        push_view!(ctrl, ConfirmView("Discard what you have written?",
            [ta.title, string(ls, ls == 1 ? " line" : " lines", " written")],
            ["yY" => () -> pop_view!(ctrl, v)];
            hint = "y discards it \u00b7 any other key goes back to writing"))
        return :ok
    elseif k == C_R                                 # the suggestion block
        if isempty(v.suggest)
            ta.status = "nothing to suggest here — this is not a line comment"
        else
            insertblock!(ta.buf, v.suggest)
            ta.status = "suggestion inserted — edit the lines, they replace the ones commented on"
        end
    end
    :ok
end
