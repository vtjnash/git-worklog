
# --- content loading -------------------------------------------------------

"""How long a cached thread or diff is current, and how long it is worth
showing at all.

Two numbers, because they answer different questions. Past `DETAIL_TTL` the
entry is out of date and wants re-reading - but it is still what was on the page
ten minutes ago, so it goes up at once and the fetch runs behind it: a browser
that opens should not be a browser that waits. Past `DETAIL_KEEP` it is not
worth showing at all and the fetch blocks, because a week-old thread on screen
is worse than a pause in front of one.
"""
const DETAIL_TTL = Ref(600.0)
const DETAIL_KEEP = Ref(7 * 86_400.0)

"""How long an item has to stay selected before a stale entry is re-read.

A debounce and not a delay. Holding `j` down passes twenty stale entries, and a
request for each would spend the whole point of the cache on items nobody read;
a second of the item actually being on screen is the difference between reading
it and going past it.
"""
const REFRESH_AFTER = Ref(1.0)

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
    when = first(run[end]["at"], 16)
    # The last commit's author, which is whose push it was except where a run
    # collected two people's. A list of names on the header would be a byline
    # about the push rather than about a person, which is not what a byline is.
    who = isempty(run[end]["by"]) ? "" : string(run[end]["by"], "  ")
    peek = strip(first(replace(String(run[end]["headline"]), r"\s+" => " "), 58))
    body = join((string(first(c["oid"], 8), "  ", first(c["at"], 16), "  ",
                        oneline(c["headline"])) for c in Iterators.reverse(run)), "\n")
    hd = string(GRN, "↑ pushed ", n, n == 1 ? " commit" : " commits", AR)
    nd = Node(string(hd, "  ", AD, who, when, AR, "   ", peek), body, :plain, n <= 3)
    nd.meta["byline"] = string(hd, "  ", AD, who, when, AR)
    nd.meta["src"] = string("pushed ", n, n == 1 ? " commit" : " commits",
                            "  ", astrip(who), when)
    # The branch's own page, since a push is not a comment and has no anchor in
    # the thread to point at.
    nd.meta["url"] = string(url, "/commits")
    nd.meta["push"] = n
    nd
end

"""The rule the new part of a thread begins under.

Drawn from the read stamp alone, which is the whole of what it needs: `r` marks
the thread read up to the moment it was *fetched*, so everything written before
that stamp was on screen and everything written after it was not. There is no
second record of where you had got to, because a second record is a second
answer that can disagree with this one.

It is a node rather than a decoration so that `n`/`N` reaches it, folding above
it works, and `collect_pending!` has something to open the pane on.
"""
function newmark_node(n::Int)
    nd = Node(string(YEL, "new since you last looked", AR, "  ", AD,
                     n, n == 1 ? " entry" : " entries", AR),
              "", :plain, true)
    nd.meta["newmark"] = true
    nd.meta["src"] = "--- new since you last looked ---"
    nd
end

