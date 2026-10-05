# What TermInput lacks that the Term clone had to work around, as tests.
#
#     julia --project=TermInput.jl TermClone/TermInput-TODO.jl
#
# Each testset is one gap: what is missing, the API that would fill it (a
# proposal - the tests pin the behaviour, the name is negotiable), and the
# workaround in TermClone to delete once it exists. Every test here is
# `@test_broken` against the proposed API, so the file runs clean today and
# reports an "Unexpected Pass" for each gap as it is filled: then flip that test
# to `@test` (or move it into TermInput's own suite), delete the workaround it
# names, and rerun TermClone's suite to see what moved.
#
# Ordered by how much clone code each one would remove.

using Test
using TermInput, Markdown
import TermInput: render, caret, handle!, Row, row, Box, BOXES, MarkdownStyle
import StyledStrings: Face, annotations

rows3 = [rowpad("one", 10), rowpad("two", 10), rowpad("three", 10)]
hasface(r::AbstractString, f::Face) = any(a -> a.label === :face && a.value == f, annotations(r))
quietly(f) = try f() catch; nothing end

@testset "TermInput gaps found by the Term clone" begin

# ----------------------------------------------------------------------------
# 1. A frame that is not the whole screen.
#
# `frame_bytes` writes rows at absolute lines 1..n and resets the scroll region
# (`\e[r`). Term draws a progress bar in a strip under output that keeps
# scrolling above it, and draws prompts and apps under the cursor, wherever that
# is. Neither can use `frame_bytes`: the first needs to start at a line and keep
# the scroll region it set, the second needs to draw relative to the cursor and
# rewrite in place on the next frame.
#
# Proposed: `frame_bytes(rows, title, cur; top = 1, region = :reset)` - rows
# written from line `top`, the scroll region left alone with `region = :keep` -
# and `frame_bytes(rows; inline = n)`, the frame drawn over the `n` lines the
# last inline frame took (cursor moved up `n`, not to a line number), leaving
# the cursor under it.
#
# Remove: `Term.Progress.region_write` (src/progress.jl) and
# `Term.LiveWidgets.InlineView` (src/Live/inline.jl).
@testset "1. frame_bytes from a line, or inline" begin
    s = quietly(() -> String(frame_bytes(rows3, "", nothing; top = 20, region = :keep)))
    @test_broken s !== nothing && occursin("\e[20H", s) && !occursin("\e[r", s)
    s = quietly(() -> String(frame_bytes(rows3; inline = 3)))
    @test_broken s !== nothing && occursin("\e[3A", s) && !occursin(r"\e\[\d+H", s)
end

# ----------------------------------------------------------------------------
# 2. Writing one row, public.
#
# `frame_bytes` writes a row with `writerow`, which handles verbatim pieces
# (writes them untouched and moves the cursor past their width). Anything that
# draws rows itself - (1) above, until it exists - has to re-implement that, or
# print rows with StyledStrings and lose verbatim pieces.
#
# Proposed: `writerow` in the `public` list.
#
# Remove: the per-row `print(IOContext(io, :color => true), row)` in
# `region_write` and `InlineView`.
@testset "2. writerow is public" begin
    @test_broken Base.ispublic(TermInput, :writerow)
end

# ----------------------------------------------------------------------------
# 3. A widget's natural height.
#
# `render(v, w, h)` always returns `h` rows with the box centred in them. Drawn
# inline (a prompt under the cursor) a widget wants exactly the rows it has, and
# the caret in those rows.
#
# Proposed: `render(v, w)` and `caret(v, w)` - the box alone, no centring - or
# `height(v, w)`, the `h` at which `render` adds no blank rows.
#
# Remove: `Term.LiveWidgets.widget_rows` (src/Live/inline.jl), which renders at
# h = 200, trims the blank rows and shifts the caret to match.
@testset "3. render at a widget's own height" begin
    li = LineInput("Name")
    rs = quietly(() -> render(li, 40))
    @test_broken rs !== nothing && !isempty(rs) && all(r -> !isempty(strip(r)), rs)
    @test_broken quietly(() -> caret(li, 40)) isa Tuple{Int,Int}
