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
  | `config.toml` | you     | edited by hand, only ever read    |
  | `state.toml`  | you     | edited key-by-key, never rewritten|
  | `facts.json`  | machine | overwritten every refresh         |
  | `bulk.json`   | machine | slow-lane cache, refetched every 6h|
  | `queue.json`  | machine | what the backlog queue has shown  |
  | `read.json`   | machine | one seen-up-to timestamp per item |
  | `touched.json`| machine | one last-interaction timestamp per item|
  | `snooze.json` | machine | armed "until it moves" fingerprints|
  | `DASHBOARD.md`| machine | overwritten every refresh         |
"""
module Worklog

using Dates, Printf, SHA, TOML
using JSON3, OrderedCollections
import REPL
import InteractiveUtils
using SHA
using Base64

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

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
