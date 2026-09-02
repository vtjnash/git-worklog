"""
    Worklog

A dashboard for tracking ongoing work across every repo, sorted into lanes by
what the work actually needs next.

Four pieces, all in this one module so that the file-format quirks and the
GitHub quirks live in exactly one place:

  * `gh.jl`      the GraphQL search lanes, over `gh api graphql`
  * `events.jl`  unread tracking, over GitHub.jl's REST
  * `refresh.jl` bucketing, snoozes, the snapshot diff, DASHBOARD.md
  * `touched.jl` the interaction clock, for ordering work by what you did
  * `state.jl`   the comment-preserving line editor for state.toml
  * `ui.jl`      the interactive navigator
  * `mux.jl`     multiplexer sessions, for hosting a child program
  * `paneview.jl` one of those sessions, drawn in a pane
  * `cli.jl`     the `wl <command>` surface

File ownership is strict, because it is what keeps the user's notes safe:

  | file          | owner   | lifetime                          |
  |---------------|---------|-----------------------------------|
Everything but `config.toml` lives in `data/`, which is a git repository of its
own - see `datadir()`.

  | `config.toml`      | you     | edited by hand, only ever read    |
  | `data/state.toml`  | you     | edited key-by-key, never rewritten|
  | `data/facts.json`  | machine | overwritten every refresh         |
  | `data/bulk.json`   | machine | slow-lane cache, refetched every 6h|
  | `data/queue.json`  | machine | what the backlog queue has shown  |
  | `data/read.json`   | machine | one seen-up-to timestamp per item |
  | `data/inbox.json`  | machine | the event cursors, and what is unread |
  | `data/touched.json`| machine | one last-interaction timestamp per item|
  | `data/snooze.json` | machine | armed "until it moves" fingerprints|
  | `data/DASHBOARD.md`| machine | overwritten every refresh         |
"""
module Worklog

using Dates, Printf, SHA, TOML
using JSON3, OrderedCollections
import REPL
import InteractiveUtils
using SHA
using Base64

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

"""Where the state lives, which is not where the code does.

These files stopped being ephemeral. The interaction clock, the read cursors and
the inbox are records of what you have *done*, and none of them can be
re-derived from GitHub - so they are worth a history, and it is not the code's
history. Kept together in one directory with a git repository of its own: mixed
into this one they buried the diffs that matter in the diffs that do not, and
dirtied the tree on every refresh.

`config.toml` stays beside the code. It is configuration, hand-written, and
versioned with the program that reads it.

Resolved lazily and not at precompile time, so `WORKLOG_DATA` can point a test
somewhere disposable without the answer having been baked into the image.
"""
const DATA_DIR = Ref("")
function datadir()
    isempty(DATA_DIR[]) || return DATA_DIR[]
    d = get(ENV, "WORKLOG_DATA", joinpath(ROOT, "data"))
    isdir(d) || mkpath(d)
    DATA_DIR[] = d
end

"One file in the data directory."
datapath(name::AbstractString) = joinpath(datadir(), name)

include("pyjson.jl")
include("util.jl")
include("cache.jl")
include("ansi.jl")
include("repos.jl")
include("ci.jl")
include("gh.jl")
include("events.jl")
include("refresh.jl")
include("touched.jl")
include("state.jl")
include("controller.jl")
include("ui.jl")
include("mux.jl")
include("browse.jl")
include("paneview.jl")
include("cli.jl")

# `dispatch` reaches every code path in the program, so the first call to it
# infers the whole command surface: `wl --help` cost 6s of which only 0.7s was
# loading the module. Forcing that inference into the package image at
# precompile time is the difference between a usable CLI and one you avoid.
precompile(main, (Vector{String},))
precompile(dispatch, (Vector{String}, DateTime))
precompile(refresh, (Vector{String}, DateTime))
precompile(render, (OrderedDict{String,Any}, Vector{Any}, Dict{String,Any}, Int, DateTime, Vector{OrderedDict{String,Any}}))
precompile(normalize, (JSON3.Object, String, String))
precompile(Events.unread, (Dict{String,Any}, String, DateTime))
precompile(set_fields, (String, Vector{Pair{String,Any}}, DateTime))
precompile(next_batch, (Int,))
precompile(ui, (Vector{String}, DateTime))

function __init__()
    # A colour nothing else emits, so `style_code_spans` can find the code-span
    # delimiters Term marks and turn them into a background. Set here rather
    # than at precompile time: the theme is a mutable global of Term's.
    try
        Term.TERM_THEME[].md_code = "#ff00ff"
    catch
    end
end

end # module Worklog
