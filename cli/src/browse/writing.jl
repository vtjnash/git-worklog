
# --- writing ----------------------------------------------------------------

"""
    hunk_line_at(st, i, w) -> (line, side) or nothing

The source line under the cursor inside hunk node `i`.

The cursor is a display row and the hunk is diff lines, so the rows are counted
back to a logical line first - `part == 0` marks the first row of each - and the
hunk is then walked from its own top, which knows where it starts and how far
`[`/`]` has widened it.

The old-side number is only right while expansion has added pure context, which
is all it ever adds; a hunk expanded across a deletion would drift.
"""
function hunk_line_at(st::BState, i::Int, w::Int, row::Int = st.nrow)
    n = st.nodes[i]
    haskey(n.meta, "start") || return nothing
    rs = rows(st.nodes, w)
    idx = 0
    for j in 1:min(row, length(rs))
        r = rs[j]
        (r.node == i && !r.header && r.part == 0) && (idx += 1)
    end
    idx == 0 && return nothing
    lines = split(n.raw, "\n")
    idx > length(lines) && return nothing
    up = get(n.meta, "up", 0)
    newno = n.meta["start"] - up
    oldno = get(n.meta, "ostart", n.meta["start"]) - up
    for (k, l) in enumerate(lines)
        del, add = startswith(l, "-"), startswith(l, "+")
        k == idx && return del ? (oldno, "LEFT") : (newno, "RIGHT")
        del ? (oldno += 1) : add ? (newno += 1) : (oldno += 1; newno += 1)
    end
    nothing
end

"""The rows of hunk `i` a comment is about: the selection, or the cursor row.

Dragging over a hunk already selects rows - it is how `y` copies several - so a
range comment needs no new gesture, only for `c` to look at what is selected
instead of at where the cursor happens to be. Rows outside the hunk are clipped
rather than refused: a selection that runs off the end of a hunk still says
which lines of it were meant.
"""
function hunk_rows(st::BState, i::Int, w::Int)
    sr = selrange(st)
    sr === nothing && return (st.nrow, st.nrow)
    rs = rows(st.nodes, w)
    lo = hi = 0
    for j in max(1, sr[1]):min(sr[2], length(rs))
        rs[j].node == i && !rs[j].header || continue
        lo == 0 && (lo = j)
        hi = j
    end
    lo == 0 ? (st.nrow, st.nrow) : (lo, hi)
end

"""The lines of the hunk between two display rows, as they would be replaced.

The text of a suggestion, in other words: what GitHub prefills its box with when
you press the button. Deletions are left out - a suggestion replaces what is on
the side being commented on, and a deleted line is not there any more - and the
diff marker goes with them, since it is a column of the display and not of the
file.
"""
function hunk_text(st::BState, i::Int, w::Int, lo::Int, hi::Int)
    rs = rows(st.nodes, w)
    out = String[]
    for j in max(1, lo):min(hi, length(rs))
        r = rs[j]
        (r.node == i && !r.header && r.part == 0) || continue
        src = r.src
        isempty(src) && (push!(out, ""); continue)
        startswith(src, "-") && continue
        push!(out, String(SubString(src, nextind(src, 1))))
    end
    out
end

"""What `c` writes to, given where the cursor is standing.

One key rather than three, because the answer is never ambiguous: on a review
comment it is a reply, on a hunk it is those lines, and anywhere else it is the
item itself.

A hunk answers with a *range*, which is one line long unless rows are selected.
GitHub takes `start_line`/`line` for that, and the range is what makes a
suggestion worth anything: a replacement for one line is a note, and a
replacement for the five you highlighted is a patch.
"""
function compose_target(st::BState, iw::Int)
    i = curnode(st, iw)
    i == 0 && return (:item, nothing)
    n = st.nodes[i]
    cid = get(n.meta, "comment_id", nothing)
    cid === nothing || return (:reply, cid)
    if st.mode === :diff && haskey(n.meta, "file")
        (lo, hi) = hunk_rows(st, i, iw)
        a = hunk_line_at(st, i, iw, lo)
        b = hunk_line_at(st, i, iw, hi)
        a === nothing && (a = b)
        b === nothing && (b = a)
        if b !== nothing
            # The end of the range is what GitHub calls the line; the start is
            # only sent when there is one, and a range across both sides of the
            # diff is not a thing it accepts.
            first_ = (a !== nothing && a[2] == b[2] && a[1] < b[1]) ? a[1] : nothing
            return (:line, (file = n.meta["file"], line = b[1], side = b[2],
                            start = first_,
                            text = first_ === nothing ? String[] :
                                   hunk_text(st, i, iw, lo, hi)))
        end
    end
    (:item, nothing)
