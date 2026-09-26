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
  you the same way a comment on an open one does. A notification that is not
  an issue or pull request - a release, a discussion, a comment on a commit,
  a CI run, an alert, an invitation - is a **notice**: a row, unread until you
  dismiss it, and then gone until it notifies again.
- **Knows what moved.** An item is unread when somebody else did something to
  it since you read it: pushed, commented, reviewed, asked you, assigned you,
  closed or merged it, or your own CI went red. Nothing you did yourself counts.
- **Knows what to do next**, as tags derived from facts, none of them
  exclusive: `edits` (changes requested, unresolved threads, red CI, or the
  `status: waiting for PR author` label),
  `ready` (approved and green), `review` (asked, and not reviewed since their
  last push), `reply` (mentioned recently, last word theirs), `mentioned`
  (you were ever named on it, by a notification or an `@you` in a thread you
  opened - kept after GitHub's reason has moved on), `second` (the author
  acted and nobody has answered for two working days - "waiting on an answer"
  in the filter pane, and the `waiting on me` / `waiting on them` views).
- **Shows *what* changed**: the thread opens on the first comment you have not
  seen, and `p` is the diff or `range-diff` since the head you last read.
- **Writes back**: comment, review (a draft held on GitHub until you send it),
  label, merge.
- **Hosts a shell or an agent** in a tmux pane beside the thread, per worktree.
- **Nothing leaves.** Everything that was ever in front of you stays in the
  corpus; `done` and `filed` are marks, not deletions.

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
or `wl refresh`, is the only thing that fetches. Each refresh then starts
`wl prefetch` detached, which caches the thread of every unread item that has
none yet, so the browser has it the moment the cursor lands - and, for a pull
request in a pinned checkout, fetches what its diff needs into the checkout:
four at a time, a few minutes for a first run over ~500 unread, a second for
one that finds them all there. `data/cache/prefetch.log` says what it did.

## The browser

Three panes: the item list, its metadata, and the detail. The list opens on
**what moved and is unfiled**, open or closed, newest first - or, once it
has been closed once, wherever it was closed; unread rows are bold, and the
whole list is quieter while `tab` has put the keys on the reading pane. Reading
an item, or putting it away, takes it out of that list, and it comes back
when it moves. The terminal's title follows the cursor - `wl
JuliaLang/julia#62452` - so a tab or a tmux pane says which item it is on
(VS Code's tab shows it with `terminal.integrated.tabs.title` set to
`${sequence}`);
the title bar and the detail pane's header say what the number is of, between
it and the title - `issue`, `pull request`, `draft pull request`, `merged
pull request`, `closed issue`; the title bar's right-hand end says when the
corpus was last fetched, and `refreshing …` while `u` runs. Every date on
the metadata pane and on a comment, push or state header has how long ago
that was beside it, dim - `3d ago`,
`in 2w` for a snooze's wake - worked out against the moment the frame is
drawn. The `why` row under `local` says in a word each what has moved since
you read the item, newest first - `unread: pushed, comment`, `reviewed`,
`review requested`, `assigned`, `merged`, `CI failed`, `new`, `woke`, and
`agent` first of all for an agent that stopped on it while you were away. The
`branch` row is `head → base` in the form git takes, `owner/repo:head` for
a fork, and a base that is not the repository's default branch is coloured
and says so - `→ v1.x  not master`.

The order a list opens in holds while it is read: a row that changes under
the cursor - the re-read that brings its tags up to date, a note - stays
where it is, and the list is sorted afresh when another is asked for - a
view, a filter, `w`, a search, a refresh landing.

Lowercase keys look at things or change this machine; **uppercase keys reach
GitHub.**

