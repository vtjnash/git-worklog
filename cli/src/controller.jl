# The view controller: the one thing that owns stdin.
#
# Input used to be read wherever a view happened to want it, which forced a
# choice between two bad options. A dedicated reader task per view outlives its
# view - still blocked in readkey, holding stdin - and steals the next keystroke
# from whatever runs next. Polling `bytesavailable` avoids that but never
# terminates on a non-TTY, spins the CPU, and adds latency to every key.
#
# Owning stdin for the whole run removes the choice. One reader task exists for
# the lifetime of the process - `TermInput`'s `InputReader` - and keys, mouse
# events and background wakeups arrive on the same channel, so the loop can
# block on `take!` - no polling, no sleep, and a fetch finishing redraws
# immediately rather than at the next tick.

"""
A screen. `render` and `handle!` are required; everything else has a default,
and each is explained where it is defined.

    render(v, w, h) -> String          the whole frame, no trailing newline
    handle!(v, key, ctrl) -> Symbol    :ok | :pop | :quit
    onmouse!(v, ev, ctrl) -> Symbol    the same, for a MouseEvent
    onwake!(v) -> Bool                 adopt background results; true to redraw
    onresize!(v)                       the terminal changed shape; the frame is redrawn regardless
    wantsraw(v) -> Bool                take input undecoded, as bytes
    onraw!(v, bytes, ctrl) -> Symbol   those bytes, for a view that asked
    onpaste!(v, text, ctrl) -> Symbol  a bracketed paste, as text; ignored by default
    viewcursor(v, w, h)                where the terminal's cursor goes, or nothing
    viewtitle(v) -> String | nothing   what the terminal's title bar says while this is on top
    isdialog(v) -> Bool                a question to answer, or a place to be
    closeview!(v)                      let go of whatever it owns
"""
abstract type View end

onwake!(::View) = false
onresize!(::View) = nothing

"""Bring what a view shows up to date with what it has selected, after any
event, whichever view the event went to. Returns whether the frame changed.

The one place a selection's consequences are started. Before it, every path
that could move a cursor had to remember to start them - the end of a key, a
wake, and then each dialog's answer and each other view's callback one at a
time, since those run while something else is on top and no key of the
view's own is about to finish. Asked of every view in the stack, not only the
top: the answer that moves the browser's cursor comes from the dialog over it.
"""
settle!(::View) = false

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

"""The terminal's title while `v` is on top, or `nothing` to leave it to the
view underneath - a dialog has nothing to say about it, and the item stays in
the title bar while a question about it is being answered."""
viewtitle(::View) = nothing

"""The title for the stack as it stands: the topmost view with an answer, else
the bare name. Written with OSC 2 after a frame, only when it has changed -
the tab, or tmux's pane title, says which item the browser is on."""
function stacktitle(stack::Vector{View})
    for v in Iterators.reverse(stack)
        t = viewtitle(v)
        t === nothing || return String(t)
    end
    "wl"
end

struct WakeEvent end

"""The terminal changed shape.

Its own event and not a `WakeEvent`, so a view is told which it was: a wake
means "something landed, adopt it", and a hosted pane on a wake resizes its
child to whatever `displaysize` says *because* it cannot tell. Every cache
keyed on a width - `Node.cw`, `st.diw`, `st.dpage` - is checked against the
width of the frame that reads it, so nothing has to be dropped here; the frame
is drawn again at the new size, which is the whole of what a resize needs.
"""
struct ResizeEvent end

"""Somewhere to put a paste - `TermInput`'s `PasteEvent`, with bracketed paste on
for the whole run - for a view that has one. The default is to do nothing with
it, which is the point of it not being keys."""
onpaste!(::View, ::AbstractString, ::Any) = :ok

"""A mouse report, `TermInput`'s `MouseEvent`, for a view that takes one."""
onmouse!(::View, ::MouseEvent, ::Any) = :ok