end

"""Put the cursor on this item, or say why it cannot go there.

Returns `""` on success, which is what tells the worktree view it may close.
An item the filter is hiding is reached by clearing the filter and saying so -
see below - and one this dashboard does not carry at all is what this reports
on instead.
"""
function select_item!(st::BState, it::Item)
    i = findfirst(x -> x.url == it.url, st.items)
    cleared = false
    if i === nothing
        findfirst(x -> x.url == it.url, st.all) === nothing &&
            return string(it.ref, " is not in this dashboard")
        # Asking to go to an item is asking to *see* it, and a filter that hides
        # it is the thing in the way rather than the answer. Told to go to the
        # pull request a worktree belongs to, "it is filtered out" is a refusal
        # to do the one thing that was asked.
        #
        # Cleared rather than widened by whichever axis is hiding it: which one
        # that is is not a question anybody wants answered, and `\`` is the way
        # back from this the same as from every other jump. `:all` and not the
        # default `:active`, because archived and snoozed work still has a
        # worktree and is exactly what you would be going to look at.
        st.prev = st.filters
        st.filters = Filters(); st.filters.state = :all
        # A list search narrows on top of the axes, so it can hide it too.
        st.searchin === :list && (st.search = "")
        refilter!(st)
        cleared = true
        i = findfirst(x -> x.url == it.url, st.items)
        i === nothing && return string(it.ref, " could not be shown")
    end
    st.sel = i
    st.focus = :list
    # `window` re-aims the scroll around the cursor, so `top` is left alone.
    # The detail pane is loaded here rather than on the next keystroke: the
    # caller is another view, so there is no `handle!` about to finish and do
    # it, and arriving on an item showing the previous one's thread is worse
    # than arriving a moment later.
    load_nodes!(st)
    load_meta!(st)
    # After the loads and not before, which is the same rule `\`` follows:
    # `load_nodes!` writes "loading …" over whatever is there, and a message
    # about the jump the user just made is exactly what it would write over.
    # It said "went to …" and nobody ever saw it.
    st.status = string("went to ", it.ref,
                       cleared ? " · cleared the filter to show it, ` goes back" : "")
    ""
end

"After a write lands, re-read the thread rather than showing the stale one."
function reread!(st::BState)
    st.loaded = ""; st.pendkey = ""
    st.metakey = ""
    load_nodes!(st); load_meta!(st)
end

"""Open the composer on whatever `c` is pointing at."""
function compose_action(st::BState, ctrl::Controller, it::Item, iw::Int)
    (kind, target) = compose_target(st, iw)
    if kind === :line && target.side == "LEFT"
        st.status = "a comment on a deleted line has to go to the old side — not wired up"
        return
    end
    suggest = ""
    (title, note, submit) = if kind === :reply
        (string("Reply · ", it.ref), "goes into this review thread",
         b -> Events.reply_review_comment(it.url, target, b))
    elseif kind === :line
        where_ = target.start === nothing ? string(target.file, ":", target.line) :
                 string(target.file, ":", target.start, "-", target.line)
        suggest = suggestion(target.text)
        held = batch_of(st, it)
        (string("Comment on ", where_),
         string(held === nothing ? "starts a review — it stays a draft on GitHub" :
                                   string("joins the draft review (", held.n, ")"),
                ", A submits it",
                isempty(suggest) ? "" : " · ^r suggests a replacement"),
         b -> begin
             (stt, err) = Events.add_review_thread(it.url, target.file, target.line,
                                                   target.side, b;
                                                   start_line = target.start)
             stt === nothing && return err
             st.batch = mkbatch(it.url, it.ref, stt.review, stt.n)
             ""
         end)
    else
        (string("Comment on ", it.ref), it.title, b -> Events.post_comment(it.url, b))
    end
    push_view!(ctrl, EditorView(title, note, b -> begin
        r = submit(b)
        st.status = !isempty(r) ? r :
                    kind === :line ? string("added to the draft review (",
                                            st.batch === nothing ? 1 : st.batch.n, ")") :
                    "posted"
        # A draft is not on the thread yet, so there is nothing to re-read for
        # it - and re-reading would cost the fetch and show the same page.
        isempty(r) && (touch!(it.url); kind === :line || reread!(st))
    end; suggest = suggest))
