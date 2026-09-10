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

Timers are deliberately *not* in here. `arm_refresh!` starts a task that sleeps
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

function load_nodes!(st::BState)
    # The import row has nothing to fetch and says so itself. Keyed like any
    # other load, so moving away and back does not rebuild it.
    if st.sel == 0 || isempty(st.items)
        st.loaded == "new:" && return
        place!(st, "new:")      # before the nodes go: it reads them
        st.nodes = newnodes()
        st.loaded = "new:"
        st.pending = nothing; st.pendkey = ""; st.quiet = false
        clearsel!(st)
        # The status is not touched. There is no fetch here to announce, and
        # this runs after every key - including the ones on an empty list, whose
        # message it would otherwise write over on the way past.
        return
    end
    it = st.items[st.sel]
    mode = st.mode
    key = string(it.url, ":", mode)
    if st.loaded == key || st.pendkey == key
        # Nothing to fetch. What is on screen is this key's already - or is the
        # empty pane its read left - so the cursor belongs to it and is claimed
        # rather than moved. Moving it here would throw away the place of
        # anyone who arrived by any road but a fetch.
        st.nkey = key
        return
    end
    # Taken here rather than inside the task: a moment before the fetch begins
    # is early by however long scheduling takes, and early is the safe end -
    # `fetched` decides what `r` can mark seen, and too early leaves a comment
    # unread rather than hiding one.
    at = utcnow()
    st.pending = fetching(key) do
        try
            mode_nodes(mode, it, at)
        finally
            st.wake === nothing || st.wake()   # redraw as soon as this lands
        end
    end
    st.pendkey = key
    st.quiet = false
    place!(st, key)        # while the nodes going away are still here to read
    st.nodes = Node[]
    clearsel!(st)          # it indexed rows that are about to be replaced
    st.status = "loading " * it.ref * "…"
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
here decides for itself when to re-read - the thread has a ten-minute window,
the checks two minutes, the metadata is re-read when the selection moves - and
each of those is a guess about how fast that thing changes. `R` is for when the
guess is wrong: you pushed a moment ago, or commented from the web, and what is
wanted is the answer GitHub has now.

Only this item. The dashboard is `wl refresh`, which takes minutes and re-reads
two thousand items to answer a question about one.

The metadata is asked for by clearing the key that decides whether it needs
asking for, and started here rather than left to the caller so that the
`load_meta!` at the end of the key loop finds it already in flight.
"""
function refresh_item!(st::BState)
    (isempty(st.items) || st.sel == 0) && return "nothing selected to re-read"
    it = st.items[clamp(st.sel, 1, length(st.items))]
    st.metakey = ""; st.metapending = nothing
    load_meta!(st; fresh = true)
    # Refuses while something is already in flight, and the message is the same
    # either way: a read of this item is on its way, and a second one behind it
    # would answer with what the first is already going to say.
    refresh_nodes!(st)
    string("re-reading ", it.ref, "…")
end

"""Arm the debounce for an entry that went up stale.

The timer is a task that sleeps and then wakes the frame, because the event loop
blocks on its channel and has no tick of its own. It decides nothing: by the time
it fires the selection may have moved, and what gets re-read is whatever is on
screen then rather than what was on screen when this was armed.
"""
function arm_refresh!(st::BState, at::Float64 = time())
    (isempty(st.nodes) || get(st.nodes[1].meta, "stale", false) !== true) && return false
    st.refreshkey = st.loaded
    st.refreshat = at + REFRESH_AFTER[]
    w = st.wake
    w === nothing || @async begin
        sleep(REFRESH_AFTER[])
        w()
    end
    true
end

"""Re-read a stale entry whose debounce has run out, if it is still on screen.

Returns false either way: nothing it does changes the frame. What lands from it
does, in its own wake.
"""
function due_refresh!(st::BState, at::Float64 = time())
    isempty(st.refreshkey) && return false
    if st.refreshkey != st.loaded || !isempty(st.pendkey)
        st.refreshkey = ""                  # it belongs to something else now
        return false
    end
    at < st.refreshat && return false
    st.refreshkey = ""
    refresh_nodes!(st)
    false
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
    if quiet && !isempty(ns) && get(ns[1].meta, "failed", false) === true
        # A refresh nobody asked for must not take the thread away from someone
        # reading it. The cached copy stayed on screen and stays there; only the
        # status says the re-read did not land.
        st.status = "could not re-read \u00b7 showing the cached copy"
        return true
    end
    st.nodes = ns
    # The cursor is only moved by a load the reader asked for, and it is moved
    # to wherever they were in this thread the last time they were in it - the
    # top of it only the first time. A refresh under them keeps their place
    # untouched: rows may have shifted by a comment, and that is a better answer
    # than either of the two above.
    if !quiet
        st.nkey = st.loaded
        st.nrow, st.ntop = get(st.place, st.loaded, (1, 1))
        st.status = ""
    end
    clearsel!(st)          # either way, it indexed rows that are gone
    arm_refresh!(st)
    true
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
# still downstream of a key press - `arm_refresh!` is the only timer, it is a
# one-shot debounce armed by a load somebody asked for, and it writes nothing
# but cache entries under their own names.
#
# That is what makes the read-modify-write in `set_mark!` safe without a lock.
# It reads the whole file, changes one field of one row and writes it back, so
# two of them straddling each other would lose the earlier one's field - and two of them cannot straddle each other while the only thing
# that starts one is a person typing in one window at a time. A poll loop that
# went off in every open window at once is exactly what would break that, so if
# one is ever wanted, the lock comes first and this is where to remember it.

"""Files whose contents are on screen, and what changing one costs to adopt.

