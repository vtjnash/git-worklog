# Edit state.toml safely.
#
# Line-based on purpose: it rewrites only the keys you name, inside only the
# block you name, and leaves every other block, comment and blank line
# byte-identical. A TOML round-trip library would reformat the whole file and
# lose the comments - and Julia's `TOML.print` in particular reorders tables and
# drops every comment in the file, which here are the instructions the user
# wrote for themselves.

"Overridable so a test can write somewhere other than the user's own file."
const STATE = Ref("")
statefile() = isempty(STATE[]) ? datapath("state.toml") : STATE[]
const FIELDS = ["adopted", "archive", "blocked_on", "bucket", "deadline", "note",
                "snooze", "track"]
const ALIAS = Dict("blocked" => "blocked_on")
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
    facts = datapath("facts.json")
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

load_lines() = isfile(statefile()) ? String.(splitlines(read(statefile(), String))) : String[]

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

"""Set (or with a `nothing` value, remove) named keys of one item's block.

Setting a field is an interaction, so this stamps the clock - here rather than
at each caller, because this is the one point every field write passes through:
`v` and `s` in the browser, and every `wl <field>` command. An undo therefore
has to put the previous timestamp back explicitly, since restoring the value
comes back through here and stamps again.

`at` is the operation this write belongs to, so that one keystroke setting a
field and stamping the clock records one instant for both.
"""
function set_fields(url::AbstractString, updates, at::DateTime = utcnow())
    touch!(url, at)
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
        write_atomic(statefile(), join(lines, "\n") * "\n")
        return "added"
    end
    i, j = span
    body = lines[i+1:j-1]
    # The blank line that separates this block from the next one belongs to the
    # block, and a new key must not land on the far side of it. Hold it back,
    # write into what is left, and put it on again - filtering it out instead
    # kept new keys in the right place but took a line out of the user's file on
    # every write, which "edited key-by-key, never rewritten" is meant to rule
    # out.
    tail = 0
    while tail < length(body) && isempty(strip(body[end-tail]))
        tail += 1
    end
    body, blanks = body[1:end-tail], body[end-tail+1:end]
    for (k, v) in updates
        pat = Regex("^\\s*\\Q" * k * "\\E\\s*=")
        body = [b for b in body if match(pat, b) === nothing]
        v === nothing || push!(body, "$k = $(fmt(v))")
    end
    # An emptied block is removed entirely rather than left as a bare header,
    # and its separator goes with it.
    keep = [b for b in body if !isempty(strip(b))]
    new = vcat(lines[1:i-1],
               isempty(keep) ? String[] : vcat([lines[i]], body, blanks),
               lines[j:end])
    write_atomic(statefile(), rstripnl(join(new, "\n")) * "\n")
    isempty(keep) ? "cleared" : "updated"
end

"""Every block's value for one key, in one pass over the file.

`get_field` re-reads and re-scans for a single lookup, which is right for one
and quadratic for a question about every item - and the browser asks two of
those (`adopted`, `archive`) every time it rebuilds the list.

Unquoted the same way `get_field` unquotes, so the two agree about what a value
is.
"""
function field_map(key::AbstractString)
    out = Dict{String,String}()
    url = ""
    pat = Regex("^\\s*\\Q" * key * "\\E\\s*=\\s*(.*?)\\s*\$")
    for l in load_lines()
        h = match(r"^\[\"(.*)\"\]\s*$", strip(l))
        if h !== nothing
            url = String(h[1])
            continue
        end
        isempty(url) && continue
        m = match(pat, l)
        m === nothing || (out[url] = String(strip(String(m[1]), '"')))
    end
    out
end

"""One field of one item's block, as it is written, or `nothing`.

Read out of the file text rather than out of a parse, because a parse cannot
tell an absent key from one set to an empty value - and that is exactly the
distinction an undo needs, between putting a value back and removing the key.
Surrounding quotes are stripped; anything else comes back as written.
"""
function get_field(url::AbstractString, key::AbstractString)
    lines = load_lines()
    span = block_span(lines, url)
    span === nothing && return nothing
    i, j = span
    pat = Regex("^\\s*\\Q" * key * "\\E\\s*=\\s*(.*?)\\s*\$")
    for b in lines[i+1:j-1]
        m = match(pat, b)
        m === nothing || return String(strip(String(m[1]), '"'))
    end
    nothing
end

"""Hand back the next slice of untagged backlog, quietest first.

Pull, never push: nothing from the backlog reaches the dashboard on its own. You
ask for work when you want it. Items you have already tagged in state.toml are
considered triaged and never come back here - and tagging is the only thing that
retires one. It used to keep a `queue.json` of what it had printed and sort that
to the back, which is a fifth file of one fact per url to make asking twice in a
row show two different slices; the tag is the record of having dealt with
something, and there was never a second one worth keeping.
"""
function next_batch(n::Int)
    facts = datapath("facts.json")
    isfile(facts) || die("no facts.json yet - run `wl refresh` first")
    items = JSON3.read(read(facts, String)).items
    state = load_state()
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
    # Your areas first, so a thousand-PR pile still hands you the relevant end
    # of it; then quietest first.
    rank(u) = (!any(in(areas), jget(items[Symbol(u)], :labels, ())),
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
    end
    println("tag each:  wl dismiss <ref> | track <ref> loose | note <ref> \"...\" | snooze <ref> <date>")
    0
end
