
# --- content loading -------------------------------------------------------

"""How long an item has to stay selected before anything is asked about it.

Two debounces, not delays, and they answer two questions. Holding `j` down
passes twenty entries, and a request for each would spend the whole point of
the cache on items nobody read. `LOAD_AFTER` is for an item with nothing cached
at all - one the poll just found - and is short, because until it is fetched
the pane is empty and a quarter of a second is the most an empty pane should
cost the reader who did stop. `REFRESH_AFTER` is for a stale entry that went up
from the cache: the reader has something to look at, and a second of it being
on screen is the difference between reading it and going past it.

A cached entry, current or stale, is never held: showing what is already on
disk costs no request, and the feel of the browser is that moving is free.
"""
const LOAD_AFTER = Ref(0.25)
const REFRESH_AFTER = Ref(1.0)

# The keys under which the detail pane's reads are cached, named once so that
# the loader can ask `cache_age` about an entry without fetching it.
thread_key(url::AbstractString) = string("thread:", url)
"The gh answer, by number: what it was at the time, and so on a clock."
diff_key(it::Item) = string("diff:", it.repo, "#", it.number)

"""The heads whose diff the checkout has answered this launch - what
`mode_cached` asks, since the checkout's answer is not cached and "is there
something to show at once" is then "has this been shown": the first `d` on
an item waits out the dwell like a fetch, and every one after is immediate,
which is what git being the cache means for the pane."""
const DIFFED = Set{String}()

"""
    split_details(md) -> Vector{Tuple{Symbol,String,String}}

Break a comment body into prose and `<details>` blocks, in the order they
appear: `(:text, "", prose)` or `(:details, summary, contents)`.

`Markdown.parse` passes HTML straight through, so a codecov report or a pasted
build log arrives as several hundred lines of raw tags sitting in the middle of
the thread - which is the opposite of what the author meant by folding it away.

Scanned rather than matched with a regex, because these nest: a lazy `.*?` run
to the first `</details>` closes the outer block at the inner one's end and
spills the remainder into the prose.
"""
function split_details(md::AbstractString)
    OPEN, CLOSE = r"<details\b[^>]*>"i, r"</details\s*>"i
    out = Tuple{Symbol,String,String}[]
    pos = firstindex(md)
    while pos <= lastindex(md)
        m = findnext(OPEN, md, pos)
        m === nothing && break
        k, depth, closing = nextind(md, last(m)), 1, nothing
        while depth > 0
            o = findnext(OPEN, md, k)
            c = findnext(CLOSE, md, k)
            c === nothing && break
            if o !== nothing && first(o) < first(c)
                depth += 1; k = nextind(md, last(o))
            else
                depth -= 1; k = nextind(md, last(c))
                depth == 0 && (closing = c)
            end
        end
        # Unbalanced: leave the rest as prose rather than guessing where it ends.
        closing === nothing && break
        pre = md[pos:prevind(md, first(m))]
        isempty(strip(pre)) || push!(out, (:text, "", String(strip(pre))))
        inner = md[nextind(md, last(m)):prevind(md, first(closing))]
        smy = match(r"<summary[^>]*>(.*?)</summary\s*>"is, inner)
        summary = smy === nothing ? "details" :
                  strip(unescape_html(replace(smy[1], r"<[^>]+>" => "")))
        summary = replace(String(summary), r"\s+" => " ")
        content = smy === nothing ? inner : replace(inner, smy.match => "")
        push!(out, (:details, isempty(summary) ? "details" : summary,
                    String(strip(content))))
        pos = nextind(md, last(closing))
    end
    tail = pos > lastindex(md) ? "" : md[pos:end]
    isempty(strip(tail)) || push!(out, (:text, "", String(strip(tail))))
    out
end

"""
    split_fences(md) -> Vector{Tuple{Symbol,String,String}}

Break prose apart from fenced code blocks: `(:text, "", prose)` and
`(:code, language, contents)`.

Term draws a fenced block as a bordered panel sized to its *longest line*, not
to the width it was asked for. A pasted gdb log or stack trace routinely runs to
250 columns, so in a 96-column pane the panel is wider than the pane and the
wrapping breaks it: the left border, some content, then the rest of that line on
following rows with the closing border landing in the middle of nothing.

Lifting the block out means it never reaches Term at all - it becomes a node of
its own, rendered as plain text, which wraps like everything else and keeps its
borders because it has none. A long log also becomes foldable, which is what a
long log wants to be.
"""
function split_fences(md::AbstractString)
    out = Tuple{Symbol,String,String}[]
    buf, code = String[], String[]
    lang, opener, fenced = "", "", false
    flushtext!() = begin
        t = strip(join(buf, "\n"))
        isempty(t) || push!(out, (:text, "", String(t)))
        empty!(buf)
    end
    for line in split(md, '\n')
        m = match(r"^\s*(?:```|~~~)\s*([A-Za-z0-9_+-]*)\s*$", line)
        if m !== nothing
            if fenced
                # Flush the prose here rather than at the opening fence, so the
                # segments come out in the order they were written.
                flushtext!()
                push!(out, (:code, lang, join(code, "\n")))
                empty!(code); fenced = false
            else
                lang, opener, fenced = String(m[1]), String(line), true
            end
            continue
        end
        fenced ? push!(code, String(line)) : push!(buf, String(line))
    end
    if fenced
        # Never closed, so it was not a fence: give every line back as prose,
        # in one piece rather than as two segments either side of nothing.
        push!(buf, opener); append!(buf, code)
    end
    flushtext!()
    out
end

"How far a `<details>` chain is followed before its contents are left as text."
const MAX_DEPTH = 3

"""Nodes for one body: its prose, then a folded node per `<details>` block.

The block becomes a sibling drawn inset and starting closed, rather than a child
- which is what a five-hundred-line generated table wants to be, and avoids
turning the flat node list into a tree for the one case that needs one.

Every piece of one body sits one level under that body's node, blocks and the
prose between them alike, so the whole comment folds as a unit. Putting the
trailing prose back at the parent's depth reads correctly but folds wrongly:
closing the comment left its own tail on screen as a stray `…`, and the block
after that tail hung off the tail rather than off the comment.
"""
function body_nodes!(ns::Vector{Node}, header, body, url, open::Bool, depth::Int = 0)
    # GitHub writes CRLF, and this is the one place every body passes through -
    # the markdown path normalised it and `split_fences` never did, so a fenced
    # block came out with a carriage return on the end of every line.
    body = replace(String(body), "\r\n" => "\n")
    segs = depth >= MAX_DEPTH ? [(:text, "", String(body))] :
           collect(Iterators.flatten(
               (k === :text ? split_fences(c) : [(k, sm, c)]
                for (k, sm, c) in split_details(body))))
    lead = (!isempty(segs) && segs[1][1] === :text) ? segs[1][3] : ""
    n = Node(String(header), lead, :md, open, depth)
    isempty(url) || (n.meta["url"] = url)
    push!(ns, n)
    for (k, (kind, summary, content)) in enumerate(segs)
        (k == 1 && kind === :text) && continue
        if kind === :details
            body_nodes!(ns, summary, content, url, false, depth + 1)
        elseif kind === :code
            # Its own node, and never through Term: plain text wraps like
            # everything else, and a block with no border cannot have a broken
            # one. Folded when it is long enough to be in the way.
            nl = count(==('\n'), content) + 1
            c = Node(string(isempty(summary) ? "code" : summary, "  ",
                            nl, nl == 1 ? " line" : " lines"),
                     content, :plain, nl <= 12, depth + 1)
            isempty(url) || (c.meta["url"] = url)
            push!(ns, c)
        else
            # Prose after a block is the comment carrying on, not a thing of its
            # own: a fence in the middle of a paragraph left the rest of the
            # paragraph under a foldable header called `…`. Nested all the same,
            # so folding the comment still takes it with everything else - which
            # is what the header was there for and the only thing it did.
            t = Node("", String(content), :md, true, depth + 1)
            t.meta["bare"] = true
            push!(ns, t)
        end
    end
    ns
