# TODO

## Resuming work

Read this first if you are picking this up cold.

### What it is
A personal GitHub work dashboard for `vtjnash`, in Julia. It buckets ~2100
items - own PRs, review requests, assigned issues, recently merged or closed
ones, personal and team mentions, comment history, and every open
JuliaLang/julia PR as a background pile - tracks which threads are unread so
per-event email notification can stay off, and browses them in a terminal UI of
three panes: the item list, its metadata, and the thread or diff.

Beyond GitHub it also knows about *local* work: a branch with no pull request
can be adopted and becomes an item like any other, and finished work is archived
rather than deleted.

It also hosts programs. A tmux session per worktree can be opened on an item
(`t` a shell, `T` an agent), drawn in a pane beside the thread and driven by
forwarding the bytes you type, so the browser needs no model of what is running
in it. `"` lists every worktree and what is running in each, and `v` opens the
item's note in `$EDITOR` in a pane of its own.

### Where and how to run it
The checkout is wherever the sandbox mounted it - it has been at
`/root/.claude/worklog` and at `.../claude_home/git-worklog`, so take the path
from `git rev-parse --show-toplevel` rather than from here — **but run that from
the code checkout, not from inside `data/`, which is a git repository of its
own and will answer with itself.** It persists; the rest of the home directory
is a throwaway overlay. `origin` is `vtjnash/git-worklog` (see Infrastructure -
pushing has never been tried).

```bash
cd "$(git rev-parse --show-toplevel)"
./cli/bin/refresh              # fetch, bucket, write DASHBOARD.md  (~30s)
./cli/bin/refresh --firehose   # force the 6-hourly bulk lanes too  (~6min)
./cli/bin/wl                   # the browser (needs a TTY)
./cli/bin/wl show julia#62841  # non-interactive thread view
./cli/bin/wl next 10           # pull untagged backlog to triage
./cli/bin/wl watching          # repos you watch, and which are tracked
./cli/bin/wl import <url>...   # follow items, landed unread; `i` in the browser
                               # is the same thing, one at a time
cat urls | ./cli/bin/wl import -    # `-` is "read them from stdin" everywhere:
printf '%s\n' julia#1 julia#2 | ./cli/bin/wl snooze - 3d
julia --project=cli cli/test/runtests.jl   # everything testable without a TTY
```

The browser's keys divide by case: **lowercase shows you something, uppercase
changes something on GitHub.** `/` searches, `C` composes, `A` reviews, `L`
labels, `r` toggles read, `s` asks how long to snooze for, `w` sorts by when you
last acted, `x` archives, `z` undoes the last local action. A click on a url
copies it, whole even where the wrapping cut it.

`'` is the named views - six built in, more from `config.toml`, and its last
entry copies the current filter as the TOML that would name it - and `` ` ``
goes back to the filter you were in before. `f` opens the filter pane, whose
states are `active` / `unread` / `mine` /
`second look` / `touched` / `snoozed` / `backlog` / `archived` / `all`, with a second radio group
for issues, pull requests or both, and checkbox axes for category, repo, label
and author — each long one listing its head and offering the rest as a picker
you type into.

Two ways in for work no lane returns: `i` imports an item by url, and so does
`↵` on the row above the first item, which is the only row in the list that is
not one. Either way it lands **unread**, and importing something the dashboard
already carries adds no second row - it marks it unread again, which is what an
import of it means. Much of what gets imported is like that: an old issue in a
repo that is tracked anyway, or a pull request of yours in one that is not.

Reviewing: a drag over a diff makes `c` a comment on that range, `^r` in the
composer drops in GitHub's suggestion block filled with the lines it would
replace, and the comments accumulate into a **draft review held on GitHub**
rather than posting one at a time. `A` sends it, and leaving the item asks
whether to - "leave it" keeps the draft and re-asks the next time you walk off
it, since nothing but this program mentions one anywhere else. Existing review
comments are placed against the hunk they point into, with a resolved thread
folded away under it rather than dropped.

`v` edits the note in a pane, `t` and `T` open a shell and an agent on the
item's worktree, and `"` lists every worktree with what is running in each -
`tab` there swaps the worktrees for the branches, `i` goes to a row's pull
request, and `a` adopts a local branch as work of yours; its one-character
columns (`san`, `+*`, `●`) are spelled out in a legend under the list. Inside a
hosted pane every key belongs to the child except the prefix `^]`: `^]tab`
leaves it running, `^]K` ends it, `^]a` goes full screen, `^]r` re-reads, `^]]`
sends a literal `^]`.

