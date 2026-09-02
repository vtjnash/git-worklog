# A child program, drawn inside a pane.
#
# The view holds no idea of what its child is. It sizes a multiplexer session
# to the box it is drawn in, asks for the screen whenever the child writes
# anything, and prints what comes back. Nothing here parses an escape sequence
# or names a key, which is the whole point: `vi`, a pager and an agent are the
# same amount of work, and a program this does not know about is no work at all.
#
# Input is forwarded, not interpreted. The controller hands this view the bytes
# exactly as they arrived and they go straight to `send-keys -H`, so an arrow, a
# paste, a control character and a mouse report are all the same thing: bytes
# the child understands and this does not. One key is held back to get out
# again, because every other key now belongs to the child.

"""A multiplexer session shown in a pane.

`frame` is the last screen read back, one string per row with the escapes left
in. It is only ever replaced whole: a partial frame is not a thing tmux can
hand out, since `capture-pane` reads a grid that is always in a consistent
state, so there is no tearing to guard against and no need to wait for a redraw
to finish before drawing it.
"""
mutable struct PaneView <: View
    name::String
    title::String
    client::Union{MuxClient,Nothing}
    frame::Vector{String}
    sized::Tuple{Int,Int}          # what the child was last told it had
    status::String
end

"""The child's usable size inside a frame of `w` by `h`.

`pane` spends two rows on its border and four columns on border and padding,
and this view keeps one more row for its own footer.
"""
pane_box(w::Integer, h::Integer) = (max(1, w - 4), max(1, h - 3))

"""Open a view onto `name`, which must already be a running session.

Returns `nothing` when there is no multiplexer or no such session, so the
caller can put a reason in its own status line rather than showing an empty
pane that never explains itself.
"""
function pane_view(name::AbstractString, title::AbstractString, ctrl)
    c = mux_open(name; onoutput = _ -> wake!(ctrl))
    c === nothing && return nothing
    PaneView(String(name), String(title), c, String[], (0, 0), "")
end

"""Give the child the size it is being drawn at, and read its screen back.

Kept out of `render`, which is pure and gets called for every frame. The size
comes from `displaysize` here for the same reason `handle!` reads it there.
"""
function pane_sync!(v::PaneView)
    v.client === nothing && return false
    h, w = displaysize(stdout)
    box = pane_box(w, h)
    if box != v.sized
        mux_resize(v.client, box[1], box[2]) && (v.sized = box)
    end
    lines = mux_capture(v.client)
    if v.client.dead
        v.status = "session ended"
        v.client = nothing
        return true
    end
    # Every row is closed off, or an unterminated colour would run out of the
    # content and into the pane's own border and padding.
    v.frame = [string(l, "\e[0m") for l in lines]
    true
end

onwake!(v::PaneView) = pane_sync!(v)

function render(v::PaneView, w::Int, h::Int)
    body = pane(v.frame, w, h - 1, v.title, true)
    note = if !isempty(v.status)
        v.status
    elseif v.client === nothing
        string(v.name, " \u00b7 q to leave \u00b7 K to kill it")
    else
        string(v.name, " \u00b7 ^] to leave it running \u00b7 a full screen")
    end
    rows = vcat(body, [string("\e[2m", afit(note, w), "\e[0m")])
    # Exactly `h` rows of exactly `w` columns, like every other view: the frame
    # is printed as-is and a short row would leave the last one behind on it.
    while length(rows) < h
        push!(rows, "")
    end
    join([apad(r, w) for r in rows[1:h]], "\n")
end

"""The one key this view keeps: Ctrl-] leaves the pane.

Everything else belongs to the child, Escape and Ctrl-C included, so the way
out cannot be a key any program would want. Ctrl-] is telnet's, for the same
reason, and almost nothing binds it.

Leaving is not ending. The session runs on and the same program is still there
next time, which is the whole reason for putting the child in a session rather
than running it as a child process of this one.
"""
const PANE_ESCAPE = 0x1d

wantsraw(v::PaneView) = v.client !== nothing

"""Bytes as typed, straight through to the child.

No key is named and no sequence is interpreted on the way, so this is the same
amount of code whether the child is a shell, `vi` or something that has not
been written yet.
"""
function onraw!(v::PaneView, bytes::Vector{UInt8}, ctrl)
    v.client === nothing && return :pop
    # Only alone: a lone Ctrl-] is someone leaving, the same byte inside a
    # longer burst is a paste or a sequence and is the child's.
    if length(bytes) == 1 && bytes[1] == PANE_ESCAPE
        mux_close(v.client)
        return :pop
    end
    mux_keys(v.client, bytes)
    :ok
end

