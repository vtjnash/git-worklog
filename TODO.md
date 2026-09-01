# TODO

Outstanding work, roughly in the order it is worth doing. Things already
shipped are not listed; `git log` is the record of those.

## Requested features, not started

### Mouse support
Own the mouse rather than leaving selection to the terminal. Terminal selection
cannot follow text that *we* wrapped — the terminal only sees the wrapped
lines, so selecting a paragraph inside a pane yields the wrapped fragments plus
the pane borders.

- Enable SGR mouse reporting (`\e[?1006h\e[?1002h`) alongside the alternate
  screen in `Controller.run!`, and disable it in the same `finally`.
- Decode `\e[<b;x;yM` / `m` in the controller's reader. That reader is now the
  only thing that touches stdin, which is what makes this tractable; emit a
  `MouseEvent` on the same channel as keys and wakeups.
- Selection state on the view: click positions, drag extends, and a yank that
  reconstructs the **unwrapped** source text from the node rather than scraping
  the screen. This is the part that carries the value and most of the work.
- Clicking a row should also move the cursor there, and clicking a fold marker
  should toggle it.

### Collapse `<details>` to its `<summary>`
GitHub comments are full of them — codecov reports, log dumps, generated
tables. `Markdown.parse` passes HTML through untouched, so this is a pre-pass
over the raw body in `comment_nodes`: find `<details>…</details>`, take the
`<summary>` as a header, and emit the contents as a nested foldable node.
Nesting is the only awkward part; `Node` is currently a flat list, so either
give it a depth field or splice the block out into sibling nodes.

### tmux + ClaudeBox review sessions
A persistent sandboxed Claude per review, to push an item into and resume
later. Two things to establish before designing further:

- Whether ClaudeBox.jl can launch non-interactively into an existing tmux pane.
- Whether sandbox-in-sandbox works here, or whether this is only testable on
  the host.

Session naming from the item (`wl-julia-62841`) makes tmux itself the state
store; only the mapping needs persisting, which fits the `state.toml` pattern
(`review_session = "..."`) or `repos.toml`.

## Known gaps in what has shipped

- **Hunk context expands against the head commit.** Context around a `-` line
  therefore shows the post-change file, not the pre-change one. Fine for
  reading a change; wrong if you want the base side. Needs a second fetch and a
  decision about which side to show per hunk.
- **Worktree choice is automatic.** `e` prefers a worktree already on the PR's
  branch and otherwise falls back to the main clone. There is no way to pick a
  different one, and no offer to create a worktree for the branch.
- **`repos.toml` is never pruned.** Entries pointing at deleted folders are
  ignored at read time but never removed or re-prompted.

## Unverified — needs a real terminal

Everything below is written and compiles, and its state transitions are tested
by driving `handle!` directly, but none of it has been exercised through an
actual TTY:

- Key handling end to end: arrow keys, page keys, and specifically Shift-Tab,
  whose fix (draining `CSI Z` in the reader) was reasoned about rather than
  observed.
- Raw mode setup and restoration on abnormal exit.
- Whether the title-bar row actually settles the tmux copy-mode scroll.
- `open_editor`: `code` is not on PATH in the sandbox, so the launch is
  untested. The worktree *selection* around it is tested against a real
  worktree list.
- `ensure_commit!`'s fetch path: every PR tried so far already had its head
  commit locally, so the fetch fallback has never run.

## Carried over from the Python port

Small behaviour differences the port deliberately kept or introduced, recorded
so they are not mistaken for bugs later:

- `set_fields` moves edited keys to the end of their block and drops blank
  lines *inside* an edited block. This matched the Python exactly.
- An unquoted `deadline` (a bare TOML date) crashed the Python; the Julia
  flattens it to an ISO string instead.
- `table_key_order` is untested against TOML shapes it does not parse, such as
  multi-line inline tables. It degrades to sorted order rather than dropping
  keys.
- `cli/bin/refresh --firehose` was tested through `main` directly but never as
  a full live run through the shell wrapper.

## Infrastructure

- **Push to a private repo.** Needs a fine-grained PAT scoped to
  `vtjnash/worklog` with `Contents: read/write`; the sandbox's GitHub App token
  is read-only for contents everywhere. Until then everything is local.
- **Notifications lane.** Decided against: `mentions:` and `commenter:` cover
  the gap through ordinary search, leaving only team mentions
  (`@JuliaLang/compiler`) genuinely unreachable. Revisit only if those matter
  enough to justify a classic PAT, and build it as a durable sync rather than a
  live lane if so.
