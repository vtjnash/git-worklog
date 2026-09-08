
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
            body_nodes!(ns, "…", content, url, true, depth + 1)
        end
    end
    ns
end
body_nodes(header, body, url, open::Bool) = body_nodes!(Node[], header, body, url, open)

function comment_nodes(it::Item, at::DateTime; fresh::Bool = false)
    local body, cs
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
            body, cs = Events.thread(it.url; limit = 30)
            cache_put(key, (body = body, comments = cs))
        else
            body, cs = hit[1].body, hit[1].comments
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
    btxt = strip(replace(nz(get(body, "body", nothing), ""), "\r\n" => "\n"))
    if !isempty(btxt)
        body_nodes!(ns, string(nz(who0, "?"), " opened this"), btxt,
                    String(nz(get(body, "html_url", nothing), it.url)), true)
    end
    for c in cs
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
        when = first(String(c["created_at"]), 16)
        txt = strip(replace(nz(get(c, "body", nothing), ""), "\r\n" => "\n"))
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
        n.meta["url"] = string(it.url, "/files")
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
    isempty(ns) && return [Node("empty diff", "", :plain, true)]
    out = place_comments(ns, it)
    stale && !isempty(out) && (out[1].meta["stale"] = true)
    out
end

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
        made = body_nodes!(Node[], hdr, strip(replace(String(nz(get(c, "body", nothing), "")),
                                                      "\r\n" => "\n")),
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
        n.header = string(n.header,
                          isempty(live) ? "" : string("  ", CYA, "💬", length(live), AR),
                          isempty(settled) ? "" : string("  ", AD, "✓", length(settled), AR))
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
    mode === :diff     ? diff_nodes(it; fresh = fresh) : check_nodes(it)