Use the `julia` on PATH (juliaup, 1.14-DEV). The in-tree
`/home/vtjnash/julia/usr/bin/julia` does **not** run in this sandbox — it is
linked against a newer glibc.

### Layout
| file | role |
|---|---|
| `cli/src/gh.jl` | GraphQL search lanes, shelled through `gh api graphql` |
| `cli/src/events.jl` | the incremental inbox and live thread fetch (submodule `Events`) |
| `cli/src/refresh.jl` | normalize, bucket, fingerprint, snooze, bulk cache, render |
| `cli/src/touched.jl` | the interaction clock: when you last acted on an item |
| `cli/src/state.jl` | the line-based `state.toml` editor, `next` queue |
| `cli/src/controller.jl` | the view controller that owns stdin; input decoding; `PromptView`, `EditorView`, `ChooseView` |
| `cli/src/browse.jl` | the two-pane browser: filters, panes, folding, diffs, checks |
| `cli/src/ansi.jl` | escape-aware width, truncate, wrap |
| `cli/src/ci.jl` | check contexts and Buildkite drill-down |
| `cli/src/repos.jl` | repo → local checkout mapping, the worktree/branch survey, `git show` |
| `cli/src/mux.jl` | tmux sessions and the control-mode client |
| `cli/src/paneview.jl` | a hosted program drawn in a pane; the worktree list |
| `cli/src/cache.jl` | on-disk cache with TTL |
| `cli/test/runtests.jl` | everything testable without a terminal |

**The state lives in `data/`, which is its own git repository.** It stopped
being ephemeral — `read.json`, `touched.json` and `inbox.json` are records of
what has been read, acted on and seen, and `state.toml` holds the notes,
snoozes, adoptions and archives — so it is worth a history, but not the code's:
mixed into this one it buried the diffs that matter and dirtied the tree on
every refresh. `datapath(name)` resolves it; `WORKLOG_DATA` points it elsewhere,
which is how a test gets a disposable one. `config.toml` stays beside the code,
being configuration rather than state.

**Careful: `git rev-parse --show-toplevel` from inside `data/` answers with the
data repo.** Run it from the code checkout, or keep an absolute path.

Owner rules still matter: `config.toml`, `data/state.toml` and `data/repos.toml`
are **yours** — `refresh` reads `state.toml` and never writes it, and only `wl`
edits it, through a line-based editor that preserves comments. The rest of
`data/` is machine-owned, and `facts.json`, `bulk.json`, `cache/` and
`errors.log` are gitignored inside it as re-fetchable or noise. `errors.log` is
written by the browser when something throws, and deleting it is how its
standing footer warning is dismissed.

### The second look
Derived every refresh, never stored, and the opposite of a snooze: it needs no
asking for, because the failure it catches is work going quiet without anybody
deciding it should. It fires on two shapes of silence - the author spoke or
pushed and nobody answered, or somebody approved it and nothing happened after -
measured in *working* days, in a window (`second_look_days` to
`second_look_max_days`, 2 to 20). Below the window nobody is late yet; above it
the quiet is not news and `stale` is the right pile. Only for work you are
carrying: the background pile is full of other people's pull requests where the
author spoke last.

It cuts across the buckets rather than being one - a pull request nobody
answered is still waiting on a reviewer - so it is a filter state and a
dashboard section, not a bucket. A bot commenting after the author hides the
author's comment from `comments(last: 1)`, so that case does not fire rather
than firing on a stale reading.

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
- A hosted pane is tested against a *real* tmux, and those testsets skip
  themselves when there is none. `WORKLOG_TMUX` points at a binary, which is how
  they run in a sandbox where the only tmux is a `tmux_jll` artifact:
  ```bash
  julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("tmux_jll");
            using tmux_jll; println(tmux_jll.tmux_path)'
  export WORKLOG_TMUX=<that path>       # and its artifact LD_LIBRARY_PATH
  ```
  The protocol itself needs none of that: `mux_feed!` is a pure function of one
  line and the state before it, driven from a vector of strings the way
  `readevent` is driven from an `IOBuffer`.
