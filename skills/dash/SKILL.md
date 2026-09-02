---
name: dash
description: Refresh and triage the work dashboard across all repos - open PRs, review requests, assigned issues, adopted branches, and the JuliaLang/julia firehose. Sorts work into needs-reply / needs-edits / needs-review / needs-nudge, honours snoozes, deadlines and archives. Use when asked what to work on, what changed, what needs review, or to snooze/note/archive an item.
---

# Work dashboard

The checkout is wherever it is mounted — take the path from
`git rev-parse --show-toplevel`, not from a remembered one. Read `README.md`
there once if you have not.

**The interactive browser is the primary surface.** `cli/bin/wl` with no
arguments opens it, and everything below is the non-interactive half, which is
what you can drive. Do not describe the browser's keys to the user as though you
had pressed them.

## The one rule

The refresh owns the facts. You own the judgement. **Never rewrite `state.toml`
wholesale** — it holds the user's snoozes, notes, deadlines, adoptions and
archives. Change it only through `cli/bin/wl`, which edits single keys in place.

## Refresh

```bash
cd "$(git rev-parse --show-toplevel)" && cli/bin/refresh
```

~30s and ~20 of 5000 hourly rate-limit points, so cadence is never the
constraint. The background pile is cached for 6h; `--firehose` forces a refetch
(several minutes). Then read `DASHBOARD.md`.

## Triage the change set only

Do **not** re-examine every item; that is what makes this expensive and what the
bucketing rules already handle. Look only at **"Changed since last refresh"** and
anything marked `NEW`. For each, decide the two things rules cannot:

1. **What is the actual next action?** One line, concrete, imperative:
   `wl note <ref> "rebase after #62396 lands"`. Not a restatement of the title.
2. **Should it be quiet?** If it is genuinely waiting on another person, snooze
   it until it moves rather than letting it sit in view:
   `wl snooze <ref> on-change`.

Prefer `on-change` over a date. It wakes the moment the item actually moves,
which is almost always what "remind me later" really means. Use a date only for a
real calendar constraint.

## Recently landed

`is:closed` lanes mean a pull request that merged between two refreshes is still
seen; they arrive in the **done** bucket. A merge the user did not do is *news*,
so leave it: `x` in the browser is how they file one away, after they have read
it. Do not archive on their behalf.

## Reading threads

`wl show <ref>` prints an item's state and its recent comments, fetched live.
`wl read <ref>` marks it seen; `wl read all` zeroes the inbox. Unread is an
incremental sync of every tracked repo, held in `inbox.json`; the only thing
stored per item is one timestamp in `read.json`.

## Commands

```bash
cli/bin/wl note     julia#62452 "rebase onto master first"
cli/bin/wl snooze   libuv#5212  on-change      # a span (3d/2w/6mo), a date, or off
cli/bin/wl deadline julia#62452 2026-09-30
cli/bin/wl blocked  julia#62452 JuliaLang/julia#62396
cli/bin/wl track    julia#62452 loose          # close|normal|loose|background
cli/bin/wl archive  julia#62452 2026-09-02     # done; leaves active without deleting
cli/bin/wl dismiss  julia#43202                # retire from the backlog
cli/bin/wl next     10                         # pull backlog to triage
cli/bin/wl bucket   julia#62452 needs-review   # force a lane
cli/bin/wl clear    julia#62452
cli/bin/wl show     julia#62452
```

Refs are `repo#number` or a full URL. Re-run `cli/bin/refresh` after edits to
re-render.

## Needs a reply

The narrowest and most valuable lane: someone mentioned the user recently and the
last comment is not theirs. Treat these as the top of the dashboard — they are
questions owed answers, and they are few. Everything else from the
mention/comment history sits in the background pile.

## Tracking levels

`wl track <ref> close|normal|loose|background` sets how sensitive an item's wake
is, not just how it is displayed. `loose` ignores CI churn, bot comments and
relabels, waking only on a review decision or a human reply. `close` wakes on
anything and pins the item to the top of its lane. Suggest `loose` for things the
user is watching but not driving, `close` for whatever they are actively landing.

## Working the backlog (pull, never push)

Nothing from the backlog reaches the dashboard on its own. When the user wants to
grind it down:

```bash
cli/bin/wl next 10
```

That prints untagged backlog items — their areas first, then quietest first. Walk
them with the user and tag each: `dismiss` for anything no longer worth carrying,
`track ... loose` for keep-but-quiet, `note` for anything to revive. Tagged items
never reappear in `next`, so the queue drains monotonically.

## The stale pile

Anything of the user's, quiet for `stale_days` and **unclaimed**, drops into
**Stale — decide**. Setting any of `note` / `deadline` / `snooze` claims it and
pulls it back into an active lane. Triage the pile once, claim what matters,
propose the rest for closing. **Do not close anything yourself** — surface
candidates and let the user decide.

## Reporting back

Lead with what changed and what to do next, not a dump of the file:

> 3 changed since yesterday: `julia#62942` got your review request (new),
> `julia#62841` went red on llvm-23, `libuv#5212` woke — the maintainer replied.
> Nothing due before 2026-09-30.

Then stop. The full listing is in `DASHBOARD.md` if they want it.

## Limits

Per `AGENTS.md`, agents may not open PRs or post comments autonomously. Prepare
the branch and stop; the user pushes.
