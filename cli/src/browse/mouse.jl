
# --- mouse ------------------------------------------------------------------

"""
    onmouse!(st, ev, ctrl, at) -> Symbol

One mouse report, in the same shape as `handle!`.

Clicking anywhere moves the cursor there and focuses that pane, which is the
behaviour that makes a pointer worth having at all. Clicking a fold marker
toggles it, and clicking the copy mark at the end of a header copies that node
whole. A double click copies what is under the pointer: the url, the word, or in
the item list that item's own url. Dragging selects rows, which `y` then copies
as the text they were written as rather than as the wrapped fragments the
terminal can see; held past the top or bottom of the pane it goes on
selecting, a row at a time, whether or not the pointer moves (`drag_rows!`).

The wheel moves the cursor rather than only the viewport, because the viewport
does not survive: `window` pulls the pane back to wherever the cursor is on the
next redraw, so a scroll that left the cursor behind would spring back at the
next keystroke.

`at` is a wall clock and the only thing here that is not a pure function of the
event, because a double click is two presses close together in time and the
terminal reports each of them as if it were alone. Handed in, so that a test can
make one without waiting for it.

`L` is where the panes are, and it is the geometry of the frame that was
*drawn*: `layout`'s when the browser is on its own, and `beside_layout`'s when
the detail is the left column beside a hosted pane or a composer, which is
what those views hand in. A click only maps to the row under it against the
wrapping the reader is looking at - the same rule `st.diw` holds for the keys.
"""
function onmouse!(st::BState, ev::MouseEvent, ctrl::Controller, at::Float64 = time();
                  L = nothing)
    before = curl(st)
    r = onmouse_at!(st, ev, ctrl, at; L)
    if curl(st) != before
        rearm_batch!(st, before)
        batch_prompt!(st, ctrl, curl(st))
    end
    r
end

"""How long two presses can be apart and still be one double click.

Longer than a terminal's own, deliberately: this one copies rather than selects,
so a double click that misses does nothing at all and a single click that counts
as a double copies a word nobody asked for. Neither is expensive, and the slower
window is the one that catches the gesture people actually make.

`[mouse] double_click_seconds` in the config, set when the browser starts.
"""
const DOUBLECLICK = Ref(0.5)

"""Is this press the second half of a double click - near enough the last
one, and soon enough after it? (`TermInput.doubled` says how near.)"""
function doubled!(st::BState, ev::MouseEvent, at::Float64)
    dbl = doubled(st.lastclick, ev, at)
    st.lastclick = (at, ev.x, ev.y)
    dbl
end

function onmouse_at!(st::BState, ev::MouseEvent, ctrl::Controller, at::Float64 = time();
                     L = nothing)
    if L === nothing
        h, w = displaysize(ctrl.term)
        L = layout(w, h, st.nmeta)
    end
    # A drag the thread started is the thread's wherever the pointer goes,
    # since past its top or bottom is where a drag goes to scroll.
    st.dragging && (ev.kind === :drag || ev.kind === :release) &&
        return drag_rows!(st, ev, L)
    p = hitpane(L, ev.x, ev.y)
    p === nothing && return :ok
    (which, row, col) = p
    which === :meta && return :ok      # a readout, not a control
    wheel = ev.kind === :wheelup || ev.kind === :wheeldown

    if which === :list
        (wheel || ev.kind === :press) || return :ok
        st.focus = :list
        if st.lmode === :filters
            # The foot is a readout of the row under the cursor, not a row.
            !wheel && row > L.lh - 2 - filter_help_h(L.lh) && return :ok
            nf = length(filter_rows(st))
            st.frow = wheel ? listmove(ev.kind, st.frow, nf) : clamp(st.top + row - 1, 1, nf)
            wheel || toggle_filter!(st, ctrl)
        else
            # `- 2`, not `- 1`: the drawn list carries the import row in front
            # of item 1, and `st.top` counts drawn rows.
            was = st.sel
            st.sel = wheel ? listmove(ev.kind, st.sel, length(st.items); lo = 0) :
                             clamp(st.top + row - 2, 0, length(st.items))
            # A second click on the row you are already on copies its url. The
            # list has one thing worth copying and that is it; `y` is the same
            # copy from the keyboard.
            if !wheel && doubled!(st, ev, at) && st.sel == was && st.sel > 0
                it = st.items[st.sel]
                clip(ctrl.term, weblink(it))
                st.status = string("copied ", it.ref, " \u00b7 ", shortlink(weblink(it), 60))
            end
        end
        return :ok
    end

    # The same rows the pane drew, marks and all: a click on the copy mark is
    # recognised by the row ending in one, so `rows` stays the only place that
    # knows where the mark is.
    rs = rows(st.nodes, L.riw, st.mouse)
    isempty(rs) && return :ok
    if wheel
        st.focus = :detail
        clearsel!(st)
        st.nrow = listmove(ev.kind, st.nrow, length(rs))
        return :ok
    end
    # `ntop` indexes rows including the item-title block; `nrow` excludes it.
    idx = st.ntop + row - 1 - st.hdr
    1 <= idx <= length(rs) || return :ok
    if ev.kind === :press
        dbl = doubled!(st, ev, at)
        st.focus = :detail
        st.nrow = idx
        st.anchor = idx
        st.sela = 0; st.selb = 0
        r = rs[idx]
        # The ▾/▸ marker, which a nested node draws after its indent: the
        # blank columns in front of it belong to nobody.
        ind = 2 * st.nodes[r.node].depth
        if r.header && r.part == 0 && ind < col <= ind + 2
            i = r.node
            st.nodes[i].open = !st.nodes[i].open
            st.nrow = headerrow(st, i, L.riw)
            st.anchor = 0
        elseif r.header && col >= L.riw - textwidth(COPYMARK) &&
               endswith(String(r.text), COPYMARK)
            # The mark at the end of a header, which copies the node whole. The
            # target is the mark and the space in front of it - two columns,
            # like the fold marker at the other end - and it is recognised by
            # the row ending in one rather than by working out where `rows`
            # would have drawn it.
            txt = node_text(st.nodes, r.node, L.riw)
            clip(ctrl.term, txt)
            st.status = string("copied ", count(==('\n'), txt) + 1, " lines")
            st.anchor = 0
        else
            # A click on a url copies it, which is what owning the mouse is
            # for: the alternative was an OSC 8 hyperlink and a hope that the
            # terminal on the other end knew what to do with one. `y` and this
            # are the same copy, so whatever works for one works for both.
            #
            # A double click copies whatever else is under the pointer, which is
            # the gesture everybody already makes at a word they want.
            u = link_at(st, r, col)
            isempty(u) && dbl && (u = word_at(st, r, col))
            if !isempty(u)
                clip(ctrl.term, u)
                st.status = string("copied ", shortlink(u, 60))
                st.anchor = 0          # copying is not the start of a selection
            end
        end
        st.dragging = st.anchor != 0
    end
    :ok
