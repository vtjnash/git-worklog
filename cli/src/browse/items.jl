# Items that came from neither a search lane nor `facts.json`: one imported by
# url, and a local branch adopted into being an item. Both are given a synthetic
# url, which is what makes notes, snoozes, the clock and the filters work on
# them without a line of code each.

"""The one row in the list that is not an item.

Importing is not an action on whatever happens to be selected - it is how
something that is *not* here gets in - so it is a row you move onto and press
`\u21b5` on rather than a key you have to have been told about. `i` still does it
from anywhere, and this is what tells you that.

It is not in `st.items`. A row that is not an item, in the vector every filter,
sort, count and per-item key reads, would have to be excluded from all of them
one by one. Instead the list is drawn with this row in front of it and the
cursor is allowed one place further up: `st.sel == 0` is this row, and every
item index stays exactly what it was. That also makes the empty list right for
free - nothing selected and nothing to select is precisely when importing is
what you came to do.
"""
const NEWROW = "\u002b import an item by url"

"What the detail pane says while the import row is selected."
newnodes() = [Node("import an item by url",
                   "`\u21b5` here, or `i` from anywhere, asks for a url.\n\n" *
                   "Everything else in this list arrived through a lane - your " *
                   "pull requests, review requests, mentions, the repos in " *
                   "`config.toml`. An issue in a repo nobody watches that does " *
                   "not mention you matches none of them, and a url is not a " *
                   "query, so this is the way in.\n\n" *
                   "It is followed from then until you archive it, with notes, " *
                   "snoozes, the clock and the buckets all working on it as they " *
                   "do on anything else. The one thing it cannot have is the " *
                   "events poller, which only watches the repos named in " *
                   "`config.toml` - so new activity on an imported item will " *
                   "still reach you by email.",
                   :md, true)]

"""Ask for a url, and follow whatever it names.

The one thing the lanes cannot reach: an issue in a repo nobody watches that
does not mention you matches nothing by construction. From here it is an
ordinary item - notes, snoozes, the clock, the buckets and archive are all keyed
by url and work on it the moment it exists.

The one thing it cannot have is the events lane, which is why the prompt says so
rather than leaving it to be found out: an item is imported *precisely because*
its repo is not in `[events].repos`.
"""
function import_action(st::BState, ctrl::Controller, at::DateTime)
    push_view!(ctrl, PromptView(
        "Import an item",
        "paste the url of an issue or pull request, in any repo. It is followed " *
        "from now until you archive it - but not by the events poller, which " *
        "only watches the repos in config.toml, so new activity on it will " *
        "still reach you by email.",
        u -> (st.status = import_url!(st, u, at))))
end

"""Write the import, fetch the item, and go to it.

The fetch is on the key loop rather than behind it. An import is one request the
user just asked for by hand and is waiting on the answer to, and a row that
appears a second later somewhere in a list of two thousand is not an answer.

Nothing is written until the item is known to exist: a url that resolves to
nothing would otherwise leave a line in `state.toml` that fetches nothing on
every refresh forever.
"""
function import_url!(st::BState, raw::AbstractString, at::DateTime)
    u = item_url(raw)
    u === nothing && return "not the url of an issue or a pull request"
    was = findfirst(x -> x.url == u, st.all)
    it = if was === nothing
        try
            item_by_url(u, at)
        catch e
            return string("could not import it: ", first(oneline(sprint(showerror, e)), 100))
        end
    else
        # Already here, which is the common case rather than the odd one: an old
        # issue in a repo that is tracked anyway, a pull request of yours in one
        # that is not. No second row, no second request - what an import of it
        # means is that it should be in front of you again.
        st.all[was]
    end
    set_fields(u, ["imported" => string(Date(at))], at)
    # What the import is about to change, so that undoing it can change it back.
    # An import is three writes and not one - the field, the inbox row and the
    # read stamp - and an undo that took back only the field left the row in the
    # unread lane for good: no poll covers the repo, which is why it was
    # imported, so nothing would ever have cleared it.
    hadrow = Events.in_inbox(u)
    prevread = read_at(u)
    # Unread either way, and the same unread the poller writes. An import is
    # somebody - you a minute ago, or an agent - saying this wants looking at,
    # and the lane that answers "what have I not looked at" is the one it
    # belongs in. `inbox_add!` leaves a poll's own richer entry alone.
    Events.inbox_add!([inbox_row(it, at)]; overwrite = false)
    push!(st.unread, u)
    was === nothing && add_item!(st, it)
    push!(st.undos, Undo(string("import ", it.ref), () -> begin
        set_fields(u, ["imported" => nothing])
        set_read(u, prevread)
        # A row a poll wrote is not this import's to remove: the import found it
        # there and left it alone, and so does taking the import back.
        hadrow || Events.inbox_drop!([u])
        delete!(st.unread, u)
        was === nothing && drop_item!(st, u)
    end))
    r = select_item!(st, it)
    string(was === nothing ? "imported " : "already here, marked unread: ", it.ref,
           r isa String && !isempty(r) ? string(" \u00b7 ", r) : "",
           was === nothing ? " \u00b7 no events lane: its repo is not watched" : "")