end
body_nodes(header, body, url, open::Bool) = body_nodes!(Node[], header, body, url, open)

"""One run of commits with no comment between them, as a node.

Consecutive is what a push is here. GitHub records the push events themselves
and GraphQL will hand them over, but only as part of `timelineItems` - a second
connection on the same node, paged separately from the comments, for a fact that
is already implied by the order: commits nobody said anything between are
commits that arrived together. Two of somebody's pushes a minute apart do read
as one here, and that is the same thing a reader coming back to the thread
cares about anyway.

Folded past three, with the newest headline as the peek: a rebase of forty
commits is context for the comment under it rather than forty lines to scroll.
"""
function push_node(run, url::AbstractString)
    n = length(run)
    when = when_str(run[end]["at"])
    # The last commit's author, which is whose push it was except where a run
    # collected two people's. A list of names on the header would be a byline
    # about the push rather than about a person, which is not what a byline is.
    who = isempty(run[end]["by"]) ? "" : string(run[end]["by"], "  ")
    peek = strip(first(replace(String(run[end]["headline"]), r"\s+" => " "), 58))
    body = join((string(first(c["oid"], 8), "  ", when_str(c["at"]), "  ",
                        oneline(c["headline"])) for c in Iterators.reverse(run)), "\n")
    hd = string(THEME.settled, "↑ pushed ", n, n == 1 ? " commit" : " commits", THEME.reset)
    nd = Node(string(hd, "  ", THEME.dim, who, when, THEME.reset, "   ", peek),
              body, :plain, n <= 3)
    nd.meta["byline"] = string(hd, "  ", THEME.dim, who, when, THEME.reset)
    nd.meta["src"] = string("pushed ", n, n == 1 ? " commit" : " commits",
                            "  ", astrip(who), when)
    # The branch's own page, since a push is not a comment and has no anchor in
    # the thread to point at.
    nd.meta["url"] = string(url, "/commits")
    nd.meta["push"] = n
    # The whole sha behind each row of the body, in the order drawn: the rows
    # show eight characters, and `o` on one opens that commit.
    nd.meta["oids"] = [String(c["oid"]) for c in Iterators.reverse(run)]
    nd.meta["at"] = String(run[end]["at"])
    nd
end

"""One change of state, as a node: closed, merged, reopened, converted to
draft, ready for review.

A header and no body, like the rule below: what happened, who did it and when,
and what else the event says - what closed it (`by julia#63266`, a commit) and
why (`not planned`), where a merge went (`into master  fd4b58c`). It is in the
activity list because it is activity: "they replied, then it was merged" is
one sequence, and a thread that ended at the last comment read as open a day
after the merge. Merged is settled and closed is blocked, the colours the state
has on the pane's header; reopened is waiting, since it is open work again.

Followed to the closer when there is one - the pull request that fixed it is
where the answer is - and to the item itself otherwise.
"""
function state_node(e, url::AbstractString)
    kind = String(e["kind"])
    (col, word) = kind == "merged" ? (THEME.settled, "\u2713 merged") :
                  kind == "closed" ? (THEME.blocked, "\u2717 closed") :
                  kind == "reopened" ? (THEME.waiting, "\u21bb reopened") :
                  kind == "draft" ? (THEME.dim, "converted to draft") :
                                    (THEME.settled, "ready for review")
    by = String(nz(get(e, "by", nothing), ""))
    when = when_str(String(e["at"]))
    closer = String(nz(get(e, "closer", nothing), ""))
    reason = String(nz(get(e, "reason", nothing), ""))
    into = String(nz(get(e, "into", nothing), ""))
    oid = String(nz(get(e, "oid", nothing), ""))
    said = kind == "closed" ? join(filter(!isempty, [isempty(closer) ? "" : string("by ", closer),
                                                     isempty(reason) ? "" : string("as ", reason)]),
                                   ", ") :
           kind == "merged" ? join(filter(!isempty, [isempty(into) ? "" : string("into ", into), oid]),
                                   "  ") : ""
    # No `byline`: an open header is drawn as its byline in place of the peek,
    # and there is no body under this one for the rest to be read off - so the
    # whole of it stays on the header.
    nd = Node(string(col, word, THEME.reset, "  ", THEME.dim,
                     isempty(by) ? "" : string(by, "  "), when, THEME.reset,
                     isempty(said) ? "" : string("   ", said)), "", :plain, true)
    nd.meta["src"] = string(word, "  ", isempty(by) ? "" : string(by, "  "), when,
                            isempty(said) ? "" : string("  ", said))
    nd.meta["url"] = String(nz(get(e, "closer_url", nothing), url))
    nd.meta["at"] = String(e["at"])
    nd
end

"""A submitted review, as nodes: the verdict, who and when on the header, and
its words under it the way a comment's are - or nothing under it, for the
approval that says nothing else, which is a header like a state change.

Approved is settled and changes requested blocked, the colours the verdict has
on the row; a comment review is plain, since it is a comment; a dismissed one
is dim - GitHub keeps no record of what it had said.
"""
function review_node(e, url::AbstractString)
    state = String(nz(get(e, "state", nothing), ""))
    (col, word) = state == "approved" ? (THEME.settled, "\u2713 approved") :
                  state == "changes_requested" ? (THEME.blocked, "\u2717 changes requested") :
                  state == "dismissed" ? (THEME.dim, "review dismissed") :
                                         ("", "reviewed")
    by = String(nz(get(e, "by", nothing), ""))
    who = isempty(by) ? "" : string(by, "  ")
    when = when_str(String(e["at"]))
    hd = string(col, word, THEME.reset, "  ", THEME.dim, who, when, THEME.reset)
    txt = strip(String(nz(get(e, "body", nothing), "")))
    link = String(nz(get(e, "url", nothing), ""))
    link = isempty(link) ? String(url) : link
    ns = isempty(txt) ? [Node(hd, "", :plain, true)] : body_nodes(hd, txt, link, true)
    if !isempty(txt)
        lead = isempty(strip(ns[1].raw)) && length(ns) > 1 ? ns[2].header : ns[1].raw
        ns[1].header = string(hd, "   ", strip(first(replace(lead, r"\s+" => " "), 58)))
        ns[1].meta["byline"] = hd
    end
    ns[1].meta["src"] = string(word, "  ", who, when)
    ns[1].meta["url"] = link
    ns[1].meta["at"] = String(e["at"])
    ns
