
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

`fresh` is `R`: past every cache, and past the dwell too - a key pressed on the
item is not the cursor passing over it.
"""
function load_meta!(st::BState; fresh::Bool = false)
    (isempty(st.items) || st.sel == 0) && return
    note_sel!(st)
    it = st.items[st.sel]
    st.metakey == it.url && return
    # Cleared before the dwell rather than after it: what is here is the last
    # item's, and it must not stand under this one's title for a quarter of a
    # second. The pane says "loading…" meanwhile - `meta_waiting` reads the
    # dwell as waiting, which it is.
    st.metakey = ""
    st.meta = nothing
    st.checks = nothing
    st.merge = nothing
    st.metapending = nothing
    st.mergepending = nothing
    st.metastale = false
    !fresh && held!(st, meta_cached(it)) && return
    st.metakey = it.url
    start_meta!(st, it, fresh ? :fresh : :load)
end

"Does the pane want `mergeable` for `it`? Only while there is a merge to be had."
merge_wanted(it::Item) = it.is_pr && (isempty(it.state) || it.state == "OPEN")

"""Is everything the pane shows for `it` on disk - anything to put up without a
request? Asked before a load is held for the dwell: a cached item is never held."""
meta_cached(it::Item) =
    cache_has(Events.meta_key(it.url)) &&
    (!it.is_pr || cache_has(checks_key(it.repo, it.number))) &&
    (!merge_wanted(it) ||
     Events.merge_usable(cache_get(Events.merge_key(it.url), MERGE_FRESH[];
                                   keep_s = CACHE_KEEP[]), MERGE_FRESH[]))

"""Start the two metadata tasks for `it`, under one of three windows.

`:load` is the cursor landing: an entry within `CACHE_KEEP` goes up at once,
and `collect_meta!` marks it stale past `CACHE_FRESH` so that a re-read runs
behind it. `mergeable` has its own window, `MERGE_FRESH` - a clean answer past
it is not shown, and a conflict is shown like anything else; see `merge_state`.

`:quiet` is that re-read: plain fresh-or-miss at the same windows, so that only
what is actually old is asked for again. The metadata and the checks share a
window; the merge keeps its own unless the conflict on screen is the thing
that is old, in which case it is asked at the shorter one. This is the one
place a conflict is ever re-asked before `MERGE_FRESH`.

`:fresh` is `R`: past everything.

**The bundle rides on the re-read.** The row itself - the tags, the CI, the
head, everything `derive!` makes - is as old as the refresh that last asked
about it, and for a row outside the open work that is the last time a clock
said it moved. So a `:quiet` or `:fresh` read that finds the bundle older than
`CACHE_FRESH` (or missing: a light row the poll or a thread made) asks for it
too - `fetch_bundle`, one GraphQL request, a second - and `collect_meta!` puts
the answer in the list. Never on `:load`: the row is already on screen, and a
request per keystroke while `j` is held is what the dwell exists to prevent.
Once per selection, `bundletried`, so a fetch that fails does not fail again
every second.
"""
function start_meta!(st::BState, it::Item, how::Symbol)
    ttl, keep = how === :fresh ? (0.0, 0.0) :
                how === :quiet ? (CACHE_FRESH[], CACHE_FRESH[]) :
                                 (CACHE_FRESH[], CACHE_KEEP[])
    mttl = how === :fresh ? 0.0 :
           how === :quiet && st.merge !== nothing && st.merge.mergeable == "CONFLICTING" ?
               CACHE_FRESH[] : MERGE_FRESH[]
    mkeep = how === :load ? CACHE_KEEP[] : mttl
    tag = how === :load ? "" : how === :quiet ? " quiet" : " fresh"
    # `R` reads past the checks' own window, so it cannot join the ordinary
    # read of the same item - that is the read it was pressed to go past.
    st.metapending = fetching(string("meta ", it.url, tag)) do
        try
            (meta = Events.itemmeta(it.url, it.is_pr; ttl = ttl, keep = keep),
             checks = it.is_pr ?
                 check_contexts(it.repo, it.number; ttl = ttl, keep = keep) : nothing,
             sessions = mux_list())
        catch e
            (meta = nothing, checks = nothing, sessions = String[],
             err = first(sprint(showerror, e), 120))
        finally
            st.wake === nothing || st.wake()
        end
    end
    # Whether it can be merged is asked here and nowhere else: the lanes do
    # not fetch `mergeable`, since asking is what makes GitHub compute it and
    # a page that asked took four times as long. One pull request, on the one
    # occasion the answer is wanted, and only while it is open - a merged one
    # has no merge left to be possible.
    #
    # **A task of its own**, beside the one above rather than inside it. The
    # answer comes back well after the reviews and the checks do - it is the
    # computation the lanes were made to stop waiting for - and the thread,
    # the reviewers and the check tally are all on screen before it lands.
    st.mergepending = merge_wanted(it) ?
        fetching(string("merge ", it.url, tag)) do
            try
                Events.merge_state(it.url; ttl = mttl, keep = mkeep)
            catch
                nothing
            finally
                st.wake === nothing || st.wake()
            end
        end : nothing
    if how === :fresh || (how === :quiet && st.bundletried != it.url &&
                          bundle_age(it) > CACHE_FRESH[])
        st.bundletried = it.url
        st.bundlepending = fetching(string("bundle ", it.url, tag)) do
            try
                fetch_bundle(it)
            catch
                nothing
            finally
                st.wake === nothing || st.wake()
            end
        end
    end
    st
end

"""Re-read the metadata on screen, under it.

