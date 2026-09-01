# TODO

## Resuming work

Read this first if you are picking this up cold.

### What it is
A personal GitHub work dashboard for `vtjnash`, in Julia. It buckets ~2000
items (own PRs, review requests, assigned issues, plus mention/comment history
and every open JuliaLang/julia PR as a background pile), tracks which threads
are unread so per-event email notification can stay off, and browses them in a
two-pane terminal UI.

### Where and how to run it
Everything lives in `/root/.claude/worklog`, a git repo with no remote yet.
That path is a real host bind-mount and persists; `/home/vtjnash` outside the
Julia checkout is a throwaway overlay.

```bash
cd /root/.claude/worklog
./cli/bin/refresh              # fetch, bucket, write DASHBOARD.md  (~30s)
./cli/bin/refresh --firehose   # force the 6-hourly bulk lanes too  (~6min)
./cli/bin/wl                   # the browser (needs a TTY)
./cli/bin/wl show julia#62841  # non-interactive thread view
./cli/bin/wl next 10           # pull untagged backlog to triage
```

Use the `julia` on PATH (juliaup, 1.14-DEV). The in-tree
`/home/vtjnash/julia/usr/bin/julia` does **not** run in this sandbox — it is
linked against a newer glibc.

### Layout
| file | role |
|---|---|
| `cli/src/gh.jl` | GraphQL search lanes, shelled through `gh api graphql` |
| `cli/src/events.jl` | unread tracking and live thread fetch (submodule `Events`) |
| `cli/src/refresh.jl` | normalize, bucket, fingerprint, snooze, bulk cache, render |
| `cli/src/state.jl` | the line-based `state.toml` editor, `next` queue |
| `cli/src/controller.jl` | the view controller that owns stdin; `PromptView` |
| `cli/src/browse.jl` | the two-pane browser: filters, panes, folding, diffs, checks |
| `cli/src/ansi.jl` | escape-aware width, truncate, wrap |
| `cli/src/ci.jl` | check contexts and Buildkite drill-down |
| `cli/src/repos.jl` | repo → local checkout mapping, worktrees, `git show` |
| `cli/src/cache.jl` | on-disk cache with TTL |
| `cli/test/runtests.jl` | everything testable without a terminal |

Owner rules for the data files matter: `config.toml`, `state.toml` and
`repos.toml` are **yours** — `refresh` reads `state.toml` and never writes it,
and only `wl` edits it, through a line-based editor that preserves comments.
`facts.json`, `bulk.json`, `read.json`, `queue.json`, `snooze.json` and
`cache/` are machine-owned.

### Testing without a terminal
There is no TTY here, so the UI is tested by construction rather than by use:

- `render(view, w, h)` is **pure** — state and a size in, a string out. Snapshot
  it and assert every line has the same display width.
- `handle!(view, keycode, ctrl)` takes a keycode and returns an action, so real
  keystrokes can be driven directly without stdin.
- Strip escapes before measuring: both SGR (`\e[...m`) and OSC 8 hyperlinks.
- A background fetch signals completion by pushing a `WakeEvent`; in a test,
  `take!(ctrl.events)` then `onwake!(view)`.
- `readevent(io)` is a pure function of a byte stream, so keys and mouse reports
  are driven from an `IOBuffer`: `readevent(IOBuffer("\e[<0;40;12M"))`.
- `onmouse!(view, MouseEvent(...), ctrl)` takes screen coordinates. Render a
  frame first — the mouse maps a click through `layout(w, h)` and `st.hdr`, and
  `st.hdr` is only known once the item title has been wrapped.
- `cli/test/runtests.jl` holds all of the above; run it with
  `julia --project=cli cli/test/runtests.jl`.

Typical harness:

```julia
items = Worklog.loaditems()
st = Worklog.BState(items, "worklog", Set{String}())
ctrl = Worklog.Controller(); ctrl.running = true
st.wake = () -> Worklog.wake!(ctrl)
Worklog.load_nodes!(st); take!(ctrl.events); Worklog.onwake!(st)
```

### Invariants that were each found by debugging a real failure
Do not "simplify" any of these away.