end

"""One draft review, as the browser holds it.

`asked` is whether leaving the item has already put the question, and it is part
of the batch rather than beside it so that nothing can hold one without the
other - the pair is what makes "leave it" mean *not now* instead of *never*.
"""
mkbatch(url, ref, review, n; asked::Bool = false) =
    (url = String(url), ref = String(ref), review = String(review),
     n = Int(n), asked = asked)

"The draft review on this item, or `nothing` - a batch belongs to one item."
batch_of(st::BState, it::Item) =
    (st.batch !== nothing && st.batch.url == it.url) ? st.batch : nothing

"""GitHub's suggestion block, filled with the lines it would replace.

The one toolbar button worth having. The others insert a couple of characters of
markdown anybody can type; this one is a *review action* - GitHub applies the
block as a commit - and it is unusable without the current text of the lines in
front of you, which is the part the editor cannot know on its own.

Empty for an empty range: a suggestion that replaces nothing is a comment.
"""
function suggestion(lines::Vector{String})
    isempty(lines) && return ""
    string("```suggestion\n", join(lines, "\n"), "\n```")
end

"""Submit a review: pick the verdict, then write the body."""
function review_action(st::BState, ctrl::Controller, it::Item)
    it.is_pr || (st.status = "not a pull request"; return)
    held = batch_of(st, it)
    opts = [("approve", "APPROVE"), ("request changes", "REQUEST_CHANGES"),
            ("comment", "COMMENT")]
    held === nothing || push!(opts, ("discard the draft and its comments", "DISCARD"))
    push_view!(ctrl, ChooseView(
        string("Review ", it.ref),
        held === nothing ? it.title :
            string("sends the draft review and its ", held.n,
                   held.n == 1 ? " comment" : " comments"),
        opts, ev -> begin
        if ev == "DISCARD"
            r = Events.discard_pending(it.url, held.review)
            st.status = isempty(r) ? string("discarded the draft on ", it.ref) : r
            isempty(r) && (st.batch = nothing)
            return
        end
        push_view!(ctrl, EditorView(
            string(replace(lowercase(ev), "_" => " "), " · ", it.ref),
            ev == "APPROVE" ? "a body is optional; ^s submits the approval" :
                              "GitHub requires a body for this",
            b -> begin
                # The draft is the review once there is one: submitting a second
                # one beside it would leave the comments unsent and unmentioned.
                r = held === nothing ? Events.submit_review(it.url, ev, b) :
                                       Events.submit_pending(it.url, held.review, ev, b)
                st.status = isempty(r) ?
                    string("submitted: ", replace(lowercase(ev), "_" => " "),
                           held === nothing ? "" :
                           string(" with ", held.n, held.n == 1 ? " comment" : " comments")) : r
                isempty(r) && (touch!(it.url); st.batch = nothing; reread!(st))
            end; allow_empty = ev == "APPROVE"))
    end))
end

