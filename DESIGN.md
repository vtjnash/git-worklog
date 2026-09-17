# Design

For whoever is changing the code - a person or a model. README.md says what
the program does; this says why it is shaped the way it is, which invariants
were each found by debugging a real failure, and which decisions are settled.
`git log` is the history; this is not.

## The one rule

**Facts are fetched, what a row wants is derived from facts by rules, and
judgement is written down.** A tag is a sentence on the row while its rule
holds and empty when it does not, none of them exclusive. What a red CI
really means, what the next action is, what is urgent - that is written into
`local.toml`, by you or by a model reading the same files, and nothing else in
the program decides it.

There used to be a *bucket* - one word per row, first rule to answer wins -
and the winning made it wrong: a closed row's word was `done`, so the question
somebody asked on it was never seen. Facts do not compete.

## Ownership

| file | owner | rule |
|---|---|---|
| `config.toml`, `themes/*.toml` | you | read, never written |
| `data/local.toml` | you and the program | **never rewritten.** Every write goes through a line-based editor (`state.jl`) that changes the keys it names inside the block it names and leaves every other line byte-identical. Tracked, in `data/`'s own repository |
| `data/fetched.json` | `wl refresh` | everything GitHub can answer again. Must stay safe to delete: nothing that cannot be rebuilt from GitHub goes in it |
| `data/cache/` | the browser | per-item reads with a TTL |

The line between the two data files is *what GitHub can answer again*. A fact
about what was done on this machine - a mark, a cursor, the day a repository
was named - is `local.toml`'s, even when it is the poll that writes it. That
is why the poll cursors and the `source:` blocks live there: for an evening
the backlog's read-by-construction stamp was in `fetched.json`, and the file
was no longer safe to lose.

`data/` is its own git repository so that the record has a history without
dirtying the code's tree on every refresh. **`git rev-parse --show-toplevel`
from inside `data/` answers with the data repo.**

## The corpus

The corpus is the index of everything that was ever in front of you, read or
unread. **Nothing leaves it.** A row is re-asked only when a clock says it
moved; otherwise it is kept as it was, derived against itself, so nothing
about it moves. The `read` and `filed` boxes hold the read and the filed; the
merge you never looked at stays a merge you never looked at, a day or a
season later.

It is populated three ways:

**The lanes** - `mine`, `review`, `assigned` under `[lanes]` - are GraphQL
searches for the **open work**, ~135 rows, fetched whole every refresh. They
do two things nothing else does as cheaply: enumerate the standing set (a
pull request of yours nobody has touched notifies nobody) and return the
bundle for every row in it - CI, review threads, the draft flag - which change
without any clock saying so. Each is walked by creation time (`created:>=`
the last row read, first page every time), never by offset; each is checked
before it runs: the sort put on, `created:` refused, `is:open` and your login
expected.

**The clocks** say what moved. Two: the repositories under `[events]`, polled
with `since=` and walked by stamp; and `/notifications`, when the token is a
person's. A thread that names you - mention, review request, assignment,
activity on yours, a thread you commented on - is fetched by url with its
bundle the first time it is seen, whatever repository, open or closed. A
watched repository's other traffic stays a **light row** (state, author,
comment count; no bundle) until it is looked at. That is what reaches a
question on an issue closed years ago, which no `is:open` search could. What no clock covers - a push, a label or a draft toggle on an open row
of yours in a repository nobody polls, on a machine whose token cannot read
notifications - is asked by url every refresh while it is open (`covered`).

**The backlog** is the whole open list of every repository under `[events]`,
imported the day it is named (and for all of them on `--backlog`). Backlog
rows are read by construction up to that day - the `source:` block in
`local.toml` says which day, one line per repository rather than a stamp per
row - and unread the moment one next moves. `backfill_days = 0` is policy:
the unread side starts at now. The same floor answers in every lane; see
"Marks".

**Light rows are promoted, not replaced.** When a poll or thread row enters
the open work, or is selected, it gets the bundle and keeps its `lane`,
`reason` and `why`. `sync!` merges a row over the entry at its url, so two
sources that each saw one url keep what only they knew.

**The poll is a witness for the notifications.** GitHub's notifications have
been seen to lag by an hour and, rarely, twelve; a late one stamped with the
event's time would be behind `cursor - overlap` and never asked for. For a
repository both polled and watched, a polled row that moved in a way that
notifies with no thread behind it after `EXPECT_GRACE` (15 min) is declared
the lag on stderr, and the source asks a day behind its cursor until the
thread arrives or `wl refresh --caught-up`.

### What the lanes ask for, and what they do not

Every field in `PR_FIELDS` has a reader that is not the refresh talking to
itself. Three are deliberately absent:

- **`mergeable` is computed lazily, and asking is what schedules it** - for
  every row on the page. Measured: a page naming it took 20-33s on four runs
  in twelve; a page without never left 5-8s. No lane asks for it and no row
  carries it. It is asked of one pull request when the cursor lands on it, by
  the same `merge_state` call the merge prompt makes, and shown the prompt's
  way (`behind master`, `conflicts with master`). It has its own cache window
  (`merge_minutes`): a clean answer that has gone stale is silent, so past the
  window it is not shown at all; a conflict holds until somebody rebases and
  is shown as long as anything else.
