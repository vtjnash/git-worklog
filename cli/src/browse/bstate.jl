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

Keyword-constructed, with defaults: it has thirty fields, and the positional
form is a place where two of them get transposed silently. `render` mutates the
scroll offsets and the two geometry readings (`hdr`, `nmeta`) that the mouse
needs, so it is pure in what it returns but not in what it touches.
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
    authors::Vector{String} = String[]   # busiest first, the two predicates
                                         # ahead of every login
    sort::Symbol = :none            # how the list is ordered; see `SORTS`
    touched::Dict{String,String} = Dict{String,String}()   # the interaction
                                    # clock, read when something changes rather
                                    # than per frame
    archived::Dict{String,String} = Dict{String,String}()  # url -> the date it
                                    # was put away, from `state.toml`
    lmode::Symbol = :items          # :items | :filters
    frow::Int = 3        # the first state row; 1 is the reset row and 2 its head
    wake::Any = nothing             # set by the controller; called when a fetch lands
    hdr::Int = 0           # rows of item title above the nodes in the detail
                           # pane; the mouse needs it to turn a screen row into
                           # an `nrow`, and only `render` knows how tall it got
    nmeta::Int = 0         # metadata lines the pane last drew; it sizes to its
                           # content, so the heights depend on it
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
end
function BState(all::Vector{Item}, title, unread = Set{String}())
    # Labels by how often they appear rather than alphabetically: there are
    # hundreds across this many repos, and the ones reached for constantly
    # should not be somewhere down past "upstream".
    lc = Dict{String,Int}()
    for it in all, l in it.labels
        lc[l] = get(lc, l, 0) + 1
    end
    ac = Dict{String,Int}()
    for it in all
        # Your own login is left out: `@me` is that row, and it is the better
        # one - it also carries the adopted branches, which have no author at
        # all and are yours by definition.
        (isempty(it.author) || it.author == login()) && continue
        ac[it.author] = get(ac, it.author, 0) + 1
    end
    st = BState(; all = collect(all), title = String(title), unread = unread,
                  touched = load_touched(), archived = field_map("archive"),
                  buckets = sort(unique(it.bucket for it in all)),
                  # Alphabetical, like every other axis. Ordering by weight put
                  # the busiest first, which sounds useful and is not: nobody
                  # holds a mental model of which value would select most, so
                  # the head of the list was in an order that could not be
                  # predicted or looked up. A name can be found by knowing its
                  # name.
                  repos = sort(unique(it.repo for it in all)),
                  labels = sort(collect(keys(lc))),
                  # The two predicates lead, because they are the two anybody
                  # wants and neither is a name you would think to type. The
                  # logins after them are alphabetical like everything else.
                  authors = vcat([AUTHOR_ME, AUTHOR_OTHERS],
                                 sort(collect(keys(ac)))))
    refilter!(st)
    st
end
