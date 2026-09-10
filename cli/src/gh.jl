# The GraphQL half of the fetch.
#
# `gh api graphql --input -` rather than a Julia HTTP client on purpose:
# GitHub.jl exports no GraphQL and no search (checked: 151 exports, none of
# them either), and the value here is not the transport, it is `gh`'s already
# working credentials. The REST half genuinely does use GitHub.jl - see
# events.jl.

"""A lane could not be fetched. Fatal for the active lanes, survivable for the
bulk ones, which fall back to their previous cached contents."""
struct FetchError <: Exception
    msg::String
end
Base.showerror(io::IO, e::FetchError) = print(io, e.msg)

const PR_FIELDS = "\n" * """
      url number title isDraft createdAt updatedAt state
      headRefName
      mergedBy { login }
      repository { nameWithOwner }
      author { login }
      reviewDecision
      mergeable
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      commits(last: 1) { nodes { commit {
        committedDate
        statusCheckRollup { state }
      } } }
      reviewThreads(first: 100) { nodes { isResolved isOutdated } }
      comments(last: 1) { nodes { author { login } createdAt } }
      reviews(last: 20) { nodes { author { login } state submittedAt } }
"""

const ISSUE_FIELDS = "\n" * """
      url number title createdAt updatedAt state
      repository { nameWithOwner }
      author { login }
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      comments(last: 1) { nodes { author { login } createdAt } }
"""

# The firehose is ~1000 PRs, so it drops the expensive nested connections
# (review threads, review history, comments). Background items are never
# bucketed on those fields, and shedding them buys 100 nodes/page at 2 points.
# `headRefName` stays in both: it is a scalar, it costs nothing, and it is what
# lets a local branch be matched to its pull request without a request per row.
#
# Both inline fragments are required even though most of the bulk lanes are
# `is:pr`: a search that returns an Issue against a selection spreading only
# `... on PullRequest` yields a bare `{__typename: "Issue"}` stub, with no
# fields and no error, and the two `is:issue` lanes come back as husks.
const FIREHOSE_QUERY = "\n" * """
query(\$q: String!, \$cursor: String) {
  rateLimit { cost remaining }
  search(query: \$q, type: ISSUE, first: 100, after: \$cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { __typename ... on PullRequest {
      url number title isDraft createdAt updatedAt state
      headRefName
      repository { nameWithOwner }
      author { login }
      reviewDecision mergeable
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
      comments(last: 1) { nodes { author { login } createdAt } }
    }
    ... on Issue {
      url number title createdAt updatedAt state
      repository { nameWithOwner }
      author { login }
      milestone { title dueOn }
      labels(first: 20) { nodes { name } }
      comments(last: 1) { nodes { author { login } createdAt } }
    } }
  }
}
"""

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
rather than a trim: these urls come out of `state.toml`, which is a file the
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
"""
function fetch_urls(urls)
    us = String[]
    for u in urls
        c = item_url(u)
        c === nothing || push!(us, c)
    end
    isempty(us) && return Any[]
    parts = [string("  r", i, ": resource(url: ", json_dumps(u), ") {\n",
                    "    __typename\n    ... on PullRequest {", PR_FIELDS, "    }\n",
                    "    ... on Issue {", ISSUE_FIELDS, "    }\n  }\n")
             for (i, u) in enumerate(us)]
    q = string("query {\n  rateLimit { cost remaining }\n", join(parts), "}\n")
    rc, o, e = gh_run(["api", "graphql", "--input", "-"], json_dumps(["query" => q]))
    rc == 0 || throw(FetchError("GraphQL failed for $(length(us)) urls: " *
                                first(isempty(e) ? o : e, 300)))
    d = JSON3.read(o)
    haskey(d, :errors) &&
        throw(FetchError("GraphQL errors: " * first(json_dumps(d.errors), 500)))
    out = Any[]
    for i in eachindex(us)
        n = jget(d.data, Symbol("r", i))
        # Null for a url that resolves to nothing, and field-less for one that
        # resolves to something else - a discussion, a commit, a repository.
        (n === nothing || jget(n, :url) === nothing) && continue
        push!(out, n)
    end
    out
end

"One item by url. Throws when there is nothing there to have."
function fetch_url(url::AbstractString)
    ns = fetch_urls([url])
    isempty(ns) && throw(FetchError("no issue or pull request at $url"))
    ns[1]
end

"Run `gh` with `input` on stdin, capturing both streams instead of raising."
function gh_run(args::Vector{String}, input::AbstractString = "")
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(Cmd(["gh"; args]));
                     stdin = IOBuffer(input), stdout = out, stderr = err))
    (p.exitcode, String(take!(out)), String(take!(err)))
end

"""One GraphQL document, with variables. Returns `data`, or throws.

