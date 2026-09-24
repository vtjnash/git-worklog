# The filter and view model: what is shown, in what order, and the pane that
# says so. Tag sets over one list rather than a menu of lanes.
#
# --- filters ---------------------------------------------------------------
#
# The lane menu forced one choice at a time and made you back out to change it,
# and the radio that replaced it was the same mistake in a smaller box: one
# `state` answering three unrelated questions at once, so that asking "what is
# unread" meant giving up "what is mine".
#
# Every axis here is a set. Empty restricts nothing on all of them but the
# first, which adds rather than narrows and where empty is therefore the empty
# list. What each one asks, and what the answers cost:
#
#   * **show** - what you have done with it, one value per row of three, and
#     an axis that only ever adds: a box brings its kind of row in beside the
#     others and takes none away. Empty is therefore the empty list, and the
#     box on when nothing has been asked is the first:
#       - **not done** - the done stamp against `moved_at` and against the
#         snooze's wake time says it moved since, and **nothing overrides
#         it**: an item that moves is unread again whether it is snoozed,
#         yours or a stranger's. A review request, a mention and a reply all
#         land here, which is why none of them needs a lane.
#       - **done** - the stamp is at or past the last movement.
#       - **filed away** - your decision, and the only thing here GitHub cannot
#         see. A mark, `x` writes it, and it wins over the stamp: a filed row
#         is filed whether or not it has moved since, and held out of every
#         view that does not name this box - which is what lets the backlog
#         leave it out.
#     There was a fourth, **snoozed**, and it was not a disposition: a snoozed
#     item is a done one with a wake time, so it is a tag now.
#   * **state** - GitHub's `OPEN` against `CLOSED`/`MERGED`, two boxes, both
#     on when nothing has been asked: a closed thing that moved is news. A
#     view that wants the open work alone names `state = ["open"]`. The two
#     axes are asked separately and a row has to pass both, which is what
#     makes each box's count a plain total against the other rather than a
#     delta that moved as its neighbours were toggled - `closed` used to be a
#     box on the `show` axis that a closed row needed *as well as* its own.
#   * **tag** - the things worth asking that are not any of the above, and
#     several can be true of one row: a question waiting on you (`reply
#     owed`), a review you were asked for (`review owed`), a pull request that
#     wants edits (`needs edits`) or is waiting on a button (`ready`), work
#     that has gone quiet (`waiting on an answer`), work you have acted on (`touched`),
#     words you have written and not sent (`drafts`), and work you put down
#     for a while (`snoozed`).
#   * **kind**, **lane**, **repo**, **label**, **author** - facts on the row.
#     `lane` is which search claimed it, and it stands where `bucket` did.
#
# What is *not* here any more: `active`, `backlog`, `mine` and `bucket`. `mine`
# was the author axis written twice. `active` and `backlog` were one fact
# wearing a state's clothes - which lane fetched the row - and the answer to
# "how do I stop seeing the pile" is now the same as the answer for everything
# else: dismiss it, one item at a time, recorded and undoable. That is the one
# thing this program knows that GitHub does not. `bucket` was one word per row
# from a cascade of rules, first to answer wins, and the cascade is what lost
# the question somebody put to you on a thread that then closed - `done`
# answered first. Every rule in it was a fact the row carries, and a fact can
# be a tag; tags compose and a bucket could not. The one thing it gave that
# the tags do not is a single word for a row, and nothing was reading it.

"""What to show: three boxes, one per disposition, and the first is the
dashboard.

One axis, and it only ever adds - checking a box brings a kind of row *in
beside* whatever is already there, and no box takes another one's rows away.
Every row has exactly one of the three values (`disp_of`), so a box's count is
its rows and nothing else's. `not done` is the unfiled work that moved since
you looked, which is what this program is for, and it is on when nothing has
been asked: `c`, a fresh `Filters` and a view that names no `show` all leave it
checked, so the screen cannot be emptied by accident. Unchecking it is how the
other two are asked for *alone* - the filed work on its own rather than beside
today's. Unchecking every box is an empty list: an empty set of things to show
is no things, which is the honest reading of an axis that adds rather than
narrows.

Open against closed is a second axis, `STATE`, asked of the same row on its
own: the dashboard is not-done rows open *or* closed, since a closed item that
moved - your pull request merged, a closed issue somebody commented on, a
mention on a thread that was settled years ago - is unread like anything else,
and the backlog is not-done and done rows, open only, because a closed thing
is news and not work. Until 2026-09-21 `closed` was a fourth box on this axis
that a closed row needed *as well as* its own, and `base` was one cell - not
done *and* open - so two of the four boxes meant something different from the
other two, and the number beside each was a delta that moved as its
neighbours were toggled.

`filed` wins over the stamp - see `disp_of`. "Show me what I put down for
now" is a different question from "show me what I gave up on", and it is the
`snoozed` tag over the `done` box rather than a box of its own: a snooze is a
done mark with a wake time, and the wake is a reason to be unread again, not a
place to be.

The readings the values come from are `seen_of`, `filed_of` and `over_of` -
what is here is the control over them, not the facts.

The mark is *done*, the GitHub inbox's and Gmail's word for a thread put
away that comes back when it moves; *unread* stays the word for the fact -
an item moved since your mark: the bold row, `why  unread:`, `wl unread` -
and in this program those are the same two states. The TOML keys follow the
labels, and so does the stamp in `local.toml`, `done`, and `wl done`.
"""
const NOT_DONE = Symbol("not-done")
const SHOW = [(NOT_DONE, "not done"), (:done, "done"), (:filed, "filed away")]

"The other axis a row is in or out on: open, or closed and merged. See `SHOW`."
const STATE = [(:open, "open"), (:closed, "closed or merged")]

"""The boxes that are on when nothing has been asked; see `isdefault` and `c`.

Not done, open or closed - the dashboard is the unfiled work that moved,
whatever its state - and not the open half alone, which is the floor the
backlog stands on; see `SHOW`.

Compared against, never pushed into - the `Filters` default below writes the
sets out again rather than naming these, because a shared mutable default would
make one item's `show` every item's.
"""
const SHOW_DEFAULT = Set([NOT_DONE])
const STATE_DEFAULT = Set([:open, :closed])

"""The questions that are not an axis of their own.

Each is a mark or a derivation rather than a field: `reply`, `review`, `edits`,
`ready` and `second` are worked out every refresh - from a mention, a request,
a verdict, and silence - and `touched`, `drafts` and `snoozed` are rows in
`local.toml`. Unlike the axes above an item can carry several at once, so
these behave like labels - any of the ones you pick brings the row.

The first five were the bucket, and are tags on purpose. A bucket is one
answer per row and a closed row's answer is `done`, so "somebody asked you
something on this" was lost the moment the thread closed. A tag is a fact
beside the others, and over the default `show` it is exactly the list the
`unanswered` view is: unread, reply owed, open or closed. The others are the
same shape: `review` is a request you have not answered, `edits` is a verdict
or a red run on a pull request, `ready` is approved and green, and a view
names whichever it means beside whichever author it means.

`mentioned` is the wide one `reply` is carved out of: named, ever, however
long ago and whoever spoke last - a latch on the row, not the notification's
reason, which moves on with the next comment; see `Events.mention_words`.

`snoozed` is a wake time that has not come yet. One that has is not a tag any
more, it is the item being unread - see `seen_of`.
"""
const TAGS = [(:reply, "reply owed"), (:mentioned, "mentioned"),
              (:review, "review owed"), (:edits, "needs edits"),
              # Named for what it is for and not for what it does: "second
              # look" was the rule's own name, and "who is waiting on me" did
              # not find it by reading. The two views that read it are
              # "waiting on me" and "waiting on them", by author.
              (:ready, "ready to merge"), (:second, "waiting on an answer"),
              (:touched, "touched"), (:drafts, "drafts"), (:snoozed, "snoozed")]

