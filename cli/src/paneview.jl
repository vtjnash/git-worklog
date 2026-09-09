# A child program, drawn inside a pane.
#
# The mechanism is `TermIFrame`, and it is a package rather than a file here
# because none of it is about this program: it sizes a multiplexer session to a
# box, reads the screen back as text, forwards what was typed and holds one
# prefix key for itself, and it does all of that without knowing whether the
# child is `vi`, a pager or an agent.
#
# What is left in this file is the part that *is* about this program, and it is
# the reason a pane exists at all: an agent worth watching is one you want to
# read the pull request against while it works. So the iframe is drawn in a
# column, the thread goes beside it, and `^]tab` moves the keyboard between
# them. Everything else here follows from that - which side is lit, which side
# a key belongs to, and what the footer says about it.

"""A multiplexer session shown in a pane, with the browser's detail beside it.

`child` is the iframe: the session, its screen, its scrollback and its keys.
Everything else is what this program puts around one.
"""
mutable struct PaneView <: View
    child::IFrame
    beside::Any                    # the BState to read alongside, or nothing
    focus::Symbol                  # :child forwards every byte to it; :read
                                   # gives the keys to the thread drawn beside
end

"""Below this there is no room to put two things side by side."""
const SPLIT_MIN = 150

"""
    split_box(w) -> (reading, child)

How to divide `w` between what is being read and the child. `reading` is zero
when there is no room, and the child takes the screen.

The child goes on the right. What is being read - a thread, a diff, the checks -
is what the left already holds, so it stays where the eye expects it, and the
thing that was not there before is what moves in beside it.

The child is never given less than half, and the reading never more than
`DETAIL_MAX`. Those two together are the whole rule: below the split minimum
neither column is usable, at the minimum it is an even half each, and every
column a wider screen adds goes to the terminal.
"""
function split_box(w::Integer)
    w < SPLIT_MIN && return (0, Int(w))
    read = min(Int(w) ÷ 2, DETAIL_MAX)
    (read, Int(w) - read)
end

"""The columns the child's own pane gets, out of a screen `w` wide."""
pane_cols(v::PaneView, w::Integer) =
    v.beside === nothing ? Int(w) : last(split_box(w))

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

The four callbacks are the whole of what the iframe knows about this program:
what to poke when the child writes, what to do when it exits, how to hand the
terminal over for `^]a`, and where an error in any of that gets written down.
"""
function pane_view(name::AbstractString, title::AbstractString, ctrl;
                   beside = beside_of(ctrl), onend = nothing)
    f = iframe(name, title;
               onwake = () -> wake!(ctrl),
               onend = onend,
               suspend = g -> suspend(g, ctrl),
               onerror = logerror!)
    f === nothing && return nothing
    PaneView(f, beside, :child)
end

"""Give the child the size it is being drawn at, and read its screen back.

Kept out of `render`, which is pure and gets called for every frame. The size
comes from `displaysize` here for the same reason `handle!` reads it there, and
the child is sized to its own column rather than to the screen: beside a thread
it has half.
"""
function pane_sync!(v::PaneView)
    h, w = displaysize(stdout)
    iframe_sync!(v.child, iframe_box(pane_cols(v, w), h)...)
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

The pane starts after whatever is drawn to its left, at the top of the screen;
the border and padding inside it are the iframe's own arithmetic.
"""
pane_origin(v::PaneView, w::Int) =
    iframe_origin((v.beside === nothing ? 0 : first(split_box(w))) + 1, 1)

"""Put the terminal's own cursor where the child's is."""
viewcursor(v::PaneView, w::Int, h::Int) =
    iframe_cursor(v.child, pane_origin(v, w), iframe_box(pane_cols(v, w), h))

"""The child's column: exactly `h` rows of exactly `w`.

The footer is the iframe's wherever it has something of its own to say - where
in the history you are looking, what the last key answered, that the child has
gone. What it cannot say is which side of the split has the keyboard, so that
is what is passed in.
"""
function pane_column(v::PaneView, w::Int, h::Int)
    note = something(iframe_note(v.child),
        v.focus === :read ?
            string(v.child.name, " · reading · tab back to it",
                   " · esc/t/T the list · every other key is the browser's") :
            string(v.child.name, " · ^]tab read beside it",
                   " · ^]q leave it running · ^]? keys"))
    iframe_rows(v.child, w, h; focused = v.focus === :child, note = note)
end

