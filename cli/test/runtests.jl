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
# By name where a test asks Term what this program told it - the two palettes
# under `[term]` and `[code]` in a theme file are Term's globals, not ours.
import Term
const W = Worklog

# The standing error warning takes the footer's second row, so a log left over
# from a previous run would fail every test that asserts what is written there.
# Clearing it is deliberate: running the suite is a developer action, and the
# tests below write and delete this file themselves anyway.
isfile(W.errlog()) && rm(W.errlog())

# Every path this program writes through is a `Ref`, and the rule is that all of
# them are pointed somewhere else for the whole run - not that each leak is
# fixed as it turns up. Both halves of `data/` are redirected here: a test that
# pressed `r` stamped a real item as read, and one that adopted a branch left a
# block behind in a file whose `finally` did not run.
#
# Seeded from the real files, because the read-only testsets are tests of
# whatever is actually in them. The cache is not, since a cache is rebuildable
# by definition and starting empty is the honest state for one.
#
# `errors.log` is the deliberate exception: the suite deletes the real one at
# startup and several tests assert on the footer warning it produces.
let d = mktempdir()
    for (r, real, empty) in ((W.FETCHED, W.fetchedfile(), "{}"),
                             (W.LOCAL, W.localfile(), ""))
        to = joinpath(d, basename(real))
        isfile(real) ? cp(real, to) : write(to, empty)
        r[] = to
    end
    W.CACHE_DIR[] = joinpath(d, "cache")
end
# Where the testsets that point `LOCAL` at a temp file put it back, since ""
# would mean the user's own file again.
const REPOS_SANDBOX = W.LOCAL[]

# And the colours, for the same reason the paths are redirected: a test that
# asserts a row is bold is a test of the program, not of whatever `config.toml`
# happens to name - `theme = ""` there would otherwise make every one of those
# assertions vacuously true, since `occursin("", row)` is.
@assert isempty(W.load_theme!(joinpath(W.ROOT, "themes", "default-ansi.toml")))

"""A fresh, empty `local.toml` for a testset that wants to start from nothing.

Empty rather than absent: several testsets read the file to put it back
afterwards, and "not there yet" is a state only the very first run of the
program is ever in.
"""
fresh_local() = (p = joinpath(mktempdir(), "local.toml"); write(p, ""); p)

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
include("suite/theme.jl")
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
include("suite/since.jl")
