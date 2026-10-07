# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next quick issues

Nothing now.

## Bigger tasks

- [ ] **A preview of the session under the cursor in `"`.** Once the cursor
      rests on a row (the pane's `LOAD_AFTER` dwell), `capture-pane -e` its
      session down the command pipe (about 0.1 ms) and draw the screen beside
      the list where there are 150 columns, the split `t`/`T` use, and its
      bottom rows under the list where there are not. The agent's session
      when the row has one, else the shell's; `tab` is the modes', so a key
      of its own if the other is wanted. Colours and links come through
      `capture-pane -e` as the hosted pane's do (`iframe_sync!`).
- [ ] Is it worthwhile to prefix keys with numbers for repeating (e.g. 6j for down 6), for kjnN? But we might want numbers for other hotkeys.
- [ ] **Copy mode's screen from tmux.** `capture-pane -M` (tmux 3.6, and
      tmux_jll is 3.7c now) reads copy mode's screen, selection drawn, where
      TermIFrame paints the selection itself, rewriting the escapes of a
      pane's rows in `paint_selection!`/`reverse_cells` - the one place
      anything edits them. With `-M`, both go, and a pane's rows are tmux's
      from end to end.
- [ ] try rewriting the Term API on top of TermInput now, just to see if it is possible
- [ ] **Other languages' code blocks, through Highlights as a TermInput
      extension.** Highlights 0.6.3 no longer imports Pkg
      (JuliaDocs/Highlights.jl#103). The extension would use only
      `highlight_tokens(grammar_jll, code)`: its byte ranges and tree-sitter
      captures are already what `highlight` answers. Highlights' themes and
      formatters stay unused, so it does not need StyledStrings first. To
      settle, and TermInput's premises may change for them:
      - The hook. One method per `MIME` cannot be both the extension's and a
        host's, and a catch-all overwrites the stub. Perhaps a language
        becomes a value looked up in a table of highlighters, rather than a
        type.
      - The grammar. Use one only if the host has already loaded it, never
        Highlights' `resolve_language`, which `Base.require`s by name at run
        time.
      - The faces. Map captures to the face names JuliaSyntaxHighlighting
        uses (`function.call` to `funcall`), falling back by prefix, so one
        `[code]` table colours every language.
      - Whether wl loads it is a separate decision. Measured 2026-10-02 with
        `latency.jl`: `import Highlights` in `Worklog` (bringing TreeSitter,
        tree_sitter_jll, AbstractTrees and CEnum; JSON is already ours) moved
        the wrapper's load from 0.79s to 0.81s and the first thread from
        1.13s to 1.17s. That is with no grammar loaded and nothing
        highlighted; a grammar and its first query are still to measure, and
        so is whether TreeSitter trims.
      - Upstream, separately: Highlights could answer an `AnnotatedString` of
        capture-named faces, as JuliaSyntaxHighlighting does. Then the
        extension would just read annotations, like `TermInputHighlightExt`.

## Unverified

- [ ] **A pane whose child exited, in a real terminal.** The suite drives it
      against the bundled tmux with `echo` for a child, no terminal and no
      `claude`. By hand:
      - MANUAL.md 16 again, as it now reads: exit `claude` in a `T` pane, and
        `exit` in a `t` shell. The screen stays, the footer says `exited
        with status 0 · q clears it` within about a second, `q` closes it.
      - `T`, `^]q`, and have the agent exit while the list is on screen
        (`kill` it from a shell): within about a second the item pane says
        `agent  exited` under `running`, and `"` shows its `T` on the badge
        with `exited` on a line under the worktree. The row is not unread
        for it, and `e` on it changes none of that. `T` shows what it said
        last; `q` closes it, and `T` again asks for a prompt and starts
        another.
      - On a wide screen, `T` on an item whose agent is `waiting on you`:
        within about a second of the pane opening, the thread beside it says
        `agent` with no `waiting on you`, with nothing pressed. And from
        `"`: `T` on a row whose badge is lit, `q` back out - the badge is
        off, and after `q` in an `exited` pane its line is gone, without `r`
        (2026-10-07; both stood until the next `T` or `r`).
      - `exit` in a `t` shell and `^]q` at once, before the footer has said
        `exited`: the session is gone - no `exited` under `running`, no badge
        in `"` - and `t` starts a fresh one (2026-10-07; it stood, and took
        a second `t` and `q`).

## Trim

`juliac --trim=safe` over `wl`: the plan, the counts and how to reproduce
them are in `TRIM.md`, under "The plan". What it needs from Julia itself is
under *Upstream* here.

## Upstream

- [ ] **File: `@nospecialize` on an argument with a default does nothing.**
      `f(a, @nospecialize(b) = nothing) = b` gives both of `f`'s methods a
      `nospecialize` mask of `0` - on 1.12.6, 1.13.0 and the 1.14 nightly -
      where `h(@nospecialize(a), @nospecialize(b) = nothing)` gets `1` on
      both: the argument with the default is dropped, silently. The form in
      the body, `@nospecialize b`, does mark it. Check for an existing issue
      first; then `thread_facts!` and `carry_mention!` (`refresh.jl`) can go
      back to one method each.
- [ ] **Running a subprocess does not trim.** `read(`echo hi`, String)`
      alone is 30 errors on 1.13 and 44 on 1.14, all in `process.jl`
      (`setup_stdios`, `close_stdio`, `rawhandle`, the `cancel` keyword).
      Everything `wl` does goes through `gh`, `git` or `tmux`, so nothing
      else here makes a trimmed `wl` run until this does. Check the nightly
      first; report it if it is still so.

- [ ] **File: `--trim` neither verifies nor compiles `Core._task`'s body.**
      Julia 1.14.0-DEV.3217 has `PartialTask`, and inlining attaches the
      body as `Core._task(f, size, ci)`, but `may_dispatch` (`verifytrim.jl`)
      does not list `Core._task`, so it passes unexamined, and
      `collectinvokes!` never queues the `ci`: `--trim=safe` verifies clean
      and the task dies at start, `MethodError(f=<closure>, args=())`. On
      1.13 only a concretely typed `:new` of the closure gets it compiled.
      Six lines reproduce it: `Task(() -> println(...))`, `schedule`,
      `wait`. Nothing under `test/trim/` starts a task. Drafts, the MWEs
      and the builds are in `.worktrees/h1trim/` (`julia-issue.md`,
      `http-issue.md`).

- [ ] **Drop `parse_gfm` once Julia aligns a plain column left.**
      JuliaLang/julia#63365 (open, RFC) makes `default_align` `:l`. When it
      is in the nightly this runs on, delete `gfm_table`, `GFM_FLAVOR` and
      `parse_gfm` (`ui.jl`), call `Markdown.parse` again, keep the alignment
      test in "a comment is drawn as GitHub draws a comment", and drop the
      bullet from DESIGN's "Julia's Markdown". If it lands as something else
      - a marker for no alignment - `markdown_rows` already draws anything
      that is not `:r` or `:c` left.

## Reading

- [ ] **A search match on a url footnote is marked loosely.** The footnote row
      shows an elided form of the url, so the match is placed against text that
      is not what was searched.

- [ ] **A short fenced block reads as a labelled block.** *Decide: whether a
      short snippet should be part of the sentence instead.*
      A fenced block is a node with its own header and fold state, so a
      three-line snippet gets the same furniture as a file.