function render(v::PaneView, w::Int, h::Int)
    lw, tw = v.beside === nothing ? (0, w) : split_box(w)
    right = pane_column(v, tw, h)
    lw == 0 && return join(right, "\n")
    # The detail pane alone, not the whole browser shrunk: a list beside a child
    # that holds the keys is a list nothing can be done with, and it would cost
    # the thread three quarters of its rows to sit there.
    # `sel` is zero on the import row, which is not an item and has no thread.
    it = (isempty(v.beside.items) || v.beside.sel == 0) ? nothing :
         v.beside.items[clamp(v.beside.sel, 1, length(v.beside.items))]
    left = detail_pane(v.beside, it, lw, h, v.focus === :read)
    # Both sides are `h` rows, so they lay against each other a row at a time -
    # and the left is padded in case it gave back fewer, since a short frame
    # would pull the whole right column leftwards.
    join([string(apad(get(left, i, ""), lw), right[i]) for i in 1:h], "\n")
end

"""Is there a thread beside the child to give the keys to?

Two conditions and both are about the screen: something to read, and a column
wide enough that it was drawn. Below `SPLIT_MIN` the child has the whole
screen, and a focus nobody can see is worse than no focus at all - so there
`^]tab` keeps the meaning it always had.
"""
function readable(v::PaneView)
    v.beside === nothing && return false
    _, w = displaysize(stdout)
    first(split_box(w)) > 0
end

"""Hand one key to the browser underneath, and show what it said.

The browser's own footer is not on screen here - the pane took the columns it
was drawn in - so a message it wrote in answer would go nowhere. It is copied
into the note under the child instead, which is the row nearest the key that
was pressed.

`f` is the one key not handed over, from either side. It opens the filter pane
*and* moves the browser's focus to the list - and the list is not on screen
here, so the keys after it would be going to a pane nobody can see, with `f`
again toggling the mode back and leaving the focus where it was. A key whose
effect is on what is not drawn is not this view's to forward.

The browser leaves through a dialog rather than through a return value, so
nothing that comes back from here means "quit" any more; `:ok` either way, and
this view is popped by its own keys.
"""
function forward!(v::PaneView, k::Int, ctrl)
    v.beside === nothing && return :ok
    if k == Int('f')
        v.child.status =
            "f needs the item list, which is not on screen — q leaves the pane"
        return :ok
    end
    handle!(v.beside, k, ctrl)
    v.child.status = v.beside.status
    :ok
end

"""What the prefix is for, spelled out. `^]?` asks for it.

The iframe's own keys, with this program's two either side of them: what `^]tab`
does here, and that a key this layer has no use for is the browser's.
"""
pane_keys(v::PaneView) =
    string(readable(v) ? "^]tab read beside it (q leaves from there) · " : "",
           iframe_keys(),
           v.beside === nothing ? "" : " · anything else is the browser's")

"""The keys after the prefix that are this program's rather than the iframe's.

`^]tab` is the one this whole file exists for, and `^]?` is the help, which has
to be written here because the iframe cannot know what is drawn beside it.
`:unhandled` gives the key back - to `TermIFrame` for its own (`IFRAME_KEYS`,
which must not be shadowed), and to the browser for everything else.

That last part is the rule, not a list: `^]` means "this one is not the
child's", and the sensible place for a key this layer has no use for is the
other side of the screen - which is what makes `^]m` reach the mouse toggle,
`^]o` the comments and `^]j` a line of the thread without leaving the child,
none of them named here and none of them forgettable here either.

`^]t` and `^]T` go with them, which is how a shell reaches the agent on the same
item and back; `enter_session` refuses to stack a second view on the session
already showing, so the same-kind press says so rather than doubling the pane.
"""
function pane_command!(v::PaneView, b::UInt8, ctrl)
    if b == UInt8('\t') && readable(v)
        # The keys go to the thread; the child keeps running and keeps being
        # drawn. Aimed at the detail rather than at the item list, because the
        # list is not what is on screen here.
        v.focus = :read
        v.beside.focus = :detail
        v.child.status = ""
        :ok
    elseif b == UInt8('?')
        v.child.status = pane_keys(v)
        :ok
    elseif v.beside === nothing || b in IFRAME_KEYS
        :unhandled
    else
        # As a key code, which for one byte it is: control bytes and escape
        # arrive as the numbers the browser already binds. A multi-byte
        # character after the prefix would not survive this, and is not
        # something any of these keys is.
        forward!(v, Int(b), ctrl)
    end
end

