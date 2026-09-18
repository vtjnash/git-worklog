# Unread tracking, replacing per-event email notification.
#
# Email's real value here is one bit per thread: have you seen it. Everything
# else it carries - titles, bodies, who spoke - GitHub can answer live, so none
# of it is stored. The only persisted state is the read stamp in `local.toml`:
# per item, the timestamp you have seen up to. That is precisely the bit an
# inbox was providing and the one thing that cannot be re-derived from GitHub -
# and it is a fact about the whole corpus, which is why it lives there and not
# here. What this module owns is the poll: the cursors, and what moved.
#
# Finding what is unread costs one query per repo: `issues?since=` returns every
# item touched in the window, with its `updated_at` and comment count already in
# the payload. Comment bodies are fetched only when you ask to read one.
#
# This is the one half of the fetch that is a plain REST call, so it uses
# GitHub.jl rather than shelling to `gh`. It deliberately does NOT use
# `GitHub.issues`, which pages by following Link headers - see `api_paged`.
module Events

# cache.jl is included into the parent before this file.
import ..cache_get, ..cache_put, ..cache_drop
import ..gh_graphql

using Dates, Printf, JSON3, OrderedCollections
import GitHub

using ..Worklog: ROOT, datapath, stamp, ts, json_dumps, write_atomic
# The seen bit itself is the corpus's, not the poll's - see `marks.jl`.
using ..Worklog: load_read, mark_unread, nz, report, warning
import ..Worklog

struct ApiError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ApiError) = print(io, e.msg)

const _AUTH = Ref{Any}(nothing)

"Overridable so the source order can be tested without a real sandbox."
const TOKEN_FILE = Ref("/run/claudebox-github/token")

"""
    token() -> (token, source)

Find a GitHub token, in order of decreasing authority.

The sandbox host keeps `TOKEN_FILE` refreshed, so it beats the environment,
which can hold a stale copy of an expired token. `gh auth token` comes last but
matters most off the sandbox: there `gh` keeps its credential in its own config
or the system keyring and exports nothing, so `gh auth status` succeeds while
`GH_TOKEN` is unset - which looked like a broken tool rather than a missing
lookup.
"""
function token()
    f = TOKEN_FILE[]
    if isfile(f)
        t = strip(read(f, String))
        isempty(t) || return (String(t), f)
    end
    for v in ("GH_TOKEN", "GITHUB_TOKEN")
        t = strip(get(ENV, v, ""))
        isempty(t) || return (String(t), "\$$v")
    end
    t = try
        strip(read(`gh auth token`, String))
    catch
        ""
    end
    isempty(t) || return (String(t), "gh auth token")
    throw(ApiError("no GitHub token. Tried $f, \$GH_TOKEN, \$GITHUB_TOKEN and " *
                   "`gh auth token`. Run `gh auth login`, or set GH_TOKEN."))
end

function auth()
    _AUTH[] === nothing || return _AUTH[]
    tok, _ = token()
    _AUTH[] = GitHub.authenticate(tok)
end

"Overridable for the same reason `TOKEN_FILE` is. Empty means `data/notifications.token`."
const PAT_FILE = Ref("")
const _PAT = Ref{Any}(nothing)
patfile() = isempty(PAT_FILE[]) ? datapath("notifications.token") : PAT_FILE[]

"""Is this a GitHub App token - a user-to-server `ghu_` or an installation
`ghs_`? Those are the two `/notifications` refuses: 403 "not accessible by
integration", and the endpoint is missing from the App permissions list rather
than denied by it. `ghp_`, `gho_` and `github_pat_` are a person's."""
app_token(t::AbstractString) = startswith(t, "ghu_") || startswith(t, "ghs_")

"""
    pat() -> (auth, source), or nothing

The token the notifications source polls with, and where it came from, or
`nothing` when there is none - in which case that source is skipped and every
other one polls as before.

`token()` first: off the sandbox, `gh auth token` is the `gho_` token `gh auth
login` keeps, whose `repo` scope carries notifications access, and there is
nothing to set up. What `token()` must not be followed into is the sandbox
file, which holds a GitHub App user token that cannot read the endpoint - and
that is told by the token, not by the rung: `app_token`. When it is one, or
`token()` finds nothing, `data/notifications.token` is read instead - one
line, gitignored, a token that is *yours*: a classic PAT with the
`notifications` scope, or that same `gho_` token copied in. Not something to
put on a machine where somebody else can read the file; a sandbox is exactly
that, and there the source is simply skipped. Measured 2026-09-13 with the
`gho_` token.
"""
function pat()
    _PAT[] === nothing || return _PAT[]
    t, src = try
        token()
    catch e
        e isa ApiError || rethrow()
        ("", "")
    end
    if isempty(t) || app_token(t)
        f = patfile()
        isfile(f) || return nothing
        t, src = String(strip(read(f, String))), f
        isempty(t) && return nothing
    end
    # `OAuth2` outright rather than `authenticate`, which asks `/user` to check
    # the token: a bad one is reported by the poll, as `FAILED: 401`.
    _PAT[] = (GitHub.OAuth2(t), src)
end

"""
    server_now() -> DateTime

GitHub's now, off the `Date` header of a request that costs nothing. The
header is whole seconds, and taken against nothing local: this is the instant
as GitHub would write it, for the stamps that will be compared against ones
GitHub wrote. See `utcnow` for which those are.
"""
function server_now()
    r = GitHub.gh_get(GitHub.DEFAULT_API, "/rate_limit"; auth = auth())
    d = Worklog.http_date(GitHub.HTTP.header(r, "Date", nothing))
    d === nothing && throw(ApiError("no Date header on /rate_limit"))
    d
end

"""One request, one page. Always returns a vector, as the Python `_get` did.

`auth` is an argument so the one endpoint the sandbox token cannot reach can be
asked with the one that can - see `pat` - rather than through a second copy of
this.
"""
api_get(endpoint::AbstractString; params = Dict{String,Any}(), auth = auth()) =
    api_get_dated(endpoint; params = params, auth = auth)[1]

"""
    api_get_dated(endpoint; params, auth) -> (rows, started)

`api_get`, and a lower bound on GitHub's time when the request *began*:
`started`, a `DateTime`, or `nothing` if the response carried no `Date`.

The `Date` header is when the server generated the response - the request's
end, not its start - so the start is bounded from below by that less the
request's own length, which is a duration off the monotonic clock and so
needs no agreement between any two clocks, less one second for the header's
truncation. It is what a
windowed source's cursor is set from, see `sync!`: the instant before which
everything the page shows was already true. It used to be a `/rate_limit`
request made beforehand for its header alone, one per poll; this is the same
bound off the page itself, tighter by the request's own length.
"""
function api_get_dated(endpoint::AbstractString; params = Dict{String,Any}(), auth = auth())
    # The monotonic clock: a length of time, not a time of day, and the wall
    # clock is not one - NTP steps it, a resumed VM lands wherever the host
    # says - so measured on the clock that cannot run backwards.
    t0 = time_ns()
    r = try
        GitHub.gh_get(GitHub.DEFAULT_API, endpoint; auth = auth, params = params)
    catch e
        throw(ApiError(first(sprint(showerror, e), 200)))
    end
    elapsed = (time_ns() - t0) / 1e9
    v = GitHub.JSON.parse(GitHub.http_payload(r, String))
    d = Worklog.http_date(GitHub.HTTP.header(r, "Date", nothing))
    started = d === nothing ? nothing :
              d - Millisecond(round(Int, 1000 * elapsed)) - Second(1)
    (v isa AbstractVector ? v : Any[v], started)
end

"""Page explicitly rather than by following Link headers.

`GitHub.issues` (and `gh api --paginate`) walk `Link: rel="next"` over a list
that is being reordered underneath them. With the default descending
`sort=updated`, an item touched mid-walk jumps to page 1 and shifts a whole page
past the cursor, so entries are silently dropped: the same query returned 168
items on one attempt and 612 on the next. Ascending order is stable for a
`since` window - a concurrent update moves an item toward the end, which can
duplicate but never skip - and explicit paging plus a short-page stop makes the
walk deterministic. Dedupe by id to absorb the duplicates that ordering allows.

That is why this reaches for `gh_get_json` (a single request) instead of the
library's own paginating helpers: correctness beats using the convenience API.
"""
function api_paged(endpoint::AbstractString; params = Dict{String,Any}(),
                   per_page::Int = 100, max_pages::Int = 60, auth = auth(),
                   started = Ref{Any}(nothing))
    out, seen = Any[], Set{Any}()
    for page in 1:max_pages
        rows, st = api_get_dated(endpoint; auth = auth, params = merge(params, Dict{String,Any}(
            "per_page" => per_page, "page" => page)))
        # The first request's bound is the walk's: everything any page shows
        # was already true before it; see `api_get_dated`.
        page == 1 && (started[] = st)
        for r in rows
            k = something(get(r, "id", nothing), get(r, "url", nothing), page)
            if !(k in seen)
                push!(seen, k)
                push!(out, r)
            end
        end
        if isempty(rows) && page == 1
            # An empty first page has been observed spuriously, and the
            # short-page stop below then reports the whole repo as having no
            # activity: unread went 781 -> 170 with no error. A genuinely empty
            # result is stable, so confirm it before believing it. Reassign
            # `rows` rather than looping, so a successful retry's page is still
            # collected below.
            for _ in 1:2
                sleep(1)
                rows = api_get(endpoint; auth = auth, params = merge(params,
                    Dict{String,Any}("per_page" => per_page, "page" => 1)))
                isempty(rows) || break
            end
            isempty(rows) && break
        end
        length(rows) < per_page && break
    end
    out
end