"""Pick a view, or write down the one you are in.

A list rather than a key each: a binding apiece would be bindings nobody
remembers, and the next view added would have nowhere to go. `ChooseView`
narrows by typing, so a name is enough to reach one however many there are.

The last entry is the way *out* of the list of names - the current filter,
written as the TOML that would name it, for pasting into `config.toml`. The
browser does not write that file.
"""
function view_action(st::BState, ctrl::Controller)
    vs = try
        views()
    catch e
        st.status = string("could not read the views: ", first(sprint(showerror, e), 80))
        return
    end
    opts = Tuple{String,Any}[(n, d) for (n, d) in vs]
    push!(opts, ("\u2026 write this filter down as a view", :save))
    push_view!(ctrl, ChooseView("Views", "\u21b5 applies one \u00b7 ` goes back", opts,
        v -> begin
            if v === :save
                push_view!(ctrl, PromptView(
                    "Name this view",
                    "prints the TOML to paste into config.toml - this program " *
                    "does not write that file",
                    n -> begin
                        # Copied rather than printed: it is several lines of
                        # TOML and the status is one row, and pasting is the
                        # whole of what anybody wants to do with it. The same
                        # OSC 52 `y` uses, so whatever works for one works here.
                        t = view_toml(st.filters, st.sort, n)
                        print("\e]52;c;", Base64.base64encode(t), "\a")
                        st.status = string("copied [views.", repr(n),
                                           "] \u00b7 paste it into config.toml")
                    end))
            else
                msg = apply_view!(st, v)
                load_nodes!(st); load_meta!(st)
                st.status = string("view: ", msg)
            end
        end))
end

"""Ask about a draft the cursor has just walked away from.

A draft review is durable - it is on GitHub, and quitting does not lose it - but
it is also invisible from anywhere except the pull request it belongs to, which
is exactly how five careful comments end up never being sent. So leaving the
item it belongs to asks once, and taking no for an answer leaves it where it is.

Returns true when it asked, which is what lets `q` wait for the answer rather
than quitting out from under it.
"""
function batch_prompt!(st::BState, ctrl::Controller, leaving::AbstractString)
    b = st.batch
    b === nothing && return false
    b.url == leaving && return false
    # Asked once and answered "leave it". Quitting asks anyway - it is the last
    # moment there is - and so does walking away from it a second time, which is
    # what going back to the item re-arms.
    (get(b, :asked, false) && !isempty(leaving)) && return false
    # The item it belongs to, and no fallback: prompting about the wrong one
    # would offer to submit a review to a pull request nobody was writing about.
    i = findfirst(x -> x.url == b.url, st.all)
    i === nothing && return false
    it = st.all[i]
    push_view!(ctrl, ChooseView(
        string("Draft review on ", b.ref),
        string(b.n, b.n == 1 ? " comment is" : " comments are",
               " written and not sent"),
        [("submit it now", :yes), ("leave it as a draft on GitHub", :no)],
        v -> v === :yes ? review_action(st, ctrl, it) :
             # Not forgotten - only asked. The draft stays on the footer and in
             # the metadata pane, `A` still sends it from the item it belongs
             # to, and going back to that item arms the question again. Dropping
             # it here is how a draft ends up remembered by nobody: this program
             # would have stopped mentioning it, and it is invisible from
             # everywhere except the pull request itself.
             (st.batch = mkbatch(b.url, b.ref, b.review, b.n; asked = true);
              st.status = string("draft kept on ", b.ref, " \u00b7 A submits it there"))))
    true
end

"""Take back the newest local action, and say what it was.

Reports rather than throwing: an undo that fails over the frame would take the
browser down for the sake of a line in `state.toml`.
"""
function undo!(st::BState)
    isempty(st.undos) && return "nothing to undo"
    u = pop!(st.undos)
    try
        u.undo()
        # The lanes that are membership in something have to be rebuilt for the
        # row to come back - `:snoozed` among them, since undoing a snooze is
        # the same move `apply_snooze!` refilters for on the way in.
        st.filters.state in (:unread, :archived, :touched, :mine, :active,
                             :snoozed) && refilter!(st)
        string("undid: ", u.what)
    catch e
        string("could not undo ", u.what, ": ", first(sprint(showerror, e), 80))
    end
end