- Time is an argument, so a test says when "now" is by passing it rather than
  by setting a global first: `snooze_active(url, st, fp, snz, at, cap)`,
  `comment_nodes(it, at)`, `handle!(st, key, ctrl, at)`. That is what makes
  "measured from when the operation started" assertable at all — a global could
  not tell that apart from a clock read halfway through the work.
- The suite deletes `errors.log` at startup. The standing warning takes the
  footer's second row, so a log left from a previous run fails every test that
  asserts what is written there.
- The events lane is an **incremental sync**, not a window: `inbox.json` holds a
  cursor per source and everything seen and not yet read. A source seen for the
  first time starts at *now*, so turning one on is inbox zero. `read.json` is
  still what decides an item leaves.
- It takes `owner/*` as well as `owner/name`. A glob is two searches (`is:issue`
  and `is:pull-request` under `user:<owner>`), so it is cheap to add one and it
  truncates at 1000 where a named repo does not.
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
2. GraphQL `search(type: ISSUE)` returns **0** unless the query carries
   `is:issue` or `is:pr`. Found on `assignee:`, and it is not about `assignee:`
   at all — a free-text lane (`"@JuliaLang/compiler" in:body,comments`) returned
   0 through GraphQL and 31 through REST search until `is:pr` was added. Every
   lane must carry one, which is why the team-mention lanes are a pair.
3. A search returning Issues against a fragment that only spreads
   `... on PullRequest` yields field-less `{__typename: "Issue"}` stubs, with no
   error.
4. Search truncates at **1000 results**; JuliaLang/julia is at ~993, so a query
   crossing 950 is re-run partitioned by creation year.
5. `gh api --paginate` is unsafe on a `sort=updated` list — it follows Link
   headers over a reordering collection and silently drops entries (168 vs 612
   on identical runs). Page explicitly with `direction=asc` and dedupe by id.

   **`since=` does not fix this and does not replace it.** The hazard is the
   *direction*, not the window: an item's `updated_at` only ever increases, so
   in ascending order it can only move toward the end — seen twice, never
   skipped — while descending lets it jump back past a cursor already walked.
   What the incremental cursor changed is the exposure: a poll is now one page
   (34 rows over a six-hour gap on all eight sources) so the walk barely runs,
   and because the cursor advances to the poll's *start* rather than to the
   newest row, anything touched mid-fetch is read again next time. Keep the
   explicit paging, keep `asc`, keep the dedupe.
6. A search cursor must carry a *time*, not a date. `updated:>2026-09-02`
   means after the end of that day, so a date-granularity cursor silently skips
   everything that happened today: the same query returned 0 where
   `updated:>2026-09-02T13:00:10Z` returned 1. Search takes the full ISO form,
   so pass the cursor through unshortened.
7. A *successful* response can still be wrong: an `issueCount` of 0 alongside
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

**tmux** (all of these are silent - each returns success and the wrong answer)
14. A session name has `.` and `:` rewritten to `_` without a word, so a session
    is created under a name it can never be found by. `mux_session` does the
    same substitution. `/` is left alone.
15. Targets take the exact form `=name`, and a pane wants `=name:` with the
    colon. Do **not** quote a target: `-t='=name:'` returns success and an empty
    result, `-t '=name:'` fails looking for a session called `=name`.
16. Formats **must** be quoted, which is the opposite rule: `#` starts a comment
    in tmux's command syntax, so an unquoted `#{cursor_x}` is discarded and the
    default message comes back - successfully, about the session rather than the
    pane.
17. Attaching in control mode answers with a reply block of its own before
    anything is asked, which leaves every later reply one behind. `mux_sync!`
    drains to a token nothing else could produce, rather than a fixed count.
18. `%output` escapes only bytes below 0x20 and the backslash, as three octal
    digits. DEL and UTF-8 pass through raw, so decoding works on bytes.
19. `tmux attach` refuses to nest. Inside tmux - which is the normal case -
    `switch-client` is what works, and it returns at once rather than blocking.
