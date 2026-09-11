"""
    Worklog

A dashboard for tracking ongoing work across every repo, sorted into lanes by
what the work actually needs next.

One module, so that the file-format quirks and the GitHub quirks live in
exactly one place. The pieces, with the includes at the foot of this file as the
index of the rest:

  * `theme.jl`   every colour the program prints, and the file under `themes/`
                 that `config.toml` names as the one to read them from
  * `gh.jl`      the GraphQL search lanes, over `gh api graphql`
  * `events.jl`  the activity poll, over GitHub.jl's REST
  * `refresh.jl` bucketing, snoozes, and the snapshot diff
  * `marks.jl`   what you have done to an item: seen, touched, snoozed, drafted
  * `fetched.jl` one half of `data/`: everything GitHub can answer again
  * `state.jl`   the other half: the comment-preserving line editor for
                 `local.toml`, which holds every block anything here writes
  * `ui.jl`      the `Item` type, the lists it is loaded from, and the entry
                 that opens the browser on them
  * `controller.jl` the view stack that owns stdin, the decoder that turns its
                 bytes into `TermInput.Keys`, and the views it prompts with
  * `browse/`    the browser itself: filters, panes, threads, diffs, writing
  * `paneview.jl` a `TermIFrame` session drawn in a pane, with a thread beside it
  * `cli.jl`     the `wl <command>` surface

File ownership is strict, because it is what keeps the user's notes safe.
Everything but `config.toml` lives in `data/`, which is a git repository of its
own - see `datadir()`.

  | file          | owner   | lifetime                          |
  |---------------|---------|-----------------------------------|
  | `config.toml`      | you     | edited by hand, only ever read    |
  | `data/local.toml`  | both    | edited key-by-key, never rewritten, tracked |
  | `data/fetched.json`| machine | everything GitHub can answer again, ignored |

Two files and one line between them: what can be got again from GitHub, and
what cannot. The second is what you decided about each item and what you have
done to it - it is worth a history, and it is small enough to read one.
"""
module Worklog

using Dates, Printf, SHA, TOML
import FileWatching
using JSON3, OrderedCollections
using TermIFrame
# By name, so the pane can add the one method that knows where it is drawn.
import TermIFrame: retarget_mouse
# The composer, the line prompt, the key vocabulary they bind and the
# escape-aware measuring under all of it. `suspend` and `text` are extended
# here rather than shadowed: this program's terminal is one more thing that can
# be handed to a child, and its composer is one more thing that holds text.
using TermInput
import TermInput: suspend, text
import REPL
import InteractiveUtils
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
    # Expanded, because a shell is not the only thing that sets this: a `~` that
    # arrives unexpanded would have `mkpath` quietly create a directory *called*
    # `~` under whatever the working directory happens to be.
    d = expanduser(get(ENV, "WORKLOG_DATA", joinpath(ROOT, "data")))
    isdir(d) || mkpath(d)
    DATA_DIR[] = d
end

"One file in the data directory."
datapath(name::AbstractString) = joinpath(datadir(), name)

include("pyjson.jl")
include("util.jl")
include("theme.jl")
include("marks.jl")
include("fetched.jl")
include("cache.jl")
include("repos.jl")
include("ci.jl")
include("gh.jl")
include("events.jl")
include("refresh.jl")
include("state.jl")
include("controller.jl")
include("ui.jl")
# The browser, in the order the pieces depend on each other: a type or a
# constant has to exist before the methods annotated on it are defined, and
# everything below that is a function and could go anywhere. Split because one
# file of four and a half thousand lines is a file nobody can find anything in -
# the names are the index.
include("browse/nodes.jl")        # `Node`, which the rest of this is about
include("browse/filters.jl")      # the filter and view model
include("browse/bstate.jl")       # `Undo` and `BState`
include("browse/markdown.jl")     # a comment body becomes styled rows
include("browse/meta.jl")         # the metadata pane
include("browse/layout.jl")       # geometry, selection, hit-testing, links
include("browse/frame.jl")        # the detail pane, and the whole frame
include("browse/content.jl")      # threads and diffs become nodes
include("browse/fetch.jl")        # what runs in the background, and who waits
include("browse/keys.jl")         # `handle_key!`
include("browse/mouse.jl")        # `onmouse!`
include("browse/search.jl")       # `/`
include("browse/writing.jl")      # comments, reviews, labels, snoozes, archive
include("browse/checkout.jl")     # which local checkout an item's work is in
include("browse/items.jl")        # imported items and adopted branches
include("browse/sessions.jl")     # the editor, the note, and hosted programs
include("browse/checks.jl")       # CI
include("paneview.jl")
include("cli.jl")

# `dispatch` reaches every code path in the program, so the first call to it
# infers the whole command surface: `wl --help` cost 6s of which only 0.7s was
# loading the module. Forcing that inference into the package image at
# precompile time is the difference between a usable CLI and one you avoid.
precompile(main, (Vector{String},))
precompile(dispatch, (Vector{String}, DateTime))
precompile(refresh, (Vector{String}, DateTime))
# Spelled out, because `JSON3.Object` bare is a `UnionAll` and `precompile`
# answers `false` for one without saying so - this line was a no-op for as long
# as it has been here. The parameters are what `JSON3.read` of a string gives a
# *nested* object, which is what a search result's node is.
precompile(normalize, (JSON3.Object{Base.CodeUnits{UInt8,String},
                                    SubArray{UInt64,1,Vector{UInt64},
                                             Tuple{UnitRange{Int64}},true}},
                       String, String))
precompile(Events.unread, (Dict{String,Any}, String, DateTime))
precompile(set_fields, (String, Vector{Pair{String,Any}}, DateTime))
precompile(next_batch, (Int,))
precompile(ui, (Vector{String}, DateTime))

function __init__()
    # The colours, before anything can draw. Said on stderr rather than thrown:
    # a misspelt colour must not stop the dashboard, and must not go unnoticed
    # either - the role it names is drawn as nothing until the line is fixed.
    try
        for p in load_theme!()
            println(stderr, "worklog: ", p)
        end
    catch
        # A theme is decoration. Not being able to read one is not a reason for
        # the program to refuse to start, and `THEME` is already all empty.
    end
    # The sessions this program owns are the ones named for it, and
    # `WORKLOG_TMUX` is the variable its own documentation tells you to export.
    # Both are TermIFrame's defaults to be told, not its business to guess.
    MUX_PREFIX[] = "wl"
    MUX_ENV[] = "WORKLOG_TMUX"
    # A colour nothing else emits, so `style_code_spans` can find the code-span
    # delimiters Term marks and turn them into a background. Set here rather
    # than at precompile time: the theme is a mutable global of Term's.
    try
        Term.TERM_THEME[].md_code = "#ff00ff"
    catch
    end
end

end # module Worklog
