# worklog

A terminal dashboard for the GitHub work you are carrying, across every
repository. It keeps a record of its own - what you have read, what you have
put off, what you have filed away - and keeps it on this machine, in plain
text, so that the email GitHub sends for every event can be turned off and
nothing is lost by the silence.

Nothing off-the-shelf did this. [gh-dash] is stateless: every section is a
live query, and a query has no memory - no snooze, no note, no record of what
has changed since you looked. [Octobox] remembers, and has a real snooze, and
yet it triages notifications alone: one row per thread, carrying the latest
reason and no fact about the item itself. GitHub Projects can hold the state,
and cannot fill it, nor sort a few thousand items by what each one needs
next. What all three lack is a record of what *you* decided, and the facts a
decision rests on; "changes requested and CI red" is a fact about content,
and no query expresses it.

[gh-dash]: https://github.com/dlvhdr/gh-dash
[Octobox]: https://github.com/octobox/octobox

## Quick start

```bash
git clone --recurse-submodules https://github.com/vtjnash/git-worklog
cd git-worklog
juliaup add 1.14-nightly
julia +1.14-nightly --project=cli/precompile -e 'using Pkg; Pkg.instantiate()'
cli/bin/wl
```

Needs `gh`, logged in. The first launch writes `data/config.toml`, once and
never again; `[events] repos` there names the repositories you poll (see
*Configuration*).

**Three panes**: the list on the left, the item's facts, and its thread or
diff. The workflow, in keys:

- `'` picks a view: `1` what moved, `2` my work, `3` the backlog.
- `j`/`k` walk the list; `↵` reads the item, `h` `d` `p` `c` show its
  history, diff, what was pushed since you looked, and its checks.
- `e` marks it done, `s` snoozes it, `x` files it away. It comes back when
  somebody else acts on it, and not before.
- `C` comments, `A` sends a review, `M` merges.
- `t` opens a shell and `T` an agent in the item's worktree, in a pane
  beside the thread; `"` lists the worktrees.
- `u` refreshes; `?` is the key table; `q` quits.

## What it does

- **Fetches the open work whole** - the pull requests you authored, the pull
  requests awaiting your review, the issues assigned to you - at every
  refresh, and everything else **only when a clock says it moved**: the
  repositories you poll, and your GitHub notifications. So a question put to
  you on an issue closed years ago reaches you by the same road as a comment
  on an open one. A notification that is not an issue or a pull request - a
  release, a discussion, a comment on a commit, a CI run, an alert, an
  invitation - is a **notice**: a row, unread until you dismiss it, and then
  gone until it notifies again.
- **Knows what moved.** An item is unread when somebody else did something to
  it since you read it: pushed, commented, reviewed, asked you, assigned you,
  closed or merged it, or your own CI went red. Nothing you did yourself
  counts, and no clock of this program's is consulted: every stamp is
  GitHub's own time for an event by another hand.
- **Knows what to do next**, as tags derived from facts - none of them
  exclusive, and none of them stored, since each is worked out again from the
  facts at every refresh:
  - `edits` - changes requested, unresolved threads, red CI, or the
    `status: waiting for PR author` label
  - `ready` - approved and green; `approved` - approved, CI not green yet.
    Where the repository requires no approval, as julia's does, it is read
    off the reviews
  - `review` - asked, and not reviewed since their last push
  - `reply` - mentioned recently, and the last word is theirs
  - `mentioned` - ever named on it, by a notification or an `@you` in a
    thread you opened; kept after GitHub's reason has moved on
  - `second` - the author acted and nobody has answered for two working
    days; "second look" in the filter pane and the views
- **Shows *what* changed**: the thread opens on the first comment you have not
  seen, and `p` is the diff, or the `range-diff`, since the head you last
  read.
- **Writes back**: comment, review (a draft held on GitHub until you send it),
  label, merge.
- **Hosts a shell or an agent** in a tmux pane beside the thread, one per
  worktree.
- **Nothing leaves.** Everything that was ever in front of you stays in the
  corpus; `done` and `filed` are marks, not deletions, and every mark can be
  taken back.

## The browser

Three panes: the list, the item's facts, and its thread or diff. Unread rows
are bold. Reading an item, or putting it away, takes it out of the list; it
comes back when it moves, and not before. Three keys say what the list is:

- `'` - views: `1` the firehose, what moved and is unfiled · `2` my work ·
  `3` the backlog · more below, and your own in `data/config.toml`.
