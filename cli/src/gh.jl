# GitHub, over HTTP.jl: the GraphQL lanes, and the one request everything
# else here - REST reads and writes alike - goes through.
#
# One client, and not `gh` or GitHub.jl, because a subprocess per request does
# not trim and neither does MbedTLS, and because GitHub.jl has no GraphQL - so
# there used to be two of everything: two transports, two retry policies, two
# ways a request failed. What `gh` was kept for was its credentials, and those
# are still asked of it: `gh auth token` is the last place `token` looks.

"""A lane could not be fetched. Fatal for the lanes; a by-url fetch that fails
keeps the rows it was refreshing as they were."""
struct FetchError <: Exception
    msg::String
end
Base.showerror(io::IO, e::FetchError) = print(io, e.msg)

"""A request GitHub refused or never answered, as one line: `HTTP 403: …`
with GitHub's own `message`, or the transport's error. Callers that can
carry on without the answer catch this one and nothing else."""
struct ApiError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ApiError) = print(io, e.msg)

"Overridable so the source order can be tested without a real sandbox."
const TOKEN_FILE = Ref("/run/claudebox-github/token")

"`gh auth token`'s answer, once had: it is a subprocess, and the rest are reads."
const GH_TOKEN = Ref("")

"""
    token() -> (token, source)

Find a GitHub token, in order of decreasing authority.

The sandbox host keeps `TOKEN_FILE` refreshed, so it beats the environment,
which can hold a stale copy of an expired token. `gh auth token` comes last but
matters most off the sandbox: there `gh` keeps its credential in its own config
or the system keyring and exports nothing, so `gh auth status` succeeds while
`GH_TOKEN` is unset - which looked like a broken tool rather than a missing
lookup.

Asked on every request rather than once a process, because the file is
refreshed under a browser that stays open for days; only `gh`'s answer is
kept, since asking it is a spawn. `gh` is looked for before it is run, for the
reason `hermetic` empties `PATH`: a failed spawn leaves handles behind.
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
    if isempty(GH_TOKEN[]) && Sys.which("gh") !== nothing
        GH_TOKEN[] = try
            String(strip(read(`gh auth token`, String)))
        catch
            ""
        end
    end
    isempty(GH_TOKEN[]) || return (GH_TOKEN[], "gh auth token")
    throw(ApiError("no GitHub token. Tried $f, \$GH_TOKEN, \$GITHUB_TOKEN and " *
                   "`gh auth token`. Run `gh auth login`, or set GH_TOKEN."))
end

const API = "https://api.github.com"

"A path segment or a query value, percent-encoded: a label can hold spaces and colons."
uri_escape(s::AbstractString) =
    join(c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~" ?
         string(c) : join(string("%", uppercase(string(b, base = 16, pad = 2)))
                          for b in codeunits(string(c)))
         for c in String(s))

"""
    github(method, path; params, body, accept, tok) -> (rc, text, err, date)

One request to GitHub, which is every request this program makes of it.
`path` is under `API`, or a whole url GitHub handed back. `params` is the
query string, `body` is sent as JSON - a string as it is, being JSON already - and `tok` is the token when it is not
`token()`'s - see `Events.pat`.

Answers rather than throws, in the shape `gh` answered in, because what
callers do with a failure differs: `rc` is `0` for a 2xx, the status for any
other, and `1` when there was no response - no token, or the transport's
error - and `err` then says why in a line, GitHub's `message` included.
`date` is the response's `Date` header, `""` without one.

No retries and no status exceptions from HTTP.jl: the one retry policy is
`retry_wait`'s, applied by `retrying`. The default protocol, which is HTTP/2
by ALPN: trimmed, an HTTP/1.1 request with a body hangs (TODO, *Upstream*).
"""
function github(method::AbstractString, path::AbstractString;
                params = nothing, body = nothing,
                accept::AbstractString = "application/vnd.github+json",
                tok::Union{Nothing,AbstractString} = nothing)
    t = if tok === nothing
        try
            token()[1]
        catch e
            e isa ApiError || rethrow()
            return (1, "", e.msg, "")
        end
    else
        String(tok)
    end
    url = startswith(path, "https://") ? String(path) : string(API, path)
    if params !== nothing && !isempty(params)
        url = string(url, occursin('?', url) ? "&" : "?",
                     join((string(uri_escape(string(k)), "=", uri_escape(string(v)))
                           for (k, v) in params), "&"))
    end
    hdrs = ["Authorization" => "Bearer $t", "Accept" => String(accept),
            "User-Agent" => "worklog", "X-GitHub-Api-Version" => "2022-11-28"]
    body === nothing || push!(hdrs, "Content-Type" => "application/json")
    r = try
        HTTP.request(String(method), url, hdrs,
                     body === nothing ? nothing : body isa AbstractString ? String(body) : json_dumps(body);
                     status_exception = false, retry = false, cookies = false)
    catch e
        e isa InterruptException && rethrow()
        return (1, "", first(sprint(showerror, e), 300), "")
    end
    text = String(r.body)
    date = String(HTTP.header(r, "Date", ""))
    200 <= r.status < 300 && return (0, text, "", date)
    msg = try
        jstr(JSON.parse(text), :message, "")
    catch
        ""
    end
    (Int(r.status), text,
     string("HTTP ", r.status, ": ", first(isempty(msg) ? strip(text) : msg, 300)), date)
end

"""
    retrying(f) -> (rc, text, err, …)