| key | |
|---|---|
| `?` | this table, on screen |
| `j`/`k` `g`/`G` `space`/`b` | move, and the arrow, Home/End and page keys likewise; `tab` moves the keyboard between panes |
| `↵` | on an item: read it; in the detail: fold; on the row above the first item: import a url |
| `h` `d` `p` `c` | the thread - its history, with the pushes and the closes, merges and reopenings among the comments · the diff · what was pushed since you last looked · the checks |
| `[` `]` | widen a hunk's context; `l` fetches a failing Buildkite job's log |
| `n`/`N` | next/previous node, or search match |
| `/` | search; a bare number in the list jumps to that item past any filter, the same way `"` does. In the detail it is a regex (a half-typed one is taken literally), case-insensitive unless it starts `\C`, and `/` then `↵` or `↑` searches for the last one again |
| `e` | done ↔ not done: the same key, and the same word, as the GitHub inbox and Gmail. A done item that moves is not done again |
| `s` | snooze: `3d`, `2w`, `6mo`, a date. Wakes then, **or when it moves, whichever is first** |
| `x` | file it away (and back). A filed item that moves is unread again, in the `filed away` box |
| `v` | edit the note in `$VISUAL`/`$EDITOR`; `o` opens the checkout in VS Code (`code`) - under `d` or `p`, the diff of the file at the line the cursor is on; on a commit in a push or a range-diff, that commit |
| `;` | set a field - a picker: the tracking level (`normal` ↔ `loose`, this machine), then the milestone, an assignee, a reviewer, the state (draft ↔ ready; close and reopen, which ask first), the title - which reach GitHub; assignee and reviewer toggle, as `L` does |
| `z` `Z` | undo the last local action, and go back to the row it was on · redo what `z` took back, until another action is taken |
| `u` `R` | refresh everything without leaving (what it said is kept in `data/refresh.log`; the status row counts its warnings; a source the poll could not get an answer from - at launch or under `u` - stands in the footer until it answers) · reload this item |
| `f` | the filter pane; `c` there clears it |
| `'` | views; `1`–`9`, `0` are the first ten |
| `` ` `` `~` | back and forward through where you have been: each list, each jump, and each row the cursor stopped on long enough for the pane to show it - not the rows `j` passed. A row the filters now hide comes back as the `+` row |
| `w` | cycle the order: when it moved · that or when you acted · when you acted · url. Each view opens in the one made for it: the firehose by when it moved, my work by the later of the two clocks, the backlog by url |
| `I` | import an item by url; lands unread. Uppercase because it fetches, like `R` |
| `y` | copy the selection (rows from a drag, or `⇧j`/`⇧k`); `m` gives the mouse back to the terminal |
| `t` `T` `"` | a shell · an agent on the item's worktree, asking which checkout when nothing says - each row with the worktree list's `tT` marks and the item those sessions are on - and, when the copy is on some other branch, whether to `gh pr checkout` there first: the question shows the branch, whose it is, the head commit, how the branch stands to its upstream (and whether a force push from there would go), and `git status`; `y` checks out, `n` goes in as it is, `w` picks another place. Asked when the place is new to the item, not on the way back to its own session; a copy since checked out on another item's branch is not its place any more. A session already in that copy on *another* item is taken over - the question says whose is running there, the item pane's `running` block lists it beside the item's own as `wt#9's · T takes it over`, and the pane's title keeps `was wt#9's` for the length of the visit. A copy is on the pull request's branch by what the branch tracks as much as by its name: gh's `<owner>/master` and our `pr<N>/<branch>` are found, not asked about · the worktree list, each row filed under its branch's pull request or, failing that, the item its sessions were opened on; `h` on a row there goes to it - a row the filter hides is put in the list where it sorts, marked `+`, until another list is asked for - `a` on a worktree or a branch adopts its branch as an item of yours, or gives it back; one with a pull request already is refused - `tab` goes from every worktree to the `active` ones - a `t` or `T` running - to the branches, and `↵` on the `+ new worktree` row at the bottom asks for a repo, a branch and a place, making the branch from the default branch when it is not here |
| `C` `A` `L` `M` | comment · send the draft review · toggle a label · merge |
| `q` | quit; asks first, and about an unsent draft review if there is one |

**A notice** is a row for a notification that is not an issue or pull
request, listed as the repository and its type - `julia release`, `julia CI`,
`julia alert`, `julia invite`, `julia discussion`, `julia commit` - in the
firehose (it is `closed` on the state axis: news, and not work) and in no
other built-in view; `kind` has a fourth value for them alone (`kind = "notice"` in a view).
The pane is its own facts: what it is, why GitHub said so, the repository,
when, the link. `o` opens the link - through `code --openExternal` from a
Remote-SSH terminal, the desktop's opener where there is a display, and
otherwise it is copied - and `y` copies it. `e` and `x` both dismiss it:
there is no *not done* for it to go back to and no filed box to hold it,
so its block in `data/local.toml` goes, and `z` puts it back. `s` is
refused, as is everything that needs a thread or a checkout (`C` `A` `M`
`L` `;` `R` `t` `T` `v`); `d`, `p` and `c` say there is nothing to show.
A dismissed notice comes back when the thread notifies again, and not
before.