"""The child takes bytes only while it has the focus.

On the reading side the keys are the browser's, and they arrive decoded like any
other view's - which is what lets `j` scroll a thread rather than reaching a
shell that would beep at it.
"""
wantsraw(v::PaneView) = v.child.client !== nothing && v.focus === :child

# Both are places rather than dialogs: a terminal is somewhere you work and the
# worktree list is somewhere you look, and neither is a question asked of the
# view underneath.
isdialog(::PaneView) = false
closeview!(v::PaneView) = iframe_close!(v.child)

"""Mouse reports in `bytes`, moved into the child's box - or answered here.

The geometry is the one thing this layer has to supply: where the pane starts
depends on whether a thread is drawn beside it, and how big the child's box is
depends on the same. Everything after that - which reports the child asked for,
and the wheel it did not - is `TermIFrame`'s.
"""
retarget_mouse(v::PaneView, bytes::Vector{UInt8}, w::Int, h::Int) =
    retarget_mouse(v.child, bytes, pane_origin(v, w), iframe_box(pane_cols(v, w), h))

"""Bytes as typed, straight through to the child.

The geometry is this program's to supply - where the pane starts depends on
whether a thread is drawn beside it - and everything after that is the iframe's:
the mouse report moved into the child's box, the prefix held back across bursts,
and the rest sent on unread.
"""
function onraw!(v::PaneView, bytes::Vector{UInt8}, ctrl)
    h, w = displaysize(stdout)
    iframe_input!(v.child, bytes, pane_origin(v, w), iframe_box(pane_cols(v, w), h);
                  oncommand = b -> pane_command!(v, b, ctrl))
end

"""Keys, while the thread beside the child has the focus.

The child gets *nothing* here, not even the keys that would reach it from the
other side. Which keys belong to which side has to be answerable by looking at
which side has the focus; a pane that still answered `r` by re-reading its own
screen, while the thread beside it read `r` as "mark this one read", would be
asking the reader to hold a list instead - some keys and not others, for a side
that does not have the focus.

So what is kept here is leaving, and the keys that opened this. `tab` goes back
to the child. Escape and `q` leave for the list, because **`q` leaves the view
you are in** - it does that in the worktree list, it does it here, and in the
browser, which is the view every other one is a view *from*, leaving is leaving
the program and is the one place it stops to ask. `q` used to be forwarded, so
the same key ended the whole session from one side of a split and closed a pane
from the other. `t` and `T` leave as well, because the key that put the pane on
the screen is the one that takes it off again.

Everything else, `K` and `r` included, is the browser's and does there exactly
what it does there.

`t` and `T` are the one thing here that is not settled. The child's side
forwards them instead - `^]T` in a shell reaches the agent on the same item, and
`enter_session` refuses to stack a second view on a session already showing, so
forwarding doubles nothing. They are kept here anyway, for the reason above, and
nothing on screen says the two sides differ.

Killing the session is `^]K` from the child's side, and full screen is `^]a`.
Both were reachable from here and neither should have been: they are things done
*to* the pane, and the pane is not what the keys are pointed at.
"""
function handle!(v::PaneView, k::Int, ctrl)
    if v.child.client !== nothing && v.focus === :read
        if k == 9 || k == K_STAB
            v.focus = :child
            v.child.status = ""
        elseif k == 27 || k == Int('q') || k == Int('t') || k == Int('T')
            iframe_close!(v.child)
            return :pop
        else
            # `:pop` from the browser would take *this* view off the stack,
            # which is not what a key aimed at the reading asked for. Nothing
            # comes back from there that means anything else, so `:ok` it is.
            return forward!(v, k, ctrl)
        end
        return :ok
    end
    # The child has gone and its bytes have nowhere to go, so this view answers
    # for itself. `q` and escape leave the session running - there is nothing
    # left running here - and `K` is the one that ends it, uppercase because it
    # is the one that destroys something.
    if k == Int('q') || k == 27
        iframe_close!(v.child)
        return :pop
    elseif k == Int('K')
        iframe_close!(v.child)
        mux_kill(v.child.name)
        return :pop
    elseif k == Int('a')
        mux_attach(v.child.name; suspend = v.child.suspend)
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

Three things, because the row says the rest: `kind` is which mark it lights,
`attached` is what colours it, and `name` is what `K` ends. Where it is running
and what it is running on are the row it is sitting on.
"""
struct SessionRow
    name::String
    kind::Symbol
    attached::Bool
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
    staged::Bool
    unstaged::Bool
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

"""One local branch: work that exists whether or not it has a place.

