# LATER

What is blocked or undecided: nothing here can be started today. Each item
says what would start it - *blocked on* a fact outside this repository,
*decide* a question that is this repository's to answer, or *after*
something that has to happen or be felt first - and enough of the plan that
it is not designed twice. What needs doing now is in TODO.md.

## Blocked on GitHub - the notifications sync

**Blocked on** the GitHub thread record carrying `done` - a field on the thread
and in the listings, or a `done=true` filter. Measured 2026-09-16.

**Wanted**: the GitHub inbox and this program's read state kept in step,
both ways at once - a thread marked done there is read here, a thread read
here is done there - because either direction alone is no use. "Done" means
read *and* done: a thread glanced at on the website is not one dealt with.
Nice to have: `e` a second time un-dones it there. Not wanted: the reverse.

**Why it is blocked.** Measured with the `gho_` token: a thread record has
one bit, `unread`, and every action - `DELETE` (done), `PATCH` (read), both,
done in the iOS app, opened on github.com - clears it and changes nothing
else. `last_read_at` is never written per thread; it echoes the bulk `PUT
/notifications` parameter. So the REST API cannot tell done from read, and
done is not on the record at all. The site knows: it has three states,
unread → read → done, "mark as unread" going back to the first and un-doing
on the way; its forms are `POST /notifications/beta/archive` and
`/unarchive`, and `is:done` is the only readable list of done there is.
GitHub Mobile uses non-public GraphQL (`notificationThreads` with `isDone`
and `isSaved`, `markNotificationAsDone`) gated to GitHub's own clients; the
one time the flag leaked it was pulled within two weeks (community#24653,
April 2026). Saved has no API of any kind (community#39606). Retention is
three months and a day: `all=true` answered back to 2026-06-15T00:01:52Z,
1970 threads in 40 pages; `all=false` is exactly the unread set, 327 in 7.

**Not doing**: pulling on `unread: false`, which would mark done here
everything ever clicked there; the website with a session cookie, which is
the whole login in a file over HTML with no contract; the mobile GraphQL,
which is not ours and was taken away once already. REST or nothing.

**The plan**, once the record carries `done` (and, for the nice-to-have,
any endpoint that marks a thread unread):

- **Keep the handle.** `sync!` writes every thread it sees to
  `fetched.json` as `inbox.threads`: `url → (id, notified)`. The inbox row
  is dropped by the refresh once its corpus row is fetched past it and read,
  and the id with it, so this table is pruned only past the retention floor
  (`[notifications] retention_days`, 80) and on a 404. (This table is also
  what removes the overlap hazard: a dropped row re-read under the cursor's
  overlap starts a false expectation in `expect!`, since `old === nothing`.)
  `thread_facts!` carries it onto the corpus row beside `reason`. Bootstrap
  is one ids-only `all=true` walk to the floor, adding no inbox rows:
  `backfill_days = 0` still holds.
- **`Events.reconcile!(at; dry_run)`**, once per `wl refresh` after the
  corpus is written, over corpus rows ∩ `threads`. A url with no local
  record is never touched and never asked for. `notified` under the floor:
  skip. Otherwise:

  | local (`seen_of`) | remote | do |
  |---|---|---|
  | read | not done | `DELETE /notifications/threads/{id}` |
  | unread, no `snooze`, `done` not `""` | done | `set_done(url, moved_of(it))`, folded under the floor |
  | unread said (`read == ""`) | done | un-done, if an endpoint exists |
  | asleep | not done | `PATCH` read: listed on the phone, not bold, bold again when it moves - the nearest thing to Saved |
  | agree | | nothing |

  No ledger: the remote state says whether a write is needed. The two
  exclusions on the pull are what one would have been for - a snooze that
  has just woken is not put back to sleep by a stale remote read, and an
  `e`-not-done is a statement and wins. Reads applied here have no `z`; `e`
  toggles them. This is the one place `unread` or `done` is read off a
  thread; the cursor is untouched, and DESIGN item 8 under GitHub is
  rewritten to say so.
- **`wl sync [--dry-run]`**, dry-run forced until `[notifications] sync =
  true`: the bootstrap finds hundreds of rows read here and unread there,
  and that list is to be seen before it is sent. `wl refresh` calls it when
  on, and says so through `warning()` where `pat()` has no token. Later,
  the browser runs it on a task after `e`/`s`/`x`, the way `u` runs the
  refresh (`refresh_all!`).
- **Tests**, with a fake fetch: floor and 404 skip; the two exclusions; no
  corpus row untouched; bootstrap adds ids and no items; a truncated
  listing turns the pull off and says so; asleep then woken and read gets
  its `DELETE`.
- **Docs**: DESIGN item 8 and a decisions entry for "not doing"; README for
  `wl sync` and the two keys.

About 150 lines in `events.jl` and `refresh.jl`, none in the browser. Until
then the push works by hand: `gh api --paginate /notifications --jq
'.[].id' | xargs -I{} gh api -X DELETE /notifications/threads/{}`,
filtered as wanted.

## The browser

- [ ] **A comment box drawn inline, between the diff lines it is about.**
      *Decide: the cheap version or the honest one.*
      The rest of that idea is done - threads hang off their hunk, the line is
      marked `💬`, `n`/`N` walks them. A hunk is one node whose body is the diff
      text, and cutting it at the commented line cuts the `start`, `count` and
      `body` that `hunk_line_at`, `[`/`]` and `C`-on-a-range all read off one
      node. Cheap version: a node per fragment sharing the parent's meta, and
      the arithmetic of four ranges in step. Honest version: rows that belong to
      a node without being its body, which changes what a `Row` is.

- [ ] **Quick actions on the checkout.** *Decide: where they live, which case
      they are, and how a stopped rebase reports.*
      Whether the browser should run the git and `gh` commands that today mean
      `t` and typing. `gh pr checkout N` is done (2026-09-19): the question
      `t`/`T` asks on a copy that is on some other branch, and what makes a new
      worktree for a branch this repository has never had; a checkout that fails
      opens the shell anyway with gh's words on the status line. Still open:
      `git rebase <remote>/<base>` (`ensure_base!` already fetches the base for
      `p`; `mergeable  behind master` on the pane is the row that would want
      it), `git push --force-with-lease` after it, `gh pr ready`/`--undo`,
      re-running a failed check.

      - **Where** - a key opening a picker the way `'` does (the pane's rows are
        not a candidate: they are a readout, see DESIGN's decisions), or `t`
        opened with the command typed and not sent, which is the one that leaves
        a conflict in the shell where it has to be resolved anyway. The worktree
        list (`"`) is the other candidate, since a checkout is a fact about a
        worktree and not about an item.
      - **Which case** - the rule is lowercase looks or changes this machine and
        uppercase reaches GitHub; a rebase is the first, a push the second.
      - **How it reports** - the status line is one row, and a rebase that stops
        is not one row.

- [ ] **A word for *filed away*.** *Decide: the word.*
      `x` puts a thing out of the backlog as well as out of the inbox, and it
      comes back when it moves the way a done one does - neither "filed away"
      nor "done" says the difference.

## Reading

- [ ] **A short fenced block reads as a labelled block.** *Decide: whether a
      short snippet should be part of the sentence instead.*
      A fenced block is a node with its own header and fold state, so a
      three-line snippet gets the same furniture as a file.

- [ ] **A clipboard cut short is held until the pane says more.** *Decide:
      whether to drop a carry thirty seconds after its last byte, or leave it.*
      `passthrough` keeps an unfinished OSC 52 across `%output` lines, with
      no bound: a child that stops mid-sequence just stops, and the tail is
      only as large as what it wrote. What a `\e]52;` the child never
      terminates costs is that its head goes out in front of the pane's next
      copy, the two as one sequence; a terminal ends an OSC at the escape, so
      the next copy still lands, with a stray one before it. Nothing has done
      that; if something does, a cutoff of thirty seconds since the last byte
      seen is the shape, so a slow copy is not cut and a dead one does not
      stand. Not a size: a real copy can be any size.

## The composer

- [ ] **Undo in the composer.** *After the `^w` you did not mean bites.*
      `⌥e` is the answer for anything past a paragraph, and this is the first
      thing past one. The scope, so it is not designed twice:

      - In `TextBuffer`, not the widget: a snapshot is `(lines, row, col)` - one
        vector copy, the strings being immutable - pushed by each mutating
        operation before it acts, capped at a couple hundred. `undo!` pops one.
        No redo, and an undo is not itself recorded, so `^_^_^_` walks straight
        back; readline has no redo either.
      - One step, by the rule `killing` already uses for the kill buffer, turned
        around - the buffer remembers the kind of the last operation and an
        operation pushes unless it continues a run: typed characters are one step
        **broken at a word boundary** (a space or newline after a non-space
        starts a new one, so undo takes back a word at a time); a run of
        backspaces likewise; every kill, `^y`, `^t`, `^d`, `↵`, a `^r` block and
        an `⌥e` round trip is its own step; any motion ends a run without
        pushing. So `^_` after `^w` gives the word back exactly.
      - `^_` alone (byte 31, what `^/` sends too), in both widgets. Not `^x^u`:
        the host binds `^x` to cycling the composer's target (`controller.jl`)
        and the widget sees keys first.
      - ~40 lines in `buffer.jl`, two per `handle!`, the README row's ✅, a
        testset driving the sequences above. A `TermInput.jl` commit plus the
        pointer bump here.

- [ ] **`TermInput` and Term's `InputBox` are not the same widget.** *After
      `readevent` has moved to the package.*
      `InputBox` appends keystrokes with no cursor, because `readkey` cannot
      tell Left from Escape-`[`-`D`. Unifying wants, in order: a decoder good
      enough to have a cursor behind it (`readevent`, still in `controller.jl` -
      it is a pure function of a byte stream and could go to the package; what
      should stay is who owns stdin), `TextBuffer` under `InputBox`, then the
      frame, where markup measurement is the open question.

## Upstream

- [ ] **Offer `TermInput` and `TermIFrame` to Term.** *After they have carried
      real use.*
      Term.jl#131 asked for an input widget; #119 and #247 bear on how much
      would be welcome. `TermIFrame` only backend-shaped, since `psmux` and
      wezterm have the same two primitives under other names and `tmux_jll`
      covers three platforms.

- [ ] **Upstream the ANSI measuring to Term.** *Decide: whether Term would take
      it - ask, with #119 as the precedent.*
      `awidth`/`afit`/`apad`/`awrap` measure what prints; `Panel` and
      `reshape_text` measure markup. Find out whether Term would take a path
      that does not strip markup, a "not markup" flag on `Panel`, and `awrap`'s
      escape replay (what #119 was closed without).

- [ ] **StyledStrings.** *After the ANSI measuring question, which is the same
      parser from the other end.*
      For text this program composes it would replace every `_off` closer. For
      text that arrives as escapes - Term's output, `capture-pane -e`, git's
      diff - nothing parses it back, so a migration is an ANSI parser at every
      boundary; and a `Face` cannot say `on 236`.

- [ ] **Drop the underscore half of `escape_source`.** *Blocked on
      JuliaLang/julia#63081 (fix submitted, open) landing in a Julia this runs
      on.*
      `Markdown.parse` opens emphasis on an underscore inside a word, which
      CommonMark forbids; `escape_source` escapes them outside code.

## The corpus

- [ ] **`wl refresh` calling `consolidate!` on its own.** *After `wl done
      --consolidate` has been watched for a while.*
      It was shipped explicit and dry-run first. Nothing else about it is open.

- [ ] **`refresh_` parses `fetched.json` three times.** *After the 100 ms hitch
      under `u` is felt.*
      `fetched("items")` at the top, `Events.load_inbox()` for the drop,
      `load_fetched()` for the write - about 60 ms of its 450. One read held for
      the run would do; the write is the larger half of it and stays.

- [ ] **Discussions, releases, commit comments.** *Decide: whether to open them
      at all.*
      The notifications source sees each arrive and skips it, counted. Nothing
      here can open one.

- [ ] **What "mine" means.** *Decide: whether a pull request you pushed to, or
      that carries you in `Co-authored-by`, is yours; neither costed.*
      "Mine" is author or assignee today.

- [ ] **An adopted branch that landed is news until read.** *Decide: whether
      reading the merge commit's committer is worth it, when it only says so for
      a real merge.*
      `merged_here` says the commits are in the base and not how.
