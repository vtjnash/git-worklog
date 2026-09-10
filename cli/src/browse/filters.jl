# The filter and view model: what is shown, in what order, and the pane that
# says so. Tag sets over one list rather than a menu of lanes - state is
# exclusive so it reads as a radio group, categories and repos are additive.


# --- filters ---------------------------------------------------------------
#
# The lane menu forced one choice at a time and made you back out to change it.
# The same information reads better as tag sets applied to a single list: state
# is exclusive so it behaves as a radio group, while categories and repos are
# additive and behave as checkboxes.

# `mine` is not here, and was. It said `author == login()` in the state axis,
# which is the author axis said twice - and the author axis says it better,
# since `@me` also covers an adopted branch (no author, local url) and an issue
# you opened, both of which the state refused.
#
# It could not be removed until now for one reason: `stale` swept 44 of your own
# pull requests into the backlog, and `mine` was the only lane that did not
# subtract the backlog, so it was the only place they could be seen. With the
# eviction gone, `active` + `@me` is that list and two more besides.
const STATES = [(:active, "active"), (:unread, "unread"),
                (:second, "second look"), (:drafts, "drafts"),
                (:touched, "touched"), (:snoozed, "snoozed"),
                (:backlog, "backlog"), (:archived, "archived"), (:all, "all")]

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

"""The order a lane opens in, where the lane implies one.

Not a preference, a definition: the `touched` lane *is* the interaction clock -
membership in it is having acted on something - so the clock is the order it
means, and arriving in it sorted by anything else asks the reader to press `w`
to see the thing they came for.

Every other lane is deliberately absent, which reads as newest-first - the
order an inbox has, and the answer use gave to the question this table used to
leave open. It is still where a lane that wants a different one says so. `w`
still overrides, until the lane changes.
"""
const LANE_SORT = Dict(:touched => :touched)

"""The order to open `state` in - newest first, when the lane implies none."""
lane_sort(state::Symbol) = get(LANE_SORT, state, :latest)

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

mutable struct Filters
    state::Symbol
    buckets::Set{String}      # empty means every category
    repos::Set{String}        # empty means every repo
    labels::Set{String}       # empty means every label
    kind::Symbol              # :both | :pr | :issue
    authors::Set{String}      # empty means anybody; @me and @anyone-else are
                              # values here as well as logins
    seen::Set{Symbol}         # empty means every disposition; see `DISPOSITIONS`
end
# The shorter shapes are the ones from before there was a kind, an author or a
# disposition, kept because every caller of them means "any of those" - which
# is what the defaults say.
Filters(state, buckets, repos, labels, kind, authors) =
    Filters(state, buckets, repos, labels, kind, authors, Set{Symbol}())
Filters(state, buckets, repos, labels, kind) =
    Filters(state, buckets, repos, labels, kind, Set{String}())
Filters(state, buckets, repos, labels) =
    Filters(state, buckets, repos, labels, :both, Set{String}())
Filters() = Filters(:active, Set{String}(), Set{String}(), Set{String}())

"""Is this the filter the browser opens with - nothing asked of it?

Asked of the value rather than tracked, so it stays true however the filter got
here: a view, a picker, `\`` going back, or every checkbox toggled off one at a
time all reach the same place, and the row that offers to clear it should say
so in all four.
"""
isdefault(f::Filters) =
    f.state === :active && f.kind === :both && isempty(f.seen) &&
    isempty(f.buckets) && isempty(f.repos) && isempty(f.labels) &&
    isempty(f.authors)

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
                                            # not the seen bit; see `disposition`
    read::Dict{String,String} = EMPTY_TOUCHED
    touched::Dict{String,String} = EMPTY_TOUCHED
    archived::Dict{String,String} = EMPTY_TOUCHED
    drafts::Dict{String,String} = EMPTY_TOUCHED
end
Marks(st) = Marks(st.unread, st.read, st.touched, st.archived, st.drafts)

const DISPOSITIONS = [(:unseen, "unseen"), (:unread, "unread"), (:read, "read"),
                      (:snoozed, "snoozed"), (:archived, "archived")]