- `f` - the filter pane: the axes a view is made of, one per question.
- `"` - the worktrees: every checkout, with the shell (`t`) or agent (`T`)
  running in it, filed under its pull request.

Nothing is unread from before the first launch. Each source - your lanes,
your notifications, every repository you poll - is dated the day it is first
seen, and only what moves after that day is news; everything older is read
by construction, and stays so. The shells and agents are tmux sessions on the
item's worktree, and they outlive the browser: `^]q` leaves one running, and
the next `t` or `T` on the item goes back in. Everything the program knows is
plain text under `data/`, a git repository of its own: `local.toml` is your
record, one block per item, and `fetched.json` is what GitHub said (see
*Files*).

Lowercase keys look, or change this machine, and reach no further.
**Uppercase keys reach GitHub**, most of them, and what they do there is done
in your name.

| key | | |
|---|---|---|
| `?` | help | this table, on screen |
| `j`/`k` `g`/`G` `space`/`b` | move | a row, the ends, a page - the arrows, Home/End and the page keys likewise. `^j`/`^k` are the next and previous item from any pane |
| `tab` | panes | moves the keyboard between the panes: the list, the item's facts, the thread or diff, a composer or hosted pane beside it. In `"` it cycles what is listed; after `T` it picks the agent |
| `↵` | open | read the item under the cursor; in the detail, fold the node; on the row above the first item, import a url |
| `h` `d` `p` `c` | history · diff · pushed · checks | the thread, with the pushes, closes and merges among the comments · the diff · what was pushed since you last looked · the checks. `d` again picks which commits to show - one, or a run with shift-↑/↓; `p` again picks where to compare from - where you last looked, where the snooze put it away, after any commit, or a commit or branch typed in. A pick is kept for the item until the next, and both need a checkout. A diff of one commit has its message on top. An adopted branch has `d` and `p` from its checkout alone. The pane's top border says the size of the change, `+120 -7`. Under `p` a rebase is one row per commit, the changed ones open |
| `[` `]` | context | widen a hunk's context |
| `n`/`N` | next · previous | node, or search match |
| `/` | search | in the list, a bare number jumps to that item past any filter. In the detail, a regex, case-insensitive unless it starts `\C`; `/` then `↵` repeats the last. The query edits like any field: the arrows, `^a`/`^e`, `^w`, `^k`, `^y` |
| `e` | done | done ↔ not done, as in the GitHub inbox and Gmail. A done item that moves is unread again |
| `s` | snooze | `3d`, `2w`, `6mo`, a date. Wakes then, **or when it moves, whichever is first**; the thread then has a rule where you last looked and one over what moved while it slept |
| `x` | file away | file it away, and back. A filed item that moves is unread again, in the `filed away` box |
| `v` | visual · open | `v` edits the note in `$VISUAL`/`$EDITOR`. `o` opens the checkout in VS Code; under `d` or `p`, the file's diff at the cursor's line; on a commit, that commit |
| `;` | set | a picker over the item's fields: the tracking level (`normal` ↔ `loose`, this machine only), then on GitHub the milestone, an assignee, a reviewer, the state (draft ↔ ready, close, reopen - these two ask first) and the title. Assignee and reviewer toggle, as `L` does |
| `z` `Z` | undo · redo | undo the last local action and go back to its row · redo it, until another action is taken |
| `u` `R` | update · reload | refresh everything without leaving · reload this item. What the refresh said is in `data/refresh.log`; the status row counts its warnings, and a source that did not answer stands in the footer until it does |
| `f` | filter | the filter pane; `c` there clears it |
| `'` | views | the view picker; `1`–`9`, `0` are the first ten |
| `` ` `` `~` | back · forward | through where you have been: each list, each jump, each row the cursor rested on. A row the filters now hide comes back as the `+` row |
| `w` | order | cycle it: when it moved · that or when you acted · when you acted · url. Each view opens in its own - the firehose by when it moved, my work by the later of the two, the backlog by url |
| `I` | import | an item by url; it lands unread |
| `y` | yank | copy the selection - a drag, or `⇧j`/`⇧k`; `m` gives the mouse back to the terminal |
| `t` `T` | terminal · agent | a shell · an agent, each a tmux session in the item's worktree. When nothing says which checkout, they ask; a checkout on another branch also asks whether to `gh pr checkout` there first - `y` checks out, `n` goes in as it is, `w` picks another place. A session already there on another item is taken over, and the pane's title says whose it was. `T` with no agent running asks for a prompt, and `tab` there picks the agent (`[[agent.list]]`) |
| `"` | worktrees | the worktree list. **`tab` cycles what it shows**: every worktree · the active ones, with a `t` or `T` running · the branches. Each is filed under its pull request or, failing that, the item its sessions were opened on; `h` goes to that item, `a` adopts the branch as an item of yours or gives it back, and `↵` on `+ new worktree` makes one |
| `C` `A` `L` `M` | comment · review · label · merge | comment · send the draft review · toggle a label · merge |
| `q` | quit | asks first, and about an unsent draft review if there is one |

