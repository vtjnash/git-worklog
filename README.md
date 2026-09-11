# worklog

A dashboard for tracking ongoing work across every repo, sorted into lanes by
what the work actually needs next.

Nothing off-the-shelf did this. [gh-dash] is stateless — every section is a live
query, so there is no snooze, no note, no memory of what changed. [Octobox] has
real snooze but triages *notifications*, and `GET /notifications` is 403 for the
sandbox's GitHub App token. GitHub Projects v2 can hold the state but cannot
populate or classify a couple of thousand items. The missing piece in all of them is judgement:
"needs edits" vs "needs an agent" is a fact about content that no query language
expresses.

[gh-dash]: https://github.com/dlvhdr/gh-dash
[Octobox]: https://github.com/octobox/octobox

## Design

The split that makes it safe to let a model touch this:

| file | owner | lifetime |
|---|---|---|
| `config.toml` | you | edited by hand |
| `data/local.toml` | you + the model, via `wl` | **never machine-rewritten** — edited key by key, block by block. Per item: your note, snooze, deadline and tracking level, and what you have done to it (seen, and the head you saw it at, touched, drafted). Plus a `repo:` block per local checkout. Tracked |
| `data/fetched.json` | `wl refresh` | everything GitHub can answer again: the items, the slow-lane cache, the poll's cursors and what it saw. Not tracked; ~4MB |

Everything but `config.toml` lives in `data/`, which is a git repository of its
own. Two files and one line between them: what can be re-fetched from GitHub is
gitignored, and what records something you did is tracked.

The refresh never rewrites `local.toml` - it edits the keys it owns, in the
blocks it names, and leaves every other line byte-identical. Every snooze and
note you set survives any refresh, and a confused model cannot erase your
triage.

Buckets are derived from facts by rules, not guessed: changes-requested or
unresolved threads or red CI → **needs-edits**; `CONFLICTING` → **needs-stacking**;
approved and green → **ready to merge**; they pushed after your last review →
**needs-review**. Judgement is not made here at all: what a red CI really means,
what the next action is, and what is urgent are written into `local.toml`, by
you or by a model reading the same files.

## Snooze until it moves

`snooze = "on-change"` fingerprints the PR (head commit, review decision,
mergeability, CI, unresolved threads, last comment, labels) and hides it until
that fingerprint differs. For a PR waiting on a reviewer this is the right
primitive — a timer is guessing, and Octobox only offers 1h/1d/1w/1mo. Once
woken an item stays awake until you re-snooze, so a wake cannot scroll past you.

An `on-change` snooze on its own has no clock, and a pull request everybody has
quietly given up on is exactly the shape whose fingerprint never differs — so it
would hide forever, and that is the one worth being reminded of. Give it a
deadline: `snooze = "on-change/30d"` wakes when it moves *or* after thirty days,
whichever comes first, and `max_days` under `[snooze]` in `config.toml` is the
default cap for the ones that carry none.

`snooze = "2026-09-15"` still works for real calendar constraints, and
`snooze = "3d"` / `"2w"` / `"6mo"` count from when you set them.

**A snooze marks it read, and waking marks it unread again.** "Not now" and
"unread" are the same answer twice, so an item you have put away stops sitting
in the unread lane asking to be read - and when it wakes it comes back as news,
by the same hand-delivery `wl import` uses, since the repo it is in may be one no
lane polls. Both edges and only the edges: marking read every refresh would bury
a comment that arrived while it slept, and marking unread every refresh would
make a woken item impossible to file. Clearing a snooze by hand is not a wake -
you did that on purpose, on an item in front of you.

**Waking happens in `wl refresh` and nowhere else.** It is not a predicate a
browser can evaluate: deciding an item has woken also arms and records it, so
two windows on one dashboard would each decide and each write, and neither would
know what the other had already woken. The browser shows the answer the last
refresh wrote, and the metadata pane says which trigger the item is waiting for
- `until it moves`, `for 2w, 9d left`, `until 2026-09-15` - so a snooze that has
run its course comes back when you ask for a refresh, at a moment you chose.

