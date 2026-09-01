# CI status, and Buildkite drill-down.
#
# The rollup on an item is one word - FAILURE tells you nothing about which of
# sixty jobs broke. GitHub's checks give per-context state, and for Julia the
# interesting ones point at Buildkite, whose build page frontend serves two
# JSON endpoints anonymously. That is enough to name the failing jobs and pull
# their logs without a sign-in.

"Per-check state for an item's head commit. Cached: this is three API calls."
function check_contexts(repo::AbstractString, number::Integer; ttl = 120.0)
    key = string("checks:", repo, "#", number)
    hit = cache_get(key, ttl)
    hit === nothing || return hit[1]
    owner, name = split(String(repo), '/')
    q = """
    query(\$owner:String!,\$name:String!,\$num:Int!) {
      repository(owner:\$owner, name:\$name) {
        pullRequest(number:\$num) {
          commits(last:1) { nodes { commit { statusCheckRollup {
            state
            contexts(first:100) { nodes {
              __typename
              ... on CheckRun { name conclusion status detailsUrl }
              ... on StatusContext { context state targetUrl }
            } }
          } } } }
        }
      }
    }"""
    out = try
        d = JSON3.read(read(pipeline(`gh api graphql -F owner=$owner -F name=$name
                                      -F num=$number -F query=@-`; stdin = IOBuffer(q)), String))
        roll = d.data.repository.pullRequest.commits.nodes[1].commit.statusCheckRollup
        roll === nothing ? (state = "NONE", contexts = []) :
            (state = String(roll.state),
             contexts = [(name = String(get(c, :name, get(c, :context, "?"))),
                          state = String(something(get(c, :conclusion, nothing),
                                                   get(c, :state, "?"))),
                          url = String(something(get(c, :detailsUrl, nothing),
                                                 get(c, :targetUrl, nothing), "")))
                         for c in roll.contexts.nodes])
    catch e
        (state = "ERROR", contexts = [(name = "could not fetch checks",
                                       state = first(sprint(showerror, e), 120), url = "")])
    end
    cache_put(key, out)
    out
end

"`(pipeline, build)` for a Buildkite URL, or nothing."
function bk_parse(url::AbstractString)
    m = match(r"buildkite\.com/([^/]+)/([^/]+)/builds/(\d+)", String(url))
    m === nothing ? nothing : (org = String(m[1]), pipeline = String(m[2]), build = String(m[3]))
end

function _curl_json(url)
    out = read(`curl -sS -H "Accept: application/json" $url`, String)
    JSON3.read(out)
end

"""Every job in a build.

Uses the build page's own /data/jobs endpoint. `builds/<n>.json` looks like the
obvious choice and is a trap: anonymously it returns build metadata with an
empty jobs array, so job discovery through it silently finds nothing.
"""
function bk_jobs(b; ttl = 300.0)
    key = string("bkjobs:", b.org, "/", b.pipeline, "/", b.build)
    hit = cache_get(key, ttl)
    hit === nothing || return hit[1]
    out = try
        d = _curl_json("https://buildkite.com/$(b.org)/$(b.pipeline)/builds/$(b.build)/data/jobs")
        [(name = String(get(j, :name, "?")), state = String(get(j, :state, "?")),
          exit = something(get(j, :exit_status, nothing), ""),
          id = String(get(j, :id, ""))) for j in d.records]
    catch e
        NamedTuple[]
    end
    cache_put(key, out)
    out
end

bk_failed(jobs) = [j for j in jobs
                   if j.state in ("failed", "broken", "timed_out") ||
                      (j.exit isa Integer && j.exit != 0)]

"""Tail of a job's log.

The payload is HTML: ANSI colour as spans, and a <time> element per line whose
text is a timestamp. Dropping the time elements first matters - stripping tags
blindly glues the timestamp onto the log text.
"""
function bk_log(b, uuid::AbstractString; tail::Int = 300, ttl = 900.0)
    key = string("bklog:", b.org, "/", b.pipeline, "/", b.build, "/", uuid)
    hit = cache_get(key, ttl)
    txt = if hit === nothing
        t = try
            d = _curl_json("https://buildkite.com/organizations/$(b.org)/pipelines/" *
                           "$(b.pipeline)/builds/$(b.build)/jobs/$uuid/log")
            String(get(d, :output, ""))
        catch e
            "could not fetch log: " * first(sprint(showerror, e), 120)
        end
        cache_put(key, t)
        t
    else
        String(hit[1])
    end
    s = replace(txt, r"<time[^>]*>.*?</time>"s => "")
    s = replace(s, r"<[^>]+>" => "")
    s = unescape_html(s)
    lines = split(s, "\n")
    length(lines) <= tail ? String(s) :
        string("… ", length(lines) - tail, " earlier lines omitted …\n",
               join(lines[end-tail+1:end], "\n"))
end
