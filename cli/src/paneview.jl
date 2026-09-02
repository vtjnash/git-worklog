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
    pending::Bool                  # the prefix has been seen, its key has not
    beside::Any                    # the BState to read alongside, or nothing
end

"""The child's usable size inside a frame of `w` by `h`.

`pane` spends two rows on its border and four columns on border and padding,
and this view keeps one more row for its own footer.
"""
pane_box(w::Integer, h::Integer) = (max(1, w - 4), max(1, h - 3))

"""Below this there is no room to put two things side by side."""
const SPLIT_MIN = 150

"""
    split_box(w) -> (browser, terminal)

How to divide `w` between what is being read and the child. `browser` is zero
when there is no room, and the child takes the screen.

The child goes on the right. What is being read - a thread, a diff, the checks -
is what the left already holds, so it stays where the eye expects it, and the
thing that was not there before is what moves in beside it.

Half each, bounded: below the bound both columns are too narrow to use, and on
a very wide screen the child would otherwise be given far more than a terminal
needs, starving nothing but the reading.
"""
function split_box(w::Integer)
    w < SPLIT_MIN && return (0, Int(w))
    tw = clamp(w ÷ 2, 60, 100)
    (Int(w) - tw, tw)
end

"""The browser this is running under, if any: what to read beside the child.

Taken from the bottom of the stack rather than passed in, because every route
to a pane - `t`, `T`, the session list - is under the same browser, and a pane
opened from any of them wants the same thing next to it.
"""
beside_of(ctrl) = isempty(ctrl.stack) ? nothing :
                  (first(ctrl.stack) isa BState ? first(ctrl.stack) : nothing)

"""Open a view onto `name`, which must already be a running session.

Returns `nothing` when there is no multiplexer or no such session, so the
caller can put a reason in its own status line rather than showing an empty
pane that never explains itself.
"""
function pane_view(name::AbstractString, title::AbstractString, ctrl;
                   beside = beside_of(ctrl))
    c = mux_open(name; onoutput = _ -> wake!(ctrl))
    c === nothing && return nothing
    PaneView(String(name), String(title), c, String[], (0, 0), "", false, beside)
end

"""Give the child the size it is being drawn at, and read its screen back.

Kept out of `render`, which is pure and gets called for every frame. The size
comes from `displaysize` here for the same reason `handle!` reads it there.
"""
function pane_sync!(v::PaneView)
    v.client === nothing && return false
    h, w = displaysize(stdout)
    # Sized to its own column, not to the screen: beside a thread it has half.
    box = pane_box(v.beside === nothing ? w : last(split_box(w)), h)
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

"""A wake is the child's, or a fetch landing for what is drawn beside it.

Both are adopted: either can change what is on screen and neither says which.
"""
function onwake!(v::PaneView)
    a = pane_sync!(v)
    b = v.beside === nothing ? false : onwake!(v.beside)
    a || b
end

"""The child's column: exactly `h` rows of exactly `w`."""
function pane_column(v::PaneView, w::Int, h::Int)
    body = pane(v.frame, w, h - 1, v.title, true)
    note = if !isempty(v.status)
        v.status
    elseif v.client === nothing
        string(v.name, " \u00b7 q to leave \u00b7 K to kill it")
    else
        string(v.name, " \u00b7 ^]tab leaves it running \u00b7 ^]a full screen")
    end
    rows = vcat(body, [string("\e[2m", afit(note, w), "\e[0m")])
    while length(rows) < h
        push!(rows, "")
    end
    [apad(r, w) for r in rows[1:h]]
end

function render(v::PaneView, w::Int, h::Int)
    lw, tw = v.beside === nothing ? (0, w) : split_box(w)
    right = pane_column(v, tw, h)
    lw == 0 && return join(right, "\n")
    # Both sides are exactly `h` rows, so they lay against each other a row at
    # a time. The left is padded in case its renderer gave back fewer: a short
    # frame would otherwise pull the whole right column leftwards.
    # The detail pane alone, and not the whole browser shrunk. While the child
    # holds the keys the browser cannot be scrolled or moved, so a list beside
    # it is a list nothing can be done with - and it would cost the thread
    # three quarters of its rows to sit there.
    it = isempty(v.beside.items) ? nothing : v.beside.items[v.beside.sel]
    left = detail_pane(v.beside, it, lw, h, false)
    join([string(apad(get(left, i, ""), lw), right[i]) for i in 1:h], "\n")
