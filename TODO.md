# TODO

What is open. Anything shipped is in `git log`; why things are shaped as they
are is in DESIGN.md.

## Blocked on a token that can write

**Every write is unexercised.** `post_comment`, `add_review_thread`,
`submit_review`, `discard_pending`, the label toggle and `merge_pr` are
written and none has ever been sent: the sandbox token is read-only. It is
the only part of the program where a failure loses work. The shapes are from
the docs and, for the four review mutations, introspected from the live
schema; the read half (`review_state`) has run against the real API.

`Events.pat()` already finds the `gho_` token with `repo` scope off the
sandbox, which covers `issues: write` and `pull_requests: write` everywhere.
**Route the writes through it**, then, in order:

- [ ] `merge_pr`: the first thing to verify is that `expectedHeadOid` refuses
      a stale head rather than merging over it. Then that the row rewritten as
      merged reads correctly beside the refresh's own version when one lands.
- [ ] a comment, a review comment on a range, a submitted and a discarded
      draft review, a label toggle.
- [ ] pushing this repository: `origin` is `vtjnash/git-worklog`, never pushed
      to; needs a fine-grained PAT with `Contents: read/write`.

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
      row is dropped once `updated <= read`, and the id with it, so this
      table is pruned only past the retention floor (`[notifications]
      retention_days`, 80) and on a 404. `thread_facts!` carries it onto the
      corpus row beside `reason`. Bootstrap is one ids-only `all=true` walk
      to the floor, adding no inbox rows: `backfill_days = 0` still holds.
- [ ] **`Events.reconcile!(at; dry_run)`**, once per `wl refresh` after the
      corpus is written, over corpus rows ∩ `threads`. A url with no local
      record is never touched and never asked for. `notified` under the
      floor: skip. Otherwise:

      | local (`seen_of`) | remote | do |
      |---|---|---|
      | read | not done | `DELETE /notifications/threads/{id}` |
      | unread, no `snooze`, `read` not `""` | done | `set_read(url, read_up_to(moved_at, updated, at))` |
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
      calls it when on, and skips it with a line where `pat()` has no token.
      Later, the browser runs it in a subprocess after `r`/`s`/`x`, as `R`
      runs a refresh.
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
- [ ] **Editing in the metadata pane.** It is a readout, and every field on
      it that can change is changed from somewhere else or not from here: the
      labels (`L`), the snooze (`s`), the note (`v`), `deadline`, `blocked`
      and `why` (`wl set` only), the assignees and reviewers (nothing at all).
      Wanted: `tab` reaches the pane as a third focus, `j`/`k` walk its
      fields, `↵` edits the one under the cursor with the prompt each already
      has - the label picker, the snooze menu, a line prompt for a
      `local.toml` field - and a click on a field does the same. Decide
      first: whether `tab` cycles three panes or the pane has a key of its
      own; how a row knows its field - `meta_lines` returns strings, so the
      `kv` rows would have to carry their key for `layout.jl` to hit-test and
      `mouse.jl` to act on; and that assignee and reviewer are GitHub writes,
      a mutation each, unexercised like the rest (see the first section).
- [ ] **Undo in the composer.** `^_`/`^x^u` are unbound; the answer has been
      `⌥e`. Weak for the `^w` you did not mean. Needs a snapshot stack and a
      rule for what one step is.
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

- [ ] **`Highlights` 0.6 imports `Pkg` at load time** - 0.35s on every launch
      of everything that highlights anything - for one
      `Pkg.Registry.reachable_registries()` on an error path
      (`languages.jl:40`). File with the measurement.
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

- [ ] Arrow, page and Shift-Tab bytes from this terminal; which spelling of
      Alt it sends (on a Mac, Option may compose instead).
- [ ] `^s` in the composer: raw mode should clear IXON.
- [ ] Raw mode restoration on abnormal exit.
- [ ] OSC 8 links and the OSC 52 copy end to end. The bundled client is
      3.5.1, but an older server already on the socket renders `capture-pane`
      (OSC 8 needs 3.4), and OSC 52 is opt-in in some terminals. Whether the
      title-bar row settles copy-mode scrolling.
- [ ] `⌥e`/`^o` launching `$EDITOR` from inside the browser; `e` (`code` is
      not on the sandbox's `PATH`).
- [ ] `u` end to end: the child's exit and the status line from its last
      output line.
- [ ] `p` against a rebase whose base moved, network and arithmetic at once:
      needs a checkout of a repository whose base moves.
- [ ] The `pull/N/head` refspec in `ensure_commit!` - the bare sha answered
      every time.
- [ ] Whether owning the mouse is the right trade, or `m` is reached for
      constantly. Whether 150 columns is the right split threshold.
- [ ] Whether any lane wants an order of its own (`lane_sort` is one line).

## Known gaps

Reviewing and writing:
- [ ] `C` on a line of the `p` pane comments on the item, not the line:
      GitHub's `LEFT` is the base, and the left side there is the head you
      last saw. Restricting to the right side would work.
- [ ] `C` refuses a comment on a deleted line - the old-side number is known,
      but it must be anchored against a commit the line existed in.
- [ ] `C` on an issue comment writes a new comment rather than replying
      (matches GitHub; surprises).
- [ ] The metadata pane is a readout; editing it is under "To design". Also
      not there: opening the check under the eye.
- [ ] **The `tracking` block of the metadata pane - `lane`, `level`, `why` -
      reads as three settings and is one.** `lane` is which search claimed
      the row (a fact, the filter axis of the same name); `why` is the
      reason GitHub gave for a notification (a fact, `THREAD_WHY`); `level`
      is `track`, the one that is yours - `wl track <ref> normal|loose` -
      and nothing on screen says so, or says what `normal` and `loose` mean
      (README, "Tracking"). Rename or remove: at least say `track` and not
      `level`, so the word on screen is the command's; drop `lane` and `why`
      from under a heading that promises tracking, or move them up with
      `author` and `state` where the facts are; and if `track` stays, its
      row is the first thing the metadata-pane editing above should reach.

The corpus:
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
- [ ] The reading side forwards `f` (switches to the filter pane, invisibly)
      and `q` (quits the program from inside a pane).
- [ ] A pane once reported `session ended` with an empty frame (2026-09-02,
      scripted launch). The wake-channel theory was tested and is wrong (11
      of 64 slots). Not recurred.
- [ ] The second look is called "second look" in the filter pane, which is
      what it does and not what it is for; "who is waiting on me" does not
      find it by reading.