20. `$TMUX` decides which server a command talks to, so inside byobu these
    sessions are created on byobu's server and inherit its config.
21. `send-keys` puts bytes into the pane's pty as *input*, so tmux never sees
    them as mouse events and its own `mouse` setting has no bearing. A program
    that never enabled mouse reporting prints the escape sequence. Ask
    `mouse_any_flag` first, and translate the coordinates - they arrive in
    screen space and the child owns a box inside it.

**The terminal**
22. A one-row field must hold one row. `showerror` embeds a newline, and the
    frame is clamped by *element*, so one element holding a newline is two
    printed rows: the screen scrolls and every mouse click reports a row that is
    no longer under it. `oneline` is why.
23. `capture-pane` returns the grid and says nothing about the cursor. The real
    cursor is hidden for the whole run, so a hosted child has none unless
    `viewcursor` puts the terminal's own where the child's is.

**state.toml**
24. The blank line separating one block from the next lives *inside* the block.
    Filtering it out to keep new keys in the right place took a line out of the
    user's file on every write; hold it back and re-append it instead.

**git**
26. `%(upstream:track)` is a *translated* string — `[ahead 3, behind 1]` comes
    through gettext, so in a translating locale it parses as no divergence at
    all, silently. Every git call here is read by this program rather than by a
    person, so `git()` runs them all under `LC_ALL=C`.

**The clock**
25. **The instant an operation is measured against is an argument, `at`, and
    it is when the operation *started*.** There is no global clock; there was
    one, `NOW[]`, frozen at process start, and it was wrong at both ends.

    Frozen is right for a refresh — one instant for every age and expiry, so a
    run cannot straddle midnight and bucket half its items against a different
    day. It is wrong for the browser, which stays open for hours and runs an
    operation per keystroke: `comment_nodes` recorded each thread as fetched at
    the frozen instant, and `r` marks read up to that, so in a session open
    since morning every comment posted since launch stayed unread however
    carefully it had just been read. The cached branch subtracted a real age
    from the frozen instant and drifted further back the longer the session ran.

    Reading a live clock instead only moves the error: an operation that stamps
    on the way *out* claims a moment after things it never saw — a thread whose
    fetch took two seconds would be marked read up to a comment that landed
    during the request. So the start is threaded in, and a long operation and a
    short one are honest for the same reason.

    The rule the signatures follow: **an entry point defaults `at` to
    `utcnow()`; everything it calls takes `at` as a required argument.** A
    default further in is how the second failure gets back in, quietly.

    The same reasoning forbids *storing* a time-derived number. `Item` carries
    `act`, the timestamp it last moved, and `age(it, at)` works the difference
    out when it is asked for. An age computed at load is an age from whenever
    `wl` was started — right for about a day, then quietly wrong — and the
    browser holds its items for the length of a session.

**Buildkite** (see the `buildkite-logs` skill for the endpoint shapes)
12. Job discovery must use `/data/jobs`; the per-build JSON returns an empty
    jobs array to an anonymous caller, with no error.
13. Logs are HTML — drop `<time>` elements *before* stripping tags, and decode
    numeric entities (`&#47;`) as well as named ones.

### Conventions
Commit as `worklog: brief summary`, prose body explaining the purpose (not a
file list, not a test plan), ending with whatever trailer the session is told
to use — currently:

    Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
    Claude-Session: <the session URL>

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

Everything "where the work is" left behind has now shipped; `git log` is the
record of it.

### What review writing still cannot do

`c`, `A` and `L` are wired but unexercised - see Unverified below, and
Infrastructure for the PAT they need. What is missing rather than merely
untested:

- **A comment on a deleted line.** `c` refuses it. The line number is known -
  `hunk_line_at` returns the old-side number and says which side it is - but
  GitHub wants that anchored against the commit the line still existed in, and
  `head_sha` only knows the head.
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

## Issues to file upstream

Kept here so they can be written up in one pass rather than rediscovered.

- **Term.jl: a table inside a list or a block quote is a `MethodError`.**
  `parse_md(::Markdown.Table)` takes `width` and nothing else, while Term's own
  recursion passes `inline` to whatever it finds nested. The fix is one
  `inline = false` in that signature. Worked around locally by `for_term`, which
  moves a nested table into a code block of its own source; a table at the top
  level is left alone, since Term renders it properly there.
