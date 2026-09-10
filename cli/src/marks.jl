# What this program knows about an item that GitHub cannot answer.
#
# Five facts, one file, one row per url:
#
#     marks.json   url -> {read, touched, snooze_fp, snooze_at, draft}
#
#   * `read`      the timestamp you have seen this item up to
#   * `touched`   when you last *did* something to it
#   * `snooze_fp` the fingerprint an "until it moves" snooze was armed against,
#                 or the string `WOKE` once it has moved
#   * `snooze_at` when that arming happened, so a cap can expire it
#   * `draft`     when an unsent review on it was last written to
#
# These were four files - `read.json`, `touched.json`, `snooze.json` and
# `drafts.json` - which is four read-modify-writes where there should be one,
# four watches on `data/` where there should be one, and no single place to look
# at what is recorded about an item. They are one small string per url and they
# are written by the same key presses; there was never a reason for them to be
# apart beyond the order they were built in.
#
# Machine-owned but tracked, like everything in `data/` that records something
# you did: GitHub can answer none of it, so none of it is re-fetchable and it is
# worth a history. `facts.json` and `bulk.json` are the other way round and are
# ignored there.
#
# **The read stamp is the seen bit, and it is a fact about the corpus.** Whether
# an item is unread is a question to ask of the item and this file, not
# membership in `inbox.json` - which is the poll's own record of what moved in
# the repos it watches, bounded by a lookback window, and answers a narrower
# question than the one most of the program asks.
#
# **The interaction clock is not a viewing clock.** Opening an item, scrolling
# it, searching, folding a comment and changing filters are all *looking*, and
# looking must not reorder the list you are looking at - a clock that moved as
# your eye did would put whatever you just glanced at on top, every time, and
# the list would be a record of browsing rather than of work. What writes it: a
# comment (`C`), a review (`A`), a label (`L`), a note (`v`), a snooze (`s`),
# any field set through `wl`, and opening a shell or an agent on it (`t`, `T`).
# That last one is the reason this is not a viewing clock in disguise: starting
# work on something is the strongest signal there is, and it involves no reading
# at all. Marking a thread read is deliberately *not* an interaction either - it
# is the end of looking, not the start of doing, and it has its own field one
# line above.
#
# **The draft mark exists because GitHub will not list them.** A pending review
# is visible only to its author and only on the pull request it is on: GraphQL
# answers `reviews(states: PENDING, author: $me)` for *one* pull request, and
# `review:pending` is not a search qualifier - it matches nothing at all,
# exactly as `review:banana` does. So the only way to have a lane of them is to
# write them down as they are made.

"Overridable so a test can write somewhere other than the real file."
const MARKS = Ref("")
marksfile() = isempty(MARKS[]) ? datapath("marks.json") : MARKS[]

"""The whole file: `url -> field -> value`, every value a string.

Read whole and written whole. It is a few hundred short rows - the four files it
replaces were each read in full by every accessor they had - and holding it
anywhere would mean deciding when to let go of it.
"""
function load_marks()
    out = Dict{String,Dict{String,String}}()
    isfile(marksfile()) || return out
    for (u, rec) in JSON3.read(read(marksfile(), String))
        r = Dict{String,String}()
        for (k, v) in rec
            v === nothing || (r[String(k)] = String(v))
        end
        isempty(r) || (out[String(u)] = r)
    end
    out
end

"""Write it back, dropping any url left with nothing recorded about it.

An empty record is what clearing the last field on an item leaves behind, and
keeping it would grow the file by one line per item ever looked at.
"""
write_marks(m::Dict{String,Dict{String,String}}) = write_atomic(marksfile(),
    json_dumps(Dict{String,Any}(u => r for (u, r) in m if !isempty(r));
               indent = 1, sortkeys = true))

"""One field across every item: `url -> value`, for the urls that carry it.

The shape each of the four files used to have, which is what the filters and the
lanes still want - they ask "is this url in the drafts map", and the map is now
a projection rather than a file.
"""
field_marks(m::Dict{String,Dict{String,String}}, field::AbstractString) =
    Dict{String,String}(u => r[field] for (u, r) in m if haskey(r, field))

load_field(field::AbstractString) = field_marks(load_marks(), field)

"One field of one item, or `nothing` if it has never been recorded."
mark_at(url::AbstractString, field::AbstractString) =
    get(get(load_marks(), String(url), Dict{String,String}()), field, nothing)

"""Set, or with `nothing` clear, one field of one item.

The primitive behind every mark and behind undoing one: the undo of a mark is
not "mark it the other way", it is putting back whatever was there before, which
may have been nothing at all.

Unchanged is not written. Nothing downstream can tell a no-op write from a real
one - the browser's watch on `data/` would refilter for it - and the four files
this replaces disagreed about it, `set_draft` alone getting it right.
"""
function set_mark!(url::AbstractString, field::AbstractString,
                   at::Union{Nothing,AbstractString})
    m = load_marks()
    u = String(url)
    r = get(m, u, Dict{String,String}())
    was = get(r, field, nothing)
    was == at && return nothing
    at === nothing ? delete!(r, field) : (r[field] = String(at))
    m[u] = r
    write_marks(m)
    nothing
end

"""Set one field on many items at once, and answer how many were named.

Once, not once per url: a refresh that puts twenty items to sleep should rewrite
this file once.
"""
function set_marks!(urls, field::AbstractString, at::AbstractString)
    m = load_marks()
    n, s = 0, String(at)
    for u in urls
        r = get!(m, String(u), Dict{String,String}())
        r[field] = s
        n += 1
    end
    n == 0 || write_marks(m)
    n
