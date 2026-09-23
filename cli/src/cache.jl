# On-disk cache for the slow reads.
#
# The lanes cache in `fetched.json` from one refresh to the next, but every
# thread and diff was fetched fresh each time an item was selected -
# several REST calls or a `gh pr diff` per keystroke, which is what makes the
# browser feel slow when moving back and forth over the same few items. The
# diff has since moved to the pinned checkout where there is one - git is
# its cache - and gh's copy by number is the answer where there is not.
#
# Entries are keyed by the request, not the item, so switching modes or lanes
# still hits whatever was already fetched. Writes are atomic: a torn JSON file
# here would look like a corrupt response rather than a missing one.

const CACHE_DIR = Ref("")

"""How long a cached answer is current, and how long it is worth showing at all.

Two numbers, because they answer different questions. Past `CACHE_FRESH` the
entry is out of date and wants re-reading - but it is still what was on the page
two minutes ago, so it goes up at once and the fetch runs behind it: a browser
that opens should not be a browser that waits. Past `CACHE_KEEP` it is not worth
showing at all and the fetch blocks, because a month-old thread on screen is
worse than a pause in front of one.

One pair for everything the metadata pane and the detail pane read - the
thread, the diff, the reviewers, the checks - because they are all facts about
an item that change at the speed people type, and a reader moving back over the
same few items should see them at once and see them current soon after.

`mergeable` is the exception, and has a window of its own. A conflict is worth
showing for as long as anything else: it stays until somebody rebases, and being
a few minutes late to notice it is gone costs nothing. A *clean* answer is the
one that goes wrong silently - master moved, a check finished - so past
`MERGE_FRESH` it is not shown at all, and the pane says "loading…" while the
question is asked again. Longer than `CACHE_FRESH` because asking is what makes
GitHub compute it, and that is the slowest request in the program.

The whole policy, one row per thing the browser reads about the item under the
cursor. *fresh* is how old an entry may be and still be current; *keep* is how
old it may be and still go up at once, with the re-read behind it; past keep the
fetch blocks. *held* is the dwell before a fetch starts for an item with nothing
to show - `LOAD_AFTER`, a quarter of a second - and the re-read behind a stale
entry waits `REFRESH_AFTER`, a second, of the item being on screen. Both are in
`browse/content.jl`; the loaders in `browse/fetch.jl` and `browse/meta.jl` are
what apply them.

| read                    | where           | fresh         | keep         | past fresh       | held  |
|-------------------------|-----------------|---------------|--------------|------------------|-------|
| thread (`thread:`)      | `comment_nodes` | `CACHE_FRESH` | `CACHE_KEEP` | shown, re-read   | yes   |
| diff, checkout          | `diff_nodes`    | -             | -            | local git; not cached | once per head |
| diff, gh (`diff:`)      | `diff_nodes`    | `CACHE_FRESH` | `CACHE_KEEP` | shown, re-read   | yes   |
| checks (`checks:`)      | `check_nodes`, `load_meta!` | `CACHE_FRESH` | `CACHE_KEEP` | shown, re-read | yes |
| reviewers (`itemmeta:`) | `load_meta!`    | `CACHE_FRESH` | `CACHE_KEEP` | shown, re-read   | yes   |
| merge, clean (`merge:`) | `load_meta!`    | `MERGE_FRESH` | -            | dropped, re-asked | yes  |
| merge, CONFLICTING      | `load_meta!`    | `CACHE_FRESH` | `CACHE_KEEP` | shown, re-read   | yes   |
| pushed (`p`)            | `pushed_nodes`  | -             | -            | local git; not cached | no |
| Buildkite jobs, logs    | `bk_jobs`, `bk_log` | 300s, 900s | = fresh     | dropped, blocks  | with the checks |
| review draft (`review:`) | `review_state` | 60s           | = fresh      | dropped, blocks  | on a write, not a move |
| forks, head sha         | `owner_forks`, `head_sha` | 1 day | = fresh    | dropped, blocks  | no    |

`wl prefetch` writes the `thread:` and `diff:` rows ahead of the pane, for
every unread item that has no entry inside keep; see `prefetch.jl`.

The last three rows are the plain fresh-or-miss cache `cache_get` is with one
number: read on a keypress that writes, or inside the checks pane's own fetch,
and not what the pane waits on when the cursor moves. `R` reads past every
window in the table. `CACHE_SWEEP` is longer than every keep, so the sweep only
ever collects what nothing would have shown.

Before 2026-09-13 the top of the table was three policies: the thread and the
diff at ten minutes fresh and seven days kept, the checks and `mergeable` at
120s fresh-or-miss, the reviewers at 300s fresh-or-miss - and nothing was held,
so holding `j` over the poll's new rows was a request per row.
"""
const CACHE_FRESH = Ref(120.0)
const CACHE_KEEP = Ref(30 * 86_400.0)
const MERGE_FRESH = Ref(600.0)

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

"""Seconds since the entry under `key` was written, or `Inf` for none.

The file's mtime rather than its contents: this is asked on the key loop, once
per load, to decide whether there is anything to show without waiting - and
whether what went up is old enough to want re-reading behind it. Reading a diff
back to learn its age would cost what the cache exists to save.
"""
function cache_age(key::AbstractString)
    f = _slot(key)
    isfile(f) ? max(0.0, time() - mtime(f)) : Inf
end

"Is there an entry under `key` worth showing, current or not?"
cache_has(key::AbstractString) = cache_age(key) <= CACHE_KEEP[]

function cache_put(key::AbstractString, value)
    d = cachedir()
    isdir(d) || mkpath(d)
    try
        write_atomic(_slot(key), JSON3.write((at = time(), key = key, value = value)))
    catch
        # A cache that cannot be written is a slow program, not a broken one -
        # which is the one thing here that is true of no other file in `data/`.
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
const CACHE_SWEEP = Ref(45 * 86_400.0)

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
