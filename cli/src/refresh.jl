# Refresh the work dashboard from GitHub.
#
# Deterministic half of the dashboard: fetches live facts over GraphQL, derives
# a bucket for every item from rules, expires snoozes and diffs against the
# previous snapshot.
#
# File ownership is strict, because it is what keeps your notes safe - the
# table is in `Worklog.jl`, and this half of it is the load-bearing part:
# `config.toml` and `local.toml` are read here and *never* written here, while
# `facts.json` is overwritten every run and the snooze marks with it.
#
# Judgement calls this deliberately does not make (they belong in `local.toml`,
# written by hand or by a model reading the same files): whether a red CI
# is mechanical enough to delegate, what the real next action is, and priority
# order.

"Python truthiness, which several of the bucketing rules lean on: `unresolved`
is meaningfully `0`, `None` and `[]` alike."
truthy(v) = !(v === nothing || v === missing || v === false || v == "" ||
              (v isa Integer && v == 0) ||
              (v isa Union{AbstractVector,AbstractDict} && isempty(v)))

"""Last real human activity: a push or a comment, falling back to updatedAt.

updatedAt moves on label and milestone edits too, so it overstates liveness.
"""
function activity_at(r)
    c = [t for t in (get(r, "head_at", nothing), get(r, "last_comment_at", nothing)) if truthy(t)]
    isempty(c) ? r["updated"] : maximum(c)
end

activity_age(r, at::DateTime) = days_since(activity_at(r), at)

"""The newest timeline event of the given kinds that **somebody else did**, and
- when `who` names a field - did **to you**; or `nothing`.

Every key in the wake table that comes from the timeline is this with one
argument changed, and the rule is the same for all of them: an event is news
when somebody else was the actor. You assigning yourself an issue, closing your
own pull request, or dismissing a review on it are your own keystrokes, and the
dashboard reporting them back to you is what `their_head` exists to stop for a
push.

And being **let off** is not news: a review request withdrawn or an assignment
removed is the end of a claim on your attention, not a claim on it, so the
`Removed` and `Unassigned` events are not fetched at all. The one exception is
a close or a merge, which is asked for by name below.

`evs` is `nothing` for a row the bulk lanes returned, which fetch no timeline,
and for an imported row before the refresh has caught up with it.
"""
function event_at(evs, login::AbstractString, kinds, who::Union{Symbol,Nothing})
    evs === nothing && return nothing
    best = ""
    for e in evs
        jget(e, :__typename) in kinds || continue
        jget(jget(e, :actor), :login) == login && continue
        who === nothing || jget(jget(e, who), :login) == login || continue
        t = jget(e, :createdAt)
        t === nothing || (best = max(best, String(t)))
    end
    isempty(best) ? nothing : best
end