**Views** (`'`):

1. the firehose - what moved and is unfiled, open or closed
2. my work - your open pull requests and adopted branches, done ones too
3. the backlog - everyone's open items, done ones too
4. ready to merge - approved and green
5. approved - CI not green yet
6. second look, theirs - their pull requests gone quiet on you
7. second look, mine - yours gone quiet on them
8. everything

Add your own under `[views]` in `data/config.toml`; the last entry under `'`
copies the current filter as the TOML that would name it, so a list arrived
at by hand is a view by the time it is pasted.

**The filter pane** (`f`) is one axis per question:

- `show` - three boxes that each *add* rows: `not done` · `done` · `filed
  away`. The number by a box is what checking it would bring in.
- `state` - two more: `open` · `closed or merged`. A row is in when its box
  on each of these two axes is checked.
- tag, kind, lane, repo, label, author - each narrows. A row has one kind -
  `pr`, `draft`, `branch`, `issue`, `notice` - so a view that wants every
  pull request names `pr` and `draft` both, and my work names `branch` with
  them.

Nothing asked means not done, in both states. Repo, label and author list
what is applied and keep the rest behind a picker row; `[filters]
pinned_repos` in `data/config.toml` names repos listed first regardless, as a
name or `owner/*`. In a view's TOML the axes are `show = ["not-done", "done",
"filed"]`, `state = ["open", "closed"]`, `kind = ["pr", "draft"]` and so on.
A view names a filter and nothing else: it is never a lane, and no row
carries a word for which view it belongs to.

**A notice** is a notification that is not an issue or pull request - a
release, a CI run, an alert, an advisory, an invitation, a discussion, a
comment on a commit - listed as the repository and its type: `julia release`,
`julia CI`. It is in the firehose and in no other built-in view
(`kind = ["notice"]` names them in yours), since it is news and never work.
Its pane is the facts: what it is, why GitHub said so, when, the link, and on
a commit its comments, all of them, oldest first.

- `o` opens the link - through `code --openExternal` from a Remote-SSH
  terminal, the desktop's opener where there is a display, and otherwise it
  is copied; `y` copies it.
- `e` or `x` dismisses it, and `z` puts it back. A dismissed notice returns
  when the thread notifies again, and not before.
- `R` reads a commit's comments again. Everything that needs a thread or a
  checkout is refused, since a notice has neither, and `d`, `p` and `c` say
  there is nothing to show.

**Reviewing**:

1. Drag over a diff, or `⇧j`/`⇧k`, then `C` comments on that range - under
   `d`, or on the right side under `p`, which is the head now. `^r` in the
   composer drops in a suggestion block.
2. Comments accumulate in a draft review on GitHub, pinned to the commit the
   diff was read at. Once the branch has moved under it, the draft names a
   head that is no longer the head, and the next `C` says to send it first.
3. `A` sends it: `1`-`3` a verdict with a body to write, `4` an approval with
   none, `5` the draft as it stands, `6` throws it away, asking once more.
   Leaving the item asks whether to send.

A diff is one node per hunk, headed by its file, its range and its counts,
with the function git names on the row under the header. While a hunk is
scrolled under the pane its top row says the file, the function and the
counts, and a click there is a click on the header. Existing review threads
hang off the hunk they point into, resolved ones folded, with `💬` in the
margin on their line. A control character is drawn as `^[` or `^M` rather
than sent to the terminal, and a row on top counts them and the characters
that print nothing - a bidi override, a zero-width space; a tab is drawn to
the next stop of eight and stays a tab in what `y` copies and `^r` suggests.

**Composers** open beside the diff or thread when the screen is 150 columns
or wider, with `tab` between them.

- `^s` sends; `^c` copies the whole text to the clipboard; `⌥e` or `^o`
  opens `$EDITOR`.
- `M`'s composer cycles the merge operation with `^x` - the bold word on its
  note, with a `don't squash` label as a red warning beside it - and asks
  once before it sends.

**A hosted pane** (`t`, `T`) takes every key except the prefix `^]`:

| | |
|---|---|
| `^]tab` `^][` | to the thread beside it, and back |
| `^]q` | leave it running |
| `^]K` | end it |
| `^]a` | full screen; back when the child exits |
| `^]r` | re-read it |
| `^]]` | a literal `^]` |
| `^]m` | the mouse to the terminal, and back |
| `^]t` `^]T` | the shell and the agent in its worktree |
| `^]` + an item key | `d` `h` `p` `c` `e` `x` `s` `v` `;` `A` `M` `L` `R` act on the session's item; the thread beside it moves there first |

Keys that point into the thread - `j`, `o`, `y`, `C` - act on whatever it
shows. Over a program that did not ask for the mouse - a shell, `less` - a
drag selects as tmux's copy mode does and copies to the clipboard on release;
the wheel scrolls back.

A program that exits - the agent finishing, `exit` in the shell - leaves its
pane on screen with its status, and nothing closes it but you: `q` there
ends it, and until then `t` or `T` opens what it left. It says `exited`
wherever the session is listed - under `running` in the item pane, under its
worktree in `"`, in the checkout picker - and that is the whole of it: an
exit is not a movement, and the item is not unread for it.

Every pane sees the ssh agent and the `code` of whichever login most
recently launched `wl`, however old the pane: `SSH_AUTH_SOCK`,
`VSCODE_IPC_HOOK_CLI` and `code` on `PATH` are links under
`$XDG_RUNTIME_DIR/wl/`, re-pointed at each launch. When nothing answers, the
status line says `no live ssh agent` as the pane opens.

**An agent that stopped while you were elsewhere** - finished, or asking
permission - makes its item unread, `why  unread: agent`, and shows in the
theme's `rang` colour: its row in the list, its `T` badge in the worktree
list, and `waiting on you` under `running` in the item pane.

- It is the terminal bell, rung by the hooks in `cli/claude-settings.json`,
  which `T` hands `claude` as `--settings`. tmux keeps it with the session,
  so nothing has to be running to catch it: a bell rung at three in the
  morning stands until it is looked at.
- Looking (`T`) clears it, and so does any mark - `e`, `s`, `x`, `wl done`;
  `z` rings it back.
- While the browser is up, tmux tells it within a second through one
  control-mode client, parked on a session of its own, `_wl-ctl-<pid>`,
  which `tmux ls` shows and `wl` does not list.

**A session's title** is what the child set: `claude` names it after the
conversation's topic, and a shell may set its own. It shows under the
worktree's row in `"`, on the `running` lines of the item pane, and on the
border of its pane. An agent titled `✳ Claude Code` has no conversation yet -
just started, or `/clear`ed - and is marked `/cleared`.

**VS Code** (`o`) opens the item's checkout - the worktree on its branch when
there is one - and under `d` or `p` the file at the line the cursor is on.
With the extension in `vscode/` installed, it opens the *diff* at that line
instead - against the merge base under `d`, the head you last read under `p`
- and on a commit in a push or a range-diff, that commit, every file against
its first parent. Build it with `vscode/package.sh` and install it once with
`code --install-extension`, from the terminal that reaches the VS Code you
use (under Remote-SSH, the remote one). Without it `o` opens the file or the
checkout, and says so.

**References are links**, as GitHub draws them: in the thread and under `p`,
`#123`, `owner/repo#123`, a sha and `owner/repo@sha` open the issue or the
commit. A sha is seven to forty hex digits with a digit and a letter both.

**The mouse**:

- a drag selects rows, and goes on scrolling when held past the pane's
  edge; a click moves the cursor; a click on a marker folds; the wheel
  scrolls the pane under it.
- in a picker - `'`, `"`, the checkout chooser - a click moves the cursor
  and a double click is `↵`.
- a click on a url copies it; a double click copies the word under the
  pointer, or the item's url in the list; the `⧉` at the right of every
  header copies that block.
- beside a composer or a hosted pane the thread takes the same clicks, and
  the keys stay where they were: `tab` moves them.

How far apart a double click's presses can be, and how fast a drag held
past an edge scrolls, are under `[mouse]` in the config.

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

`wl unread` is the browser's unread list, newest movement first, each row
with `why` - the same words the item pane says. `wl done all` marks that
same list, so a second pass finds nothing. A row with no done stamp is read
up to the day its source was named - the `since` in the `source:` blocks of
`local.toml` - and `wl done --consolidate` raises each `since` as far as the
stamps allow, dropping the stamps it then covers, without changing what any
row answers. `--dry-run` says what it would do.

`cli/bin/gmail-unread <label>` lists the threads with unread GitHub
notification mail under a Gmail label as urls, one per line, so
`gmail-unread GitHub | wl import -` imports what the mailbox says is still to
be looked at; `--seen` then marks those mails read. It needs an app password,
in `$GMAIL_APP_PASSWORD` or `~/.netrc`; `--help` has the details.

## Tracking

`track` decides what counts as an item *moving*, which is the one thing that
makes it unread and the one thing that wakes a snooze early. Two levels:

| level | default for | ignores |
|---|---|---|
| `normal` | your own unfinished work | nothing |
| `loose` | everything else, and anything finished | a bot's comment; a stranger's CI |

Both see a push, a human's comment, a review, a request, an assignment, a
close or a merge - by somebody other than you. Not movement at any level, and
never to be: your own actions, a label, a milestone, a title edit, a thread
being resolved, a review request being withdrawn.

## Configuration

Two files, read as one. `config.toml` beside the code has every key, its
default, and the comment that is its manual, versioned with the program.
`data/config.toml` is yours: copied from `config.user.toml` on the first
launch, with `login` filled from `gh`, and never written by the program
again. A key set there replaces the shared one - a table key by key, and
anything under a table key whole - so your `[events] repos` is the whole
list, not an addition to the shared one, and a `[views."name"]` of the same
name is the whole view. Both are hand-edited and only ever read.

Colours are in `themes/`, one file per theme, each naming colours by role in
words (`"bold white"`, `"black on yellow"`, `"on 236"`); `theme` in your
file picks one. The comments in `config.toml` and in the theme files are the
manual for every key.

## Files

| | owner | |
|---|---|---|
| `config.toml`, `config.user.toml`, `themes/` | you | hand-edited; the shared half, the template for yours, the colours |
| `cli/claude-settings.json` | you | what `T` hands `claude` as `--settings`: the hooks that ring the pane when a turn ends. Only ever read |
| `data/config.toml` | you | your half: login, theme, the repos you poll and pin. Seeded from the template on the first launch and never written again. Tracked |
| `data/local.toml` | you and the program | one block per item: your note, snooze, tracking level, and what you have done to it; and one per unread notice, `["notice:<id>"]`, written by the poll and removed when it is dismissed. Edited key by key; **never rewritten**. Tracked |
| `data/fetched.json` | `wl refresh` | everything GitHub can answer again. Safe to delete; ~6MB; ignored |
| `data/cache/`, `data/errors.log`, `data/refresh.log` | the browser, `wl prefetch` | ignored. Deleting `errors.log` dismisses the footer warning; `refresh.log` is the whole of what the last `u` said, and `wl log` prints it |
| `data/view.toml` | the browser | where it was when it last closed - the filter, the item, which view of it - read back at the next launch, the item even when the filter hides it; `` ` `` is the way back to the firehose from there. Written whole on the way out; ignored. Delete it to open on the firehose |
| `data/notifications.token` | you | optional: a token that can read `/notifications`, for a machine whose own cannot |
| `$XDG_RUNTIME_DIR/wl/` | the browser | links to the ssh agent, VS Code socket and `code` of the last login to launch it, which every pane is handed. Yours alone (`0700`, set at every launch); gone with the last login, like what they point at |

`data/` is a git repository of its own, so your record has a history without
cluttering the code's. Nothing commits automatically; the history is yours
to write, when you choose. `WORKLOG_DATA` points it elsewhere.

## Authentication

Every request to GitHub - the searches, the poll, the writes - is made with
one token, looked for in `/run/claudebox-github/token`, then `$GH_TOKEN` /
`$GITHUB_TOKEN`, then `gh auth token`, and failing all three it fails once,
naming every place it looked. `gh` is asked only for the token, so a machine
without it needs `GH_TOKEN` set, or the token in that file.

`/notifications` needs a *person's* token (`gho_`, `ghp_`) - a GitHub App's
(`ghu_`, `ghs_`) cannot read it. Off a sandbox, `gh auth token` is a `gho_`
with `repo` scope, which is enough; on a machine whose token is an App's, put
one in `data/notifications.token` or the source is skipped and says so.
Writing - comments, reviews, labels, merges - needs `issues: write` and
`pull_requests: write` on the repositories in question.