end

"""The rule the new part of a thread begins under.

Drawn from the done stamp alone, which is the whole of what it needs: `e` marks
the thread done up to the moment it was *fetched*, so everything written before
that stamp was on screen and everything written after it was not. There is no
second record of where you had got to, because a second record is a second
answer that can disagree with this one.

It is a node rather than a decoration so that `n`/`N` reaches it, folding above
it works, and `collect_pending!` has something to open the pane on.
"""
function newmark_node(n::Int)
    nd = Node(string(THEME.waiting, "new since you last looked", THEME.reset,
                     "  ", THEME.dim, n, n == 1 ? " entry" : " entries",
                     THEME.reset),
              "", :plain, true)
    nd.meta["newmark"] = true
    nd.meta["src"] = "--- new since you last looked ---"
    nd
end

"""Consecutive pushes folded into one entry, keeping everything else in place.

The run is stamped at its *last* commit, so a push that is half older than the
done mark still lands wholly below the rule. That is the safe direction: it
shows a commit you had already seen among the new ones, where the other way
round hides one you have not.
"""
function group_pushes(evs)
    out = Any[]
    for e in evs
        if e.kind === :push && !isempty(out) && out[end].kind === :push
            run = push!(out[end].c, e.c)
            out[end] = (kind = :push, at = e.at, c = run)
        else
            push!(out, e.kind === :push ? (kind = :push, at = e.at, c = Any[e.c]) : e)
        end
    end
    out
end

"""The activity list: comments, pushes and state changes in the order they
happened, which is one sequence and was being read as two. "They replied,
then pushed, then replied" is the shape of most review conversations, and
the pushes were a field on the item while the replies were the pane.

A review is a comment for this purpose: it is said in the thread, it sorts
among the comments, and it is shown inside the same window the pushes are.

Only the pushes that fall inside the window the comments are shown for - the
thread is the last thirty of those - so a branch with two hundred commits
does not arrive above the first thing anybody said. The state changes are
all shown, wherever they fall: there are a handful at most, and a close from
before the window is the one thing a reader of the last thirty comments most
needs told.

A commit and a comment stamped the same second: the commit first, because
the reply is about the push in that case and never the other way round. A
comment and a close the same second: the comment first, since "closing as
fixed by #N" is what the close button with a comment produces, in that
order. Consecutive pushes are one entry ([`group_pushes`](@ref)).

Each entry is `(kind, at, c)`: `:comment` with the comment, `:push` with the
run of commits, `:state` with the event, `:review` with the review. What the browser draws and what
`wl show` and `wl thread` print, so the three agree on what happened.
"""
function activity_list(cs, cms, sts)
    from = isempty(cs) ? "" : String(first(cs)["created_at"])
    evs = Any[(kind = :comment, at = String(c["created_at"]), c = c) for c in cs]
    for c in cms
        t = String(c["at"])
        (isempty(from) || t >= from) && push!(evs, (kind = :push, at = t, c = c))
    end
    for e in sts
        t = String(e["at"])
        if get(e, "kind", "") == "review"
            (isempty(from) || t >= from) && push!(evs, (kind = :review, at = t, c = e))
        else
            push!(evs, (kind = :state, at = t, c = e))
        end
    end
    sort!(evs; by = e -> (e.at, e.kind === :push ? 0 : e.kind === :state ? 2 : 1))
    group_pushes(evs)
end

"""Who an activity entry is by: the commenter, the reviewer, whoever changed
the state, and for a run of pushes its last commit's author."""
entry_by(e) = String(nz(e.kind === :comment ?
                            get(something(get(e.c, "user", nothing), Dict{String,Any}()), "login", nothing) :
                        e.kind === :push ? get(e.c[end], "by", nothing) :
                                           get(e.c, "by", nothing), ""))

"""The thread pane of an adopted branch, which has no thread.

Nothing about it is on GitHub, so there is nothing to ask for - and asking,
which is what happened, was a `local:` url split as if it were a GitHub one.
What it has instead is the note, the one thing written about it, so that is the
body; a branch without one says how to write it.
"""
function local_nodes(it::Item)
    lead = Node(string("local branch ", it.branch, " - no thread"),
                string("This is an adopted branch of ", it.repo,
                       ": nothing about it is on GitHub, so there is nothing ",
                       "said here until it is pushed and opened as a pull request",
                       isempty(it.web) ? "" : string(" - which is done from ", it.web),
                       ". Its title is the tip's subject, and the note below is `v`."),
                :md, true)
    isempty(it.web) || (lead.meta["url"] = it.web)
    ns = Node[lead]
    isempty(it.note) ? push!(ns, Node("no note - `v` writes one", "", :plain, true)) :
                       body_nodes!(ns, "your note", it.note, "", true)
    ns
end

"""Read the thread from GitHub and put it in the cache under `thread_key`, the
shape `comment_nodes` reads back. Its own function so the prefetch fills the
very entry the pane will look for."""
function fetch_thread!(url::AbstractString)
    body, cs, cms, sts = Events.thread(url; limit = 30)
    cache_put(thread_key(url), (body = body, comments = cs, commits = cms, events = sts))
    (body, cs, cms, sts)
end