The writes in `events.jl` are REST because GitHub.jl speaks REST, but a pending
review is not reachable that way: appending a thread to one and submitting it
are mutations and nothing else. So they come back through here, which is the
same `gh api graphql` the lanes already run on and the same credentials.
"""
function gh_graphql(query::AbstractString; vars = Dict{String,Any}())
    body = json_dumps(["query" => String(query), "variables" => vars])
    rc, out, err = gh_run(["api", "graphql", "--input", "-"], body)
    rc == 0 || throw(FetchError(first(isempty(err) ? out : err, 300)))
    d = JSON3.read(out)
    haskey(d, :errors) && throw(FetchError(first(json_dumps(d.errors), 400)))
    d.data
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
every lane is a burst, and with `bulk.json` deleted there is no previous copy
behind any of them to fall back to, so five lanes came back empty and the
dashboard was a third of its size. Three attempts at a minute, two and four -
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

`unexpected end of JSON input` is `gh` saying the body stopped early, which is a
truncated response and not something a different query would fix - the lane it
kept failing on (`commented_pr`, ~400 results) succeeded on its own a minute
later with the same string. It was invisible until the failure line stopped
spending its width re-printing the query: the row said `unexpected ` and then
ran out.
"""
const TRANSIENT = ("502", "503", "504", "timeout", "unexpected end of JSON input")

"""
    search(q; cap=1000, query=QUERY) -> (nodes, points, total)

Paginate one search lane.
"""
function search(q::AbstractString; cap::Int = 1000, query::AbstractString = QUERY)
    out = Any[]
    cursor = nothing
    spent = 0
    total = 0
    while true
        body = json_dumps(["query" => query,
                           "variables" => ["q" => q, "cursor" => cursor]])
        local stdout_
        # Long paginations (the firehose is ~10 sequential pages) reliably hit
        # transient 5xx from the GraphQL endpoint, and a whole refresh is enough
        # requests in a burst to be told so. Retry the page rather than losing
        # the refresh.
        for attempt in 0:6
            rc, o, e = gh_run(["api", "graphql", "--input", "-"], body)
            if rc == 0
                stdout_ = o
                break
            end
            err = first(isempty(e) ? o : e, 200)
            wait_ = attempt == 6 ? nothing : retry_wait(err, attempt)
            wait_ === nothing &&
                throw(FetchError("GraphQL failed for $(repr(q)): $err"))
            # Said before the wait and not after it. On the 5xx schedule that is
            # a nicety; on the other one the wait is minutes, and a refresh that
            # goes silent for four of them looks wedged.
            @printf(stderr, "    retry %d in %ds after: %s\n",
                    attempt + 1, round(Int, wait_), strip(err))
            sleep(wait_)
        end
        d = JSON3.read(stdout_)
        if haskey(d, :errors)
            throw(FetchError("GraphQL errors for $(repr(q)): " *
                             first(json_dumps(d.errors), 2000)))
        end
        spent += d.data.rateLimit.cost
        s = d.data.search
        for n in s.nodes
            # A stub with no `url` is the Issue-against-a-PR-only-fragment case
            # above; it carries nothing usable, so drop it rather than
            # normalising a record with no fields.
            n === nothing || jget(n, :url) === nothing || push!(out, n)
        end
        cursor === nothing && (total = s.issueCount)
        if !s.pageInfo.hasNextPage || length(out) >= cap
            return (out[1:min(cap, length(out))], spent, total)
        end
        cursor = String(s.pageInfo.endCursor)
    end
end
