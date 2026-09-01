# Edit state.toml safely.
#
# Line-based on purpose: it rewrites only the keys you name, inside only the
# block you name, and leaves every other block, comment and blank line
# byte-identical. A TOML round-trip library would reformat the whole file and
# lose the comments - and Julia's `TOML.print` in particular reorders tables and
# drops every comment in the file, which here are the instructions the user
# wrote for themselves.

const STATE = joinpath(ROOT, "state.toml")
const FIELDS = ["agent_task", "blocked_on", "bucket", "deadline", "note", "snooze", "track"]
const ALIAS = Dict("agent" => "agent_task", "blocked" => "blocked_on")
const TRACK = ("close", "normal", "loose", "background")

"A message for the user and a non-zero exit, the way `sys.exit(str)` behaved."
struct CliError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CliError) = print(io, e.msg)
die(msg) = throw(CliError(msg))

"Accept a full URL, owner/repo#N, repo#N, or #N (Julia)."
function resolve(ref::AbstractString)
    startswith(ref, "http") && return String(rstrip(ref, '/'))
    facts = joinpath(ROOT, "facts.json")
    isfile(facts) || die("no facts.json yet - run `wl refresh` first")
    items = JSON3.read(read(facts, String)).items
    occursin('#', ref) || die("cannot parse ref '$ref'")
    i = findlast('#', ref)
    repo, num = ref[1:prevind(ref, i)], ref[nextind(ref, i):end]
    hits = String[]
    for (u, r) in pairs(items)
        string(r.number) == num || continue
        (isempty(repo) || r.repo == repo || split(r.repo, '/')[end] == repo) || continue
        push!(hits, String(u))
    end
    isempty(hits) && die("no tracked item matches '$ref'")
    length(hits) > 1 && die("ambiguous '$ref':\n  " * join(hits, "\n  "))
    hits[1]
end

load_lines() = isfile(STATE) ? String.(splitlines(read(STATE, String))) : String[]

"""Line range of the `[\"url\"]` table, as `(header, first_line_after)`, or
`nothing`. The body is `lines[header+1:after-1]`."""
function block_span(lines, url)
    header = "[\"$url\"]"
    i = findfirst(l -> strip(l) == header, lines)
    i === nothing && return nothing
    j = i + 1
    while j <= length(lines) && !startswith(lstrip(lines[j]), "[")
        j += 1
    end
    (i, j)
end

fmt(v::AbstractVector) = "[" * join((json_dumps(x) for x in v), ", ") * "]"
fmt(v) = json_dumps(v)

function set_fields(url::AbstractString, updates)
    lines = load_lines()
    span = block_span(lines, url)
    if span === nothing
        if !isempty(lines) && !isempty(strip(lines[end]))
            push!(lines, "")
        end
        push!(lines, "[\"$url\"]")
        for (k, v) in updates
            v === nothing || push!(lines, "$k = $(fmt(v))")
        end
        write(STATE, join(lines, "\n") * "\n")
        return "added"
    end
    i, j = span
    body = lines[i+1:j-1]
    for (k, v) in updates
        pat = Regex("^\\s*\\Q" * k * "\\E\\s*=")
        body = [b for b in body if match(pat, b) === nothing]
        v === nothing || push!(body, "$k = $(fmt(v))")
    end
    # An emptied block is removed entirely rather than left as a bare header.
    keep = [b for b in body if !isempty(strip(b))]
    new = vcat(lines[1:i-1], isempty(keep) ? String[] : vcat([lines[i]], keep), lines[j:end])
    write(STATE, rstripnl(join(new, "\n")) * "\n")
    isempty(keep) ? "cleared" : "updated"
end

"Drop any armed fingerprint so a re-snooze re-arms from the current state."
function disarm(url::AbstractString)
    f = joinpath(ROOT, "snooze.json")
    isfile(f) || return
    d = Dict{String,Any}(String(k) => v for (k, v) in JSON3.read(read(f, String)))
    if haskey(d, url)
        delete!(d, url)
        write(f, json_dumps(d; indent = 1, sortkeys = true))
    end
    nothing
end

"""Hand back the next slice of untagged backlog, oldest-unseen first.

Pull, never push: nothing from the backlog reaches the dashboard on its own. You
ask for work when you want it. Items you have already tagged in state.toml are
considered triaged and never come back here.
"""
function next_batch(n::Int)
    facts = joinpath(ROOT, "facts.json")
    isfile(facts) || die("no facts.json yet - run `wl refresh` first")
    items = JSON3.read(read(facts, String)).items
    state = load_state()
    seenp = joinpath(ROOT, "queue.json")
    seen = isfile(seenp) ?
           Dict{String,Any}(String(k) => v for (k, v) in JSON3.read(read(seenp, String))) :
           Dict{String,Any}()
    filter!(p -> haskey(items, Symbol(p.first)), seen)

    pool = String[String(u) for (u, r) in pairs(items)
                  if truthy(jget(r, :backlog)) && !truthy(jget(r, :snoozed)) &&
                     !truthy(get(state, String(u), nothing))]
    if isempty(pool)
        println("backlog is fully triaged")
        return 0
    end
    function last_activity(u)
        r = items[Symbol(u)]
        c = [t for t in (jget(r, :head_at), jget(r, :last_comment_at)) if truthy(t)]
        isempty(c) ? String(r.updated) : maximum(String(x) for x in c)
    end
    areas = Set{String}(get(TOML.parse(read(joinpath(ROOT, "config.toml"), String))["firehose"],
                            "areas", String[]))
    # Never-shown first; then your areas, so a thousand-PR pile still hands you
    # the relevant end of it; then quietest first.
    rank(u) = (String(get(seen, u, "")),
               !any(in(areas), jget(items[Symbol(u)], :labels, ())),
               last_activity(u), u)
    sort!(pool; by = rank)
    batch = first(pool, n)
    @printf("%d untagged backlog items (%d shown)\n\n", length(pool), length(batch))
    for u in batch
        r = items[Symbol(u)]
        ref = "$(split(r.repo, '/')[end])#$(r.number)"
        hit = sort(String[l for l in jget(r, :labels, ()) if l in areas])
        @printf("%-22s %-8s %s\n", ref, r.bucket, first(String(r.title), 74))
        isempty(hit) || @printf("%-22s %s\n", "", join(hit, ", "))
        @printf("%-22s %s\n\n", "", u)
        seen[u] = string(Dates.today())
    end
    write(seenp, json_dumps(seen; indent = 1, sortkeys = true))
    println("tag each:  wl dismiss <ref> | track <ref> loose | note <ref> \"...\" | snooze <ref> <date>")
    0
end
