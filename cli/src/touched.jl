# The interaction clock: when you last did something to an item.
#
# `url -> ISO8601`, machine-owned and gitignored, the same shape `read.json`
# uses for a per-item timestamp the refresh does not own.
#
# The whole design is in what does *not* write here. Opening an item, scrolling
# it, searching, folding a comment and changing filters are all *looking*, and
# looking must not reorder the list you are looking at - a clock that moved as
# your eye did would put whatever you just glanced at on top, every time, and
# the list would be a record of browsing rather than of work.
#
# Read/unread is not an interaction either, deliberately. Marking a thread read
# is the end of looking at it, not the start of doing anything to it, and it
# already has its own filter - so nothing is lost by leaving it out and the
# "have you seen it" bit stays exactly one bit.
#
# What writes: a comment (`C`), a review (`A`), a label (`L`), a note (`v`), a
# snooze (`s`), any field set through `wl`, and opening a shell or an agent on
# it (`t`, `T`). That last one is the reason this is not a viewing clock in
# disguise: starting work on something is the strongest signal there is, and it
# involves no reading here at all.

"Overridable so a test can write somewhere other than the real file."
const TOUCHED = Ref(joinpath(ROOT, "touched.json"))

load_touched() = isfile(TOUCHED[]) ?
    Dict{String,String}(String(k) => String(v)
                        for (k, v) in JSON3.read(read(TOUCHED[], String))) :
    Dict{String,String}()

"When this item was last acted on, or `nothing` if it never has been."
touched_at(url::AbstractString) = get(load_touched(), String(url), nothing)

"""Set, or with `nothing` clear, one item's last-interaction time.

The primitive behind both the stamp and its undo - and as with `set_read`, the
undo of an interaction is not "stamp it again", it is putting back whatever was
there before, which for a first interaction is nothing at all.
"""
function set_touched(url::AbstractString, at::Union{Nothing,AbstractString})
    t = load_touched()
    u = String(url)
    at === nothing ? (haskey(t, u) && delete!(t, u)) : (t[u] = String(at))
    write(TOUCHED[], json_dumps(t; indent = 1, sortkeys = true))
    nothing
end

"""Record that this item was just acted on, and return what the clock said
before - which is what an undo has to put back."""
function touch!(url::AbstractString)
    prev = touched_at(url)
    set_touched(url, livestamp())
    prev
end
