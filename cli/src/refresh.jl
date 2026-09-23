# Refresh the work dashboard from GitHub.
#
# Deterministic half of the dashboard: fetches live facts over GraphQL, derives
# the few facts the browser's tags are made of, expires snoozes and diffs
# against the previous snapshot.
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

"Python truthiness, which several of the fact rules lean on: `unresolved`
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
function event_at(evs, login::AbstractString, kinds, who::Union{Symbol,Nothing};
                  team::Bool = false)
    evs === nothing && return nothing
    best = ""
    for e in evs
        jget(e, :__typename) in kinds || continue
        jget(jget(e, :actor), :login) == login && continue
        named = who === nothing || jget(jget(e, who), :login) == login ||
                (team && jget(jget(e, who), :slug) !== nothing)
        named || continue
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
        # And whose repository that branch is in: a fork's pull request from
        # its `master` is named the same as the project's, and as every
        # other fork's, so the name alone does not say which local branch is
        # this pull request's - `carrier_refused` reads this against what
        # the branch tracks. Null when the fork has been deleted.
        rec["head_repo"] = something(jget(jget(n, :headRepository), :nameWithOwner), "")
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
        # And where that branch was, so `d` can measure from the merge base
        # with no round trip: a checkout that has both shas has the diff.
        rec["base_sha"] = something(jget(n, :baseRefOid), "")
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
        # the done mark directly. Not the withdrawal: being let off is the end
        # of a claim on your attention and not a claim on it, and it used to
        # wake the item on the theory that `e` was waiting to hear it - decided
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
        # A request of a *team* you are in reaches the `review` lane too -
        # `review-requested:` is direct or via team; `user-review-requested:`
        # would be direct only - and it names you exactly as a direct one
        # does. Which team is not asked: the lane is the proof you are in it,
        # so on a `review` row any team request counts, and on any other row
        # none does (your own pull request with a request of some team is
        # not you being asked).
        rec["review_requested_at"] = event_at(evs, login, ("ReviewRequestedEvent",),
                                              :requestedReviewer; team = lane == "review")
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
# `edits` reads it and the metadata pane prints it - and it is
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
of its own, and the wrong one for a comment. The gap is not academic: `e` stamps
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
comment deletion at 09:00 would be marked done again, and what that loses is not
the deleted comment - it is the CI change nobody ever looked at.

First sight has no old row and is not this: it is `activity_at`, what GitHub
says, or a rebuilt `fetched.json` would read as every item moving at once.

`movement` is the same walk answering the second question too - *which* key
moved it, `""` when none did - and `moved_stamp` is its first half.
"""
moved_stamp(old, r, at::DateTime) = first(movement(old, r, at))

"""
    movement(old, r, at) -> (stamp, key)

When the item last moved (`moved_stamp`), and the key of the wake table that
moved it then: the one whose time is the stamp, the bool that rose, the key
whose time could not account for the change. `""` when nothing moved and the
mark stayed, so the caller keeps the key it had.
"""
function movement(old, r, at::DateTime)
    prev = jget(old, :moved_at)
    high = prev isa AbstractString ? String(prev) : ""
    ev = Pair{String,String}[]          # the event's time => the key
    for k in get(TRACK_KEYS, r["track"], TRACK_KEYS["normal"])
        was, now_ = jget(old, Symbol(k)), get(r, k, nothing)
        was == now_ && continue
        by = get(TIMED_KEYS, k, nothing)
        if by === nothing
            # A bool: the rising edge is the event, and the falling one is not.
            (now_ === true && was !== true) && return (stamp(at), k)
            continue
        end
        t = get(r, by, nothing)
        truthy(t) || return (stamp(at), k)
        # The record catching up rather than something happening; see above.
        (was === nothing && !isempty(high) && String(t) <= high) || push!(ev, String(t) => k)
    end
    # Nothing moved at this level, or only keys that were arriving, or a bool
    # that cleared: the mark stays where it is. An old row with no mark at all
    # is a shape from before there was one, and gets what first sight gets.
    isempty(ev) && return (isempty(high) ? activity_at(r) : high, "")
    (m, k) = maximum(ev)
    (m <= high ? stamp(at) : m, k)
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
    (pget(r, "mine") === true && !isover(r)) ? "normal" : "loose"
end

"Finished, whichever lane found it: `MERGED` or `CLOSED`."
isover(r) = pget(r, "state") in ("MERGED", "CLOSED")

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
default, and never stored - a conditional snooze that arms itself, and whose
condition is silence.

**The author acted, and nobody has answered.** One shape, read two ways: they
opened it and there are no comments at all, or they commented and the comment
is still the last one. On your own pull request that is a reviewer who never
came, or never came back; on somebody else's it is a reply you owe. The same
rule reads both, which is why it is written about "the author" rather than
about you.

A push is not an action here, and it used to be. The author pushing to their
own branch says nothing about whether anybody is waiting - they may be
answering a review, or tidying - and "pushed, then quiet" fired on every pull
request whose author kept working on it. What counts is the author *saying*
something, or the opening itself, and what answers it is a comment or a
review by somebody else - measured in *working* days from the action, and
only for things you are actually carrying, since the background pile is full
of other people's pull requests that nobody has answered and none of them is
yours to nudge.

Labels do not count as an answer, which is the point of measuring against the
comment rather than against `updated`. A bot's comment is not an answer either,
but a bot commenting *after* the author leaves us unable to see the author's
comment at all - `comments(last: 1)` is one comment - so that case quietly
does not fire rather than firing on a stale reading.
"""
function second_look(r, at::DateTime, days::Int)
    isover(r) && return ""
    in_pile(r) && return ""
    author = String(nz(get(r, "author", nothing), ""))
    opened = ts(get(r, "created", nothing))
    lc = ts(get(r, "last_comment_at", nothing))
    # The author's last word: the opening, or their comment if it is the last.
    # Somebody else's last comment is an answer, and there is nothing to say.
    acted = opened
    if lc !== nothing
        get(r, "last_comment_by", nothing) == author || return ""
        acted = acted === nothing ? lc : max(acted, lc)
    end
    acted === nothing && return ""
    # A review by anybody - theirs, or yours - after the author last spoke is
    # an answer too, whatever its verdict.
    for k in ("review_at", "my_last_review_at")
        rv = ts(get(r, k, nothing))
        rv !== nothing && rv > acted && return ""
    end
    n = workdays_since(stamp(acted), at)
    # A floor and not a window. There used to be a ceiling too - `n > cap` -
    # on the grounds that a pull request nobody has touched since last spring is
    # a different problem. It is, and dropping it out of the lane was the wrong
    # way to say so: the row did not go anywhere, it *stopped existing* on a day
    # nobody chose, and nothing recorded that it had. The lane is ordered newest
    # first, so an old row is already at the bottom and already out of the way -
    # the ceiling was solving a crowding problem that the order does not have.
    #
    # `e` is what takes one out now: read, which is a decision somebody made,
    # is written down in `local.toml`, comes back by itself when the thing
    # moves, and can be undone with `z`. None of those five things is true of a
    # number in `config.toml`.
    n < days && return ""
    day(n) = string(n, n == 1 ? " work day" : " work days")
    # No subject: it is the author's silence by construction, and the author
    # is the row above this one in the pane that shows it.
    lc === nothing ? string("opened, then quiet for ", day(n)) :
                     string("asked, then quiet for ", day(n))
