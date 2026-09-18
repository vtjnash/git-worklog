# worklog

A terminal dashboard for the GitHub work you are carrying, across every
repository. It keeps its own record of what you have read, put off and filed,
so the per-event email notifications can stay off.

Nothing off-the-shelf did this. [gh-dash] is stateless - every section is a
live query, so there is no snooze, no note, no memory of what changed.
[Octobox] has real snooze but triages notifications alone, one row per thread
with the latest reason and no facts about the item. GitHub Projects can hold
the state but cannot populate or classify a few thousand items. What all of
them lack is a record of what *you* decided, and the facts a decision needs -
"changes requested and CI red" is a fact about content that no query expresses.

[gh-dash]: https://github.com/dlvhdr/gh-dash
[Octobox]: https://github.com/octobox/octobox

## What it does

- **Fetches the open work whole** - pull requests you authored, pull requests
  awaiting your review, issues assigned to you - and everything else **only
  when a clock says it moved**: the repositories you poll, and your GitHub
  notifications. A question put to you on an issue closed years ago reaches
  you the same way a comment on an open one does.
- **Knows what moved.** An item is unread when somebody else did something to
  it since you read it: pushed, commented, reviewed, asked you, assigned you,
  closed or merged it, or your own CI went red. Nothing you did yourself counts.
- **Knows what to do next**, as tags derived from facts, none of them
  exclusive: `edits` (changes requested, unresolved threads, red CI, or the
  `status: waiting for PR author` label),
  `ready` (approved and green), `review` (asked, and not reviewed since their
  last push), `reply` (mentioned recently, last word theirs), `second` (the
  author acted and nobody has answered for two working days - "waiting on an
  answer" in the filter pane, and the `waiting on me` / `waiting on them`
  views).
- **Shows *what* changed**: the thread opens on the first comment you have not
  seen, and `p` is the diff or `range-diff` since the head you last read.
- **Writes back**: comment, review (a draft held on GitHub until you send it),
  label, merge.
- **Hosts a shell or an agent** in a tmux pane beside the thread, per worktree.
- **Nothing leaves.** Everything that was ever in front of you stays in the
  corpus; `read` and `filed` are marks, not deletions.

## Running it

Needs `gh` logged in and `git`. `wl` runs the julia its manifest was
resolved with - under juliaup, `cli/bin/wl` passes the channel itself
(`1.14-nightly` for a `1.14.0-DEV` manifest, `1.12.6` for `1.12.6`), so it
must be installed: `juliaup add 1.14-nightly`. `JULIAUP_CHANNEL` overrides
it; without juliaup, whatever `julia` is on `PATH` runs (1.11 or newer).
tmux comes bundled (`tmux_jll`, 3.5.1) and is what `t` and `T` run;
`WORKLOG_TMUX` names another binary. The sessions are on the ordinary socket,
so your own `tmux ls` sees them. No tmux on Windows.

```bash
git clone --recurse-submodules https://github.com/vtjnash/git-worklog
cd git-worklog
cli/bin/wl refresh            # writes data/config.toml the first time; ~25s, 16 points
cli/bin/wl refresh --backlog  # once: the open lists of the polled repos, read
cli/bin/wl                    # the browser
```

`cli/bin/refresh` is `cli/bin/wl refresh`. The first `wl` after any change
under `cli/src` rebuilds a precompile image (~22s); after that a launch is
about a second. Nothing runs on a cadence of its own: `u` inside the browser,
or `wl refresh`, is the only thing that fetches.

## The browser

Three panes: the item list, its metadata, and the detail. The list opens on
**what moved and is unfiled**, open or closed, newest first - or, once it
has been closed once, wherever it was closed; unread rows are bold. Reading
an item, or putting it away, takes it out of that list, and it comes back
when it moves. The terminal's title follows the cursor - `wl
JuliaLang/julia#62452` - so a tab or a tmux pane says which item it is on.
Every date on the metadata pane and on a comment or
push header has how long ago that was beside it, dim - `3d ago`, `in 2w` for
a snooze's wake - worked out against the moment the frame is drawn. The
`branch` row is `head → base` in the form git takes, `owner/repo:head` for a
fork, and a base that is not the repository's default branch is coloured and
says so - `→ v1.x  not master`.