"""How the list is ordered. Its own control, deliberately.

Sorting is orthogonal to all three filter axes - any order makes sense over any
selection - so it does not belong inside `Filters`, where it would multiply the
axes instead of sitting beside them. `w` cycles it.

Four orders, and each is the one of the three views it was made for; see
`lane_sort` for which selection implies which.

`:moved` is GitHub's clock alone - the head commit, else the last comment, else
`updated` - and the firehose's order: what happened most recently is at the
top, whoever did it. It is the default, and the order the browser opens in.

`:latest` is the later of that and your own last interaction, which is the
order your work reads in: something you answered this morning belongs above
something that moved yesterday, and the reverse too. `:touched` is your clock
alone, with GitHub's standing in where it is empty - what you last dealt with,
which is what the `touched` selection is asking.

`:name` is the url order, descending: owner, then project, then number - the
backlog's order. That is what `facts.json` is written in - it is sorted by key,
and the key is the url - so it keeps the grouping the file has, everything from
one repo together, and reads from the newest of each rather than from two
thousand rows ago. The number is taken as a number and not as the digits it is
spelled with; see `urlkey`.

The two that read the interaction clock tie over a batch of imports, which one
`at` stamped together; a tie on any clock falls through to the url order, so a
batch reads the way the backlog does rather than the way the sort left it.
"""
const SORTS = [(:moved, "by when it moved"),
               (:latest, "by when anything last happened"),
               (:touched, "by when you last acted"),
               (:name, "by url, newest first")]

"""Issue, pull request, or both - the third radio group.

A radio and not a fourth tag axis: the values are exhausted by three and they
are mutually exclusive, so a set of them would only ever hold one thing or say
nothing. `Item.is_pr` was already there and every lane carries both kinds, which
is what made "issues only" impossible to ask for and obvious to want.
"""
const KINDS = [(:both, "both"), (:pr, "pull requests"), (:issue, "issues")]

"""The order a selection opens in, where it implies one.

Each order is the one of the three views it was made for, and the rule reads
the axis that makes the view what it is - so the order follows a selection
made by hand as well as the view, and a view names `sort` only to say
something this table would not.

`touched` alone *is* the interaction clock - membership in it is having acted on
something - so the clock is the order it means, and arriving in it sorted by
anything else asks the reader to press `w` to see the thing they came for.

Your own work is the author axis naming you, and it reads by the later of the
two clocks: what you did to it counts for as much as what happened to it.

The backlog is the open list with the done ones beside it and nothing else -
`show` exactly not done and done, `state` open, no tag - and it is a standing
list rather than news, so it reads in the order the file is written in, by url.

Everything else is what moved, newest first, which is the order an inbox has
and the answer use gave to the question this table used to leave open.
"""
lane_sort(f) = f.tags == Set([:touched]) ? :touched :
               AUTHOR_ME in f.authors ? :latest :
               f.show == Set([NOT_DONE, :done]) && f.state == Set([:open]) &&
                   isempty(f.tags) ? :name : :moved

# Whose it is, as two values of the author axis that are not logins.
#
# `mine` answers half of the question - your own open pull requests - and nothing
# answered the other half, which is the more common one: somebody else's work
# that is in front of you. So the axis carries two members that are predicates
# rather than names. They are OR-ed with any logins picked beside them, like
# every other value in an axis, and `@` cannot begin a GitHub login, so neither
# can collide with one.
const AUTHOR_ME = "@me"
const AUTHOR_OTHERS = "@anyone-else"

Base.@kwdef mutable struct Filters
    show::Set{Symbol} = Set([NOT_DONE])    # which kinds of row to show, of the
                                           # three there are; not done is the
                                           # dashboard and is what an unasked
                                           # question answers. Empty shows
                                           # nothing. Written out rather than
                                           # `SHOW_DEFAULT`, which would be one
                                           # set shared by every filter. `SHOW`
    state::Set{Symbol} = Set([:open, :closed]) # and of the two states; both,
                                           # unasked. Empty shows nothing. `STATE`
    tags::Set{Symbol} = Set{Symbol}()      # empty means no restriction; `TAGS`
    lanes::Set{String} = Set{String}()     # empty means every lane
    repos::Set{String} = Set{String}()     # empty means every repo
    labels::Set{String} = Set{String}()    # empty means every label
    kind::Symbol = :both                   # :both | :pr | :issue
    authors::Set{String} = Set{String}()   # empty means anybody; @me and
                                           # @anyone-else are values here as
                                           # well as logins
end

"""What the browser opens on: the notifications, unfiled, open or closed.

Unread is what moved since you looked at it, whoever moved it - a review
request, a mention, a reply, a push, a merge - which is the one list that is
about *today*. Awake because "I do not want to see this" is a decision you made
and honouring it by default is the whole of what it means.

A bare `Filters`, because `show` defaults to the not-done box and `state` to
both of its: this list is what the program is, so it is what a filter says when
it has been asked nothing. `c` clears the filters *to* it, the other two `SHOW`
boxes are how the rest of the corpus comes back, and unchecking not done itself
is how one of them is asked for alone.
"""
DEFAULT_FILTERS() = Filters()

"""Every row there is: every box on, on both axes.

The corpus, which used to be what a bare `Filters` meant. Two places need it -
a jump to one item by number and a jump to the item a worktree belongs to -
because there the row being hidden is exactly the row asked for, and one view
offers it by name.
"""
everything() = Filters(show = Set(k for (k, _) in SHOW))

"""Is anything asked of this filter at all?

Asked of the value rather than tracked, so it stays true however the filter got
here: a view, a picker, `\`` going back, or every checkbox toggled off one at a
time all reach the same place, and the row that offers to clear it should say
so in all four.

`c` clears to where the browser opens rather than to the corpus: every axis
empty, `show` back to the not-done box and `state` to both, which is what an
unasked question answers here. `\`` is the way back to what you had, and the
other two `SHOW` boxes are the way back out to the corpus.
"""
isdefault(f::Filters) =
    f.show == SHOW_DEFAULT && f.state == STATE_DEFAULT && isempty(f.tags) &&
    f.kind === :both && isempty(f.lanes) && isempty(f.repos) &&
    isempty(f.labels) && isempty(f.authors)

"One empty map, shared, for every caller that has no marks to hand."
const EMPTY_TOUCHED = Dict{String,String}()
"And one empty set, for a caller with no sessions to ask."
const EMPTY_RANG = Set{String}()