"""Input that was never decoded, for a view that asked to forward it."""
struct RawEvent
    bytes::Vector{UInt8}
end

"""The scheme the terminal last reported, or `nothing` before it has: what
tells a report that is a change from the first answer, which is when the
background is worth asking for again."""
const TERM_DARK = Ref{Union{Nothing,Bool}}(nothing)

# --- raw input ------------------------------------------------------------
#
# Decoding is `TermInput`'s `readevent`, which also reads the scheme and
# background reports as `SchemeEvent`s. What is here is the other way in: the
# bytes undecoded, for a view that forwards them, with those reports taken out.

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
    # A read that ends inside one of our reports waits for the rest of it,
    # as `readevent` does for any sequence: the report is ours whenever it
    # arrives, and its head alone would have gone to the child. What stops
    # being able to become one goes on as the bytes it is.
    while occursin(REPORT_UNFINISHED, String(copy(buf)))
        push!(buf, read(io, UInt8))
        n = bytesavailable(io)
        n > 0 && append!(buf, read(io, n))
    end
    scheme_in(buf)
end

"""A read that ends partway into a report `scheme_in` takes: `ESC [ ?` and
on towards `997;1n`, or `ESC ]` and on towards `11;<colour>` and its
terminator. Not a bare `ESC` or `ESC [`, which are keys: Escape, and the head
of every arrow, arrive in one write and are never held for a report."""
const REPORT_UNFINISHED =
    r"\e(?:\[\?(?:9(?:9(?:7(?:;[12]?)?)?)?)?|\](?:1(?:1(?:;[\x21-\x7e]{0,100}\e?)?)?)?)$"

"""A raw read as the event it is: the colour-scheme report and the background
colour are ours and not the child's, and are taken out of the bytes with
whatever else came with them left in order. A report cut across two reads
is whole by the time it is here (`readraw`)."""
function scheme_in(buf::Vector{UInt8})
    s = String(copy(buf))
    m = nothing
    for x in eachmatch(SCHEME_REPORT, s)
        m = x
    end
    b = nothing
    for x in eachmatch(BG_REPORT, s)
        b = x
    end
    m === nothing && b === nothing && return RawEvent(buf)
    rest = replace(s, SCHEME_REPORT => "", BG_REPORT => "")
    SchemeEvent(m === nothing ? nothing : m[1] == "1", b === nothing ? "" : String(b[1]),
                Vector{UInt8}(codeunits(rest)))
end

"""One event from stdin, for the reader: undecoded when the view on top forwards
its input (`wantsraw`), keys otherwise. Which is decided by the loop as it
arms the reader, and handed over as `raw`."""
readinput(io::IO, raw::Bool) = raw ? readraw(io) : readevent(io)

mutable struct Controller
    term::Union{Nothing,HeldTerminal}   # while `run!` holds it
    events::Channel{Any}
    reader::Union{Nothing,InputReader{Bool}}  # `readinput`, onto `events`
    stack::Vector{View}
    running::Bool
    mouse::Bool                 # what `m` last asked for; `term.mouse` follows it
    title::String               # what the terminal's title bar was last told
    woken::Bool                 # a `WakeEvent` is on `events` and not yet taken
end
Controller() = Controller(nothing, Channel{Any}(64), nothing, View[], false, false,
                          "", false)

"""Called from a background task to ask for a redraw once its work has landed.

**One wake on the queue at a time, and never a blocking one.** A wake is a
level, not a count: the loop that takes it runs every collector there is
(`onwake!`), so a second one queued behind the first would find nothing left
to adopt. And the task calling this may be one the loop is waiting on. A
hosted pane's control-mode reader called it once per `%output` line (a pane's
`watch_pane!` does now, per wake of the client), and the loop answers a wake
by asking tmux for the screen and blocking on the reply - which that same
reader has to deliver, after every `%output` line queued in front of it.
Sixty-four of those and `put!` blocked the reader with the reply
unread: the ask timed out at five seconds, the client was marked dead, and
the pane said `session ended` over an empty frame with no reason anywhere. A
child clearing to the alternate screen, or `git log` into a pager, is that
many lines in one burst. It was tested once at eleven of the sixty-four and
called wrong; it was the burst that was missing.
"""
function wake!(ctrl::Controller)
    ctrl.running && isopen(ctrl.events) || return false
    ctrl.woken && return true
    ctrl.woken = true
    put!(ctrl.events, WakeEvent())
    true