`f()` again, while what it failed with is worth another try: `retry_wait`
says so, and how long. `f` answers as `github` does. For reads only - a POST
that failed after GitHub acted on it would act twice.
"""
function retrying(f)
    for attempt in 0:6
        res = f()
        res[1] == 0 && return res
        err = first(isempty(res[3]) ? res[2] : res[3], 200)
        w = attempt == 6 ? nothing : retry_wait(err, attempt)
        w === nothing && return res
        # Said before the wait and not after it. On the 5xx schedule that
        # is a nicety; on the other one the wait is minutes, and a refresh
        # that goes silent for four of them looks wedged.
        @printf(report(), "    retry %d in %ds after: %s\n",
                attempt + 1, round(Int, w), strip(err))
        sleep(w)
    end
    error("unreachable")
end

"""
    rest(method, path; params, body, accept, tok) -> (value, date)

A REST request that has to have succeeded: the parsed JSON - or the text,
for an `accept` that is not JSON - and the `Date` header, or an `ApiError`.
A GET is retried as the lanes' pages are; a write is sent once.
"""
function rest(method::AbstractString, path::AbstractString; params = nothing, body = nothing,
              accept::AbstractString = "application/vnd.github+json",
              tok::Union{Nothing,AbstractString} = nothing)
    ask() = github(method, path; params = params, body = body, accept = accept, tok = tok)
    rc, text, err, date = method == "GET" ? retrying(ask) : ask()
    rc == 0 || throw(ApiError(err))
    v = !endswith(accept, "json") ? text : isempty(strip(text)) ? nothing : JSON.parse(text)
    (v, date)
end

"""`POST /graphql` with a JSON body already made, answering as `github`
does less the date: the one transport under `search` and `gh_graphql`, and
the argument a test hands `search` in its place."""
graphql_run(body::AbstractString) = github("POST", "/graphql"; body = body)[1:3]

# **`mergeable` is not asked for, anywhere.** GitHub computes it lazily, and
# asking is what schedules the computation - measured on the `mine` lane, a page
# that names it took 20-33s on four runs in twelve and 5-8s on the rest, and a
# page that does not never left 5-8s in twenty-five. It is the one field in
# these selections that is slow to *compute* rather than to fetch, and it is
# refetched when the item is opened anyway: `merge_state` asks for one pull
# request at a time, which is when the answer is wanted and the one time the
# computation is worth waiting for. `statusCheckRollup` is computed too, and
# was measured the same way: free.
#
# `reviewRequests` is not asked for either. The standing bool it produced had
# no reader once the request became a time - see `review_requested_at` - and
# the metadata pane lists who is asked from the REST head it already fetches.
const PR_FIELDS = "\n" * """
      url number title isDraft createdAt updatedAt state
      headRefName headRefOid baseRefName baseRefOid
      headRepository { nameWithOwner }
      mergedBy { login }
      repository { nameWithOwner }
      author { login }
      reviewDecision
      milestone { title dueOn }
      assignees(first: 10) { nodes { login } }
      labels(first: 20) { nodes { name } }
      commits(last: 1) { nodes { commit {
        committedDate
        author { user { login } }
        committer { user { login } }
        statusCheckRollup { state }
      } } }
      reviewThreads(first: 100) { nodes { isResolved isOutdated } }
      timelineItems(last: 50, itemTypes: [REVIEW_REQUESTED_EVENT, REVIEW_DISMISSED_EVENT, ASSIGNED_EVENT,
                                          CLOSED_EVENT, MERGED_EVENT, REOPENED_EVENT]) {
        nodes {
          __typename
          ... on ReviewRequestedEvent { createdAt actor { login } requestedReviewer { ... on User { login } ... on Team { slug } } }
          ... on ReviewDismissedEvent { createdAt actor { login } }
          ... on AssignedEvent { createdAt actor { login } assignee { ... on User { login } } }
          ... on ClosedEvent { createdAt actor { login } }
          ... on MergedEvent { createdAt actor { login } }
          ... on ReopenedEvent { createdAt actor { login } }
        } }
      comments(last: 1) { nodes { author { login } createdAt } }
      reviews(last: 20) { nodes { author { login } state submittedAt } }
