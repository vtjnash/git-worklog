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

using Dates, Printf, JSON3, OrderedCollections
import GitHub

using ..Worklog: ROOT, NOW, stamp, json_dumps

const READ = joinpath(ROOT, "read.json")

struct ApiError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ApiError) = print(io, e.msg)

const _AUTH = Ref{Any}(nothing)

"""The sandbox host keeps `/run/claudebox-github/token` refreshed, so prefer the
file over the environment, which can be a stale copy of an expired token."""
function auth()
    _AUTH[] === nothing || return _AUTH[]
    tok = ""
    f = "/run/claudebox-github/token"
    isfile(f) && (tok = strip(read(f, String)))
    isempty(tok) && (tok = strip(get(ENV, "GH_TOKEN", get(ENV, "GITHUB_TOKEN", ""))))
    isempty(tok) && throw(ApiError("no GitHub token: set GH_TOKEN or run `gh auth login`"))
    _AUTH[] = GitHub.authenticate(String(tok))
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
    rd = load_read()
    out = OrderedDict{String,Any}[]
    for repo in repos
        rows = try
            api_paged("/repos/$repo/issues"; params = Dict{String,Any}(
                "since" => since, "state" => "all", "sort" => "updated", "direction" => "asc"))
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

end # module Events
