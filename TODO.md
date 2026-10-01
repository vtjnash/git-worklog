# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next quick issues

- [ ] Can we DRY some of the scrolling code by moving it into TermInput (where other clients might want it too)
  
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
- [ ] upgrade tmux_jll to latest in Yggdrasil: JuliaPackaging/Yggdrasil#14980
      (3.7c, with `jemalloc_jll` on Apple, which 3.7c's configure wants
      there, tmux#5385), open 2026-10-01; done when it merges and registers.
- [ ] try rewriting the Term API on top of TermInput now, just to see if it is possible

## Unverified

- [ ] **`T` asks first.** On an item with no agent: the prompt, `tab` to the
      picker and back with the title changed, `↵` with words and the agent's
      first turn starting on them, `↵` with none, escape. And `^]T` from a
      shell pane: the shell's pane is gone from the stack after (`^]q` once
      reaches the browser).
- [ ] **The filter pane's foot.** The sentence follows the cursor, wraps in
      three rows at a narrow list, is not there below 20 rows, and a click on
      it toggles nothing.

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
