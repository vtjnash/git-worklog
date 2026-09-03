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
in it. `^]tab` moves the keyboard between the child and the thread beside it, so
an agent can be watched and the pull request read at the same time; the wheel
scrolls the pane's own history when the child has no use for it. `"` lists every
worktree and what is running in each, and `v` opens the item's note in `$EDITOR`
in a pane of its own.

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

`bin/wl` runs `--project=cli/precompile`, which is `Worklog` with the browser's
own work already compiled into a package image — about two and a half seconds
off every launch. **The tests use `--project=cli` and must keep doing so**: that
split is the whole point of the wrapper. After changing anything under
`cli/src`, the first `wl` pays to re-run the workload (~18s) and everything
after it is fast; the suite pays nothing.

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
  The `LD_LIBRARY_PATH` is **not optional** and is three directories, not one:
  without it the binary dies with `libutf8proc.so.3: cannot open shared object
  file` and every session test *fails* rather than skipping. After a sandbox
  reset, `find` builds it:
  ```bash
  export WORKLOG_TMUX=$(find ~/.julia/artifacts -name tmux -type f | head -1)
  export LD_LIBRARY_PATH=$(dirname $(find ~/.julia/artifacts -name 'libutf8proc.so.3' | head -1)):\
  $(dirname $(find ~/.julia/artifacts -name 'libevent-2.1.so.7' | head -1)):\
  $(dirname $(find ~/.julia/artifacts -name 'libncursesw.so.6' | head -1))
  ```
  Worth doing rather than skipping: without it the whole session, pane and
  worktree half of the suite silently does not run.
- **Every path the program writes through is redirected at the top of the run**
  — `STATE`, `READ`, `INBOX` and `REPOS_FILE` seeded from the real files,
  `CACHE_DIR` started empty, alongside `TOUCHED`. The rule is that *all* of them
  go, not that each leak is fixed as it turns up: `state.toml` was found by an
  adoption testset whose `finally` did not run, and `read.json` by a test that
  pressed `r` and stamped a real item as read. A testset that points
  `REPOS_FILE` at a temp repo puts it back to `REPOS_SANDBOX`, never to `""`,
  which means the user's own file again. `errors.log` is the deliberate
  exception — the suite deletes the real one at startup and several tests assert
  on the footer warning it produces.
- **The suite runs against `Worklog` directly** (`--project=cli`), never through
  `cli/precompile`. That is the point of the wrapper being a separate package:
  the workload is `wl`'s tax and not the edit-test loop's.
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

**A background fetch has to be findable, not just started.** `@async` with the
task dropped into a field is not enough: the next load overwrites the field, and
what was started is then unreachable — it cannot be joined, waited for, or asked
whether it failed. Everything that runs in the background goes through
`fetching`, which keys it by what it is fetching. The three things that broke
without it were duplicate `gh` processes while scrolling, silent failures in
abandoned tasks, and package precompilation hanging on IO nothing held a handle
on.

**A hyperlink is not somewhere to write another one.** `linkify` runs last, on
the finished frame, and used to `replace` over the whole of it. Every comment
header is already an OSC 8 hyperlink to its own permalink, and a url written in
one comment is very often the permalink of another — nanosoldier replies with a
link to the `runbenchmarks()` comment that asked. So the replacement landed
*inside* the outer sequence's payload, and the inner `\e]8;;` terminated it
early: the rest of the url printed as literal characters nothing had measured,
and the row came out 224 columns wide in a 150-column terminal. That is what the
screen tearing in VS Code was. It now cuts the frame on its OSC sequences and
substitutes only between them.

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

- **`^]t`/`^]T` from a pane, and `t`/`T` from the reading side, disagree.** From
  the child's side the prefix forwards them, so `^]T` in a shell pane reaches
  the agent on the same item — which is the useful thing. From the reading side
  they leave for the list, which is the toggle that was asked for. Both are
  defensible on their own and nothing on screen says they differ.
- **The reading side forwards `f` and `q` to the browser.** `f` switches the
  browser to its filter pane, which is not drawn there — so nothing visibly
  happens and the change is waiting when you pop back. `q` quits the program
  from inside a pane, which is consistent (the reading side *is* the browser)
  but is not what `q` does in any other view here.