Lowercase keys look at things or change this machine; **uppercase keys reach
GitHub.**

| key | |
|---|---|
| `?` | this table, on screen |
| `j`/`k` `g`/`G` `space`/`b` | move; `tab` moves the keyboard between panes |
| `↵` | on an item: read it; in the detail: fold; on the row above the first item: import a url |
| `o` `d` `p` `c` | the thread · the diff · what was pushed since you last looked · the checks |
| `[` `]` | widen a hunk's context; `l` fetches a failing Buildkite job's log |
| `n`/`N` | next/previous node, or search match |
| `/` | search; a bare number in the list jumps to that item past any filter |
| `r` | read ↔ unread |
| `s` | snooze: `3d`, `2w`, `6mo`, a date. Wakes then, **or when it moves, whichever is first** |
| `x` | file it away (and back). A filed item that moves is unread again, in the `filed away` box |
| `v` | edit the note in `$VISUAL`/`$EDITOR`; `e` opens the checkout in VS Code (`code`) - under `d` or `p`, the diff of the file at the line the cursor is on |
| `z` | undo the last local action |
| `u` `R` | refresh everything without leaving (what it said is kept in `data/refresh.log`; the status row counts its warnings; a source the poll could not get an answer from - at launch or under `u` - stands in the footer until it answers) · reload this item |
| `f` | the filter pane; `c` there clears it |
| `'` | views; `1`–`9`, `0` are the first ten, `` ` `` goes back to the previous filter |
| `w` | cycle the order: when it moved · that or when you acted · when you acted · url. Each view opens in the one made for it: the firehose by when it moved, my work by the later of the two clocks, the backlog by url |
| `i` | import an item by url; lands unread |
| `y` | copy the selection (rows from a drag, or `⇧j`/`⇧k`); `m` gives the mouse back to the terminal |
| `t` `T` `"` | a shell · an agent on the item's worktree · the worktree list |
| `C` `A` `L` `M` | comment · send the draft review · toggle a label · merge |
| `q` | quit; asks first, and about an unsent draft review if there is one |

**Views** (`'`): 1 the firehose - unread, open or closed · 2 my work - open,
read ones too · 3 the backlog - the same for everyone's · 4 waiting on me · 5 waiting on them · 6 ready
to merge · 7 needs edits, mine · 8 unanswered · 9 snoozed · 0 everything. Add
your own in `data/config.toml`; the last entry under `'` copies the current filter
as the TOML that would name it.

**The filter pane** (`f`): `show` is four boxes that each *add* rows - `unread,
open` · `read` · `filed away` · `closed or merged` - so the number by each is
what checking it would bring in. The first and last are on when nothing has
been asked. The other axes narrow: tag, kind, lane, repo, label, author.
The repo, label and author axes list what is applied and put the rest
behind a picker row; `[filters] pinned_repos` in `data/config.toml` names repos
listed first regardless, a name or `owner/*`.

**Reviewing**: drag over a diff (or `⇧j`/`⇧k`), then `C` comments on that
range - under `d`, or under `p` on its right side, which is the head now;
`^r` in the composer drops in a suggestion block. Comments accumulate in
a draft review on GitHub; `A` sends it, and leaving the item asks whether to.
Existing review threads hang off the hunk they point into, resolved ones
folded, and the line each is on carries `💬` in the margin, over the border.
A control character in a diff is drawn as `^[`, `^G`, `^M` rather than sent
to the terminal, and a row at the top says how many there were.

**Composers** open beside the diff or thread when the screen is 150 columns or
wider, with `tab` between them. `^s` sends; `M`'s composer cycles the merge
operation with `^x` and asks once before it sends; `⌥e` or `^o` opens
`$EDITOR`.

**A hosted pane** (`t`, `T`) takes every key except the prefix `^]`: `^]tab`
or `^][` moves to the thread beside it and back, `^]q` leaves it running, `^]K`
ends it, `^]a` goes full screen, `^]r` re-reads, `^]]` sends a literal `^]`.
Its shell sees the ssh agent and the `code` of whichever login most recently
launched `wl`, however old the pane: `SSH_AUTH_SOCK`, `VSCODE_IPC_HOOK_CLI`
and `code` on `PATH` are links under `$XDG_RUNTIME_DIR/wl/`, re-pointed at
launch from `wl`'s own environment when what it names still answers - never
found by searching, since the newest socket on the machine is not
necessarily yours. When nothing answers, the status line says `no live ssh
agent` as the pane opens.