"""

const ISSUE_FIELDS = "\n" * """
      url number title createdAt updatedAt state
      repository { nameWithOwner }
      author { login }
      milestone { title dueOn }
      assignees(first: 10) { nodes { login } }
      labels(first: 20) { nodes { name } }
      timelineItems(last: 30, itemTypes: [ASSIGNED_EVENT, CLOSED_EVENT, REOPENED_EVENT]) {
        nodes {
          __typename
          ... on AssignedEvent { createdAt actor { login } assignee { ... on User { login } } }
          ... on ClosedEvent { createdAt actor { login } }
          ... on ReopenedEvent { createdAt actor { login } }
        } }
      comments(last: 1) { nodes { author { login } createdAt } }
"""

# Both inline fragments are required even when a lane is `is:pr`: a search
# that returns an Issue against a selection spreading only
# `... on PullRequest` yields a bare `{__typename: "Issue"}` stub, with no
# fields and no error, and an `is:issue` lane comes back as husks.

const QUERY = "\n" * """
query(\$q: String!, \$cursor: String) {
  rateLimit { cost remaining }
  search(query: \$q, type: ISSUE, first: 50, after: \$cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on PullRequest {
""" * PR_FIELDS * "\n" * """      }
      ... on Issue {
""" * ISSUE_FIELDS * "\n" * """      }
    }
  }
}
"""

"""
    item_url(text) -> canonical url, or nothing

The one issue or pull request a pasted string names, or `nothing` when it names
none. Everything after a `#` or a `?` goes, so the url copied off a comment
anchor or out of the files tab is the same item as the url copied off the title;
`/pulls/` becomes `/pull/`, which is what `resource` will answer to.

It is also the guard on what reaches the query, which is why it is a whitelist
rather than a trim: these urls come out of `local.toml`, which is a file the
user edits, and they are interpolated into GraphQL as literals.
"""
function item_url(text::AbstractString)
    t = replace(strip(String(text)), r"[#?].*$" => "")
    m = match(r"^(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(pull|pulls|issues)/(\d+)/?", t)
    m === nothing && return nothing
    string("https://github.com/", m[1], "/", m[2],
           m[3] == "issues" ? "/issues/" : "/pull/", m[4])
end

"""Items by url, in one request: what no lane can return.

`search` cannot do this at all - a url is not a query, and an item in a repo
nobody watches matches no lane by construction, which is exactly why it had to
be asked for by hand. `resource` is GraphQL's lookup by url and takes the same
two shapes the lanes already select, so what comes back normalizes identically.

One aliased field per url rather than a request each: this runs on every refresh
once anything has been imported, and a request per row is the thing the rest of
this file exists to avoid. A url that names nothing - deleted, or moved to a
repository you cannot see - comes back null and is skipped rather than thrown,
because one dead import must not cost the refresh the live ones.