"""Keys, for when the child has gone and its bytes have nowhere to go.

`q` leaves the session running and `K` is the one that ends it, uppercase
because it is the one that destroys something.
"""
function handle!(v::PaneView, k::Int, ctrl)
    if k == Int('q') || k == 27
        v.client === nothing || mux_close(v.client)
        return :pop
    elseif k == Int('K')
        v.client === nothing || mux_close(v.client)
        mux_kill(v.name)
        return :pop
    elseif k == Int('a')
        mux_attach(v.name, ctrl)
        pane_sync!(v)
    elseif k == Int('r')
        pane_sync!(v)
    end
    :ok
end

# --- every session at once --------------------------------------------------
#
# A session outlives the view of it, which is the point, and the cost of that is
# that they accumulate somewhere you cannot see. This is the somewhere: what is
# running, on which item, and how to get back into it or be rid of it.

"""One row of the session list, and the item it belongs to if that is known.

The item is matched by generating names and comparing them, not by parsing the
session name into a repo: `mux_session` keeps only the short half of the repo,
so `julia` cannot be turned back into `JuliaLang/julia` without guessing.
"""
struct SessionRow
    name::String
    kind::Symbol
    command::String
    attached::Bool
    label::String            # the item's title, or what could be recovered
end

function session_rows(items::Vector{Item})
    byname = Dict{String,Item}()
    for it in items, kind in (:shell, :agent)
        byname[mux_session(it, kind)] = it
    end
    rows = SessionRow[]
    for r in mux_list()
        p = mux_parse(r.name)
        it = get(byname, r.name, nothing)
        label = if it !== nothing
            string(it.repo, "#", it.number, "  ", it.title)
        elseif p !== nothing
            string(p.short, "#", p.number)
        else
            r.name
        end
        push!(rows, SessionRow(r.name, p === nothing ? :shell : p.kind,
                               r.command, r.attached, label))
    end
    rows
end

"""The list of running sessions, as a view.

Held as a snapshot rather than re-read per frame: `render` is pure, and asking
tmux costs a process. `r` re-reads it, and so does anything here that changes
what is running.
"""
mutable struct SessionView <: View
    items::Vector{Item}
    rows::Vector{SessionRow}
    sel::Int
    status::String
end

function session_view(items::Vector{Item})
    rows = session_rows(items)
    SessionView(items, rows, 1, isempty(rows) ? "nothing running" : "")
end

session_reload!(v::SessionView) =
    (v.rows = session_rows(v.items); v.sel = clamp(v.sel, 1, max(1, length(v.rows))); true)

function render(v::SessionView, w::Int, h::Int)
    # Fixed columns, so the eye can run down the kind and the command rather
    # than hunting for where each one starts.
    iw = w - 4
    cw = 10
    lw = max(10, iw - 5 - 1 - 1 - 1 - cw - 1)
    body = String[]
    for (i, r) in enumerate(v.rows)
        mark = r.kind === :agent ? string("\e[35m", rpad("agent", 5), "\e[0m") :
                                   string("\e[2m", rpad("shell", 5), "\e[0m")
        line = string(mark, " ", r.attached ? "\e[32m\u25cf\e[0m" : " ", " ",
                      apad(afit(r.label, lw), lw), " ",
                      "\e[2m", afit(r.command, cw), "\e[0m")
        # `hlrow` rather than a background in front: it puts the colour back
        # after every reset in the row, so the highlight covers the whole line
        # without flattening what is coloured in it.
        push!(body, i == v.sel ? hlrow(apad(line, iw), SELBG) : line)
    end
    isempty(body) && push!(body, "\e[2mnothing running — t or T on an item starts one\e[0m")
    rows = vcat(pane(body, w, h - 1, "sessions", true),
                [string("\e[2m", afit(isempty(v.status) ?
                    "↵ open · K kill · r refresh · q back" : v.status, w), "\e[0m")])
    while length(rows) < h
        push!(rows, "")
    end
    join([apad(x, w) for x in rows[1:h]], "\n")
end

function handle!(v::SessionView, k::Int, ctrl)
    n = length(v.rows)
    if k == Int('q') || k == 27
        return :pop
    elseif k in (Int('j'), K_DOWN)
        n > 0 && (v.sel = min(v.sel + 1, n))
    elseif k in (Int('k'), K_UP)
        n > 0 && (v.sel = max(v.sel - 1, 1))
    elseif k == Int('r')
        session_reload!(v)
    elseif n > 0 && (k == 13 || k == 10)
        r = v.rows[v.sel]
        pv = pane_view(r.name, r.label, ctrl)
        if pv === nothing
            v.status = "could not attach to " * r.name
            session_reload!(v)
        else
            pane_sync!(pv)
            push!(ctrl.stack, pv)
        end
    elseif n > 0 && k == Int('K')
        mux_kill(v.rows[v.sel].name)
        session_reload!(v)
    end
    :ok
end
