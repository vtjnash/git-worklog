---
name: dash
description: Refresh and triage the work dashboard across all repos - open PRs, review requests, assigned issues, and the JuliaLang/julia firehose. Sorts work into needs-edits / needs-agents / needs-stacking / needs-review, honours snoozes and deadlines. Use when asked what to work on, what changed, what needs review, or to snooze/note/schedule an item.
---

# Work dashboard

State lives in `/root/.claude/worklog`. Read `README.md` there once if you have not.

## The one rule

`refresh.py` owns the facts. You own the judgement. **Never rewrite `state.toml`
wholesale** — it holds the user's snoozes, notes and deadlines. Change it only
through `wl.py`, which edits single keys in place.

## Refresh

```bash
cd /root/.claude/worklog && python3 refresh.py
```

~40s, ~21 of 5000 hourly rate-limit points, so cadence is never the constraint.
It writes `DASHBOARD.md`, `facts.json` (snapshot) and `snooze.json` (armed
fingerprints). Then read `DASHBOARD.md`.

## Triage the change set only

Do **not** re-examine all ~160 items; that is what makes this expensive and
what the bucketing rules already handle. Look only at the **"Changed since last
refresh"** section and anything marked `NEW`. For each, decide the three things
rules cannot:

1. **Is the failure mechanical?** Rebase, a rerun of a flaky job, a mechanical
   API update, a stale checksum — if an agent could do it unattended, set
   `wl.py agent <ref> "<the task>"`, which promotes it into **Needs agents**.
   A design disagreement or a real bug is not mechanical; leave it in needs-edits.
2. **What is the actual next action?** One line, concrete, in the imperative:
   `wl.py note <ref> "rebase after #62396 lands"`. Not a restatement of the title.
3. **Should it be quiet?** If it is genuinely waiting on another person, snooze
   it until it moves rather than letting it sit in view:
   `wl.py snooze <ref> on-change`.

Prefer `on-change` over a date. It wakes the moment the PR actually moves, which
is almost always what "remind me later" really means for a PR. Use a date only
for a real calendar constraint.

## Commands

```bash
python3 wl.py note     julia#62452 "rebase onto master first"
python3 wl.py agent    julia#62841 "bisect the CI failures, prepare fixups"
python3 wl.py snooze   libuv#5212  on-change     # or 2026-09-15, or off
python3 wl.py deadline julia#62452 2026-09-30
python3 wl.py blocked  julia#62452 JuliaLang/julia#62396
python3 wl.py track    julia#62452 loose        # close|normal|loose|background
python3 wl.py dismiss  julia#43202               # retire from the backlog
python3 wl.py next     10                        # pull backlog to triage
python3 wl.py bucket   julia#62452 needs-agents  # force a lane
python3 wl.py clear    julia#62452
python3 wl.py show     julia#62452
```

Refs are `repo#number` (or a full URL). Re-run `refresh.py` after edits to
re-render.

## Tracking levels

`wl.py track <ref> close|normal|loose|background` sets how sensitive an item's
wake is, not just how it is displayed. `loose` ignores CI churn, bot comments and
relabels, waking only on a review decision or a human reply. `close` wakes on
anything and pins the item to the top of its lane. Suggest `loose` for things the
user is watching but not driving, `close` for whatever they are actively landing.

## Working the backlog (pull, never push)

Nothing from the backlog reaches the dashboard on its own. When the user wants to
grind it down:

```bash
python3 wl.py next 10
```

That prints untagged backlog items, quietest first. Walk them with the user and
tag each one — `dismiss` for anything no longer worth carrying, `track ... loose`
for keep-but-quiet, `note` for anything they want revived. Tagged items never
reappear in `next`, so the queue drains monotonically. Do not close PRs yourself;
propose and let the user decide.

## The stale pile

Anything of the user's, quiet for `stale_days` (60) and **unclaimed**, drops into
**Stale — decide**. Setting any of `note` / `deadline` / `agent_task` / `snooze`
claims it and pulls it back into an active lane. That is the intended workflow:
triage the pile once, claim what matters, close the rest. Do not close anything
yourself — surface candidates and let the user decide.

## Reporting back

Lead with what changed and what to do next, not a dump of the file. Something like:

> 3 changed since yesterday: `julia#62942` got your review request (new),
> `julia#62841` went red on llvm-23 (queued for agents), `libuv#5212` woke — the
> maintainer replied. Nothing due before 2026-09-30.

Then stop. The full listing is in `DASHBOARD.md` if they want it.

## Limits

Per `AGENTS.md`, agents may not open PRs or post comments autonomously. A
**Needs agents** item means *prepare the branch and stop*; the user pushes.
