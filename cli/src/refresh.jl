# Refresh the work dashboard from GitHub.
#
# Deterministic half of the dashboard: fetches live facts over GraphQL, derives
# a bucket for every item from rules, expires snoozes and diffs against the
# previous snapshot.
#
# File ownership is strict, because it is what keeps your notes safe - the
# table is in `Worklog.jl`, and this half of it is the load-bearing part:
# `config.toml` and `state.toml` are read here and *never* written here, while
# `facts.json` and `snooze.json` are overwritten every run.
#
# Judgement calls this deliberately does not make (they belong in `state.toml`,
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

"Flatten one GraphQL node into the record the rest of the script uses."
function normalize(n, lane::AbstractString, login::AbstractString)
    typename = jget(n, :__typename, "PullRequest")
    is_pr = typename == "PullRequest"
    author = jget(jget(n, :author), :login)
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
        "mine" => author == login,
    )
    lastc = jget(jget(n, :comments), :nodes, ())
    rec["last_comment_by"] = isempty(lastc) ? nothing : jget(jget(lastc[1], :author), :login)
    rec["last_comment_at"] = isempty(lastc) ? nothing : jget(lastc[1], :createdAt)
    rec["human_comment_at"] =
        endswith(something(rec["last_comment_by"], ""), "[bot]") ? nothing : rec["last_comment_at"]

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
        # Who pushed the button, and only ever asked of the closed lanes -
        # every other lane is is:open, where it is null by definition.
        rec["merged_by"] = jget(jget(n, :mergedBy), :login)
        rec["draft"] = n.isDraft
        rec["review_decision"] = jget(n, :reviewDecision)
        rec["mergeable"] = jget(n, :mergeable)
        rec["head_at"] = jget(commit, :committedDate)
        rec["ci"] = jget(roll, :state)
        rec["unresolved"] = light ? nothing :
                            count(t -> !t.isResolved && !t.isOutdated, threads)
        rec["review_count"] = length(reviews)
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
    end
    rec
end

# How closely you are tracking an item decides what counts as it having moved.
# A loosely-tracked PR should not wake you because CI flapped or someone
# relabelled it; a closely-tracked one should wake on anything at all.
const TRACK_KEYS = Dict(
    "close"      => ("head_at", "review_decision", "mergeable", "ci", "unresolved",
                     "review_count", "last_comment_at", "labels"),
    "normal"     => ("head_at", "review_decision", "ci", "unresolved",
                     "review_count", "last_comment_at"),
    "loose"      => ("review_decision", "review_count", "human_comment_at"),
    "background" => (),          # empty key set -> constant -> never wakes
)

"What counts as 'this item moved', at the given tracking level."
function fingerprint(rec, level::AbstractString = "close")
    ks = get(TRACK_KEYS, level, TRACK_KEYS["normal"])
    key = Any[k == "labels" ? sort(get(rec, "labels", String[])) : get(rec, k, nothing)
              for k in ks]
    bytes2hex(SHA.sha256(json_dumps(key)))[1:16]
end

"Explicit setting wins; otherwise the lane picks a sensible default."
function resolve_track(st, bucket)
    t = get(st, "track", nothing)
    t isa AbstractString && haskey(TRACK_KEYS, t) && return t
    bucket == "done" && return "loose"   # over; nothing about it should wake you
    bucket in ("stale", "firehose", "mentioned") && return "background"
    bucket in ("issue", "reviewed", "blocked") && return "loose"
    "normal"
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
function second_look(r, at::DateTime, days::Int, cap::Int = 20)
    get(r, "state", nothing) in ("MERGED", "CLOSED") && return ""
    truthy(get(r, "backlog", false)) && return ""
    hd, lc = ts(get(r, "head_at", nothing)), ts(get(r, "last_comment_at", nothing))
    ap = ts(get(r, "approved_at", nothing))
    events = [x for x in (hd, lc, ap) if x !== nothing]
    isempty(events) && return ""
    last_ = maximum(events)
    n = workdays_since(stamp(last_), at)
    # A window, not a floor. Below it nobody is late yet; above it the silence
    # is not news - a pull request nobody has touched since last spring is a
    # different problem, and a reminder that fires on forty of those every day
    # is one nobody reads. That is what `stale` is for, and what a search is for.
    (n < days || n > cap) && return ""
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
# is left to the model via a state.toml override.

