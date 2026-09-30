# Plan: rows of faces, and a pane's rows verbatim

What `wl` draws becomes StyledStrings text - faces over ranges - from the theme
to the frame, and the escape-string layer under it goes: the `_off` closers,
`rearm`, `hlrow`, `hlspan`, and TermInput's `awidth`/`afit`/`apad`/`awrap`/
`astrip` and friends. A hosted pane's rows are the one thing that stays
escapes, and they go to the terminal exactly as tmux gave them, never measured,
cut or re-styled on the way. Written 2026-09-30, against `wl` at `3481e03`,
TermInput at `82e5448` and TermIFrame at `f35e8ac`. Check items off as they
land; each is marked with the repository it is in.

## Why

Markdown already went this way (TermInput `82e5448`, `wl` `3481e03`): a
`MarkdownStyle` is `Face`s, merged where they nest, and StyledStrings writes
the row. Everything else `wl` draws is still escape strings, and that is two
models of one screen:

| by hand now | why it exists | with faces |
|---|---|---|
| every `<role>_off` field in `Theme` | a colour has to be ended without ending what is under it | gone: a face ends only what it began |
| `rearm`, `hlrow`, `hlspan` (`layout.jl`, `theme.jl`) | a highlight laid over a row stops at the row's first reset | a face annotated over the range, merged on top |
| `awidth`, `astrip` | `textwidth` counts escapes as characters | `textwidth` of the text |
| `afit`, `apad`, `ahead`, `atail`, `amid`, `awrap` | cutting a string of escapes has to replay what was open | slicing an annotated string keeps its annotations |
| `parse_style` and the `ATTRS` codes | the theme's words as escapes | `parse_face`, which exists |
| two ways to write `on 236` | markdown is 24-bit under truecolor, a role is the index | one |

About 110 calls to the measuring helpers in 11 files of `wl`, and TermInput's
widgets and `CHROME` on top.

433e375 wrote down why this waited, and three of its four reasons are gone: a
comment body is TermInput's markdown, not Term's escapes; a diff is coloured
by `wl` from the theme, not by git; and RGB for 236 is the colour wanted,
drawn as the index again where the terminal has no truecolor. The fourth is
the hosted pane, and the answer to it is not to parse it.

## A pane's rows are verbatim

`capture-pane -e` is the only way to have a pane's screen with its colours,
and what it gives is tmux's own escapes, SGR carried from row to row and OSC 8
from 3.4. No parser turns those into faces - StyledStrings has none, on any
version - and none is wanted: tmux owns decoding the child's output, and a
round trip through `Face` would lose what a `Face` cannot say (blink,
overline, hidden, a palette index past 15). So a pane's row is a piece of a
row that nothing on this side looks inside:

- **It is annotated, not parsed.** A row is an `AnnotatedString`; a pane's row
  inside it is its text as tmux gave it, carrying one annotation,
  `:verbatim => w`, where `w` is the pane's width in columns. Nothing else
  annotates that range.
- **Its width is the pane's, not measured.** `iframe_sync!` has already
  resized the pane to its box (`mux_resize`), so tmux has made each row fit;
  checking it again is not this side's job. A row shorter than `w` is not
  padded either - see the frame writer below.
- **It ends with `\e[0m`,** outside it, as `iframe_sync!` already does: tmux
  leaves a colour open from one row into the next (a background set on one
  row came back as `\e[49m` at the start of the next, measured on 3.5a), and
  a row read alone has to be closed.
- **It is written by the frame writer as it is.** `frame_bytes` already
  deletes every row's line before writing it (`\e[M`), so the row starts
  blank; after a verbatim piece it moves the cursor to the column after its
  `w` (`\e[<col>G`), and what follows - the border, the list beside it - is
  written from there. Nothing measures the piece to find where it ended.

`capture-pane -N` does not make the rows `w` wide: it keeps trailing spaces
only up to the last cell written (7 and 30 columns, in a 30-column pane, on
3.5a). That is why the cursor is moved rather than the row padded.

## Now: auto-wrap off while a frame is written