end
"`wake!` the controller a view was handed, if it was handed one."
wake!(::Nothing) = false

"""A view whose frame holds colours it worked out before now - rendered rows,
headers built with the theme's escapes in them - drops them, because the theme
just changed. Most views draw from `THEME` on every frame and need nothing."""
retheme!(::View) = nothing

"""Draw with the theme for a terminal whose colours are `dark` or light.

The one `config.toml` names, or its pair (`scheme_theme`); nothing happens
when that is the one already loaded, which is every report after the first
until the terminal's scheme actually changes. What the load had to say
replaces what the last one did, in the footer's standing note."""
function scheme!(ctrl::Controller, dark::Bool)
    path = scheme_theme(themefile(), dark)
    path == LOADED_THEME[] && return false
    probs = load_theme!(path)
    empty!(THEME_NOTES)
    append!(THEME_NOTES, probs)
    for v in ctrl.stack
        try
            retheme!(v)
        catch e
            logerror!(e, catch_backtrace(), "retheme!")
        end
    end
    true
end

"`settle!` every view in the stack, bottom first; whether any frame changed."
function settle_all!(ctrl::Controller)
    changed = false
    for v in copy(ctrl.stack)
        changed |= try
            settle!(v) === true
        catch e
            logerror!(e, catch_backtrace(), "settle!")
            true
        end
    end
    changed
end

"""Hear the terminal change shape, and put a `ResizeEvent` on the loop.

Nothing answered a resize before this: the frame was drawn at the `displaysize`
read on the last key or wake and stayed that shape until the next one, so a
narrowed terminal showed a torn frame and a widened one a frame in its corner
until something was pressed - and a hosted pane's child was told its new box
only then.

SIGWINCH, through libuv's `uv_signal_t` - the loop it fires on is the one
`take!(ctrl.events)` waits on, so this is the same plumbing as a key. Julia
wraps no signal but its own, so the handle is libuv's directly: allocated at
libuv's own size for it, started under the io lock the way `Timer` starts its
handle, and unref'd so it never holds the loop open by itself. The signal
callback runs on the loop and may not yield, so it does one thing that is safe
there - `uv_async_send` on a `Base.AsyncCondition` - and a task waiting on the
condition does the `put!`. A timer comparing `displaysize` every 200 ms was the
other way, and one ioctl every fifth of a second for the life of the browser
is a cadence of its own, which nothing else here runs on.

Windows too: libuv delivers SIGWINCH there itself, from the console's resize
events, and gives it the same number (`uv/win.h`), so nothing here asks which
system it is on.

Returns the function that stops it, for `run!`'s `finally`.
"""
const SIGWINCH = 28
const UV_SIGNAL = 16            # uv_handle_type, for `uv_handle_size`
const WINCH_COND = Ref{Base.AsyncCondition}()
winch_signalled(::Ptr{Cvoid}, ::Cint) =
    (ccall(:uv_async_send, Cint, (Ptr{Cvoid},), WINCH_COND[].handle); nothing)