`worktree` is the checkout that has it out, empty when nothing does - which is
the whole distinction this list draws against the worktree list beside it.
"""
struct BranchRow
    repo::String
    name::String
    at::String                      # its tip's committer date
    ahead::Int
    behind::Int
    gone::Bool
    upstream::String
    worktree::String
    item::Union{Nothing,Item}
end

"""Both lists, from one survey: worktrees with their sessions, and branches.

Built together because they are two lenses on the same git output and running
it twice would be two answers to the same question, taken a moment apart.

`withdirty` decides whether the one part that walks a tree runs. The view opens
without it and fills it in behind, so a checkout the size of julia costs the
list nothing on the way up.
"""
function place_rows(items::Vector{Item}; withdirty::Bool = true)
    ix = branch_index(items)
    # Keyed by the worktree each session is running in, which is the row it is
    # about to be filed under - and by `wtkey`, since tmux was told one spelling
    # of that path and git reports another.
    live = Dict{String,Vector{SessionRow}}()
    for r in mux_list()
        k = isempty(r.worktree) ? "" : wtkey(r.worktree)
        # tmux hands a tag back as the string it was set with, and an untagged
        # session as an empty one: a shell is what a session is unless it says
        # otherwise.
        kind = Symbol(isempty(r.kind) ? "shell" : r.kind)
        push!(get!(live, k, SessionRow[]), SessionRow(r.name, kind, r.attached))
    end
    ws, bs = survey(; withdirty = withdirty)
    rows = WorktreeRow[]
    for w in ws
        k = wtkey(w.path)
        push!(rows, WorktreeRow(w.repo, w.path, basename(rstrip(w.path, '/')), w.branch,
                                w.staged, w.unstaged, w.ahead, w.behind, w.at, w.main, false,
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
        push!(rows, WorktreeRow("", k, basename(rstrip(k, '/')), "", false, false, 0, 0,
                                "", false, true, nothing, sort!(ss; by = r -> r.kind)))
    end
    brows = [BranchRow(b.repo, b.name, b.at, b.ahead, b.behind, b.gone, b.upstream,
                       b.worktree, get(ix, (b.repo, b.name), nothing)) for b in bs]
    # Newest tip first, across every repo at once: what this list is for is
    # finding work, and the most recent commit is the best guess at where it
    # was. It is also what `git branch --sort=-committerdate` shows, which is
    # what anyone reaching for this list is used to.
    sort!(brows; by = r -> (r.at, r.repo, r.name), rev = true)
    (rows, brows)
end

"The worktree half, for a caller that wants only that."
worktree_rows(items::Vector{Item}; withdirty::Bool = true) =
    first(place_rows(items; withdirty = withdirty))

"""Every worktree of every registered repo, as a view.

Held as a snapshot rather than re-read per frame: `render` is pure, and both
halves of this - listing sessions and asking git - cost processes. `r` re-reads
it, and so does anything here that changes what is running.
"""
mutable struct WorktreeView <: View
    items::Vector{Item}
    rows::Vector{WorktreeRow}
    brows::Vector{BranchRow}
    mode::Symbol                    # :worktrees | :branches
    sel::Int                        # per mode, so `tab` does not lose either
    top::Int
    bsel::Int
    btop::Int
    status::String
    pending::Union{Nothing,Task}    # the dirty pass, which is the slow half
    wake::Any
    onitem::Any                     # (Item) -> String, supplied by the browser
    onadopt::Any                    # (repo, branch, take::Bool) -> String
    source::Any                     # () -> Vector{Item}, re-read on every reload
end

"""Open the list, without having walked a single tree yet.

The rows are built twice on purpose. `git status` per worktree is the only part
of the survey that is not instant, and a list you cannot see yet is worse than
one whose last column arrives a moment late - so the first pass skips it and a
background pass fills it in.
"""
function worktree_view(items::Vector{Item}; wake = nothing, onitem = nothing,
                       onadopt = nothing, source = nothing)
    rows, brows = place_rows(items; withdirty = false)
    v = WorktreeView(items, rows, brows, :worktrees, 1, 1, 1, 1,
                     isempty(rows) ? "no worktrees — none of the registered repos is here" : "",
                     nothing, wake, onitem, onadopt, source)
    dirty_pass!(v)
    v
end

"""Re-read what is running and what git says, and walk the trees again.

