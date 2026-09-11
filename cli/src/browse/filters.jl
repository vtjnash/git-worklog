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
#   * **show** - the three dispositions, merged into one axis that only ever
#     adds. Five boxes, and no box can take another one's rows away. Three
#     separate axes said the same thing and let you turn the dashboard off with
#     them - `seen: read` alone hid everything that had moved, which is the one
#     list nobody wants - and all but one of the built-in views had to spell
#     `sleep = awake` to avoid it. What each value means:
#       - **unread, awake, open** - the dashboard itself, and the box that is on
#         when nothing has been asked, so the screen cannot be emptied by
#         accident. Unchecking it is how one of the other four is asked for
#         *alone*, and the only way there is.
#       - **read** - the read stamp against `moved_at`, and **nothing overrides
#         it**: an item that moves is unread again whether it is snoozed,
#         filed, yours or a stranger's. A review request, a mention and a reply
#         all land here, which is why none of them needs a lane.
#       - **snoozed** and **filed away** - your decision, and the only thing
#         here GitHub cannot see. One field, `x` and `s` write it.
#       - **closed or merged** - GitHub's `OPEN` against `CLOSED`/`MERGED`.
#   * **tag** - the three things worth asking that are not any of the above:
#     work that has gone quiet (`second look`), work you have acted on
#     (`touched`), and words you have written and not sent (`drafts`).
#   * **kind**, **category**, **repo**, **label**, **author** - unchanged.
#
# What is *not* here any more: `active`, `backlog` and `mine`. `mine` was the
# author axis written twice. `active` and `backlog` were one fact wearing a
# state's clothes - which lane fetched the row - and the answer to "how do I
# stop seeing the pile" is now the same as the answer for everything else:
# dismiss it, one item at a time, recorded and undoable. That is the one thing
# this program knows that GitHub does not.

"""What to show: five boxes over the three dispositions, and one of them is the
dashboard itself.

One axis, and it only ever adds - checking a box brings a kind of row *in
beside* whatever is already there, and no box takes another one's rows away.
`base` is the unread, awake and open work this program is for, and it is the
box that is on when nothing has been asked: `c`, a fresh `Filters` and a view
that names no `show` all leave it checked, so the screen cannot be emptied by
accident. Unchecking it is how the other four are asked for *alone* - the filed
work on its own rather than beside today's, which is the one question this axis
could not be asked while the base was a floor with no control at all. Unchecking
every box is an empty list: an empty set of things to show is no things, which
is the honest reading of an axis that adds rather than narrows.

`filed` is beside `snoozed` rather than folded into it because filing is the
decision you make when you never want to see a thing again, and "show me what I
put down for now" is a different question from "show me what I gave up on".
Either one brings what it names whether or not it has been read - see
`show_ok`, which is where the one asymmetry in this axis is written down.

The three readings the values come from are `seen_of`, `sleep_of` and `over_of`,
which are still three questions with three answers each - what merged is the
control over them, not the facts.
"""
const SHOW = [(:base, "unread, awake, open"), (:read, "read"),
              (:snoozed, "snoozed"), (:filed, "filed away"),
              (:done, "closed or merged")]

"""The one box that is on when nothing has been asked; see `isdefault` and `c`.

Compared against, never pushed into - the `Filters` default below writes the set
out again rather than naming this, because a shared mutable default would make
one item's `show` every item's.
"""
const SHOW_BASE = Set([:base])

"""The three questions that are not an axis of their own.

Each is a mark or a derivation rather than a field: `second` is worked out every
refresh from silence, `touched` and `drafts` are rows in `local.toml`. Unlike
the axes above an item can carry all three at once, so these behave like labels
- any of the ones you pick brings the row.
"""
const TAGS = [(:second, "second look"), (:touched, "touched"), (:drafts, "drafts")]

"""How the list is ordered. Its own control, deliberately.

Sorting is orthogonal to all three filter axes - any order makes sense over any
selection - so it does not belong inside `Filters`, where it would multiply the
axes instead of sitting beside them. `w` cycles it.

`:latest` is the default, and the order every other inbox opens in: what moved
most recently is at the top.

`:none` is the url order, descending: owner, then project, then number. That is
what `facts.json` is written in - it is sorted by key, and the key is the url -
so it keeps the grouping the file has, everything from one repo together, and
reads from the newest of each rather than from two thousand rows ago. The number
is taken as a number and not as the digits it is spelled with; see `urlkey`.
"""
const SORTS = [(:none, "by url, newest first"),
               (:touched, "by when you last acted"),
               (:latest, "by when anything last happened")]

