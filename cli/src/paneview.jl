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
    cursor::Tuple{Int,Int,Bool}    # the child's cursor: x, y (0-based), showing
    wantsmouse::Bool               # the child asked for mouse reporting
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
    PaneView(String(name), String(title), c, String[], (0, 0), "", false, beside,
             (0, 0, false), false)
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
    cx, cy, showing, mouse = mux_pane_state(v.client)
    v.cursor, v.wantsmouse = (cx, cy, showing), mouse
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

"""Screen position of the child's top-left cell, 1-based `(col, row)`.

`pane` spends its first row on the border and its first two columns on border
and padding, and the whole pane starts after whatever is drawn to its left.
"""
function pane_origin(v::PaneView, w::Int)
    lw = v.beside === nothing ? 0 : first(split_box(w))
    (lw + 3, 2)
end

"""Put the terminal's own cursor where the child's is.

Nothing when the child is hiding it, when the pane is not showing one, or when
it would land outside the box - a cursor drawn over the border would be worse
than none.
"""
function viewcursor(v::PaneView, w::Int, h::Int)
    cx, cy, showing = v.cursor
    (showing && v.client !== nothing) || return nothing
    cols, rows = pane_box(v.beside === nothing ? w : last(split_box(w)), h)
    (0 <= cx < cols && 0 <= cy < rows) || return nothing
    ox, oy = pane_origin(v, w)
    (oy + cy, ox + cx)
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

"""Rewrite the mouse reports in `bytes` for the child, or drop them.

This is the one thing that cannot be forwarded untouched, and both reasons are
worth stating.

A report arrives in *screen* coordinates, but the child owns a box inside that
screen, offset by whatever is drawn to its left and by its own border. Sent on
unchanged, a click lands wherever the arithmetic happens to put it - which is
somewhere else, and usually plausibly so.

And a report means nothing to a program that never asked for one. `send-keys`
puts these bytes into the pane's pty as *input*, so tmux never sees them as
mouse events and its own `mouse` setting has no bearing: an application that
has not turned mouse reporting on receives the escape sequence and prints it,
which is exactly the control characters that show up on the screen. So the
child is asked, through `mouse_any_flag`, and told nothing it did not ask for.

Only the SGR form (`\e[<b;x;yM`) is understood, which is the only form the
browser asks its own terminal for.
"""
function retarget_mouse(v::PaneView, bytes::Vector{UInt8}, w::Int, h::Int)
    occursin("\e[<", String(copy(bytes))) || return bytes
    ox, oy = pane_origin(v, w)
    cols, rows = pane_box(v.beside === nothing ? w : last(split_box(w)), h)
    out, i, n = UInt8[], 1, length(bytes)
    while i <= n
        # ESC [ < ... (M|m)
        if bytes[i] == 0x1b && i + 2 <= n && bytes[i+1] == UInt8('[') && bytes[i+2] == UInt8('<')
            j = i + 3
            while j <= n && bytes[j] != UInt8('M') && bytes[j] != UInt8('m')
                j += 1
            end
            if j <= n
                f = split(String(bytes[i+3:j-1]), ';')
                nums = length(f) == 3 ? tryparse.(Int, f) : nothing
                if nums !== nothing && !any(isnothing, nums)
                    b, sx, sy = nums
                    cx, cy = sx - ox, sy - oy      # 0-based within the child
                    if v.wantsmouse && 0 <= cx < cols && 0 <= cy < rows
                        append!(out, codeunits(string("\e[<", b, ";", cx + 1, ";",
                                                      cy + 1, Char(bytes[j]))))
                    end
                    i = j + 1
                    continue
                end
            end
        end
        push!(out, bytes[i]); i += 1
    end
    out
end

"""Bytes as typed, straight through to the child.

No key is named and no sequence is interpreted on the way, so this is the same
amount of code whether the child is a shell, `vi` or something not yet written.
The prefix is the one byte read rather than forwarded, and it is tracked across
bursts: it can arrive alone, or ahead of its key in the same read.
"""
function onraw!(v::PaneView, bytes::Vector{UInt8}, ctrl)
    v.client === nothing && return :pop
    h, w = displaysize(stdout)
    bytes = retarget_mouse(v, bytes, w, h)
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