"""Everything about an item that comes from `state.toml` rather than GitHub.

Its own function because a refresh is no longer the only place an item is built:
an import arrives in the middle of a session and has to be bucketed by the same
rule as everything else. A second copy of this is a bucket that drifts, and the
bucket is what decides where a row shows up at all.
"""
function apply_state!(r, st, cfg, at::DateTime)
    r["bucket"], r["why"] = derive_bucket(r, st, cfg, at)
    r["track"] = resolve_track(st, r["bucket"])
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

The four shapes a `snooze` value can take:

  * `on-change` (or `until-review`) - hide until the fingerprint differs
  * `on-change/30d` - the same, but give up after that long
  * `3d`, `2w`, `6mo` - hide for a while, counted from when it was set
  * `2026-09-15` - hide until a date, ignoring movement entirely

`nothing` for anything else, which is a value that was typed wrong.
"""
function parse_snooze(sv::AbstractString)
    s = strip(lowercase(String(sv)))
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

"""What `mergeable` should say when GitHub has answered `UNKNOWN`.

GitHub computes mergeability lazily: the first read of a pull request returns
`UNKNOWN` and only schedules the real computation. Treating that as fact flaps
the needs-stacking lane between refreshes and, worse, spuriously wakes
on-change snoozes - so the last known value is carried forward until a real one
arrives, and the read that got `UNKNOWN` has warmed it for the next refresh.

**Except once it is over.** A merged or closed pull request answers `UNKNOWN`
for good: there is no merge to be possible any more, so this is not a fact that
has gone temporarily unknown, it is a question with no answer. Carrying the last
value forward there pins whatever was true the day before the merge onto
something that has merged - which is how julia#62396 came to be merged and
"conflicting" at the same time.
"""
carried_mergeable(state, prev) =
    (state in ("MERGED", "CLOSED") || prev == "UNKNOWN") ? nothing : prev

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

"""Run every [bulk.queries] entry, cached on a slow cadence.

These are ~2000 items that move slowly and never surface on their own, so
per-refresh freshness buys nothing and costs minutes of wall clock.

GitHub's search API truncates at 1000 results and the Julia firehose is already
at ~993, so any query approaching the cap is re-run partitioned by creation year
and the slices unioned.
"""
function fetch_bulk(cfg, cfgtext, at::DateTime; force::Bool = false)
    cache = datapath("bulk.json")
    hours = get(cfg["bulk"], "refresh_hours", 6)
    if isfile(cache) && !force
        c = JSON3.read(read(cache, String))
        age_h = Dates.value(at - ts(c.fetched_at)) / 3_600_000
        if age_h < hours
            return (OrderedDict{String,Any}(String(k) => v for (k, v) in c.lanes), 0,
                    @sprintf("cached %.1fh old", age_h))
        end
    end

    # Start from whatever is cached so one flaky lane cannot discard the others.
    # These fetches take minutes; losing a completed lane to a later 502 is the
    # difference between a slow refresh and a wasted one.
    prev = OrderedDict{String,Any}()
    if isfile(cache)
        for (k, v) in JSON3.read(read(cache, String)).lanes
            prev[String(k)] = v
        end
    end
    lanes = copy(prev)
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
                    lane, length(get(prev, lane, ())), first(e.msg, 80))
            continue
        end
        # Persist after every lane, not at the end.
        write_atomic(cache, json_dumps(["fetched_at" => now_isoformat(at), "lanes" => lanes]))
    end
    write_atomic(cache, json_dumps(["fetched_at" => now_isoformat(at), "lanes" => lanes]))
    how = "fetched $(sum(length(v) for v in values(lanes); init=0))"
    isempty(failed) || (how *= ", $(length(failed)) lane(s) stale")
    (lanes, spent, how)
end

"""Read state.toml.

Dates written unquoted (`deadline = 2026-09-30`) come back as `Date`; everything
downstream compares and prints them as ISO strings, so flatten them here. The
Python raised `TypeError` out of `json.dumps` on the same input.
"""
function load_state()
    p = datapath("state.toml")
    isfile(p) || return Dict{String,Any}()
    raw = TOML.parse(read(p, String))
    Dict{String,Any}(u => Dict{String,Any}(
        k => (v isa Union{Date,DateTime,Dates.Time} ? string(v) : v) for (k, v) in st)
        for (u, st) in raw if st isa AbstractDict)
end

"""Drafts on the items that have just left the dashboard.

