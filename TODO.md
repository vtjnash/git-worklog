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
./cli/bin/wl agent julia#62841 "rebase and rerun Compiler tests"
julia --project=cli cli/test/runtests.jl   # everything testable without a TTY
```

The browser's keys divide by case: **lowercase shows you something, uppercase
changes something on GitHub.** `/` searches, `C` composes, `A` reviews, `L`
labels, `r` toggles read, `z` undoes the last local action.

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
7. Braces are markup. `parse_md` doubles them **inside a code span** and
   nothing collapses them, so a signature arrives as `Tuple{{Type{{S{{N, Tup}}}`
   — `render_md` undoes that. In prose it does *not* double them and
   `apply_style` *deletes* them as an unknown tag, so `escape_source` doubles
   them first. Both paths end at one brace; neither may be removed alone.
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

**Markdown (Julia's stdlib)**
11. `Markdown.parse` opens emphasis on an underscore inside a word, which
    CommonMark forbids, so `deliver_result and connect_to_peer` loses both
    underscores and italicises what is between them. It takes two to pair, so a
    single identifier looks fine and a real comment does not. Every parse goes
    through `escape_intraword` first.

**Buildkite** (see the `buildkite-logs` skill for the endpoint shapes)
12. Job discovery must use `/data/jobs`; the per-build JSON returns an empty
    jobs array to an anonymous caller, with no error.
13. Logs are HTML — drop `<time>` elements *before* stripping tags, and decode
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

### File the intraword-emphasis bug upstream
`deliver_result and connect_to_peer` renders as `deliverresult and
connectto_peer`. Every snake_case name in a comment that was not written inside
backticks loses characters — which is most of them, since people type function
names as prose.

**It is Julia's `Markdown`, not Term.** Term was the first suspect and is
innocent; `parse_md` passes the text through untouched. The mangling is already
in the AST:

```julia
julia> Markdown.parse("call deliver_result and connect_to_peer here").content[1].content
3-element Vector{Any}:
 "call deliver"
 Markdown.Italic(Any["result and connect"])
 "to_peer here"
```

Note it takes **two** underscores to pair. `deliver_result` alone comes back
intact, which is why a one-word test looks fine and a real comment does not —
worth putting in the report, since it is what makes the bug easy to miss.

CommonMark forbids this: a `_` may open emphasis only if it is left-flanking and
either not right-flanking or preceded by punctuation. An underscore with a
letter on both sides is both-flanking and unpunctuated, so it cannot open —
which is why GitHub renders `snake_case_name` literally and we do not. The
disagreement is with the page the comment came from.

**Not filed yet, and there is no existing issue.** Searched JuliaLang/julia for
markdown + emphasis/underscore/intraword/italic; the closest is #57265, which is
`@md_str` interpolation and closed as a duplicate of something else. `Markdown`
is still a stdlib inside JuliaLang/julia (`stdlib/Markdown`), so that is where it
goes, with the snippet above.

**The workaround has shipped** — `escape_intraword` escapes such an underscore
before `Markdown.parse` sees it, skipping fenced blocks, indented blocks and
inline code spans, where a backslash would print. So this repo is no longer
waiting on the fix; what remains is filing it, so that everyone else's rendered
docstrings and READMEs stop losing characters too.

### File the brace bug on Term.jl
`a Tuple{Type{S{N}}} sig` printed as `a Tuple sig` — the type silently deleted,
not mangled. Term's markup is `{...}` and `apply_style` consumes anything shaped
like a tag, and `parse_md` does not escape the braces it passes through from
prose. It *does* escape them inside a code span, which is what makes this a bug
rather than a design: the same characters are protected in one context and not
the other.

**Worked around here** — `escape_source` doubles them before `Markdown.parse`,
which is Term's own escape (`Term.escape_brackets` does the same), and the
doubling survives `parse_md` for `render_md` to collapse. It cannot be done to
`parse_md`'s *output*, where Term's own tags live as braces.

**Not filed.** FedeClaudi/Term.jl. Prior art to cite, both closed and both the
same bug when the markup delimiter was `[...]`: **#59** "escape style brackets",
where the maintainer said the next version would ignore doubled brackets, and
**#84** "Term removes bracket `[...]`". Neither covers `parse_md` failing to
escape what it emits, which is the actual report:

```julia
julia> apply_style(string(Term.TermMarkdown.parse_md(
           Markdown.parse("a Tuple{Type{S{N}}} sig"); width = 80)))
"a Tuple sig\e[0m"
```

Goes alongside the intraword-underscore report above — the same failure, one
markup layer each, both consuming characters that were text.

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

### Agent integration — push an item into an agent and get it back

**Now largely built** — see *A tmux-backed pane, as a widget* below, whose
stage 4 is this entry. What follows is the shape it was planned in; the one part
still missing is step 4, taking the result.

In place today:

- `agent_task` in `state.toml`, set by `wl agent <ref> "..."` (aliased to
  `agent_task` in `state.jl`'s `ALIAS`).
- setting it forces the item into the `needs-agents` bucket — `refresh.jl`'s
  rule is literally "you queued an agent task" — and it counts as *claimed*, so
  the item stops being treated as untriaged backlog.
- the metadata pane prints it under `agent`, and the browser has no key to set
  or clear one; that goes through `wl agent` on the command line.

So an item can be marked as wanting an agent, and nothing more happens. The task
text is a note to yourself.

What integration would mean, roughly in order of how much has to be decided:

1. **Launch one.** Given an item and its `agent_task`, start an agent with the
   repo checked out at the PR's branch — `repos.jl` already maps a repo to a
   local checkout and finds a worktree on a given branch, which is what `e`
   uses. The prompt has the item, its thread and its diff available; all three
   are already fetched and cached.
2. **Keep it.** A session per item, resumable, so an agent can be left running
   and returned to. Naming it from the item (`wl-julia-62841`) makes the session
   store itself and leaves only the mapping to persist, which fits the
   `state.toml` pattern — a `review_session` field beside `agent_task`.
3. **See it.** The metadata pane is the obvious place for "running / finished /
   failed", and it already fetches per-item state lazily on the async path that
   `load_meta!` established.
4. **Take the result.** An agent that produces a diff or a comment draft has
   nowhere to put it yet; the composer (`C`) is where a draft would land, and it
   already accepts initial text.

**tmux is available here after all; the rest of the stack still is not.**
Rechecked 2026-09-02. `claudebox`, `docker` and `podman` are still absent from
`PATH`, ClaudeBox.jl is in no environment here, and `$TMUX` is unset, so the two
questions that were open before still are: whether ClaudeBox.jl can launch
non-interactively into an existing pane, and whether sandbox-in-sandbox works at
all. Both remain answerable only on the host.

tmux itself, though, is one `Pkg.add` away: **`tmux_jll` ships 3.5a as an
artifact**, needing no apt and no build. Do not use the Debian package — it is
3.1c, its `libutempter0` postinst cannot chown under this sandbox, and 3.1c
drops OSC 8. Run the JLL binary through `tmux_jll.tmux()`, or with the
`LD_LIBRARY_PATH` that carries.

Verified on 2026-09-02, with the browser itself running in a pane:

- **Headless works with no tty at all.** `tmux new-session -d -s wl -x 120 -y 40
  -- ./cli/bin/wl` starts a server from a pipe-only shell, and the session
  outlives the process that made it. Size is per-session and settable at will;
  `new-window` has no `-x`/`-y` in 3.5a either, so it is one session per size.
- **`capture-pane -p` returns the rendered frame** — both panels, box-drawing,
  wide CJK and emoji intact. `-e` adds the SGR escapes, and on 3.5a keeps OSC 8
  hyperlinks; 3.1c returns the link text with the URL dropped.
- **Input goes in blind.** `send-keys` for keys, and raw SGR mouse as
  `send-keys -H 1b 5b 3c 30 3b 31 30 3b 36 4d` — that clicks row 6, and the
  browser selects the item under it.
- **Control mode is the transport to build on.** `tmux -C attach` over two pipes
  is one long-lived client: commands go in as lines, replies come back framed in
  `%begin`/`%end` by command id, and screen updates arrive unsolicited as
  `%output`. No process per key, and keys batch (`send-keys j j j j j`).
  `%output` carries the application's own bytes, so OSC 8 survives there on any
  version.
- **Redraw on any update; do not wait for the screen to settle.** `%output` is
  a wake-up and every `capture-pane` returns a coherent grid — tmux hands back a
  whole consistent screen, so there is no tearing to guard against. Paint the
  frames as they arrive. One `j` produced three, at 27ms, 307ms and 609ms: the
  first already had the selection moved and the status on `loading julia#36605…`,
  the last had the comment body filled in. That progression is what a human sees
  anyway. A capture costs ~1ms through the control-mode client and ~5ms as a
  separate process, so it is affordable at any frame rate worth having.
- **Settle detection is only for wanting one final frame**, as a scraper might.
  It takes two phases: wait for the first output *after* the input, then for the
  stream to go quiet. Neither half works alone — quiet fired at 350ms before the
  app had written a byte, and two matching `capture-pane` frames declared the
  screen settled at 100ms with four keys still buffered.

The same machinery is worth more than agents: a pane that runs *any* program and
is scraped back is a general widget, and it means `e` could open a real `vi`
without the browser having to understand or translate a single keystroke. That
is the shape to offer Term.jl; it is planned just below.

### A tmux-backed pane, as a widget

A pane runs any program, `%output` says when it changed, and `capture-pane`
hands back a coherent frame. Nothing in that is about agents, and the widget it
implies — one that owns a child program and never interprets it — is what makes
`e` able to open a real `vi`. An agent is then just another child.

The browser is already the right shape to host it. `controller.jl` owns stdin
for the whole run and dispatches to a `View` with `render(v, w, h)`,
`handle!(v, k, ctrl)`, `onmouse!` and `onwake!(v)`; a landed fetch calls
`wake!(ctrl)`, which is precisely the signal `%output` gives. So the widget is a
`View` whose render is the last captured frame and whose wake is a pane update.

Three things have to be built, and only the third is a real design problem.

- **A control-mode client.** One `tmux -C attach` per session over a pipe pair,
  replies routed by the `%begin`/`%end` command id, `%output` forwarded to
  `wake!`. It is pure IO over pipes, so it tests with no terminal, like
  everything else here.
- **Sizing.** A pane is a whole session, because `new-window` has no `-x`/`-y`
  in any version. The widget owns a session sized to its inner area and resizes
  it with `refresh-client -C <w>,<h>` when the terminal changes.
- **Raw input, which is the hard part.** `readevent` decodes bytes into
  `KeyEvent` and `MouseEvent` precisely so that views deal in characters. A
  pass-through pane wants the opposite — the bytes as typed, handed to
  `send-keys -H` untouched — and re-encoding a decoded key back into bytes would
  reintroduce the translation this whole design exists to avoid. The controller
  needs a way for the top view to ask for undecoded bytes: a `wantsraw(v)` the
  reader consults and a `RawEvent` beside `KeyEvent`, plus one key held back as
  the escape hatch, since every other key now belongs to the child.

The stages, each of which stands on its own:

0. **Full-screen handoff, no widget. Done 2026-09-02.** `mux.jl` holds the
   session bookkeeping — `mux_bin`, `mux_session`, `mux_start`, `mux_alive`,
   `mux_kill`, `mux_sessions` — and `t` opens a shell on the item's checkout in
   a session named after it, through the `suspend(ctrl)` that already drops raw
   mode and leaves the alt screen. Leaving the session is not ending it: press
   `t` on the same item and the same shell is still there. `WORKLOG_TMUX`
   overrides `PATH`, which is how it is tested where the only tmux is an
   artifact in the depot. Two things worth keeping:
   - **tmux rewrites `.` and `:` in a session name to `_` without saying so.**
     `wl-Distributed.jl-198` is created as `wl-Distributed_jl-198` and then
     cannot be found under the name it was asked for, so `mux_session` does the
     same substitution and holds the name the server holds.
   - **`-t=name` is the exact form**; plain `-t name` is a pattern, and an item
     whose name extends another's would answer for it.
1. **The control-mode client. Done 2026-09-02.** `MuxProto`/`mux_feed!` parse
   the protocol, `MuxClient` wires one `tmux -C attach` to a process pair, and
   `mux_ask`, `mux_capture`, `mux_resize`, `mux_keys` sit on top. `mux_feed!` is
   a pure function of one line and the state before it, so the protocol is
   tested from a vector of strings the way `readevent` is tested from an
   `IOBuffer`; the live half of the testset skips when there is no tmux. Read
   against the running browser it returns 40 lines with 13 OSC 8 links intact,
   and every line already measures within the width, so `astrip` and `awidth`
   handle captured text as-is. Three things cost time and would cost it again:
   - **Attaching answers with a reply block of its own**, before anything has
     been asked. Left in the queue it puts every later reply one behind: the
     first `capture-pane` returns empty and the *next* command returns the
     screen, which reads as a capture that failed rather than a stream that has
     slipped. `mux_sync!` drains up to a token nothing else could produce,
     rather than a fixed number of blocks, so a version that emits a different
     number of them changes nothing.
   - **Do not quote the target.** Control mode does its own quote handling:
     `-t='=name:'` comes back *successful and empty*, and `-t '=name:'` fails
     looking for a session called `=name`. Unquoted `-t =name:` is right, and
     the `=` exact form takes a session on `has-session` but wants the trailing
     colon anywhere a pane is the target.
   - **`%output` escapes only bytes below 0x20 and the backslash**, as three
     octal digits — a tab is `\011`, a backslash `\134`. DEL and UTF-8
     continuation bytes pass through raw, so `mux_unescape` works on bytes and
     leaves anything it does not recognise alone.
   A line inside a reply block is content and never protocol, or a captured
   screen with a `%` at the start of a line would parse as a notification and
   vanish from the reply.
2. **A read-only `PaneView`. Done 2026-09-02.** `paneview.jl` holds a `View`
   whose `render` is the last captured frame and whose `onwake!` is a pane
   update, so `%output` reaches it by the same path a landed fetch does. `t`
   now starts the session and pushes the pane; `q` leaves it running, `K` ends
   it, `r` re-reads it, and `a` hands the terminal over full-screen, which is
   the only way to type into it until the next stage.
   - **The child is sized, not just the box around it.** `pane_box` is
     `(w-4, h-3)` — two rows of border, one for the footer, four columns of
     border and padding — and `pane_sync!` sends `refresh-client -C` when that
     changes. It reads `displaysize` itself rather than taking the size from
     `render`, which stays pure; with no tty that is `LINES`/`COLUMNS`, so the
     resize path is drivable from a test.
   - **Close every captured row.** A row ending mid-colour runs out of the
     content and into the pane's own border and padding, so each one gets a
     reset appended.
   - Every row is padded to exactly `w` and the frame to exactly `h`, the same
     invariant the other views are held to.
3. **Raw pass-through. Done 2026-09-02.** `wantsraw(v)` and `RawEvent` beside
   `KeyEvent`, `readraw` in the controller, `onraw!` on the view. The reader is
   armed with the top view's mode from the loop, where the top view is known —
   deciding it in the reader would decide it against whatever was on top last
   time, since the reader is parked between events. `PaneView` forwards the
   bytes to `send-keys -H` and interprets none of them, so a mouse report and a
   paste need no more code than a letter does.
   - **Proven by driving `vi`**: `G`, `o`, text, a literal escape byte and
     `:wq\r` went through as bytes and the file on disk changed. Nothing in the
     browser named a key or parsed a sequence.
   - **Ctrl-] is a prefix, not an escape.** Everything else belongs to the
     child, Escape and Ctrl-C included, so the way in cannot be a key a program
     would want. It had to become a prefix because an escape key alone left
     everything else the view can do — killing the session, going full screen —
     reachable only after the child had died, which was a hole. `^] tab` leaves
     (the browser already uses `tab` to change pane), `^] K` ends it, `^] a`
     goes full screen, `^] r` re-reads, `^] ]` sends a literal Ctrl-].
   - **`tab` itself is not the prefix.** It is the most-pressed key in a shell
     and completion would cost two presses for the rest of time; checked that a
     literal tab still reaches `vi` through the pane.
   - `readraw` blocks for one byte, then takes what has already arrived. That
     draining never waits, so it cannot hang the way polling for input would,
     and it is what keeps a sequence together and in order.
4. **The agent on top. Mostly done 2026-09-02.** `T` runs `claude` on the
   item's `agent_task` in a session of its own, in the checkout `item_checkout`
   picks, prompted with the item and its URL, and shows it in the same pane
   everything else uses. Verified by running a real agent in it and watching it
   answer. `t` and `T` are separate sessions — `wl-julia-62841` and
   `wl-julia-62841-agent` — so a shell and an agent can both be open on one
   item.
   - **`review_session` in `state.toml` turned out to be unnecessary**, and
     so did keying anything on the item; see the entry below.
   - **The metadata pane reports a running session** from a list cached by
     `load_meta!` on the async path. Listing them costs a process, and `render`
     is pure and runs per frame, so it cannot be the thing that asks.
   - **The task is shell-quoted** (`shquote`). It is a sentence someone typed,
     interpolated into a command tmux hands to `sh`, so an apostrophe in it
     would otherwise break the launch.
   - **Taking the result needs nothing.** It was carried as outstanding for
     half a day: an agent that had written a diff or a draft had "nowhere to
     put it". It has somewhere — press `T` and read it, and type the reply
     there. The pane is not a display of the agent, it is the agent, and input
     in it is as user-driven as input anywhere else.
   - **Starting one needs nothing either.** `T` required an `agent_task` and
     refused without one, which made the agent reachable only through a field
     the workflow has no reason to fill in — it exists to pull an item into the
     `needs-agents` bucket — and left `T` refusing to connect to a session
     sitting right there. Now it just connects.
   - **Nothing is said to the agent on the way in.** Not the task, and not the
     checkout: an agent already reads its working directory and branch from its
     own system prompt, so anything added would be a second, staler copy of
     what it can see. Staler matters here because a system prompt survives
     `/clear` — checked, not assumed — so it would outlive every correction
     made from inside, on a session that gets pointed at a different item.
   - The three things it is actually for — `/review`, reading a buildkite log,
     making the edit — are all typed in the pane, and none of them want to be
     preceded by a reply to a preamble.
   - **A child must be started standalone, or it joins the parent's bridge.**
     Remote Control looked uninvolved — it is opt-in per invocation
     (`--remote-control`) and no setting turns it on — and that was the wrong
     place to look. A child started from inside an agent inherits the whole
     `CLAUDE_*` family, `CLAUDE_CODE_MESSAGING_SOCKET`, its token and
     `CLAUDE_CODE_BRIDGE_SESSION_ID` among them, and joins that bridge without
     any flag being passed: agents launched in a pane showed up in the parent's
     remote list for as long as they lived. The same inheritance silently turns
     the child's transcript saving off. `standalone` scrubs whatever this
     process actually holds — the identity when it holds none, so it costs
     nothing when the browser was started from a plain terminal. Verified by
     reading a child's environment back: ten such variables here, none in it.

4b. **The session list. Done 2026-09-02.** `"` opens a `SessionView` over
   every `wl-` session: what kind it is, which item it belongs to, what is
   running in it, and whether anyone is attached. `\u21b5` opens one in a pane,
   `K` ends it, `r` re-reads. A session outliving the view of it is the point,
   and the cost of that is that they pile up somewhere unseen; this is the
   somewhere.
   - `mux_list` is one call, filtered to the active pane of each session, and
     the view holds a snapshot — `render` is pure and per-frame.
   - **Sessions are matched to items by generating names and comparing them.**
     `mux_session` keeps only the short half of the repo, so `julia` cannot be
     turned back into `JuliaLang/julia` without guessing; `mux_parse` recovers
     enough to label an orphan, and nothing more.

4c. **A session belongs to a worktree, not to an item. Done 2026-09-02.**
   Keying on the item was wrong, and wrong in a way that could not be seen: a
   session records the item but `item_checkout` decides *where* at launch time,
   so once a worktree exists for the branch, `mux_alive` says the session is
   there and `t` reattaches to a shell in the wrong directory. Two items both
   falling back to the main checkout got two sessions in one place, and either
   could change the branch under the other.
   - **Identity is `@wl_worktree` and `@wl_kind`, tmux session options.** The
     worktree is what is actually shared, and the kind because a shell and an
     agent in one checkout are two different things. Options survive a rename,
     which a name cannot: a branch gets renamed, a different item gets opened.
   - **The name is a label**, `wl-<worktree>-<branch>-<ref>`, all three because
     each answers a different question and the list is unreadable without any
     one of them. `/` survives, so a branch keeps its owner prefix.
   - **Both kinds are renamed to whatever item was last opened on them**, and
     there is one code path for the two. An agent looked like the exception —
     it has a task, where a shell is only a place — and it is not one: an agent
     can be cleared and pointed at something else as easily as a shell can be
     `cd`-ed, and the pane is where that happens. Coming back to a session that
     was on another item says so in the status line, which is information and
     not a refusal; the session is yours to redirect. All that differs between
     the kinds is what gets run when there is nothing there yet.
   - Two agents editing one worktree is still impossible to express, which is
     the point of keying on the worktree, but that falls out of the key rather
     than needing a rule of its own.
   - **`@wl_item` is neither name nor identity.** It is what the metadata pane
     matches on, so an item can be told a session exists for it without the
     pane working out which worktree it would land in — that costs a `git`
     call, and the pane redraws per frame.
   - Sessions are matched in Julia rather than with a tmux filter expression: a
     path can contain the characters a format string is made of, and a comma in
     a checkout's name would otherwise quietly match nothing.

4e. **Reading beside the child. Done 2026-09-02.** Above 150 columns the
   detail pane keeps the left and the child takes the right, half each within
   bounds, so a thread or a diff stays readable while a build runs. Below that
   there is no split: two columns too narrow to use are worse than one that
   works.
   - **The detail pane alone, not the browser shrunk.** Drawing the whole
     browser narrow was the first attempt and it was wrong: while the child
     holds the keys the browser cannot be scrolled or moved, so the list beside
     it is a list nothing can be done with — and it cost the thread three
     quarters of its rows. `detail_pane` came out of `render_frame` for this,
     unchanged otherwise, which the existing frame tests were enough to
     confirm.
   - The child is sized to its own column, not the screen, and `beside` is
     taken from the bottom of the view stack, so a pane opened by `t`, `T` or
     the session list all get the same thing next to them.
   - **`^]a` inside tmux needed `switch-client`, not `attach`.** tmux refuses
     to nest an attach, so the key did nothing on a host where the browser is
     itself run inside tmux — which is the normal case. Attaching still applies
     when there is a terminal to give away; inside tmux the client we are
     already under is pointed at the other session and returns at once, and
     tmux's own binding brings it back.
   - Key hints are written `^]a` and not `^] a`: in a line naming several of
     them, a lone `a` reads as a word.

4f. **Surviving a bug, and the cursor. Done 2026-09-02.** Two things a live
   session found that no test had.
   - **An uncaught error ended the run**, taking raw mode, the alternate screen
     and every open pane with it — a bad trade when nearly every such bug costs
     one frame. `safe_render` and `safe_dispatch!` catch, append to
     `errors.log`, and carry on; the same error is written once, since a bug on
     the render path runs every frame. The file *is* the warning: the footer
     says so while it exists and deleting it is how the warning is dismissed, so
     a bug cannot be quietly lived with. The note names the file relatively and
     puts the instruction first — with the absolute path in it, `afit` cut the
     sentence before "delete" and left a warning that said something was wrong
     without saying what to do.
   - **The bug it caught was mine**: `load_meta!` still fetched `mux_sessions()`
     — names — into a field that had become what `mux_list()` returns. Every
     test set `st.sessions` by hand, so none of them ever ran the fetch. There
     is now one that does.
   - **The child's cursor has to be drawn.** `capture-pane` returns the grid and
     says nothing about the cursor, and the real one is hidden for the whole
     run, so a scraped child had none at all. `mux_cursor` asks for it and
     `cursor_frame` inverts that cell, in reverse video rather than a colour so
     it reads as a block over whatever was underneath — which is why `hlspan`
     learned to close a span with something other than a background reset.
   - **A tmux format must be quoted and a target must not.** `#` starts a
     comment in tmux's command syntax, so an unquoted `#{cursor_x}` is
     discarded and the default message comes back — successfully, about the
     session rather than the cursor. A quoted *target* meanwhile succeeds and
     matches nothing. The two rules are opposite and both are silent.

4d. **Next: drop `agent_task`, and give the notes a place instead.** Nothing
   launches from it any more, so what is left is a `state.toml` field whose
   only remaining job is to force an item into the `needs-agents` bucket. That
   bucket, `wl agent`, the `agent` block in the metadata pane and the
   `refresh.jl` rule all go with it. What people actually want that field for
   is somewhere to keep a prompt they are drafting, which is a private note and
   not a piece of workflow state — so a notes editor, on the `note` field that
   already exists, is the replacement. Not started; it changes the dashboard's
   buckets, so it wants doing deliberately.

5. **Offer it upstream.** Only after it has carried `vi` and an agent for a
   while, and only backend-shaped rather than tmux-shaped. On Windows `psmux`
   claims the same control mode (`-C`/`-CC`, with `capture-pane` and
   `send-keys`), and wezterm has the same two primitives under other names —
   `wezterm cli get-text --escapes` and `send-text`, against a headless
   `wezterm-mux-server`. Neither is verified: there is no Windows in this
   sandbox. Treat it as a reason to keep the seam, not as a promise. `tmux_jll`
   covers macos, linux and freebsd only, so a Term.jl dependency would have to
   be optional in any case.


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
- **A snooze cap is measured from when it was armed, not from when you set it.**
  `snooze.json` records the time the fingerprint was first taken, which is the
  next refresh after the value appears in `state.toml` — close enough for a
  thirty-day cap, wrong if you wanted the day you typed it. Entries written
  before arming times existed adopt one on first sight rather than counting as
  infinitely old, so an upgrade wakes nothing.
- **A row whose text is not a piece of its source cannot mark a match exactly.**
  `row_span` locates a row inside the line it came from by looking for it, which
  works because wrapping only ever cuts. A URL footnote row breaks that: it
  shows an elided form and its source is the whole URL. Those fall back to
  marking whatever of the query is visible on the row, which is the old
  behaviour and is right for them.
- **A fenced code block is a node, not part of its comment.** Lifting it out of
  the markdown is what stops Term boxing it. It keeps its place in the reading
  order and folds away with the comment above it, but it costs a header row of
  its own and carries its own fold state, and one over a dozen lines starts
  closed — so a short snippet reads as a labelled block rather than as part of
  the sentence around it.
- **A code span Term wrapped gets no background.** `style_code_spans` pairs
  delimiters within a line, and Term breaks a long span across two — so those
  fall back to a dim backtick. Drawing a background across the break would need
  the span to be known before wrapping, which is Term's side of the line.
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
- `⌥e`/`^o` in the composer, end to end. `suspend` is tested to run its body and put
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
  lines *inside* an edited block. This matched the Python exactly. Note the
  block's own trailing blank counts as inside it — `block_span` runs to the next
  `[`, so the separator before the next block goes too, and `state.toml` grows
  denser as blocks are edited. `z` therefore restores the *value* exactly and
  the file only nearly: undoing a snooze leaves the key as it was and the blank
  line gone.
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
