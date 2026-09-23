# Warming the cache for what you are about to read.
#
# The browser reads a thread and a diff the first time an item is looked at,
# and holds the cursor a quarter of a second before it asks (`LOAD_AFTER`), so
# going down the unread list is a pause and a "loading …" per row. Everything
# on that list is known when a refresh ends: it is `unread_items`, the same
# list `wl unread` prints. This asks for each row's thread and diff then,
# behind the refresh, so the pane has them the moment the cursor lands.
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

Put a thread and, for a pull request, a diff in the cache for each of `items`
that has none. In the order given - `unread_items` is newest movement first,
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
        islocal(it) && return
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
                got = diff(it)
                got === :fetched ? (diffs += 1) : (cached += 1)
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

"""The diff `diff_nodes` would show, made ready: `:local` when a pinned
checkout answers it - `pr_diff` fetches the objects it lacks, once, which is
the slow part - `:cached` when gh's copy is already in the cache, and
`:fetched` when it was not and now is."""
function prefetch_diff(it::Item; run = gh_run)
    repo = repo_path(it.repo)
    head = repo === nothing ? it.head : head_sha(it)
    if repo !== nothing && !isempty(head) &&
       pr_diff(repo, it.repo, it.number, it.base, it.base_sha, head) !== nothing
        return :local
    end
    cache_has(diff_key(it)) && return :cached
    cache_put(diff_key(it), fetch_diff(it; run = run))
    :fetched
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
        @printf(report(), "prefetched %d unread: %d threads, %d diffs fetched, %d already there%s (%.0fs)\n",
                length(its), r.threads, r.diffs, r.cached,
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