- **Term.jl: an empty list item is a `BoundsError`.**
  `parse_md(::Markdown.List)` indexes `[1]` on every item, but Julia's markdown
  parses `- a`/`-`/`- b` into items `[1, 0, 1]`, so any empty bullet throws
  `BoundsError: attempt to access 0-element Vector{Any} at index [1]`
  (`Term/src/markdown.jl:265`). Ordered or unordered, nested or top level, and
  a lone `-` on its own is enough. Caught on 2026-09-02 from a real comment; the
  whole comment fell back to raw text.

  **Worked around here** — `for_term` fills an empty item with an empty
  paragraph before Term sees the AST, rather than dropping it: the bullet was
  typed, so it should be drawn, and dropping one out of an ordered list would
  renumber everything after it. That is the same pass that moves a nested
  table, since both are Term crashing on a shape Julia's parser is happy with
  and each takes a whole comment down.
- **Term.jl: the intraword-emphasis bug** — see its own section above.
- **Term.jl: the brace bug** — see its own section above.
- **Term.jl: a tmux-backed pane as a widget.** Built here and in use: a session
  per worktree, a control-mode client over a pipe pair, a `View` whose render is
  the captured frame and whose wake is `%output`, and input forwarded as the
  bytes it arrived as. Offer it only after it has carried `vi` and an agent for
  a while, and only backend-shaped rather than tmux-shaped — on Windows `psmux`
  claims the same control mode (`-C`/`-CC`, `capture-pane`, `send-keys`) and
  wezterm has the same two primitives under other names (`wezterm cli get-text
  --escapes`, `send-text`, against a headless `wezterm-mux-server`). Neither is
  verified; there is no Windows in this sandbox. `tmux_jll` covers macos, linux
  and freebsd only, so the dependency would have to be optional in any case.

## Known gaps in what has shipped

- **A url sometimes prints where the header of the next node is.** Reported
  2026-09-02 from julia#18004, as
  `https://…#issuecomment-372112478\u25be nalimilan  2018-03-11 …`. **Not the
  rows and not the parser**: over widths 40..200 no header row on that thread
  ever contains a url, and the footnote rows land where they belong. What is
  left is `linkify`, which wraps every rendered url in an OSC 8 hyperlink on the
  *finished frame* — so the url is in the output as the escape's payload, and a
  terminal that does not consume the sequence prints it and swallows what
  follows, which is exactly the shape of the artifact. That fits it only
  appearing in a real terminal, and tmux below 3.4 is one of the things that
  does not forward OSC 8.

  Click-to-copy has since made the hyperlinks unnecessary: `y` copies and now so
  does a click, both through OSC 52, neither needing the terminal to understand
  a link. So `linkify` could go, and with it the underline that marks a link -
  but it is kept for now (decided 2026-09-03) on the grounds that nothing has
  been seen to render wrong since, and the axe is there whenever something does.
  If the artifact comes back, that is the thing to remove.
- **A pane once reported `session ended` with an empty frame, unexplained.**
  Seen once, in a scripted launch on 2026-09-02. The first theory — that the
  wake channel filled and blocked the reader — was tested and is wrong: the
  client survives with 11 of 64 slots used. It has not recurred, including at
  the same shape, so it is recorded as a known-unknown rather than a fixed bug.

- **Hunk context expands against the head commit.** Context around a `-` line
  therefore shows the post-change file, not the pre-change one. Fine for
  reading a change; wrong if you want the base side. Needs a second fetch and a
  decision about which side to show per hunk.
- **Worktree choice is automatic.** `item_checkout` prefers a worktree already
  on the pull request's branch and otherwise falls back to the main clone. There
  is no way to pick a different one — and since a session is keyed by its
  worktree, that choice decides which session you land in as well as which files
  `e` opens. `"` is where every worktree can be seen, made and started in, which
  is most of it; what is left is for `t` on an *item* to ask, rather than
  landing you wherever the fallback went.
