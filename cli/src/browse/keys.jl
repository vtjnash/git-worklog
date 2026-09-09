
# --- interaction -----------------------------------------------------------

"Node index owning the cursor row, so folding works from anywhere in a body."
function curnode(st::BState, w::Int)
    rs = rows(st.nodes, w)
    isempty(rs) && return 0
    rs[clamp(st.nrow, 1, length(rs))].node
end

"Row index of node `i`'s header - where the cursor lands after folding."
function headerrow(st::BState, i::Int, w::Int)
    rs = rows(st.nodes, w)
    j = findfirst(r -> r.node == i && r.header && r.part == 0, rs)
    j === nothing ? 1 : j
end

"Move the cursor to the next (`+1`) or previous (`-1`) node header."
function jumpnode(st::BState, dir::Int, w::Int)
    rs = rows(st.nodes, w)
    isempty(rs) && return
    hdrs = [j for j in eachindex(rs) if rs[j].header && rs[j].part == 0]
    isempty(hdrs) && return
    st.nrow = if dir > 0
        something(findfirst(>(st.nrow), hdrs), length(hdrs)) |> i -> hdrs[i]
    else
        something(findlast(<(st.nrow), hdrs), 1) |> i -> hdrs[i]
    end
end

render(st::BState, w::Int, h::Int) = render_frame(st, w, h)

"""Adopt whatever woke us - a finished fetch, or a file somebody else wrote.

Bitwise `|` and not `||`: each of these has to run whichever way the ones before
it answered, and what comes back is whether the frame is now wrong.
"""
onwake!(st::BState) = collect_pending!(st) | collect_meta!(st) | due_refresh!(st) |
                      reload_data!(st)

"""
    browse(items, title, unread)

Open the browser under a controller that owns stdin for the whole run.
"""
function browse(items::Vector{Item}, title::AbstractString, unread = Set{String}())
    isempty(items) && (println("\n  nothing in ", title, "\n"); return 0)
    st = BState(collect(items), String(title), unread)
    ctrl = Controller()
    st.wake = () -> wake!(ctrl)
    watch_data!(st)
    run!(ctrl, st)
end

"""The url the cursor is on, or `""` - which is also what the import row is."""
curl(st::BState) = (isempty(st.items) || st.sel == 0) ? "" : st.items[st.sel].url

"""
    handle!(st, k, ctrl) -> Symbol

One keystroke, with the one question that has to be asked between keys: whether
a draft review has just been walked away from. It goes here rather than in the
dozen places that can move the cursor - `j`, a click, a search jump, going to an
item from the worktree list - because the condition is not "which key was
pressed", it is "the selection changed and something was left behind".

`q` asks whether it meant it, and asks about a draft in the same breath rather
than in a question of its own. The answer comes back through the view, so this
returns `:ok` and the quitting is done there; the controller redraws after every
key.
"""
function handle!(st::BState, k::Int, ctrl::Controller, at::DateTime = utcnow())
    before = curl(st)
    r = handle_key!(st, k, ctrl, at)
    r === :quit && (quit_prompt!(st, ctrl); return :ok)
    if curl(st) != before
        rearm_batch!(st, before)
        batch_prompt!(st, ctrl, curl(st))
    end
    r
end

"""Ask before quitting, because `q` ends the whole program from one key press.

Nothing written is lost - notes, snoozes, the archive and the read marks all go
to disk as they are made, and a draft review lives on GitHub. What a stray `q`
costs is the session it was typed into: the fetch that filled the list, where
you were in it, and the panes on the screen. That is small enough that a modal
would be an imposition every time and large enough to be worth one key.

The confirming key is deliberately not `q` again, which a doubled keystroke
answers on its own, and not `↵`, which is the reflex a dialog appearing
produces.

This is the *only* question `q` asks. A draft review is the one other thing that
wants saying before the program goes away, so it says it here, in a row of this
box and as the `A` that submits it everywhere else - not as a second dialog in
front of this one. That is what it used to be, and it could not be got past:
dismissing it left the draft exactly as it was, so the next `q` asked again and
quitting was unreachable while a draft was held.

Both facts are gathered rather than assumed - the sessions counted, the draft
looked up - because "these carry on without you" and "this one does not" are the
two things about leaving worth knowing, and a screen showing either does not say
it.
"""
function quit_prompt!(st::BState, ctrl::Controller)
    n = length(mux_sessions())
    a = draft_answer(st, ctrl)
    answers = Pair{String,Any}["yY" => () -> :quit]
    a === nothing || push!(answers, last(a))
    notes = String[]
    a === nothing || push!(notes, first(a))
    n == 0 || push!(notes, string(n, n == 1 ? " session keeps" : " sessions keep",
                                  " running \u00b7 quitting does not end them"))
    # Only when there was nothing else to say. A box that says a draft is unsent
    # and in the next breath that nothing is left running is contradicting
    # itself over two different meanings of the word.
    isempty(notes) && push!(notes, "nothing here is left running")
    push_view!(ctrl, ConfirmView("Quit", notes, answers;
        hint = a === nothing ? "y quits \u00b7 any other key stays" :
               "y quits and leaves the draft \u00b7 A submits it first \u00b7 any other key stays"))