"""What is recorded about the items on screen, as one argument.

The marks the filters ask of every row. They travelled as four and then five
positional arguments with defaults, which is a list that grows every time the
model learns something and is wrong the moment one caller passes them in the
other order.

References, not copies - `BState` owns the maps and re-reads them whenever
something changes; this is a way of naming all of them at once, made per
`refilter!` and thrown away with it.
"""
Base.@kwdef struct Marks
    done::Dict{String,String} = EMPTY_TOUCHED
    sources::Dict{String,String} = EMPTY_TOUCHED   # source label -> the day it was
                                                    # named: the floor a row with no
                                                    # stamp is done up to; see `seen_of`
    touched::Dict{String,String} = EMPTY_TOUCHED
    archived::Dict{String,String} = EMPTY_TOUCHED
    drafts::Dict{String,String} = EMPTY_TOUCHED
    wake::Dict{String,String} = EMPTY_TOUCHED   # url -> when its snooze ends
    now::String = stamp(utcnow())   # the instant the wakes are read against,
                                    # one per `refilter!` so a list is not
                                    # half-woken across its own rows
    rang::Set{String} = EMPTY_RANG  # urls whose agent rang with nobody
                                    # looking: tmux's bell, `rang_urls`
end
Marks(st, at::DateTime = utcnow()) =
    Marks(st.done, st.sources, st.touched, st.archived, st.drafts, st.wakes, stamp(at),
          st.rang)

"""Has this item changed since you last looked at it?

    seen_of(it, marks) -> :unread | :done

The done stamp against `moved_at`, and **nothing overrides it**. Not a snooze,
not a filing, not whose it is: movement makes a thing unread, because unread is
not a claim about wanting to see something - it is a claim about whether it has
changed since you last did.

**`moved_at` and not `updated`.** GitHub's own timestamp does not move when a
check run finishes and does move when somebody relabels a pull request, so it
misses the thing you asked to be told about and reports things you did not.
`moved_at` is when the refresh last saw a change *at this item's tracking
level* - so your own pull request turning red is unread and a stranger's is
not, which is what `track` is for and what it did not used to reach. An item no
refresh has seen - a row the activity poll alone knows about - has no
wake table to compare, and there `updated` is the only answer anybody has.
`moved_of` is that rule, and it is the rule every mark stamps by, so what is
compared here is what `e`, `s`, `x` and `wl done` wrote.

**And a snooze is a second reason, beside the table.** A snooze is a wake
time; once it has passed it is as if the item moved then, and it is unread
until you read it again. Asked of the clock here, per frame, rather than
decided by a refresh and carried on the item: waking needs no write and no
arbiter, so two browsers on one dashboard cannot disagree about it, and a
snooze that runs out at lunch is back before the next `wl refresh`. It used to
be the refresh's alone to decide, because the old snooze *armed* against a
hash and wrote `WOKE` when it differed - a decision that had to be recorded
exactly once. A time needs nothing recorded.

**And an agent that stopped on it is a third.** The agent in its `T` pane
rings as its turn ends or as it asks, and tmux keeps the bell while nobody is
attached (`rang_urls`). That is a seen bit already - looking clears it - so it
is read as one: unread while it stands, whatever the stamp says, since it has
no time to compare and needs none. Every mark clears it (`agent_seen!`), for
the reason the woken snooze taught: a reason left standing beside the stamp
would keep the row unread whatever was pressed.

No stamp at all reads against the floor - the day the row's source was named,
`floor_of` - and as unread only where there is none, which is what "never been
in front of you" means. It used to be a third value, `unseen`, on the theory
that the firehose browse wanted it: it does not. What takes something out of
that pile is dismissing it, and what an item you have never opened has in
common with one that moved this morning is exactly that you have not seen what
it says now.

Computed rather than stored. On `Item` it would be derived state that goes stale
the moment `e` is pressed - `Item` is immutable and rebuilt by the refresh - so
the browser would have to rewrite every row it touched.
"""
function seen_of(it::Item, m::Marks = Marks())
    it.url in m.rang && return :unread
    at = get(m.done, it.url, nothing)
    # Nothing said about it: it is done up to the day its source was named,
    # whatever the lane - day zero reads zero - and unread if the source has
    # no block. An empty stamp is something said - unread - and is earlier
    # than any movement below.
    at === nothing && (at = floor_of(it, m.sources))
    at === nothing && return :unread
    # An item with no movement on record is a synthetic one - an adopted
    # branch, an import no refresh has caught up with - and a stamp on it is
    # the only thing anybody has said about whether it has been seen.
    moved = something(moved_of(it), "")
    wake = get(m.wake, it.url, nothing)
    wake !== nothing && wake <= m.now && wake > moved && (moved = wake)
    at < moved ? :unread : :done
end

"""Have you filed this away?

    filed_of(it, marks) -> Bool

The `archived` mark. Filed is read - `x` stamps both - with one difference:
a read item that moves comes back on its own, and a filed one that moves is
unread too but comes back only when the `filed` box is on. That difference is
the whole reason it is a mark of its own and not a done stamp: it is what
lets the backlog - read work and unread work together - leave out the work you
gave up on.
"""
filed_of(it::Item, m::Marks = Marks()) = haskey(m.archived, it.url)

"""Is its snooze still running?

    asleep(it, marks) -> Bool

A wake time that has not come. Once it has, the item is unread rather than
asleep, and this is false.
"""
function asleep(it::Item, m::Marks = Marks())
    wake = get(m.wake, it.url, nothing)
    wake !== nothing && wake > m.now
end

"Is it finished? Empty reads as open, which is what a synthetic item is."
over_of(it::Item) = (it.state == "CLOSED" || it.state == "MERGED") ? :closed : :open

"""The tags an item carries, of the nine there are.

Unlike the axes, several can be true at once, so this answers with a set and the
axis behaves like labels: any tag you pick brings the row.
"""
function tags_of(it::Item, m::Marks = Marks())
    out = Symbol[]
    isempty(it.reply) || push!(out, :reply)
    isempty(it.mentioned) || push!(out, :mentioned)
    isempty(it.review) || push!(out, :review)
    isempty(it.edits) || push!(out, :edits)
    isempty(it.ready) || push!(out, :ready)
    isempty(it.secondlook) || push!(out, :second)
    haskey(m.touched, it.url) && push!(out, :touched)
    haskey(m.drafts, it.url) && push!(out, :drafts)
    asleep(it, m) && push!(out, :snoozed)
    out
end

"""Which `SHOW` box a row is under: filed wins, else the stamp.

    disp_of(seen, filed) -> :not-done | :done | :filed

Filing stamps done - see `archive!` - so a `filed` box that also asked the
stamp would have shown nothing at all, and the reader would have had a control
that did not work rather than a list. What you filed is what you filed, moved
since or not; the done stamp is how the *pile* gets shorter, and the filed mark
is how the backlog gets shorter without the pile changing. So a filed row is
under `filed` whatever its stamp says, and the other two boxes are asked of
unfiled rows only.
"""
disp_of(sn::Symbol, fd::Bool) = fd ? :filed : sn === :unread ? NOT_DONE : :done

"""Is a row in, on the two disposition axes?

    show_ok(show, state, seen, filed, over) -> Bool

Two memberships: the row's `SHOW` value is checked, and its `STATE` value is.
Each axis is a set of the values it lets through and a row has exactly one
value on each, so adding a box can only ever bring rows in, and `axis_counts`
relies on that: the number beside a box is its rows that pass the *other*
axis, the same number whether it is on or off. Unchecking every box on either
axis shows nothing, and that is the honest reading of it rather than a case to
special-case.
"""
show_ok(show::Set{Symbol}, state::Set{Symbol}, sn::Symbol, fd::Bool, ov::Symbol) =
    disp_of(sn, fd) in show && ov in state

"The same, asked of an item."
shown(f::Filters, it::Item, m::Marks = Marks()) =
    show_ok(f.show, f.state, seen_of(it, m), filed_of(it, m), over_of(it))