- **An adopted branch's merge has no author.** A pull request you merged
  yourself skips the wait before archive is offered, because `mergedBy` says
  who pushed the button. A local branch has no such record: `merged_here` says
  every commit is in the base and says nothing about how it got there, so an
  adopted branch that landed is still news until it has been read. The merge
  commit's committer is where that would come from, and only when the work
  landed as a merge rather than a squash or a rebase.
- **`repos.toml` is never pruned.** Entries pointing at deleted folders are
  ignored at read time but never removed or re-prompted.
- **A long filter axis shows a fixed eight values, whatever the pane height.**
  `AXIS_SHOWN` is a constant, so a tall terminal wastes the room and a short one
  still scrolls. It also orders by weight across the whole dashboard rather than
  within the current filter — deliberately, so the pane does not reshuffle under
  the cursor as the filter changes, but it means the head of the repo axis is
  the same eight whatever else is selected.
- **The metadata pane is a readout, not a control.** Clicking in it does
  nothing and `Tab` cycles only the list and the detail, so nothing in it can be
  acted on where it is shown: `L` toggles a label from anywhere, but there is no
  way to assign a reviewer, or to open the check your eye is actually on.
- **Only the thread and the diff are shown stale while they are re-read.**
  `check_contexts` and the Buildkite logs still have one TTL each, so a check
  pane past its two minutes is a pause rather than a stale frame with a fetch
  behind it. That is defensible - a check that is two minutes out of date is
  wrong in a way a comment thread is not - but it is a difference in behaviour
  between two panes and nothing says so on screen.
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
- Every write. Posting a comment, replying in a thread, adding a line comment to
  a draft review, submitting or discarding that review, toggling a label: all of
  them are written and none has ever been sent, because the token here cannot.
  The shapes are from the docs and, for the four review mutations, from the live
  GraphQL schema - `addPullRequestReview` with `threads` and no `event`,
  `addPullRequestReviewThread`, `submitPullRequestReview` and
  `deletePullRequestReview` were introspected rather than remembered. What has
  run against the real API is the *read* half: `review_state` answers with the
  pull request's node id and no pending review, and `nothing` for an issue.
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
- A hosted pane through a real terminal. Every part is driven directly in the
  tests - `onraw!` with bytes, `render` at fixed sizes, the mouse and cursor
  against a live tmux - but not one keystroke has reached it from an actual tty.
  Specifically unknown: whether this terminal sends `0x1d` for `^]`, and whether
  anything between here and tmux binds it first.
- Which reading of "when" you actually reach for. `w` now cycles three ways —
  as fetched, by when you last acted, by when anything last happened — because
  the two orders answer different questions and neither is righter in the
  abstract. What use would settle is whether one of them should be the *default*
  for a given lane (`mine` and `touched` are the candidates, and they probably
  want different ones), which would mean an order per filter state rather than
  one for the session.
- The split layout at a real width. It is asserted to be `h` rows of `w` at
  several sizes, but how it *reads* at the sizes an actual screen has - and
  whether 150 columns is the right threshold - is a judgement only use can make.

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

- **A PAT, for two separate things — and both are writes.** The notifications
  one below is gone, so this is the only credential still outstanding. `origin` is now
  `vtjnash/git-worklog` and is readable, but its `master` is still at the last
  commit made before any of this - pushing has never been attempted, and the
  sandbox's App token is read-only for contents everywhere, so it is expected to
  fail. That needs `Contents: read/write`. Writing a review needs a *different*
  pair of permissions on the repositories being reviewed - `issues: write` and
  `pull_requests: write` - which the same fine-grained PAT can carry but which
  are not implied by the first. A *fine-grained* PAT carries both; nothing here
  needs a classic one any more.