# --- where the work is ------------------------------------------------------
#
# A session outlives the view of it, which is the point, and the cost of that is
# that they accumulate somewhere you cannot see. This used to be a list of them.
#
# But a session is *keyed by its worktree*, so every one already belongs to
# exactly one checkout: they were never a list of their own, they were a column
# of a list nobody had written yet. So this is that list - every worktree of
# every registered repo, what is checked out in it, whether it is dirty, the
# pull request its branch belongs to if there is one, and which sessions are
# live in it. `"` still opens it, and everything the session list could do is
# still done here, on the row the session is part of.

"""One session, as the worktree row it belongs to sees it.

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

"""One place work can happen, and what is happening in it.

`orphan` is a session whose worktree has since been deleted. It is a row rather
than a hidden entry, because a session nothing can reach is exactly the thing
you would want told about - it is still holding a process, and `K` is still how
to be rid of it.
"""
struct WorktreeRow
    repo::String
    path::String
    name::String                    # the worktree's stem, as it is referred to
    branch::String                  # "" on a detached head
    dirty::Bool
    ahead::Int
    behind::Int
    at::String                      # its branch's tip date
    main::Bool
    orphan::Bool
    item::Union{Nothing,Item}       # the pull request its branch belongs to
    sessions::Vector{SessionRow}
end

"""Compare two worktree paths the way the filesystem does.

tmux was told the path `item_checkout` chose and git reports its own; those are
the same directory reached two ways, and a symlink anywhere above them makes the
strings differ. Matching on the string alone turned every session in a linked
worktree into an orphan.
"""
wtkey(p) = try
    realpath(String(p))
catch
    String(rstrip(String(p), '/'))
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

"""Every worktree, with its sessions folded in.

`withdirty` decides whether the one part that walks a tree runs. The view opens
without it and fills it in behind, so a checkout the size of julia costs the
list nothing on the way up.
"""
function worktree_rows(items::Vector{Item}; withdirty::Bool = true)
    ix = branch_index(items)
    byref = Dict(it.ref => it for it in items)
    live = Dict{String,Vector{SessionRow}}()
    for r in mux_list()
        it = get(byref, r.item, nothing)
        label = it !== nothing ? string(it.ref, "  ", it.title) :
                !isempty(r.item) ? r.item : r.name
        k = isempty(r.worktree) ? "" : wtkey(r.worktree)
        push!(get!(live, k, SessionRow[]),
              SessionRow(r.name, r.kind, r.command, r.attached,
                         isempty(r.worktree) ? "" : basename(rstrip(r.worktree, '/')), label))
    end
    ws, _ = survey(; withdirty = withdirty)
    rows = WorktreeRow[]
    for w in ws
        k = wtkey(w.path)
        push!(rows, WorktreeRow(w.repo, w.path, basename(rstrip(w.path, '/')), w.branch,
                                w.dirty, w.ahead, w.behind, w.at, w.main, false,
                                get(ix, (w.repo, w.branch), nothing),
                                sort!(pop!(live, k, SessionRow[]); by = r -> r.kind)))
    end
    # By repo and then by name, which is an order that does not move under you.
    # The primary checkout leads its repo: it is the one every other worktree of
    # it was made from, and the one a fallback lands in.
    sort!(rows; by = r -> (r.repo, !r.main, r.name))
    # Whatever is left over is running somewhere that is no longer there.
    for (k, ss) in sort(collect(live); by = first)
        isempty(k) && continue
        push!(rows, WorktreeRow("", k, basename(rstrip(k, '/')), "", false, 0, 0, "",
                                false, true, nothing, sort!(ss; by = r -> r.kind)))
    end
    rows
end

"""Every worktree of every registered repo, as a view.