"Flatten one GraphQL node into the record the rest of the script uses."
function normalize(n, lane::AbstractString, login::AbstractString)
    typename = jget(n, :__typename, "PullRequest")
    is_pr = typename == "PullRequest"
    author = jget(jget(n, :author), :login)
    # Asked of every lane, including the bulk ones, because "mine" is a fact
    # about the item rather than about which query found it: an issue assigned
    # to you that a mention lane returned first is still yours to do.
    assignees = String[String(a.login) for a in jget(jget(n, :assignees), :nodes, ())
                       if truthy(jget(a, :login))]
    ms = jget(n, :milestone)
    rec = Dict{String,Any}(
        "type" => typename,
        "lane" => lane,
        "url" => n.url,
        "number" => n.number,
        "title" => n.title,
        "repo" => n.repository.nameWithOwner,
        "author" => truthy(author) ? author : "?",
        "state" => jget(n, :state),
        "created" => n.createdAt,
        "updated" => n.updatedAt,
        "labels" => String[l.name for l in n.labels.nodes],
        "milestone" => jget(ms, :title),
        "milestone_due" => jget(ms, :dueOn),
        "assignees" => assignees,
        # Author **or** assignee. Being asked to review something, or named in a
        # thread, is what makes an item *unread*; it does not make it yours.
        # Being assigned it does, and GitHub is the only one who can say so.
        "mine" => author == login || login in assignees,
    )
    lastc = jget(jget(n, :comments), :nodes, ())
    rec["last_comment_by"] = isempty(lastc) ? nothing : jget(jget(lastc[1], :author), :login)
    rec["last_comment_at"] = isempty(lastc) ? nothing : jget(lastc[1], :createdAt)
    # `their_comment_at` and `human_comment_at` - the keys - are set beside
    # `their_head` in the refresh loop, which is where the old row is: your
    # own comment carries the previous value forward, and `comments(last: 1)`
    # cannot see past it.
    #
    # **When you were last assigned this**, which has the shape of a review
    # request and had its bug: a first assignment arrived as a new item through
    # the `assigned` lane, and an unassign-and-reassign was silent. Issues and
    # pull requests alike, since both are assigned.
    evs = jget(jget(n, :timelineItems), :nodes)
    rec["assigned_at"] = event_at(evs, login, ("AssignedEvent",), :assignee)
    # **When somebody else closed, merged or reopened it.** `state` says what
    # it is and not when it got there, and without this a pull request of
    # yours merged by somebody else left `moved_at` where the last comment put
    # it - julia#62396, merged on a Thursday, never moved for it. It is one
    # of the things GitHub itself mails about, and the reason to be told is the
    # reason not to wait for a snooze to expire on something already finished.
    # Yours - you closed it, you pressed merge - is not news, as everywhere.
    rec["state_at"] = event_at(evs, login, ("ClosedEvent", "MergedEvent", "ReopenedEvent"), nothing)

    if is_pr
        commits = n.commits.nodes
        commit = isempty(commits) ? nothing : commits[1].commit
        roll = jget(commit, :statusCheckRollup)
        threads = jget(jget(n, :reviewThreads), :nodes)
        reviews = jget(jget(n, :reviews), :nodes, ())
        light = threads === nothing       # firehose record: no thread/review data
        threads === nothing && (threads = ())
        mine_reviews = [r for r in reviews
                        if jget(jget(r, :author), :login) == login && jget(r, :submittedAt) !== nothing]
        rec["branch"] = something(jget(n, :headRefName), "")
        # The head *sha*, and not only the date it was made. `head_at` says a
        # push happened; only the sha says what it pushed, which is what a diff
        # against the head you last saw has to be taken between. It is a scalar
        # on the same node every lane already selects, so it costs nothing and
        # arrives for every row rather than for the one under the cursor.
        rec["head_sha"] = something(jget(n, :headRefOid), "")
        # And what it is to be merged *into*, which is what the head is measured
        # against: a rebase moves the branch onto a newer base, and without
        # knowing which branch that is there is no way to tell the base's own
        # commits from the ones somebody pushed. See `branch_moved`.
        rec["base"] = something(jget(n, :baseRefName), "")
        # Who pushed the button, and only ever asked of the closed lanes -
        # every other lane is is:open, where it is null by definition.
        rec["merged_by"] = jget(jget(n, :mergedBy), :login)
        rec["draft"] = n.isDraft
        rec["review_decision"] = jget(n, :reviewDecision)
        rec["head_at"] = jget(commit, :committedDate)
        # **Who put the head there**, which decides whether a push is news.
        # The committer and not the author: somebody rebasing your branch leaves
        # you as the author of every commit on it and is the one who moved it,
        # and a commit you wrote that they pushed is a thing to look at. The
        # author is the fallback for a commit with no committer user - the web
        # flow, and anything pushed by an app.
        rec["head_by"] = something(jget(jget(jget(commit, :committer), :user), :login),
                                   jget(jget(jget(commit, :author), :user), :login),
                                   "")
        rec["ci"] = jget(roll, :state)
        rec["unresolved"] = light ? nothing :
                            count(t -> !t.isResolved && !t.isOutdated, threads)
        # **When you were last asked.** Being asked is an event, and it used
        # to be recorded as a bool without its time - so it had to be hashed,
        # and hashed as true-or-absent so that the day it shipped did not read
        # as every row moving. The timeline has the time: the newest
        # `ReviewRequestedEvent` naming you, and as a stamp it compares against
        # the read mark directly. Not the withdrawal: being let off is the end
        # of a claim on your attention and not a claim on it, and it used to
        # wake the item on the theory that `r` was waiting to hear it - decided
        # otherwise on 2026-09-12.
        #
        # Only *you*. A request of somebody else is not news at either level -
        # on a stranger's pull request it is the churn `loose` exists to ignore,
        # and on your own it is not a thing to be told twice. A request of a
        # *team* you are in is invisible here and stays that way: `/user/teams`
        # is 403 for this token, so there is nothing to match the slug against.
        # And `requestedReviewer` is null for a deleted account - julia#62245
        # has one - which `event_at` reads as naming nobody.
        #
        # `last: 50` of six event types together, at no rate-limit cost - a
        # page of the `review` lane is 4 with the connection and 4 without,
        # measured at 10, 20 and 50. What it truncates is a pull request with
        # fifty such events after the last one naming you; julia#51908, the
        # widest today, has ten. `nothing` for an issue, for a row the bulk
        # lanes returned, and for a pull request nobody ever asked you about.
        rec["review_requested_at"] = event_at(evs, login, ("ReviewRequestedEvent",), :requestedReviewer)
        # **When anybody last reviewed it**, which is a review *arriving* and so
        # has a time of its own - where `review_decision` is the standing
        # verdict and `review_count` is how many there have been, neither of
        # which can say when it changed. Both were keys and this replaces them:
        # a verdict only ever moves because a review was submitted or dismissed,
        # and the count only ever moves because one was submitted, so the time
        # of the newest review is the same news dated by the event instead of by
        # the poll that noticed it.
        #
        # **Somebody else's review.** Yours is your own keystroke - and every
        # inline reply you post is a review with state `COMMENTED`, so without
        # this the item came back unread for what you had just said on it.
        # `reviews(last: 20)` is deep enough that nobody else's needs carrying
        # past yours, unlike a comment.
        #
        # A *dismissal* leaves `submittedAt` where it was, so it is folded in
        # from the timeline: `ReviewDismissedEvent` by somebody else, which is
        # them dismissing your review or somebody's on a pull request you are
        # watching. Dismissing one yourself is not news, by the same rule.
        #
        # `nothing` for a row the bulk lanes returned, which fetch no reviews at
        # all - see `light`. A key arriving is not an event, and `moved_stamp`
        # is where that is written down.
        theirs = (jget(r, :submittedAt) for r in reviews
                  if jget(jget(r, :author), :login) != login)
        dismissed = event_at(evs, login, ("ReviewDismissedEvent",), nothing)
        rec["review_at"] = maximum(String(t) for t in Iterators.flatten((theirs, (dismissed,)))
                                   if t !== nothing; init = "") |>
                           (s -> isempty(s) ? nothing : s)
        rec["my_last_review_at"] = isempty(mine_reviews) ? nothing :
                                   maximum(r.submittedAt for r in mine_reviews)
        rec["my_last_review_state"] = isempty(mine_reviews) ? nothing :
            sort(mine_reviews; by = r -> r.submittedAt)[end].state
        # The newest approval by anybody, which is a thing that *happened* and
        # so has a time - unlike `reviewDecision`, which is the current verdict
        # and says nothing about when it was reached.
        approvals = [jget(r, :submittedAt) for r in reviews
                     if jget(r, :state) == "APPROVED" && jget(r, :submittedAt) !== nothing]
        rec["approved_at"] = isempty(approvals) ? nothing : maximum(approvals)
        # **One bool, where the whole CI state used to be a key.** What is worth
        # being told is that your own pull request is failing; a run starting,
        # a run finishing green on something that was never red, and the flap
        # between `PENDING` and `SUCCESS` are all the machine talking to itself.
        # 374 of today's 2167 rows say `FAILURE` and 42 of them are yours.
        #
        # It carries `mine` rather than leaning on the level to mean it. `track`
        # defaults by whose the work is but can be set by hand, and a stranger's
        # pull request tracked `normal` should not wake you because their CI
        # went red.
        #
        # **True or absent, never `false`**, for the reason `review_requested`
        # was: the value is hashed, so a `false` on every row would differ from
        # the missing key on every row already in `fetched.json` and the first
        # refresh after this shipped would stamp the whole dashboard as moved.
        rec["ci_failed"] = (rec["mine"] && rec["ci"] == "FAILURE") ? true : nothing
    end
    rec
end

# How closely you are tracking an item decides what counts as it having moved -
# for the snooze that wakes on it, and for whether it is unread.
#
# **Two levels, and there were four.** `close` added `mergeable` and `labels` to
# `normal`, which is a distinction nobody ever wanted to make by hand, and
# `background` had an empty key set - a constant fingerprint, so nothing about
# the item could ever reach you. The pile does not need that: what takes
# something out of view is dismissing it, one item at a time, and a level that
# means "never tell me anything" is a dismissal you cannot see and cannot undo.
#
# **Two, and there is no third.** There was an `all` - every key there is, not
# settable, hashed into `fp_full` so that "the refresh's change list could
# report something the item's own level ignores". It reported nothing: the
# change list is built from its own explicit field list and gated on the
# *level* `fp`, `fp_full` was read by one line that set `r["moved"]`, and
# `Item.moved` was read nowhere at all. Three things kept each other alive and
# nothing kept any of them. `labels` went with it, being a key of that level
# alone - and with it the one list-valued key. `fingerprint` itself, the hash
# of a level's keys, went on 2026-09-12 when the snooze stopped reading it:
# `moved_stamp` compares the keys and needs no digest of them.
#
# `review_requested_at` and `assigned_at` are in both, which nothing else
# fetched per-lane is. Neither is a property of the item that might interest
# you - each is somebody naming you, and there is no level at which being asked
# to review something, or handed it, is noise. `loose` exists to ignore a
# stranger's CI and a bot's comment, and a human asking you for something is the
# opposite of both. `state_at` is in both for the reason GitHub mails about it:
# an item somebody else finished is finished, and there is nothing to wait for.
# And `their_head` is in both since 2026-09-12: a push on something you are
# watching loosely is not a thing to review, but it is the item being active,
# which is what you are watching it to know.
#
# **One fetched fact is deliberately not a key: `unresolved`.** It is a count
# of open review threads, and somebody resolving one is not a thing to be told:
# what there was to resolve arrived as a comment or a review, and moved
# `their_comment_at` or `review_at` on the day it did. It is still fetched -
# `needs-edits` is bucketed on it and the metadata pane prints it - and it is
# not a reason to put an item back in front of you. `mergeable` was the other,
# and is not fetched at all any more: see `PR_FIELDS` for why, and
# `Events.merge_state` for where it is asked instead.
const TRACK_KEYS = Dict(
    "normal" => ("their_head", "their_comment_at", "review_at", "review_requested_at",
                 "assigned_at", "state_at", "ci_failed"),
    "loose"  => ("their_head", "human_comment_at", "review_at", "review_requested_at",
                 "assigned_at", "state_at"),
)

