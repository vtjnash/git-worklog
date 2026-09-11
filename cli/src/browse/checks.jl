
# --- CI checks --------------------------------------------------------------

"""How a check state is drawn. Anything unrecognised gets no colour, which is
the honest answer for a state this program has never seen.

The three verdicts and nothing of its own: a green check is settled, a red one
is blocking, and one still running is being waited on - the same question the
review decision and the mergeable state answer, so the same colours. Cancelled,
skipped and neutral are dim, being the states that say nothing happened.

A function rather than the `Dict` it was, for the reason `rev_mark` is one: a
`Dict` of colours is built when the module loads and the theme is read after.
"""
function ci_color(state::AbstractString)
    s = uppercase(state)
    s == "SUCCESS" ? THEME.settled :
    s in ("FAILURE", "ERROR", "TIMED_OUT") ? THEME.blocked :
    s == "PENDING" ? THEME.waiting :
    s in ("CANCELLED", "SKIPPED", "NEUTRAL") ? THEME.dim : ""
end

"""Checks for an item, with failing Buildkite jobs listed underneath.

A rollup of FAILURE says nothing about which of sixty jobs broke, so each
failing Buildkite build is expanded into its failed jobs, each of which can
pull its own log.
"""
function check_nodes(it::Item)
    it.is_pr || return [Node("no checks - this is an issue, not a pull request",
                             "", :plain, true)]
    c = check_contexts(it.repo, it.number)
    ns = Node[]
    seen_builds = Set{String}()
    for x in c.contexts
        col = ci_color(x.state)
        n = Node(string(col, rpad(x.state, 9), THEME.reset, x.name), "", :plain, false)
        isempty(x.url) || (n.meta["url"] = x.url)
        n.raw = isempty(x.url) ? "" : x.url
        push!(ns, n)

        b = bk_parse(x.url)
        b === nothing && continue
        k = string(b.pipeline, "/", b.build)
        k in seen_builds && continue
        push!(seen_builds, k)
        failed = bk_failed(bk_jobs(b))
        isempty(failed) && continue
        for j in failed
            jn = Node(string(THEME.blocked, rpad(j.state, 10), THEME.reset, j.name,
                             j.exit == "" ? "" : string("  (exit ", j.exit, ")")),
                      "press l to fetch this job's log", :plain, false, 1)
            jn.meta["bk"] = b
            jn.meta["job"] = j.id
            jn.meta["url"] = "https://buildkite.com/$(b.org)/$(b.pipeline)/builds/$(b.build)#$(j.id)"
            push!(ns, jn)
        end
    end
    isempty(ns) ? [Node("no checks reported", "", :plain, true)] : ns
end