"""The timestamp a sorted list is ordered by, under one of three readings of
when.

`:moved` is GitHub's clock, `act`, and nothing of yours: *when did this last
happen*. `:touched` is your own last interaction if there is one and the remote
time only otherwise: *when did I last deal with this*. `:latest` is the later of
the two, *when did anything happen to this* - the order notification mail would
have arrived in, with your own work folded into it.

They differ exactly where both exist. An item you touched in March that somebody
commented on this morning sorts to March under `:touched` and to this morning
under the other two; one you answered this morning that last moved in March
sorts to March under `:moved` and to this morning under the other two. None is
righter than another - a to-do list wants the first, a firehose the second, and
your own work the third - and the same key gives all three rather than choosing
on the user's behalf.

One key rather than two groups, under any reading. A branch nothing has been
done to but that was committed to this morning belongs above a pull request last
touched in March, and splitting the list into touched-then-untouched would bury
it.
"""
function sortkey(it::Item, touched::Dict{String,String}, order::Symbol = :touched)
    order === :moved && return it.act
    t = get(touched, it.url, "")
    order === :latest && return max(t, it.act)
    isempty(t) ? it.act : t
end

"""What a url is made of: owner, project, number - and the url itself, so the
order is total.

The url order wants the three separately rather than as the string they are
written into. A url sorts as text, and text puts `#6661` above `#62836` because
it compares a character at a time; the number is a number, and taking it as one
is the whole of the fix. The first two keep the grouping that made url order
worth having - everything from one repo together, and one owner's repos
together - and the third stops lying about which of them is newer.

Not stored on the item, and not split into `facts.json` either: the row already
carries `repo` and `number`, so an owner and a project beside them would be the
same fact written twice, and a field only a refresh can fill in is one that is
missing from every snapshot written before it.

The url is last, and it is there for one class of item only. GitHub numbers
issues and pull requests from a single sequence per repository, so the first
three already tell any two of *those* apart. An adopted branch has no number at
all - every one in a repo is `0` - so they tie on all three, and the order two
of them come out in should not depend on which the file happened to hold first.
`it.branch` would separate them equally well, since a `local:` url is built from
the repo and the branch; the url is what the rest of this program keys on, so
totality is true of it by construction rather than by an argument about branches.
"""
function urlkey(it::Item)
    parts = split(it.repo, '/'; limit = 2)
    (String(first(parts)), length(parts) > 1 ? String(parts[2]) : "",
     it.number, it.url)
end

"""Newest first, with the url order under every clock.

All four orders are newest-first; they differ in what "newest" is. `:name` is
the url alone, which is the order `facts.json` is written in - by owner, project
and number - read from the top instead of from two thousand rows ago. The other
three are a timestamp, and a tie on it - a batch of imports, stamped together
with the one `at` the import ran under; a run of untimed rows - is broken by
the url the same way, so two items that agree on when read in a known order
rather than in whichever one the sort happened to leave them."""
sortitems(items, mode::Symbol, touched::Dict{String,String}) =
    mode === :name ? sort(items; by = urlkey, rev = true) :
    sort(items; by = it -> (sortkey(it, touched, mode), urlkey(it)), rev = true)

"Issue or pull request, with `:both` restricting nothing."
kind_ok(kind::Symbol, it::Item) = kind === :both || (kind === :pr) == it.is_pr

"""Whose it is. An empty set restricts nothing, as on every other axis.

`@me` is author **or assignee**, which is the whole of what makes an item yours
to finish. Being asked to review something, or being named in a thread, is what
makes it *unread* - somebody wants something from you, and that is a question
the attention axis answers - and it does not put the item in your pile.

An adopted branch has no author and is therefore yours: it is in this dashboard
because you claimed it, and nobody else wrote it.
"""
function author_ok(authors::Set{String}, it::Item)
    isempty(authors) && return true
    mine = it.author == login() || login() in it.assignees ||
           (isempty(it.author) && islocal(it))
    (mine && AUTHOR_ME in authors) && return true
    (!mine && AUTHOR_OTHERS in authors) && return true
    it.author in authors
end

"""Is this row in the list?

An empty set restricts nothing on every axis but `show`, which adds rather than
narrows and where empty is therefore nothing at all. A bare filter has the base
box alone, which is the list the browser opens on.
"""
function matches(f::Filters, it::Item, m::Marks = Marks())
    shown(f, it, m) || return false
    isempty(f.tags) || any(in(f.tags), tags_of(it, m)) || return false
    kind_ok(f.kind, it) || return false
    author_ok(f.authors, it) || return false
    isempty(f.lanes) || it.lane in f.lanes || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    isempty(f.labels)  || any(in(f.labels), it.labels) || return false
    true
end

"""
    axis_counts(st) -> (; shows, states, tags, kinds, lanes, repos, labels, authors)

How many items each filter value would select, in one pass over the items.

Every count is against the *other* axes only - a category shows what selecting
it would add, not a total that ignores the rest of the filter - so there is one
predicate per axis over the same item, eight of them, and computing them together
is what makes this one pass instead of one per row. It was a pass per row: 93 rows
over 2050 items came to 190,650 `matches` calls per build and two builds per
keystroke, which made the filter pane the only part of the UI with visible lag -
128ms a frame against 0.7ms for the item list.

`shows` and `states` are tallies like the rest, since a row has one value on
each: the number beside a box is its rows that pass every other axis, which is
what checking it would bring or unchecking it would take - the same number
either way. They were not, while closed was a box on `show` that a closed row
needed as well as its own: each box was then worth a with-minus-without.
"""
function axis_counts(st)
    f, m = st.filters, Marks(st)
    shows = Dict{Symbol,Int}(); states = Dict{Symbol,Int}(); tagn = Dict{Symbol,Int}()
    kinds = Dict{Symbol,Int}(); lanes = Dict{String,Int}()
    repos = Dict{String,Int}(); labels = Dict{String,Int}()
    authors = Dict{String,Int}()
    bump!(d, k) = d[k] = get(d, k, 0) + 1
    for it in st.all
        sn, sl, ov, tg = seen_of(it, m), filed_of(it, m), over_of(it), tags_of(it, m)
        dp = disp_of(sn, sl)
        # Every axis, answered once, in the order the pane draws them.
        ok = (dp in f.show, ov in f.state,
              isempty(f.tags) || any(in(f.tags), tg),
              kind_ok(f.kind, it), author_ok(f.authors, it),
              isempty(f.lanes) || it.lane in f.lanes,
              isempty(f.repos) || it.repo in f.repos,
              isempty(f.labels) || any(in(f.labels), it.labels))
        # Each count is against the *other* axes only, so a value shows what
        # picking it would bring rather than a total that ignores the rest of
        # the filter. Which is: this row already passes everything except
        # possibly the axis being counted - one subtraction rather than a pass
        # per axis per row.
        nfail = count(!, ok)
        others(i) = nfail == 0 || (nfail == 1 && !ok[i])
        others(1) && bump!(shows, dp)
        others(2) && bump!(states, ov)
        if others(3)
            for t in tg
                bump!(tagn, t)
            end
        end
        if others(4)
            for (k, _) in KINDS
                kind_ok(k, it) && bump!(kinds, k)
            end
        end
        if others(5)
            # One item counts towards its own author *and* towards whichever of
            # the two predicates it answers, since picking either would bring it.
            isempty(it.author) || bump!(authors, it.author)
            author_ok(Set([AUTHOR_ME]), it) && bump!(authors, AUTHOR_ME)
            author_ok(Set([AUTHOR_OTHERS]), it) && bump!(authors, AUTHOR_OTHERS)
        end
        others(6) && bump!(lanes, it.lane)
        others(7) && bump!(repos, it.repo)
        if others(8)
            for l in it.labels
                bump!(labels, l)
            end
        end
    end
    (; shows, states, tags = tagn, kinds, lanes, repos, labels, authors)
