# Edit `local.toml` safely.
#
# The half of `data/` that is not re-fetchable: what you decided about each
# item, what you have done to it, and where its repo is checked out. Small,
# tracked, and the only thing here that cannot be got again from GitHub - which
# is the whole of why it is one file and `fetched.json` is the other.
#
# One flat namespace of blocks, keyed by what the block is about:
#
#     ["https://github.com/o/r/pull/1"]   an item
#     ["local:o/r#some-branch"]           a branch you adopted, which has no url
#     ["repo:o/r"]                        where that repo is checked out
#
# Inside an item's block, your fields and the marks sit together - `note` and
# `snooze` beside `read` and `touched` - because they are one answer to "what
# is recorded about this item" and were three files pretending to be three
# questions.
#
# Line-based on purpose: it rewrites only the keys you name, inside only the
# block you name, and leaves every other block, comment and blank line
# byte-identical. A TOML round-trip library would reformat the whole file and
# lose the comments - and Julia's `TOML.print` in particular reorders tables and
# drops every comment in the file, which here are the instructions the user
# wrote for themselves.

"Overridable so a test can write somewhere other than the user's own file."
const LOCAL = Ref("")
localfile() = isempty(LOCAL[]) ? datapath("local.toml") : LOCAL[]
# `archive` is not one of them and was: filing something away is a snooze with
# no wake condition, so it is `snooze = "forever"` and there is one field for
# "I do not want to see this", not two that have to be kept in precedence.
const FIELDS = ["adopted", "blocked_on", "bucket", "deadline", "note",
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
    items = fetched("items")
    items === nothing && die("nothing fetched yet - run `wl refresh` first")
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

load_lines() = isfile(localfile()) ? String.(splitlines(read(localfile(), String))) : String[]

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

"""Apply named-key updates to any number of blocks, in one pass over the file.

    set_blocks!([url => ["note" => "x", "snooze" => nothing], other => [...]])

One pass and one write, which is what a mark needs: `wl read` stamps 852 items
at once and a write per item would be a rewrite of the whole file per item.

A block that is not there is appended; a block left with no keys at all is
removed entirely rather than left as a bare header. Nothing is written when
nothing changed - the browser's watch on `data/` would refilter for a no-op
write, and half the callers here set a value that is already there.

Answers with what happened per block: "added", "updated" or "cleared".
"""
function set_blocks!(updates)
    lines = load_lines()
    want = OrderedDict{String,Any}()
    for (k, v) in updates
        want[String(k)] = v
    end
    out, said = String[], Dict{String,String}()
    i, n = 1, length(lines)
    while i <= n
        h = match(r"^\[\"(.*)\"\]\s*$", strip(lines[i]))
        key = h === nothing ? "" : String(h[1])
        if isempty(key) || !haskey(want, key)
            push!(out, lines[i]); i += 1; continue
        end
        j = i + 1
        while j <= n && !startswith(lstrip(lines[j]), "[")
            j += 1
        end
        body = lines[i+1:j-1]
        # The blank line that separates this block from the next one belongs to
        # the block, and a new key must not land on the far side of it. Hold it
        # back, write into what is left, and put it on again - filtering it out
        # instead kept new keys in the right place but took a line out of the
        # user's file on every write, which "edited key-by-key, never rewritten"
        # is meant to rule out.
        tail = 0
        while tail < length(body) && isempty(strip(body[end-tail]))
            tail += 1
        end
        body, blanks = body[1:end-tail], body[end-tail+1:end]
        for (k, v) in want[key]
            pat = Regex("^\\s*\\Q" * k * "\\E\\s*=")
            body = [b for b in body if match(pat, b) === nothing]
            v === nothing || push!(body, "$k = $(fmt(v))")
        end
        keep = [b for b in body if !isempty(strip(b))]
        isempty(keep) || append!(out, vcat([lines[i]], body, blanks))
        said[key] = isempty(keep) ? "cleared" : "updated"
        delete!(want, key)
        i = j
    end
    # Whatever had no block yet, appended in the order it was asked for.
    for (key, ups) in want
        rows = ["$k = $(fmt(v))" for (k, v) in ups if v !== nothing]
        if isempty(rows)
            said[key] = "cleared"
            continue
        end
        (isempty(out) || isempty(strip(out[end]))) || push!(out, "")
        push!(out, "[\"$key\"]")
        append!(out, rows)
        said[key] = "added"
    end
    out == lines || write_atomic(localfile(), rstripnl(join(out, "\n")) * "\n")
    said
end

"""Set (or with a `nothing` value, remove) named keys of one item's block.

Setting a field is an interaction, so this stamps the clock - here rather than
at each caller, because this is the one point every field write passes through:
`v` and `s` in the browser, and every `wl <field>` command. An undo therefore
has to put the previous timestamp back explicitly, since restoring the value
comes back through here and stamps again.

The stamp goes in with the fields rather than through `touch!`, so one keystroke
is one write of one block: `at` is the operation this write belongs to, and the
field and the clock record the same instant because they are the same edit.
"""
function set_fields(url::AbstractString, updates, at::DateTime = utcnow())
    ups = Pair{String,Any}[String(k) => v for (k, v) in updates]
    push!(ups, "touched" => stamp(at))
    get(set_blocks!([String(url) => ups]), String(url), "updated")
end

"""Every block's values for the named keys, in one pass over the file.

    field_maps(("read", "touched")) -> key -> field -> value

`get_field` re-reads and re-scans for a single lookup, which is right for one
and quadratic for a question about every item - and the browser asks for five of
these every time it rebuilds the list.

Unquoted the same way `get_field` unquotes, so the two agree about what a value
is. A table header that is not a block key - there are none today - ends the
block rather than continuing it, so nothing is ever attributed to the wrong one.
"""
function field_maps(keys)
    out = Dict{String,Dict{String,String}}()
    pats = [(String(k), Regex("^\\s*\\Q" * String(k) * "\\E\\s*=\\s*(.*?)\\s*\$"))
            for k in keys]
    cur = ""
    for l in load_lines()
        if startswith(lstrip(l), "[")
            h = match(r"^\[\"(.*)\"\]\s*$", strip(l))
            cur = h === nothing ? "" : String(h[1])
            continue
        end
        isempty(cur) && continue
        for (k, pat) in pats
            m = match(pat, l)
            m === nothing ||
                (get!(out, cur, Dict{String,String}())[k] = String(strip(String(m[1]), '"')))
        end
    end
    out
end

"One key across every block: the shape the filters and the lanes want."
field_map(key::AbstractString) =
    Dict{String,String}(u => r[String(key)] for (u, r) in field_maps((key,)))

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

"""Every item filed away, as `url -> the value that filed it`.

Archiving is `snooze = "forever"`, so this is the snooze map with the values
that never wake kept - not a field of its own. See `archive!`.
"""
archived_map() = Dict{String,String}(u => v for (u, v) in field_map("snooze")
                                     if snooze_forever(v))

"""Hand back the next slice of the untriaged pile, quietest first.

Pull, never push: nothing in the pile reaches the dashboard on its own. You ask
for work when you want it. Items you have already tagged in local.toml are
considered triaged and never come back here - and tagging is the only thing that
retires one. It used to keep a `queue.json` of what it had printed and sort that
to the back, which is a fifth file of one fact per url to make asking twice in a
row show two different slices; the tag is the record of having dealt with
something, and there was never a second one worth keeping.
"""
function next_batch(n::Int)
    items = fetched("items")
    items === nothing && die("nothing fetched yet - run `wl refresh` first")
    state = load_state()
    pool = String[String(u) for (u, r) in pairs(items)
                  if in_pile(r) && !truthy(jget(r, :snoozed)) &&
                     !truthy(get(state, String(u), nothing))]
    if isempty(pool)
        println("the pile is fully triaged")
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
    @printf("%d untriaged items in the pile (%d shown)\n\n", length(pool), length(batch))
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