end

# --- the facts the tags are made of ----------------------------------------
# Every rule below is a fact GitHub already knows, and each is its own key on
# the row: a sentence when it holds and `""` when it does not, the shape
# `second_look` has always had. They are **not exclusive**. There used to be a
# `bucket` here - one word per row from a cascade of these same rules, first
# to answer wins - and the cascade is what lost the question somebody put to
# you on a thread that then closed: `done` answered first, and the mention
# rule never ran. A fact beside another fact loses nothing; the browser's tag
# axis is the facts, and a view names whichever it wants. Anything requiring
# judgement is left to `local.toml`.

"""Everything about an item that comes from `local.toml` rather than GitHub,
and the derived facts that need the config to derive.

Its own function because a refresh is no longer the only place an item is built:
an import arrives in the middle of a session and has to carry the same facts as
everything else. A second copy of this is a fact that drifts, and the facts are
what decide which views a row is in.
"""
function apply_state!(r, st, cfg, at::DateTime)
    r["reply"] = reply_owed(r, cfg, at)
    r["edits"] = edits_owed(r)
    r["ready"] = ready_to_merge(r)
    r["review"] = review_owed(r)
    r["track"] = resolve_track(st, r)
    r["note"] = get(st, "note", nothing)
    r
end

"""Why a reply is owed on this, or `""`.

Somebody named you recently and the last word is theirs, so a question is
probably waiting on an answer. A fact about the thread and not about its state:
a closed issue somebody asked you a question on owes the answer exactly as an
open one does, and it is the `reply` tag in the browser either way.

Only a mention asks. A thread you commented on (`comment`) is, on the repos
where you are effectively the maintainer, every thread there is, and a
stranger having the last word on one of those is not a question put to you.
Read off the notification `reason` the row carries - `mention`, or
`team_mention` - which is GitHub saying you were named; it was read off the
lane while the mention searches existed, and a team mention was a free-text
search for the team's name.
"""
function reply_owed(r, cfg, at::DateTime)
    get(r, "reason", nothing) in ("mention", "team_mention") || return ""
    age = activity_age(r, at)
    (age !== nothing && age <= cfg["thresholds"]["reply_days"]) || return ""
    get(r, "last_comment_by", nothing) in (nothing, cfg["login"]) && return ""
    "mentioned you $(age)d ago; last word is theirs"
end

"""Why this wants edits, or `""`: changes requested, unresolved threads, red CI,
or the label that says so. About the pull request, whoever's it is - the view
that means yours names the author axis beside it.
"""
function edits_owed(r)
    isover(r) && return ""
    L = Set(get(r, "labels", String[]))
    get(r, "review_decision", nothing) == "CHANGES_REQUESTED" && return "changes requested"
    truthy(get(r, "unresolved", nothing)) && return "$(r["unresolved"]) unresolved thread(s)"
    get(r, "ci", nothing) in ("FAILURE", "ERROR") && return "CI $(lowercase(r["ci"]))"
    "status: waiting for PR author" in L && return "labelled waiting for author"
    ""
end

"Approved and green, and not a draft: waiting on a button, or `\"\"`."
function ready_to_merge(r)
    isover(r) && return ""
    truthy(get(r, "draft", nothing)) && return ""
    get(r, "review_decision", nothing) == "APPROVED" && get(r, "ci", nothing) == "SUCCESS" ||
        return ""
    "approved and green"
end

"""Why a review is owed by you, or `""`: somebody asked, and either you have not
reviewed it or they pushed after you did. Not on your own pull request, and
not on one nobody asked you about.
"""
function review_owed(r)
    isover(r) && return ""
    pget(r, "mine") === true && return ""
    truthy(get(r, "review_requested_at", nothing)) || return ""
    head, mine_rev = ts(get(r, "head_at", nothing)), ts(get(r, "my_last_review_at", nothing))
    mine_rev === nothing && return "review requested"
    head !== nothing && mine_rev <= head && return "they pushed after your review"
    ""
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
    `local.toml` is counted from the done stamp beside it.
  * `2026-09-15` - wake on that date; `2026-09-15T20:00:00Z` - at that moment.
    The second is what the first two are written as.

`nothing` for anything else, which is a value that was typed wrong. "Until it
moves" is not a shape, because it is what `e` does; "forever" is not one,
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

"""Is this a row nobody put in front of you - the pile?

What the clocks brought in: a row the notifications source or the repo poll
saw move and the refresh fetched by url for it, unless somebody in it asked
you something, which is the one thing in the pile that is in front of you.
One thing asks, and it is not a filter: `second_look`, because the pile is not
a to-do list and silence in it is not a failure anybody owes an answer for.

Read off the *lane*, which is the fact. It used to be read off the bucket,
which was derived from the lane, and before that it was stored as `backlog`,
a field on every row from when it was also a lane. Nothing filters on it:
what takes something out of the pile is reading it, or filing it, one item at
a time, recorded and undoable.

Until 2026-09-13 the pile was the six bulk searches and the firehose - two
thousand rows fetched every six hours so that the ones that moved could be
noticed - and a standing list by construction. The clocks say which rows moved
for one REST page, so the pile is now the rows that did; the old lane names
are still recognised so that a `fetched.json` from before is let go of
cleanly, see `RETIRED_LANES`.

`stale` is deliberately not here, and used to be. It is your *own* open work,
and sweeping it out on a 60-day threshold hid 44 pull requests of which 36 were
waiting on a reviewer - which `second_look` could not say either, since it
refuses the pile. Two thresholds, both silent, both unrecorded, both hiding the
same work.
"""
function in_pile(r)
    lane = String(nz(pget(r, "lane"), ""))
    pile = lane in ("notifications", "activity", "backlog") || retired_lane(lane)
    pile && isempty(String(nz(pget(r, "reply"), "")))
end

"""The lanes that were deleted on 2026-09-13 - the firehose and the six
mention and comment searches. A row in `fetched.json` still carrying one is
from before, and is dropped without a change line rather than carried, since
nothing will ever return it again."""
retired_lane(lane::AbstractString) =
    lane == "firehose" || startswith(lane, "mentioned") || startswith(lane, "commented")

"""Which notification `reason`s name *you* - as against `subscribed`, which is
the repository being watched. A thread with one of these is brought into the
corpus with its bundle the first time it is seen; a watched repository's
traffic stays a light row in the inbox until it is looked at. The rule is the
source's, `Events.involved_reason`, which reads it on the backfill too."""
involved(reason) = Events.involved_reason(reason)

