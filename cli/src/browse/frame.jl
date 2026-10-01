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
function detail_pane(st::BState, it::Union{Nothing,Item}, rw::Int, rh::Int, focused::Bool,
                     at::DateTime = utcnow())
    riw = rw - 4
    # What the keys have to measure against, recorded for the same reason `hdr`
    # is: only the thing that draws it knows how wide it got. `render_frame`
    # hands over what `layout` said, but a hosted pane hands over half the
    # screen - and a row index taken against the other number lands on a line
    # that was wrapped somewhere else. And the indices already taken - the
    # cursor, and the rows a drag went over - are carried across to the new
    # wrapping before the width is forgotten, or they would land there too.
    rewrap!(st, st.diw, riw)
    st.diw, st.dpage = riw, max(1, rh - 3)
    # The item title again, above the detail. The title bar is a row away at the
    # top of the screen and easy to lose track of once you have scrolled into a
    # long thread.
    rrows = Row[]
    if it !== nothing
        htitle = osc8(weblink(it), faced(it.ref, THEME.bold)) * "  " * kind_phrase(it) *
                 "  " * osc8(weblink(it), it.title)
        for l in rowwrap(htitle, riw)
            push!(rrows, Row(0, false, l, string(it.ref, "  ", it.title), 0))
        end
        push!(rrows, Row(0, false, faced("─"^riw, THEME.dim), "", 0))
    end
    # The mouse turns a screen row into an `nrow` by subtracting this, and only
    # here is it known - the item title wraps to however many rows it wraps to.
    st.hdr = length(rrows)
    # With the copy marks: this is the one place the pane is actually drawn,
    # and the mark is an offer to click that only holds while we own the mouse.
    # And with the clock, for the same reason: how long ago a comment was made
    # is drawn against `at` here and stored nowhere.
    nrows = rows(st.nodes, riw, st.mouse; at = at)
    append!(rrows, nrows)
    st.nrow = clamp(st.nrow, 1, max(1, length(nrows)))
    sr = selrange(st)
    if !isempty(st.search) && st.searchin === :detail
        # Marked against the source rather than against the row, so that a match
        # the wrapping cut in half is marked on both of the rows it landed on.
        # Hits are found once per logical line; several rows share one.
        srchits = Dict{String,Vector{UnitRange{Int}}}()
        re = searchre(st.search)
        cursor = 1
        for i in 1:length(nrows)
            r = rrows[i + st.hdr]
            r.part == 0 && (cursor = 1)
            ind = 2 * st.nodes[r.node].depth
            sp = r.header ? nothing : row_span(r, ind, cursor)
            hs = if sp === nothing
                findhits(String(r.text), re)
            else
                cursor = last(sp) + 1
                out = UnitRange{Int}[]
                for mr in get!(() -> findhits(r.src, re), srchits, r.src)
                    lo, hi = max(first(mr), first(sp)), min(last(mr), last(sp))
                    lo <= hi &&
                        push!(out, (lo - first(sp) + 1 + ind):(hi - first(sp) + 1 + ind))
                end
                out
            end
            isempty(hs) && continue
            rrows[i + st.hdr] = Row(r.node, r.header, hlspan(r.text, hs, THEME.match_bg),
                                    r.src, r.part, r.gutter)
        end
    end
    for i in 1:length(nrows)
        insel = sr !== nothing && sr[1] <= i <= sr[2]
        # Mark the cursor row so it is visible while paging through a body,
        # not only when it lands on a header. The selection outranks it.
        cur = st.focus === :detail && i == st.nrow
        r = rrows[i + st.hdr]
        # Otherwise a header in the diff says what it heads by its background,
        # as GitHub's do. Laid here and not in `rows`, and only where the cursor
        # is not: a background inside the row would outlast the cursor's.
        bg = insel ? THEME.select_bg : cur ? THEME.cursor_bg : header_bg(st, r)
        bg == Face() && continue
        rrows[i + st.hdr] = Row(r.node, r.header, hlrow(rowpad(rowfit(r.text, riw), riw), bg),
                                r.src, r.part, r.gutter)
    end
    rvis, st.ntop = window(rrows, st.nrow + st.hdr, st.ntop, rh - 2)

    total = length(nrows)
    rtitle = string(String(st.mode),
                    it === nothing ? "" : string("  ", it.ref),
                    total > 0 ? string("  ", st.ntop, "-",
                                       min(total, st.ntop + rh - 3), "/", total) : "") *
             (sr === nothing ? row("") :
                  "  " * faced(string(sr[2] - sr[1] + 1, " selected"), THEME.bold))

    footer!(bordered([r.text for r in rvis], rw, rh, rtitle; focused,
                     gutter = [r.gutter for r in rvis]),
            pane_stamp(st, at))