`fetch_url_map` is the same request answered *by the url asked*: `nothing` for
one that named nothing, and the node for the rest - which carries its own
`url`, and that is not always the one asked. `resource` follows a redirect, so
a repository that was renamed or an issue that was transferred answers under
its new name, and only the map can say which asked url it was.
"""
function fetch_url_map(urls; per::Int = 40)
    out = OrderedDict{String,Any}()
    for u in urls
        c = item_url(u)
        c === nothing || (out[c] = nothing)
    end
    us = collect(keys(out))
    isempty(us) && return out
    # A request per forty, not one for all: the carried rows can be many on
    # the day something big closes, and a query naming two hundred resources
    # with these selections is past what the endpoint will take in one body.
    if length(us) > per
        for i in 1:per:length(us)
            merge!(out, fetch_url_map(us[i:min(i + per - 1, end)]; per = per))
        end
        return out
    end
    parts = [string("  r", i, ": resource(url: ", json_dumps(u), ") {\n",
                    "    __typename\n    ... on PullRequest {", PR_FIELDS, "    }\n",
                    "    ... on Issue {", ISSUE_FIELDS, "    }\n  }\n")
             for (i, u) in enumerate(us)]
    q = string("query {\n  rateLimit { cost remaining }\n", join(parts), "}\n")
    rc, o, e = retrying(() -> graphql_run(json_dumps(["query" => q])))
    rc == 0 || throw(FetchError("GraphQL failed for $(length(us)) urls: " *
                                first(isempty(e) ? o : e, 300)))
    d = JSON.parse(o)
    # An error with data beside it is one slot GitHub would not answer - a
    # resource behind SAML is the known case - and that slot is unanswered,
    # not the batch failed: forty rows kept as they were for one url that
    # cannot be seen would be forty rows frozen for as long as it stays in
    # the ask. Errors with no data at all are the request failing.
    data = jobj(d, :data)
    errs = jlist(d, :errors)
    if !isempty(errs)
        data === nothing &&
            throw(FetchError("GraphQL errors: " * first(json_dumps(errs), 500)))
        @printf(warning(), "    by url: %d of %d not answered: %s\n", length(errs),
                length(us), first(json_dumps(errs), 200))
    end
    for (i, u) in enumerate(us)
        n = jobj(data, Symbol("r", i))
        # Null for a url that resolves to nothing, and field-less for one that
        # resolves to something else - a discussion, a commit, a repository.
        jstr(n, :url) === nothing && continue
        out[u] = n
    end
    out
end

fetch_urls(urls; per::Int = 40) =
    Any[n for n in values(fetch_url_map(urls; per = per)) if n !== nothing]

"One item by url. Throws when there is nothing there to have."
function fetch_url(url::AbstractString)
    ns = fetch_urls([url])
    isempty(ns) && throw(FetchError("no issue or pull request at $url"))
    ns[1]
end

"""One GraphQL document, with variables. Returns `data`, or throws.

What REST cannot reach comes through here: a pending review - appending a
thread to one and submitting it are mutations and nothing else - the draft
flag, the checks. Not retried: a mutation that failed after GitHub acted on it
would act twice.
"""
function gh_graphql(query::AbstractString; vars = Dict{String,Any}())
    body = json_dumps(["query" => String(query), "variables" => vars])
    rc, out, err = graphql_run(body)
    rc == 0 || throw(FetchError(first(isempty(err) ? out : err, 300)))
    d = JSON.parse(out)
    errs = jlist(d, :errors)
    isempty(errs) || throw(FetchError(first(json_dumps(errs), 400)))
    jobj(d, :data)
end

"""How long to wait before trying this failure again, or `nothing` to give up.

Two classes, and they want waits an order of magnitude apart.

A **5xx** from the GraphQL endpoint is the endpoint having a moment. Long
paginations hit them reliably and a second or two is enough, so it backs off to
half a minute across all seven attempts.

A **secondary rate limit** is GitHub saying, in as many words, that you asked
for too much too fast. It is not the hourly quota - `rateLimit.remaining` was
5000 of 5000 while this was being returned - and it clears in minutes rather
than seconds, so retrying it on the 5xx schedule spends every attempt inside
the window and reports failure anyway. That is exactly what a cold start did:
every lane is a burst, and on a cold start there is no previous copy behind
any of them to fall back to, so five lanes came back empty and the dashboard
was a third of its size. Three attempts at a minute, two and four -
seven minutes of waiting at worst, and then it really has failed.

Deliberately *not* the primary rate limit. That is the hourly quota, it is on
every response as `rateLimit.remaining`, and a refresh that has run out of it
has to say come back later rather than sleep out the rest of the hour.
"""
function retry_wait(err::AbstractString, attempt::Int)
    if occursin("secondary rate limit", lowercase(err))
        return attempt <= 2 ? min(60.0 * 2.0^attempt, 300.0) : nothing
    end
    any(occursin(c, err) for c in TRANSIENT) && return min(2.0^attempt, 30.0)
    nothing
end

"""What a page failure looks like when the endpoint, not the request, is at
fault.

`unexpected end of JSON input` is what `gh`, which these went through until
2026-09, said when the body stopped early, which is a truncated response and not something a different query would fix - the lane it
kept failing on (`commented_pr`, ~400 results) succeeded on its own a minute
later with the same string. It was invisible until the failure line stopped
spending its width re-printing the query: the row said `unexpected ` and then
ran out.
"""
const TRANSIENT = ("502", "503", "504", "timeout", "unexpected end of JSON input")

"""
    search(q; cap=1000, query=QUERY) -> (nodes, points, total)

Paginate one search lane.

**The pages are cut by creation time, not by offset.** GraphQL's `after:`
cursor is an offset over the result set as it stands at each request, and an
`is:open` set does not hold still for the fifteen seconds of a walk: a pull
request of yours that closes leaves from ahead of the cursor, the rows behind
it shift up, and the first row of the next page lands on the page already
read - and a close with a reopen or a fresh open beside it leaves `issueCount`
where it was, so no count can tell. Creation time never moves. So every
request is the *first* page of `q created:>=<created of the last row read>`,
ordered `sort:created-asc`, and the boundary is a stamp this walk holds, not
a place in a list the set can shift under. A close between two requests
cannot move it; a reopen behind it is next run's, as it always was. The ask
is `>=` so a tie on the second is never stepped past, and the repeat is
dropped by url.