"""Issue, pull request, or both - the third radio group.

A radio and not a fourth tag axis: the values are exhausted by three and they
are mutually exclusive, so a set of them would only ever hold one thing or say
nothing. `Item.is_pr` was already there and every lane carries both kinds, which
is what made "issues only" impossible to ask for and obvious to want.
"""
const KINDS = [(:both, "both"), (:pr, "pull requests"), (:issue, "issues")]

"""The order a selection opens in, where it implies one.

`touched` alone *is* the interaction clock - membership in it is having acted on
something - so the clock is the order it means, and arriving in it sorted by
anything else asks the reader to press `w` to see the thing they came for.

Everything else is newest-first, which is the order an inbox has and the answer
use gave to the question this table used to leave open. It is still where a
selection that wants a different one says so.
"""
lane_sort(f) = f.tags == Set([:touched]) ? :touched : :latest

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
    show::Set{Symbol} = Set([:base])       # which kinds of row to show, of the
                                           # five there are; `:base` is the
                                           # dashboard and is what an unasked
                                           # question answers. Empty shows
                                           # nothing. Written out rather than
                                           # `SHOW_BASE`, which would be one
                                           # set shared by every filter. `SHOW`
    tags::Set{Symbol} = Set{Symbol}()      # empty means no restriction; `TAGS`
    buckets::Set{String} = Set{String}()   # empty means every category
    repos::Set{String} = Set{String}()     # empty means every repo
    labels::Set{String} = Set{String}()    # empty means every label
    kind::Symbol = :both                   # :both | :pr | :issue
    authors::Set{String} = Set{String}()   # empty means anybody; @me and
                                           # @anyone-else are values here as
                                           # well as logins
end

"""What the browser opens on: the notifications, awake and open.

Unread is what moved since you looked at it, whoever moved it - a review
request, a mention, a reply, a push - which is the one list that is about
*today*. Awake because "I do not want to see this" is a decision you made and
honouring it by default is the whole of what it means.

A bare `Filters`, because `show` defaults to the base box alone: this list is
what the program is, so it is what a filter says when it has been asked
nothing. `c` clears the filters *to* it, the other four `SHOW` boxes are how
the rest of the corpus comes back, and unchecking the base itself is how one of
them is asked for alone.
"""
DEFAULT_FILTERS() = Filters()

"""Every row there is: all five boxes on.

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
empty, and `show` back to the base box alone, which is what an unasked question
answers here. `\`` is the way back to what you had, and the other four `SHOW`
boxes are the way back out to the corpus.
"""
isdefault(f::Filters) =
    f.show == SHOW_BASE && isempty(f.tags) &&
    f.kind === :both && isempty(f.buckets) && isempty(f.repos) &&
    isempty(f.labels) && isempty(f.authors)

"One empty map, shared, for every caller that has no marks to hand."
const EMPTY_TOUCHED = Dict{String,String}()

"""What is recorded about the items on screen, as one argument.

Five maps that the filters ask of every row: the poll's `unread` set, and the
four marks. They travelled as four and then five positional arguments with
defaults, which is a list that grows every time the model learns something and
is wrong the moment one caller passes them in the other order.

References, not copies - `BState` owns the maps and re-reads them whenever
something changes; this is a way of naming all of them at once, made per
`refilter!` and thrown away with it.
"""
Base.@kwdef struct Marks
    unread::Set{String} = Set{String}()     # what the poll saw move, which is
                                            # not the seen bit; see `seen_of`
    read::Dict{String,String} = EMPTY_TOUCHED
    touched::Dict{String,String} = EMPTY_TOUCHED
    archived::Dict{String,String} = EMPTY_TOUCHED
    drafts::Dict{String,String} = EMPTY_TOUCHED
end
Marks(st) = Marks(st.unread, st.read, st.touched, st.archived, st.drafts)