end

"""Claim a local branch as work of yours, and make it an item.

Explicit by design. Nothing becomes yours by being present in a checkout - the
whole point of the guard on the automatic route is that `gh pr checkout` leaves
other people's branches lying about - so this is what a key press does and it
can always be undone.
"""
function adopt!(st::BState, repo, branch, at::DateTime)
    isempty(branch) && return "a detached head has no branch to adopt"
    u = localurl(repo, branch)
    get_field(u, "adopted") === nothing || return string(localref(repo, branch),
                                                         " is already yours")
    prev = touched_at(u)
    set_fields(u, ["adopted" => string(Date(at))], at)
    it = local_item(u, branchfor(repo, branch))
    add_item!(st, it)
    push!(st.undos, Undo(string("adopt ", it.ref), () -> begin
        set_fields(u, ["adopted" => nothing])
        set_touched(u, prev)
        drop_item!(st, u)
    end))
    string("adopted ", it.ref)
end

"""Give a branch back: it stops being an item and its row goes.

Whatever was written about it stays in `state.toml` - a note is not undone by
deciding the work is not yours - so re-adopting finds it again.
"""
function unadopt!(st::BState, repo, branch, at::DateTime)
    u = localurl(repo, branch)
    get_field(u, "adopted") === nothing && return string(localref(repo, branch),
                                                         " was not adopted")
    was = get_field(u, "adopted")
    prev = touched_at(u)
    set_fields(u, ["adopted" => nothing], at)
    drop_item!(st, u)
    push!(st.undos, Undo(string("release ", localref(repo, branch)), () -> begin
        set_fields(u, ["adopted" => was])
        set_touched(u, prev)
        add_item!(st, local_item(u, branchfor(repo, branch)))
    end))
    string("released ", localref(repo, branch))
end

"What the survey knows about one branch, or `nothing`. One repo, not every one."
function branchfor(repo, branch)
    p = repo_path(repo)
    p === nothing && return nothing
    for b in try; branches(repo, p); catch; Branch[]; end
        b.name == branch && return b
    end
    nothing
end

"""Make every value this item carries selectable in the filter pane.

Each axis is built once, from the items the browser opened with, so a bucket,
repo, label or author arriving mid-session - an import, an adoption, a label
just put on - is a filter nobody can ask for until it is added here.

Your own login is left off the author axis, the same as when it is built: `@me`
is that row.
"""
function note_axes!(st::BState, it::Item)
    it.bucket in st.buckets || push!(st.buckets, it.bucket)
    it.repo in st.repos || push!(st.repos, it.repo)
    for l in it.labels
        l in st.labels || push!(st.labels, l)
    end
    (isempty(it.author) || it.author == login() || it.author in st.authors) ||
        push!(st.authors, it.author)
    nothing
end

"Put a synthetic item into the browser's lists."
function add_item!(st::BState, it::Item)
    findfirst(x -> x.url == it.url, st.all) === nothing || return false
    push!(st.all, it)
    note_axes!(st, it)
    refilter!(st)
    true
end

"""A copy of `it` with some fields changed.

`Item` is immutable - it is built from `facts.json` and read from everywhere -
so anything that changes one between refreshes hands back a new one. Rebuilt
from `fieldnames` with the named fields swapped, rather than field by field: two
dozen names written out here would be a list to keep in step with the struct.

Two callers, and both are a write that has landed: `L` knows the label set it
just changed, and `M` knows the pull request is merged and who merged it. Both
are facts `facts.json` carries and neither can write, so without this the pane
went on showing the old one until the next refresh and the status line had to
apologise for it.
"""
with(it::Item; kw...) =
    Item((get(kw, f, getfield(it, f)) for f in fieldnames(Item))...)

withlabels(it::Item, labels::Vector{String}) = with(it; labels = labels)

"Put a changed copy of an item back where the old one was, keyed by url."
function replace_item!(st::BState, it::Item)
    i = findfirst(x -> x.url == it.url, st.all)
    i === nothing && return false
    st.all[i] = it
    note_axes!(st, it)
    refilter!(st)
    true
end

"Take one back out again, by url."
function drop_item!(st::BState, url::AbstractString)
    i = findfirst(x -> x.url == url, st.all)
    i === nothing && return false
    deleteat!(st.all, i)
    refilter!(st)
    true
end
