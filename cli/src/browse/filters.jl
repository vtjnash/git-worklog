# The filter and view model: what is shown, in what order, and the pane that
# says so. Tag sets over one list rather than a menu of lanes - state is
# exclusive so it reads as a radio group, categories and repos are additive.


# --- filters ---------------------------------------------------------------
#
# The lane menu forced one choice at a time and made you back out to change it.
# The same information reads better as tag sets applied to a single list: state
# is exclusive so it behaves as a radio group, while categories and repos are
# additive and behave as checkboxes.

const STATES = [(:active, "active"), (:unread, "unread"), (:mine, "mine"),
                (:second, "second look"),
                (:touched, "touched"), (:snoozed, "snoozed"),
                (:backlog, "backlog"), (:archived, "archived"), (:all, "all")]

"""How the list is ordered. Its own control, deliberately.

Sorting is orthogonal to all three filter axes - any order makes sense over any
selection - so it does not belong inside `Filters`, where it would multiply the
axes instead of sitting beside them. `w` cycles it.

`:none` is the order the lanes were fetched in, which is the order the dashboard
has always had.
"""
const SORTS = [(:none, "as fetched"), (:touched, "by when you last acted"),
               (:latest, "by when anything last happened")]

"""Issue, pull request, or both - the third radio group.

A radio and not a fourth tag axis: the values are exhausted by three and they
are mutually exclusive, so a set of them would only ever hold one thing or say
nothing. `Item.is_pr` was already there and every lane carries both kinds, which
is what made "issues only" impossible to ask for and obvious to want.
"""
const KINDS = [(:both, "both"), (:pr, "pull requests"), (:issue, "issues")]

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
end
# The shorter shapes are the ones from before there was a kind and before there
# was an author, kept because every caller of them means "any of those" - which
# is what the defaults say.
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
    f.state === :active && f.kind === :both && isempty(f.buckets) &&
    isempty(f.repos) && isempty(f.labels) && isempty(f.authors)

"Does this item belong to one of the five exclusive states?"
function state_ok(state::Symbol, it::Item, unread::Set{String},
                  touched::Dict{String,String} = EMPTY_TOUCHED,
                  archived::Dict{String,String} = EMPTY_TOUCHED)
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
    # Yours: an open pull request you wrote, or a branch you have claimed.
    # Both are things you are expected to carry, which is what makes them one
    # list rather than two.
    state === :mine    && return !haskey(archived, it.url) &&
                                 ((it.is_pr && !isempty(it.author) &&
                                   it.author == login()) || islocal(it))
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

"Newest first, and stable - so an untimed item keeps the order it was fetched in."
sortitems(items, mode::Symbol, touched::Dict{String,String}) =
    mode === :none ? items :
    sort(items; by = it -> sortkey(it, touched, mode), rev = true)

"Issue or pull request, with `:both` restricting nothing."
kind_ok(kind::Symbol, it::Item) = kind === :both || (kind === :pr) == it.is_pr

"""Whose it is. An empty set restricts nothing, as on every other axis.

An adopted branch has no author and is therefore yours: it is in this dashboard
because you claimed it, and nobody else wrote it.
"""
function author_ok(authors::Set{String}, it::Item)
    isempty(authors) && return true
    mine = it.author == login() || (isempty(it.author) && islocal(it))
    (mine && AUTHOR_ME in authors) && return true
    (!mine && AUTHOR_OTHERS in authors) && return true
    it.author in authors
end

"An empty tag set means 'no restriction', so a fresh filter shows everything."
function matches(f::Filters, it::Item, unread::Set{String},
                 touched::Dict{String,String} = EMPTY_TOUCHED,
                 archived::Dict{String,String} = EMPTY_TOUCHED)
    state_ok(f.state, it, unread, touched, archived) || return false
    kind_ok(f.kind, it) || return false
    author_ok(f.authors, it) || return false
    isempty(f.buckets) || it.bucket in f.buckets || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    isempty(f.labels)  || any(in(f.labels), it.labels) || return false
    true
end