- **A pane once reported `session ended` with an empty frame, unexplained.**
  Seen once, in a scripted launch on 2026-09-02. The first theory — that the
  wake channel filled and blocked the reader — was tested and is wrong: the
  client survives with 11 of 64 slots used. It has not recurred, including at
  the same shape, so it is recorded as a known-unknown rather than a fixed bug.

- **Hunk context expands against the head commit.** Context around a `-` line
  therefore shows the post-change file, not the pre-change one. Fine for
  reading a change; wrong if you want the base side. Needs a second fetch and a
  decision about which side to show per hunk.
- **An adopted branch's merge has no author.** A pull request you merged
  yourself skips the wait before archive is offered, because `mergedBy` says
  who pushed the button. A local branch has no such record: `merged_here` says
  every commit is in the base and says nothing about how it got there, so an
  adopted branch that landed is still news until it has been read. The merge
  commit's committer is where that would come from, and only when the work
  landed as a merge rather than a squash or a rebase.
- **`repos.toml` is never pruned.** Entries pointing at deleted folders are
  ignored at read time but never removed or re-prompted.
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
- Click-to-row and drag-to-select in the *browser's* panes. The mouse round
  trip itself is answered — `\e[?1006h\e[?1002h` goes out, SGR reports come
  back, they survive the user's tmux, and `retarget_mouse` lands them inside a
  hosted pane correctly enough for an editor two multiplexers down to respond
  (2026-09-03, from the nested-tmux report). What that does not pin is the
  browser's own geometry: `onmouse!` maps a click through `layout(w, h)` and
  `st.hdr`, and only synthetic events have ever gone through it.
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
- ~~A hosted pane through a real terminal.~~ Answered on 2026-09-03: `^]` does
  arrive as `0x1d` and nothing between the terminal and here binds it first —
  the report that `^]tab` and `^]esc` behaved wrongly is a report from somebody
  whose prefix was reaching the pane. What is still unknown is only whether the
  *title-bar* row settles tmux copy-mode scrolling, which is listed above.
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

## The plan, in order

Agreed 2026-09-03. Do these in this order; the rest of this file is the
standing backlog they were picked out of.

0. **The precompile wrapper's dependencies.** Done — see "The precompile
   wrapper" below for what was actually heavy and why it was not
   `PrecompileTools`. One decision is still open there and is flagged.
1. **Split `browse.jl`.** It is 4,576 lines and holds at least five separable
   things: the filter and view model, the node building for threads and diffs,
   the composer and review writing, the session and worktree glue, and the
   render. Every session spends real time grepping it for where something
   lives. Invisible from outside, and the suite is thorough enough to make it
   low-risk. `runtests.jl` is 4,673 lines and has the same problem; splitting it
   the same way is the obvious follow-on, and worth doing in the same pass so
   the two halves keep matching.
2. **The small unblocked wins.** `wl watching` printing a suggested
   `[events].repos` from `/user/subscriptions` (specced under Infrastructure — a
   command that *prints* a line to paste, never a live source); a default sort
   per lane rather than one for the session (see "Unverified", which says `mine`
   and `touched` probably want different ones); and pruning `repos.toml` entries
   that point at directories which are gone.
3. **Then decide whether the two pane inconsistencies are worth fixing** — the
   first two entries under "Known gaps". Both are real and both are small, but
   neither has been hit in use yet, so the question is whether they are worth a
   change to keys that have just settled.

Not on the list because it is blocked: **every write is still unexercised**.
`post_comment`, `add_review_thread`, `submit_review`, `delete_review` and the
label toggle are written and none has ever been sent, because the token here is
read-only. It is the only part of the program where a failure loses work, and it
needs a fine-grained PAT with `issues: write` and `pull_requests: write` on the
repositories being reviewed. See Infrastructure.

## Where this session got to

Everything on the previous session's list is done. What is left below is the
standing backlog — "Outstanding work", "Known gaps", "Unverified" and
"Infrastructure" — plus the one item that turned out not to be this program's.

