# What can be tested without a terminal.
#
# There is no TTY here, so the UI is verified by construction: `readevent` is a
# pure function of a byte stream, `render` is a pure function of state and a
# size, and `handle!`/`onmouse!` take an event and return an action. Between
# them that covers everything except whether a real terminal sends the bytes
# these tests feed it.
#
#     julia --project=cli cli/test/runtests.jl

using Test
using Worklog
const W = Worklog

# The standing error warning takes the footer's second row, so a log left over
# from a previous run would fail every test that asserts what is written there.
# Clearing it is deliberate: running the suite is a developer action, and the
# tests below write and delete this file themselves anyway.
isfile(W.errlog()) && rm(W.errlog())

# The interaction clock is redirected for the whole run. Several tests below
# set a field, and setting a field stamps it - against the real file that would
# reorder the user's own lists as a side effect of running the suite.
W.TOUCHED[] = joinpath(mktempdir(), "touched.json")

# And the same for `state.toml`, for a stronger reason. Several testsets below
# adopt a branch or write a note, and each one reads the file first and writes
# it back in a `finally` - so a run that ends part-way through never reaches
# that, and the *next* run fails on counts that are one too high. Redirected,
# there is no `finally` to fail to run and no way for a test to reach the
# user's file at all. Seeded from the real one, because the read-only tests are
# tests of whatever is actually in there.
let d = joinpath(mktempdir(), "state.toml")
    isfile(W.statefile()) ? cp(W.statefile(), d) : write(d, "")
    W.STATE[] = d
end

# And the rest of them, found the same way: a test that pressed `r` stamped a
# real item as read a moment ago. Every path this program writes through is a
# `Ref`, and the rule is that all of them are pointed somewhere else for the
# whole run - not that each leak is fixed as it turns up. Seeded from the real
# files, because the read-only testsets are tests of whatever is in them; the
# cache is not, since a cache is rebuildable by definition and starting empty is
# the honest state for one.
#
# `errors.log` is the deliberate exception: the suite deletes the real one at
# startup and several tests assert on the footer warning it produces.
let d = mktempdir()
    for (r, real, empty) in ((W.Events.READ, W.Events.readfile(), "{}"),
                             (W.Events.INBOX, W.Events.inboxfile(), "{}"),
                             (W.REPOS_FILE, W.repos_file(), ""))
        to = joinpath(d, basename(real))
        isfile(real) ? cp(real, to) : write(to, empty)
        r[] = to
    end
    W.CACHE_DIR[] = joinpath(d, "cache")
end
# Where the testsets that point `REPOS_FILE` at a temp repo put it back, since
# "" would mean the user's own file again.
const REPOS_SANDBOX = W.REPOS_FILE[]

# Shared by every file below: the dashboard as it actually is, and a state
# over it whose fetch is already satisfied so that no test reaches the
# network for a thread it did not ask for.
items = W.loaditems()
mkstate() = begin
    st = W.BState(items, "worklog", Set{String}())
    st.nodes = [W.Node("alice  2026-08-01   first", "A paragraph long enough that it has to be wrapped across several rows of the detail pane, which is exactly the case a copy must undo.\n\nsecond para", :md, true),
                W.Node("bob  2026-08-02   second", "short", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)   # suppress the fetch
    st
end

# One file per thing being tested, mirroring `src/browse/`. The order is not
# cosmetic: several of these leave a file, a session or a filter behind that
# the next one reads.
include("suite/input.jl")
include("suite/composer.jl")
include("suite/frame.jl")
include("suite/filters.jl")
include("suite/repos.jl")
include("suite/refresh.jl")
include("suite/writing.jl")
include("suite/search.jl")
include("suite/markdown.jl")
include("suite/state.jl")
include("suite/mux.jl")
include("suite/pane.jl")
include("suite/views.jl")
include("suite/worktrees.jl")
include("suite/lanes.jl")
include("suite/archive.jl")
include("suite/robustness.jl")
include("suite/git.jl")
include("suite/items.jl")
include("suite/clock.jl")
