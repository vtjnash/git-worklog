# Reading in the background, and who is holding the result. Everything that
# runs off the key loop goes through `fetching`, which is what makes a second
# ask join the first and lets anything wait for what is still in the air.

"""Every fetch this process has in the air, by what it is fetching.

A map under a lock rather than a field on the view, for three reasons that are
all the same reason - a view can only hold one.

**Duplicates.** `st.pending` is overwritten by the next load, so holding `j`
down the list starts a `gh api graphql` per row and abandons all but the last:
a process each, a rate limit spent on answers nobody will read, and the winner
decided by whichever finishes last. Keyed by what is being fetched, a second ask
for something already in the air *joins* it instead.

**Results nobody watches.** An abandoned task's value is never fetched, so
anything that escaped its own error handling escaped silently. They are logged
here, which is the only place that still sees them.

**Nothing that can wait.** There was no way to ask "is anything still running",
which is what stopped package precompilation dead when the workload moved the
selection: two `gh` processes and two pipes, with nothing holding a handle.

Timers are deliberately *not* in here. `wake_after!` starts a task that sleeps
and then wakes the frame, and a drain that waited on one would hang for as long
as the debounce.
"""
const INFLIGHT = Dict{String,Task}()
const INFLIGHT_LOCK = ReentrantLock()

"""Run `f` in the background as `key`, or join the run already under way.

The task takes itself out of the map when it finishes, so what is in there is
what is *in flight* rather than a history of everything ever asked for.
"""
function fetching(f, key::AbstractString)
    k = String(key)
    lock(INFLIGHT_LOCK) do
        t = get(INFLIGHT, k, nothing)
        (t !== nothing && !istaskdone(t)) && return t
        t = @async begin
            try
                f()
            catch e
                # Nobody may ever `fetch` this one - the cursor moves on - so
                # this is the last place its failure can be noticed at all.
                logerror!(e, catch_backtrace(), string("fetch ", k))
                rethrow()
            finally
                lock(INFLIGHT_LOCK) do
                    get(INFLIGHT, k, nothing) === current_task() && delete!(INFLIGHT, k)
                end
            end
        end
        INFLIGHT[k] = t
        t
    end
end

"""Wait for every fetch in the air, ignoring what they answered.

For shutting something down cleanly rather than for using a result: the
precompile workload calls it so that no `gh` or `tmux` outlives the package
image being built. Loops rather than snapshotting, because a fetch can start
another.
"""
function drain_fetches!()
    while true
        t = lock(INFLIGHT_LOCK) do
            isempty(INFLIGHT) ? nothing : first(values(INFLIGHT))
        end
        t === nothing && return
        try; wait(t); catch; end
    end
end

"""Remember where the reader is in what is on screen.

Nothing is remembered while a fetch is in flight: the nodes are empty then, and
whatever drew that empty pane clamped `nrow` to 1 - which is not a place
anybody was. That guard is also what makes `place!` safe to call twice.
"""
function mark_place!(st::BState)
    (isempty(st.nkey) || isempty(st.nodes)) && return st
    st.place[st.nkey] = (st.nrow, st.ntop)
    st
end

"""Hand the cursor to another key, putting it back where that key was left.

Coming back to a thread or a diff at the top of it means scrolling for the line
you were reading, every time - and the way back into a two hundred row review is
not one anybody wants to find twice. The key carries the mode as well as the
url, so the thread and the diff of one item are remembered apart.

The restore here is provisional: between a fetch starting and its nodes landing
the pane is empty and the frame clamps `nrow` to the top of it, so
`collect_pending!` does it again for real. What this does that nothing else can
is the marking, which has to happen while the rows going away are still here to
have a position in.
"""
function place!(st::BState, key::AbstractString)
    mark_place!(st)
    key == st.nkey && return st
    st.nkey = String(key)
    st.nrow, st.ntop = get(st.place, key, (1, 1))
    st
end

