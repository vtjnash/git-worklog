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

cachedir() = (isempty(CACHE_DIR[]) && (CACHE_DIR[] = joinpath(ROOT, "cache")); CACHE_DIR[])

_slot(key) = joinpath(cachedir(), bytes2hex(sha256(key))[1:32] * ".json")

"""
    cache_get(key, ttl_s) -> (value, age_s) or nothing

`nothing` when absent, unreadable, or older than `ttl_s`. A damaged entry is a
miss rather than an error: the cost of re-fetching is a delay, the cost of
trusting it is wrong data on screen.
"""
function cache_get(key::AbstractString, ttl_s::Real)
    f = _slot(key)
    isfile(f) || return nothing
    try
        d = JSON3.read(read(f, String))
        age = time() - d.at
        age > ttl_s && return nothing
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
