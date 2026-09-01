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

Reading a review has shipped: review comments are placed against the hunk they
were left on, threaded by `in_reply_to_id`, with the ones GitHub can no longer
anchor gathered under a folded header; and labels are carried through to the
metadata pane and the filter pane.

What is left is the writing, and all of it waits on a token that can write.

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

**Labels.** Reading them has shipped - `Item` carries them, the metadata pane
shows them and the filter pane has a label axis. What is left is writing:

- one-key toggles for the two or three reached for constantly (a backport
  label, `merge me`), named in `config.toml` rather than hardcoded, and a
  picker for everything else. `POST`/`DELETE /repos/{r}/issues/{n}/labels`.

### Marking a thread unread again
`r` marks a thread read and there is no way back. The only inverse today is
editing `read.json` by hand, which is the file the whole unread lane is derived
from - so a misplaced `r`, or one pressed on the wrong row, silently loses the
one bit of state that cannot be re-derived from GitHub.

`Events.mark_read` writes one timestamp per URL into `read.json`; the inverse is
deleting that key, and `unread()` then treats the item as unseen if it moved
inside the lookback window. So this is a `mark_unread(urls)` beside it, a key in
the browser (`R` is free, and pairs with `r`), and a line in `wl read`'s command
surface for the non-interactive side.

Worth deciding at the same time: whether `r` should mark read *up to the
timestamp shown* rather than to now, so that reading a thread, walking away, and
coming back does not mark comments read that arrived while you were gone. That
is the same key doing a slightly different thing, not a second key.

### Inline code should not shout
Term renders a markdown code span as `md_code`-styled backticks around
syntax-highlighted content, and `md_code` defaults to `#FFF59D italic` - a pale
yellow that is the loudest thing on the screen for what is usually a variable
name. A grey background behind the *contents*, with the backticks quiet or gone,
is what it should look like.

What is in hand: `Term.TERM_THEME[].md_code` is writable at run time and takes a
Term style string, and it styles **only the delimiters** - setting it to
`"on_grey19"` gives a grey backtick, not a grey span. Verified shapes:

    default        \e[3m\e[38;2;255;245;157m`\e[23m\e[39m  <content>  <same again>
    md_code="dim"  \e[2m`\e[22m                             <content>  <same again>

So killing the yellow is a one-line theme assignment, but putting the background
behind the content needs a pass over the rendered ANSI in `render_md`: set
`md_code` to a sentinel style, then rewrite `SENTINEL ` RESET … SENTINEL ` RESET`
into background-wrapped content. Two things to decide there: whether to drop the
backticks once the background marks the span, and what to do when Term wraps a
span across a line - the pair is then on two lines, and a background that spans
the break would bleed into the pane border, so a split span probably has to keep
the plain delimiters.

### tmux + ClaudeBox review sessions
A persistent sandboxed Claude per review, to push an item into and resume
later.

**This one cannot be built from inside the sandbox.** Checked on 2026-09-01:
`tmux`, `claudebox`, `docker` and `podman` are all absent from `PATH`,
ClaudeBox.jl is not in any environment here, and `$TMUX` is unset — so neither
of the questions this section used to open with can be answered from here, and
neither can the feature be exercised. It is host work; do not start it in a
sandbox session expecting to test it.

What still holds, for whoever picks it up on the host: session naming from the
item (`wl-julia-62841`) makes tmux itself the state store, so only the mapping
needs persisting, which fits the `state.toml` pattern (`review_session = "..."`)
or `repos.toml`. The two open questions remain whether ClaudeBox.jl can launch
non-interactively into an existing pane, and whether sandbox-in-sandbox works
at all.

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
- **The metadata pane is a readout, not a control.** Clicking in it does
  nothing, `Tab` still cycles only the list and the detail, and there is no way
  to act on what it shows — no key to add a label, assign a reviewer or open a
  check from there. The review-from-the-browser work above is where that goes.
- **Per-check counts come from the same cache the `C` pane uses.** So the
  rollup line is as stale as `check_contexts`' TTL (120s), and an item whose
  checks have never been fetched shows the one-word rollup from `facts.json`
  until the lazy fetch lands.
- **Nesting is depth, not structure.** `Node.depth` draws a block inset and
  `rows` hides the run of deeper nodes under a closed one, which is enough to
  behave like a tree when reading. It is not one: nothing can be moved or
  counted as a subtree, and a body whose depth would exceed `MAX_DEPTH` is left
  as raw text rather than nested further.

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