**Views** (`'`): 1 the firehose - unread, open or closed · 2 my work - open,
done ones too · 3 the backlog - the same for everyone's · 4 waiting on me · 5 waiting on them · 6 ready
to merge · 7 needs edits, mine · 8 unanswered · 9 snoozed · 0 everything. Add
your own in `data/config.toml`; the last entry under `'` copies the current filter
as the TOML that would name it.

**The filter pane** (`f`): `show` is three boxes that each *add* rows - `not
done` · `done` · `filed away` - and `state` is two more - `open` · `closed or
merged`; a row is under one box on each, and is in when both are checked, so
the number by a box is what checking it would bring in. Not done and both
states are on when nothing has been asked; in a view's TOML they are
`show = ["not-done", "done", "filed"]` and `state = ["open", "closed"]`. The
other axes narrow: tag, kind, lane, repo, label, author.
The repo, label and author axes list what is applied and put the rest
behind a picker row; `[filters] pinned_repos` in `data/config.toml` names repos
listed first regardless, a name or `owner/*`.

**Reviewing**: drag over a diff (or `⇧j`/`⇧k`), then `C` comments on that
range - under `d`, or under `p` on its right side, which is the head now;
`^r` in the composer drops in a suggestion block. Comments accumulate in
a draft review on GitHub, pinned to the commit the diff was read at; `A`
sends it, and leaving the item asks whether to. Once the branch has moved
under an open draft, the next `C` says to send the draft first.
Existing review threads hang off the hunk they point into, resolved ones
folded, and the line each is on carries `💬` in the margin, over the border.
A control character in a diff is drawn as `^[`, `^G`, `^M` rather than sent
to the terminal, and a row at the top says how many there were; a tab is
drawn to the next stop of eight, and stays a tab in what `y` copies and `^r`
suggests.

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

**An agent that stopped while you were elsewhere** makes its item unread -
`why  unread: agent`, on the list and in `wl unread` - and shows as a yellow
`T` in the worktree list and as `waiting on you` under `running` in the item
pane. `T` runs `claude` with `--settings` holding the contents of
`cli/claude-settings.json` - the JSON, not the path, since a sandboxed `claude`
sees the worktree and its config directory and not this checkout: a `Stop`
hook and a permission-prompt hook that ring the terminal bell, which tmux
keeps as the window's bell flag until somebody looks. It is only that one bit
- stopped or asking, not which - and it lives in the tmux server with the
session, so nothing has to be running to catch it. Looking (`T`) clears it,
and so does every mark - `e`, `s`, `x`, `wl done` - the way a mark ends a
woken snooze; `z` rings it back. The browser lists the sessions every two
seconds for it while it is up.

**VS Code** (`o`) opens the item's checkout - the worktree on its branch
when there is one - and under `d` or `p` the file at the line the cursor is
on. The *diff* at that line is more than `code`'s command line can say, so
it goes through a small extension of our own, `vscode/`: build it with
`vscode/package.sh`, install it once with `code --install-extension` (from
the terminal that reaches the VS Code you use - under Remote-SSH that is the
remote one), and `o` on a diff line then opens the diff editor at that line,
against the merge base under `d` and against the head you last read under
`p`. Without the extension `o` opens the file at the line and says so. On a
commit in a list of them - a row of `↑ pushed N commits` in the thread, or a
pair of a range-diff under `p` - `o` opens that commit, every file it changed
against its first parent in one editor; that too is the extension's, and
without it `o` opens the checkout and says so.

**References are links**, as GitHub draws them: in the thread and under `p`,
`#123`, `owner/repo#123`, a sha and `owner/repo@sha` are hyperlinks to the
issue or the commit. A sha is seven to forty hex digits with a digit and a
letter both - GitHub asks whether the commit exists, and this cannot.

**The mouse** selects rows (drag), moves the cursor (click), folds (click a
marker), scrolls the pane under it; in the pickers - `'`, the checkout
chooser, `"` - a click moves the cursor to the row and a double click is `↵`. A click on a url copies it; a double click
copies the word under the pointer, or the item's url in the list; the `⧉` at
the right of every header copies that block. Beside a composer or a hosted
pane the thread takes the same clicks, and the keys stay where they were -
`tab` is what moves them.