"""Each key that can be dated, and the field that dates it.

This is the wake table with `TRACK_KEYS`: that says which keys a level watches,
and this says what each one *is*. A key in here is a **time** - a comment, a
review, a request, an assignment, a close carry the moment they were made, and
a push does not: `their_head` is a *sha*, which is the exact answer to whether the
branch moved and no answer at all to when - so it is dated by `head_at`, the
committer date of the commit it now points at, which is the closest thing
GitHub offers and is checked against the high-water mark in `moved_stamp`
because a force-push can carry an older one.

A key **not** in here is a **bool with no clock** - `ci_failed`, and nothing
else - and what it means to move is different in kind: it moves when it
*becomes true*, dated by the refresh that saw it, and never when it clears. A
red that goes green is not news, because the green either arrived as the push
that fixed it or is a rerun of the same commit that you will find out about
when you next look; and a rerun that goes red again through pending would
otherwise wake the item twice for one failure. That is why a bool is not
hashed: a hash of the value differs on both edges, and only one of them is a
thing to be told.
"""
const TIMED_KEYS = Dict("their_comment_at" => "their_comment_at",
                        "human_comment_at" => "human_comment_at",
                        "review_at" => "review_at",
                        "review_requested_at" => "review_requested_at",
                        "assigned_at" => "assigned_at",
                        "state_at" => "state_at",
                        "their_head" => "head_at")

"""When the item last moved, given what it looked like last time: the mark it
had if nothing at its level did, and the time of the change if something did.

**This is the one arbiter of movement.** It used to run only when the level's
hash differed, and the hash was computed by walking the same keys this walks;
now the loop asks it about every row that has an old one, and "nothing moved"
is an answer it gives rather than a case it never sees.

`stamp(at)` - the refresh clock - is the honest answer for a state with no clock
of its own, and the wrong one for a comment. The gap is not academic: `r` stamps
you read at the moment the *thread* was fetched, which is fresher than any
refresh, so a comment posted at 09:55 and read at 10:00 was dated 11:00 by the
refresh that first saw it and the item came back unread for something you had
already read.

So a movement in a key `TIMED_KEYS` can date is dated by what dates it, and a
bool becoming true by now. Mixed is now: a stamp older than a CI failure that
happened beside it would say the item moved before it did.

**A key that was not there before is not an event.** A row the bulk lanes
returned carries no reviews at all, so `review_at` appears the day an active
lane claims it; a key added to `TRACK_KEYS` appears on every row at once. Either
would otherwise read as movement on every row it lands on - which is what made
`review_requested` have to be true-or-absent while it was a key, and what would
have marked the whole dashboard unread on the day the sha replaced the clock,
and again on the day the request became a time. So a key arriving
with a time *older than the movement already recorded* is the record catching up
rather than something happening, and the mark stays where it was. Arriving with
a newer one is a genuine first comment, or a first review, and counts.

**Never backwards, and that is what the last line is for.** Two things move a
timestamped key to an *earlier* value, and only one of them matters.

`head_at` is a *committer* date rather than a push time, so a force-push of an
older commit carries an older date. There is something to show there - the
branch is not what you last saw - and dating the push by the commit it put back
would leave the item read. So a time that cannot account for the change does not
get to explain it, and the refresh clock is what is left.

A **deleted comment** is the other, and it is fine either way: the thing that
moved the key is gone, so missing it costs nothing and catching it costs an
unread item with nothing new in it. It is not the argument for this line and was
written down as though it were.

What the line is really protecting is that `moved_at` **only ever goes forward**.
It is a high-water mark: an item unread since a CI change at 11:00 that took a
comment deletion at 09:00 would be marked read again, and what that loses is not
the deleted comment - it is the CI change nobody ever looked at.

First sight has no old row and is not this: it is `activity_at`, what GitHub
says, or a rebuilt `fetched.json` would read as every item moving at once.
"""
function moved_stamp(old, r, at::DateTime)
    prev = jget(old, :moved_at)
    high = prev isa AbstractString ? String(prev) : ""
    ev = String[]
    for k in get(TRACK_KEYS, r["track"], TRACK_KEYS["normal"])
        was, now_ = jget(old, Symbol(k)), get(r, k, nothing)
        was == now_ && continue
        by = get(TIMED_KEYS, k, nothing)
        if by === nothing
            # A bool: the rising edge is the event, and the falling one is not.
            (now_ === true && was !== true) && return stamp(at)
            continue
        end
        t = get(r, by, nothing)
        truthy(t) || return stamp(at)
        # The record catching up rather than something happening; see above.
        (was === nothing && !isempty(high) && String(t) <= high) || push!(ev, String(t))
    end
    # Nothing moved at this level, or only keys that were arriving, or a bool
    # that cleared: the mark stays where it is. An old row with no mark at all
    # is a shape from before there was one, and gets what first sight gets.
    isempty(ev) && return isempty(high) ? activity_at(r) : high
    m = maximum(ev)
    m <= high ? stamp(at) : m
end

"""Explicit setting wins; otherwise **your unfinished work is tracked normally
and everything else loosely**.

What counts as movement is not a property of the lane an item arrived in - it is
a property of how much of your attention it has a claim on. Your own pull
request should reach you when CI turns green or somebody approves it; the one
you were asked to review should reach you when there is a verdict or a human
reply, and not because their CI flapped or somebody relabelled it.

It defaulted by bucket and never once asked whose the work was, which is how
your pull request and a stranger's ended up at the same level - and how 66 items
of your own, reached through a mention lane, ended up at a level where nothing
about them could reach you at all.

Finished work is loose whoever it belongs to: nothing about it should wake you.
"""
resolve_track(st, r) = let t = get(st, "track", nothing)
    t isa AbstractString && t in TRACK ? t :
    (pget(r, "mine") === true && pget(r, "bucket") != "done") ? "normal" : "loose"
end

