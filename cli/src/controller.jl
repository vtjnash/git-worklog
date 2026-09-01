# The view controller: the one thing that owns stdin.
#
# Input used to be read wherever a view happened to want it, which forced a
# choice between two bad options. A dedicated reader task per view outlives its
# view - still blocked in readkey, holding stdin - and steals the next keystroke
# from whatever runs next. Polling `bytesavailable` avoids that but never
# terminates on a non-TTY, spins the CPU, and adds latency to every key.
#
# Owning stdin for the whole run removes the choice. One reader task exists for
# the lifetime of the process, and keys and background wakeups arrive on the
# same channel, so the loop can block on `take!` - no polling, no sleep, and a
# fetch finishing redraws immediately rather than at the next tick.

"""
A screen. Implement:

    render(v, w, h) -> String      the whole frame, no trailing newline
    handle!(v, key, ctrl) -> Symbol   :ok | :pop | :quit | :redraw
    onwake!(v) -> Bool             adopt background results; true to redraw
"""
abstract type View end

onwake!(::View) = false

struct KeyEvent
    code::Int
end
struct WakeEvent end

mutable struct Controller
    term::Any
    events::Channel{Any}
    reader::Union{Nothing,Task}
    stack::Vector{View}
    running::Bool
end
Controller() = Controller(nothing, Channel{Any}(64), nothing, View[], false)

"Called from a background task to ask for a redraw once its work has landed."
wake!(ctrl::Controller) = ctrl.running && isopen(ctrl.events) &&
                          put!(ctrl.events, WakeEvent())

push_view!(ctrl::Controller, v::View) = push!(ctrl.stack, v)

"""
    run!(ctrl, root)

Own the terminal, then dispatch events until the stack empties.

The reader task lives as long as the controller, which lives as long as the
program - so it is never left running behind a view that has gone away. It is
blocked in `readkey` at exit; the process is ending, so it is left to die with
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
    ctrl.running = true
    ctrl.reader = @async while ctrl.running
        try
            put!(ctrl.events, KeyEvent(REPL.TerminalMenus.readkey(stdin)))
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
                act = handle!(v, ev.code, ctrl)
                act === :quit && break
                act === :pop && pop!(ctrl.stack)
                dirty = true
            end
        end
    finally
        ctrl.running = false
        REPL.Terminals.raw!(ctrl.term, false)
        print("\e[?25h\e[?1049l")
    end
    0
end
