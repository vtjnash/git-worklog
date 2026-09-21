# Tests that need a terminal

What the suite cannot run: it has no TTY, no tmux server of the user's, no
GitHub it may write to. Each test here says what to do, what passing looks
like, and when it last passed and where. Run one when its code moves; a new
one is written here when a TODO item under *Unverified* is first tried, and
the TODO line goes.

Last full pass: **2026-09-21**, VS Code Remote-SSH from a Mac (xterm.js),
with Terminal.app and a tmux of the user's own for the title and width
checks; bundled tmux 3.5.1 client and server. What the pass turned up was
fixed the same day, in the commits after the one that added this file;
what remains is in TODO.md under *Unverified*.

## 1. Key bytes

In a plain shell, `cat -v`, then the keys with a space between each.

| key | bytes |
|---|---|
| ↑ ↓ ← → | `^[[A ^[[B ^[[D ^[[C`, or `^[OA`… - both decode |
| PgUp PgDn | `^[[5~ ^[[6~` |
| Home End | `^[[H ^[[F` or `^[[1~ ^[[4~` |
| Shift-Tab | `^[[Z` |
| Alt-e Alt-b Alt-f | `^[e ^[b ^[f` |
| Alt-← | `^[[1;3D`, `^[^[[D` or `^[b` - all three decode |

Alt-Backspace cannot be seen this way: `cat` runs in canonical mode and the
DEL erases the ESC before it. It is checked in the composer (5b). Fail is
Alt-e arriving as a composed character - a Mac terminal whose Option is not
Meta - which leaves `^o` as the way to the editor.

*2026-09-21*: pass. VS Code with `macOptionIsMeta` sends `^[e` **and** leaves
the dead accent pending, so a single `⌥e` printed `^[e´` and the `⌥b` after
it `∫`; alone, `⌥b` is `^[b`. Nothing of that reached the composer (5c).
VS Code keeps PgUp/PgDn for its own scroll and never hands them over, so
those two rows pass by construction there (`controller.jl` decodes `5~`/`6~`
and every pager binds `K_PGUP`/`K_PGDN` beside `space`/`b`).

## 2. SIGWINCH

- **the frame**: `wl`, `o` on a pull request, drag the terminal narrower
  and wider without pressing a key. Pass: the frame redraws to each size on
  its own; crossing 150 columns switches side-by-side and stacked.
- **a hosted pane**: `t`, `tput cols`, resize, `tput cols` again. Pass: the
  second number is the new width and the shell redrew inside the new box.
- **a pty that never sends the signal**: stand in with the signal blocked
  across `exec` -
  `python3 -c 'import signal,os; signal.pthread_sigmask(signal.SIG_BLOCK,[signal.SIGWINCH]); os.execv("cli/bin/wl",["wl"])'`
  - open a thread, resize. Pass: nothing moves until the next key, which
  draws the new size with no fragments of the old frame.

*2026-09-21*: all three pass.

## 3. The title

- **follows the cursor**: the terminal's tab or title reads `wl <repo>#<n>`
  and changes with `j`/`k`; the title bar row says what the number is of.
  VS Code shows the sequence only with `terminal.integrated.tabs.title` set
  to `${sequence}`; tmux and Terminal.app show it as they are.
- **through a dialog**: `q` then `n`; `t` into the checkout question and
  out. Pass: the title stays on the item.
- **inside tmux**: `tmux new -s x cli/bin/wl`; `tmux display -p
  '#{pane_title}'` from another pane, or the status bar's right end if
  `status-right` still shows `pane_title`.
- **after exit**: `q`. Pass is the old title back at once (a terminal with
  a title stack), or the `wl` title standing until the next prompt takes it
  back (xterm.js). Fail is a wrong title at the next prompt.

*2026-09-21*: pass in Terminal.app and tmux; VS Code needs the setting
above; after exit it was back at bash's title.

## 4. OSC 8 links, OSC 52 copy, scrolling a pane

`tmux display -p '#{version}'` says which server renders `capture-pane`;
OSC 8 through it needs 3.4.