"""Consecutive pushes folded into one entry, keeping everything else in place.

The run is stamped at its *last* commit, so a push that is half older than the
read mark still lands wholly below the rule. That is the safe direction: it
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

function comment_nodes(it::Item, at::DateTime; fresh::Bool = false)
    local body, cs, cms
    stale = false
    # When the fetch *started*, which is the whole reason `at` is threaded here
    # rather than read off a clock below. `r` marks the thread read up to this,
    # so a comment that arrived while the request was in flight has to stay
    # unread - stamping on the way out would mark it seen without it ever
    # having been on screen.
    fetched = stamp(at)
    try
        key = "thread:" * it.url
        hit = fresh ? nothing : cache_get(key, DETAIL_TTL[]; keep_s = DETAIL_KEEP[])
        if hit === nothing
            body, cs, cms = Events.thread(it.url; limit = 30)
            cache_put(key, (body = body, comments = cs, commits = cms))
        else
            body, cs = hit[1].body, hit[1].comments
            # Absent on an entry written before the pushes were drawn in here.
            # A thread kept for a week is worth showing without them rather
            # than dropped for want of a field that is new.
            cms = something(jget(hit[1], :commits), ())
            stale = hit[2] > DETAIL_TTL[]
            # When this thread was actually read from GitHub, not when it came
            # out of the cache. Measured back from the start of *this*
            # operation, so the answer errs early rather than late - the age
            # was taken a moment after `at`, and reading up to too early a
            # point leaves a comment unread, which is the safe direction.
            fetched = stamp(at - Millisecond(round(Int, 1000 * hit[2])))
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
    end
    # The activity list: comments and pushes in the order they happened, which
    # is one sequence and was being read as two. "They replied, then pushed,
    # then replied" is the shape of most review conversations, and the pushes
    # were a field on the item while the replies were the pane.
    #
    # Only the pushes that fall inside the window the comments are shown for -
    # the thread is the last thirty of those - so a branch with two hundred
    # commits does not arrive above the first thing anybody said.
    from = isempty(cs) ? "" : String(first(cs)["created_at"])
    evs = Any[(kind = :comment, at = String(c["created_at"]), c = c) for c in cs]
    for c in cms
        t = String(c["at"])
        (isempty(from) || t >= from) && push!(evs, (kind = :push, at = t, c = c))
    end
    # A commit and a comment stamped the same second: the commit first, because
    # the reply is about the push in that case and never the other way round.
    sort!(evs; by = e -> (e.at, e.kind === :push ? 0 : 1))
    evs = group_pushes(evs)
    # Where the new part starts, and how much of it there is. Nothing at all for
    # an item never marked read: the whole thread is new then, and a rule above
    # the first line of it says nothing.
    seen = read_at(it.url)
    mk = seen === nothing ? nothing : findfirst(e -> e.at > seen, evs)
    mark = mk === nothing ? 0 : mk
    for (k, e) in enumerate(evs)
        k == mark && push!(ns, newmark_node(length(evs) - mark + 1))
        if e.kind === :push
            push!(ns, push_node(e.c, it.url))
            continue
        end
        c = e.c
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
        when = first(String(c["created_at"]), 16)
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
        # Only a review comment can be replied to in a thread; an issue comment
        # has no thread to reply into, so `c` there writes a new one.
        isempty(loc) || (made[1].meta["comment_id"] = get(c, "id", nothing))
        append!(ns, made)
    end
    isempty(ns) || (ns[1].meta["fetched"] = fetched)
    out = isempty(ns) ? [Node("no comments", "", :plain, true)] : ns
    stale && (out[1].meta["stale"] = true)
    out
end

"""One node per hunk, not per file.

A file-sized node makes n/N step over whole files, which is the wrong grain for
reading a change: hunks are the units you actually move between. The file name
stays in each hunk's header so the context is never lost.
"""
function diff_nodes(it::Item; fresh::Bool = false)
    # Issues have no diff, and asking gh for one fails with a GraphQL error
    # rather than an empty result. The assigned lane is full of them.
    it.is_pr || return [Node("no diff - this is an issue, not a pull request",
                             "", :plain, true)]
    stale = false
    txt = try
        key = string("diff:", it.repo, "#", it.number)
        hit = fresh ? nothing : cache_get(key, DETAIL_TTL[]; keep_s = DETAIL_KEEP[])
        if hit === nothing
            cache_put(key, read(`gh pr diff $(it.number) --repo $(it.repo)`, String))
        else
            stale = hit[2] > DETAIL_TTL[]
            String(hit[1])
        end
    catch e
        return [failednode("no diff (not a PR, or gh failed)",
                           first(sprint(showerror, e), 200))]
    end
    ns = hunk_nodes(txt, string(it.url, "/files"))
    isempty(ns) && return [Node("empty diff", "", :plain, true)]
    out = place_comments(ns, it)
    stale && !isempty(out) && (out[1].meta["stale"] = true)
    out
end

"""Unified diff text as one node per hunk, carrying the ranges that `[`/`]` and
`place_comments` measure against.