"""Note which item the cursor is on, and since when.

Called by both loaders, so whichever runs first starts the clock and both
measure the same dwell. The url and not the loaded key: switching the pane's
mode on an item you have been reading is a deliberate ask, not a pass, and
should not wait a quarter of a second for the diff.
"""
function note_sel!(st::BState, at::Float64 = time())
    u = curl(st)
    u == st.selurl && return st
    st.selurl = u
    st.selat = at
    st
end

"""Wake the frame in `secs` seconds.

A task that sleeps and then wakes, because the event loop blocks on its channel
and has no tick of its own. It decides nothing: by the time it fires the
selection may have moved, and what the wake does is whatever `settle!` and
`due_refresh!` find on screen then rather than what was there when it was
armed. Not in `INFLIGHT`: a drain that waited on one would hang for as long as
the delay.
"""
function wake_after!(st::BState, secs::Real)
    w = st.wake
    w === nothing && return false
    @async begin
        sleep(max(0.0, secs))
        w()
    end
    true
end

"""Hold a fetch until the item has been on screen for `LOAD_AFTER`.

`cached` says whether there is anything to show without asking; a cached copy
is never held. Returns true when the load should not start yet, having armed
the wake after which `settle!` retries it - once per selection, not once per
key: the second loader to ask in the same dwell finds the timer already
running.
"""
function held!(st::BState, cached::Bool, at::Float64 = time())
    cached && return false
    left = LOAD_AFTER[] - (at - st.selat)
    left <= 0 && return false
    if st.heldat != st.selat
        st.heldat = st.selat
        wake_after!(st, left)
    end
    true
end

function load_nodes!(st::BState)
    # The import row has nothing to fetch and says so itself. Keyed like any
    # other load, so moving away and back does not rebuild it.
    note_sel!(st)
    if st.sel == 0 || isempty(st.items)
        st.loaded == "new:" && return
        place!(st, "new:")      # before the nodes go: it reads them
        st.nodes = newnodes()
        st.loaded = "new:"
        st.pending = nothing; st.pendkey = ""; st.quiet = false
        clearsel!(st)
        # There is no fetch here to announce, and no stamp on the border.
        return
    end
    it = st.items[st.sel]
    mode = st.mode
    key = string(it.url, ":", mode)
    if st.loaded == key || (st.pendkey == key && st.pending !== nothing)
        # Nothing to fetch. What is on screen is this key's already - or is the
        # empty pane its read left - so the cursor belongs to it and is claimed
        # rather than moved. Moving it here would throw away the place of
        # anyone who arrived by any road but a fetch. A key claimed but held
        # falls through, to ask `held!` again whether the dwell is over.
        st.nkey = key
        return
    end
    # The pane empties and says "loading …" whether the fetch starts now or
    # after the dwell: what is held is the request, not the frame. The old
    # nodes belong to the item the cursor has left and are not left standing
    # under a title that is somebody else's. Said on the pane's own border
    # (`pane_stamp`) and not in the status, which is the keys' - a load
    # started by the key that also had something to say wrote over it.
    if st.pendkey != key
        place!(st, key)        # while the nodes going away are still here to read
        st.nodes = Node[]
        clearsel!(st)          # it indexed rows that are about to be replaced
        st.pending = nothing
        st.pendkey = key
        st.quiet = false
        st.loadedat = 0.0
        st.reloadfailed = false
    end
    held!(st, mode_cached(mode, it)) && return
    # Taken here rather than inside the task: a moment before the fetch begins
    # is early by however long scheduling takes, and early is the safe end -
    # `fetched` decides what `e` can mark seen, and too early leaves a comment
    # unread rather than hiding one.
    at = utcnow()
    st.pending = fetching(key) do
        try
            mode_nodes(mode, it, at)
        finally
            st.wake === nothing || st.wake()   # redraw as soon as this lands
        end
    end
end

"Is a load of `key` waiting on the dwell - claimed, and not yet started?"
holding(st::BState, key::AbstractString) = st.pendkey == key && st.pending === nothing

