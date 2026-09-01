# Unread tracking, replacing per-event email notification.
#
# Email's real value here is one bit per thread: have you seen it. Everything
# else it carries - titles, bodies, who spoke - GitHub can answer live, so none
# of it is stored. The only persisted state is `read.json`: per item, the
# timestamp you have seen up to. That is precisely the bit an inbox was
# providing and the one thing that cannot be re-derived from GitHub.
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
import ..cache_get, ..cache_put

using Dates, Printf, JSON3, OrderedCollections
import GitHub

using ..Worklog: ROOT, NOW, stamp, json_dumps

const READ = joinpath(ROOT, "read.json")

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

"One request, one page. Always returns a vector, as the Python `_get` did."
function api_get(endpoint::AbstractString; params = Dict{String,Any}())
    v = try
        GitHub.gh_get_json(GitHub.DEFAULT_API, endpoint; auth = auth(), params = params)
    catch e
        throw(ApiError(first(sprint(showerror, e), 200)))
    end
    v isa AbstractVector ? v : Any[v]
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
                   per_page::Int = 100, max_pages::Int = 60)
    out, seen = Any[], Set{Any}()
    for page in 1:max_pages
        rows = api_get(endpoint; params = merge(params, Dict{String,Any}(
            "per_page" => per_page, "page" => page)))
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
                rows = api_get(endpoint; params = merge(params,
                    Dict{String,Any}("per_page" => per_page, "page" => 1)))
                isempty(rows) || break
            end
            isempty(rows) && break
        end
        length(rows) < per_page && break
    end
    out
end

load_read() = isfile(READ) ?
    Dict{String,Any}(String(k) => v for (k, v) in JSON3.read(read(READ, String))) :
    Dict{String,Any}()

function mark_read(urls)
    r = load_read()
    s = stamp()
    for u in urls
        r[u] = s
    end
    write(READ, json_dumps(r; indent = 1, sortkeys = true))
    length(urls)
end

"""Items touched in the lookback window that you have not marked read.

One query per repo, nothing cached. An item you have never marked is unread only
if it moved inside the window - otherwise turning this on would present every
thread in the repo as new mail.
"""
function unread(cfg, login; verbose::Bool = true)
    cfge = get(cfg, "events", Dict{String,Any}())
    repos = get(cfge, "repos", String[])
    isempty(repos) && return OrderedDict{String,Any}[]
    since = Dates.format(NOW[] - Day(get(cfge, "lookback_days", 30)), "yyyy-mm-ddTHH:MM:SS") * "Z"
    auth()          # Fail once, loudly. Without a token every repo fails the
                    # same way and the result degrades into a silently empty
                    # unread list rather than an error.
    rd = load_read()
    out = OrderedDict{String,Any}[]
    ttl = Float64(get(cfge, "activity_ttl_seconds", 120))
    for repo in repos
        # Persisted: this runs on every launch of the browser and is several
        # paginated requests per repo, which is most of the startup wait. Read
        # state is applied below, after the cache, so marking something read is
        # reflected immediately even against a warm entry.
        ckey = string("activity:", repo, ":", since)
        rows = try
            hit = cache_get(ckey, ttl)
            hit === nothing ?
                cache_put(ckey, api_paged("/repos/$repo/issues"; params = Dict{String,Any}(
                    "since" => since, "state" => "all", "sort" => "updated",
                    "direction" => "asc"))) :
                hit[1]
        catch e
            e isa ApiError || rethrow()
            @printf(stderr, "    %-24s FAILED: %s\n", repo, e.msg)
            continue
        end
        for r in rows
            url = r["html_url"]
            r["updated_at"] <= get(rd, url, "") && continue
            push!(out, OrderedDict{String,Any}(
                "url" => url, "repo" => repo, "number" => r["number"],
                "title" => r["title"],
                "is_pr" => haskey(r, "pull_request"),
                "state" => r["state"],
                "author" => get(something(get(r, "user", nothing), Dict{String,Any}()), "login", nothing),
                "updated" => r["updated_at"],
                "comments" => get(r, "comments", 0),
                "labels" => [l["name"] for l in get(r, "labels", ())],
                "mine" => get(something(get(r, "user", nothing), Dict{String,Any}()), "login", nothing) == login))
        end
    end
    sort!(out; by = e -> e["updated"], rev = true)
    verbose && @printf(stderr, "  %-16s %4d unread across %d repo(s)\n",
                       "activity", length(out), length(repos))
    out