"""Where one item stands with you, as a single value.

Five states, exclusive by construction, decided in this order - the first that
applies wins:

  1. **archived** - `state.toml` carries an `archive` stamp.
  2. **snoozed**  - it is asleep, as of the last refresh to have looked.
  3. **unseen**   - no read stamp at all. *Never been in front of you.*
  4. **unread**   - a stamp, older than the item's `updated`.
  5. **read**     - a stamp at or after it.

**Unseen and unread are different and both are wanted**, which is the finding
this is built on. The firehose browse wants *unseen* - almost all of nine
hundred rows, and it needs nothing but the read stamps. The incoming inbox wants
*unread* - you looked, it moved, look again - and must not fill with 2014 issues
merely because nobody ever opened them. The `unread` lane is neither: it is
membership in `inbox.json`, which is what the poll saw move in the repos it
watches inside its lookback window, and that is a narrower question than either.

**One value, not five bools.** They are exclusive, so the exclusivity belongs in
the value rather than in a precedence rule re-applied wherever something is
read - which is what it is today: `snoozed` is a bool on the item, unread is
membership in a `Set`, archived is a lookup in a map, and the order between them
is written out again at every site that cares.

**Computed, not stored.** On `Item` it would be derived state that goes stale
the moment `r` is pressed: `Item` is immutable and rebuilt by the refresh, so
the browser would have to rewrite every row it touched. Computed, the filter is
`disposition(it, ...) in f.seen` and there is nothing to keep in step.

The seen bit is the only mark it needs; `archived` is `state.toml`'s and asleep
is the refresh's, carried on the item because deciding it here would be a second
opinion - see `snooze_active`.
"""
function disposition(it::Item, m::Marks = Marks())
    haskey(m.archived, it.url) && return :archived
    it.snoozed && return :snoozed
    seen = get(m.read, it.url, nothing)
    seen === nothing && return :unseen
    # An item with no `updated` is a synthetic one - an adopted branch, an
    # import a refresh has not caught up with - and a stamp on it is the only
    # thing anybody has said about whether it has been seen.
    seen < it.updated ? :unread : :read
end

"""Is this item one of the five dispositions asked for?

An empty set is every one of them, which is what every other multiselect axis
here means by empty and what makes the corpus what is left when nothing has
been narrowed.
"""
seen_ok(seen::Set{Symbol}, it::Item, m::Marks) =
    isempty(seen) || disposition(it, m) in seen

"Does this item belong to one of the exclusive states - the `STATES` radio group?"
function state_ok(state::Symbol, it::Item, m::Marks = Marks())
    unread, touched, archived, drafts = m.unread, m.touched, m.archived, m.drafts
    state === :unread  && return it.url in unread
    state === :snoozed && return it.snoozed
    state === :backlog && return it.backlog
    # Archived work is out of the two lanes that answer "what should I be doing"
    # and stays in the rest: `touched` is a record of what happened and `all` is
    # everything, and neither is a to-do list.
    state === :archived && return haskey(archived, it.url)
    state === :active  && return !(it.snoozed || it.backlog || haskey(archived, it.url))
    # Work that has gone quiet on somebody. Derived rather than asked for - see
    # `second_look` - so this lane is never empty because you forgot to fill it.
    state === :second  && return !isempty(it.secondlook) && !haskey(archived, it.url)
    # Everything you have actually done something to, which is what the
    # interaction clock is a record of - and nothing else writes to it, so this
    # is work rather than browsing.
    state === :touched && return haskey(touched, it.url)
    # Work you have started saying and not said. Archived items stay in it: a
    # draft on something you have put away is the strongest reason there is to
    # be shown it again, since the two together mean you filed the work and
    # never sent the words.
    state === :drafts  && return haskey(drafts, it.url)
    true                                              # :all
end

const EMPTY_TOUCHED = Dict{String,String}()

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

"An empty tag set means 'no restriction', so a fresh filter shows everything."
function matches(f::Filters, it::Item, m::Marks = Marks())
    state_ok(f.state, it, m) || return false
    seen_ok(f.seen, it, m) || return false
    kind_ok(f.kind, it) || return false
    author_ok(f.authors, it) || return false
    isempty(f.buckets) || it.bucket in f.buckets || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    isempty(f.labels)  || any(in(f.labels), it.labels) || return false
    true
end