What makes it a refresh is what it does not do: `st.meta`, `st.checks` and
`st.merge` stay where they are until the answer lands, and a failed answer
leaves them there. Only for the item the cursor is on, and only when nothing
about it is already in the air.
"""
function refresh_meta!(st::BState)
    (isempty(st.items) || st.sel == 0) && return false
    it = st.items[clamp(st.sel, 1, length(st.items))]
    st.metakey == it.url || return false
    (st.metapending === nothing && st.mergepending === nothing &&
     st.bundlepending === nothing) || return false
    start_meta!(st, it, :quiet)
    true
end

"""Is the pane waiting on `it` - a fetch in the air, or a load the dwell is
holding? Either way the honest word is "loading…" rather than "—"."""
meta_waiting(st::BState, it::Item) =
    st.metakey == it.url ? st.metapending !== nothing : st.selurl == it.url
merge_waiting(st::BState, it::Item) =
    st.metakey == it.url ? st.mergepending !== nothing : st.selurl == it.url

function collect_meta!(st::BState)
    # Each of the three lands on its own; the merge answer is the late one, and
    # a frame that has the reviews should not wait for it.
    got = false
    if st.bundlepending !== nothing && istaskdone(st.bundlepending)
        b = try
            fetch(st.bundlepending)
        catch
            nothing
        end
        st.bundlepending = nothing
        # The row on screen, replaced by the exact one - tags, CI, head, the
        # mark. `replace_item!` refilters, and keeps the cursor on the url.
        b === nothing || replace_item!(st, b)
        got = true
    end
    if st.mergepending !== nothing && istaskdone(st.mergepending)
        m = try
            fetch(st.mergepending)
        catch
            nothing
        end
        # A re-read that failed leaves the answer it was re-reading; a load
        # that failed had nothing there to leave.
        m === nothing || (st.merge = m)
        st.mergepending = nothing
        # A conflict is shown for as long as anything else, and re-asked at
        # the same window as the rest - the one answer that is not re-asked
        # here is a clean one, which `merge_state` drops on its own past
        # `MERGE_FRESH`. Never off a failure: the entry that failed to re-read
        # is still old, and would arm this again every second.
        m !== nothing && m.mergeable == "CONFLICTING" &&
            cache_age(Events.merge_key(st.metakey)) > CACHE_FRESH[] &&
            (st.metastale = true)
        got = true
    end
    if st.metapending === nothing
        got && arm_refresh!(st)
        return got
    end
    istaskdone(st.metapending) || return got
    r = try
        fetch(st.metapending)
    catch
        (meta = nothing, checks = nothing, err = "load failed")
    end
    if hasproperty(r, :err) && st.meta !== nothing
        # A re-read nobody asked for must not take the pane away from someone
        # reading it. What is there stays, and is not marked stale again: the
        # entry that failed to re-read is still old, and would only fail again.
    else
        st.meta = r.meta
        st.checks = r.checks
        i = findfirst(x -> x.url == st.metakey, st.all)
        it = i === nothing ? nothing : st.all[i]
        # Old enough to want re-reading behind what just went up. Not off a
        # failure, for the reason above; and either half is enough, since the
        # re-read asks only for what is actually old.
        !hasproperty(r, :err) && it !== nothing &&
            (cache_age(Events.meta_key(it.url)) > CACHE_FRESH[] ||
             (it.is_pr && cache_age(checks_key(it.repo, it.number)) > CACHE_FRESH[]) ||
             (st.bundletried != it.url && bundle_age(it) > CACHE_FRESH[])) &&
            (st.metastale = true)
    end
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
    arm_refresh!(st)
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
    wait_ = meta_waiting(st, it)

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
    # Fetched for this item when the cursor landed on it, and said the way the
    # merge prompt says it - `merge_note` reads `mergeStateStatus`, which is
    # finer than `mergeable`: behind, blocked, unstable. Loading until it has
    # arrived - which is after the rest of this pane, since it is the slow
    # answer and has a task of its own - and nothing at all once the pull
    # request is over.
    if it.is_pr && (isempty(it.state) || it.state == "OPEN")
        ms = st.metakey == it.url ? st.merge : nothing
        mwait = merge_waiting(st, it)
        kv("mergeable", ms === nothing ? (mwait ? "loading…" : "") :
                        ms.mergeable == "CONFLICTING" || ms.status == "DIRTY" ?
                        string(THEME.blocked, merge_note(ms), THEME.reset) :
                        merge_note(ms))
    end
    # The derived facts, each in its own words, and only while it holds: the
    # tag axis in the filter pane is these same four.
    isempty(it.reply) ||
        kv("reply", string(THEME.waiting, it.reply, THEME.reset))
    isempty(it.review) ||
        kv("review", string(THEME.waiting, it.review, THEME.reset))
    isempty(it.edits) ||
        kv("edits", string(THEME.waiting, it.edits, THEME.reset))
    isempty(it.ready) ||
        kv("ready", string(THEME.waiting, it.ready, THEME.reset))
    isempty(it.secondlook) ||
        kv("quiet", string(THEME.waiting, it.secondlook, THEME.reset))
    b = batch_of(st, it)
    b === nothing ||
        kv("draft", string(THEME.waiting, b.n,
                           b.n == 1 ? " comment" : " comments", THEME.reset,
                           "  ", THEME.dim, "c adds one \u00b7 A sends them",
                           THEME.reset))
    if haskey(st.archived, it.url)
        a = st.archived[it.url]
        kv("archived", string(when_str(a), "  ", THEME.dim,
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
    kv("lane", it.lane)
    kv("level", it.track)
    # When it wakes, while it is asleep; and when it was filed, if it was. Both
    # are marks read off `local.toml` rather than anything the refresh decided,
    # which is why a snooze that ran out at lunch says nothing here by dinner.
    asleep(it, Marks(st)) && kv("snoozed", string("until ", when_str(st.wakes[it.url])))
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