"""Has this item changed since you last looked at it?

    seen_of(it, marks) -> :unread | :read

The read stamp against `moved_at`, and **nothing overrides it**. Not a snooze,
not a filing, not whose it is: movement makes a thing unread, because unread is
not a claim about wanting to see something - it is a claim about whether it has
changed since you last did.

**`moved_at` and not `updated`.** GitHub's own timestamp does not move when a
check run finishes and does move when somebody relabels a pull request, so it
misses the thing you asked to be told about and reports things you did not.
`moved_at` is when the refresh last saw a change *at this item's tracking
level* - so your own pull request turning green is unread and a stranger's is
not, which is what `track` is for and what it did not used to reach. An item no
refresh has bucketed - a row the activity poll alone knows about - has no
fingerprint to compare, and there `updated` is the only answer anybody has.

No stamp at all reads as unread, which is what "never been in front of you"
means. It used to be a third value, `unseen`, on the theory that the firehose
browse wanted it: it does not. What takes something out of that pile is
dismissing it, and what an item you have never opened has in common with one
that moved this morning is exactly that you have not seen what it says now.

Computed rather than stored. On `Item` it would be derived state that goes stale
the moment `r` is pressed - `Item` is immutable and rebuilt by the refresh - so
the browser would have to rewrite every row it touched.
"""
function seen_of(it::Item, m::Marks = Marks())
    at = get(m.read, it.url, nothing)
    at === nothing && return :unread
    # An item with neither is a synthetic one - an adopted branch, an import no
    # refresh has caught up with - and a stamp on it is the only thing anybody
    # has said about whether it has been seen.
    moved = isempty(it.moved_at) ? it.updated : it.moved_at
    at < moved ? :unread : :read
end

"""Do you want to see this?

    sleep_of(it, marks) -> :awake | :snoozed | :filed

One decision with three readings. `filed` is the snooze that never wakes, which
is what `x` writes and what archiving has always been; `snoozed` is one with a
wake condition the refresh is watching for. Whether it is asleep is the
refresh's answer, carried on the item - see `snooze_active` - because deciding
it here would be a second opinion about a thing that has already been decided.
"""
sleep_of(it::Item, m::Marks = Marks()) =
    haskey(m.archived, it.url) ? :filed : it.snoozed ? :snoozed : :awake

"Is it finished? Empty reads as open, which is what a synthetic item is."
over_of(it::Item) = (it.state == "CLOSED" || it.state == "MERGED") ? :done : :open

"""The tags an item carries, of the three there are.

Unlike the axes, several can be true at once, so this answers with a set and the
axis behaves like labels: any tag you pick brings the row.
"""
function tags_of(it::Item, m::Marks = Marks())
    out = Symbol[]
    isempty(it.secondlook) || push!(out, :second)
    haskey(m.touched, it.url) && push!(out, :touched)
    haskey(m.drafts, it.url) && push!(out, :drafts)
    out
end

"""Is a row in, on the merged disposition axis?

    show_ok(show, seen, sleep, over) -> Bool

A row is in where `show` names **every way in which it is not base work** - and
a row that deviates in no way at all is base work, which is in where `:base` is
named. So the three clauses below are one rule read three times: each says "this
is how the row differs, and the box for it has to be on".

**`read` is a question about awake work only**, which is the one thing here that
is not symmetric and is the point of the whole axis. Putting something away
stamps it read - a snooze and a filing both do, see `apply_snooze!` - so a
`snoozed` box that also insisted on the read stamp would have shown nothing at
all, and the reader would have had a control that did not work rather than a
list. What you put away is what you put away, read or not; the read stamp is
how the *pile* gets shorter.

Closed is asked of every row, since nothing about closing an item says whether
it has been looked at. So a row can be held out twice - a closed pull request
you read last week needs both `read` and `done` - which is what makes the count
beside a box a delta rather than a total: see `axis_counts`.

The base clause is last and is the only one that is about the *absence* of a
deviation: a read one, a snoozed one and a closed one each answer to their own
box whether or not the base is on, which is what makes "the filed ones alone" a
question this axis can be asked. Unchecking every box shows nothing, and that is
the honest reading of it rather than a case to special-case.

Monotone in `show` by construction, and `axis_counts` relies on it: adding a
value can only ever bring rows in.
"""
show_ok(show::Set{Symbol}, sn::Symbol, sl::Symbol, ov::Symbol) =
    (sl === :awake ? (sn === :unread || :read in show) : sl in show) &&
    (ov === :open || :done in show) &&
    (:base in show || !(sl === :awake && sn === :unread && ov === :open))