end

"""When what a pane shows was read, said on its bottom border: `loaded 14:02`,
`loading …` until it has been, and `· reloading …` while a re-read runs under
it. On the border because the border is there anyway - a row of its own would
make the pane a row taller or shorter as a load came and went - and not in the
status, which is what the keys say and was written over by every load one of
them started.

`at` is a unix time, 0 for nothing to say. The day is left out when it is today
where you are, which is the case a stamp is mostly read in.
"""
function load_stamp(at::Float64, now::DateTime; loading::Bool = false,
                    reloading::Bool = false, failed::Bool = false)
    loading && return "loading \u2026"
    at > 0 || return ""
    t = unix2datetime(at)
    day = local_str(t)
    when = first(day, 10) == first(local_str(now), 10) ? last(day, 5) : day
    string("loaded ", when, reloading ? " \u00b7 reloading \u2026" :
                            failed ? " \u00b7 re-read failed" : "")
end

"The detail pane's stamp: the thread, the diff or the checks, as `load_stamp`."
function pane_stamp(st::BState, at::DateTime)
    (st.sel == 0 || isempty(st.items)) && return ""
    key = mode_key(st, st.items[clamp(st.sel, 1, length(st.items))], st.mode)
    load_stamp(st.loaded == key ? st.loadedat : 0.0, at;
               loading = st.pendkey == key && !st.quiet,
               reloading = st.quiet && st.pendkey == key,
               failed = st.reloadfailed)
end

"The metadata pane's stamp, the same way."
function meta_stamp(st::BState, it::Union{Nothing,Item}, at::DateTime)
    it === nothing && return ""
    mine = st.metakey == it.url
    landed = mine && st.metaat > 0
    load_stamp(landed ? st.metaat : 0.0, at;
               loading = !landed && meta_waiting(st, it),
               reloading = landed &&
                           (st.metapending !== nothing || st.bundlepending !== nothing ||
                            # The merge's first answer is the row saying
                            # "loading…", not a re-read.
                            (st.mergepending !== nothing && st.merge !== nothing)))
end

"""Write `label` into the bottom border of a box `bordered` drew, at the right
end - the mirror of the title at the top left. The border's own face is lifted
off the row rather than asked for again, so it is whatever weight the box was
drawn in; a label that does not fit leaves the border as it was."""
function footer!(box::Vector{Styled}, label::AbstractString)
    (isempty(label) || isempty(box)) && return box
    l = box[end]
    cs = collect(String(l))
    lw = rowwidth(label)
    n = length(cs) - 5 - lw
    n >= 1 || return box
    # The face over the corner is the border's; the label is drawn dim in it.
    edge = Styled(string(cs[1], string(cs[2])^n, " "), Ann[])
    tail = Styled(string(" ", cs[2], cs[end]), Ann[])
    bf = Face[a.value for a in anns(l) if a.label === :face && 1 in a.region]
    f = isempty(bf) ? Face() : first(bf)
    box[end] = faced(edge, f) * faced(faced(label, THEME.dim), f) * faced(tail, f)
    box
end

"""What the number is of, said beside it: `issue`, `pull request`, `draft
pull request`, `branch` for an adopted one - the words the filter's kind axis
uses - with the state in front once it is over, `merged pull request`, `closed
issue` - and `notice` for a notice, whose ref already says its type.
`julia#62452` says neither, and which of the two it is decides what
the keys under it do: `d`, `p`, `M` and a review are a pull request's. Merged
is settled and closed is blocked, the colours the state has everywhere else;
open is dim, being the usual case."""
function kind_phrase(it::Item)
    islocal(it) && return faced("branch", THEME.dim)
    isnotice(it) && return faced("notice", THEME.dim)
    what = it.is_pr ? (it.draft ? "draft pull request" : "pull request") : "issue"
    it.state == "MERGED" && return faced("merged " * what, THEME.settled)
    it.state == "CLOSED" && return faced("closed " * what, THEME.blocked)
    faced(what, THEME.dim)
end