The items are re-read too, not just the git side: adopting a branch *creates* an
item, and a view labelling its rows from the snapshot it opened with would go on
saying the branch has none.
"""
function worktree_reload!(v::WorktreeView)
    v.source === nothing || (v.items = v.source())
    v.rows, v.brows = place_rows(v.items; withdirty = false)
    v.sel = clamp(v.sel, 1, max(1, length(v.rows)))
    v.bsel = clamp(v.bsel, 1, max(1, length(v.brows)))
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
            Dict(p => changes(p) for p in paths)
        catch
            Dict{String,Tuple{Bool,Bool}}()
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
        Dict{String,Tuple{Bool,Bool}}()
    end
    v.pending = nothing
    isempty(d) && return false
    v.rows = [haskey(d, r.path) && d[r.path] != (r.staged, r.unstaged) ?
              WorktreeRow(r.repo, r.path, r.name, r.branch, d[r.path]..., r.ahead,
                          r.behind, r.at, r.main, r.orphan, r.item, r.sessions) : r
              for r in v.rows]
    true
end

# Column widths, shared by the rows and the header that names them - the header
# *is* the key to the marks, so the two cannot be allowed to drift apart.
const WT_RUN, WT_CHG, WT_NAME, WT_BRANCH, WT_DATE, WT_TRACK = 3, 2, 18, 22, 10, 10
const BR_NAME, BR_REPO, BR_DATE, BR_TRACK = 30, 16, 10, 10

"The three session slots of one row: a shell, an agent and a note, each present or not."
function session_marks(r::WorktreeRow)
    out = ""
    for (kind, ch) in ((:shell, 't'), (:agent, 'T'), (:note, 'v'))
        i = findfirst(x -> x.kind === kind, r.sessions)
        out *= i === nothing ? " " :
               r.sessions[i].attached ? string("\e[32m", ch, "\e[0m") :
                                        string("\e[2m", ch, "\e[0m")
    end
    out
end

"`+2/-1` against upstream, or nothing to say."
function track_mark(ahead::Int, behind::Int)
    ahead == 0 && behind == 0 && return ""
    string(ahead > 0 ? string("+", ahead) : "",
           behind > 0 ? string(ahead > 0 ? "/" : "", "-", behind) : "")
end
track_mark(r::WorktreeRow) = track_mark(r.ahead, r.behind)
track_mark(r::BranchRow) = track_mark(r.ahead, r.behind)

"""Scroll so the cursor is on screen, and report the window to draw.

Both lists share it: the geometry of a list of rows in a box does not depend on
what the rows are.
"""
function listwindow(n::Int, sel::Int, top::Int, inner::Int)
    sel = clamp(sel, 1, max(1, n))
    top = clamp(top, 1, max(1, n))
    sel < top && (top = sel)
    sel >= top + inner && (top = sel - inner + 1)
    (sel, top, top:min(n, top + inner - 1))
end

"""What is changed here: staged, unstaged, or both.

Two marks and not one. A checkout with something staged and something else not
is in the middle of a commit, which is a different thing to have walked away
from than a checkout that was merely edited - and `+*` says so at a glance.
"""
function change_marks(r::WorktreeRow)
    string(r.staged ? "\e[32m+\e[0m" : " ",
           r.unstaged ? "\e[33m*\e[0m" : " ")
end

"""The width the tip date costs on a worktree row, which is nothing when the
row is too narrow to spare it.

The date is collected for every branch and is the cheapest way to tell a
checkout that is current from one abandoned in March, so it is drawn wherever
there is room. Where there is not, the pull request is what the row is for: at
eighty columns the fixed columns already leave the title sixteen, and taking
eleven more would leave it a ref and an ellipsis. So this column comes and goes
with the width, the way the browser's second pane does.
"""
wt_date(iw::Int) = iw >= 90 ? WT_DATE + 1 : 0

wt_label(iw::Int) = max(12, iw - WT_RUN - 1 - WT_CHG - 1 - WT_NAME - 1 -
                             WT_BRANCH - 1 - wt_date(iw) - WT_TRACK - 1)

"One worktree row, drawn."
function wt_line(r::WorktreeRow, iw::Int)
    label = r.item !== nothing ? string(r.item.ref, "  ", r.item.title) :
            r.orphan ? "\e[31mworktree is gone\e[0m" :
            isempty(r.repo) ? "" : string("\e[2m", r.repo, "\e[0m")
    string(session_marks(r), " ", change_marks(r), " ",
           apad(afit(r.name, WT_NAME), WT_NAME), " ",
           "\e[36m", apad(amid(isempty(r.branch) ? "(detached)" : r.branch, WT_BRANCH),
                          WT_BRANCH), "\e[0m ",
           wt_date(iw) == 0 ? "" :
               string("\e[2m", apad(first(r.at, WT_DATE), WT_DATE), "\e[0m "),
           "\e[2m", apad(afit(track_mark(r), WT_TRACK), WT_TRACK), "\e[0m ",
           apad(afit(label, wt_label(iw)), wt_label(iw)))
end

"""One branch row, drawn.

