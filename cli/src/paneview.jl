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

"""The screen changed shape: the child is told its new box now, not at the
next wake or key. The reading side beside it keeps nothing keyed on a width
that the next frame does not check."""
onresize!(v::PaneView) = (pane_sync!(v); nothing)

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
            # `^]K` is on it and `^]tab` is not, which is a trade and not a
            # tidy-up: ending the session is the one thing here that cannot be
            # undone and it was reachable only through `^]?`, while `tab` is
            # what everything else in this program uses to change which side
            # has the keyboard - a reader who has `^][` will try it anyway, and
            # `^]?` is where it stays written down.
            string(v.child.name, " · ^][ read beside it",
                   " · ^]q leave it running · ^]K kill · ^]? keys"))
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

# --- a dialog drawn beside what it is about ---------------------------------
#
# A composer used to take the whole screen, and the thing it was about went
# behind it. That is exactly backwards for the three that matter: a comment is
# written *at* a diff, a review message *at* the commits it lands, and a note
# *at* the item it is a note on - and the answer was to write a sentence, press
# escape, read the hunk again and start over.
#
# The split already existed for `t` and `T`, and none of it is about a child
# process: `split_box` divides the columns and `detail_pane` draws the reading
# side. So a composer goes where the iframe goes, and `tab` moves the keyboard
# between them the same way `^]tab` does over there.

"""A dialog drawn beside what it is about, rather than over it.

`inner` is the dialog - a composer, in every case there is so far - and it is
answered exactly as it would be full screen: `^s` submits, escape gives up, and
what comes back from it is what comes back from here, so the caller cannot tell
the difference. What changes is only where it is drawn and that `tab` reaches
past it.

The reading side is the *detail* pane and not the whole browser, for the reason
the hosted pane has: a list beside something holding the keys is a list nothing
can be done with, and it would cost the thread three quarters of its rows.
"""
mutable struct SideView <: View
    inner::View
    beside::BState
    focus::Symbol                  # :inner has the keys, or :read
end

"""Put a dialog beside what it is about, where the screen has room for both.

Below the split minimum it is pushed as it always was. That is not a fallback so
much as the same rule the pane follows: two columns nobody can read is worse
than one, and a composer is the half that has to stay usable.
"""
function push_beside!(ctrl, st::BState, v::View)
    _, w = displaysize(stdout)
    first(split_box(w)) == 0 ? push_view!(ctrl, v) :
                               push_view!(ctrl, SideView(v, st, :inner))
end

# A question that hands the keys back, which is what its inner view is. The
# pane above is a *place*; this is not one, and `push_place!` must not clear it.
isdialog(::SideView) = true
# The item the dialog is about, which is the one beside it.
viewtitle(v::SideView) = viewtitle(v.beside)
closeview!(v::SideView) = closeview!(v.inner)
wantsraw(::SideView) = false
holds(v::SideView, inner::View) = v.inner === inner

"""The item the reading side is showing, or `nothing` on the import row."""
side_item(st::BState) = (isempty(st.items) || st.sel == 0) ? nothing :
                        st.items[clamp(st.sel, 1, length(st.items))]

"""Both columns, laid against each other a row at a time.

The dialog is asked to draw itself into its own width and answers with a whole
frame of that width - `centred` pads every row - so the right-hand column needs
no arithmetic here beyond splitting it back into rows. The left is padded in
case it gave back fewer, since a short frame would pull the right column
leftwards.
"""
function render(v::SideView, w::Int, h::Int)
    lw, rw = split_box(w)
    lw == 0 && return render(v.inner, w, h)
    # Which side is lit, said the same way on both. The detail pane has always
    # taken it as an argument; the composer carries it as a field, and drawing
    # its block cursor while the keys are on the other side of the screen would
    # be two cursors saying neither side has them.
    v.inner isa EditorView && (v.inner.focused = v.focus === :inner)
    right = split(render(v.inner, rw, h), "\n")
    left = detail_pane(v.beside, side_item(v.beside), lw, h, v.focus === :read)
    join([string(apad(get(left, i, ""), lw), get(right, i, ""))
          for i in 1:h], "\n")