"""Put work away, or take it back out. `x` toggles.

Done, rejected or merged work should be able to leave without being deleted:
the note, the snooze and everything else written about it stay in `state.toml`,
and the `archived` lane is where it can still be found. `active` and `mine`
stop showing it, which is the whole point - they are the two lanes that answer
"what should I be doing", and neither should be answering with work that is
over.

It closes the loop for an adopted branch especially. A merged pull request
leaves the active lanes on its own once GitHub says so; a local branch that came
to nothing has no other way out.
"""
function archive!(st::BState, it::Item, at::DateTime)
    was = get_field(it.url, "archive")
    prevtouch = touched_at(it.url)
    set_fields(it.url, ["archive" => was === nothing ? string(Date(at)) : nothing], at)
    push!(st.undos, Undo(string(was === nothing ? "archive " : "unarchive ", it.ref),
                         () -> begin
        set_fields(it.url, ["archive" => was])
        set_touched(it.url, prevtouch)
    end))
    refilter!(st)
    was === nothing ? string("archived ", it.ref) : string("back out: ", it.ref)
end

"""Is this item over, as far as GitHub is concerned?

`state` is empty on a `facts.json` written before the lanes were asked for it,
which reads as "not known to be closed" rather than as closed - the wrong way
round would offer to archive the whole dashboard after an upgrade.
"""
isdone(it::Item) = it.state == "CLOSED" || it.state == "MERGED"

"""Merged by you: the one ending that is not news.

The wait before archive is offered exists so that a merge is read before it is
filed - somebody else finished your work, or finished with it, and that is worth
being told. When you pushed the button yourself there is nothing to be told, so
the notice is skipped and the offer stands on the first frame.

Empty for a `facts.json` written before the field was asked for, and for every
open item, which reads as "not known to have been merged by you" - the wrong way
round would have offered to file half the dashboard unread after an upgrade.

An adopted local branch has no record of this at all: `merged_here` says the
work landed and says nothing about who pushed it, which would want the merge
commit's committer.
"""
mergedbyme(it::Item) = it.state == "MERGED" && !isempty(it.merged_by) &&
                       it.merged_by == login()

"""Ask how long for, then snooze.

`s` used to set `on-change` and say nothing. That is the right default and was
the wrong only choice: `parse_snooze` has always taken spans and dates, and
`wl snooze` could reach them from the shell where the browser could not - so
the one place snoozing is actually done was the one place it could not be
said how long for.

The current value leads the note, because the common case for pressing this
twice is wanting to know what it is already set to.
"""
function snooze_action(st::BState, ctrl::Controller, it::Item, at::DateTime)
    cur = get_field(it.url, "snooze")
    opts = Tuple{String,Any}[
        ("until it moves",                "on-change"),
        ("until it moves, or 30 days",    "on-change/30d"),
        ("3 days",                        "3d"),
        ("1 week",                        "1w"),
        ("2 weeks",                       "2w"),
        ("1 month",                       "1mo"),
        ("3 months",                      "3mo"),
        ("a span or a date\u2026",         :ask)]
    # Only offered when there is something to clear, so the list does not lead
    # with an option that would do nothing.
    cur === nothing || pushfirst!(opts, ("off \u2014 wake it now", nothing))
    push_view!(ctrl, ChooseView(string("Snooze ", it.ref),
        cur === nothing ? it.title : string("now: ", cur), opts,
        v -> v === :ask ?
            push_view!(ctrl, PromptView(string("Snooze ", it.ref),
                "a span like 3d, 2w, 6mo, 1y - or a date like 2026-09-15",
                b -> (st.status = apply_snooze!(st, it, strip(b), at)))) :
            (st.status = apply_snooze!(st, it, v, at))))
end

