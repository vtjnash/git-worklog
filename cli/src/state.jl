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
# `archive` is not one of them: it is a mark - `archived`, when you filed it -
# written by `x` and `wl archive` the way `read` is written by `e`, and it
# lives with the marks. `snooze` is one of them, and is a wake time: `wl snooze`
# writes it resolved, and one typed here as a span counts from the read stamp.
# `imported` is, and was not: it is written by `wl import` and by the browser,
# so leaving it out meant `wl clear` cleared the other seven and left the item
# imported - tagged by nothing, and still fetched by url every run. It sits here
# beside `adopted` for the same reason that one does: the field is the record,
# and the command that makes it is a convenience over the field.
const FIELDS = ["adopted", "blocked_on", "deadline", "imported",
                "note", "snooze", "track"]
const ALIAS = Dict("blocked" => "blocked_on")
# Two, and there were four: see `TRACK_KEYS` for what `close` and `background`
# were and why neither was worth keeping.
const TRACK = ("normal", "loose")

"A message for the user and a non-zero exit, the way `sys.exit(str)` behaved."
struct CliError <: Exception
    msg::String
end
Base.showerror(io::IO, e::CliError) = print(io, e.msg)
die(msg) = throw(CliError(msg))

"""Accept a full URL, owner/repo#N, repo#N, or #N (Julia).

A `local:o/r#branch` url is its own answer, as an `http` one is: an adopted
branch is never in `fetched.json` - it is an item because `local.toml` says
`adopted` - so `wl adopted local:o/r#branch DATE` is the one command whose ref
must not be looked up there.
"""
function resolve(ref::AbstractString)
    (startswith(ref, "http") || startswith(ref, "local:")) && return String(rstrip(ref, '/'))
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