"""
    walk_updated(page, since; per_page, max_pages) -> rows

Walk a window ascending by `updated_at`, cut by stamp and not by offset.

`page(floor, n)` is page `n` of the rows updated at or after `floor`, in
ascending order, `per_page` long. The walk asks page one from `since`, and
then page one again from the `updated_at` of the newest row it has, and so
on: the boundary is a stamp the walk holds, and a row that moves cannot move
it. What moves is exactly the case `api_paged`'s docstring covers only half
of: an item updated mid-walk goes to the end - which is fine when it was
behind the cursor, it is read there - but one *already read* on an earlier
page goes to the end too, and the unread rows behind it shift up one, so the
first row of the next page lands on a page already read. Its `updated_at` is
old, from before the poll began, and the next poll's `since` is past it: a
row lost for good. With the boundary a stamp, the mover is simply read again
past it, and nothing else shifts.

The ask is at-or-after, so a tie on the second is never stepped past; a row
read twice keeps its *later* reading, which is the mover's new stamp. A page
that makes no progress - every row on it in the floor's own second - is
drained by offset from that floor, page two on, until a row past the second
appears, and the walk goes on from there. That drain is the one place an
offset is still walked, and it has the offset's hole in miniature: a row of
that second updated *while its second is being paged* leaves it - and is read
again at the end, past the floor - but the rows after it shift up one, and
the row that crosses the page boundary is not read. It takes a hundred rows
touched in one second and one of them touched again within the second the
drain takes; the row lost is the one that did *not* move, and it is seen
again only if it moves again, or if its second is still inside the next
poll's overlap.

The spurious empty first page `api_paged` retries is retried here too.
"""
function walk_updated(page, since::AbstractString; per_page::Int = 100, max_pages::Int = 60,
                      started = Ref{Any}(nothing), cut = Ref(false))
    out, seen = Any[], Dict{Any,Int}()
    # `page` answers rows, or `(rows, started)`; the first request's bound is
    # the walk's.
    function ask(floor_, n)
        a = page(floor_, n)
        a isa Tuple || return a
        started[] === nothing && (started[] = a[2])
        a[1]
    end
    take!(rows) = begin
        last_ = ""
        for r in rows
            last_ = max(last_, String(get(r, "updated_at", "")))
            k = something(get(r, "id", nothing), get(r, "url", nothing), length(out) + 1)
            i = get(seen, k, nothing)
            if i === nothing
                push!(out, r)
                seen[k] = length(out)
            else
                out[i] = r          # read again, later: the newer reading
            end
        end
        last_
    end
    floor_ = String(since)
    pages = 0
    # A walk that runs out of pages has seen everything up to its floor and
    # nothing past it - in ascending order the floor is the newest stamp read
    # - so the bound it answers with is the floor and not the walk's start:
    # a cursor at the start would step past every unread row beyond the cut,
    # for good. Until 2026-09-14 the cursor was the newest row seen, which
    # resumed a cut walk by construction; this keeps that for the cut case.
    cut!() = begin
        cut[] = true
        f = ts(floor_)
        f === nothing || (started[] = started[] === nothing ? f : min(started[], f))
        out
    end
    while pages < max_pages
        rows = ask(floor_, 1)
        pages += 1
        if isempty(rows) && isempty(out)
            # An empty first page has been observed spuriously, and believed,
            # it reports the whole window as having nothing in it: unread went
            # 781 -> 170 with no error. A genuinely empty result is stable, so
            # confirm it before believing it.
            for _ in 1:2
                sleep(1)
                rows = ask(floor_, 1)
                isempty(rows) || break
            end
        end
        last_ = take!(rows)
        length(rows) < per_page && return out
        if last_ <= floor_
            # The whole page is the floor's own second: page on from it by
            # offset until a row past that second appears.
            n = 2
            while pages < max_pages
                rows = ask(floor_, n)
                pages += 1
                last_ = take!(rows)
                (length(rows) < per_page || last_ > floor_) && break
                n += 1
            end
            length(rows) < per_page && return out
            last_ > floor_ || return cut!()
        end
        floor_ = last_
    end
    cut!()
end

"""One page of one issue search: the items and the total. Returns
`(items, total_count)`.

Search is the only way to ask about a whole owner at once, and it needs
`is:issue` or `is:pull-request` - a query with neither is a 422. It is capped at
1000 results, which `total` is reported for so the caller can say when a window
is too wide rather than silently seeing part of it. Ascending by update, and
walked by `walk_updated`, for the reason given there.
"""
function search_page(q::AbstractString, page::Int; per_page::Int = 100)
    ds, st = api_get_dated("/search/issues"; params = Dict{String,Any}(
        "q" => String(q), "per_page" => per_page, "page" => page,
        "sort" => "updated", "order" => "asc"))
    d = first(ds)
    (get(d, "items", Any[]), get(d, "total_count", 0), st)
end

"""Every item `q` matches updated after `since`, walked by stamp; and the
total the first page reported."""
function search_issues(q::AbstractString, since::AbstractString; per_page::Int = 100,
                       started = Ref{Any}(nothing), cut = Ref(false))
    total = Ref(0)
    rows = walk_updated(since; per_page = per_page, max_pages = 10, started = started,
                        cut = cut) do floor_, n
        items, t, st = search_page(string(q, " updated:>=", floor_), n; per_page = per_page)
        n == 1 && floor_ == since && (total[] = t)
        (items, st)
    end
    (rows, total[])
end

"""Split the configured entries into the two kinds of source.

`(explicit, owners, bad)`: repos to poll by name, owners to sweep with a search,
and anything shaped like a pattern that is not `owner/*`, which is reported
rather than guessed at.
"""
function event_sources(repos)
    explicit = [String(r) for r in repos if !occursin('*', r)]
    owners = unique([String(first(split(r, '/'))) for r in repos if endswith(r, "/*")])
    bad = [String(r) for r in repos if occursin('*', r) && !endswith(r, "/*")]
    (explicit, owners, bad)
end

"""Every repo you watch on GitHub, as `owner/name`.

Not a source, and deliberately: this prints a list to paste rather than feeding
the events lane directly. A watch list is a record of what you were once
interested in, and a repo you stopped caring about would come back on every
refresh because you never got round to unwatching it. `config.toml` stays the
statement of what is tracked.
"""
subscriptions() = sort!([String(r["full_name"]) for r in api_paged("/user/subscriptions")])

"""The repositories watched on github.com, as a set, cached for a day: every
notifying event on one of these should reach the notifications source, which
is what makes a polled row that moved with no thread behind it a signal. An
answer that fails is an empty set - no signal, rather than a wrong one."""
function watched_repos()
    hit = cache_get("watched", 86_400.0)
    hit === nothing || return Set{String}(String(x) for x in hit[1])
    out = try
        subscriptions()
    catch e
        e isa ApiError || rethrow()
        return Set{String}()
    end
    cache_put("watched", out)
    Set{String}(out)
end

"""Repos of `owner` that are forks of somebody else's project.

Issue search has no fork qualifier, so telling them apart takes a listing of the
owner's repos - one request, cached for a day, since repos are created about
that often. It is not a saving either way: a glob is two searches whatever the
repo count. It is a noise control, and `vtjnash/*` is two hundred repos of which
171 are forks, where an issue somebody filed on a fork of their own project is
not work of yours.

**Unknown is not a fork.** A listing that fails, a repo private to the owner, a
repo created since the entry was cached - all of them keep their items. This
only ever hides things, and a noise control that guesses wrong hides work.
"""
function owner_forks(owner::AbstractString)
    key = string("forks:", owner)
    hit = cache_get(key, 86_400.0)
    hit === nothing || return Set{String}(String(x) for x in hit[1])
    out = String[]
    try
        for r in api_paged("/users/$owner/repos";
                           params = Dict{String,Any}("type" => "owner"))
            get(r, "fork", false) === true && push!(out, String(r["full_name"]))
        end
    catch e
        e isa ApiError || rethrow()
        return Set{String}()      # not cached: unknown now is not unknown forever
    end
    cache_put(key, out)
    Set{String}(out)
end

"`owner/name` out of a search result, which names the repo only by its API url."
function item_repo(r)
    u = String(get(r, "repository_url", ""))
    p = split(u, "/repos/")
    length(p) < 2 ? "" : String(p[end])
end

"""Whether a glob keeps the owner's forks. It does unless told otherwise.

Keeping them is the free direction. The sweep is the same one REST search either
way and spends no GraphQL points at all - those go on the refresh lanes in
`gh.jl` - while *skipping* them is what adds a request, one repo listing per
owner per day to tell which repo is which. So the noise control is the opt-in
side, and a config that says nothing pays nothing.
"""
keep_forks(cfge) = get(cfge, "include_forks", true) !== false

"""Drop the search results that came from a fork.

Off the item and not off the source, the same way the repo is: a glob covers
many repos and only the row knows which one it came from.
"""
drop_forks(rows, forks::Set{String}) =
    isempty(forks) ? rows : [r for r in rows if !(item_repo(r) in forks)]

"""The accumulated inbox: `cursors`, `polled` and `items`.

One part of `fetched.json`, because that is what it is: `cursors` is how far
each source has been polled, `polled` is when it was last asked, and `items` is
everything the poll has seen. All of it comes back from GitHub on the next
`wl refresh` - the cursors reset to `backfill_days` and the rows arrive again -
which is the whole test for which half of `data/` a thing belongs in.
"""
function load_inbox()
    d = Dict{String,Any}("cursors" => Dict{String,String}(), "polled" => Dict{String,String}(),
                         "failed" => Dict{String,String}(),
                         "items" => Dict{String,Any}())
    raw = Worklog.fetched("inbox")
    raw === nothing && return d
    try
        for k in ("cursors", "polled", "failed")
            for (kk, vv) in get(raw, Symbol(k), (;))
                d[k][String(kk)] = String(vv)
            end
        end
        for (kk, vv) in get(raw, :items, (;))
            d["items"][String(kk)] = OrderedDict{String,Any}(String(a) => b
                                                             for (a, b) in vv)
        end
        # What the poll is waiting on from the notifications, and since when
        # the ask has been wide; see `expect!`.
        for (kk, vv) in get(raw, :expect, (;))
            get!(d, "expect", Dict{String,Any}())[String(kk)] =
                Dict{String,Any}(String(a) => b for (a, b) in vv)
        end
        w = get(raw, :wide, nothing)
        w === nothing || (d["wide"] = String(w))
    catch
        # A damaged inbox is an empty one: the cursors reset to now, which loses
        # a poll's worth of history rather than every future poll.
    end
    d