winch_freed(h::Ptr{Cvoid}) = (Libc.free(h); nothing)
function watch_winch!(ctrl::Controller)
    cond = Base.AsyncCondition()
    WINCH_COND[] = cond
    h = Libc.malloc(ccall(:uv_handle_size, Csize_t, (Cint,), UV_SIGNAL))
    Base.iolock_begin()
    try
        ccall(:uv_signal_init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}), Base.eventloop(), h)
        ccall(:uv_signal_start, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Cint), h,
              @cfunction(winch_signalled, Cvoid, (Ptr{Cvoid}, Cint)), SIGWINCH)
        ccall(:uv_unref, Cvoid, (Ptr{Cvoid},), h)
    finally
        Base.iolock_end()
    end
    @async while isopen(cond)
        try
            wait(cond)
        catch
            break                       # closed: the watch is over
        end
        ctrl.running && isopen(ctrl.events) && put!(ctrl.events, ResizeEvent())
    end
    () -> begin
        Base.iolock_begin()
        try
            ccall(:uv_signal_stop, Cint, (Ptr{Cvoid},), h)
            ccall(:uv_close, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), h,
                  @cfunction(winch_freed, Cvoid, (Ptr{Cvoid},)))
        finally
            Base.iolock_end()
        end
        close(cond)
    end
end

"""Turn mouse reporting on or off.

Owning the mouse costs the terminal's own selection, so this is a toggle rather
than a setting: `m` gives it back when you want to select with the terminal, or
when a terminal turns out not to speak SGR at all.

The two sequences are `TermInput.mouse_reporting`, which is also what `suspend`
puts back - a second copy here would be one to keep in step - and the held
terminal is told, so that `suspend` and `leave_terminal` put back what is on.
"""
function mouse!(ctrl::Controller, on::Bool)
    ctrl.mouse = on
    ctrl.term === nothing || (ctrl.term.mouse = on)
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
controller's held terminal, handed to `TermInput.suspend`, which undoes what
`enter_terminal` did because anything holding raw mode has this problem; and
the scheme reports, which are this program's. With no terminal held - a test -
the sequences are written all the same.

**Only safe to call from the event loop.** The reader task is parked between
events rather than sitting in `read`, which is what makes this work at all - a
reader blocked in `read(stdin)` would race the child for every keystroke the
user typed into it. The loop does not re-arm the reader until it has finished
handling the event, and running the editor happens inside that handling.
"""
function suspend(f, ctrl::Controller)
    print(scheme_reports(false))
    try
        ctrl.term === nothing ? suspend(f, nothing; mouse = ctrl.mouse, paste = true) :
                                suspend(f, ctrl.term)
    finally
        # And asked again: the scheme may have changed while it was away.
        print(scheme_reports(true))
    end
end

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
        rows = vcat([string(THEME.blocked, "this view could not be drawn",
                            THEME.reset)], awrap(line, w),
                    [""], awrap(standing_note(), w))
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
        ev isa PasteEvent ? onpaste!(v, ev.text, ctrl) :
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

"""What stands in the footer until it is dealt with: a logged error, else a
source the poll cannot get an answer from, else a theme that did not load as
written, else a tmux server older than ours. All four are things the reader
has to act on and none happens again by itself, which is what makes them the
footer's rather than the status row's."""
standing_note(at::DateTime = utcnow(), failing = ()) = (e = errnote(); !isempty(e) ? e :
                   (f = failnote(failing, at); !isempty(f) ? f :
                    !isempty(THEME_NOTES) ? string("theme: ", first(THEME_NOTES)) : muxnote()))

"""The tmux server this is talking to, when it is older than the tmux `wl`
runs (`MUX_OLDER`): the panes are the server's, and it may be missing features
they count on. Which ones is not said - the list would only be right until the
next one - and restarting the server on a newer tmux is the reader's call,
since it ends every session on it, theirs too."""
muxnote() = (v = MUX_OLDER[]; isempty(v[1]) ? "" :
             string("tmux: the server is ", v[1], ", older than wl's ", v[2],
                    ", and may be missing features"))

"""The first source whose last poll failed, and how many more there are.