"The title bar: the item under the cursor, by repository and number - the
form that reads on a tab and pastes into a search - or the bare name."
viewtitle(st::BState) =
    (st.sel == 0 || isempty(st.items)) ? "wl" :
    (it = st.items[clamp(st.sel, 1, length(st.items))];
     string("wl ", it.repo, isnotice(it) ? " " * notice_word(it.notice) :
                            it.number == 0 ? " " * it.branch : string("#", it.number)))

"""The title bar's right-hand end: when the corpus was last fetched -
`fetched_at`, GitHub's time, absolute and relative the way every other stamp
is drawn - or that `u`'s refresh is running. Empty when nothing has been
fetched, and for a corpus from before the refresh stamped it."""
function refresh_stamp(st::BState, at::DateTime)
    refreshing() && return faced("refreshing \u2026 ", THEME.dim)
    w = when_str(st.refreshed, at)
    isempty(w) ? row("") : faced("refreshed ", THEME.dim) * w * " "
end

"""The background a header row is drawn on, or the empty face.

In the diff, a hunk is blue and a hunk of a new file grey, which is how GitHub
marks where one region of a change ends and the next begins; a review comment
hanging off a line has its own. In the thread, a comment or a review is grey,
and blue when it is yours, as GitHub boxes them - and a push, a close or the
rule over what is new is none, being the timeline between the boxes rather
than one of them. Not the blank row above a top-level header, which is spacing.
"""
function header_bg(st::BState, r::Row)
    (r.header && !(r.part == 1 && isempty(r.text))) || return Face()
    n = st.nodes[r.node]
    n.kind === :diff && return get(n.meta, "newfile", false) === true ?
                               THEME.diff_file_bg : THEME.diff_hunk_bg
    st.mode === :diff && haskey(n.meta, "comment_id") && return THEME.diff_comment_bg
    st.mode === :comments && n.depth == 0 && haskey(n.meta, "mine") &&
        return n.meta["mine"] === true ? THEME.thread_mine_bg : THEME.thread_bg
    Face()
end