"""Where a thread opens when the reader has never been in it this session.

The top of it, unless it carries the rule saying where the new part starts - in
which case that, with the new part below the fold of the screen rather than
above it. Coming back to a forty-comment thread you have read thirty-nine of and
landing on comment one is the thing this is for; `st.place` already answers it
for a thread visited in *this* session, and the rule is what answers it across
sessions, because it is drawn from a mark on disk.

The width is the one the pane was last drawn at, which is known because a fetch
only ever lands after the frame whose border said "loading …" has been on screen.
"""
function openrow(st::BState)
    i = findfirst(n -> get(n.meta, "newmark", false) === true, st.nodes)
    i === nothing && return (1, 1)
    r = headerrow(st, i, max(20, st.diw))
    # One row of what came before it, so the rule reads as a division rather
    # than as the top of the pane.
    (r, max(1, r - 1))
end

"""Start a background re-read of what is already on screen.

What makes it a refresh is everything it does not do: the nodes stay, the cursor
stays, the fold state stays, the status stays. One that the reader has to notice
is not a refresh - it is being thrown back to the top of a thread they were in
the middle of.

Only ever for the item that is loaded and only when nothing else is in flight,
so this can never be what a keystroke is waiting on.
"""
function refresh_nodes!(st::BState)
    (isempty(st.items) || st.sel == 0) && return false
    it = st.items[clamp(st.sel, 1, length(st.items))]
    key = string(it.url, ":", st.mode)
    (st.loaded == key && isempty(st.pendkey)) || return false
    mode = st.mode
    at = utcnow()
    st.quiet = true
    st.pendkey = key
    # Its own key: a re-read that joined the cached read already in the air
    # would come back with exactly the answer it was asked to go past.
    st.pending = fetching(string(key, " fresh")) do
        try
            mode_nodes(mode, it, at; fresh = true)
        finally
            st.wake === nothing || st.wake()
        end
    end
    true
end

"""Re-read everything about the item on screen, cache and all.

The one key that says "what is on the page is out of date". Everything else
here decides for itself when to re-read - two minutes for the thread, the
checks and the reviewers, ten for a clean `mergeable` - and each of those is a
guess about how fast that thing changes. `R` is for when the guess is wrong:
you pushed a moment ago, or commented from the web, and what is wanted is the
answer GitHub has now.

Only this item. The dashboard is `wl refresh`, which takes minutes and re-reads
two thousand items to answer a question about one.

The metadata is asked for by clearing the key that decides whether it needs
asking for, and started here rather than left to the caller so that the
`load_meta!` in `settle!` finds it already in flight.

Says nothing when it starts, which it used to ("re-reading …"): the borders
say it, `reloading …` under the thread and `loading …` in the metadata, and
go when the answer lands - a status stayed until the next key, long after.
"""
function refresh_item!(st::BState)
    (isempty(st.items) || st.sel == 0) && return "nothing selected to re-read"
    it = st.items[clamp(st.sel, 1, length(st.items))]
    st.metakey = ""; st.metapending = nothing; st.mergepending = nothing
    load_meta!(st; fresh = true)
    # Refuses while something is already in flight, which is the same answer:
    # a read of this item is on its way, and a second one behind it would
    # answer with what the first is already going to say.
    refresh_nodes!(st)
    ""
end

"""Arm the debounce for what went up stale - the nodes, the metadata, or both.

It decides nothing: by the time the wake fires the selection may have moved,
and what gets re-read is whatever is on screen then rather than what was on
screen when this was armed. One due time for both panes, because they are
stale for the same reason - the item has been sitting in the cache - and the
second armed resets it for the first, which costs the first a moment and
saves a timer.
"""
function arm_refresh!(st::BState, at::Float64 = time())
    nodes = !isempty(st.nodes) && get(st.nodes[1].meta, "stale", false) === true
    (nodes || st.metastale) || return false
    nodes && (st.refreshkey = st.loaded)
    st.refreshat = at + REFRESH_AFTER[]
    wake_after!(st, REFRESH_AFTER[])
    true
