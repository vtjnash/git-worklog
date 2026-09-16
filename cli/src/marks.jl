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
# **Two layers, and the file's is on top.** A read stamp on an item's block is
# something you did. Beneath it is the *floor*: the day the row's source was
# named, one block per source, `["source:JuliaLang/julia"] since = ...`. A
# row with no stamp is read up to that day by construction and unread the
# moment it next moves past it - **in every lane**: the open list of a
# repository imported whole for the backlog view, and equally a pull request
# of yours from 2021 that a lane returned on the first run and no clock ever
# carried since. Day zero reads zero. A source is what fetched the row
# (`source_of`): a repository, then the glob over its owner, for a `backlog`
# or `activity` row; the lane's own name for everything else; and every one
# names itself on first sight - the repositories when their lists are
# imported, `notifications` where its cursor is first written, a lane the
# first time a corpus row carries it (`name_source!`, from the refresh). A
# source with no block answers nothing, and such a row is unread.
#
# **`since` is how far a source is read by construction** - the day it was
# named, to begin with, and a consolidation point after that: `wl read
# --consolidate` raises every source's `since` together to the newest point
# the read stamps allow and drops the stamps the floor then answers for
# (`consolidate!`), so the file says one line per source where it said one
# per row. Never lowered. A fact about what you did, in the file that holds
# those; and it rebuilds exactly, since a row's mark is recomputed from
# GitHub's own event times, so a `fetched.json` lost and re-imported comes
# out with the same rows unread. (For an evening it was a stamp per row in
# `fetched.json`, which put a fact GitHub cannot answer in the file that is
# supposed to hold only what it can.) Until 2026-09-16 the floor answered
# for a backlog row only, and 1915 rows of the other lanes - retired ones,
# and `mine` back to 2021 - were unread with nothing to read.
#
# And **unread is sayable**: `read = ""` is a key present with nothing in it,
# which `get_field` tells from an absent one, and it is what `r` writes to put
# a row back - under the floor as under a stamp, "" is earlier than any
# movement. An absent key means nothing has been said, and the floor answers;
# an empty one means you said unread. The other way round folds: a plain read
# mark on a row whose movement is at or under the floor drops the key rather
# than stamping it (`folded`), since the floor already answers and the block
# goes back to saying nothing. `s` and `x` keep stamping, because the refresh
# reads a snooze or an archive with no stamp as put away by hand and stamps
# it, and a hand-typed span counts from the stamp.

"When each source was named: `label -> ISO8601`, off the `source:` blocks."
source_since() = Dict{String,String}(String(k)[8:end] => v
                                     for (k, v) in field_map("since") if startswith(k, "source:"))

"Record that `label` was named on `at`, unless it is on record already."
function name_source!(label::AbstractString, at::AbstractString)
    haskey(source_since(), label) && return false
    set_blocks!([string("source:", label) => ["since" => String(at)]])
    true
end

"""How far each source has been read: `label -> ISO8601`, off the `cursor`
key of the `source:` blocks. The other fact about a source that GitHub cannot
answer - `since` is when you named it, this is where the poll has got to -
and the one that, kept only in `fetched.json`, made that file cost the events
of a gap when it was lost. Nine values that move every poll; a small file
rewritten atomically, and the browser's own write as far as the watcher is
concerned. `polled`, when *this machine* last asked, and `failed` stay in the
cache: they are about the machine, not the reading."""
source_cursors() = Dict{String,String}(String(k)[8:end] => v
                                       for (k, v) in field_map("cursor") if startswith(k, "source:"))

"Record how far these sources have been read, in one write."
function set_source_cursors!(cursors::AbstractDict)
    isempty(cursors) && return 0
    set_blocks!([string("source:", l) => ["cursor" => String(c)] for (l, c) in cursors])
    length(cursors)
end

"""The source a row came through, as the label of its `source:` block: the
repository, else the glob over its owner, for a row the repository's own
list or poll fetched (`backlog`, `activity`) - a repository named outright
beats the glob, being the more deliberate of the two; `notifications` by
itself; any other lane by its name. The label whether or not a block exists
for it, so that what is named and what is read are the same question."""
function source_of(lane::AbstractString, repo::AbstractString, sources::AbstractDict)
    lane in ("backlog", "activity") || return String(lane)
    haskey(sources, String(repo)) && return String(repo)
    g = string(first(split(String(repo), '/')), "/*")
    haskey(sources, g) ? g : String(repo)
end

"The day the row's source was named, or `nothing`: what a row with no stamp is read up to."
floor_of(lane::AbstractString, repo::AbstractString, sources::AbstractDict) =
    get(sources, source_of(lane, repo, sources), nothing)

"""What a plain read mark writes: `upto`, or `nothing` - the key dropped - when
the floor already answers for a movement that early."""
folded(upto::AbstractString, floor) = (floor !== nothing && upto <= floor) ? nothing : upto

"Every seen-up-to timestamp: `url -> ISO8601`."
load_read() = load_field("read")

