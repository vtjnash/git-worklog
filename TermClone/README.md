# Term, on TermInput

An API-compatible clone of [Term.jl](https://github.com/FedeClaudi/Term.jl) 2.2
whose renderables are [TermInput](../TermInput.jl) rows, as a test of what
TermInput can carry. The package is named `Term` (with its own UUID), so
`using Term` and Term's own test suite run against it unchanged.

Term's tests, copied into `test/`, are the acceptance criteria: each one passes,
or is `@test_broken` with the reason it cannot pass written beside it.

## The model

Term keeps every line of every renderable as a `String` with ANSI escapes in it,
and every operation - padding, wrapping, stacking, boxing - edits those strings
and re-measures them by stripping the escapes again.

Here a line is a `TermInput.Row`: an `AnnotatedString` with StyledStrings faces
over ranges of it. So:

* **In:** `Style.torow` reads Term's markup (`{bold red}...{/bold red}`) *and*
  ANSI escapes (SGR and OSC 8 links) into faces, once, where a string enters.
* **Through:** a `Segment` is a row and its measure; a renderable is segments.
  Measuring is `rowwidth`, cutting `rowfit`/`rowhead`, padding `rowpad`/
  `pad_row`, wrapping `rowwrap`, joining `rowcat`, styling `faced`/`overlaid`,
  links `linked` - TermInput's row functions throughout. Nothing re-parses a
  row, so a panel inside a panel inside a table costs nothing to measure.
* **Out:** `seg.text`, `string(renderable)` and `apply_style` write the row as
  StyledStrings writes it (`Style.ansi`), which is the only place escapes exist.

The interactive half is TermInput's widgets: prompts and `InputBox` are
`LineInput`/`TextArea`, menus are `Choice`, yes/no is `Confirm`, the pager
scrolls with `listwindow`, and the keys come from `readevent`.

## Reading the test results

Term's snapshots are its exact bytes, and StyledStrings spells the same picture
differently (it writes only what changes between faces; Term closes and reopens
every colour). So each snapshot comparison (`check_level` in
`test/__cells.jl`) is graded:

| level   | meaning |
|---|---|
| `bytes` | the bytes Term wrote |
| `cells` | the same terminal cells: same picture, different escapes |
| `text`  | the same text, drawn differently |
| `none`  | different text: a different layout |

A terminal emulator in `__cells.jl` reads both strings into cells to decide.
`test/expected/<file>.toml` lists every snapshot that is not `bytes` and the
level it is at; the comparison is then `@test_broken` on the bytes and `@test`
on that level, so a snapshot that gets *better or worse* fails. Run with
`TERM_RECORD=1` to rewrite the manifests from what was observed (review the
diff), `TERM_DUMP=dir` to keep both sides of every mismatch, and
`TERM_TESTS=08,09` to run some files.

    cd TermClone/test && julia --project=. runtests.jl

## Where it stands

All 28 of Term's test files run: **2741 pass, 702 `@test_broken`, 0 fail**
(Julia 1.14 nightly). Of the snapshots that are not Term's bytes, 337 are the
same terminal cells, 104 the same text, and 258 a different layout
(`julia test/levels.jl` prints the table per file). For scale: the real Term
fails on this Julia too, from `10_test_introspection` on (subtype order).

## Known differences, by cause

These are what the broken tests come down to.

* **Escape spelling** (`cells`): StyledStrings writes the minimal transition,
  `\e[38;2;…m` for a 256-colour Term names (`dodger_blue2`), and no reset
  junk. Term's own literal-escape tests cannot pass; their pictures do.
* **Wrapping** (most `none`): TermInput's `rowwrap` breaks at the last space
  that fits and drops it. Term's `reshape_text` breaks at a space only within
  five columns of the edge, mid-word otherwise, and keeps a leading space on
  the next line (and overflows CJK: 17 wide characters in a 33-column wrap).
  Every snapshot of wrapped prose differs in its line breaks. A renderable that
  is too wide is cut with `rowwrap(...; hard = true)`, which is Term's result.
* **Elision**: `rowfit` ends a cut in `…`; Term's `str_trunc` in `...`.
* **Faces Term has and StyledStrings does not** (most `text`): no `hidden`
  (conceal) and no `blink`; one weight, so `bold dim` is bold. A `hidden`
  panel border is drawn. (A tree's `hidden` pair mark is drawn as blanks.)
* **Terminfo**: StyledStrings writes italic, dim, strikethrough and reverse
  only where the terminal's terminfo has them, and 24-bit colour only where
  `COLORTERM` says so. The suite sets `TERM=xterm-256color` and
  `COLORTERM=truecolor`, as Term assumes.
* **Crossing tags**: `{red}a{green}b{blue}c{/green}d{/blue}e{/red}` - Term
  reopens red at `{/green}`; here tags are a stack, and `d` is still blue.
* **`reshape_text` returns escapes**, not markup: rows have no way back to
  markup, and nothing needs one. Term's markdown returns some markup unapplied.
* **Dict order**: trees and tables of `Dict`s list keys in 1.14's order, not
  the order Term's snapshots were taken in; fed Term's order they are `cells`.

## What this found about TermInput

What carried the clone: rows as `AbstractString`s go anywhere Term takes a
string; `faced` (under) and `overlaid` (over) are exactly Term's two ways of
styling a span; `rowcat` merges faces, so output is smaller than Term's;
`rowfit`/`rowwrap(hard)`/`pad_row` replaced every escape-aware string helper;
`highlight`'s `MIME` extension point let Term's code colours be added beside
Julia's; `handle!` taking key codes made `InputBox` a `TextArea` in a line per
key; `Choice`'s cursor and `picked` served all three menus; `listwindow`/
`listmove` replaced the pager's arithmetic; `readevent`/`enter_terminal` on an
`IOBuffer` let every prompt and app be driven headless. No TermInput bugs
turned up.

The gaps it found, each now filled in TermInput and the workaround gone (see
`TermInput-TODO.jl`, which keeps the one left):

* **Inline drawing.** `frame_bytes(rows; top, region = :keep)` draws the
  progress bar's strip under scrolling output, and `frame_bytes(rows; inline
  = n)` a prompt or an app under the cursor (`LiveWidgets.InlineView` only
  remembers `n`). `writerow` is public.
* **Natural height.** `render(v, w)` and `caret(v, w)` are a widget at its own
  height, for drawing inline.
* **Titles are rows**, so a prompt's styled question keeps its faces.
* **`Choice(...; filter = false, horizontal, selected)`** is a menu's cursor:
  no query, its letters the menu's, `←`/`→` in a row, a default to start on,
  and `select!` for `active`.
* **`drawcursor` is public**, so `InputBox` draws its blinking block with it.
* **`markdown_rows`** takes a style's `url` face, `footnote_ref` (`[id]`),
  `inlinecode` highlighting, `bullets`/`numbers` and their faces, and `pad =
  false`. What Term draws round blocks - panels, the quote's bar - is still
  composed here.
* **`highlight`'s ranges** are string ranges.
* **Boxes and tables.** `Box` has Term's eight lines and `BOXES` Term's
  eighteen boxes, which `Boxes.BOXES` is; `tablerows` lays a `Table` out, and
  what is left in `src/tables.jl` is Term's sizing, its arguments, its cells'
  `...` and which rules it draws.
* **Row helpers**: `rowfit(s, w; mark = "...", word = true)` is `str_trunc`,
  and `rowrstrip` and `rowvpad` are TermInput's.

Left: **`InputReader` cannot be cancelled mid-read**, which is meant to stay
so. Lists differ from Term's in two small ways TermInput's options do not
reach: no blank row after a list inside another, and a list inside a numbered
item one column further in.

## Layout

    src/style.jl         markup and ANSI read into rows, rows written as ANSI
    src/segments.jl      a Segment: a row and its measure
    src/renderables.jl   AbstractRenderable, Renderable, RenderableText
    src/text_reshape.jl  wrapping and justifying rows
    src/boxes.jl         Term's `Box`, its lines TermInput's, and `BOXES` from TermInput's
    src/layout.jl        pad, stack, align, lines, placeholders
    src/panels.jl        Panel and TextBox
    src/text_utils.jl    Term's plain-string helpers for its markup language
    test/__cells.jl      the terminal-cell comparison and the manifests

Term's plain-string helpers (`remove_markup`, `textlen`, `str_trunc`, …) and its
data tables (colour names, themes) are Term's own code, under Term's MIT
licence in `LICENSE.Term`.