## Lanes

Fast lanes, fetched every refresh: PRs you authored, PRs awaiting your review,
issues assigned to you. Slow lanes in `[bulk.queries]`, fetched every 6h: every
open PR in JuliaLang/julia, plus everything you were mentioned in or have
commented on (~2500 items). Nothing from a slow lane surfaces on its own.

The one exception is **needs-reply**: you were mentioned within `reply_days`
(30) and the last comment is not yours, so a question is probably owed an
answer. Deliberately narrow — plain `commented:` never qualifies, because in the
repos where you are effectively the maintainer you touch nearly every PR, and
that would put forty items a week in front of you.

## How closely you track an item

`track` is what counts as this item having *moved* - which decides both whether
it goes unread and whether a snooze on it wakes. Two levels, because two is what
anybody sets:

| level | counts as movement | default for |
|---|---|---|
| `normal` | a push, CI finishing, a review verdict, an unresolved thread resolving, any comment | **your unfinished work** |
| `loose` | a review verdict or a **human** reply — bot comments and CI churn are ignored | everything else, and anything finished |

```bash
cli/bin/wl track julia#62452 loose
```

This is a real difference in behaviour rather than a label, because the
fingerprint is hashed from the level's key set: CI turning green on your own
pull request makes it unread, the same on a stranger's does not, and a human
reply reaches you either way.

It also answers a thing GitHub cannot. `updated_at` does not move when a check
run finishes - a pull request stamped 20:55:52 had its three suites complete at
20:56:04, :07 and :19 and the stamp never moved - and it *does* move when
somebody relabels a pull request you have no interest in. So "has this changed
since I looked" is measured against `moved_at`: when this program last saw a
change at the item's own level.

## Showing what changed, not just that something did

Knowing an item moved is half an answer. The other half is *what* moved, and
without it, opening something you have already read means being handed the whole
thread and the whole diff again with the new part somewhere in them.

Three things answer it, and all three are read off the mark `r` leaves behind:

**The thread is one activity list.** The comments and the pushes are one
sequence — "they replied, then pushed, then replied" — and reading it as two is
why you scroll back and forth. The commits are drawn in among the comments in
the order they happened, with a run of them that nobody spoke between folded
into one `↑ pushed 3 commits` entry.

**A rule says where the new part starts.** `r` marks a thread read up to the
moment it was *fetched*, so everything written before the stamp was on screen
and everything written after it was not. An item that comes back unread opens on
that rule with the new entries below it, rather than at the top of a forty-entry
thread you have read thirty-nine of. That is also why nothing records *which*
comment you had got to: the stamp already answers it, and a second answer is one
that can disagree with the first.

**`p` is what has been pushed since you last looked.** The stamp cannot answer
this one — a rebase is invisible to a clock — so the read mark also records the
head commit it was made at, and `p` diffs that against the head now:

| what the branch did | what `p` shows |
|---|---|
| only added to it — the old head is still in its history | the plain diff between the two heads, and how many commits arrived |
| rebased, amended, force-pushed | `git range-diff`, one foldable node per commit, marked `unchanged` / `changed` / `gone` / `new` |

It needs a pinned checkout, because there is no GitHub endpoint that compares
two heads of one pull request — `compare` is between refs and the head you saw
is not one. It also needs to have been marked read once; on an item that never
has been, the pane says which key makes one rather than showing an empty box.
Only `r` writes that sha — a snooze, an archive and `wl read` stamp "not now"
and know nothing about what you were looking at, so they leave it alone.

## Working the pile

The pile is about two thousand items: every open PR in JuliaLang/julia (~690),
and everything you were mentioned in or commented on (~1300). It is in the
corpus like everything else - the browser opens on what *moved*, so it is not in
front of you until it does - and `wl next` is the other way at it: pull a batch
when you want one and work through it by tagging.