**GitHub**
1. `mergeable` is computed lazily — a cold read returns `UNKNOWN` and only
   schedules the work. Carry the last known value forward.
2. GraphQL `search(type: ISSUE)` returns **0** for `assignee:` unless the query
   also carries `is:issue` or `is:pr`.
3. A search returning Issues against a fragment that only spreads
   `... on PullRequest` yields field-less `{__typename: "Issue"}` stubs, with no
   error.
4. Search truncates at **1000 results**; JuliaLang/julia is at ~993, so a query
   crossing 950 is re-run partitioned by creation year.
5. `gh api --paginate` is unsafe on a `sort=updated` list — it follows Link
   headers over a reordering collection and silently drops entries (168 vs 612
   on identical runs). Page explicitly with `direction=asc` and dedupe by id.
6. A *successful* response can still be wrong: an `issueCount` of 0 alongside
   100 nodes once overwrote a 957-item cached lane. `implausible()` guards this.

**Term.jl**
7. `parse_md` escapes braces by doubling them and nothing downstream collapses
   them — Julia type signatures arrive as `Tuple{{Type{{S{{N, Tup}}}`.
8. `parse_md` does not wrap lines containing inline code (232 display columns
   for a requested 90). We wrap with `awrap`.
9. `Panel` measures markup, not what prints, so it is no longer used for layout
   at all — `pane()` draws borders here. Term is only a markdown→ANSI converter.
10. `parse_md` wraps prose at the width it is handed, so by the time text
    reaches us a paragraph is already in pieces and `awrap` only sees what Term
    declined to wrap. Rendering a second time at a width nothing reaches gives
    the unwrapped form — but that render cannot be displayed, because a code
    block or table is a box and Term pads the box to the full width. `nodelines`
    renders both and aligns them; that is what makes a copy paste as paragraphs.

**Buildkite** (see the `buildkite-logs` skill for the endpoint shapes)
11. Job discovery must use `/data/jobs`; the per-build JSON returns an empty
    jobs array to an anonymous caller, with no error.
12. Logs are HTML — drop `<time>` elements *before* stripping tags, and decode
    numeric entities (`&#47;`) as well as named ones.

### Conventions
Commit as `worklog: brief summary`, prose body explaining the purpose (not a
file list, not a test plan), ending with:

    Assisted-by: Claude Code (Opus 5)

Write commit bodies to a file and use `git commit -F` — backticks in a heredoc
get interpreted by the shell and silently mangle the message.

Outstanding work, roughly in the order it is worth doing. Things already
shipped are not listed; `git log` is the record of those.

## Requested features, not started

### Review from inside the browser

Everything here is read-only today. The natural next step is the review itself:
read the diff, say something about a line, approve, label, move on. Four pieces
that share one prerequisite - a token that can write. The sandbox's GitHub App
token is read-only for most of this, so this lands behind the same PAT that
Infrastructure below already wants.

**Comments inline with the diff.** `Events.thread` already fetches
`/pulls/N/comments` next to the issue comments and merges both into one flat,
time-ordered list - so a review comment shows up in the `o` pane detached from
the code it is about, and the `d` pane shows code nobody has said anything
about. Each review comment carries `path`, `line`/`original_line`, `side`,
`diff_hunk` and `in_reply_to_id`; `comment_nodes` throws all of it away. Keep
those fields and hang each comment off the hunk node whose file and line range
contains it. Two things to decide: what to do with a comment that lands outside
every hunk of the current diff - an outdated one has a null `line` and only
`original_line` to go on - and whether a reply thread becomes a nested node or
an indented block inside the hunk's. Threading is by `in_reply_to_id`; the API
returns them flat and does not group them.

**Writing a comment.** Three calls, in increasing order of ceremony:

- on the PR or issue as a whole: `POST /repos/{r}/issues/{n}/comments`.
- on a source line, from the diff pane: `POST /repos/{r}/pulls/{n}/comments`
  with `commit_id`, `path`, `line` and `side`. The hunk node already holds all
  of it - `meta["file"]`, `meta["start"]`, the cursor's offset within the hunk,
  and `head_sha(it)`.
- replying to an existing review comment: the same endpoint with `in_reply_to`.