end

"""Leaving the draft's item again makes it a question again.

The draft is durable and this program is the only thing that keeps mentioning
it, so "leave it" has to mean *not now* rather than *never ask again*. What says
you are still working on it is having gone back to it - so the question is
re-armed by walking off it, and moving between two other items asks nothing.
"""
function rearm_batch!(st::BState, before::AbstractString)
    b = st.batch
    (b === nothing || !get(b, :asked, false) || b.url != before) && return false
    st.batch = mkbatch(b.url, b.ref, b.review, b.n)
    true
end

function handle_key!(st::BState, k::Int, ctrl::Controller, at::DateTime = utcnow())
    h, w = displaysize(stdout)
    load_nodes!(st)
    load_meta!(st)
    L = layout(w, h, st.nmeta)
    # From the last frame, not from `layout`: those agree in the browser and do
    # not when a hosted pane has taken half the screen. `lpage` is the item
    # list's and stays `layout`'s, since the list is not drawn beside a pane.
    iw = st.diw > 0 ? st.diw : L.riw
    page = st.dpage > 0 ? st.dpage : L.page
    lpage = L.lpage
    # The shifted arrows extend the selection, and the detail pane is the only
    # thing here that has one. In the two lists they are the arrows they are
    # drawn on rather than keys that do nothing.
    st.focus === :detail && st.lmode !== :filters || (k = unshift(k))
    # While the query is being typed it takes every key, so that `/julia` is a
    # search and not four commands. Enter keeps it, escape drops it.
    if st.typing
        if k in (13, 10)
            commit_search!(st, iw)
        elseif k == 27
            st.search = ""; st.typing = false
            st.searchin === :list && refilter!(st)
        elseif k in (127, 8)
            isempty(st.search) || (st.search = st.search[1:prevind(st.search, end)];
                                   research!(st, iw))
        elseif k == C_U
            st.search = ""; research!(st, iw)
        elseif k in (C_W, K_WORD_BACK)
            st.search = String(first(st.search,
                                     word_start(st.search, length(st.search) + 1) - 1))
            research!(st, iw)
        elseif printable(k)
            st.search *= keychar(k); research!(st, iw)
        end
        return :ok
    end
    if k == Int('/')
        st.typing = true
        st.search = ""
        st.searchin = st.focus === :detail ? :detail : :list
        st.hidden = 0
        st.searchin === :list && refilter!(st)
        return :ok
    elseif k == Int('q')
        return :quit          # Escape no longer quits: it heads key sequences
    elseif k == Int('\t') || k == K_STAB
        st.focus = st.focus === :list ? :detail : :list
    elseif k == Int('f')
        st.lmode = st.lmode === :filters ? :items : :filters
        st.focus = :list
    elseif k == Int('m')
        # Handled up here rather than with the other actions so it still works
        # in the filter pane - a terminal that cannot report the mouse has to be
        # escapable from wherever you happen to be standing.
        st.mouse = mouse!(ctrl, !ctrl.mouse)
        clearsel!(st)
        st.status = st.mouse ? "mouse on — drag to select, y to copy" :
                               "mouse off — the terminal's own selection is back"
    elseif st.focus === :list && st.lmode === :filters
        frows = filter_rows(st)
        nf = length(frows)
        if k in (Int('j'), K_DOWN);     st.frow = min(nf, st.frow + 1)
        elseif k in (Int(' '), 6, K_PGDN); st.frow = min(nf, st.frow + lpage)
        elseif k in (Int('k'), K_UP);   st.frow = max(1, st.frow - 1)
        # The same four the item list has. The filter list is long enough to
        # need them - it is every bucket, every repo and every label seen -
        # and `nf` is its bound the way `length(st.items)` is that list's.
        elseif k in (Int('b'), 2, K_PGUP); st.frow = max(1, st.frow - lpage)
        elseif k in (Int('g'), K_HOME); st.frow = 1
        elseif k in (Int('G'), K_END);  st.frow = nf
        elseif k in (Int('n'), Int('N'))
            g = filter_groups(frows)
            if !isempty(g)
                st.frow = k == Int('n') ?
                          g[something(findfirst(>(st.frow), g), length(g))] :
                          g[something(findlast(<(st.frow), g), 1)]
            end
        elseif k in (13, 10);           toggle_filter!(st, ctrl)
        elseif k == Int('c')
            st.prev = st.filters        # clearing is a jump like any other
            st.filters = Filters(); refilter!(st; keeprow = false)
        end
    elseif st.focus === :list
        # Zero is the import row, which is why the floor here is not one. `g`
        # stops at the first item rather than on it: the top of the list is
        # where the work is, and the row above the top is asked for by moving
        # up off it.
        if k in (Int('j'), K_DOWN);          st.sel = min(length(st.items), st.sel + 1)
        elseif k in (Int('k'), K_UP);        st.sel = max(0, st.sel - 1)
        elseif k in (Int(' '), 6, K_PGDN);   st.sel = min(length(st.items), st.sel + lpage)
        elseif k in (Int('b'), 2, K_PGUP);   st.sel = max(0, st.sel - lpage)
        elseif k in (Int('g'), K_HOME);      st.sel = min(1, length(st.items))
        elseif k in (Int('G'), K_END);       st.sel = length(st.items)
        elseif k in (13, 10)
            # The row that is not an item does the one thing it is for; every
            # other row hands the keys to the pane beside it.
            st.sel == 0 ? import_action(st, ctrl, at) : (st.focus = :detail)
        end
    else
        n = length(rows(st.nodes, iw))
        # Moving the cursor drops the selection. Listed rather than blanket, so
        # that `y` - which falls through this branch to the actions below - can
        # still see what is selected.
        k in (Int('j'), K_DOWN, Int('k'), K_UP, Int(' '), 6, K_PGDN, Int('b'), 2,
              K_PGUP, Int('g'), K_HOME, Int('G'), K_END, Int('n'), Int('N'),
              13, 10) && clearsel!(st)
        if k in (Int('J'), K_SDOWN, Int('K'), K_SUP)
            # The keyboard half of a drag: the anchor is wherever the cursor
            # already was, and every press moves the far end of the range. Not
            # in the list above, so these are the four keys in this pane that
            # move the cursor and keep what is selected - which is the whole of
            # what they are for.
            #
            # Two spellings because both are reached for: the arrows are what a
            # selection is extended with everywhere else, and `J`/`K` are what
            # `j`/`k` are already under the hand. They are also the two capitals
            # in the program that change nothing on GitHub, which the rule can
            # afford: a selection is a way of pointing at rows, and `y` and `c`
            # are what act on it.
            st.anchor == 0 && (st.anchor = st.nrow)
            st.nrow = clamp(st.nrow + (k in (Int('J'), K_SDOWN) ? 1 : -1), 1, n)
            st.sela, st.selb = st.anchor, st.nrow
            st.status = string(abs(st.selb - st.sela) + 1, " rows selected — y to copy")
        elseif k in (Int('j'), K_DOWN);      st.nrow = min(n, st.nrow + 1)
        elseif k in (Int('k'), K_UP);        st.nrow = max(1, st.nrow - 1)
        elseif k in (Int(' '), 6, K_PGDN);   st.nrow = min(n, st.nrow + page)
        elseif k in (Int('b'), 2, K_PGUP);   st.nrow = max(1, st.nrow - page)
        elseif k in (Int('g'), K_HOME);      st.nrow = 1
        elseif k in (Int('G'), K_END);       st.nrow = n
        elseif k == Int('n')
            (isempty(st.search) || st.searchin !== :detail) ? jumpnode(st, 1, iw) :
                                                              jumpmatch(st, 1, iw)
        elseif k == Int('N')
            (isempty(st.search) || st.searchin !== :detail) ? jumpnode(st, -1, iw) :
                                                              jumpmatch(st, -1, iw)
        elseif k in (13, 10)
            i = curnode(st, iw)
            # Prose that carries on after a block has no fold of its own, so
            # `↵` inside it folds the comment it is part of, which is the thing
            # the reader is pointing at.
            i > 0 && isbare(st.nodes[i]) && (i = parentnode(st.nodes, i))
            if i > 0
                st.nodes[i].open = !st.nodes[i].open
                st.nrow = headerrow(st, i, iw)
            end
        end
    end
    # Neither of these is about the selected item, so both sit above the guard
    # that wants one - the same reason `z` and `i` do.
    if k == Int('\'') && st.lmode !== :filters
        view_action(st, ctrl)
        return :ok
    elseif k == Int('`') && st.lmode !== :filters
        if st.prev === nothing
            st.status = "no filter to go back to"
        else
            was = st.filters
            st.filters = st.prev
            st.prev = was
            refilter!(st; keeprow = false)
            # After the loads, not before: `load_nodes!` writes "loading …" over
            # whatever is there, and a message about a jump the user just made
            # is exactly what it would write over.
            load_nodes!(st); load_meta!(st)
            st.status = string("back to [", filter_summary(st.filters, st.sort), "]")
            return :ok
        end
        load_nodes!(st); load_meta!(st)
        return :ok
    end
    # Above the guard as well, and an empty list is exactly when `z` is wanted:
    # archiving or snoozing the last row of a lane empties it, and the way back
    # used to be swallowed along with every per-item key.
    if k == Int('z') && st.lmode !== :filters
        st.status = undo!(st)
        load_nodes!(st); load_meta!(st)
        return :ok
    end
    # Above the guard for the same reason `z` is: an empty list is exactly when
    # the dashboard most wants rebuilding, and "nothing is selected" is not an
    # answer to "fetch everything again".
    if k == Int('u') && st.lmode !== :filters
        st.status = refresh_all!(st)
        return :ok
    end
    # For the same reason: `i` is about something that is *not* here yet, so
    # wanting it and having nothing selected are the same situation. A list
    # filtered down to nothing, or a dashboard whose lanes returned nothing, is
    # exactly where the first import gets made.
    if k == Int('i') && st.lmode !== :filters
        import_action(st, ctrl, at)
        return :ok
    end
    # `st.sel == 0` is the import row, which is not an item and answers to none
    # of the keys below. The pane beside it still has to catch up with whatever
    # the cursor has just moved onto, which for that row is its own text - and
    # the per-item path below does this at its end for the same reason.
    if st.lmode === :filters || st.sel == 0 || isempty(st.items)
        load_nodes!(st)
        return :ok
    end
    it = st.items[clamp(st.sel, 1, length(st.items))]

    # Context expansion and the editor both need a local checkout. Ask for it the
    # first time it is actually needed, rather than as up-front configuration.
    needs_repo(action) = push_view!(ctrl, PromptView(
        "Local checkout for $(it.repo)",
        "Path to a clone or worktree. It is resolved to the main .git, so any " *
        "worktree of the repository will do.",
        p -> begin
            try
                r = register_repo!(it.repo, p)
                st.status = string("pinned ", it.repo, " -> ", r.path,
                                   r.matched ? "" : "  (remote does not match)")
                action()
            catch e
                st.status = "could not pin: " * first(sprint(showerror, e), 80)
            end
        end))

    if k in (Int('['), Int(']')) && st.mode === :diff
        i = curnode(st, iw)
        if i > 0
            dir = k == Int('[') ? -1 : 1
            retry_expand = () -> begin
                rr = expand_hunk!(st.nodes[i], it, dir)
                st.status = rr isa String ? rr : ""
            end
            r = expand_hunk!(st.nodes[i], it, dir)
            r === :needs_repo ? needs_repo(retry_expand) :
                (st.status = r isa String ? r : "")
        end
        return :ok
    elseif k == Int('e')
        retry_edit = () -> (rr = open_editor(it); st.status = rr isa String ? rr : "")
        r = open_editor(it)
        r === :needs_repo ? needs_repo(retry_edit) : (st.status = r isa String ? r : "")
        return :ok
    elseif k == Int('t')
        # `say` and not the return value alone: `t` may have to ask which
        # checkout, and the answer to that arrives long after this call has
        # returned. Both routes report through the same line.
        say = rr -> (st.status = rr isa String ? rr : "")
        retry_term = () -> say(open_terminal(it, ctrl, say))
        r = open_terminal(it, ctrl, say)
        r === :needs_repo ? needs_repo(retry_term) : say(r)
        return :ok
    elseif k == Int('T')
        say = rr -> (st.status = rr isa String ? rr : "")
        retry_agent = () -> say(open_agent(it, ctrl, say))
        r = open_agent(it, ctrl, say)
        r === :needs_repo ? needs_repo(retry_agent) : say(r)
        return :ok
    elseif k == Int('v')
        st.status = edit_note(st, it, ctrl)
        return :ok
    elseif k == Int('x')
        # Its own return, because archiving refilters and the selection can move
        # - and `load_nodes!` would put "loading …" over what this has to say.
        msg = archive!(st, it, at)
        load_nodes!(st); load_meta!(st)
        st.status = msg
        return :ok
    elseif k == Int('w')
        i = findfirst(x -> x[1] === st.sort, SORTS)
        st.sort = SORTS[mod1(something(i, 1) + 1, length(SORTS))][1]
        refilter!(st)
        st.status = string("sorted ", last(SORTS[findfirst(x -> x[1] === st.sort, SORTS)]))
        load_nodes!(st); load_meta!(st)
        return :ok
    elseif k == Int('"')
        # Not per-item: a worktree outlives whatever was opened on it, and this
        # is the only place every one of them - and every session in them - can
        # be seen at once.
        # Every item, not the filtered ones: a row should not lose the pull
        # request it belongs to because a filter is hiding it elsewhere.
        push_place!(ctrl, worktree_view(st.all;
                                        source = () -> st.all,
                                        wake = () -> wake!(ctrl),
                                        onitem = x -> select_item!(st, x),
                                        onadopt = (repo, br, take) ->
                                            take ? adopt!(st, repo, br, at) :
                                                   unadopt!(st, repo, br, at)))
        return :ok
    end

    # Lowercase shows you something, uppercase changes something. `c` was the
    # composer and `C` the checks pane, which had it exactly backwards.
    if k == Int('d');     st.mode = :diff
    elseif k == Int('o'); st.mode = :comments
    elseif k == Int('c'); st.mode = :checks
    elseif k == Int('y')
        # OSC 52, so the copy works over ssh and through tmux. Also shown in the
        # footer, since OSC 52 is disabled by default in some terminals.
        txt = selection_text(st, iw)
        note = if isempty(txt)
            i = curnode(st, iw)
            txt = i > 0 ? get(st.nodes[i].meta, "url", it.url) : it.url
        else
            string(count(==('\n'), txt) + 1, " lines")
        end
        clip(txt)
        st.status = string("copied ", note)
    elseif k == Int('l')
        i = curnode(st, iw)
        if i > 0 && haskey(st.nodes[i].meta, "bk")
            n = st.nodes[i]
            n.raw = bk_log(n.meta["bk"], n.meta["job"])
            n.cw = -1; n.open = true
            st.status = "log fetched"
        end
    elseif k == Int('C'); compose_action(st, ctrl, it, iw)
    elseif k == Int('A'); review_action(st, ctrl, it)
    elseif k == Int('L'); label_action(st, ctrl, it)
    elseif k == Int('r')
        # A toggle: on something unread it marks it read, on something read it
        # puts it back. `u` used to be the unconditional half of this and is
        # now the whole refresh - two presses of a toggle reach either state,
        # and nothing else in the program could ask for a refresh at all.
        was = it.url in st.unread
        seen = was
        # Read up to when the thread was *fetched*, not to now. A comment that
        # arrived while you were reading - or while you were away from a pane
        # loaded ten minutes ago - was never in front of you, and stamping now
        # would mark it seen. Not the newest comment's own time either: an item
        # whose `updated_at` moved for a label edit would then be permanently
        # unread, because marking it read could never catch up to it.
        fi = findfirst(n -> haskey(n.meta, "fetched"), st.nodes)
        prev = Events.read_at(it.url)
        if seen
            Events.set_read(it.url,
                            fi === nothing ? stamp(at) : st.nodes[fi].meta["fetched"])
        else
            Events.mark_unread([it.url])
        end
        seen ? delete!(st.unread, it.url) : push!(st.unread, it.url)
        push!(st.undos, Undo(string(seen ? "read " : "unread ", it.ref), () -> begin
            Events.set_read(it.url, prev)
            was ? push!(st.unread, it.url) : delete!(st.unread, it.url)
        end))
        # The unread lane is membership in that set, so it has to be rebuilt for
        # the row to leave or arrive.
        st.filters.state === :unread && refilter!(st)
        st.status = seen ? "marked read" : "marked unread"
    elseif k == Int('s')
        snooze_action(st, ctrl, it, at)
    elseif k == Int('R')
        # Its own return: `load_nodes!` below would find the key unchanged and
        # do nothing, but `st.status` is what this key is for and the message
        # should not be at the mercy of what runs after it.
        st.status = refresh_item!(st)
        return :ok
    end
    load_nodes!(st)
    load_meta!(st)
    :ok
end