Everything still in the list reconciles itself by being opened: the metadata
says whether the pending review is still there, and asking costs nothing until
somebody looks. An item that has *gone* is the one case where that can never
happen - the lane is items, so a mark on a url that is no longer one of them
cannot be shown, cannot be navigated to, and would sit in `drafts.json` for
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
    factsp = datapath("facts.json")
    prev_items = isfile(factsp) ? JSON3.read(read(factsp, String)).items : (;)
    # A default cap for on-change snoozes that carry none of their own.
    snooze_cap = get(get(cfg, "snooze", Dict{String,Any}()), "max_days", nothing)
    second_days = Int(get(cfg["thresholds"], "second_look_days", 2))
    second_cap = Int(get(cfg["thresholds"], "second_look_max_days", 20))
    snzp = datapath("snooze.json")
    snz = Dict{String,Any}()
    if isfile(snzp)
        for (k, v) in JSON3.read(read(snzp, String))
            snz[String(k)] = v
        end
    end

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
    # cursors and writes what is unread into `inbox.json`, and every reader of
    # that asks for itself. Nothing in this run looks at the list any more.
    Events.unread(cfg, login, at)
    bulk, c, how = fetch_bulk(cfg, cfgtext, at; force = "--firehose" in args)
    spent += c
    for (lane, nodes) in bulk
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
        apply_state!(r, st, cfg, at)
        r["fp"] = fingerprint(r, r["track"])
        r["fp_full"] = fingerprint(r, "close")
        snoozed, sreason = snooze_active(url, st, r["fp"], snz, at, snooze_cap)
        r["snoozed"], r["snooze_why"] = snoozed, sreason
        # The backlog is everything you are not actively carrying: the stale pile,
        # the discovery feed, and anything you explicitly pushed to background.
        r["backlog"] = r["bucket"] in ("stale", "firehose", "mentioned") ||
                       r["track"] == "background"
        # After the backlog is known, since the pile is not a to-do list, and
        # after the snooze, since an item you have said "not now" about is not
        # one to be reminded of.
        r["second_look"] = r["snoozed"] ? "" :
                           second_look(r, at, second_days, second_cap)
        old = jget(prev_items, Symbol(url))
        # A snooze is "not now", and an item you have said that about should not
        # also be sitting in the unread lane asking to be read. So falling
        # asleep marks it read and waking marks it unread again; `snooze_edge`
        # is where the rule about which refreshes count is written down.
        if old !== nothing
            e = snooze_edge(jget(old, :snoozed) === true, snoozed, sreason)
            e === :slept && push!(slept, url)
            e === :woke && push!(woke, woke_row(r, at))
        end
        r["moved"] = old !== nothing && jget(old, :fp_full) != r["fp_full"]
        if old === nothing
            r["new"] = true
            push!(changes, (url, r, "new"))
        else
            r["new"] = false
            if jget(old, :fp) != r["fp"]
                d = String[]
                for (f, lab) in (("ci", "CI"), ("review_decision", "review"),
                                 ("mergeable", "mergeable"), ("unresolved", "unresolved"),
                                 ("head_at", "new push"), ("last_comment_at", "new comment"))
                    if jget(old, Symbol(f)) != get(r, f, nothing)
                        push!(d, f in ("head_at", "last_comment_at") ? lab :
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
    # that puts twenty items to sleep should not rewrite `read.json` twenty
    # times. `overwrite = false` leaves a poll's own richer row alone, which is
    # the same courtesy an import pays.
    #
    # After `unread()` has already answered, which costs nothing now that
    # nothing in this run reads the answer again: the browser asks for itself
    # when it opens, and that is where this is read.
    isempty(slept) || @printf(stderr, "  %-16s %4d marked read on falling asleep\n",
                              "snooze", Events.mark_read(slept, at))
    isempty(woke) || @printf(stderr, "  %-16s %4d marked unread on waking\n",
                             "snooze", Events.inbox_add!(woke; overwrite = false))

    # A bad value means "not snoozed", so the item is not in the snoozed section
    # and its reason is printed nowhere. Say it here instead of losing it.
    for (u, r) in items
        w = get(r, "snooze_why", nothing)
        w isa AbstractString && startswith(w, "bad snooze value") &&
            @printf(stderr, "  %-16s %s  (%s)\n", "snooze", w, u)
    end

    write_atomic(factsp, json_dumps(["fetched_at" => now_isoformat(at), "points" => spent,
                                     "items" => items]; indent = 1, sortkeys = true))
    write_atomic(snzp, json_dumps(snz; indent = 1, sortkeys = true))
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