The composer is the work, not the request. `PromptView` is one line with
backspace and nothing else, which is not somewhere anyone will write a review.
Either grow it into a multi-line editor view, or shell out to `$EDITOR` on a
temp file - which means giving up raw mode and the alternate screen while it
runs and restoring both afterwards. The controller owns both, so that belongs
there, as a `suspend(ctrl) do ... end`.

**Approval.** `POST /repos/{r}/pulls/{n}/reviews` with an `event` of `APPROVE`,
`REQUEST_CHANGES` or `COMMENT`, which can carry pending line comments in the
same call. Batching them into one review rather than posting each as it is
written is the difference between a review and a stream of notifications, so
the pending set wants to live on `BState` and be visible while it accumulates -
a count in the footer, and a line in the metadata pane. An approval checkbox
that submits an empty `APPROVE` is the common case and should be one key.

**Labels.** `labels` is fetched by every GraphQL fragment, stored in
`facts.json`, and already load-bearing for `state.jl`'s area matching - but
`Item` drops it, so the browser cannot see it. Carry it through, then:

- a label axis in the filter pane beside category and repo. `Filters` and
  `filter_rows` are already shaped for another checkbox group.
- one-key toggles for the two or three reached for constantly (a backport
  label, `merge me`), named in `config.toml` rather than hardcoded, and a
  picker for everything else. `POST`/`DELETE /repos/{r}/issues/{n}/labels`.

### Collapse `<details>` to its `<summary>`
GitHub comments are full of them — codecov reports, log dumps, generated
tables. `Markdown.parse` passes HTML through untouched, so this is a pre-pass
over the raw body in `comment_nodes`: find `<details>…</details>`, take the
`<summary>` as a header, and emit the contents as a nested foldable node.
Nesting is the only awkward part; `Node` is currently a flat list, so either
give it a depth field or splice the block out into sibling nodes.

### Third pane: metadata
Reviewers, labels and CI state at a glance, without switching the detail pane
away from what you are reading.

Contents: requested reviewers and who has actually reviewed (with their state),
labels, the CI rollup plus a per-check line, milestone, assignees, mergeable
state, and the tracking level and any note from `state.toml`.

Most of it is already in hand. `facts.json` carries labels, `review_decision`,
`ci`, `unresolved`, `mergeable` and `milestone`; `check_contexts` (cached)
gives per-check state. The gap is per-person review state: the heavy GraphQL
query fetches `reviews(last:20)` with author and state, but the light query the
bulk lanes use does not, and items reached through the mention or firehose
lanes therefore have none. Either widen the light query — it is ~2000 items, so
measure the cost first — or fetch reviews lazily for the selected item, which
fits the existing async `load_nodes!` pattern.

Layout is the real question. Side-by-side already needs 110 columns; a third
pane wants roughly 160. Below that it should probably become a strip under the
detail pane, or a toggle rather than a permanent pane. `pane()` already draws
any box, and the frame is assembled by joining rows, so the drawing is not the
work — deciding the breakpoints is.

Also note `Tab` currently toggles between two panes and would need to cycle
three, and `BState.focus` is a `Symbol` compared against `:list` / `:detail` in
several places rather than being a proper cycle.

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

- Key handling end to end: arrow keys, page keys and Shift-Tab. The decoder
  that produces them is driven directly from an `IOBuffer` in the tests, so the
  byte-to-keycode step is covered; what is not is whether this terminal sends
  the bytes the tests feed it.
- Mouse reporting end to end. `\e[?1006h\e[?1002h` going out, SGR reports
  coming back, and whether they survive tmux. Click-to-row, drag-to-select and
  the wheel are all tested by handing `onmouse!` synthetic events against a
  rendered frame, which pins the geometry but not the terminal.
- Whether giving up the terminal's own selection is the right trade in practice.
  `m` turns mouse reporting off and hands it back, which is the escape hatch,
  but only real use will say whether that toggle is reached for constantly.
- Raw mode setup and restoration on abnormal exit.
- Whether the title-bar row actually settles the tmux copy-mode scroll.
- Whether OSC 8 links and the OSC 52 copy survive this tmux (both need 3.4+,
  and OSC 52 is opt-in in some terminals).
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