end

apply_filters(f, all, m::Marks = Marks()) = [it for it in all if matches(f, it, m)]

"""Which axes list only what is applied, and reach the rest through the picker.

The pane used to try to show what was *available*, and there is too much of it:
~140 repos, several hundred labels, more authors than either. Showing the first
eight of them was a compromise that served neither purpose - too many rows to
skim and too few to choose from, in an order nobody could predict.

So these axes are a readout of what is *on*, and the picker row underneath is
where choosing happens. It has every value and it narrows by typing, which is
the only thing that scales to several hundred; and the pane collapses to the
length of the answer rather than the length of the question.

Category is exempt, and is the whole axis: a dozen or so values that are each
a different kind of work, short enough to read at a glance and the one nobody
would think to search for by name.
"""
const AXIS_APPLIED_ONLY = (:repo, :label, :author)

"""`[filters] pinned_repos` from the config: the repos listed on the pane
whether or not they are applied, as written there - a name or `owner/*`."""
pinned_filter_repos(cfg = config()) =
    String[String(r) for r in get(get(cfg, "filters", Dict{String,Any}()),
                                  "pinned_repos", String[])]

"""The repo axis in the order the pane lists it: the pinned repos first, in the
order they were written, then the rest alphabetically.

A pinned entry is listed whether it is applied or not, and at zero - the point
of pinning one is that it is in the same place every time, one `↵` away, and a
row that comes and goes with the count is not. `owner/*` is every repo of that
owner the corpus has, alphabetically, so the entry `[events] repos` already
takes is the entry this takes.
"""
function repo_axis(st)
    out = String[]
    for p in st.pinned
        if endswith(p, "/*")
            for r in st.repos
                startswith(r, p[1:end-1]) && !(r in out) && push!(out, r)
            end
        else
            p in out || push!(out, p)
        end
    end
    npin = length(out)
    for r in st.repos
        r in out || push!(out, r)
    end
    (out, npin)
end

"The set an axis filters on, which is where a picked value lands."
axis_set(f::Filters, axis::Symbol) =
    axis === :lane ? f.lanes : axis === :repo ? f.repos :
    axis === :label ? f.labels : f.authors

"The same, for the three axes whose values are symbols rather than names."
sym_set(f::Filters, axis::Symbol) =
    axis === :show ? f.show : axis === :state ? f.state : f.tags

"How a value of `axis` is written in the pane. Only the author axis has any."
axis_label(axis::Symbol, v::AbstractString) =
    axis !== :author ? String(v) :
    v == AUTHOR_ME ? string("me (", login(), ")") :
    v == AUTHOR_OTHERS ? "anyone else" : String(v)

"""The views `\'` offers, from the config, in the order they were written.

A view is a whole filter set under a name. The pane composes state × kind × repo
× label × author, which is enough to ask almost anything and far too much to
retype - so what was missing was never expressiveness, it was *recall*.

The defaults are deliberately composites. A single tag is already one `f`
away and needs no name; what needs one is the pair of axes nobody assembles
twice.

Read and never written: `data/config.toml` is the user's file, and `wl watching`
already established what this program does when it wants to suggest a line for
it - it prints one to paste.
"""
const VIEWS = [
    # The way back to where the browser opens, and the first row for the same
    # reason the import row leads the item list: a control nobody can find is a
    # control nobody uses. It names no axis at all, because the list it goes to
    # is what is left when every axis is off - and no `sort`, because each of
    # these three is what one of the orders was made for and `lane_sort` reads
    # it off the selection: this one by when it moved, the next by the later
    # of that and when you acted, the backlog by url.
    ("notification firehose — unread, open or closed", Dict{String,Any}()),
    # The two modes that are left. Which work is yours is the author axis; what
    # has moved is the base. One axis per question, and neither of them a lane.
    # This one is the *open* work, done or not: it names `show` and `state` the
    # way the backlog does, because left to the default it was the not-done
    # rows open or closed - your merged pull requests standing in for the ones
    # you have done and are still carrying, which is the opposite of what the
    # view is for.
    ("my work — mine, open, done ones too",
                       Dict("author" => [AUTHOR_ME], "show" => ["not-done", "done"],
                            "state" => ["open"])),
    # The backlog. It names `state` open only, which is the one place it and
    # the dashboard come apart: a closed thing that moved is news and belongs
    # in the firehose, and it is not work and does not belong here.
    ("open items — the backlog, done ones too",
                       Dict("show" => ["not-done", "done"], "state" => ["open"])),
    ("waiting on me",  Dict("tag" => ["second"], "kind" => "pr",
                            "author" => [AUTHOR_OTHERS])),
    ("waiting on them", Dict("tag" => ["second"], "author" => [AUTHOR_ME])),
    ("ready to merge", Dict("tag" => ["ready"])),
    ("needs edits, mine", Dict("author" => [AUTHOR_ME], "tag" => ["edits"])),
    # A tag, so a closed thread somebody asked you something on is in it: the
    # default `show` has the closed news, and the tag does not care about
    # state. See `TAGS`.
    ("unanswered — unread, reply owed", Dict("tag" => ["reply"])),
    ("snoozed — put down for a while", Dict("show" => ["done"], "tag" => ["snoozed"])),
    # The corpus, which no longer has a keystroke of its own: it is the
    # dashboard with the two things it leaves out added back to it, and it
    # names all three because a view that names the axis names the whole of it.
    ("everything — done, filed and closed too",
                       Dict("show" => ["not-done", "done", "filed"])),
]

"The keys a view may name. Anything else in one is a misspelling; see `apply_view!`."
const VIEW_KEYS = ("show", "state", "tag", "kind", "lane", "repo", "label", "author", "sort")

"Every view: the built-in ones, then whatever `[views]` in the config adds or replaces."
function views(cfg = config())
    out = Tuple{String,Any}[(n, d) for (n, d) in VIEWS]
    for (name, d) in get(cfg, "views", Dict{String,Any}())
        i = findfirst(x -> x[1] == String(name), out)
        i === nothing ? push!(out, (String(name), d)) : (out[i] = (String(name), d))
    end
    out
end