end

"""Re-read what is stale on screen once its debounce has run out.

Returns false either way: nothing it does changes the frame. What lands from it
does, in its own wake.
"""
function due_refresh!(st::BState, at::Float64 = time())
    if !isempty(st.refreshkey)
        if st.refreshkey != st.loaded || !isempty(st.pendkey)
            st.refreshkey = ""              # it belongs to something else now
        elseif at >= st.refreshat
            st.refreshkey = ""
            refresh_nodes!(st)
        end
    end
    if st.metastale
        if st.metakey != curl(st)
            st.metastale = false            # the cursor has left it
        elseif at >= st.refreshat
            # Declined only while a merge answer is still in the air, and
            # that landing is a wake that re-arms this for a second on.
            st.metastale = !refresh_meta!(st)
        end
    end
    false
end

"""Start the loads for whatever the cursor is on: the thread in the mode
showing, and the metadata. What `settle!` is for the browser - run after every
event, by the controller and at the end of `handle!` - so the pane follows the
cursor however it moved: a key, a dialog's answer, another view's callback, a
list that changed under it, or the dwell's wake (`held!`) arriving with no key
at all. Both loaders are idempotent, so an event that moved nothing starts
nothing. True when the pane or the metadata was let go of for a new load.
"""
function settle!(st::BState)
    before = (st.pendkey, st.loaded, st.metakey, st.meta === nothing)
    load_nodes!(st)
    load_meta!(st)
    before != (st.pendkey, st.loaded, st.metakey, st.meta === nothing)
end

"Adopt a finished fetch. Returns true when the frame needs redrawing."
function collect_pending!(st::BState)
    st.pending === nothing && return false
    istaskdone(st.pending) || return false
    ns = try
        fetch(st.pending)
    catch e
        [failednode("load failed", first(sprint(showerror, e), 300))]
    end
    quiet = st.quiet
    st.quiet = false
    st.loaded = st.pendkey
    st.pending = nothing
    st.pendkey = ""
    failed = !isempty(ns) && get(ns[1].meta, "failed", false) === true
    if quiet && failed
        # A refresh nobody asked for must not take the thread away from someone
        # reading it. The cached copy stayed on screen and stays there; only the
        # stamp on the border says the re-read did not land.
        st.reloadfailed = true
        return true
    end
    st.nodes = ns
    # As of when it was read, which for a cached copy is when the copy was
    # made: a thread from the cache is as old as the entry, not as the frame.
    st.loadedat = failed ? 0.0 : isempty(ns) ? time() : Float64(get(ns[1].meta, "asof", time()))
    st.reloadfailed = false
    # The cursor is only moved by a load the reader asked for, and it is moved
    # to wherever they were in this thread the last time they were in it - the
    # top of it only the first time. A refresh under them keeps their place
    # untouched: rows may have shifted by a comment, and that is a better answer
    # than either of the two above.
    if !quiet
        st.nkey = st.loaded
        st.nrow, st.ntop = get(st.place, st.loaded) do
            openrow(st)
        end
    end
    clearsel!(st)          # either way, it indexed rows that are gone
    arm_refresh!(st)
    note_mention!(st, st.loaded, ns)
    true
end

"""A thread that has just landed and names you latches `mentioned` on its item,
on screen and on disk - once: an item already carrying it is left as it is,
whatever this thread says. After everything else in `collect_pending!`, since
`replace_item!` refilters and the row may leave the list under the cursor."""
function note_mention!(st::BState, key::AbstractString, ns)
    isempty(ns) && return false
    why = get(ns[1].meta, "mentioned", "")
    isempty(why) && return false
    url = String(rsplit(key, ':'; limit = 2)[1])
    i = findfirst(x -> x.url == url, st.all)
    (i === nothing || !isempty(st.all[i].mentioned)) && return false
    try
        latch_mention!(url, why)
    catch e
        logerror!(e, catch_backtrace(), "mentioned")
    end
    replace_item!(st, with(st.all[i]; mentioned = String(why)))
