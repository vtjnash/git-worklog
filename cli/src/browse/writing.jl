
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

The text of a suggestion, in other words. Deletions are left out - a suggestion
replaces what is on the side being commented on, and a deleted line is not there
any more - and the diff marker goes with them, being a column of the display
rather than of the file.
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

A hunk answers with a *range* - one line long unless rows are selected - which
GitHub takes as `start_line`/`line`, and with `text`, the lines as they stand
now, which is what `^r` fills a suggestion with.
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
            # What a suggestion would replace: the whole range where there is
            # one, and the anchored line alone where there is not. A one-line
            # suggestion is the commonest kind there is, so standing on a line
            # is enough to fill `^r` in.
            return (:line, (file = n.meta["file"], line = b[1], side = b[2],
                            start = first_,
                            text = hunk_text(st, i, iw,
                                             first_ === nothing ? hi : lo, hi)))
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
        # back from this the same as from every other jump. Bare and not the
        # filter the browser opens with, because filed and snoozed work still
        # has a worktree and is exactly what you would be going to look at.
        st.prev = st.filters
        st.filters = Filters()
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
             # The lane, which outlives this session and this browser: written
             # here because this is the moment a draft comes into being, and
             # GitHub will not answer for one from anywhere but the item itself.
             draft!(it.url); st.drafts = load_drafts()
             ""
         end)
    else
        (string("Comment on ", it.ref), it.title, b -> Events.post_comment(it.url, b))
    end
    push_beside!(ctrl, st, EditorView(title, note, b -> begin
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

Empty when there is nothing to replace - a range of nothing but deletions -
since a suggestion that replaces nothing is only a comment.
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
            isempty(r) && (st.batch = nothing; undraft!(it.url); st.drafts = load_drafts())
            return
        end
        # Beside the diff, the same as `c` and `M`: a review body is written
        # about the commits it lands, and the verdict picker in front of it is
        # a question rather than a page to write on.
        push_beside!(ctrl, st, EditorView(
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
                isempty(r) && (touch!(it.url); st.batch = nothing;
                               undraft!(it.url); st.drafts = load_drafts();
                               reread!(st))
            end; allow_empty = ev == "APPROVE"))
    end))
end

"""What GitHub says about whether this can be merged, as one phrase.

`mergeStateStatus` is the field that knows, and it knows more than `mergeable`
does: a pull request with no conflicts is still `BLOCKED` while a required
review is missing and `BEHIND` while the base has moved under it. Saying it in
the composer is the point - the alternative is finding out from a refusal after
the message has been written.

`UNKNOWN` is GitHub still computing the merge, which it does lazily on being
asked; `mergeable` is the second opinion to fall back on and is usually further
along by then.
"""
function merge_note(ms)
    ms.draft && return "a draft — GitHub will refuse to merge it"
    ms.status == "CLEAN" && return "clean"
    ms.status == "HAS_HOOKS" && return "clean, with hooks on the base branch"
    ms.status == "BEHIND" && return string("behind ", ms.base)
    ms.status == "BLOCKED" && return "blocked — a required review or check is missing"
    ms.status == "DIRTY" && return string("conflicts with ", ms.base)
    ms.status == "UNSTABLE" && return "checks are failing, none of them required"
    ms.mergeable == "CONFLICTING" && return string("conflicts with ", ms.base)
    ms.mergeable == "MERGEABLE" && return "mergeable"
    "GitHub is still working out whether it can be merged"
end

"""The message for one operation, as one buffer: headline, blank line, body.

A commit message is one thing to write and GitHub stores it as two, which is
its API's shape rather than anybody's idea of writing one. Splitting at the
first blank line on the way back out is what git itself does with the same text.
"""
function merge_message(ms, method::AbstractString)
    (h, b) = get(ms.text, method, ("", ""))
    isempty(strip(b)) ? String(h) : string(h, "\n\n", b)
end

"""The two halves back: everything up to the first blank line, then the rest.

An empty answer for a rebase, which has neither - `merge_pr` sends nothing at
all for one, and this is only ever asked what the composer is holding.
"""
function merge_split(text::AbstractString)
    t = strip(String(text))
    isempty(t) && return ("", "")
    i = findfirst("\n\n", t)
    i === nothing ? (t, "") : (strip(t[1:first(i) - 1]), strip(t[last(i) + 1:end]))
