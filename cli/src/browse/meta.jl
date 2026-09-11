
# --- the metadata pane ------------------------------------------------------

"""One person's review, as the colour and the glyph it is drawn in.

A function and not the `Dict` this was, because a `Dict` is built when the
module loads and `__init__` reads the theme after that - so it would have
captured five empty strings, once, for good. Every colour in the program is a
field read at the moment of drawing for the same reason.
"""
rev_mark(state::AbstractString) =
    state == "APPROVED" ? (THEME.settled, "✓") :
    state == "CHANGES_REQUESTED" ? (THEME.blocked, "✗") :
    state == "COMMENTED" ? (THEME.dim, "·") :
    state == "DISMISSED" ? (THEME.dim, "✗") :
    state == "PENDING" ? (THEME.waiting, "…") : (THEME.dim, "?")

"""
    load_meta!(st)

Fetch what the metadata pane needs for the selected item, off the key loop.

Separate from `load_nodes!` because it does not change with the mode: switching
between the thread, the diff and the checks re-reads the body three times, but
the reviewers and the labels are the same each time.
"""
function load_meta!(st::BState; fresh::Bool = false)
    (isempty(st.items) || st.sel == 0) && return
    it = st.items[st.sel]
    (st.metakey == it.url || (st.metapending !== nothing && st.metakey == it.url)) && return
    st.metakey = it.url
    st.meta = nothing
    st.checks = nothing
    # `R` reads past the checks' own window, so it cannot join the ordinary
    # read of the same item - that is the read it was pressed to go past.
    st.metapending = fetching(string("meta ", it.url, fresh ? " fresh" : "")) do
        try
            # Listing sessions is a process, so it rides along with the fetch
            # that is already off the key loop rather than happening per frame.
            (meta = Events.itemmeta(it.url, it.is_pr),
             checks = it.is_pr ?
                 check_contexts(it.repo, it.number; ttl = fresh ? 0.0 : 120.0) : nothing,
             sessions = mux_list())
        catch e
            (meta = nothing, checks = nothing, sessions = String[],
             err = first(sprint(showerror, e), 120))
        finally
            st.wake === nothing || st.wake()
        end
    end
end

function collect_meta!(st::BState)
    st.metapending === nothing && return false
    istaskdone(st.metapending) || return false
    r = try
        fetch(st.metapending)
    catch
        (meta = nothing, checks = nothing)
    end
    st.meta = r.meta
    st.checks = r.checks
    hasproperty(r, :sessions) && (st.sessions = r.sessions)
    # A draft left on this pull request by an earlier session, which nothing
    # here would otherwise know about. This is also the only thing that ever
    # contradicts the `drafts` lane: the mark is written by this program as it
    # writes comments, and a review submitted from github.com would leave one
    # standing forever - so what the metadata says about the item on screen is
    # taken as the answer, in both directions.
    if st.meta !== nothing && !isempty(st.metakey)
        if !isempty(get(st.meta, :pending, ""))
            haskey(st.drafts, st.metakey) ||
                (draft!(st.metakey); st.drafts = load_drafts())
            # Adopted only when the batch in hand is nothing or is this item's
            # own: a draft being carried on another item must not be dropped for
            # one read off this one. The count comes from this session where
            # there is one, since a review read back does not carry it.
            if st.batch === nothing || st.batch.url == st.metakey
                i = findfirst(x -> x.url == st.metakey, st.all)
                i === nothing || (st.batch = mkbatch(st.metakey, st.all[i].ref,
                                                    st.meta.pending,
                                                    st.batch === nothing ? 0 : st.batch.n))
            end
        elseif haskey(st.drafts, st.metakey)
            # Gone: sent or discarded somewhere else. The row is left where it
            # is until the list is next rebuilt - this arrives while you are
            # reading, and nothing you are reading should move underneath you.
            undraft!(st.metakey); st.drafts = load_drafts()
            st.batch === nothing || st.batch.url != st.metakey || (st.batch = nothing)
        end
    end
    st.metapending = nothing
    true
end

