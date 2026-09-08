# Which items have a draft review on them, and when one was last written to.
#
# `url -> ISO8601`, the same shape `read.json` and `touched.json` use, and local
# for a reason GitHub decides rather than this program: a pending review is
# visible only to its author, and only on the pull request it is on. GraphQL
# answers `reviews(states: PENDING, author: $me)` for *one* pull request - which
# is what `review_state` asks, an item at a time - and there is no query, on any
# API, that answers it for all of them at once. `review:pending` is not a search
# qualifier either: it matches nothing at all, exactly as `review:banana` does.
#
# So the only way to list the drafts is to write them down as they are made. The
# five careful comments that this whole batching apparatus exists to protect are
# invisible from everywhere except the pull request they are on - and that, not
# the count, is what a lane of them is for.
#
# What writes here: a comment joining a draft, and opening an item whose
# metadata turns out to carry a pending review this program did not start - a
# draft from an earlier session, or from the web UI. What clears it: submitting
# the review, discarding it, and equally opening an item that was marked and
# whose metadata says there is no draft on it any more, which is how one
# submitted on github.com stops being listed here.

"Overridable so a test can write somewhere other than the real file."
const DRAFTS = Ref("")
draftsfile() = isempty(DRAFTS[]) ? datapath("drafts.json") : DRAFTS[]

load_drafts() = isfile(draftsfile()) ?
    Dict{String,String}(String(k) => String(v)
                        for (k, v) in JSON3.read(read(draftsfile(), String))) :
    Dict{String,String}()

"""Set, or with `nothing` clear, the mark saying this item carries a draft.

Written through in both directions rather than accumulated in memory: the lane
is membership in this file, and the browser re-reads it whenever it rebuilds the
list.
"""
function set_draft(url::AbstractString, at::Union{Nothing,AbstractString})
    d = load_drafts()
    u = String(url)
    was = get(d, u, nothing)
    at === nothing ? (haskey(d, u) && delete!(d, u)) : (d[u] = String(at))
    was == at || write_atomic(draftsfile(), json_dumps(d; indent = 1, sortkeys = true))
    nothing
end

"Record that this item carries a draft review, as of now."
draft!(url::AbstractString, at::DateTime = utcnow()) = set_draft(url, stamp(at))

"Forget the draft on this item - it has been sent, or thrown away."
undraft!(url::AbstractString) = set_draft(url, nothing)