"The same, asked of an item."
shown(f::Filters, it::Item, m::Marks = Marks()) =
    show_ok(f.show, seen_of(it, m), sleep_of(it, m), over_of(it))

"""The timestamp a sorted list is ordered by, under one of two readings of when.

`:touched` is your own last interaction if there is one and the remote time only
otherwise: it answers *when did I last deal with this*. `:latest` is the later
of the two, which answers *when did anything happen to this* - the order
notification mail would have arrived in, with your own work folded into it.

They differ exactly where both exist. An item you touched in March that somebody
commented on this morning sorts to March under the first and to this morning
under the second. Neither is righter than the other - a to-do list wants the
first and an inbox wants the second, and the same key gives both rather than
choosing on the user's behalf.

One key rather than two groups, under either reading. A branch nothing has been
done to but that was committed to this morning belongs above a pull request last
touched in March, and splitting the list into touched-then-untouched would bury
it.
"""
function sortkey(it::Item, touched::Dict{String,String}, order::Symbol = :touched)
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

"""Newest first, and stable - so an untimed item keeps the order it was fetched
in.

All three orders are newest-first; they differ in what "newest" is. `:none` is
the url, which is the order `facts.json` is written in - by owner, project and
number - read from the top instead of from two thousand rows ago."""
sortitems(items, mode::Symbol, touched::Dict{String,String}) =
    mode === :none ? sort(items; by = urlkey, rev = true) :
    sort(items; by = it -> sortkey(it, touched, mode), rev = true)

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
    isempty(f.buckets) || it.bucket in f.buckets || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    isempty(f.labels)  || any(in(f.labels), it.labels) || return false
    true
end

"""
    axis_counts(st) -> (; shows, tags, kinds, buckets, repos, labels, authors)

How many items each filter value would select, in one pass over the items.

Every count is against the *other* axes only - a category shows what selecting
it would add, not a total that ignores the rest of the filter - so there is one
predicate per axis over the same item, seven of them, and computing them together
is what makes this one pass instead of one per row. It was a pass per row: 93 rows
over 2050 items came to 190,650 `matches` calls per build and two builds per
keystroke, which made the filter pane the only part of the UI with visible lag -
128ms a frame against 0.7ms for the item list.

`shows` is the one that is not a tally of values, because its five are not
alternatives: it is what each box is *worth* - the rows it alone is holding in,
or would bring in. A closed item you have read needs both boxes and is counted
under neither until one of them is on, which is the honest answer to "what does
pressing this do". The base box is counted the same way, so the number beside it
is what unchecking it would cost.
"""
function axis_counts(st)
    f, m = st.filters, Marks(st)
    shows = Dict{Symbol,Int}(); tagn = Dict{Symbol,Int}()
    kinds = Dict{Symbol,Int}(); buckets = Dict{String,Int}()
    repos = Dict{String,Int}(); labels = Dict{String,Int}()
    authors = Dict{String,Int}()
    bump!(d, k) = d[k] = get(d, k, 0) + 1
    # One set per value, built once rather than per row: the count for a box is
    # what it changes, which is the difference between the filter with it on and
    # the same filter with it off.
    with = Dict(k => union(f.show, [k]) for (k, _) in SHOW)
    without = Dict(k => setdiff(f.show, [k]) for (k, _) in SHOW)
    for it in st.all
        sn, sl, ov, tg = seen_of(it, m), sleep_of(it, m), over_of(it), tags_of(it, m)
        # Every axis, answered once, in the order the pane draws them.
        ok = (show_ok(f.show, sn, sl, ov),
              isempty(f.tags) || any(in(f.tags), tg),
              kind_ok(f.kind, it), author_ok(f.authors, it),
              isempty(f.buckets) || it.bucket in f.buckets,
              isempty(f.repos) || it.repo in f.repos,
              isempty(f.labels) || any(in(f.labels), it.labels))
        # Each count is against the *other* axes only, so a value shows what
        # picking it would bring rather than a total that ignores the rest of
        # the filter. Which is: this row already passes everything except
        # possibly the axis being counted - one subtraction rather than a pass
        # per axis per row.
        nfail = count(!, ok)
        others(i) = nfail == 0 || (nfail == 1 && !ok[i])
        if others(1)
            for (k, _) in SHOW
                # On or off, the number beside a box is the same number: the
                # rows that are in with it and out without it.
                (show_ok(with[k], sn, sl, ov) && !show_ok(without[k], sn, sl, ov)) &&
                    bump!(shows, k)
            end
        end
        if others(2)
            for t in tg
                bump!(tagn, t)
            end
        end
        if others(3)
            for (k, _) in KINDS
                kind_ok(k, it) && bump!(kinds, k)
            end
        end
        if others(4)
            # One item counts towards its own author *and* towards whichever of
            # the two predicates it answers, since picking either would bring it.
            isempty(it.author) || bump!(authors, it.author)
            author_ok(Set([AUTHOR_ME]), it) && bump!(authors, AUTHOR_ME)
            author_ok(Set([AUTHOR_OTHERS]), it) && bump!(authors, AUTHOR_OTHERS)
        end
        others(5) && bump!(buckets, it.bucket)
        others(6) && bump!(repos, it.repo)
        if others(7)
            for l in it.labels
                bump!(labels, l)
            end
        end
    end
    (; shows, tags = tagn, kinds, buckets, repos, labels, authors)
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