Its own function because there are two diffs in this program now: the pull
request's whole change, and what has been pushed to it since you last looked.
They differ in where the text comes from and in nothing else, and a second
parser would be a second set of hunk ranges to keep in step with `hunk_line_at`.
"""
function hunk_nodes(txt::AbstractString, url::AbstractString)
    ns, file, buf, hdr = Node[], "", String[], ""
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
        push!(ns, n)
    end
    for l in split(txt, "\n")
        if startswith(l, "diff --git")
            flush!(); hdr = ""; buf = String[]
            file = replace(String(last(split(l, " "))), r"^b/" => "")
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
    ns
end

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
a line read as the same thing said at two grains. The number is left off a lone
thread: `💬` on the line is the sentence, and `💬1` is it said twice.
"""
markof(m::Union{Nothing,Tuple{Int,Int}}) =
    m === nothing ? "" :
    string(m[1] == 0 ? "" : string("  ", CYA, "💬", m[1] == 1 ? "" : m[1], AR),
           m[2] == 0 ? "" : string("  ", AD, "✓", m[2] == 1 ? "" : m[2], AR))

"""Where a review comment was pointing: `file.jl:544`, or empty for a plain one.

Falls back to `original_line` when `line` is null, which is how an outdated
comment arrives - it is the wrong line in today's file, but it is the only
number the comment has, and printing nothing there reads as a bug.
"""
function comment_loc(c)
    p = String(nz(get(c, "path", nothing), ""))
    isempty(p) && return ""
    ln = something(get(c, "line", nothing), get(c, "original_line", nothing), "?")
    string("  ", CYA, last(split(p, '/')), ":", ln, AR)
end

"""Header for one review comment, as it is drawn under its hunk: who, when and
a peek. Not where it pointed - the hunk it hangs off is where, which is the
whole of what `place_comments` is for."""
function comment_header(c)
    who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
    at = first(String(nz(get(c, "created_at", nothing), "")), 16)
    peek = strip(first(replace(String(nz(get(c, "body", nothing), "")), r"\s+" => " "), 48))
    (string(who, "  ", at, "   ", peek), string(who, "  ", at))
end

"""
    place_comments(hunks, it) -> Vector{Node}

Hang each review comment off the hunk it was left on.

A review comment carries the file and line it points at, so it belongs against
the code - not at the end of a chronological thread, which is where the `o`
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
            isempty(live) ? "" : string("  ", CYA, "💬", length(live), AR),
            isempty(settled) ? "" : string("  ", AD, "✓", length(settled), AR))
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
            h = Node(string(AD, "\u2713 ", length(settled), " resolved",
                            length(settled) == 1 ? "" : " threads", AR),
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
        push!(out, Node(string(AD, label, AR), "", :plain, false))
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
# conversation - the rule `r` leaves behind - and nothing answered it for the
# branch, which is where it matters most: you already know what the pull request
# does, and what you came back for is the rebase.
#
# It needs two commits and a checkout. The new head rides in on the item
# (`headRefOid`, selected by every lane); the old one is `read_head`, written by
# `r` and by nothing else. An item that has neither has no view here and says
# so - that is the honest answer for a pull request nobody has marked read yet,
# and it becomes a real one the first time `r` is pressed on it.

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
    o == UInt8('+') && return string(GRN, l, AR)
    o == UInt8('-') && return string(RED, l, AR)
    occursin(r"^\s*@@", l) ? string(AD, l, AR) : String(l)
end

"""How `git range-diff` marks each pair of commits, and what it means here."""
# Padded to ten in the header rather than to nine, because "unchanged" is nine
# characters long and ran straight into the sha beside it.
const RANGE_MARK = Dict('=' => (AD, "unchanged"), '!' => (YEL, "changed"),
                        '<' => (RED, "gone"), '>' => (GRN, "new"))

"""`git range-diff` output as one node per commit.

