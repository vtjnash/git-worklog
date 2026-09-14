# What this program knows about an item that GitHub cannot answer.
#
# Five facts, in the item's own block of `local.toml`:
#
#     read · read_head · touched · archived · draft
#
#   * `read`      the timestamp you have seen this item up to
#   * `read_head` the head commit it stood at when you saw it
#   * `touched`   when you last *did* something to it
#   * `archived`  when you filed it away - read, and held out of every view
#                 that does not ask for the filed ones
#   * `draft`     when an unsent review on it was last written to
#
# And beside them, yours rather than written for you, `snooze`: a wake *time*,
# which `seen_of` reads as a second reason for the item to be unread beside
# the wake table. There were two more here - `snooze_fp`, the hash an
# "until it moves" snooze was armed against or `WOKE` once it had, and
# `snooze_at`, when the arming happened - and they went on 2026-09-12: a
# snooze that wakes on movement is a read mark, and a wake time needs no arming.
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
# membership in `fetched.json` - which is the poll's own record of what moved in
# the repos it watches, bounded by a lookback window, and answers a narrower
# question than the one most of the program asks.
#
# **The read mark is a record of where you were, not only of when.** Saying an
# item has changed is not the same as saying *what* changed, and the difference
# is what you are handed when you open it: the whole thread and the whole diff,
# with the new part somewhere in them.
#
# For the thread, the stamp alone answers it. `r` stamps the moment the thread
# was *fetched* - see the key - so every comment written before it was on
# screen, every comment written after it was not, and "new since you last
# looked" is a comparison the file already supports. That is why there is no
# key here recording which comment you had got to: it would be a second copy of
# an answer `read` already gives, and one that could disagree with it.
#
# For the diff it does not. A rebase is invisible to a timestamp - the question
# is not "when did the branch move" but "what did they change in it", and that
# is a diff between two commits. So the mark carries `read_head`: the sha this
# item stood at when the stamp was made. `p` takes a range-diff between it and
# the head now, and an item with no `read_head` simply has no such view to show
# - which is the honest state for one marked read before this existed.
#
# Only `r` writes it, because only `r` means "I have looked at this". The other
# things that stamp `read` - a snooze, an archive, `wl read` over the whole
# lane - are saying "not now", and they know when you decided that and nothing
# at all about what you were looking at. They leave the sha alone rather than
# writing a wrong one or clearing a right one, so it goes on meaning the head
# as of your last actual look. Going unread clears it: that is the one thing
# that says you are no longer anywhere in this item.
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

"""The five marks, as `url -> field -> value`, in one pass over `local.toml`.

They live in the item's own block, beside the note and the snooze that are your
words about the same item: one place to look, one file to write, and no
precedence to keep in step between a "what I decided" file and a "what I did"
one.
"""
const MARK_FIELDS = ("archived", "draft", "read", "read_head", "touched")

load_marks() = field_maps(MARK_FIELDS)

"""One field across every item: `url -> value`, for the urls that carry it.

The shape the filters and the lanes want - they ask "is this url in the drafts
map", and the map is a projection of the file rather than a file of its own.
"""
field_marks(m::Dict{String,Dict{String,String}}, field::AbstractString) =
    Dict{String,String}(u => r[field] for (u, r) in m if haskey(r, field))

load_field(field::AbstractString) = field_map(field)

"One field of one item, or `nothing` if it has never been recorded."
mark_at(url::AbstractString, field::AbstractString) = get_field(url, field)

"""Set, or with `nothing` clear, one field of one item.

The primitive behind every mark and behind undoing one: the undo of a mark is
not "mark it the other way", it is putting back whatever was there before, which
may have been nothing at all.

Deliberately *not* through `set_fields`, which stamps the interaction clock:
marking something read is the end of looking at it rather than the start of
doing anything to it, and a clock that moved when your eye did would make the
list a record of browsing.
"""
set_mark!(url::AbstractString, field::AbstractString,
          at::Union{Nothing,AbstractString}) =
    (set_blocks!([String(url) => [String(field) => at]]); nothing)

"""Set one field on many items at once, and answer how many were named.

Once, not once per url: `wl read` stamps every unread thread at a stroke, and a
refresh that puts twenty items to sleep should rewrite this file once.
"""
function set_marks!(urls, field::AbstractString, at::AbstractString)
    us = unique(String(u) for u in urls)
    isempty(us) || set_blocks!([u => [String(field) => String(at)] for u in us])
    length(us)
end

# --- the seen bit ------------------------------------------------------------
#
# **Two layers, and the file's is on top.** A read stamp in `local.toml` is
# something you did. Beneath it is the *baseline*: a stamp a row was given
# when it arrived as background - the open list of a polled repository,
# imported whole for the backlog view - read by construction, since it was
# never in front of you, and unread the moment it next moves past that stamp.
# Kept in `fetched.json` under `baseline` and not as five thousand blocks in
# this file, which is a record of what you did and would parse on every
# keystroke; and taken out again the moment you say otherwise - `r` on such a
# row clears the baseline for it along with the stamp, and from then on it is
# an ordinary row with nothing said about it. Every reader of the seen bit
# reads the two merged, the file's winning.

"The stamps rows were given on arrival as background: `url -> ISO8601`."
function load_baseline()
    b = fetched("baseline")
    b === nothing ? Dict{String,String}() :
        Dict{String,String}(String(k) => String(v) for (k, v) in pairs(b))
end

