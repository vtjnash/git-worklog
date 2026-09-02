# Small shared helpers: the clock, ISO timestamps, and the two places where
# Julia's stdlib does not give us what the Python it replaces relied on.

# Ref{T}() for an isbits T is zero-initialised, not undefined, so reading NOW[]
# before _clock!() yields year 0 rather than throwing - which silently produced
# an empty unread list instead of an error. The module's __init__ sets it, so
# calling any function directly is safe; main() re-freezes per run.
const NOW = Ref{DateTime}()
const TODAY = Ref{Date}()

"""Freeze the clock for the whole run, as the Python module did at import.

Every age, threshold and snooze expiry is measured against one instant, so a
refresh cannot straddle midnight and bucket half its items against a different
day.
"""
function _clock!()
    NOW[] = Dates.now(Dates.UTC)
    TODAY[] = Date(NOW[])
end

"`datetime.now(utc).isoformat()`. Julia's clock is millisecond resolution, so
the microsecond field is padded rather than measured; only the day matters."
now_isoformat() = string(Dates.format(NOW[], "yyyy-mm-ddTHH:MM:SS.sss"), "000+00:00")

stamp() = Dates.format(NOW[], "yyyy-mm-ddTHH:MM:SS") * "Z"

"""The wall clock, for the program that outlives the instant it started at.

`stamp()` reads the frozen `NOW[]`, which is right for a refresh: one instant
for every age and expiry, so a run cannot straddle midnight and bucket half its
items against a different day. The browser is the other kind of program - it
stays open for hours - and a timestamp taken from the frozen clock there would
date every action in the session to when `wl` was launched, ordering them by
nothing at all. Anything recording *when something happened* wants this one.

`ago` is seconds back from now, for the case where the thing being stamped
happened at a known age rather than just now - a cache hit knows how old its
entry is, not when it was written.
"""
livestamp(ago::Real = 0) =
    Dates.format(Dates.now(Dates.UTC) - Millisecond(round(Int, 1000ago)),
                 "yyyy-mm-ddTHH:MM:SS") * "Z"

"""Parse a GitHub/ISO timestamp. Everything GitHub emits is UTC, so the offset
is dropped rather than modelled."""
function ts(s)
    (s === nothing || s === missing) && return nothing
    m = match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?", String(s))
    m === nothing && return nothing
    frac = m[2] === nothing ? "" : "." * rpad(first(m[2], 3), 3, '0')
    DateTime(m[1] * frac)
end

"`(NOW - t).days`, which floors, so a future timestamp is negative rather than
rounded toward zero."
function days_since(s)
    t = ts(s)
    t === nothing ? nothing : fld(Dates.value(NOW[] - t), 86_400_000)
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