end

# --- the other windows ------------------------------------------------------
#
# Everything in `data/` is read into memory once and re-read only when this
# process changes something - which was fine when there was one of them. There
# is not: `wl set` runs in another terminal, a second browser is open on another
# screen, and `wl refresh` runs on a timer. Each of those writes files this one
# is holding a copy of, and until now the copy stood until the browser was
# restarted.
#
# A watch on the directory answers it. What arrives is a name, so the question
# each event has to answer is "does anything on screen come from that file" -
# and the answer for the whole of `data/` is one of three: the item list, the
# records the lanes are membership in, or neither.
#
# What the watch deliberately does not do is *write*. Two windows agreeing about
# `data/` is a matter of reading it again, and every write in this program is
# still downstream of a key press - `wake_after!` is the only timer, it is a
# one-shot debounce armed by a load somebody asked for, and what it wakes
# writes nothing but cache entries under their own names.
#
# That is what makes the read-modify-write in `set_mark!` safe without a lock.
# It reads the whole file, changes one field of one row and writes it back, so
# two of them straddling each other would lose the earlier one's field - and two of them cannot straddle each other while the only thing
# that starts one is a person typing in one window at a time. A poll loop that
# went off in every open window at once is exactly what would break that, so if
# one is ever wanted, the lock comes first and this is where to remember it.

"""Files whose contents are on screen, and what changing one costs to adopt.

Both of them, which is all `data/` holds now: `fetched.json` carries the item
list and is rebuilt from disk, and `local.toml` carries the marks and the
fields the filters read, which is a `refilter!`. Everything else in there is
the cache, which the browser does not read again after it starts and which
changes on every fetch this program makes.

`fetched.json` is also written by another window's *poll*, which is not a
refresh landing - the items in it are unchanged - so `reload_data!` compares
mtimes and rebuilds the list only when the fetch that moved it was a real one.
"""
const WATCHED = ("fetched.json", "local.toml")

"""Watch `data/` and flag the browser when somebody else writes in it.

Its own task, blocked in the kernel rather than polling: this is a directory
that changes a few times an hour and a poll would be a wakeup a second for the
life of the session. Like the controller's reader it is left to die with the
process - it holds nothing that needs releasing, and the alternative is a
shutdown handshake for a task that is asleep.

The wake is deliberately late by a quarter of a second. A refresh writes four
files in a row and a note writes one twice; waking on each would rebuild the
list once per file, and nothing on screen is any more correct for the first
three of them.
"""
function watch_data!(st::BState)
    dir = datadir()
    # Registered here and not inside the task: `watch_folder` starts the watch
    # when it is first called and queues what happens after that, so a write
    # landing between the browser opening and the task first being scheduled is
    # a write nobody would hear.
    try
        FileWatching.watch_folder(dir, 0)
    catch
        return              # no watch, and a browser that behaves as it always did
    end
    @async while true
        try
            name, ev = FileWatching.watch_folder(dir)
            (ev isa FileWatching.FileEvent && ev.timedout) && continue
            String(name) in WATCHED || continue
            # Our own write, still as we left it: re-reading what is already in
            # memory would cost a rebuild per keystroke, and a row moving out
            # from under the reader who just acted on it.
            ours(joinpath(dir, String(name))) && continue
            sleep(0.25)
            st.reload = true
            st.wake === nothing || st.wake()
        catch
            # A directory that has gone away, or a watch the kernel dropped:
            # there is nothing on screen this can be reported to, and the
            # browser works exactly as it did before this existed.
            return
        end
    end
end

"""How often the sessions are listed for a bell, in seconds.

One `list-panes` a poll, about 5 ms: nothing against a bell that is the
difference between an agent waiting and an agent working, and the reason
this is not a second.
"""
const SESSIONS_EVERY = Ref(2.0)