`failing` is the inbox's `failed` table as `Events.failing` reads it, held on
the browser's state (`BState.failing`) and taken again when `fetched.json`
lands, not read from the file at every frame. The table is where the poll
writes the one line of its report the reader has to act on - so the launch
poll, which runs before there is a frame and reports to nobody, is said here
all the same, and `u`'s is said twice, here and in `refresh.log`. What to do
comes before what GitHub said, since the row is cut at the edge and the
message is the part that can run long. Clears itself: the next poll that
gets an answer from the source deletes the entry.
"""
function failnote(fs, at::DateTime)
    isempty(fs) && return ""
    f = first(fs)
    string(f.label, ": the poll FAILED ", ago_str(f.since, at),
           length(fs) > 1 ? string(" (and ", length(fs) - 1, " more)") : "",
           " \u2014 stands until it answers", isempty(f.why) ? "" : string(" \u00b7 ", f.why))
end

"""Input has ended; say so in the error log when it was not the terminal.

End of file and an I/O error are the terminal going away, which is how a
session usually ends and nothing to warn about. Anything else is a read that
failed - a bug in a decoder - and the run is over either way, so it goes where
every other error goes: the log, whose warning the next launch shows, since
this one has no footer left to show it in. Returns whether it logged.
"""
function ended!(ev::EndEvent)
    (ev.why === nothing || ev.why isa EOFError || ev.why isa Base.IOError) && return false
    # The reader keeps the error and not where it was thrown, so the entry is
    # the error alone.
    logerror!(ev.why, Base.StackTraces.StackFrame[], "reading input")
    true
end

"""
    run!(ctrl, root)

Own the terminal, then dispatch events until the stack empties.