end

"""Put it back, and only it.

A fresh read of the file first, because a poll is several HTTP requests long and
`R` runs a refresh in a subprocess while the browser is open: carrying the
`items` this process read a minute ago back over the ones that landed in the
meantime is exactly the race that is worth not having.
"""
save_inbox(d) = Worklog.put_fetched!("inbox", d)

"""The inbox row for one issue or pull request, as the REST list endpoints
return it - `/repos/o/r/issues?since=`, a search hit, or one `GET
/repos/o/r/issues/N`. Off the item, not off the source: a glob covers many
repos and only the item knows which one it came from.
"""
function issue_row(r, login)
    url = String(r["html_url"])
    who = get(something(get(r, "user", nothing), Dict{String,Any}()), "login", nothing)
    OrderedDict{String,Any}(
        "url" => url, "repo" => item_repo(r), "number" => r["number"],
        "title" => r["title"],
        "is_pr" => haskey(r, "pull_request"),
        "state" => r["state"],
        "author" => who,
        "updated" => r["updated_at"],
        "comments" => get(r, "comments", 0),
        "labels" => [l["name"] for l in get(r, "labels", ())],
        "mine" => who == login)
end

"""What a notification thread's `reason` says, in words: `why` as `wl unread`
prints it. The reason is the *latest* one GitHub has for the thread - it
evolves, `author` becoming `mention` - and it maps onto the item, not onto
an event: a thread is one row per subject, one reason, one `updated_at`, no
actor and no history. Not on the metadata pane, whose `why` row is what
moved since you read; this is a standing fact about the item.

`author` and `comment` say nothing: "something of yours moved" and "a thread
you commented on moved" said only that it moved."""
const THREAD_WHY = Dict{String,String}(
    "mention" => "you were mentioned",
    "team_mention" => "a team you are on was mentioned",
    "review_requested" => "your review was asked for",
    "assign" => "assigned to you",
    "author" => "",
    "comment" => "",
    "state_change" => "you changed its state",
    "subscribed" => "you watch the repository",
    "manual" => "you subscribed to the thread")

"""
    thread_subject(t) -> (path, url, repo, number, is_pr), or nothing

Where a notification thread points. `subject.url` is an API url -
`/repos/o/r/issues/N` or `/repos/o/r/pulls/N` - and `nothing` is every
subject this program cannot open: a Discussion, a Release, a Commit, a
CheckSuite, a RepositoryVulnerabilityAlert. `path` is the issue endpoint for
both kinds, which is the shape `issue_row` reads and the one the repo polls
already return.
"""
function thread_subject(t)
    s = get(t, "subject", nothing)
    s === nothing && return nothing
    kind = String(get(s, "type", ""))
    kind in ("Issue", "PullRequest") || return nothing
    m = match(r"^https://api\.github\.com/repos/([^/]+/[^/]+)/(?:issues|pulls)/(\d+)$",
              String(something(get(s, "url", nothing), "")))
    m === nothing && return nothing
    repo, n = String(m[1]), parse(Int, m[2])
    is_pr = kind == "PullRequest"
    (path = "/repos/$repo/issues/$n",
     url = "https://github.com/$repo/$(is_pr ? "pull" : "issues")/$n",
     repo = repo, number = n, is_pr = is_pr)
end

"""
    thread_row(t, login; fetch) -> row, or nothing

The inbox row for a notification thread. A thread carries less than a poll's
row does - no state, no author, no labels, no comment count - so it is filled
in with one `GET` of its subject, through `fetch`: that is what makes a closed
thing that stirred a `done` row rather than one that reads as open, and at a
few dozen threads a day on a 5000-an-hour budget it is nothing. Every thread,
not only one whose url is new to the inbox - it was the latter until
2026-09-14, and a thread merged over a poll's row without the fetch carried
its delivery time as `updated` over the poll's event time, the two clocks
this docstring's last paragraph is about.

What the thread contributes is `updated`, `lane`, `reason` and `why`. `unread`
and `last_read_at` are never read: the cursor is ours and the read stamp is
ours, and adopting GitHub's would undo the property the whole lane exists for.

**`updated` is the subject's clock once the subject has been fetched**, and
the thread's only until then. A thread's `updated_at` is when GitHub
*delivered* it, 2 to 46 seconds after the event; the repo poll writes the
subject's `updated_at`, the event itself. Two clocks for one event on one url
is a row read between them coming back unread - the poll's row read at R, the
thread landing at R + 20 with a later time - so the fetched row takes the
subject's time, which is what the poll would have written. The source's cursor
is untouched by this: it is read off the raw thread, in `sync!`.

A `fetch` that fails leaves the thin row - the thread is still shown, only
with less on it - and `fetch = nothing` asks for the thin row outright.
"""
function thread_row(t, login; fetch = path -> api_get(path; auth = pat()[1]))
    sub = thread_subject(t)
    sub === nothing && return nothing
    reason = String(get(t, "reason", ""))
    row = OrderedDict{String,Any}(
        "url" => sub.url, "repo" => sub.repo, "number" => sub.number,
        "title" => String(get(t["subject"], "title", "")),
        "is_pr" => sub.is_pr,
        "updated" => String(t["updated_at"]),
        # The thread's own stamp, kept apart from `updated` - which becomes
        # the subject's below - because it is the *delivery* time, and the
        # poll's witness is measured against it; see `expect!`.
        "notified" => String(t["updated_at"]),
        "lane" => "notifications", "reason" => reason,
        "why" => get(THREAD_WHY, reason, reason))
    fetch === nothing && return row
    issue = try
        first(fetch(sub.path))
    catch e
        e isa ApiError || rethrow()
        nothing
    end
    issue === nothing && return row
    full = merge!(issue_row(issue, login), row)
    u = get(issue, "updated_at", nothing)
    isempty(something(u, "")) || (full["updated"] = String(u))
    full
end

"""Which notification `reason`s name *you* - as against `subscribed`, which is
the repository being watched. Shared with the refresh, whose `involved` is
this: what is brought into the corpus with its bundle on first sight."""
involved_reason(reason) = !(reason in (nothing, "", "subscribed"))

"""How far behind its cursor each kind of source is asked from; see `sync!`.

Five minutes for REST since 2026-09-14, from one: the cursor became the
walk's own start, so this is the *whole* of the margin against a write that
was committed before the walk and visible on the replica after it - where
the cursor at the newest row seen used to sit however far before the poll
that row happened to be, minutes or hours, and the minute rode on top. What
a wider window costs is rows read twice: nothing for a repo poll, and one
subject fetch per thread inside it for the notifications source, which at a
few dozen threads a day is one in ten polls."""
const OVERLAP_REST = Second(5 * 60)
const OVERLAP_SEARCH = Second(15 * 60)