**VS Code** (`e`) opens the item's checkout - the worktree on its branch
when there is one - and under `d` or `p` the file at the line the cursor is
on. The *diff* at that line is more than `code`'s command line can say, so
it goes through a small extension of our own, `vscode/`: build it with
`vscode/package.sh`, install it once with `code --install-extension` (from
the terminal that reaches the VS Code you use - under Remote-SSH that is the
remote one), and `e` on a diff line then opens the diff editor at that line,
against the merge base under `d` and against the head you last read under
`p`. Without the extension `e` opens the file at the line and says so.

**The mouse** selects rows (drag), moves the cursor (click), folds (click a
marker), scrolls the pane under it. A click on a url copies it; a double click
copies the word under the pointer, or the item's url in the list; the `⧉` at
the right of every header copies that block.

## Commands

```
wl                                      the browser
wl --refresh                            refresh first, then the browser
wl refresh [--backlog] [--caught-up]    re-fetch; --backlog imports the polled repos'
                                        open lists, read; --caught-up stops waiting
                                        on a late notification
wl import  <url>...                     follow items no lane returns, unread
wl show    julia#62891                  state and the thread, non-interactive
wl thread  julia#62891 [n]              JSON of a thread's recent comments
wl unread  [julia#62891]                JSON of the unread list / mark one unread
wl log                                  what the last refresh run from the browser said
wl read    julia#62891                  mark read (or: read all)
wl read    --consolidate [--dry-run]    fold the read stamps into the sources' floors
wl track   julia#62452 loose            normal | loose - what counts as it moving
wl snooze  julia#62452 3d               or 2w, 6mo, a date; "off" clears it
wl dismiss julia#62452                  loose, and read
wl archive julia#62452                  file it away; again to take it back out
wl note    julia#62452 "..."
wl deadline julia#62452 2026-09-30
wl blocked julia#62452 JuliaLang/julia#62396
wl clear   julia#62452
wl watching                             repos you watch, and which are polled
wl repos [--prune]                      pinned checkouts
```

Wherever a ref is taken, `-` reads them from stdin, one per line:
`printf '%s\n' julia#1 julia#2 | wl snooze - 3d`.

`wl unread` lists what the browser shows unread - every row of the corpus and
every light row the clocks know that has moved since you read it, or that no
stamp and no floor answers for, less the ones filed away - newest movement
first; `wl read all` marks that same list, so a second pass finds nothing. A
row with no stamp is read up to the day its source was named (`since` in the
`source:` blocks of `local.toml`); `wl read --consolidate` raises every
source's `since` as far as the stamps allow and drops the stamps the floor
then answers for, without changing what any row answers. `--dry-run` says
what it would do.

`cli/bin/gmail-unread <label>` lists the threads with unread GitHub
notification mail under a Gmail label as urls, one per line, so
`gmail-unread GitHub | wl import -` imports what the mailbox says is still to
be looked at; `--seen` then marks those mails read. It needs an app password,
in `$GMAIL_APP_PASSWORD` or `~/.netrc`; `--help` has the details.

## Tracking

`track` decides what counts as an item *moving*, which is what makes it unread
and what wakes a snooze. Two levels:

| level | default for | ignores |
|---|---|---|
| `normal` | your own unfinished work | nothing |
| `loose` | everything else, and anything finished | a bot's comment; a stranger's CI |

Both see a push, a human's comment, a review, a request, an assignment, a
close or a merge - by somebody other than you. Not movement at any level: your
own actions, a label, a milestone, a title edit, a thread being resolved, a
review request being withdrawn.

## Configuration

Two files, read as one. `config.toml` beside the code is the shared half,
versioned with the program: every key, its default and the comment that is
its manual, naming nobody. `data/config.toml` is yours - written once from
`config.user.toml` the first time `wl` runs, with `login` filled from `gh`,
and never written by the program again. A key set there replaces the shared
one: a table key by key, anything under a table key whole - so `[events]
repos` in your file is the list, and a `[views."name"]` of the same name is
the view. Hand-edited, both, and only ever read.

