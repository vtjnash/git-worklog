# What can be tested without a terminal.
#
# There is no TTY here, so the UI is verified by construction: `readevent` is a
# pure function of a byte stream, `render` is a pure function of state and a
# size, and `handle!`/`onmouse!` take an event and return an action. Between
# them that covers everything except whether a real terminal sends the bytes
# these tests feed it.
#
#     julia --project=cli cli/test/runtests.jl

using Test, Sockets
using Worklog
# And the two widget packages, for the one hook a theme reaches into them
# through: the weights a box is drawn in.
import TermInput, TermIFrame
const W = Worklog

"""What StyledStrings writes for a row of faces, which is what the terminal is
sent - and for a frame of them, a row to a line. What an assertion about a
colour on the screen reads."""
ansi(r::AbstractString) = sprint(print, r; context = :color => true)
ansi(rows::AbstractVector) = join(ansi.(rows), "\n")

"""What the screen says, as against how it looks: a row's text, or a string of
escapes with them taken out."""
const SGR_OSC = r"\e\[[0-9;:]*[A-Za-z]|\e\][^\e]*\e[\\]"
unstyled(s::Base.AnnotatedString) = String(s)
unstyled(s::AbstractString) = replace(String(s), SGR_OSC => "")

"The columns `s` prints in: a row's by its text, a string of escapes past them."
width(s::Base.AnnotatedString) = W.rowwidth(s)
width(s::AbstractString) = textwidth(unstyled(s))

"""A view drawn as the terminal would be sent it: `render`'s rows, written."""
frame(v, w::Int, h::Int, args...) = ansi(W.render(v, w, h, args...))

"""What a face writes before and after a word, as StyledStrings has it for this
terminal: `(on, off)`, for finding a style in a rendered row."""
function faceesc(f)
    s = ansi(TermInput.faced("x", f))
    i = findfirst('x', s)
    (s[1:prevind(s, i)], s[nextind(s, i):end])
end

"The escape a face begins with, on its own."
esc(f) = faceesc(f)[1]

"""The text an annotation of `s` is over: a region ends at its last byte, which
is not an index of `s` where the last character is wider than one."""
over(s, r::UnitRange{Int}) = (t = String(s); t[first(r):thisind(t, last(r))])

"""What faces a row has, and over what: `text => face` for each, in order."""
faces(s) = [over(s, a.region) => a.value for a in Base.annotations(s) if a.label === :face]

"""Is `f` on `s`: laid over some of a row, or written in a string of escapes."""
faceon(f, s::Base.AnnotatedString) =
    any(a -> a.label === :face && a.value == f, Base.annotations(s))
faceon(f, s::AbstractString) = occursin(esc(f), s)

# The standing error warning takes the footer's second row, so a log left over
# from a previous run would fail every test that asserts what is written there.
# Clearing it is deliberate: running the suite is a developer action, and the
# tests below write and delete this file themselves anyway.
isfile(W.errlog()) && rm(W.errlog())

# Times are drawn in the zone the process is in (`set_tz!`), and what the tests
# assert they are drawn as is UTC - on the developer's laptop as much as here.
W.set_tz!("UTC")