"""Whole working days between two instants, counting Monday to Friday.

Two days of silence over a weekend is not silence, it is a weekend. Everything
this measures is somebody being expected to answer, and nobody is expected to
answer on Saturday - so the clock that decides whether a thing has gone quiet
has to skip the days when quiet is the normal state.

Counted by day and not by hour: a comment at nine on Monday morning and one at
five on Monday evening have both had the same number of working days go past by
Wednesday, and pretending otherwise would make the answer depend on the hour
somebody happened to be typing.
"""
function workdays_since(from::AbstractString, at::DateTime)
    t = ts(from)
    t === nothing && return 0
    d, last_ = Date(t) + Day(1), Date(at)
    n = 0
    while d <= last_ && n < 500
        Dates.dayofweek(d) <= 5 && (n += 1)
        d += Day(1)
    end
    n
end
workdays_since(::Nothing, ::DateTime) = 0

"""Why this wants a second look, or `""`.

Snooze answers "not now" and has to be asked for. This is the other half of
that, and asking for it would defeat it: the whole failure it addresses is work
that goes quiet without anybody deciding it should. So it is derived, on by
default, and never stored.

It fires on the two shapes of silence that mean nobody is coming:

  * **The author spoke last.** They commented, or they pushed and nothing has
    been said since - so the ball is in somebody else's court and it has not
    moved. On your own pull request that is a reviewer who never came back; on
    somebody else's it is a reply you never answered. The same rule reads both,
    which is why it is written about "the author" rather than about you.
  * **Somebody approved it and nothing happened after.** Approved and idle is
    not waiting on review, it is waiting on a button.

Measured in *working* days, from whichever of those happened last, and only for
things you are actually carrying - the background pile is full of other people's
pull requests where the author spoke last, and none of them is yours to nudge.

Labels do not count as an answer, which is the point of measuring against the
comment rather than against `updated`. A bot's comment is not an answer either,
but a bot commenting *after* the author leaves us unable to see the author's
comment at all - `comments(last: 1)` is one comment - so that case quietly
does not fire rather than firing on a stale reading.
"""
function second_look(r, at::DateTime, days::Int)
    get(r, "state", nothing) in ("MERGED", "CLOSED") && return ""
    in_pile(r) && return ""
    hd, lc = ts(get(r, "head_at", nothing)), ts(get(r, "last_comment_at", nothing))
    ap = ts(get(r, "approved_at", nothing))
    events = [x for x in (hd, lc, ap) if x !== nothing]
    isempty(events) && return ""
    last_ = maximum(events)
    n = workdays_since(stamp(last_), at)
    # A floor and not a window. There used to be a ceiling too - `n > cap` -
    # on the grounds that a pull request nobody has touched since last spring is
    # a different problem. It is, and dropping it out of the lane was the wrong
    # way to say so: the row did not go anywhere, it *stopped existing* on a day
    # nobody chose, and nothing recorded that it had. The lane is ordered newest
    # first, so an old row is already at the bottom and already out of the way -
    # the ceiling was solving a crowding problem that the order does not have.
    #
    # `r` is what takes one out now: read, which is a decision somebody made,
    # is written down in `local.toml`, comes back by itself when the thing
    # moves, and can be undone with `z`. None of those five things is true of a
    # number in `config.toml`.
    n < days && return ""
    day(n) = string(n, n == 1 ? " work day" : " work days")
    # An approval that is the last thing to have happened. Checked first: it is
    # the more specific reading of the same silence, and the more actionable.
    ap === nothing || ap < last_ || return string("approved, then quiet for ", day(n))
    author = String(nz(get(r, "author", nothing), ""))
    who = isempty(author) || author == "?" ? "the author" : author
    # The author had the last word: they commented and nobody answered, or they
    # pushed and nobody has said anything since.
    if lc !== nothing && lc == last_
        get(r, "last_comment_by", nothing) == author || return ""
        return string(who, " asked, then quiet for ", day(n))
    end
    hd !== nothing && hd == last_ || return ""
    string(who, " pushed, then quiet for ", day(n))
end

# --- bucketing -------------------------------------------------------------
# Every rule below is a fact GitHub already knows. Anything requiring judgement
# is left to the model via a local.toml override.

"""Everything about an item that comes from `local.toml` rather than GitHub.

Its own function because a refresh is no longer the only place an item is built:
an import arrives in the middle of a session and has to be bucketed by the same
rule as everything else. A second copy of this is a bucket that drifts, and the
bucket is what decides where a row shows up at all.
"""
function apply_state!(r, st, cfg, at::DateTime)
    r["reply"] = reply_owed(r, cfg, at)
    r["bucket"], r["why"] = derive_bucket(r, st, cfg, at)
    r["track"] = resolve_track(st, r)
    r["note"] = get(st, "note", nothing)
    r["deadline"] = get(st, "deadline", nothing)
    r["blocked_on"] = get(st, "blocked_on", String[])
    r
end

"""Why a reply is owed on this, or `""`.

Somebody named you recently and the last word is theirs, so a question is
probably waiting on an answer. A fact like `second_look` - derived every
refresh, never stored, carried on the row as the reason in words - and unlike
the bucket it is **not a place the row is in**, so nothing else about the row
takes it away: a closed issue somebody asked you a question on owes the
answer exactly as an open one does, and it is the `reply` tag in the browser
either way. The bucket reads this too, for `needs-reply`, but only on an open
row, since the bucket is one answer per row and "over" wins there.

Only from the mention lanes. The `commented_*` lanes are threads you spoke on,
and on the repos where you are effectively the maintainer that is every thread
there is; a stranger having the last word on one of those is not a question
put to you.
"""
function reply_owed(r, cfg, at::DateTime)
    startswith(String(nz(get(r, "lane", nothing), "")), "mentioned") || return ""
    age = activity_age(r, at)
    (age !== nothing && age <= cfg["thresholds"]["reply_days"]) || return ""
    get(r, "last_comment_by", nothing) in (nothing, cfg["login"]) && return ""
    "mentioned you $(age)d ago; last word is theirs"
end