"""Hear an agent ring while the browser is elsewhere.

The bell is tmux's, and tmux tells nobody: a control client hears `%output`
for the pane it is on and nothing for any other, and there is no client at all
while the list is up. So the sessions are listed, every `SESSIONS_EVERY`
seconds, and a change in who rang is a wake - compared against what
`refilter!` last read, so a change it already took, `e` silencing a bell or
`T` looking, wakes nothing, and a wake that reached a view with no list in it
comes again. Not started where there is no tmux to ask.
"""
function watch_sessions!(st::BState)
    mux_bin() === nothing && return
    @async while true
        try
            sleep(SESSIONS_EVERY[])
            rang_urls() == st.rang && continue
            st.rerang = true
            st.wake === nothing || st.wake()
        catch e
            logerror!(e, catch_backtrace(), "watch_sessions!")
            return
        end
    end
end

"Take the sessions again once one rang, or went quiet, behind the frame."
function rerang!(st::BState)
    st.rerang || return false
    # Lowered after the refilter, not before: it yields reading the file and
    # the sessions, and a poll landing in between compares against the `rang`
    # it has not yet replaced and raises the flag again for a change this is
    # taking. Dropping one raised in that window loses nothing, since the poll
    # compares afresh each time and a change the refilter missed is unequal
    # again on the next.
    refilter!(st)
    st.rerang = false
    true
end

"""Run the whole refresh, from inside the browser, without blocking it.

`R` re-reads the item under the cursor; this is the other half - the fetch that
rebuilds the dashboard itself, which until now meant leaving the browser or
running `wl refresh` in another terminal and waiting for the watcher to notice.

**In this process, on a task.** It was a child - `bin/refresh` to a temp file
- because `refresh` reported on stderr and `redirect_stderr` is process-wide.
It reports through `reporting` now (DESIGN, "What is said, and where"), so
the same call the command makes runs here with `data/refresh.log` as its
report, and what is left to answer for is the CPU: the walk over the corpus
yields every 256 rows (`breathe`) and at each file it reads or writes, so the
longest stretch the key loop waits is `save_fetched`, about 100 ms - measured
2026-09-17 with the network faked; the network itself yields on every `gh`.
The summary and the warning count come straight off the report, and nothing
reads a last line back. A refresh that throws throws here, into `errors.log`
with its own stack rather than as `ProcessExited(1)`.

**And it sets `reload` by hand.** `watch_data!` deliberately ignores writes
this process made - which every write of this refresh now is - so the flag is
set here rather than left to the watcher.

`fetching` is what keeps two of these from overlapping: a second `u` joins the
one already running instead of starting a second refresh against the same files.
"""
function refresh_all!(st::BState)
    refreshing() && return "already refreshing"
    fetching("refresh") do
        said = try
            s = run_refresh!()
            # Behind it, in a process of its own; see `prefetch.jl`.
            prefetch_behind()
            s
        catch e
            # Logged, so the footer stands until it is read; the report has
            # everything the refresh said up to the throw.
            logerror!(e, catch_backtrace(), "refresh")
            string("refresh failed \u00b7 see the footer, and ", refreshlog_name())
        end
        st.refreshsaid = said
        st.reload = true
        st.wake === nothing || st.wake()
    end
    "refreshing \u2026"
end

"Is `refresh_all!`'s refresh in the air? The title bar says so while it is."
refreshing() = lock(INFLIGHT_LOCK) do
    t = get(INFLIGHT, "refresh", nothing)
    t !== nothing && !istaskdone(t)
end

