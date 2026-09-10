# Everything that came from GitHub, in one file.
#
#     fetched.json   {items, bulk, inbox}
#
# The split this half of `data/` is on one side of: **re-fetchable, big, and
# not tracked**. Every byte of it can be got again by running `wl refresh`, so
# none of it is worth a history and all of it is worth keeping out of one - it
# is several megabytes that churn on every run, and a diff of them buries the
# diff of what you actually did. The other side is `local.toml`, which is the
# opposite in every respect: small, yours, and the only thing that cannot be
# recovered from anywhere.
#
# It was three files - `facts.json`, `bulk.json` and `inbox.json` - split by
# which part of the fetch wrote them rather than by what they are. The parts:
#
#   * `items`  what the lanes returned, bucketed and stamped: the dashboard
#   * `bulk`   the slow queries, on their own 6-hour cadence
#   * `inbox`  the activity poll: a cursor per source, when each was last
#              asked, and the rows it has seen
#
# **Every writer re-reads before it writes.** A refresh holds the whole thing
# and writes it as it goes; the browser's poll touches `inbox` alone and must
# not carry a stale `items` back over one that landed while it was on the
# network - which is a real race, since the poll is several HTTP requests long
# and `R` runs a refresh in a subprocess while the browser is open. So the poll
# reads the file again at write time and replaces its own part. That is the
# same read-modify-write `set_mark!` does, for the same reason, with the same
# limit: it is safe because a person types in one window at a time.
#
# Written compact rather than at `indent = 1`, which is the one thing that
# changed with the merge: nothing here is committed any more, so there is no
# diff to keep readable and the file is a third smaller for it.

"Overridable so a test can write somewhere other than the real file."
const FETCHED = Ref("")
fetchedfile() = isempty(FETCHED[]) ? datapath("fetched.json") : FETCHED[]

"""The whole file: top-level parts by name, their contents left as JSON3.

Mutable at the top level and read-only underneath, which is exactly the shape
every caller wants - each replaces one whole part and reads the others.
"""
function load_fetched()
    isfile(fetchedfile()) || return OrderedDict{String,Any}()
    try
        OrderedDict{String,Any}(String(k) => v
                                for (k, v) in JSON3.read(read(fetchedfile(), String)))
    catch
        # A damaged file is an empty one. Everything in here is re-fetchable by
        # definition, so the recovery is `wl refresh` rather than an error at
        # every call site.
        OrderedDict{String,Any}()
    end
end

"""Write it back, in the order it is already in.

Not sorted, which the files it replaces were: `bulk` holds one entry per query
*in the order `config.toml` names them*, and that order decides which lane
claims an item that two of them return - a mention becomes a `needs-reply` and
a comment never does. Sorting the keys quietly handed `commented_issue` 165 rows
that belong to `mentioned_issue`. Nothing here is committed, so the sort was
buying nothing in exchange.
"""
save_fetched(d::AbstractDict) = write_atomic(fetchedfile(), json_dumps(d))

"One part of it, or `nothing` when nothing has been fetched yet."
fetched(key::AbstractString) = get(load_fetched(), String(key), nothing)

"""Replace one part, keeping whatever else is in the file.

For a caller that holds no copy of the rest - the poll, and the browser. A
refresh has the whole dict already and calls `save_fetched` instead.
"""
function put_fetched!(key::AbstractString, value)
    d = load_fetched()
    d[String(key)] = value
    save_fetched(d)
    nothing
end