function comment_nodes(it::Item, at::DateTime; fresh::Bool = false)
    islocal(it) && return local_nodes(it)
    local body, cs, cms, sts
    stale = false
    asof = nothing          # when a cached copy was read; `loadedat`
    try
        key = thread_key(it.url)
        hit = fresh ? nothing : cache_get(key, CACHE_FRESH[]; keep_s = CACHE_KEEP[])
        if hit === nothing
            body, cs, cms, sts = fetch_thread!(it.url)
        else
            body, cs = hit[1].body, hit[1].comments
            # Absent on an entry written before the pushes, and then the state
            # events, were drawn in here. A thread kept for a week is worth
            # showing without them rather than dropped for want of a field
            # that is new.
            cms = something(jget(hit[1], :commits), ())
            sts = something(jget(hit[1], :events), ())
            stale = hit[2] > CACHE_FRESH[]
            asof = time() - hit[2]
        end
    catch e
        return [failednode("could not load thread", first(sprint(showerror, e), 200))]
    end
    ns = Node[]
    who0 = get(something(get(body, "user", nothing), Dict{String,Any}()), "login", "?")
    btxt = strip(nz(get(body, "body", nothing), ""))
    if !isempty(btxt)
        body_nodes!(ns, string(nz(who0, "?"), " opened this"), btxt,
                    String(nz(get(body, "html_url", nothing), it.url)), true)
        ns[1].meta["at"] = String(nz(get(body, "created_at", nothing), ""))
    end
    evs = activity_list(cs, cms, sts)
    # Where the new part starts, and how much of it there is. Nothing at all for
    # an item never marked done: the whole thread is new then, and a rule above
    # the first line of it says nothing. It starts at somebody else's entry,
    # the same rule the wake table keeps: your own reply, push or review after
    # the stamp is not news to you, and a rule over it alone said there was some.
    # The stamp or the floor, as the list reads it: the stamp alone left no rule
    # on a row read by construction, which the list called unread all the same.
    seen = done_upto(it)
    me = login()
    # And nothing for a thread opened since, by somebody else: the floor is
    # older than all of it, the opening post included, which is drawn first
    # and is no entry for the rule to go above. Under it the rule stood over
    # the first push - its commits dated before the opening, so older than
    # the post above it (libuv#5295).
    opened = String(nz(get(body, "created_at", nothing), ""))
    seen !== nothing && opened > seen && (isempty(me) || who0 != me) && (seen = nothing)
    mk = seen === nothing ? nothing :
         findfirst(e -> e.at > seen && (isempty(me) || entry_by(e) != me), evs)
    mark = mk === nothing ? 0 : mk
    for (k, e) in enumerate(evs)
        k == mark && push!(ns, newmark_node(length(evs) - mark + 1))
        if e.kind === :push
            push!(ns, push_node(e.c, it.url))
            continue
        elseif e.kind === :state
            push!(ns, state_node(e.c, it.url))
            continue
        elseif e.kind === :review
            append!(ns, review_node(e.c, it.url))
            continue
        end
        c = e.c
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
        when = when_str(String(c["created_at"]))
        txt = strip(nz(get(c, "body", nothing), ""))
        # Anchored, so following it lands on this comment rather than the top.
        url = String(nz(get(c, "html_url", nothing), it.url))
        # A review comment reads as a non-sequitur in a chronological list
        # without the line it was left on. The diff pane places it against the
        # code; here it at least says where it was pointing.
        loc = comment_loc(c)
        made = body_nodes(string(nz(who, "?"), "  ", when), txt, url, true)
        # The peek belongs to the prose. A comment that is nothing but a folded
        # block has none, so it borrows the summary - "<details><summary>" is
        # not a useful thing to read on the header line.
        lead = isempty(strip(made[1].raw)) && length(made) > 1 ?
               made[2].header : made[1].raw
        peek = strip(first(replace(lead, r"\s+" => " "), 58))
        made[1].header = string(nz(who, "?"), "  ", when, loc, "   ", peek)
        # The header's peek is cut mid-word; copy the byline instead, since the
        # body itself is on the rows underneath it. `byline` is the same thing
        # for the screen rather than for the clipboard, so it keeps the colour
        # on the location - it is what the header reads as once the node is open
        # and the peek would be repeating the row below it.
        made[1].meta["src"] = string(nz(who, "?"), "  ", when, astrip(loc))
        made[1].meta["byline"] = string(nz(who, "?"), "  ", when, loc)
        # The time itself, for `rows` to say how long ago that was against
        # the frame's clock; the header carries only the date.
        made[1].meta["at"] = e.at
        # Only a review comment can be replied to in a thread; an issue comment
        # has no thread to reply into, so `c` there writes a new one.
        isempty(loc) || (made[1].meta["comment_id"] = get(c, "id", nothing))
        append!(ns, made)
    end
    # **What this thread shows you up to**, which is what `e` marks the item
    # seen up to: the newest event on screen - a comment, a review or a review
    # comment, a push, a close or a merge, the body's own last edit - and no clock at
    # all, this machine's or GitHub's. A comment that landed while the reads
    # were in flight is either here, and seen, or not here, and newer than
    # this - unread at the next refresh, as it should be. A cached thread
    # stamps the same, since the newest thing in it is the newest thing in
    # it. `e` takes the max of this and `moved_at`, for the movements a
    # thread does not show: a CI edge, a review request.
    seen = maximum(Iterators.flatten((
               (String(nz(get(c, "created_at", nothing), "")) for c in cs),
               (String(nz(get(c, "at", nothing), "")) for c in cms),
               (String(nz(get(e, "at", nothing), "")) for e in sts),
               (String(nz(get(body, "updated_at", nothing), "")),))); init = "")
    isempty(ns) || isempty(seen) || (ns[1].meta["seen_up_to"] = seen)
    out = isempty(ns) ? [Node("no comments", "", :plain, true)] : ns
    stale && (out[1].meta["stale"] = true)
    asof === nothing || (out[1].meta["asof"] = asof)
    # For `collect_pending!` to latch onto the item; see `latch_mention!`.
    why = thread_mention(body, cs, login())
    isempty(why) || (out[1].meta["mentioned"] = why)
    out
end

"""Does `txt` name `me` - an `@me` GitHub would link? Not inside code, fenced
or inline, and not the tail of an address or another name (`a@me`, `@me-x`)."""
function names_you(txt::AbstractString, me::AbstractString)
    isempty(me) && return false
    t = replace(txt, r"```.*?(```|\z)"s => " ", r"`[^`\n]*`" => " ")
    occursin(Regex(string("(?<![\\w@/.`-])@", "\\Q", me, "\\E", "(?![\\w-])"), "i"), t)
end

"""The first place in a thread somebody other than you wrote `@you`, as the
sentence `mentioned` carries, or `""`. The opening post first, then the
comments in the order they came; only what was loaded, which is the newest
thirty. Your own team is not looked for: which teams you are in is not a thing
this program knows."""
function thread_mention(body, cs, me::AbstractString)
    for c in Iterators.flatten(((body,), cs))
        who = String(nz(get(something(get(c, "user", nothing), Dict{String,Any}()), "login", nothing), ""))
        lowercase(who) == lowercase(me) && continue
        names_you(String(nz(get(c, "body", nothing), "")), me) || continue
        when = first(String(nz(get(c, "created_at", nothing), "")), 10)
        return string("@", me, " by ", isempty(who) ? "?" : who, isempty(when) ? "" : string(", ", when))
    end
    ""
end

"""The pull request's diff as `gh pr diff` answers it, or a `FetchError`.

Through `gh_run` rather than `read`, so gh's stderr is captured as the reason
and never printed onto the frame - which is where it went, as a row under the
diff, the one time gh refused one.

That refusal is the diff carrying a terminal escape sequence, which gh will
not write to a pipe without being told to; told to, it answers the same diff,
and `inert` in `hunk_nodes` is what keeps the escape off the terminal. Asked
for on the refusal and not up front: the flag is gh 2.9x, and a gh without it
prints the diff verbatim and would refuse the flag on every diff.
"""
function fetch_diff(it::Item; run = gh_run)
    args = ["pr", "diff", string(it.number), "--repo", it.repo]
    rc, out, err = run(args)
    if rc != 0 && occursin("--allow-escape-sequences", err)
        rc, out, err = run([args; "--allow-escape-sequences"])
    end
    rc == 0 || throw(FetchError(first(strip(isempty(err) ? out : err), 300)))
    out