end

"Clear one field on many items, and answer how many actually carried it."
function clear_marks!(urls, field::AbstractString)
    m = load_marks()
    n = 0
    for u in urls
        r = get(m, String(u), nothing)
        r === nothing && continue
        haskey(r, field) && (delete!(r, field); n += 1)
    end
    n == 0 || write_marks(m)
    n
end

# --- the seen bit ------------------------------------------------------------

"Every seen-up-to timestamp: `url -> ISO8601`."
load_read() = load_field("read")

"The seen-up-to timestamp for one item, or `nothing` if it has never been read."
read_at(url::AbstractString) = mark_at(url, "read")

"Set, or with `nothing` clear, one item's seen-up-to timestamp."
set_read(url::AbstractString, at::Union{Nothing,AbstractString}) =
    set_mark!(url, "read", at)

"""Forget the seen-up-to timestamps for these items, making them unread again.

An item counts as unread when it moved more recently than its stamp here, so
dropping the key restores it.
"""
mark_unread(urls) = clear_marks!(urls, "read")

"Record that these items have been seen up to `at`."
mark_read(urls, at::DateTime) = set_marks!(urls, "read", stamp(at))

# --- the interaction clock ---------------------------------------------------

"Every last-interaction timestamp: `url -> ISO8601`."
load_touched() = load_field("touched")

"When this item was last acted on, or `nothing` if it never has been."
touched_at(url::AbstractString) = mark_at(url, "touched")

"Set, or with `nothing` clear, one item's last-interaction time."
set_touched(url::AbstractString, at::Union{Nothing,AbstractString}) =
    set_mark!(url, "touched", at)

"""Record that this item was just acted on, and return what the clock said
before - which is what an undo has to put back."""
function touch!(url::AbstractString, at::DateTime = utcnow())
    prev = touched_at(url)
    set_touched(url, stamp(at))
    prev
end

# --- unsent reviews ----------------------------------------------------------

"Every item carrying a draft review: `url -> ISO8601`."
load_drafts() = load_field("draft")

"""Set, or with `nothing` clear, the mark saying this item carries a draft.

Written through in both directions rather than accumulated in memory: the lane
is membership in this map, and the browser re-reads it whenever it rebuilds the
list.

What writes here: a comment joining a draft, and opening an item whose metadata
turns out to carry a pending review this program did not start - one from an
earlier session, or from the web UI. What clears it: submitting the review,
discarding it, and equally opening an item that was marked and whose metadata
says there is no draft on it any more, which is how one submitted on github.com
stops being listed. Opening the item is enough for everything still on the
dashboard; `reconcile_drafts!` asks about the ones that have left it, since a
mark on an item off the list can never be shown or navigated to again.
"""
set_draft(url::AbstractString, at::Union{Nothing,AbstractString}) =
    set_mark!(url, "draft", at)

"Record that this item carries a draft review, as of now."
draft!(url::AbstractString, at::DateTime = utcnow()) = set_draft(url, stamp(at))

"Forget the draft on this item - it has been sent, or thrown away."
undraft!(url::AbstractString) = set_draft(url, nothing)

# --- armed snoozes -----------------------------------------------------------

"""The armed fingerprints, in the shape a refresh works in: `url -> entry`.

An entry is `WOKE` or a `(fp, at)` record; see `snooze_entry`. Only `refresh`
reads or writes these - arming and waking are its business alone, for the
reasons on `snooze_active` - so they are lifted out of the file into that shape
at the top of a run and synced back at the foot of one.
"""
function load_snoozes()
    out = Dict{String,Any}()
    for (u, r) in load_marks()
        fp = get(r, "snooze_fp", nothing)
        fp === nothing && continue
        out[u] = fp == "WOKE" ? "WOKE" : snooze_record(fp, get(r, "snooze_at", nothing))
    end
    out
end

"""Put a refresh's whole snooze map back, dropping what is no longer in it.

A sync rather than a merge: `refresh` deletes the entry for an item that has
left the dashboard, and the file has to lose it too.
"""
function save_snoozes!(snz::Dict{String,Any})
    m = load_marks()
    want = Dict{String,Tuple{Union{Nothing,String},Union{Nothing,String}}}()
    for (u, v) in snz
        fp, at = snooze_entry(v)
        want[String(u)] = (fp === nothing ? nothing : String(fp),
                           at === nothing ? nothing : String(at))
    end
    dirty = false
    for (u, r) in m, (k, v) in zip(("snooze_fp", "snooze_at"),
                                   get(want, u, (nothing, nothing)))
        get(r, k, nothing) == v && continue
        v === nothing ? delete!(r, k) : (r[k] = v)
        dirty = true
    end
    for (u, (fp, at)) in want
        haskey(m, u) && continue
        fp === nothing && at === nothing && continue
        r = Dict{String,String}()
        fp === nothing || (r["snooze_fp"] = fp)
        at === nothing || (r["snooze_at"] = at)
        m[u] = r
        dirty = true
    end
    dirty && write_marks(m)
    nothing
end

"""Drop any armed fingerprint so a re-snooze re-arms from the current state.

The one thing outside a refresh that may touch these, and it only ever forgets:
what it is undoing is an arming, not a decision about whether the item is
asleep, which is `state.toml`'s to make.
"""
function disarm(url::AbstractString)
    m = load_marks()
    r = get(m, String(url), nothing)
    r === nothing && return nothing
    (haskey(r, "snooze_fp") || haskey(r, "snooze_at")) || return nothing
    delete!(r, "snooze_fp")
    delete!(r, "snooze_at")
    write_marks(m)
    nothing
end
