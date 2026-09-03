
# --- mouse ------------------------------------------------------------------

"""
    onmouse!(st, ev, ctrl) -> Symbol

One mouse report, in the same shape as `handle!`.

Clicking anywhere moves the cursor there and focuses that pane, which is the
behaviour that makes a pointer worth having at all. Clicking a fold marker
toggles it. Dragging selects rows, which `y` then copies as the text they were
written as rather than as the wrapped fragments the terminal can see.

The wheel moves the cursor rather than only the viewport, because the viewport
does not survive: `window` pulls the pane back to wherever the cursor is on the
next redraw, so a scroll that left the cursor behind would spring back at the
next keystroke.
"""
function onmouse!(st::BState, ev::MouseEvent, ctrl::Controller)
    before = curl(st)
    r = onmouse_at!(st, ev, ctrl)
    if curl(st) != before
        rearm_batch!(st, before)
        batch_prompt!(st, ctrl, curl(st))
    end
    r
end

function onmouse_at!(st::BState, ev::MouseEvent, ctrl::Controller)
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
            st.sel = wheel ? clamp(st.sel + d, 0, length(st.items)) :
                             clamp(st.top + row - 2, 0, length(st.items))
            load_nodes!(st)         # clears any selection with the old nodes
        end
        return :ok
    end

    rs = rows(st.nodes, L.riw)
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
        st.focus = :detail
        st.nrow = idx
        st.anchor = idx
        st.sela = 0; st.selb = 0
        if rs[idx].header && rs[idx].part == 0 && col <= 2   # the ▾/▸ marker
            i = rs[idx].node
            st.nodes[i].open = !st.nodes[i].open
            st.nrow = headerrow(st, i, L.riw)
            st.anchor = 0
        else
            # A click on a url copies it, which is what owning the mouse is
            # for: the alternative was an OSC 8 hyperlink and a hope that the
            # terminal on the other end knew what to do with one. `y` and this
            # are the same copy, so whatever works for one works for both.
            u = link_at(st, rs[idx], col)
            if !isempty(u)
                print("\e]52;c;", Base64.base64encode(u), "\a")
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
