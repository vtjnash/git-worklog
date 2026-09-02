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

It also hosts programs. A tmux session per worktree can be opened on an item
(`t` a shell, `T` an agent), drawn in a pane beside the thread and driven by
forwarding the bytes you type, so the browser needs no model of what is running
in it. `"` lists every worktree and what is running in each, `v` opens the
item's note in `$EDITOR`.

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
julia --project=cli cli/test/runtests.jl   # everything testable without a TTY
```

The browser's keys divide by case: **lowercase shows you something, uppercase
changes something on GitHub.** `/` searches, `C` composes, `A` reviews, `L`
labels, `r` toggles read, `z` undoes the last local action. `v` edits the note,
`t` and `T` open a shell and an agent on the item's worktree, `"` lists what is
running; `tab` there swaps the worktrees for the branches, and `i` on a row of
either goes to its pull request. Inside a hosted
pane every key belongs to the child except the prefix
`^]`: `^]tab` leaves it running, `^]K` ends it, `^]a` goes full screen, `^]r`
re-reads, `^]]` sends a literal `^]`.

Use the `julia` on PATH (juliaup, 1.14-DEV). The in-tree
`/home/vtjnash/julia/usr/bin/julia` does **not** run in this sandbox — it is
linked against a newer glibc.

### Layout
| file | role |
|---|---|
| `cli/src/gh.jl` | GraphQL search lanes, shelled through `gh api graphql` |
| `cli/src/events.jl` | unread tracking and live thread fetch (submodule `Events`) |
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

Owner rules for the data files matter: `config.toml`, `state.toml` and
`repos.toml` are **yours** — `refresh` reads `state.toml` and never writes it,
and only `wl` edits it, through a line-based editor that preserves comments.
`facts.json`, `bulk.json`, `read.json`, `touched.json`, `queue.json`,
`snooze.json` and `cache/` are machine-owned. `errors.log` is written by the
browser when something throws, and deleting it is how its standing footer
warning is dismissed.

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
- The suite deletes `errors.log` at startup. The standing warning takes the
  footer's second row, so a log left from a previous run fails every test that
  asserts what is written there.
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
25. `NOW[]` is frozen for the whole run, which is right for a refresh — one
    instant for every age and expiry, so a run cannot straddle midnight and
    bucket half its items against a different day. The browser is the other
    kind of program: it stays open for hours, so anything recording *when you
    did something* must use `livestamp()`. Stamping `touched.json` from
    `stamp()` would date a whole session to when `wl` was launched, ordering it
    by nothing at all.

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

### Where the work is — worktrees, branches, interactions, and what is mine

Four lists the browser cannot show today, planned together because they share
two things underneath and because two of them turn out to be the same list.

**Both prerequisites have shipped.** Nothing reads either of them yet — the
lists below are what they are for.

- **The interaction clock**, `touched.json` and `touched.jl`. The reasoning
  about what does and does not write to it is in that file's header.
- **The local git survey**, `survey()` in `repos.jl`, returning `Worktree` and
  `Branch` for every repo in `repos.toml` at once: the branch, dirty or clean,
  ahead/behind upstream, the tip's date, and for a branch whether anything has
  it checked out. Three git invocations per repo plus one `git status` per
  worktree, and `survey(; withdirty = false)` drops even those — the tree walk
  is the only part that is not instant.
- **Branch → item**, which is what joins them: the lanes now fetch
  `headRefName`, so `facts.json` carries it and `branch_index(items)` keys an
  item by `(repo, branch)`. Verified against a live refresh — 1133 of 1133
  pull requests carry a branch and no issue does. `pr_branch` reads the field
  and only falls back to `gh` for a `facts.json` written before it existed.

**The lists.**

**A. Worktrees, by name — shipped.** `WorktreeView` in `paneview.jl`, on the
`"` the session list used to have. A session is *keyed* by its worktree, so
every one already belonged to exactly one worktree row: they are a column now,
not a list, which left one view fewer rather than one more. `↵`/`t` and `T` open
a shell and an agent on the row, `i` goes to its pull request, `K` ends what is
running there, and a session whose worktree has been deleted is an orphan row
rather than a hidden one.

Still missing from it: the last-commit date is collected but not drawn, there is
no way to *make* a worktree from here, and the rows are not sortable — which is
what list D wants and what `touched.json` is waiting for.

**B. Branches, as a second lens — shipped.** `tab` inside `"` switches between
them, the way `tab` already changes pane in the browser, and each lens keeps its
own cursor. Worktrees are places that exist; branches are work that exists
without one, so the leading column is whether anything has the branch checked
out and `↵` on a branch goes to the worktree that does. Sorted newest tip first
across every repo, which is what `git branch --sort=-committerdate` shows.

What it is still missing is its whole purpose: **adoption**, below, and a way to
*make* a worktree for a branch that has none — today `↵` on one can only say
that there is nowhere to go.

**C. Everything touched, by when.** A state in `STATES` beside
`active`/`unread`/`snoozed`/`backlog`/`all`, plus a *sort* by that timestamp.
Sorting is orthogonal to all three filter axes and should not be squeezed into
`Filters`; it wants its own control and its own key.

**D. What is mine, by when.** Everything with an open pull request of mine, plus
every branch that has been *adopted*, sorted by last interaction and falling
back to last commit date — which is what `git br` sorts by and the right answer
for something nothing has happened to yet.

A branch without a pull request is not an item and the list is a list of items,
so it is given a synthetic one keyed `local:<worktree>#<branch>`. Every
per-item mechanism here is keyed by url, so notes, snoozes, the interaction
clock and the buckets all begin working on unlanded work for free — which is
exactly what neither `git br` nor `gh pr status` can do.

