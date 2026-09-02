# Refresh the work dashboard from GitHub.
#
# Deterministic half of the dashboard: fetches live facts over GraphQL, derives
# a bucket for every item from rules, expires snoozes, diffs against the
# previous snapshot and renders DASHBOARD.md.
#
# File ownership is strict, because it is what keeps your notes safe:
#   config.toml  state.toml   -- yours. Read here, NEVER written here.
#   facts.json                -- machine. Overwritten every run.
#   snooze.json               -- machine. Fingerprints for "snooze until it moves".
#   DASHBOARD.md              -- machine. Overwritten every run.
#
# Judgement calls this deliberately does not make (they belong to the model
# running the /dash skill, which writes them into state.toml): whether a red CI
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
    bucket in ("stale", "firehose", "mentioned") && return "background"
    bucket in ("issue", "reviewed", "blocked") && return "loose"
    "normal"
end

# --- bucketing -------------------------------------------------------------
# Every rule below is a fact GitHub already knows. Anything requiring judgement
# is left to the model via a state.toml override.

function derive_bucket(r, st, cfg, at::DateTime)
    truthy(get(st, "bucket", nothing)) && return (st["bucket"], "override")
    L = Set(get(r, "labels", String[]))
    r["lane"] == "firehose" && return ("firehose", "discovery")
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