"The set an axis filters on, which is where a picked value lands."
axis_set(f::Filters, axis::Symbol) =
    axis === :bucket ? f.buckets : axis === :repo ? f.repos :
    axis === :label ? f.labels : f.authors

"The same, for the two axes whose values are symbols rather than names."
sym_set(f::Filters, axis::Symbol) = axis === :show ? f.show : f.tags

"How a value of `axis` is written in the pane. Only the author axis has any."
axis_label(axis::Symbol, v::AbstractString) =
    axis !== :author ? String(v) :
    v == AUTHOR_ME ? string("me (", login(), ")") :
    v == AUTHOR_OTHERS ? "anyone else" : String(v)

"""The views `\'` offers, from `config.toml`, in the order they were written.

A view is a whole filter set under a name. The pane composes state × kind × repo
× label × author, which is enough to ask almost anything and far too much to
retype - so what was missing was never expressiveness, it was *recall*.

The defaults are deliberately composites. A single bucket is already one `f`
away and needs no name; what needs one is the pair of axes nobody assembles
twice.

Read and never written: `config.toml` is the user's file, and `wl watching`
already established what this program does when it wants to suggest a line for
it - it prints one to paste.
"""
const VIEWS = [
    # The way back to where the browser opens, and the first row for the same
    # reason the import row leads the item list: a control nobody can find is a
    # control nobody uses. It names no axis at all, because the list it goes to
    # is what is left when every axis is off.
    ("notification firehose — unread, awake, open", Dict{String,Any}()),
    # The two modes that are left. Which work is yours is the author axis; what
    # has moved is the base. One axis per question, and neither of them a lane.
    ("my work — mine", Dict("author" => [AUTHOR_ME])),
    ("open items — the pile, read ones too", Dict("show" => ["base", "read"])),
    ("waiting on me",  Dict("tag" => ["second"], "kind" => "pr",
                            "author" => [AUTHOR_OTHERS])),
    ("waiting on them", Dict("tag" => ["second"], "author" => [AUTHOR_ME])),
    ("ready to merge", Dict("bucket" => ["needs-merge"])),
    ("red CI, mine",   Dict("author" => [AUTHOR_ME], "bucket" => ["needs-edits"])),
    ("unanswered",     Dict("bucket" => ["needs-reply"])),
    # The corpus, which no longer has a keystroke of its own: it is the base
    # with the four things it leaves out added back to it, and it names all
    # five because a view that names the axis names the whole of it.
    ("everything — read, snoozed, filed and closed too",
                       Dict("show" => ["base", "read", "snoozed", "filed", "done"])),
]