### What shipped, and the argument each one rests on

Read the commits for the detail; this is the shape, so the next session knows
what the program now believes about itself.

- **`t`/`T` ask which checkout.** Three rules in `item_worktree`: a worktree
  already on the item's branch, then a session already tagged with the item
  (whatever branch it has out, whichever kind — so `t` lands where this item's
  agent is), then the main checkout *and a flag saying that was a guess*. Only
  the flag's holder asks. `item_checkout` is the same answer without the flag,
  so `e` reads the same first two rules and the two cannot disagree; and the
  session's tag *is* the memory, so it asks once per item and never again.
- **The way back to nothing.** A `:reset` row leads the filter pane and a
  default view leads `'`. The latter is a view like any other because a view now
  clears the sort it does not name, the way it already cleared every other axis
  it does not name — so `state = "active"` and nothing else *is* a fresh
  `Filters()`.
- **A filter axis is a readout, not a menu.** Repo, label and author list only
  what is applied, plus the author axis's two controls; the picker row under
  each is where choosing happens, and it narrows by typing, which is the only
  thing that scales to several hundred labels. Category keeps its whole list.
- **`R` re-reads the item on screen** — the thread past its ten-minute window,
  the checks past their two-minute one, the metadata that otherwise only reloads
  when the selection moves. Quiet on purpose: nodes, cursor and fold state all
  stay.
- **A pane and the thread beside it share the keyboard.** `PaneView` has a
  `focus`, and `wantsraw` is what it means. `^]tab` gives the keys to the
  thread; `tab` gives them back; `esc`/`t`/`T` leave for the list. The side
  without the focus gets *nothing* — which keys belong to which side has to be
  answerable by looking at which side is lit, not by remembering a list. And
  unknown keys after `^]` go to the browser, which is what makes `^]m` reach the
  mouse toggle without anything in `paneview.jl` naming it.
- **Places replace places; dialogs stack.** `isdialog` is the distinction and
  `push_place!` enforces it. A terminal on top of the worktree list was never a
  state anybody meant to be in.
- **Losing the terminal is an exit.** `trap '' HUP` in `bin/wl` before the
  `exec`, and `EndEvent` so the reader task cannot leave the loop parked on its
  channel forever.
- **A pane has scrollback.** The wheel reports a child never asked for used to
  be dropped; they now move this view's own window over the pane's history.
- **`wl` starts through `cli/precompile`.** See below.
- **One fetch in the air per thing being fetched.** `INFLIGHT` is a locked map
  from what is being fetched to the task fetching it, and `fetching(f, key)`
  joins a run already under way instead of starting a second. A view can only
  hold one `pending`, so holding `j` down the list used to start a
  `gh api graphql` per row and abandon all but the last — a process each, a rate
  limit spent on answers nobody reads, and the winner decided by whichever
  finished last. An abandoned task's value is never fetched either, so anything
  that escaped its own error handling escaped silently; those are logged now.
  And `drain_fetches!` is how anything can ask "is something still running",
  which is what the precompile workload needed and what nothing could answer.
  Timers are deliberately not in the map: `arm_refresh!` starts a task that
  *sleeps*, and a drain that waited on one would hang for the debounce.

### The precompile wrapper

`cli/precompile` is `WorklogPrecompile`: `Worklog` re-exported, plus a
`@compile_workload` of the browser's own path. `bin/wl` loads it; the test suite
loads `Worklog` directly and never sees it.

Measured on the path that draws a comment thread, interleaved against the same
path with no wrapper: **4.33s → 1.36s**, so about three seconds off every
launch. Nearly all of it is the markdown renderer — a comment body goes to Term,
and nothing had ever run that before the user did.

Three decisions worth not re-litigating:

- **Separate package, not a workload in `Worklog`.** A workload runs whenever
  the package holding it is precompiled, and `Worklog` is precompiled every time
  one of its own files is touched. Downstream, the tax lands only on `wl`.
- **A hand-written workload, not the test suite.** The suite was tried first. It
  spawns tmux servers, `vi` and half a dozen git repositories, which would then
  be happening inside package precompilation — parallel, in a subprocess, output
  captured. And a failing test would stop `wl` from starting at all.