The leading mark is whether it has a place: `\u25cf` for a branch that is
checked out somewhere, nothing for one that is only a ref. That column is the
difference between the two lists, so it leads.
"""
br_label(iw::Int) = max(12, iw - 1 - 1 - BR_NAME - 1 - BR_REPO - 1 -
                             BR_DATE - 1 - BR_TRACK - 1)

function br_line(r::BranchRow, iw::Int)
    label = r.item !== nothing ? string(r.item.ref, "  ", r.item.title) :
            r.gone ? "\e[2mupstream is gone\e[0m" : ""
    string(isempty(r.worktree) ? " " : "\e[32m\u25cf\e[0m", " ",
           "\e[36m", apad(amid(r.name, BR_NAME), BR_NAME), "\e[0m ",
           "\e[2m", apad(afit(last(split(r.repo, '/')), BR_REPO), BR_REPO), "\e[0m ",
           "\e[2m", apad(first(r.at, BR_DATE), BR_DATE), "\e[0m ",
           "\e[2m", apad(afit(track_mark(r), BR_TRACK), BR_TRACK), "\e[0m ",
           apad(afit(label, br_label(iw)), br_label(iw)))
end

"""The row that names the columns, which is also the key to the marks.

It does not scroll with the list: a key you have to scroll back to is not a
key. `t`/`T` and `+`/`*` are one character each and unguessable on their own,
so the header carries their names and the colour carries the rest - green for a
session you are attached to and for what is staged, yellow for what is not.
"""
function list_header(branches::Bool, iw::Int)
    line = branches ?
        string(apad("at", 2), " ", apad("branch", BR_NAME), " ",
               apad("repo", BR_REPO), " ", apad("tip", BR_DATE), " ",
               apad("\u00b1upstream", BR_TRACK), " ", apad("pull request", br_label(iw))) :
        string(apad("tTv", WT_RUN), " ", apad("+*", WT_CHG), " ",
               apad("worktree", WT_NAME), " ", apad("branch", WT_BRANCH), " ",
               wt_date(iw) == 0 ? "" : string(apad("tip", WT_DATE), " "),
               apad("\u00b1upstream", WT_TRACK), " ",
               apad("pull request", wt_label(iw)))
    string("\e[2m", afit(line, iw), "\e[0m")
end

"""What the one-character columns mean, spelled out.

The marks have to be one character wide - three session slots in three columns
is what lets a row show every repo, branch and pull request beside them - so the
header can only name the column, and `tTv` is not something anyone guesses. This
is the other half of it, and it stays on screen: a key you have to already know
to ask for is no better than no key at all.