end

"""One node per hunk, not per file.

A file-sized node makes n/N step over whole files, which is the wrong grain for
reading a change: hunks are the units you actually move between. The file name
stays in each hunk's header so the context is never lost.

**The checkout answers first, gh second.** Both ends of the diff are known -
the head from the lanes, the base branch and where it was on the item - and
a pinned checkout has the objects, or fetches them once as `p` and `]`
already do. So the diff is [`pr_diff`](@ref), computed every time: `git
diff` between two shas is milliseconds and never stale, where `gh pr diff`
by number was cached for two minutes whatever was pushed inside them, and a
request every two minutes past that whether anything moved or not. gh's
answer, under its key and its clock, is for an item with no checkout
pinned, a head the checkout cannot get, or a base it cannot bring up to
date - and for the `stale` flag, which a local answer has no use for.
"""
function diff_nodes(it::Item; fresh::Bool = false, run = gh_run)
    # Issues have no diff, and asking gh for one fails with a GraphQL error
    # rather than an empty result. The assigned lane is full of them.
    it.is_pr || return [Node(string("no diff - this is ", not_pr(it)), "", :plain, true)]
    stale = false
    asof = nothing
    # The commit the hunks are numbered against, for a comment to be pinned
    # to: the head the checkout diffed to, and unknown for gh's copy, which
    # is at the head now for as long as it is fresh - as GitHub's default is.
    at_head = ""
    txt = try
        repo = repo_path(it.repo)
        # `head_sha` asks gh for a head the lanes did not supply, which is
        # worth it only where a checkout could use the answer.
        head = repo === nothing ? it.head : head_sha(it)
        local_ = repo === nothing || isempty(head) ? nothing :
                 pr_diff(repo, it.repo, it.number, it.base, it.base_sha, head)
        if local_ !== nothing
            push!(DIFFED, string(it.url, "@", head))
            at_head = head
            local_
        else
            key = diff_key(it)
            hit = fresh ? nothing : cache_get(key, CACHE_FRESH[]; keep_s = CACHE_KEEP[])
            if hit === nothing
                cache_put(key, fetch_diff(it; run = run))
            else
                stale = hit[2] > CACHE_FRESH[]
                asof = time() - hit[2]
                String(hit[1])
            end
        end
    catch e
        return [failednode("no diff (not a PR, or gh failed)",
                           first(sprint(showerror, e), 200))]
    end
    ns = hunk_nodes(txt, string(it.url, "/files"); head = at_head)
    isempty(ns) && return [Node("empty diff", "", :plain, true)]
    out = place_comments(ns, it)
    stale && !isempty(out) && (out[1].meta["stale"] = true)
    asof === nothing || isempty(out) || (out[1].meta["asof"] = asof)
    out
end

"""Unified diff text as one node per hunk, carrying the ranges that `[`/`]` and
`place_comments` measure against, and `head`, the commit the new side is
numbered against, for `add_review_thread` to pin a comment to - empty when
the text came from gh and the commit is not known.

Its own function because there are two diffs in this program now: the pull
request's whole change, and what has been pushed to it since you last looked.
They differ in where the text comes from and in nothing else, and a second
parser would be a second set of hunk ranges to keep in step with `hunk_line_at`.
"""
function hunk_nodes(txt::AbstractString, url::AbstractString; head::AbstractString = "")
    txt, ctl = inert(txt)
    ns, file, buf, hdr = Node[], "", String[], ""
    # Whether the file is one the change creates: said between `diff --git`
    # and its first `@@`, and nowhere after.
    newfile = false
    pending_range, pending_old = (0, 0), (0, 0)
    flush!() = if !isempty(hdr)
        adds = count(l -> startswith(l, "+") && !startswith(l, "+++"), buf)
        dels = count(l -> startswith(l, "-") && !startswith(l, "---"), buf)
        n = Node(string(file, "  ", hdr, "  +", adds, " -", dels),
                 join(buf, "\n"), :diff, true)
        n.meta["file"] = file
        n.meta["start"] = pending_range[1]
        n.meta["count"] = pending_range[2]
        # The old-side range as well, so a comment left on a deleted line - which
        # GitHub anchors to the LEFT side - can be placed too.
        n.meta["ostart"] = pending_old[1]
        n.meta["ocount"] = pending_old[2]
        n.meta["body"] = join(buf, "\n")      # the hunk itself, without context
        n.meta["up"] = 0
        n.meta["down"] = 0
        n.meta["url"] = String(url)
        n.meta["head"] = String(head)
        n.meta["newfile"] = newfile
        push!(ns, n)
    end
    for l in split(txt, "\n")
        if startswith(l, "diff --git")
            flush!(); hdr = ""; buf = String[]; newfile = false
            file = replace(String(last(split(l, " "))), r"^b/" => "")
        elseif isempty(hdr) && (startswith(l, "new file mode") || l == "--- /dev/null")
            newfile = true
        elseif startswith(l, "@@")
            flush!()
            m = match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", String(l))
            rng = m === nothing ? (0, 0) :
                  (parse(Int, m[3]), m[4] === nothing ? 1 : parse(Int, m[4]))
            old = m === nothing ? (0, 0) :
                  (parse(Int, m[1]), m[2] === nothing ? 1 : parse(Int, m[2]))
            hdr = string("@@ ", rng[1], ",", rng[2], " @@")
            pending_range, pending_old = rng, old
            buf = String[]
        elseif !isempty(hdr)
            push!(buf, String(l))
        end
    end
    flush!()
    isempty(ns) || ctl == 0 || pushfirst!(ns, ctlnode(ctl))
    ns
end

"""The row that says `inert` found something, for the top of a diff.

The first row, not the last: a long diff pushes the bottom off the screen, and
this is a fact about what follows and a reason to read it differently. A plain
node with no `file`, which is what `[`/`]`, `C` and `attach_comments` all step
over.
"""
ctlnode(n::Int) =
    Node(string(THEME.blocked, n, n == 1 ? " control character" : " control characters",
                " in this diff, drawn as ^[ ^G ^M", THEME.reset), "", :plain, true)

