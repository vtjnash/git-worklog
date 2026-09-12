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
        rec["mergeable"] = jget(n, :mergeable)
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
        rec["review_count"] = length(reviews)
        # **Are you asked right now**, which is a state, and is not a key. It
        # was, as true-or-absent-never-false, because being asked is somebody
        # addressing you and until it was fetched a *re*-request - the only
        # kind you can get on something you have already read - moved nothing
        # at all: `reviewDecision` did not change, `review_count` did not
        # change, and no comment is posted. The key is now the time below;
        # this is what the change list reads to say which way it went.
        #
        # Only *you*. A request of somebody else is not news at either level -
        # on a stranger's pull request it is the churn `loose` exists to ignore,
        # and on your own it is not a thing to be told twice. A request of a
        # *team* you are in is invisible here and stays that way: `/user/teams`
        # is 403 for this token, so there is nothing to match the slug against.
        #
        # `requestedReviewer` is null for a reviewer that is neither a User nor
        # a Team - a deleted account, or a type this selection does not spread.
        # julia#62245 has one today, which is why the lookup goes through
        # `jget` rather than a field access.
        reqs = jget(jget(n, :reviewRequests), :nodes)
        rec["review_requested"] =
            (reqs !== nothing &&
             any(rr -> jget(jget(rr, :requestedReviewer), :login) == login, reqs)) ?
            true : nothing
        # **When you were last asked.** Being asked is an event, and the bool
        # above recorded one without its time - so it had to be hashed, and
        # hashed as true-or-absent so that the day it shipped did not read as
        # every row moving. The timeline has the time: the newest
        # `ReviewRequestedEvent` naming you, and as a stamp it compares against
        # the read mark directly. Not the withdrawal: being let off is the end
        # of a claim on your attention and not a claim on it, and it used to
        # wake the item on the theory that `r` was waiting to hear it - decided
        # otherwise on 2026-09-12.
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
# alone - and with it the one list-valued key, which is why `fingerprint` no
# longer has to sort anything before it hashes it.
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
# **Two fetched facts are deliberately not keys: `mergeable` and `unresolved`.**
# Mergeable is computed lazily and answers `UNKNOWN` on the first read of every
# pull request - `carried_mergeable` exists to stop that flapping - so it is not
# a value that can be trusted to have *changed*, and 671 of today's 2167 rows
# are `CONFLICTING` because somebody else's base moved, which is not news
# anybody asked for. Unresolved is a count of open review threads, and somebody
# resolving one is not a thing to be told: what there was to resolve arrived as
# a comment or a review, and moved `their_comment_at` or `review_at` on the day
# it did. Both are still fetched - `needs-stacking` and `needs-edits` are
# bucketed on them and the metadata pane prints both - and neither is a reason
# to put an item back in front of you.
const TRACK_KEYS = Dict(
    "normal" => ("their_head", "their_comment_at", "review_at", "review_requested_at",
                 "assigned_at", "state_at", "ci_failed"),
    "loose"  => ("their_head", "human_comment_at", "review_at", "review_requested_at",
                 "assigned_at", "state_at"),
)

"""What counts as 'this item moved', at the given tracking level, as a hash.

**Only the snooze reads this now.** Whether an item moved, and when, is
`moved_stamp`'s answer, key by key; this is the hash an `on-change` snooze was
armed against and is compared to, and it goes when the snooze's arming does -
see "Read and snooze are one state" in TODO. Until then it has the bug the
table below does not: `ci_failed` is hashed as a value, so a snooze wakes on
the green as well as the red.

The level is named by every caller and has no default: the one it used to have
was `all`, which no longer exists, and "whatever `get` falls back to" is not a
thing to decide what wakes you. A key whose value is a list would have to be
sorted here before it is hashed; none is, since `labels` left with `all`.
"""
function fingerprint(rec, level::AbstractString)
    ks = get(TRACK_KEYS, level, TRACK_KEYS["normal"])
    bytes2hex(SHA.sha256(json_dumps(Any[get(rec, k, nothing) for k in ks])))[1:16]