## Commands

```
wl                                      the browser
wl --refresh                            refresh first, then the browser
wl refresh [--backlog] [--caught-up]    re-fetch; --backlog imports the polled repos'
                                        open lists, read; --caught-up stops waiting
                                        on a late notification
wl import  <url>...                     follow items no lane returns, unread
wl show    julia#62891                  state and the thread - comments, pushes, closes and
                                        merges in order - non-interactive
wl thread  julia#62891 [n]              JSON of the same: `comments`, and `activity` with the
                                        pushes and state changes among them
wl unread  [julia#62891]                JSON of the unread list / mark one unread
wl log                                  what the last refresh run from the browser said
wl prefetch                             cache the thread of every unread item that has none
                                        (any age counts), and fetch its diff into a pinned
                                        checkout; runs by itself after a refresh
wl done    julia#62891                  mark done (or: done all)
wl done    notice:1234567               dismiss a notice (`done all` dismisses them too)
wl done    --consolidate [--dry-run]    fold the done stamps into the sources' floors
wl track   julia#62452 loose            normal | loose - what counts as it moving
wl snooze  julia#62452 3d               or 2w, 6mo, a date; "off" clears it
wl dismiss julia#62452                  loose, and read
wl archive julia#62452                  file it away; again to take it back out
wl note    julia#62452 "..."
wl adopt   [branch | repo#branch]       a local branch as an item, the one checked out
                                        here when none is named; again to give it back
wl clear   julia#62452
wl watching                             repos you watch, and which are polled
wl repos [--prune]                      pinned checkouts
```

Wherever a ref is taken, `-` reads them from stdin, one per line:
`printf '%s\n' julia#1 julia#2 | wl snooze - 3d`.

`wl unread` lists what the browser shows unread - every row of the corpus and
every light row the clocks know that has moved since you read it, or that no
stamp and no floor answers for, less the ones filed away - newest movement
first, each with `why`: the same words the pane's row says for what moved;
`wl done all` marks that same list, so a second pass finds nothing. A
row with no stamp is done up to the day its source was named (`since` in the
`source:` blocks of `local.toml`); `wl done --consolidate` raises every
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
  Where the terminal says whether it is dark or light - VS Code's does, and
  tmux 3.6 passes it on - a name with `light` or `dark` in it is swapped for
  its pair, and swapped back when the terminal's theme changes.
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
- `[agent] command` - what `T` runs, when it is not your shell's `claude`
  (add `--settings "$(cat …/cli/claude-settings.json)"` yourself to keep the bell).

**Themes** name colours by role - `blocked`, `settled`, `diff_add`,
`cursor_bg` - in words: `"bold white"`, `"black on yellow"`, `"on 236"`.
`default-ansi.toml` uses the terminal's own sixteen colours;
`github-light-256.toml` and `github-dark-256.toml` are GitHub's palette pinned
to the 256-colour cube.

## Files

| | owner | |
|---|---|---|
| `config.toml`, `config.user.toml`, `themes/` | you | hand-edited; the shared half, the template for yours, the colours |
| `cli/claude-settings.json` | you | what `T` hands `claude` as `--settings`: the hooks that ring the pane when a turn ends. Only ever read |
| `data/config.toml` | you | your half: login, theme, the repos you poll and pin. Seeded from the template on the first launch and never written again. Tracked |
| `data/local.toml` | you and the program | one block per item: your note, snooze, tracking level, and what you have done to it; and one per unread notice, `["notice:<id>"]`, written by the poll and removed when it is dismissed. Edited key by key; **never rewritten**. Tracked |
| `data/fetched.json` | `wl refresh` | everything GitHub can answer again. Safe to delete; ~6MB; ignored |
| `data/cache/`, `data/errors.log`, `data/refresh.log` | the browser, `wl prefetch` | ignored. Deleting `errors.log` dismisses the footer warning; `refresh.log` is the whole of what the last `u` said, and `wl log` prints it |
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
is one, reads `data/fetched.json` for one sweep. What needs a terminal, a tmux of
your own or GitHub is in `cli/test/MANUAL.md`, with when it last passed. See
DESIGN.md for how the suite is built, and TODO.md for what is open.