end

"""Merge it, on the message GitHub itself would have written.

`M`, and the last key of the loop the rest of this file is: `c` remarks, `A`
decides, `L` files, and this is the one thing a review that ends in "yes" still
had to be finished on github.com for.

The composer opens on the operation this program prefers - squash where the
repository allows it, then merge, then rebase - which is *not* the repository's
default, because a repository has none to be. See `Events.merge_state`. `^x`
changes it, which is the whole of the choice: there is no picker in front of
this, because the message and the operation that decides it belong on one
screen rather than on two.

`^s` asks once before it lands. Everything else here that writes is a comment,
a verdict or a label - each of them answerable with another one - and this is
the only key in the program whose mistake is somebody else's repository. The
question is not in front of the composer, it is behind it: what it can say is
"squash and merge, 3 commits into master", and none of that is known until the
message is written.
"""
function merge_action(st::BState, ctrl::Controller, it::Item)
    it.is_pr || (st.status = "not a pull request"; return)
    ms = try
        Events.merge_state(it.url)
    catch e
        st.status = string("could not read the merge state: ",
                           first(sprint(showerror, e), 120))
        return
    end
    ms === nothing && (st.status = "not a pull request"; return)
    # Said rather than attempted. All three are things GitHub would refuse, and
    # a refusal arrives after the message has been written rather than instead
    # of writing it.
    ms.state == "MERGED" && (st.status = string(it.ref, " is already merged"); return)
    ms.state == "CLOSED" && (st.status = string(it.ref, " is closed"); return)
    isempty(ms.methods) &&
        (st.status = string(it.repo, " allows no way to merge this"); return)
    merge_compose(st, ctrl, it, ms, first(ms.methods))
end

"""Open the merge composer on one operation, with `text` already in it.

Its own function because it is opened from two places and both are the same
screen: `M` opens it, and declining the question at the end puts it back with
what was written still in it. `^x` is not one of them - it swaps the buffer and
the note in place, so that changing the operation is not a new box appearing
over the old one.
"""
function merge_compose(st::BState, ctrl::Controller, it::Item, ms,
                       method::AbstractString, text::Union{Nothing,AbstractString} = nothing)
    # A `Ref` and not a closed-over binding: `^x` rewrites it from inside the
    # view, and the submit that runs afterwards has to read what `^x` left
    # rather than what this call was opened on.
    cur = Ref(String(method))
    ev = EditorView(string("Merge ", it.ref), merge_head(ms, cur[]),
                    b -> merge_confirm(st, ctrl, it, ms, cur[], b);
                    initial = text === nothing ? merge_message(ms, cur[]) : String(text),
                    # A rebase writes no message, so there is nothing for `^s`
                    # to refuse to send. Everything else needs its headline.
                    allow_empty = cur[] == "REBASE",
                    cycle = length(ms.methods) == 1 ? nothing :
                            (v, dir) -> merge_cycle!(v, ctrl, ms, cur, dir))
    push_beside!(ctrl, st, ev)
end

"""The line above the message: what is about to happen, and whether it can.

Its own function rather than a closure over the composer, because `^x` has to
rewrite it: a note still naming the operation the buffer no longer holds is the
one thing on that screen that could send the wrong merge.

`^x:` names where the next press goes rather than saying that `^x` cycles - the
hint under the box already says that, and which operation is one press away is
the thing worth knowing twice.
"""
merge_head(ms, method::AbstractString) =
    string(Events.merge_label(method), " · ", merge_lands(ms, method),
           " · ", merge_note(ms),
           method == "REBASE" ? " · no message to write" : "",
           length(ms.methods) == 1 ? "" :
           string(" · ^x: ", Events.merge_label(nextmethod(ms, method, 1))))

"""What lands where, which the composer and the question before the merge both
say - in the same words, since they are two views of the one sentence.

Onto rather than into for a rebase: it is the one operation that makes no commit
on the base branch, it writes these ones onto its tip.
"""
merge_lands(ms, method::AbstractString) =
    string(ms.commits, ms.commits == 1 ? " commit " : " commits ",
           method == "REBASE" ? "onto " : "into ", ms.base)

