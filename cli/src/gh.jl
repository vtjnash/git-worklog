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
      url number title isDraft createdAt updatedAt
      headRefName
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
      url number title createdAt updatedAt
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
      url number title isDraft createdAt updatedAt
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
      url number title createdAt updatedAt
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