# Every path this program writes through is a `Ref`, and the rule is that all of
# them are pointed somewhere else for the whole run - not that each leak is
# fixed as it turns up. Both halves of `data/` are redirected here: a test that
# pressed `e` stamped a real item as read, and one that adopted a branch left a
# block behind in a file whose `finally` did not run.
#
# **Seeded from `fixture.json`, and it used to be from the real files** - on the
# argument that a read-only testset is a test of whatever is actually in them.
# That argument covers a sweep and not a testset that needs *a row with a
# property*, which is a fixture whether or not it is written as one; hunting the
# live corpus for one made an undeclared precondition out of a fact about
# somebody's inbox that day, and when the last snooze was cleared two of them
# errored - `nothing` as an index, which takes down every file after it rather
# than naming itself. `fetched.json` is untracked besides, so a fresh clone had
# no corpus at all and could not run the suite.
#
# The rows in the fixture are real ones, picked by property; `fixture.jl` is
# the record of which property each was picked for and how to make another.
# `suite/corpus.jl` is where the real dashboard is still read, over every row
# and never for one of them, and it skips itself when there is no `data/` here.
#
# `local.toml` starts **empty**, which is the honest state for a file that is a
# record of what you have done: the testsets that want a mark write it. The
# cache starts empty too, being rebuildable by definition.
#
# `errors.log` is the deliberate exception: the suite deletes the real one at
# startup and several tests assert on the footer warning it produces.
const REAL_FETCHED = W.fetchedfile()
let d = mktempdir()
    cp(joinpath(@__DIR__, "fixture.json"), joinpath(d, "fetched.json"))
    W.FETCHED[] = joinpath(d, "fetched.json")
    # And the per-user half of the config, which used to be the developer's
    # own: `mkstate` cleared the pinned repos by hand to undo that.
    cp(joinpath(@__DIR__, "config.toml"), joinpath(d, "config.toml"))
    W.USER_CONFIG[] = joinpath(d, "config.toml")
    W.LOCAL[] = joinpath(d, "local.toml")
    W.VIEWFILE[] = joinpath(d, "view.toml")
    write(W.LOCAL[], "")
    W.CACHE_DIR[] = joinpath(d, "cache")
    # And no `wl prefetch` left running behind each refresh the suite makes.
    W.PREFETCH_BEHIND[] = false
    # And the socket links, which would otherwise be re-pointed under
    # `/run/user` by a test of the re-pointing.
    W.RUN_DIR[] = joinpath(d, "run")
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
    st = W.BState(items, "worklog")
    st.nodes = [W.Node("alice  2026-08-01   first", "A paragraph long enough that it has to be wrapped across several rows of the detail pane, which is exactly the case a copy must undo.\n\nsecond para", :md, true),
                W.Node("bob  2026-08-02   second", "short", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)   # suppress the fetch
    st
end

"""Answer the question a new agent asks before it starts, with `cmd` as the
agent and nothing typed - for a test about where the session opens rather
than about the question - and say what the session said: the status the
pane was given, or `r`, what the call that asked returned, when nothing was
asked."""
function answer_agent!(ctrl, r; cmd = "sleep 120")
    top = isempty(ctrl.stack) ? nothing : last(ctrl.stack)
    top isa W.AgentPromptView || return r
    top.agents = [("test", cmd)]
    W.handle!(top, 13, ctrl)
    v = last(ctrl.stack)
    v isa W.PaneView ? v.child.status : r
end

"""The fixture row put there for this, under the name `fixture.jl` gave it.

    fixture_item("an issue")

A testset that needs a row with a property asks for it by name rather than
searching the corpus for one. The property is then declared in one place, the
dependency is greppable from both ends, and a fixture that has stopped carrying
it says so by name - where `findfirst` over the corpus handed back `nothing` to
be used as an index, which errors rather than fails and takes the file down.
"""
function fixture_item(name::AbstractString)
    u = W.jget(W.fetched("wanted"), Symbol(name))
    u === nothing && error("no fixture row for \"$name\" - see cli/test/fixture.jl")
    i = findfirst(x -> x.url == String(u), items)
    i === nothing && error("the fixture row for \"$name\" is not in the corpus")
    items[i]
end

# One file per thing being tested, mirroring `src/browse/`. The order is not
# cosmetic: several of these leave a file, a session or a filter behind that
# the next one reads.
include("suite/config.jl")
include("suite/theme.jl")
include("suite/input.jl")
include("suite/composer.jl")
include("suite/frame.jl")
include("suite/filters.jl")
include("suite/repos.jl")
include("suite/refresh.jl")
include("suite/notices.jl")
include("suite/writing.jl")
include("suite/search.jl")
include("suite/history.jl")
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
# Last, because it is the one file that reads `data/` and it puts the redirect
# back when it is done.
include("suite/corpus.jl")