Held as a snapshot rather than re-read per frame: `render` is pure, and both
halves of this - listing sessions and asking git - cost processes. `r` re-reads
it, and so does anything here that changes what is running.
"""
mutable struct WorktreeView <: View
    items::Vector{Item}
    rows::Vector{WorktreeRow}
    sel::Int
    top::Int
    status::String
    pending::Union{Nothing,Task}    # the dirty pass, which is the slow half
    wake::Any
    onitem::Any                     # (Item) -> String, supplied by the browser
end

"""Open the list, without having walked a single tree yet.

The rows are built twice on purpose. `git status` per worktree is the only part
of the survey that is not instant, and a list you cannot see yet is worse than
one whose last column arrives a moment late - so the first pass skips it and a
background pass fills it in.
"""
function worktree_view(items::Vector{Item}; wake = nothing, onitem = nothing)
    rows = worktree_rows(items; withdirty = false)
    v = WorktreeView(items, rows, 1, 1,
                     isempty(rows) ? "no worktrees — none of the registered repos is here" : "",
                     nothing, wake, onitem)
    dirty_pass!(v)
    v
end

"Re-read what is running and what git says, and walk the trees again."
function worktree_reload!(v::WorktreeView)
    v.rows = worktree_rows(v.items; withdirty = false)
    v.sel = clamp(v.sel, 1, max(1, length(v.rows)))
    dirty_pass!(v)
    true
end

"""Work out which worktrees are dirty, off the key loop.

