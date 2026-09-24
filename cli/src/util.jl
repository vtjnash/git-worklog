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
        OURS[abspath(path)] = mtime(path)
    catch
        # The temporary is this function's own mess and nobody else's: leaving
        # one behind would put an untracked file in the data repository for
        # every failure, which is how a directory ends up full of them.
        isfile(tmp) && rm(tmp; force = true)
        rethrow()
    end
    nothing
end

"""What this process last wrote, as `path -> mtime`, so a watcher can tell its
own writes from somebody else's.

Every key press that archives, notes or comments writes a file in `data/`, and a
watch on that directory hears all of them. Reacting to your own write is not
wrong so much as pointless and slightly worse than pointless - it re-reads what
is already in memory, and it would move a row out from under a reader at the
moment they acted on it. The timestamp is the evidence: a file whose mtime is
still the one we left is a file nobody else has touched since.
"""
const OURS = Dict{String,Float64}()

"Was this the file this process last wrote, unchanged since?"
ours(path::AbstractString) = get(OURS, abspath(path), -1.0) == mtime(path)

"""When an operation started, which is the instant everything in it is
measured against.

Every age, threshold and snooze expiry inside one operation is compared to one
instant, so a refresh cannot straddle midnight and bucket half its items
against a different day. That instant is threaded through as an argument rather
than held in a global: a global is only ever right for a process that does one
thing and exits, and the browser does not - it stays open for hours, running an
operation per keystroke. It held a frozen `NOW[]` once, and the browser reading
it recorded threads as fetched when `wl` was launched.

The rule the signatures follow: **an entry point defaults `at` to now, and
everything it calls takes `at` as a required argument.** A default further in
would quietly reintroduce the second half of the problem - measuring against
the moment a function happened to be reached, so that a long operation stamps
its result with a time *after* things it never saw. The start is the honest
answer for both.

**Whose now, is the other half.** This is the machine's clock, and it is right
for what is only ever compared against itself: a snooze's wake against the
frame that reads it, the interaction clock, a draft's age. A stamp that will
meet one *GitHub* wrote - the refresh's `at`, which dates movements and read
marks; the poll's cursor, compared on the server against `updated_at`; the
moment a thread was read, which `e` marks it seen up to - is taken off GitHub
instead, from the `Date` header of the response that produced it: see
`Events.server_now` and `Events.thread`. Not corrected from this clock by a
measured offset, which was tried and is a correction factor with all the ways
of being wrong those have; read off the wire, once, where it is wanted. A
Windows box with its clock minutes out then gets every comparison right.
"""
utcnow() = Dates.now(Dates.UTC)