"""Apply one view, and answer with what it did.

A view sets every axis it names and clears every axis it does not, because half
of a remembered filter is worse than none: the point of a name is that pressing
it twice from different places lands in the same list.
"""
function apply_view!(st, d)
    f = Filters()
    bad = ""
    # Said rather than silently ignored. An axis takes a set, and an empty set
    # restricts nothing - so a value that is not one of the axis's would quietly
    # widen the view instead of narrowing it, which reads as a view that has
    # stopped filtering rather than as one that is misspelt. It cost a real bug
    # the day `mine` was removed: the built-in "red CI, mine" went on naming it
    # and went on returning the right twelve rows, because every `needs-edits`
    # item happened to be yours. `config.toml` writes these by hand.
    #
    # And no alias for a spelling that has been retired. `show` was `base`,
    # `read`, `filed`, `done` until 2026-09-21, when the boxes were renamed,
    # `done` moved from the closed-or-merged box to the read one, and open
    # against closed became `state`: a view from before, read quietly under
    # the new names, would show a different list than it says, so it is
    # reported here like a misspelt one.
    for (key, values, set) in (("show", SHOW, f.show), ("state", STATE, f.state),
                               ("tag", TAGS, f.tags))
        haskey(d, key) || continue
        # Named means named *whole*, the not-done box included - a view that says
        # `show` says which of its boxes are checked, and one that says nothing
        # keeps the default the fresh `Filters` above already has. Emptying
        # first is what makes "the filed ones alone" nameable, and it is the
        # same rule as every other axis: a name means one list, from anywhere.
        empty!(set)
        v = d[key]
        for x in (v isa AbstractString ? [v] : v)
            k = Symbol(x)
            any(y -> y[1] === k, values) ? push!(set, k) :
                (bad = string(" \u00b7 no ", key, " '", x, "'"))
        end
    end
    # And an axis that is not one of them is said too, for the same reason a
    # value that is not one of the axis's is: an unknown key filters nothing, so
    # a view that names one quietly shows more than it says. `seen` and
    # `sleep` were keys here until the dispositions merged, and a
    # `config.toml` still spelling them would otherwise go on working and mean
    # something else.
    for key in keys(d)
        key in VIEW_KEYS ||
            (bad = string(bad, " \u00b7 no axis '", key, "'"))
    end
    haskey(d, "kind") && (f.kind = Symbol(d["kind"]))
    for (k, set) in (("lane", f.lanes), ("repo", f.repos),
                     ("label", f.labels), ("author", f.authors))
        haskey(d, k) || continue
        v = d[k]
        for x in (v isa AbstractString ? [v] : v)
            push!(set, String(x))
        end
    end
    st.prev = st.filters                # `\`` is the way back out
    st.filters = f
    # Cleared like every other axis when the view names none, and for the same
    # reason: a name has to mean the same list from wherever it is pressed, and
    # an order left over from the list you were in is not that. Naming one
    # overrides what the selection implies - `sort = "name"` on a selection
    # that would open by a clock. And an order that is not one of the four is
    # said, like a value on any other axis: `none` was the url order's name,
    # and a view still spelling it would otherwise sort by a symbol nothing
    # reads and cycle `w` from nowhere.
    order = haskey(d, "sort") ? Symbol(d["sort"]) : lane_sort(f)
    if !any(x -> x[1] === order, SORTS)
        bad = string(bad, " \u00b7 no sort '", d["sort"], "'")
        order = lane_sort(f)
    end
    st.sort = order
    refilter!(st; keeprow = false)
    string("[", filter_summary(f, st.sort), "]", bad)
end

"""The current filter written as the TOML line that would name it.

The browser does not write `data/config.toml`; this is the paste-able form, which is
the same answer `wl watching` gives for the repos you watch. A filter you got to
by hand is the one worth keeping, and it is also the one you cannot reconstruct
from memory an hour later.
"""
view_toml(f::Filters, order::Symbol, name::AbstractString = "a name") =
    join(vcat([string("[views.", repr(String(name)), "]")], view_lines(f, order)), "\n")

"The body of that: one `key = ...` line per axis that is applied."
function view_lines(f::Filters, order::Symbol)
    lines = String[]
    # Written unless it is what a view that names no `show` would get anyway -
    # which is the not-done box, not the empty set: `show = []` is a real
    # filter here, and one that has to survive being written down.
    for (key, values, set, quiet) in (("show", SHOW, f.show, SHOW_DEFAULT),
                                      ("state", STATE, f.state, STATE_DEFAULT),
                                      ("tag", TAGS, f.tags, Set{Symbol}()))
        set == quiet && continue
        # In the axis's own order rather than the set's, so the same filter
        # writes the same line every time.
        push!(lines, string(key, " = [",
                            join([repr(String(k)) for (k, _) in values if k in set],
                                 ", "), "]"))
    end
    f.kind === :both || push!(lines, string("kind = ", repr(String(f.kind))))
    for (k, set) in (("lane", f.lanes), ("repo", f.repos),
                     ("label", f.labels), ("author", f.authors))
        isempty(set) && continue
        push!(lines, string(k, " = [",
                            join([repr(x) for x in sort(collect(set))], ", "), "]"))
    end
    # Like `show`: written unless it is what a view naming no `sort` would
    # get anyway, which is the selection's own order and not any fixed one.
    order === lane_sort(f) || push!(lines, string("sort = ", repr(String(order))))
    lines
end

"""Rows for the filter pane: the way out, what to show and in which state, the
tags, the kind radio, then four more checkbox axes.

Counts are computed against the other axes only, so a category shows how many
items selecting it would actually add rather than a total that ignores the rest
of the filter.
"""
function filter_rows(st)
    f, rows = st.filters, Tuple{Symbol,String,String}[]
    n = axis_counts(st)
    # The way out, at the top, for the same argument the import row won: `c`
    # has always done this and nothing on screen said so. It leads because a
    # filter you want to abandon is one you are already lost in, and the top of
    # the pane is the one place the cursor can reach without reading anything.
    push!(rows, (:reset, "", string("  ↺ clear every filter",
                                    isdefault(f) ? "" : "  (c)")))
    # The three axes that are about the item and you rather than about what it
    # is. `show` and `state` partition the rows - one value each - and the tags
    # do not: a row can carry all three or none. The number beside a box is
    # what checking it would bring, or what unchecking it would take away - the
    # same number either way, which is the only one worth printing next to a
    # control.
    #
    # Not done leads its axis and is a box like the other two, so the count
    # beside it says what the dashboard is currently worth and the cursor can
    # take it off. It is the one box whose being on is the default rather than a
    # choice, which is what `c` puts back.
    for (axis, label, values, tally, sel) in
            ((:show, "show", SHOW, n.shows, f.show),
             (:state, "state", STATE, n.states, f.state),
             (:tag, "tag", TAGS, n.tags, f.tags))
        push!(rows, (:head, "", label))
        for (k, name) in values
            push!(rows, (axis, string(k), string(k in sel ? "[x] " : "[ ] ",
                                                 rpad(name, 24), get(tally, k, 0))))
        end
        push!(rows, (:head, "", ""))
    end
    push!(rows, (:head, "", "kind"))
    for (k, name) in KINDS
        push!(rows, (:kind, string(k), string(f.kind === k ? "(•) " : "( ) ",
                                              rpad(name, 24), get(n.kinds, k, 0))))
    end
    repos, npinned = repo_axis(st)
    for (axis, label, values, tally) in ((:lane, "lane", st.lanes, n.lanes),
                                         (:repo, "repo", repos, n.repos),
                                         (:label, "label", st.labels, n.labels),
                                         (:author, "author", st.authors, n.authors))
        push!(rows, (:head, "", ""))
        push!(rows, (:head, "", label))
        sel = axis_set(f, axis)
        for (j, v) in enumerate(values)
            cnt = get(tally, v, 0)
            on = v in sel
            # `me` and `anyone else` are the axis's two controls rather than two
            # of its values, and a control is worth offering when it would
            # select nothing: that it selects nothing is the answer. Narrow to a
            # repo you have written nothing in and the whole axis used to
            # vanish - no rows at all, not even the half of it that had items.
            # A pinned repo is the same kind of thing: a row that is there to
            # be reached for, so it is there.
            always = (axis === :author && v in (AUTHOR_ME, AUTHOR_OTHERS)) ||
                     (axis === :repo && j <= npinned)
            # A label nothing here carries is noise - and there are hundreds of
            # them across this many repos. The zero-count skip is what keeps the
            # list to the ones worth seeing.
            cnt == 0 && !on && !always && continue
            # What is applied is listed, and on the long axes that is all that
            # is: the picker row below has every value and narrows by typing,
            # which is the only thing that scales to several hundred labels.
            # The pane is then as long as the answer rather than as long as the
            # question.
            (!on && !always && axis in AXIS_APPLIED_ONLY) && continue
            push!(rows, (axis, v, string(on ? "[x] " : "[ ] ",
                                         rpad(first(axis_label(axis, v), 22), 24), cnt)))
        end
        # The rest of them, behind a picker you can type into. Offered even when
        # everything fits, so the row is in the same place every time.
        axis === :lane ||
            push!(rows, (:pick, string(axis),
                         string("  \u002b ", length(values), " ", label,
                                length(values) == 1 ? "" : "s", ", pick one\u2026")))
    end
    rows