end

# ----------------------------------------------------------------------------
# 4. Titles with faces.
#
# A widget's `title` is a `String` field, so a styled question - Term's
# `Prompt("Gimme a {red}number{/red}")` - loses its colour. Its `note` already
# keeps faces (it is a `Row`).
#
# Proposed: `title::Row`, drawn as `faced(title, chrome.strong)` - under the
# faces it has, as `dialogbox`'s `head` already would.
#
# Remove: `Term.Prompts.prompt_title` (src/prompt.jl), which strips the markup.
@testset "4. a title keeps its faces" begin
    red = Face(foreground = :red)
    t = rowcat("Gimme a ", faced("number", red))
    li = LineInput(t)
    @test_broken any(r -> hasface(r, red), render(li, 60, 10))
    c = Choice(t, "", ["a", "b"])
    @test_broken any(r -> hasface(r, red), render(c, 60, 10))
end

# ----------------------------------------------------------------------------
# 5. A `Choice` that does not filter.
#
# Every printable key goes into a `Choice`'s query. A menu with no query line -
# Term's SimpleMenu, ButtonsMenu, MultiSelectMenu, a horizontal row of buttons -
# wants the movement keys and `↵` and nothing else, and its letters back as
# `:unhandled` for the host's own bindings (`q` to quit, space to toggle).
#
# Proposed: `Choice(...; filter = false)` - no query line drawn, printable keys
# `:unhandled` - and, for a menu laid out in a row, `Choice(...; horizontal =
# true)`, where ←/→ move the cursor.
#
# Remove: the key forwarding in `Term.LiveWidgets` menus (src/Live/menus.jl:
# only the arrows and ^p/^n are handed to the Choice) and its ←/→ remapping.
@testset "5. Choice without a query" begin
    c = quietly(() -> Choice("Pick", "", ["one", "two"]; filter = false))
    @test_broken c !== nothing && handle!(c, Int('q')) === :unhandled
    c = quietly(() -> Choice("Pick", "", ["one", "two"]; horizontal = true))
    @test_broken c !== nothing && (handle!(c, K_RIGHT); TermInput.selected(c) == 2)
end

# ----------------------------------------------------------------------------
# 6. A `Choice` that starts somewhere else.
#
# There is no way to put the cursor on an option but by assigning the internal
# field `sel`. Term's DefaultPrompt starts on the default answer, and a menu
# whose `active` index is set from outside moves it.
#
# Proposed: `Choice(...; selected = i)` and `select!(c, i)` (index into the
# labels, clamped; what `selected(c)` then answers).
#
# Remove: `c.sel = prompt.default` (src/prompt.jl) and the `active` setter
# writing `choice.sel` (src/Live/menus.jl).
@testset "6. Choice's initial cursor" begin
    c = quietly(() -> Choice("Again?", "", ["yes", "no"]; selected = 2))
    @test_broken c !== nothing && TermInput.selected(c) == 2
    c = Choice("Again?", "", ["yes", "no"])
    @test_broken quietly(() -> (TermInput.select!(c, 2); TermInput.selected(c))) == 2
end

# ----------------------------------------------------------------------------
# 7. The second cursor, public.
#
# `drawcursor` draws the block that marks where typing goes in a field that does
# not have the terminal's cursor. Term's InputBox is drawn inside a Term Panel,
# not by `render`, so it needs the block on its own rows - and re-implements the
# display-column-to-byte walk to place it.
#
# Proposed: `drawcursor` in the `public` list, beside `drawfield`.
#
# Remove: the cursor block in `Term.LiveWidgets.frame(::InputBox)`
# (src/Live/widgets.jl, the `overlaid(..., Face(inverse = true))` walk).
@testset "7. drawcursor is public" begin
    @test_broken Base.ispublic(TermInput, :drawcursor)
end