function derive_bucket(r, st, cfg, at::DateTime)
    truthy(get(st, "bucket", nothing)) && return (st["bucket"], "override")
    # Over, whichever lane found it. This has to come before every rule below,
    # which are all about what to do next: a merged pull request does not need
    # review, a nudge, or a rebase.
    s = get(r, "state", nothing)
    if s in ("MERGED", "CLOSED")
        d = activity_age(r, at)
        return ("done", string(s == "MERGED" ? "merged" : "closed",
                               d === nothing ? "" : " $(d)d ago"))
    end
    L = Set(get(r, "labels", String[]))
    r["lane"] == "firehose" && return ("firehose", "discovery")
    # Asked for by url, which is the whole reason it is here: no lane claimed it
    # and no rule below should invent a reason for it. `done` still wins above -
    # an import that merged is finished like anything else is.
    r["lane"] == "imported" && return ("imported", "imported by url")
    if startswith(r["lane"], "mentioned") || startswith(r["lane"], "commented")
        # The only thing in this pile worth interrupting for: someone named you
        # recently and the last word is theirs, so a question is probably owed an
        # answer - `reply_owed`, which is the same fact whether or not the row
        # is open, where this is not. Everything else - including your own old
        # comments, and the repos where you are effectively the maintainer and
        # touch every PR - stays in the background where you pull it on your
        # own schedule.
        why = reply_owed(r, cfg, at)
        isempty(why) || return ("needs-reply", why)
        return ("mentioned", "mention or comment history")
    end
    # Only after the lanes: an Issue reached via `assigned` is yours to act on,
    # while the same Issue reached via a mention is background.
    r["type"] == "Issue" && return ("issue", "assigned issue")

    if r["mine"]
        claimed = any(truthy(get(st, k, nothing)) for k in ("note", "deadline", "snooze"))
        age = activity_age(r, at)
        if !claimed && age !== nothing && age >= cfg["thresholds"]["stale_days"]
            return ("stale", "quiet $(age)d, unclaimed")
        end
        "status: blocked by upstream" in L && return ("blocked", "labelled blocked by upstream")
        get(r, "review_decision", nothing) == "CHANGES_REQUESTED" &&
            return ("needs-edits", "changes requested")
        truthy(get(r, "unresolved", nothing)) &&
            return ("needs-edits", "$(r["unresolved"]) unresolved thread(s)")
        get(r, "ci", nothing) in ("FAILURE", "ERROR") &&
            return ("needs-edits", "CI $(lowercase(r["ci"]))")
        "status: waiting for PR author" in L && return ("needs-edits", "labelled waiting for author")
        truthy(get(r, "draft", nothing)) && return ("draft", "draft")
        get(r, "review_decision", nothing) == "APPROVED" && get(r, "ci", nothing) == "SUCCESS" &&
            return ("needs-merge", "approved and green")
        age !== nothing && age >= cfg["thresholds"]["nudge_days"] &&
            return ("needs-nudge", "quiet $age days")
        return ("waiting", "waiting on reviewer")
    end

    # Someone else's PR that asked for you.
    head, mine_rev = ts(get(r, "head_at", nothing)), ts(get(r, "my_last_review_at", nothing))
    mine_rev !== nothing && head !== nothing && mine_rev > head &&
        return ("reviewed", "you reviewed after their last push")
    mine_rev !== nothing && head !== nothing && mine_rev <= head &&
        return ("needs-review", "they pushed after your review")
    ("needs-review", "review requested")
end

"""Days in a relative snooze - `3d`, `2w`, `6mo`, `1y` - or `nothing`.

Months and years are 30 and 365 days. Nobody snoozing a pull request for six
months means it to the calendar day, and pretending otherwise would need the
arming date to be a `Date` rather than a timestamp.
"""
function rel_days(sv::AbstractString)
    m = match(r"^(\d+)\s*(mo|[dwy])$", lowercase(strip(String(sv))))
    m === nothing && return nothing
    per = m[2] == "mo" ? 30 : m[2] == "w" ? 7 : m[2] == "y" ? 365 : 1
    parse(Int, m[1]) * per
end

"""
    parse_snooze(sv) -> (mode, days, until) or nothing

The shapes a `snooze` value can take. A snooze is **a wake time and nothing
else** - a second reason for an item to come back, beside the wake table,
rather than a hold that the table has to get past - so every shape is a time:

  * `3d`, `2w`, `6mo` - wake after that long. Counted from when it was set:
    `wl snooze` and `s` write the resolved time, and a span typed by hand into
    `local.toml` is counted from the read stamp beside it.
  * `2026-09-15` - wake on that date; `2026-09-15T20:00:00Z` - at that moment.
    The second is what the first two are written as.

`nothing` for anything else, which is a value that was typed wrong. "Until it
moves" is not a shape, because it is what `r` does; "forever" is not one,
because it is what `x` does.
"""
function parse_snooze(sv::AbstractString)
    s = strip(lowercase(String(sv)))
    d = rel_days(s)
    d === nothing || return (mode = :days, days = d, until = nothing)
    t = ts(strip(String(sv)))
    t === nothing || return (mode = :at, days = nothing, until = stamp(t))
    dt = tryparse(Date, strip(String(sv)))
    dt === nothing ? nothing : (mode = :at, days = nothing, until = stamp(DateTime(dt)))
end

"""
    wake_of(sv, from) -> stamp or nothing

When a `snooze` value says to come back, as a stamp: a span counted from
`from`, a date or a moment as itself, and `nothing` for a value with no wake
time in it - an empty one, or one typed wrong. `from` is `nothing` when there
is nothing to count a span from, and then a span has no answer either.
"""
function wake_of(sv, from)
    truthy(sv) || return nothing
    p = parse_snooze(String(sv))
    p === nothing && return nothing
    p.mode === :at && return p.until
    f = from === nothing ? nothing : ts(String(from))
    f === nothing ? nothing : stamp(f + Day(p.days))
end

"Has this wake time passed, as of `at`? A wake that has not is a snooze still on."
woken(wake, at::DateTime) = wake !== nothing && String(wake) <= stamp(at)

"""The head as of the last time somebody else moved it, or `nothing`.

**The sha says whether there is something new to review; nothing else does.**
`head_at` is a committer date and a rebase rewrites it, a force-push of an older
commit walks it backwards, and a branch moved onto a newer base carries dates
that say nothing about when the push happened. Two shas are equal or they are
not.

**And your own push is not news.** You know what you pushed; being told about it
is the dashboard reporting your own keystrokes back to you. So the key is the
newest head *somebody else* put there: a push of your own carries the previous
value forward, the way `carried_mergeable` carries a value GitHub will not
answer, and a push of theirs replaces it. They push after you, and it moves;
you push after them, and it does not move back.

Carried and not cleared, which is the whole of why this is a separate value from
`head_sha`: clearing it on your own push would be a change like any other, and
the item would go unread for the thing this exists to ignore.

`nothing` for an issue, for a row no lane has fetched commits for, and for a
pull request only ever pushed to by you - which is the honest state for each.
"""
function their_head(r, old, login::AbstractString)
    sha = get(r, "head_sha", nothing)
    truthy(sha) || return nothing
    get(r, "head_by", nothing) == login ? jget(old, :their_head) : String(sha)
end

"""The newest comment by somebody else - and with `human`, by somebody who is
neither you nor a bot - carried forward across the ones that are not; or
`nothing` for an item nobody else has commented on.

`their_head` for a comment, and the same reason: your own reply is your own
keystroke, and without this the item came back unread every time you answered
it from the web. `comments(last: 1)` sees one comment, so when that one is
yours the value is carried rather than looked past - and if somebody commented
and you replied between two refreshes, theirs is missed and you read it, which
is the trade `their_head` makes for a push.

Carried across a bot's too, for the `human` key: it used to go to `nothing`
when a bot spoke after a human, which was a change like any other and woke a
`loose` item for exactly the comment that level exists to ignore. Carried
across no comment at all - every one deleted - for the same reason.
"""
function their_comment_at(r, old, login::AbstractString, key::AbstractString; human::Bool)
    at, by = get(r, "last_comment_at", nothing), get(r, "last_comment_by", nothing)
    carried = jget(old, Symbol(key))
    carry = carried === nothing ? nothing : String(carried)
    truthy(at) || return carry
    (by == login || (human && endswith(something(by, ""), "[bot]"))) ? carry : String(at)
end