"""A GitHub timestamp as `2026-09-08 01:36`, or `""` for anything unparseable.

Its own function because "" has to survive it: a synthetic row - an unread
thread the poll found, an adopted branch - carries no timestamps at all, and the
metadata pane skips an empty value rather than printing an empty row.
"""
when_str(s::AbstractString) =
    length(s) >= 16 && s[11] == 'T' ? string(s[1:10], " ", s[12:16]) : ""

"""Lines for the metadata pane: what is true of this item, rather than what is
in it.

Everything cheap comes from the fetched row and is on screen immediately; the two
that need a request - who has actually reviewed, and the per-check breakdown -
arrive when `load_meta!` lands and say so until then.
"""
function meta_lines(st::BState, it::Union{Nothing,Item}, w::Int)
    it === nothing && return String[]
    out = String[]
    head(t) = push!(out, string(THEME.bold, t, THEME.reset))
    kv(k, v) = isempty(string(v)) ? nothing :
               push!(out, string(THEME.dim, rpad(k, 10), THEME.reset,
                                 afit(string(v), max(4, w - 10))))
    wait_ = st.metakey == it.url && st.metapending !== nothing

    if it.is_pr
        dec = it.review_decision
        head(string("reviews", isempty(dec) ? "" :
                    string("  ", dec == "APPROVED" ? THEME.settled :
                                 dec == "CHANGES_REQUESTED" ? THEME.blocked :
                                 THEME.waiting,
                           lowercase(replace(dec, "_" => " ")), THEME.reset)))
        m = st.meta
        if m === nothing
            push!(out, string(THEME.dim, wait_ ? "  loading…" : "  —", THEME.reset))
        else
            for r in m.reviews
                (col, mark) = rev_mark(r.state)
                push!(out, string("  ", col, mark, THEME.reset, " ",
                                  afit(rpad(r.login, 16), max(4, w - 6)),
                                  THEME.dim, first(r.at, 10), THEME.reset))
            end
            for who in vcat(m.requested, ["@" * t for t in m.teams])
                push!(out, string("  ", THEME.waiting, "○", THEME.reset, " ",
                                  afit(rpad(who, 16), max(4, w - 6)),
                                  THEME.dim, "requested", THEME.reset))
            end
            isempty(m.reviews) && isempty(m.requested) && isempty(m.teams) &&
                push!(out, string(THEME.dim, "  nobody yet", THEME.reset))
        end
        it.unresolved > 0 &&
            push!(out, string("  ", THEME.waiting, it.unresolved, " unresolved thread",
                              it.unresolved == 1 ? "" : "s", THEME.reset))
        push!(out, "")

        head("checks")
        c = st.checks
        if c === nothing
            push!(out, string("  ", isempty(it.ci) ? (wait_ ? "loading…" : "—") :
                              string(ci_color(it.ci), lowercase(it.ci), THEME.reset)))
        else
            tally = Dict{String,Int}()
            for x in c.contexts
                k = uppercase(x.state)
                tally[k] = get(tally, k, 0) + 1
            end
            parts = [string(ci_color(k), get(Dict("SUCCESS" => "✓", "FAILURE" => "✗",
                            "ERROR" => "✗", "PENDING" => "…"), k, "·"), " ", n, THEME.reset)
                     for (k, n) in sort(collect(tally); by = first)]
            push!(out, string("  ", isempty(parts) ?
                                    string(THEME.dim, "none", THEME.reset) :
                                    join(parts, "  ")))
        end
        push!(out, "")
    end

    if !isempty(it.labels)
        head("labels")
        for l in awrap(join(it.labels, ", "), max(8, w - 2))
            push!(out, string("  ", THEME.accent, l, THEME.reset))
        end
        push!(out, "")
    end

    kv("author", it.author)
    st.meta === nothing || isempty(st.meta.assignees) ||
        kv("assignee", join(st.meta.assignees, ", "))
    # How old it is and when it last changed at all. Both are on the item
    # already and neither was on screen, so the age of what you are reading had
    # to be guessed from the comment dates - and a pull request opened in 2022
    # reads very differently from one opened on Tuesday. To the minute and no
    # further: seconds are noise, and the zone is UTC everywhere in this
    # program, which is why it is not printed either.
    #
    # `updated` is GitHub's own, so a label edit moves it. That is a different
    # fact from `act` - the head commit or the last comment - and the lanes are
    # ordered by `act` precisely because this one moves for things nobody did.
    kv("created", when_str(it.created))
    kv("updated", when_str(it.updated))
    kv("milestone", string(it.milestone,
                           isempty(it.milestone_due) ? "" : string("  (", it.milestone_due, ")")))
    # Only while it is open. Once it is merged or closed there is no merge left
    # to be possible, and a snapshot taken before the merge would otherwise go
    # on saying "conflicting" about something that is over. The refresh drops
    # the value at the same edge; this is the half that is right about a
    # snapshot written before it did.
    it.is_pr && (isempty(it.state) || it.state == "OPEN") &&
        kv("mergeable", it.mergeable == "CONFLICTING" ?
                        string(THEME.blocked, "conflicting", THEME.reset) :
                        lowercase(it.mergeable))
    isempty(it.secondlook) ||
        kv("quiet", string(THEME.waiting, it.secondlook, THEME.reset))
    b = batch_of(st, it)
    b === nothing ||
        kv("draft", string(THEME.waiting, b.n,
                           b.n == 1 ? " comment" : " comments", THEME.reset,
                           "  ", THEME.dim, "c adds one \u00b7 A sends them",
                           THEME.reset))
    if haskey(st.archived, it.url)
        kv("archived", string("filed away", "  ", THEME.dim,
                              "x takes it back out", THEME.reset))
    elseif isdone(it) && !mergedbyme(it) && (it.url in st.unread || it.new)
        # Merged, and you have not looked at it since - or this is the first
        # refresh that has seen it at all, which is the same thing for a repo
        # the event poller does not cover. That is news, not filing: a merge you
        # did not do is exactly the thing to be told about.
        kv("state", string(lowercase(it.state), "  ", THEME.dim,
                           "new since you last looked", THEME.reset))
    elseif isdone(it)
        # Offered once the notice has been read, and never done silently: a
        # merged pull request is usually finished with and occasionally the one
        # thing you still owe a reply on, and this cannot tell the difference.
        kv("state", string(lowercase(it.state), "  ", THEME.dim,
                           mergedbyme(it) ? "you merged it \u00b7 x archives it" :
                                            "x archives it", THEME.reset))
    elseif !isempty(it.state) && it.state != "OPEN"
        kv("state", lowercase(it.state))
    end
    it.draft && kv("state", "draft")
    push!(out, "")

    head("tracking")
    kv("bucket", it.bucket)
    kv("level", it.track)
    # What it is waiting for, not that it is waiting: "yes" answered a question
    # nobody was asking, since the row is in the snoozed lane either way. The
    # sentence is the refresh's own (`snooze_active`), so the reason shown here
    # is the one that decided it rather than a second opinion about it.
    it.snoozed && kv("snoozed", isempty(it.snooze_why) ? "yes" : it.snooze_why)
    kv("deadline", it.deadline)
    isempty(it.blocked_on) || kv("blocked", join(it.blocked_on, ", "))
    kv("why", it.why)
    if !isempty(it.note)
        push!(out, string(THEME.dim, "note", THEME.reset))
        for l in awrap(it.note, max(8, w - 2))
            push!(out, string("  ", l))
        end
    end
    # A session is its own record that something is running: named after the
    # item, so nothing has to be stored to know it is there.
    # Matched on the item a session was tagged with, not on its name: the name
    # is built from a worktree this pane would have to run `git` to work out,
    # and it redraws per frame.
    live = [r for r in st.sessions if r.item == it.ref]
    if !isempty(live)
        push!(out, string(THEME.dim, "running", THEME.reset))
        for r in sort(live; by = x -> x.kind)
            push!(out, string("  ", r.kind == "agent" ? "agent  T to watch" : "shell  t to open"))
        end
    end
    while !isempty(out) && isempty(strip(astrip(last(out))))
        pop!(out)
    end
    out
end
