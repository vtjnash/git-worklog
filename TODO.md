# TODO

What is open. Anything shipped is in `git log`; why things are shaped as they
are is in DESIGN.md.

## Blocked on GitHub - the notifications sync

**Wanted**: the GitHub inbox and this program's read state kept in step,
both ways at once - a thread marked done there is read here, a thread read
here is done there - because either direction alone is no use. "Done" means
read *and* done: a thread glanced at on the website is not one dealt with.
Nice to have: `r` a second time un-dones it there. Not wanted: the reverse.

**Why it is blocked.** Measured 2026-09-16 with the `gho_` token: a thread
record has one bit, `unread`, and every action - `DELETE` (done), `PATCH`
(read), both, done in the iOS app, opened on github.com - clears it and
changes nothing else. `last_read_at` is never written per thread; it echoes
the bulk `PUT /notifications` parameter. So the REST API cannot tell done
from read, and done is not on the record at all. The site knows: it has
three states, unread → read → done, "mark as unread" going back to the first
and un-doing on the way; its forms are `POST /notifications/beta/archive` and
`/unarchive`, and `is:done` is the only readable list of done there is.
GitHub Mobile uses non-public GraphQL (`notificationThreads` with `isDone`
and `isSaved`, `markNotificationAsDone`) gated to GitHub's own clients; the
one time the flag leaked it was pulled within two weeks (community#24653,
April 2026). Saved has no API of any kind (community#39606). Retention is
three months and a day: `all=true` answered back to 2026-06-15T00:01:52Z,
1970 threads in 40 pages; `all=false` is exactly the unread set, 327 in 7.

**Not doing**: pulling on `unread: false`, which would mark read here
everything ever clicked there; the website with a session cookie, which is
the whole login in a file over HTML with no contract; the mobile GraphQL,
which is not ours and was taken away once already. REST or nothing.

**The plan, once the thread record carries `done`** - a field on the thread
and in the listings, or a `done=true` filter; for the nice-to-have, any
endpoint that marks a thread unread:

- [ ] **Keep the handle.** `sync!` writes every thread it sees to
      `fetched.json` as `inbox.threads`: `url → (id, notified)`. The inbox
      row is dropped by the refresh once its corpus row is fetched past it
      and read, and the id with it, so this table is pruned only past the
      retention floor (`[notifications] retention_days`, 80) and on a 404.
      (This table is also what removes the overlap hazard: a dropped row
      re-read under the cursor's overlap starts a false expectation in
      `expect!`, since `old === nothing`.) `thread_facts!` carries it onto the
      corpus row beside `reason`. Bootstrap is one ids-only `all=true` walk
      to the floor, adding no inbox rows: `backfill_days = 0` still holds.
- [ ] **`Events.reconcile!(at; dry_run)`**, once per `wl refresh` after the
      corpus is written, over corpus rows ∩ `threads`. A url with no local
      record is never touched and never asked for. `notified` under the
      floor: skip. Otherwise:

      | local (`seen_of`) | remote | do |
      |---|---|---|
      | read | not done | `DELETE /notifications/threads/{id}` |
      | unread, no `snooze`, `read` not `""` | done | `set_read(url, moved_of(it))`, folded under the floor |
      | unread said (`read == ""`) | done | un-done, if an endpoint exists |
      | asleep | not done | `PATCH` read: listed on the phone, not bold, bold again when it moves - the nearest thing to Saved |
      | agree | | nothing |

      No ledger: the remote state says whether a write is needed. The two
      exclusions on the pull are what one would have been for - a snooze
      that has just woken is not put back to sleep by a stale remote read,
      and an `r`-unread is a statement and wins. Reads applied here have no
      `z`; `r` toggles them. This is the one place `unread` or `done` is read
      off a thread; the cursor is untouched, and DESIGN item 8 under GitHub
      is rewritten to say so.
- [ ] **`wl sync [--dry-run]`**, dry-run forced until `[notifications]
      sync = true`: the bootstrap finds hundreds of rows read here and unread
      there, and that list is to be seen before it is sent. `wl refresh`
      calls it when on, and says so through `warning()` where `pat()` has
      no token. Later, the browser runs it on a task after `r`/`s`/`x`, the
      way `u` runs the refresh (`refresh_all!`).
- [ ] **Tests**, with a fake fetch: floor and 404 skip; the two exclusions;
      no corpus row untouched; bootstrap adds ids and no items; a truncated
      listing turns the pull off and says so; asleep then woken and read
      gets its `DELETE`.
- [ ] **Docs**: DESIGN item 8 and a decisions entry for "not doing";
      README for `wl sync` and the two keys.

About 150 lines in `events.jl` and `refresh.jl`, none in the browser. Until
then the push works by hand: `gh api --paginate /notifications --jq '.[].id'
| xargs -I{} gh api -X DELETE /notifications/threads/{}`, filtered as wanted.

## To design before starting

- [ ] **A comment box drawn inline, between the diff lines it is about.** The
      rest of that idea is done - threads hang off their hunk, the line is
      marked `💬`, `n`/`N` walks them. A hunk is one node whose body is the
      diff text, and cutting it at the commented line cuts the `start`,
      `count` and `body` that `hunk_line_at`, `[`/`]` and `C`-on-a-range all
      read off one node. Cheap version: a node per fragment sharing the
      parent's meta, and the arithmetic of four ranges in step. Honest version:
      rows that belong to a node without being its body, which changes what a
      `Row` is. Decide which before starting.
- [ ] **Quick actions on the checkout.** Whether the browser should run
      the git and `gh` commands that today mean `t` and typing: `gh pr
      checkout N` (which is what a pull request from a fork needs - the
      pane now names the fork, and `add_worktree!` is `git worktree add
      <dest> <branch>`, which only works for a branch that is already here),
      `git rebase <remote>/<base>` (`ensure_base!` already fetches the
      base for `p`; `mergeable  behind master` on the pane is the row
      that would want it), `git push --force-with-lease` after it, `gh pr
      ready`/`--undo`, re-running a failed check. Decide: **where** - a
      key opening a picker the way `'` does (the pane's rows are not a
      candidate: they are a readout, see DESIGN's decisions), or `t` opened
      with the command typed and not sent, which is the one that leaves a conflict
      in the shell where it has to be resolved anyway; **which case** - the
      rule is lowercase looks or changes this machine and uppercase reaches
      GitHub, and a rebase is the first, a push the second, a checkout of a
      fork's branch both; **how it reports** - the status line is one row,
      and a rebase that stops is not one row. The worktree list (`"`) is
      the other candidate, since a checkout is a fact about a worktree
      and not about an item.
- [ ] **Realign the names, and maybe the keys, with GitHub and Gmail.**
      What this program calls *read* is what GitHub's inbox calls **done**
      - a thread put away that comes back when it moves - and the sync
      entry above already equates them; "read" here is a stamp, and what
      the user does with `r` is finish with the thing. Names first: `r`
      says "marked read" and should say done; the `read` show box, the
      `unread, open` box, "read ↔ unread" in the help; and *filed away*
      (`x`) wants a word too, since it is also a thing that comes back
      when it moves, and the difference - out of the backlog as well - is
      not in either name. Then the keys, which are the same across the
      two inboxes and mostly not this program's:

      | does | GitHub | Gmail | here |
      |---|---|---|---|
      | done / archive | `e` | `e`, `y` | `r` (and `x` is filed) |
      | done and next / previous | | `]` `[` | |
      | mark read / unread | `⇧i` / `⇧u` | `⇧i` / `⇧u` | `r` toggles |
      | snooze | | `b` | `s` |
      | save / star | `s` | `s` | |
      | unsubscribe | `⇧m` | | |
      | undo | | `z` | `z` |
      | search · help · move | `/` `?` `j`/`k` | `/` `?` `j`/`k` | `/` `?` `j`/`k` |

      Every one of `e`, `y`, `[`, `]`, `s` is taken here - the editor, copy,
      hunk context, snooze - and `⇧i`/`⇧u` would be two local keys in the
      uppercase-reaches-GitHub case. Decide whether the hand that lives in
      those inboxes is worth moving the editor and the context keys for,
      which need homes first, or whether it is the names alone; and
      whether "done and next" (`]`) is wanted at all, given `r` in the
      base list already advances the cursor by removing the row.
- [ ] **Undo in the composer** - scoped 2026-09-17, **deferred**: `⌥e` is
      the answer for anything past a paragraph, and this is the first thing
      past one. Weak for the `^w` you did not mean; do it when that bites.
      The scope, so it is not designed twice:
      - In `TextBuffer`, not the widget: a snapshot is `(lines, row, col)` -
        one vector copy, the strings being immutable - pushed by each
        mutating operation before it acts, capped at a couple hundred.
        `undo!` pops one. No redo, and an undo is not itself recorded, so
        `^_^_^_` walks straight back; readline has no redo either.
      - One step, by the rule `killing` already uses for the kill buffer,
        turned around - the buffer remembers the kind of the last operation
        and an operation pushes unless it continues a run: typed characters
        are one step **broken at a word boundary** (a space or newline after
        a non-space starts a new one, so undo takes back a word at a time);
        a run of backspaces likewise; every kill, `^y`, `^t`, `^d`, `↵`, a
        `^r` block and an `⌥e` round trip is its own step; any motion ends a
        run without pushing. So `^_` after `^w` gives the word back exactly.
      - `^_` alone (byte 31, what `^/` sends too), in both widgets. Not
        `^x^u`: the host binds `^x` to cycling the composer's target
        (`controller.jl`) and the widget sees keys first.
      - ~40 lines in `buffer.jl`, two per `handle!`, the README row's ✅, a
        testset driving the sequences above. A `TermInput.jl` commit plus
        the pointer bump here.
- [ ] **`TermInput` and Term's `InputBox`** are not the same widget:
      `InputBox` appends keystrokes with no cursor, because `readkey` cannot
      tell Left from Escape-`[`-`D`. Unifying wants, in order: a decoder good
      enough to have a cursor behind it (`readevent`, still in
      `controller.jl` - it is a pure function of a byte stream and could go to
      the package; what should stay is who owns stdin), `TextBuffer` under
      `InputBox`, then the frame, where markup measurement is the open
      question.
- [ ] **Upstream the ANSI measuring to Term.** `awidth`/`afit`/`apad`/`awrap`
      measure what prints; `Panel` and `reshape_text` measure markup. Find
      out whether Term would take a path that does not strip markup, a
      "not markup" flag on `Panel`, and `awrap`'s escape replay (what #119 was
      closed without).
- [ ] **StyledStrings**, later. For text this program composes it would
      replace every `_off` closer. For text that arrives as escapes - Term's
      output, `capture-pane -e`, git's diff - nothing parses it back, so a
      migration is an ANSI parser at every boundary; and a `Face` cannot say
      `on 236`. The shape of later: the parser is the same work as the
      measuring question above, from the other end.

## Upstream - delete the workaround when a release carries the fix

| where | what | workaround here |
|---|---|---|
| FedeClaudi/Term.jl#304 | braces deleted in prose, doubled in code spans | `escape_source` doubles; `render_md` collapses |
| Term.jl#305 | empty list item is a `BoundsError` | `for_term` fills it |
| Term.jl#306 | table nested in a list is a `MethodError` | `for_term` moves it to a code block |
| Term.jl#309 | code span in a table header drawn as a block | header cells wrapped in a `Paragraph` |
| Term.jl#310 | `leftalign`/`vstack` re-wrap a table wider than the terminal | none needed - `render_md` is handed a pane width |
| JuliaLang/julia#63081 | intraword `_` opens emphasis (fix submitted) | the underscore half of `escape_source` |

Found and not filed:

- [ ] **`Highlights` 0.6 imports `Pkg` at load time** for one
      `Pkg.Registry.reachable_registries()` in `available_language_jlls`
      (`languages.jl:40`), a discovery helper nothing calls on the way to
      highlighting. Measured 2026-09-16, Highlights 0.6.2 under Term 2.2 on
      julia nightly, this sandbox: `import Pkg` alone is 0.28-0.30s; `import
      Term` is 0.91s cold and 0.56-0.67s with `Pkg` already loaded, so the
      import is 0.25-0.35s of every launch of everything that highlights
      anything. The fix upstream is `Base.require`-on-demand or an extension
      on `Pkg`; nothing filed on JuliaDocs/Highlights.jl as of the
      measurement (no open issues). File it.
- [ ] **Term's code palette is not part of its theme.** `Term.CodeTheme` is a
      hard-coded `Dict` that `set_theme` never touches; the `Theme` fields that
      look like they do that (`string`, `number`, `operator`, `type`…) drive
      only the old regex highlighter. Offer a patch from the `Term.jl/` clone.
- [ ] **`Term.Live.InputBox` throws on backspace after a multi-byte
      character**: `input_text[1:(end - 1)]` is a byte slice; `aée` gives
      `StringIndexError`.

Offers, once they have carried real use: `TermInput` to Term (#131 asked for
it; #119 and #247 bear on how much would be welcome), and `TermIFrame` as a
widget - only backend-shaped, since `psmux` and wezterm have the same two
primitives under other names and `tmux_jll` covers three platforms.

## Unverified - needs a real terminal

Written, compiled, state transitions driven through `handle!`; not exercised
through a TTY. Strike through rather than delete when one answers.

- [ ] **SIGWINCH**, end to end. `watch_winch!` hears it through libuv and
      the loop redraws on the `ResizeEvent` (2026-09-16; the suite raises
      the signal at itself and sees the event). Unseen: a real terminal
      narrowed and widened with a thread, and with a hosted pane - whose
      child is told its new box in `onresize!` - and a pty that does not
      send the signal, where the frame stays the old shape until a key, as
      it always did. The Windows half is `displaysize` at the next key
      alone; there is no signal.
- [ ] Arrow, page and Shift-Tab bytes from this terminal; which spelling of
      Alt it sends (on a Mac, Option may compose instead).
- [ ] `^s` in the composer: raw mode should clear IXON.
- [ ] Raw mode restoration on abnormal exit.
- [ ] The title: `wl JuliaLang/julia#1` on the tab and the tmux pane,
      following the selection and staying through a dialog about it; the
      old title back on exit where the terminal keeps a title stack (`CSI
      22 t` / `CSI 23 t`), the last one until the next prompt where it does
      not.
- [ ] OSC 8 links and the OSC 52 copy end to end. The bundled client is
      3.5.1, but an older server already on the socket renders `capture-pane`
      (OSC 8 needs 3.4), and OSC 52 is opt-in in some terminals. Whether the
      title-bar row settles copy-mode scrolling.
- [ ] `⌥e`/`^o` launching `$EDITOR` from inside the browser; `e` (`code` is
      not on the sandbox's `PATH`).
- [ ] The forwards, across a reconnect: a pane opened from one VS Code
      window, the window reconnected (new `vscode-ssh-auth-sock-*` and
      `vscode-ipc-*.sock`, the old files left behind), then `git push` and
      `code <file>` in the old pane after a fresh `wl` from the new
      connection has re-pointed the links; and the `no live ssh agent`
      suffix from a pane key in a `wl` whose own login has reconnected
      under it. The re-pointing and the handover are tested on listeners
      of our own and the bundled tmux; a real forwarded agent has not been
      connected to.
- [ ] `u` end to end: the browser staying live through the refresh's walk
      over the corpus (a ~100 ms hitch at the write is expected; a hang is
      not), and the status line off the report when it lands.
- [ ] `p` against a rebase whose base moved, network and arithmetic at once:
      needs a checkout of a repository whose base moves.
- [ ] The `pull/N/head` refspec in `ensure_commit!` - the bare sha answered
      every time.
- [ ] Whether owning the mouse is the right trade, or `m` is reached for
      constantly. Whether 150 columns is the right split threshold.
- [ ] Whether any lane wants an order of its own (`lane_sort` is one line).

## Known gaps

Reviewing and writing:
- [ ] `C` on an issue comment writes a new comment rather than replying
      (matches GitHub; surprises).
- [ ] `deadline`, `blocked`, `why` and `track` are `wl set`/`wl track` only;
      the browser wants one key opening a picker of the four, the way `'`
      opens views, then the line prompt each already has. Not a cursor on
      the pane (DESIGN's decisions). Also not there: opening the check under
      the eye.

The writes, all tried against GitHub by 2026-09-18 and none wrong so far:
- [ ] `C` on a deleted line - the one write that landed after the trial
      (2026-09-17): a `LEFT` thread numbered against the base.
- [ ] The suite reaches GitHub in one place - `Events.server_now`, through
      the witness testset at `refresh.jl:1257` - so with no token that file
      errors and stops `runtests.jl` there; every other file runs (seen
      2026-09-17, when the sandbox token expired overnight). Either hand that
      testset a clock, or accept that one line of the suite needs the network.

The corpus:
- [ ] `wl refresh` calling `consolidate!` on its own, once `wl read
      --consolidate` has been watched for a while - it was shipped explicit
      and dry-run first (2026-09-16). Nothing else about it is open.
- [ ] `refresh_` parses `fetched.json` three times - `fetched("items")` at
      the top, `Events.load_inbox()` for the drop, `load_fetched()` for the
      write - about 60 ms of its 450 (profiled 2026-09-17). One read held
      for the run would do, if the 100 ms hitch under `u` is ever felt;
      the write is the larger half of it and stays.
- [ ] Discussions, releases, commit comments: the notifications source sees
      each arrive and skips it, counted. Nothing here can open one.
- [ ] A kept row under an old url that is never asked again is a duplicate
      with old facts until it is.
- [ ] The unread light rows of a watched repository's traffic that moved
      before the cursor are the one thing a lost `fetched.json` does not bring
      back.
- [ ] "Mine" is author or assignee. Not yet: a pull request somebody else
      opened that you pushed to, or that carries you in `Co-authored-by`.
      Neither costed.
- [ ] An adopted branch that landed is news until read: `merged_here` says
      the commits are in the base and not how; the merge commit's committer
      would say, only for a real merge.

Reading:
- [ ] Hunk context expands against the head, so context around a `-` line is
      the post-change file.
- [ ] A fenced block is a node with its own header and fold state; a short
      snippet reads as a labelled block rather than part of the sentence.
- [ ] A code span Term wrapped across two lines gets a dim backtick, no
      background.
- [ ] Nesting is depth, not structure: nothing can be moved or counted as a
      subtree; past `MAX_DEPTH` a body is raw text.
- [ ] A url footnote row shows an elided form, so a search match on it is
      marked loosely.
- [ ] Buildkite job lists and logs are the one read still on a plain TTL
      (`bk_jobs` 5 min, `bk_log` 15), so a failing job's expansion can pause
      where the tally above did not; the per-check counts are as old as that
      entry.

Panes:
- [ ] `^]t`/`^]T` from a pane forward to the pane; `t`/`T` from the reading
      side go to the list. Both defensible; nothing on screen says they
      differ. Left alone.
- [ ] **`session ended` over an empty frame** (2026-09-02 scripted; since
      then when a child goes to the alternate screen, and sometimes under
      `git log`, with nothing said about why). Explained 2026-09-17 and
      fixed by construction, unverified in a terminal: the control-mode
      reader raised a wake per `%output` line into a 64-slot queue while the
      loop it fed was blocked on a `capture-pane` reply only that reader
      could deliver; a burst past 64 lines - an alternate-screen clear, a
      pager filling - blocked the reader, the ask timed out at 5s, the
      client was marked dead, and `mux_capture` dropped the reason. The
      2026-09-02 test that cleared the theory measured 11 of 64 at rest,
      not a burst. `wake!` now queues one wake at a time, and a dead client
      says why on the status. To see: a pane running `less` on a long file,
      `git log`, and an editor opening, with the status row watched for
      `session ended:`.