**Adoption is explicit, and guarded.**

Nothing becomes "mine" by being present. A branch is adopted by picking it from
the branch list, or by opening a shell or an agent in a worktree whose branch
has no pull request — working in something is a deliberate enough act to count.
Adoption can be undone, which is what makes it safe to offer.

The guard matters: `gh pr checkout` leaves someone else's branch in your
checkout, and opening a terminal there must not quietly claim their work.
**A branch is only adoptable automatically if you have a commit on it** —
authored, or listed as a co-author — over the range `base..branch`. Otherwise
it can still be adopted, but only by asking for it in the branch list.

**Archive, as a state tag.** Work that is done, rejected or merged should leave
without being deleted: an `archive` field in `state.toml` carrying the date it
was set, a state in `STATES` to look at it, and `active` excluding it. It is
what closes the loop for adopted branches especially — a merged pull request
already leaves the active lanes on its own, but a local branch that came to
nothing has no other way out. A merged or closed item is worth *offering* to
archive rather than archiving silently.

**Order to build in.** Adoption and the synthetic items are next, and they are
what make lists C and D possible — until a branch can become an item, nothing
keyed by url can hold anything about it. Archive last: it is the only piece that
touches how items leave the lanes.

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

## Issues to file upstream

Kept here so they can be written up in one pass rather than rediscovered.

- **Term.jl: a table inside a list or a block quote is a `MethodError`.**
  `parse_md(::Markdown.Table)` takes `width` and nothing else, while Term's own
  recursion passes `inline` to whatever it finds nested. The fix is one
  `inline = false` in that signature. Worked around locally by `untable`, which
  moves a nested table into a code block of its own source; a table at the top
  level is left alone, since Term renders it properly there.
- **Term.jl: an empty list item is a `BoundsError`.**
  `parse_md(::Markdown.List)` indexes `[1]` on every item, but Julia's markdown
  parses `- a`/`-`/`- b` into items `[1, 0, 1]`, so any empty bullet throws
  `BoundsError: attempt to access 0-element Vector{Any} at index [1]`
  (`Term/src/markdown.jl:265`). Ordered or unordered, nested or top level, and
  a lone `-` on its own is enough. Caught on 2026-09-02 from a real comment; the
  whole comment falls back to raw text.

  Needs the same local treatment as `untable`: drop or fill empty items before
  Term sees the AST. Both workarounds are AST rewrites for the same reason, and
  are worth writing as one pass over the tree rather than two.
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

- **The key help line is missing `g`/`G`, and is ordered worst-first.**
  `g`/`G` (top and bottom) are bound in the list and the detail but appear in
  neither footer row. And the row leads with the keys that need explaining least.
  The obvious navigation keys should move to the *end* of the first row, with
  `n`/`N` leading that group and `q`/`tab` closing it — so the line reads
  `f filters · d diff · o comments · c checks · [/] context · l log · y copy ·
  / search · ↵ fold · n/N node · g/G top/bottom · j/k line · space/b page ·
  q quit · tab pane`, leaving what is worth reading at the front.
- **`g`, `G` and `b` do nothing in the filters view.** The filters branch of
  `handle!` binds `j`/`k`/`space`/`n`/`N`/`↵`/`c` and stops there, while the
  items branch immediately below it also has `b` and `PgUp` for page-up and
  `g`/`Home`, `G`/`End` for the ends. The filter list is long enough to need
  all three. They are one `elseif` each, taking `nf` as the bound the way the
  items branch takes `length(st.items)`.
- **URL handling in the detail pane is inconsistent.** A comment's links
  sometimes appear inline immediately before the following node's header rather
  than where the text put them, so a header reads as
  `https://…#issuecomment-372112478\u25be nalimilan  2018-03-11 …`. Reported
  2026-09-02 from a real thread on julia#18004; the footnote rows and `linkify`
  are the two things that touch this and it is not yet known which is wrong.
- **A pane once reported `session ended` with an empty frame, unexplained.**
  Seen once, in a scripted launch on 2026-09-02. The first theory — that the
  wake channel filled and blocked the reader — was tested and is wrong: the
  client survives with 11 of 64 slots used. It has not recurred, including at
  the same shape, so it is recorded as a known-unknown rather than a fixed bug.
- **Click-to-copy on a link is unconfirmed.** `y` copies and is known to work;
  clicking a link to copy it may not, and may be the editor not acting on OSC 8
  rather than anything here. Needs checking against a terminal that is known to
  support OSC 8 clicks.

- **Hunk context expands against the head commit.** Context around a `-` line
  therefore shows the post-change file, not the pre-change one. Fine for
  reading a change; wrong if you want the base side. Needs a second fetch and a
  decision about which side to show per hunk.
- **Worktree choice is automatic, and now decides more than it used to.**
  `item_checkout` prefers a worktree already on the pull request's branch and
  otherwise falls back to the main clone. There is no way to pick a different
  one and no offer to create a worktree for the branch — and since a session is
  keyed by its worktree, that choice now decides which session you land in as
  well as which files `e` opens. `"` is now where every worktree can be *seen*
  and started in, which is half of it; what it still cannot do is create one,
  or be the thing `t` on an item asks first.
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
- A hosted pane through a real terminal. Every part is driven directly in the
  tests - `onraw!` with bytes, `render` at fixed sizes, the mouse and cursor
  against a live tmux - but not one keystroke has reached it from an actual tty.
  Specifically unknown: whether this terminal sends `0x1d` for `^]`, and whether
  anything between here and tmux binds it first.
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