- **Notifications lane. Dropped, not deferred.** Every reason for it has been
  answered by ordinary search, and the token could not reach it anyway — the one
  in this sandbox is a GitHub *App installation* token (`X-OAuth-Scopes` empty,
  `/notifications` is 403 "not accessible by integration"), so it would have
  needed a *classic* PAT with the `notifications` scope, the largest credential
  anything here has asked for.

  What replaced it, measured rather than assumed:

  | wanted | answer today |
  |---|---|
  | a merge seen between refreshes | the `is:closed` lanes |
  | all activity on chosen repos | `since=` polling, one cheap page a poll |
  | whole owners without listing repos | `owner/*` → `user:<owner>` searches |
  | the repo list from GitHub | `/user/subscriptions` — works now, 51 repos |

  What is left is thinner than the old note claimed. **Team mentions**:
  `team:ORG/TEAM` turns out to be a real issue-search qualifier — it rejects
  `JuliaLang/core` as "not a valid team name" while accepting
  `JuliaLang/compiler` — so the *query* needs no notifications scope. But it
  returns 0 for every team tried here and `/user/teams` is 403, so whether it
  actually reports mentions cannot be settled with this token. Try it first with
  a token that has org read; that is a far smaller ask than the alternative.

  **What search genuinely cannot reach**: Discussions, releases, security
  advisories, `ci_activity`. Only these would still need notifications, and CI
  is already covered by the checks in `facts.json`.

  **And one thing notifications would make worse.** It carries GitHub's own
  read state, and this program deliberately owns its cursor — "the cursor is
  ours, so nothing is missed because it was read somewhere else". Adopting
  GitHub's would undo the property the whole events lane exists for.

- **Auto-populating `[events].repos` from what you watch.** `/user/subscriptions`
  is readable with the current token and lists 51 repos. That is the "read it
  from GitHub" half of the request that `owner/*` only half answered — worth
  doing as a `wl` command that *prints* the list to paste, rather than as a live
  source, so the file stays the user's and a repo you stopped caring about does
  not come back because you never unwatched it.

## Where we were at just now before context reset:

First need to continue that work also on `t` improvements.

Next asks: Collapse author/label/repo in filter to only show the ones that are
currently active, but always show author:me and author:not-me. Sort those
filter lists alphabetically too. Add a key to refresh the current item --
either R (browser) or u (gmail). Change how ^]tab works -- use to toggle
between left/right panes, so I can operate in terminal or agent while also
navigating in the github comments. Bind escape to restore the list view (also
perhaps t/T toggles that state too)? What is 'ready to merge' -- it doesn't
seem to select any filters. Can you add an option at the top of filters to
clear all / reset? Always show me/not me in authors. Does views include sort
(it should)? The first view option should also always be reset / default.
The 'san' key should be 'tTv' to correspond to the shortcuts there. Can we
ignore SIGHUP in cli before starting julia, then exit gracefully when stdin
disappears (aka gets EOF / EPIPE / EIO)?