"""An HTTP `Date` header as a `DateTime`, or `nothing`. RFC 1123, always GMT."""
function http_date(s)
    s === nothing && return nothing
    m = match(r"^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d) GMT$", strip(String(s)))
    m === nothing && return nothing
    mon = findfirst(==(m[2]), ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
                               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"))
    mon === nothing && return nothing
    DateTime(parse(Int, m[3]), mon, parse(Int, m[1]),
             parse(Int, m[4]), parse(Int, m[5]), parse(Int, m[6]))
end

"""`datetime.now(utc).isoformat()` for `at`. Julia's clock is millisecond
resolution, so the microsecond field is padded rather than measured; only the
day matters."""
now_isoformat(at::DateTime) = string(Dates.format(at, "yyyy-mm-ddTHH:MM:SS.sss"),
                                     "000+00:00")

"The ISO-8601 Z form of `at`, which is how every timestamp is written here."
stamp(at::DateTime) = Dates.format(at, "yyyy-mm-ddTHH:MM:SS") * "Z"

"""
    set_tz!(tz) -> notes

Show times in `tz`, an IANA name - `America/New_York` - from the top-level
`tz` in the config. Empty leaves the zone the process was started in, which is
`TZ` or the machine's.

**Only what is shown.** Every stamp stays UTC - GitHub's, written as `Z`,
compared as strings - and nothing is stored in local time or against an offset.
This is what a stamp is *drawn* as, and what a bare date typed as a snooze
means: midnight where you are, not where the server is. A name and not an
offset because an offset is right for half the year: libc knows when daylight
time starts in a zone, and a number in a file does not.

Set on the process, for git's `format-local` and `Dates.today()` to agree with
it, and `tzset` asked to read it again: glibc reads `TZ` once, on the first
conversion, and not on the ones after. A name libc has no file for is drawn
as UTC without complaint, so that is said here instead.
"""
function set_tz!(tz = get(config(), "tz", ""))
    (tz isa AbstractString && !isempty(tz)) || return String[]
    ENV["TZ"] = tz
    ccall(:tzset, Cvoid, ())
    dirs = ("/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo")
    (startswith(tz, ":") || any(d -> isfile(joinpath(d, tz)), dirs)) && return String[]
    [string("tz = \"", tz, "\" is not a zone this machine knows; times are in UTC")]
end

"""`t`, a UTC time, as the wall clock where you are shows it: `2026-09-08 01:36`.
See `set_tz!`."""
local_str(t::DateTime) = Libc.strftime("%Y-%m-%d %H:%M", datetime2unix(t))

"""The UTC time that the wall clock where you are shows as `t` - the other
direction, for a time typed in. Daylight time is libc's to decide (`isdst = -1`),
including for the hour a spring-forward skips."""
function utc_of_local(t::DateTime)
    tm = Libc.TmStruct()
    tm.year, tm.month, tm.mday = year(t) - 1900, month(t) - 1, day(t)
    tm.hour, tm.min, tm.sec = hour(t), minute(t), second(t)
    tm.isdst = -1
    unix2datetime(time(tm))
end

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

"""How far a timestamp is from `at`, in the fewest words: `3d ago`, `in 2h`,
`just now`; `""` for anything `ts` cannot read.

The one wording for every relative time on screen, so the metadata pane and
the comment headers agree. Worked out at the point of use from the frame's
`at` and never stored: an age is only true at the instant it is computed (see
"Time" in DESIGN.md). Minutes under an hour, hours under a day, days under
two years, then years - a pull request opened in 2022 wants `4y ago`, not
`1500d ago`.
"""
function ago_str(s, at::DateTime)
    t = ts(s)
    t === nothing && return ""
    d = fld(Dates.value(at - t), 1000)
    a = abs(d)
    a < 60 && return "just now"
    n, unit = a < 3600 ? (a ÷ 60, "m") :
              a < 86_400 ? (a ÷ 3600, "h") :
              a < 730 * 86_400 ? (a ÷ 86_400, "d") :
              (a ÷ (365 * 86_400), "y")
    d < 0 ? string("in ", n, unit) : string(n, unit, " ago")
end

# --- what an operation says as it runs --------------------------------------
#
# Three channels, and every message chooses one. **The report** is what an
# operation says while it works - a lane's count, a retry, a lane that is not
# `is:open` - and it goes to `report()`, which is the report opened for the
# current task or, failing that, the process's: stderr for a command, nothing
# for the browser, whose frame a stray line would draw over. A line the reader
# has to act on goes through `warning()` instead, which is the same stream
# with a count kept, so the summary the status row reads can say how many
# there were without anybody reading the text back. **The status row** is for
# what just happened and will not happen again; the browser writes it directly.
# **`errors.log`** is for exceptions, through `logerror!`, and stands in the
# footer until it is deleted. Nothing in the browser writes stderr.

"""One operation's commentary: where it goes, how many lines were warnings,
and the one line that says what happened - which is what a status row wants
of it, and what `refresh` sets last."""
mutable struct Report
    io::IO
    warnings::Int
    summary::String
end
Report(io::IO) = Report(io, 0, "")

"""The process's report, for a task that opened none of its own. Set by the
browser to `devnull` before the first frame; unset, it is stderr as it stands
at each call - not captured, since `redirect_stderr` rebinds it and a test
does - with no count kept, there being nobody to read one."""
const REPORT = Ref{Union{Nothing,Report}}(nothing)

"The report the current task writes to."
function current_report()
    r = get(task_local_storage(), :report, nothing)
    r === nothing || return r::Report
    REPORT[] === nothing ? Report(stderr) : REPORT[]::Report
end

"The stream a progress line goes to. `@printf(report(), ...)`."
report() = current_report().io

"The same stream, for a line the reader has to act on; counted."
function warning()
    r = current_report()
    r.warnings += 1
    r.io
end

"""Run `f` with a report of its own on `io`, and answer with `(f(), report)`.
What `refresh` does, so its lanes' lines go where it was asked to put them and
its summary can count its warnings."""
function reporting(f, io::IO)
    r = Report(io)
    (task_local_storage(f, :report, r), r)
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

# Here and not in `ui.jl`, where it was: `events.jl` imports it from `Worklog`
# and is included first, which 1.14 names as "undeclared at import time".
nz(x, d = "") = x === nothing || x === missing ? d : x

# Python's `str.splitlines()` for the line endings a TOML file can carry.
splitlines(s::AbstractString) = split(replace(s, "\r\n" => "\n"), '\n')[1:end-(endswith(s, "\n") ? 1 : 0)]

rstripnl(s::AbstractString) = replace(s, r"\n+$" => "")

"""Percent-encode `s` for a url's query: everything but the unreserved set,
as `%XX` of its UTF-8 bytes. A path with a space or a `&` in it, or a branch
with a `#`, must survive `URLSearchParams` on the far side."""
urlenc(s::AbstractString) = sprint() do io
    for b in codeunits(s)
        c = Char(b)
        (isascii(c) && (isletter(c) || isdigit(c) || c in "-._~")) ? write(io, c) :
            print(io, '%', uppercase(string(b, base = 16, pad = 2)))
    end
end

"""
    table_key_order(text, table) -> Vector{String}

Key order inside one TOML table, recovered from the file text.

Julia's `TOML.parse` returns an unordered `Dict`, but the order of `[lanes]`
is load-bearing rather than cosmetic: the first lane to claim a URL keeps it,
so a pull request of yours that you were also asked to review is `mine` and
not `review`. Python's `tomllib` preserved file order for free; here it has to
be read back out of the file.

Only the shapes `config.toml` actually uses are handled - one key per line, no
inline tables spanning lines. Keys the scan misses are appended in sorted order
so a malformed line degrades to "wrong order", never to "silently dropped"; a
continuation line it takes for a key is dropped by `ordered`, which only keeps
what the parsed table has. Pinned in `suite/refresh.jl`.
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
    # Once each: `config_text` is two files end to end, and a lane both name
    # sits where the first one put it.
    unique!(out)
end

"Iterate a parsed TOML table in the order its keys appear in the file."
function ordered(tbl::AbstractDict, text::AbstractString, table::AbstractString)
    order = table_key_order(text, table)
    ks = [k for k in order if haskey(tbl, k)]
    append!(ks, sort([k for k in keys(tbl) if !(k in ks)]))
    [k => tbl[k] for k in ks]
end

# --- the configuration, in two layers ----------------------------------------
#
# `config.toml` beside the code is what is shared: every key, with its default
# and the comment that is its manual. `data/config.toml` is what is yours -
# your login, your theme, the repositories you poll and pin - and is read on
# top of it. Until 2026-09-17 there was one file, committed with one person's
# login in it, so a second user edited a shared file and every pull was a
# merge of their name against the first's. Now the shared file names nobody:
# the lanes say `@me`, which GitHub reads as whoever holds the token.
#
# The merge is two levels deep and no more. A top-level scalar or array in
# your file replaces the shared one; a top-level table merges key by key; and
# whatever sits under one of those keys replaces whole. One rule, and it is
# the one each key wants: `[thresholds] reply_days` overrides one number,
# `[events] repos` is *your* list and not additions to a shared one, and a
# `[views."name"]` of the same name replaces the view rather than merging its
# axes - which is what `views` already promised.

"Overridable for the same reason `LOCAL` is. Empty means `data/config.toml`."
const USER_CONFIG = Ref("")
userconfig() = isempty(USER_CONFIG[]) ? datapath("config.toml") : USER_CONFIG[]

"The shared file, and the template your file is copied from the first time."
commonconfig() = joinpath(ROOT, "config.toml")
configtemplate() = joinpath(ROOT, "config.user.toml")

"""
    config() -> Dict

Both layers, merged - see above. Parsed on every call and never cached: the
browser reads `[views]` when `'` opens, so a view pasted into your file is
there the next time it is pressed, without a restart. `login()` is the one
cache, and it is over one string.
"""
function config()
    common = TOML.parse(read(commonconfig(), String))
    f = userconfig()
    isfile(f) || return common
    merge_config(common, TOML.parse(read(f, String)))
end

"""The two files end to end, for `ordered`: the order of `[lanes]` is the
shared file's, and a lane only your file names comes after them."""
function config_text()
    t = read(commonconfig(), String)
    f = userconfig()
    isfile(f) ? string(t, "\n", read(f, String)) : t
end

"Two levels: a table merges key by key, anything else replaces."
function merge_config(common::AbstractDict, user::AbstractDict)
    out = Dict{String,Any}(common)
    for (k, v) in user
        c = get(out, k, nothing)
        out[k] = v isa AbstractDict && c isa AbstractDict ? merge(Dict{String,Any}(c), v) : v
    end
    out
end

"""
    seed_config!(; io = stderr, whoami = gh_login) -> Bool

Write your file from the template, the first time there is none, and say so.
Answers whether it did.

A copy and not a `TOML.print`: the template's comments are the manual for its
keys, and a serialization would drop them. The one edit is `login`, filled
from `gh api user` when it answers - the same `gh` the lanes go through - and
left `""` otherwise, which `dispatch` refuses to run with, naming the file.
Nothing else here is ever written by the program again.
"""
function seed_config!(; io::IO = stderr, whoami = gh_login)
    f = userconfig()
    isfile(f) && return false
    text = read(configtemplate(), String)
    who = whoami()
    isempty(who) || (text = replace(text, r"^login = \"\"$"m => "login = \"$who\""; count = 1))
    mkpath(dirname(f))
    write(f, text)
    println(io, "worklog: wrote ", f, isempty(who) ? " - set `login` in it" : " for $who",
            "; the repositories to poll and pin are yours to edit there")
    true
end

"Whose token `gh` holds, or `\"\"`."
gh_login() = try
    String(strip(read(`gh api user --jq .login`, String)))
catch
    ""
end

# Records reach the renderer from two places with two key types: freshly
# normalised items are `Dict{String,Any}`, while items recovered from the
# previous `fetched.json` are JSON3 objects keyed by `Symbol`. One accessor for
# both, so a lookup cannot silently miss.
pget(o::AbstractDict{String}, k::AbstractString) = get(o, k, nothing)
pget(o, k::AbstractString) = get(o, Symbol(k), nothing)
pget(::Nothing, ::AbstractString) = nothing

"""One line, whatever it was.

Anything that reaches a single-row field - the footer's message, a status - has
to *be* one row. `showerror` is the reason this exists: its output carries a
newline, so an error put straight into the footer made the frame one row taller
than the screen, scrolled it, and left every mouse click reporting a row that
was no longer under it.
"""
oneline(s::AbstractString) = replace(strip(s), r"\s*\n\s*" => " \u00b7 ")
