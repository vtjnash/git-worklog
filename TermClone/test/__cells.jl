# What a terminal shows for a string of text and escapes: the acceptance
# criterion under Term's own, which is the bytes.
#
# Term and StyledStrings spell the same picture differently - Term closes and
# reopens a colour around every nested tag, StyledStrings writes only what
# changes - so a byte comparison fails for output that draws identically. This
# reads both the way a terminal does, into lines of cells, each a grapheme and
# what it is drawn in, and compares those. A snapshot is then one of
#
#   bytes  the bytes Term wrote
#   cells  the same cells: the same picture, spelled differently
#   text   the same text, drawn differently (a colour, a weight, a box style)
#   none   different text: a different layout
#
# and `expected/<test file>.toml` says which each snapshot that is not `bytes`
# is, so the suite fails when one gets worse and when one gets better.

import TOML

const CELL_ESC = r"\e\[([0-9;:]*)([A-Za-z])|\e\]8;[^;\e\a]*;([^\e\a]*)(?:\e\\|\a)|\e\][^\a\e]*(?:\e\\|\a)"

const BASE16 = ((0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238),
    (205, 0, 205), (0, 205, 205), (229, 229, 229), (127, 127, 127), (255, 0, 0),
    (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255),
    (255, 255, 255))

"A colour as a terminal has it: one of the sixteen by index, anything else as RGB."
function cellcolor(n::Int)
    n < 16 && return n
    if n < 232
        i = n - 16
        lv(x) = x == 0 ? 0 : 55 + 40x
        return (lv(i ÷ 36), lv((i ÷ 6) % 6), lv(i % 6))
    end
    g = 8 + 10 * (n - 232)
    return (g, g, g)
end

mutable struct CellState
    fg::Any
    bg::Any
    bold::Bool
    dim::Bool
    italic::Bool
    underline::Bool
    blink::Bool
    inverse::Bool
    hidden::Bool
    strike::Bool
    link::Union{Nothing, String}
end
CellState() = CellState(nothing, nothing, false, false, false, false, false, false, false, false, nothing)

function cellsgr!(st::CellState, params::AbstractString)
    ps = [isempty(p) ? 0 : something(tryparse(Int, p), 0) for p in split(params, r"[;:]")]
    i = 1
    while i <= length(ps)
        p = ps[i]
        if p == 0
            link = st.link
            st2 = CellState()
            for f in fieldnames(CellState)
                setfield!(st, f, getfield(st2, f))
            end
            st.link = link
        elseif p == 1; st.bold = true
        elseif p == 2; st.dim = true
        elseif p == 3; st.italic = true
        elseif p == 4; st.underline = true
        elseif p == 5; st.blink = true
        elseif p == 7; st.inverse = true
        elseif p == 8; st.hidden = true
        elseif p == 9; st.strike = true
        elseif p == 21 || p == 22; st.bold = false; st.dim = false
        elseif p == 23; st.italic = false
        elseif p == 24; st.underline = false
        elseif p == 25; st.blink = false
        elseif p == 27; st.inverse = false
        elseif p == 28; st.hidden = false
        elseif p == 29; st.strike = false
        elseif 30 <= p <= 37; st.fg = p - 30
        elseif 90 <= p <= 97; st.fg = p - 90 + 8
        elseif 40 <= p <= 47; st.bg = p - 40
        elseif 100 <= p <= 107; st.bg = p - 100 + 8
        elseif p == 39; st.fg = nothing
        elseif p == 49; st.bg = nothing
        elseif p == 38 || p == 48
            c = nothing
            if i + 2 <= length(ps) && ps[i + 1] == 5
                c = cellcolor(ps[i + 2]); i += 2
            elseif i + 4 <= length(ps) && ps[i + 1] == 2
                c = (ps[i + 2], ps[i + 3], ps[i + 4]); i += 4
            end
            p == 38 ? (st.fg = c) : (st.bg = c)
        end
        i += 1
    end
end

"""
    cell(g, st) -> Tuple

A grapheme as it is seen: a space has no foreground, weight or slant to see,
and a concealed character is a space.
"""
function cell(g::AbstractString, st::CellState)
    glyph = st.hidden ? " "^textwidth(g) : String(g)
    blank = all(isspace, glyph)
    fg = st.fg isa Int && st.fg >= 16 ? cellcolor(st.fg) : st.fg
    bg = st.bg isa Int && st.bg >= 16 ? cellcolor(st.bg) : st.bg
    if blank && !st.inverse
        return (glyph, nothing, bg, false, false, false, st.underline, false, st.strike, st.link)
    end
    return (glyph, fg, bg, st.bold, st.dim, st.italic, st.underline, st.inverse, st.strike, st.link)
end

