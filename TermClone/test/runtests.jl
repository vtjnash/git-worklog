# Term's own suite, run against the clone. StyledStrings writes what the
# terminal's terminfo says it can draw, so the suite says which terminal that
# is: one with italics, dim, strikethrough and 24-bit colour, as Term assumes.
ENV["TERM"] = "xterm-256color"
ENV["COLORTERM"] = "truecolor"

using Suppressor
import Suppressor: @capture_out
using StableRNGs
using Term
using Test
import Term: console_width
import Term: Tree, Dendogram, Table, Compositor

const RNG = StableRNG(1337)

include("__test_utils.jl")

using TimerOutputs: TimerOutputs, @timeit
const TIMEROUTPUT = TimerOutputs.TimerOutput()

import Term.Consoles: Console, enable, disable

Term.DEBUG_ON[] = false
const TEST_DEBUG_MODE = false  # renderables are saved as strings
const TEST_CONSOLE_WIDTH = 80
const IS_WIN = Sys.iswindows()
con = Console(TEST_CONSOLE_WIDTH)
enable(con)

# Each file in a testset of its own, so that one file's failures are counted
# and the next file still runs - Term's suite stops at the first file that
# fails.
macro runner(fn)
    return quote
        tprintln(
            $(
                "\n{bold green}Running:{/bold green} {underline bold white}'$fn'{/underline bold white}"
            ),
        )
        @testset $fn begin
            @time @timeit_include($fn)
        end
    end |> esc
end

const ONLY = filter(!isempty, split(get(ENV, "TERM_TESTS", ""), ','))
const FILES = [
    "01_test_text_utils.jl",
    "02_test_ansi.jl",
    "03_test_measure.jl",
    "04_test_style.jl",
    "05_test_macros.jl",
    "06_test_box.jl",
    "07_test_renderables.jl",
    "08_test_panel.jl",
    "09_test_layout.jl",
    "10_test_introspection.jl",
    "11_test_theme.jl",
    "12_test_console.jl",
    "13_test_logs.jl",
    "14_test_highlight.jl",
    "15_test_progress.jl",
    "16_test_tree.jl",
    "17_test_dendogram.jl",
    "18_test_table.jl",
    "19_test_repr.jl",
    "20_test_compositor.jl",
    "21_test_markdown.jl",
    "22_test_grid.jl",
    "23_test_link.jl",
    "24_prompts.jl",
    "25_annotations.jl",
    "26_test_live.jl",
    "98_test_examples.jl",
    "99_test_errors.jl",
]

try
    @testset "Term on TermInput" begin
        for fn in FILES
            (isempty(ONLY) || any(o -> startswith(fn, o), ONLY)) || continue
            @eval @runner $fn
        end
    end
finally
    write_expected()
end
show(TIMEROUTPUT; compact = true, sortby = :firstexec)
println('\n')
disable(con)
