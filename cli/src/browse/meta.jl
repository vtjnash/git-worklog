
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
    st.bundletried = ""      # once per selection, and this is a new one
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
            # An adopted branch has nothing on GitHub to ask about, and its
            # `local:` url is not one the request could be made of anyway.
            rows = mux_list()
            (meta = islocal(it) ? nothing :
                        Events.itemmeta(it.url, it.is_pr; ttl = ttl, keep = keep),
             checks = it.is_pr ?
                 check_contexts(it.repo, it.number; ttl = ttl, keep = keep) : nothing,
             sessions = rows, taken = taken_in(it, item_place(it; items = st.all), rows))
        catch e
            (meta = nothing, checks = nothing, sessions = String[], taken = NamedTuple[],
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
        !hasproperty(r, :err) && it !== nothing && !islocal(it) &&
            (cache_age(Events.meta_key(it.url)) > CACHE_FRESH[] ||
             (it.is_pr && cache_age(checks_key(it.repo, it.number)) > CACHE_FRESH[]) ||
             (st.bundletried != it.url && bundle_age(it) > CACHE_FRESH[])) &&
            (st.metastale = true)
    end
    hasproperty(r, :sessions) && (st.sessions = r.sessions)
    hasproperty(r, :taken) && (st.taken = r.taken)
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

"""The same, with how long ago that was beside it, dim: `2026-09-08 01:36
3d ago`. The reader was doing the subtraction on every date the pane shows.
Off `at`, the frame's clock, and worked out per frame - never kept on the
item, which is the same rule as `age`."""
when_str(s::AbstractString, at::DateTime) = (w = when_str(s); isempty(w) ? "" :
    string(w, "  ", THEME.dim, ago_str(s, at), THEME.reset))

"""What has moved since you read the item, newest first, in the pane's
words - `pushed`, `comment`, `reviewed`, `review requested`, `assigned`,
`merged`/`closed`/`reopened`, `CI failed`, `new`, `woke`, `updated` - or
nothing for an adopted branch, which no clock moves.

Read off the item against the done stamp - the same stamp `seen_of` compares,
so the words are the unread - and not off a record: the wake table's keys are
each the time somebody else last did the thing, and every one past the stamp
is a thing that happened since you looked. Computed here, per frame, so `e`
empties it and a stamp that moves back fills it, with no refresh between.

Two movements have no time of their own to compare, and for those the
refresh's own answer stands in: the key it kept beside the stamp
(`moved_by`) is the *last* movement, dated `moved_at`, and is listed
whatever it was - the bool that rose (`CI failed`), the force-push of an
older commit whose date cannot account for it. `new` says the row itself
arrived, and is said only when nothing since is. A push is dated by the head
only while the head is theirs: after a push of your own the date is yours,
and their push before it is the refresh's to remember.

Beside the table: a snooze that ran out (`woke`), a light row (`updated`),
which has the poll's clock and nothing else, and an agent that rang on the
item (`agent`) - first, since it is standing now whatever else moved when,
and on a local row too, which is the one kind of movement one can have.
"""
function moved_words(it::Item, m::Marks)
    words = table_words(it, m)
    it.url in m.rang ? pushfirst!(words, "agent") : words
end

"The words off the wake table alone; `moved_words` puts the agent's in front."
function table_words(it::Item, m::Marks)
    islocal(it) && return String[]
    stamp = get(m.done, it.url, nothing)
    stamp === nothing && (stamp = floor_of(it, m.sources))
    # Never in front of you at all: everything on it is new, and one word
    # says so.
    stamp === nothing && return ["new"]
    evs = Tuple{String,String}[]          # (when, word), to sort newest first
    keys = get(TRACK_KEYS, it.track, TRACK_KEYS["normal"])
    for k in keys
        t = k == "their_head" ? (it.head_by == login() ? "" : it.head_at) :
            k == "their_comment_at" ? it.their_comment_at :
            k == "human_comment_at" ? it.human_comment_at :
            k == "review_at" ? it.review_at :
            k == "review_requested_at" ? it.review_requested_at :
            k == "assigned_at" ? it.assigned_at :
            k == "state_at" ? it.state_at : ""
        isempty(t) || t <= stamp || push!(evs, (t, moved_word(k, it)))
    end
    moved = something(moved_of(it), "")
    wake = get(m.wake, it.url, nothing)
    wake !== nothing && wake <= m.now && wake > stamp && push!(evs, (wake, "woke"))
    # The last movement as the refresh recorded it, which is the one the
    # timed keys cannot always say: dated by the stamp it set.
    if moved > stamp && !isempty(it.moved_by) && (it.moved_by != "new" || isempty(evs))
        push!(evs, (moved, moved_word(it.moved_by, it)))
    end
    isempty(evs) && return moved > stamp ? [isempty(it.moved_at) ? "updated" : "moved"] : String[]
    sort!(evs; by = first, rev = true)
    unique!(last.(evs))
end

"The CI state as the mergeable row repeats it, or nothing for no CI."
ci_word(ci::AbstractString) =
    ci == "SUCCESS" ? "CI passed" :
    ci in ("PENDING", "EXPECTED") ? "CI pending" :
    ci in ("FAILURE", "ERROR") ? "CI failed" : ""

"The pane's word for a key of the wake table; the state's own for a close."
moved_word(k::AbstractString, it::Item) =
    k == "their_head" ? "pushed" :
    k in ("their_comment_at", "human_comment_at") ? "comment" :
    k == "review_at" ? "reviewed" :
    k == "review_requested_at" ? "review requested" :
    k == "assigned_at" ? "assigned" :
    k == "state_at" ? (it.state == "OPEN" ? "reopened" : lowercase(it.state)) :
    k == "ci_failed" ? "CI failed" :
    k == "new" ? "new" : "moved"

"""Lines for the metadata pane: what is true of this item, rather than what is
in it.

Everything cheap comes from the fetched row and is on screen immediately; the two
that need a request - who has actually reviewed, and the per-check breakdown -
arrive when `load_meta!` lands and say so until then.
"""
function meta_lines(st::BState, it::Union{Nothing,Item}, w::Int,
                    at::DateTime = utcnow())
    it === nothing && return String[]
    out = String[]
    # One reading of the marks and one clock for the whole pane: every date on
    # it is placed against `at`, and the snooze is asleep or woken by it.
    marks = Marks(st, at)
    head(t) = push!(out, string(THEME.bold, t, THEME.reset))
    # A value longer than the pane wraps under itself, at the value column:
    # "asked, then quiet for 12 work days" and "blocked — a required review or
    # check is missing" were being cut at the pane's edge, and a fact cut is a
    # fact half-said. The pane grows by the row; `nmeta` is what the layout
    # reads, so the split follows.
    kv(k, v) = if !isempty(string(v))
        ls = awrap(string(v), max(4, w - 10))
        push!(out, string(THEME.dim, rpad(k, 10), THEME.reset, ls[1]))
        for l in ls[2:end]
            push!(out, string(" "^10, l))
        end
    end
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
                                  THEME.dim, first(r.at, 10), "  ", ago_str(r.at, at),
                                  THEME.reset))
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

    # How it got here, first: which search claimed the row - the filter axis
    # of the same name. A fact, so it sits with the facts; it was under
    # "tracking" beside `track`, where three rows read as three settings and
    # one was. The reason GitHub gave for a thread is not on the pane: it is
    # what `wl unread` prints as `why`, and what moved is the `why` here.
    kv("lane", it.lane)
    kv("author", it.author)
    st.meta === nothing || isempty(st.meta.assignees) ||
        kv("assignee", join(st.meta.assignees, ", "))
    # The branch, and where it is going, in the form `git` and `gh` take:
    # `owner/repo:branch` when the head lives in a fork, which the lanes do
    # not say and the metadata fetch does. An adopted branch has one and no
    # base; an issue has neither. A base that is not the repository's default
    # branch - `v1.x` on libuv, a backport branch anywhere - is the one fact
    # on this row worth a colour: it says where the change will *not* land.
    if !isempty(it.branch)
        fork = st.meta === nothing ? "" : String(get(st.meta, :fork, ""))
        default = st.meta === nothing ? "" : String(get(st.meta, :default, ""))
        offbase = !isempty(default) && !isempty(it.base) && it.base != default
        kv("branch", string(isempty(fork) ? "" : string(fork, ":"), it.branch,
                            isempty(it.base) ? "" :
                            offbase ? string(" → ", THEME.waiting, it.base, THEME.reset,
                                             THEME.dim, "  not ", default, THEME.reset) :
                            string(" → ", it.base)))
    end
    # How old it is and when it last changed at all. Both are on the item
    # already and neither was on screen, so the age of what you are reading had
    # to be guessed from the comment dates - and a pull request opened in 2022
    # reads very differently from one opened on Tuesday. To the minute and no
    # further: seconds are noise, and the zone is UTC everywhere in this
    # program, which is why it is not printed either. And how long ago that
    # was, beside it, since the subtraction was being done by the reader.
    #
    # `updated` is GitHub's own, so a label edit moves it. That is a different
    # fact from `act` - the head commit or the last comment - and the lanes are
    # ordered by `act` precisely because this one moves for things nobody did.
    kv("created", when_str(it.created, at))
    kv("updated", when_str(it.updated, at))
    kv("milestone", string(it.milestone,
                           isempty(it.milestone_due) ? "" : string("  (", it.milestone_due, ")")))
    # Fetched for this item when the cursor landed on it, and said the way the
    # merge prompt says it - `merge_note` reads `mergeStateStatus`, which is
    # finer than `mergeable`: behind, blocked, unstable. Loading until it has
    # arrived - which is after the rest of this pane, since it is the slow
    # answer and has a task of its own - and nothing at all once the pull
    # request is over.
    # With the CI beside it, the one repeat the row keeps: whether it can be
    # merged and whether it should be are read together, and the checks
    # section is a screen's worth of rows up on a pull request with labels.
    if it.is_pr && (isempty(it.state) || it.state == "OPEN")
        ms = st.metakey == it.url ? st.merge : nothing
        mwait = merge_waiting(st, it)
        ci = ci_word(it.ci)
        kv("mergeable", ms === nothing ? (mwait ? "loading…" : "") :
                        string(ms.mergeable == "CONFLICTING" || ms.status == "DIRTY" ?
                                   string(THEME.blocked, merge_note(ms), THEME.reset) :
                                   merge_note(ms),
                               isempty(ci) ? "" : string("  ", THEME.dim, ci, THEME.reset)))
    end
    # The tags, only while each holds: the tag axis in the filter pane is
    # these same words. `edits` and `ready` are the word alone - what they
    # say is on the pane already, as the review decision, the unresolved
    # count, the checks and the labels; the sentence stays on the row for
    # `wl` and the filter. The other three say what is said nowhere else:
    # whose the last word is, that they pushed after your review, how long
    # the quiet has been.
    isempty(it.reply) ||
        kv("reply", string(THEME.waiting, it.reply, THEME.reset))
    isempty(it.review) ||
        kv("review", string(THEME.waiting, it.review, THEME.reset))
    # Only where `reply` is not already saying you were named.
    isempty(it.mentioned) || !isempty(it.reply) || kv("mentioned", it.mentioned)
    isempty(it.edits) || push!(out, string(THEME.waiting, "edits", THEME.reset))
    isempty(it.ready) || push!(out, string(THEME.waiting, "ready", THEME.reset))
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
        kv("archived", string(when_str(a, at), "  ", THEME.dim,
                              "x takes it back out", THEME.reset))
    elseif !isempty(it.state) && it.state != "OPEN"
        # Whether you were the one who merged it, beside the state: a merge
        # you pressed the button for is not news, and the pane is where that
        # is read. That a merge you did not do is news is the `why` row's
        # under `local` - `unread: merged`. Nothing is offered here: filing
        # is `x`, which the footer names, and the same offer on every closed
        # row was a row of noise on the pane.
        kv("state", string(lowercase(it.state),
                           mergedbyme(it) ? string("  ", THEME.dim, "you merged it", THEME.reset) : ""))
    end
    it.draft && kv("state", "draft")
    push!(out, "")

    # What is written down about it, in `local.toml`: the block is the file's
    # block for this item, and the heading is the file's name.
    head("local")
    # Why it is in front of you, first: unread, and in a word each what has
    # moved since you read it - a comment, a push, a review, newest first -
    # which `seen_of` says with the stamp and the list says with the bold and
    # neither says in words; or read. What moved and nothing standing: the
    # reason GitHub gave for a thread ("you were mentioned") and an adopted
    # branch's standing stood after it for a day, and are facts about the
    # item, which the pane says above - the lane, the author, the branch.
    seen, words = seen_of(it, marks), moved_words(it, marks)
    kv("why", seen === :unread ?
              (isempty(words) ? "unread" : string("unread: ", join(words, ", "))) : "done")
    # By the command's own word. What the level means is the command's help;
    # said here it wrapped the row on every item, and `;` is the key for it.
    kv("track", it.track)
    # When it wakes, while it is asleep; once the snooze has gone, that
    # there was one, and whether it woke or was cleared by hand
    # (`last_snooze`, which outlives the snooze) - the one place the wake's
    # time is on screen. Marks read off `local.toml` rather than anything
    # the refresh decided, so a snooze that ran out at lunch says so here
    # before the next refresh. That a row is unread under its snooze is the
    # `why` row's, with what moved.
    if asleep(it, marks)
        kv("snoozed", string("until ", when_str(st.wakes[it.url], at)))
    elseif haskey(st.snoozes, it.url) || haskey(st.wakes, it.url)
        # Off the snooze itself where one is still on file and woken - typed
        # by hand, and no refresh has written it down yet.
        ls = get(st.snoozes, it.url, get(st.wakes, it.url, ""))
        kv("snoozed", ls <= marks.now ? string("woke ", when_str(ls, at)) :
                      string("until ", when_str(ls, at), "  ", THEME.dim, "cleared", THEME.reset))
    end
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
    # The bell is the agent's: it rang at the end of a turn or at a question,
    # with nobody looking, and `T` is what clears it.
    # And, beside them, what is running in the copy `t` or `T` would open in
    # that is some other item's (`taken_in`): the key takes it over, and an
    # empty `running` read as nothing running when another item's agent was
    # in the very copy `T` was about to land in (2026-09-22).
    live = [r for r in st.sessions if r.item == it.ref]
    if !isempty(live) || !isempty(st.taken)
        push!(out, string(THEME.dim, "running", THEME.reset))
        for r in sort(live; by = x -> x.kind)
            push!(out, string("  ", r.kind != "agent" ? "shell  t to open" :
                              r.bell ? string("agent  ", THEME.waiting, "waiting on you",
                                              THEME.reset, " · T to see") :
                              "agent  T to watch"))
        end
        for r in sort(st.taken; by = x -> x.kind)
            k = r.kind == "agent" ? "agent" : "shell"
            push!(out, string("  ", k, "  ", THEME.waiting, r.item, "'s", THEME.reset,
                              ", in this item's copy · ", k == "agent" ? "T" : "t",
                              " takes it over"))
        end
    end
    while !isempty(out) && isempty(strip(astrip(last(out))))
        pop!(out)
    end
    out
end