- **`reviewRequests`**: the bool it produced lost its last reader when the
  request became a time. The pane lists who is asked from the REST head.
- **The unresolved-thread count and `mergeable` are keys at no tracking
  level**: a thread being resolved is not news - what there was to resolve
  arrived as a comment or a review.

`statusCheckRollup`, `reviewThreads`, `reviews(last: 20)` and the timeline
were each cut and timed: within noise. Rate-limit cost is flat at 4 a page.

## Marks: read, snooze, archive are one rule

**An item is unread when it has moved since you read it.** "Moved" is the
wake table below. The other two marks are the read stamp with one thing added.

**One seen bit.** The read stamp is compared against one thing, the item's
last movement - `moved_of`: `moved_at`, else `updated` for a light row that
has no wake table, else nothing - and every mark stamps that same thing:
`r` (taking the max with the thread's `seen_up_to`), `s`, `x`, `wl read`,
`wl snooze`, `wl archive`. Nothing compares a read stamp against `updated`.
There used to be three answers to "is it unread" - the poll pruning its
inbox on `updated <= read`, the marks stamping `moved_at`, the browser
comparing against `moved_at` - and on 2026-09-16 "mark everything read" took
three passes and 2277 stamps because they disagreed: 366 rows whose
`updated` had moved past `moved_at` (a push, a label, your own comment)
could not be cleared by anything the marks wrote. `unread_items` is the one
list, `seen_of` over the corpus and the light rows, and `wl unread`, `wl
read all` and the browser's base list are on it.

**The floor answers for a missing stamp, in every lane.** A row with no
stamp is read up to the day its *source* was named - `floor_of`, off the
`source:` block - and unread if the source has no block. The source is what
fetched the row (`source_of`): the repository, then the glob over its owner,
for a `backlog` or `activity` row; `notifications` by itself; any other lane
by its name. Every source names itself on first sight: the repositories
when their lists are imported, `notifications` where its cursor is first
written, a lane the first time a corpus row carries it. Day zero reads zero.
Until 2026-09-16 the floor answered for backlog rows only, and 1915 rows of
the other lanes - retired ones, and `mine` back to 2021 - were unread with
nothing to read. `read = ""` still beats the floor; and a plain read mark
on a row the floor already answers for drops the key rather than stamping
it (`folded`), keeping `read_head`. `s` and `x` keep stamping, since the
refresh reads a snooze or an archive with no stamp as put away by hand.

**`since` is a consolidation point, raised together and never lowered.**
`wl read --consolidate [--dry-run]` raises every source's `since` to the
newest movement among the read rows that is below the oldest movement of
any stampless unread row - light rows included - and drops the stamps the
new floor answers for, so `seen_of` answers the same for every row before
and after. Together, so a row whose lane changes cannot flip by falling
under a different floor; explicit, until it has been watched.

**The inbox is a clock, never an answer.** An inbox row for a url the corpus
has says "ask again" (`stale_by`), and has said it once the corpus row's
`fetched_at` passes its `updated`. The refresh drops such a row once it is
also read; unread it stays, keeping `expect!`'s history while there is
anything to witness; unanswered it stays, to be asked again. A light row is
never dropped by reading - a mark on it promotes it - and `sync!` prunes
nothing. `new` is not a seen state: it is "arrived this refresh", read by
the change line and nothing else.

**A snooze is a wake time.** `s` writes the moment a span ends, resolved, so
`local.toml` says *when* and nothing remembers when it was set. The item is
read from then, and comes back at the wake time **or the moment it moves,
whichever is first** - a second reason to be unread beside the wake table, not
a hold against it. Waking is `seen_of` comparing `max(moved_at, wake)` against
the read stamp per frame: no write, no arbiter, no refresh, so two windows on
one dashboard cannot disagree. There is no `on-change` (that is `r`) and no
`forever` (that is `x`).

**A woken snooze is over: unread implies no snooze.** Every mark stamps the
last movement, which is under the wake, so a snooze left standing would keep
the row unread whatever was pressed - `r` said "marked read" and the row
stayed bold. So the refresh writes a woken row down (`read = ""`, the snooze
dropped, `read_head` kept), and `r`, `x` and `wl read` on one the refresh has
not reached drop the snooze with the stamp they write; `z` puts it back. A
snooze still to come is left alone by all of them. What ends keeps a trace:
`last_snooze` is the wake of the last snooze put on a row, written where a
snooze is set or ended and outliving it, so the pane can say there was one
and what brought the row back - `woke <when>`, `until <when> · moved before
the wake`, or `until <when> · cleared`. The one thing that wakes an item
that GitHub did not do and the row does not show already.

**An archive is a read mark that filters separately.** `x` stamps `archived`
and `read`. An archived item that moves is unread again - filing is not an
answer about whether a thing changed - but `show_ok` holds it out of every
list that does not name the `filed` box. That one asymmetry is why it is a
mark of its own: the backlog is `base + read`, and leaves the filed work out.

Only `r` writes `read_head`, the sha the read was made at, because only `r`
knows what you were looking at; `s`, `x` and `wl read` stamp "not now" and
leave it alone.

## Movement: the wake table

`track` is which rows of this table the refresh compares, key by key, against
the row it saw last time. `moved_at` is when it last saw a change at the
item's level.

| event | key | `normal` | `loose` | dated by | not counted when |
|---|---|---|---|---|---|
| somebody pushed | `their_head` | ✓ | ✓ | `head_at` | you are the committer |
| somebody commented | `their_comment_at` | ✓ | – | itself | you are the author |
| a human commented | `human_comment_at` | – | ✓ | itself | you, or a bot |
| somebody reviewed, or dismissed a review | `review_at` | ✓ | ✓ | itself | you did it |
| somebody asked you to review | `review_requested_at` | ✓ | ✓ | itself | you did it |
| somebody assigned you | `assigned_at` | ✓ | ✓ | itself | you did it |
| somebody closed, merged or reopened it | `state_at` | ✓ | ✓ | itself | you did it |
| your own CI went red | `ci_failed` | ✓ | – | the refresh that saw it | not yours, or it went green |

The rules behind the table, each of which cost a bug:

- **Nothing you did yourself is movement.** Every key is the newest one
  *somebody else* made, carried forward across your own - `comments(last: 1)`
  cannot see past your reply, so `their_comment_at` is carried. Being let off
  (a request withdrawn, an assignment removed) is not movement either; the
  `Removed`/`Unassigned` events are not fetched.
- **Every key says what it is, not what it was.** A push is a **sha**, not a
  clock: a rebase rewrites the committer date and a force-push of an older
  commit walks it backwards. A review is the **time the newest one arrived**,
  not the verdict and not a count: the verdict only moves because a review
  arrived. A request, an assignment and a close are the time of the timeline
  event (`event_at`: the newest of the given kinds whose actor is not you
  and, where it names somebody, names you).
- **A bool is an edge, not a value.** `ci_failed` counts becoming true and
  ignores clearing: going green either arrived as the push that fixed it or
  is a rerun of the same commit, and a rerun through pending would wake the
  item twice for one failure. Hashing a bool wakes on both edges, which is why
  there is no fingerprint any more: `moved_stamp` is the one arbiter.
- **A key that arrives is not an event.** A row the light path returned
  carries no `review_at` until an active lane claims it; a key added to the
  table appears on every row at once. Arriving with a time older than the
  movement already recorded is the record catching up; the mark stays put.
- **A re-request is a time.** A second review request on something you had
  read changes nothing else GitHub reports - `reviewDecision`, the review
  count, no comment - so as a bool it passed in silence.
- **`updated_at` cannot answer any of this.** It does not move when a check
  finishes and does move when a stranger relabels. Everything compares against
  `moved_at`.
- **Not in the table, on purpose:** `mergeable`, `unresolved`, labels,
  milestones, title edits, ready-for-review (arrives with the request that
  follows), a team being asked (the token cannot see it).

## Time

**The instant an operation is measured against is an argument, `at`, and it
is when the operation started.** An entry point defaults it to `utcnow()`;
everything it calls takes it as a required argument. A global frozen at
process start was wrong for a browser open all day; a live clock read on the
way *out* claims a moment after things it never saw. A default further in is
how the second failure gets back in. The same rule forbids storing a
time-derived number: `Item` carries `act` and `age(it, at)` is computed when
asked; the `3d ago` beside every date on screen is `ago_str` against the
frame's `at`, put on the metadata pane by `meta_lines` and on a header by
`rows` as it draws it, from a timestamp the node carries (`meta["at"]`) and
never from a string kept on the node - a thread is fetched once and read for
hours.

**Dated by the thing that moved.** A push and a comment carry the moment they
were made, so that is the stamp; CI has no clock and is stamped with the
refresh that first saw it differ. Dating a comment by the poll made a comment
read at 10:00 come back unread when the 11:00 refresh first saw it.

**Nothing stamps the observation clock.** Proposed 2026-09-16 and rejected:
a mark advanced to *the observation*, with `wl read` stamping *now*. Two
counterexamples, each of which loses or re-shows a comment:

- `wl read` at now, `moved_stamp` unchanged: `read = 10:00`; a comment dated
  09:30, delivered late and learned at 11:00, on a row whose mark was 08:00
  is dated 09:30 (`m > high`), and `09:30 < 10:00` reads it - lost. Stamped
  with `moved_at` (08:00), as it is, it is unread.
- `moved_stamp` dating a movement `max(m, at)` so a late arrival is always
  past any stamp: the bundle under the cursor is fresh for `fresh_minutes`,
  so a comment landing after the bundle was fetched, read live in the thread
  pane and marked `r` (`read = seen_up_to`, GitHub's time) is dated by the
  next refresh's clock, past the stamp - back for something you read, on
  every comment inside that window. That is the bug `moved_stamp`'s
  docstring records, at two minutes instead of an hour.

GitHub's timeline is the one clock both observers see; dating by it is what
lets the browser and the refresh agree. What "later information wins" needs
is already the high-water rule: a movement dated at or before the mark is
stamped `at`. The residual - an event learned late whose time falls between
`moved_at` and an `r` stamp that the thread's `seen_up_to` pushed past it -
is a review made before your own last reply on the same thread, and is read
by any reading of "read".

**By GitHub's time wherever a stamp will meet one GitHub wrote**, and by an
*event's* time wherever there is one. `r` stamps `max(moved_at, newest
visible event in the thread)` - all times GitHub wrote. `s` and `x` stamp
`moved_at` alone. The poll cursor is the newest `updated_at` a source
returned, asked again from behind it - 5 minutes for REST, 15 for search -
because GitHub does not promise a response is a snapshot as of its newest
row, and the overlap is free on an inbox keyed by url. The two places that
need a *now* with no event to stand in - the refresh's `at`, and a source's
first sight - take the `Date` header of a free request (`/rate_limit`). What
stays on the machine's clock is only compared with itself: a snooze's wake
against the frame, the cache's ages. **No offset is measured and none is
applied** - an offset was tried and deleted the same hour.

## Tags

The refresh derives each as a sentence or `""` - `reply`, `edits`, `ready`
and `review` in `apply_state!`, `second` in `derive!` - and the browser shows
them as the tag axis. None reads the state except to be empty on finished
work, and the one that reads another is `second`, which is withheld from the
pile (`in_pile`: a clock lane with no `reply` owed):

| tag | rule |
|---|---|
| `edits` | changes requested, unresolved threads, red CI, or the label |
| `ready` | approved, green, not a draft |
| `review` | asked, and not reviewed since their last push |
| `reply` | mentioned within `reply_days` and the last comment is not yours - open or closed. Deliberately narrow: plain `commented:` never qualifies, because where you are effectively the maintainer that is forty items a week |
| `second` | the author acted - opened it, or commented - and nobody has answered with a comment or a review for `second_look_days` *working* days. A push is not an action. Never on the pile, never on finished work. On by default because asking for it would defeat it: the failure it catches is work that goes quiet without anybody deciding it should |
| `snoozed` | a wake time still to come - a tag over read rows, not a box |
| `touched`, `drafts` | marks |

What the bucket had that none of these is: `draft` (a field), `blocked` (a
label), `issue` (`kind`), `stale` and `needs-nudge` (the second look says
"quiet 65 work days" in words), `firehose`/`mentioned` (the `lane` axis).

## The browser's model

**`show` is one axis that only adds.** Four boxes - `unread, open` · `read` ·
`filed away` · `closed or merged` - each brings its own kind of row beside the
others, and none can take another's away. The first and last are checked when
nothing has been asked, so the screen cannot be emptied by accident, and `c`
lands there rather than on the corpus. The number beside each is a delta:
what checking it would bring, or unchecking it would take. `read` is asked of
unfiled work only, because filing stamps read - a box that insisted on both
would do nothing (`show_ok`). Three axes that could each be turned off were
merged into this one because turning one off was never what anybody wanted.

**A view names an axis whole.** `show = ["filed"]` is the filed work alone;
naming no `show` keeps the default. An unknown axis or value is reported, not
ignored: a misspelt one silently widens a view, and did.

**Newest first is policy, not a default.** Serving the second-look list
newest-first answers new work while the author still has the change in their
head, and an old row is at the bottom rather than in the way. Oldest-first is
uniform slowness. No fourth sort; `w` cycles three.

**A place replaces a place; a dialog stacks on one.** `isdialog` is the
distinction and `push_place!` enforces it. Going somewhere means leaving where
you were; a dialog answers a question and hands the keys back.

**The side without the focus gets no keys.** Which keys belong to which side
is answerable by looking at which side is lit. A hosted pane's reading side
keeps three (`tab` back, `esc`/`t`/`T` out); through `^]` it runs the other
way. `tab` moves the keyboard between two things on screen everywhere, which
is why the merge composer cycles with `^x`.

**A capital reaches GitHub; lowercase does not.** The line is *remote*, not
*writes something* - `r` and `s` write `local.toml`. `z` may undo the
lowercase set and must never offer to undo a capital.

**A composer is drawn beside what it is about**, in the same split `t` and
`T` use, wherever the screen has 150 columns; the machinery was never about a
child process. `q` in a composer comes back to the message, because `q`
elsewhere ends the program.

**A colour is a role, never an escape.** Every SGR sequence comes from a
field of `THEME`; a call site names what the colour means. A table of colours
built at top level captures the theme before it is read, so `rev_mark`,
`ci_color`, `range_mark` are functions. A role drawn inside another colour
needs its `<role>_off` closer, or it ends the background it was drawn on.
Adding a role is a field in `Theme` and a line in every theme file; the suite
asserts both directions. Term's two palettes - `TERM_THEME[]` and the
`CodeTheme` `Dict` that tree-sitter highlighting actually reads, unreachable
from `set_theme` - are set from the same file. With no theme, Term's own
resets are stripped too.

**A row index is only meaningful against the width it was measured at.**
Beside a hosted pane the detail is half the screen; `detail_pane` records the
width and page it was drawn at, and every key that indexes rows reads that.

**A resize is an event, not a tick.** SIGWINCH reaches the loop through
libuv's `uv_signal_t` (`watch_winch!`) as a `ResizeEvent`, and the frame is
drawn again at the new `displaysize`; a hosted pane resizes its child in
`onresize!`. No cache has to be dropped, because every width-keyed one -
`Node.cw`, `st.diw`, `st.dpage` - is checked against the frame that reads it.
The alternative was a timer comparing `displaysize` five times a second for
the life of the browser, and nothing here runs on a cadence of its own.

**Coming back to an item lands where you were**, per item and per mode; a row
leaving the list under you (`r`, `x`, `s`) leaves the cursor in place, so an
inbox is read by pressing `r`. A new list - view, filter, query - opens at the
top.

## Showing what changed

Three things answer it, all read off the mark `r` leaves:

- **The thread opens on a rule.** `r` marks read up to the newest event it
  showed, so everything before the stamp was on screen. Nothing records
  *which* comment you got to: a second answer can disagree with the first.
- **The thread is one activity list**: commits drawn among the comments in
  order, a run nobody spoke between folded into one `↑ pushed N commits`.
  `commits(last: 30)` beside the REST reads, in the thread's own cache entry.
- **`p` diffs `read_head` against the head now.** Only added to (old head
  still in history, base unmoved): plain `git diff`. Otherwise `git
  range-diff`, **measured from the base branch on each side** - `old...new`
  measures from where the heads meet, so a two-commit branch rebased over ten
  of master reports twelve. The base ref is fetched first, because a stale
  copy puts the commits it has not heard about inside the answer. A
  force-pushed head is fetchable by sha (measured: fourteen months old), so
  "gone" is not a state; a failure is the network. Needs a pinned checkout:
  GitHub compares refs, and the head you saw is not one.

## What is said, and where

Three channels, and every message chooses one by what the reader does with
it. Audited 2026-09-17; before that there were three channels and no rule,
and a `FAILED:` lane reached the status row only if it happened to be the
child's last line.

- **The report** is what an operation says as it runs: a lane's count, a
  retry, a lane that is not `is:open`. It goes to `report()`, the `IO` of the
  report opened for the current task (`reporting`, in task-local storage) or,
  failing that, the process's (`REPORT[]`): stderr for a command, `devnull`
  for the browser, which sets it before its first frame because a line on
  stderr draws over the frame. A line the reader has to act on goes through
  `warning()` - the same stream, counted - and `refresh`'s summary line says
  how many there were, so `run_refresh` never reads the child's text back.
  Under `u` the report is `data/refresh.log`, whole, and `wl log` prints it.
- **The status row** is for what just happened and will not happen again -
  "copied 3 lines", "posted", "sorted by age" - and is replaced by the next
  key. It is wrong for anything the reader has to act on later, which is why
  a send that fails keeps its composer open with the failure on the
  composer's row (`Unsent`) instead of popping and leaving one line here.
- **Standing** notes stay until dealt with: `errors.log`, written by
  `logerror!` for exceptions and read as the footer's warning until the file
  is deleted; and a theme that did not load as written (`THEME_NOTES`), in
  the same place behind it. `standing_note` is the one reader of both.

The browser writes nothing to stderr. The one exception is `run!` refusing to
start without a terminal, which is before there is a frame.

## Code layout

| | |
|---|---|
| `cli/src/gh.jl` | the GraphQL lanes, shelled through `gh api graphql` (GitHub.jl has neither GraphQL nor search) |
| `cli/src/events.jl` | `Events`: the clocks, the by-url fetch, the token lookup |
| `cli/src/refresh.jl` | normalize, the wake table, the tags, the snapshot diff |
| `cli/src/cli.jl` | the `wl <command>` surface and `USAGE` |
| `cli/src/ui.jl` | `Item`, and the adopted branches synthesized from `local.toml` |
| `cli/src/marks.jl`, `state.jl` | what you did to an item; the line-based `local.toml` editor |
| `cli/src/util.jl`, `pyjson.jl` | `oneline`, `table_key_order`; JSON written the way the Python port did |
| `cli/src/fetched.jl` | `fetched.json` |
| `cli/src/controller.jl` | owns stdin; input decoding (`readevent`); the `View` protocol; dialogs |
| `cli/src/browse/` | the browser; `Worklog.jl`'s include list is the index |
| `cli/src/theme.jl`, `themes/` | roles and the spec language |
| `cli/src/repos.jl`, `ci.jl`, `cache.jl`, `paneview.jl` | checkouts and worktrees; Buildkite; the TTL cache; a `TermIFrame` beside the thread |
| `TermInput.jl/` | submodule: `TextBuffer`, `TextArea`, `LineInput`, the key vocabulary, the dialog box, `CHROME`, `suspend`, and the escape-aware measuring (`awidth`/`afit`/`apad`/`awrap`) |
| `TermIFrame.jl/` | submodule: tmux sessions, the control-mode client, `bordered`. Depends on `TermInput` for measuring, never the other way |
| `cli/precompile/` | `WorklogPrecompile`: `Worklog` plus a `@compile_workload` of the browser's path. `bin/wl` loads it; the suite never does |

Everything is one Julia module, so the browser calls the same functions the
commands do rather than shelling out to itself.

**Order is not cosmetic in either include list**: a type must exist before
methods on it, and several testsets leave state the next reads. **Cut above a
definition, never into it**: a file that ends in `"""` strands a docstring,
which is a legal no-op nothing complains about.

**Splitting a file moves nothing; splitting a package is a design change.**
`TermIFrame` went across as it was. `TermInput` did not: the editing model
came out from under the view, the callbacks became returned actions
(`:ok`/`:unhandled`, nothing else - "finished" is the host's policy, not the
widget's), and the keys this program owns became `:unhandled`.

### The precompile wrapper

Separate package, not a workload in `Worklog`: a workload runs whenever its
package precompiles, and `Worklog` precompiles on every edit. Hand-written,
not the suite: the suite spawns tmux, `vi` and git repositories, and a
failing test would stop `wl` starting. Invented items, hermetic paths, a
`catch` around everything. **It must not leave a process running**, or
precompilation stops on "waiting for IO": `hermetic` takes the binaries away
(empty `PATH`; `WORKLOG_TMUX` at a path that does not exist), which survives
somebody adding a key; `drain_fetches!` at the end is the other half.
`PrecompileTools` is kept: the macro is worth 0.6s a launch over a bare `let`,
and Base has no equivalent.

**Its manifest is `cli/Manifest.toml` plus one entry**, never resolved fresh:
copy, fix the two relative `../` paths, `Pkg.resolve()`. Check:

```bash
diff <(grep '^\[\[deps\.' cli/Manifest.toml | sort) \
     <(grep '^\[\[deps\.' cli/precompile/Manifest.toml | sort)   # one line
```

`Term` 2.2 costs 0.35s of every launch through `Highlights` importing `Pkg`;
taken for the tree-sitter renderer.

## Testing

No TTY, so the UI is tested by construction:

- `render(view, w, h)` is pure; `handle!(view, key, ctrl, at)` returns an
  action; `readevent(io)` is a pure function of a byte stream, driven from an
  `IOBuffer`; `onmouse!` takes screen coordinates after a render, since the
  map goes through `layout` and `st.hdr`. Strip SGR and OSC 8 before measuring.
- **Every path the program writes through is redirected at the top of the
  run** - `LOCAL`, `FETCHED`, `CACHE_DIR` - and the rule is that all of them
  go, not that each leak is fixed as found. A testset that repoints `LOCAL`
  puts it back to the sandbox, never to `""`. `errors.log` is the deliberate
  exception: deleted at startup, asserted on.
- **The corpus is `cli/test/fixture.json`**, 29 real rows, made by
  `fixture.jl` from `WANTED` - properties with names. **Never search the
  corpus for a row with a property**; ask `fixture_item("an issue")`. A hunt
  that stops holding is `nothing` as an index - an error, which takes the file
  down and silently stops every file after it. `suite/corpus.jl` is the one
  sweep over the real `data/`, over every row and never for one, and skips
  itself when there is none.
- **Skip, never fail**, for anything needing tmux; one unguarded assertion
  hid seven files in every sandbox without it. The bundled `tmux_jll` means
  nothing has to be exported; `WORKLOG_TMUX` overrides it, which is how a
  particular build gets tested.
- The suite pins `themes/default-ansi.toml`: with `theme = ""` every
  assertion about a bold row passes by `occursin("", x)`.
- A background fetch signals with a `WakeEvent`: `take!(ctrl.events)` then
  `onwake!`.
- Time is an argument: a test says when now is by passing it.
- `--project=cli`, never the wrapper. `latency.jl` builds the image and spawns
  cold processes and is deliberately not in the suite.

Harness:

```julia
items = Worklog.loaditems()
st = Worklog.BState(items, "worklog")
ctrl = Worklog.Controller(); ctrl.running = true
st.wake = () -> Worklog.wake!(ctrl)
Worklog.load_nodes!(st); take!(ctrl.events); Worklog.onwake!(st)
```

## Invariants found by debugging

Do not simplify any of these away.

### GitHub

1. **Paging by offset is unsafe on a list that moves.** `Link: rel="next"`,
   `gh api --paginate`, `GitHub.issues`, GraphQL `after:` all walk a
   collection being reordered (168 vs 612 rows on identical runs). Every walk
   here is cut by a stamp the walk holds: lanes by `created:>=`, polls by
   `since=`/`updated:>=` ascending so a mover is read again past the floor.
   Only a page inside one second is walked by offset.
2. `search(type: ISSUE)` returns **0** unless the query carries `is:issue` or
   `is:pr` - not about `assignee:`; a free-text lane did it too.
3. A search returning Issues against a fragment that only spreads `... on
   PullRequest` yields field-less `{__typename: "Issue"}` stubs, no error.
4. Two qualifiers on one field are **or**ed: `created:>=X` beside a lane's
   own `created:` is the whole set again.
5. Search truncates at 1000; a walk cut by stamp steps past it. Long walks
   hit transient 502s; pages retry.
6. A search cursor must carry a **time**: `updated:>2026-09-02` means after
   the end of that day.
7. The `Date` header is when the response was *generated* - the request's
   end.
8. `/notifications`: 50 a page whatever is asked, newest first; `since=` is
   compared against when the thread last *notified*, strict; a thread's
   `updated_at` is delivery time, 2-46s after the event - so a fetched thread
   carries the subject's clock, and "moved" compares the clock against the
   row's `fetched_at`, taken *before* the request. `all=true` returns read
   threads. `latest_comment_url` is never a review comment. Nothing here reads
   `unread` or `PATCH`es a thread: the cursor is ours. An inbox row's life:
   written by a source, merged over by the next, kept while it is unread or
   unanswered, and dropped by the refresh once the corpus row has been
   fetched past it and is read - never by the poll, never on `updated`
   against a stamp.
9. `mergeable`: see above. A merged or closed pull request answers `UNKNOWN`
   for good.
10. `viewerDefaultMergeMethod` is viewer-scoped history, not a setting: the
    same allowed pair answers `SQUASH` on one repository and `MERGE` on
    another. `M` opens on squash, then merge, then rebase, and says so.
11. `team:ORG/TEAM` and `team-review-requested:` return 0 even with a token
    that can list the team. `/user/teams` needs `read:org`.
12. `requestedReviewer` can be null (a deleted account).
13. **Two failure classes that are not 5xx and need retrying**: the secondary
    rate limit (minutes, not seconds: 1m/2m/4m) and `unexpected end of JSON
    input` (a truncated body). Found by deleting `data/` and starting from
    nothing. And a failure line that truncates must truncate the derivable
    part, not the news.
14. An `issueCount` of 0 beside 100 nodes has happened: a successful response
    can still be wrong.

### Term.jl (v2.2, pinned)

- Braces are markup. `parse_md` doubles them inside a code span and nothing
  collapses them (`render_md` undoes it); in prose it does not, and
  `apply_style` deletes them (`escape_source` doubles them first). Both paths
  end at one brace. Filed as FedeClaudi/Term.jl#304.
- `parse_md` does not wrap a line containing inline code; `awrap` does. #247
  is open on Term's own wrapping.
- `Panel` measures markup, not what prints; not used for layout. A `{`
  somebody typed into a composer is not a tag.
- `parse_md` wraps at the width it is handed, so a paragraph arrives in
  pieces; `nodelines` renders a second time at a width nothing reaches and
  aligns the two, which is what makes a copy paste as paragraphs. The wide
  line is only the better source when it *joined* several narrow ones.
- An empty list item is a `BoundsError` (#305); a table nested in a list is a
  `MethodError` (#306); a code span in a table header is drawn as a block
  (#309). `for_term` works around the first two, a `Paragraph` around the
  third.

### Julia's Markdown

- `Markdown.parse` opens emphasis on an underscore inside a word, which
  CommonMark forbids; it takes two to pair, so `deliver_result and
  connect_to_peer` loses both. `escape_source` escapes them outside code.
  Filed, with a fix, as JuliaLang/julia#63081 (open).

### tmux

The binary is `tmux_jll`'s (3.5.1), or whatever `WORKLOG_TMUX` names; `PATH`
is deliberately not consulted. It buys nothing - sessions live in a server
addressed by a socket, so any binary sees the same ones and the user's own
`tmux ls` lists these - and it would cost knowing what we are talking to:
`capture-pane -e` keeps OSC 8 from 3.4 and drops the url in 3.1c. What it
cannot pin is the *server*: where one is already running on the socket, its
version renders `capture-pane` and evaluates the formats. `mux_cmd`, not a
path: the JLL's `Cmd` carries the library and terminfo paths, and the bare
path fails with `libutf8proc.so.3: cannot open shared object file`.

Each of the following returns success and the wrong answer:

- A session name has `.` and `:` rewritten to `_`; `mux_name` does the
  same.
- Targets are `=name`, a pane `=name:`, **unquoted**. Formats **must** be
  quoted: `#` starts a comment.
- Attaching in control mode answers with a reply block before anything is
  asked; `mux_sync!` drains to a token nothing else could produce.
- `%output` escapes only bytes below 0x20 and backslash, as octal; decode on
  bytes.
- `attach` refuses to nest; `switch-client` is what works inside tmux.
- `$TMUX` decides which server; inside byobu the sessions land on byobu's.
- `send-keys` writes into the pty as input, so tmux's own `mouse` setting has
  no bearing; ask `mouse_any_flag` and translate the coordinates.
- `capture-pane` reads cells, so a sequence that paints none - OSC 52 - is
  lost from the grid. It does arrive in `%output`; `passthrough` relays that
  one and nothing else.
- A nested tmux gets no mouse unless *it* has `mouse on`. Not ours to fix.

### The terminal

- A one-row field must hold one row: `showerror` embeds a newline, and one
  element holding a newline scrolls the screen and shifts every mouse click.
  `oneline`.
- `capture-pane` says nothing about the cursor; `viewcursor` puts the
  terminal's where the child's is.
- **A hyperlink is not somewhere to write another one.** `linkify` runs on
  the finished frame; a url inside a comment header's OSC 8 payload
  terminated it early and the row came out 224 columns wide. It cuts the
  frame on OSC sequences and substitutes only between them.
- A key code is **the bytes that arrived**, packed big-endian, and `K_BASE`
  is `1 << 32`. Starting the key range at `0x110000` let a malformed
  four-byte sequence assemble to `K_LEFT`; rejecting non-codepoints is wrong,
  because Julia does not need a decoder to throw anything away.
- `REPL.TerminalMenus.readkey` cannot see a mouse report and drops any
  sequence it does not know as a bare `Escape`. `readevent` consumes what it
  cannot parse. Three spellings of Alt-arrow are decoded.

### Processes

- **A background fetch has to be findable.** Everything goes through
  `fetching`, keyed by what it fetches; `@async` into a field is overwritten
  by the next load and cannot be joined or asked whether it failed.
- **An alias is not reachable from a program.** `T` runs `$SHELL -ic claude`:
  `-c` without `-i` reads no rc *and* has `expand_aliases` off; `exec claude`
  looks up `exec`. Reading the alias is the point - a copy in `config.toml`
  would drift.
- `gh_run` calls `Sys.which` before spawning: a failed spawn with an
  `IOBuffer` on stdin leaves a pipe with an orphaned writer and a process
  handle in async close that nothing owns, which is what hung precompilation.
  `robustness.jl` counts libuv handles across the call.
- Every git call runs under `LC_ALL=C`: `%(upstream:track)` is translated,
  and parses as no divergence in a translating locale.
- `bin/wl` ignores SIGHUP in the shell, because an ignored disposition is the
  one thing that survives `exec`.
- **juliaup's launcher does not pass argv[0] through**: it execs the real
  binary under that binary's own path, so `exec -a wl` in `bin/wl` names
  nothing. The process names itself instead: `uv_set_process_title` in `main`
  rewrites the argv area - `ps`'s line and tmux's automatic window name - and
  the comm name with it; `prctl(PR_SET_NAME)` reached only the second. The
  terminal's title is OSC 2 in `run!`.

### local.toml

- The blank line separating blocks lives *inside* the block; filtering it out
  took a line from the user's file on every write. `set_fields` moves edited
  keys to the end of their block, so `z` restores the value exactly and the
  file only nearly.
- `read = ""` is a key present and empty - said unread - which `get_field`
  tells from an absent one. That is what lets a backlog row be marked unread
  and stay so.

### Buildkite

- Job discovery must use `/data/jobs`; the per-build JSON returns an empty
  jobs array to an anonymous caller. Logs are HTML: drop `<time>` before
  stripping tags, decode numeric entities too.

## Decisions not to re-litigate

- **No sweep heuristic.** "Moved recently" is not a hint for what moves next;
  the bounded set re-asked whole is the open work itself.
- **No source axis** (direct · participating · watching). Those are GitHub's
  filters and GitHub is where to go for them; what subtracts the pile is
  dismissal, one item at a time, recorded, undoable.
- **No bucket**, and no `wl next`: the tags it handed out were the marks the
  browser writes one row at a time, where the row can be read first.
- **Newest first**, no fourth sort, no ceiling on the second look.
- **Read by construction is a fact about the source**, one line per
  source, not a stamp per row - in every lane, and raised together by
  `wl read --consolidate`, never per source and never lowered.
- **Nothing stamps the observation clock.** Every mark stamps the movement,
  GitHub's time; see "Time" for the two counterexamples, written down so
  it is not tried again.
- **The lanes stay GraphQL**; REST search could answer the three queries but
  not the bundle. GraphQL is slow per row (150-200ms a node), not per request.
- **`p` uses a checkout**; there is no endpoint.
- **`^u` kills to the start of the line** (readline), not the whole line.
- **The mouse is owned**, `m` gives it back.
- **`Term.jl/` beside this checkout is ignored, not a submodule**; Term comes
  from the registry.

## Conventions

Commit as `worklog: brief summary`, prose body saying the purpose - not a file
list, not a test plan - ending with the trailer the session is given. Write
the body to a file and `git commit -F`; backticks in a heredoc are mangled by
the shell.

**What a read-through turns up**, every pass so far: counts that stopped
being true (nine states described as five); arguments that outlived the code
needing them; dead things left behind by what replaced them; defects the
prose walked straight past; and a rule enforced by matching text where
identity could enforce it instead - the footnote links were made by replacing
a url's display form in the finished frame, which could not tell two urls
apart once they elided to the same string, and the fix was to make the link
where the row is written.