"The keys a view may name. Anything else in one is a misspelling; see `apply_view!`."
const VIEW_KEYS = ("show", "tag", "kind", "bucket", "repo", "label", "author", "sort")

"Every view: the built-in ones, then whatever `config.toml` adds or replaces."
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
    for (key, values, set) in (("show", SHOW, f.show), ("tag", TAGS, f.tags))
        haskey(d, key) || continue
        # Named means named *whole*, the base box included - a view that says
        # `show` says which of the five are checked, and one that says nothing
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
    # a view that names one quietly shows more than it says. `seen`, `sleep` and
    # `state` were three keys here until the dispositions merged, and a
    # `config.toml` still spelling them would otherwise go on working and mean
    # something else.
    for key in keys(d)
        key in VIEW_KEYS ||
            (bad = string(bad, " \u00b7 no axis '", key, "'"))
    end
    haskey(d, "kind") && (f.kind = Symbol(d["kind"]))
    for (k, set) in (("bucket", f.buckets), ("repo", f.repos),
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
    # an order left over from the list you were in is not that. It also makes
    # the url order nameable, which nothing else could say - a view that names
    # `sort = "none"` gets it even where the selection would have implied one.
    st.sort = haskey(d, "sort") ? Symbol(d["sort"]) : lane_sort(f)
    refilter!(st; keeprow = false)
    string("[", filter_summary(f, st.sort), "]", bad)
end

"""The current filter written as the TOML line that would name it.

The browser does not write `config.toml`; this is the paste-able form, which is
the same answer `wl watching` gives for the repos you watch. A filter you got to
by hand is the one worth keeping, and it is also the one you cannot reconstruct
from memory an hour later.
"""
function view_toml(f::Filters, order::Symbol, name::AbstractString = "a name")
    lines = [string("[views.", repr(String(name)), "]")]
    # Written unless it is what a view that names no `show` would get anyway -
    # which is the base box alone, not the empty set: `show = []` is a real
    # filter here, and one that has to survive being written down.
    for (key, values, set, quiet) in (("show", SHOW, f.show, SHOW_BASE),
                                      ("tag", TAGS, f.tags, Set{Symbol}()))
        set == quiet && continue
        # In the axis's own order rather than the set's, so the same filter
        # writes the same line every time.
        push!(lines, string(key, " = [",
                            join([repr(String(k)) for (k, _) in values if k in set],
                                 ", "), "]"))
    end
    f.kind === :both || push!(lines, string("kind = ", repr(String(f.kind))))
    for (k, set) in (("bucket", f.buckets), ("repo", f.repos),
                     ("label", f.labels), ("author", f.authors))
        isempty(set) && continue
        push!(lines, string(k, " = [",
                            join([repr(x) for x in sort(collect(set))], ", "), "]"))
    end
    order === :none || push!(lines, string("sort = ", repr(String(order))))
    join(lines, "\n")
end

"""Rows for the filter pane: the way out, what to show, the tags, the kind
radio, then four more checkbox axes.

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
    # The two axes that are about the item and you rather than about what it is,
    # and neither is a partition: a row can carry all three tags or none, and
    # `show` is five kinds of row that are each in or out on their own. The
    # number beside a box is what checking it would bring, or what unchecking it
    # would take away - the same number either way, which is the only one worth
    # printing next to a control.
    #
    # The base leads its axis and is a box like the other four, so the count
    # beside it says what the dashboard is currently worth and the cursor can
    # take it off. It is the one box whose being on is the default rather than a
    # choice, which is what `c` puts back.
    for (axis, label, values, tally, sel) in
            ((:show, "show", SHOW, n.shows, f.show),
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
    for (axis, label, values, tally) in ((:bucket, "category", st.buckets, n.buckets),
                                         (:repo, "repo", st.repos, n.repos),
                                         (:label, "label", st.labels, n.labels),
                                         (:author, "author", st.authors, n.authors))
        push!(rows, (:head, "", ""))
        push!(rows, (:head, "", label))
        sel = axis_set(f, axis)
        for v in values
            cnt = get(tally, v, 0)
            on = v in sel
            # `me` and `anyone else` are the axis's two controls rather than two
            # of its values, and a control is worth offering when it would
            # select nothing: that it selects nothing is the answer. Narrow to a
            # repo you have written nothing in and the whole axis used to
            # vanish - no rows at all, not even the half of it that had items.
            always = axis === :author && v in (AUTHOR_ME, AUTHOR_OTHERS)
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
        axis === :bucket ||
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

Values already applied are left out. They are on screen a few rows above, where
`\u21b5` takes them off again.
"""
function pick_axis!(st, ctrl, axis::Symbol)
    n = axis_counts(st)
    tally = axis === :repo ? n.repos : axis === :label ? n.labels : n.authors
    values = axis === :repo ? st.repos : axis === :label ? st.labels : st.authors
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
    if axis in (:show, :tag)
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
    elseif axis in (:bucket, :repo, :label, :author)
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

"""Rebuild `st.items` from the filters, and decide where the cursor lands.

`keeprow` is the difference between the list changing under the reader and the
reader asking for a different list. Marking something read in the unread lane,
archiving, snoozing and undoing all take one row out of the list being read, and
there the cursor belongs on whatever moved up into its place. Choosing a view, a
filter or a search asks for a list that has nothing to do with where the cursor
was in the last one, and those pass `keeprow = false` and open at the top.
"""
function refilter!(st; keeprow::Bool = true)
    keep = (st.sel == 0 || isempty(st.items)) ? "" : st.items[st.sel].url
    # Re-read here rather than per frame: this runs when something has changed,
    # and `render` is pure. The `touched` lane is membership in this map, so it
    # has to be current for a row to arrive in it. One read of `local.toml` for
    # both of the maps that come out of it, which is what one file buys.
    m = load_marks()
    st.touched = field_marks(m, "touched")
    st.drafts = field_marks(m, "draft")
    st.read = field_marks(m, "read")
    st.archived = archived_map()
    st.items = sortitems(apply_filters(st.filters, st.all, Marks(st)),
                         st.sort, st.touched)
    # The text filter sits on top of the tag axes rather than inside `Filters`,
    # so the counts in the filter pane keep describing the tags alone - which is
    # what they are for.
    # Only a search started in the list narrows it. One begun in the thread is
    # about the thread, and should not quietly filter the list out from under
    # the cursor the next time anything rebuilds it.
    (isempty(st.search) || st.searchin !== :list) ||
        (st.items = [it for it in st.items if hits(it, st.search)])
    i = findfirst(x -> x.url == keep, st.items)
    # Stay on the same item when possible, and failing that on the same *row* -
    # whatever moved up into the place being read. `r` in the unread lane is the
    # case: the row it marks read leaves the lane it is in, and a cursor thrown
    # to the top of the list by that turns reading an inbox into `r`, scroll
    # back down, `r`, scroll back down.
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
    # The base is not named while it is on, on the argument the sort key makes a
    # few lines down: it is true of almost every screen there is, so saying it
    # on each one is a phrase the reader stops seeing. What is worth saying is
    # what has been added to it - and where nothing else is applied either, the
    # base is the whole answer and is said at the end.
    #
    # Off, it is the most important thing on the screen and is said first: a
    # list with the dashboard taken out of it looks like a list that has lost
    # rows, and "only" is the word that stops it reading as a bug.
    rest = [last(x) for x in SHOW if first(x) !== :base && first(x) in f.show]
    if :base in f.show
        isempty(rest) || push!(parts, string("also ", join(rest, "+")))
    else
        push!(parts, isempty(rest) ? "nothing shown" : string("only ", join(rest, "+")))
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
    # it turned `sort(collect(f.buckets))` into a call on a Symbol.
    order === lane_sort(f) ||
        push!(parts, order === :latest ? "by when it moved" :
                     order === :touched ? "by when you acted" : "by url")
    isempty(f.authors) ||
        push!(parts, join(sort([axis_label(:author, a) for a in f.authors]), "+"))
    isempty(f.buckets) || push!(parts, join(sort(collect(f.buckets)), "+"))
    isempty(f.repos) || push!(parts, join([last(split(r, '/')) for r in sort(collect(f.repos))], "+"))
    isempty(f.labels) || push!(parts, join(sort(collect(f.labels)), "+"))
    isempty(parts) && push!(parts, "unread, awake, open")
    join(parts, " · ")
end