"""Read the item blocks of `local.toml`.

Dates written unquoted (`adopted = 2026-09-04`) come back as `Date`; everything
downstream compares and prints them as ISO strings, so flatten them here. The
Python raised `TypeError` out of `json.dumps` on the same input.
"""
function load_state()
    # `localfile()` and not `datapath`, so a test that points `LOCAL` somewhere
    # disposable is pointing *this* somewhere disposable too. It read the real
    # file through the redirect for as long as it has been here.
    p = localfile()
    isfile(p) || return Dict{String,Any}()
    raw = parse_local(p)
    # Item blocks only. The file's other inhabitants are keyed by what they are
    # - `repo:o/r` - and a refresh has no business reading them.
    Dict{String,Any}(u => Dict{String,Any}(
        k => (v isa Union{Date,DateTime,Dates.Time} ? string(v) : v) for (k, v) in st)
        for (u, st) in raw if st isa AbstractDict && !startswith(u, "repo:"))
end

"""An adopted branch whose pull request has arrived hands it what was written.

The branch was the item while there was nothing else to be: a `local:` row
carrying the note, the track, whatever was said about the work.
Once the pull request exists it is the item, and everything the branch row
carried is about it - so those move to its block, the branch stops being
adopted, and the row that was in the list under one name is in it under the
other with nothing lost. Moved rather than copied: a note found again on the
branch after the pull request is closed would be a note about work that has
landed, and re-adopting is deliberate anyway.

Only your own pull request, since the branch is yours: somebody else's from a
branch of the same name - `master` on a fork, twice a week - is not what the
adoption was about. And only keys the pull request's block does not already
have, so a note written on the pull request itself is not written over by an
older one on the branch - except the interaction clock, which is whichever of
the two is later.

`state` is updated in place as well, so the rows derived after this carry what
was moved in the same run. Answers with the refs it handed over.
"""
function adopt_pull_requests!(items, state, login::AbstractString)
    byb = Dict{Tuple{String,String},String}()
    for (u, st) in state
        (islocal(u) && truthy(get(st, "adopted", nothing))) || continue
        byb[localparts(u)] = u
    end
    isempty(byb) && return String[]
    carried = ("note", "snooze", "track", "touched")
    ups = Pair{String,Vector{Pair{String,Any}}}[]
    out = String[]
    for (url, r) in items
        pget(r, "type") == "PullRequest" || continue
        String(nz(pget(r, "author"), "")) == login || continue
        lu = get(byb, (String(nz(pget(r, "repo"), "")), String(nz(pget(r, "branch"), ""))), nothing)
        lu === nothing && continue
        from = state[lu]
        to = get!(state, url, Dict{String,Any}())
        into, outof = Pair{String,Any}[], Pair{String,Any}["adopted" => nothing]
        for k in carried
            v = get(from, k, nothing)
            truthy(v) || continue
            push!(outof, k => nothing)
            # The clock is the later of the two; a word is the one already there.
            have = get(to, k, nothing)
            truthy(have) && (k != "touched" || String(have) >= String(v)) && continue
            push!(into, k => v)
            to[k] = v
        end
        delete!(from, "adopted")
        for k in carried
            delete!(from, k)
        end
        isempty(into) || push!(ups, url => into)
        push!(ups, lu => outof)
        push!(out, string(last(split(String(pget(r, "repo")), '/')), "#", pget(r, "number")))
        delete!(byb, localparts(lu))        # one pull request takes it
    end
    isempty(ups) || set_blocks!(ups)
    out
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
            @printf(warning(),
                    "  %-16s %s left the dashboard with an unsent draft review\n",
                    "drafts", ref)
        end
    end
    dropped > 0 && @printf(report(), "  %-16s %d mark(s) dropped with their items\n",
                           "drafts", dropped)
    dropped
end

"""
    derive!(r, old, st, cfg, at) -> r

Everything a row is given beyond what GitHub said about it, in the order the
refresh always did it: the carried keys (`their_head`, the two comment
clocks), the facts and the tracking level (`apply_state!`), the wake, the
second look, and the mark - `moved_at`, against the row it replaces. Its own
function because a refresh is no longer the only place a row is built: the
browser fetches the bundle for the row under the cursor and has to give it
the same facts, or the tags on the row you are looking at would be the one
place they could drift.

`old` is the row this one replaces, or `nothing` on first sight - or the row
itself, for one the refresh kept without asking GitHub again, in which case
nothing moves and only what depends on `at` (the second look) and on
`local.toml` is re-derived. Returns the row; `r["slept"]` says whether it
has a snooze or an archive but no done stamp, which the refresh stamps once
for all of them, and `r["woken"]` whether its snooze has run out, which the
refresh writes down as unread once for all of them.
"""
function derive!(r, old, st, cfg, at::DateTime)
    login = cfg["login"]
    second_days = Int(get(cfg["thresholds"], "second_look_days", 2))
    r["their_head"] = their_head(r, old, login)
    r["their_comment_at"] = their_comment_at(r, old, login, "their_comment_at"; human = false)
    r["human_comment_at"] = their_comment_at(r, old, login, "human_comment_at"; human = true)
    r["mentioned"] = mentioned_of(r, old)
    apply_state!(r, st, cfg, at)
    # **A snooze is a wake time, and an archive is a mark.** Neither is a
    # decision this run makes: the browser reads both off `local.toml` and
    # answers "is it unread" per frame - `seen_of` - with the wake as a
    # second reason beside the wake table. What this run does with them is
    # two things. It carries the resolved wake on the row for the second
    # look, since an item you have said "not now" about is not one to be
    # reminded of; and it stamps done an item that has a snooze or an archive
    # but no done stamp - a value typed into the file by hand, which is what
    # `apply_snooze!` and `wl snooze` do on the way in and the only thing that
    # used to need an arming. Without it the item would be unread and hidden
    # by nothing, and "not now" would have said nothing at all.
    read_ = get(st, "done", nothing)
    r["wake"] = wake_of(get(st, "snooze", nothing), read_)
    held = (r["wake"] !== nothing && !woken(r["wake"], at)) ||
           truthy(get(st, "archived", nothing))
    r["slept"] = held && !truthy(read_)
    # And the other end of a snooze: a wake that has passed is written down
    # - `done = ""`, the snooze gone - so that **unread implies no snooze**.
    # The browser shows the row unread from the moment the wake passes,
    # `seen_of` reading the wake per frame; this is the file catching up,
    # and what lets a done mark take afterwards: every mark stamps the last
    # movement, which is under the wake, so a snooze left standing would
    # keep the row unread whatever was pressed. Said unread rather than
    # left to the stamp, since the stamp is the movement the snooze was
    # made at and would read as read; `done_head` stays, because you are
    # still where you were in it.
    r["woken"] = r["wake"] !== nothing && woken(r["wake"], at)
    # After `reply`, which `in_pile` reads and the pile is not a to-do
    # list, and after the snooze, for the reason above.
    r["second_look"] = held ? "" : second_look(r, at, second_days)
    # **When this program last saw a change you asked to be told about** -
    # what the seen axis compares your done stamp against.
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
    # `WOKE`, `snooze_fp`, `snooze_at`, a `mark_done` on falling asleep and
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
    #
    # **And which key moved it**, `moved_by`, kept beside the stamp: the
    # pane's one word for what made the row unread - a push, a comment, a
    # review - which the stamp alone cannot say. `new` on first sight; the
    # key it had when nothing moved, or nothing, for a row from before there
    # was one.
    if old === nothing
        r["moved_at"], r["moved_by"] = first_seen_at(r), "new"
    else
        (r["moved_at"], by) = movement(old, r, at)
        r["moved_by"] = isempty(by) ? String(nz(jget(old, :moved_by), "")) : by
        isempty(r["moved_by"]) && (r["moved_by"] = moved_key(r))
    end
    r["new"] = old === nothing
    r
