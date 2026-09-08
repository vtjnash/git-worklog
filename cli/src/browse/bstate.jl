# What the browser is looking at, and the one step of it that can be taken
# back. Everything below this file takes a `BState` and most of it mutates one.

"""One undoable local action: what it was, and how to put it back.

The stack's scope is exactly the lowercase keys, and not by coincidence. A
capital reaches GitHub, and nothing here could take that back - so if this ever
holds one, it is the binding rule that has gone wrong, not this.
"""
struct Undo
    what::String
    undo::Any            # () -> Nothing
end

"""The browser's whole state.

Keyword-constructed, with defaults: it has close to fifty fields, and the
positional form is a place where two of them get transposed silently. `render`
mutates the scroll offsets and the two geometry readings (`hdr`, `nmeta`) that
the mouse needs, so it is pure in what it returns but not in what it touches.
"""
Base.@kwdef mutable struct BState <: View
    items::Vector{Item} = Item[]
    title::String
    sel::Int = 1
    top::Int = 1
    nodes::Vector{Node} = Node[]
    nrow::Int = 1          # cursor into the flattened rows, not into nodes:
                           # scrolling inside a long comment needs row
                           # granularity, and folding still works because every
                           # row knows which node it belongs to
    ntop::Int = 1
    focus::Symbol = :list           # :list | :detail
    mode::Symbol = :comments        # :comments | :diff | :checks
    loaded::String = ""
    place::Dict{String,NTuple{2,Int}} = Dict{String,NTuple{2,Int}}()
                           # where the reader was in each thread they have been
                           # in: a loaded key -> the `(nrow, ntop)` the pane was
                           # left at. Keyed like `loaded` and so by mode as well
                           # as by url, because a comment thread and a diff are
                           # two readings of one item and are two places to come
                           # back to. Lives as long as the browser does; coming
                           # back to a thread is the whole point of it, and a
                           # row per item visited is nothing.
    nkey::String = ""      # the key `nrow` and `ntop` are a position in. Not
                           # `loaded`: from the moment a fetch starts the cursor
                           # belongs to what is coming rather than to what is
                           # still on screen.
    status::String = ""
    pending::Union{Nothing,Task} = nothing   # in-flight fetch; the key loop
    pendkey::String = ""                     # never blocks
    quiet::Bool = false             # the fetch in flight is a background
                                    # re-read: what is on screen stays there
    refreshkey::String = ""         # the loaded key a stale entry wants re-read,
    refreshat::Float64 = 0.0        # and the second it becomes due
    all::Vector{Item}               # unfiltered
    unread::Set{String} = Set{String}()
    filters::Filters = Filters()
    prev::Union{Nothing,Filters} = nothing   # one slot deep, for `\``: diving
                                             # into a view and getting back out
                                             # is the move, and `z` is for
                                             # actions rather than for looking
    buckets::Vector{String} = String[]
    repos::Vector{String} = String[]
    labels::Vector{String} = String[]
    authors::Vector{String} = String[]   # the two predicates, then every login
                                         # that appears, alphabetically
    sort::Symbol = :latest          # how the list is ordered; see `SORTS`
    touched::Dict{String,String} = Dict{String,String}()   # the interaction
                                    # clock, read when something changes rather
                                    # than per frame
    archived::Dict{String,String} = Dict{String,String}()  # url -> the date it
                                    # was put away, from `state.toml`
    drafts::Dict{String,String} = Dict{String,String}()    # url -> when a review
                                    # was last written to on it and not sent;
                                    # the one lane GitHub cannot be asked for
    lmode::Symbol = :items          # :items | :filters
    frow::Int = 3        # the first state row; 1 is the reset row and 2 its head
    wake::Any = nothing             # set by the controller; called when a fetch lands
    hdr::Int = 0           # rows of item title above the nodes in the detail
                           # pane; the mouse needs it to turn a screen row into
                           # an `nrow`, and only `render` knows how tall it got
    nmeta::Int = 0         # metadata lines the pane last drew; it sizes to its
                           # content, so the heights depend on it
    diw::Int = 0           # the detail pane's inner width and page, as it was
    dpage::Int = 0         # last *drawn*. Not what `layout` would give: with a
                           # hosted pane beside it the detail gets half the
                           # screen and the full height, and every key that
                           # indexes a row - n/N, the search, page down - has to
                           # measure against the wrapping the reader is looking
                           # at rather than the one it would have had alone
    meta::Any = nothing    # Events.itemmeta result for `metakey`, or nothing
    checks::Any = nothing  # check_contexts result, or nothing
    metakey::String = ""
    # The pending review, if there is one, and which item it belongs to. Held
    # rather than asked for per frame, and kept after the cursor moves away -
    # that is the whole point of it: a draft you have walked off is the one that
    # gets forgotten.
    batch::Any = nothing            # (url, ref, review, n) or nothing
    metapending::Union{Nothing,Task} = nothing
    sessions::Vector{NamedTuple} = NamedTuple[]  # live multiplexer sessions, as
                                          # of the last metadata fetch; asking
                                          # costs a process, and `render` is pure
    anchor::Int = 0        # row a drag started on
    sela::Int = 0          # selected range in `nrow` coordinates; 0 for none
    selb::Int = 0
    mouse::Bool = true     # mirrors the controller, for the footer
    undos::Vector{Undo} = Undo[]   # local actions, newest last
    search::String = ""    # the live query; "" when no search is running
    searchin::Symbol = :list  # the pane it was started in, and belongs to
    hidden::Int = 0        # matches inside folded nodes, counted when re-aiming
    typing::Bool = false   # is the query still being typed?
    reload::Bool = false   # something under `data/` changed and it was not us;
                           # the next wake takes the records again
    refreshsaid::String = ""   # what a refresh started from *this* window
                               # reported, so that the reload it causes can say
                               # so rather than blame somebody else
    factsat::Float64 = 0.0 # mtime of `facts.json` as the item list was built
                           # from it, so a refresh landing is told from a note
end
"""The four listed axes, from the items that are in hand.

Alphabetical, like every other axis. Ordering by weight put the busiest first,
which sounds useful and is not: nobody holds a mental model of which value would
select most, so the head of the list was in an order that could not be predicted
or looked up. A name can be found by knowing its name.

Wholesale, where `note_axes!` is the same thing for one item arriving. Both
exist because both happen: an import adds one row, and a refresh landing under
an open browser replaces every one of them.
"""
function rebuild_axes!(st::BState)
    ls, as = Set{String}(), Set{String}()
    for it in st.all
        for l in it.labels
            push!(ls, l)
        end
        # Your own login is left out: `@me` is that row, and it is the better
        # one - it also carries the adopted branches, which have no author at
        # all and are yours by definition.
        (isempty(it.author) || it.author == login()) || push!(as, it.author)
    end
    st.buckets = sort(unique(it.bucket for it in st.all))
    st.repos = sort(unique(it.repo for it in st.all))
    st.labels = sort(collect(ls))
    # The two predicates lead, because they are the two anybody wants and
    # neither is a name you would think to type. The logins after them are
    # alphabetical like everything else.
    st.authors = vcat([AUTHOR_ME, AUTHOR_OTHERS], sort(collect(as)))
    st
end

function BState(all::Vector{Item}, title, unread = Set{String}())
    st = BState(; all = collect(all), title = String(title), unread = unread,
                  touched = load_touched(), archived = field_map("archive"),
                  drafts = load_drafts(),
                  factsat = mtime(datapath("facts.json")))
    rebuild_axes!(st)
    refilter!(st)
    st
end