# ----------------------------------------------------------------------------
# 8. An `InputReader` that lets go mid-read -- DO NOT FIX in TermInput.jl
#
# `close(r)` while a read is pending marks the reader closed, but the read
# completes on the next key and that key is swallowed. A host that arms, then
# decides to stop (an app quit from a timer, a prompt cancelled by a signal)
# loses the user's next keystroke to it.
#
# Proposed: `close(r)` interrupts the pending read, and whatever it had read
# but not yet decoded stays readable from the stream.
#
# Remove: the "never re-arm after the quitting key" rule in `Term.LiveWidgets`'
# loop (src/Live/app.jl, src/Live/keyboard_input.jl), which is correct only for
# quits that come from a key.
@testset "8. close(::InputReader) while reading" begin
    p = Pipe()
    Base.link_pipe!(p)
    events = Channel{Any}(8)
    r = InputReader(p.out, events)
    arm!(r)
    sleep(0.1)
    close(r)
    write(p.in, "x")
    sleep(0.2)
    @test_broken bytesavailable(p.out) == 1
    close(p)
end

# ----------------------------------------------------------------------------
# 9. markdown_rows: what Term draws that it cannot be asked for.
#
# Each is a style option rather than new layout, so it stays one renderer.
#
#  a. A link's url. It draws the label only and leaves the url to the host;
#     Term shows `label (url)`. Proposed: `MarkdownStyle(url = face)`, the url
#     drawn after the label in that face when it is not `nothing`.
#     Remove: `with_urls` in src/markdown.jl, which rewrites the tree to put
#     the url in as inline HTML.
#  b. Unpadded rows. Every row is padded to `w`; Term's text is not, and a host
#     placing rows beside something else wants their own width. Proposed:
#     `markdown_rows(md, w; pad = false)`. Remove: `rstrip_row` in `md_rows`.
#  c. Highlighted code spans. Inline code is drawn in `code` alone; Term colours
#     it as Julia. Proposed: `MarkdownStyle(inlinecode = true)`, spans run
#     through `highlight` like a block. Remove: nothing yet - the clone leaves
#     them plain - but three markdown snapshots move.
#  d. Footnote references as `[id]`. Drawn as `[^id]`. Proposed: a
#     `footnote_ref` format (`"[^%s]"` by default). Remove: the `[^` rewrite in
#     `block_rows(::Markdown.Footnote)`.
#  e. A list marker of the host's. `• ` is fixed, no face, no per-level marker.
#     Proposed: `MarkdownStyle(bullets = ("• ", "◦ ", "▪ "), marker = face)`.
#     Remove: `block_rows(::Markdown.List)`, which lays lists out itself.
#  f. Table rules between every body row (only drawn where a cell wrapped), and
#     cell padding. Proposed: `MarkdownStyle(table_rows = :always, cellpad = 1)`.
@testset "9. markdown_rows options" begin
    md = md"see [the docs](https://example.org) now"
    rs = quietly(() -> markdown_rows(md, 60; style = MarkdownStyle(url = Face(weight = :light))))
    @test_broken rs !== nothing && any(r -> occursin("https://example.org", r.text), rs)
    rs = quietly(() -> markdown_rows(md"short", 40; pad = false))
    @test_broken rs !== nothing && rowwidth(only(rs).text) == 5
    st = MarkdownStyle(faces = Dict(:keyword => Face(weight = :bold)))
    rs = quietly(() -> markdown_rows(md"a `function f end` b", 40;
        style = MarkdownStyle(faces = st.faces, inlinecode = true)))
    @test_broken rs !== nothing && hasface(only(rs).text, Face(weight = :bold))
    rs = markdown_rows(md"a[^1] b", 40)
    @test_broken !occursin("[^1]", rs[1].text)
    rs = quietly(() -> markdown_rows(md"* a\n* b", 40; style = MarkdownStyle(bullets = ("- ",))))
    @test_broken rs !== nothing && startswith(rs[1].text, "- a")
end