`facts.json` is the item list itself and is rebuilt from disk. The other two are
records the filters read - `marks.json` is several of them now - and taking them
again is a `refilter!`. Everything else in there - the cache, the inbox cursors
- is either not read by the browser or not read again after it starts, and a
watch that woke for those would be waking for every fetch this program makes.
"""
const WATCHED = ("facts.json", "state.toml", "marks.json")

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

"""Run the whole refresh, from inside the browser, without blocking it.

`R` re-reads the item under the cursor; this is the other half - the fetch that
rebuilds the dashboard itself, which until now meant leaving the browser or
running `wl refresh` in another terminal and waiting for the watcher to notice.

**As a subprocess, and not in this process.** The work would be the same, but
`refresh` prints thirty lines of lane progress to stderr and there is no way to
send that somewhere else without `redirect_stderr`, which is process-wide: it
would take the browser's own writes with it for the half-minute the refresh
takes. A child gets its own descriptors, and the same `bin/refresh` the user
would have run by hand - which also means a refresh that dies takes nothing on
screen with it.

**And it sets `reload` by hand.** `watch_data!` deliberately ignores writes this
process made, and the child's writes are this process's as far as `OURS` is
concerned only because the child never touched that map - but the watcher fires
on the mtime, so the flag is set here rather than left to a race with it.

`fetching` is what keeps two of these from overlapping: a second `u` joins the
one already running instead of starting a second refresh against the same files.
"""
function refresh_all!(st::BState)
    key = "refresh"
    running = lock(INFLIGHT_LOCK) do
        t = get(INFLIGHT, key, nothing)
        t !== nothing && !istaskdone(t)
    end
    running && return "already refreshing"
    fetching(key) do
        said = try
            run_refresh()
        catch e
            logerror!(e, catch_backtrace(), "refresh")
            "refresh failed \u2014 see the footer"
        end
        st.refreshsaid = said
        st.reload = true
        st.wake === nothing || st.wake()
    end
    "refreshing \u2026"
end

"""Run `bin/refresh` to completion and answer with the last line it printed.

The last line is its own summary - items, changes, rate-limit points - which is
exactly what a status row wants. Captured to a temp file rather than a pipe
because nothing reads it while it runs, and a pipe nobody drains is a way to
wedge a child that writes more than its buffer.
"""
function run_refresh()
    log = tempname()
    try
        open(log, "w") do io
            run(pipeline(`$(joinpath(ROOT, "cli", "bin", "refresh"))`;
                         stdin = devnull, stdout = io, stderr = io))
        end
        said = ""
        for l in eachline(log)
            isempty(strip(l)) || (said = strip(l))
        end
        isempty(said) ? "refreshed" : String(said)
    finally
        rm(log; force = true)
    end
end

"""Take the records again, and the item list with them when a refresh landed.

Returns true when the frame has to be drawn again, which is the whole contract
`onwake!` has with the controller.

The item list is only rebuilt when `facts.json` is the file that moved, because
that is the only change that can add or remove a row - and rebuilding it is a
read of the file plus a walk of the local checkouts, which is a cost worth
paying every few minutes and not every keystroke somebody else types.

Rows that came from the unread poll rather than from `facts.json` are carried
across: they are the threads that are unread and untracked, this process asked
GitHub for them at startup, and a refresh that does not mention them is not
evidence that they are gone.
"""
function reload_data!(st::BState)
    st.reload || return false
    st.reload = false
    facts = datapath("facts.json")
    m = mtime(facts)
    if m != st.factsat && isfile(facts)
        st.factsat = m
        fresh = try
            vcat(loaditems(), local_items())
        catch e
            logerror!(e, catch_backtrace(), "reload_data!")
            Item[]
        end
        if !isempty(fresh)
            have = Set(x.url for x in fresh)
            append!(fresh, (it for it in st.all if it.url in st.unread && !(it.url in have)))
            st.all = fresh
            rebuild_axes!(st)
        end
    end
    refilter!(st)           # which is what re-reads the three records
    # A refresh this window started says what it did; anything else is somebody
    # else's write, and saying whose it was is the whole point of the line.
    st.status = isempty(st.refreshsaid) ? "reloaded — something else wrote in data/" :
                st.refreshsaid
    st.refreshsaid = ""
    true
end