"Put `stamps` under the baseline, beside what is there."
function add_baseline!(stamps::AbstractDict)
    isempty(stamps) && return 0
    b = load_baseline()
    merge!(b, Dict{String,String}(String(k) => String(v) for (k, v) in stamps))
    put_fetched!("baseline", b)
    length(stamps)
end

"Take these urls out of the baseline: from here their seen bit is the file's alone."
function drop_baseline!(urls)
    b = load_baseline()
    n = count(u -> haskey(b, String(u)), urls)
    n == 0 && return 0
    for u in urls
        delete!(b, String(u))
    end
    put_fetched!("baseline", b)
    n
end

"Every seen-up-to timestamp: `url -> ISO8601` - the baseline under the file's."
load_read() = merge!(load_baseline(), load_field("read"))

"The seen-up-to timestamp for one item, or `nothing` if it has never been read."
read_at(url::AbstractString) = something(mark_at(url, "read"),
                                         get(load_baseline(), String(url), nothing), Some(nothing))

"The read stamps for the browser: the file's over the baseline."
read_marks(m::Dict{String,Dict{String,String}}) = merge!(load_baseline(), field_marks(m, "read"))

"""The head commit this item stood at when it was marked read, or `nothing`.

Empty as well as absent answers `nothing`: an issue has no head to record and a
row the activity poll wrote has no sha to record one from, so "" is what a mark
made on either of them carries, and neither is a commit to diff against.
"""
function read_head(url::AbstractString)
    h = mark_at(url, "read_head")
    (h === nothing || isempty(h)) ? nothing : h
end

"Set, or with `nothing` clear, one item's seen-up-to timestamp."
set_read(url::AbstractString, at::Union{Nothing,AbstractString}) =
    set_mark!(url, "read", at)

"""Set both halves of one item's read mark at once, or with `nothing` clear both.

The pair is written in one pass because it is one fact - where you were - and
the two halves disagreeing is the only way `p` can show a diff from somewhere
you never stood. `head` may be empty for an item that has no head commit to
have; the key is then dropped rather than written blank.
"""
function set_read_mark(url::AbstractString, at::Union{Nothing,AbstractString},
                       head::Union{Nothing,AbstractString} = nothing)
    h = (at === nothing || head === nothing || isempty(head)) ? nothing : String(head)
    set_blocks!([String(url) => ["read" => at === nothing ? nothing : String(at),
                                 "read_head" => h]])
    nothing
end

"""Forget the read marks on these items, making them unread again.

An item counts as unread when it moved more recently than its stamp here, so
dropping the key restores it. Both halves go: a `read_head` outliving the stamp
it was made with is a commit nothing is measured from any more.
"""
function mark_unread(urls)
    have = load_read()
    us = unique(String(u) for u in urls)
    named = [u for u in us if haskey(have, u)]
    isempty(us) || set_blocks!([u => ["read" => nothing, "read_head" => nothing]
                                for u in us])
    drop_baseline!(us)
    length(named)
end

"""Record that these items have been seen up to `at`.

The stamp only. This is `wl read` over the whole unread lane and the refresh
putting a batch to sleep - neither of which knows what you were looking at, so
neither writes `read_head`, and an item that carries one from the last time you
actually opened it keeps it.
"""
mark_read(urls, at::DateTime) = set_marks!(urls, "read", stamp(at))

"""What to stamp an item read up to when it is being put away rather than
looked at: its own `moved_at`, the last movement on record.

That is read by definition - `seen_of` is the stamp against `moved_at` - and
it is GitHub's time by construction, so a local clock minutes out cannot
leave a just-snoozed item unread (behind) or swallow the next comment
(ahead). Anything that has moved since the last refresh is newer than this
and comes back unread, which is right: you put away what you knew about.
`updated` for a row no refresh has stamped, and `at` for a synthetic one that
has neither.
"""
read_up_to(moved_at, updated, at::DateTime) =
    truthy(moved_at) ? String(moved_at) : truthy(updated) ? String(updated) : stamp(at)

"""Mark each url read up to its own last movement - `read_up_to` over the
fetched rows - and answer how many. The shell's `wl snooze`, `wl archive`
and `wl read`, which have no thread on screen to have read up to."""
function mark_read_moved(urls, at::DateTime)
    items = something(fetched("items"), (;))
    us = unique(String(u) for u in urls)
    isempty(us) && return 0
    set_blocks!([u => ["read" => read_up_to(jget(jget(items, Symbol(u)), :moved_at),
                                            jget(jget(items, Symbol(u)), :updated), at)]
                 for u in us])
    length(us)
end

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

# --- archive and the wake time ---------------------------------------------

"""Every item filed away, as `url -> when`.

The `archived` mark. Filed is read that no view shows unless asked: see
`show_ok`.
"""
archived_map() = field_map("archived")

"""Every item with a wake time, as `url -> stamp`, resolved.

A span typed by hand is counted from the read stamp beside it, which is what
`wl snooze` and `s` wrote it from too. Whether the wake has *passed* is not
decided here: `seen_of` asks that of a clock, per frame, so that a snooze
running out needs no refresh to be noticed.
"""
function wake_map()
    out = Dict{String,String}()
    for (u, r) in field_maps(("snooze", "read"))
        w = wake_of(get(r, "snooze", nothing), get(r, "read", nothing))
        w === nothing || (out[u] = w)
    end
    out
end

"File one item away, or with `nothing` take it back out."
set_archived(url::AbstractString, at::Union{Nothing,AbstractString}) =
    set_mark!(url, "archived", at)