Independent of the rest, and worth doing first. A row wider than the screen -
a pane row in the frame between a resize and tmux catching up, or any row a
measure got wrong - wraps onto the next line and pushes the frame down. With
DECAWM off (`\e[?7l`) a terminal writes the extra over the last column and
the frame stays where it is; `frame_bytes` turns it back on (`\e[?7h`) at the
end of the frame, so a program run under `suspend` sees the terminal as it
was. It also ends the pending-wrap question `frame_bytes`' docstring
describes, since with wrap off there is no pending wrap to disagree about;
the scroll-region move stays, for the delete.

## Copy mode's selection, without `-M`

`paint_selection!` draws copy mode's selection by rewriting the escapes of a
pane's rows (`reverse_cells`), because `capture-pane` reads the pane's grid
and not the mode's screen. tmux 3.6 added `capture-pane -M` to read the mode's
screen, selection drawn; tmux_jll is 3.5a, and this plan does not wait for it.

So the selection stays as it is: TermIFrame paints it into the rows *before*
they become verbatim pieces, in `iframe_sync!`, the one place that has ever
edited them. It is TermIFrame's own code - an escape walk over `ESCAPE` and
`textwidth`, none of the helpers this plan removes - and when tmux_jll reaches
3.6 it is replaced by `-M` and deleted. What "verbatim" promises is that
nothing *after* TermIFrame alters a row, which holds either way.

The two places that read a pane's text - `dead_screen` finding blank rows, and
`copy_goto` counting characters - read, not write. They strip escapes with
`ESCAPE` inside TermIFrame, which is where `ESCAPE` moves (step 7).

## Shape

- **A row is an `AnnotatedString{String}`,** faces as `:face` annotations,
  links as `:link`, a pane's row as `:verbatim`. `wl`'s rows are built by
  concatenation, and `*`/`annotatedstring` keep annotations, so the call
  sites change their arguments more than their shape.
- **The theme is faces.** `Theme`'s fields become `Face`s and the `_off`
  fields go. `THEME.reset` goes with them: nothing has to be reset when a
  face ends only what it began.
- **`CHROME` is faces:** `strong`, `quiet`, `focus` - and `reset` goes.
- **Width is `textwidth`, except over `:verbatim`,** which is its `w`. One
  function in TermInput, `rowwidth`, says so, and the fitting and wrapping
  functions use it and never split a verbatim range: a row cut through a pane
  is cut before or after it.
- **No theme is still no escape at all.** An empty theme is empty faces, and
  an empty face writes nothing; the suite's "no theme is no colour at all"
  tests keep asserting it, unchanged.
- **The theme decides colour, not the stream.** StyledStrings writes escapes
  only to an `IOContext` with `:color => true`, where `wl` today writes the
  theme's escapes wherever it prints. Every print of styled text - the frame,
  and the few lines printed outside it (`ui.jl`'s url list, the controller's
  "this view could not be drawn") - says `:color => true` itself, so a theme
  still colours `wl` piped into `less -R`, and `theme = ""` still does not.
- **The frame is written from annotated rows.** `frame_bytes` takes rows,
  prints each with StyledStrings (`IOContext(io, :color => true)`), and a
  verbatim range as its text followed by the cursor move. The host joining
  rows with `"\n"` and the writer splitting them again goes.

## Steps

- [x] 0. **(TermInput)** Auto-wrap off while `frame_bytes` writes, on again
      at the end, and the docstring's pending-wrap paragraph rewritten for
      it. Test: a row wider than `w` leaves the next row where it was.
- [x] 1. **(TermInput)** `rowwidth`, and the fitting helpers for
      `AnnotatedString` - fit, pad, head, tail, middle, wrap - that keep
      annotations and never split a `:verbatim` range; grapheme-whole, as
      `wraprun` is. `markdown_rows`' `wraprun` becomes one of their callers,
      not a copy of them. Tests beside the escape-string ones they replace.
- [x] 2. **(TermInput)** `frame_bytes` takes `Vector{AnnotatedString}` and
      writes a verbatim range as above; the `String` method stays until the
      host has moved, then goes.
