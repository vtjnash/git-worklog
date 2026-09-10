
# --- search -----------------------------------------------------------------

"""Rows of the detail pane that contain the query.

Matched against `src`, the line as it was written, not against what the row
prints - so a phrase the pane broke across a wrap is still found. One row per
logical line, which is what `part == 0` selects and what stops a wrapped line
counting as three matches.

Marking such a match is `row_span`'s job: a row is a contiguous piece of its
source, so the piece can be located and the match intersected with it, and a
match cut in half is marked on both of the rows it landed on.
"""
function match_rows(st::BState, w::Int)
    isempty(st.search) && return Int[]
    q = lowercase(st.search)
    [j for (j, r) in enumerate(rows(st.nodes, w))
     if r.part == 0 && occursin(q, lowercase(r.src))]
end

"""A node's source lines, at the width `rows` would render it.

`nodelines` caches per width, so asking a *closed* node costs one render the
first time and nothing after. That is the price of searching what is folded
away, and it is only paid when a search actually runs.
"""
node_srcs(n::Node, w::Int) = (nodelines(n, max(20, w - 2 * n.depth)); n.srcs)

"Nodes containing the query, whether or not any of them is currently visible."
function node_hits(st::BState, w::Int)
    q = lowercase(st.search)
    isempty(q) && return Int[]
    [i for (i, n) in enumerate(st.nodes)
     if occursin(q, lowercase(astrip(n.header))) ||
        any(occursin(q, lowercase(src)) for (_, src) in node_srcs(n, w))]
end

"""Node `i` and the run it is nested inside, innermost first.

Folding is depth rather than structure, so there are no parent pointers: what a
node is nested inside is the nearest preceding node of each lower depth.
"""
function ancestors_of(st::BState, i::Int)
    out = [i]
    d = st.nodes[i].depth
    for j in (i - 1):-1:1
        if st.nodes[j].depth < d
            push!(out, j)
            d = st.nodes[j].depth
            d == 0 && break
        end
    end
    out
end

"""Open every node holding a match, and everything each is nested inside.

Returns how many had to be opened. Only done when a search is *committed*, not
while it is being typed - folds springing open under a half-finished query would
be unreadable.
"""
function reveal_matches!(st::BState, w::Int)
    opened = 0
    for i in node_hits(st, w)
        for j in ancestors_of(st, i)
            st.nodes[j].open || (st.nodes[j].open = true; opened += 1)
        end
    end
    opened
end

"""Re-aim after the query changed.

In the list the query narrows; in the detail pane it moves the cursor to the
first hit at or after where it already is, so refining a search does not jump
back to the top of the thread.
"""
function research!(st::BState, w::Int)
    if st.searchin === :detail
        rs = rows(st.nodes, w)
        ms = match_rows(st, w)
        # A node holding a match that contributes no visible matching row is
        # folded away. Counted here rather than in `render`, which would pay for
        # it on every frame.
        seen = Set(rs[j].node for j in ms)
        st.hidden = count(!in(seen), node_hits(st, w))
        isempty(ms) && return
        st.nrow = something(findfirst(>=(st.nrow), ms), 1) |> i -> ms[i]
    else
        # A query narrows the list to what answers it, and the answer is read
        # from the top: the row the cursor was on in the list before it is not
        # a place in this one.
        refilter!(st; keeprow = false)
    end
end

"""Finish a search. A bare number is a jump rather than a filter.

Only on Enter: done live, typing the `1` of `18004` would land on whatever
`#1` happens to be and take the rest of the digits as commands. The jump also
reaches past the filter that is hiding the item, by widening the state axis -
being unable to see it is exactly when you go looking for it by number.
"""
function commit_search!(st::BState, w::Int)
    st.typing = false
    if st.searchin === :detail
        opened = reveal_matches!(st, w)
        research!(st, w)
        opened > 0 && (st.status = string("opened ", opened, " folded block",
                                          opened == 1 ? "" : "s"))
        return
    end
    n = tryparse(Int, strip(st.search))
    n === nothing && return
    k = findfirst(it -> it.number == n, st.all)
    if k === nothing
        st.status = string("no item numbered ", n)
        return
    end
    target, ref = st.all[k].url, st.all[k].ref
    st.search = ""
    # With the same marks `refilter!` uses, or the question is asked of a
    # different list than the one on screen: without them an archived item
    # reads as active, the widen does not happen, and the jump lands nowhere.
    # Widening drops the disposition axis with the state: a number typed into
    # `/` is a jump to one item, and every axis that could be hiding it goes.
    # Bare, not widened one axis at a time: a number typed into `/` is a jump
    # to one item, and every axis that could be hiding it goes.
    any(it -> it.url == target, apply_filters(st.filters, st.all, Marks(st))) ||
        (st.filters = Filters())
    refilter!(st)
    j = findfirst(it -> it.url == target, st.items)
    j === nothing || (st.sel = j)
    st.status = string("jumped to ", ref)
end

"Step to the next (`+1`) or previous (`-1`) match in the detail pane."
function jumpmatch(st::BState, dir::Int, w::Int)
    ms = match_rows(st, w)
    isempty(ms) && return false
    st.nrow = dir > 0 ? ms[something(findfirst(>(st.nrow), ms), 1)] :
                        ms[something(findlast(<(st.nrow), ms), length(ms))]
    true
end