"The operation after this one, wrapping - `ms.methods` is already in our order."
function nextmethod(ms, method::AbstractString, dir::Int)
    i = something(findfirst(==(method), ms.methods), 1)
    ms.methods[mod1(i + dir, length(ms.methods))]
end

"""`^x`: the next operation, and the message rewritten for it.

Silently when the message is still the one this program put there, and after a
question when it is not. That is the same rule `esc` follows in a composer, and
for the same reason: words that were typed exist in this buffer and in no other
place, and swapping the operation replaces every one of them.

Declining leaves the operation alone as well as the words. "No" to a question
raised by `^x` is no to the whole of what `^x` was going to do - changing the
operation and keeping a squash headline on a merge commit would be a third
outcome nobody asked for.

One direction, because one key is one direction. Three operations is at most two
presses to any of them, and the two repos this is used on daily allow two.
"""
function merge_cycle!(v::EditorView, ctrl::Controller, ms, cur::Ref{String}, dir::Int)
    nxt = nextmethod(ms, cur[], dir)
    swap = () -> begin
        settext!(v.buf, merge_message(ms, nxt))
        v.allow_empty = nxt == "REBASE"
        cur[] = nxt
        # The note goes with the buffer. It is the only thing on this screen
        # that says which merge `^s` sends, so leaving it behind would leave the
        # composer telling the truth about the message and lying about the
        # operation.
        v.note = merge_head(ms, nxt)
        v.status = string("now: ", Events.merge_label(nxt))
    end
    if strip(text(v)) == strip(merge_message(ms, cur[]))
        swap()
        return
    end
    push_view!(ctrl, ConfirmView("Change the operation?",
        [string("to ", Events.merge_label(nxt)),
         "what you have written is replaced by GitHub's message for it"],
        ["yY" => swap];
        hint = "y replaces it · any other key keeps what you wrote"))
end

"""The one question this program asks before it changes somebody else's repo.

Behind the composer rather than in front of it, because what makes it worth
asking - the operation, the number of commits, the branch they land on - is not
settled until the message is. Declining puts the composer back with the words
still in it: a question that cost you what you had written would be a worse
mistake than the one it is guarding against.
"""
function merge_confirm(st::BState, ctrl::Controller, it::Item, ms,
                       method::AbstractString, body::AbstractString)
    (head, rest) = merge_split(body)
    push_view!(ctrl, ConfirmView(string("Merge ", it.ref, "?"),
        [string(Events.merge_label(method), " · ", merge_lands(ms, method)),
         merge_note(ms),
         method == "REBASE" ? "the commits are replayed as they were written" :
                              # The headline only. The body was on the screen
                              # this one replaced, and repeating it would be a
                              # box the length of the message asking about the
                              # one line that names it.
                              string("“", first(head, 70),
                                     length(head) > 70 ? "…" : "", "”")],
        ["yY" => () -> merge_now!(st, it, ms, method, head, rest),
         # The composer, back with what was in it. Not a new one: this is the
         # box that was open a keystroke ago and the words in it are the same
         # words.
         "\e" => () -> merge_compose(st, ctrl, it, ms, method, body)];
        hint = "y merges it · esc goes back to the message · any other key cancels"))
end

"""Send it, and make the row say so without waiting for a refresh.

`merged_by` is set to you deliberately: it is what `mergedbyme` reads, and the
metadata pane uses it to skip the "new since you last looked" notice and offer
`x` at once. A merge you pressed the button for is not news to you.
"""
function merge_now!(st::BState, it::Item, ms, method::AbstractString,
                    head::AbstractString, body::AbstractString)
    r = Events.merge_pr(it.url, ms.id, method, head, body, ms.oid)
    if !isempty(r)
        st.status = r
        return
    end
    touch!(it.url)
    replace_item!(st, with(it; state = "MERGED", merged_by = login()))
    reread!(st)
    # Not the operation's own name with a "d" on it: two of the three are
    # phrases rather than verbs, and "create a merge commitd" was what that got.
    st.status = string("merged ", it.ref, " · ", Events.merge_label(method),
                       " · x archives it")
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
    # Numbered, alone among the pickers: the built-in views are the same ten in
    # the same order every time, so they are reached by memory rather than by
    # reading, and arrow-and-return is the slow way to press something you
    # already know the position of.
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
                        clip(t)
                        st.status = string("copied [views.", repr(n),
                                           "] \u00b7 paste it into config.toml")
                    end))
            else
                msg = apply_view!(st, v)
                load_nodes!(st); load_meta!(st)
                st.status = string("view: ", msg)
            end
        end; numbered = true))