"""The seen-up-to timestamp for one item, or `nothing` if it is unread - never
read, or said to be. The raw key, which tells the two apart, is
`mark_at(url, "read")`, and is what an undo puts back."""
read_at(url::AbstractString) = (v = mark_at(url, "read"); truthy(v) ? v : nothing)

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
have; the key is then dropped rather than written blank. With `fold`, a
stamp of `nothing` is the floor answering rather than unread (`folded`), and
the head is kept: you did look, and the head you saw is still the head you
saw.
"""
function set_read_mark(url::AbstractString, at::Union{Nothing,AbstractString},
                       head::Union{Nothing,AbstractString} = nothing; fold::Bool = false)
    h = ((at === nothing && !fold) || head === nothing || isempty(head)) ? nothing : String(head)
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
    have = field_map("read")
    us = unique(String(u) for u in urls)
    named = [u for u in us if truthy(get(have, u, nothing))]   # a stamp, not "" already
    # Said, not unsaid: an empty stamp is unread whatever the floor for the
    # row would have answered, where a dropped key would hand the question
    # back to it. See the head of this section.
    isempty(us) || set_blocks!([u => ["read" => "", "read_head" => nothing]
                                for u in us])
    length(named)
end

"""Write down that these items' snoozes have run out: said unread, the
snooze gone, the head kept. The refresh's, once for all of them; see
`derive!`. Answers how many."""
function mark_woken(urls)
    us = unique(String(u) for u in urls)
    isempty(us) || set_blocks!([u => ["read" => "", "snooze" => nothing] for u in us])
    length(us)
end

"""Has this item's snooze run out as of `at`, by the wake map? A mark made
on such a row drops the snooze with the stamp it writes, or the stamp - the
last movement, under the wake - would leave the row unread whatever was
pressed. The refresh writes the same down for every woken row it sees
(`mark_woken`); this is for the marks that fire before it has."""
woken_by(url::AbstractString, wakes::AbstractDict, at::DateTime) =
    (w = get(wakes, String(url), nothing); w !== nothing && String(w) <= stamp(at))

"""Record that these items have been seen up to `at`.

The stamp only. This is `wl read` over the whole unread lane and the refresh
putting a batch to sleep - neither of which knows what you were looking at, so
neither writes `read_head`, and an item that carries one from the last time you
actually opened it keeps it.
"""
mark_read(urls, at::DateTime) = set_marks!(urls, "read", stamp(at))

"""The last movement on record for a row, or `nothing`: `moved_at`, else
`updated` for a light row that has no wake table - what the poll saw is the
movement, and `poll_item` writes it so - else nothing at all, which is a
synthetic row, an adopted branch or an import no refresh has caught up with.

    moved_of(it::Item); moved_of(row)      # a corpus row, or an inbox row

**The one thing a read stamp is ever compared against**, and so the one thing
every mark writes. `seen_of` reads it; `r`, `s`, `x`, `wl read`, `wl snooze`
and `wl archive` stamp it. Stamping the movement rather than a clock is read
by definition, and it is GitHub's time by construction, so a local clock
minutes out cannot leave a just-snoozed item unread (behind) or swallow the
next comment (ahead); anything that moves after is newer than this and comes
back unread, which is right: you put away what you knew about. There used to
be three answers to "is it unread" - the poll pruning on `updated`, the marks
stamping `moved_at`, the browser comparing against `moved_at` - and a row
whose `updated` was past its `moved_at` (a push, a label, your own comment)
could not be marked read by anything. Nothing compares a stamp against
`updated` any more.
"""
moved_of(moved_at, updated) =
    truthy(moved_at) ? String(moved_at) : truthy(updated) ? String(updated) : nothing
moved_of(::Nothing) = nothing
moved_of(r) = moved_of(rget(r, "moved_at"), rget(r, "updated"))

"""One key of a row, or `nothing`: an inbox row is keyed by `String`, a corpus
row read back from `fetched.json` by `Symbol`, and the marks read both."""
rget(r::AbstractDict{String}, k::AbstractString) = get(r, k, nothing)
rget(r, k::AbstractString) = jget(r, Symbol(k))

"""Mark each url read up to its own last movement - `moved_of` over the row
the corpus or the inbox has for it, `at` for a synthetic row that has neither
- and answer how many. The shell's `wl snooze`, `wl archive` and `wl read`,
which have no thread on screen to have read up to. The inbox as well as the
corpus so that a light row gets the stamp `r` in the browser would give it,
and the bundle over the file's row for the same reason `loaditems` takes it:
it is the newer of the two. With `fold`, a plain read mark: a row whose
movement is under its source's floor has its key dropped rather than
stamped, see `folded`; a snooze and an archive stamp regardless."""
function mark_read_moved(urls, at::DateTime; fold::Bool = false)
    items = something(fetched("items"), (;))
    inbox = Events.load_inbox()["items"]
    sources = source_since()
    wakes = wake_map()
    us = unique(String(u) for u in urls)
    isempty(us) && return 0
    function upto(u)
        r = bundled(u, jget(items, Symbol(u)))
        r === nothing && (r = get(inbox, u, nothing))
        r === nothing && return stamp(at)
        m = something(moved_of(r), stamp(at))
        fold || return m
        folded(m, floor_of(String(nz(rget(r, "lane"), "activity")),
                           String(nz(rget(r, "repo"), "")), sources))
    end
    # A snooze that has run out goes with the stamp; see `woken_by`.
    set_blocks!([u => woken_by(u, wakes, at) ? ["read" => upto(u), "snooze" => nothing] :
                      ["read" => upto(u)] for u in us])
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
