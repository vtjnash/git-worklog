# The frame: the detail pane on its own - it is also drawn beside a hosted
# child - and then the whole screen, which is `render` and is pure.

"""The detail pane: the item's title, then whatever `st.mode` selected —
the thread, the diff or the checks — wrapped to `w` and scrolled to `st.nrow`.

Split out of `render_frame` so it can also be drawn on its own, beside a pane
hosting a child program. There it is the whole left column rather than one of
three stacked ones, which is the difference between four rows of a thread and
twenty while a build runs next to it.

It mutates `st`: `hdr` for the mouse, and the scroll offset it settles on. That
is how it already worked as part of `render_frame`, and both callers want the
same thing remembered.
"""
function detail_pane(st::BState, it::Union{Nothing,Item}, rw::Int, rh::Int, focused::Bool)
    riw = rw - 4
    # What the keys have to measure against, recorded for the same reason `hdr`
    # is: only the thing that draws it knows how wide it got. `render_frame`
    # hands over what `layout` said, but a hosted pane hands over half the
    # screen - and a row index taken against the other number lands on a line
    # that was wrapped somewhere else.
    st.diw, st.dpage = riw, max(1, rh - 3)
    # The item title again, above the detail. The title bar is a row away at the
    # top of the screen and easy to lose track of once you have scrolled into a
    # long thread.
    rrows = Row[]
    if it !== nothing
        htitle = osc8(it.url, string(AB, it.ref, AR, "  ", it.title))
        for l in awrap(htitle, riw)
            push!(rrows, Row(0, false, l, string(it.ref, "  ", it.title), 0))
        end
        push!(rrows, Row(0, false, string(AD, "─"^riw, AR), "", 0))
    end
    # The mouse turns a screen row into an `nrow` by subtracting this, and only
    # here is it known - the item title wraps to however many rows it wraps to.
    st.hdr = length(rrows)
    nrows = rows(st.nodes, riw)
    append!(rrows, nrows)
    st.nrow = clamp(st.nrow, 1, max(1, length(nrows)))
    sr = selrange(st)
    if !isempty(st.search) && st.searchin === :detail
        # Marked against the source rather than against the row, so that a match
        # the wrapping cut in half is marked on both of the rows it landed on.
        # Hits are found once per logical line; several rows share one.
        srchits = Dict{String,Vector{UnitRange{Int}}}()
        cursor = 1
        for i in 1:length(nrows)
            r = rrows[i + st.hdr]
            r.part == 0 && (cursor = 1)
            ind = 2 * st.nodes[r.node].depth
            sp = r.header ? nothing : row_span(r, ind, cursor)
            hs = if sp === nothing
                findhits(astrip(r.text), st.search)
            else
                cursor = last(sp) + 1
                out = UnitRange{Int}[]
                for mr in get!(() -> findhits(r.src, st.search), srchits, r.src)
                    lo, hi = max(first(mr), first(sp)), min(last(mr), last(sp))
                    lo <= hi &&
                        push!(out, (lo - first(sp) + 1 + ind):(hi - first(sp) + 1 + ind))
                end
                out
            end
            isempty(hs) && continue
            rrows[i + st.hdr] = Row(r.node, r.header, hlspan(r.text, hs, HITBG),
                                    r.src, r.part)
        end
    end
    for i in 1:length(nrows)
        insel = sr !== nothing && sr[1] <= i <= sr[2]
        # Mark the cursor row so it is visible while paging through a body,
        # not only when it lands on a header. The selection outranks it.
        cur = st.focus === :detail && i == st.nrow
        (insel || cur) || continue
        r = rrows[i + st.hdr]
        rrows[i + st.hdr] = Row(r.node, r.header,
                                hlrow(apad(afit(r.text, riw), riw), insel ? SELBG : CURBG),
                                r.src, r.part)
    end
    rvis, st.ntop = window(rrows, st.nrow + st.hdr, st.ntop, rh - 2)

    total = length(nrows)
    rtitle = string(String(st.mode),
                    it === nothing ? "" : string("  ", it.ref),
                    total > 0 ? string("  ", st.ntop, "-",
                                       min(total, st.ntop + rh - 3), "/", total) : "",
                    sr === nothing ? "" : string("  ", AB, sr[2] - sr[1] + 1, " selected", AR))

    pane(rvis, rw, rh, rtitle, focused)