end

"""First selectable row of each group in the filter pane.

The groups are what you actually move between - the way out, then what else to
show, tag, kind, category, repo, label, author - and with a couple of hundred
labels one of them is long enough that stepping into it a row at a time is not
stepping into it.
"""
function filter_groups(rows)
    starts, prev_head = Int[], true
    for (j, r) in enumerate(rows)
        ishead = r[1] === :head
        (!ishead && prev_head) && push!(starts, j)
        prev_head = ishead
    end
    starts
end

"""Every value of one axis, as a picker you can type into.

`ChooseView` already narrows its options by `occursin` and hands back the one
picked, so this is a wiring job rather than a picker. The counts come from
`axis_counts`, which computes what each value would *add* against the rest of
the filter - the same number the listed rows show, and the one worth having
while choosing.

Values already applied are left out, and so are the pinned repos. They are on
screen a few rows above, where `\u21b5` takes them off or puts them on.
"""
function pick_axis!(st, ctrl, axis::Symbol)
    n = axis_counts(st)
    tally = axis === :repo ? n.repos : axis === :label ? n.labels : n.authors
    values = axis === :repo ? (r = repo_axis(st); r[1][r[2]+1:end]) :
             axis === :label ? st.labels : st.authors
    sel = axis_set(st.filters, axis)
    opts = Tuple{String,Any}[(string(rpad(axis_label(axis, v), 30), " ",
                                     get(tally, v, 0)), v)
                             for v in values if !(v in sel)]
    isempty(opts) && return false
    push_view!(ctrl, ChooseView(string("Filter by ", axis), "type to narrow", opts,
        v -> begin
            push!(axis_set(st.filters, axis), String(v))
            refilter!(st; keeprow = false)
            st.status = string("filtered: ", axis, " ", axis_label(axis, String(v)))
        end))
    true
end

"""Toggle whatever the filter cursor is on; radio rows replace, checkboxes flip.

`ctrl` is only wanted by the row that opens a picker, and a caller that has none
gets everything else.
"""
function toggle_filter!(st, ctrl = nothing)
    rows = filter_rows(st)
    st.frow = clamp(st.frow, 1, length(rows))
    (axis, val, _) = rows[st.frow]
    if axis in (:show, :state, :tag)
        set, v = sym_set(st.filters, axis), Symbol(val)
        v in set ? delete!(set, v) : push!(set, v)
        # A selection brings its order with it. `w` is still the override, and
        # it lasts until the selection changes again - which is the only rule
        # here that can be stated in one sentence, and the reason it is this one.
        st.sort = lane_sort(st.filters)
    elseif axis === :kind
        st.filters.kind = Symbol(val)
    elseif axis === :reset
        # The same jump `c` makes, remembered the same way: `\`` goes back to
        # whatever was applied before, which is what makes clearing safe to try.
        isdefault(st.filters) && return false
        st.prev = st.filters
        st.filters = Filters()
    elseif axis === :pick
        ctrl === nothing && return false
        return pick_axis!(st, ctrl, Symbol(val))
    elseif axis in (:lane, :repo, :label, :author)
        set = axis_set(st.filters, axis)
        val in set ? delete!(set, val) : push!(set, val)
    else
        return false
    end
    refilter!(st; keeprow = false)
    true
end

"Does this item answer to `/query`? Title or ref, case-insensitively."
hits(it::Item, q::AbstractString) =
    occursin(lowercase(q), lowercase(it.title)) || occursin(lowercase(q), lowercase(it.ref))

"""The list in the order it was already being read in.

`fresh` is the list as the sort would have it now; `prev` is the list on
screen. A row in both keeps its place among the rows that stayed, one that
arrives goes where the sort puts it among them, and one that left is gone -
so the order the reader opened is the order they read, until they ask for
another.

The sort key moves under a list that is being read: the bundle re-read under
the cursor (`collect_meta!`) brings a fresh `act` for the one row, and a
re-sort put that row - the one being read - somewhere else on the screen. A
note, a snooze put on and undone, a label: each is one row changed and the
whole list re-ordered around it, on an order the reader had already taken in.
"""
function held_order(fresh::Vector{Item}, prev::Vector{Item})
    (isempty(prev) || isempty(fresh)) && return fresh
    pos = Dict{String,Int}(it.url => i for (i, it) in enumerate(prev))
    kept = sort!([it for it in fresh if haskey(pos, it.url)]; by = it -> pos[it.url])
    k, out = 1, Item[]
    for it in fresh
        push!(out, haskey(pos, it.url) ? kept[k] : it)
        haskey(pos, it.url) && (k += 1)
    end
    out
end