- **links in the frame**: the item's number in the title bar, a comment
  header, a url in the prose - each ⌘-clickable, each to the right page
  (a header to its own permalink).
- **copy three ways**: `⇧j` `⇧j` `y`; a double click on a word; the `⧉` at
  the right of a header. Paste after each. OSC 52 is off in some terminals
  (Terminal.app), which is the terminal and not a fail.
- **through a pane**: in a `t` shell,
  `printf '\e]8;;https://example.com\e\\a link\e]8;;\e\\\n'` and
  `printf '\e]52;c;%s\a\n' "$(printf 'from the pane' | base64)"`. Pass: the
  link is clickable through the captured frame, and a paste gives the text.
- **scrolling back**: `seq 1 500`, wheel up over the pane. Pass: the pane
  scrolls back in copy-mode with tmux's `[n/500]` at its top right, the
  frame's title row and borders stay put, `q` returns to the prompt.

*2026-09-21*: all pass in VS Code; copy fails in Terminal.app as expected.
Found on the way: Terminal.app drew the frame with the right border off
every row unless `wl` ran under tmux - the erase after a full row, taken
from the pending-wrap cell - fixed the same day (`frame_bytes`) and seen
right in Terminal.app after.

## 5. The composer, the editor, and leaving

- **`^s` is a key**: `C`, and with the composer empty, `^s`. Pass: the
  status says `nothing to send — esc cancels`; the screen freezing is IXON
  still on (`^q` unfreezes).
- **`⌥⌫`**: type `one two three`, `⌥⌫` leaves `one two `; `⌥←`/`⌥→` move by
  word, `⌥d` kills forward.
- **`⌥e` and `^o`**: with text in the composer, each opens `$EDITOR` on it,
  the frame gone while it is up, and returns with the edit and a clean
  redraw. Look for a stray character (a dead-key accent) in the editor's
  buffer or in the composer afterwards. Esc, `y` to discard.
- **`e`**: on a pull request with a checkout, the worktree opens in `code`;
  under `d` on a diff line, the file at that line - the diff editor at it
  with the `vscode/` extension installed.
- **raw mode on abnormal exit**: `kill -TERM` the `wl` julia from another
  terminal. Pass: normal screen back, prompt there, typing echoes, no
  `reset` needed. Then close the terminal tab on a running `wl`: no julia
  left in `pgrep -af julia`.

*2026-09-21*: all pass; no stray accent seen.

## 6. `u` end to end

`u`. The title bar's right end says `refreshing …` and the browser stays
live - `j`/`k`, `o` - for the ~25s; one ~100 ms hitch at the corpus write is
expected. When it lands: the report on the status row, the fetched time now,
the list re-sorted with the new on top. `wl log` afterwards prints what the
run said.

*2026-09-21*: pass.

## 7. `session ended` over an empty frame

The burst that blocked the control-mode reader (DESIGN, tmux). In a `t`
pane: `less README.md` and page through; `git log` and page through; an
editor opening on a file; `seq 1 20000`. Pass: the pane survives all four,
`^]tab` still swaps to the thread and back, and the status never says
`session ended` - and when it does, it says why after the colon.

*2026-09-21*: pass.

## 8. The forwards across a reconnect

- **before**: `t`; `ls -l $XDG_RUNTIME_DIR/wl/`, `ssh-add -l`, `code
  --version`. The links name this login's sockets, the agent answers, `code`
  answers. `^]q`.
- **the login goes stale under a running `wl`**: with `wl` still up,
  *Developer: Reload Window*; VS Code hands the terminal back with `wl` in
  it and its environment naming abandoned sockets. `t` on the same item goes
  straight into the pane, and the status says what is not live. `^]q`, `q`.
- **a fresh `wl` re-points the links**: a new terminal, `wl`, `t` into the
  same old pane. The links now name the new sockets; `ssh-add -l` answers;
  `ssh -T git@github.com` authenticates; `code README.md` opens in this
  window; nothing on the status about a missing agent.