end

"""Ctrl-] is the prefix, and the only key this view keeps.

Everything else belongs to the child, Escape and Ctrl-C included, so the way in
cannot be a key a program would want. Ctrl-] is telnet's, for the same reason,
and almost nothing binds it.

It has to be a prefix and not simply an escape. With every key forwarded, a
lone escape key leaves no way to reach anything else the view can do - killing
the session, going full screen - which were reachable only after the child had
already died. One prefix gives all of them back.

`^]tab` leaves the pane, since `tab` is already what moves between panes in the
browser. `Tab` itself is not the prefix: it is the most-pressed key in a shell,
and completion would cost two presses for the rest of time.

Written without a space - `^]a`, not `^] a` - because in a line of prose that
names several of them, a lone `a` reads as the word.
"""
const PANE_PREFIX = 0x1d

"""One key after the prefix. Returns `:pop`, `:literal` to send the prefix
through to the child, or `:ok`."""
function pane_command!(v::PaneView, b::UInt8, ctrl)
    if b == UInt8('\t') || b == UInt8('q')
        mux_close(v.client)
        :pop
    elseif b == UInt8('K')
        mux_close(v.client)
        mux_kill(v.name)
        :pop
    elseif b == UInt8('a')
        mux_attach(v.name, ctrl)
        pane_sync!(v)
        :ok
    elseif b == UInt8('r')
        pane_sync!(v)
        :ok
    elseif b == PANE_PREFIX || b == UInt8(']')
        :literal
    else
        v.status = "^]tab leave \u00b7 ^]K kill \u00b7 ^]a full screen \u00b7 ^]r reread \u00b7 ^]] literal"
        :ok
    end
end

wantsraw(v::PaneView) = v.client !== nothing

"""Bytes as typed, straight through to the child.

No key is named and no sequence is interpreted on the way, so this is the same
amount of code whether the child is a shell, `vi` or something not yet written.
The prefix is the one byte read rather than forwarded, and it is tracked across
bursts: it can arrive alone, or ahead of its key in the same read.
"""
function onraw!(v::PaneView, bytes::Vector{UInt8}, ctrl)
    v.client === nothing && return :pop
    out = UInt8[]
    flush!() = (isempty(out) || (mux_keys(v.client, out); empty!(out)))
    for b in bytes
        if v.pending
            v.pending = false
            act = begin
                # Anything typed before the prefix goes first: the child should
                # see the order it was typed in, whatever the prefix then does.
                flush!()
                pane_command!(v, b, ctrl)
            end
            act === :pop && return :pop
            act === :literal && push!(out, PANE_PREFIX)
        elseif b == PANE_PREFIX
            v.pending = true
        else
            push!(out, b)
        end
    end
    flush!()
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

"""One row of the session list.

The item comes from the session's own `@wl_item` tag rather than from anything
read out of its name. A name is a label that changes - a shell gets renamed to
whichever item was opened on it last - and half of what is in it, the short
repo, cannot be turned back into a full one without guessing.
"""
struct SessionRow
    name::String
    kind::Symbol
    command::String
    attached::Bool
    where::String            # the worktree's stem, which is what is shared
    label::String            # the item's title, or what could be recovered
end

function session_rows(items::Vector{Item})
    byref = Dict(it.ref => it for it in items)
    rows = SessionRow[]
    for r in mux_list()
        it = get(byref, r.item, nothing)
        label = it !== nothing ? string(it.ref, "  ", it.title) :
                !isempty(r.item) ? r.item : r.name
        where = isempty(r.worktree) ? "" : basename(rstrip(r.worktree, '/'))
        push!(rows, SessionRow(r.name, r.kind, r.command, r.attached, where, label))
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
    ww = 14
    lw = max(10, iw - 5 - 1 - 1 - 1 - ww - 1 - cw - 1)
    body = String[]
    for (i, r) in enumerate(v.rows)
        mark = r.kind === :agent ? string("\e[35m", rpad("agent", 5), "\e[0m") :
                                   string("\e[2m", rpad("shell", 5), "\e[0m")
        line = string(mark, " ", r.attached ? "\e[32m\u25cf\e[0m" : " ", " ",
                      apad(afit(r.label, lw), lw), " ",
                      "\e[36m", apad(afit(r.where, ww), ww), "\e[0m ",
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