```bash
cli/bin/wl next 10                 # next untriaged items, quietest first
cli/bin/wl dismiss julia#43202     # retire: loose + wake only on real movement
cli/bin/wl track   julia#43257 loose
cli/bin/wl note    julia#44005 "still relevant; rebase onto the new pass manager"
```

Anything you have tagged never comes back in `next`, so the queue drains
monotonically and you can stop and resume at any point - the tag is the only
record of having dealt with something, and there is no second one. `next` hands
you your areas first (from `config.toml`'s `areas` list) so a thousand-PR pile
still leads with the relevant end of it.

## The stale pile

Yours, quiet for 60 days, and unclaimed → the **stale** bucket. It is a true
thing to say about a row and no longer decides whether you see it: nothing is
evicted for being quiet, since a row leaving on a day nobody chose is the one
thing a dashboard must not do. `second_look` is the live half of this - work
that has gone quiet *on somebody*, derived every refresh and never stored.

## The browser

The same program with no arguments is an interactive browser over the same data:

```bash
cli/bin/wl              # the item list, its metadata, and the thread or diff
cli/bin/wl --refresh    # re-fetch first
```

`u` re-fetches from inside it - the whole dashboard, in the background, with the
list rebuilt where it lands; `R` is the same thing for the one item under the
cursor. `u` is Gmail's key for it, and it was free because `r` toggles read
either way.

A fenced code block becomes a foldable block of its own rather than prose, so a
pasted log folds away to one line and never gets drawn as a box wider than the
pane. Inline code is a quiet grey span instead of yellow punctuation, and
`snake_case` names keep their underscores — Julia's Markdown reads them as
emphasis, which CommonMark forbids and GitHub does not do.

`d` is the diff, `o` the thread, `p` what has been pushed since you last looked,
and `c` the per-check breakdown — see "Showing what changed" above for the last
of those and for the rule the thread opens on.

It opens on **what moved, awake and open**. So an item leaves the opening list
two ways - you read it, or you put it away with `s` or `x` - and comes back the
same two ways, with "moved" meaning what `track` says it means for that item.

That list is one box on an axis that only **adds**. Five checkboxes -
`unread, awake, open`, `read`, `snoozed`, `filed away`, `closed or merged` -
and each brings its own kind of row *beside* the others rather than instead of
them, so no box can take another's rows away. The number next to each is what
checking it would bring, or what unchecking it would take away. All five is the
corpus, and `'` has it by name ("everything"); `c` clears every filter, which
lands on the first box alone rather than on the corpus.

The first box is checked when nothing has been asked - it is what the dashboard
*is*, and `c`, a fresh filter and a view that names no `show` all leave it on -
so the screen cannot be emptied by accident. Unchecking it is how you ask for
one of the other four **alone**: the filed work on its own, rather than beside
today's. Uncheck all five and you get no rows, which is what an empty set of
things to show means.

The `read` box is a question about awake work only: putting something away
stamps it read, so `snoozed` and `filed away` bring what they name whether or
not it has been read. A box that insisted on both would have been a control that
did nothing.

The list itself says what has been read: unread rows are bold and read ones
plain, and the cursor is a background rather than a weight - the same mark the
reading pane puts on the line you are on.

Under the item list is a metadata pane: who has reviewed and who was asked,
labels, the check tally, milestone, mergeable state, and the tracking level and
note from `local.toml`. It sits there rather than beside the detail because ten
item numbers at a time is plenty and the thing being read wants the height.
Everything in it that `fetched.json` already knows is on screen immediately; the
two that need a request — per-person review state and the per-check breakdown —
are fetched for the selected item only. The light GraphQL query the bulk lanes
use carries no reviews, so widening it would pay for ~2000 items to answer a
question about the one on screen.

The list opens newest first - by when anything last happened to an item, yours
or GitHub's - which is the order every other inbox has. `w` cycles the other
two: the interaction clock, and url order - owner, project, number, descending -
which keeps the grouping the fetch is written in and reads from the newest of
each repo. The number is sorted as a number, not as the digits it is written
with, so `#6661` is below `#62836` rather than above it. An order you choose
lasts until the selection changes, and the `[...]` summary names it only while
it is not the one that selection opens in.

`/` searches. In the item list it narrows by title or ref, and a bare number is
a jump — reaching past the filter that is hiding the item, since being unable to
see it is exactly when you go looking for it by number. In the thread or the
diff it marks every match and `n`/`N` step between them — matching the line as it
was written rather than as the pane wrapped it, so a phrase broken across a line
break is still found, and reaching into folded blocks, which `↵` then opens.

It owns the mouse rather than leaving selection to the terminal. That is not a
flourish: the terminal only sees the lines *we* wrapped, so selecting a
paragraph with it yields the wrapped fragments plus the pane borders. Dragging
here selects rows, and `y` copies them as the lines they were written as - one
line per paragraph, links whole, no colours in the paste. Clicking moves the
cursor and clicking a fold marker toggles it; the wheel scrolls the pane under
the pointer. A single click on a url copies it and a **double click** copies
whatever else is under the pointer - the word, the path, the identifier without
the backticks that made it code - while in the item list it copies that item's
url. Every node header carries a **`⧉`** at its right-hand end: clicking it
copies that block whole, the comment with its code and its tail, the hunk
without the conversation hanging off it. `m` gives the mouse back to the terminal when you want it - and
`shift-J`/`shift-K`, or the shifted arrows, extend a selection from the
keyboard, which is what `m` off would otherwise take away along with the drag.

`M` merges a pull request, on the message GitHub itself would have written -
`viewerMergeHeadlineText` and `viewerMergeBodyText`, which already honour the
repository's squash-title and squash-message settings. There is no picker in
front of it: the composer opens on the operation and `^x` changes it, rewriting
the message for the new one, because the operation and the message it decides
belong on one screen. The line above the message says the whole of what is about
to happen - the operation, how many commits land on which branch, and what
`mergeStateStatus` says about whether it can be merged at all, so that "blocked"
or "behind master" is read before the message is written rather than out of a
refusal after it.

The operation it opens on is squash where the repository allows it, then merge,
then rebase. That is this program's preference and is named on screen as ours,
because a repository has no default to have: `viewerDefaultMergeMethod` is the
only field of its type in GitHub's schema and it reports what *you* last merged
with there - the same allowed pair answers `SQUASH` on `JuliaLang/julia` and
`MERGE` on `JuliaCI/julia-buildkite`. Rebasing has no commit message at all, so
the composer empties and says why. `^s` asks once before it sends, which nothing
else that writes here does: a comment, a verdict and a label can each be
answered with another one, and a merge cannot.

A composer is drawn **beside** what it is about rather than over it, wherever
the screen is wide enough for two columns - the same split `t` and `T` put a
hosted program in, and none of that machinery was ever about a child process.
`c`, `A`'s body and `M` all open in the right-hand column with the diff or the
thread still on the left, and `tab` moves the keyboard between them; `esc` and
`q` come back to the message too, since `q` in the browser ends the program and
quitting out from under a half-written comment is what this exists to prevent.
Below 150 columns there is no room for two, and a composer takes the screen the
way it used to. `v` was already doing this - it runs `$EDITOR` in a pane - which
is where the idea came from.

That is also why the merge composer cycles the operation with `^x` and not
`tab`: `tab` moves the keyboard between two things on screen, here and in the
item list and in the worktree lenses and after `^]`, and a composer drawn beside
its diff needs it to go on meaning that.

Coming back to an item lands on the line you were reading in it, per item and
per mode - a comment thread and a diff of one pull request are two readings of
it and two places to come back to. And when a row leaves the list under you -
`r`, `x`, `s`, each of which takes the row out of the opening list - the cursor stays on the row it was on rather
than jumping to the top, so an inbox is read by pressing `r`. Choosing a view, a
filter or a query is asking for a different list, and those open at the top.

Everything is one Julia module under `cli/src`, so the comment-preserving TOML
writer and the GitHub quirks below live in one place rather than two: the
browser calls the same functions the commands do, rather than shelling back
out to itself. Startup is about a second: 1.0s to the list pane and 1.14s to a
comment thread beside it, of which 0.96s is loading the module. `julia
--project=cli cli/test/latency.jl` measures it.

The GraphQL search lanes shell out to `gh api graphql` because GitHub.jl exports
neither GraphQL nor search; the REST side (`events.jl`) uses GitHub.jl directly,
though not its paginating helpers - see the `--paginate` note below.

## Saving

Nothing commits automatically. `/root/.claude` is a host bind-mount, so the repo
survives sandbox restarts on its own; commit when you have something worth
keeping.

Pushing needs a fine-grained PAT scoped to this repo with `Contents: read/write`
- the sandbox's GitHub App token is read-only for contents everywhere, including
repos you own.

## Authentication

The GraphQL lanes shell out to `gh`, so they use whatever credential `gh` has.
The REST lanes go through GitHub.jl, which needs the token itself; `token()`
looks in `/run/claudebox-github/token` (the sandbox host refreshes it, so it
beats a possibly-stale environment), then `$GH_TOKEN` / `$GITHUB_TOKEN`, then
`gh auth token`.

That last one is what makes this work off the sandbox: there `gh` keeps its
credential in its own config or the system keyring and exports nothing, so
`gh auth status` succeeds while `$GH_TOKEN` is empty. A missing token now fails
once with a message naming every place it looked, rather than once per repo.

## Use

```bash
cli/bin/refresh                                # ~20s, 12 of 5000 rate points
cli/bin/wl note   julia#62452 "rebase after #62396"
cli/bin/wl snooze libuv#5212 on-change
cli/bin/wl clear  julia#62452
cli/bin/wl                                     # the browser
```

`cli/bin/refresh` is `cli/bin/wl refresh`; every command is a subcommand of the
one entry point.

## Scope

`config.toml` defines the lanes. Currently: PRs you authored, PRs awaiting your
review, issues assigned to you, plus **every** open PR in JuliaLang/julia as the
background pile. The `areas` list is a ranking signal for `wl next`, not a
filter — nothing is excluded.

The firehose is fetched on its own 6-hour cadence (`cli/bin/refresh --firehose`
forces it), because it is ~1000 PRs and several minutes, while a normal refresh with
it cached is ~20s and 12 rate-limit points.

Two GitHub behaviours worth knowing, both of which cost real debugging:

Following `Link: rel="next"` is **unsafe on a `sort=updated` list**, whether the
follower is `gh api --paginate` or `GitHub.issues`. It walks a collection being
reordered underneath it, so an item touched mid-walk jumps to page 1 and shifts
a whole page past the cursor. The same query returned 168 items on one attempt
and 612 on the next. `events.jl` therefore uses GitHub.jl's single-request
`gh_get_json` and pages itself with `direction=asc` - where a concurrent update
moves an item toward the end, which can duplicate but never skip - and dedupes
by id.

`search(type: ISSUE)` silently returns **0** for `assignee:` unless the query
also carries `is:issue` or `is:pr`. REST has no such quirk, so 16 assigned issues
were invisible until the qualifier went in. Do not remove it from the `assigned`
lane.

A search returning Issues against a query fragment that only spreads
`... on PullRequest` yields bare `{__typename: "Issue"}` stubs with **no fields
and no error** — the light query needs both fragments or the two `is:issue` bulk
lanes come back as unusable husks.

GitHub's search API truncates at **1000 results** and this repo is at ~993 open
PRs, so the fetch partitions by creation year and unions the slices once the
total crosses 950. Long paginations also hit transient 502s, so pages retry.

`mergeable` is computed **lazily** — the first read of a PR returns `UNKNOWN` and
merely schedules the computation (94 of 145 on a cold run). Concluding from it
flaps the needs-stacking lane and spuriously wakes `on-change` snoozes, so the
last known value is carried forward until a real one arrives.
