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
| `config.toml`, `themes/*.toml` | you | read, never written. The shared half of the config: every key with its default, naming nobody - the lanes say `@me` |
| `data/config.toml` | you | your half, read on top of the shared one: login, theme, the repos you poll and pin. Written **once**, from `config.user.toml`, by the first `wl` that finds none (`seed_config!`), with `login` filled from `/user`; never again. The merge is two levels: a table merges key by key, anything under a key replaces whole. Tracked, in `data/`'s own repository |
| `data/local.toml` | you and the program | **never rewritten.** Every write goes through a line-based editor (`state.jl`) that changes the keys it names inside the block it names and leaves every other line byte-identical. Tracked, in `data/`'s own repository. One kind of block the poll writes whole: a notice, `["notice:<id>"]`, which dismissal removes whole (Marks) |
| `data/fetched.json` | `wl refresh` | everything GitHub can answer again. Must stay safe to delete: nothing that cannot be rebuilt from GitHub goes in it |
| `data/cache/` | the browser | per-item reads with a TTL |
| `data/view.toml` | the browser | where it was when it last closed: the filter and its order, the item, the mode. Written whole on the way out (`save_view`), read once at launch (`restore_view!`), the item as the guest when the list does not show it. Not `local.toml`'s: it is nothing without the corpus beside it, and where you were is not judgement. Ignored |

The line between the two data files is *what GitHub can answer again*. A fact
about what was done on this machine - a mark, a cursor, the day a repository
was named - is `local.toml`'s, even when it is the poll that writes it. That
is why the poll cursors and the `source:` blocks live there: for an evening
the backlog's read-by-construction stamp was in `fetched.json`, and the file
was no longer safe to lose.

A **notice** - a notification that is not an issue or pull request - is
the case that rule was written for. Once the cursor is past a thread nothing
can ask for it again, so an unread one kept in `fetched.json` was lost with
the file; and it is not in the inbox either, whose rows everything that
reads them - `stale_by`, the refresh's `involved` ask, `expect!` - would ask
GitHub about. So each unread one is a block in `local.toml`, written whole
by `sync!` and removed whole when it is dismissed: the set that stays small,
where a record of the dismissed would only grow.

`data/` is its own git repository so that the record has a history without
dirtying the code's tree on every refresh. **`git rev-parse --show-toplevel`
from inside `data/` answers with the data repo.**

## The corpus

The corpus is the index of everything that was ever in front of you, read or
unread. **Nothing leaves it.** A row is re-asked only when a clock says it
moved; otherwise it is kept as it was, derived against itself, so nothing
about it moves. The `done` and `filed` boxes hold the done and the filed; the
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
rows are done by construction up to that day - the `source:` block in
`local.toml` says which day, one line per repository rather than a stamp per
row - and unread the moment one next moves. `backfill_days = 0` is policy:
the unread side starts at now. The same floor answers in every lane; see
"Marks".

**Light rows are promoted, not replaced.** When a poll or thread row enters
the open work, or is selected, it gets the bundle and keeps its `lane` and
`reason`. `sync!` merges a row over the entry at its url, so two
sources that each saw one url keep what only they knew.

**The poll is a witness for the notifications.** GitHub's notifications have
been seen to lag by an hour and, rarely, twelve; a late one stamped with the
event's time would be behind `cursor - overlap` and never asked for. For a
repository both polled and watched, a polled row that moved in a way that
notifies with no thread behind it after `EXPECT_GRACE` (15 min) is declared
the lag on stderr, and the source asks a day behind its cursor until the
thread arrives or `wl refresh --caught-up`. A row new to the inbox is not a
new item - the inbox drops a row once it is read, and a label swept over
seventeen merged pull requests held the ask wide for a week - so "new" is
`created` inside the window the poll asked for; and an expectation whose
row the refresh has dropped is let go, having nothing left to arrive on.

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
wake table below. The other two marks are the done stamp with one thing added.