"""Does a row no lane returns still have a claim on you: unread, and not filed?

`seen_of`'s rule, asked by the refresh of a row it fetched by url: the read
stamp against `moved_at`, no stamp being unread. Filed is read that the
`filed` box holds - it has been dealt with, and a lane not returning it is not
a reason to keep fetching it.
"""
function still_unread(r, st)
    truthy(get(st, "archived", nothing)) && return false
    read_ = get(st, "read", nothing)
    !truthy(read_) || String(read_) < String(nz(get(r, "moved_at", nothing), ""))
end

"""Is this a row nobody put in front of you - the pile?

The discovery sweep and the mention corpus, plus anything you pushed to the
background by hand. Two things ask, and neither is a filter: `second_look`,
because the pile is not a to-do list and silence in it is not a failure anybody
owes an answer for, and `wl next`, whose whole job is to hand you a slice of it.

**Computed, and it was stored** - as `backlog`, a field on every row and a bool
on every `Item`, from when it was also a *lane*. Nothing filters on it any more:
what takes something out of the pile is dismissing it, one item at a time, and
the bucket already says which pile a row is in. So the two callers that mean
"the pile" ask for it by name, and a row carries one less derived fact that
could disagree with the bucket it was derived from.

`stale` is deliberately not here, and used to be. It is your *own* open work,
and sweeping it out on a 60-day threshold hid 44 pull requests of which 36 were
waiting on a reviewer - which `second_look` could not say either, since it
refuses the pile. Two thresholds, both silent, both unrecorded, both hiding the
same work.
"""
in_pile(r) = pget(r, "bucket") in ("firehose", "mentioned")


"""
    implausible(nodes, total, cached) -> reason or nothing

Reject a bulk result that contradicts itself or the previous snapshot, rather
than letting it overwrite a good cache. `nothing` means the result is fine.
"""
function implausible(nodes, total, cached::Int)
    n = length(nodes)
    total isa Number || return nothing
    n > 0 && total == 0 &&
        return "issueCount 0 alongside $n nodes"
    cached > 0 && n < cached ÷ 2 && total >= cached &&
        return "got $n but issueCount says $total, cache had $cached"
    cached > 0 && n == 0 && cached >= 20 &&
        return "empty result replacing $cached cached"
    nothing
end

"""Why a lane failed, without the query it failed on.

`FetchError` names the query, which is right for a message read on its own and
wrong for this row: the lane is already in the first column and the query is
derivable from it, so all the prefix does is push the reason off the end. At 80
characters it pushed *all* of it off - a cold start reported
`commented_pr FAILED ... : unexpected ` and there was no way to tell from the
output whether that was a rate limit, a 5xx or a bad query.
"""
why(msg::AbstractString) =
    first(strip(replace(String(msg), r"^GraphQL failed for \"[^\"]*\": " => "")), 150)

"""Run every [bulk.queries] entry, cached on a slow cadence.

These are ~2000 items that move slowly and never surface on their own, so
per-refresh freshness buys nothing and costs minutes of wall clock.

GitHub's search API truncates at 1000 results and the Julia firehose is already
at ~993, so any query approaching the cap is re-run partitioned by creation year
and the slices unioned.
"""
function fetch_bulk(cfg, cfgtext, at::DateTime; force::Bool = false)
    cached = fetched("bulk")
    hours = get(cfg["bulk"], "refresh_hours", 6)
    if cached !== nothing && !force
        age_h = Dates.value(at - ts(cached.fetched_at)) / 3_600_000
        if age_h < hours
            return (OrderedDict{String,Any}(String(k) => v for (k, v) in cached.lanes), 0,
                    @sprintf("cached %.1fh old", age_h))
        end
    end

    # Start from whatever is cached so one flaky lane cannot discard the others.
    # These fetches take minutes; losing a completed lane to a later 502 is the
    # difference between a slow refresh and a wasted one.
    prev = OrderedDict{String,Any}()
    cached === nothing || for (k, v) in cached.lanes
        prev[String(k)] = v
    end
    lanes = copy(prev)
    # Persisted after every lane rather than at the end, so a run that dies
    # halfway keeps what it has. It writes the whole store because that is what
    # a part of it costs now - the alternative was a file per fetch, split by
    # which query wrote it rather than by what any of it is.
    keep() = put_fetched!("bulk", Dict{String,Any}("fetched_at" => now_isoformat(at),
                                                   "lanes" => lanes))
    spent = 0
    failed = String[]
    for (lane, q) in ordered(cfg["bulk"]["queries"], cfgtext, "bulk.queries")
        local nodes
        try
            nodes, c, total = search(q; cap = 1000, query = FIREHOSE_QUERY)
            spent += c
            if total > 950
                seen, merged = Set{String}(), Any[]
                for y in 2011:Dates.year(at)
                    part, pc, _ = search("$q created:$y-01-01..$y-12-31";
                                         cap = 1000, query = FIREHOSE_QUERY)
                    spent += pc
                    for n in part
                        if !(n.url in seen)
                            push!(seen, String(n.url))
                            push!(merged, n)
                        end
                    end
                end
                nodes = merged
            end
            cached = length(get(prev, lane, ()))
            why = implausible(nodes, total, cached)
            if why !== nothing
                # A soft truncation is more dangerous than a hard failure: it
                # arrives as a well-formed 200 and silently replaces good data.
                # Seen live - the firehose returned issueCount 0 alongside 100
                # nodes and hasNextPage false, which would have overwritten 957
                # cached items with 100 and dropped the total from 2010 to 1444
                # without an error anywhere.
                push!(failed, lane)
                @printf(stderr, "    %-16s SUSPECT (%s), keeping %d cached\n",
                        lane, why, cached)
                continue
            end
            lanes[lane] = nodes
            @printf(stderr, "    %-16s %4d of %s\n", lane, length(nodes), total)
        catch e
            e isa FetchError || rethrow()
            push!(failed, lane)
            @printf(stderr, "    %-16s FAILED, keeping %d cached: %s\n",
                    lane, length(get(prev, lane, ())), why(e.msg))
            continue
        end
        keep()
    end
    keep()
    how = "fetched $(sum(length(v) for v in values(lanes); init=0))"
    isempty(failed) || (how *= ", $(length(failed)) lane(s) stale")
    (lanes, spent, how)
end

"""Read the item blocks of `local.toml`.

Dates written unquoted (`deadline = 2026-09-30`) come back as `Date`; everything
downstream compares and prints them as ISO strings, so flatten them here. The
Python raised `TypeError` out of `json.dumps` on the same input.
"""
function load_state()
    # `localfile()` and not `datapath`, so a test that points `LOCAL` somewhere
    # disposable is pointing *this* somewhere disposable too. It read the real
    # file through the redirect for as long as it has been here.
    p = localfile()
    isfile(p) || return Dict{String,Any}()
    raw = TOML.parse(read(p, String))
    # Item blocks only. The file's other inhabitants are keyed by what they are
    # - `repo:o/r` - and a refresh has no business reading them.
    Dict{String,Any}(u => Dict{String,Any}(
        k => (v isa Union{Date,DateTime,Dates.Time} ? string(v) : v) for (k, v) in st)
        for (u, st) in raw if st isa AbstractDict && !startswith(u, "repo:"))