Per mode, because the two lists share no marks: `\u25cf` is the whole difference
the branch list draws, and none of the session or change marks appear in it.
"""
list_legend(branches::Bool) = branches ?
    "\u25cf checked out somewhere \u00b7 \u00b1upstream is +ahead/-behind" :
    "t shell \u00b7 T agent \u00b7 v note (green: attached) \u00b7 + staged \u00b7 * unstaged"

function render(v::WorktreeView, w::Int, h::Int)
    # Fixed columns, so the eye can run down the branch and the marks rather
    # than hunting for where each one starts.
    iw = w - 4
    # The pane's border, the legend and status rows under it, and the header
    # that names the columns.
    inner = max(1, h - 5)
    branches = v.mode === :branches
    n = branches ? length(v.brows) : length(v.rows)
    sel, top, win = listwindow(n, branches ? v.bsel : v.sel,
                               branches ? v.btop : v.top, inner)
    branches ? (v.bsel = sel; v.btop = top) : (v.sel = sel; v.top = top)
    body = [list_header(branches, iw)]
    for i in win
        line = branches ? br_line(v.brows[i], iw) : wt_line(v.rows[i], iw)
        push!(body, i == sel ? hlrow(apad(line, iw), SELBG) : line)
    end
    # `n`, not `body`: the header is always in there, so an empty list is one
    # that has no rows rather than one that drew nothing.
    n == 0 && push!(body, branches ?
        "\e[2mno branches — none of the registered repos is here\e[0m" :
        "\e[2mno worktrees — register a repo with e, t or T on an item\e[0m")
    keys = branches ? "↵ its worktree, or make one · i item · tab worktrees · r refresh · q back" :
                      "↵/t shell · T agent · i item · K kill · tab branches · r refresh · q back"
    rows = vcat(bordered(body, w, h - 2, branches ? "branches" : "worktrees", true),
                [string("\e[2m", afit(list_legend(branches), w), "\e[0m"),
                 string("\e[2m", afit(isempty(v.status) ? keys : v.status, w), "\e[0m")])
    while length(rows) < h
        push!(rows, "")
    end
    join([apad(x, w) for x in rows[1:h]], "\n")
end

"Open a session of `kind` on the row, which may have no item at all."
function row_session(v::WorktreeView, r::WorktreeRow, ctrl, kind::Symbol)
    r.orphan && return "that worktree is gone; K removes what is left running"
    # The same command `T` runs on an item: through a shell, so an alias or a
    # function resolves, and refused nowhere - a name that is not a file on
    # `PATH` is not a name that is not there.
    cmd = kind === :agent ? agent_cmd() : get(ENV, "SHELL", "/bin/sh")
    title = string(kind === :agent ? "agent  " : "",
                   r.item === nothing ? r.name : r.item.ref,
                   isempty(r.branch) ? "" : string("  ", r.branch))
    # The view this was opened from is a place too, so opening a pane replaces
    # it: what says one opened is what is on top now, never how tall the stack
    # is.
    was = isempty(ctrl.stack) ? nothing : last(ctrl.stack)
    out = enter_session(r.path, r.branch,
                        r.item === nothing ? "" : r.item.ref,
                        r.item === nothing ? "" : string(r.item.number),
                        title, ctrl, kind, (_, _) -> cmd)
    (!isempty(ctrl.stack) && last(ctrl.stack) !== was) || return out
    # The same rule the item keys follow: starting work on something is what
    # the clock records.
    r.item === nothing || touch!(r.item.url)
    # Working in something is a deliberate enough act to claim it - but only
    # your own work. `gh pr checkout` leaves other people's branches in your
    # checkout, and opening a terminal in one must not quietly take it.
    if r.item === nothing && !isempty(r.branch) && v.onadopt !== nothing &&
       get_field(localurl(r.repo, r.branch), "adopted") === nothing &&
       mine_on_branch(r.path, r.branch, git_ids(r.path, login()))
        took = v.onadopt(r.repo, r.branch, true)
        isempty(took) || (out = string(out, " \u00b7 ", took))
    end
    out
end

isdialog(::WorktreeView) = false

"The row the cursor is on, in whichever list is showing, or `nothing`."
function currow(v::WorktreeView)
    if v.mode === :branches
        isempty(v.brows) ? nothing : v.brows[clamp(v.bsel, 1, length(v.brows))]
    else
        isempty(v.rows) ? nothing : v.rows[clamp(v.sel, 1, length(v.rows))]
    end
end

"""Claim the row's branch as yours, or give it back.

A toggle, and always allowed: `a` is asking for it, which is the deliberate act
the guard on the automatic route exists to require. A branch that already has a
pull request is refused - it is an item already, and a second one keyed on the
branch would be the same work listed twice.
"""
function adopt_row(v::WorktreeView, r)
    v.onadopt === nothing && return "nowhere to record that from here"
    r isa WorktreeRow && r.orphan && return "that worktree is gone"
    branch = r isa BranchRow ? r.name : r.branch
    isempty(branch) && return "a detached head has no branch to adopt"
    repo = r.repo
    isempty(repo) && return "no repo for this row"
    if r.item !== nothing && r.item.is_pr
        return string(r.item.ref, " is a pull request already")
    end
    # Asked of `state.toml` and not of the row: the file is the record of what
    # has been adopted, and the row is a picture of it from a moment ago.
    v.onadopt(repo, branch, get_field(localurl(repo, branch), "adopted") === nothing)
end

"""Ask where to put a worktree for a branch that has none.

A prompt and not a silent `git worktree add`: where a checkout goes is the
user's business - disks, build trees and naming habits all differ - so the
suggestion arrives already typed, to be accepted, edited or thrown away. `note`
carries why the last attempt failed, which is what makes correcting a path
cheaper than typing it again.
"""
function ask_worktree(v::WorktreeView, r::BranchRow, ctrl; seed = "", note = "")
    p = repo_path(r.repo)
    p === nothing && return string("no local checkout registered for ", r.repo)
    dest = isempty(seed) ? worktree_dest(p, r.name) : String(seed)
    push_view!(ctrl, PromptView(
        string("New worktree for ", r.name),
        isempty(note) ? string("where to check it out · ", r.repo, " is at ", p) : note,
        dest, length(dest) + 1,
        b -> (v.status = make_worktree!(v, r, ctrl, b))))
    ""
end

"""Make the place, and go to it.