"""
    render_frame(st, w, h) -> Vector{Styled}

The whole screen, and what `render(::BState, w, h)` is. Pure. Side by side when
the terminal is wide enough, stacked otherwise, so a narrow window degrades
rather than truncating the detail into uselessness.
"""
function render_frame(st::BState, w::Int, h::Int, at::DateTime = utcnow())
    # Zero is the import row, which is why this is not the usual clamp to 1.
    st.sel = clamp(st.sel, 0, length(st.items))
    st.caret = nothing
    qcol = 0               # the query's caret on the footer row, while it is typed
    it = st.sel == 0 ? nothing : st.items[st.sel]
    # The pane sizes to its content, so it is rendered before the heights are
    # settled; only its width is known this early, and only its width is needed.
    mlines = meta_lines(st, it, leftw(w) - 4, at)
    st.nmeta = length(mlines)
    L = layout(w, h, st.nmeta)
    lw, rw, lh, rh, liw, riw = L.lw, L.rw, L.lh, L.rh, L.liw, L.riw
    if st.lmode === :filters
        frows = filter_rows(st)
        st.frow = clamp(st.frow, 1, max(1, length(frows)))
        lrows = Row[]
        for (j, (axis, _, text)) in enumerate(frows)
            on = j == st.frow && st.focus === :list && axis !== :head
            push!(lrows, Row(j, true,
                             faced(rowfit(text, liw),
                                   axis === :head ? THEME.bold : on ? THEME.focus : THEME.dim),
                             text, 0))
        end
        # What the row under the cursor means, at the foot: the labels are a
        # few words of this program's vocabulary, and a sentence is wanted
        # only for the row being decided about. See `filter_help`.
        fh = filter_help_h(lh)
        lvis, st.top = window(lrows, st.frow, st.top, lh - 2 - fh)
        if fh > 0
            (axis, val, _) = frows[st.frow]
            help = rowwrap(filter_help(axis, val), liw)
            lvis = vcat(lvis, fill(Row(0, false, row(""), "", 0), lh - 2 - fh - length(lvis)),
                        [Row(0, false, faced("─"^liw, THEME.dim), "", 0)],
                        [Row(0, false, faced(rowfit(l, liw), THEME.dim), "", 0)
                         for l in first(vcat(help, fill(row(""), fh - 1)), fh - 1)])
        end
        ltitle = "filters"
    else
        # The import row leads, always: a list of two thousand rows is not
        # somewhere a control can be discovered at the bottom of.
        lrows = Row[Row(0, true,
                        faced(rowfit(NEWROW, liw),
                              st.sel == 0 && st.focus === :list ? THEME.focus : THEME.dim),
                        NEWROW, 0)]
        # One reading of the marks for the whole frame, so a list is not
        # half-woken across its own rows; the same answer `refilter!` sorted by.
        marks = Marks(st, at)
        quiet = st.focus !== :list
        for i in 1:length(st.items)
            it_ = st.items[i]
            # Whichever side has the keys: the row says which item the reading
            # pane is showing, and it went dark on `tab`, so the item being
            # read had to be found again in the list on the way back. Which
            # side is lit is the border's to say, and it does.
            on = i == st.sel
            # The guest says it is one, where every row has a space to spare:
            # a row the filters in the title would not have shown, which the
            # next list asked for will not have.
            txt = rowfit(string(it_.url == st.guest ? "+" : " ", it_.ref, " ", it_.title), liw)
            # Weight says whether it has been read, which is the one thing
            # about a row worth knowing before opening it and the one thing the
            # list never said: unread is bold, read is plain. Dim is left to the
            # import row, which is the only row that is not an item - two
            # thousand dimmed rows were what made the unread ones invisible
            # among them. In the quiet list the weight is the theme's
            # `quiet_bold`, which may be nothing: see `quietrow`. A row whose
            # agent rang with nobody looking is unread and in `rang` as well,
            # the colour of its `T`'s badge in the checkout picker: the one
            # unread row that is somebody waiting on you. Kept in the quiet
            # list too, since the list is quiet exactly while you are in some
            # other pane and not hearing it.
            styled = faced(faced(txt, it_.url in marks.rang ? THEME.rang : Face()),
                           seen_of(it_, marks) === :unread ?
                               (quiet ? THEME.quiet_bold : THEME.bold) : Face())
            (isempty(st.search) || st.searchin !== :list) ||
                (styled = hlspan(styled, findhits(String(styled), st.search),
                                 THEME.match_bg))
            # The cursor is a background now rather than a weight, since weight
            # is spoken for: bright-white bold among bold rows is not a cursor
            # anybody can find. Laid over the padded row the way the detail
            # pane's is, and by the same `hlrow`, which lays the background
            # under everything the row carries - a search hit keeps its own.
            on && (styled = hlrow(rowpad(styled, liw), THEME.cursor_bg))
            # The whole list quieter while the keys are on the other side, on
            # top of everything else: the lit border says which side has them,
            # and a screen of equal weight had to be read for it.
            quiet && (styled = quietrow(styled))
            push!(lrows, Row(i, true, styled,
                             string(it_.ref, " ", it_.title), 0))
        end
        # One row further down than the selection, since the import row is at
        # the front of the drawn list and in front of index 1.
        lvis, st.top = window(lrows, st.sel + 1, st.top, lh - 2)
        ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    end

    left = bordered([r.text for r in lvis], lw, lh, ltitle;
                    focused = st.focus === :list)
    L.mh > 0 && append!(left, footer!(bordered(first(mlines, L.mh - 2), lw, L.mh,
                                   it === nothing ? "meta" : string("meta  ", it.ref);
                                   focused = false), meta_stamp(st, it, at)))
    right = detail_pane(st, it, rw, rh, st.focus === :detail, at)

    # The footnote rows link themselves, in `nodelines`. What is left for
    # `linkify` is a url *written in the prose* - which happens when a comment
    # links a url to itself, the shape GitHub's own autolinking produces - and
    # there the text on screen is the whole url. So the display form is the url,
    # and no elided string is ever matched against anything.
    links = Pair{String,String}[]
    for n in st.nodes, u in n.urls
        push!(links, u => u)
    end

    # Split the way the keys themselves divide: what shows you something, then
    # what changes something. The status keeps the bottom row, where it has
    # always been and where the eye already goes for it.
    # Worst-first is the wrong order for a line that gets cut on a narrow
    # screen: `j/k` is the key nobody needs told, so the navigation runs at
    # the end and what is worth reading is at the front. `?` is at the very
    # front, because it is the key that names the rest, and it took `g/G`'s
    # place under the rule below: the help says it. `q`, `tab`, `l` and
    # `⇧j/k` are not here for the same reason - the help says them, `l`
    # is offered on the failing job's own row, and the columns were wanted.
    # What is applied is on the title bar, and was here too. One copy: the axes
    # are sets now, so the summary is as long as the selection rather than one
    # word, and this row was already being cut at 200 columns with `M` on it.
    keys1 = string("? help \u00b7 f filters \u00b7 \' views \u00b7 w sort \u00b7 ",
                   "d diff \u00b7 h thread \u00b7 p pushed \u00b7 c checks \u00b7 [/] context \u00b7 ",
                   "y copy \u00b7 / search/jump \u00b7 ",
                   # What `\u21b5` does depends on where the cursor is, and a
                   # footer that names only one of the three is why the row at
                   # the top of the list needed explaining twice.
                   st.focus === :detail ? "\u21b5 fold \u00b7 " :
                   st.sel == 0 ? "\u21b5 import \u00b7 " : "\u21b5 read \u00b7 ",
                   "n/N node \u00b7 ",
                   "j/k line \u00b7 space/b page")
    b = st.batch
    nb = b === nothing ? "" : string("(", b.n, ")")
    # `I import` is not in here, and is the only key that is not: its control is
    # the row at the top of the list, permanently on screen and saying what it
    # does. A second copy of it costs the row that the keys which have no such
    # row are competing for.
    keys2 = string("C comment \u00b7 A review", nb, " \u00b7 M merge \u00b7 L labels \u00b7 e done/not done \u00b7 u update all \u00b7 R reload \u00b7 s snooze \u00b7 ",
                   "z undo", isempty(st.undos) ? "" : string("(", length(st.undos), ")"),
                   " \u00b7 v note \u00b7 x archive \u00b7 o code \u00b7 t term \u00b7 T agent \u00b7 \" worktrees \u00b7 ",
                   # With `M` on it this row was 194 columns and everything
                   # past `t term` was cut below 160. Both rows are over
                   # budget, so the next key added has to take somebody's place
                   # rather than be appended - and what it should take is
                   # decided by row one's rule, which is that the keys nobody
                   # needs told run at the end.
                   "m mouse ", st.mouse ? "on" : "off")
    # A logged error, or a theme that did not load, outranks both: it is
    # standing, and stays until the file naming it is deleted or the line is
    # fixed.
    # `oneline` is not belt and braces: a status set from an exception carries
    # whatever newlines `showerror` put in it, and one of those in a one-row
    # field makes the frame taller than the screen.
    note = standing_note(at, st.failing)
    msg = oneline(isempty(note) ? st.status : note)
    foot1 = faced(rowfit(keys1, w), THEME.dim)
    foot2 = if st.typing
        # The query line, with the terminal's cursor in it: `viewcursor` puts
        # it at the column the field says, on the row the footer lands on.
        #
        # The count of what is folded away belongs *here*, while there is still
        # a decision to make about it. After enter it is always zero, because
        # committing is what opens them.
        found = st.searchin === :detail ? length(match_rows(st, riw)) : length(st.items)
        unit = st.searchin === :detail ? (found == 1 ? " match" : " matches") :
                                         (found == 1 ? " item" : " items")
        tally = isempty(st.search) ?
                (st.searchin === :detail && !isempty(st.lastsearch) ?
                     string("↑ /", st.lastsearch, " · ") : "") :
                string(found, unit,
                       st.hidden > 0 ? string(" (+", st.hidden, " folded)") : "", " · ")
        trail = string("   ", tally, st.hidden > 0 ? "↵ opens them" : "↵ keep", " · esc drop")
        # The field scrolls sideways rather than being cut at the screen's
        # edge, which is where the cursor is while typing - so it gets what the
        # tally leaves, and never so little that the query is what is lost.
        fw = max(w - 1 - textwidth(trail), min(w - 1, 20))
        f, fc = TermInput.field(TermInput.text(st.query), TermInput.column(st.query), fw)
        qcol = 1 + fc
        faced("/", THEME.bold) * f * faced(trail, THEME.dim)
    elseif !isempty(st.search) && isempty(msg)
        # Only when there is nothing to say. A live search is *standing*
        # information - it is re-derived every frame and the query is on screen
        # anyway - while a status is something that just happened and will not
        # happen again. Held the other way round, an answer to a key press
        # ("`claude` is not on PATH") never appeared at all, and the key looked
        # broken rather than refused.
        nmatch = st.searchin === :detail ? length(match_rows(st, riw)) : length(st.items)
        faced("/" * st.search, THEME.bold) *
            faced(string("  ", nmatch,
                         st.searchin === :detail ?
                             string(nmatch == 1 ? " match · " : " matches · n/N steps them · ") :
                             (nmatch == 1 ? " item · " : " items · "),
                         "/ to search again"), THEME.dim)
    else
        faced(rowfit(isempty(msg) ? keys2 : msg, w), THEME.dim)
    end
    foot2 = faced(rowfit(foot2, w), THEME.dim)
    # Padded to the screen as well as laid out to it: the columns add up to `w`
    # by construction, and this is what keeps a frame the width of the terminal
    # if they ever stop.
    body = Styled[rowpad(r, w) for r in
                  (L.side ? [left[i] * right[i] for i in 1:min(length(left), length(right))] :
                            vcat(left, right))]
    # Row 1 is a title bar so that selecting the top line in tmux - which
    # scrolls the pane to make room for its own status line - never lands on
    # content. Everything real starts at row 2.
    bar = if it === nothing
        " worklog  " * faced(string(length(st.items), " items"), THEME.dim)
    else
        # The kind between the number and the title, as on the pane's own
        # header: it is the one thing about the item the number does not say.
        " " * faced(osc8(weblink(it), it.ref), THEME.bold) * "  " * kind_phrase(it) * "  " *
            faced(osc8(weblink(it), it.title), THEME.bold) * "  " *
            faced(string("[", filter_summary(st.filters, st.sort), "]"), THEME.dim)
    end
    # The last refresh at the right-hand end, and the running one: a fact
    # about the whole list that stands, where the status row is one line the
    # next key replaces. Not at the title's expense - on a narrow screen the
    # stamp goes before the title does.
    tail = refresh_stamp(st, at)
    room = w - rowwidth(tail)
    room < 40 && (tail = row(""); room = w)
    # Clamp to the terminal rather than trusting the arithmetic: on a very short
    # terminal the pane minimums add up to more than there is room for, and a
    # frame taller than the screen scrolls the title bar off the top.
    all_ = vcat(Styled[rowpad(rowfit(bar, room), room) * tail], body,
                Styled[rowpad(foot1, w), rowpad(foot2, w)])
    qcol > 0 && length(all_) <= h && (st.caret = (length(all_), qcol))
    while length(all_) < h
        push!(all_, row(" "^w))
    end
    Styled[linkify(r, links) for r in all_[1:h]]