end

"""Drafts on the items that have just left the dashboard.

Everything still in the list reconciles itself by being opened: the metadata
says whether the pending review is still there, and asking costs nothing until
somebody looks. An item that has *gone* is the one case where that can never
happen - the lane is items, so a mark on a url that is no longer one of them
cannot be shown, cannot be navigated to, and would sit in `local.toml` for
good.

So the refresh asks about exactly those and only those, which is usually none
and at most a handful. Both answers are worth having: a draft that went with its
item is dropped, and one that did not is five careful comments on a pull request
that has just closed, which is the case the whole draft apparatus exists for and
the last moment anything will mention it.

A question that cannot be asked leaves the mark alone. A network that is down is
not evidence that a draft was sent.

`ask` is a parameter so the suite can drive both answers without a token.
"""
function reconcile_drafts!(gone, ask = url -> Events.review_state(url; ttl = 0.0))
    d = load_drafts()
    (isempty(d) || isempty(gone)) && return 0
    dropped = 0
    for (url, ref) in gone
        haskey(d, url) || continue
        stt = try
            ask(url)
        catch
            continue
        end
        if stt === nothing || isempty(stt.review)
            undraft!(url)
            dropped += 1
        else
            @printf(stderr,
                    "  %-16s %s left the dashboard with an unsent draft review\n",
                    "drafts", ref)
        end
    end
    dropped > 0 && @printf(stderr, "  %-16s %d mark(s) dropped with their items\n",
                           "drafts", dropped)
    dropped
end