"""
    hunk_marks(n) -> Dict{Int,Tuple{Int,Int}}

Which row of a hunk each of its comment threads hangs off: the index into the
node's own lines, and how many threads there are open and settled on it.

The inverse of `hunk_line_at`, and it walks the hunk the same way, so the two
agree about which row is line 544 - including after `[`/`]` has widened the hunk
with context, which moves every row and no line number.

A comment left on the old side is matched against the old numbering, which is
where a remark on a deleted line lives; a context row carries both numbers and
answers to either.
"""
function hunk_marks(n::Node)
    ms = get(n.meta, "cmarks", nothing)
    out = Dict{Int,Tuple{Int,Int}}()
    (ms === nothing || !haskey(n.meta, "start")) && return out
    up = get(n.meta, "up", 0)
    newno = n.meta["start"] - up
    oldno = get(n.meta, "ostart", n.meta["start"]) - up
    for (k, l) in enumerate(split(n.raw, "\n"))
        del, add = startswith(l, "-"), startswith(l, "+")
        for (line, right, done) in ms
            hit = right ? (!del && newno == line) : (!add && oldno == line)
            hit || continue
            (a, b) = get(out, k, (0, 0))
            out[k] = done ? (a, b + 1) : (a + 1, b)
        end
        del ? (oldno += 1) : add ? (newno += 1) : (oldno += 1; newno += 1)
    end
    out
end

"""One line's worth of that, as it is drawn at the end of the row.

The same two marks the hunk header carries, so a count on a header and a mark on
a line read as the same thing said at two grains. A lone open thread says
nothing here: its `💬` stands in the gutter, over the pane's border (`rows`),
and `💬` at the end of the row as well is it said twice. Two or more say their
count, and a settled thread its tick, dim.
"""
markof(m::Union{Nothing,Tuple{Int,Int}}) =
    m === nothing ? "" :
    string(m[1] <= 1 ? "" : string("  ", THEME.accent, "💬", m[1], THEME.reset),
           m[2] == 0 ? "" : string("  ", THEME.dim, "✓", m[2] == 1 ? "" : m[2],
                                   THEME.reset))

"""Where a review comment was pointing: `file.jl:544`, or empty for a plain one.

Falls back to `original_line` when `line` is null, which is how an outdated
comment arrives - it is the wrong line in today's file, but it is the only
number the comment has, and printing nothing there reads as a bug.
"""
function comment_loc(c)
    p = String(nz(get(c, "path", nothing), ""))
    isempty(p) && return ""
    ln = something(get(c, "line", nothing), get(c, "original_line", nothing), "?")
    string("  ", THEME.accent, last(split(p, '/')), ":", ln, THEME.reset)
end

"""Header for one review comment, as it is drawn under its hunk: who, when and
a peek. Not where it pointed - the hunk it hangs off is where, which is the
whole of what `place_comments` is for."""
function comment_header(c)
    who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
    at = when_str(String(nz(get(c, "created_at", nothing), "")))
    peek = strip(first(replace(String(nz(get(c, "body", nothing), "")), r"\s+" => " "), 48))
    (string(who, "  ", at, "   ", peek), string(who, "  ", at))
end

"""
    place_comments(hunks, it) -> Vector{Node}

Hang each review comment off the hunk it was left on.

A review comment carries the file and line it points at, so it belongs against
the code - not at the end of a chronological thread, which is where the `h`
pane necessarily puts it, several screens away from the change it is a question
about.

`line` is the position in the file as it now stands. On a comment left against
a line that has since changed it is null, and only `original_line` survives -
which is a position in a diff that no longer exists. Those are gathered under a
single folded header at the end rather than guessed at: placing one against
whatever now occupies that line number would attach the discussion to unrelated
code, which is worse than not placing it.

Replies are threaded by `in_reply_to_id`; the API returns them flat and in
creation order, and a reply carries the same anchor as its parent.
"""
function place_comments(hunks::Vector{Node}, it::Item)
    cs = try
        Events.review_comments(it.url)
    catch
        return hunks                # the diff is still worth reading without them
    end
    # Which of them are settled. Its own request because REST does not know -
    # resolution is a property of the thread and only GraphQL carries it - and
    # its own failure, because a diff with every comment shown is still a diff.
    done_ = try
        Events.resolved_comments(it.url)
    catch
        Set{Int}()
    end
    attach_comments(hunks, cs, it.url, done_)
end

"The placement itself, given the comments - so it can be tested without GitHub."
function attach_comments(hunks::Vector{Node}, cs, url::AbstractString,
                         resolved::Set{Int} = Set{Int}())
    isempty(cs) && return hunks
    replies = Dict{Any,Vector{Any}}()
    tops = Any[]
    for c in cs
        r = get(c, "in_reply_to_id", nothing)
        r === nothing ? push!(tops, c) : push!(get!(replies, r, Any[]), c)
    end

    "The hunk a comment points into, by file and by the side it was left on."
    function findhunk(c)
        path = String(nz(get(c, "path", nothing), ""))
        line = get(c, "line", nothing)
        line === nothing && return nothing        # outdated: nothing to point at
        right = String(nz(get(c, "side", nothing), "RIGHT")) != "LEFT"
        for (i, n) in enumerate(hunks)
            get(n.meta, "file", "") == path || continue
            st_ = right ? n.meta["start"] : n.meta["ostart"]
            ct = right ? n.meta["count"] : n.meta["ocount"]
            st_ <= line <= st_ + max(ct, 1) - 1 && return i
        end
        nothing
    end

    emit!(out, c, depth) = begin
        (hdr, src) = comment_header(c)
        made = body_nodes!(Node[], hdr, strip(String(nz(get(c, "body", nothing), ""))),
                           String(nz(get(c, "html_url", nothing), url)), true, depth)
        made[1].meta["src"] = src
        made[1].meta["byline"] = src
        made[1].meta["comment_id"] = get(c, "id", nothing)
        made[1].meta["at"] = String(nz(get(c, "created_at", nothing), ""))
        append!(out, made)
        for r in get(replies, get(c, "id", nothing), ())
            emit!(out, r, depth + 1)
        end
    end

    byhunk = Dict{Int,Vector{Any}}()
    orphans = Any[]
    for c in tops
        i = findhunk(c)
        i === nothing ? push!(orphans, c) : push!(get!(byhunk, i, Any[]), c)
    end

    isdone(c) = Int(something(get(c, "id", 0), 0)) in resolved

    out = Node[]
    for (i, n) in enumerate(hunks)
        here = get(byhunk, i, ())
        live = [c for c in here if !isdone(c)]
        settled = [c for c in here if isdone(c)]
        # Two marks, because they say different things: a conversation waiting
        # for an answer is why you are reading the hunk, and one that was
        # answered is why you can stop.
        # Kept as well as appended: `[`/`]` rebuilds this header from the file
        # and the range, and would otherwise drop the tally on the way past.
        n.meta["tally"] = string(
            isempty(live) ? "" : string("  ", THEME.accent, "💬", length(live), THEME.reset),
            isempty(settled) ? "" : string("  ", THEME.dim, "✓", length(settled),
                                           THEME.reset))
        n.header = string(n.header, n.meta["tally"])
        # And the line each thread points at, so the hunk says *where* it is
        # being talked about and not only that it is. Kept as the line number
        # and the side rather than as a row of the hunk, because `[`/`]` widens
        # the hunk upwards and every row index would move.
        marks = Tuple{Int,Bool,Bool}[]
        for c in here
            line = get(c, "line", nothing)
            line === nothing && continue
            push!(marks, (Int(line),
                          String(nz(get(c, "side", nothing), "RIGHT")) != "LEFT",
                          isdone(c)))
        end
        isempty(marks) || (n.meta["cmarks"] = marks)
        push!(out, n)
        for c in live
            emit!(out, c, n.depth + 1)
        end
        if !isempty(settled)
            # Under the hunk they belong to rather than in a pile at the end:
            # resolved is not the same as irrelevant, and the code it was about
            # is the thing that makes it readable at all. Closed, so it costs a
            # row rather than a screen.
            h = Node(string(THEME.dim, "\u2713 ", length(settled), " resolved",
                            length(settled) == 1 ? "" : " threads", THEME.reset),
                     "", :plain, false, n.depth + 1)
            push!(out, h)
            for c in settled
                emit!(out, c, n.depth + 2)
            end
        end
    end
    # Comments whose line is gone. Split the same way, because the two are not
    # the same thing to walk past: a settled conversation about code that has
    # since changed is over twice over, while an open one is a remark nobody
    # answered and the line moving out from under it did not make it moot.
    for (group, label) in ((filter(!isdone, orphans),
                            string(count(!isdone, orphans), " comment",
                                   count(!isdone, orphans) == 1 ? "" : "s",
                                   " on lines that have since changed")),
                           (filter(isdone, orphans),
                            string("\u2713 ", count(isdone, orphans), " resolved, on lines",
                                   " that have since changed")))
        isempty(group) && continue
        # Folded, and folding now hides the run nested under it, so this really
        # does put them away.
        push!(out, Node(string(THEME.dim, label, THEME.reset), "", :plain, false))
        for c in group
            emit!(out, c, 1)
        end
    end
    out
