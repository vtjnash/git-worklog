
# --- CI checks --------------------------------------------------------------

const CI_COLOR = Dict("SUCCESS" => "\e[32m", "FAILURE" => "\e[31m", "ERROR" => "\e[31m",
                      "PENDING" => "\e[33m", "TIMED_OUT" => "\e[31m",
                      "CANCELLED" => "\e[2m", "SKIPPED" => "\e[2m", "NEUTRAL" => "\e[2m")

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
        col = get(CI_COLOR, uppercase(x.state), "")
        n = Node(string(col, rpad(x.state, 9), "\e[0m", x.name), "", :plain, false)
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
            jn = Node(string("\e[31m", rpad(j.state, 10), "\e[0m", j.name,
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