# ----------------------------------------------------------------------------
# 10. highlight's ranges, as string ranges.
#
# `highlight(lang, code)` answers ranges ending at the last *byte* of the last
# character, so `code[r]` throws over a multibyte character (`×`, `é`). Either
# answer `first:thisind(code, last)` ranges, or say "byte ranges, index with
# `codeunits`" in the docstring.
#
# Remove: the `codeunits(code)[r]` indexing in src/highlight.jl.
@testset "10. highlight ranges are valid string ranges" begin
    code = "f(x) = x × \"é\""
    rs = TermInput.highlight("julia", code)
    @test_broken all(((r, _),) -> isvalid(code, last(r)), rs)
end

# ----------------------------------------------------------------------------
# 11. Boxes with a footer, and more of them.
#
# `Box` has six lines; Term's has eight - a rule above a footer and the footer
# line - and Term's tables use both. `BOXES` has five; Term names eighteen, and
# its tables default to `MINIMAL_HEAVY_HEAD` but are often `SIMPLE`/`MINIMAL`.
#
# Proposed: `foot_row` and `foot` fields (defaulting to `row` and `mid`), and
# the rest of Term's names in `BOXES` (ASCII, ASCII2, ASCII_DOUBLE_HEAD,
# SQUARE_DOUBLE_HEAD, MINIMAL, MINIMAL_DOUBLE_HEAD, SIMPLE, SIMPLE_HEAD,
# SIMPLE_HEAVY, HORIZONTALS, HEAVY_EDGE, HEAVY_HEAD, DOUBLE_EDGE).
#
# Remove: `Term.Boxes.tibox` (src/boxes.jl) and Term's own box table there.
@testset "11. Box footer lines and Term's box names" begin
    @test_broken hasfield(Box, :foot_row) && hasfield(Box, :foot)
    @test_broken all(n -> haskey(BOXES, n), (:SIMPLE, :MINIMAL, :ASCII, :HEAVY_HEAD, :DOUBLE_EDGE))
end

# ----------------------------------------------------------------------------
# 12. Table layout outside markdown.
#
# `markdown_rows` lays out a table - column widths fitted to `w`, wrapped
# cells, a box - but only from a `Markdown.Table` of inline markdown. Term's
# `Table` is cells of rows (or of other renderables: panels in a table), with a
# header, a footer, per-column justification, padding and widths.
#
# Proposed: `tablerows(cells::Matrix, w; header, footer, widths, justify, pad,
# box)` - the layout `markdown_rows` already has, over rows - and
# `markdown_rows` drawing its tables with it.
#
# Remove: most of src/tables.jl and src/_tables.jl (column sizing, cell
# padding, box rules).
@testset "12. tablerows" begin
    @test_broken isdefined(TermInput, :tablerows)
end

# ----------------------------------------------------------------------------
# 13. Small row helpers.
#
#  a. Elision with a mark of the host's: `rowfit` ends in `…`; Term's
#     `str_trunc` in `...`, and cuts at a word. Proposed: `rowfit(s, w; mark =
#     "…", word = false)`. Remove: `trunc_row` (src/tables.jl), and the `…`/`...`
#     difference behind most `text`-level snapshot mismatches of cut titles.
#  b. Trailing blanks off: `rowrstrip(s)`. Remove: `rstrip_row`
#     (src/text_reshape.jl).
#  c. Rows padded to a height: `rowvpad(rows, w, h, :top|:center|:bottom)`.
#     Remove: `vertical_pad_rows` (src/tables.jl).
@testset "13. row helpers" begin
    @test_broken quietly(() -> rowfit("abcdefgh", 6; mark = "...")) == "abc..."
    @test_broken quietly(() -> rowfit("ab cdefgh", 7; word = true)) == "ab…"
    @test_broken quietly(() -> TermInput.rowrstrip(row("ab  "))) == "ab"
    @test_broken quietly(() -> length(TermInput.rowvpad([row("a")], 1, 3, :center))) == 3
end

end

# Not TermInput's to fill, for the record: StyledStrings faces have no conceal
# and no blink, and one weight (so `bold dim` is bold); and what StyledStrings
# writes depends on the terminfo of the process (italic, dim, reverse,
# strikethrough) and on COLORTERM (24-bit colour). Term's `hidden` panels,
# `bold dim` dendograms and blinking text come out differently for that reason.