end

"""The mouse over the reading side, beside a composer.

The browser gets it against the geometry the detail was drawn at - the left
column, whole height - and not against `layout`, which is where the detail
would have been alone: measured that way a click landed on some other row,
and a mark or a url under the pointer was not the one clicked.

The keys stay where they are. A click on the thread moves the cursor, folds
a comment, copies a url, drags a selection - all of it visible - and none of
it is a reason to take the caret out of a half-written comment; there is no
click that would give it back, only `tab`.
"""
function onmouse!(v::SideView, ev::MouseEvent, ctrl::Controller, at::Float64 = time())
    h, w = displaysize(stdout)
    lw, _ = split_box(w)
    (lw == 0 || ev.x > lw) && return :ok
    onmouse!(v.beside, ev, ctrl, at; L = beside_layout(lw, h))
end

"""A fetch landing for what is drawn beside the dialog is worth a redraw.

The composer itself has nothing to wake for - it holds text and nothing else -
so this is the reading side's alone.
"""
onwake!(v::SideView) = onwake!(v.beside)

"""
    handle!(v::SideView, k, ctrl)

`tab` moves the keyboard across, and everything else belongs to whichever side
has it.

**Leaving the reading side is four keys, not one.** `tab` and shift-tab go back
because that is what put you there; `esc` and `q` go back because they are what
the fingers produce when a screen is not the one being worked in - and neither
can be allowed to mean what it means in the browser, where `q` ends the program.
Quitting out from under a half-written comment is the one thing this view exists
to make impossible.

`f` is refused for the same reason the hosted pane refuses it: it opens the
filter pane and moves the browser's focus to the list, and the list is not
drawn here.
"""
function handle!(v::SideView, k::Int, ctrl)
    if v.focus === :read
        if k in (9, K_STAB, 27, Int('q'))
            v.focus = :inner
            return :ok
        elseif k == Int('f')
            v.beside.status = "f needs the item list, which is not on screen"
        else
            handle!(v.beside, k, ctrl)
        end
        # The browser's own footer is not on screen - the dialog took the
        # columns it would have been drawn in - so what it said goes under the
        # dialog instead, which is the row nearest the key that was pressed.
        sidestatus!(v)
        return :ok
    end
    if k in (9, K_STAB)
        v.focus = :read
        # The detail and not the list, which is not drawn here.
        v.beside.focus = :detail
        sidestatus!(v)
        return :ok
    end
    handle!(v.inner, k, ctrl)
end

"""Show the reading side's answer under the dialog, where there is a row for it.

The composer is the only kind wrapped so far and the only kind with a row to put
this in, so it is named rather than asked. `hasproperty` would answer `false`
for it anyway: the field is the `TextArea`'s and reaches the view through
`getproperty`, which is exactly the sort of thing that check cannot see.
"""
function sidestatus!(v::SideView)
    v.inner isa EditorView || return
    v.inner.status = !isempty(v.beside.status) ? v.beside.status :
        v.focus === :read ?
            "reading · tab back to the message · esc and q come back too" :
            "tab reads the diff beside this"
    nothing
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
    string(readable(v) ? "^]tab or ^][ read beside it (q leaves from there) · " : "",
           iframe_keys(),
           v.beside === nothing ? "" : " · anything else is the browser's")