- **Invented items and nodes, hermetic paths, and a `catch` around everything.**
  So the image does not depend on what was in the dashboard the day it was
  built, so nothing reads or writes the real data, and so a workload that breaks
  cannot stop the program from being installed.

To extend it, add to the workload in `precompile/src/WorklogPrecompile.jl` — and
keep the two rules it already follows: nothing that spawns a process, and
`load_nodes!`/`load_meta!` satisfied before any `handle!` call, or the workload
starts a fetch and hangs.

**Its manifest is `cli/Manifest.toml` plus one entry, and must stay that way.**
Resolved fresh it was not: `Pkg.resolve()` in an empty project picked a newer
`Term`, which pulls a newer `Highlights`, which depends on `Pkg` and
`TreeSitter` — and with them `LibGit2`, `Downloads`, `Tar`, `LibCURL` and four
jlls. None of that came from `PrecompileTools`, which `Term` has depended on all
along (`cli/Manifest.toml`), and which therefore costs this package nothing at
all. The cure is to copy `cli/Manifest.toml` over and `Pkg.resolve()`, which
keeps every version already pinned and adds only `WorklogPrecompile`. Check it
with:

```bash
diff <(grep '^\[\[deps\.' cli/Manifest.toml | sort) \
     <(grep '^\[\[deps\.' cli/precompile/Manifest.toml | sort)
```

which should print exactly one line, for `WorklogPrecompile` itself.

**Open decision: whether to drop `PrecompileTools` anyway.** Measured in one
batch on the comment-thread path: 1.37s with `@compile_workload`, 1.99s with the
same workload run as a bare `let` block. So the macro is worth about 0.6s on
every launch, because plain execution does not get everything cached against the
downstream image. Base has no equivalent — `Base.Experimental` has only
`@force_compile` and `@compiler_options` — so removing it means either losing
that 0.6s or hand-rolling the `jl_set_newly_inferred` bookkeeping, which is
exactly the version-fragile thing the 1.12/1.13 concern is about. And it cannot
be removed from the *tree* while `Term` is the markdown renderer. Kept on those
grounds; the bare-`let` version is a three-line edit if that changes.

**It must not leave a process running.** A package that does stops precompilation
dead with "waiting for IO to finish", and this one did: `load_nodes!` and
`load_meta!` start a fetch the moment the selection moves to an item they have
not loaded, so a single `j` in the workload left two `gh` processes and two
pipes with nothing holding a handle. Pinning `st.loaded` was not the fix — the
pin moves with the selection. `hermetic` takes the *binaries* away instead: an
empty `PATH` makes `run` throw before it forks, and `WORKLOG_TMUX` at a path
that does not exist makes `mux_bin` answer `nothing`. That is a property of the
environment rather than of which keys the workload presses, which is what makes
it survive somebody adding one. `drain_fetches!` at the end is the second half.

### Nested tmux and the mouse: measured, and not this program's

"mouse-in-nvim-in-tmux-in-wl-tmux works, but the tmux pane itself does not —
notably for activating scrolling, since `^b^b[` does not seem to reach there
either." Both halves reproduced against a real tmux 3.5a, and there is a testset
pinning each.

- **`^b^b[` is one prefix too many; `^b[` works.** `onraw!` writes bytes into
  the pane's pty with `send-keys -H`, so the *hosting* session never sees them
  as keys of its own — there is no outer prefix to escape. The second `^b` is
  the inner tmux's `send-prefix`, which puts a literal `^b` into the shell.
- **The mouse is the inner tmux's own `mouse` setting.** With `mouse on` it sets
  1002 + 1006 on the pane it is drawn in, the wheel is handed over, and copy
  mode opens — measured end to end. With `mouse off` it sets nothing on its own
  behalf, only on behalf of what runs inside it: so the wheel reaches nvim and
  the tmux does nothing with it. `set -g mouse on` is the whole fix.
- **`#{mouse_any_flag}` is the disjunction** of standard/button/all — 1 for each
  of `?1000h`, `?1002h`, `?1003h`, and 0 for SGR-only. The gate was never wrong.