- [x] 3. **(TermInput)** `CHROME` as faces, and the widgets - `dialogbox`,
      the text area, the line input, the picker - drawing annotated rows. The
      composer's cursor stays reverse video whatever a theme says; it becomes
      `Face(inverse = true)`.
- [x] 4. **(TermIFrame)** `iframe_rows` and `bordered` produce annotated
      rows, a pane's row as a `:verbatim` piece of the pane's width, the
      selection still painted before it is (see above). `bordered` stops
      measuring its lines: a line is verbatim or it is an annotated string,
      and an annotated one is fitted with step 1's helpers.
- [x] 5. **(worklog)** `Theme` as faces from `parse_face`; `parse_style`,
      `ATTRS`, `sgr`, the `_off` fields and `reset`/`no_bg` go. `rearm`,
      `hlrow`, `hlspan` become a face annotated over a range. DESIGN.md's
      "A colour is a role, never an escape" paragraph loses its `_off`
      sentence, and the shipped themes' header comment ("There is no entry
      for the resets...") says what is true of faces instead.
- [x] 6. **(worklog)** Every row builder to annotated strings, file by file,
      the measuring calls to step 1's. `render` returns rows, not a joined
      string. Suite green after each file.
- [ ] 7. **(TermInput)** The escape-string helpers go - `awidth`, `afit`,
      `apad`, `ahead`, `atail`, `amid`, `awrap`, `awraplines`, `astrip` - with
      their tests and their README section, and `ESCAPE` moves to TermIFrame,
      the one package still reading escapes.

Each step that changes a package's API - `frame_bytes`, `CHROME`,
`bordered`, `iframe_rows` - changes that package's README in the same
commit. After steps 5-7, `julia --project=cli/precompile cli/test/aqua.jl`
too, since the precompile workload draws frames.
- [ ] 8. **(TermIFrame, later)** When tmux_jll is 3.6 or newer: copy mode's
      screen by `capture-pane -M`, and `paint_selection!`/`reverse_cells` go.

Steps 0 and 1 stand alone. 2-4 can land before 5-6, with `wl` rendering
annotated rows to strings at the frame until 6 is done.

## Decided

- **A pane is not parsed.** Its rows go to the terminal as tmux gave them.
- **No `-M` for now.** The selection is painted where it is today.
- **No width check on a pane's rows.** tmux sized them; auto-wrap off is
  the guard for the frame in which it has not caught up.
- **1.10 stays.** StyledStrings is the registered package there, the stdlib
  from 1.11.
- **1.11 draws bold and dim run together, and that is accepted.** Before
  1.12 StyledStrings writes dim straight over bold (`\e[1m` then `\e[2m`, no
  `\e[22m`), which a terminal draws as both; with every row going through it,
  that is a focused box's title beside its border and a bold row beside a
  quiet one, not just a backtick in bold. `wl` stays on 1.11 with it, no
  workaround is written, and `wl`'s README says so where it names 1.11. A
  test that pins a weight change is `broken = VERSION < v"1.12"`, as
  TermInput's markdown one is.

## For the agent doing this

- Read DESIGN.md first; `wl` and TermInput have their own commit styles
  (`worklog: summary` here, a lowercase sentence in the packages).
- TermInput and TermIFrame never mention `wl`, in code, docs or commits.
- `julia --project=cli cli/test/runtests.jl` is `wl`'s suite;
  `Pkg.test()` in each package is theirs. Run TermInput's on 1.10 as well
  as the default: the `AnnotatedString` constructor differs there (a
  `faced` helper in `src/markdown.jl` already hides it).
- StyledStrings consults terminfo for italic and strikethrough and the
  environment for truecolor, so a test compares against what a face
  writes, not a spelled-out escape (`faceesc` in `cli/test/runtests.jl`).
- A face's `inherit` is looked up in StyledStrings' global table; leave it
  empty.
- `--trim` (TRIM.md): measure StyledStrings' printing under it before
  step 6 makes every row depend on it.

## Not doing

- Parsing a pane's escapes into faces, in any form.
- `capture-pane -M` before tmux_jll has it.
- Re-checking a pane row's width against the pane.
