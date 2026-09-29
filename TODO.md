# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next

- [ ] when snooze runs, it seems not to come back with a "new since" tag which means I can't easily actually tell if anything moved since snooze. Perhaps we should separately track since-read and since-snooze, and draw different markers for each of those in the history. we'll need to decide if `p` is relative to read, snooze, or max of those.
- [ ] "A drag in a pane" was verified, but "dragging past the top or bottom scrolls" didn't work quite right: it scrolled only on mouse movement, at the speed of mouse movement, rather than being a steady continuous rate until the mouse returned into range.
- [ ] A code span Term wrapped across two lines loses its background.
- [ ] upgrade tmux_jll to latest in Yggdrasil (check for open PR or make our own)
- [ ] **A preview of the session under the cursor in `"`.** Once the cursor
      rests on a row (the pane's `LOAD_AFTER` dwell), `capture-pane -e` its
      session down the command pipe (about 0.1 ms) and draw the screen beside
      the list where there are 150 columns, the split `t`/`T` use, and its
      bottom rows under the list where there are not. The agent's session
      when the row has one, else the shell's; `tab` is the modes', so a key
      of its own if the other is wanted. Colours and links come through
      `capture-pane -e` as the hosted pane's do (`iframe_sync!`).
- [ ] **Move the picker, and the other dialogs, into TermInput.** A picker
      is `<select>` beside TermInput's `<input>` (`LineInput`) and `<textarea>`
      (`TextArea`), so the name still fits. `ChooseView` becomes a thin view
      over a `TermInput.Choice`, as `PromptView` is over `LineInput`: pure
      `render(w, h)` and `handle!(key)` answering `:ok`/`:unhandled`, colours
      from `CHROME` rather than `THEME`, and multi-line options with it.
      `listwindow` and `numkey` go too, and the query becomes a real
      `LineInput` instead of the backspace, `^u` and `^w` written out by hand.
      `ConfirmView` (named keys, everything else no) is the same kind of thing.
      Its mouse handling (`mouse.jl`) comes along, with the double click's
      time as an argument.
- [ ] changes to make for views:
      * 'my work' (2) should be only my PRs
      * 4-9 haven't seemed useful, 1-3 and 0 have been good
      * ready-to-merge doesn't seem functional (nothing tagged)
      * add an "approved to merge" view?
      * add a "second look" view? I thought we tried to design for this a long time ago, but then I think we might have dropped it and it might need a second-look itself (haha).
      * improve the text around "lane" and "tag" vocab, since it isn't obvious what those mean to someone who hasn't read the source code
        - might want to add a "help" message footer to the filters pane which gives a description of the item under the cursor
- [ ] Is it worthwhile to prefix keys with numbers for repeating (e.g. 6j for down 6), for kjnN? But we might want numbers for other hotkeys.
  
## Unverified

- [x] **The command pipe, and the pane's keys, in a real terminal.** The
      suite drives both against the bundled tmux, with no terminal and no
      `claude`. By hand, bundled tmux and a server of the user's own:
      - `T`, let the agent stop, go back to the list: the row turns unread
        within about a second, with no `wl-` listing on a clock (the pipe's
        subscription). `e` clears it.
      - `tmux ls` shows `_wl-ctl-<pid>` while a session of ours is up; it
        goes when the last one is killed (`^]K`), when `wl` quits, and when
        `wl` is `kill -9`ed.
      - `^]q`, `^]K`, `^]a` and back, `^]r`, `^]]` into `cat -v`, `^]?`;
        `^]tab` with more typed in the same burst, which must not reach the
        child; `v` on an item, edit, quit the editor: the note is saved.
      - With the thread beside a `T` pane moved to another item: `^]h` puts
        it back on the agent's item, `^]t` opens the shell in the agent's
        worktree without asking which copy, and `^]j` scrolls what is shown.
      - MANUAL.md 4 and 7 again, since their code moved: the clipboard is
        relayed by the sync now, not the reader, and a pane wakes through
        its own watch.
- [ ] **A drag in a pane, and `^]m` with nothing beside it, in a real
      terminal.** The suite drives the drag as SGR reports against the bundled
      tmux and reads the clipboard off stdout. By hand, in a pane running a
      shell and then `less`:
      - A drag highlights as it goes, the cursor following its end and the
        footer saying `copy mode`; letting go pastes elsewhere as what was
        selected, a wrapped line whole and without the pane's border.
      - Dragging past the top or bottom scrolls; the wheel during a drag
        moves the view; after the copy the view stays put and a key returns
        to live.
      - A click alone does nothing, and `vi` or a `mouse on` tmux in the
        pane still gets its own clicks and drags.
      - With emacs and with vi `mode-keys`, the last cell highlighted is the
        last one copied.
      - `^]m` in a pane opened with no thread beside it: the terminal's own
        selection back, the footer saying so, and `^]m` again takes it.

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

- [ ] **Take Term's header fix once it is released.** FedeClaudi/Term.jl#313
      (merged 2026-09-25, after v2.2.1) keeps a header's inline elements on
      one line; on 2.2.1 `## a `b` c` renders as three centred lines. Bump
      Term, and add the header case to the `render_md` tests.

- [ ] **Take Term's table fitting once it is released.**
      FedeClaudi/Term.jl#314 (open) makes `parse_md(::Markdown.Table)` fit
      the width it is handed, wrapping cells rather than truncating, and
      reads the table's box, style and row rules from the theme
      (`md_table_box`, `md_table_style`, `md_table_compact`). Bump Term; set
      `md_table_box = :MINIMAL_HEAVY_HEAD` and `md_table_compact = true`
      where `load_theme!` sets Term's theme, which is GitHub's look; add a
      test that JuliaLang/julia#63195's second table fits the pane at 60 and
      100 columns with every word of every cell present; and drop the table
      bullet from DESIGN's "Term.jl" section. Check whether a table nested in
      a list still needs `for_term`'s move to code once it is not padded to
      the width.

- [ ] **Drop `parse_gfm` once Julia aligns a plain column left.**
      JuliaLang/julia#63365 (open, RFC) makes `default_align` `:l`. When it
      is in the nightly this runs on, delete `gfm_table`, `GFM_FLAVOR` and
      `parse_gfm` (`ui.jl`), call `Markdown.parse` again, keep the alignment
      test in "a comment is drawn as GitHub draws a comment", and drop the
      bullet from DESIGN's "Julia's Markdown". If it lands as something else
      - a marker for no alignment - map that to `:l` in `for_term` instead.

- [ ] **File Highlights' `Pkg` import upstream.** `Highlights` 0.6 imports `Pkg`
      at load time for one `Pkg.Registry.reachable_registries()` in
      `available_language_jlls` (`languages.jl:40`), a discovery helper nothing
      calls on the way to highlighting. Measured with Highlights 0.6.2 under
      Term 2.2 on julia nightly, this sandbox: `import Pkg` alone is 0.28-0.30s;
      `import Term` is 0.91s cold and 0.56-0.67s with `Pkg` already loaded, so
      the import is 0.25-0.35s of every launch of everything that highlights
      anything. The fix upstream is `Base.require`-on-demand or an extension on
      `Pkg`. Still on master and still unfiled as of 2026-09-21
      (JuliaDocs/Highlights.jl has no issue on it). File it.

- [ ] **Offer Term a code palette that is part of its theme.** `Term.CodeTheme`
      is a hard-coded `Dict` that `set_theme` never touches; the `Theme` fields
      that look like they do that (`string`, `number`, `operator`, `type`…)
      drive only the old regex highlighter. `term_code_plain!` and the `[code]`
      table in `theme.jl` write into the `Dict` in place, which works only
      because the binding is `const` and the contents are anybody's. Offer a
      patch from the `Term.jl/` clone.

## Reading

- [ ] **A code span Term wrapped across two lines loses its background.** The
      second line gets a dim backtick and no background.

- [ ] **A search match on a url footnote is marked loosely.** The footnote row
      shows an elided form of the url, so the match is placed against text that
      is not what was searched.

- [ ] **A short fenced block reads as a labelled block.** *Decide: whether a
      short snippet should be part of the sentence instead.*
      A fenced block is a node with its own header and fold state, so a
      three-line snippet gets the same furniture as a file.