"""The refresh, reporting to `data/refresh.log`, and the status row's line
for it: the summary, the warnings when there were any, and where the rest is.

`at` and `kw` reach `refresh_` - the clock, the searches and the poll - so the
suite can run one without GitHub; the browser gives it nothing, and the
refresh takes GitHub's time as it always has.
"""
function run_refresh!(at::Union{Nothing,DateTime} = nothing; kw...)
    log = refreshlog()
    (code, r) = open(log, "w") do io
        refresh_report(String[], at; io = io, kw...)
    end
    code == 0 || error("refresh answered ", code, " \u00b7 see ", refreshlog_name())
    string(isempty(r.summary) ? "refreshed" : r.summary,
           r.warnings == 0 ? "" :
               string(" \u00b7 ", r.warnings, r.warnings == 1 ? " warning" : " warnings"),
           " \u00b7 wl log")
end

"""Where the last refresh started from the browser wrote what it had to say.
Overwritten per run: it is a record of the last refresh, not a history -
`fetched.json` is the history."""
const REFRESHLOG = Ref("")
refreshlog() = isempty(REFRESHLOG[]) ? datapath("refresh.log") : REFRESHLOG[]
"The log's name as a row says it: `data/refresh.log` from the checkout, the
whole path when `WORKLOG_DATA` put it elsewhere."
refreshlog_name() = (p = refreshlog(); startswith(p, ROOT) ? relpath(p, ROOT) : p)

"""Take the records again, and the item list with them when a refresh landed.

Returns true when the frame has to be drawn again, which is the whole contract
`onwake!` has with the controller.

The item list is only rebuilt when `fetched.json` is the file that moved,
because that is the only change that can add or remove a row - and rebuilding it
is a read of the file plus a walk of the local checkouts, which is a cost worth
paying every few minutes and not every keystroke somebody else types.

Rows that came from the unread poll rather than from a lane are carried
across: they are the threads that are unread and untracked, this process asked
GitHub for them at startup, and a refresh that does not mention them is not
evidence that they are gone.

A file with no `items` in it is not a corpus of none: it is a refresh landing
in a file that was wiped - its inbox poll writes `inbox` alone, and `items`
comes with the `save_fetched` at its end - which on 2026-09-17 stood in the
footer as `nothing fetched yet`, logged by a browser that had a list on screen
the whole time. The rows it has stand until the refresh has said what replaces
them. A corpus of no rows, `items = {}`, does replace them: the file said so.
"""
function reload_data!(st::BState)
    st.reload || return false
    st.reload = false
    facts = fetchedfile()
    m = mtime(facts)
    if m != st.factsat && isfile(facts)
        st.factsat = m
        fresh = try
            # One read of the file for both: the rows, and when they were
            # fetched, which the title bar shows.
            store = load_fetched()
            st.refreshed = String(something(get(store, "fetched_at", nothing), ""))
            its = get(store, "items", nothing)
            its === nothing ? nothing : vcat(loaditems(its), local_items())
        catch e
            logerror!(e, catch_backtrace(), "reload_data!")
            nothing
        end
        if fresh !== nothing
            # The rows the clocks know and the corpus does not, rebuilt the
            # way launch builds them rather than kept by hand off a set the
            # poll wrote once: a light row the refresh has since brought in
            # is the corpus's now, and one the inbox has since dropped as read
            # is nobody's.
            append!(fresh, try
                inbox_items(Set(x.url for x in fresh))
            catch e
                logerror!(e, catch_backtrace(), "inbox_items")
                Item[]
            end)
            st.all = fresh
            rebuild_axes!(st)
        end
        # And the sources the poll in that refresh could not get an answer
        # from, which stand in the footer until one does.
        st.failing = try
            Events.failing()
        catch e
            logerror!(e, catch_backtrace(), "failing")
            st.failing
        end
    end
    # Sorted afresh: what landed is a new list, and what moved in it is
    # what the order is for.
    refilter!(st; resort = true)   # which is what re-reads the three records
    # A refresh this window started says what it did; anything else is somebody
    # else's write, and saying whose it was is the whole point of the line.
    st.status = isempty(st.refreshsaid) ? "reloaded — something else wrote in data/" :
                st.refreshsaid
    st.refreshsaid = ""
    true
end
