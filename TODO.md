# TODO

## Resuming work

Read this first if you are picking this up cold.

### What it is
A personal GitHub work dashboard for `vtjnash`, in Julia. It buckets ~2000
items (own PRs, review requests, assigned issues, plus mention/comment history
and every open JuliaLang/julia PR as a background pile), tracks which threads
are unread so per-event email notification can stay off, and browses them in a
terminal UI of three panes - the item list, its metadata, and the thread or
diff.

### Where and how to run it
The checkout is wherever the sandbox mounted it - it has been at
`/root/.claude/worklog` and at `.../claude_home/git-worklog`, so take the path
from `git rev-parse --show-toplevel` rather than from here. It persists; the
rest of the home directory is a throwaway overlay. `origin` is
`vtjnash/git-worklog` (see Infrastructure - pushing has never been tried).

```bash
cd "$(git rev-parse --show-toplevel)"
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
| `cli/src/controller.jl` | the view controller that owns stdin; input decoding; `PromptView`, `EditorView`, `ChooseView` |
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
   for a requested 90). We wrap with `awrap`. Term's own wrapping is known to be
   shaky - FedeClaudi/Term.jl#247 is open on it - so this is not a workaround
   waiting on an upgrade.
9. `Panel` measures markup, not what prints, so it is no longer used for layout
   at all — `pane()` draws borders here. Term is only a markdown→ANSI converter.
10. `parse_md` wraps prose at the width it is handed, so by the time text
    reaches us a paragraph is already in pieces and `awrap` only sees what Term
    declined to wrap. Rendering a second time at a width nothing reaches gives
    the unwrapped form — but that render cannot be displayed, because a code
    block or table is a box and Term pads the box to the full width. `nodelines`
    renders both and aligns them; that is what makes a copy paste as paragraphs.
    The wide line is only ever the better source when it *joined* several narrow
    ones. Matched one-to-one they are the same content, and taking the wide one
    hands a copy the box's padding - 1992 columns of spaces with a border on the
    end, for the gdb log on Distributed.jl#196.

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

**Key bindings: a capital reaches GitHub, lowercase does not.** `C`, `A` and `L`
post a comment, submit a review and set a label; everything lowercase stays on
this machine, `r` and `s` included — `read.json` and `state.toml` are local
files, and `e` only launches an editor. The line is *remote*, not *writes
something*, which is also why `z` below can offer to undo the lowercase set and
must never offer to undo the capitals.

Outstanding work, roughly in the order it is worth doing. Things already
shipped are not listed; `git log` is the record of those.

## Outstanding work

### What review writing still cannot do

`c`, `A` and `L` are wired but unexercised - see Unverified below, and
Infrastructure for the PAT they need. What is missing rather than merely
untested:

- **A comment on a deleted line.** `c` refuses it. The line number is known -
  `hunk_line_at` returns the old-side number and says which side it is - but
  GitHub wants that anchored against the commit the line still existed in, and
  `head_sha` only knows the head.
- **Batching line comments into one review.** Each `c` on a line posts
  immediately, so five remarks are five notifications rather than one review.
  `POST /pulls/{n}/reviews` takes a `comments` array; the pending set wants to
  live on `BState` and be visible while it accumulates - a count in the footer,
  a line in the metadata pane - with `A` submitting it.
- **A label toggle does not show until the next refresh.** `Item` is built from
  `facts.json` and is not rewritten in place, so the metadata pane keeps the old
  set; the status line says so. Either patch the item in memory or re-read it.
- **A reply to an issue comment.** Only review comments carry a thread, so `c`
  on an ordinary comment writes a new one rather than replying. That matches
  GitHub, but it surprises.

### `z` undoes the last local action
`r` and `s` change a file with no way back, and both are one keystroke on a list
where the cursor moves under you. A per-session undo stack on `BState`, deepest
first, so `z z z` walks back a run of them.

What each needs put back:

- `r` calls `Events.mark_read([url])`, which sets `read.json[url]` to now. The
  previous value has to be captured *before* the write — `load_read()` already
  reads the whole file — and restored, or the key deleted when there was none.
  That is exactly the operation the mark-unread entry wants, so build that first
  and `z` becomes one of its callers.
- `s` calls `disarm(url)` and then `set_fields(url, ["snooze" => "on-change"])`.
  `set_fields` already removes a key when handed `nothing`, so the undo is
  `set_fields(url, ["snooze" => previous])` with `previous === nothing` when
  there was none. Reading `previous` needs a getter for one field of one block,
  which `state.jl` does not have. `disarm` needs nothing put back: `snooze.json`
  is machine-owned and the next refresh re-arms it from the current state.
- `e` has nothing to undo. It launches an editor and changes nothing here.

The scope is exactly the lowercase set, and that is not a coincidence: a posted
comment cannot be taken back by rewriting a local file, and `z` must not look as
though it might. If the stack ever holds something that reached GitHub, it is
the binding rule that has gone wrong.

### Search the source, not the screen
`/` matches each row's *printed* text, which is what made highlighting possible
— a character offset in what prints is an offset that can be given a background.
It also means the search only finds what happens to be visible, and there are
two ways that loses a real hit. Both are worth fixing even at the cost of the
highlight, which is a nicety; finding the thing is the point.

**A phrase broken across a wrap.** `perf_event_paranoid` split as `perf_event_`
/ `paranoid` is not found by either half. Every row already carries `src`, the
unwrapped line it came from, so this is a change of one predicate in
`match_rows`: test `r.src` instead of `astrip(r.text)`, on the rows with
`part == 0` — one per logical line, which is what stops a wrapped line matching
three times.

Highlighting need not be lost outright, and the hybrid is cheap because both
halves already exist. Find on `src`; then highlight with the existing
`findhits(astrip(r.text), q)`, which returns empty exactly for the rows where
the match straddles a break. So every hit that *is* visible on one row keeps its
marking, and only the split ones are found-but-unmarked. Those should still be
reachable — the cursor lands on the row, and the footer count is honest about
how many there are.

Note this changes what a match *is*: one per logical line rather than one per
visible occurrence. That is the better unit for `n`/`N` anyway.

**Content inside a folded node.** `rows` skips a closed node's body and the
whole nested run beneath it, so no row exists to search — a search cannot see
into a collapsed `<details>` or a comment you folded away. This is the bigger
half. It means searching the nodes rather than the rows: each `Node` holds its
`raw`, and `nodelines` has already computed `srcs` for any node that has been
rendered at the current width (a never-opened one has not, so it would have to
be rendered to be searched, which is the cost).

Then a hit has to be *revealed*, and folding is depth-based rather than
structural: there are no parent pointers, so opening the node holding the hit
means also walking backwards to the nearest preceding node of each lower depth
and opening those too, or the run stays hidden. Opening anything renumbers every
row, so the sequence has to be: find the node, open it and its ancestors,
rebuild the rows, then locate the row. Worth deciding whether a search should
change fold state at all, or instead report "3 matches in folded blocks" and
leave the opening to you.

### Long node headers are cut, not wrapped
A comment's header is the byline plus a peek at the body — and for a review
comment, now also the file and line it points at. `rows` runs it through `afit`,
so on a narrow pane it is truncated mid-sentence with an ellipsis instead of
wrapping onto a second row. Seen on julia#18004, whose headers run to 91 columns
before the pane is even involved.

The work is not the wrapping, it is that `rows` currently emits exactly one row
per node header and several things rely on it: `headerrow` takes the first match
(fine), the fold-marker hit test treats columns 1-2 of any header row as the
marker (a continuation row would toggle the fold, which probably wants
restricting to the first row), and the `▾`/`▸` marker itself should not repeat
on continuation rows. `Row` already carries `part`, which is exactly the flag
needed to tell them apart.

### Code blocks in comments are boxes, and long lines break them
Term draws a fenced code block as a bordered panel sized to its longest line,
not to the width it was asked for. A pasted gdb log or stack trace routinely
runs to 130-250 columns, so in a 96-column pane the panel is wider than the pane
and `awrap` hard-breaks it: the left border, some content, then the rest of that
line on the following rows with the closing border landing in the middle of
nothing. Distributed.jl#196 is the case to look at - its longest log line is 135
columns against a 91-column panel.

The content is readable; the box is the problem. Options, roughly in order of
how much they change: stop letting Term draw the panel at all and render a
fenced block as plain indented text, clipped at the pane width with the overflow
reachable some other way; or keep the panel and truncate its contents to fit,
which loses the ends of exactly the lines somebody pasted a log to show; or let
a code node scroll horizontally, which nothing else in the pane does.

### Offer the composer to Term.jl
Term has no text input at all - no line editor, no text area, nothing that takes
a keystroke. `EditorView` and `PromptView` are small, and the parts worth having
upstream are the parts that were annoying to get right: the input decoder, which
handles the three spellings terminals use for Alt and assembles UTF-8 from its
bytes; the two readline word rules, which genuinely differ; and the
cursor-to-wrapped-row mapping, which is what makes a soft-wrapped text area
behave.

What would have to be untangled first, none of it deep:

- They are `View`s, so they assume this program's controller - `render(v, w, h)`
  returning a string, `handle!(v, k, ctrl)` returning an action, and a caller
  that owns raw mode. Upstream would want the editing model separated from the
  view, so a `TextBuffer` with `insert!`/`delete_word!`/`move!` could be driven
  by whatever loop the user already has.
- They draw with `apad`/`afit`/`awrap` from `ansi.jl` rather than with Term's
  own measuring, because Term measures markup instead of what prints
  (invariant 9). Upstream that is backwards: it should use Term's measurement,
  which means the box-drawing has to be rewritten against `Panel` - and `Panel`
  is exactly the thing that could not be trusted here.
- `^o` shelling out to `InteractiveUtils.edit` needs the caller to hand back the
  terminal for the duration. That is `suspend`, and it belongs upstream too,
  since anything holding raw mode has the same problem.

They have been asked before: **FedeClaudi/Term.jl#131**, "How To Accept User
Input?" (Jul 2022), someone wanting to type into a `Panel`. It was closed
without one, and the discussion ends on the two approaches they could not choose
between - so the appetite exists and the shape is the open question, which is a
good position to arrive with a working implementation.

Worth reading first, since they bear on how much of ours would be welcome:
**#119** "Style information is dropped on wrapped lines" (closed) is the bug our
escape replay exists to avoid, and **#247** "TextBox line wrapping bug" (open,
Mar 2024) is still open with the maintainer saying text wrapping "has been hard
to fix".

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
  nothing and `Tab` cycles only the list and the detail, so nothing in it can be
  acted on where it is shown: `L` toggles a label from anywhere, but there is no
  way to assign a reviewer, or to open the check your eye is actually on.
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
- Every write. Posting a comment, replying in a thread, commenting on a source
  line, submitting a review, toggling a label: all five are written and none has
  ever been sent, because the token here cannot. The shapes of the requests are
  from the REST docs, not from a response.
- `^o` in the composer, end to end. `suspend` is tested to run its body and put
  the alternate screen back, and the reader is armed one event at a time so it
  is not on the tty while a child runs - but no editor has actually been
  launched from inside the browser here.
- Which spelling of Alt this terminal actually sends. All three are decoded and
  each is tested from an `IOBuffer`, but which one arrives is a property of the
  terminal and its settings - and on a Mac, Option may be composing characters
  rather than sending Meta at all, in which case none of them arrive.
- `^s` in the composer. Ctrl-S is XOFF under terminal flow control; raw mode
  should be clearing IXON, which has not been confirmed against a real tty.
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

- **A PAT, for two separate things.** `origin` is now
  `vtjnash/git-worklog` and is readable, but its `master` is still at the last
  commit made before any of this - pushing has never been attempted, and the
  sandbox's App token is read-only for contents everywhere, so it is expected to
  fail. That needs `Contents: read/write`. Writing a review needs a *different*
  pair of permissions on the repositories being reviewed - `issues: write` and
  `pull_requests: write` - which the same fine-grained PAT can carry but which
  are not implied by the first.
- **Notifications lane.** Decided against: `mentions:` and `commenter:` cover
  the gap through ordinary search, leaving only team mentions
  (`@JuliaLang/compiler`) genuinely unreachable. Revisit only if those matter
  enough to justify a classic PAT, and build it as a durable sync rather than a
  live lane if so.
