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
# Every axis here is a set, and an empty set restricts nothing. What each one
# asks, and what the answers cost:
#
#   * **seen** - has it changed since I looked at it? The read stamp against
#     `updated`, and **nothing overrides it**: an item that moves is unread
#     again whether it is snoozed, filed, yours or a stranger's. A review
#     request, a mention and a reply all land here, which is why none of them
#     needs a lane.
#   * **sleep** - do I want to see it? One decision, one field, three answers:
#     awake, snoozed until something, or filed away for good. `x` and `s` write
#     it and it is yours alone; GitHub has no opinion.
#   * **state** - is it finished? GitHub's `OPEN` against `CLOSED`/`MERGED`.
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

"Has it changed since you looked at it? Nothing overrides this axis."
const SEEN = [(:unread, "unread"), (:read, "read")]

"""Do you want to see it? Your decision, and the only axis GitHub cannot see.

`filed` is a snooze with no wake condition - see `archive!` - so this is one
field with three readings rather than two fields with a precedence rule.
"""
const SLEEP = [(:awake, "awake"), (:snoozed, "snoozed"), (:filed, "filed away")]

"Is it finished? GitHub's answer, and the only axis nobody here writes."
const OVER = [(:open, "open"), (:done, "closed or merged")]

"""The three questions that are not an axis of their own.

Each is a mark or a derivation rather than a field: `second` is worked out every
refresh from silence, `touched` and `drafts` are rows in `marks.json`. Unlike
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
    seen::Set{Symbol} = Set{Symbol}()      # empty means either; see `SEEN`
    sleep::Set{Symbol} = Set{Symbol}()     # empty means all three; see `SLEEP`
    over::Set{Symbol} = Set{Symbol}()      # empty means both; see `OVER`
    tags::Set{Symbol} = Set{Symbol}()      # empty means no restriction; `TAGS`
    buckets::Set{String} = Set{String}()   # empty means every category
    repos::Set{String} = Set{String}()     # empty means every repo
    labels::Set{String} = Set{String}()    # empty means every label
    kind::Symbol = :both                   # :both | :pr | :issue
    authors::Set{String} = Set{String}()   # empty means anybody; @me and
                                           # @anyone-else are values here as
                                           # well as logins
end

"""What the browser opens on: the notifications, awake.

Unread is what moved since you looked at it, whoever moved it - a review
request, a mention, a reply, a push - which is the one list that is about
*today*. Awake because "I do not want to see this" is a decision you made and
honouring it by default is the whole of what it means.

Every other axis is open, so the corpus is one keystroke away in any direction:
this is a starting place rather than a lane, and `c` clears it.
"""
DEFAULT_FILTERS() = Filters(seen = Set([:unread]), sleep = Set([:awake]))

"""Is anything asked of this filter at all?

Asked of the value rather than tracked, so it stays true however the filter got
here: a view, a picker, `\`` going back, or every checkbox toggled off one at a
time all reach the same place, and the row that offers to clear it should say
so in all four.

`c` clears to *nothing*, not to the opening filter: "clear every filter" has to
mean what it says, and what it leaves is the corpus - every item fetched,
including the ones you have filed away. `\`` is the way back to what you had.
"""
isdefault(f::Filters) =
    isempty(f.seen) && isempty(f.sleep) && isempty(f.over) && isempty(f.tags) &&
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

The read stamp against `updated`, and **nothing overrides it**. Not a snooze,
not a filing, not whose it is: movement makes a thing unread, because unread is
not a claim about wanting to see something - it is a claim about whether it has
changed since you last did.

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
    # An item with no `updated` is a synthetic one - an adopted branch, an
    # import no refresh has caught up with - and a stamp on it is the only
    # thing anybody has said about whether it has been seen.
    at === nothing ? :unread : at < it.updated ? :unread : :read
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

"An empty set restricts nothing, which is what every axis here means by empty."
axis_ok(want::Set{Symbol}, v::Symbol) = isempty(want) || v in want

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

"An empty tag set means 'no restriction', so a bare filter shows everything."
function matches(f::Filters, it::Item, m::Marks = Marks())
    axis_ok(f.seen, seen_of(it, m))   || return false
    axis_ok(f.sleep, sleep_of(it, m)) || return false
    axis_ok(f.over, over_of(it))      || return false
    isempty(f.tags) || any(in(f.tags), tags_of(it, m)) || return false
    kind_ok(f.kind, it) || return false
    author_ok(f.authors, it) || return false
    isempty(f.buckets) || it.bucket in f.buckets || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    isempty(f.labels)  || any(in(f.labels), it.labels) || return false
    true
end

"""
    axis_counts(st) -> (; seens, sleeps, overs, tags, kinds, buckets, repos, labels, authors)

How many items each filter value would select, in one pass over the items.

