# Small shared helpers: the clock, ISO timestamps, the one way anything here is
# allowed to write a file, and the two places where Julia's stdlib does not give
# us what the Python it replaces relied on.

"""Write `content` to `path` so that a reader sees all of it or none of it.

A unique name in the *same directory* - the same filesystem, or the rename below
would be a copy - and then a rename over the target, which is the one file
operation POSIX promises is atomic. Every caller of this rewrites a whole file
from what it read a moment ago, and everything they rewrite is a record of what
you have done that GitHub cannot re-answer: a crash, a full disk or a second
`wl` reading mid-write would otherwise leave a truncated file where the record
used to be. `cache_put` had this shape first, on the one file in `data/` that
could be thrown away without loss.

Atomicity, not durability. A reader never sees half a file; surviving the power
going out would want the file and its directory fsynced around the rename, which
is a cost per keystroke for a risk that loses at most the last thing typed.
"""
function write_atomic(path::AbstractString, content)
    dir = dirname(abspath(path))
    isdir(dir) || mkpath(dir)
    tmp = tempname(dir; cleanup = false)
    try
        write(tmp, content)
        mv(tmp, path; force = true)
    catch
        # The temporary is this function's own mess and nobody else's: leaving
        # one behind would put an untracked file in the data repository for
        # every failure, which is how a directory ends up full of them.
        isfile(tmp) && rm(tmp; force = true)
        rethrow()
    end
    nothing
end

"""When an operation started, which is the instant everything in it is
measured against.

Every age, threshold and snooze expiry inside one operation is compared to one
instant, so a refresh cannot straddle midnight and bucket half its items
against a different day. That instant is threaded through as an argument rather
than held in a global: a global is only ever right for a process that does one
thing and exits, and the browser does not - it stays open for hours, running an
operation per keystroke. It held a frozen `NOW[]` once, and the browser reading
it recorded threads as fetched when `wl` was launched.

The rule the signatures follow: **an entry point defaults `at` to `utcnow()`,
and everything it calls takes `at` as a required argument.** A default further
in would quietly reintroduce the second half of the problem - measuring against
the moment a function happened to be reached, so that a long operation stamps
its result with a time *after* things it never saw. The start is the honest
answer for both.
"""
utcnow() = Dates.now(Dates.UTC)

"""`datetime.now(utc).isoformat()` for `at`. Julia's clock is millisecond
resolution, so the microsecond field is padded rather than measured; only the
day matters."""
now_isoformat(at::DateTime) = string(Dates.format(at, "yyyy-mm-ddTHH:MM:SS.sss"),
                                     "000+00:00")

"The ISO-8601 Z form of `at`, which is how every timestamp is written here."
stamp(at::DateTime) = Dates.format(at, "yyyy-mm-ddTHH:MM:SS") * "Z"

"""Fill in the date placeholders in a search lane.

`{since:21}` becomes the date 21 days before this run, and `{since}` defaults to
14. Written here rather than in `config.toml` because the answer changes daily
and the file is the user's - a literal date there would be a thing to remember
to edit, and a lane that quietly stopped covering the gap it was added for.

The gap: every other lane is `is:open`, so a pull request that merges between
two refreshes stops being returned and is never seen at all.
"""
function expand_lane(q::AbstractString, at::DateTime)
    replace(String(q), r"\{since(?::(\d+))?\}" => s -> begin
        m = match(r"\{since(?::(\d+))?\}", s)
        string(Date(at) - Day(m[1] === nothing ? 14 : parse(Int, m[1])))
    end)
end

"""Parse a GitHub/ISO timestamp. Everything GitHub emits is UTC, so the offset
is dropped rather than modelled."""
function ts(s)
    (s === nothing || s === missing) && return nothing
    m = match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?", String(s))
    m === nothing && return nothing
    frac = m[2] === nothing ? "" : "." * rpad(first(m[2], 3), 3, '0')
    DateTime(m[1] * frac)
end

"`(at - t).days`, which floors, so a future timestamp is negative rather than
rounded toward zero."
function days_since(s, at::DateTime)
    t = ts(s)
    t === nothing ? nothing : fld(Dates.value(at - t), 86_400_000)
end

"""Decode HTML entities.

Numeric ones as well as named: Buildkite escapes path separators as `&#47;`, so
a named-entity-only pass leaves log paths unreadable. `&amp;` is undone last,
or an escaped `&amp;lt;` decodes twice into a tag.
"""
function unescape_html(s::AbstractString)
    s = replace(s, r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))))
    s = replace(s, r"&#x([0-9a-fA-F]+);" => m -> string(Char(parse(Int, m[4:end-1], base = 16))))
    replace(s, "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"",
               "&#39;" => "'", "&nbsp;" => " ", "&amp;" => "&")
end

# Python's `.get(k)`, which cannot tell a missing key from an explicit null and
# does not need to: both mean "GitHub did not give us this".
jget(o, k::Symbol) = get(o, k, nothing)
jget(::Nothing, ::Symbol) = nothing
jget(o, k::Symbol, d) = (v = jget(o, k); v === nothing ? d : v)

# Python's `str.splitlines()` for the line endings a TOML file can carry.
splitlines(s::AbstractString) = split(replace(s, "\r\n" => "\n"), '\n')[1:end-(endswith(s, "\n") ? 1 : 0)]

rstripnl(s::AbstractString) = replace(s, r"\n+$" => "")

"""
    table_key_order(text, table) -> Vector{String}

Key order inside one TOML table, recovered from the file text.

Julia's `TOML.parse` returns an unordered `Dict`, but the order of `[lanes]` and
`[bulk.queries]` is load-bearing rather than cosmetic: within the bulk lanes the
first one to claim a URL keeps it, so visiting `firehose` before `commented_pr`
is the whole reason a JuliaLang/julia PR lands in the background firehose
instead of the mention pile. Python's `tomllib` preserved file order for free;
here it has to be read back out of the file.

Only the shapes `config.toml` actually uses are handled - one key per line, no
inline tables spanning lines. Keys the scan misses are appended in sorted order
so a malformed line degrades to "wrong order", never to "silently dropped".
"""
function table_key_order(text::AbstractString, table::AbstractString)
    want = "[" * table * "]"
    cur = ""
    out = String[]
    for raw in splitlines(text)
        l = strip(raw)
        (isempty(l) || startswith(l, "#")) && continue
        if startswith(l, "[")
            cur = String(l)
            continue
        end
        cur == want || continue
        m = match(r"^(\"[^\"]*\"|[A-Za-z0-9_.\-]+)\s*=", l)
        m === nothing && continue
        push!(out, String(strip(m.captures[1], '"')))
    end
    out
end

"Iterate a parsed TOML table in the order its keys appear in the file."
function ordered(tbl::AbstractDict, text::AbstractString, table::AbstractString)
    order = table_key_order(text, table)
    ks = [k for k in order if haskey(tbl, k)]
    append!(ks, sort([k for k in keys(tbl) if !(k in ks)]))
    [k => tbl[k] for k in ks]
end

# Records reach the renderer from two places with two key types: freshly
# normalised items are `Dict{String,Any}`, while items recovered from the
# previous `facts.json` are JSON3 objects keyed by `Symbol`. One accessor for
# both, so a lookup cannot silently miss.
pget(o::AbstractDict{String}, k::AbstractString) = get(o, k, nothing)
pget(o, k::AbstractString) = get(o, Symbol(k), nothing)
pget(::Nothing, ::AbstractString) = nothing