end

"Fetch a thread's recent comments live - the part email used to hand you."
function thread(url::AbstractString; limit::Int = 10)
    parts = split(url, '/')
    owner_repo = join(parts[4:5], '/')
    num = parts[end]
    body = api_get("/repos/$owner_repo/issues/$num")[1]
    cs = api_paged("/repos/$owner_repo/issues/$num/comments")
    try
        append!(cs, api_paged("/repos/$owner_repo/pulls/$num/comments"))
    catch e
        e isa ApiError || rethrow()   # not a PR, or no review comments
    end
    sort!(cs; by = c -> c["created_at"])
    (body, cs[max(1, end - limit + 1):end])
end

# --- writing ---------------------------------------------------------------
#
# Everything above reads. These five write, and they are the only functions in
# the program that change anything on GitHub.
#
# Each returns a status string - empty for success, the failure otherwise - so a
# caller can put it in the footer. They do not raise: a review that will not
# post is a message to read, not a stack trace over the frame you were reading.
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
    for k in ("thread:", "reviewcomments:", "itemmeta:")
        try
            cache_put(string(k, url), nothing)
        catch
        end
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

"""Comment on one source line, as a standalone review comment.

`commit_id` has to be the head the diff was read against, not the branch tip: a
line number means nothing without the commit it was counted in.
"""
function post_review_comment(url::AbstractString, commit_id::AbstractString,
                             path::AbstractString, line::Integer,
                             side::AbstractString, body::AbstractString)
    r, n = _repo_num(url)
    _write() do
        GitHub.gh_post_json(GitHub.DEFAULT_API, "/repos/$r/pulls/$n/comments";
                            auth = auth(),
                            params = Dict("body" => String(body), "commit_id" => String(commit_id),
                                          "path" => String(path), "line" => Int(line),
                                          "side" => String(side)))
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

"""
    itemmeta(url, is_pr) -> (requested, reviews, assignees, teams)

Who was asked to review, who has, and who it is assigned to.

Fetched for the selected item only, on demand. The heavy GraphQL query carries
reviews already, but the light query the bulk lanes use does not - so anything
reached through the mention or firehose lanes has none, which is most of the
list. Widening the light query would pay for ~2000 items to answer a question
about the one on screen; this pays for the one.

`reviews` is per person, latest state wins: GitHub keeps every submission, so a
reviewer who approved after requesting changes appears twice and the earlier
verdict is not the one that counts. COMMENTED never overrides a verdict.
"""
function itemmeta(url::AbstractString, is_pr::Bool; ttl = 300.0)
    key = string("itemmeta:", url)
    hit = cache_get(key, ttl)
    hit === nothing || return _meta_shape(hit[1])
    parts = split(url, '/')
    owner_repo = join(parts[4:5], '/')
    num = parts[end]
    kind = is_pr ? "pulls" : "issues"
    head = api_get("/repos/$owner_repo/$kind/$num")[1]
    assignees = String[String(a["login"]) for a in get(head, "assignees", ())]
    requested, teams, latest = String[], String[], OrderedDict{String,Any}()
    if is_pr
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
            # A later COMMENTED does not undo an APPROVED or a CHANGES_REQUESTED.
            prev = get(latest, who, nothing)
            (st == "COMMENTED" && prev !== nothing && prev["state"] != "COMMENTED") && continue
            latest[who] = Dict{String,Any}("state" => st, "at" => at)
        end
    end
    v = OrderedDict{String,Any}(
        "requested" => requested, "teams" => teams, "assignees" => assignees,
        "reviews" => [OrderedDict{String,Any}("login" => k, "state" => v["state"],
                                              "at" => v["at"]) for (k, v) in latest])
    cache_put(key, v)
    _meta_shape(v)
end

"Both a fresh fetch and a cache hit reach the caller in the same shape."
_meta_shape(v) = (requested = String[String(x) for x in v["requested"]],
                  teams = String[String(x) for x in v["teams"]],
                  assignees = String[String(x) for x in v["assignees"]],
                  reviews = [(login = String(r["login"]), state = String(r["state"]),
                              at = String(r["at"])) for r in v["reviews"]])

end # module Events