Only the dirty bits are taken from the result. Anything else could have changed
under it - a session started, a branch switched - and re-adopting a whole row
from a snapshot taken before the last keystroke would undo what that keystroke
did.
"""
function dirty_pass!(v::WorktreeView)
    v.pending === nothing || return
    paths = [r.path for r in v.rows if !r.orphan]
    isempty(paths) && return
    v.pending = @async begin
        r = try
            Dict(p => dirty(p) for p in paths)
        catch
            Dict{String,Bool}()
        finally
            v.wake === nothing || v.wake()
        end
        r
    end
end

function onwake!(v::WorktreeView)
    v.pending === nothing && return false
    istaskdone(v.pending) || return false
    d = try
        fetch(v.pending)
    catch
        Dict{String,Bool}()
    end
    v.pending = nothing
    isempty(d) && return false
    v.rows = [haskey(d, r.path) && d[r.path] != r.dirty ?
              WorktreeRow(r.repo, r.path, r.name, r.branch, d[r.path], r.ahead, r.behind,
                          r.at, r.main, r.orphan, r.item, r.sessions) : r
              for r in v.rows]
    true
end

"The two session slots of one row: a shell and an agent, each present or not."
function session_marks(r::WorktreeRow)
    out = ""
    for (kind, ch) in ((:shell, 's'), (:agent, 'a'))
        i = findfirst(x -> x.kind === kind, r.sessions)
        out *= i === nothing ? " " :
               r.sessions[i].attached ? string("\e[32m", ch, "\e[0m") :
                                        string("\e[2m", ch, "\e[0m")
    end
    out
end

"`+2/-1` against upstream, or nothing to say."
function track_mark(r::WorktreeRow)
    r.ahead == 0 && r.behind == 0 && return ""
    string(r.ahead > 0 ? string("+", r.ahead) : "",
           r.behind > 0 ? string(r.ahead > 0 ? "/" : "", "-", r.behind) : "")
end

function render(v::WorktreeView, w::Int, h::Int)
    # Fixed columns, so the eye can run down the branch and the marks rather
    # than hunting for where each one starts.
    iw = w - 4
    nw = 18
    bw = 22
    lw = max(12, iw - 2 - 1 - 1 - 1 - nw - 1 - bw - 1 - 5 - 1)
    inner = h - 3          # the pane's border, plus the footer row
    v.sel = clamp(v.sel, 1, max(1, length(v.rows)))
    v.top = clamp(v.top, 1, max(1, length(v.rows)))
    v.sel < v.top && (v.top = v.sel)
    v.sel >= v.top + inner && (v.top = v.sel - inner + 1)
    body = String[]
    for i in v.top:min(length(v.rows), v.top + inner - 1)
        r = v.rows[i]
        label = r.item !== nothing ? string(r.item.ref, "  ", r.item.title) :
                r.orphan ? "\e[31mworktree is gone\e[0m" :
                isempty(r.repo) ? "" : string("\e[2m", r.repo, "\e[0m")
        line = string(session_marks(r), " ",
                      r.dirty ? "\e[33m*\e[0m" : " ", " ",
                      apad(afit(r.name, nw), nw), " ",
                      "\e[36m", apad(afit(isempty(r.branch) ? "(detached)" : r.branch, bw), bw),
                      "\e[0m ",
                      "\e[2m", apad(afit(track_mark(r), 5), 5), "\e[0m ",
                      apad(afit(label, lw), lw))
        push!(body, i == v.sel ? hlrow(apad(line, iw), SELBG) : line)
    end
    isempty(body) &&
        push!(body, "\e[2mno worktrees — register a repo with e, t or T on an item\e[0m")
    rows = vcat(pane(body, w, h - 1, "worktrees", true),
                [string("\e[2m", afit(isempty(v.status) ?
                    "↵/t shell · T agent · i item · K kill · r refresh · q back" :
                    v.status, w), "\e[0m")])
    while length(rows) < h
        push!(rows, "")
    end
    join([apad(x, w) for x in rows[1:h]], "\n")
end

"Open a session of `kind` on the row, which may have no item at all."
function row_session(v::WorktreeView, r::WorktreeRow, ctrl, kind::Symbol)
    r.orphan && return "that worktree is gone; K removes what is left running"
    kind === :agent && Sys.which("claude") === nothing && return "`claude` is not on PATH"
    cmd = kind === :agent ? "claude" : get(ENV, "SHELL", "/bin/sh")
    title = string(kind === :agent ? "agent  " : "",
                   r.item === nothing ? r.name : r.item.ref,
                   isempty(r.branch) ? "" : string("  ", r.branch))
    n = length(ctrl.stack)
    out = enter_session(r.path, r.branch,
                        r.item === nothing ? "" : r.item.ref,
                        r.item === nothing ? "" : string(r.item.number),
                        title, ctrl, kind, (_, _) -> cmd)
    # The same rule the item keys follow: starting work on something is what
    # the clock records, and a worktree with a pull request is that pull
    # request. One with none has nowhere to record it yet - that is what the
    # synthetic items in the plan are for.
    length(ctrl.stack) > n && r.item !== nothing && touch!(r.item.url)
    out
end

function handle!(v::WorktreeView, k::Int, ctrl)
    n = length(v.rows)
    if k == Int('q') || k == 27
        return :pop
    elseif k in (Int('j'), K_DOWN)
        n > 0 && (v.sel = min(v.sel + 1, n))
    elseif k in (Int('k'), K_UP)
        n > 0 && (v.sel = max(v.sel - 1, 1))
    elseif k in (Int('g'), K_HOME)
        v.sel = 1
    elseif k in (Int('G'), K_END)
        v.sel = max(1, n)
    elseif k == Int('r')
        worktree_reload!(v)
        v.status = ""
    elseif n > 0 && (k == 13 || k == 10 || k == Int('t'))
        v.status = row_session(v, v.rows[v.sel], ctrl, :shell)
        worktree_reload!(v)
    elseif n > 0 && k == Int('T')
        v.status = row_session(v, v.rows[v.sel], ctrl, :agent)
        worktree_reload!(v)
    elseif n > 0 && k == Int('i')
        # The item is one key away, as promised - and going to it means leaving,
        # because it is the list underneath that shows it.
        it = v.rows[v.sel].item
        if it === nothing
            v.status = "no pull request on this branch"
        elseif v.onitem === nothing
            v.status = "nowhere to show it from here"
        else
            r = v.onitem(it)
            r isa String && !isempty(r) ? (v.status = r) : return :pop
        end
    elseif n > 0 && k == Int('K')
        r = v.rows[v.sel]
        if isempty(r.sessions)
            v.status = "nothing running here"
        else
            for s in r.sessions
                mux_kill(s.name)
            end
            v.status = string("ended ", length(r.sessions), " in ", r.name)
            worktree_reload!(v)
        end
    end
    :ok
end