The terminal is `TermInput`'s to enter and leave, the events its reader's, and
a frame its `frame_bytes`; what is here is the loop and its policy. The reader
lives as long as the controller, which lives as long as the program - so it is
never left running behind a view that has gone away. It is blocked in a read
at exit; the process is ending, so it is let go and left to die with it rather
than being interrupted mid-read.
"""
function run!(ctrl::Controller, root::View)
    if !(stdin isa Base.TTY)
        println(stderr, "wl: this view needs a terminal; stdin is not a TTY")
        return 1
    end
    push_view!(ctrl, root)
    # The terminal's title, which juliaup's launcher had set to `Julia` and
    # nothing here set after: a tab, or under tmux the pane's title. Saved
    # on the way in and put back on the way out (`title`), so a terminal with
    # a title stack (xterm, VTE, kitty, wezterm, iTerm2, foot) gets its own
    # back; one without keeps the last one until its shell's prompt writes the
    # next, which every common prompt does. What it says is set per frame,
    # below. Bracketed paste is on for the whole run, so a paste is text.
    ctrl.term = enter_terminal(stdin, stdout; altscreen = true, title = true,
                               mouse = true, paste = true)
    ctrl.mouse = true
    # Asked and not waited for: the answer is an event like any other, and a
    # terminal that does not know the question says nothing at all.
    print(scheme_reports(true))
    ctrl.running = true
    unwatch_winch = watch_winch!(ctrl)
    # One event per `arm!`, parked between them, which is what lets `suspend`
    # hand stdin to a child. Whatever ends the reading - EOF because the
    # terminal closed, EIO because the pty is gone - comes as an `EndEvent`.
    ctrl.reader = InputReader(readinput, ctrl.term, ctrl.events, Bool)
    try
        dirty, armed = true, false
        # Before the first frame too, so the browser's first thread is asked
        # for rather than an empty pane drawn until somebody presses something.
        settle_all!(ctrl)
        while !isempty(ctrl.stack)
            v = last(ctrl.stack)
            # Not while the terminal has already sent more: a paste into a
            # composer is a key per character, and a frame per key was ~14 kB
            # rendered, written and drawn per character - a paste came in at
            # about typing speed. `dirty` stays set, so the frame is drawn
            # once the input already here has run out.
            if dirty && !input_waiting(ctrl.term)
                h, w = displaysize(ctrl.term)
                # The title bar follows the selection: `wl JuliaLang/julia#1`
                # while that is the item, `wl` on the import row. Only on a
                # change, since a terminal redraws its tab for every OSC 2 it
                # is sent.
                t = stacktitle(ctrl.stack)
                title = t == ctrl.title ? "" : (ctrl.title = t; string("\e]2;", t, "\e\\"))
                # Asked after the frame is rendered, since rendering is what
                # decides where a composer's caret is.
                cur = try
                    viewcursor(v, w, h)
                catch e
                    logerror!(e, catch_backtrace(), "viewcursor")
                    nothing
                end
                write(ctrl.term, frame_bytes(safe_render(v, w, h), title, cur; h))
                dirty = false
            end
            # Arm only when the previous event is fully handled. A wakeup does
            # not consume the token: the reader is still waiting on the key it
            # was armed for, and arming twice would put it back on the tty
            # while the loop is busy.
            # The mode is decided here, where the top view is known, and not
            # in the reader, which is parked between events and would be
            # deciding it against whatever was on top last time.
            armed || (arm!(ctrl.reader, wantsraw(v)); armed = true)
            ev = take!(ctrl.events)                 # blocks; no polling
            if ev isa EndEvent
                # Nothing to ask and nobody to ask: leave through the `finally`
                # below, which is what hands the terminal back.
                ended!(ev)
                break
            elseif ev isa WakeEvent
                # Cleared before the collectors run, so a wake that lands while
                # they are running queues the next one rather than being lost.
                ctrl.woken = false
                dirty = try
                    onwake!(v)
                catch e
                    logerror!(e, catch_backtrace(), "onwake!")
                    true                      # redraw, to show the warning
                end
            elseif ev isa ResizeEvent
                # Redrawn whatever the view says: the screen is not the shape
                # the last frame was.
                try
                    onresize!(v)
                catch e
                    logerror!(e, catch_backtrace(), "onresize!")
                end
                dirty = true
            else
                armed = false
                if ev isa SchemeEvent
                    if ev.dark !== nothing
                        scheme!(ctrl, ev.dark)
                        # A flip, not the first answer - which came with a
                        # background of its own - is a new background too.
                        was = TERM_DARK[]
                        TERM_DARK[] = ev.dark
                        was === nothing || was == ev.dark || print(BG_QUERY)
                    end
                    isempty(ev.bg) || terminal_bg!(ev.bg)
                    ev = isempty(ev.rest) ? nothing : RawEvent(ev.rest)
                end
                act = ev === nothing ? :ok : safe_dispatch!(v, ev, ctrl)
                act === :quit && break
                # Pop the view that asked, not whatever is on top: a view may
                # push its successor while handling the key it pops on - the
                # picker that opens a composer does exactly that - and popping
                # the top would throw away the one just pushed.
                if act === :pop
                    at = findlast(x -> x === v, ctrl.stack)
                    at === nothing || deleteat!(ctrl.stack, at)
                    # And a wake for the view underneath, which heard none while
                    # it was covered: a fetch can have landed behind it.
                    wake!(ctrl)
                end
                dirty = true
            end
            settle_all!(ctrl) && (dirty = true)
        end
    finally
        ctrl.running = false
        close(ctrl.reader)                          # release the parked reader
        try
            unwatch_winch()
        catch
        end
        # Guarded, because the commonest way to get here is the terminal having
        # gone away - and then every one of these writes to a descriptor that is
        # closed. An exception thrown from a `finally` replaces whatever brought
        # us here with a stack trace about giving back a terminal that no longer
        # exists. `leave_terminal` is guarded the same way.
        try
            print(scheme_reports(false))
        catch
        end
        leave_terminal(ctrl.term)
        ctrl.term = nothing
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

onpaste!(v::PromptView, s::AbstractString, ::Controller) =
    (TermInput.paste!(getfield(v, :li), s); :ok)

# --- a picker, as a view ----------------------------------------------------

"""Pick one of a list, narrowing by typing.