end

# --- what has been pushed since you last looked ------------------------------
#
# The third question about an item, after "what is it" and "what does it
# change": *what changed since I was here*. The thread answers it for the
# conversation - the rule `e` leaves behind - and nothing answered it for the
# branch, which is where it matters most: you already know what the pull request
# does, and what you came back for is the rebase.
#
# It needs two commits and a checkout. The new head rides in on the item
# (`headRefOid`, selected by every lane); the old one is `done_head`, written by
# `e` and by nothing else - or, where `e` wrote none, the refresh's copy on the
# row, `read_head`, the head as of the stamp or the floor the thread's rule is
# drawn at. An item that has neither has no view here and says so - that is
# the honest answer for a pull request nobody has marked done yet, and it
# becomes a real one the first time `e` is pressed on it.

"""One line's worth of `git range-diff`, coloured by which range it is in.

Column five is the *outer* marker - whether this line belongs to the old range,
the new one, or both - and column six is the inner diff the two ranges share.
The outer one is what this view is about, so it is what gets the colour: green
is what the new commits do and the old ones did not, red is the other way
round, and an unmarked line is a change both versions make and neither of them
is the reason you are looking.
"""
function rangeline(l::AbstractString)
    ncodeunits(l) >= 5 || return String(l)
    o = codeunit(l, 5)
    o == UInt8('+') && return string(THEME.diff_add, l, THEME.reset)
    o == UInt8('-') && return string(THEME.diff_del, l, THEME.reset)
    occursin(r"^\s*@@", l) ? string(THEME.diff_meta, l, THEME.reset) : String(l)
end

"""How `git range-diff` marks each pair of commits, and what it means here.

Padded to ten in the header rather than to nine, because "unchanged" is nine
characters long and ran straight into the sha beside it. A function rather than
a `Dict` for the reason `rev_mark` is one: a table of colours built when the
module loads is built before the theme is read.
"""
range_mark(c::Char) =
    c == '=' ? (THEME.dim, "unchanged") :
    c == '!' ? (THEME.waiting, "changed") :
    c == '<' ? (THEME.diff_del, "gone") :
    c == '>' ? (THEME.diff_add, "new") : nothing

"""Where one pair of commits ends and the next begins in `git range-diff` output.

**There is no porcelain mode.** `git range-diff -h` on 2.54.0 offers
`--no-dual-color`, `--creation-factor`, `--left-only`/`--right-only`, `--notes`
and the ordinary diff-format options - and those last apply to the *inner*
diffs, so `--raw` or `-z` would destroy the patch text that is the whole point
while leaving the pair header exactly as it is. So this reads the human output,
and the only question is which invariant to lean on.

Not the shape of the header, which is what two bugs came from. Past nine commits
git right-aligns the numbers, so every row of a ten-commit range-diff is
indented by one and an anchored `^` plus a digit matched none of them - a rebase
came out as "no textual change". Allowing leading whitespace instead then matched the
*wrong* lines: a diff whose own content looks like a range-diff header - which
`cli/test/suite/since.jl` is now full of - was read as three commits where git
reported one, and the real diff went under an invented heading.

The invariant that holds is the indent. Every line of an inner diff is indented
by exactly four spaces before its dual-color marker; a pair header's leading
spaces are number padding and there are `len(string(n)) - 1` of them. So four
spaces means body, and nothing else does. It fails only for a range of ten
thousand commits or more, where the padding reaches four - at which point the
pane shows one unfolded node rather than an invented structure, which is the
right way round.

`git range-diff -s` is the escape hatch if this ever needs more: it prints the
pair headers and nothing else, so splitting the full output at exactly those
lines needs no pattern at all. It is not used because it pays for the whole
cost matrix a second time, and that is the expensive half of a range-diff.
"""
const RANGE_PAIR =
    r"^(?! {4})\s*(\d+|-):\s+(\S+)\s+([=!<>])\s+(\d+|-):\s+(\S+)\s*(.*)$"

"""`git range-diff` output as one node per commit.

The same grain the diff pane uses for hunks and for the same reason: a commit is
the unit you move between with `n`/`N`, and a rebase of forty is forty things to
walk rather than one wall of text. A commit the rebase left alone folds to its
header, which is all anybody wants of it.
"""
function rangediff_nodes(txt::AbstractString)
    txt, ctl = inert(txt)
    ns, buf = Node[], String[]
    flush!() = if !isempty(ns) && !isempty(buf)
        ns[end].raw = join((rangeline(l) for l in buf), "\n")
        empty!(buf)
    end
    for l in split(txt, "\n")
        m = match(RANGE_PAIR, String(l))
        if m === nothing
            isempty(ns) || push!(buf, String(l))
            continue
        end
        flush!()
        (col, what) = something(range_mark(first(m[3])), (THEME.reset, String(m[3])))
        # Which sha to show: the one that still exists. A commit the rebase
        # dropped has no new sha and a commit it added has no old one, and
        # `-------` is not something to put in front of a subject line.
        sha = m[5] == "-------" ? m[2] : m[5]
        n = Node(string(col, rpad(what, 10), THEME.reset,
                        THEME.dim, first(sha, 8), THEME.reset, "  ", m[6]),
                 "", :plain, first(m[3]) != '=')
        n.meta["src"] = string(what, "  ", first(sha, 8), "  ", m[6])
        # What `o` opens, anywhere on the node: the pair is one commit.
        n.meta["sha"] = String(sha)
        n.meta["byline"] = string(col, rpad(what, 10), THEME.reset,
                                  THEME.dim, first(sha, 8), THEME.reset)
        push!(ns, n)
    end
    flush!()
    isempty(ns) || ctl == 0 || pushfirst!(ns, ctlnode(ctl))
    ns