"""Returns (is_snoozed, reason). Arms a snooze on first sight.

`maxdays` is the fallback cap for an `on-change` that carries none of its own:
without one it hides the item until the fingerprint differs, and a pull request
that everybody has quietly given up on is exactly the shape whose fingerprint
never differs. That is also the one worth being reminded about.
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
    cache = joinpath(ROOT, "bulk.json")
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
        write(cache, json_dumps(["fetched_at" => now_isoformat(at), "lanes" => lanes]))
    end
    write(cache, json_dumps(["fetched_at" => now_isoformat(at), "lanes" => lanes]))
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
    p = joinpath(ROOT, "state.toml")
    isfile(p) || return Dict{String,Any}()
    raw = TOML.parse(read(p, String))
    Dict{String,Any}(u => Dict{String,Any}(
        k => (v isa Union{Date,DateTime,Dates.Time} ? string(v) : v) for (k, v) in st)
        for (u, st) in raw if st isa AbstractDict)
end

function refresh(args::Vector{String} = String[], at::DateTime = utcnow())
    cfgtext = read(joinpath(ROOT, "config.toml"), String)
    cfg = TOML.parse(cfgtext)
    login = cfg["login"]
    state = load_state()
    factsp = joinpath(ROOT, "facts.json")
    prev_items = isfile(factsp) ? JSON3.read(read(factsp, String)).items : (;)
    # A default cap for on-change snoozes that carry none of their own.
    snooze_cap = get(get(cfg, "snooze", Dict{String,Any}()), "max_days", nothing)
    snzp = joinpath(ROOT, "snooze.json")
    snz = Dict{String,Any}()
    if isfile(snzp)
        for (k, v) in JSON3.read(read(snzp, String))
            snz[String(k)] = v
        end
    end

    items = OrderedDict{String,Any}()
    spent = 0
    for (lane, q) in ordered(cfg["lanes"], cfgtext, "lanes")
        nodes, c, _ = search(q)
        spent += c
        for n in nodes
            items[String(n.url)] = normalize(n, lane, login)
        end
        @printf(stderr, "  %-9s %3d items (%d pts)\n", lane, length(nodes), c)
    end

    unread = Events.unread(cfg, login, at)
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
    for (url, r) in items
        st = get(state, url, Dict{String,Any}())
        # GitHub computes mergeability lazily: the first read of a PR returns
        # UNKNOWN and only schedules the real computation. Treating that as fact
        # flaps the needs-stacking lane between refreshes and, worse, spuriously
        # wakes on-change snoozes. Carry the last known value forward until a
        # real one arrives - this read warms it for the next refresh.
        if get(r, "mergeable", nothing) == "UNKNOWN"
            carried = jget(jget(prev_items, Symbol(url)), :mergeable)
            r["mergeable"] = carried == "UNKNOWN" ? nothing : carried
        end
        r["bucket"], r["why"] = derive_bucket(r, st, cfg, at)
        r["track"] = resolve_track(st, r["bucket"])
        r["fp"] = fingerprint(r, r["track"])
        r["fp_full"] = fingerprint(r, "close")
        r["note"] = get(st, "note", nothing)
        r["deadline"] = get(st, "deadline", nothing)
        r["blocked_on"] = get(st, "blocked_on", String[])
        snoozed, sreason = snooze_active(url, st, r["fp"], snz, at, snooze_cap)
        r["snoozed"], r["snooze_why"] = snoozed, sreason
        # The backlog is everything you are not actively carrying: the stale pile,
        # the discovery feed, and anything you explicitly pushed to background.
        r["backlog"] = r["bucket"] in ("stale", "firehose", "mentioned") ||
                       r["track"] == "background"
        old = jget(prev_items, Symbol(url))
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
    for (k, old) in pairs(prev_items)
        url = String(k)
        if !haskey(items, url)
            push!(changes, (url, old, "closed or merged"))
            delete!(snz, url)
        end
    end

    # A bad value means "not snoozed", so the item is not in the snoozed section
    # and its reason is printed nowhere. Say it here instead of losing it.
    for (u, r) in items
        w = get(r, "snooze_why", nothing)
        w isa AbstractString && startswith(w, "bad snooze value") &&
            @printf(stderr, "  %-16s %s  (%s)\n", "snooze", w, u)
    end

    write(factsp, json_dumps(["fetched_at" => now_isoformat(at), "points" => spent,
                              "items" => items]; indent = 1, sortkeys = true))
    write(snzp, json_dumps(snz; indent = 1, sortkeys = true))
    write(joinpath(ROOT, "DASHBOARD.md"), render(items, changes, cfg, spent, at, unread))
    @printf(stderr, "  %d items, %d changes, %d rate-limit points\n",
            length(items), length(changes), spent)
    0
end

"How Python's `%s` renders the values that appear in a change line."
pyrepr(v) = v === nothing ? "None" : v isa Bool ? (v ? "True" : "False") : string(v)

# --- rendering -------------------------------------------------------------

const SECTIONS = [
    ("needs-reply",    "Needs a reply",     "You were mentioned and the last word is theirs."),
    ("needs-edits",    "Needs edits",       "Review feedback, red CI, or you're the blocker."),
    ("needs-stacking", "Needs stacking",    "Conflicts; rebase or restack with `gh stack`."),
    ("needs-review",   "Needs review",      "Waiting on you to review someone else."),
    ("needs-merge",    "Ready to merge",    "Approved and green."),
    ("needs-nudge",    "Needs a nudge",     "Yours, quiet, waiting on a reviewer."),
    ("waiting",        "Waiting on others", "Yours, in flight, nothing for you to do."),
    ("blocked",        "Blocked",           "Blocked upstream."),
    ("draft",          "Drafts",            "Yours, not yet proposed."),
    ("issue",          "Assigned issues",   ""),
    ("reviewed",       "Reviewed, waiting", "You reviewed; ball is with the author."),
]

shortrepo(r) = split(r["repo"], '/')[end]

function line(r, at::DateTime)
    tag = "$(shortrepo(r))#$(r["number"])"
    bits = String[]
    truthy(get(r, "ci", nothing)) && r["ci"] != "SUCCESS" && push!(bits, "CI $(lowercase(r["ci"]))")
    truthy(get(r, "unresolved", nothing)) && push!(bits, "$(r["unresolved"]) unresolved")
    get(r, "mergeable", nothing) == "CONFLICTING" && push!(bits, "conflicts")
    truthy(get(r, "milestone", nothing)) && push!(bits, r["milestone"])
    truthy(get(r, "deadline", nothing)) && push!(bits, "**due $(r["deadline"])**")
    truthy(get(r, "blocked_on", nothing)) && push!(bits, "blocked on " * join(r["blocked_on"], ", "))
    age = activity_age(r, at)
    age === nothing || push!(bits, "$(age)d")
    if truthy(get(r, "new", nothing))
        pushfirst!(bits, "NEW")
    elseif truthy(get(r, "moved", nothing))
        pushfirst!(bits, "moved")
    end
    get(r, "track", nothing) in ("close", "loose") && pushfirst!(bits, "track:$(r["track"])")
    star = get(r, "track", nothing) == "close" ? "* " : ""
    s = "- $star[$tag]($(r["url"])) $(r["title"])"
    isempty(bits) || (s *= "  \n  <sub>" * join(bits, " · ") * "</sub>")
    truthy(get(r, "note", nothing)) && (s *= "  \n  > $(r["note"])")
    s
end

function urgency(r, at::DateTime)
    d = truthy(get(r, "deadline", nothing)) ? String(r["deadline"]) :
        first(something(get(r, "milestone_due", nothing), ""), 10)
    (get(r, "track", nothing) == "close" ? 0 : 1,
     isempty(d) ? "9999-99-99" : d,
     something(activity_age(r, at), 0))
end

function render(items, changes, cfg, spent, at::DateTime, unread = ())
    vis = [r for r in values(items) if !r["snoozed"]]
    snoozed = [r for r in values(items) if r["snoozed"]]
    out = ["# Work dashboard", "",
           "_$(Dates.format(at, "yyyy-mm-dd HH:MM")) UTC · $(length(items)) items · $spent rate-limit points_",
           ""]

    # Deadlines first: anything with a date attached, soonest first.
    dated = sort([r for r in vis
                  if truthy(get(r, "deadline", nothing)) || truthy(get(r, "milestone_due", nothing))];
                 by = r -> urgency(r, at))
    if !isempty(dated)
        append!(out, ["## Deadlines", ""])
        for r in first(dated, 15)
            d = truthy(get(r, "deadline", nothing)) ? String(r["deadline"]) : first(r["milestone_due"], 10)
            over = d < string(Date(at)) ? " **OVERDUE**" : ""
            push!(out, "- `$d`$over [$(shortrepo(r))#$(r["number"])]($(r["url"])) $(r["title"])")
        end
        push!(out, "")
    end

    if !isempty(unread)
        # The inbox replacement. Items you are already carrying come first: an
        # unread comment on your own PR matters more than one on a thread you
        # have never touched.
        by_url = Dict(r["url"] => r for r in values(items))
        prio(e) = (haskey(by_url, e["url"]) && !by_url[e["url"]]["backlog"] ? 0 : 1, e["updated"])
        ranked = sort(collect(unread); by = prio)
        sort!(ranked; by = e -> (prio(e)[1],))
        append!(out, ["## Unread ($(length(unread)))",
                      "_`wl show <ref>` to read a thread, `wl read <ref>` when done, " *
                      "`wl read all` to zero the inbox._", ""])
        for e in first(ranked, 40)
            r = get(by_url, e["url"], nothing)
            bits = [e["comments"] != 0 ? "$(e["comments"]) comments" : "no comments"]
            r !== nothing && !r["backlog"] && push!(bits, "**$(r["bucket"])**")
            e["state"] == "open" || push!(bits, e["state"])
            age = days_since(e["updated"], at)
            push!(bits, truthy(age) ? "$(age)d" : "today")
            push!(out, "- [$(split(e["repo"], '/')[end])#$(e["number"])]($(e["url"])) $(e["title"])  \n  <sub>" *
                       join(bits, " · ") * "</sub>")
        end
        length(unread) > 40 && push!(out, "- _...and $(length(unread) - 40) more_")
        push!(out, "")
    end

    for (key, title, blurb) in SECTIONS
        rs = sort([r for r in vis if r["bucket"] == key && !r["backlog"]];
                  by = r -> urgency(r, at))
        isempty(rs) && continue
        push!(out, "## $title ($(length(rs)))")
        isempty(blurb) || push!(out, "_$(blurb)_")
        push!(out, "")
        append!(out, [line(r, at) for r in rs])
        push!(out, "")
    end

    stale = sort([r for r in vis if r["bucket"] == "stale"]; by = r -> something(activity_age(r, at), 0))
    if !isempty(stale)
        append!(out, ["## Stale — decide ($(length(stale)))",
                      "_Yours, gone quiet, and you have not claimed them in `state.toml`. " *
                      "Add a `note` or `deadline` to pull one back into an " *
                      "active lane; otherwise close it._", "",
                      "<details><summary>expand</summary>", ""])
        for r in stale
            push!(out, "- [$(shortrepo(r))#$(r["number"])]($(r["url"])) $(r["title"]) <sub>$(something(activity_age(r, at), 0))d</sub>")
        end
        append!(out, ["", "</details>", ""])
    end

    fire = [r for r in vis if r["bucket"] == "firehose"]
    if !isempty(fire) || any(r -> r["bucket"] == "mentioned", vis)
        # Deliberately a count, not a list. The background pile is reached only
        # through `wl next`; printing a thousand lines here would be exactly the
        # firehose-in-your-feed this is meant to avoid.
        append!(out, ["## Background pile", "",
                      "$(length(fire)) open PRs in $(cfg["firehose"]["repo"]), " *
                      "$(count(r -> r["bucket"] == "mentioned", vis)) threads you were mentioned in or commented " *
                      "on, plus $(count(r -> r["bucket"] == "stale", vis)) of your own gone quiet. None of it surfaces here. " *
                      "Pull a batch to triage with `wl next`.", ""])
    end

    if !isempty(snoozed)
        append!(out, ["## Snoozed ($(length(snoozed)))", "",
                      "<details><summary>expand</summary>", ""])
        for r in sort(snoozed; by = r -> r["url"])
            push!(out, "- [$(shortrepo(r))#$(r["number"])]($(r["url"])) $(r["title"]) <sub>$(something(get(r, "snooze_why", nothing), ""))</sub>")
        end
        append!(out, ["", "</details>", ""])
    end

    real = [c for c in changes if !truthy(pget(c[2], "backlog"))]
    if !isempty(real)
        append!(out, ["## Changed since last refresh ($(length(real)))", ""])
        for (url, r, what) in first(real, 40)
            push!(out, "- [$(split(something(pget(r, "repo"), "?"), '/')[end])#$(something(pget(r, "number"), "?"))]($url) — $what")
        end
        push!(out, "")
    end
    join(out, "\n") * "\n"
end
