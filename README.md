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
| `facts.json` | `refresh.py` | overwritten every run |
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

## The stale pile

Yours, quiet for 60 days, and unclaimed → **Stale — decide**, collapsed. Setting
any of `note` / `deadline` / `agent_task` / `snooze` claims an item and pulls it
back into an active lane. Triage the pile once; claim what matters.

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
review, issues assigned to you, plus a JuliaLang/julia discovery feed filtered to
your areas (compiler, codegen, GC, multithreading, dispatch, ffi, latency …) and
capped at 90 days.

Note: GraphQL search silently returns 0 for `assignee:` without an explicit
`is:issue` / `is:pr` qualifier, unlike REST. The `assigned` lane carries `is:issue`
for that reason — do not remove it.