"""Rebuild `st.items` from the filters, and decide where the cursor lands.

`keeprow` is the difference between the list changing under the reader and the
reader asking for a different list. Marking something read in the unread lane,
archiving, snoozing and undoing all take one row out of the list being read, and
there the cursor belongs on whatever moved up into its place. Choosing a view, a
filter or a search asks for a list that has nothing to do with where the cursor
was in the last one, and those pass `keeprow = false` and open at the top.

The order is the same distinction, read off what the list is *of*: the
filters, the sort and the list search, written the way a view is
(`view_lines`) and kept as `orderkey`. While those stand, a refilter keeps the
order the reader has (`held_order`); the moment any of them changes - a view,
a filter, `w`, a search - the list is another list and is sorted afresh. So
is one that asks (`resort`), which is a refresh landing: the same list, with
what moved in it moved to where the order says.

`guest` is a jump's: the url of a row the filters hide, to be shown in this
list anyway (`st.guest`), until another list is asked for.
"""
function refilter!(st; keeprow::Bool = true, resort::Bool = false,
                   guest::Union{Nothing,String} = nothing)
    keep = (st.sel == 0 || isempty(st.items)) ? "" : st.items[st.sel].url
    # Re-read here rather than per frame: this runs when something has changed,
    # and `render` is pure. The `touched` lane is membership in this map, so it
    # has to be current for a row to arrive in it. One read of `local.toml` for
    # both of the maps that come out of it, which is what one file buys.
    m = load_marks()
    st.touched = field_marks(m, "touched")
    st.drafts = field_marks(m, "draft")
    st.done = field_marks(m, "done")
    st.sources = source_since()
    st.archived = archived_map()
    st.wakes = wake_map()
    st.snoozes = field_marks(m, "last_snooze")
    # And the one record that is not in the file: whose agent rang. A
    # process, the same as the reads above are a file.
    st.rang = rang_urls()
    key = string(join(view_lines(st.filters, st.sort), "\n"), "\n/",
                 st.searchin === :list ? st.search : "")
    # The guest is a row a jump went to that the filters hide: shown where the
    # sort puts it among the rows they do not, rather than the filters cleared
    # to reach it, which threw away the list being read to show one row of
    # another. It stays while this list does - a key that marks it leaves it
    # where it is, as the cursor being on it would - and goes the moment
    # another list is asked for, or when the filters come to show it anyway.
    (!keeprow || key != st.orderkey) && (st.guest = "")
    guest === nothing || (st.guest = guest)
    listed = apply_filters(st.filters, st.all, Marks(st))
    g = isempty(st.guest) ? nothing : findfirst(it -> it.url == st.guest, st.all)
    if g === nothing || any(it -> it.url == st.guest, listed)
        st.guest = ""
    else
        push!(listed, st.all[g])
    end
    fresh = sortitems(listed, st.sort, st.touched)
    st.items = (resort || !keeprow || key != st.orderkey) ? fresh : held_order(fresh, st.items)
    st.orderkey = key
    # The text filter sits on top of the tag axes rather than inside `Filters`,
    # so the counts in the filter pane keep describing the tags alone - which is
    # what they are for.
    # Only a search started in the list narrows it. One begun in the thread is
    # about the thread, and should not quietly filter the list out from under
    # the cursor the next time anything rebuilds it.
    # The guest is not narrowed by it either: it is there because it was asked
    # for by name.
    (isempty(st.search) || st.searchin !== :list) ||
        (st.items = [it for it in st.items if it.url == st.guest || hits(it, st.search)])
    i = findfirst(x -> x.url == keep, st.items)
    # Stay on the same item when possible, and failing that on the same *row* -
    # whatever moved up into the place being read. `e` in the unread lane is the
    # case: the row it marks done leaves the lane it is in, and a cursor thrown
    # to the top of the list by that turns reading an inbox into `e`, scroll
    # back down, `e`, scroll back down.
    #
    # The import row only when there is no item at all to be on. Deliberately
    # not sticky: you land on that row by moving to it, and a rebuilt list that
    # has work in it should open on the work rather than on the way to add more.
    #
    # `top` is left where it is for the same reason the row is: `window`
    # re-aims it around the cursor, so an unchanged one leaves the row being
    # read where it is on the screen rather than scrolling the list under it.
    st.sel = isempty(st.items) ? 0 :
             something(i, keeprow ? clamp(st.sel, 1, length(st.items)) : 1)
    keeprow || (st.top = 1)
end

"One-line summary of what is applied, for the frame title."
function filter_summary(f, order::Symbol = lane_sort(f))
    parts = String[]
    # Not done is not named while it is on, on the argument the sort key makes
    # a few lines down: it is true of almost every screen there is, so saying it
    # on each one is a phrase the reader stops seeing. What is worth saying is
    # what has been added to it - and where nothing else is applied either, the
    # dashboard is the whole answer and is said at the end. Both states are on
    # by default and as unremarkable while they are; what is said about them is
    # an *absence*, since a dashboard without its closed rows is a narrower
    # list than the one the browser opens on, and "open only" is what it is.
    #
    # Off, not done is the most important thing on the screen and is said
    # first: a list with the dashboard taken out of it looks like a list that
    # has lost rows, and "only" is the word that stops it reading as a bug.
    if NOT_DONE in f.show
        rest = [last(x) for x in SHOW if first(x) !== NOT_DONE && first(x) in f.show]
        isempty(rest) || push!(parts, string("also ", join(rest, "+")))
    else
        rest = [last(x) for x in SHOW if first(x) in f.show]
        push!(parts, isempty(rest) ? "nothing shown" : string("only ", join(rest, "+")))
    end
    if f.state != STATE_DEFAULT
        push!(parts, isempty(f.state) ? "nothing shown" :
                     :open in f.state ? "open only" : "closed only")
    end
    isempty(f.tags) ||
        push!(parts, join([last(x) for x in TAGS if first(x) in f.tags], "+"))
    f.kind === :both || push!(parts, f.kind === :pr ? "pull requests" : "issues")
    # Named only when it is not the order this selection opens in. Newest-first
    # is the default everywhere now, and a summary that says so on every screen
    # is a phrase the reader stops seeing and a footer three words narrower for
    # the keys - while an order somebody chose with `w` is exactly what wants
    # saying, and stops being said the moment the selection changes it back.
    #
    # Not `sort`: that is the name of the function two lines down, and shadowing
    # it turned `sort(collect(f.lanes))` into a call on a Symbol.
    order === lane_sort(f) ||
        push!(parts, order === :moved ? "by when it moved" :
                     order === :latest ? "by when anything happened" :
                     order === :touched ? "by when you acted" : "by url")
    isempty(f.authors) ||
        push!(parts, join(sort([axis_label(:author, a) for a in f.authors]), "+"))
    isempty(f.lanes) || push!(parts, join(sort(collect(f.lanes)), "+"))
    isempty(f.repos) || push!(parts, join([last(split(r, '/')) for r in sort(collect(f.repos))], "+"))
    isempty(f.labels) || push!(parts, join(sort(collect(f.labels)), "+"))
    isempty(parts) && push!(parts, "unread")
    join(parts, " · ")
end

"""Where the browser was when it last closed - `data/view.toml`.

The filter, its order, the item under the cursor and which of its views was
up: enough to reopen in the same place, which is what a stray `q` used to
cost and what a terminal that went away always did. Written whole on the way
out, since it is one record and not a file anybody edits; read once at
launch, and an item that is no longer in the list - read since, filed,
filtered out - leaves the cursor at the top of the list it is not in.

Not `local.toml`: that is judgement, written key by key and never rewritten.
This is where you were, and it is nothing without the corpus beside it.
"""
const VIEWFILE = Ref("")
viewfile() = isempty(VIEWFILE[]) ? datapath("view.toml") : VIEWFILE[]

const VIEW_MODES = (:comments, :diff, :pushed, :checks)

function save_view(st)
    lines = vcat(["# Where the browser was when it last closed, read back at the next",
                  "# launch. Written whole on the way out; `` ` `` is the way back to the",
                  "# firehose from a view it restored.",
                  "[view]"], view_lines(st.filters, st.sort), [""])
    u = curl(st)
    if !isempty(u)
        push!(lines, "[at]", string("item = ", repr(u)),
              string("mode = ", repr(String(st.mode))), "")
    end
    try
        write_atomic(viewfile(), join(lines, "\n"))
    catch
        # Nothing on screen to say it to, and nothing lost but where you were.
    end
end

"""Reopen where the last run closed, and say so on the status row. Answers
whether anything was restored."""
function restore_view!(st)
    f = viewfile()
    isfile(f) || return false
    d = try
        TOML.parsefile(f)
    catch
        return false
    end
    v = get(d, "view", nothing)
    v isa AbstractDict || return false
    said = apply_view!(st, v)
    at = get(d, "at", Dict{String,Any}())
    i = findfirst(x -> x.url == String(get(at, "item", "")), st.items)
    i === nothing || (st.sel = i)
    m = Symbol(String(get(at, "mode", "comments")))
    m in VIEW_MODES && (st.mode = m)
    st.status = string("where you were: ", said)
    true
end