"""
    axis_counts(st) -> (; states, seens, kinds, buckets, repos, labels, authors)

How many items each filter value would select, in one pass over the items.

Every count is against the *other* axes only - a category shows what selecting
it would add, not a total that ignores the rest of the filter - so there is one
predicate per axis over the same item, seven of them, and computing them together
is what makes this one pass instead of one per row. It was a pass per row: 93 rows
over 2050 items came to 190,650 `matches` calls per build and two builds per
keystroke, which made the filter pane the only part of the UI with visible lag -
128ms a frame against 0.7ms for the item list.
"""
function axis_counts(st)
    f, m = st.filters, Marks(st)
    states = Dict{Symbol,Int}()
    seens = Dict{Symbol,Int}()
    kinds = Dict{Symbol,Int}()
    buckets = Dict{String,Int}()
    repos = Dict{String,Int}()
    labels = Dict{String,Int}()
    authors = Dict{String,Int}()
    bump!(d, k) = d[k] = get(d, k, 0) + 1
    for it in st.all
        bok = isempty(f.buckets) || it.bucket in f.buckets
        rok = isempty(f.repos)   || it.repo in f.repos
        lok = isempty(f.labels)  || any(in(f.labels), it.labels)
        sok = state_ok(f.state, it, m)
        kok = kind_ok(f.kind, it)
        aok = author_ok(f.authors, it)
        # Once per item and not once per value: it is a lookup in two maps and a
        # comparison, and the axis below would otherwise ask for it five times.
        d = disposition(it, m)
        dok = isempty(f.seen) || d in f.seen
        if bok && rok && lok && kok && aok && dok
            for (k, _) in STATES
                state_ok(k, it, m) && bump!(states, k)
            end
        end
        # An item answers exactly one disposition, so its own is the only value
        # it counts towards - which is what makes this axis a partition of the
        # list and the five counts add up to it.
        sok && bok && rok && lok && kok && aok && bump!(seens, d)
        if sok && bok && rok && lok && aok && dok
            for (k, _) in KINDS
                kind_ok(k, it) && bump!(kinds, k)
            end
        end
        if sok && bok && rok && lok && kok && dok
            # One item counts towards its own author *and* towards whichever of
            # the two predicates it answers, since picking either would bring it.
            isempty(it.author) || bump!(authors, it.author)
            author_ok(Set([AUTHOR_ME]), it) && bump!(authors, AUTHOR_ME)
            author_ok(Set([AUTHOR_OTHERS]), it) && bump!(authors, AUTHOR_OTHERS)
        end
        sok && rok && lok && kok && aok && dok && bump!(buckets, it.bucket)
        sok && bok && lok && kok && aok && dok && bump!(repos, it.repo)
        if sok && bok && rok && kok && aok && dok
            for l in it.labels
                bump!(labels, l)
            end
        end
    end
    (; states, seens, kinds, buckets, repos, labels, authors)
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
    # The way back to nothing, and the first row for the same reason the import
    # row leads the item list: `c` already clears the filter pane, and a control
    # nobody can find is a control nobody uses. It names no axis but `state`,
    # which - since a view clears every axis it does not name, sort included -
    # is exactly what a fresh `Filters()` is.
    ("the default — active, unfiltered, newest first",
                        Dict("state" => "active")),
    # The two modes, and the reason they are views rather than lanes: which work
    # is yours is the author axis, and what state it is in is the state axis.
    # One axis per question. A `mine` lane was the author axis said a second
    # time in a place it did not belong, and it is gone.
    ("my work — what I am carrying",
                        Dict("state" => "active", "author" => [AUTHOR_ME])),
    ("incoming — everyone else's",
                        Dict("state" => "active", "author" => [AUTHOR_OTHERS])),
    ("waiting on me",  Dict("state" => "second", "kind" => "pr",
                            "author" => [AUTHOR_OTHERS])),
    ("waiting on them", Dict("state" => "second", "author" => [AUTHOR_ME])),
    ("ready to merge", Dict("state" => "active", "bucket" => ["needs-merge"])),
    ("red CI, mine",   Dict("state" => "active", "author" => [AUTHOR_ME],
                            "bucket" => ["needs-edits"])),
    ("unanswered",     Dict("state" => "active", "bucket" => ["needs-reply"])),
    ("unread",         Dict("state" => "unread")),
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
    if haskey(d, "state")
        f.state = Symbol(d["state"])
        # Said rather than silently ignored. `state_ok` ends in `true` - the
        # `:all` case - so a state that is not one falls through it and shows
        # *everything*, which reads as a view that has stopped filtering rather
        # than as one that is misspelt. It cost a real bug the day `mine` was
        # removed: the built-in "red CI, mine" went on naming it and went on
        # returning the right twelve rows, because every `needs-edits` item
        # happened to be yours. `config.toml` writes these by hand.
        if !any(x -> x[1] === f.state, STATES)
            bad = string(" \u00b7 no state '", d["state"], "', showing all")
        end
    end
    if haskey(d, "seen")
        v = d["seen"]
        for x in (v isa AbstractString ? [v] : v)
            k = Symbol(x)
            any(y -> y[1] === k, DISPOSITIONS) ?
                push!(f.seen, k) :
                (bad = string(" \u00b7 no disposition '", x, "'"))
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
    # `sort = "none"` gets it even where the lane would have implied an order.
    st.sort = haskey(d, "sort") ? Symbol(d["sort"]) : lane_sort(f.state)
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
    lines = [string("[views.", repr(String(name)), "]"),
             string("state = ", repr(String(f.state)))]
    isempty(f.seen) ||
        push!(lines, string("seen = [",
                            join([repr(String(k)) for (k, _) in DISPOSITIONS
                                  if k in f.seen], ", "), "]"))
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
    # Where each item stands with you, and the one axis that is a partition:
    # every row answers exactly one of the five, so these counts add up to the
    # list. Checkboxes, because "unseen or unread" is the question the firehose
    # browse and the incoming inbox each ask half of.
    push!(rows, (:head, "", "seen"))
    for (k, name) in DISPOSITIONS
        push!(rows, (:seen, string(k), string(k in f.seen ? "[x] " : "[ ] ",
                                              rpad(name, 13), get(n.seens, k, 0))))
    end
    push!(rows, (:head, "", ""))
    push!(rows, (:head, "", "state"))
    for (k, name) in STATES
        push!(rows, (:state, string(k), string(f.state === k ? "(•) " : "( ) ",
                                              rpad(name, 13), get(n.states, k, 0))))
    end
    push!(rows, (:head, "", ""))
    push!(rows, (:head, "", "kind"))
    for (k, name) in KINDS
        push!(rows, (:kind, string(k), string(f.kind === k ? "(•) " : "( ) ",
                                              rpad(name, 14), get(n.kinds, k, 0))))
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
    if axis === :seen
        v = Symbol(val)
        v in st.filters.seen ? delete!(st.filters.seen, v) : push!(st.filters.seen, v)
    elseif axis === :state
        st.filters.state = Symbol(val)
        # The lane brings its order with it. `w` is still the override, and it
        # lasts until the lane changes again - which is the only rule here that
        # can be stated in one sentence, and the reason it is this one.
        st.sort = lane_sort(st.filters.state)
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
function filter_summary(f, order::Symbol = lane_sort(f.state))
    parts = [string(f.state)]
    isempty(f.seen) ||
        push!(parts, join([String(k) for (k, _) in DISPOSITIONS if k in f.seen], "+"))
    f.kind === :both || push!(parts, f.kind === :pr ? "pull requests" : "issues")
    # Named only when it is not the order this lane opens in. Newest-first is
    # the default everywhere now, and a summary that says so on every screen is
    # a phrase the reader stops seeing and a footer three words narrower for
    # the keys - while an order somebody chose with `w` is exactly what wants
    # saying, and stops being said the moment the lane changes it back.
    #
    # Not `sort`: that is the name of the function two lines down, and shadowing
    # it turned `sort(collect(f.buckets))` into a call on a Symbol.
    order === lane_sort(f.state) ||
        push!(parts, order === :latest ? "by when it moved" :
                     order === :touched ? "by when you acted" : "by url")
    isempty(f.authors) ||
        push!(parts, join(sort([axis_label(:author, a) for a in f.authors]), "+"))
    isempty(f.buckets) || push!(parts, join(sort(collect(f.buckets)), "+"))
    isempty(f.repos) || push!(parts, join([last(split(r, '/')) for r in sort(collect(f.repos))], "+"))
    isempty(f.labels) || push!(parts, join(sort(collect(f.labels)), "+"))
    join(parts, " · ")
end