The list, its query, its cursor and its box are `TermInput.Choice`, and a
click on it is `TermInput.click!` (`mouse.jl`). What is here is what is this
program's: the value each option stands for, the callback the pick goes to, and
being a `View` the stack can hold - which is also what escape means, closing it.
"""
mutable struct ChooseView <: View
    c::Choice
    options::Vector{Tuple{String,Any}}    # (what is shown, what is returned)
    onpick::Any                           # (value) -> Nothing; not called on cancel
    ChooseView(c::Choice, options, onpick) = new(c, options, onpick)
end
# The hint is the widget's keys and then this view's: `↵` and escape come back
# from a `Choice`, and what they do here is pick and close.
ChooseView(title, note, options, onpick; numbered::Bool = false) =
    ChooseView(Choice(title, note, [o[1] for o in options]; numbered,
                      hint = string(numbered ? "0-9 picks · " : "", CHOICE_HINT,
                                    " · ↵ pick · esc cancel")),
               Tuple{String,Any}[(String(o[1]), o[2]) for o in options], onpick)

# The title, the note, the cursor and the rest are the widget's, read through
# the view as `PromptView`'s are.
Base.getproperty(v::ChooseView, f::Symbol) =
    f in fieldnames(ChooseView) ? getfield(v, f) : getproperty(getfield(v, :c), f)
Base.setproperty!(v::ChooseView, f::Symbol, x) =
    f in fieldnames(ChooseView) ? setfield!(v, f, x) : setproperty!(getfield(v, :c), f, x)

"What is typed to narrow the list."
query(v::ChooseView) = TermInput.query(getfield(v, :c))
query!(v::ChooseView, s::AbstractString) = (TermInput.query!(getfield(v, :c), s); v)

"The options the query leaves showing."
shown(v::ChooseView) = v.options[TermInput.matches(getfield(v, :c))]

render(v::ChooseView, w::Int, h::Int) = TermInput.render(getfield(v, :c), w, h)

"Pick the option at `i` of `options`, and close."
pick!(v::ChooseView, i::Int) = (v.onpick(v.options[i][2]); :pop)

function handle!(v::ChooseView, k::Int, ctrl::Controller)
    c = getfield(v, :c)
    TermInput.handle!(c, k) === :ok && return :ok
    unshift(k) == 27 && return :pop
    i = TermInput.picked(c, k)
    i == 0 ? :ok : pick!(v, i)
end

onpaste!(v::ChooseView, s::AbstractString, ::Controller) =
    (TermInput.paste!(getfield(v, :c), s); :ok)

# --- a yes or no, as a view -------------------------------------------------

"""Ask a question that named keys answer, and nothing else does.

The question, its keys and its box are `TermInput.Confirm`. An answer here is
`"keys" => f`, where the string is every key that gives that answer and `f`
says what it was worth: `:quit` ends the run, anything else closes the question
and goes back to what asked it. More than one answer is how a question offers
the thing you would rather do than say yes - and each is a key you have to reach
for on purpose.
"""
struct ConfirmView <: View
    c::Confirm
    answers::Vector{Any}
end
ConfirmView(title, notes, answers::AbstractVector{<:Pair};
            hint::AbstractString = "y confirms · any other key cancels") =
    ConfirmView(Confirm(title, notes, [first(a) for a in answers]; hint),
                Any[last(a) for a in answers])
ConfirmView(title, notes, onyes; kw...) =
    ConfirmView(title, notes, ["yY" => onyes]; kw...)

Base.getproperty(v::ConfirmView, f::Symbol) =
    f in fieldnames(ConfirmView) ? getfield(v, f) : getproperty(getfield(v, :c), f)

render(v::ConfirmView, w::Int, h::Int) = TermInput.render(getfield(v, :c), w, h)

function handle!(v::ConfirmView, k::Int, ctrl::Controller)
    i = TermInput.answer(getfield(v, :c), k)
    i == 0 && return :pop
    v.answers[i]() === :quit ? :quit : :pop
end

"""`^x`, which `TermInput` does not name because nothing in a text area binds it.