end

"""The draft review being held, as a line to show and a key to answer with.

Both questions that have to mention a draft - walking off its item, and leaving
the program - ask it through this, so the sentence and the key are the same in
each and `A` means what it means everywhere else in this program.

`nothing` when there is no draft, and equally when the draft belongs to an item
this dashboard is not carrying: prompting about the wrong one would offer to
submit a review to a pull request nobody was writing about.
"""
function draft_answer(st::BState, ctrl::Controller)
    b = st.batch
    b === nothing && return nothing
    i = findfirst(x -> x.url == b.url, st.all)
    i === nothing && return nothing
    it = st.all[i]
    (string(b.n, b.n == 1 ? " comment is" : " comments are",
            " written and not sent on ", b.ref),
     "A" => () -> (review_action(st, ctrl, it); :ok))
end

"""Ask about a draft the cursor has just walked away from.

A draft review is durable - it is on GitHub, and quitting does not lose it - but
it is also invisible from anywhere except the pull request it belongs to, which
is exactly how five careful comments end up never being sent. So leaving the
item it belongs to asks once, and any key but `A` leaves it where it is: the
draft stays on the footer and in the metadata pane, `A` still sends it from the
item it belongs to, and going back to that item arms the question again.

Asked once and dismissed is asked, which is why the mark goes on here rather
than in an answer - there is no answer for "not now", only the absence of one.
Leaving the program asks its own question and asks it every time; see
`quit_prompt!`, which is where this one used to be answered a second time and
never let go.

Returns true when it asked.
"""
function batch_prompt!(st::BState, ctrl::Controller, leaving::AbstractString)
    b = st.batch
    b === nothing && return false
    b.url == leaving && return false
    get(b, :asked, false) && return false
    a = draft_answer(st, ctrl)
    a === nothing && return false
    note, submit = a
    # `Esc` puts the cursor back on the item the draft belongs to, and re-arms
    # the question with it: the move is what raised this, so the key that means
    # "no" everywhere else in this program has to be able to take the move back
    # as well as leave the draft alone. Without it the only way to stay was to
    # dismiss the box and walk back by hand, past the item you had just left.
    #
    # It goes through `select_item!` rather than restoring `st.sel`, because the
    # row may not be in the list any more: the filter can have moved under it,
    # and being unable to see the item you are being asked about is exactly the
    # case that one is for.
    back = "\e" => () -> begin
        i = findfirst(x -> x.url == b.url, st.all)
        if i !== nothing
            # It writes its own "went to …" and answers with a *failure*, so
            # only a non-empty return is worth putting on the footer.
            r = select_item!(st, st.all[i])
            isempty(r) || (st.status = r)
        end
        st.batch = mkbatch(b.url, b.ref, b.review, b.n)
    end
    # The title says what this is about and the row says the whole of it - the
    # same sentence the quit question uses, ref and all, rather than a shorter
    # one that reads differently in the two places it can appear.
    push_view!(ctrl, ConfirmView("Draft review", note, [submit, back];
                                 hint = "A submits it now \u00b7 esc goes back to it \u00b7 " *
                                        "any other key keeps it as a draft"))
    st.batch = mkbatch(b.url, b.ref, b.review, b.n; asked = true)
    true
end

"""Take back the newest local action, and say what it was.

Reports rather than throwing: an undo that fails over the frame would take the
browser down for the sake of a line in `local.toml`.
"""
function undo!(st::BState)
    isempty(st.undos) && return "nothing to undo"
    u = pop!(st.undos)
    try
        u.undo()
        # Every axis is membership in something an undo can put back, so the
        # list is rebuilt rather than asked whether it cares.
        refilter!(st)
        string("undid: ", u.what)
    catch e
        string("could not undo ", u.what, ": ", first(sprint(showerror, e), 80))
    end
end