"""The keys after the prefix that are this program's rather than the iframe's.

`^]tab` is the one this whole file exists for, and `^][` is the same thing under
the hand: `]` and `[` are one key apart, so the roll is right pinky twice with
the left one never leaving control, where `^]tab` sends it back up to tab. It is
the most-pressed key here and it was the slowest to type.

Ctrl has to come *off* for the `[`. Held down it is `^]` then `^[`, and `^[` is
escape, which the iframe reads as leaving the pane - a different thing, and one
that is no worse to have arrived at by accident: the session keeps running.

`^]?` is the help, which has to be written here because the iframe cannot know
what is drawn beside it.
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
    if (b == UInt8('\t') || b == UInt8('[')) && readable(v)
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
# The item the session was opened on, read off the reading side when there is
# one and off the session's own tag otherwise; a session on no item is the pane's name.
viewtitle(v::PaneView) = v.beside !== nothing ? viewtitle(v.beside) :
                         string("wl ", v.child.name)
closeview!(v::PaneView) = iframe_close!(v.child)

"""Mouse reports in `bytes`, moved into the child's box - or answered here.

The geometry is the one thing this layer has to supply: where the pane starts
depends on whether a thread is drawn beside it, and how big the child's box is
depends on the same. Everything after that - which reports the child asked for,
and the wheel it did not - is `TermIFrame`'s.
"""
retarget_mouse(v::PaneView, bytes::Vector{UInt8}, w::Int, h::Int) =
    retarget_mouse(v.child, bytes, pane_origin(v, w), iframe_box(pane_cols(v, w), h))

"""The mouse over the thread beside the child, while the thread has the keys.

Decoded, like the keys, only on the reading side: with the child focused the
input is raw and `retarget_mouse` is what sees a report, moving it into the
child's box and dropping one outside it. Here the browser gets it, against the
left column it was drawn in rather than `layout`'s idea of where the detail
would have been alone - see the `SideView` method.
"""
function onmouse!(v::PaneView, ev::MouseEvent, ctrl::Controller, at::Float64 = time())
    v.beside === nothing && return :ok
    h, w = displaysize(stdout)
    lw = first(split_box(w))
    (lw == 0 || ev.x > lw) && return :ok
    onmouse!(v.beside, ev, ctrl, at; L = beside_layout(lw, h))
end

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
which side has the focus; a pane that answered `r` by re-reading its own
screen, while the thread beside it took `e` as "done", would be
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

Everything else, `K` and `e` included, is the browser's and does there exactly
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
    bell::Bool                      # rang since anyone looked: see `AGENT_SETTINGS`
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
    item::Union{Nothing,Item}       # the pull request its branch belongs to,
                                    # or the item its sessions were opened on
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
    byurl = Dict(it.url => it for it in items)
    # Keyed by the worktree each session is running in, which is the row it is
    # about to be filed under - and by `wtkey`, since tmux was told one spelling
    # of that path and git reports another. `on` is what the sessions there
    # were opened on, agents first: the item a copy is about when its branch
    # names none.
    live = Dict{String,Vector{SessionRow}}()
    on = Dict{String,Vector{Tuple{String,String}}}()
    for r in mux_list()
        k = isempty(r.worktree) ? "" : wtkey(r.worktree)
        # tmux hands a tag back as the string it was set with, and an untagged
        # session as an empty one: a shell is what a session is unless it says
        # otherwise.
        kind = Symbol(isempty(r.kind) ? "shell" : r.kind)
        push!(get!(live, k, SessionRow[]), SessionRow(r.name, kind, r.attached, r.bell))
        isempty(r.url) || push!(get!(on, k, Tuple{String,String}[]), (String(kind), r.url))
    end
    ws, bs = survey(; withdirty = withdirty)
    rows = WorktreeRow[]
    # Which item a checkout carries is `branch_carrier`'s to say - the same
    # answer `t` reads when it asks whether a copy has been reused, refusal
    # included - so the list and the key never disagree about a row. Failing
    # the branch, the sessions: an agent opened on an issue is working in
    # this copy on that issue, whatever it named the branch it made, and a
    # shell opened on a pull request whose branch gh named otherwise is on
    # that pull request - which is what `h` goes to, and what says the branch
    # is not a stranger's to adopt. The branch's word first when both speak.
    trs = Dict{String,Tracking}()
    tracking(w) = get!(() -> Tracking(w.path), trs, w.repo)
    for w in ws
        k = wtkey(w.path)
        it = branch_carrier(ix, w.repo, w, tracking(w))
        if it === nothing
            for (_, u) in sort(get(on, k, Tuple{String,String}[]))
                it = get(byurl, u, nothing)
                it === nothing || break
            end
        end
        push!(rows, WorktreeRow(w.repo, w.path, basename(rstrip(w.path, '/')), w.branch,
                                w.staged, w.unstaged, w.ahead, w.behind, w.at, w.main, false,
                                it, sort!(pop!(live, k, SessionRow[]); by = r -> r.kind)))
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
    # A branch row's item the same way as a worktree's, less the sessions: a
    # branch has no place for one to run in. `main` is false for the
    # refusal's sake - a branch is not the main checkout, whatever has it out.
    brows = [BranchRow(b.repo, b.name, b.at, b.ahead, b.behind, b.gone, b.upstream,
                       b.worktree,
                       branch_carrier(ix, b.repo, (path = "", branch = b.name, main = false),
                                      get!(trs, b.repo) do
                                          p = repo_path(b.repo)
                                          p === nothing ? Tracking() : Tracking(p)
                                      end))
             for b in bs]
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
    mode::Symbol                    # :worktrees | :active | :branches
    sel::Int                        # per mode, so `tab` does not lose any
    top::Int
    bsel::Int
    btop::Int
    asel::Int
    atop::Int
    status::String
    pending::Union{Nothing,Task}    # the dirty pass, which is the slow half
    wake::Any
    onitem::Any                     # (Item) -> String, supplied by the browser
    onadopt::Any                    # (repo, branch, take::Bool) -> String
    source::Any                     # () -> Vector{Item}, re-read on every reload
    lastclick::Tuple{Float64,Int,Int}
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
    v = WorktreeView(items, rows, brows, :worktrees, 1, 1, 1, 1, 1, 1,
                     isempty(rows) ? "no worktrees — none of the registered repos is here" : "",
                     nothing, wake, onitem, onadopt, source, (0.0, 0, 0))
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
    v.sel = clamp(v.sel, 1, length(v.rows) + 1)       # the row that adds one
    v.bsel = clamp(v.bsel, 1, max(1, length(v.brows)))
    v.asel = clamp(v.asel, 1, max(1, count(isactive, v.rows)))
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

"""The three session slots of one row: a shell, an agent and a note, each
present or not.