"""
    axis_counts(st) -> (states, kinds, buckets, repos, labels, authors)

How many items each filter value would select, in one pass over the items.

Every count is against the *other* axes only - a category shows what selecting
it would add, not a total that ignores the rest of the filter - so there are
four different predicates over the same item, and computing them together is
what makes this one pass instead of one per row. It was a pass per row: 93 rows
over 2050 items came to 190,650 `matches` calls per build and two builds per
keystroke, which made the filter pane the only part of the UI with visible lag -
128ms a frame against 0.7ms for the item list.
"""
function axis_counts(st)
    f = st.filters
    states = Dict{Symbol,Int}()
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
        sok = state_ok(f.state, it, st.unread, st.touched, st.archived)
        kok = kind_ok(f.kind, it)
        aok = author_ok(f.authors, it)
        if bok && rok && lok && kok && aok
            for (k, _) in STATES
                state_ok(k, it, st.unread, st.touched, st.archived) && bump!(states, k)
            end
        end
        if sok && bok && rok && lok && aok
            for (k, _) in KINDS
                kind_ok(k, it) && bump!(kinds, k)
            end
        end
        if sok && bok && rok && lok && kok
            # One item counts towards its own author *and* towards whichever of
            # the two predicates it answers, since picking either would bring it.
            isempty(it.author) || bump!(authors, it.author)
            author_ok(Set([AUTHOR_ME]), it) && bump!(authors, AUTHOR_ME)
            author_ok(Set([AUTHOR_OTHERS]), it) && bump!(authors, AUTHOR_OTHERS)
        end
        sok && rok && lok && kok && aok && bump!(buckets, it.bucket)
        sok && bok && lok && kok && aok && bump!(repos, it.repo)
        if sok && bok && rok && kok && aok
            for l in it.labels
                bump!(labels, l)
            end
        end
    end
    (states, kinds, buckets, repos, labels, authors)
end

apply_filters(f, all, unread, touched = EMPTY_TOUCHED, archived = EMPTY_TOUCHED) =
    [it for it in all if matches(f, it, unread, touched, archived)]

"""Which axes list only what is applied, and reach the rest through the picker.

The pane used to try to show what was *available*, and there is too much of it:
~140 repos, several hundred labels, more authors than either. Showing the first
eight of them was a compromise that served neither purpose - too many rows to
skim and too few to choose from, in an order nobody could predict.

So these axes are a readout of what is *on*, and the picker row underneath is
where choosing happens. It has every value and it narrows by typing, which is
the only thing that scales to several hundred; and the pane collapses to the
length of the answer rather than the length of the question.

Category is exempt, and is the whole axis: thirteen values that are each a
different kind of work, short enough to read at a glance and the one nobody
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
    ("the default — active, unfiltered, as fetched",
                        Dict("state" => "active")),
    ("waiting on me",  Dict("state" => "second", "kind" => "pr",
                            "author" => [AUTHOR_OTHERS])),
    ("waiting on them", Dict("state" => "second", "author" => [AUTHOR_ME])),
    ("ready to merge", Dict("state" => "active", "bucket" => ["needs-merge"])),
    ("red CI, mine",   Dict("state" => "mine", "bucket" => ["needs-edits"])),
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
    haskey(d, "state") && (f.state = Symbol(d["state"]))
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
    # "as fetched" nameable, which nothing else could say.
    st.sort = haskey(d, "sort") ? Symbol(d["sort"]) : :none
    refilter!(st)
    string("[", filter_summary(f, st.sort), "]")
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

"""Rows for the filter pane: the radio group, then the two checkbox groups.