"""
    sources(cfg, login; verbose) -> [(; label, fetch, overlap, row), ...]

Every source the inbox is polled from, in the order they are asked. `fetch`
takes a `since` stamp and returns `(rows, started)` - the raw rows and a lower
bound on GitHub's time when the first request began, see `api_get_dated` -
or bare rows, for which the bound is asked of the clock; `row` takes one raw
row and whether this is the source's first sight (the backfill), and returns
the entry to write or `nothing` to skip it.

Three kinds. A repo named in `[events] repos` is one REST list with `since=`,
exact. An `owner/*` entry is every repo that owner has, asked as one search
per kind rather than as one poll per repo: `vtjnash/*` is two hundred repos,
and two hundred requests a poll is not a thing to do for a handful of
comments - the cost is fidelity, since search truncates at 1000, so a repo
that has to be seen exactly is still listed by name, and both may be listed at
once. And `/notifications`, which is what the other two emulate, and is only
polled when `pat` finds a token for it: it is the one source that reaches a
closed thread outside every polled repo - an @-mention on a years-old issue,
a repository you watch on github.com and never listed here, a thread you
subscribed to by hand. Measured 2026-09-13: of 32 issue-or-pull-request
threads in one week outside the polled repos, 20 were returned by no search
lane at all.

It goes **first**, and a row is merged over what is there rather than written
over it, so the repo poll's richer row for the same url - state, author,
labels, comments - lands on top of the thread's `lane`, `reason` and `why`
rather than in place of them; see `sync!`.
"""
function sources(cfg, login; verbose::Bool = true)
    cfge = get(cfg, "events", Dict{String,Any}())
    repos = get(cfge, "repos", String[])
    explicit, owners, bad = event_sources(repos)
    verbose && !isempty(bad) &&
        @printf(warning(), "    ignoring %s: only `owner/*` is a pattern\n", join(bad, ", "))
    srcs = NamedTuple{(:label, :fetch, :overlap, :row),Tuple{String,Any,Second,Any}}[]
    p = pat()
    if p !== nothing
        p = p[1]
        # `all=true`, because GitHub's read state is not this program's: a
        # thread read on github.com and then moved again is still news here.
        # `since` there is compared against when the thread last *notified*,
        # not against `updated_at` - a label edit moves the latter and fires
        # nothing - so a thread comes back exactly when there was something to
        # be told, and always with `updated_at` past the ask, which is what
        # the cursor needs. Newest first and capped at 50 a page, both
        # unlike the repo polls: a page is one point, a poll is one page, and
        # the walk past it is only ever taken on a cold start or after a gap.
        # Newest first is the order `api_paged` warns about, and the warning
        # is about a row leaving from ahead of the cursor between two pages,
        # which shifts the rows behind it up one and drops the first row of
        # the next page onto the page already read. Nothing leaves this list:
        # `all=true` keeps a thread read on github.com, and a thread that
        # arrives mid-walk shifts the rows behind it *down*, so a page
        # boundary can only repeat a row, and the ids absorb that. The one
        # row that does move is a thread that re-notifies mid-walk and jumps
        # to the top - and its new `updated_at` is past the cursor this walk
        # sets, so it is the next poll's, by the same rule as everything else.
        #
        # On the source's first sight - the backfill, hundreds of threads -
        # only a thread that names you fetches its subject; a watched
        # repository's traffic stays a thin row, as a poll's own would be,
        # and is filled in when it next moves or is looked at. Steady state
        # fetches every subject: a few dozen a day.
        push!(srcs, (label = "notifications",
                     fetch = (since, ctx) -> begin
            st = Ref{Any}(nothing)
            # **Wide**, while a notification is known to be late - `sync!`
            # asks a day behind the cursor rather than five minutes, in case
            # the one that is late arrives stamped with the event's time
            # rather than its own, the case a normal ask would never see -
            # threads the inbox already has with that stamp are dropped
            # here, before their subject would be fetched again.
            wide = ctx.wide
            params = Dict{String,Any}("all" => "true", "since" => since)
            rows = api_paged("/notifications"; auth = p, per_page = 50, started = st,
                             params = params, max_pages = 60)
            if wide
                known(t) = (s = thread_subject(t); s !== nothing &&
                    String(nz(get(get(ctx.items, s.url, Dict{String,Any}()), "notified", nothing), "")) >= String(t["updated_at"]))
                rows = [t for t in rows if !known(t)]
            end
            # Sixty pages is three thousand threads, which a backfill on a
            # busy account can exceed - and newest first, a walk cut there
            # would lose the *oldest* of the window, with no floor to resume
            # from. So past sixty pages the walk goes on by `before=`, the
            # oldest stamp seen plus a second so a tie is not stepped past,
            # the repeats dropped by id: a boundary that is a stamp, which an
            # arrival cannot shift.
            if length(rows) >= 60 * 50
                seen = Set(String(r["id"]) for r in rows)
                oldest = minimum(String(r["updated_at"]) for r in rows)
                strict = false
                for _ in 1:400
                    b = strict ? oldest : stamp(ts(oldest) + Second(1))
                    more, _ = api_get_dated("/notifications"; auth = p,
                        params = merge(params, Dict{String,Any}("per_page" => 50, "before" => b)))
                    new = [r for r in more if !(String(r["id"]) in seen)]
                    for r in new
                        push!(seen, String(r["id"]))
                        push!(rows, r)
                    end
                    length(more) < 50 && break
                    o = minimum(String(r["updated_at"]) for r in more)
                    strict = o >= oldest && isempty(new)    # a page inside one second
                    oldest = min(oldest, o)
                end
            end
            (rows, st[])
        end,
                     overlap = OVERLAP_REST,
                     row = (t, first) -> thread_row(t, login;
                         fetch = first && !involved_reason(get(t, "reason", nothing)) ?
                                 nothing : path -> api_get(path; auth = p))))
    elseif verbose
        @printf(warning(), "    %-24s skipped: the token is a GitHub App's, and there is no %s\n",
                "notifications", patfile())
    end
    for repo in explicit
        push!(srcs, (label = repo,
                     fetch = (since, _) -> begin
            st = Ref{Any}(nothing)
            rows = walk_updated(since; started = st) do floor_, n
                api_get_dated("/repos/$repo/issues"; params = Dict{String,Any}(
                    "since" => floor_, "state" => "all", "sort" => "updated",
                    "direction" => "asc", "per_page" => 100, "page" => n))
            end
            (rows, st[])
        end,
                     overlap = OVERLAP_REST,
                     row = (r, _) -> issue_row(r, login)))
    end
    # Looked up inside the closure, so the listing a filter needs is paid only
    # by a source that actually polls.
    keep = keep_forks(cfge)
    for owner in owners, kind in ("is:issue", "is:pull-request")
        push!(srcs, (label = string(owner, "/* ", kind),
                     fetch = (since, _) -> begin
            st, cut = Ref{Any}(nothing), Ref(false)
            its, total = search_issues("user:$owner $kind", since; started = st, cut = cut)
            # Ten pages a poll. A walk cut short answers with its floor, so
            # the rest is the next poll's rather than lost - which is what
            # "truncated at 1000" used to mean, before the walk went by stamp.
            cut[] && @printf(report(), "    %-24s cut at %d of %d; the rest next poll\n",
                             string(owner, "/*"), length(its), total)
            keep && return (its, st[])
            kept = drop_forks(its, owner_forks(owner))
            length(kept) == length(its) ||
                @printf(report(), "    %-24s %d on forks skipped\n",
                        string(owner, "/*"), length(its) - length(kept))
            (kept, st[])
        end,
                     overlap = OVERLAP_SEARCH,
                     row = (r, _) -> issue_row(r, login)))
    end
    srcs
end

"""
    sync!(srcs, at; ttl, backfill, now) -> (items, new)

Poll each source that is due and fold what it returned into the inbox; the
unread items, and how many rows arrived. `now` is asked only for a source
seen for the first time, whose backfill has to start somewhere.

**The cursor is GitHub's time just before the source's first request** -
`started`, off that request's own `Date` header less its length, see
`api_get_dated` - and not the newest row the source returned, which it was
until 2026-09-14. It is compared on the server against `updated_at`, so it
has to be GitHub's time and not this machine's: a local clock running ahead
would have the next poll skip whatever landed in the gap, and Windows clocks
have been minutes out. The start of the walk is the one instant that is safe
**whatever order the pages come in**: `since=` makes each page the whole
window as of that request, not the walk as a whole, so an item updated after
its page was read is either read again later - only if the walk is ascending
by `updated`, which moves it to the end - or not read again at all, and the
newest row seen can then be past it. Everything updated after the walk began
is, by definition, either unseen or seen with a stale stamp, and a cursor at
that instant asks for all of it next time. What that costs is the walk's own
late rows read twice, which are free: the inbox is keyed by url. Never
backwards, so a source whose cursor is already past this poll keeps it. A
source that answers without a bound - a test's, or a response with no `Date`
- gets the clock's now, asked then.

**And the ask is from behind the cursor**, by an overlap, because GitHub
promises nothing about a response being a snapshot as of its newest row.
Search is eventually consistent by its own account - an item updated at T can
be missing from `updated:>` for minutes and then appear - and a REST list
comes off a replica, which can be a beat behind, with `updated_at` set by
whichever server took the write. So a cursor at the start of the poll would
step past a change that was made before it and indexed after. Asking from
`cursor - overlap` catches that, and what it costs is rows fetched twice,
which are free: the inbox is keyed by url, and a row already read is dropped
again on arrival. Fifteen minutes for search, five for REST - the second
widened from one when the cursor became the walk's start, since the overlap
is then the whole of the margin - and both past any lag either has shown,
which is an observation and not a promise: GitHub documents no bound.

The one instant that is not an event is the first sight of a source - inbox
zero, so switching this on is not a month of history to dismiss - and that is
GitHub's now off a `Date` header. `polled` is the other clock: when *this
machine* last asked, against the ttl, local and compared only with itself.

A row is **merged** over the entry already at its url, not written in its
place. Two sources can see one url - the notifications source and the poll of
the repo it is in - and each knows something the other does not: the thread
its `reason`, the poll the state and the author. Merging keeps both whichever
came second; overwriting kept whichever came last.
"""
function sync!(srcs, at::DateTime; ttl = Millisecond(120_000), backfill = Day(0),
               now = server_now, watched = watched_repos, login = Worklog.login())
    inbox = load_inbox()
    polled, items = inbox["polled"], inbox["items"]
    # The cursors are `local.toml`'s - `source_cursors`, how far each source
    # has been read, which is a fact about what was done and not one GitHub
    # can answer - with the inbox's own copy under them for a file from
    # before they moved there. What this poll advances is written back in
    # one go at the end.
    cursors = merge!(Dict{String,String}(String(k) => String(v) for (k, v) in inbox["cursors"]),
                     Worklog.source_cursors())
    advanced = Dict{String,String}()
    got = 0
    server = nothing
    failed = get!(inbox, "failed", Dict{String,String}())
    watching = nothing                   # asked once, only if a poll runs
    # The poll can witness for the notifications only where the source runs:
    # on a machine whose token cannot read them there is nothing to expect,
    # and an expectation left from elsewhere is dropped rather than declared
    # late here.
    witness = any(s.label == "notifications" for s in srcs)
    witness || (delete!(inbox, "expect"); delete!(inbox, "wide"))
    due(label) = (last = get(polled, label, nothing);
                  t = last === nothing ? nothing : ts(last);
                  t === nothing || at - t >= ttl)
    for (label, fetch, overlap, torow) in srcs
        due(label) || continue
        first = !haskey(cursors, label)
        if first
            server === nothing && (server = now())
            cursors[label] = stamp(server - backfill)
            # The one source that is not a repository names itself here,
            # where its cursor starts: a thread with no stamp is read up to
            # this day by construction, and the backfill, if any, is unread.
            # The repositories are named when their lists are imported.
            label == "notifications" && Worklog.name_source!(label, cursors[label])
        end
        watching === nothing && (watching = watched())
        cur = cursors[label]
        answer = try
            wide = label == "notifications" && haskey(inbox, "wide")
            ctx = (items = items, wide = wide)
            s_ = stamp(ts(cur) - (wide ? Day(1) : overlap))
            applicable(fetch, s_, ctx) ? fetch(s_, ctx) : fetch(s_)   # a test's takes one
        catch e
            e isa ApiError || rethrow()
            @printf(warning(), "    %-24s FAILED: %s\n", label, e.msg)
            # Written down - when, then why - so a reader of the file can tell
            # a source that is answering from one that has a token and
            # nothing else, and so the browser's footer can say it
            # (`failing`): the poll before its first frame reports to nobody,
            # and this is the one line of it the reader has to act on.
            # Cleared by the next answer.
            failed[label] = string(stamp(at), " ", e.msg)
            continue
        end
        delete!(failed, label)
        rows, started = answer isa Tuple ? answer : (answer, nothing)
        started === nothing && (started = now())
        skipped = 0
        for r in rows
            row = torow(r, first)
            if row === nothing
                skipped += 1
                continue
            end
            url = String(row["url"])
            old = get(items, url, nothing)
            witness && label != "notifications" &&
                expect!(inbox, url, old, row, at, watching, login)
            items[url] = old === nothing ? row : merge!(old, row)
            got += 1
        end
        skipped == 0 || @printf(report(), "    %-24s %d not an issue or pull request, skipped\n",
                                label, skipped)
        cursors[label] = advanced[label] = max(String(cur), stamp(started))
        polled[label] = stamp(at)
    end

    witness && settle_expectations!(inbox, items, at, login)
    # Nothing leaves here. A row is dropped by the refresh once the corpus
    # has asked about it and it is read - see `refresh` - and not on
    # `updated <= read`, which it was until 2026-09-16: the marks stamp the
    # last movement at the row's tracking level, and a push, a label or your
    # own comment moves `updated` past that, so a row could stay in here
    # with nothing anybody could write to let it go.
    inbox["cursors"] = cursors           # the copy, for a reader of the file
    save_inbox(inbox)
    Worklog.set_source_cursors!(advanced)
    (items, got)
