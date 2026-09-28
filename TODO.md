# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next

- [ ] **Push TermIFrame before `wl`.** `wl`'s submodule points at
      TermIFrame `098f86c` (a drag is tmux's copy mode), which with
      `70542f5` under it (copy mode's coordinates) is only local: push
      TermIFrame's `main` first, or a fresh clone has no such commit.
- [ ] upgrade tmux_jll to latest in Yggdrasil (check for open PR or make our own)
- [ ] **Run JET over `Worklog`.** A script like `aqua.jl`, or a testset if it
      is fast enough for the suite. `report_package` for the errors it can
      prove, and `report_opt` over the entry points (`dispatch`, `render`,
      `handle!`) for runtime dispatch - read knowing that the thread readers
      (`activity_list`, the node builders, `thread_seen`, `event_at`,
      `bk_failed`) are `@nospecialize` on purpose. Fix what is real; note
      what is deliberate where it is.
- [ ] Add a placeholder <refreshing> notice as the bottom node when opening an item history, in addition to the one in the margin, roughly where we expect new content to fill in (but only on open, not on explicit refresh)
- [ ] **A reader for a release or a commit comment.** A quick summary in the
      pane and the link to GitHub for the rest: notices are rare, so this is
      not a thread view. Today the pane is the block's own facts, no fetch.
      - Keep the subject's API url in the block: `sync!` writes an `api` key
        off `subject.url`, and `latest_comment_url` for a commit. A block
        from before has none, and stays as it is until its thread notifies
        again.
      - Fetch it in the task `comment_nodes` already runs for the pane, one
        request, cached with the thread's window; a failure leaves today's
        pane. `R` re-reads it rather than being refused.
      - A release: `GET /repos/o/r/releases/<id>` - the name, the tag, the
        first lines of the notes. Its `html_url` is the exact page, for the
        pane's link (not the block's), which answers LATER's release-link
        question at no cost to the poll.
      - A commit comment: `GET /repos/o/r/comments/<id>` - who, when, the
        file and line, the body. Not the commit's own message.
      - An advisory, a CI run, an invitation: nothing on the thread to ask
        about; unchanged.
      - Tests with the fetch passed in: each type's summary, a failed fetch,
        and no request until the notice is opened.
- [ ] **A reader for a discussion.** The same quick summary, and harder: REST
      has no endpoint for a repository's discussions, so it is GraphQL,
      `repository.discussion(number:)`, the number off `subject.url`.
      - The title, who opened it, when, the first lines of the body, how many
        comments; not the comments themselves - `o` is for those.
      - The query through `gh_graphql`, as the lanes' are, in the same
        task and cache as the item above, which should land first.
- [ ] **`^]` keys act on the pane's own session, not the reader beside it.**
      A key after the prefix that the pane does not answer goes to the
      browser (`forward!`), and so acts on whatever item the thread on the
      left is showing - which need not be the one the session was opened on.
      From inside a pane the subject should be the pane: `^]t` the terminal
      for the same worktree, `^]T` its agent, `^]h` the history of the item it
      is tagged with, and so on, read off the session's tags (`worktree`,
      `item`, `url`, `branch`; `mux_tag!` in `enter_session`). That is the
      difference from `^]tab`, which moves the keys to the reader, where `t`
      and `T` go on meaning the reader's item and its worktree. Which keys
      follow the pane and which stay the reader's is the first thing to
      decide - `^]m` is neither's, and `^]j` scrolling the thread is the
      reader's by nature.
- [ ] **Double-click a word, triple-click a line, in a pane.** To be
      reconsidered: a drag over a child that ignores the mouse is tmux's copy
      mode (`iframe_drag!`), but a click is nothing, as in tmux. tmux's own
      `DoubleClick1Pane` and `TripleClick1Pane` are `select-word` and
      `select-line`, then a copy - the same `copy_goto` and
      `copy_finish!` with one command between them. What it needs first is
      the clicks counted, which `retarget_mouse` cannot: it has no clock, and
      the time is the host's to pass (`at`), as the browser's double click
      already is.

## Unverified

- [ ] **The command pipe, and the pane's keys, in a real terminal.** The
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

- [ ] **Report the 1.14 `LazyLibrary` regression.** A trimmed executable
      whose JLL loads a lazy dependency dies at load: `InitError(:libevent_jll,
      MethodError(dlopen, ("…/libcrypto.so.3", 0x44)))`. Four lines,
      `using libevent_jll` and an `@main`, with `--trim=unsafe-warn`: dies on
      the 1.14 nightly, runs on 1.13. `dlopen(string(ll.path::Any))` in
      `libdl.jl`.
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
- [ ] **File: HTTP.jl hangs on any HTTP/1.1 request with a body when
      trimmed** - which is what "`protocol = :h1` hangs" was: a GET without
      a body over h1 works, and a POST over plain `http://` hangs with
      `:auto`. `_roundtrip_incoming!` `@spawn`s the body writer as a closure
      over `write_state::Union{Nothing,_RequestWriteState}` and a TCP-or-TLS
      stream: the item above, and past it a capture that cannot be trimmed,
      since a `Union` closure splits and no one body can be attached. The
      writer dies before its `try`, so nothing marks the write done, and
      the caller's `IOPoll.timedwait` loop, which never looks at the task,
      spins forever. The server receives zero
      bytes. Ours go over h2 by ALPN to api.github.com, so `wl` is clear of
      it until a proxy or a server without h2 is in the way.

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

- [ ] **Code spans before emphasis, once Julia has it.**
      JuliaLang/julia#63364 (open) matches code spans before emphasis, so
      `` *a `abc*` b* `` is italic around a code span. Nothing here works
      around it; when it is in the nightly, add that case to the `render_md`
      tests and drop the bullet from DESIGN's "Julia's Markdown".

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