end

"""
    linkify(row, links) -> Styled

Make a url *written in the prose* a hyperlink, so it can be followed rather
than only read.

The footnote rows under a comment are not this function's work: they are
built in `nodelines`, which holds the url and the text standing for it at the
same moment and links one to the other by identity. Matching text is for what
only the finished frame has, which is the body of a comment that linked a url
to itself - the shape GitHub's own autolinking produces - where the url is both
the target and the words. So a display form here is the url itself, and no
elided string is ever matched against anything.

Done last, on each finished row, where a url wrapped across two rows is not
one run of text and so is not found; it was not found before this either.

A link is an annotation over the text and not bytes in it, so nothing here can
write one inside another: every comment header is a link to its own permalink,
and a url written in one comment is very often the permalink of another -
nanosoldier replies with a link to the `runbenchmarks()` comment that asked.
When links were escapes, a second `\\e]8;;` inside the first terminated it early
and printed the rest as characters nothing had measured - a row 224 columns
wide in a 150-column terminal. Here a match that is already inside a link is
left alone, and so is one inside a pane's verbatim row, which is its child's.

The links are one per url per *node*, so a url cited in four comments arrives
four times; the list is deduplicated and taken longest first, so a url that is
the head of another - an issue, and a comment on that issue - cannot take the
match from it.
"""
function linkify(r::AbstractString, links)
    x = row(r)
    isempty(links) && return x
    str = x.string
    targets = unique!(sort!([String(d) => String(u) for (d, u) in links if !isempty(d)];
                            by = p -> (-length(first(p)), first(p))))
    for (d, u) in targets
        occursin(d, str) || continue
        at = 1
        while (f = findnext(d, str, at)) !== nothing
            lo, hi = first(f), last(f) + ncodeunits(str[last(f)]) - 1
            taken = any(a -> (a.label === :link || a.label === :verbatim) &&
                             !isempty(intersect(a.region, lo:hi)), anns(x))
            taken || (x = linkrange(x, lo:hi, u))
            at = hi + 1
        end
    end
    x
end