Counts are computed against the other axes only, so a category shows how many
items selecting it would actually add rather than a total that ignores the rest
of the filter.
"""
function filter_rows(st)
    f, rows = st.filters, Tuple{Symbol,String,String}[]
    (nstate, nkind, nbucket, nrepo, nlabel, nauthor) = axis_counts(st)
    # The way out, at the top, for the same argument the import row won: `c`
    # has always done this and nothing on screen said so. It leads because a
    # filter you want to abandon is one you are already lost in, and the top of
    # the pane is the one place the cursor can reach without reading anything.
    push!(rows, (:reset, "", string("  ↺ clear every filter",
                                    isdefault(f) ? "" : "  (c)")))
    push!(rows, (:head, "", "state"))
    for (k, name) in STATES
        n = get(nstate, k, 0)
        push!(rows, (:state, string(k), string(f.state === k ? "(•) " : "( ) ",
                                              rpad(name, 13), n)))
    end
    push!(rows, (:head, "", ""))
    push!(rows, (:head, "", "kind"))
    for (k, name) in KINDS
        n = get(nkind, k, 0)
        push!(rows, (:kind, string(k), string(f.kind === k ? "(•) " : "( ) ",
                                              rpad(name, 14), n)))
    end
    for (axis, label, values, tally) in ((:bucket, "category", st.buckets, nbucket),
                                         (:repo, "repo", st.repos, nrepo),
                                         (:label, "label", st.labels, nlabel),
                                         (:author, "author", st.authors, nauthor))
        push!(rows, (:head, "", ""))
        push!(rows, (:head, "", label))
        sel = axis_set(f, axis)
        for v in values
            n = get(tally, v, 0)
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
            n == 0 && !on && !always && continue
            # What is applied is listed, and on the long axes that is all that
            # is: the picker row below has every value and narrows by typing,
            # which is the only thing that scales to several hundred labels.
            # The pane is then as long as the answer rather than as long as the
            # question.
            (!on && !always && axis in AXIS_APPLIED_ONLY) && continue
            push!(rows, (axis, v, string(on ? "[x] " : "[ ] ",
                                         rpad(first(axis_label(axis, v), 22), 24), n)))
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

The groups are what you actually move between - state, category, repo, label -
and with a couple of hundred labels the last one is long enough that stepping
into it a row at a time is not stepping into it.
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
    tallies = axis_counts(st)
    tally = axis === :repo ? tallies[4] : axis === :label ? tallies[5] : tallies[6]
    values = axis === :repo ? st.repos : axis === :label ? st.labels : st.authors
    sel = axis_set(st.filters, axis)
    opts = Tuple{String,Any}[(string(rpad(axis_label(axis, v), 30), " ",
                                     get(tally, v, 0)), v)
                             for v in values if !(v in sel)]
    isempty(opts) && return false
    push_view!(ctrl, ChooseView(string("Filter by ", axis), "type to narrow", opts,
        v -> begin
            push!(axis_set(st.filters, axis), String(v))
            refilter!(st)
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
    if axis === :state
        st.filters.state = Symbol(val)
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
    refilter!(st)
    true
end

"Does this item answer to `/query`? Title or ref, case-insensitively."
hits(it::Item, q::AbstractString) =
    occursin(lowercase(q), lowercase(it.title)) || occursin(lowercase(q), lowercase(it.ref))

function refilter!(st)
    keep = (st.sel == 0 || isempty(st.items)) ? "" : st.items[st.sel].url
    # Re-read here rather than per frame: this runs when something has changed,
    # and `render` is pure. The `touched` lane is membership in this map, so it
    # has to be current for a row to arrive in it.
    st.touched = load_touched()
    st.archived = field_map("archive")
    st.items = sortitems(apply_filters(st.filters, st.all, st.unread, st.touched,
                                       st.archived),
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
    # Stay on the same item when possible, failing that the first one - and the
    # import row only when there is no item at all to be on. Deliberately not
    # sticky: you land on that row by moving to it, and a rebuilt list that has
    # work in it should open on the work rather than on the way to add more.
    st.sel = isempty(st.items) ? 0 : something(i, 1)
    st.top = 1
end

"One-line summary of what is applied, for the frame title."
function filter_summary(f, order::Symbol = :none)
    parts = [string(f.state)]
    f.kind === :both || push!(parts, f.kind === :pr ? "pull requests" : "issues")
    # Not `sort`: that is the name of the function two lines down, and shadowing
    # it turned `sort(collect(f.buckets))` into a call on a Symbol.
    order === :none || push!(parts, order === :latest ? "by when it moved" :
                                    "by when you acted")
    isempty(f.authors) ||
        push!(parts, join(sort([axis_label(:author, a) for a in f.authors]), "+"))
    isempty(f.buckets) || push!(parts, join(sort(collect(f.buckets)), "+"))
    isempty(f.repos) || push!(parts, join([last(split(r, '/')) for r in sort(collect(f.repos))], "+"))
    isempty(f.labels) || push!(parts, join(sort(collect(f.labels)), "+"))
    join(parts, " · ")
end
