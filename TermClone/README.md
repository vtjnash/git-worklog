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
`test/__cells.jl`) is graded, by a terminal emulator there that reads both
strings into cells:

| level    | meaning | |
|---|---|---|
| `bytes`  | the bytes Term wrote | pass |
| `cells`  | the same terminal cells: same picture, different escapes | pass |
| `reflow` | the same styled text, broken into lines at other places, or cut with `…` where Term cuts with `...` | pass |
| `text`   | the same text, drawn differently | broken |
| `none`   | different text: a different layout | broken |

`reflow` is TermInput's wrapping and elision, which are equivalent to Term's or
better. It is strict about everything else: the same characters in the same
faces in the same order once blanks and box lines are set aside; the same box
characters in the same faces (more or fewer of them, never another kind, or one
drawn where Term conceals it); and any line that says what one of Term's lines
says drawn exactly as Term draws it - but for the one blank Term's wrap leaves
at the start of a line, and the blanks before a cut. So a line that did not
move is never let off, and an alignment or width bug is not a reflow.

Bold and dim at once is read as bold on both sides: a face has one weight,
and terminals draw the pair as one or the other. Term's output is compared as
it is drawn: where it returns its markup still
unapplied, or its braces escaped (`{{`), they are applied and unescaped first,
as printing it does. And where Term's own output on this Julia differs from its
snapshot, `test/txtfiles-1.14/` holds it - written by the real Term's suite in
debug mode - and the better of the two is the level. Those are the 47
snapshots that `Dict` order and `subtypes` order decide on this Julia.

`test/expected/<file>.toml` lists every snapshot that is not `bytes` and the
level it is at, so a snapshot that gets *better or worse* fails; the broken
levels are `@test_broken` on the bytes besides. Run with `TERM_RECORD=1` to
rewrite the manifests from what was observed (review the diff),
`TERM_DUMP=dir` to keep both sides of every mismatch, and `TERM_TESTS=08,09`
to run some files.

    cd TermClone/test && julia --project=. runtests.jl

## Where it stands

All 28 of Term's test files run: **2741 pass, 40 `@test_broken`, 0 fail**
(Julia 1.14 nightly, TermInput at `0187294`). Of the snapshots that are not
Term's bytes, 466 are the same cells and 194 a reflow of them, which pass; 8
are the same text drawn differently and 32 a different layout, which do not
(`julia test/levels.jl` prints the table per file). For scale: the real Term
fails on this Julia too, from `10_test_introspection` on.

What is left broken, by cause - each a place where Term and the clone draw
something differently on purpose, or where Term's output is its own bug:

* **Term's colour restoration** (17): `{red}a{green}b{blue}c{/green}d{/blue}`
  - Term reopens red at `{/green}`, where tags are a stack here and `d` is
  still blue; and a colour applied as escapes rather than markup (a
  `RenderableText`'s `style`) is lost after the first tag inside it closes,
  where here it stays.
* **The tree's indentation past the edge** (8): a key wider than the tree puts
  its children's indent past the console's edge. Both cut it; Term breaks it at
  a space five columns short of the edge, as its wrap breaks prose, and the
  clone cuts it at the edge as it cuts any laid-out line, so the children
  start five columns further left.
* **A page of wrapped text** (6, the pager): the text wrapped at other places
  is more or fewer lines, so the page the test turns to is another slice of
  it. Each page is a reflow of Term's, but no one page is the same text.
* **Byte slices** (4): highlight tests that compare the first 100 bytes of
  Term's escapes, which only the same spelling can match.
* **Unbalanced braces in code** (3): `{}}, Tuple{{}}` - Term escapes the lone
  `{` and the clone keeps it; printed, the braces come out differently.
* **One each** of a table (`mts_repr`, cells cut and padded to other widths)
  and markdown (`markdown_3`, list spacing).

## Known differences, by cause

Every way the clone's output differs from Term's - the ones that pass as
equivalent (`cells`, `reflow`) as well as the ones above that do not.

* **Escape spelling** (`cells`): StyledStrings writes the minimal transition,
  `\e[38;2;…m` for a 256-colour Term names (`dodger_blue2`), and no reset
  junk. Term's own literal-escape tests cannot pass; their pictures do.
* **Wrapping** (`reflow`): TermInput's `rowwrap` breaks at the last space
  that fits and drops it. Term's `reshape_text` breaks at a space only within
  five columns of the edge, mid-word otherwise, and keeps a leading space on
  the next line (and overflows CJK: 17 wide characters in a 33-column wrap).
  Every snapshot of wrapped prose differs in its line breaks. A renderable that
  is too wide is cut with `rowwrap(...; hard = true)`, which is Term's result.
* **Elision** (`reflow`): `rowfit` ends a cut in `…`; Term's `str_trunc` in `...`, which
  only a table's cells are cut with here.
* **Lists**: no blank row after a list inside another, and a list inside a
  numbered item one column further in than Term's.
* **Faces Term has and StyledStrings does not**: no `blink`, and one weight,
  so `bold dim` is bold - which is what most terminals draw for the pair, so
  the cells compare it as bold. No conceal either: concealed text carries a
  `:conceal` annotation instead, which `Style.ansi` writes as `\e[8m`, so a
  `hidden` border is concealed as Term's is and still in the text.
* **Terminfo**: StyledStrings writes italic, dim, strikethrough and reverse
  only where the terminal's terminfo has them, and 24-bit colour only where
  `COLORTERM` says so. The suite sets `TERM=xterm-256color` and
  `COLORTERM=truecolor`, as Term assumes.
* **Crossing tags**: `{red}a{green}b{blue}c{/green}d{/blue}e{/red}` - Term
  reopens red at `{/green}`; here tags are a stack, and `d` is still blue.
* **`reshape_text` returns escapes**, not markup: rows have no way back to
  markup, and nothing needs one. Term's markdown returns some markup unapplied.
* **Dict order**: trees and tables of `Dict`s list keys in 1.14's order, not
  the order Term's snapshots were taken in - as the real Term does on 1.14,
  whose output (`test/txtfiles-1.14/`) they are graded against too.

## What this found about TermInput

What carried the clone: rows as `AbstractString`s go anywhere Term takes a
string; `faced` (under) and `overlaid` (over) are exactly Term's two ways of
styling a span; `rowcat` merges faces, so output is smaller than Term's;
`rowfit`/`rowwrap(hard)`/`pad_row` replaced every escape-aware string helper;
`highlight`'s `MIME` extension point let Term's code colours be added beside
Julia's; `handle!` taking key codes made `InputBox` a `TextArea` in a line per
key; `Choice`'s cursor and `picked` served all three menus; `listwindow`/
`listmove` replaced the pager's arithmetic; `readevent`/`enter_terminal` on an
`IOBuffer` let every prompt and app be driven headless; `frame_bytes`' `top`
and `inline` draw the progress strip and every prompt and app; `tablerows`
lays out a `Table`, and `markdown_rows`' style draws Term's urls, footnotes,
bullets and code spans. No TermInput bugs turned up.

What TermInput still lacks is in `TermInput-TODO.jl`, as tests.

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