Every other control key a composer answers to is the widget's own vocabulary and
comes from there. This one is a key this program hangs on top of one, the way
`^r` is - except that `^r` is a readline key `TermInput` already had a number
for, and there was never a reason to give this one a name until now.
"""
const C_X = 24

# --- a multi-line composer, as a view ---------------------------------------

"""What `onsubmit` answers when the send did not happen. The composer stays
open on it, with the words still there; anything else it answers is a send."""
struct Unsent
    why::String
end

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
  * **`^x` changes what is being written, where there is a choice.** Only the
    merge composer has one - the same message written three ways - and the
    callback is handed the view, so what it swaps is the buffer, the note and
    the emptiness rule of the composer the key was pressed in. Every other
    composer leaves this `nothing`, and `^x` does nothing in one.

    It is not `tab`, which was where this started and is the wrong key by one
    rule: `tab` moves the keyboard between two things on screen, here and in the
    browser and in the worktree lenses and after `^]`, and a composer drawn
    beside the diff it is about needs it to go on meaning that. `^t` is
    readline's transpose and taken; `^x` is free in a text area and is the one
    of the free ones that reads as an exchange.
  * **The terminal `⌥e` hands over is the controller's**, and is only known
    once an event is being handled in it.
"""
mutable struct EditorView <: View
    ta::TextArea
    onsubmit::Any            # (String) -> `Unsent`, or anything else for sent;
                             # not called when cancelled
    suggest::String          # a block `^r` drops in, empty when there is none
    allow_empty::Bool        # an approval needs no words; a comment does
    cycle::Any               # (view, ±1) -> Nothing on `tab`, or `nothing`
    # Spelled out so that the default one - of `Any`s - is not generated,
    # because that is the signature the constructor below wants.
    EditorView(ta::TextArea, onsubmit, suggest::AbstractString, allow_empty::Bool,
               cycle) = new(ta, onsubmit, String(suggest), allow_empty, cycle)
end

function EditorView(title, note, onsubmit; initial::AbstractString = "",
                    allow_empty::Bool = false, suggest::AbstractString = "",
                    cycle = nothing)
    hint = string("^s submit · ", isempty(suggest) ? "" : "^r suggestion · ",
                  cycle === nothing ? "" : "^x cycles · ",
                  "⌥e/^o \$EDITOR · ^w word · ^a/^e line · esc cancel")
    EditorView(TextArea(title, note; initial = initial, hint = hint),
               onsubmit, String(suggest), allow_empty, cycle)
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

onpaste!(v::EditorView, s::AbstractString, ::Controller) =
    (TermInput.paste!(getfield(v, :ta), s); :ok)

function handle!(v::EditorView, k::Int, ctrl::Controller)
    # Which terminal to give away is not known when the view is built, and is
    # known here: a composer is only ever driven from the loop that owns one.
    ta = getfield(v, :ta)
    TermInput.handle!(ta, k; suspend = f -> suspend(f, ctrl)) === :ok && return :ok
    # What is left is every key that does not edit text, which the composer
    # hands back because none of it is a text box's to answer.
    if k == C_S                                     # submit
        if isblank(ta) && !v.allow_empty
            ta.status = "nothing to send — esc cancels"
            return :ok
        end
        # A send that failed keeps the composer, with the failure on its own
        # status row: the words are still here to send again or copy out,
        # where a popped composer took them with it and left one line on the
        # browser's status row, gone at the next key. The one thing the
        # reader has to act on is the one thing the status row is wrong for.
        r = v.onsubmit(submission(ta))
        if r isa Unsent
            ta.status = string(r.why, " \u2014 ^s tries again, esc keeps nothing")
            return :ok
        end
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
    elseif k == C_X && v.cycle !== nothing
        # What a cycle *is* belongs to the caller; this only says which way
        # round it went, and one key can only say forwards.
        v.cycle(v, 1)
    end
    :ok
end
