# Where the reader has been: `\`` back through it, `~` forward. The places are
# lists and the rows in them, and nothing a key does has to say it moved - the
# settle after every event is where a move is seen, for the reason it is where
# the pane follows the cursor: every path that had to remember would be one
# that forgot.

"How many spots `\`` can go back through; the oldest goes first."
const HISTORY_MAX = 200

"The spot the browser is at now."
spot_of(st::BState) = Spot(deepcopy(st.filters), st.sort,
                           st.searchin === :list ? st.search : "", st.orderkey, curl(st))

"""Notice the reader has moved, and keep where they were if it was somewhere.

Called by `settle!`, so after every event, with `now` the time of it. What is
left is kept on `back` when it was a place and not a row passed on the way:

- **a list**: any move to another list keeps the one left, whatever row it was
  on, since asking for a list is the move `\`` was first made for;
- **a jump**, either way: the row a jump went to, and the row a jump left -
  `"`, a number in `/`, `\`` and `~` themselves;
- **a row the cursor rested on** for the pane's own dwell (`LOAD_AFTER`), long
  enough for the pane to have shown it. `j` held down the list passes rows,
  and a history of every one of them would be a slower `k`.

Nothing is seen while a query is typed or the filter pane has the keys: each
character and each box is a list, and the one worth going back to is the one
before the first of them, which is where `here` still is when they end.

`fwd` is emptied by a jump or another list, which is a new road forking off
the one `~` would have retraced; not by the cursor wandering off a row `\``
went back to, which is looking around the place `~` leaves from.
"""
function note_place!(st::BState, now::Float64 = time())
    (st.typing || st.lmode === :filters) && return false
    h = st.here
    url = curl(st)
    if h !== nothing && h.key == st.orderkey && h.url == url
        st.jumped = false
        return false
    end
    kept = h !== nothing &&
           (st.jumped || st.herejump || h.key != st.orderkey ||
            now - st.hereat >= LOAD_AFTER[])
    if kept
        push!(st.back, h)
        length(st.back) > HISTORY_MAX && popfirst!(st.back)
        (st.jumped || h.key != st.orderkey) && empty!(st.fwd)
    end
    st.here = spot_of(st)
    st.hereat = now
    st.herejump = st.jumped
    st.jumped = false
    kept
end

"""Go to a spot: its list, and its row in it - as the guest when the filters
hide it now (`refilter!`), since the row is what was being looked at and
something since, a mark, may have taken it out of that list. A list that is
the one on screen keeps its order; another opens as it would when asked for."""
function go_spot!(st::BState, s::Spot)
    same = s.key == st.orderkey
    st.filters = deepcopy(s.filters)
    st.sort = s.sort
    if !isempty(s.search)
        st.search, st.searchin = s.search, :list
    elseif st.searchin === :list
        st.search = ""
    end
    refilter!(st; keeprow = same, guest = s.url)
    i = isempty(s.url) ? nothing : findfirst(x -> x.url == s.url, st.items)
    i === nothing || (st.sel = i)
    i
end

"""`\`` (`dir = -1`) or `~` (`+1`): one spot back or forward, the one left
going onto the other stack. Answers the status."""
function step_place!(st::BState, dir::Int, now::Float64 = time())
    # A move no settle has seen yet is seen first - the filter pane's, which
    # is seen only once the keys leave it - or the step would skip over it.
    note_place!(st, now)
    from, to = dir < 0 ? (st.back, st.fwd) : (st.fwd, st.back)
    isempty(from) && return dir < 0 ? "nowhere to go back to" : "nowhere to go forward to"
    push!(to, spot_of(st))
    s = pop!(from)
    samelist = s.key == st.orderkey
    i = go_spot!(st, s)
    # Arrived at by a jump, so leaving it by any road keeps it; and seen here
    # rather than by the settle after this key, which would take the step for
    # a move of its own and push the spot just left a second time.
    st.here, st.hereat, st.herejump, st.jumped = spot_of(st), now, true, false
    word = dir < 0 ? "back to " : "forward to "
    what = i === nothing ? (isempty(s.url) ? "the list" : "the list; the item is gone") :
                           st.items[i].ref
    string(word, what, samelist ? "" : string(" in [", filter_summary(st.filters, st.sort), "]"))
end