Green is one you are in; yellow is one that rang while you were not - the agent
stopped, or is asking - and is waiting on you until you look, since tmux clears
the bell on the attach. Grey is there and quiet.

Over anything with `kind`, `attached` and `bell` - the row's `SessionRow`s, or
the sessions of one worktree straight off `mux_list` - so the checkout picker
draws the same three letters this list does, and a reader who has seen either
knows the other.
"""
function session_marks(sessions)
    out = ""
    for (kind, ch) in ((:shell, 't'), (:agent, 'T'), (:note, 'v'))
        i = findfirst(x -> x.kind === kind, sessions)
        out *= i === nothing ? " " :
               sessions[i].attached ? string(THEME.settled, ch, THEME.reset) :
               sessions[i].bell ? string(THEME.waiting, ch, THEME.reset) :
                                  string(THEME.dim, ch, THEME.reset)
    end
    out
end
session_marks(r::WorktreeRow) = session_marks(r.sessions)

"`+2/-1` against upstream, or nothing to say."
function track_mark(ahead::Int, behind::Int)
    ahead == 0 && behind == 0 && return ""
    string(ahead > 0 ? string("+", ahead) : "",
           behind > 0 ? string(ahead > 0 ? "/" : "", "-", behind) : "")
end
track_mark(r::WorktreeRow) = track_mark(r.ahead, r.behind)
track_mark(r::BranchRow) = track_mark(r.ahead, r.behind)

"""Is something running here: a shell or an agent. A note is not work going on,
so it does not put a worktree in the `active` list on its own."""
isactive(r::WorktreeRow) = any(s -> s.kind === :shell || s.kind === :agent, r.sessions)

"""The rows the cursor walks in the mode showing: every worktree, the ones with
something running in them, or the branches. `active` is the first filtered by
`isactive`, so it is the same rows drawn the same way, and a key does on one
there what it does on it in the whole list."""
shown(v) = v.mode === :branches ? v.brows :
           v.mode === :active ? filter(isactive, v.rows) : v.rows

"""How many rows the cursor can be on: `shown`, and in the whole worktree list
one more - the row at the bottom that makes a new one, the way the import row
at the top of the browser's list makes a new item."""
nshown(v) = length(shown(v)) + (v.mode === :worktrees)