The same grain the diff pane uses for hunks and for the same reason: a commit is
the unit you move between with `n`/`N`, and a rebase of forty is forty things to
walk rather than one wall of text. A commit the rebase left alone folds to its
header, which is all anybody wants of it.
"""
function rangediff_nodes(txt::AbstractString)
    ns, buf = Node[], String[]
    flush!() = if !isempty(ns) && !isempty(buf)
        ns[end].raw = join((rangeline(l) for l in buf), "\n")
        empty!(buf)
    end
    for l in split(txt, "\n")
        # Leading space allowed, and it is not cosmetic: past nine commits git
        # right-aligns the numbers, so every row of a ten-commit range-diff is
        # indented by one and an anchored `^\d` matches none of them. A pane
        # that said "no textual change" about a rebase was this.
        m = match(r"^\s*(\d+|-):\s+(\S+)\s+([=!<>])\s+(\d+|-):\s+(\S+)\s*(.*)$", String(l))
        if m === nothing
            isempty(ns) || push!(buf, String(l))
            continue
        end
        flush!()
        (col, what) = get(RANGE_MARK, first(m[3]), (AR, String(m[3])))
        # Which sha to show: the one that still exists. A commit the rebase
        # dropped has no new sha and a commit it added has no old one, and
        # `-------` is not something to put in front of a subject line.
        sha = m[5] == "-------" ? m[2] : m[5]
        n = Node(string(col, rpad(what, 10), AR, AD, first(sha, 8), AR, "  ", m[6]),
                 "", :plain, first(m[3]) != '=')
        n.meta["src"] = string(what, "  ", first(sha, 8), "  ", m[6])
        n.meta["byline"] = string(col, rpad(what, 10), AR, AD, first(sha, 8), AR)
        push!(ns, n)
    end
    flush!()
    ns
end

"""What has been pushed to this branch since the read mark was made.

Every way this can have nothing to show is a sentence rather than an empty pane
or an error, because each of them is a different thing to do about it: press
`r`, pin a checkout, or nothing at all because nothing was pushed.
"""
function pushed_nodes(it::Item)
    it.is_pr || return [Node("no pushes - this is an issue, not a pull request",
                             "", :plain, true)]
    old = read_head(it.url)
    old === nothing &&
        return [Node("nothing to compare against yet",
                     "This view is the diff between the head commit you last " *
                     "looked at and the head commit now, and the first half of " *
                     "that is written by `r`.\n\nMark it read once and the next " *
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
                            "`, which is where it was when you marked this read.\n\n" *
                            "`o` has what has been *said* since then."), :md, true)]
    repo = repo_path(it.repo)
    repo === nothing &&
        return [Node(string("no checkout pinned for ", it.repo),
                     string("The two commits are `", first(old, 8), "` and `",
                            first(new, 8), "`, and diffing them is a local " *
                            "operation - GitHub has no endpoint that compares " *
                            "two heads of the same pull request.\n\nPress `e`, " *
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
           string(GRN, mv.now - mv.then, mv.now - mv.then == 1 ? " commit" : " commits",
                  " added", AR) :
           string(YEL, mv.moved > 0 ? "rebased" : "rewritten", AR,
                  mv.moved > 0 ?
                  string(AD, "  onto ", mv.moved, " newer ",
                         mv.moved == 1 ? "commit" : "commits", AR) : "",
                  mv.then == mv.now ? "" :
                  string(AD, "  ", mv.now, mv.now == 1 ? " commit" : " commits",
                         ", was ", mv.then, AR))
    lead = Node(string(said, "  ", AD, first(old, 8), " → ", first(new, 8), AR),
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
    ns = kind === :diff ? hunk_nodes(txt, string(it.url, "/files")) : rangediff_nodes(txt)
    isempty(ns) && return [lead, Node("no textual change", "", :plain, true)]
    pushfirst!(ns, lead)
    ns
end

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

mode_nodes(mode::Symbol, it::Item, at::DateTime; fresh::Bool = false) =
    mode === :comments ? comment_nodes(it, at; fresh = fresh) :
    mode === :diff     ? diff_nodes(it; fresh = fresh) :
    mode === :pushed   ? pushed_nodes(it) : check_nodes(it)