end

"""The key of the wake table whose time is the row's `moved_at`, or `""`.

For a row from before the refresh kept `moved_by`: the record catching up,
once, so that the pane does not say `moved` of every row until each moves
again. A stamp that is an event's time names the event; a bool's, a
force-push's or a first sight's names nothing, and `""` is the answer.
"""
function moved_key(r)
    m = String(nz(get(r, "moved_at", nothing), ""))
    isempty(m) && return ""
    for k in get(TRACK_KEYS, r["track"], TRACK_KEYS["normal"])
        by = get(TIMED_KEYS, k, nothing)
        by === nothing && continue
        String(nz(get(r, by, nothing), "")) == m && return k
    end
    ""
end

"""The mark a row gets on first sight: the newest thing GitHub says happened
to it - a push or a comment (`activity_at`), or any of the dated keys of the
wake table, whichever is latest. A row arrives here because something brought
it - a review request, an assignment, somebody merging it - and that event is
on the row as a time; dating the row by the last comment instead, as
`activity_at` alone did, put the mark before the event, and before a read
stamp from an earlier life, so a thread the inbox said was unread arrived
read. Every one of these is GitHub's time, so a rebuilt `fetched.json` still
does not read as everything moving at once."""
function first_seen_at(r)
    best = String(activity_at(r))
    for k in values(TIMED_KEYS)
        t = get(r, k, nothing)
        truthy(t) && (best = max(best, String(t)))
    end
    best
end

"""What moved between `old` and `r`, said for a person, or `""`.

Gated on the mark, not on the hash: a green or a relabel that moved nothing is
not in it. Said as what happened, because it is an event and not a value:
"review_requested_at 14:02->16:40" is the same sentence written for a machine,
and this is the line a person reads to find out why their dashboard changed.
"""
function change_of(old, r)
    r["moved_at"] == String(nz(jget(old, :moved_at), "")) && return ""
    d = String[]
    jget(old, :review_requested_at) == get(r, "review_requested_at", nothing) ||
        push!(d, "review requested")
    jget(old, :assigned_at) == get(r, "assigned_at", nothing) ||
        push!(d, "assigned to you")
    jget(old, :state_at) == get(r, "state_at", nothing) ||
        push!(d, get(r, "state", nothing) == "OPEN" ? "reopened" :
                 lowercase(something(get(r, "state", nothing), "closed")))
    # The events say what happened; the states say what they went from and
    # to. `their_head` and `review_at` are printed as events even though they
    # are a sha and a timestamp, because "new push 0a1b2c->3d4e5f" is not a
    # sentence anybody reads.
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
    join(d, ", ")
end

"""A row kept from the last run without asking GitHub again, as this run's
row: a copy, so that the derivation can compare it to itself and find nothing
moved. `fetched_at` stays what it was, which is the whole point."""
kept_row(old) = OrderedDict{String,Any}(String(k) => v for (k, v) in pairs(old))

"""What a thread the notifications source saw contributes to the corpus row
built for it: the reason. Off the inbox row, which
is where GitHub said it - or off the row being replaced, when the inbox has
no thread for this url any more: a mention that was read, and then moved in
a way the repo poll saw and the notifications source did not re-deliver (a
label, your own comment), is still a mention, and the `reply` tag still reads
the reason."""
function thread_facts!(r, inbox_row, old = nothing)
    v = inbox_row === nothing ? nothing : get(inbox_row, "reason", nothing)
    truthy(v) || (v = jget(old, :reason))
    truthy(v) && (r["reason"] = String(v))
    carry_mention!(r, inbox_row, old)
end

"""The `mentioned` latch, onto a row built afresh: off the inbox row, which may
have latched it off a reason that has moved on since, or off the row being
replaced. `derive!` then sets it from this row's own reason if neither had it;
see `Events.mention_words`."""
function carry_mention!(r, inbox_row, old = nothing)
    v = inbox_row === nothing ? nothing : get(inbox_row, "mentioned", nothing)
    truthy(v) || (v = jget(old, :mentioned))
    truthy(v) && (r["mentioned"] = String(v))
    r
end

"""Whether you were ever named on this, as a sentence, or `""`: what the row
already carries, else what the row it replaces did, else its reason now. Never
unset once set - the whole of what makes it a different fact from `reason`."""
function mentioned_of(r, old)
    v = String(nz(get(r, "mentioned", nothing), ""))
    isempty(v) || return v
    v = String(nz(jget(old, :mentioned), ""))
    isempty(v) || return v
    Events.mention_words(r)
end

"""
    stale_by(inbox_row, old, read) -> bool

Has anything seen this row move since its bundle was fetched? Two witnesses.
The inbox row's `updated` is GitHub's time for the newest thing the poll or
the notifications source saw; `fetched_at` is GitHub's time for when the
bundle was asked. Both GitHub's, so they compare - where the row's own
`updated` does not: a thread's `updated_at` is the *delivery* time, 2 to 46
seconds after the subject's `updatedAt` for the same event, and comparing the
two read 35 unmoved rows as moved. And the **done stamp**, `done`: `e` on a
row in the list writes it up to the newest movement the list knew of, which
for a light row is the inbox's clock, and with a thread on screen the newest
event in it, fetched fresher than any bundle - so a done stamp past the
bundle is evidence that something was seen the bundle does not have. A row
from before there was a `fetched_at` is stale, once.
"""
function stale_by(inbox_row, old, read = nothing)
    f = jget(old, :fetched_at)
    truthy(f) || return true
    inbox_row !== nothing &&
        String(nz(get(inbox_row, "updated", nothing), "")) > String(f) && return true
    truthy(read) && String(read) > String(f)
end