"Is the cursor on the row that makes a new worktree?"
onnew(v) = v.mode === :worktrees && v.sel == length(v.rows) + 1

"The cursor and the scroll of the mode showing - each mode keeps its own."
cursor(v) = v.mode === :branches ? (v.bsel, v.btop) :
            v.mode === :active ? (v.asel, v.atop) : (v.sel, v.top)
function setcursor!(v, sel::Int, top::Int = cursor(v)[2])
    v.mode === :branches ? (v.bsel = sel; v.btop = top) :
    v.mode === :active ? (v.asel = sel; v.atop = top) : (v.sel = sel; v.top = top)
    sel
end

"The order `tab` goes through the modes; shift-tab goes back through it."
const WT_MODES = (:worktrees, :active, :branches)

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
    string(r.staged ? string(THEME.settled, "+", THEME.reset) : " ",
           r.unstaged ? string(THEME.waiting, "*", THEME.reset) : " ")
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
            r.orphan ? string(THEME.blocked, "worktree is gone", THEME.reset) :
            isempty(r.repo) ? "" : string(THEME.dim, r.repo, THEME.reset)
    string(session_marks(r), " ", change_marks(r), " ",
           apad(afit(r.name, WT_NAME), WT_NAME), " ",
           THEME.accent, apad(amid(isempty(r.branch) ? "(detached)" : r.branch, WT_BRANCH),
                              WT_BRANCH), THEME.reset, " ",
           wt_date(iw) == 0 ? "" :
               string(THEME.dim, apad(first(r.at, WT_DATE), WT_DATE), THEME.reset, " "),
           THEME.dim, apad(afit(track_mark(r), WT_TRACK), WT_TRACK), THEME.reset, " ",
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
            r.gone ? string(THEME.dim, "upstream is gone", THEME.reset) : ""
    string(isempty(r.worktree) ? " " :
           string(THEME.settled, "\u25cf", THEME.reset), " ",
           THEME.accent, apad(amid(r.name, BR_NAME), BR_NAME), THEME.reset, " ",
           THEME.dim, apad(afit(last(split(r.repo, '/')), BR_REPO), BR_REPO),
           THEME.reset, " ",
           THEME.dim, apad(first(r.at, BR_DATE), BR_DATE), THEME.reset, " ",
           THEME.dim, apad(afit(track_mark(r), BR_TRACK), BR_TRACK), THEME.reset, " ",
           apad(afit(label, br_label(iw)), br_label(iw)))
end

"""The row that names the columns, which is also the key to the marks.

It does not scroll with the list: a key you have to scroll back to is not a
key. `t`/`T` and `+`/`*` are one character each and unguessable on their own,
so the header carries their names and the colour carries the rest - green for a
session you are attached to and for what is staged, yellow for what is not, and
for a session that rang while you were away.
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
    string(THEME.dim, afit(line, iw), THEME.reset)
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
    "t shell \u00b7 T agent \u00b7 v note (green: in, yellow: rang) \u00b7 + staged \u00b7 * unstaged"

function render(v::WorktreeView, w::Int, h::Int)
    # Fixed columns, so the eye can run down the branch and the marks rather
    # than hunting for where each one starts.
    iw = w - 4
    # The pane's border, the legend and status rows under it, and the header
    # that names the columns.
    inner = max(1, h - 5)
    branches = v.mode === :branches
    rs = shown(v)
    n = nshown(v)
    sel, top, win = listwindow(n, cursor(v)..., inner)
    setcursor!(v, sel, top)
    body = [list_header(branches, iw)]
    for i in win
        line = i > length(rs) ?
            string(THEME.dim, "+ new worktree …", THEME.reset) :
            branches ? br_line(rs[i], iw) : wt_line(rs[i], iw)
        push!(body, i == sel ? hlrow(apad(line, iw), THEME.select_bg) : line)
    end
    # `rs`, not `body`: the header is always in there, and so in the whole
    # list is the row that adds one, so an empty list is one that has no rows
    # rather than one that drew nothing.
    isempty(rs) && push!(body, string(THEME.dim,
        branches ? "no branches — none of the registered repos is here" :
        v.mode === :active ? "nothing running — t or T on a worktree starts something" :
                             "no worktrees — register a repo with e, t or T on an item",
        THEME.reset))
    keys = branches ? "↵ its worktree, or make one · h item · tab worktrees · r refresh · q back" :
           onnew(v) ? "↵ make a worktree, for a branch that is here or a new one · tab active · q back" :
                      string("↵/t shell · T agent · h item · K kill · tab ",
                             v.mode === :active ? "branches" : "active", " · r refresh · q back")
    rows = vcat(bordered(body, w, h - 2, String(v.mode), true),
                [string(THEME.dim, afit(list_legend(branches), w), THEME.reset),
                 string(THEME.dim, afit(isempty(v.status) ? keys : v.status, w),
                        THEME.reset)])
    while length(rows) < h
        push!(rows, "")
    end
    join([apad(x, w) for x in rows[1:h]], "\n")
end

"""A click moves the cursor to the row and a double click is `↵`; the wheel
moves the cursor. The worktree list's half of what `mouse.jl` says of the
pickers, here because the view is."""
function onmouse!(v::WorktreeView, ev::MouseEvent, ctrl::Controller, at::Float64 = time())
    h, w = displaysize(stdout)
    n = nshown(v)
    if ev.kind === :wheelup || ev.kind === :wheeldown
        d = ev.kind === :wheelup ? -3 : 3
        setcursor!(v, clamp(cursor(v)[1] + d, 1, max(1, n)))
        return :ok
    end
    ev.kind === :press || return :ok
    dbl = doubled(v.lastclick, ev, at)
    v.lastclick = (at, ev.x, ev.y)
    # The same window `render` drew: the border, then the column header, then
    # the rows from `top`.
    _, top, win = listwindow(n, cursor(v)..., max(1, h - 5))
    i = ev.y - 3 + top
    i in win || return :ok
    setcursor!(v, i)
    dbl ? handle!(v, 13, ctrl) : :ok
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
                        r.item === nothing ? "" : r.item.url,
                        title, ctrl, kind, (_, _) -> cmd)
    (!isempty(ctrl.stack) && last(ctrl.stack) !== was) || return out
    # The same rule the item keys follow: starting work on something is what
    # the clock records.
    r.item === nothing || touch!(r.item.url)
    # Working in something is a deliberate enough act to claim it - but only
    # your own work. `gh pr checkout` leaves other people's branches in your
    # checkout, and opening a terminal in one must not quietly take it. Nor
    # is an agent's work yours by its commits: it writes them in your name,
    # so a branch it made passes `mine_on_branch` and was adopted on the
    # next look at the pane (`issue-61397`, 2026-09-22). With an agent in the
    # copy, or being opened, the branch is the agent's item's - on the row
    # when the agent was opened on one - or nobody's until `a` says.
    if r.item === nothing && !isempty(r.branch) && v.onadopt !== nothing &&
       kind !== :agent && !any(s -> s.kind === :agent, r.sessions) &&
       get_field(localurl(r.repo, r.branch), "adopted") === nothing &&
       mine_on_branch(r.path, r.branch, git_ids(r.path, login()))
        took = v.onadopt(r.repo, r.branch, true)
        isempty(took) || (out = string(out, " \u00b7 ", took))
    end
    out
end

isdialog(::WorktreeView) = false

"""The row the cursor is on, in whichever list is showing, or `nothing` - which
is also what the row that makes a new worktree is."""
function currow(v::WorktreeView)
    onnew(v) && return nothing
    rs = shown(v)
    isempty(rs) ? nothing : rs[clamp(cursor(v)[1], 1, length(rs))]
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

`start` is where a branch that is not here yet is made from, and the note says
what will be made, since that is decided before the path is asked for.
"""
function ask_worktree(v::WorktreeView, repo::AbstractString, branch::AbstractString, ctrl;
                      seed = "", note = "", start::AbstractString = "")
    p = repo_path(repo)
    p === nothing && return string("no local checkout registered for ", repo)
    from, base = branch_source(p, repo, branch, start)
    dest = isempty(seed) ? worktree_dest(p, branch) : String(seed)
    # What will be checked out there, since that was decided before this was
    # asked and is the thing most worth catching before git does it.
    what = !isempty(from) ? string("It will track ", from, ", the branch already pushed there.") :
           !isempty(base) ? string("It will be a new branch, started from ", base, ".") :
                            "The branch is already here, and is checked out as it is."
    push_view!(ctrl, PromptView(
        string("New worktree for ", branch),
        isempty(note) ? string("Where to put the new checkout: \u21b5 to use this path, ",
                               "or edit it first. ", what, " ", repo,
                               "'s main checkout is at ", p, ".") : note,
        b -> (v.status = make_worktree!(v, repo, branch, ctrl, b; start)); initial = dest))
    ""
end

"""Where a worktree's branch comes from, as `add_worktree!`'s `from` and `base`.

A branch that is here is checked out as it is, and neither is set. One that is
only on the project's remote is made tracking it - the branch somebody else
pushed, not a new one of the same name. Anything else is a new branch of your
own: from `start` when it was given, or from the default branch.
"""
function branch_source(p::AbstractString, repo::AbstractString, branch::AbstractString,
                       start::AbstractString = "")
    has_rev(p, string("refs/heads/", branch)) && return ("", "")
    isempty(start) || return ("", String(start))
    theirs = string("refs/remotes/", remote_for(p, repo), "/", branch)
    has_rev(p, theirs) && return (theirs, "")
    ("", something(default_base(p), "HEAD"))
end

"""The row at the bottom of the worktree list: which repo, which branch, and
for a branch that is not here yet, optionally where it starts. Asked in one
line - `JuliaLang/julia jn/fix` - seeded with the repo of the last row, which
is the one the cursor came down from; the path is asked next, the same as for a
branch in the branch list.
"""
function ask_new_worktree(v::WorktreeView, ctrl; seed = "", problem = "")
    pins = [r.name for r in pinned_repos()]
    if isempty(seed)
        repos = [r.repo for r in v.rows if !isempty(r.repo)]
        repo = !isempty(repos) ? last(repos) : isempty(pins) ? "" : first(pins)
        seed = isempty(repo) ? "" : string(repo, " ")
    end
    push_view!(ctrl, PromptView("New worktree",
        new_worktree_note(first(vcat(split(seed), [""])), pins, problem),
        b -> (v.status = new_worktree!(v, ctrl, b)); initial = seed))
    ""
end

"""What the first prompt says: the shape of the answer, by example, and what
each kind of branch name does - since which of the three happens is decided by
what is in the repository, and is not something to find out from git's error.
A problem with the last answer goes first, and the explanation stays under it,
because the problem is usually that the explanation was not read."""
function new_worktree_note(repo::AbstractString, pins::Vector{String},
                           problem::AbstractString = "")
    # The example in the repository typed or seeded, when that is one of them:
    # after a bad answer, its first word may be the branch.
    r = repo in pins ? String(repo) : isempty(pins) ? "owner/repo" : first(pins)
    known = isempty(pins) ? "No repository is registered yet: e, t or T on an item registers its own." :
            string("Registered: ", join(first(pins, 6), ", "), length(pins) > 6 ? ", \u2026" : "", ".")
    string(isempty(problem) ? "" : string(problem, " \u2014 "),
           "Type a repository and a branch, like `", r, " jn/fix`. A branch that is here ",
           "is checked out as it is; one only on the remote is checked out tracking it; ",
           "any other name is a new branch from the default branch, or from a third word, ",
           "like `", r, " jn/fix v1.12.0`. Where to put it is asked next. ", known)
end

"The answer to `ask_new_worktree`: asked again when it is not one, or on to the path."
function new_worktree!(v::WorktreeView, ctrl, b::AbstractString)
    ws = split(strip(b))
    if !(length(ws) in (2, 3))
        ask_new_worktree(v, ctrl; seed = b, problem = string(
            isempty(ws) ? "Nothing was typed" :
            length(ws) == 1 ? "That is one word, and a repository and a branch are two" :
                              "That is more than three words", "."))
        return ""
    end
    repo, branch = String(ws[1]), String(ws[2])
    if repo_path(repo) === nothing
        ask_new_worktree(v, ctrl; seed = b, problem = string(
            repo, " has no checkout registered here, so there is nowhere to add a worktree to."))
        return ""
    end
    ask_worktree(v, repo, branch, ctrl; start = length(ws) == 3 ? String(ws[3]) : "")
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
function make_worktree!(v::WorktreeView, repo::AbstractString, branch::AbstractString,
                        ctrl, at::AbstractString; start::AbstractString = "")
    p = repo_path(repo)
    p === nothing && return string("no local checkout registered for ", repo)
    dest = try
        from, base = branch_source(p, repo, branch, start)
        add_worktree!(p, branch, at; from, base)
    catch e
        e isa GitError || rethrow()
        ask_worktree(v, repo, branch, ctrl; seed = at, start,
                     note = oneline(first(sprint(showerror, e), 200)))
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
where an item is shown - in whatever reading it was in, not the thread. `h`,
the browser's thread key, so the lowercase letter means one thing everywhere;
it was `i` until `i` became `I`, import."""
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
    n = nshown(v)
    move!(d) = setcursor!(v, clamp(cursor(v)[1] + d, 1, max(1, n)))
    r = currow(v)
    if k == Int('q') || k == 27
        return :pop
    elseif k == 9 || k == K_STAB
        # The same `tab` the browser uses to change pane: three lenses on one
        # key, and each keeps its own cursor so switching back returns to where
        # you were rather than to the top.
        i = findfirst(==(v.mode), WT_MODES)
        v.mode = WT_MODES[mod1(i + (k == 9 ? 1 : -1), length(WT_MODES))]
        v.status = ""
    elseif k in (Int('j'), K_DOWN); move!(1)
    elseif k in (Int('k'), K_UP);   move!(-1)
    elseif k in (Int('g'), K_HOME); move!(-n)
    elseif k in (Int('G'), K_END);  move!(n)
    elseif k == Int('r')
        worktree_reload!(v)
        v.status = ""
    elseif onnew(v) && k in (13, 10, Int('t'))
        v.status = ask_new_worktree(v, ctrl)
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
                v.status = ask_worktree(v, r.repo, r.name, ctrl)
            else
                # Checked out somewhere the survey did not report: another repo
                # entirely, or one that has been unregistered since.
                v.status = string(r.name, " is checked out at ", r.worktree)
            end
        else
            v.status = row_session(v, r, ctrl, kind)
            worktree_reload!(v)
        end
    elseif k == Int('h')
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
