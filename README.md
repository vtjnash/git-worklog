# worklog

A dashboard for tracking ongoing work across every repo, sorted into lanes by
what the work actually needs next.

Nothing off-the-shelf did this. [gh-dash] is stateless — every section is a live
query, so there is no snooze, no note, no memory of what changed. [Octobox] has
real snooze but triages *notifications*, and `GET /notifications` is 403 for the
sandbox's GitHub App token. GitHub Projects v2 can hold the state but cannot
populate or classify 160 items. The missing piece in all of them is judgement:
"needs edits" vs "needs an agent" is a fact about content that no query language
expresses.

[gh-dash]: https://github.com/dlvhdr/gh-dash
[Octobox]: https://github.com/octobox/octobox

## Design

The split that makes it safe to let a model touch this:

| file | owner | lifetime |
|---|---|---|
| `config.toml` | you | edited by hand |
| `state.toml` | you + the model, via `wl` | **never machine-rewritten** |
| `facts.json` | `wl refresh` | overwritten every run (gitignored, ~1MB) |
| `bulk.json` | `wl refresh` | slow-lane cache, refetched every 6h (gitignored) |
| `queue.json` | `wl next` | what the backlog queue has shown you (gitignored) |
| `read.json` | `wl read` | one seen-up-to timestamp per item (gitignored) |
| `snooze.json` | `wl refresh` | overwritten every run |
| `DASHBOARD.md` | `wl refresh` | overwritten every run |

The refresh reads `state.toml` and never writes it. Every snooze and note you
set survives any refresh, and a confused model cannot erase your triage.

Buckets are derived from facts by rules, not guessed: changes-requested or
unresolved threads or red CI → **needs-edits**; `CONFLICTING` → **needs-stacking**;
approved and green → **ready to merge**; they pushed after your last review →
**needs-review**. Judgement is left to the `/dash` skill, which only looks at
items that changed since the last snapshot — that is what bounds the cost.

## Snooze until it moves

`snooze = "on-change"` fingerprints the PR (head commit, review decision,
mergeability, CI, unresolved threads, last comment, labels) and hides it until
that fingerprint differs. For a PR waiting on a reviewer this is the right
primitive — a timer is guessing, and Octobox only offers 1h/1d/1w/1mo. Once
woken an item stays awake until you re-snooze, so a wake cannot scroll past you.

`snooze = "2026-09-15"` still works for real calendar constraints.

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

`track` sets both how sensitive its wake is and how prominently it shows. It is
the answer to "I want to watch this one, and barely watch that one":

| level | wakes on | default for |
|---|---|---|
| `close` | anything, including a relabel | — (pinned to the top of its lane, marked `*`) |
| `normal` | pushes, CI, reviews, comments | your PRs, review requests |
| `loose` | review decisions and **human** replies only — bot comments and CI churn are ignored | assigned issues, reviewed-and-waiting |
| `background` | nothing; never surfaces on its own | the stale pile, the firehose |

```bash
cli/bin/wl track julia#62452 close
```

Because the fingerprint is computed from the level's key set, this is a real
difference in behaviour, not a label: a CI flip wakes `normal` but not `loose`,
a relabel wakes only `close`, a human reply wakes all three.

## Working the backlog

The background pile is **983 items**: every open PR in JuliaLang/julia (939) plus
your own that have gone quiet (44). None of it appears in the dashboard — not
even as a collapsed list, just a one-line count. You pull a batch when you want
one and work through it by tagging:

```bash
cli/bin/wl next 10                 # next untagged backlog items, quietest first
cli/bin/wl dismiss julia#43202     # retire: loose + wake only on real movement
cli/bin/wl track   julia#43257 loose
cli/bin/wl note    julia#44005 "still relevant; rebase onto the new pass manager"
```

Anything you have tagged never comes back in `next`, so the queue drains
monotonically and you can stop and resume at any point. `queue.json` remembers
what you have already been shown, and `next` hands you your areas first (from
`config.toml`'s `areas` list) so a thousand-PR pile still leads with the
relevant end of it.

## The stale pile

Yours, quiet for 60 days, and unclaimed → **Stale — decide**, collapsed and out
of the lanes. Setting any of `note` / `deadline` / `agent_task` / `snooze` claims
an item and pulls it back into an active lane; `track` alone marks it triaged
without reviving it.

## Navigator

The same program with no arguments is an interactive browser over the same data:

```bash
cli/bin/wl              # lane -> item -> thread -> action
cli/bin/wl --refresh    # re-fetch first
```

It owns the mouse rather than leaving selection to the terminal. That is not a
flourish: the terminal only sees the lines *we* wrapped, so selecting a
paragraph with it yields the wrapped fragments plus the pane borders. Dragging
here selects rows, and `y` copies them as the lines they were written as - one
line per paragraph, links whole, no colours in the paste. Clicking moves the
cursor and clicking a fold marker toggles it; the wheel scrolls the pane under
the pointer. `m` gives the mouse back to the terminal when you want it.

Everything is one Julia module under `cli/src`, so the comment-preserving TOML
writer and the GitHub quirks below live in one place rather than two: the
navigator calls the same functions the commands do, rather than shelling back
out to itself. Startup is ~0.7s.

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
cli/bin/wl agent  julia#62841 "bisect CI, prepare fixups"
cli/bin/wl snooze libuv#5212 on-change
cli/bin/wl clear  julia#62452
cli/bin/wl                                     # the interactive navigator
```

`cli/bin/refresh` is `cli/bin/wl refresh`; every command is a subcommand of the
one entry point.

Or `/dash` in Claude Code, which refreshes, triages the change set and reports
only what moved.

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

GraphQL search silently returns 0 for `assignee:` without an explicit
`is:issue` / `is:pr` qualifier, unlike REST. The `assigned` lane carries `is:issue`
for that reason — do not remove it.