end

"""
    failing() -> [(label, since, why)]

The sources whose last poll failed, off the inbox's `failed` table, by label:
when it was last tried and what GitHub said. A source that answers is not
here; a source that is skipped for want of a token was never asked and is
not here either. `why` is `""` for an entry from before the reason was kept.
"""
function failing()
    out = NamedTuple{(:label, :since, :why),Tuple{String,String,String}}[]
    for (label, v) in load_inbox()["failed"]
        parts = split(String(v), ' '; limit = 2)
        push!(out, (label = String(label), since = String(parts[1]),
                    why = length(parts) > 1 ? String(strip(parts[2])) : ""))
    end
    sort!(out; by = x -> x.label)
end

# --- the poll as a witness for the notifications ----------------------------
#
# GitHub's notifications have been seen to lag by an hour and, rarely, twelve.
# Whether a late one is stamped with its delivery time or the event's is not
# known, and it matters: stamped at delivery it is past the cursor and the
# next poll returns it; stamped at the event it is behind `cursor - overlap`
# and nothing here would ever ask for it. Nothing about a normal poll can
# tell, since the dangerous case leaves no trace - but for a repository that
# is both polled and watched on github.com, every notifying event has two
# witnesses, and the poll's is not late. So: a polled row that moved in a
# way that notifies - a comment by somebody else, a state change, a new item
# by somebody else - in a watched repository is **expected** to have a thread
# behind it within `EXPECT_GRACE`. One that has not is the lag, observed:
# said on stderr, and the notifications source goes **wide** - a day behind
# its cursor every poll - until the expected thread arrives or `wl refresh
# --caught-up` says to stop waiting. And when it arrives, its stamp against
# the event says which way GitHub stamps a late one, the first time it
# happens.
#
# What does not count: a label or a push, which move `updated_at` and notify
# nobody and which the issues list cannot tell from a comment - so the
# evidence is the comment count rising, the state changing, or the row being
# new - and your own comment, which notifies nobody either and which the list
# cannot tell from anybody else's, so an expectation that is unmet after the
# grace is checked once for whose the last comment was before it is called a
# lag.

"How long a notification may trail the poll's witness before it is late."
const EXPECT_GRACE = Minute(15)

"""Record that `url` moved in a way that should notify, unless a thread with a
stamp at or past the movement is already here. `old` is the inbox row the
poll's `row` replaces, or `nothing`."""
function expect!(inbox, url, old, row, at::DateTime, watched::Set{String}, login::AbstractString)
    String(nz(get(row, "repo", nothing), "")) in watched || return
    ev = String(nz(get(row, "updated", nothing), ""))
    isempty(ev) && return
    evidence = old === nothing ? get(row, "author", nothing) != login :
               (get(row, "comments", 0) > get(old, "comments", 0) ||
                get(row, "state", nothing) != get(old, "state", nothing))
    evidence || return
    notified = old === nothing ? "" : String(nz(get(old, "notified", nothing), ""))
    notified >= ev && return
    exp = get!(inbox, "expect", Dict{String,Any}())
    haskey(exp, url) && String(exp[url]["event"]) >= ev && return
    exp[url] = Dict{String,Any}("event" => ev, "seen" => stamp(at))
    nothing
end

"""Go over what is expected: satisfied by a thread that arrived, dropped when
the last comment turns out to be yours, and otherwise - past the grace - the
lag, said, with the wide ask switched on until it is met."""
function settle_expectations!(inbox, items, at::DateTime, login::AbstractString)
    exp = get(inbox, "expect", nothing)
    (exp === nothing || isempty(exp)) && (haskey(inbox, "wide") || return; )
    exp === nothing && (exp = Dict{String,Any}())
    late = 0
    for (url, e) in collect(exp)
        ev, seen = String(e["event"]), ts(String(e["seen"]))
        row = get(items, url, nothing)
        notified = row === nothing ? "" : String(nz(get(row, "notified", nothing), ""))
        if notified >= ev
            # Arrived. How long after the event, and stamped with which time:
            # a stamp within a minute of the event is the event's own, and
            # the answer to the question at the head of this section.
            n, v = ts(notified), ts(ev)
            if n !== nothing && v !== nothing && haskey(inbox, "wide")
                lag = Dates.value(at - v) ÷ 60_000
                own = Dates.value(n - v) ÷ 60_000
                @printf(report(), "    %-24s %s: the notification arrived %d min after the event, stamped %s\n",
                        "notifications", url, lag,
                        own < 1 ? "with the EVENT's time - a late one is behind the cursor" :
                                  "at delivery ($own min after)")
            end
            delete!(exp, url)
            continue
        end
        seen === nothing && (delete!(exp, url); continue)
        at - seen < EXPECT_GRACE && continue
        # Unmet past the grace. Your own comment notifies nobody and the
        # list could not tell; one look at the last comment settles it.
        if !get(e, "checked", false)
            e["checked"] = true
            by = last_comment_by(url)
            if by == login
                delete!(exp, url)
                continue
            end
        end
        late += 1
    end
    if late > 0
        if !haskey(inbox, "wide")
            inbox["wide"] = stamp(at)
            @printf(warning(), "    %-24s LAGGING: %d polled row(s) moved with no notification after %d min; asking a day behind the cursor until it arrives, or `wl refresh --caught-up`\n",
                    "notifications", late, Dates.value(EXPECT_GRACE))
        else
            @printf(warning(), "    %-24s still lagging: %d awaited, wide since %s\n",
                    "notifications", late, inbox["wide"])
        end
    elseif haskey(inbox, "wide") && isempty(exp)
        delete!(inbox, "wide")
        @printf(report(), "    %-24s caught up: every awaited notification arrived; the ask is narrow again\n",
                "notifications")
    end
    isempty(exp) ? delete!(inbox, "expect") : (inbox["expect"] = exp)
    nothing
end

"Who wrote the newest comment on `url`, or `nothing`: one request, on demand."
function last_comment_by(url::AbstractString)
    parts = split(String(url), '/')
    length(parts) >= 7 || return nothing
    try
        cs = api_get("/repos/$(parts[4])/$(parts[5])/issues/$(parts[7])/comments";
                     params = Dict{String,Any}("per_page" => 1, "sort" => "created",
                                               "direction" => "desc"))
        isempty(cs) ? nothing : String(get(get(cs[1], "user", Dict{String,Any}()), "login", ""))
    catch e
        e isa ApiError || rethrow()
        nothing
    end
end

"""Stop waiting: `wl refresh --caught-up`. Every expectation dropped and the
ask narrow again, on the user's word that the notifications are fine."""
function caught_up!()
    inbox = load_inbox()
    n = length(get(inbox, "expect", Dict()))
    delete!(inbox, "expect"); delete!(inbox, "wide")
    save_inbox(inbox)
    n
end

"""Poll the clocks, and answer with everything the inbox holds.

An **incremental** sync, not a window. Each source keeps a cursor, and a poll
asks only for what has changed since it - so a repo seeing dozens of events a
day costs a handful of rows per poll rather than a re-read of the last month,
and nothing ages out unread because the window moved past it.

A source seen for the first time starts at *now*, so turning this on is inbox
zero rather than a month of history to dismiss. `backfill_days` moves that start
back if some is wanted.

**The inbox is a clock, never an answer.** What it holds is every url a
source has said moved, with GitHub's time for the newest thing it saw, until
the refresh has asked about the url and the row is read; whether a row is
*unread* is `seen_of`'s to say, over the corpus and these rows alike. This
used to be named for the unread list and prune on the read stamp, which was
one of three answers to the question. The sources are `sources`, the loop is
`sync!`.
"""
function poll(cfg, login, at::DateTime; verbose::Bool = true)
    cfge = get(cfg, "events", Dict{String,Any}())
    srcs = sources(cfg, login; verbose = verbose)
    isempty(srcs) && return OrderedDict{String,Any}[]
    auth()          # Fail once, loudly. Without a token every repo fails the
                    # same way and the result degrades into a silently empty
                    # unread list rather than an error.
    items, got = sync!(srcs, at; login = login,
        ttl = Millisecond(round(Int, 1000 * get(cfge, "activity_ttl_seconds", 120))),
        backfill = Day(get(cfge, "backfill_days", 0)))
    out = collect(OrderedDict{String,Any}, values(items))
    sort!(out; by = e -> e["updated"], rev = true)
    verbose && @printf(report(), "  %-16s %4d in the inbox (%d new across %d source(s))\n",
                       "activity", length(out), got, length(srcs))
    out