end

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
    # `s` `1` is what takes one out now: an on-change snooze, which is a
    # decision somebody made, is written down in `local.toml`, comes back by
    # itself when the thing moves, and can be undone with `z`. None of those
    # five things is true of a number in `config.toml`.
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
    r["bucket"], r["why"] = derive_bucket(r, st, cfg, at)
    r["track"] = resolve_track(st, r)
    r["note"] = get(st, "note", nothing)
    r["deadline"] = get(st, "deadline", nothing)
    r["blocked_on"] = get(st, "blocked_on", String[])
    r
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
        # answer. Everything else - including your own old comments, and the
        # repos where you are effectively the maintainer and touch every PR -
        # stays in the background where you pull it on your own schedule.
        age = activity_age(r, at)
        if startswith(r["lane"], "mentioned") && age !== nothing &&
           age <= cfg["thresholds"]["reply_days"] &&
           !(r["last_comment_by"] in (nothing, cfg["login"]))
            return ("needs-reply", "mentioned you $(age)d ago; last word is theirs")
        end
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
        get(r, "mergeable", nothing) == "CONFLICTING" && return ("needs-stacking", "merge conflict")
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

The five shapes a `snooze` value can take:

  * `forever` - hide it and never bring it back. **This is what archiving is.**
    Filing something away and putting it to sleep are the same sentence with a
    different wake condition, so they are one field: `x` writes this one.
  * `on-change` (or `until-review`) - hide until the fingerprint differs
  * `on-change/30d` - the same, but give up after that long
  * `3d`, `2w`, `6mo` - hide for a while, counted from when it was set
  * `2026-09-15` - hide until a date, ignoring movement entirely

`nothing` for anything else, which is a value that was typed wrong.
"""
function parse_snooze(sv::AbstractString)
    s = strip(lowercase(String(sv)))
    (s == "forever" || s == "archive" || s == "never") &&
        return (mode = :forever, days = nothing, until = nothing)
    (s == "on-change" || s == "until-review") &&
        return (mode = :onchange, days = nothing, until = nothing)
    if startswith(s, "on-change/") || startswith(s, "until-review/")
        d = rel_days(last(split(s, '/')))
        return d === nothing ? nothing : (mode = :onchange, days = d, until = nothing)
    end
    d = rel_days(s)
    d === nothing || return (mode = :rel, days = d, until = nothing)
    dt = tryparse(Date, strip(String(sv)))
    dt === nothing ? nothing : (mode = :date, days = nothing, until = dt)
end

"""An armed snooze, as `(fingerprint, armed_at)`.

Tolerates both shapes on disk: the bare fingerprint it used to be, and the
record carrying the time it was armed. An entry written before this existed has
no time, and is treated as arming now rather than as infinitely old - waking
every long-standing snooze at once on the first refresh after an upgrade is not
an improvement.
"""
function snooze_entry(v)
    v === nothing && return (nothing, nothing)
    v isa AbstractString && return (String(v), nothing)
    fp, at = pget(v, "fp"), pget(v, "at")
    (fp === nothing ? nothing : String(fp), at === nothing ? nothing : String(at))
end

snooze_record(fp, at) = Dict{String,Any}("fp" => fp, "at" => at)

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

"""What `mergeable` should say when GitHub has answered `UNKNOWN`.

GitHub computes mergeability lazily: the first read of a pull request returns
`UNKNOWN` and only schedules the real computation. Treating that as fact flaps
the needs-stacking lane between refreshes - so the last known value is carried
forward until a real one arrives, and the read that got `UNKNOWN` has warmed it
for the next refresh. It used to wake on-change snoozes too, and that is the
half of this that `TRACK_KEYS` settled instead: a value this unreliable has no
business deciding that something moved, so it is not a key at any level.

**Except once it is over.** A merged or closed pull request answers `UNKNOWN`
for good: there is no merge to be possible any more, so this is not a fact that
has gone temporarily unknown, it is a question with no answer. Carrying the last
value forward there pins whatever was true the day before the merge onto
something that has merged - which is how julia#62396 came to be merged and
"conflicting" at the same time.
"""
carried_mergeable(state, prev) =
    (state in ("MERGED", "CLOSED") || prev == "UNKNOWN") ? nothing : prev

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

"""Which edge of a snooze this refresh crossed: `:slept`, `:woke`, or nothing.

Only the edges. Marking read on every refresh an item is asleep would bury a
comment that arrived while it slept; marking unread on every refresh after it
wakes would make a woken item impossible to file. And `:woke` is the wake
proper, which is why the reason is looked at: `snooze_active` answers "not
snoozed" for a snooze that has been *cleared* too, and clearing one is something
you did on purpose, a moment ago, on an item in front of you - it has no
business coming back as news.
"""
snooze_edge(was::Bool, now::Bool, why) =
    was == now ? nothing :
    now ? :slept :
    (why isa AbstractString && startswith(why, "woke")) ? :woke : nothing

"""The inbox row for an item that has just woken, from its `facts.json` row.