*2026-09-21*: pass; the stale case said `no live VS Code to open it in`.

## 9. `y` on the checkout question, against GitHub

Needs a registered checkout (`wl repos`) with pull requests; each case goes
through `gh` for real. `t` on the named kind of item; `git worktree remove`
and `git branch -D` afterwards.

- **a PR into a copy on master**: someone else's PR, head never fetched, the
  main copy on `master`. The question shows `<copy> is on master`, `git
  status`, `y runs gh pr checkout <N> there`. `y`: the shell opens on the
  PR's branch.
- **a fork's branch into a fresh worktree**: a fork PR whose branch name is
  not here; `w`, `+ a new worktree …`, a path. gh makes it (`git worktree
  list`), the shell opens in it on the branch; no `invalid reference`.
- **a fork's PR named like a branch here**: a fork PR whose head is
  `master`. The worktree is on `pr<N>/master`, your `master` untouched, and
  `git rev-parse --abbrev-ref @{u}` there is the right remote's branch.
- **your own branch that moved on the remote**: local `<b>` behind
  `origin/<b>`, the copy on something else. `y` checks out `<b>` at the
  remote tip.
- **the lease line**: absent on every question while
  `push.useForceIfIncludes` is on; `git config push.useForceIfIncludes
  false` in one checkout, and the question there carries the line, naming
  the right remote and branch. `--unset` after.
- **a branch two remotes carry**: `origin/<b>` and `<fork>/<b>`, no local
  `<b>`; `w`, new worktree. Made from the project's remote, no refusal;
  `@{u}` is `origin/<b>`.
- **the fast-forward offer, and none for a rewind**: a copy on your PR's
  branch. *Left behind*: `git checkout --detach; git branch -D <b>; git
  branch <b> origin/<b>~1; git checkout <b>` (the delete drops the reflog);
  `t` asks to fast-forward and `y` moves it. *Rewound*: `git reset --hard
  HEAD~1` (the reflog remembers); `t` opens the shell with no offer.
- **a changed file in the way**: copy on `master`, an uncommitted edit to a
  file the PR changes, `y`. The shell opens anyway on `master`, git's
  complaint first on the status row.

*2026-09-21*: all pass; the fork's `@{u}` was `origin/<branch>`. Found on
the way and fixed the same day: the report after `y` landed on the
browser's status row, which the pane covers (now on the pane's footer too);
a worktree on a same-named branch of *another* fork's PR was taken by name
(now refused when git and the item disagree about whose it is); the
question's `git status` wanted the head, ahead/behind and the lease's
answer (now there); the lease line names the `git config` that fixes it,
and the box wraps its notes. The next pass should see each of those.

## 10. The `pull/N/head` refspec

A PR whose head is not local (`git cat-file -t <sha>` fails). By hand:
`git fetch --quiet --no-write-fetch-head origin pull/<N>/head && git
cat-file -t <sha>` says `commit`, and `.git/FETCH_HEAD`'s mtime is
unchanged. Then `p` in `wl` on another such PR with a push since it was
read: the push's diff is drawn and the new head is now local.

*2026-09-21*: pass - the first spec answers on its own; the bare sha is the
fallback it was meant to be.

## 11. `p` against a rebase whose base moved

In a checkout with a PR branch of yours: `git update-ref
refs/remotes/origin/master origin/master~30`; fetch the real master, rebase
the branch onto it, `git push --force-with-lease`. In `wl`, `R` then `p`.
Pass: the branch's own commits, not the thirty the rebase pulled under it;
`git rev-parse origin/master` is the current tip afterwards.

*2026-09-21*: pass.

## 12. Judgement, after real use

Not pass/fail; asked once the program has been lived in.

- Owning the mouse, with `m` to give it back: is `m` reached for constantly?
- 150 columns as the split threshold: right?
- Does any lane want an order of its own, or is `w`'s cycle enough?

*2026-09-21*: the mouse trade holds, 150 holds, `w` is enough. One ask, in
TODO: a list row two high for the longer titles, which are cut at about half.
