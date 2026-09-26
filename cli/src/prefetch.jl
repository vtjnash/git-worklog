# Warming the cache for what you are about to read.
#
# The browser reads a thread and a diff the first time an item is looked at,
# and holds the cursor a quarter of a second before it asks (`LOAD_AFTER`), so
# going down the unread list is a pause and a "loading …" per row. Everything
# on that list is known when a refresh ends: it is `unread_items`, the same
# list `wl unread` prints. This asks for each row's thread then, behind the
# refresh, so the pane has it the moment the cursor lands - and the diff where
# a pinned checkout can keep it; gh's copy is not fetched ahead.
#
# **Presence, not freshness.** An entry already in the cache is left alone
# however old it is, as long as it is inside `CACHE_KEEP`: the pane shows it at
# once and re-reads it behind itself (`arm_refresh!`), which is the part a
# prefetch cannot do better. The job is to turn "nothing to show" into
# "something to show", for the rows that have nothing.
#
# **In a process of its own**, started detached when a refresh ends
# (`prefetch_behind`), whether that refresh was `wl refresh`, `wl --refresh`
# or `u` in the browser - so a browser does not spend its key loop on a few
# hundred requests, and a refresh from a timer does not wait for them. One run
# at a time, behind a pid lock in `cache/`: a second one arriving while the first
# is still going has nothing to add. `wl prefetch` is the same run, in front
# of you.

"Where the prefetch writes what it did, and the lock that keeps it to one."
prefetchlog() = joinpath(cachedir(), "prefetch.log")
prefetchlock() = joinpath(cachedir(), "prefetch.pid")

"""Off in the suite, which runs refreshes and must not leave a process
behind each one."""
const PREFETCH_BEHIND = Ref(true)

"""
    prefetch_items(items; thread, diff, ntasks) -> (; threads, diffs, cached, failed)

Put a thread in the cache for each of `items` that has none, and for a pull
request in a pinned checkout bring its diff's objects in (`prefetch_diff`). In the order given - `unread_items` is newest movement first,
so what you will read first is warm first - and `ntasks` at a time: a thread
is several REST reads one after another, three to eight seconds of waiting,
and five hundred of them one by one was half an hour on the first run. Four,
and not forty, since a burst is what the secondary rate limit trips on and
nobody is waiting on this. A line every 25 items, so the log says it is
moving.

`thread` and `diff` are what fetches each, so the suite can count the calls
without GitHub.
"""
function prefetch_items(items; thread = fetch_thread!, diff = prefetch_diff, ntasks::Int = 4)
    threads = diffs = cached = failed = done = 0
    warm(it) = begin
        ghitem(it) || return
        try
            if cache_has(thread_key(it.url))
                cached += 1
            else
                thread(it.url)
                threads += 1
            end
        catch e
            failed += 1
            @printf(warning(), "  %-24s thread: %s\n", it.ref, first(sprint(showerror, e), 200))
        end
        if it.is_pr
            try
                diff(it) === :fetched && (diffs += 1)
            catch e
                failed += 1
                @printf(warning(), "  %-24s diff: %s\n", it.ref, first(sprint(showerror, e), 200))
            end
        end
        done += 1
        if done % 25 == 0
            @printf(report(), "  %d of %d\n", done, length(items))
            flush(report())
        end
    end
    # The tasks share one report: `asyncmap`'s are this task's children, and
    # `task_local_storage` is not inherited, so it is handed on by hand.
    r = current_report()
    asyncmap(it -> task_local_storage(() -> warm(it), :report, r), items; ntasks = ntasks)
    (; threads, diffs, cached, failed)
end

"""The diff made ready where there is somewhere to keep it: a pinned checkout,
where `pr_diff` fetches the objects it lacks, once - the slow part - and git is
the cache from then on. `:fetched` then, and `:none` for a repository with no
checkout: gh's copy is not fetched ahead. It is one request whenever it is
looked at either way, and pinning a checkout is how you say you want this
repository's diffs kept."""
function prefetch_diff(it::Item)
    repo = repo_path(it.repo)
    repo === nothing && return :none
    head = head_sha(it)
    isempty(head) && return :none
    pr_diff(repo, it.repo, it.number, it.base, it.base_sha, head) === nothing ? :none : :fetched
end

"""`wl prefetch`: the unread list, warmed. Returns the exit code; `0` also when
another prefetch holds the lock, since what was asked is being done."""
function prefetch(at::DateTime = utcnow(); items = nothing)
    d = cachedir()
    isdir(d) || mkpath(d)
    ran = FileWatching.Pidfile.trymkpidlock(prefetchlock()) do
        its = something(items, unread_items(at))
        t0 = time()
        r = prefetch_items(its)
        @printf(report(), "prefetched %d unread: %d threads fetched, %d already there, %d diffs in checkouts%s (%.0fs)\n",
                length(its), r.threads, r.cached, r.diffs,
                r.failed == 0 ? "" : ", $(r.failed) failed", time() - t0)
        true
    end
    ran === false && println(report(), "a prefetch is already running")
    0
end

"""Start `wl prefetch` detached, writing to `cache/prefetch.log`, and return at
once. After a refresh has written `fetched.json`, which is what the unread list
is read off. A failure to start it is logged and nothing more: the cache it
would have filled is filled anyway, one look at a time."""
function prefetch_behind()
    PREFETCH_BEHIND[] || return nothing
    try
        d = cachedir()
        isdir(d) || mkpath(d)
        wl = joinpath(ROOT, "cli", "bin", "wl")
        # One handle for both, or the two streams write over each other.
        open(prefetchlog(), "w") do io
            run(pipeline(detach(`$wl prefetch`); stdin = devnull, stdout = io, stderr = io);
                wait = false)
        end
    catch e
        logerror!(e, catch_backtrace(), "prefetch")
    end
    nothing
end