**A whole page inside one second** - fifty pull requests a script opened at
once - is the one place `>=` cannot advance: the next ask would return the
same page. That second is a bounded set, so it is drained by offset within
the exact-second window, `created:X..X`, where a close can at worst shift a
row of that second, and the walk then continues from `created:>X`. Not a
loop that can stall: the window is drained page by page until it has no
next page, and the floor moves past it.

A query without `sort:created-asc` walks by `after:` as before, with the
caveat above - and so does one that carries a `created:` qualifier of its
own, because GitHub **ors** two qualifiers on one field: `q created:>=X`
would then be `q`'s whole set again, the floor would never narrow it, and
the walk would never end. Every loop below has a page budget besides, so a
page of nothing - null nodes, or empty with a next page - ends the walk
with what it has rather than asking again forever.
"""
function search(q::AbstractString; cap::Int = 1000, query::AbstractString = QUERY,
                run = graphql_run)
    out = Any[]
    seen = Set{String}()
    # Refs, since the closures below add to them: a captured variable that is
    # assigned again is boxed, and every read of it is then untyped.
    spent = Ref(0)
    total = Ref(0)
    keyset = occursin("sort:created-asc", q) && !occursin("created:", q)
    budget = cap ÷ 50 + 8               # requests, all loops together
    spent_pages = Ref(0)
    # One page of `ask` after `cursor`: the retry loop, the errors, the cost.
    function page(ask, cursor)
        spent_pages[] += 1
        body = json_dumps(["query" => query,
                           "variables" => ["q" => ask, "cursor" => cursor]])
        # Long paginations reliably hit transient 5xx from the GraphQL
        # endpoint, and a whole refresh is enough requests in a burst to be
        # told so. Retry the page rather than losing the refresh.
        rc, stdout_, e = retrying(() -> run(body))
        rc == 0 || throw(FetchError("GraphQL failed for $(repr(q)): " *
                                    first(isempty(e) ? stdout_ : e, 200)))
        d = JSON.parse(stdout_)
        errs = jlist(d, :errors)
        isempty(errs) ||
            throw(FetchError("GraphQL errors for $(repr(q)): " *
                             first(json_dumps(errs), 2000)))
        data = jobj(d, :data)
        spent[] += jint(jobj(data, :rateLimit), :cost, 0)
        jobj(data, :search)
    end
    # Where the next page starts, or `nothing` on the last one.
    function next_cursor(s)
        p = jobj(s, :pageInfo)
        jbool(p, :hasNextPage, false) ? jstr(p, :endCursor) : nothing
    end
    # Collect a page's rows; the newest `createdAt` on it, seen or not.
    function take!(s)
        last_ = ""
        for n in jlist(s, :nodes)
            # A stub with no `url` is the Issue-against-a-PR-only-fragment case
            # above; it carries nothing usable, so drop it rather than
            # normalising a record with no fields.
            u = jstr(n, :url)
            u === nothing && continue
            last_ = jstr(n, :createdAt, last_)
            u in seen && continue
            push!(seen, u)
            push!(out, n)
        end
        last_
    end
    done() = length(out) >= cap || spent_pages[] >= budget
    cut() = (out[1:min(cap, length(out))], spent[], total[])

    if !keyset
        cursor = nothing
        while true
            s = page(q, cursor)
            take!(s)
            cursor === nothing && (total[] = jint(s, :issueCount, 0))
            cursor = next_cursor(s)
            (cursor === nothing || done()) && return cut()
        end
    end
    floor_, strict = "", false
    while true
        ask = isempty(floor_) ? q : string(q, " created:", strict ? ">" : ">=", floor_)
        s = page(ask, nothing)
        last_ = take!(s)
        isempty(floor_) && (total[] = jint(s, :issueCount, 0))
        (next_cursor(s) === nothing || done()) && return cut()
        isempty(last_) && return cut()       # nothing on it to cut by
        if last_ == floor_
            # The whole page is the floor's own second: drain it by offset.
            cursor = nothing
            while true
                t = page(string(q, " created:", floor_, "..", floor_), cursor)
                take!(t)
                cursor = next_cursor(t)
                (cursor === nothing || done()) && break
            end
            done() && return cut()
            strict = true
        else
            floor_, strict = last_, false
        end
    end
end