I think nested tmux has some issues with handling mouse. Maybe a tmux issue,
but mouse-in-nvim-in-tmux-in-wl-tmux, but doesn't work in tmux pane itself
(notably for activating scrolling, since ^b^b[ doesn't seem to reach there either).

### The `t` design, worked out and not yet built

The ask, in the words it was given in: `t` prompts for which worktree to open,
or to make a new one (default fill with the path to the main repo) — **unless**
that branch is already checked out in one, or there is already a tmux running
on that item, in which case use it without asking.

So three questions in order, and only the third one asks:

1. **A worktree already on the item's branch.** That is the copy the work is in,
   and `item_checkout` already prefers it. No prompt.
2. **A session already tagged with this item.** `mux_list()` rows carry `.item`
   (from the `@wl_item` tag, which is the item's `ref`) and `.worktree`, so a
   session says where the work is happening whatever branch happens to be out.
   Kind does not matter here: `t` should land in the worktree an *agent* of this
   item is already running in. No prompt.
3. **Otherwise ask.** A `ChooseView` over `worktrees(repo)` — main first, each
   labelled with the branch it has out and whether a session is live in it —
   plus a last entry that makes a new one. That entry opens a `PromptView`, and
   the prefill is `worktree_dest(p, branch)` when the item has a branch (which
   is `<main>-<branch with slashes dashed>`, the same suggestion the branch list
   makes) and the main checkout's own path when it does not, which is what the
   ask asked for. `add_worktree!` does the rest and already re-prompts with
   git's own complaint when a path is refused.

Where it goes: `enter_session(it, ctrl, kind, mkcmd)` in `browse.jl` is the
thing that currently calls `item_checkout` and goes; `open_agent` and
`open_terminal` are its two callers, and `t`/`T` in `handle_key!` are theirs.
Because asking means pushing a view and returning, those have to become
"decide, then either enter or push a chooser whose callback enters" - the same
shape `needs_repo` already uses for the checkout prompt, and the same shape
`row_session` in `paneview.jl` has on the other side (that one already opens a
session on a *chosen* worktree, so it needs none of this).

Two things to decide while building it, neither settled:

- **Whether `e` shares the answer.** The known gap says the automatic choice
  decides which files `e` opens as well as which session you land in. If the
  chooser only serves `t`/`T`, the two can disagree about the same item.
- **Whether the choice is remembered.** Asked once per item per session, or
  every time? Remembering wants somewhere to put it; a session tagged with the
  item *is* that memory, since rule 2 then answers on the second press.

This closes the "Worktree choice is automatic" known gap when it lands.

### What I already know about the asks above

Answers that took a measurement or a read of the code, so the next session does
not have to make them again:

- **"What is 'ready to merge' — it doesn't seem to select any filters."** It is
  `state = "active", bucket = ["needs-merge"]`, and it selects nothing because
  `needs-merge` had **0 items** when the views landed: that bucket is "approved
  and green" and nothing was. The view is right and the dashboard was empty.
  Worth checking `axis_counts` still says 0 before treating it as a bug.
- **"Does views include sort (it should)?"** It does: `apply_view!` reads
  `d["sort"]` and `view_toml` writes it. What it does *not* do is reset the sort
  when a view names none - every other axis is cleared, and that one is left
  alone. Making it symmetric is probably what is wanted, and would mean a view
  can pin "as fetched" as well as change it.
- **"Always show me/not me in authors."** Done - and it was worse than it
  looked: narrowed to a repo with none of your work in it the *whole* author
  axis vanished, not only those two rows. They are listed now whether or not
  they would select anything, since that they select nothing is the answer, and
  they do not spend the axis's share of the pane.
- **"Sorted alphabetically."** Done, on every axis: ordering by weight put the
  busiest first, which sounds useful and is not, because nobody holds a model of
  which value would select most - so the head of the list was in an order that
  could be neither predicted nor looked up. The stability that ordering was for
  survives, since alphabetical does not reshuffle under the cursor either.
- **"Collapse author/label/repo to only the ones currently active."** Not done.
  The rest of the ask: today an axis lists what is applied plus the first
  `AXIS_SHOWN` (8) of what is not, with anything a filter would select nothing
  from skipped already. Showing *only* what is applied is a smaller list again,
  and the picker row is what makes it reachable.
- **"An option at the top of filters to clear all / reset."** `c` already does
  exactly that in the filter pane (`st.filters = Filters()`), and now also
  remembers the previous filter for `` ` ``. What is missing is the *row*, which
  is the same argument the import row won: a control nobody can find is a
  control nobody uses. Same for "the first view option should be reset/default".
- **"The 'san' key should be 'tTv'."** Right: `s`/`a`/`n` are the three session
  slots (shell, agent, note) and `t`/`T`/`v` are the keys that open them, so the
  header should name the keys. `list_header` and `list_legend` in `paneview.jl`,
  and the legend text under the list says the same thing twice.
- **`^]tab` and escape.** `pane_command!` in `paneview.jl` is the whole prefix
  vocabulary; `^]tab` currently pops the pane and leaves it running.
- **SIGHUP / stdin EOF.** `cli/bin/wl` is a shell wrapper around `julia`, so the
  trap belongs there; the graceful side is `run!` in `controller.jl`, whose
  reader task is what would see the EOF.

### A test fix worth making: redirect `STATE[]` for the suite

The suite writes the **real** `data/state.toml` and puts it back in a `finally`,
so a run that ends part-way through leaves whatever the adoption testset wrote
behind, and the *next* run fails on counts that are one too high. It happened
once this session and cost twenty minutes of looking at the wrong thing:
`git -C data checkout state.toml` is the cure, and the counts being "one too
high" is the tell.

**Do this rather than explain it:** redirect `STATE[]` at the top of
`runtests.jl` the way `TOUCHED[]` already is, and the whole class goes away -
no `finally` to fail to run, and no way for a test to touch the file at all.

(The mechanism was *not* SIGPIPE: julia disables it, so `| head` closing the
pipe does not kill the process that way. Whatever ends a run early, the fix is
the same and does not depend on knowing which.)