end

"""Put items into the inbox as unread, without a poll having found them.

The activity lane only watches the repos in `config.toml`, and an imported item
is imported *because* its repo is not one of them - so no poll will ever put it
in front of you. This is the hand-delivery: the same entry a poll would have
written, and the read stamp cleared, so it arrives in the unread lane and leaves
it the same way everything else does.

Deliberately not a cursor: nothing is advanced and nothing is claimed to have
been seen. One entry per row, and the row is whatever the caller could learn
about the item.

`overwrite = false` leaves an entry a *poll* already wrote. Much of what gets
imported is an old issue in a repo that is tracked anyway, or a pull request of
yours in one that is not - so the url is often already in here, with a comment
count and a state this caller does not have. Marking it unread is the whole of
what is wanted in that case; replacing it with a thinner row is not.
"""
function inbox_add!(rows; overwrite::Bool = true)
    inbox = load_inbox()
    items = inbox["items"]
    urls = String[]
    for r in rows
        u = String(r["url"])
        (overwrite || !haskey(items, u)) && (items[u] = r)
        u in urls || push!(urls, u)
    end
    save_inbox(inbox)
    mark_unread(urls)          # a read stamp from last time would hide it again
    length(urls)
end

"Is this url in the inbox already? What tells an import's own row from a poll's."
in_inbox(url::AbstractString) = haskey(load_inbox()["items"], String(url))

"""Take entries back out of the inbox. The other half of `inbox_add!`.

An import that is undone has to undo both halves of the hand-delivery, and the
row is the half that outlives the session: `imported` goes back out of
`local.toml` and the read stamp is put back, but an entry left in `fetched.json`
keeps the item in the unread lane for as long as it stays there - there is no
poll that would ever clear it, because the reason the item was imported is that
no poll covers its repo.

Only rows this program put there should be handed to it. A poll's own entry is
a record of something that actually happened and is not an import's to remove.
"""
function inbox_drop!(urls)
    inbox = load_inbox()
    items = inbox["items"]
    n = 0
    for u in urls
        haskey(items, String(u)) && (delete!(items, String(u)); n += 1)
    end
    n == 0 || save_inbox(inbox)
    n
end

"""Fetch a thread live - the part email used to hand you.

Returns `(body, comments, commits)`. The commits are what the thread is read
*with*: "they replied, then pushed, then replied" is one sequence, and having
them arrive on a second cadence from a second cache is how it came to be read as
two. Callers that only want the conversation destructure the first two and are
none the wiser.

The commit query is started before the REST reads and waited on after them, so
what a person waits for is the slower of the two rather than the sum. It is
also the only part allowed to come back empty on failure: an issue has no
branch, and a pull request whose commits could not be read is a line missing
from a list rather than a reason to show no thread at all.
"""
function thread(url::AbstractString; limit::Int = 10)
    parts = split(url, '/')
    owner_repo = join(parts[4:5], '/')
    num = parts[end]
    commits = @async try; pr_commits(url); catch; OrderedDict{String,Any}[]; end
    body = api_get("/repos/$owner_repo/issues/$num")[1]
    cs = api_paged("/repos/$owner_repo/issues/$num/comments")
    try
        append!(cs, api_paged("/repos/$owner_repo/pulls/$num/comments"))
    catch e
        e isa ApiError || rethrow()   # not a PR, or no review comments
    end
    sort!(cs; by = c -> c["created_at"])
    (body, cs[max(1, end - limit + 1):end],
     try; fetch(commits); catch; OrderedDict{String,Any}[]; end)
end

"""The last commits on a pull request's branch: `oid`, `at`, `headline`, `by`.

Empty for an issue, which has no branch - `resource` answers `null` against a
selection that only spreads `... on PullRequest`.

GraphQL rather than `/pulls/N/commits`, for one reason that decides it: REST
returns commits oldest-first and pages forward, so the *newest* thirty of a
four-hundred-commit branch are four requests away, while `commits(last: 30)` is
one request and one rate-limit point for exactly the end anybody is reading.

`committedDate` and not `authoredDate`: a rebase rewrites the first and keeps
the second, and the question this answers is when the branch moved rather than
when the work was originally done.

Uncached on purpose. It is stored inside the thread's own cache entry, so it
ages with the thread it is drawn into and a hit on one can never be a miss on
the other - which is what the two-threshold window on that entry is for: a
cached thread goes up at once, and a fetch that had to wait on this would have
been exactly the pause it exists to avoid.
"""
function pr_commits(url::AbstractString; n::Int = 30)
    d = gh_graphql(
        "query(\$u: URI!, \$n: Int!) { resource(url: \$u) { ... on PullRequest {\n" *
        "      commits(last: \$n) { nodes { commit {\n" *
        "        oid committedDate messageHeadline\n" *
        "        author { user { login } name }\n" *
        "      } } }\n  } } }";
        vars = Dict{String,Any}("u" => String(url), "n" => n))
    r = get(d, :resource, nothing)
    cc = r === nothing ? nothing : get(r, :commits, nothing)
    ns = cc === nothing ? () : something(get(cc, :nodes, nothing), ())
    out = OrderedDict{String,Any}[]
    for x in ns
        c = get(x, :commit, nothing)
        c === nothing && continue
        # The GitHub login where the committer has an account, the name off the
        # commit where they do not - a co-author or an unlinked email is still
        # somebody, and "?" beside a push reads as a bug rather than as a fact.
        a = something(get(c, :author, nothing), Dict{Symbol,Any}())
        u = something(get(a, :user, nothing), Dict{Symbol,Any}())
        who = something(get(u, :login, nothing), get(a, :name, nothing), "")
        push!(out, OrderedDict{String,Any}(
            "oid" => String(c.oid), "at" => String(c.committedDate),
            "headline" => String(something(get(c, :messageHeadline, nothing), "")),
            "by" => String(who)))
    end
    out
end

# --- writing ---------------------------------------------------------------
#
# Everything above reads. What follows is every function in the program that
# changes anything on GitHub: a comment, a thread on a pending review,
# submitting or discarding one, a reply, a whole review, and a label.
#
# They return a status string - empty for success, the failure otherwise - so a
# caller can put it in the footer; `add_review_thread` returns the draft's new
# state beside it, because the browser has to hold what it just added to. None
# of them raise: a review that will not post is a message to read, not a stack
# trace over the frame you were reading.
#
# A 403 here is worth naming specially. The sandbox's App token is scoped for
# reading, so every one of these fails that way in this environment, and the
# generic message ("Resource not accessible by integration") reads like a bug in
# the request rather than the one thing it actually means.

"Post one write, turning any failure into a line of text."
function _write(f)
    try
        f()
        ""
    catch e
        msg = first(sprint(showerror, e), 300)
        occursin("not accessible by integration", msg) || occursin("403", msg) ?
            "refused: this token cannot write. It needs a PAT with issues and \
             pull_requests write access - see Infrastructure in TODO.md" :
            first(msg, 160)
    end
end

_repo_num(url) = (join(split(url, '/')[4:5], '/'), split(url, '/')[end])

"Drop the cached reads an item's own write has just invalidated."
function _invalidate(url)
    # `merge:` is here rather than only in `merge_pr`, because the writes that
    # change whether a pull request can be merged are the *other* ones: an
    # approval takes it from `BLOCKED` to `CLEAN`, and `M` pressed straight
    # after `A` should not read the state the approval was submitted against.
    for k in ("thread:", "reviewcomments:", "itemmeta:", "merge:")
        cache_drop(string(k, url))
    end
end

"""Comment on the pull request or issue as a whole."""
function post_comment(url::AbstractString, body::AbstractString)
    r, n = _repo_num(url)
    _write() do
        GitHub.gh_post_json(GitHub.DEFAULT_API, "/repos/$r/issues/$n/comments";
                            auth = auth(), params = Dict("body" => String(body)))
        _invalidate(url)
    end
end

# --- a review, written a comment at a time ----------------------------------
#
# GitHub's own answer to "five remarks should be one notification" is a *pending
# review*: a draft that lives on GitHub, is visible only to its author, and is
# submitted later as one thing. That is what "Start a review" does in the web UI,
# and it means the batch is durable without this program storing a line of it -
# quitting, or losing the machine, leaves the draft where a browser or the app
# will find it.
#
# Three mutations do all of it, and there is no REST for any of them:
# `addPullRequestReview` with `threads` and no `event` creates the draft,
# `addPullRequestReviewThread` appends to it, `submitPullRequestReview` sends it.

"""The pull request's node id, and the pending review of yours on it if any.

One query for both, because the id is what a mutation needs and the review is
what the browser needs to show. `nothing` when the url is not a pull request.

Cached briefly rather than not at all: this runs when an item is selected, and
moving up and down a list should not be a request a row. Every mutation below
writes the new state straight into that cache, so what is on screen is right at
once rather than after the entry expires.
"""
function review_state(url::AbstractString; ttl = 60.0)
    key = string("review:", url)
    hit = cache_get(key, ttl)
    hit === nothing || return _review_shape(hit[1])
    d = gh_graphql(
        "query(\$u: URI!, \$me: String!) { resource(url: \$u) { ... on PullRequest " *
        "{ id reviews(states: PENDING, first: 1, author: \$me) " *
        "{ nodes { id comments { totalCount } } } } } }";
        vars = Dict{String,Any}("u" => String(url), "me" => Worklog.login()))
    r = get(d, :resource, nothing)
    (r === nothing || get(r, :id, nothing) === nothing) && return nothing
    ns = get(get(r, :reviews, (; nodes = ())), :nodes, ())
    v = OrderedDict{String,Any}("id" => String(r.id),
                                "review" => isempty(ns) ? "" : String(ns[1].id),
                                "n" => isempty(ns) ? 0 : ns[1].comments.totalCount)
    cache_put(key, v)
    _review_shape(v)