end

"""
    drag_rows!(st, ev, L) -> Symbol

A drag that began on a row of the thread, and the button coming up on it,
wherever the pointer now is. Over the pane it selects to the row under it.
Past the top or the bottom it selects a row further at once, and then a row
every `TermIFrame.DRAG_SCROLL` - the rate a hosted pane's drag scrolls at, and
the same setting - until the pointer is back over the pane or the button comes
up: a timer wakes the controller, and `drag_step!` takes the row. The window
follows the cursor, so the next frame shows it. Motion past the edge moves
nothing; that is the timer's, and moving does not hurry it.
"""
function drag_rows!(st::BState, ev::MouseEvent, L)
    if ev.kind === :release
        st.dragging = false
        drag_edge!(st, 0)
        r = selrange(st)
        r === nothing ||
            (st.status = string(r[2] - r[1] + 1, " rows selected — y to copy"))
        return :ok
    end
    n = length(rows(st.nodes, L.riw, st.mouse))
    n == 0 && return :ok
    row, inner = ev.y - L.ry, L.rh - 2      # as `hitpane` counts them
    edge = row < 1 ? -1 : row > inner ? 1 : 0
    if edge == 0
        drag_to!(st, clamp(st.ntop + row - 1 - st.hdr, 1, n))
    elseif st.ticker === nothing
        # One past the row drawn at that edge, which the window then shows.
        drag_to!(st, clamp(edge < 0 ? st.ntop - st.hdr - 1 : st.ntop - st.hdr + inner, 1, n))
    end
    drag_edge!(st, edge, L.riw)
    :ok
end

"The end of a drag's selection is row `idx`, and so is the cursor."
function drag_to!(st::BState, idx::Int)
    st.anchor == 0 && (st.anchor = idx)
    st.sela, st.selb = st.anchor, idx
    st.nrow = idx
    nothing
end

"""The drag is past an edge, `-1` or `1`, or it is not, `0`: the timer for its
next row is armed on the way past and stopped on the way back."""
function drag_edge!(st::BState, edge::Int, w::Int = st.dragw)
    st.edge, st.dragw = edge, w
    if edge == 0
        st.ticker === nothing || close(st.ticker)
        st.ticker = nothing
    elseif st.ticker === nothing
        drag_arm!(st)
    end
    nothing
end

function drag_arm!(st::BState)
    w = st.wake
    w === nothing && return
    st.ticker = Timer(_ -> wake!(w), TermIFrame.DRAG_SCROLL[])
end

"""A row further past the edge, when the timer has fired: the wake it raised
is the one that is here. Any other wake finds it not yet due. At the end of
the rows there is nowhere to go, and the timer is not armed again."""
function drag_step!(st::BState)
    t = st.ticker
    (st.dragging && st.edge != 0 && t !== nothing && !isopen(t)) || return false
    st.ticker = nothing
    n = length(rows(st.nodes, st.dragw, st.mouse))
    to = clamp(st.nrow + st.edge, 1, max(n, 1))
    to == st.nrow && return false
    drag_to!(st, to)
    drag_arm!(st)
    true
end

# --- the pickers ------------------------------------------------------------
#
# A click on a row of a picker moves the cursor there and a double click picks
# it, which is `↵` - the two gestures the item list answers, for the views
# list (`'`), the checkout chooser under `t`/`T` and the worktree list (`"`).
# The wheel moves the cursor, for the reason it does in the list. Nothing else
# on them is a control; a click outside a chooser's box cancels it, which is
# what a click outside a box means everywhere.

"Is this press the second half of a double click on `last`?"
doubled(last::Tuple{Float64,Int,Int}, ev::MouseEvent, at::Float64) =
    TermInput.doubled(last, ev.x, ev.y, at, DOUBLECLICK[])

function onmouse!(v::ChooseView, ev::MouseEvent, ctrl::Controller, at::Float64 = time())
    r = TermInput.click!(getfield(v, :c), ev.kind, ev.x, ev.y, at; window = DOUBLECLICK[])
    r === :unhandled ? :pop : r === :pick ? handle!(v, 13, ctrl) : :ok
end
