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
      | unread, no `snooze`, `read` not `""` | done | `set_read(url, moved_of(it))` |
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

- [ ] **One seen bit: `seen_of` answers everywhere, the floor answers for
      a missing stamp, and the inbox is a clock.** Designed 2026-09-16 from
      the findings below; not started.

      **What was found.** "Mark everything read" took three passes and 2277
      stamps because there are three answers to "is it unread", and they
      disagree:
      1. `Events.unread` keeps an inbox row while its `updated` - GitHub's
         `updated_at` off the poll or the thread's subject (`events.jl:535`,
         `:635`) - is past the read stamp (`sync!`, `events.jl:942`). That
         is `wl unread`, `wl read all`'s input, and the light rows.
      2. `wl read`, `wl snooze`, `wl archive`, `s` and `x` stamp `moved_at`
         (`read_up_to`, `marks.jl:272`; `mark_read_moved`, `:278`), the
         last movement off the wake table. A push, a label or your own
         comment after that leaves `updated > moved_at` on 1507 of 5553
         corpus rows, so nothing `wl read` writes can clear such a row from
         answer 1: 993 stamped, 366 stayed (`julia#62879`: moved 08-31,
         updated 09-16).
      3. The browser's `seen_of` (`filters.jl:316`) is the stamp against
         `moved_at`, with the source's `since` standing in for a missing
         stamp on a backlog row only (`:321`); every other lane with no
         stamp is unread - 1915 rows, mostly the retired lanes and `mine`
         rows from 2021-2025 that no clock ever carried and no `wl read`
         ever reached.
      The workaround in place: `read = "2026-09-16T15:41:54Z"` on 2277
      blocks in `data/local.toml` over data commit `ce0cf87`. Harmless, and
      the consolidation below folds it away.

      **Decided.**

      - **Answer 2 was right and answers 1 and 3 are made to agree with
        it.** The read stamp is compared against one thing, the item's
        last movement, `moved_of(it)`: `moved_at`, else `updated` for a
        light row that has no wake table (`poll_item` already writes it
        so), else nothing. `seen_of` reads it; `r`, `s`, `x`, `wl read`,
        `wl snooze`, `wl archive` stamp it (`r` still takes the max with
        the thread's `seen_up_to`). `read_up_to`'s three fallbacks become
        that one function plus `stamp(at)` for a synthetic row with no
        movement at all, and `mark_read_moved` builds its rows from the
        corpus *and* the inbox so a light row gets the same stamp `r`
        would give it. Nothing compares a read stamp against `updated`
        any more, which is what AGENTS.md's "never `updated_at`" already
        says.
      - **The inbox is a clock, never an answer.** An inbox row for a url
        the corpus has is there to say "ask again" (`stale_by`,
        `refresh.jl:1014`), and it has said it once the corpus row's
        `fetched_at` passes its `updated`. `sync!` stops pruning on
        `updated <= read`; the refresh drops, after `derive!`, every inbox
        row whose corpus row is both **consumed** (`fetched_at >=
        updated`) and **read** (`seen_of`). Unread stays, as today, so
        `expect!`'s `notified` history is kept while there is anything to
        witness; unanswered stays, so it is asked again. A light row is
        never pruned by reading: a mark on it promotes it (`refresh.jl:1323`),
        and the next run finds it consumed and read. The overlap re-read of
        a dropped row still starts a false expectation (`expect!` with
        `old === nothing`); that is today's hazard, unchanged, and the
        `inbox.threads` table in the sync plan above is what removes it.
      - **`wl unread` and `wl read all` are `seen_of` over the corpus and
        the light rows**, not the inbox listing. `Events.unread` is renamed
        to what it is - the poll - and the unread list is one function in
        `Worklog` that the browser's base list, the JSON dump and "read
        all" share. A second `wl read all` then finds nothing, by
        construction.
      - **Day zero reads zero, in every lane.** `since` becomes the floor
        for a row with no stamp whatever its lane. A row's source is what
        fetched it - `source_of(it)`: `backlog` and `activity` rows by
        repository, then owner glob (`baseline_of` as it is);
        `notifications` by itself; any other lane by its name - and every
        source names itself on first sight with `name_source!`: the repo
        sources as now, `notifications` where its cursor is first written,
        and every `lane` value present on a corpus row with no
        `source:` block (the three configured lanes, and the retired ones
        once). A source with no block is still unread, and `read = ""`
        still beats the floor - and marking such a row read again drops
        the key rather than stamping it, when `moved_of` is still at or
        under the floor: the floor answers, and the block goes back to
        saying nothing. That is the consolidation below applied to one
        row as it is marked. `read_head` is still written beside it. Only
        the plain read mark folds: `s` and `x` keep stamping, because
        `derive!` reads a snooze or an archive with no stamp as put away
        by hand and stamps it, and a hand-typed span counts from the
        stamp. First sight stays GitHub's time
        (`first_seen_at`), so on day zero every row is under the floor and
        a rebuilt `fetched.json` still does not read as everything moving.
      - **`moved_stamp` stays as it is; nothing stamps the observation
        clock.** The intent stated 2026-09-16 was a mark advanced to *the
        observation* and `wl read` stamping *now*. Checked against the
        cases and rejected, with two counterexamples that lose or re-show
        a comment:
        - `wl read` at now, `moved_stamp` unchanged: `read = 10:00`, a
          late-delivered comment dated 09:30 learned at 11:00 on a row
          whose mark was 08:00 is dated 09:30 (`m > high`), `09:30 <
          10:00`, read - lost. Stamped with `moved_at` (08:00) it is
          unread, as it is today.
        - `moved_stamp` dated `max(m, at)` so that a late arrival is always
          past any stamp: the bundle under the cursor is fresh for
          `fresh_minutes` (2), so a comment landing after the bundle was
          fetched, read live in the thread pane and marked `r` (`read =
          seen_up_to`, GitHub's time) is dated by the next refresh's clock,
          which is past the stamp - the item comes back for something
          you read, on every comment inside that window. That is the bug
          `moved_stamp`'s docstring records, at two minutes instead of an
          hour. GitHub's timeline is the one clock both observers see;
          dating by it is what lets the browser and the refresh agree.
        What "later information wins" needs is already the high-water
        rule: a movement dated at or before the mark is stamped `at`
        (`refresh.jl:405`). The residual - an event learned late whose
        time falls between `moved_at` and an `r` stamp that the thread's
        `seen_up_to` had pushed past it - is a review made before your
        own last reply on the same thread, and is read by any reading of
        "read". Written down so the observation clock is not tried again.
      - **`since` is a consolidation point, raised together and never
        lowered.** `wl read --consolidate [--dry-run]`: over corpus and
        light rows, `S'` is the newest `moved_of` among the *read* rows
        (stamp at or past the movement) that is below the oldest movement
        of any unread row with *no* stamp - light rows included. A row
        still unread against its own stamp bounds nothing and keeps it;
        `read = ""` is a statement and does the same. Then `since =
        max(since, S')` on every `source:` block, and `read` is dropped on
        every read row whose `moved_of` is at or below its source's new
        `since` - so `seen_of` answers the same for every row before and
        after, which is the test. `read` only: `read_head` stays, since
        the head you last saw is still the head you last saw and `p`
        reads it alone. Rows with a `snooze` are skipped, because a
        hand-typed span counts from the stamp (`wake_of`). Raised together
        rather than per source so that a row
        whose lane changes - a backlog issue that `assigned` claims -
        cannot flip by falling under a different floor; a source named
        later keeps its later day. Explicit and dry-run first; the
        refresh can call it once it has been watched. `marks.jl:141-148`
        is rewritten: `since` is how far a source is read by construction,
        the day it was named to begin with.
      - **The cursor stays what it is** (`source_cursors`): about
        fetching, never about reading.
      - **`new` is not a seen state.** `r["new"]` is "arrived this
        refresh", read by the change line and by one clause in
        `meta.jl:427` that stands in for `seen_of` and should not.

      **Plan**, in order, each step leaving the suite green:
      - [x] `moved_of` in `marks.jl`; `seen_of`, `keys.jl:493`,
            `writing.jl:706`/`:814`, `mark_read_moved` through it;
            `read_up_to` gone. Tests: the three call sites stamp what
            `seen_of` compares, on a corpus row, a light row and a
            synthetic one.
      - [x] `source_of` beside `baseline_of`; `seen_of` uses it for every
            lane; `name_source!` for lanes, `notifications` and unnamed
            lane values in the refresh. Tests: no stamp + `since` in every
            lane; a lane with no block is unread; `read = ""` beats the
            floor; a fresh `local.toml` names every source on the first
            run and nothing on the second.
      - [x] The inbox prune moves from `sync!` to the refresh, consumed and
            read. Tests: read + consumed dropped, unread kept, unanswered
            kept, light row kept then promoted then dropped; a row with
            `updated > moved_at` (the 366) is dropped after `wl read`.
      - [x] `unread_items(at)` in `Worklog`; `wl unread`, `wl read all`, the
            launch poll in `ui` and `inbox_items` on it; `Events.unread`
            renamed. Test: the 2026-09-16 scenario as a fixture - `read
            all` once, then zero.
      - [x] `wl read --consolidate [--dry-run]`. Tests: `seen_of` answers
            the same for every row before and after; never lowers; a
            stampless unread row pins it; a light row pins it; a snoozed
            row keeps its stamp; `read_head` survives; the 2277-stamp
            file folds to a handful of lines.
      - [ ] `meta.jl:427` drops `|| it.new`.
      - [ ] Docs: DESIGN "Marks" (the floor in every lane; the inbox as a
            clock), "Time" (nothing stamps the observation clock, with the
            two counterexamples), GitHub invariant 8 (the inbox row's life),
            "Decisions" (read by construction is per source, raised
            together; the observation clock); AGENTS.md item 3; README
            `wl read --consolidate` and what `wl unread` lists; the
            `since` comment in `marks.jl`; `Events.unread`'s docstring.
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
- [ ] **Quick actions on the checkout.** Whether the browser should run
      the git and `gh` commands that today mean `t` and typing: `gh pr
      checkout N` (which is what a pull request from a fork needs - the
      pane now names the fork, and `add_worktree!` is `git worktree add
      <dest> <branch>`, which only works for a branch that is already here),
      `git rebase <remote>/<base>` (`ensure_base!` already fetches the
      base for `p`; `mergeable  behind master` on the pane is the row
      that would want it), `git push --force-with-lease` after it, `gh pr
      ready`/`--undo`, re-running a failed check. Decide: **where** - a
      key opening a picker the way `'` does, the pane's rows once they can
      be acted on (see the metadata pane above), or `t` opened with the
      command typed and not sent, which is the one that leaves a conflict
      in the shell where it has to be resolved anyway; **which case** - the
      rule is lowercase looks or changes this machine and uppercase reaches
      GitHub, and a rebase is the first, a push the second, a checkout of a
      fork's branch both; **how it reports** - the status line is one row,
      and a rebase that stops is not one row. The worktree list (`"`) is
      the other candidate, since a checkout is a fact about a worktree
      and not about an item.
- [ ] **Audit what is said on stderr and on the status line, and where
      each should go instead.** Three channels today, none chosen per
      message. **stderr**, ~30 `@printf`s in `events.jl` and `refresh.jl`
      plus the theme and import complaints: fine under `wl refresh` in a
      terminal, but under `u` the child's stderr goes to a temp file and
      only its *last non-empty line* reaches the status row
      (`run_refresh`, `fetch.jl`), so a `FAILED:` lane, a `LAGGING`
      notice or a "not `is:open`" warning is gone unless it happened to
      be last; and in the browser itself a stray `println(stderr)` draws
      over the frame. **The status line**, 56 writers, one row, replaced
      by the next key - it is right for "copied 3 lines" and wrong for
      anything the reader has to act on later. **`errors.log`**, the one
      durable place, read as the footer's standing warning - only for
      exceptions. Sort every message by whether it is *transient* (the
      status row), *standing until seen* (a row the frame keeps - the
      notes area under the item, the import row's text, the diff's first
      row for the control-characters warning above), or *a record*
      (`errors.log`, or a `refresh.log` beside it that `u` keeps whole and
      the status row points at: "refreshed · 2 lanes said something ·
      see wl log"). `wl show`/`wl refresh` keep stderr; the browser should
      never write to it.
- [ ] **The refresh under `u`: keep what it said, then bring it in.**
      Two steps, the first cheap and the second what the audit above
      makes possible.
      1. **Keep the log.** `run_refresh` writes the child's output to
         `tempname()` and deletes it in its `finally`, so a refresh that
         exits 1 leaves `errors.log` saying "ProcessExited(1)" and nothing
         else - which is what the 2026-09-16 03:45 entry says, and by hand
         the same refresh exited 0 with a `gh: HTTP 504` retried in the
         middle, so the cause was a lane dying past its retry and is now
         unknowable. Write it to `data/refresh.log` instead, whole,
         overwritten per run (it is a record of the last refresh, not a
         history - `fetched.json` is the history), and have the status
         row say "refresh failed · see data/refresh.log" or, on success,
         how many lines said something. `wl log` could print it.
      2. **A Task, not a child.** `bin/refresh` is spawned because
         `refresh` reports on `stderr` and `redirect_stderr` is
         process-wide (`fetch.jl:484`). Once every `@printf(stderr` in
         `refresh.jl`/`events.jl` takes an `io` - the audit - the reason
         is gone, and what is left is the CPU: `wl` runs with no `-t`,
         tasks are cooperative, and a refresh parses and rewrites the 6 MB
         `fetched.json` and diffs 5,500 rows, which would hold the key
         loop for as long as that takes. Measure that part first (the
         `gh` waits already yield). If it is under a frame, `@async` and
         adopt the result directly instead of through the file watcher;
         if not, `-t auto` in `bin/wl` and `Threads.@spawn`, and then the
         corpus written by one thread while another draws from it needs
         the handoff `reload_data!` already is. Keep `wl refresh` and
         `bin/refresh` as they are: the cron and the hand run want a
         process.
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

- [ ] **SIGWINCH.** Nothing answers a resize: the frame is drawn at the
      `displaysize` read on the last key or wake (`run!`, `controller.jl:509`)
      and stays that shape until the next one, so a narrowed terminal
      shows a torn frame and a widened one a frame in its corner until
      something is pressed - and a hosted pane's child is told its new box
      only then (`iframe.jl:145`). Two ways to hear it: libuv's
      `uv_signal_t` on SIGWINCH by `ccall`/`@cfunction` - Julia wraps no
      signal but the loop it would fire on is the one `take!(ctrl.events)`
      waits on, so the callback can `put!` a `ResizeEvent` beside
      `WakeEvent`; or a `Timer` every 200 ms comparing `displaysize` and
      putting the same event on a change - one ioctl, no signal plumbing,
      and it works where a signal does not reach (a pane under tmux is
      resized by tmux, which still sends the signal, but a pty that does
      not is not unheard of). A `ResizeEvent` rather than a bare redraw so
      a view can drop what it cached at the old width: `Node.cw`, `st.diw`
      and `st.dpage` from the last frame, `rows(st.nodes, w)`. The
      Windows half is `displaysize` alone; there is no signal.
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
- [ ] **A diff's "contains control characters" warning is at the bottom,
      where a long diff pushes it off the screen** (seen once, 2026-09).
      It should be the first row of the diff - or in the node's header,
      which is on screen whenever the diff is - since it is a fact about
      what follows and a reason to read it differently. It was a Term.jl
      pull request of September 2026. Looked for and not found
      (2026-09-16): nothing in this program prints it, `gh pr diff` of
      FedeClaudi/Term.jl#302-#311 carries neither the phrase nor a raw
      control byte, and neither do the cached copies of #304/#306/#310;
      of the dependencies only JSON3 has the words, in an *exception* -
      "encountered unescaped control character in json" - which would
      reach the footer as the standing `errors.log` warning, not the
      diff; and not tmux, git or gh either - the bundled tmux 3.5.1, git
      2.54 and gh 2.98 binaries carry no such phrase past Go's URL
      errors. It was the `d` view, and the message offered a command-line
      flag to restart with that would permit it - which is a program with
      flags, and neither `wl` nor julia has one (`--help-hidden` checked),
      nor tmux; and `d` is `gh pr diff` read to a string, no pager, so no
      `less`. What is left is the terminal emulator itself, drawing the
      frame - or the exact wording, when it can be checked. Then
      `data/errors.log` on the machine it was seen on. Once found: a line of the text, which `diff_nodes` lifts to the top, or
      stderr, stitched on after.
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

The process:
- [ ] **It is called `julia` everywhere but its own sessions.** htop and
      `ps` show `julia`, tmux's automatic window name is `julia` (it reads
      the process's comm name, `#{pane_current_command}`), and the
      terminal title is `Julia` - juliaup's launcher sets it before exec
      and nothing here sets it after (`run!`, `controller.jl`). Only the
      `t`/`T` sessions carry the name, through `MUX_PREFIX[] = "wl"`. To
      do: the title with OSC 2 at `run!`'s start and back to nothing at
      its end (tmux takes that as the pane title; a terminal as its tab);
      the comm name with `prctl(PR_SET_NAME, "wl")` on Linux in `main`,
      which is what tmux's rename and htop's default column read, and
      has no macOS equivalent; and `exec -a wl` in `bin/wl` for `ps`'s
      full line, which only works if juliaup's launcher passes `argv[0]`
      through - check. `wl` and not `worklog`: it is the command's name,
      and the one already on the sessions.

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
