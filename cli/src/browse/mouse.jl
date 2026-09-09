
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
terminal can see.

The wheel moves the cursor rather than only the viewport, because the viewport
does not survive: `window` pulls the pane back to wherever the cursor is on the
next redraw, so a scroll that left the cursor behind would spring back at the
next keystroke.

`at` is a wall clock and the only thing here that is not a pure function of the
event, because a double click is two presses close together in time and the
terminal reports each of them as if it were alone. Handed in, so that a test can
make one without waiting for it.
"""
function onmouse!(st::BState, ev::MouseEvent, ctrl::Controller, at::Float64 = time())
    before = curl(st)
    r = onmouse_at!(st, ev, ctrl, at)
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
"""
const DOUBLECLICK = Ref(0.5)

"""Is this press the second half of a double click - near enough the last
one, and soon enough after it?

One column of slack, because a hand moves between the two presses and a gesture
that has to land on the same cell twice is one that mostly does not.
"""
function doubled!(st::BState, ev::MouseEvent, at::Float64)
    (t, x, y) = st.lastclick
    st.lastclick = (at, ev.x, ev.y)
    at - t <= DOUBLECLICK[] && ev.y == y && abs(ev.x - x) <= 1
end

function onmouse_at!(st::BState, ev::MouseEvent, ctrl::Controller, at::Float64 = time())
    h, w = displaysize(stdout)
    L = layout(w, h, st.nmeta)
    p = hitpane(L, ev.x, ev.y)
    p === nothing && return :ok
    (which, row, col) = p
    which === :meta && return :ok      # a readout, not a control
    wheel = ev.kind === :wheelup || ev.kind === :wheeldown
    d = ev.kind === :wheelup ? -3 : 3

    if which === :list
        (wheel || ev.kind === :press) || return :ok
        st.focus = :list
        if st.lmode === :filters
            nf = length(filter_rows(st))
            st.frow = wheel ? clamp(st.frow + d, 1, nf) : clamp(st.top + row - 1, 1, nf)
            wheel || toggle_filter!(st, ctrl)
        else
            # `- 2`, not `- 1`: the drawn list carries the import row in front
            # of item 1, and `st.top` counts drawn rows.
            was = st.sel
            st.sel = wheel ? clamp(st.sel + d, 0, length(st.items)) :
                             clamp(st.top + row - 2, 0, length(st.items))
            # A second click on the row you are already on copies its url. The
            # list has one thing worth copying and that is it; `y` is the same
            # copy from the keyboard.
            if !wheel && doubled!(st, ev, at) && st.sel == was && st.sel > 0
                it = st.items[st.sel]
                clip(it.url)
                st.status = string("copied ", it.ref, " \u00b7 ", shortlink(it.url, 60))
            end
            load_nodes!(st)         # clears any selection with the old nodes
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
        st.nrow = clamp(st.nrow + d, 1, length(rs))
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
        if r.header && r.part == 0 && col <= 2   # the ▾/▸ marker
            i = r.node
            st.nodes[i].open = !st.nodes[i].open
            st.nrow = headerrow(st, i, L.riw)
            st.anchor = 0
        elseif r.header && col >= L.riw - awidth(COPYMARK) &&
               endswith(astrip(r.text), COPYMARK)
            # The mark at the end of a header, which copies the node whole. The
            # target is the mark and the space in front of it - two columns,
            # like the fold marker at the other end - and it is recognised by
            # the row ending in one rather than by working out where `rows`
            # would have drawn it.
            txt = node_text(st.nodes, r.node, L.riw)
            clip(txt)
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
                clip(u)
                st.status = string("copied ", shortlink(u, 60))
                st.anchor = 0          # copying is not the start of a selection
            end
        end
    elseif ev.kind === :drag
        st.anchor == 0 && (st.anchor = idx)
        st.sela, st.selb = st.anchor, idx
        st.nrow = idx
    elseif ev.kind === :release
        r = selrange(st)
        r === nothing ||
            (st.status = string(r[2] - r[1] + 1, " rows selected — y to copy"))
    end
    :ok
end