end

_review_shape(v) = (id = String(v["id"]), review = String(v["review"]),
                    n = Int(v["n"]))

"Remember what a mutation just made true, so the next frame does not ask."
function _review_put(url, id, review, n)
    cache_put(string("review:", url),
              OrderedDict{String,Any}("id" => String(id), "review" => String(review),
                                      "n" => Int(n)))
    (id = String(id), review = String(review), n = Int(n))
end

"""Add one thread to your pending review, starting one if there is none.

Returns `(state, "")` or `(nothing, error)`. `start_line` makes it a range, the
same way it does for a comment posted on its own.

The two mutations differ only in which id they carry, so which one runs is
decided by whether a draft is already open rather than by the caller.
"""
function add_review_thread(url::AbstractString, path::AbstractString, line::Integer,
                           side::AbstractString, body::AbstractString;
                           start_line = nothing)
    stt = try
        review_state(url)
    catch e
        return (nothing, first(sprint(showerror, e), 200))
    end
    stt === nothing && return (nothing, "not a pull request")
    vars = Dict{String,Any}("path" => String(path), "body" => String(body),
                            "line" => Int(line), "side" => String(side))
    start_line === nothing || Int(start_line) >= Int(line) ||
        (vars["startLine"] = Int(start_line); vars["startSide"] = String(side))
    try
        if isempty(stt.review)
            vars["pr"] = stt.id
            d = gh_graphql(
                "mutation(\$pr: ID!, \$path: String!, \$body: String!, \$line: Int!, " *
                "\$side: DiffSide!, \$startLine: Int, \$startSide: DiffSide) " *
                "{ addPullRequestReview(input: {pullRequestId: \$pr, threads: " *
                "[{path: \$path, body: \$body, line: \$line, side: \$side, " *
                "startLine: \$startLine, startSide: \$startSide}]}) " *
                "{ pullRequestReview { id } } }"; vars = vars)
            rid = d.addPullRequestReview.pullRequestReview.id
            return (_review_put(url, stt.id, rid, 1), "")
        else
            vars["rev"] = stt.review
            gh_graphql(
                "mutation(\$rev: ID!, \$path: String!, \$body: String!, \$line: Int!, " *
                "\$side: DiffSide!, \$startLine: Int, \$startSide: DiffSide) " *
                "{ addPullRequestReviewThread(input: {pullRequestReviewId: \$rev, " *
                "path: \$path, body: \$body, line: \$line, side: \$side, " *
                "startLine: \$startLine, startSide: \$startSide}) " *
                "{ thread { id } } }"; vars = vars)
            return (_review_put(url, stt.id, stt.review, stt.n + 1), "")
        end
    catch e
        (nothing, first(sprint(showerror, e), 300))
    end
end

"""Send the pending review, with a verdict and an optional covering note.

The note is left out when blank rather than sent as an empty string, so that
a draft whose comments are the whole review goes as one with no body - the
same as `submit_review` below, and as the web UI.
"""
function submit_pending(url::AbstractString, review::AbstractString,
                        event::AbstractString, body::AbstractString)
    _write() do
        gh_graphql(
            "mutation(\$rev: ID!, \$ev: PullRequestReviewEvent!, \$body: String) " *
            "{ submitPullRequestReview(input: {pullRequestReviewId: \$rev, " *
            "event: \$ev, body: \$body}) { pullRequestReview { id } } }";
            vars = Dict{String,Any}("rev" => String(review), "ev" => String(event),
                                    "body" => isempty(strip(body)) ? nothing : String(body)))
        cache_drop(string("review:", url))
        _invalidate(url)
    end
end

"""Throw the pending review away. The comments in it go with it."""
function discard_pending(url::AbstractString, review::AbstractString)
    _write() do
        gh_graphql(
            "mutation(\$rev: ID!) { deletePullRequestReview(input: " *
            "{pullRequestReviewId: \$rev}) { pullRequestReview { id } } }";
            vars = Dict{String,Any}("rev" => String(review)))
        cache_drop(string("review:", url))
        _invalidate(url)
    end
end

"""Reply to an existing review comment, in its thread."""
function reply_review_comment(url::AbstractString, comment_id, body::AbstractString)
    r, n = _repo_num(url)
    _write() do
        GitHub.gh_post_json(GitHub.DEFAULT_API, "/repos/$r/pulls/$n/comments";
                            auth = auth(),
                            params = Dict("body" => String(body), "in_reply_to" => comment_id))
        _invalidate(url)
    end
end

"""Submit a review: `APPROVE`, `REQUEST_CHANGES` or `COMMENT`.

`REQUEST_CHANGES` and `COMMENT` require a body; `APPROVE` does not.
"""
function submit_review(url::AbstractString, event::AbstractString, body::AbstractString)
    r, n = _repo_num(url)
    _write() do
        p = Dict{String,Any}("event" => String(event))
        isempty(strip(body)) || (p["body"] = String(body))
        GitHub.gh_post_json(GitHub.DEFAULT_API, "/repos/$r/pulls/$n/reviews";
                            auth = auth(), params = p)
        _invalidate(url)
    end
end

"""Add or remove one label. Labels live on the issue, for pull requests too."""
function toggle_label(url::AbstractString, label::AbstractString, add::Bool)
    r, n = _repo_num(url)
    _write() do
        if add
            GitHub.gh_post_json(GitHub.DEFAULT_API, "/repos/$r/issues/$n/labels";
                                auth = auth(), params = Dict("labels" => [String(label)]))
        else
            GitHub.gh_delete(GitHub.DEFAULT_API,
                             "/repos/$r/issues/$n/labels/$(HTTP_escape(label))";
                             auth = auth())
        end
        _invalidate(url)
    end
end

"A label can contain spaces and colons, which have to survive the path."
HTTP_escape(s::AbstractString) =
    join(c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~" ?
         string(c) : string("%", uppercase(string(UInt8(c), base = 16, pad = 2)))
         for c in String(s))

# --- merging ----------------------------------------------------------------
#
# The end of the loop `A` and `L` stop one step short of: a review that ends in
# "yes" still had to be finished on github.com.
#
# One query answers everything the composer needs, and it asks for the text of
# *every* operation the repo allows rather than only the one about to be used.
# That is not thrift about round trips in general - it is what makes `tab` free:
# the operation is changed while the composer is open, and a request per press
# would make choosing cost more than merging.

"""The three operations, in the order this program prefers them.

Which is *this program's* order and not the repository's, because there is no
repository's to have. See `merge_state`.
"""
const MERGE_METHODS = ("SQUASH", "MERGE", "REBASE")

"GitHub's own wording for each, since its button is the thing being recognised."
merge_label(m::AbstractString) = m == "SQUASH" ? "squash and merge" :
                                 m == "REBASE" ? "rebase and merge" :
                                                 "create a merge commit"

# `squashh`/`squashb`, `mergeh`/`mergeb`, `rebaseh`/`rebaseb`. Rebase is asked
# for with the rest and always answers with two empty strings - see below.
const _MERGE_TEXT = join(
    string(lowercase(m), "h: viewerMergeHeadlineText(mergeType: ", m, ")\n      ",
           lowercase(m), "b: viewerMergeBodyText(mergeType: ", m, ")\n      ")
    for m in MERGE_METHODS)

"""
    merge_state(url) -> nt, or nothing when the url names no pull request

Everything `M` needs: what may be done, what each way of doing it would write,
and whether it can be done at all.

`text` is GitHub's own two boxes - `viewerMergeHeadlineText` and
`viewerMergeBodyText` - which already honour the repository's squash-title and
squash-message settings, so the message this program offers is the message the
web UI would have offered. **Rebasing has no message at all**: both come back
empty even on a repository that allows it, because the commits are replayed as
they were written rather than joined into a new one.

`default` is `first(methods)`, and it is not GitHub's answer, because GitHub
has no repository-level answer to give. `Repository.viewerDefaultMergeMethod` is
the only field of that type in the whole schema and it is *viewer*-scoped: it
reports what you last merged with there, which is why the identical allowed pair
answers `SQUASH` on `JuliaLang/julia` and `MERGE` on `JuliaCI/julia-buildkite`.
A default that drifts with your own history is not a repository's default, so
this one is ours, stated as ours, and the same everywhere. TODO.md has the
measurements.

Cached briefly, and the freshness that matters is not the cache's to keep: `oid`
goes back to the mutation as `expectedHeadOid`, so a commit pushed while the
message was being written is refused by GitHub rather than merged over.

An entry older than `ttl` but younger than `keep` is handed back only when it
says CONFLICTING. That answer holds until somebody rebases, and being late to
see it cleared costs nothing; a clean answer that has gone wrong is the one
nobody notices, so past `ttl` it is not shown and the question is asked again.
"""
merge_key(url::AbstractString) = string("merge:", url)

"Is a cache hit under `merge_key` one to show, at `ttl`? See `merge_state`."
merge_usable(hit, ttl) =
    hit !== nothing && (hit[2] <= ttl || String(hit[1]["mergeable"]) == "CONFLICTING")

