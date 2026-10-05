# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next quick issues

What TermInput's new API (TermInput.jl 0187294) lets wl stop doing by hand:

- [ ] **Pickers that start on the current choice.** `ChooseView`
      (`controller.jl` ~826) forwards only `numbered` and `ranged`; pass
      `selected` too, and open the milestone picker (`writing.jl` ~1219) on
      the one marked `[x]` and the agent picker (`sessions.jl` ~1187) on
      `v.pick`.
- [ ] **Fixed menus with no query.** Views (`writing.jl` ~747), Snooze
      (~1017), Set-on (~1125) and Review (~431) as `Choice(...; filter =
      false)`: a digit picks, a letter is the menu's, nothing narrows - what
      Snooze's comment (~1010) asks for.
- [ ] **Fixed columns as `tablerows`.** The worktree and branch lists
      (`paneview.jl` ~1063 and ~1177: the `WT_*`/`BR_*` widths, `wt_label`,
      `list_header`, `wt_line`/`br_line`), help's key column (`help.jl` ~69)
      and meta's `kv` (`meta.jl` ~410). The `rpad`s in `checks.jl` ~40/53,
      `content.jl` ~1260, `filters.jl` ~990-1149 and `cli.jl` ~313 count
      characters, not columns, and misalign wide ones: `rowpad`, or a table.
- [ ] **`rowvpad`** for the padding loops in `browse/frame.jl` ~469 and ~268
      (the help rows) and `paneview.jl` ~1299, ~208 and ~285.
- [ ] **`markdown_rows(...; pad = false)`** instead of stripping its padding:
      `show_md` (`ui.jl` ~763), `row_span` (`layout.jl` ~249) and its
      comment, the fallback `MDRow` in `render_md` (`markdown.jl` ~511), and
      the tests' `rstrip`s (`suite/markdown.jl`, `suite/theme.jl` ~225,
      `suite/frame.jl` ~545).
- [ ] **Theme keys for the new `MarkdownStyle` fields.** `MD_KEYS`
      (`theme.jl` ~256) reaches none of `url`, `marker`, `number`, `bullets`,
      `numbers`, `inlinecode`, `footnote_ref`, `table_rows`, `cellpad`.
- [ ] **Small ones.** `rowpad(rowfit(x, n), n)` is `rowpad(x, n)`
      (`browse/frame.jl` ~91/466, `paneview.jl` ~1188-1213, `sessions.jl`
      ~873). Tests set a `Choice`'s `.sel` (`suite/worktrees.jl`,
      `suite/filters.jl` ~946/960): `select!`, by label rather than by row.
      `suite/input.jl` ~60 rebuilds the cursor block that `drawcursor` draws.

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
