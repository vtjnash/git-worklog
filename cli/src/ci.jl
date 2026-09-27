# CI status, and Buildkite drill-down.
#
# The rollup on an item is one word - FAILURE tells you nothing about which of
# sixty jobs broke. GitHub's checks give per-context state, and for Julia the
# interesting ones point at Buildkite, whose build page frontend serves two
# JSON endpoints anonymously. That is enough to name the failing jobs and pull
# their logs without a sign-in.

"""Per-check state for an item's head commit.

One GraphQL round trip, cached: the metadata pane asks for it every time the
selection moves, and holding `j` down should not be a request per row. `keep`
is how old an entry may be and still be handed back - the caller that passes
one is showing it while a re-read runs behind, and asks `cache_age` which.
"""
checks_key(repo::AbstractString, number::Integer) = string("checks:", repo, "#", number)

function check_contexts(repo::AbstractString, number::Integer; ttl = 120.0, keep = ttl)
    key = checks_key(repo, number)
    hit = cache_get(key, ttl; keep_s = keep)
    hit === nothing || return _checks_shape(hit[1])
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
        # Through `gh_run`, which looks for `gh` before it spawns one: see
        # there for what a failed spawn with a buffer on stdin leaves behind.
        rc, txt, err = gh_run(["api", "graphql", "-F", "owner=$owner", "-F", "name=$name",
                               "-F", "num=$number", "-F", "query=@-"], q)
        rc == 0 || error(first(isempty(err) ? txt : err, 300))
        d = JSON.parse(txt)
        cs = jnodes(jpath(d, :data, :repository, :pullRequest), :commits)
        roll = isempty(cs) ? nothing : jpath(first(cs), :commit, :statusCheckRollup)
        roll === nothing ? (state = "NONE", contexts = []) :
            (state = jstr(roll, :state, ""),
             contexts = [(name = something(jstr(c, :name), jstr(c, :context), "?"),
                          state = something(jstr(c, :conclusion), jstr(c, :state), "?"),
                          url = something(jstr(c, :detailsUrl), jstr(c, :targetUrl), ""))
                         for c in jnodes(roll, :contexts)])
    catch e
        (state = "ERROR", contexts = [(name = "could not fetch checks",
                                       state = first(sprint(showerror, e), 120), url = "")])
    end
    cache_put(key, out)
    _checks_shape(out)
end

"One check of a pull request's head: its name, its state, where it is shown."
const CheckContext = @NamedTuple{name::String, state::String, url::String}

"""What `check_contexts` answers, and what the pane holds as `st.checks`: the
rollup's state and every check under it. A type of its own so that the field
holding it is not `Any`, and every read of it a dynamic call; `checks_of`
makes one, with the defaults a test leaves out."""
const Checks = @NamedTuple{state::String, contexts::Vector{CheckContext}}
checks_of(; state = "", contexts = CheckContext[]) = Checks((state, contexts))

"Both a fresh fetch and a cache hit reach the caller in the same shape."
_checks_shape(v) =
    checks_of(state = jstr(v, :state, ""),
              contexts = CheckContext[
                  (name = jstr(c, :name, "?"), state = jstr(c, :state, "?"),
                   url = jstr(c, :url, ""))
                  for c in jlist(v, :contexts)])

"`(pipeline, build)` for a Buildkite URL, or nothing."
function bk_parse(url::AbstractString)
    m = match(r"buildkite\.com/([^/]+)/([^/]+)/builds/(\d+)", String(url))
    m === nothing ? nothing : (org = String(something(m[1])), pipeline = String(something(m[2])),
                               build = String(something(m[3])))
end

function _curl_json(url)
    out = read(`curl -sS -H "Accept: application/json" $url`, String)
    JSON.parse(out)
end

"""One job of a Buildkite build: `exit` is `nothing` until it has exited.

One type whether the jobs were fetched or read back from the cache, which
kept them as objects: the two used to be a `NamedTuple` and a `JSON.Object`,
read alike only because both answer `j.state`."""
struct BkJob
    name::String
    state::String
    exit::Union{Nothing,Int}
    id::String
end
"A job as the cache kept it. An entry from before `exit` could be null has `\"\"` there."
bk_job(@nospecialize(j)) = BkJob(jstr(j, :name, "?"), jstr(j, :state, "?"), jint(j, :exit),
                                 jstr(j, :id, ""))

"""Every job in a build.

Uses the build page's own /data/jobs endpoint. `builds/<n>.json` looks like the
obvious choice and is a trap: anonymously it returns build metadata with an
empty jobs array, so job discovery through it silently finds nothing.
"""
function bk_jobs(b; ttl = 300.0)::Vector{BkJob}
    key = string("bkjobs:", b.org, "/", b.pipeline, "/", b.build)
    hit = cache_get(key, ttl)
    hit === nothing || return BkJob[bk_job(j) for j in anylist(hit[1])]
    out = try
        d = _curl_json("https://buildkite.com/$(b.org)/$(b.pipeline)/builds/$(b.build)/data/jobs")
        BkJob[BkJob(jstr(j, :name, "?"), jstr(j, :state, "?"), jint(j, :exit_status),
                    jstr(j, :id, "")) for j in jlist(d, :records)]
    catch
        BkJob[]
    end
    cache_put(key, [(name = j.name, state = j.state, exit = j.exit, id = j.id) for j in out])
    out
end

bk_failed(jobs::Vector{BkJob}) = BkJob[j for j in jobs
                                       if j.state in ("failed", "broken", "timed_out") ||
                                          (j.exit !== nothing && j.exit != 0)]

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
            jstr(d, :output, "")
        catch e
            "could not fetch log: " * first(sprint(showerror, e), 120)
        end
        cache_put(key, t)
        t
    else
        v = hit[1]
        v isa AbstractString ? String(v) : ""
    end
    s = replace(txt, r"<time[^>]*>.*?</time>"s => "")
    s = replace(s, r"<[^>]+>" => "")
    s = unescape_html(s)
    lines = split(s, "\n")
    length(lines) <= tail ? String(s) :
        string("… ", length(lines) - tail, " earlier lines omitted …\n",
               join(lines[end-tail+1:end], "\n"))
end