"""
    screen(s) -> Vector{Vector{Tuple}}

The lines a terminal shows for `s`, each a vector of cells.
"""
function screen(s::AbstractString)
    st = CellState()
    lines = Vector{Tuple}[Tuple[]]
    i, n = 1, ncodeunits(s)
    buf = IOBuffer()
    flush!() = begin
        t = String(take!(buf))
        for g in Base.Unicode.graphemes(t)
            if g == "\n"
                push!(lines, Tuple[])
            else
                push!(lines[end], cell(g, st))
            end
        end
    end
    while i <= n
        if s[i] == '\e'
            m = match(CELL_ESC, s, i)
            if m !== nothing && m.offset == i
                flush!()
                if m.captures[2] == "m"
                    cellsgr!(st, m.captures[1])
                elseif m.captures[3] !== nothing
                    st.link = isempty(m.captures[3]) ? nothing : String(m.captures[3])
                end
                i += ncodeunits(m.match)
                continue
            end
        end
        write(buf, s[i])
        i = nextind(s, i)
    end
    flush!()
    return lines
end

"`s` with every escape taken out: the text a terminal shows."
visible(s::AbstractString) = replace(s, CELL_ESC => "")

"""
    samecells(a, b) -> Bool

Whether `a` and `b` draw the same cells in a terminal.
"""
samecells(a, b) = screen(string(a)) == screen(string(b))

"""
    match_level(got, want) -> String

How close `got` is to `want`: `bytes`, `cells`, `text` or `none`.
"""
function match_level(got::AbstractString, want::AbstractString)
    got == want && return "bytes"
    screen(got) == screen(want) && return "cells"
    visible(got) == visible(want) && return "text"
    return "none"
end

const LEVELS = ("none", "text", "cells", "bytes")
levelrank(l) = something(findfirst(==(l), LEVELS), 0)

# --------------------------- the expected manifest -------------------------- #

const RECORD = get(ENV, "TERM_RECORD", "") == "1"
const EXPECTED_DIR = joinpath(@__DIR__, "expected")
const EXPECTED = Dict{String, Dict{String, Any}}()
const OBSERVED = Dict{String, Dict{String, Any}}()

function expected_for(file::AbstractString)
    key = splitext(basename(file))[1]
    get!(EXPECTED, key) do
        p = joinpath(EXPECTED_DIR, key * ".toml")
        isfile(p) ? TOML.parsefile(p) : Dict{String, Any}()
    end
end

"""
    expected_level(file, name) -> String

The level the manifest of test file `file` expects snapshot `name` at:
`bytes` unless it says otherwise.
"""
expected_level(file, name) = get(expected_for(file), name, "bytes")

"Note what a snapshot came out as, for `TERM_RECORD=1` to write back."
function observe!(file, name, level)
    key = splitext(basename(file))[1]
    d = get!(OBSERVED, key, Dict{String, Any}())
    level == "bytes" ? delete!(d, name) : (d[name] = level)
    return level
end

"Write what was observed back to the manifests, in record mode."
function write_expected()
    RECORD || return
    mkpath(EXPECTED_DIR)
    for (key, d) in OBSERVED
        p = joinpath(EXPECTED_DIR, key * ".toml")
        isempty(d) && (isfile(p) && rm(p); continue)
        open(p, "w") do io
            println(io, "# How each snapshot of $key.jl that does not match Term's bytes matches:")
            println(io, "# cells = same terminal cells, text = same text only, none = different text.")
            TOML.print(io, d; sorted = true)
        end
    end
end

"""
    check_level(got, want, name, file)

The acceptance test for one comparison with Term's output: the bytes, where the
manifest of test file `file` expects them, and otherwise `@test_broken` on the
bytes and `@test` on the level it does expect - so a snapshot that gets better
or worse than the manifest says fails either way.
"""
function check_level(got, want, name, file)
    got, want, name = string(got), string(want), string(name)
    lvl = observe!(file, name, match_level(got, want))
    if lvl != "bytes" && get(ENV, "TERM_DUMP", "") != ""
        d = joinpath(ENV["TERM_DUMP"], splitext(basename(file))[1])
        mkpath(d)
        write(joinpath(d, name * ".got"), got)
        write(joinpath(d, name * ".want"), want)
    end
    exp = RECORD ? lvl : expected_level(file, name)
    if exp == "bytes"
        @test got == want
    else
        @test_broken got == want
        @test lvl == exp
    end
end

"""
    @test_level got want [name]

`check_level` for a comparison written in a test file, named by its line.
"""
macro test_level(got, want, name = "line_$(__source__.line)")
    file = string(__source__.file)
    return :(check_level($(esc(got)), $(esc(want)), $(esc(name)), $file))
end