function refresh(args::Vector{String} = String[], at::Union{Nothing,DateTime} = nothing)
    cfgtext = read(joinpath(ROOT, "config.toml"), String)
    cfg = TOML.parse(cfgtext)
    login = cfg["login"]
    # **GitHub's now, not this machine's.** Everything this run stamps is
    # compared, sooner or later, against a time GitHub wrote - a movement with
    # no clock of its own against the read mark, a read mark on a hand-typed
    # snooze against the next comment, the closed lanes' `{since}` against
    # `closedAt` - so the instant it is all measured from is GitHub's, off a
    # `Date` header, and not the local clock plus a correction. One request,
    # free of the rate limit. A test hands in its own.
    at === nothing && (at = Events.server_now())
    state = load_state()
    # What the last run left, to diff this one against. Read once and held: the
    # parts of the file this run writes - the poll's inbox, the bulk cache, the
    # items themselves - each go back through a fresh read at the moment they
    # are written, since between them they span minutes of network.
    prev_items = something(fetched("items"), (;))
    second_days = Int(get(cfg["thresholds"], "second_look_days", 2))

    items = OrderedDict{String,Any}()
    spent = 0
    for (lane, q) in ordered(cfg["lanes"], cfgtext, "lanes")
        nodes, c, _ = search(expand_lane(q, at))
        spent += c
        for n in nodes
            items[String(n.url)] = normalize(n, lane, login)
        end
        @printf(stderr, "  %-9s %3d items (%d pts)\n", lane, length(nodes), c)
    end

    # Items no lane returns, tracked because they were asked for by url. They go
    # in after the lanes and before the bulk pile, so a lane that does return one
    # wins: an import is how an item is followed, not what it is.
    imp = imported_urls()
    if !isempty(imp)
        kept = 0
        for n in try
                    fetch_urls(imp)
                 catch e
                    @printf(stderr, "  %-9s failed: %s\n", "imported",
                            first(sprint(showerror, e), 120))
                    Any[]
                 end
            u = String(n.url)
            haskey(items, u) && continue
            items[u] = normalize(n, "imported", login)
            kept += 1
        end
        @printf(stderr, "  %-9s %3d items (of %d)\n", "imported", kept, length(imp))
    end

    # For the poll it does, not for the answer: the events lane advances its
    # cursors and writes what it saw into `fetched.json`, and every reader of
    # that asks for itself. Nothing in this run looks at the list any more.
    Events.unread(cfg, login, at)
    bulk, c, how = fetch_bulk(cfg, cfgtext, at; force = "--firehose" in args)
    spent += c
    # The first lane to claim an item names it, and `derive_bucket` reads that
    # name - so a mention becomes a `needs-reply` and a row the firehose claimed
    # first can never be one. A lane that names *you* therefore beats the one
    # that names a repo, and the discovery sweep goes last. It used to depend on
    # the order the cache file happened to be in, which was the order the lanes
    # had been added to `config.toml` over a year.
    for (lane, nodes) in sort(collect(bulk); by = p -> first(p) == "firehose")
        kept = 0
        for n in nodes
            u = String(n.url)
            haskey(items, u) && continue      # already yours in an active lane
            items[u] = normalize(n, lane, login)
            kept += 1
        end
        @printf(stderr, "  %-16s %4d new (%s)\n", lane, kept, how)
    end

    # **Nothing ages out of being unread.** A row is an item because a lane
    # returned it, and every active lane is `is:open`: the moment somebody
    # merges your pull request it stops being returned, and until 2026-09-13
    # that was the last anyone heard of it - dropped from the snapshot before
    # the refresh could compare it to the old row, before `state_at` could
    # date the merge, before `seen_of` could call it unread. The closed lanes
    # caught it for a window, and past the window an unread merge left the
    # dashboard silently, mark and all.
    #
    # So a row that was in front of you and that no lane returns is **fetched
    # by url** - the same one request the imports make - and goes through the
    # loop below like any other. If it moved, it is unread and stays; if it is
    # read, or archived, it is let go at the foot of the loop. What was in
    # front of you is what was not in the pile: the pile is a thousand rows
    # nobody has read and never will, and a closed one leaving it is not news.
    # A row kept this way keeps its lane, so the bucket rule still runs on it
    # and a mention that goes quiet past `reply_days` returns to the pile and
    # leaves on its own.
    carried = String[]
    for (k, old) in pairs(prev_items)
        url = String(k)
        (haskey(items, url) || in_pile(old)) && continue
        push!(carried, url)
    end
    if !isempty(carried)
        kept = 0
        for n in try
                    fetch_urls(carried)
                 catch e
                    @printf(stderr, "  %-9s failed: %s\n", "carried",
                            first(sprint(showerror, e), 120))
                    Any[]
                 end
            u = String(n.url)
            old = jget(prev_items, Symbol(u))
            items[u] = normalize(n, String(nz(jget(old, :lane), "carried")), login)
            kept += 1
        end
        @printf(stderr, "  %-9s %3d items no lane returns, unread or moved (of %d)\n",
                "carried", kept, length(carried))
    end
    carried = Set(carried)

    # Bucket, then tracking level, then the wake table at that level. Order
    # matters: the level decides which keys `moved_stamp` compares.
    changes = Any[]
    slept = String[]
    for (url, r) in items
        st = get(state, url, Dict{String,Any}())
        old = jget(prev_items, Symbol(url))
        r["their_head"] = their_head(r, old, login)
        r["their_comment_at"] = their_comment_at(r, old, login, "their_comment_at"; human = false)
        r["human_comment_at"] = their_comment_at(r, old, login, "human_comment_at"; human = true)
        apply_state!(r, st, cfg, at)
        # **A snooze is a wake time, and an archive is a mark.** Neither is a
        # decision this run makes: the browser reads both off `local.toml` and
        # answers "is it unread" per frame - `seen_of` - with the wake as a
        # second reason beside the wake table. What this run does with them is
        # two things. It carries the resolved wake on the row for `wl next`
        # and for the second look, since an item you have said "not now" about
        # is not one to be reminded of; and it stamps read an item that has a
        # snooze or an archive but no read stamp - a value typed into the file
        # by hand, which is what `apply_snooze!` and `wl snooze` do on the way
        # in and the only thing that used to need an arming. Without it the
        # item would be unread and hidden by nothing, and "not now" would have
        # said nothing at all.
        read_ = get(st, "read", nothing)
        r["wake"] = wake_of(get(st, "snooze", nothing), read_)
        held = (r["wake"] !== nothing && !woken(r["wake"], at)) ||
               truthy(get(st, "archived", nothing))
        held && !truthy(read_) && push!(slept, url)
        # After the bucket, which `in_pile` reads and the pile is not a to-do
        # list, and after the snooze, for the reason above.
        r["second_look"] = held ? "" : second_look(r, at, second_days)
        # **When this program last saw a change you asked to be told about** -
        # what the seen axis compares your read stamp against.
        #
        # Not `updated`, which is wrong in both directions: GitHub does not move
        # it when a check run finishes (julia#62841 was stamped 20:55:52 and its
        # three suites completed at 20:56:04, :07 and :19, and it has not moved
        # since), and it does move it for a label edit on somebody else's pull
        # request. So "has it changed" was answered by a clock that cannot see
        # CI and can see things nobody asked about.
        #
        # The level decides what counts, which is what `track` always read like
        # it did. The *old* row is compared key by key at today's level rather
        # than through a stored hash, so changing `track` is not itself
        # movement.
        #
        # **And this is the only threshold there is.** A snooze used to compare
        # a hash armed when you said "not now" and wake when it differed, which
        # was this rule reached a second way and kept in step with it by hand -
        # `WOKE`, `snooze_fp`, `snooze_at`, a `mark_read` on falling asleep and
        # an `inbox_add!` on waking. A snooze is a wake *time* now, read beside
        # this mark by `seen_of`, and there is nothing to keep in step.
        #
        # **Whether it moved, and what it is stamped with, is `moved_stamp`**:
        # the event's own time when the keys that moved have one, the refresh
        # clock when a bool became true, and the mark it already had when
        # nothing did. It used to be gated on the level's hash differing and
        # stamped with the refresh clock either way, which dated every comment
        # by the poll that noticed it and woke on a bool clearing as well as
        # setting. On first sight it is what GitHub says rather than now, or a
        # rebuilt `fetched.json` would read as every item moving at once.
        r["moved_at"] = old === nothing ? activity_at(r) : moved_stamp(old, r, at)
        if old === nothing
            r["new"] = true
            push!(changes, (url, r, "new"))
        else
            r["new"] = false
            # The change list is what moved, said for a person - so it is gated
            # on the mark, not on the hash, and a green or a relabel that moved
            # nothing is not in it.
            if r["moved_at"] != String(nz(jget(old, :moved_at), ""))
                d = String[]
                # Said as what happened, because it is an event and not a value:
                # "review_requested_at 14:02->16:40" is the same sentence
                # written for a machine, and this is the line a person reads to
                # find out why their dashboard changed.
                jget(old, :review_requested_at) == get(r, "review_requested_at", nothing) ||
                    push!(d, "review requested")
                jget(old, :assigned_at) == get(r, "assigned_at", nothing) ||
                    push!(d, "assigned to you")
                jget(old, :state_at) == get(r, "state_at", nothing) ||
                    push!(d, get(r, "state", nothing) == "OPEN" ? "reopened" :
                             lowercase(something(get(r, "state", nothing), "closed")))
                # The events say what happened; the states say what they went
                # from and to. `their_head` and `review_at` are printed as
                # events even though they are a sha and a timestamp, because
                # "new push 0a1b2c->3d4e5f" is not a sentence anybody reads.
                for (f, lab) in (("their_head", "new push"),
                                 ("their_comment_at", "new comment"),
                                 ("review_at", "new review"),
                                 ("ci", "CI"), ("review_decision", "review"),
                                 ("unresolved", "unresolved"))
                    if jget(old, Symbol(f)) != get(r, f, nothing)
                        push!(d, f in ("their_head", "their_comment_at", "review_at") ? lab :
                                 "$lab $(pyrepr(jget(old, Symbol(f))))->$(pyrepr(get(r, f, nothing)))")
                    end
                end
                isempty(d) || push!(changes, (url, r, join(d, ", ")))
            end
        end
    end
    # A carried row that is read - up to its latest movement, this run's
    # included - or filed has nothing left to say, and goes. One that is
    # unread stays, however long that takes.
    for url in carried
        haskey(items, url) || continue
        still_unread(items[url], get(state, url, Dict{String,Any}())) || delete!(items, url)
    end
    gone = Tuple{String,String}[]
    for (k, old) in pairs(prev_items)
        url = String(k)
        if !haskey(items, url)
            push!(changes, (url, old, url in carried ? "read, and no lane returns it" :
                                                       "closed or merged"))
            push!(gone, (url, String(nz(jget(old, :ref), url))))
        end
    end
    reconcile_drafts!(gone)

    # Once, after the loop: this rewrites a file, and a refresh that finds
    # twenty hand-typed snoozes should not rewrite `local.toml` twenty times.
    isempty(slept) || @printf(stderr, "  %-16s %4d marked read, having been put away by hand\n",
                              "snooze", mark_read(slept, at))
    # A value typed wrong is not a snooze, and nothing else says so.
    for (u, st) in state
        v = get(st, "snooze", nothing)
        truthy(v) && parse_snooze(String(v)) === nothing &&
            @printf(stderr, "  %-16s bad snooze value '%s'  (%s)\n", "snooze", v, u)
    end

    store = load_fetched()
    store["fetched_at"], store["points"], store["items"] = now_isoformat(at), spent, items
    save_fetched(store)
    # The one directory nothing else prunes. Swept here rather than in the
    # browser because it is a walk of the whole folder and this run is already
    # the slow, non-interactive one - and because everything it drops is older
    # than anything the browser would have put on screen.
    swept = cache_clear(; older_than = CACHE_SWEEP[])
    swept > 0 && @printf(stderr, "  %-16s %d entries over %d days old\n",
                         "cache", swept, round(Int, CACHE_SWEEP[] / 86_400))
    @printf(stderr, "  %d items, %d changes, %d rate-limit points\n",
            length(items), length(changes), spent)
    0
end

"How Python's `%s` renders the values that appear in a change line."
pyrepr(v) = v === nothing ? "None" : v isa Bool ? (v ? "True" : "False") : string(v)