- `login` (yours; nothing runs without it), and `theme` - a file under
  `themes/`. Empty draws everything plain, with no escape sequences at all.
- `[lanes]` - the three searches for the open work, as `@me`, which GitHub
  reads as whoever holds the token. `sort:created-asc` on each is load-bearing
  (see DESIGN.md). A lane of the same key in your file replaces it; a new key
  is a fourth lane, walked after them.
- `[events] repos` (yours) - repositories polled for every change, as
  `owner/name` or `owner/*`. Their open lists become the backlog. `wl watching`
  prints the ones you watch on GitHub but have not listed.
- `[filters] pinned_repos` (yours) - repos at the top of the filter pane.
- `[thresholds]` - `reply_days` (required) and `second_look_days` (working
  days, default 2).
- `[views]` - named filters for `'`.
- `[cache]` - how long the browser trusts a cached thread, diff or merge state.
- `[agent] command` - what `T` runs, when it is not your shell's `claude`.

**Themes** name colours by role - `blocked`, `settled`, `diff_add`,
`cursor_bg` - in words: `"bold white"`, `"black on yellow"`, `"on 236"`.
`default-ansi.toml` uses the terminal's own sixteen colours;
`github-light-256.toml` and `github-dark-256.toml` are GitHub's palette pinned
to the 256-colour cube.

## Files

| | owner | |
|---|---|---|
| `config.toml`, `config.user.toml`, `themes/` | you | hand-edited; the shared half, the template for yours, the colours |
| `data/config.toml` | you | your half: login, theme, the repos you poll and pin. Seeded from the template on the first launch and never written again. Tracked |
| `data/local.toml` | you and the program | one block per item: your note, snooze, deadline, tracking level, and what you have done to it. Edited key by key; **never rewritten**. Tracked |
| `data/fetched.json` | `wl refresh` | everything GitHub can answer again. Safe to delete; ~6MB; ignored |
| `data/cache/`, `data/errors.log`, `data/refresh.log` | the browser | ignored. Deleting `errors.log` dismisses the footer warning; `refresh.log` is the whole of what the last `u` said, and `wl log` prints it |
| `data/view.toml` | the browser | where it was when it last closed - the filter, the item, which view of it - read back at the next launch; `` ` `` is the way back to the firehose from there. Written whole on the way out; ignored. Delete it to open on the firehose |
| `data/notifications.token` | you | optional: a token that can read `/notifications`, for a machine whose own cannot |
| `$XDG_RUNTIME_DIR/wl/` | the browser | links to the ssh agent, VS Code socket and `code` of the last login to launch it, which every pane is handed. Yours alone (`0700`, set at every launch); gone with the last login, like what they point at |

`data/` is a git repository of its own, so your record has a history without
cluttering the code's. Nothing commits automatically. `WORKLOG_DATA` points it
elsewhere.

## Authentication

The searches shell out to `gh` and use whatever it is logged in as. The REST
side looks for a token in `/run/claudebox-github/token`, then `$GH_TOKEN` /
`$GITHUB_TOKEN`, then `gh auth token`, and fails once, naming every place it
looked.

`/notifications` needs a *person's* token (`gho_`, `ghp_`) - a GitHub App's
(`ghu_`, `ghs_`) cannot read it. Off a sandbox, `gh auth token` is a `gho_`
with `repo` scope, which is enough; on a machine whose token is an App's, put
one in `data/notifications.token` or the source is skipped and says so.
Writing - comments, reviews, labels, merges - needs `issues: write` and
`pull_requests: write` on the repositories in question.

## Tests

```bash
julia --project=cli cli/test/runtests.jl          # everything testable without a TTY
julia --project=cli cli/test/latency.jl           # startup, measured; not part of the suite
julia --project=TermInput.jl  TermInput.jl/test/runtests.jl
julia --project=TermIFrame.jl TermIFrame.jl/test/runtests.jl
```

The suite runs on a committed fixture and on a fresh clone. It never writes
your `local.toml` or cache; it does delete `data/errors.log` and, when there
is one, reads `data/fetched.json` for one sweep. See DESIGN.md for how it is built, and TODO.md for what is
open.