"""Is there a clock over this url? The repo poll covers the repositories named
in `[events] repos` and the owners globbed there, and it sees every change
that moves `updated_at`. The notifications source is *not* a clock in that
sense, and until 2026-09-14 counted as one: it fires for participation - a
comment, a review, a request, a close - and not for a push, your own reply
from github.com, an unassignment, a draft toggle or a label, each of which
moves a row's facts and the wake table reads (`their_head` is a key at both
levels). So a carried row outside the polled repositories has no clock over
the kinds of change that matter most, and while it is open and in front of
you - not over, not the pile - it is asked by url every run, the way every
carried row was before the clocks. The set is the open carried rows, a
handful, and forty of them are one request."""
function covered(url::AbstractString, cfge)
    repo = join(split(String(url), '/')[4:5], '/')
    explicit, owners, _ = Events.event_sources(get(cfge, "repos", String[]))
    repo in explicit || first(split(repo, '/')) in owners
end

"""
    lane_query(name, q, login) -> q, as the walk will run it

What a lane may say, checked once per refresh rather than assumed. `search`
walks a lane by creation time when the query is sorted that way, and by
offset when it is not - silently, and the offset walk is the one that slips
a row when the set moves under it - so the sort is put on for a lane that
names none, and a lane that names another is refused: two sorts in one query
is nothing GitHub defines. A `created:` qualifier is refused too, since
GitHub ors two qualifiers on one field and the floor could never narrow it
(see `search`). And two things the machinery assumes without being able to
check for itself are said on stderr rather than refused: every lane is taken
to be the *open* work, which is what `covered`, `merged_by` and the wake
table read a lane row as; and a lane is taken to name *you* - `in_pile`
reads a lane row as in front of you, and a lane that names somebody else, or
a whole repository, gets the second look on every row.
"""
function lane_query(name::AbstractString, q::AbstractString, login::AbstractString)
    occursin(r"\bcreated:", q) &&
        die("lane $name: a `created:` qualifier is not allowed - the lane is walked by " *
            "creation time, and GitHub ors two qualifiers on one field")
    m = match(r"\bsort:(\S+)", q)
    m === nothing || m[1] == "created-asc" ||
        die("lane $name: `sort:$(m[1])` - a lane is walked `sort:created-asc`, or not sorted")
    occursin("is:open", q) ||
        @printf(warning(), "  %-9s not `is:open`: every lane is read as the open work\n", name)
    occursin(login, q) || occursin("@me", q) ||
        @printf(warning(), "  %-9s names neither %s nor @me: its rows will be read as yours\n",
                name, login)
    m === nothing ? string(q, " sort:created-asc") : String(q)
end

"""A corpus row from one REST issue, for the open list: the keys `item_of`,
`derive!` and the tags read, in the shape `normalize` gives a GraphQL node,
with nothing the REST list does not carry - no head, no reviews, no
timeline. Light, the way the firehose's rows were; filled in by url the
first time a clock says it moved or the cursor lands on it."""
function backlog_row(r, login::AbstractString)
    who = String(nz(get(something(get(r, "user", nothing), Dict{String,Any}()), "login", nothing), "?"))
    assignees = String[String(a["login"]) for a in get(r, "assignees", ())]
    ms = get(r, "milestone", nothing)
    OrderedDict{String,Any}(
        "type" => haskey(r, "pull_request") ? "PullRequest" : "Issue",
        "lane" => "backlog",
        "url" => String(r["html_url"]), "number" => r["number"], "title" => r["title"],
        "repo" => Events.item_repo(r), "author" => who,
        "state" => uppercase(String(get(r, "state", "open"))),
        "created" => get(r, "created_at", nothing), "updated" => r["updated_at"],
        "labels" => String[String(l["name"]) for l in get(r, "labels", ())],
        "milestone" => ms === nothing ? nothing : get(ms, "title", nothing),
        "milestone_due" => ms === nothing ? nothing : get(ms, "due_on", nothing),
        "assignees" => assignees, "mine" => who == login || login in assignees,
        "last_comment_by" => nothing, "last_comment_at" => nothing,
        "assigned_at" => nothing, "state_at" => nothing)
end

"""
    open_list(cfge, login; only) -> rows

**The whole open list of the polled repositories, for the backlog view.** The
unread side starts at zero - `backfill_days`, and a clock brings in only what
moves from then on - and this is the other half of that policy: the open
issues and pull requests of every repository under `[events]` are in the
corpus from the start, as `backlog` rows, done by construction up to the day
the source was named (`source_since`, `floor_of`; the `source:` blocks in
`local.toml`), so the backlog view is the standing list and the dashboard is
not. Unread the moment one next moves, like any carried row; filled in by url
then, or when the cursor lands on it.

Named repositories are read off the REST list, a hundred a page, ascending by
creation, which is light and fast - julia is 4,700 rows in 47 pages; owner
globs go through the search lane walk, which is the only way to ask about an
owner at once and comes back with the bundle. `only` names the sources to
import; every source, when it is the `--backlog` run.
"""
function open_list(cfge, login::AbstractString; only = nothing, spent = Ref(0))
    explicit, owners, _ = Events.event_sources(get(cfge, "repos", String[]))
    rows = Any[]                     # `normalize` gives a Dict, `backlog_row` an ordered one
    for repo in explicit
        (only === nothing || repo in only) || continue
        got = Events.api_paged("/repos/$repo/issues"; max_pages = 200,
            params = Dict{String,Any}("state" => "open", "sort" => "created",
                                      "direction" => "asc"))
        for r in got
            push!(rows, backlog_row(r, login))
        end
        @printf(report(), "  %-9s %4d open in %s\n", "backlog", length(got), repo)
    end
    for owner in owners, kind in ("is:issue", "is:pr")
        (only === nothing || string(owner, "/*") in only) || continue
        nodes, c, total = search("user:$owner is:open $kind archived:false sort:created-asc")
        spent[] += c
        for n in nodes
            push!(rows, normalize(n, "backlog", login))
        end
        @printf(report(), "  %-9s %4d open under %s/* (%s, %d pts)\n", "backlog",
                length(nodes), owner, kind, c)
    end
    rows
end

"""Let the other tasks have a turn, every so often inside a loop over the corpus.

The refresh runs on the browser's own task loop under `u` (`refresh_all!`),
and tasks are cooperative: a walk over 5,500 rows that never yields holds the
key loop for as long as it takes, which was half a second in one stretch when
measured (2026-09-17, network faked). With a turn every 256 rows the longest
stretch left is the file itself - `load_fetched` at 20 ms and `save_fetched` at
100 ms - which is a hitch and not a hang. Nothing else changes: the same rows
are walked in the same order, and the browser draws its own copy meanwhile.
"""
breathe(i::Int) = (i % 256 == 0 && yield(); nothing)

"""Re-fetch, re-derive, re-render. Returns the exit code.

Everything it has to say goes to `io` - stderr under `wl refresh`, the file
`run_refresh!` keeps under `u`, a buffer in a test - through a report of its own
(`reporting`), so the warnings among those lines are counted and the summary
line says how many there were.
"""
function refresh(args::Vector{String} = String[], at::Union{Nothing,DateTime} = nothing;
                 io::IO = report(), kw...)
    first(refresh_report(args, at; io = io, kw...))
