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
# Both inline fragments are required even though four of the five bulk lanes are
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
        # transient 5xx from the GraphQL endpoint. Retry the page rather than
        # losing the whole refresh.
        for attempt in 0:6
            rc, o, e = gh_run(["api", "graphql", "--input", "-"], body)
            if rc == 0
                stdout_ = o
                break
            end
            err = first(isempty(e) ? o : e, 200)
            if attempt == 6 || !any(occursin(c, err) for c in ("502", "503", "504", "timeout"))
                throw(FetchError("GraphQL failed for $(repr(q)): $err"))
            end
            sleep(min(2.0^attempt, 30))
            println(stderr, "    retry $(attempt + 1) after: $(strip(err))")
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