end

"""
    render_frame(st, w, h) -> String

The whole screen, and what `render(::BState, w, h)` is. Pure. Side by side when
the terminal is wide enough, stacked otherwise, so a narrow window degrades
rather than truncating the detail into uselessness.
"""
function render_frame(st::BState, w::Int, h::Int)
    # Zero is the import row, which is why this is not the usual clamp to 1.
    st.sel = clamp(st.sel, 0, length(st.items))
    it = st.sel == 0 ? nothing : st.items[st.sel]
    # The pane sizes to its content, so it is rendered before the heights are
    # settled; only its width is known this early, and only its width is needed.
    mlines = meta_lines(st, it, leftw(w) - 4)
    st.nmeta = length(mlines)
    L = layout(w, h, st.nmeta)
    lw, rw, lh, rh, liw, riw = L.lw, L.rw, L.lh, L.rh, L.liw, L.riw
    if st.lmode === :filters
        frows = filter_rows(st)
        st.frow = clamp(st.frow, 1, max(1, length(frows)))
        lrows = Row[]
        for (j, (axis, _, text)) in enumerate(frows)
            on = j == st.frow && st.focus === :list && axis !== :head
            push!(lrows, Row(j, true, string(axis === :head ? AB : on ? "\e[1;37m" : AD,
                                             afit(text, liw), AR), text, 0))
        end
        lvis, st.top = window(lrows, st.frow, st.top, lh - 2)
        ltitle = "filters"
    else
        # The import row leads, always: a list of two thousand rows is not
        # somewhere a control can be discovered at the bottom of.
        lrows = Row[Row(0, true,
                        string(st.sel == 0 && st.focus === :list ? "\e[1;37m" : AD,
                               afit(NEWROW, liw), AR), NEWROW, 0)]
        for i in 1:length(st.items)
            it_ = st.items[i]
            on = i == st.sel && st.focus === :list
            txt = afit(string(it_.track == "close" ? "*" : " ", it_.ref, " ", it_.title), liw)
            # Weight says whether it has been read, which is the one thing
            # about a row worth knowing before opening it and the one thing the
            # list never said: unread is bold, read is plain. Dim is left to the
            # import row, which is the only row that is not an item - two
            # thousand dimmed rows were what made the unread ones invisible
            # among them.
            styled = string(it_.url in st.unread ? AB : "", txt, AR)
            (isempty(st.search) || st.searchin !== :list) ||
                (styled = hlspan(styled, findhits(astrip(styled), st.search), HITBG))
            # The cursor is a background now rather than a weight, since weight
            # is spoken for: bright-white bold among bold rows is not a cursor
            # anybody can find. Laid over the padded row the way the detail
            # pane's is, and by the same `hlrow`, which re-arms the background
            # after every reset the row carries - including the ones a search
            # highlight leaves behind, which is why it goes on last.
            on && (styled = hlrow(apad(styled, liw), CURBG))
            push!(lrows, Row(i, true, styled,
                             string(it_.ref, " ", it_.title), 0))
        end
        # One row further down than the selection, since the import row is at
        # the front of the drawn list and in front of index 1.
        lvis, st.top = window(lrows, st.sel + 1, st.top, lh - 2)
        ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    end

    left = pane(lvis, lw, lh, ltitle, st.focus === :list)
    L.mh > 0 && append!(left, pane(first(mlines, L.mh - 2), lw, L.mh,
                                   it === nothing ? "meta" : string("meta  ", it.ref),
                                   false))
    right = detail_pane(st, it, rw, rh, st.focus === :detail)

    links = Pair{String,String}[]
    for n in st.nodes, u in n.urls
        push!(links, shortlink(u, max(20, riw - 8)) => u)
    end

    # Split the way the keys themselves divide: what shows you something, then
    # what changes something. The status keeps the bottom row, where it has
    # always been and where the eye already goes for it.
    # Worst-first is the wrong order for a line that gets cut on a narrow
    # screen: `j/k` and `q` are the keys nobody needs told, so the navigation
    # runs at the end and what is worth reading is at the front.
    keys1 = string("[", filter_summary(st.filters, st.sort), "]  f filters \u00b7 \' views \u00b7 w sort \u00b7 ",
                   "d diff \u00b7 o comments \u00b7 c checks \u00b7 [/] context \u00b7 l log \u00b7 ",
                   "y copy \u00b7 / search \u00b7 ",
                   # What `\u21b5` does depends on where the cursor is, and a
                   # footer that names only one of the three is why the row at
                   # the top of the list needed explaining twice.
                   st.focus === :detail ? "\u21b5 fold \u00b7 " :
                   st.sel == 0 ? "\u21b5 import \u00b7 " : "\u21b5 read \u00b7 ",
                   "n/N node \u00b7 ",
                   "g/G top/bottom \u00b7 j/k line \u00b7 space/b page \u00b7 ",
                   "q quit \u00b7 tab pane")
    nb = st.batch === nothing ? "" : string("(", st.batch.n, ")")
    # `i import` is not in here, and is the only key that is not: its control is
    # the row at the top of the list, permanently on screen and saying what it
    # does. A second copy of it costs the row that the keys which have no such
    # row are competing for.
    keys2 = string("C comment \u00b7 A review", nb, " \u00b7 L labels \u00b7 r read/unread \u00b7 u update all \u00b7 R reload \u00b7 s snooze \u00b7 ",
                   "z undo", isempty(st.undos) ? "" : string("(", length(st.undos), ")"),
                   " \u00b7 v note \u00b7 x archive \u00b7 e edit \u00b7 t term \u00b7 T agent \u00b7 \" worktrees \u00b7 m mouse ",
                   st.mouse ? "on" : "off")
    # A logged error outranks both: it is standing, and stays until the file
    # naming it is deleted.
    # `oneline` is not belt and braces: a status set from an exception carries
    # whatever newlines `showerror` put in it, and one of those in a one-row
    # field makes the frame taller than the screen.
    msg = oneline(isempty(errnote()) ? st.status : errnote())
    foot1 = string(AD, afit(keys1, w), AR)
    foot2 = if st.typing
        # The query line, with a block for the cursor: this view draws its own,
        # the terminal's being hidden for the whole run.
        #
        # The count of what is folded away belongs *here*, while there is still
        # a decision to make about it. After enter it is always zero, because
        # committing is what opens them.
        found = st.searchin === :detail ? length(match_rows(st, riw)) : length(st.items)
        unit = st.searchin === :detail ? (found == 1 ? " match" : " matches") :
                                         (found == 1 ? " item" : " items")
        tally = isempty(st.search) ? "" :
                string(found, unit,
                       st.hidden > 0 ? string(" (+", st.hidden, " folded)") : "", " · ")
        string(AB, "/", AR, st.search, "\e[7m \e[0m", AD, "   ", tally,
               st.hidden > 0 ? "↵ opens them" : "↵ keep", " · esc drop", AR)
    elseif !isempty(st.search) && isempty(msg)
        # Only when there is nothing to say. A live search is *standing*
        # information - it is re-derived every frame and the query is on screen
        # anyway - while a status is something that just happened and will not
        # happen again. Held the other way round, an answer to a key press
        # ("`claude` is not on PATH") never appeared at all, and the key looked
        # broken rather than refused.
        nmatch = st.searchin === :detail ? length(match_rows(st, riw)) : length(st.items)
        string(AB, "/", st.search, AR, AD, "  ", nmatch,
               st.searchin === :detail ?
                   string(nmatch == 1 ? " match · " : " matches · n/N steps them · ") :
                   (nmatch == 1 ? " item · " : " items · "),
               "/ to search again", AR)
    else
        string(AD, afit(isempty(msg) ? keys2 : msg, w), AR)
    end
    foot2 = string(AD, afit(foot2, w), AR)
    # Padded to the screen as well as laid out to it: the columns add up to `w`
    # by construction, and this is what keeps a frame the width of the terminal
    # if they ever stop.
    body = [apad(r, w) for r in
            (L.side ? [string(left[i], right[i])
                       for i in 1:min(length(left), length(right))] :
                      vcat(left, right))]
    # Row 1 is a title bar so that selecting the top line in tmux - which
    # scrolls the pane to make room for its own status line - never lands on
    # content. Everything real starts at row 2.
    bar = if it === nothing
        string(" worklog  ", AD, length(st.items), " items", AR)
    else
        link = osc8(it.url, string(it.ref, "  ", it.title))
        string(" ", AB, link, AR, "  ", AD, "[", filter_summary(st.filters, st.sort), "]", AR)
    end
    # Clamp to the terminal rather than trusting the arithmetic: on a very short
    # terminal the pane minimums add up to more than there is room for, and a
    # frame taller than the screen scrolls the title bar off the top.
    all_ = vcat([apad(afit(bar, w), w)], body, [apad(foot1, w), apad(foot2, w)])
    while length(all_) < h
        push!(all_, " "^w)
    end
    linkify(join(all_[1:h], "\n"), links)
