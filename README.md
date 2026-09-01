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
| `state.toml` | you + the model, via `wl.py` | **never machine-rewritten** |
| `facts.json` | `refresh.py` | overwritten every run (gitignored, ~1MB) |
| `firehose.json` | `refresh.py` | cache, refetched every 6h (gitignored) |
| `queue.json` | `wl.py next` | what the backlog queue has shown you (gitignored) |
| `snooze.json` | `refresh.py` | overwritten every run |
| `DASHBOARD.md` | `refresh.py` | overwritten every run |

`refresh.py` reads `state.toml` and never writes it. Every snooze and note you
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
python3 wl.py track julia#62452 close
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
python3 wl.py next 10            # next untagged backlog items, quietest first
python3 wl.py dismiss julia#43202  # retire: loose + wake only on real movement
python3 wl.py track   julia#43257 loose
python3 wl.py note    julia#44005 "still relevant; rebase onto the new pass manager"
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

## Use

```bash
python3 refresh.py                                   # ~40s, ~21 of 5000 rate points
python3 wl.py note   julia#62452 "rebase after #62396"
python3 wl.py agent  julia#62841 "bisect CI, prepare fixups"
python3 wl.py snooze libuv#5212 on-change
python3 wl.py clear  julia#62452
```

Or `/dash` in Claude Code, which refreshes, triages the change set and reports
only what moved.

## Scope

`config.toml` defines the lanes. Currently: PRs you authored, PRs awaiting your
review, issues assigned to you, plus **every** open PR in JuliaLang/julia as the
background pile. The `areas` list is a ranking signal for `wl.py next`, not a
filter — nothing is excluded.

The firehose is fetched on its own 6-hour cadence (`python3 refresh.py --firehose`
forces it), because it is ~1000 PRs and ~2.5 minutes, while a normal refresh with
it cached is ~16s and 12 rate-limit points.

Two GitHub behaviours worth knowing, both of which cost real debugging:

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