Landing on the new row rather than reporting a path is the point: a branch with
nowhere to work was the one thing this list could see and not act on, and the
row it becomes is where every session key already works.

Failure re-opens the prompt with what was typed still in it and git's own
complaint above it, because every way this fails is a path that wants
correcting - the directory exists, its parent does not, the branch was checked
out somewhere else a moment ago.
"""
function make_worktree!(v::WorktreeView, r::BranchRow, ctrl, at::AbstractString)
    p = repo_path(r.repo)
    p === nothing && return string("no local checkout registered for ", r.repo)
    dest = try
        add_worktree!(p, r.name, at)
    catch e
        e isa GitError || rethrow()
        ask_worktree(v, r, ctrl; seed = at, note = oneline(first(sprint(showerror, e), 200)))
        return ""
    end
    worktree_reload!(v)
    i = findfirst(x -> wtkey(x.path) == wtkey(dest), v.rows)
    i === nothing && return string("made ", dest, ", which is not in the list yet · r re-reads")
    v.mode = :worktrees
    v.sel = i
    string("made ", dest, " · t opens a shell here")
end

"""Go to the item on this row, which means leaving: the list underneath is
where an item is shown."""
function goto_item(v::WorktreeView, it::Union{Nothing,Item})
    if it === nothing
        v.status = "no pull request on this branch"
    elseif v.onitem === nothing
        v.status = "nowhere to show it from here"
    else
        r = v.onitem(it)
        (r isa String && !isempty(r)) ? (v.status = r) : return :pop
    end
    :ok
end

function handle!(v::WorktreeView, k::Int, ctrl)
    k = unshift(k)
    branches = v.mode === :branches
    n = branches ? length(v.brows) : length(v.rows)
    move!(d) = branches ? (v.bsel = clamp(v.bsel + d, 1, max(1, n))) :
                          (v.sel = clamp(v.sel + d, 1, max(1, n)))
    r = currow(v)
    if k == Int('q') || k == 27
        return :pop
    elseif k == 9 || k == K_STAB
        # The same `tab` the browser uses to change pane: two lenses on one
        # key, and each keeps its own cursor so switching back returns to where
        # you were rather than to the top.
        v.mode = branches ? :worktrees : :branches
        v.status = ""
    elseif k in (Int('j'), K_DOWN); move!(1)
    elseif k in (Int('k'), K_UP);   move!(-1)
    elseif k in (Int('g'), K_HOME); move!(-n)
    elseif k in (Int('G'), K_END);  move!(n)
    elseif k == Int('r')
        worktree_reload!(v)
        v.status = ""
    elseif r === nothing
        # Nothing to act on; every key below wants a row.
    elseif k == 13 || k == 10 || k == Int('t') || k == Int('T')
        kind = k == Int('T') ? :agent : :shell
        if r isa BranchRow
            # A branch is not a place, but one can be made for it. Enter goes to
            # the worktree that has it out, and offers to create one where there
            # is none - the same destination reached two ways. `t` and `T` open
            # nothing here, since there is nowhere yet to run: they go to that
            # same row, which is where they do work.
            i = isempty(r.worktree) ? nothing :
                findfirst(x -> wtkey(x.path) == wtkey(r.worktree), v.rows)
            if i !== nothing
                v.mode = :worktrees; v.sel = i; v.status = ""
            elseif isempty(r.worktree)
                v.status = ask_worktree(v, r, ctrl)
            else
                # Checked out somewhere the survey did not report: another repo
                # entirely, or one that has been unregistered since.
                v.status = string(r.name, " is checked out at ", r.worktree)
            end
        else
            v.status = row_session(v, r, ctrl, kind)
            worktree_reload!(v)
        end
    elseif k == Int('i')
        return goto_item(v, r.item)
    elseif k == Int('a')
        v.status = adopt_row(v, r)
        # The row's item is what changed, so the lists have to be rebuilt for
        # it to show - or to stop showing.
        worktree_reload!(v)
    elseif k == Int('K')
        if r isa BranchRow
            v.status = "nothing runs on a branch — tab to its worktree"
        elseif isempty(r.sessions)
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