end

"""What has been pushed to this branch since the done mark was made.

Every way this can have nothing to show is a sentence rather than an empty pane
or an error, because each of them is a different thing to do about it: press
`e`, pin a checkout, or nothing at all because nothing was pushed.
"""
function pushed_nodes(it::Item)
    it.is_pr || return [Node(string("no pushes - this is ", not_pr(it)), "", :plain, true)]
    old = done_head(it.url)
    old === nothing && !isempty(it.read_head) && (old = it.read_head)
    old === nothing &&
        return [Node("nothing to compare against yet",
                     "This view is the diff between the head commit you last " *
                     "looked at and the head commit now, and the first half of " *
                     "that is written by `e`.\n\nMark it done once and the next " *
                     "time it comes back unread, this pane is the rebase.",
                     :md, true)]
    new = head_sha(it)
    isempty(new) &&
        return [failednode("could not determine the head commit",
                           string("You last saw ", first(old, 8),
                                  "; GitHub did not answer with what it is now."))]
    old == new &&
        return [Node("nothing pushed since you last looked",
                     string("The branch is still at `", first(new, 8),
                            "`, which is where it was when you marked this done.\n\n" *
                            "`h` has what has been *said* since then."), :md, true)]
    repo = repo_path(it.repo)
    repo === nothing &&
        return [Node(string("no checkout pinned for ", it.repo),
                     string("The two commits are `", first(old, 8), "` and `",
                            first(new, 8), "`, and diffing them is a local " *
                            "operation - GitHub has no endpoint that compares " *
                            "two heads of the same pull request.\n\nPress `o`, " *
                            "`t` or `T` on this item to pin one, or " *
                            "`wl repo add ", it.repo, " <path>`."), :md, true)]
    rem = remote_for(repo, it.repo)
    for sha in (old, new)
        ensure_commit!(repo, sha, it.number; remote = rem) ||
            return [failednode(string("commit ", first(sha, 8), " is not in ", repo),
                               "It could not be fetched either. A head that was " *
                               "force-pushed away is normally still served by " *
                               "sha - see `ensure_commit!` for the measurement - " *
                               "so this is a repository or a network that is not " *
                               "answering rather than a commit that is gone.")]
    end
    # The branch this is to be merged into, brought up to date, because the
    # merge base against it is what separates their commits from its own. Only
    # here: it is one more round trip, and it is worth it exactly when there is
    # a range to measure.
    base = ensure_base!(repo, it.repo, it.base)
    mv = try
        branch_moved(repo, old, new; base = base)
    catch e
        return [failednode("could not diff the two heads",
                           first(sprint(showerror, e), 200))]
    end
    kind, txt = mv.kind, mv.text
    # What happened, in the order somebody would say it. A rebase whose commit
    # count did not change says so by not mentioning it, which is the common
    # case and the one where the count would be noise.
    said = kind === :diff ?
           string(THEME.settled, mv.now - mv.then,
                  mv.now - mv.then == 1 ? " commit" : " commits", " added",
                  THEME.reset) :
           string(THEME.waiting, mv.moved > 0 ? "rebased" : "rewritten", THEME.reset,
                  mv.moved > 0 ?
                  string(THEME.dim, "  onto ", mv.moved, " newer ",
                         mv.moved == 1 ? "commit" : "commits", THEME.reset) : "",
                  mv.then == mv.now ? "" :
                  string(THEME.dim, "  ", mv.now, mv.now == 1 ? " commit" : " commits",
                         ", was ", mv.then, THEME.reset))
    lead = Node(string(said, "  ", THEME.dim, first(old, 8), " → ", first(new, 8),
                       THEME.reset),
                kind === :diff ?
                "The head you saw is still in this branch's history and the base " *
                "has not moved under it, so this is the plain diff from that head " *
                "to the head now." :
                string("The commits are different objects now, so this is a ",
                       "`git range-diff`: the old commits paired with the new ",
                       "ones, and what differs between each pair.",
                       isempty(base) ? "\n\nMeasured from where the two heads " *
                       "meet, because this item has no base branch to measure " *
                       "from - so commits the base gained in between are counted " *
                       "here as pushed." :
                       string("\n\nEach side is measured from `", base,
                              "`, so the base's own commits are the number above ",
                              "rather than rows in the list.")), :md, false)
    lead.meta["src"] = string(first(old, 8), " → ", first(new, 8))
    lead.meta["url"] = string(it.url, "/files")
    ns = kind === :diff ? hunk_nodes(txt, string(it.url, "/files"); head = new) :
                          rangediff_nodes(txt)
    isempty(ns) && return [lead, Node("no textual change", "", :plain, true)]
    pushfirst!(ns, lead)
    ns
end

"What a row with no pull request is, for a pane that shows only pull requests."
not_pr(it::Item) = islocal(it) ? "a local branch, not yet a pull request" :
                                 "an issue, not a pull request"

"""A load that failed, marked as such.

A background refresh has to be able to tell a fetch that came back from one that
did not: what it does on failure is keep what is already on screen, and the
alternative is replacing a thread somebody is reading with an error about a
request they never asked for.
"""
function failednode(header::AbstractString, body::AbstractString)
    n = Node(String(header), String(body), :plain, true)
    n.meta["failed"] = true
    n
end

"""What `mode` shows for `it`, as nodes.

The thread and what was pushed are about the item's repository, and say so on
each node, which is what makes a `#123` or a sha in them a link to it
(`autolink`). The diff is code and the checks are logs, whose hex runs are
tree hashes and build ids, and neither is told.
"""
function mode_nodes(mode::Symbol, it::Item, at::DateTime; fresh::Bool = false)
    ns = mode === :comments ? comment_nodes(it, at; fresh = fresh) :
         mode === :diff     ? diff_nodes(it; fresh = fresh) :
         mode === :pushed   ? pushed_nodes(it) : check_nodes(it; fresh = fresh)
    if mode in (:comments, :pushed) && !isempty(it.repo)
        for n in ns
            n.meta["repo"] = it.repo
        end
    end
    ns
end

"""Is there a cached copy of what `mode` shows for `it` - anything at all to put
up without a request? The pushed view reads a local checkout and has nothing to
wait for."""
mode_cached(mode::Symbol, it::Item) =
    mode === :comments ? cache_has(thread_key(it.url)) :
    mode === :diff     ? (!it.is_pr || cache_has(diff_key(it)) ||
                          string(it.url, "@", it.head) in DIFFED) :
    mode === :checks   ? (!it.is_pr || cache_has(checks_key(it.repo, it.number))) : true