end

"The same, answering with the report as well: the browser reads the summary
and the warning count off it, having no last line of a child to read."
refresh_report(args::Vector{String} = String[], at::Union{Nothing,DateTime} = nothing;
               io::IO = report(), kw...) =
    reporting(() -> refresh_(args, at; kw...), io)

function refresh_(args::Vector{String}, at::Union{Nothing,DateTime};
                  search = search, fetch_url_map = fetch_url_map, poll = Events.poll,
                  open_list = open_list)
    cfg = config()
    cfgtext = config_text()
    login = cfg["login"]
    # When a row was fetched, as GitHub's time: `at` plus how long this
    # machine has been running since it asked for `at` - `t0` taken after
    # `at` came back, not before it was asked, or the stamp would run ahead
    # of GitHub by that request's round trip. Stamped per fetch
    # and not once for the run, since the lanes take fifteen seconds and a
    # bundle the browser fetched in that window is *newer* than the lanes'
    # row for the same url, and would otherwise lose the overlay to it - and
    # taken **before** the request, not after: a stamp from after a fifteen
    # second walk is later than a bundle fetched during it, and the older
    # data would win. Earlier is the safe direction for every comparison
    # this feeds - a row is at least as old as its stamp says.
    now_() = stamp(at + Millisecond(round(Int, (time_ns() - t0) ÷ 1_000_000)))
    # **GitHub's now, not this machine's.** Everything this run stamps is
    # compared, sooner or later, against a time GitHub wrote - a movement with
    # no clock of its own against the done mark, a done mark on a hand-typed
    # snooze against the next comment, a bundle's `fetched_at` against the
    # inbox's clock - so the instant it is all measured from is GitHub's, off
    # a `Date` header, and not the local clock plus a correction. One request,
    # free of the rate limit. A test hands in its own.
    at === nothing && (at = Events.server_now())
    t0 = time_ns()                       # monotonic: a duration, not a clock
    state = load_state()
    # What the last run left, to diff this one against. Read once and held: the
    # parts of the file this run writes - the poll's inbox, the items
    # themselves - each go back through a fresh read at the moment they are
    # written, since between them they span a minute of network.
    prev_items = something(fetched("items"), (;))
    yield()                                  # a 6 MB parse, in one piece
    # The row this run knows last about a url: the file's, or the bundle the
    # browser fetched for the row under the cursor when that is the newer.
    # Derived against *that*, so the two agree: a bool becoming true is dated
    # by whoever saw it first (`moved_stamp`), and a refresh that compared
    # against the file's older row would see the same edge again, date it
    # again, and put back in front of you a thing you had read.
    prev(url) = bundled(url, jget(prev_items, Symbol(url)))
    cfge = get(cfg, "events", Dict{String,Any}())

    # **The open work is asked for whole, every run.** The three lanes are
    # GraphQL searches because they do two things at once that nothing else
    # does as cheaply: they *enumerate* the standing set - a pull request of
    # yours that nobody has touched notifies nobody - and they return the
    # bundle for every row in it, which is the set whose tags have to be
    # right: `ready`, `edits` and `review` read CI, the review threads and
    # the draft flag, and all three change without a word from any clock.
    # ~135 rows, four pages, 16 points, 15 seconds; dozens of presses a day
    # is a few hundred points. Measured 2026-09-13, and decided against a
    # heuristic: moved-recently is not a hint for what moves next.
    items = OrderedDict{String,Any}()
    spent = 0
    for (lane, q) in ordered(cfg["lanes"], cfgtext, "lanes")
        f = now_()
        nodes, c, total = search(expand_lane(lane_query(lane, q, login), at))
        spent += c
        for n in nodes
            r = normalize(n, lane, login)
            r["fetched_at"] = f
            items[String(n.url)] = r
        end
        @printf(report(), "  %-9s %3d items (%d pts)%s\n", lane, length(nodes), c,
                total > length(nodes) ? " - CUT at $(length(nodes)) of $total: the open work is not whole" : "")
    end

    # Items no lane returns, tracked because they were asked for by url. They
    # go in after the lanes, so a lane that does return one wins: an import is
    # how an item is followed, not what it is.
    imp = imported_urls()
    if !isempty(imp)
        kept = 0
        f = now_()
        for n in try
                    Any[n for n in values(fetch_url_map(imp)) if n !== nothing]
                 catch e
                    @printf(warning(), "  %-9s failed: %s\n", "imported",
                            first(sprint(showerror, e), 120))
                    Any[]
                 end
            u = String(n.url)
            haskey(items, u) && continue
            items[u] = normalize(n, "imported", login)
            items[u]["fetched_at"] = f
            kept += 1
        end
        @printf(report(), "  %-9s %3d items (of %d)\n", "imported", kept, length(imp))
    end

    # **The open list of a polled repository is in the corpus from the start**
    # - on `--backlog`, for every source; and on a source's first sight, so
    # that naming a repository brings its standing list into the backlog
    # view rather than a month of its traffic into the dashboard. First sight
    # is the `source:` block missing from `local.toml`, where the day it was
    # named is written and stays: the floor every row of that source is
    # done up to, and the one fact a rebuild of `fetched.json` needs and
    # could not get from GitHub. Rows the corpus has already are left alone.
    explicit_, owners_, _ = Events.event_sources(get(cfge, "repos", String[]))
    sources = vcat(explicit_, [string(o, "/*") for o in owners_])
    named = source_since()
    first_sight = [l for l in sources if !haskey(named, l)]
    want = "--backlog" in args ? nothing : first_sight
    backlog = String[]
    if want === nothing || !isempty(want)
        f = now_()
        for l in (want === nothing ? sources : want)
            name_source!(l, f)
        end
        pts = Ref(0)
        for r in open_list(cfge, login; only = want, spent = pts)
            u = String(r["url"])
            (haskey(items, u) || haskey(prev_items, Symbol(u))) && continue
            r["fetched_at"] = f
            items[u] = r
            push!(backlog, u)
        end
        spent += pts[]
        @printf(report(), "  %-9s %4d rows new to the corpus, done by construction\n",
                "backlog", length(backlog))
    end

    # **Everything else is asked by url, and only when a clock says it
    # moved.** The clocks are the notifications source and the repo poll,
    # which `Events.poll` runs and whose rows say, per url, GitHub's time
    # for the newest thing either saw. Three kinds of row reach this:
    #
    #   * a row the corpus has - once in a lane, or brought in below - that no
    #     lane returned this run: **carried**, kept as it is until a clock
    #     says it moved, then asked again. Until 2026-09-13 every carried row
    #     was asked again every run.
    #   * a thread that names you - `mention`, `review_requested`, `assign`,
    #     `author`, `comment`, `team_mention`, `manual`, anything but the
    #     repository being watched - that the corpus has not seen: **brought
    #     in**, with its bundle, so it carries the same facts as everything
    #     else and the `reply` tag can be read off it. This is what the six
    #     mention and comment searches and the three closed lanes were for.
    #   * a row of a watched repository's traffic, `subscribed` or the poll's
    #     own: **not here**. It stays a light row in the inbox, shown by the
    #     browser as such, until it is looked at - `fetch_bundle` - or a lane
    #     returns it.
    #
    # **Nothing leaves.** The corpus is the index of everything that was ever
    # in front of you, done or not, and a row in it is kept for good: read
    # rows are what the `done` box holds, filed ones the `filed` box, and a
    # snooze on a row that then left would be a wake with nothing to wake.
    # It used to prune a carried row once it was read - which was right while
    # the closed lanes and the bulk searches re-returned anything that moved,
    # and wrong the day they went: a done row that then moved came back with
    # its carried keys gone, or oscillated between the clock bringing it in
    # and the prune letting it go. The rows of the nine retired lanes stay
    # too, as they were; `in_pile` knows their names.
    inbox = Dict{String,Any}(String(e["url"]) => e for e in poll(cfg, login, at))
    # A lane row carries the thread's reason too, when there is one: a mention
    # on your own pull request is a mention, and the `reply` tag reads it.
    # Off the row it replaces when the inbox has no thread for it any more.
    for (url, r) in items
        thread_facts!(r, get(inbox, url, nothing), prev(url))
    end
    ask = OrderedDict{String,String}()        # url => the lane its row gets
    carried = String[]
    for (i, k) in enumerate(keys(prev_items))
        breathe(i)
        url = String(k)
        haskey(items, url) && continue
        old = prev(url)
        lane = String(nz(jget(old, :lane), "carried"))
        push!(carried, url)
        if stale_by(get(inbox, url, nothing), old,
                    get(get(state, url, Dict{String,Any}()), "done", nothing)) ||
           (!covered(url, cfge) && !isover(old) && !in_pile(old))
            ask[url] = lane
        else
            items[url] = kept_row(old)
        end
    end
    brought = 0
    for (url, e) in inbox
        (haskey(items, url) || haskey(ask, url)) && continue
        involved(get(e, "reason", nothing)) || continue
        ask[url] = String(nz(get(e, "lane", nothing), "notifications"))
        brought += 1
    end
    # **A mark is proof it was in front of you.** A watched repository's
    # thread stays a light row in the inbox until it is looked at - and the
    # inbox is a clock, not a place: a light row you opened, or pressed `e`
    # or `s` or `x` on, has to be somewhere the boxes can find it once the
    # clock has been read. Any url with a block in `local.toml` that the
    # corpus does not have joins it: off the bundle the browser cached when
    # you looked, kept as it is, or - marked without a look, `e` from the
    # list - asked by url like a thread that names you.
    promoted, marked = 0, 0
    for url in keys(state)
        startswith(url, "https://") || continue
        (haskey(items, url) || haskey(ask, url)) && continue
        b = bundle_of(url)
        if b !== nothing
            items[url] = kept_row(b)
            push!(carried, url)
            promoted += 1
        elseif haskey(inbox, url)
            ask[url] = String(nz(get(inbox[url], "lane", nothing), "activity"))
            marked += 1
        end
    end
    promoted += marked
    promoted == 0 || @printf(report(), "  %-9s %3d light rows marked or looked at, kept from here\n",
                             "promoted", promoted)
    gone = Tuple{String,String}[]
    renamed = Dict{String,String}()           # new url => the one asked
    if !isempty(ask)
        got, moved_, landed = 0, 0, 0
        f = now_()
        answers = try
            fetch_url_map(collect(keys(ask)))
        catch e
            @printf(warning(), "  %-9s failed: %s\n", "by url",
                    first(sprint(showerror, e), 120))
            OrderedDict{String,Any}()
        end
        for (asked, n) in answers
            n === nothing && continue
            # Under the url GitHub answers with, which is the one asked unless
            # the repository or the issue has moved since - `resource` follows
            # the redirect. Then the row lives under its new name from here,
            # with the old row as what it replaces, and the old name goes:
            # no clock will ever say it again. What `local.toml` holds under
            # the old name - a note, a done stamp - stays under it. And when
            # the new name is here already - a lane returned it, or it was
            # asked for itself - that row is the row, and the old name only
            # goes. A kept row under an old name that is never asked again
            # stays, as it was: a duplicate with old facts, until it is.
            u = String(n.url)
            if u != asked
                moved_ += 1
                old = prev(asked)
                delete!(items, asked)
                push!(gone, (asked, String(nz(jget(old, :ref), asked))))
                @printf(report(), "  %-9s %s is now %s\n", "by url", asked, u)
                (haskey(items, u) || haskey(answers, u)) && continue
                renamed[u] = asked
            end
            r = normalize(n, ask[asked], login)
            r["fetched_at"] = f
            items[u] = thread_facts!(r, get(inbox, u, get(inbox, asked, nothing)), prev(asked))
            prev(asked) === nothing && (landed += 1)
            got += 1
        end
        # A url asked and not answered - the fetch failed whole, or the one
        # url names nothing this token can see - keeps the row it had, as it
        # was. Dropping it would be for good: no lane returns it, that is why
        # it was asked, and a burst of forty is the shape the secondary rate
        # limit trips on.
        unanswered = 0
        for asked in keys(ask)
            (haskey(items, asked) || get(answers, asked, nothing) !== nothing) && continue
            old = prev(asked)
            old === nothing && continue
            items[asked] = kept_row(old)
            unanswered += 1
        end
        # A thread the token cannot see is asked and not answered, and has no
        # row to keep; it stays a light row, and is asked again while unread.
        @printf(report(), "  %-9s %3d items fetched: %d moved, %d threads new here%s (of %d asked%s)\n",
                "by url", got, length(ask) - brought - marked, landed,
                landed == brought ? "" : " of $brought asked", length(ask),
                unanswered == 0 ? "" : "; $unanswered unanswered, kept as they were")
    end
    @printf(report(), "  %-9s %3d items no lane returns, kept or re-asked\n", "carried",
            length(carried))
    carried = Set(carried)

    # A kept row from before there was a stamp gets one now: no clock saw it
    # this run, and from here the clocks are read against it.
    for (url, r) in items
        truthy(get(r, "fetched_at", nothing)) || (r["fetched_at"] = now_())
    end

    # **Every source names itself on first sight**, and a lane is a source:
    # a row with no done stamp is done up to the day its source was named
    # (`floor_of`), so a lane first seen today - the three configured ones on
    # the first run, the retired ones once, for their rows from before there
    # was a floor - reads as zero unread rather than as every row it ever
    # returned. The repositories were named above, where their lists came
    # in, and `notifications` where its cursor started; what is left is
    # every lane value a corpus row carries with no block yet.
    let named = source_since(), f = now_()
        lanes = unique(String(nz(get(r, "lane", nothing), "")) for (_, r) in items)
        fresh = sort!([l for l in lanes if !isempty(l) && !(l in ("backlog", "activity")) &&
                                            !haskey(named, l)])
        for l in fresh
            name_source!(l, f)
        end
        isempty(fresh) || @printf(report(), "  %-9s %d source(s) named, done up to today: %s\n",
                                  "sources", length(fresh), join(fresh, ", "))
    end

    # The facts, then the tracking level, then the wake table at that level.
    # Order matters: the level decides which keys `moved_stamp` compares. A
    # kept row is derived against itself, so nothing about it moves and only
    # the second look and `local.toml` are re-read. **And a row this run
    # fetched is derived against the newest thing known about it - which is
    # the browser's bundle, when the cursor was on the row while the lanes
    # were running and something landed between the two fetches. Then the
    # bundle is the row: deriving the older fetch against the newer one would
    # read the comment it lacks as a comment deleted, date that by the
    # refresh clock, and put a thing you were reading back in front of you.
    # Before the loop, since it changes what `state` says about a row in it.
    handed = adopt_pull_requests!(items, state, login)
    isempty(handed) || @printf(report(), "  %-16s %4d adopted branch(es) now a pull request: %s\n",
                               "adopted", length(handed), join(handed, ", "))
    changes = Any[]
    slept, woke = String[], Pair{String,String}[]
    for (i, (url, r)) in enumerate(collect(items))
        breathe(i)
        st = get(state, url, Dict{String,Any}())
        old = prev(get(renamed, url, url))
        if old !== nothing && String(nz(jget(old, :fetched_at), "")) > String(r["fetched_at"])
            r = items[url] = kept_row(old)
        end
        derive!(r, old, st, cfg, at)
        pop!(r, "slept") && push!(slept, url)
        pop!(r, "woken") && push!(woke, url => String(r["wake"]))
        if old === nothing
            push!(changes, (url, r, "new"))
        else
            d = change_of(old, r)
            isempty(d) || push!(changes, (url, r, d))
        end
    end
    reconcile_drafts!(gone)

    # Once, after the loop: this rewrites a file, and a refresh that finds
    # twenty hand-typed snoozes should not rewrite `local.toml` twenty times.
    isempty(slept) || @printf(report(), "  %-16s %4d marked done, having been put away by hand\n",
                              "snooze", mark_done(slept, at))
    isempty(woke) || @printf(report(), "  %-16s %4d woke: unread, and the snooze is gone\n",
                             "snooze", mark_woken(woke))

    # **The inbox is a clock, never an answer.** An inbox row for a url the
    # corpus has is there to say "ask again" (`stale_by`), and it has said it
    # once the corpus row's `fetched_at` passes its `updated` - *consumed* -
    # and the row is *read* (`seen_of`, against the marks as they stand after
    # the snoozes above). Both, and it goes. Unread it stays, so `expect!`'s
    # `notified` history is kept while there is anything to witness;
    # unanswered it stays, to be asked again. A light row - no corpus row -
    # is never dropped by reading: a mark on it promotes it, above, and the
    # next run finds it consumed and read. Until 2026-09-16 `sync!` dropped
    # a row on `updated <= read`, which nothing that stamps the wake table's
    # movement could satisfy on a row whose `updated` had moved past it - a
    # push, a label, your own comment: 366 of 5553 rows on the day.
    yield()
    inbox_ = Events.load_inbox()
    marks = Marks(done = load_done(), sources = source_since(), wake = wake_map(),
                  now = stamp(at))
    yield()
    dropped = String[]
    for (i, (url, e)) in enumerate(inbox_["items"])
        breathe(i)
        r = get(items, url, nothing)
        r === nothing && continue
        String(nz(get(e, "updated", nothing), "")) <= String(r["fetched_at"]) || continue
        seen_of(item_of(JSON3.read(json_dumps(r))), marks) === :done || continue
        push!(dropped, url)
    end
    for u in dropped
        delete!(inbox_["items"], u)
    end
    isempty(dropped) || @printf(report(), "  %-16s %4d rows asked about and done, dropped\n",
                                "inbox", length(dropped))
    # And a row under a name GitHub answered with another name for: asked,
    # and no clock will ever say the old name again - the row it made lives
    # under the new one, with what this row said carried on it
    # (`thread_facts!`). Kept, it would never be consumed: no corpus row is
    # ever under that name, so it would be asked by url on every run, follow
    # the same redirect, and say "is now" in every report.
    moved = [u for (u, _) in gone if haskey(inbox_["items"], u)]
    for u in moved
        delete!(inbox_["items"], u)
    end
    isempty(moved) || @printf(report(), "  %-16s %4d rows under a name that moved, dropped\n",
                              "inbox", length(moved))
    append!(dropped, moved)
    # A value typed wrong is not a snooze, and nothing else says so.
    for (u, st) in state
        v = get(st, "snooze", nothing)
        truthy(v) && parse_snooze(String(v)) === nothing &&
            @printf(warning(), "  %-16s bad snooze value '%s'  (%s)\n", "snooze", v, u)
    end

    yield()                     # the two unbroken stretches: a parse and a write
    store = load_fetched()
    store["fetched_at"], store["points"], store["items"] = now_isoformat(at), spent, items
    isempty(dropped) || (store["inbox"] = inbox_)
    # The bulk cache is gone with the lanes that wrote it; a file that still
    # has one loses it here rather than carrying two thousand rows nothing
    # reads.
    haskey(store, "bulk") && delete!(store, "bulk")
    # And the per-row baseline that stood here for an evening: the day a
    # source was named is in `local.toml` now, one block per source.
    haskey(store, "baseline") && delete!(store, "baseline")
    save_fetched(store)
    yield()
    # The one directory nothing else prunes. Swept here rather than in the
    # browser because it is a walk of the whole folder and this run is already
    # the slow, non-interactive one - and because everything it drops is older
    # than anything the browser would have put on screen.
    swept = cache_clear(; older_than = CACHE_SWEEP[])
    yield()
    swept > 0 && @printf(report(), "  %-16s %d entries over %d days old\n",
                         "cache", swept, round(Int, CACHE_SWEEP[] / 86_400))
    # The summary, which is the line the browser's status row reads off the
    # child: with the warnings counted here, by the report, so the row can say
    # there were some without reading the text above it back.
    r = current_report()
    r.summary = string(length(items), " items, ", length(changes), " changes, ",
                       spent, " rate-limit points")
    @printf(report(), "  %s%s\n", r.summary,
            r.warnings == 0 ? "" :
            string(" \u00b7 ", r.warnings, r.warnings == 1 ? " warning" : " warnings"))
    0
end

"How Python's `%s` renders the values that appear in a change line."
pyrepr(v) = v === nothing ? "None" : v isa Bool ? (v ? "True" : "False") : string(v)