Every count is against the *other* axes only - a category shows what selecting
it would add, not a total that ignores the rest of the filter - so there is one
predicate per axis over the same item, nine of them, and computing them together
is what makes this one pass instead of one per row. It was a pass per row: 93 rows
over 2050 items came to 190,650 `matches` calls per build and two builds per
keystroke, which made the filter pane the only part of the UI with visible lag -
128ms a frame against 0.7ms for the item list.
"""
function axis_counts(st)
    f, m = st.filters, Marks(st)
    seens = Dict{Symbol,Int}(); sleeps = Dict{Symbol,Int}()
    overs = Dict{Symbol,Int}(); tagn = Dict{Symbol,Int}()
    kinds = Dict{Symbol,Int}(); buckets = Dict{String,Int}()
    repos = Dict{String,Int}(); labels = Dict{String,Int}()
    authors = Dict{String,Int}()
    bump!(d, k) = d[k] = get(d, k, 0) + 1
    for it in st.all
        sn, sl, ov, tg = seen_of(it, m), sleep_of(it, m), over_of(it), tags_of(it, m)
        # Every axis, answered once, in the order the pane draws them.
        ok = (axis_ok(f.seen, sn), axis_ok(f.sleep, sl), axis_ok(f.over, ov),
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
        others(1) && bump!(seens, sn)
        others(2) && bump!(sleeps, sl)
        others(3) && bump!(overs, ov)
        if others(4)
            for t in tg
                bump!(tagn, t)
            end
        end
        if others(5)
            for (k, _) in KINDS
                kind_ok(k, it) && bump!(kinds, k)
            end
        end
        if others(6)
            # One item counts towards its own author *and* towards whichever of
            # the two predicates it answers, since picking either would bring it.
            isempty(it.author) || bump!(authors, it.author)
            author_ok(Set([AUTHOR_ME]), it) && bump!(authors, AUTHOR_ME)
            author_ok(Set([AUTHOR_OTHERS]), it) && bump!(authors, AUTHOR_OTHERS)
        end
        others(7) && bump!(buckets, it.bucket)
        others(8) && bump!(repos, it.repo)
        if others(9)
            for l in it.labels
                bump!(labels, l)
            end
        end
    end
    (; seens, sleeps, overs, tags = tagn, kinds, buckets, repos, labels, authors)
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

"The same, for the four axes whose values are symbols rather than names."
sym_set(f::Filters, axis::Symbol) =
    axis === :seen ? f.seen : axis === :sleep ? f.sleep :
    axis === :over ? f.over : f.tags

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
    # reason the import row leads the item list: `c` clears the pane to
    # *nothing*, which is a different and equally wanted place, and a control
    # nobody can find is a control nobody uses.
    ("what moved — unread, awake",
                        Dict("seen" => ["unread"], "sleep" => ["awake"])),
    # The three modes. Which work is yours is the author axis; what has moved is
    # the seen axis; what is still open is GitHub's. One axis per question, and
    # none of them a lane.
    ("my work — mine, open, awake",
                        Dict("author" => [AUTHOR_ME], "state" => ["open"],
                             "sleep" => ["awake"])),
    ("open items — the pile, awake",
                        Dict("state" => ["open"], "sleep" => ["awake"])),
    ("waiting on me",  Dict("tag" => ["second"], "kind" => "pr",
                            "author" => [AUTHOR_OTHERS], "sleep" => ["awake"])),
    ("waiting on them", Dict("tag" => ["second"], "author" => [AUTHOR_ME],
                             "sleep" => ["awake"])),
    ("ready to merge", Dict("bucket" => ["needs-merge"], "sleep" => ["awake"])),
    ("red CI, mine",   Dict("author" => [AUTHOR_ME], "bucket" => ["needs-edits"],
                            "sleep" => ["awake"])),
    ("unanswered",     Dict("bucket" => ["needs-reply"], "sleep" => ["awake"])),
    ("filed away",     Dict("sleep" => ["filed", "snoozed"])),
]

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
    for (key, values, set) in (("seen", SEEN, f.seen), ("sleep", SLEEP, f.sleep),
                               ("state", OVER, f.over), ("tag", TAGS, f.tags))
        haskey(d, key) || continue
        v = d[key]
        for x in (v isa AbstractString ? [v] : v)
            k = Symbol(x)
            any(y -> y[1] === k, values) ? push!(set, k) :
                (bad = string(" \u00b7 no ", key, " '", x, "'"))
        end
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
    for (key, values, set) in (("seen", SEEN, f.seen), ("sleep", SLEEP, f.sleep),
                               ("state", OVER, f.over), ("tag", TAGS, f.tags))
        isempty(set) && continue
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

"""Rows for the filter pane: the way out, the disposition checkboxes, two radio
groups, then four more checkbox axes.

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
    # The axes that are about the item and you rather than about what it is.
    # The first three are partitions - every row answers exactly one value - so
    # their counts add up to the list, which is what makes them worth reading;
    # `tag` is the odd one, where a row can carry all three or none, and it
    # behaves like the label axis below. Checkboxes throughout: "snoozed or
    # filed" and "unread or read" are both questions somebody asks, and a radio
    # cannot say either.
    for (axis, label, values, tally, sel) in
            ((:seen, "seen", SEEN, n.seens, f.seen),
             (:sleep, "sleep", SLEEP, n.sleeps, f.sleep),
             (:over, "state", OVER, n.overs, f.over),
             (:tag, "tag", TAGS, n.tags, f.tags))
        push!(rows, (:head, "", label))
        for (k, name) in values
            push!(rows, (axis, string(k), string(k in sel ? "[x] " : "[ ] ",
                                                 rpad(name, 18), get(tally, k, 0))))
        end
        push!(rows, (:head, "", ""))
    end
    push!(rows, (:head, "", "kind"))
    for (k, name) in KINDS
        push!(rows, (:kind, string(k), string(f.kind === k ? "(•) " : "( ) ",
                                              rpad(name, 18), get(n.kinds, k, 0))))
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

The groups are what you actually move between - the way out, then seen, state,
kind, category, repo, label, author - and with a couple of hundred labels one of
them is long enough that stepping into it a row at a time is not stepping into
it.
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
    if axis in (:seen, :sleep, :over, :tag)
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
    # has to be current for a row to arrive in it. One read of `marks.json` for
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
    for (values, set) in ((SEEN, f.seen), (SLEEP, f.sleep), (OVER, f.over),
                          (TAGS, f.tags))
        isempty(set) ||
            push!(parts, join([last(x) for x in values if first(x) in set], "+"))
    end
    isempty(parts) && push!(parts, "everything")
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
    join(parts, " · ")
end