end

"""
    linkify(frame, links) -> String

Wrap each rendered short URL in an OSC 8 hyperlink pointing at the full one.

Done last, on the finished frame, because OSC 8 sequences are invisible to the
terminal but not to Term's width accounting - injecting them earlier would wrap
lines that fit. The display form is kept short enough that Term never splits it
across lines, which is what makes a plain textual replacement safe here.

Only in what *prints*, though, which a plain `replace` over the frame was not.
Every comment header is already an OSC 8 hyperlink to its own permalink, and a
url written in one comment is very often the permalink of another - nanosoldier
replies with a link to the `runbenchmarks()` comment that asked. Replacing
inside that payload put a second `\e]8;;` in the middle of the first, which
terminates the outer sequence early and prints the rest of the url as literal
characters that nothing has measured: a row 224 columns wide in a 150-column
terminal, which is the screen tearing.

So the frame is cut on its OSC sequences and only the pieces between them are
substituted. Cut on those alone and not on every escape, because a colour code
splitting a display form is a match that was already missed before this and is
none of this function's business.

**And the same tearing, from the other direction: a loop of `replace`s reads its
own output.** The links are one per url per *node*, so a url cited in four
comments - which is exactly what nanosoldier does, one report link per run -
arrives here four times. A url short enough to be shown whole is its own display
form, so the second pass found it again *inside the payload the first had just
written* and hyperlinked that, and the row tore in the way described above.
One `replace` with every pattern at once is the fix, because that one is defined
not to look at its own replacements; the list is deduplicated and taken longest
first, so a display form that is the head of another cannot win over it.
"""
const OSC = r"\e\][^\e]*\e[\\]"

function linkify(frame::AbstractString, links)
    isempty(links) && return frame
    seen, pats = Set{String}(), Pair{String,String}[]
    for (disp, full) in sort(collect(links); by = p -> -length(first(p)), alg = MergeSort)
        (isempty(disp) || disp in seen) && continue
        push!(seen, disp)
        push!(pats, String(disp) => osc8(full, disp))
    end
    isempty(pats) && return frame
    sub(s) = replace(s, pats...)
    out, at = IOBuffer(), firstindex(frame)
    for m in eachmatch(OSC, frame)
        write(out, sub(SubString(frame, at, prevind(frame, m.offset))))
        write(out, m.match)
        at = m.offset + ncodeunits(m.match)
    end
    write(out, sub(SubString(frame, at)))
    String(take!(out))
end