**One seen bit.** The done stamp is compared against one thing, the item's
last movement - `moved_of`: `moved_at`, else `updated` for a light row that
has no wake table, else nothing - and every mark stamps that same thing:
`e` (taking the max with the thread's `seen_up_to`), `s`, `x`, `wl done`,
`wl snooze`, `wl archive`. Nothing compares a done stamp against `updated`.
There used to be three answers to "is it unread" - the poll pruning its
inbox on `updated <= read`, the marks stamping `moved_at`, the browser
comparing against `moved_at` - and on 2026-09-16 "mark everything read" took
three passes and 2277 stamps because they disagreed: 366 rows whose
`updated` had moved past `moved_at` (a push, a label, your own comment)
could not be cleared by anything the marks wrote. `unread_items` is the one
list, `seen_of` over the corpus and the light rows, and `wl unread`, `wl
read all` and the browser's base list are on it.

**The floor answers for a missing stamp, in every lane.** A row with no
stamp is done up to the day its *source* was named - `floor_of`, off the
`source:` block - and unread if the source has no block. The source is what
fetched the row (`source_of`): the repository, then the glob over its owner,
for a `backlog` or `activity` row; `notifications` by itself; any other lane
by its name. Every source names itself on first sight: the repositories
when their lists are imported, `notifications` where its cursor is first
written, a lane the first time a corpus row carries it. Day zero reads zero.
Until 2026-09-16 the floor answered for backlog rows only, and 1915 rows of
the other lanes - retired ones, and `mine` back to 2021 - were unread with
nothing to read. `read = ""` still beats the floor; and a plain done mark
on a row the floor already answers for drops the key rather than stamping
it (`folded`), keeping `done_head`. `s` and `x` keep stamping, since the
refresh reads a snooze or an archive with no stamp as put away by hand.

**`since` is a consolidation point, raised together and never lowered.**
`wl done --consolidate [--dry-run]` raises every source's `since` to the
newest movement among the done rows that is below the oldest movement of
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
the done stamp per frame: no write, no arbiter, no refresh, so two windows on
one dashboard cannot disagree. There is no `on-change` (that is `e`) and no
`forever` (that is `x`).

**A woken snooze is over: unread implies no snooze.** Every mark stamps the
last movement, which is under the wake, so a snooze left standing would keep
the row unread whatever was pressed - `e` said "done" and the row
stayed bold. So the refresh writes a woken row down (`read = ""`, the snooze
dropped, `done_head` kept), and `e`, `x` and `wl done` on one the refresh has
not reached drop the snooze with the stamp they write; `z` puts it back. A
snooze still to come is left alone by all of them. What ends keeps a trace:
`last_snooze` is the wake of the last snooze put on a row, written where a
snooze is set or ended and outliving it, so the pane can say there was one
and what brought the row back - `woke <when>`, `until <when> · moved before
the wake`, or `until <when> · cleared`. The one thing that wakes an item
that GitHub did not do and the row does not show already.

**A snooze keeps where it stamped, for the thread.** The thread's rule is the
done stamp, and a snooze writes that stamp and its wake takes it away - so a
thread that woke had no rule, and nothing said what had moved while it slept.
`s` and `wl snooze` keep the stamp they wrote (`snooze_done`) and the one they
wrote over (`snooze_read`), both outliving the snooze as `last_snooze` does,
and the thread draws two rules (`thread_rules`): `new since you last looked`
at the stamp - the one the snooze wrote over, where the stamp is the snooze's
or gone - and `new since the snooze` at the snooze's, while it is the later.
`p` still measures from `done_head`, which a snooze never writes; a second
`p` picks the snooze's head instead (`snooze_head`), or any of the branch's
commits, and a second `d` a run of them. A pick is the browser's, per item,
for the session (`pfrom`, `drange`), and part of the loaded key (`mode_key`),
so each is a load and a place of its own. The commits are the checkout's
(`pr_commits`), never fetched for the picker: a key press does not wait on
the network.

**An agent's bell is a seen bit tmux holds, and every mark clears it.** The
agent in a `T` pane rings as its turn ends or as it asks
(`cli/claude-settings.json`), and tmux keeps the bell while nobody is
attached, cleared by the next attach - exactly a seen bit, kept by the server
the session lives in, so nothing has to be running to catch it. `seen_of`
reads it before the stamp (`Marks.rang`, off `rang_urls`): unread while it
stands, whatever the stamp says, since it has no time to compare and needs
none - the third reason beside the table and the wake, and the second that
GitHub did not do. And the woken-snooze rule applies: `e`, `s`, `x` and
`mark_read_moved` silence it (`agent_seen!`, a control-mode attach on a
closed stdin, 4 ms) or a bell left beside the stamp would keep the row unread
whatever was pressed; `z` rings it back (`agent_ring!`). Read per
`refilter!` like the records, one `list-panes`, and heard while the browser
is up through the command pipe's subscription to who rang
(`watch_sessions!`): tmux tells a control client about the pane it is on and
nothing else, except what it subscribes to. Where there is no pipe it is
polled every `SESSIONS_EVERY`. An agent that *exits* is not this: its pane
is kept and says `exited` until it is closed (tmux, below), which is a
state of the session and no bit of the item's - nothing rings for it and
no mark clears it.

**A notice's seen bit is its presence.** A notice has no bundle, no state
and no wake table - a Release, a Discussion, a commit comment, a CI run,
an alert, an invitation - and nothing for a stamp to be compared against
but the time it notified. So it is unread while its block stands and gone
when it does not: `seen_of` says `:unread` for one before it looks at a
stamp, a floor, a wake or a bell; `e`, `x`, `wl done` and `wl done all`
remove the block and `z` writes it back, with no `touched` stamp either way
- there is no *not done* to toggle to, and no filed box for it to be in; `s`
is refused, having no stamp for a wake to sit beside. `consolidate!` skips
one: counted as a stampless unread row it would hold every `since` down for
as long as one stood. On the axes it is the fourth `kind`, and `closed` on
`state` - what that axis answers is "is it open work", and news that is not
work is what the firehose shows and the backlog leaves out.

The poll keeps what it has made into notices, `noticed[id] = updated_at` in
the inbox, because the overlap asks again for what the last poll read and
there a dismissed thread read again and a late one read for the first time
look the same. A thread at or under its entry is not a notice again; one
that notifies again is past it and is back. Pruned under `cursor - 1 day`,
the widest ask. `sync!` is the one writer of both, and the browser only
removes a block where the poll only adds one for an `(id, at)` it has not
had, so between them they cannot bring a dismissed notice back; a lost
`fetched.json` costs one overlap's worth of dismissed notices shown again.

**A notice is not a GitHub item, and says so once.** Its `notice:` url is a
key, as `local:` is, and `ghitem` is the one predicate for "an issue or pull
request GitHub can be asked about" - the bundle, the metadata pane, the
prefetch and the thread all ask it rather than `islocal`. The pane is the
block's own facts and no fetch; `o` opens `web`, the link `notice_web`
builds from the thread alone, and `y` copies it. What needs a thread, a
checkout or a block that outlives dismissal is refused, as an adopted
branch's `C` is (`not_pr`): `C` `A` `M` `L` `;` `R`, and `t` `T` `v`.

**An archive is a done mark that filters separately.** `x` stamps `archived`
and `done`. An archived item that moves is unread again - filing is not an
answer about whether a thing changed - but `show_ok` holds it out of every
list that does not name the `filed` box. That one asymmetry is why it is a
mark of its own: the backlog is not done and done, open, and leaves the filed work out.

Only `e` writes `done_head`, the sha the read was made at, because only `e`
knows what you were looking at; `s`, `x` and `wl done` stamp "not now" and
leave it alone. A row `e` never marked - read by the floor, or by those - has
the refresh's copy instead, `read_head` on the row in `fetched.json`: the head
as of the stamp, else the floor, carried from the row it replaces while the
row moves past it (`read_head`). `p` reads it only where there is no
`done_head`. Without it the thread drew its rule at the floor and `p` had
nothing to measure from. It is lost with `fetched.json`, which is the price of
keeping `local.toml` to what you did.

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
- **Opening it is something you did.** An issue or pull request of yours
  arrived as `new` and unread, with nothing to read (2026-09-24). A row you
  wrote with no key of the table set is `moved_by = "opened"`
  (`opened_by_you`), caught up the same way on a row first seen as `new`,
  and `seen_of` reads it as seen - no stamp written, the floor not asked -
  until somebody else moves it and the key replaces the word. `done = ""`,
  a woken snooze and a bell still say unread. The poll's light row says it
  as near as it can: yours, no comments, no notification `reason`. Yours
  first seen with a bool and nothing else set - CI already red - is that
  key (`own_bool_key`), unread and said `CI failed`: as `new` the pane had
  no other word for it, since a bool has no time to be listed by, and the
  row kept `new` until a dated key moved it (julia#63474).
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
- **What moved since you read is read off the keys, per frame.** The
  pane's `why` row lists, newest first, every key of the wake table whose
  time is past the done stamp - the same stamp `seen_of` compares, so the
  words are the unread - `unread: pushed, comment`, `reviewed`, `review
  requested`, `assigned`, `merged`, `new`, `woke` for a snooze that ran
  out, and `agent` in front of them all for a bell standing on the item's
  `T` pane, which has no time and is standing now (`moved_words`).
  Computed and not stored: `e` empties it and a stamp
  put back fills it, with no refresh between. Two movements have no time
  to compare - the bool that rose (`CI failed`), the force-push of an older
  commit - and for those the refresh keeps the key that set the stamp
  beside it, `moved_by` (`movement`, which is `moved_stamp` answering the
  second question too; `new` on first sight, `opened` for one of yours; the key it had when nothing
  moved; caught up once off the stamp by `moved_key` for a row from before
  it was kept). That is the *last* movement, dated `moved_at`, and is
  listed whatever it was. A push is dated by `head_at` only while `head_by`
  is not you: after a push of your own the date is yours, and theirs
  before it is `moved_by`'s to say.

## Time

**The instant an operation is measured against is an argument, `at`, and it
is when the operation started.** An entry point defaults it to `utcnow()`;
everything it calls takes it as a required argument. A global frozen at
process start was wrong for a browser open all day; a live clock read on the
way *out* claims a moment after things it never saw. A default further in is
how the second failure gets back in. The same rule forbids storing a
time-derived number: `Item` carries the stamps and no age; the `3d ago`
beside every date on screen is `ago_str` against the frame's `at`, put on the metadata pane by `meta_lines` and on a header by
`rows` as it draws it, from a timestamp the node carries (`meta["at"]`) and
never from a string kept on the node - a thread is fetched once and read for
hours.

**Dated by the thing that moved.** A push and a comment carry the moment they
were made, so that is the stamp; CI has no clock and is stamped with the
refresh that first saw it differ. Dating a comment by the poll made a comment
read at 10:00 come back unread when the 11:00 refresh first saw it.

**Nothing stamps the observation clock.** Proposed 2026-09-16 and rejected:
a mark advanced to *the observation*, with `wl done` stamping *now*. Two
counterexamples, each of which loses or re-shows a comment:

- `wl done` at now, `moved_stamp` unchanged: `done = 10:00`; a comment dated
  09:30, delivered late and learned at 11:00, on a row whose mark was 08:00
  is dated 09:30 (`m > high`), and `09:30 < 10:00` reads it - lost. Stamped
  with `moved_at` (08:00), as it is, it is unread.
- `moved_stamp` dating a movement `max(m, at)` so a late arrival is always
  past any stamp: the bundle under the cursor is fresh for `fresh_minutes`,
  so a comment landing after the bundle was fetched, read live in the thread
  pane and marked `e` (`read = seen_up_to`, GitHub's time) is dated by the
  next refresh's clock, past the stamp - back for something you read, on
  every comment inside that window. That is the bug `moved_stamp`'s
  docstring records, at two minutes instead of an hour.

GitHub's timeline is the one clock both observers see; dating by it is what
lets the browser and the refresh agree. What "later information wins" needs
is already the high-water rule: a movement dated at or before the mark is
stamped `at`. The residual - an event learned late whose time falls between
`moved_at` and an `e` stamp that the thread's `seen_up_to` pushed past it -
is a review made before your own last reply on the same thread, and is read
by any reading of "read".

**By GitHub's time wherever a stamp will meet one GitHub wrote**, and by an
*event's* time wherever there is one. `e` stamps `max(moved_at, newest
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

The refresh derives each as a sentence or `""` - `reply`, `edits`, `ready`,
`approved` and `review` in `apply_state!`, `second` in `derive!` - and the browser shows
them as the tag axis. None reads the state except to be empty on finished
work, and the one that reads another is `second`, which is withheld from the
pile (`in_pile`: a clock lane with no `reply` owed):

| tag | rule |
|---|---|
| `edits` | changes requested, unresolved threads, red CI, or the label |
| `ready` | approved, green, not a draft. Approved is GitHub's `reviewDecision` where the repository requires a review, and otherwise the reviews' (`verdict_of`): null there, julia's and libuv's, and until 2026-10-01 that left `ready` on no row at all |
| `approved` | approved, not a draft, CI not green: the other half of an approval, so the two are two lists |
| `review` | asked, and not reviewed since their last push |
| `reply` | mentioned within `reply_days` and the last comment is not yours - open or closed. Deliberately narrow: plain `commented:` never qualifies, because where you are effectively the maintainer that is forty items a week |
| `mentioned` | you were ever named on it: a notification whose reason was `mention` or `team_mention`, or an `@you` by somebody else in a thread the browser loaded. A **latch** on the row in `fetched.json` (`items` and the inbox), never unset, because GitHub's reason is the latest notification's and a comment after the mention turns it into `comment`. The wide list `reply` is the narrow, recent slice of |
| `second` | the author acted - opened it, or commented - and nobody has answered with a comment or a review for `second_look_days` *working* days. A push is not an action. Never on the pile, never on finished work. On by default because asking for it would defeat it: the failure it catches is work that goes quiet without anybody deciding it should |
| `snoozed` | a wake time still to come - a tag over done rows, not a box |
| `touched`, `drafts` | marks |

What the bucket had that none of these is: `draft` (a field), `blocked` (a
label), `issue` (`kind`), `stale` and `needs-nudge` (the second look says
"quiet 65 work days" in words), `firehose`/`mentioned` (the `lane` axis).

## The browser's model

**The pane follows the cursor, whatever moved it.** `settle!` starts the loads
for whatever is selected, and the controller runs it on every view in the
stack after every event and before the first frame (`settle_all!`); `handle!`
runs it once more at its end, for a caller that is not the controller. No key,
dialog answer or callback starts a load itself. They used to, one at a time,
and every path that forgot one - the answer to `s`, startup, a view's callback -
was a pane left showing the item before, or nothing.

**`show` and `state` are two axes that only add, asked separately.** `show`
is three boxes - `not done` · `done` · `filed away` - and `state` two - `open`
· `closed or merged`; a row has one value on each (`disp_of`, `over_of`;
filed wins over the stamp, since filing stamps done), and is in when both
are checked. Each box brings its own kind of row beside the others and takes
none away, so the number beside it is a plain count against the other axes,
the same whether it is on or off. Not done and both states are checked when
nothing has been asked, so the screen cannot be emptied by accident, and `c`
lands there rather than on the corpus. Three narrowing axes (`seen`, `sleep`,
`state`) were merged into one adding axis on 2026-09-13 because a view naming
one of them silently lost the dashboard; that axis then carried `closed` as
a box a closed row needed *as well as* its own, and `base` as one cell, so
two of its four boxes meant something different from the other two and every
count was a with-minus-without. Split again on 2026-09-21 into two adding
axes, which keeps what the merge was for - a view names an axis whole, empty
is empty, `c` is the default - and makes the boxes one kind each.

**A view names an axis whole.** `show = ["filed"]` is the filed work alone;
naming no `show` keeps the default. An unknown axis or value is reported, not
ignored: a misspelt one silently widens a view, and did.

**Newest first is policy, not a default.** Serving the second-look list
newest-first answers new work while the author still has the change in their
head, and an old row is at the bottom rather than in the way. Oldest-first is
uniform slowness. `w` cycles four orders, each the one of the three views it
was made for - by when it moved (`moved_of`, the time on the row, and never
anything you did) for the firehose, by the later of that and when you acted
for your work, by url for the backlog, and by when you acted
for the `touched` selection - and `lane_sort` reads which off the selection.

**A place replaces a place; a dialog stacks on one.** `isdialog` is the
distinction and `push_place!` enforces it. Going somewhere means leaving where
you were; a dialog answers a question and hands the keys back.

**The side without the focus gets no keys.** Which keys belong to which side
is answerable by looking at which side is lit - the border, and the list as
a whole, drawn in `quiet` while the keys are on the reading side, its unread
rows in `quiet_bold` rather than `bold` (a 256-colour theme's `bold` carries
the full foreground, and `bold` over the `dim` attribute is the pair
terminals disagree about - VS Code draws it as plain bold - so the ANSI theme
leaves `quiet_bold` empty and drops the weight); not the cursor row, which
stays lit on either side, since it says which item the reading pane is
showing. A hosted pane's reading side
keeps three (`tab` back, `esc`/`t`/`T` out); through `^]` it runs the other
way, and there the subject is the pane: a key about an item moves the thread
to the session's item before it is answered (`PANE_ITEM_KEYS`), and `t`/`T`
go by the session's worktree, while a key that points into the thread stays
the thread's. `tab` moves the keyboard between two things on screen everywhere, which
is why the merge composer cycles with `^x`.

**A capital reaches GitHub; lowercase does not.** The line is *remote*, not
*writes something* - `e` and `s` write `local.toml`. `z` may undo the
lowercase set and must never offer to undo a capital. The two exceptions are
`;`, whose picker says on its note which rows reach GitHub; and `Z`, which
redoes what `z` undid and so can reach no further than `z` can.

**A composer is drawn beside what it is about**, in the same split `t` and
`T` use, wherever the screen has 150 columns; the machinery was never about a
child process. `q` in a composer comes back to the message, because `q`
elsewhere ends the program.

**A colour is a role, never an escape.** Every colour is a field of `THEME`,
a StyledStrings `Face`; a call site names what the colour means, and lays it
over the range of a row it covers (`faced`). A table of colours built at top
level captures the theme before it is read, so `rev_mark`, `ci_color`,
`range_mark` are functions. Nothing ends a role: a face ends where its range
does, so a colour inside another cannot end the one under it, and a highlight
is a face laid under a row (`hlrow`) or over a range of it (`hlspan`).
Adding a role is a field in `Theme` and a line in every theme file; the suite
asserts both directions. How markdown is drawn - `[markdown]` and `[code]` -
is set from the same file, into `MD_STYLE`, and so are the box and weights the
widget packages draw in (`CHROME`); with no theme all of it is empty, and an
empty face writes nothing, so no row carries an escape.

**A row is faces over text** (2026-09-30): `Styled`, `TermInput`'s `Row`, an
annotated string, and every row this program draws is one - measured by its
text (`rowwidth`), cut and wrapped by `TermInput`'s `rowfit`, `rowpad`,
`rowwrap`, which keep the faces over what they keep, and written by
StyledStrings at the frame. A link is an annotation too (`linkrange`), so no
text match can land inside one. What is not faces is a hosted pane's row:
its child's escapes as tmux gave them, carried as a verbatim piece of the
box's row, never parsed, measured or cut (`TermIFrame`). A theme decides
colour and the stream does not, so whatever prints a row outside the frame
asks for colour itself (`show_md`'s `IOContext(stdout, :color => true)`).
Build rows with `*`, never `string`: `string` of a row keeps its text and
drops its faces, without a word.

**A row index is only meaningful against the width it was measured at.**
Beside a hosted pane or a composer the detail is half the screen; `detail_pane`
records the width and page it was drawn at, and every key that indexes rows
reads that. The indices already held - the cursor, the drag's two ends - are
carried across by `rewrap!` when the width changes: back to the node and
written line each stood on, forward to a row at the new width. Without it a
selection made in the browser lit other rows beside `C`. The mouse is the
same rule from the other end: `onmouse!` is handed the geometry of the frame
that was drawn - `layout`'s alone, `beside_layout`'s as the left column - and
the two side-by-side views forward what lands on the reading side; the keys
stay where they were, since nothing but `tab` would give them back.

**A resize is an event, not a tick.** SIGWINCH reaches the loop through
libuv's `uv_signal_t` (`watch_winch!`) as a `ResizeEvent`, and the frame is
drawn again at the new `displaysize`; a hosted pane resizes its child in
`onresize!`. No cache has to be dropped, because every width-keyed one -
`Node.cw`, `st.diw`, `st.dpage` - is checked against the frame that reads it.
The alternative was a timer comparing `displaysize` five times a second for
the life of the browser, and nothing here runs on a cadence of its own.

**Coming back to an item lands where you were**, per item and per mode; a row
leaving the list under you (`e`, `x`, `s`) leaves the cursor in place, so an
inbox is read by pressing `e`. A new list - view, filter, query - opens at the
top.

**The order is fixed when a list is asked for, and held while it is read.**
Every sort key moves under a list on screen - the bundle re-read under the
cursor brings a fresh `moved_at` for the row being read, a note stamps `touched` -
and `refilter!` used to sort afresh on each, so the row being read moved
somewhere else on the screen. Now a refilter that keeps the row keeps the
order too (`held_order`): a row that changed stays where it was, one that
arrives goes where the sort puts it among the rows that stayed, one that
leaves leaves. What the list is *of* - the filters, the sort, the list
search, written as a view is and kept as `orderkey` - is what fixes it: when
any of them changes the list is another list and is sorted afresh, and a
refresh landing asks for the same (`resort`).

**A jump to a hidden row brings the row, not the filters down.** `"`'s `h`,
a number typed into `/` and `esc` back to a draft go to one item, and when
the filters hide it the row is shown anyway as the *guest* (`st.guest`),
where the sort puts it and marked `+`, until another list is asked for. It
used to clear the filters, which answered one row by throwing away the list
being read, and `` ` `` to get the list back lost the row. One slot; a row
the filters come to show is no longer a guest.

**Facts that hide the row being read leave it there, as the guest.** A
refilter is a key or it is facts arriving - the bundle re-read under the
cursor, a refresh landing, another window's write - and the second kind says
so (`hold`): the row under the cursor that it would take out of the list
stays, where it was, and the status row says it left. julia#37822
(2026-10-06) was a light row, unread on `updated` because somebody labelled
it - the only answer there is for a row with no wake table - and the bundle
fetched for looking at it dated its last movement eight months back, under
the floor: read, out of the firehose, and the cursor on the row below with
the pane half read. A mark of your own is not held - `e` takes the row out
because it was asked to - and neither is a row the cursor is not on.

**`` ` `` and `~` walk where you have been, rows and lists both.** Back and
forward stacks of *spots* - a list (filters, sort, list search) and the row in
it - kept by `note_place!` in `settle!`, so no key has to say it moved: every
list left, the row a jump left and the row it went to, and a row the cursor
rested on for the pane's dwell (`LOAD_AFTER`). Not every row `j` passed, or
`` ` `` would be a slower `k`; not each character of a query or each box
toggled in the filter pane, which are seen as one move when they end. A jump
or a new list empties the forward stack; wandering off the row `` ` `` went
back to does not. Going back to a row the filters now hide - the one `e` just
took out of the unread list - brings it as the guest. It replaced `prev`, one
slot of filters that `` ` `` swapped with the current ones (2026-09-24), which
could go back to a list but not to the item you were reading in it.

## Showing what changed

Three things answer it, all read off the mark `e` leaves:

- **The thread opens on a rule.** `e` marks done up to the newest event it
  showed, so everything before the stamp was on screen. Nothing records
  *which* comment you got to: a second answer can disagree with the first.
- **The thread is one activity list**: commits and the changes of state -
  closed, merged, reopened, draft, ready - drawn among the comments in
  order, a run of commits nobody spoke between folded into one `↑ pushed N
  commits`, a close that names what closed it (`by julia#63266`). One
  GraphQL request - `commits(last: 30)` and `timelineItems` - beside the
  REST reads, in the thread's own cache entry.
- **`p` diffs `done_head` against the head now.** Only added to (old head
  still in history, base unmoved): plain `git diff`. Otherwise `git
  range-diff`, **measured from the base branch on each side** - `old...new`
  measures from where the heads meet, so a two-commit branch rebased over ten
  of master reports twelve. The base ref is fetched first, because a stale
  copy puts the commits it has not heard about inside the answer. A
  force-pushed head is fetchable by sha (measured: fourteen months old), so
  "gone" is not a state; a failure is the network. Needs a pinned checkout:
  GitHub compares refs, and the head you saw is not one. git prints a
  commit with no pair in a range-diff - new, or gone - as its header alone,
  so its own diff is put under it (`lone_patches`), folded: a gone one opened
  onto nothing, and what a dropped commit did is in no other view. A second
  `p` can also start from any name the checkout resolves, the remote's
  branch of that name before a local one, never fetched.

## What is said, and where

Three channels, and every message chooses one by what the reader does with
it. Audited 2026-09-17; before that there were three channels and no rule,
and a `FAILED:` lane reached the status row only if it happened to be the
last line of the child that ran the refresh then.

- **The report** is what an operation says as it runs: a lane's count, a
  retry, a lane that is not `is:open`. It goes to `report()`, the `IO` of the
  report opened for the current task (`reporting`, in task-local storage) or,
  failing that, the process's (`REPORT[]`): stderr for a command, `devnull`
  for the browser, which sets it before its first frame because a line on
  stderr draws over the frame. A line the reader has to act on goes through
  `warning()` - the same stream, counted - and the report carries the
  operation's `summary`, which is what the status row says of it; nothing
  reads text back. Under `u` the report is `data/refresh.log`, whole, and
  `wl log` prints it.
- **The status row** is for what just happened and will not happen again -
  "copied 3 lines", "posted", "sorted by age" - and is replaced by the next
  key. It is wrong for anything the reader has to act on later, which is why
  a send that fails keeps its composer open with the failure on the
  composer's row (`Unsent`) instead of popping and leaving one line here.
  A fact about the whole list that stands - when it was last fetched - is
  at the right-hand end of the title bar (`refresh_stamp`), absolute and
  relative like every other stamp, and `refreshing …` there while `u`'s
  refresh runs; the row still says what the refresh did when it lands. The
  same for one pane: when what the thread pane and the metadata pane show was
  read - a cached copy's write time, not when it went up - is on each one's
  bottom border (`load_stamp`), `loading …` until it is and `· reloading …`
  while a re-read runs under it. It used to be "loading …" in this row, which
  every key that moved the cursor and had something to say about it had to
  write *after* the load or lose, and a load that landed cleared whatever the
  key had said. On the border it takes no row, so neither pane changes height
  as a load comes and goes, and this row is cleared by the next key and by
  nothing else. The top border's right-hand end is the same kind of fact
  about the pane, how big the change it shows is (`diff_size`, `header!`):
  the hunks on screen added up, and for the thread, which has none, the
  whole pull request's as GitHub counts it - asked with the thread
  (`activity`), since the lanes would ask it of every row on every refresh.
- **Standing** notes stay until dealt with: `errors.log`, written by
  `logerror!` for exceptions and read as the footer's warning until the file
  is deleted; a source the poll cannot get an answer from, off the inbox's
  `failed` table - `when why`, written by `sync!` on a `FAILED:` and deleted
  by the next answer - held on `BState.failing` and taken again when
  `fetched.json` lands; and a theme that did not load as written
  (`THEME_NOTES`), in the same place behind both; and behind those a tmux
  server older than the tmux `wl` runs (`MUX_OLDER`, read when the command
  pipe opens), which "may be missing features" and does not say which - the
  list would be right until the next one. `standing_note` is the one reader
  of the four.

  The `failed` table is how the browser's own operations get to say the one
  thing they have to: the launch poll in `ui()` runs before the first frame
  with the report on `devnull`, and a lane answering `FAILED:` there used to
  be said to nobody until the next `u`. It does not report into
  `refresh.log`, which is the last `u` whole and would be overwritten by a
  poll that is half of one; and the browser grows no `warning()` channel of
  its own, since the fact was already written down and only wanted its
  reason kept beside the stamp and a reader.

The browser writes nothing to stderr. The one exception is `run!` refusing to
start without a terminal, which is before there is a frame.

## Code layout

| | |
|---|---|
| `cli/src/gh.jl` | `github`, the one request to GitHub, over HTTP.jl; the token lookup; the GraphQL lanes |
| `cli/src/events.jl` | `Events`: the clocks, the by-url fetch, the writes |
| `cli/src/refresh.jl` | normalize, the wake table, the tags, the snapshot diff |
| `cli/src/cli.jl` | the `wl <command>` surface and `USAGE` |
| `cli/src/ui.jl` | `Item`, and the adopted branches and the notices synthesized from `local.toml` |
| `cli/src/marks.jl`, `state.jl` | what you did to an item; the line-based `local.toml` editor |
| `cli/src/util.jl`, `pyjson.jl` | `oneline`, `table_key_order`; JSON written the way the Python port did |
| `cli/src/fetched.jl` | `fetched.json` |
| `cli/src/controller.jl` | owns stdin, read with `TermInput.readevent`; the `View` protocol; dialogs |
| `cli/src/browse/` | the browser; `Worklog.jl`'s include list is the index |
| `cli/src/theme.jl`, `themes/` | roles and the spec language |
| `cli/src/repos.jl`, `ci.jl`, `cache.jl`, `paneview.jl` | checkouts and worktrees; Buildkite; the TTL cache; a `TermIFrame` beside the thread |
| `TermInput.jl/` | submodule: `TextBuffer`, `TextArea`, `LineInput`, `Choice` and `Confirm` (the pickers and questions, and `listwindow`/`listmove`, the scroll every list shares), the key vocabulary, the dialog box and `BOXES`, `CHROME`, `suspend`, rows of faces and their measuring (`rowwidth`/`rowfit`/`rowpad`/`rowwrap`, `verbatim`), the frame writer, and `markdown_rows`, which draws every comment body |
| `TermIFrame.jl/` | submodule: tmux sessions, the control-mode client and the command pipe over it, `bordered`, the iframe. Depends on `TermInput` for measuring, never the other way |
| `cli/precompile/` | `WorklogPrecompile`: `Worklog` plus a `@compile_workload` of the browser's path. `bin/wl` loads it; the suite never does |

Everything is one Julia module, so the browser calls the same functions the
commands do rather than shelling out to itself.

**Order is not cosmetic in either include list**: a type must exist before
methods on it, and several testsets leave state the next reads. **Cut above a
definition, never into it**: a file that ends in `"""` strands a docstring,
which is a legal no-op nothing complains about.

**Splitting a file moves nothing; splitting a package is a design change.**
`TermIFrame` went across as it was, and lost its callbacks and its keys
later the same way (*Decisions*). `TermInput` did not: the editing model
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
`cli/test/aqua.jl` builds the image and fails, naming the handles, where a
build would wait; Aqua's own `test_persistent_tasks` cannot, since loading
the wrapper runs none of its workload. A spawn
must look for its binary first (`token`'s `gh auth token`), or the failed
spawn leaves handles behind. **Nor reach the network**: `token()` finds one
without `gh`, so `hermetic` takes the token away too.
`PrecompileTools` is kept: the macro is worth 0.6s a launch over a bare `let`,
and Base has no equivalent.

**What it covers is read off a trace, not guessed.** The workload seeds the
files a launch reads - `fetched.json` with an inbox, the cache under the first
row (bundle, thread, meta, merge, checks, diff), a notice - launches as `ui`
does, and drives keys through `step!`, one turn of `run!`'s loop, so the
dialogs a key opens are drawn and answered too. What only the network or a
TTY reaches is a list of `precompile` signatures beside it. To redo it, run
the browser from `cli/precompile` with
`--trace-compile=<file> --trace-compile-timing` inside a tmux session over a
copy of `data/` (`WORKLOG_DATA`), press the keys, and read what is still
compiled, biggest first. JSON3 typed an empty array, a nested object and a
top-level one apart, so a path was covered only in the shapes it was seeded
in; `JSON.parse` does not - every object is a `JSON.Object{String,Any}` and
every array a `Vector{Any}` - but a fetch's lists still are typed by what is
in them. So the readers of a thread's lists (`activity_list`, the node
builders, `thread_seen`, `event_at`) are `@nospecialize` and loop
rather than build a generator over a list, so that one shape covers every
mix of empty and not. On 2026-09-26 the same session went from 18.1s of runtime compilation to
2.6s. No tmux is needed for the trace: a script that loads the wrapper and
drives `step!` over its own seeds does the same without a TTY. On
2026-10-07 the composers were found that way - the first keystroke in one
compiled `safe_dispatch!` and `safe_render` over an `EditorView`, 0.8s -
and the workload opens each of them now. **What `__init__` runs is not the
workload's to compile**: it runs when the wrapper's build loads `Worklog`,
before the workload, so what it compiles there is never tagged for the
image. The theme parse is a `precompile` line in `Worklog.jl` for that
reason, and anything else `__init__` grows should be too.

**Its manifest is `cli/Manifest.toml` plus one entry**, never resolved fresh:
copy, fix the two relative `../` paths, `Pkg.resolve()`. Check:

```bash
diff <(grep '^\[\[deps\.' cli/Manifest.toml | sort) \
     <(grep '^\[\[deps\.' cli/precompile/Manifest.toml | sort)   # one line
```

Launch, by `cli/test/latency.jl` on 2026-09-30 in this sandbox: the wrapper
loads in 0.76s, and the first thread is drawn at 1.10s. With Term (at
`de1b582`, measured the same way the same day) it was 1.31s and 1.84s: Term
brought Highlights, which imports Pkg, and a tree-sitter grammar, for a
renderer that highlighted one language.

## Testing

No TTY, so the UI is tested by construction:

- `render(view, w, h)` is pure; `handle!(view, key, ctrl, at)` returns an
  action; `readevent(io)` is a pure function of a byte stream, driven from an
  `IOBuffer`; `onmouse!` takes screen coordinates after a render, since the
  map goes through `layout` (or `beside_layout`) and `st.hdr`. `render`
  answers rows of faces; the suite's `frame` writes them as the terminal is
  sent them, and asks what face is where of a row itself (`faces`,
  `faceon`), since the escapes StyledStrings writes for one depend on the one
  before it and on the terminal.
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
- Time is an argument: a test says when now is by passing it. So is the
  network where a function reaches it outside its sources - `sync!`'s
  `now` and `lastby` - and the suite runs whole with no token.
- `--project=cli`, never the wrapper. `latency.jl` and `aqua.jl` build the
  image and spawn processes, and are deliberately not in the suite.
- What none of this reaches - the terminal's own bytes and title, a resize,
  the clipboard, a pane through a reconnect, requests against GitHub - is
  `cli/test/MANUAL.md`: steps, what passing looks like, and when each last
  did. A TODO item under *Unverified* moves there once it has been run.

Harness:

```julia
items = Worklog.loaditems()
st = Worklog.BState(items, "worklog")
ctrl = Worklog.Controller(); ctrl.running = true
st.wake = () -> Worklog.wake!(ctrl)
# The first load is held for the dwell: its wake is settled, which starts the
# fetch, and the second wake is the fetch landing.
Worklog.settle!(st); take!(ctrl.events); Worklog.onwake!(st, ctrl)
Worklog.settle!(st); take!(ctrl.events); Worklog.onwake!(st, ctrl)
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
15. A review thread's `line` is resolved against a commit, and the commit
    `addPullRequestReview` takes by default is the head *when it is posted* -
    the head the diff was read at only until somebody pushes. So a new draft
    is pinned with `commitOID` to the head the checkout diffed to;
    `addPullRequestReviewThread` has no such field and inherits the draft's,
    so a thread numbered against another commit is refused, and the draft is
    sent first. A diff GitHub served names no commit and takes the default.
16. `/repos/o/r/issues/N/comments` is oldest first and takes no `sort` or
    `direction` - those are `/repos/o/r/issues/comments`'s - so
    `per_page=1&direction=desc` answers with the *first* comment, silently.
    The newest is the last of a page asked with `since=`.
17. A notification that is not an issue or pull request carries no html url
    (measured 2026-09-26, 67 threads). `subject.url` is `/commits/<sha>` on a
    Commit, with `latest_comment_url` at `/comments/N`, which GitHub draws
    at `#commitcomment-N`; `/discussions/N` on a Discussion; a Release's is
    `/releases/<id>`, while its page is by tag, which the thread does not
    carry; `null` on a RepositoryAdvisory, which carries no GHSA id either.
    `notice_web` builds the link from exactly this, and the thread's
    `html_url`s are all the repository's.

### Julia's Markdown

`markdown_rows` draws the tree the stdlib parses, so what the stdlib gets
wrong reaches the screen unless it is corrected before the parse
(`escape_source`), in the parse (`GFM_FLAVOR`), or where the renderer reads it.

- A newline in a paragraph is kept in the text from 1.14, and `breaks = true`
  draws it as a line break, which is what GitHub does in a comment. Before
  1.14 there is no newline to act on, and a comment wrapped by hand is
  reflowed - `cli/Project.toml` still allows 1.11.
- Two spaces at the end of a line stay in the text as `"  \n"` rather than
  becoming a `LineBreak` (a backslash does become one); the renderer reads
  them as a break either way.
- A list is marked `loose` whenever a blank line follows it, which is every
  list with a paragraph after it. The renderer believes `loose` only when an
  item has more than one block, since GitHub draws that list tight.
- A double backtick opens maths, not a code span: ``` ``a`b`` ``` is a
  `LaTeX`, drawn as its source between `$`. Not worked around.
- An empty list item is an empty vector, which Term indexed into; the
  renderer draws its bullet.
- `Markdown.parse` opens emphasis on an underscore inside a word, which
  CommonMark forbids; it takes two to pair, so `deliver_result and
  connect_to_peer` loses both. `escape_source` escapes them outside code.
  Filed, with a fix, as JuliaLang/julia#63081 (open).
- A table column with no colon in its `---` is `:r` (`default_align`), and
  `Table` has no way to say none; GitHub draws it left. `parse_gfm` parses
  with a copy of the default flavor whose table parser reads the row again.
  JuliaLang/julia#63365 (open, RFC) makes the default `:l`.
- Emphasis is matched before code spans, so a `*` inside backticks closes an
  enclosing `*...*`: `` *a `b*` c* `` is italic `` a `b `` and the text
  `` ` c* ``. CommonMark gives code spans precedence. Not worked around;
  JuliaLang/julia#63364 (open).

### git

- **A pull request's branch is not here under the pull request's name, as
  often as not.** `gh pr checkout` names a fork's `master` `<owner>/master`
  to keep off the project's; `checkout_session!` and `make_checkout!` name a
  taken name `pr<N>/<branch>`. Joined by name, such a copy was nobody's:
  `"` filed it under no item and `h` there said `no pull request on this
  branch` beside the agent working on it; `t` on the pull request offered
  the chooser with the agent's copy in it; and `t` in the copy adopted the
  branch as work of its own, whereupon `branch_owner` said the copy was
  that item's and the pull request's `t` asked on every press
  (2026-09-22). Git knows: `branch.<b>.remote` and `branch.<b>.merge` are
  the fork's url and `refs/heads/<head>`, or the project's remote and
  `refs/pull/N/head`. `Tracking` reads them once per repository;
  `on_branch` is the one predicate, and `branch_carrier` ends in it.
- **`git worktree list --porcelain` leads with a bare repository**, as a
  `worktree` line with `bare` under it and no `HEAD`. It is not a checkout;
  `worktrees` drops it, and then no row is `main`.
- **A session is keyed by its worktree and kind, so `t` and `T` take one
  over from another item, and the takeover has to be loud.** `T` on an item
  whose `running` block was empty landed in another item's agent in the
  copy rule 1 chose, said `back in … · was on wt#9` on a status row that
  the next key cleared, and read as the item's own (2026-09-22). Now the
  item pane lists the other item's sessions in the copy the key would open
  (`taken_in`, off `item_place`), the checkout and fast-forward questions
  say whose is there, the report leads with `took over`, and the pane's
  title carries `was wt#9's` for the visit. The place-held answer stays:
  the shell and the agent share the copy, and an answer per kind would
  have it moved from under the other.
- **An agent's commits are in your name.** `mine_on_branch` is not a
  signal that a branch is your hand's; a branch an agent made in a copy
  passed it, and re-entering the pane adopted it. No automatic adoption
  where an agent is.
- **The project's copy of a name is not a fork's pull request from it.**
  `pr_branch_here` said `:local` for a fork's `master` because the local
  `master` tracks `origin/master`, and `git worktree add` then refused with
  `master is already checked out`. The upstream and remote-tracking rules
  hold only for a pull request from the project (`head_repo`).

### tmux

The binary is `tmux_jll`'s (3.7c), or whatever `WORKLOG_TMUX` names; `PATH`
is deliberately not consulted. It buys nothing - sessions live in a server
addressed by a socket, so any binary sees the same ones and the user's own
`tmux ls` lists these - and it would cost knowing what we are talking to:
`capture-pane -e` keeps OSC 8 from 3.4 and drops the url in 3.1c. What it
cannot pin is the *server*: where one is already running on the socket, its
version renders `capture-pane`, evaluates the formats and decides what every
command does - Ubuntu's 3.4, started before `wl`, took `refresh-client -r` as
nothing, and nvim in a pane heard black on a white terminal (2026-09-28). So
the footer says when the server is the older (`muxnote`). `mux_cmd`, not a
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
  one and nothing else. **And an `%output` line is a cut, not a sequence**:
  the stream is split at a few kilobytes wherever it happens to be (a 4K copy
  arrived as 2730 and 1268, 2026-09-22), so a clipboard of a few paragraphs
  straddles it. Read stateless, the head had no terminator and the tail no
  introducer, and the copy was lost whole - and only *sometimes*, because
  claude inside tmux writes it twice, raw and again in a DCS passthrough,
  and a cut through one copy spared the other. `passthrough` keeps the
  unfinished tail per pane and reads the next line as its continuation.
- A nested tmux gets no mouse unless *it* has `mouse on`. Not ours to fix.
- **`capture-pane -e` is one stream, not a row per line.** An escape is
  written where a cell differs from the cell before it, and the cell before a
  row's first is the last of the row above - so a `+` row of a diff that fills
  the pane to its last column, or wraps there, leaves green open and the row
  under it is written with no colour at all. Drawn as given, each verbatim
  row closed after it, the middle rows of a `+` run in a 41-column pane were
  black (2026-10-08, on 3.5a and 3.7c alike; `-J` is worse, one opener for
  the screen). `TermIFrame.reopened` carries what an SGR set into the next
  row's opener, one entry per thing set, so a row is read alone.
- **A drag is copy mode, driven blind.** A control client cannot give tmux a
  mouse event with a position (`send-keys -K` zeroes it, `-M` replays only a
  bound one), and `capture-pane` reads `wp->base`, never the mode's screen.
  So `iframe_drag!` drives the mode with `send -X` and the frame is painted
  from its formats: `copy_cursor_y` is a view row, `selection_*_y` a grid
  line (oldest history line 0), `mode-keys` whether the end cell is in.
  `start-of-line` on a wrapped row's second half goes up a row, and
  `cursor-right` past a line's end wraps to the next, so `copy_goto` asks
  where a step down left it and moves across from there, clamped.
- **One command to an ask.** A `;` list gets a reply block per command, and
  `mux_ask` pairs replies by position - the next ask reads the list's second
  answer.
- **Whether a child wants bracketed paste is asked, not followed.** tmux
  keeps `?2004` as a pane flag; for a real client it sets the terminal to
  match and drops the markers (`KEYC_PASTE_START`, `input-keys.c`) for a
  pane without it. A control client has no terminal to set, `send-keys`
  cannot name those keys (`PasteStart` goes in as text, `0x…` reaches only
  characters), and `-H` sends the marker bytes to a child that never asked.
  The mode's own `%output` is no record of it either: nothing is replayed
  on attach (measured on 3.5a), so an agent reopened is a child whose mode
  was set when nobody was looking. So `iframe_input!` asks
  `#{bracket_paste_flag}` as each paste starts and streams it with or
  without the markers. That format is **tmux 3.7's and the server's** - a
  bundled binary newer than a running server buys nothing - and an older
  server expands it to nothing; there the paste is held to its end and
  sent through `paste-buffer -p -r -d` from a buffer of this process's own,
  which brackets it per the pane. `set-buffer` takes the text in octal
  escapes, since the control line is parsed, and cannot carry a NUL.
- **The control-mode reader must never be made to wait on the loop.** It
  delivers the replies the loop blocks on, and it raises a wake per
  `%output` line: a burst longer than the events queue - a child clearing
  to the alternate screen, `git log` into a pager - blocked it in `put!`
  with the reply behind it, the ask timed out at five seconds, the client
  was dead and the pane said `session ended` over an empty frame with no
  reason kept. `wake!` queues one `WakeEvent` at a time (`woken`); a wake
  is a level. And a dead client carries `why`, which the status now says.
- **A host that stops reading is paused, not dropped.** A terminal that
  stops taking bytes - an ssh session nobody is reading - blocks `wl`'s write
  to it and the whole process with it, reader too, and tmux drops a control
  client whose output is five minutes old: the pane said `session ended: the
  server said exit: too far behind` over a session still running. An iframe
  attaches with `pause-after` (`PAUSE_AFTER`, a minute), so tmux pauses the
  pane instead; the reader notes the `%pause` and wakes, and the next sync
  continues it (`mux_continue!`) and reads the screen, which is all the resync
  there is, the screen being the grid. The reader cannot continue it itself: a
  reply nobody asked for would answer the next ask. Under `pause-after` the
  output is `%extended-output`, which the parser reads as `%output`.
- **A session ends after its last `%output`, not with it.** `%exit` comes
  alone, and a pane that re-read the session only when output woke it never
  looked again: a shell's `exit` line lands close enough to the end that the
  sync it wakes finds the client dead, but `claude` writes its farewell and
  takes a moment to exit, so its pane kept the farewell with every key sent
  to a dead client, `^]K` the only way out. The reader wakes once more as it
  stops (the client's `wake`, which `mux_wait` answers `false` from then
  on), and a key that finds the client dead says `session ended` rather
  than going nowhere. That is a session killed under the pane, or its
  server gone, now: a child that exits does not end one (next).
- **A child that exits keeps its pane, and says `exited` until it is
  closed.** `mux_start` sets `remain-on-exit on`, whatever the status: an
  agent whose command was not found - `claudebox` exec'ing a Julia juliaup
  had since removed, 2026-09-28 - leaves `Pane is dead (status 127, …)`
  under what it said, where it used to end its session before anything
  attached and `T` said only `could not attach`; and one that finished with
  nobody watching, or a shell that was `exit`ed, is there with its last
  words until it has been opened and closed (2026-10-06; it was `failed`,
  and a clean exit took the pane with it). Set before the command runs: the
  session starts on `cat` and `respawn-pane -k` puts the command in, since
  down the pipe `new-session` and `set` are two round trips and an exec that
  fails is over inside one. tmux writes its line on the bottom row and
  scrolls one up to do it, and a resize to a box shorter than 24 rows pushes
  the top - the child's only words, usually - into the history, so the sync
  reads a dead pane's history too and drops the blank rows tmux left above
  its line (`dead_screen`), which it finds by its words: in a box narrower
  than the line it wraps, and the blanks are above its first row. The sync
  that finds it drops the client, as for a child that has gone, and
  `iframe_close!` kills the session: once the screen has been seen nothing
  is left running. So `q` on it is the end of it, and `T` again starts
  another. **And `iframe_close!` asks the server as it lets go**, not only
  the last sync: the exit reaches the pane through the pipe's subscription,
  which tmux checks once a second (`control_check_subs_timer`, 3.7c), and a
  `q` inside that second - the child's farewell on screen, and the key
  pressed on it - found `exited` unset and left the session standing with
  nothing in it, `exited` on its badge until the next `T` and `q`
  (2026-10-07).
  **It is a state, not a seen bit.** `#{pane_dead}` is read into the
  session's row (`dead`), and every place a session is drawn says `exited`
  for it in the colour of something waiting on you (`session_words`, and the
  badge on its letter in the worktree list). A dead pane is not coming
  back, so there is nothing for a look or a mark to reset and nothing that
  rings: it is not the item's unread, `e` does not touch it, and it stands
  until the pane is closed. A bell for it was built and taken out the same
  day - it took the command run under a `/bin/sh` that wrote a `BEL` as it
  ended, `window_bell_flag` being set by the pane's own child and by
  nothing else, to make a bit that then had to be cleared.
  **A pane on screen is told by the pipe, not by its own client.** Nothing
  ended, so there is no `%exit`; tmux's `Pane is dead` line is written on
  the screen and is no `%output`; and a sync woken by output just ahead of
  the exit asks before it has landed (never seen, three of three). The
  pipe subscribes to the sessions of ours whose pane is dead (`MUX_DEAD`,
  beside the bells and the titles), `watch_sessions!` hears it as a change
  in the list (`sessions_changed` reads `dead`), and the wake has the pane
  on top sync. **Not a subscription on the pane's client**: with one, a
  3.7c server that pauses the pane for a host that stopped reading never
  says `%pause`, nor anything after - the line is queued behind the
  subscription's, and with the pane's own output discarded nothing is left
  to flush them. The pipe is `no-output` and has no such queue.
- **The server's environment is the first login's, forever.** Every session
  gets a copy, plus the `update-environment` list (`SSH_AUTH_SOCK`,
  `SSH_CONNECTION`, `DISPLAY`…) from the client that asked - so a pane
  carried one login's agent socket and another's `SSH_CLIENT`, `PATH` and
  no `VSCODE_*` (a real ssh session, 2026-09-17; reproduced on the bundled
  binary). A control-mode attach refreshes the *session* environment too,
  which reaches nothing already running. `forwards.jl`: the pane is handed
  links under `$XDG_RUNTIME_DIR/wl/` through `standalone`'s `set`, and every
  launch re-points them at this login's values when those are live - a
  connection, since the socket file outlives its listener - and otherwise
  leaves them. `PATH` is the launching login's with the link directory
  in front, not the pane's with it in front: `$PATH` reads differently in
  `fish` than in `sh`, and the command runs through whichever the server has.
- **The bell flag is a seen bit, and the server keeps it.** A bell rung into
  a session with a client attached sets nothing - somebody was looking; rung
  into a detached one it sets `window_bell_flag`, which the next attach
  clears, control-mode or not (measured on 3.5a). `mux_list` reads it back
  as `bell`, `mux_seen!` clears it and `mux_ring!` sets it. That is the
  whole of how a `T` pane says its agent stopped: `cli/claude-settings.json`,
  on the alias's line as `--settings` - **its contents, not its path**: a
  sandboxed `claude` mounts the worktree and `~/.claude` (at `/root/.claude`
  inside, another name outside) and not this checkout, `--settings` expands
  no `~`, and a hard link comes apart at the next checkout - holds a `Stop`
  hook and a `permission_prompt` one that ring; the worktree list and the item pane
  draw the bit, and `seen_of` reads it (Marks, above). No socket and no
  listener - a listener is a browser that has to be running, and the pane
  outlives it. A session is tagged with the item's url as well as its ref,
  since the marks are keyed by url.
  The hook runs under `/bin/sh` in a session of its own with no controlling
  terminal, so `/dev/tty` fails (`No such device or address`, 2.1.277); it
  rings `/proc/$PPID/fd/1`, its parent being `claude` and `claude`'s stdout
  the pane's pty - by descriptor, since a sandboxed `claude` has its own
  `/dev/pts` in which that pty has no name and `ps -o tty=` says `?`
  (2026-09-21) - and `/dev/$(ps -o tty= -p $PPID)` where there is no
  `/proc`, the one `ps` spelling BSD and procps share.
  `preferredNotifChannel` would do the same ring, but `auto` resolves to
  nothing under tmux and the idle delay behind it is a global setting.
- **A pane's title is the child's, and says what it is doing.** OSC 0/2 sets
  `#{pane_title}`; a pane that never set one is titled with the host name,
  which `TITLE_FORMAT` reads as none. tmux refuses a title with a control
  character in it and keeps the one before (3.5a), but a comma is kept, so
  it goes last in every format and the split is limited. `claude` titles its
  pane `✳ Claude Code` as it starts and again on `/clear`, and the
  conversation's topic from the first prompt (2.1.284) - which is `/cleared`
  (`CLEARED_TITLE`). There is no busy mark in it: sampled every 0.4 s through
  a twelve-second turn, the title did not change. Busy would take a hook
  writing a second escape into the pty beside `claude`'s own redraws, which,
  unlike the one-byte bell, a write of its can cut through; not done.
- **A session's tags are strings on the server, and the list is the host's.**
  `SESSION_TAGS` names them and `session_list` reads them into a `Session`;
  TermIFrame keeps no list of its own. Every row carries `#{session_id}`,
  `$N`: kept through a rename, never reused while the server lives, and
  back at `$0` after a restart - which ends every session too.
- **A trailing `;` is a command separator, in any argument of a command
  line.** `set @x 'y;'` as arguments sets `y`, one command or several; `\;`
  is the character. On a control line it is not: a quoted `'y;'` is `y;`,
  and inside single quotes every character is itself - `#`, `$`, `~`, `\`
  (3.5a). So the quoting is the transport's: `mux_spawn` escapes the
  argument, `mux_line` quotes the word.
- **One control line with `;` in it is one reply block per command**, and
  replies are matched by position, so `mux` sends a line per command down
  the pipe and joins them with `;` only into one process.
- **A control client has to attach to stay open.** `tmux -C` with any other
  command runs it, says `%exit` and quits; and attaching to one of ours
  clears its bell. So the command pipe (`mux_pipe_open`) parks on a
  session of its own, which `tmux ls` shows and `wl` does not list, `_wl-ctl-<pid>`, where a session beside it kept
  `attached=0` and its bell. A process is 3.2 ms a command, the pipe
  0.04 to 0.16 ms one at a time (3.5a). It is open while a `wl-` session is (`watch_sessions!` closes it
  on the `%sessions-changed` that leaves none), since opening one starts a
  server and holding one keeps it up; one-shot commands never open it.
  `switch-client` and the attach behind `mux_seen!` are spawned always: they
  are about the client that asks, which down the pipe would be the pipe.
  A session started down it takes the `update-environment` list from the
  pipe's client, which is this browser's environment as it launched - what
  a spawn would hand over too (the same size, directory and variables,
  measured).
- **`destroy-unattached` set on a session nobody is attached to ends it on
  the spot** (3.5a). The pipe's session is given it once its client is on,
  and then goes with the client: a browser killed outright closes the
  client's stdin, the client exits, the session ends. One that died between
  the two is ended by the next browser's pipe, by pid.
- **A subscription is about the attached session, unless its format loops.**
  `refresh-client -B name::fmt` is checked once a second and says
  `%subscription-changed` when the value differs; `#{S:...}` in the format
  walks every session on the server, so the pipe, on its own session,
  subscribes to the ids of our sessions with a bell standing (`bell_format`).
  That replaced listing them every two seconds. `%sessions-changed` comes
  for any session starting or ending, ours or not. A second subscription,
  `titles_format`, is our sessions' pane titles, so an agent naming its
  conversation wakes the browser as a bell does, and the item pane's
  `running` lines are listed again (`sessions_changed`) - they were read only
  as the item's metadata loaded, and kept the title from before the first
  prompt. A bell set or cleared is such a change too, not only a refilter:
  the same lines say `waiting on you` off that list, and with it handed over
  only for a title the thread beside a `T` pane went on saying it after the
  attach had cleared the bell, until the next `T` listed again (2026-10-07).
  The worktree list lists the sessions itself on every wake it gets - the
  watcher's, the dirty pass landing, the `:pop` of a pane over it - and
  rebuilds its rows when the listing differs from the one they came from:
  rows built once at `t` kept a `T` on the `rang` badge, or `exited`, after
  the pane behind it had been looked at and closed. A third, `dead_format`,
  is our sessions whose child has exited, which is how a pane on screen
  hears of it (above). A tag is not subscribed to: the tags are this program's, so a
  session re-tagged here hands the browser the new list (`relist!`). Whose a
  session is is its `item` tag, which the last `t` or `T` into it wrote, and
  the pane reads which are taken over (`taken_in`) off the list as it is
  drawn - worked out with the metadata, a `T` that took one over left it
  listed as the other item's.

### The terminal

- **Dark or light is asked, not guessed, and the answer is an event.**
  `CSI ? 996 n` and `CSI ? 2031 h` at startup, and again after a `suspend`
  (which turns reports off, since they would land in the child's input);
  the answer, now and on each change, is `CSI ? 997 ; 1|2 n` - xterm.js
  from the 6.1 betas, which VS Code tracks, and tmux from 3.6. Nothing
  waits for it: a terminal that does not know the question says nothing,
  and the configured theme stands. Not OSC 11 for dark or light: that is a
  colour to judge, and 997 says it outright. A pane's input is raw, so
  `readraw` takes the report out of it before the child sees it. The theme
  is `config.toml`'s or its pair by name, and the browser's nodes, which
  hold the old faces, are rebuilt from the cache in place.
- **The terminal's background is asked for the panes, and tmux answers
  them.** `OSC 11 ?` goes with `CSI ? 996 n`, and again when a 997 report
  flips; the answer is `SchemeEvent`'s `bg`, whenever it arrives, and
  nothing waits for it. `ESC ]` heads an OSC as `ESC [` heads a CSI, read to
  its terminator by TermInput's `readevent` however many reads that takes, so
  its tail is never keys; Alt-] is spent on that, and nothing bound it. A pane's raw
  read that ends partway into either report reads on until it is one or
  cannot be (`readraw`), so neither reaches the child in halves. It goes to tmux as `refresh-client -r %pane:` (`mux_bg!`):
  tmux answers a child's `OSC 11 ?` only from a colour it holds, and with
  only a control client attached it holds none and says nothing
  (`input_osc_colour_reply`, 3.5a and 3.6) - so nvim took `dark` whatever
  the terminal was. Seeded, tmux answers every query itself, at once and in
  the child's terminator, and `CSI ? 996 n` from the same colour. A new pane
  is seeded while it is still `cat`, with the pipe opened for it there
  (`mux_start`'s `pipe`), because nvim asks as it starts; a running one when
  the colour changes or the pipe opens. The seed counts only while a control
  client is on the server, which is while wl is. A running child is not told
  of a change: tmux sends 997 into a pane on a change of its style, not of
  the seed.
- A one-row field must hold one row: `showerror` embeds a newline, and one
  element holding a newline scrolls the screen and shifts every mouse click.
  `oneline`.
- **The cursor is the terminal's, wherever typing goes** (`viewcursor`, after
  `render`): a composer's caret and a prompt's, a picker's query, the `/`
  being typed, a hosted program's cursor. A drawn block cannot blink, ignores
  the shape the user chose, and is not where an input method opens. There is
  one, so a composer beside the thread while the thread has the keys draws a
  block in reverse video where its caret is, and the terminal's is hidden.
- `capture-pane` says nothing about the cursor; `viewcursor` puts the
  terminal's where the child's is.
- **A frame is one write** (TermInput's `frame_bytes`): cursor hidden, the
  rows, the title, the caret and then the cursor shown, inside a
  synchronized output hold (`?2026`) that a terminal which knows it draws
  once. A `TTY` is unbuffered, so `print` with three arguments was three
  writes, and the cursor shown at the end of one frame was at the top left
  for the start of the next.
- **No frame while input is waiting** (TermInput's `input_waiting`). A paste
  reaches a composer as one key per character, and a frame after each was ~14 kB per
  character to render, write and draw: 2700 characters took 5.6 s under tmux
  and about typing speed in a real terminal (2026-09-25). The loop skips the
  draw while bytes already read sit in stdin's buffer, and draws once they
  run out - 0.02 s for the same paste. It never waits for input to see if
  more is coming, since Julia stops reading a stream nobody is reading, so
  keys typed by hand still draw one frame each. A hosted pane never had the
  problem: `readraw` takes the whole burst, and that goes as one `send-keys`.
- **A paste is text, never keys.** Bracketed paste (`?2004`) is on for the
  whole run and off across `suspend`, so a paste arrives as one
  `PasteEvent` and goes to `onpaste!`: into a composer, a prompt, a picker's
  query or a `/` query being typed, and nowhere else - a `q` pasted into the
  list is not quitting, and a tab pasted into a composer is not moving the
  focus. A hosted pane's child decides for itself: see *tmux*.
- **A row is drawn by deleting its line and writing it again**: `\e[M` at
  the row, `\e[L` to put a blank line back, the row; `\e[r` once before the
  first. **Not a scroll region of the one row**: a region is two lines at the
  least, tmux ignores one a line tall, and the delete under it pulled the
  whole screen up - each row was written over the frame before's row twice
  as far down, and a pane's verbatim row, which stops at its last written
  cell, showed that frame at half height past its end (2026-09-30). An
  OSC 8 link leaves a marker on its line in xterm.js, freed only when the line
  is deleted or trimmed, and the alternate screen trims nothing: overwritten
  in place, a row kept every link it had ever held, and leaving the alternate
  screen disposed them all, quadratic in the count - 5 s after 1000 frames of
  30 links, 100 s after 4000 (`@xterm/headless` 6.1 beta). VS Code runs that
  xterm in its pty host, and restarts a pty host that misses its heartbeat for
  12 s, with every terminal in it: quitting `wl` or `^]a` over Remote-SSH
  (2026-09-28). An `id=` on the link bounds the markers only by url and row,
  which a scrolled thread outgrows; the delete bounds them by the screen. One
  row at a time, so a terminal drawing mid-frame shows a row blank and nothing
  moved; never a clear, which is a flicker on every key. It also retires the
  erase after a row, which the pending wrap had made wrong: after a full row
  xterm.js counts the cursor past the last column and Terminal.app on it,
  where `\e[K` took the right border off every row (2026-09-21). Each row
  starts with the cursor put at its line, pending or not.
- **A hyperlink is not somewhere to write another one.** `linkify` runs on
  the finished rows; when links were escapes, a url inside a comment
  header's OSC 8 payload terminated it early and the row came out 224
  columns wide. A link is an annotation now, and a match already inside one
  - or inside a pane's verbatim row - is left alone.
- **Inside a changed line, the words that changed are marked**, as GitHub
  marks them: a run of `-` lines followed by as many `+` lines is paired
  line for line, and an unequal pair of runs by likeness, each `-` line to
  the `+` line most like it still free and later than the last taken, so
  the pairs read in order. Each pair is diffed by token (a word, a run of
  spaces, one other character) with a longest common subsequence in which
  a word in common outweighs a mark in common, so `frame` is paired over
  the `.` beside it, and the tokens not in common are drawn in
  `diff_add_word`/`diff_del_word` over the line's colour. Likeness is the
  share of the *shorter* line's *words* the two share - an append is the
  clearest edit there is, and `(`, `=` in common are not likeness - and
  under a half is a rewrite that marks nothing, which is also how a `-`
  line with no line like it is left alone in an unequal run. The
  roles are backgrounds where the palette has them, laid over the line's
  colour, and the cursor row's background goes under both.
- **A diff is somebody else's bytes, printed.** An escape in one is a
  command to the terminal the frame is drawn on, and `gh pr diff` refuses
  to pipe one at all ("pass --allow-escape-sequences"), which was a row of
  stderr under the diff and no diff. `fetch_diff` captures stderr and asks
  again with the flag; `inert` draws C0, DEL and C1 as caret notation at
  both parsers and under `[`/`]`, and `ctlnode` puts the count on the first
  row, where a long diff cannot push it off the screen.
- **A tab is the columns it draws, not zero.** `textwidth('\t')` is 0 and
  the terminal moves to the next stop of eight, so a Makefile's diff - a
  tab at the head of every recipe line - fit the pane by measurement and
  tore it on screen. `detab` draws a tab as the spaces to the next stop,
  counted from the start of the line as `git diff` on a terminal counts,
  in what *prints* only - the diff and plain branches of `nodelines` - and
  the `src` behind the row keeps the tab, so `y` copies one and `^r`'s
  suggestion carries one. `row_span` gives up on such a row, and the search
  marks what is visible.
- A key code is **the bytes that arrived**, packed big-endian, and `K_BASE`
  is `1 << 32`. Starting the key range at `0x110000` let a malformed
  four-byte sequence assemble to `K_LEFT`; rejecting non-codepoints is wrong,
  because Julia does not need a decoder to throw anything away.
- `REPL.TerminalMenus.readkey` cannot see a mouse report and drops any
  sequence it does not know as a bare `Escape`. `readevent` consumes what it
  cannot parse, as `K_NONE`. Three spellings of Alt-arrow are decoded.
- **The reader is parked between events** (TermInput's `InputReader`): it
  reads one event per `arm!` and is waiting on its token, not on the tty,
  while the loop handles it - so `suspend` hands `$EDITOR` every key, where
  a reader looping on `read` raced the child for each one and kept those it
  won. The loop arms it only once the event before is handled, and never
  twice for one: a wake does not use the token up. Which read the next event
  gets - `readevent`, or `readraw` for a hosted pane - is the loop's to say,
  since it knows what is on top and the parked reader does not.
- **Leaving the terminal never throws.** The commonest way out of `run!` is
  the terminal having gone away, which the reader says as an `EndEvent`,
  and then every write in the `finally` is to a closed descriptor;
  `leave_terminal` tries each half apart, so raw mode is still given back
  when nothing can be written, and no exception about handing back a
  terminal replaces the one that brought the loop there.

### Processes

- **A background fetch has to be findable.** Everything goes through
  `fetching`, keyed by what it fetches; `@async` into a field is overwritten
  by the next load and cannot be joined or asked whether it failed.
- **An alias is not reachable from a program.** `T` runs `$SHELL -ic claude`:
  `-c` without `-i` reads no rc *and* has `expand_aliases` off; `exec claude`
  looks up `exec`. Reading the alias is the point - a copy in `config.toml`
  would drift.
- `token` calls `Sys.which` before it runs `gh auth token`: a failed spawn
  leaves a process handle in async close that nothing owns - and, with an
  `IOBuffer` on stdin, as the lanes' `gh api graphql` had, a pipe with an
  orphaned writer - which is what hung precompilation. `robustness.jl`
  counts libuv handles across a request with no token and no `gh`.
- Every git call runs under `LC_ALL=C`: `%(upstream:track)` is translated,
  and parses as no divergence in a translating locale.
- `bin/wl` ignores SIGHUP in the shell, because an ignored disposition is the
  one thing that survives `exec`.
- **`u` runs the refresh in-process, on a task, and it yields.** It was a
  child because `refresh` wrote stderr; once it reported through `reporting`
  the only reason left was the CPU, and that was measured (2026-09-17, network
  faked, the real 5.7 MB corpus): 0.45 s in one unbroken stretch. Tasks are
  cooperative, so `breathe` yields every 256 rows of each walk over the
  corpus and `yield()` sits at each file read or written; the longest stretch
  left is `save_fetched` at ~100 ms, a hitch and not a hang, and not worth
  `-t auto` and a thread with the shared-state audit that would need. The
  browser draws its own copy meanwhile; the refresh's writes are `OURS` and
  `refresh_all!` sets `reload` itself. `wl refresh` and `bin/refresh` are
  still a process, for the cron and the hand.
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

### Julia, read by `--trim`

- **`@nospecialize(x) = default` does nothing.** An argument with a default
  loses the mark on every method it makes (1.12 to the 1.14 nightly), so a
  call holding an `Any` there is dynamic after all; `thread_facts!` and
  `carry_mention!` are two methods written out for that. `@nospecialize x`
  in the body does mark it.
- **A value typed `Any` is a dynamic call wherever its type is a parameter.**
  `"k" => v` builds a `Pair` of `v`'s type at run time, and `OrderedDict`'s
  `setindex!` specializes on the value, where Base's `Dict{K,Any}` has a
  method that does not. So a row the refresh builds (`Record`) is a
  `Dict{String,Any}` filled key by key, and `String(s)` of an
  `AbstractString` is asserted `::String` so the one dynamic call stops there.

## Decisions not to re-litigate

- **One client for GitHub, HTTP.jl** (2026-09-28). Every request - the
  lanes' GraphQL, the poll's REST, the writes, the diff - is `github` in
  `gh.jl`, which answers `(rc, text, err, date)` and never throws for a
  status. Not `gh api`: a subprocess per request, and a subprocess does not
  trim. Not GitHub.jl: no GraphQL, so it was always a second transport, and
  it brings MbedTLS, whose callbacks do not trim. Not Downloads.jl: its
  libcurl glue does not trim. HTTP.jl's own retries are off - `retrying`
  over `retry_wait` is the one policy, for reads only - and the protocol is
  its default: HTTP/2 by ALPN, since trimmed, an HTTP/1.1 request with a
  body hangs (TODO, *Upstream*). `gh` stays for
  two things: `gh auth token`, the last place `token` looks, since gh may
  hold the token only in the keyring; and `gh pr checkout`, which is git.
- **No sweep heuristic.** "Moved recently" is not a hint for what moves next;
  the bounded set re-asked whole is the open work itself.
- **No source axis** (direct · participating · watching). Those are GitHub's
  filters and GitHub is where to go for them; what subtracts the pile is
  dismissal, one item at a time, recorded, undoable.
- **No bucket**, and no `wl next`: the tags it handed out were the marks the
  browser writes one row at a time, where the row can be read first.
- **Newest first**, no fifth sort, no ceiling on the second look.
- **Done by construction is a fact about the source**, one line per
  source, not a stamp per row - in every lane, and raised together by
  `wl done --consolidate`, never per source and never lowered.
- **Nothing stamps the observation clock.** Every mark stamps the movement,
  GitHub's time; see "Time" for the two counterexamples, written down so
  it is not tried again.
- **The lanes stay GraphQL**; REST search could answer the three queries but
  not the bundle. GraphQL is slow per row (150-200ms a node), not per request.
- **The terminal's dark or light is not forwarded into a pane; its
  background colour is.** tmux takes `CSI ? 997 ; 1|2 n` as a key only from
  a real terminal client, and `send-keys` would type it into the child
  instead. A control client's one channel is `refresh-client -r %pane:` with
  an OSC 11 colour, and that is used, with the colour the terminal itself
  answered - not one invented from 997 - which is what tmux asks a terminal
  client for too. Not relayed per query, spotting `OSC 11 ?` in `%output`
  and answering with `send-keys`: only a pane with a client reading its
  output would be answered, and one tmux could answer too (a real client
  attached, a `window-style` bg) would be answered twice.
- **`p` uses a checkout**; there is no endpoint.
- **`d` uses the checkout too, when one is pinned, and GitHub without.** Both
  ends are known - the head and where the base branch was, `headRefOid`
  and `baseRefOid` off the lanes - so the diff is `git diff` from their
  merge base, computed each time: two shas the checkout has are
  milliseconds and never stale, and there is nothing to key a cache by.
  GitHub's diff by number was a clock, fresh for two minutes whatever was
  pushed inside them and a request every two minutes after. A sha the checkout lacks is fetched once. Without a
  base sha (an old record) the base *branch* answers, and must be fetched
  every time: a copy older than the fork point puts the base's own commits
  in the diff, and nothing local can tell that copy from a branch made off
  the current tip - both have the base as an ancestor of the head - so when
  the fetch fails and the base is an ancestor the checkout declines, since
  GitHub's copy is the better answer than a wrong one.
- **`^u` kills to the start of the line** (readline), not the whole line.
- **The mouse is owned**, `m` gives it back.
- **Markdown is drawn by TermInput, from the stdlib's tree** (2026-09-30).
  Term drew it until then, and most of the markdown code here worked around
  the layer in the middle, where Term turned the tree into `{…}` markup and
  the markup into escapes: the brace escape, a sentinel colour to find a code
  span by, a second render at 2000 columns aligned against the first to
  recover a paragraph for a copy, nested tables made into code, and Term's
  resets stripped when there was no theme. `markdown_rows` draws from the
  tree, rows of the pane's width that each carry the line they came from, so
  none of that exists. Not a parser of our own: the stdlib's is what
  `escape_source` and `gfm_table` already correct, and a second parser is a
  second set of those. Highlighting is Julia's own highlighter from 1.12, a
  stub before it and for every other language - which is all Term did too,
  since tree-sitter's Julia grammar was the only one it had.
- **The terminal's plumbing is TermInput's; the loop is ours** (2026-09-30).
  The key decoder, the modes and their undoing, the reader task and the frame
  writer were 450 lines of `controller.jl` that any other host of the widgets
  would write again, or replace with `readkey` and be wrong. They moved as
  they were, each usable alone and none owning the loop. What stayed is the
  loop and its policy: the view stack and its dispatch, wakes, `settle!`, the
  error log, what a scheme report does to the theme, `mouse!`, the raw path
  a hosted pane forwards (`readraw`, `scheme_in` - TermIFrame's business if
  it moves anywhere), and the SIGWINCH watch, which is a libuv signal handle,
  an `AsyncCondition` and a task: too large a piece for a widget package
  until it is clear where it belongs (LATER).
- **No cell diffing; every frame is every row** (2026-10-01). Tachikoma.jl
  draws only the cells that changed, and was weighed against `frame_bytes`
  (2026-09-29): at this screen's size one synchronized write of the whole
  frame is already cheap, so a diff saves nothing that is felt. And a diff
  only ever overwrites, so it never frees an OSC 8 link's marker (see "A row
  is drawn by deleting its line"): it leaks more slowly than redrawing in
  place did, once per link that changes rather than once per frame, but a
  scrolled thread changes every link on every step, and nothing on the
  alternate screen trims them. Freeing them would mean deleting every line
  whose links changed, which is most of what the diff was there to skip.
- **The config merges two levels deep, and the login is `@me`.** A deeper
  merge would make `[events] repos` in your file additions to a shared list
  with no way to take one out, and a `[views."name"]` of the same name a
  merge of axes rather than the view - so a table key by key, and whatever is
  under a key whole. The lanes were going to template `{login}`; GitHub's own
  `@me` is the same thing with no code, and it is what the shared file says.
  The seed is a copy of the template and not `TOML.print`, because the
  comments are the manual for the keys and a serialization drops them.
- **The metadata pane is a readout, not a third focus.** Editing in place
  was designed as far as its cost (2026-09-17): every `kv` row carrying its
  key so the layout can hit-test it and `j`/`k` can walk it, a third stop
  on `tab` that every composer beside the diff then has to step over, and
  at the end of it two more GitHub mutations for assignee and reviewer. The
  fields that can change from here have keys - `L`, `s`, `v`, and `;`,
  one key and a picker the way `'` opens views - not a cursor on the pane.
  `;` is the one lowercase key with GitHub behind it: `track` is its first
  row and this machine's, and the milestone, the assignee, the reviewer,
  the state and the title are the rest, since a capital each is five keys
  the footer has no room for. The picker's note says which is which, and
  `z` undoes only the first. Closing and reopening ask, as `M` does.
- **A pane's environment is paths that do not move, not a passthrough.**
  Only a shell could re-read the session environment, and only with a hook
  in the user's rc; the agent in a `T` pane and the editor in a `v` pane
  never would. Three forwards, each one link: the ssh agent, VS Code's
  socket, `code`. Not `SSH_CONNECTION`, `DISPLAY` or the askpass variables -
  nothing in a pane has needed them. **And from `wl`'s own environment or
  not at all**: the newest `vscode-ipc-*.sock` or `/tmp/ssh-*/agent.*` on
  the machine is some session's, and a search would hand a pane another
  window's `code` or another login's keys.
- **`code`'s command line stops at a file and a line.** `--goto file:line`
  opens one; `--diff a b` opens a diff but the workbench drops the line
  (`NativeWindow.openResources` builds the diff input with `pinned` and
  nothing else); there is no `--command`, the remote CLI's socket carries
  only `open`, `openExternal`, `status` and `extensionManagement`, and
  `command:` urls are honoured inside VS Code's own markdown alone. The only
  way to ask for anything else is a `vscode://<publisher>.<name>/...` url,
  which is routed to that extension - so `vscode/` is one, with two verbs:
  `o` on a diff line hands it `diff` when `--list-extensions` says it is
  there, and is `--goto` when it is not; `o` on a commit in a list of them
  hands it `commit`, and is the checkout when it is not. The desktop CLI takes the url
  as `--open-url` and the server's (`bin/remote-cli/code`, what a Remote-SSH
  terminal has) as `--openExternal`; each drops the other's option and
  opens a file named after the url, so the path the `code` link resolves to
  picks the spelling, and the scheme with it. The refs it sends are local
  answers (`base_ref`, `merge_base`, `done_head`), never a fetch: a key press
  does not wait on the network, and a base that is only ever too old is the
  trade.
- **The mark is called done, and the key is `e`** (2026-09-21). What the
  program stamps is what the GitHub inbox and Gmail call done, and both
  bind it to `e`, so the word and the key match them; the other state is
  *not done*, and *unread* stays the word for the fact of having moved.
  Which keys `e` displaced and where each went - `o` open, `h` history,
  `I` import, `h` in the worktree list, `w` kept - is said beside each
  binding in `keys.jl`, `paneview.jl` and `sessions.jl`; the boxes and
  their TOML keys beside `SHOW` and `apply_view!` in `filters.jl`.
- **A hosted child is a session of its own, not a window or a pane of a
  shared one** (2026-09-28). A pane sizes its child through its own control
  client (`refresh-client -C`), which sizes that session's window and no
  other; windows of one session are sized by the same clients, and panes of
  one window split its area. And a session is the unit tmux keeps the seen
  bit by (an attach is looking), that `^]a` or a hand's `tmux attach` shows
  one child of, and that `kill-session` and `%exit` end: in a shared session
  what was looked at would be whichever window is current, for everyone
  attached. One control client could hear every child there, which is the
  pull; it does not outweigh the rest.
- **TermIFrame takes no functions from its host.** A stored callback is a
  field typed `Any` and a dynamic call under `--trim`, and each one the
  iframe took was a thing the host could read instead: the client's `wake`
  (an `Event` that resets as it is taken, which `watch_pane!` waits on and
  turns into `wake!`), the clipboard kept on the client and printed by the
  sync on the loop's task rather than by the reader mid-frame, the client
  gone after a sync (`pane_sync!` takes a note back from `PaneView.note`,
  once). And `oncommand` went the same way, which took the keys with it:
  TermIFrame finds the prefix - it is in the raw stream beside pastes and
  mouse reports, and a read can split it from its key - and `iframe_input!`
  answers the key after it and keeps what was read after that. Every key
  after `^]` is `wl`'s (`pane_command!`, `pane_key!`, the same list the pane
  answers once its child has gone), and the rest of the read goes to the
  child only if the key left it with the keyboard.
- **A prefix is an argument, not a setting.** It is the first part of a
  name (`mux_name`) and what a listing filters by (`mux_sessions`,
  `mux_list`, the pipe's bell subscription), and `wl` passes its own,
  `SESSION_PREFIX`, beside `SESSION_TAGS`. Nothing holds a host to one: two
  prefixes are two sets of sessions with their own behaviour. The pipe is
  still one per process, opened for one prefix; a pipe for each is for
  whenever a host has two. `MUX_PIPE` stays a global, and `MUX_ENV`, which
  names the variable to export for another tmux binary. There is no
  environment scrubbing: `SCRUB_PREFIXES` unset the `CLAUDE*` variables in
  every pane, for a problem that came from running the suite inside an
  agent, and the suite's harness is the place for that if it comes back.

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