"""Put work away, or take it back out. `x` toggles.

Done, rejected or merged work should be able to leave without being deleted:
the note and everything else written about it stay in `local.toml`, and the
`archived` lane is where it can still be found.

**It is a snooze, and always was.** "File this away" and "not now" are the same
sentence with a different wake condition, so `x` writes `snooze = "forever"` -
one field, one undo, one place to look, and `snooze_why` says which kind it is.
Two fields meant a precedence rule between them at every reader, and an item
could carry both.

It closes the loop for an adopted branch especially. A merged pull request
leaves the active lanes on its own once GitHub says so; a local branch that came
to nothing has no other way out.
"""
function archive!(st::BState, it::Item, at::DateTime)
    was = snooze_forever(get_field(it.url, "snooze"))
    r = apply_snooze!(st, it, was ? nothing : "forever", at)
    startswith(r, "bad ") && return r
    # The undo `apply_snooze!` pushed is the right one; only its name is wrong,
    # since what the reader pressed was `x`.
    isempty(st.undos) ||
        (st.undos[end] = Undo(string(was ? "unarchive " : "archive ", it.ref),
                              st.undos[end].undo))
    was ? string("back out: ", it.ref) : string("archived ", it.ref)
end

"Is this snooze value the one that never wakes - which is what archiving is?"
snooze_forever(v) = v !== nothing &&
    (p = parse_snooze(String(v)); p !== nothing && p.mode === :forever)

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
    # Only offered when there is something to clear, and at the *end* rather
    # than the front, which is where it used to be. Numbering the rows is what
    # moved it: a row that comes and goes at the top shifts every key below it,
    # so "3 days" would be `3` on an item with no snooze and `4` on one that has
    # got one - which is the whole of what a number is for, gone. Last, the
    # eight standing options keep their keys and clearing takes the one that
    # only exists when there is something to clear.
    cur === nothing || push!(opts, ("off \u2014 wake it now", nothing))
    # Numbered, the same as the views and for the same reason: it is the same
    # list in the same order every time, so it is reached by memory rather than
    # by reading. The cost is real and worth naming - a digit picks instead of
    # narrowing, so `3` is the third row and no longer types the `3` of "3 days"
    # or "3 months" - and it is the cost the views already pay.
    push_view!(ctrl, ChooseView(string("Snooze ", it.ref),
        cur === nothing ? it.title : string("now: ", cur), opts,
        v -> v === :ask ?
            push_view!(ctrl, PromptView(string("Snooze ", it.ref),
                "a span like 3d, 2w, 6mo, 1y - or a date like 2026-09-15",
                b -> (st.status = apply_snooze!(st, it, strip(b), at)))) :
            (st.status = apply_snooze!(st, it, v, at)); numbered = true))
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
    prevread, wasunread = read_at(it.url), it.url in st.unread
    disarm(it.url)
    set_fields(it.url, ["snooze" => val], at)
    # "Not now" and "unread" are the same answer twice, so putting an item to
    # sleep marks it read - here as well as in the refresh, which is what does
    # it for `wl snooze` and for a snooze typed into `local.toml`. The refresh
    # would get to this one too, on its own edge; doing it now is what makes the
    # row leave the unread lane in the session where the key was pressed.
    #
    # Only on the way in. Clearing a snooze is not a claim about whether you
    # have read the thing, and waking is the refresh's to announce.
    if val !== nothing
        set_read(it.url, stamp(at))
        delete!(st.unread, it.url)
    end
    # `set_fields` removes a key when handed nothing, so this is the undo
    # whether or not there was a snooze here before. The clock goes back after
    # it, not before: restoring the value writes through `set_fields`, which
    # stamps on the way past.
    push!(st.undos, Undo(string("snooze ", it.ref), () -> begin
        set_fields(it.url, ["snooze" => prev])
        set_touched(it.url, prevtouch)
        set_read(it.url, prevread)
        wasunread ? push!(st.unread, it.url) : delete!(st.unread, it.url)
    end))
    # The sleep axis is a filter over this field and the seen axis over the
    # stamp just written, so the row has to be able to leave or arrive on the
    # strength of either.
    refilter!(st)
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
                         node.meta["down"] > 0 ? string("  ↓", node.meta["down"]) : "",
                         # What `attach_comments` put there, since this rebuilds
                         # the header from scratch and the tally is not derivable
                         # from the file and the range.
                         get(node.meta, "tally", ""))
    ""
end