function merge_state(url::AbstractString; ttl = 30.0, keep = ttl)
    key = merge_key(url)
    hit = cache_get(key, ttl; keep_s = keep)
    merge_usable(hit, ttl) && return _merge_shape(hit[1])
    d = gh_graphql(
        "query(\$u: URI!) { resource(url: \$u) { ... on PullRequest {\n" *
        "      id state isDraft mergeable mergeStateStatus\n" *
        "      headRefOid baseRefName commits { totalCount }\n      " *
        _MERGE_TEXT *
        "repository { mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed }\n" *
        "  } } }"; vars = Dict{String,Any}("u" => String(url)))
    r = get(d, :resource, nothing)
    (r === nothing || get(r, :id, nothing) === nothing) && return nothing
    rp = r.repository
    allowed = String[m for m in MERGE_METHODS
                     if (m == "SQUASH" ? rp.squashMergeAllowed :
                         m == "MERGE" ? rp.mergeCommitAllowed : rp.rebaseMergeAllowed)]
    txt = OrderedDict{String,Any}(
        m => OrderedDict{String,Any}(
            "headline" => String(something(get(r, Symbol(lowercase(m), "h"), ""), "")),
            "body" => String(something(get(r, Symbol(lowercase(m), "b"), ""), "")))
        for m in allowed)
    v = OrderedDict{String,Any}(
        "id" => String(r.id), "oid" => String(r.headRefOid),
        "state" => String(something(get(r, :state, ""), "")),
        "draft" => get(r, :isDraft, false) === true,
        "mergeable" => String(something(get(r, :mergeable, "UNKNOWN"), "UNKNOWN")),
        "status" => String(something(get(r, :mergeStateStatus, "UNKNOWN"), "UNKNOWN")),
        "base" => String(r.baseRefName), "commits" => Int(r.commits.totalCount),
        "methods" => allowed, "text" => txt)
    cache_put(key, v)
    _merge_shape(v)
end

"Both a fresh fetch and a cache hit reach the caller in the same shape."
_merge_shape(v) = (id = String(v["id"]), oid = String(v["oid"]),
                   state = String(v["state"]), draft = v["draft"] === true,
                   mergeable = String(v["mergeable"]), status = String(v["status"]),
                   base = String(v["base"]), commits = Int(v["commits"]),
                   methods = String[String(m) for m in v["methods"]],
                   text = Dict{String,Tuple{String,String}}(
                       String(k) => (String(t["headline"]), String(t["body"]))
                       for (k, t) in pairs(v["text"])))

"""Merge it, with the message that was written for it.

`headline` and `body` go nowhere on a rebase, which has neither - sending them
would be describing a commit that is not going to be made.

`oid` is the head the message was written against. It goes as `expectedHeadOid`,
so a merge cannot land on work that arrived while the composer was open: the
mutation is refused instead, which is the one failure here worth having.
"""
function merge_pr(url::AbstractString, id::AbstractString, method::AbstractString,
                  headline::AbstractString, body::AbstractString,
                  oid::AbstractString)
    _write() do
        rebase = method == "REBASE"
        gh_graphql(
            "mutation(\$pr: ID!, \$m: PullRequestMergeMethod!, \$oid: GitObjectID!, " *
            "\$headline: String, \$body: String) " *
            "{ mergePullRequest(input: {pullRequestId: \$pr, mergeMethod: \$m, " *
            "expectedHeadOid: \$oid, commitHeadline: \$headline, commitBody: \$body}) " *
            "{ pullRequest { merged } } }";
            vars = Dict{String,Any}("pr" => String(id), "m" => String(method),
                                    "oid" => String(oid),
                                    "headline" => rebase ? nothing : String(headline),
                                    "body" => rebase ? nothing : String(body)))
        _invalidate(url)
    end
end

"""Every review comment on a pull request, unabridged.

Separate from `thread`, which merges review comments into the chronological
list and then keeps only the most recent few. The diff pane wants all of them
regardless of age - a comment is placed by where it points, not by when it was
written - and wants the anchoring fields `thread` has no use for: `path`,
`line`/`original_line`, `side` and `in_reply_to_id`.
"""
function review_comments(url::AbstractString; ttl = 300.0)
    key = string("reviewcomments:", url)
    hit = cache_get(key, ttl)
    hit === nothing || return [OrderedDict{String,Any}(String(k) => v for (k, v) in c)
                               for c in hit[1]]
    parts = split(url, '/')
    owner_repo = join(parts[4:5], '/')
    num = parts[end]
    cs = api_paged("/repos/$owner_repo/pulls/$num/comments")
    sort!(cs; by = c -> String(get(c, "created_at", "")))
    cache_put(key, cs)
    cs
end

"""Which review comments belong to a thread somebody has resolved.

Resolution is a property of the *thread*, and the REST comment carries no trace
of it - `/pulls/{n}/comments` will hand you a conversation settled six weeks ago
in exactly the shape of one waiting for an answer. Only GraphQL knows, so this
is one query for the whole pull request, cached beside the comments themselves.

Returns the comment ids, not the threads: the diff places comments, and matching
by id is what lets a REST comment be recognised as part of a settled thread.

Bounded at 100 threads of 100 comments. Past that the tail reads as unresolved,
which is the safe way round - an unresolved comment shown is noise, a resolved
one hidden that was not resolved is a remark nobody answers.
"""
function resolved_comments(url::AbstractString; ttl = 300.0)
    key = string("resolved:", url)
    hit = cache_get(key, ttl)
    hit === nothing || return Set{Int}(Int(x) for x in hit[1])
    out = Int[]
    try
        d = gh_graphql(
            "query(\$u: URI!) { resource(url: \$u) { ... on PullRequest " *
            "{ reviewThreads(first: 100) { nodes { isResolved " *
            "comments(first: 100) { nodes { databaseId } } } } } } }";
            vars = Dict{String,Any}("u" => String(url)))
        r = get(d, :resource, nothing)
        for t in get(get(r === nothing ? (;) : r, :reviewThreads, (; nodes = ())), :nodes, ())
            t.isResolved || continue
            for c in t.comments.nodes
                c.databaseId === nothing || push!(out, Int(c.databaseId))
            end
        end
    catch
        return Set{Int}()          # unknown, so nothing is hidden
    end
    cache_put(key, out)
    Set{Int}(out)
end

"""
    itemmeta(url, is_pr) -> (requested, teams, assignees, pending, fork, default, reviews)

Who was asked to review, who has, who it is assigned to, whether a draft
review of yours is sitting on it, where its head lives and what its
repository merges into by default.

Fetched for the selected item only, on demand. The heavy GraphQL query carries
reviews already, but the light query the bulk lanes use does not - so anything
reached through the mention or firehose lanes has none, which is most of the
list. Widening the light query would pay for ~2000 items to answer a question
about the one on screen; this pays for the one.

`reviews` is per person, latest state wins: GitHub keeps every submission, so a
reviewer who approved after requesting changes appears twice and the earlier
verdict is not the one that counts. COMMENTED never overrides a verdict.
"""
meta_key(url::AbstractString) = string("itemmeta:", url)

function itemmeta(url::AbstractString, is_pr::Bool; ttl = 300.0, keep = ttl)
    key = meta_key(url)
    hit = cache_get(key, ttl; keep_s = keep)
    hit === nothing || return _meta_shape(hit[1])
    parts = split(url, '/')
    owner_repo = join(parts[4:5], '/')
    num = parts[end]
    kind = is_pr ? "pulls" : "issues"
    head = api_get("/repos/$owner_repo/$kind/$num")[1]
    assignees = String[String(a["login"]) for a in get(head, "assignees", ())]
    requested, teams, latest = String[], String[], OrderedDict{String,Any}()
    pending, fork, default = "", "", ""
    if is_pr
        # And what the base repository merges into by default, off the same
        # answer: a pull request against `v1.x` or `release-1.12` is one that
        # will not land on the branch everything else does, and the pane says
        # so beside the base rather than leaving it to be noticed.
        default = String(get(get(get(head, "base", Dict{String,Any}()), "repo",
                                 Dict{String,Any}()), "default_branch", ""))
        # Where the head branch lives, when that is not here: the lanes carry
        # the branch name and not its repository, and `owner:branch` is the
        # half of the name that says which checkout it can be fetched from.
        # `head.repo` is null once a fork is deleted, and then there is no
        # name to say.
        hr = get(get(head, "head", Dict{String,Any}()), "repo", nothing)
        hr === nothing || (full = String(get(hr, "full_name", ""));
                           full == owner_repo || (fork = full))
        for r in get(head, "requested_reviewers", ())
            push!(requested, String(r["login"]))
        end
        for t in get(head, "requested_teams", ())
            push!(teams, String(get(t, "slug", get(t, "name", "?"))))
        end
        for r in api_paged("/repos/$owner_repo/pulls/$num/reviews")
            st = String(get(r, "state", ""))
            who = String(get(something(get(r, "user", nothing), Dict{String,Any}()),
                             "login", "?"))
            at = String(something(get(r, "submitted_at", nothing), ""))
            # A draft of yours, which GitHub shows to nobody else. Picked up here
            # because this request is already being made - the alternative is a
            # GraphQL query per selected pull request, to answer a question that
            # is usually "no". It is not the authority on the count, only on the
            # draft being there: the mutations that add to one say how many.
            if st == "PENDING" && who == Worklog.login()
                pending = String(get(r, "node_id", ""))
                continue
            end
            # A later COMMENTED does not undo an APPROVED or a CHANGES_REQUESTED.
            prev = get(latest, who, nothing)
            (st == "COMMENTED" && prev !== nothing && prev["state"] != "COMMENTED") && continue
            latest[who] = Dict{String,Any}("state" => st, "at" => at)
        end
    end
    v = OrderedDict{String,Any}(
        "requested" => requested, "teams" => teams, "assignees" => assignees,
        "pending" => pending, "fork" => fork, "default" => default,
        "reviews" => [OrderedDict{String,Any}("login" => k, "state" => v["state"],
                                              "at" => v["at"]) for (k, v) in latest])
    cache_put(key, v)
    _meta_shape(v)
end

"Both a fresh fetch and a cache hit reach the caller in the same shape."
_meta_shape(v) = (requested = String[String(x) for x in v["requested"]],
                  teams = String[String(x) for x in v["teams"]],
                  assignees = String[String(x) for x in v["assignees"]],
                  pending = String(get(v, "pending", "")),
                  fork = String(get(v, "fork", "")),
                  default = String(get(v, "default", "")),
                  reviews = [(login = String(r["login"]), state = String(r["state"]),
                              at = String(r["at"])) for r in v["reviews"]])

end # module Events
