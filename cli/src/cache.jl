# On-disk cache for the slow reads.
#
# The bulk search lanes already cache in bulk.json on a six-hour cadence, but
# every thread and diff was fetched fresh each time an item was selected -
# several REST calls or a `gh pr diff` per keystroke, which is what makes the
# browser feel slow when moving back and forth over the same few items.
#
# Entries are keyed by the request, not the item, so switching modes or lanes
# still hits whatever was already fetched. Writes are atomic: a torn JSON file
# here would look like a corrupt response rather than a missing one.

const CACHE_DIR = Ref("")

cachedir() = (isempty(CACHE_DIR[]) && (CACHE_DIR[] = datapath("cache")); CACHE_DIR[])

_slot(key) = joinpath(cachedir(), bytes2hex(sha256(key))[1:32] * ".json")

"""
    cache_get(key, ttl_s; keep_s = ttl_s) -> (value, age_s) or nothing

`nothing` when absent, unreadable, or older than `keep_s`. A damaged entry is a
miss rather than an error: the cost of re-fetching is a delay, the cost of
trusting it is wrong data on screen.

Two thresholds and not one, for the caller that would rather show something old
than nothing at all. `ttl_s` is how long the entry is *current*; `keep_s` is how
long it is worth showing while a fresh copy is fetched behind it. The age comes
back either way, so deciding between them is the caller's - this only refuses
what is past both. Left alone they are the same number, which is the plain
fresh-or-miss cache every other caller wants.
"""
function cache_get(key::AbstractString, ttl_s::Real; keep_s::Real = ttl_s)
    f = _slot(key)
    isfile(f) || return nothing
    try
        d = JSON3.read(read(f, String))
        age = time() - d.at
        age > max(ttl_s, keep_s) && return nothing
        (d.value, age)
    catch
        nothing
    end
end

function cache_put(key::AbstractString, value)
    d = cachedir()
    isdir(d) || mkpath(d)
    f = _slot(key)
    tmp = f * ".tmp" * string(getpid())
    try
        write(tmp, JSON3.write((at = time(), key = key, value = value)))
        mv(tmp, f; force = true)          # atomic within the directory
    catch
        isfile(tmp) && rm(tmp; force = true)
    end
    value
end

"""Drop one entry, so the next read goes to the network.

For after a write: the thread you just commented on is exactly the thing whose
cached copy is now wrong, and a TTL that made it fast to re-read makes it slow
to notice.
"""
cache_drop(key::AbstractString) = (f = _slot(key); isfile(f) && rm(f; force = true); nothing)

"""How long an entry is kept before the sweep drops it outright.

Longer than anything shows a cached copy, so the sweep only ever collects
entries nothing would have used. Without it `cache/` grows for as long as the
program is used: every thread ever opened, kept for a repo that was archived
months ago.
"""
const CACHE_SWEEP = Ref(21 * 86_400.0)

"Drop everything, or only entries older than `older_than` seconds."
function cache_clear(; older_than::Real = 0)
    d = cachedir()
    isdir(d) || return 0
    n = 0
    for f in readdir(d; join = true)
        endswith(f, ".json") || continue
        if older_than <= 0 || (time() - mtime(f)) > older_than
            rm(f; force = true); n += 1
        end
    end
    n
end