The shape a poll writes, because that is what `unread()` reads. Hand-delivered
for the same reason `wl import` hand-delivers one: the item may be in a repo no
lane polls, and then no poll will ever put it back in front of you.

`comments` is 0 and not the real count - nothing here knows it, and nothing
reads it but the row's own display.
"""
woke_row(r, at::DateTime) = OrderedDict{String,Any}(
    "url" => r["url"], "repo" => r["repo"], "number" => r["number"],
    "title" => r["title"],
    "is_pr" => get(r, "type", "PullRequest") == "PullRequest",
    "state" => lowercase(String(nz(get(r, "state", nothing), "open"))),
    "author" => String(nz(get(r, "author", nothing), "")),
    "updated" => String(nz(get(r, "updated", nothing), stamp(at))),
    "comments" => 0,
    "labels" => String[String(l) for l in get(r, "labels", ())],
    "mine" => get(r, "mine", false) === true)

"""Returns (is_snoozed, reason). Arms a snooze on first sight.

`maxdays` is the fallback cap for an `on-change` that carries none of its own:
without one it hides the item until the fingerprint differs, and a pull request
that everybody has quietly given up on is exactly the shape whose fingerprint
never differs. That is also the one worth being reminded about.

**A refresh is the only thing that may call this, and that is deliberate.** It
is not a predicate: it arms snoozes, writes `WOKE` and hands back a sentence, so
whoever calls it decides that an item has woken *and records it*. A browser that
asked it per frame would promote items on a clock nobody started - and two
browsers on one dashboard would each decide, each write, and disagree about
which of them had already woken what. So the browser reads `snoozed` and
`snooze_why` off the item it loaded and shows the refresh's answer, however old
it is: waking is something the user does by running `wl refresh`, at a moment
they chose, once.
"""
function snooze_active(url, st, fp, snz, at::DateTime, maxdays = nothing)
    s = get(st, "snooze", nothing)
    truthy(s) || return (false, nothing)
    sv = s isa AbstractString ? String(s) : string(s)
    p = parse_snooze(sv)
    p === nothing && return (false, "bad snooze value '$sv'")

    # Nothing wakes it, so there is nothing to arm and nothing to check: the
    # item moving is what makes it *unread*, which is a different question and
    # not one this answers.
    p.mode === :forever && return (true, "forever")
    if p.mode === :date
        p.until <= Date(at) && return (false, "woke: snooze expired")
        return (true, "until $(p.until)")
    end

    armed_fp, armed_at = snooze_entry(get(snz, url, nothing))
    if armed_fp === nothing
        snz[url] = snooze_record(fp, stamp(at))      # arm now
        return (true, p.mode === :rel ? "for $sv" : "until it moves")
    end
    if armed_fp == "WOKE"
        # Stay awake once woken. Re-arming here would re-hide the item on the
        # very next refresh, giving you a single window to notice it moved.
        # `wl snooze <ref> on-change` re-arms deliberately.
        return (false, "woke earlier; re-snooze to re-arm")
    end
    # An entry from before arming times were recorded: adopt one now.
    if armed_at === nothing
        armed_at = stamp(at)
        snz[url] = snooze_record(armed_fp, armed_at)
    end
    age = something(days_since(armed_at, at), 0)

    if p.mode === :rel
        age >= p.days && return (false, "woke: $sv elapsed")
        return (true, "for $sv, $(p.days - age)d left")
    end
    if armed_fp != fp
        snz[url] = "WOKE"
        return (false, "woke: it moved")
    end
    cap = p.days === nothing ? maxdays : p.days
    if cap !== nothing && age >= cap
        snz[url] = "WOKE"
        return (false, "woke: asleep $(age)d with no movement")
    end
    (true, age > 0 ? "until it moves (asleep $(age)d)" : "until it moves")
end

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

function refresh(args::Vector{String} = String[], at::DateTime = utcnow())
    cfgtext = read(joinpath(ROOT, "config.toml"), String)
    cfg = TOML.parse(cfgtext)
    login = cfg["login"]
    state = load_state()
    # What the last run left, to diff this one against. Read once and held: the
    # parts of the file this run writes - the poll's inbox, the bulk cache, the
    # items themselves - each go back through a fresh read at the moment they
    # are written, since between them they span minutes of network.
    prev_items = something(fetched("items"), (;))
    # A default cap for on-change snoozes that carry none of their own.
    snooze_cap = get(get(cfg, "snooze", Dict{String,Any}()), "max_days", nothing)
    second_days = Int(get(cfg["thresholds"], "second_look_days", 2))
    snz = load_snoozes()

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

    # Bucket, then tracking level, then a fingerprint at that level, then snooze.
    # Order matters: the level decides the fingerprint, which decides the wake.
    changes = Any[]
    slept, woke = String[], OrderedDict{String,Any}[]
    for (url, r) in items
        st = get(state, url, Dict{String,Any}())
        if get(r, "mergeable", nothing) == "UNKNOWN"
            r["mergeable"] = carried_mergeable(get(r, "state", nothing),
                                               jget(jget(prev_items, Symbol(url)), :mergeable))
        end
        old = jget(prev_items, Symbol(url))
        r["their_head"] = their_head(r, old, login)
        r["their_comment_at"] = their_comment_at(r, old, login, "their_comment_at"; human = false)
        r["human_comment_at"] = their_comment_at(r, old, login, "human_comment_at"; human = true)
        apply_state!(r, st, cfg, at)
        r["fp"] = fingerprint(r, r["track"])
        snoozed, sreason = snooze_active(url, st, r["fp"], snz, at, snooze_cap)
        r["snoozed"], r["snooze_why"] = snoozed, sreason
        # After the bucket, which `in_pile` reads and the pile is not a to-do
        # list, and after the snooze, since an item you have said "not now"
        # about is not one to be reminded of.
        r["second_look"] = r["snoozed"] ? "" :
                           second_look(r, at, second_days)
        # A snooze is "not now", and an item you have said that about should not
        # also be sitting in the unread lane asking to be read. So falling
        # asleep marks it read and waking marks it unread again; `snooze_edge`
        # is where the rule about which refreshes count is written down.
        if old !== nothing
            e = snooze_edge(jget(old, :snoozed) === true, snoozed, sreason)
            e === :slept && push!(slept, url)
            e === :woke && push!(woke, woke_row(r, at))
        end
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
        # it did and until now only governed snoozes. The *old* row is compared
        # key by key at today's level rather than through its stored `fp`, so
        # changing `track` is not itself movement.
        #
        # **The same threshold a snooze wakes on**, which this said was a
        # different one. A snooze compares against the value armed when you said
        # "not now", so it looks like it would ignore a change that undoes
        # itself where this would count it twice - except that `WOKE` is sticky:
        # the item woke on the way out and never re-armed to be fooled on the
        # way back. Read and `on-change` are one rule reached two ways, which is
        # the whole of TODO's "Read and snooze are one state".
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
                                 ("mergeable", "mergeable"), ("unresolved", "unresolved"))
                    if jget(old, Symbol(f)) != get(r, f, nothing)
                        push!(d, f in ("their_head", "their_comment_at", "review_at") ? lab :
                                 "$lab $(pyrepr(jget(old, Symbol(f))))->$(pyrepr(get(r, f, nothing)))")
                    end
                end
                isempty(d) || push!(changes, (url, r, join(d, ", ")))
            end
        end
    end
    gone = Tuple{String,String}[]
    for (k, old) in pairs(prev_items)
        url = String(k)
        if !haskey(items, url)
            push!(changes, (url, old, "closed or merged"))
            push!(gone, (url, String(nz(jget(old, :ref), url))))
            delete!(snz, url)
        end
    end
    reconcile_drafts!(gone)

    # Once each, after the loop: both of these rewrite a file, and a refresh
    # that puts twenty items to sleep should not rewrite `local.toml` twenty
    # times. `overwrite = false` leaves a poll's own richer row alone, which is
    # the same courtesy an import pays.
    #
    # After `unread()` has already answered, which costs nothing now that
    # nothing in this run reads the answer again: the browser asks for itself
    # when it opens, and that is where this is read.
    isempty(slept) || @printf(stderr, "  %-16s %4d marked read on falling asleep\n",
                              "snooze", mark_read(slept, at))
    isempty(woke) || @printf(stderr, "  %-16s %4d marked unread on waking\n",
                             "snooze", Events.inbox_add!(woke; overwrite = false))

    # A bad value means "not snoozed", so the item is not in the snoozed section
    # and its reason is printed nowhere. Say it here instead of losing it.
    for (u, r) in items
        w = get(r, "snooze_why", nothing)
        w isa AbstractString && startswith(w, "bad snooze value") &&
            @printf(stderr, "  %-16s %s  (%s)\n", "snooze", w, u)
    end

    store = load_fetched()
    store["fetched_at"], store["points"], store["items"] = now_isoformat(at), spent, items
    save_fetched(store)
    save_snoozes!(snz)
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