"""Write one snooze value, with its undo. `nothing`, or an empty string, clears.

Rejected here rather than written: a value `parse_snooze` cannot read leaves the
item *not* snoozed, and the reason goes into a field only the snoozed section
prints - so a bad one used to look like it had worked and quietly do nothing.
"""
function apply_snooze!(st::BState, it::Item, v, at::DateTime)
    val = (v === nothing || (v isa AbstractString && isempty(v))) ? nothing : String(v)
    val === nothing || parse_snooze(val) !== nothing ||
        return string("bad snooze value '", val,
                      "' - use on-change, a span like 3d/2w/6mo/1y, or a date")
    prev = get_field(it.url, "snooze")
    prevtouch = touched_at(it.url)
    disarm(it.url)
    set_fields(it.url, ["snooze" => val], at)
    # `set_fields` removes a key when handed nothing, so this is the undo
    # whether or not there was a snooze here before. The clock goes back after
    # it, not before: restoring the value writes through `set_fields`, which
    # stamps on the way past.
    push!(st.undos, Undo(string("snooze ", it.ref), () -> begin
        set_fields(it.url, ["snooze" => prev])
        set_touched(it.url, prevtouch)
    end))
    # The snoozed lane is a filter over this field, so the row has to be able to
    # leave or arrive on the strength of it.
    st.filters.state in (:snoozed, :active) && refilter!(st)
    val === nothing ? "snooze cleared" : string("snoozed ", val)
end

"""Toggle one label, chosen from this item's own plus every label seen."""
function label_action(st::BState, ctrl::Controller, it::Item)
    have = Set(it.labels)
    all_ = sort(unique(vcat(it.labels, st.labels)); by = l -> (!(l in have), l))
    opts = [(string(l in have ? "[x] " : "[ ] ", l), l) for l in all_]
    push_view!(ctrl, ChooseView(string("Labels · ", it.ref), "↵ toggles one", opts,
        l -> begin
            on = l in have
            r = Events.toggle_label(it.url, l, !on)
            isempty(r) || (st.status = r; return)
            touch!(it.url)
            # The item is rewritten in place. It came from facts.json, which
            # this cannot write - so without this the metadata pane went on
            # showing the old set until the next refresh, and the status line
            # had to apologise for it.
            replace_item!(st, withlabels(it, on ? filter(!=(l), it.labels) :
                                             sort(vcat(it.labels, l))))
            st.status = string(on ? "removed " : "added ", l)
        end))
end

# --- context expansion ------------------------------------------------------

"Head commit of a pull request, cached: expansion needs the file as it will be."
function head_sha(it::Item)
    key = string("headsha:", it.repo, "#", it.number)
    hit = cache_get(key, 86_400.0)
    hit === nothing || return String(hit[1])
    out = try
        strip(read(`gh pr view $(it.number) --repo $(it.repo) --json headRefOid -q .headRefOid`,
                   String))
    catch
        ""
    end
    cache_put(key, out)
    String(out)
end

"""
    expand_hunk!(node, it, dir, n) -> status

Widen a hunk by `n` lines above (`dir < 0`) or below (`dir > 0`), reading the
file from the pinned local checkout rather than the API - the objects are
already there, so expanding repeatedly costs nothing after the first fetch.
"""
function expand_hunk!(node::Node, it::Item, dir::Int, n::Int = 10)
    node.kind === :diff && haskey(node.meta, "file") ||
        return "not a hunk"
    repo = repo_path(it.repo)
    repo === nothing && return :needs_repo
    sha = head_sha(it)
    isempty(sha) && return "could not determine the head commit"
    ensure_commit!(repo, sha, it.number) ||
        return "commit $(first(sha, 8)) is not in $repo and could not be fetched"
    lines = file_at(repo, sha, node.meta["file"])
    lines === nothing && return "$(node.meta["file"]) is absent at $(first(sha, 8))"

    start, count = node.meta["start"], node.meta["count"]
    up = node.meta["up"] + (dir < 0 ? n : 0)
    down = node.meta["down"] + (dir > 0 ? n : 0)
    lo = max(1, start - up)
    hi = min(length(lines), start + count - 1 + down)
    node.meta["up"] = start - lo
    node.meta["down"] = hi - (start + count - 1)

    pre = [string(" ", lines[i]) for i in lo:(start - 1)]
    post = [string(" ", lines[i]) for i in (start + count):hi]
    node.raw = join(vcat(pre, split(node.meta["body"], "\n"), post), "\n")
    node.cw = -1                                    # force a re-render
    node.header = string(node.meta["file"], "  @@ ", start, ",", count, " @@",
                         node.meta["up"] > 0 ? string("  ↑", node.meta["up"]) : "",
                         node.meta["down"] > 0 ? string("  ↓", node.meta["down"]) : "")
    ""
end
