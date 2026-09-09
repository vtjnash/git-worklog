# TODO

## What is next

Three things are open, and the first of them is a decision rather than a task.
Everything else that stood here is done; `git log` is the record of it and this
file is not.

1. **A comment box drawn inline, between the lines it is about.** An idea to
   design rather than a task to pick up, and the rest of that item is done: the
   comments hang off the hunk they point into, threaded, with the resolved ones
   folded under it, they are nodes so `n`/`N` walks them, the hunk header counts
   them, and the *line* each thread hangs off carries the same `💬` mark - so
   the hunk says where it is being talked about and the discussion is one screen
   below rather than one pane away.
   What is left is the box itself, drawn between the diff lines. The cost is
   what to decide about: a hunk is one node whose body is the diff text, and
   cutting it at the commented line cuts the `start`, `count` and `body` that
   `hunk_line_at`, `[`/`]` expansion and `c`-on-a-range all read off one node.
   The cheap version - a node per fragment, sharing the parent's meta - trades
   one problem for the arithmetic of keeping four ranges in step; the honest
   version is rows that belong to a node without being its body, which is a
   change to what a `Row` is. Neither is worth starting without deciding which.

2. **Whether a drag is reported at all.** The keyboard half of this - `shift-J`
   and the shifted arrows extending a selection - is done. On the mouse half,
   everything between the byte and the highlight is exercised by the suite and
   works: `\e[<32;40;12M` decodes to a `:drag`, `onmouse!` puts the range in
   `sela`/`selb`, and the frame draws those rows in `SELBG` - checked against a
   real render, not only in the test. So what is left is outside this program:
   whether the terminal sends motion reports at all under `1002`, whether tmux
   or the terminal is taking the drag for its own selection first, and whether
   the drag was over the *item list*, which binds press and wheel and ignores
   motion by design. It needs a real terminal to find out in, which is the one
   thing this sandbox does not have.

3. **`rust#1` is still in the unread lane.** The code that left it there is
   fixed - undoing an import now takes back the inbox row and the read stamp as
   well as the `imported` field - but that row predates the fix and is still in
   `data/inbox.json`. Pressing `r` on it removes it. Left alone because it is
   the user's own data and one keystroke.

Blocked, and still the largest thing on the list: **every write is
unexercised.** `post_comment`, `add_review_thread`, `submit_review`,
`delete_review` and the label toggle are written and none has ever been sent,
because the token here is read-only. It is the only part of the program where a
failure loses work — the draft-review machinery exists precisely because five
careful comments are easy to lose — and it needs a fine-grained PAT with
`issues: write` and `pull_requests: write` on the repositories being reviewed.
See Infrastructure.

Waiting on other people rather than on us: **FedeClaudi/Term.jl#304**, **#305**
and **#306**, the three bugs this program works around in `escape_source` and
`for_term`. When each lands and a release carries it, those workarounds are what
to delete - see Upstream, below.

### What a read-through turns up

Kept from the last pass over `src/browse/*` because it says what to look for
rather than what was found, and every class of it recurred in the pass after:

- **Counts that stopped being true.** Nine filter states described as five, six
  axis predicates as four, forty-nine `BState` fields as thirty, the category
  axis as thirteen values when it is built from the buckets the items carry.
- **Arguments that outlived the code needing them.** `Term.Panel`, the label
  frequency count, `select_item!`'s promise not to un-filter, and one of the two
  reasons `t` is kept on the reading side.
- **Dead things**, each left behind by what replaced them: `esc`, `fit1`,
  `session_rows`.
- **Defects the prose walked straight past.** `/1234` never widened for an
  *archived* item; `undo!` did not rebuild the snoozed lane it had just changed;
  a note saved from a pane went into `st.items` alone and vanished at the next
  refilter; an undone import left its inbox row behind for good.
- **A rule enforced by matching text that identity could enforce instead.** The
  footnote hyperlinks were made by replacing a url's display form in the
  finished frame, which could not tell two urls apart once they elided to the
  same string - and the fix was to make the link where the row is written, where
  there is nothing to match.

## Resuming work

Read this first if you are picking this up cold; "What is next" above is what to
do once you have.

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
./cli/bin/refresh              # fetch, bucket, diff the snapshot   (~30s)
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
own work already compiled into a package image — 1.2s off the launch that draws
a thread, 0.6s off the one that only draws the list, and 0.1s *onto* a plain
`wl <command>`, which loads the bigger image for work it does not do.
**The tests use `--project=cli` and must keep doing so**: that split is the
whole point of the wrapper. After changing anything under `cli/src`, the first
`wl` pays to re-run the workload (~22s) and everything after it is fast; the
suite pays nothing. `julia --project=cli cli/test/latency.jl` re-measures all of
that in about a minute.

The browser's keys divide by case: **lowercase shows you something, uppercase
changes something on GitHub.** `/` searches, `C` composes, `A` reviews, `L`
labels, `r` toggles read, `s` asks how long to snooze for, `u` re-fetches the
whole dashboard in the background, `w` cycles the three orders, `x` archives,
`z` undoes the last local action. A click on a url copies it, whole even where
the wrapping cut it, a double click copies the word - or the item's url, in the
list - and the `⧉` at the end of every header copies that block whole. A drag
over the reading pane selects rows for `y` to copy and `c` to comment on, and
`shift-J`/`shift-K` or the shifted arrows do the same from the keyboard. The list opens newest first - by when anything last
happened, yours or GitHub's - and `w` reaches the other two orders: the
interaction clock, and the url (owner, project, number, descending). A row that
leaves the list under you - `r` in the unread lane, `x`, `s` - leaves the cursor
where it was rather than at the top, and coming back to an item lands on the
line you were reading in it, per item and per mode.

`'` is the named views - seven built in, more from `config.toml`, and its last
entry copies the current filter as the TOML that would name it. The first ten
are on `1`-`9` and `0`; `` ` `` goes back to the filter you were in before. `f` opens the filter pane, whose ten
states are `active` / `unread` / `mine` / `second look` / `drafts` / `touched` /
`snoozed` / `backlog` / `archived` / `all` - `active` being everything that is
not snoozed, not archived and not in the backlog pile, which is the only one of
the ten that is a subtraction - with a second radio group
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
replace - the range, or the one line the cursor is on - and the comments
accumulate into a **draft review held on GitHub**
rather than posting one at a time. `A` sends it, and leaving the item asks
whether to - "leave it" keeps the draft and re-asks the next time you walk off
it, since nothing but this program mentions one anywhere else. Existing review
comments are placed against the hunk they point into, with a resolved thread
folded away under it rather than dropped, and the line a thread hangs off is
marked `💬` in the diff itself - `✓` where it is settled - so the hunk says
which of its lines is being talked about.

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
| `cli/src/refresh.jl` | normalize, bucket, fingerprint, snooze, bulk cache, the snapshot diff |
| `cli/src/touched.jl` | the interaction clock: when you last acted on an item |
| `cli/src/state.jl` | the line-based `state.toml` editor, `next` queue |
| `cli/src/controller.jl` | the view controller that owns stdin; input decoding; `PromptView`, `EditorView`, `ChooseView` |
| `cli/src/browse/` | the browser: filters, panes, folding, diffs, checks, writing (`Worklog.jl`'s include list is the index) |
| `cli/src/ansi.jl` | escape-aware width, truncate, wrap |
| `cli/src/ci.jl` | check contexts and Buildkite drill-down |
| `cli/src/repos.jl` | repo → local checkout mapping, the worktree/branch survey, `git show` |
| `cli/src/mux.jl` | tmux sessions and the control-mode client |
| `cli/src/paneview.jl` | a hosted program drawn in a pane; the worktree list |
| `cli/src/cache.jl` | on-disk cache with TTL |
| `cli/test/runtests.jl` | everything testable without a terminal |
| `cli/test/latency.jl` | the three startup waits, measured; not part of the suite |

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
answered is still waiting on a reviewer - so it is a filter state, not a
bucket. A bot commenting after the author hides the
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
  themselves when there is none. **Skip, never fail**: a testset that fails
  takes the whole run down with it, and every file included after it silently
  stops running. `views.jl` had one assertion that did not guard, and it was
  hiding `worktrees`, `lanes`, `archive`, `robustness`, `git`, `items` and
  `clock` in every sandbox without tmux - the same shape as the adoption
  testset that hid behind `archive.jl`. `WORKLOG_TMUX` points at a binary, which is how
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
  `julia --project=cli cli/test/runtests.jl`. `cli/test/latency.jl` is beside
  it and is deliberately *not* part of it: it builds the wrapper's image and
  spawns cold processes, which the edit-test loop should never pay for.

Typical harness:

```julia
items = Worklog.loaditems()
st = Worklog.BState(items, "worklog", Set{String}())
ctrl = Worklog.Controller(); ctrl.running = true
st.wake = () -> Worklog.wake!(ctrl)
Worklog.load_nodes!(st); take!(ctrl.events); Worklog.onwake!(st)
```

### The split, and how to keep it

`src/browse/` and `test/suite/`. `Worklog.jl` and `runtests.jl` are now lists of
includes with a line of description each, which is the index: to find something,
read the list rather than grepping four and a half thousand lines.

**Both splits moved nothing.** Every file is a contiguous slice of the original,
in the original order, and that was checked rather than assumed — reassembling
them gives back every non-blank line, identical and in the same order (4,244 for
the source, 4,335 for the tests). The two deliberate exceptions are written down
here so nobody goes looking for a third: a dangling docstring at the top of
`browse.jl` that documented a global removed long ago, deleted; and `items` /
`mkstate` in the tests, which sat between two testsets and moved to the driver
where a shared helper belongs.

**Cut above a definition, never into it.** A naive slice at a section marker
leaves a docstring at the end of one file and its binding at the start of the
next. Seven of them did, and nothing complained: a stranded docstring is a legal
no-op and the tests still passed. The check is one line —

```bash
for f in cli/src/browse/*.jl; do
  [ "$(grep -v '^$' "$f" | tail -1)" = '"""' ] && echo "$f strands a docstring"
done
```

— and the same trap catches a comment block that introduces the next thing.

**Order is not cosmetic in either list.** In the source, a type or a constant has
to exist before the methods annotated on it are defined. In the tests, several
testsets leave a file, a session or a filter behind that the next one reads.
Adding a file means putting it where it belongs, not at the end.

### The precompile wrapper

`cli/precompile` is `WorklogPrecompile`: `Worklog` re-exported, plus a
`@compile_workload` of the browser's own path. `bin/wl` loads it; the test suite
loads `Worklog` directly and never sees it.

Measured on the path that draws a comment thread, interleaved against the same
path with no wrapper: **2.36s → 1.14s**. The list pane alone is 1.64s → 1.00s,
and `wl --help` is 0.88s → 0.97s — the wrapper is a tenth of a second *worse*
for a command that never draws anything, because the image it loads is bigger.
That is the trade, and it is the right way round: the browser is what a person
waits in front of.

Where the rest of it goes now: 0.96s of every launch is loading the module,
which no workload can touch, and 0.18s is what is left of the thread. Of the
1.22s the wrapper saves, about a quarter is `loaditems` — the JSON3 parse and
`item_of` over two thousand rows, which went into the workload once the
measurement named it, and dropped from 0.31s to 0.03s.

`julia --project=cli cli/test/latency.jl` is where every number here comes from:
three waits, both projects, interleaved, best of three. It is not a test and not
part of the suite — a ceiling asserted on a shared machine would be flaky, and
the suite must not pay to build this image.

**One caveat about the baseline, on Julia 1.14.** The runtime now writes code
compiled during a run back into the caches of the packages that own it, so the
launch straight after an edit costs about twice the launch after that: 4.97s
against 2.46s with no wrapper. Both are real waits; the table reports the
second, because that is the one a person meets over and over. It also means a
number measured on a cold depot is not comparable to one measured on a warm one,
which is why the old 4.33s is not what this section quotes any more.

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

**An alias is not reachable from a program, and `exec` is why twice over.**
`T` runs `$SHELL -ic claude`, and every part of that was got wrong once.
`Sys.which("claude")` refused the name before trying it. `-c` without `-i`
reads no `.bashrc` *and* has `expand_aliases` off, which are two independent
reasons and mean `BASH_ENV` alone does not help. And `exec claude` defines the
alias and then does not use it: aliases expand in command position only, so the
command there is `exec`. Measured against bash 5.1, not remembered.

Reading the alias *is* the point when the alias is the thing being kept in
sync — copying it into `config.toml` would be a second definition to drift.
Verified end to end through a real pane, with the alias in the shape that
prompted this (`alias claude='~/.julia/bin/claudebox --preserve '`): the `~`
expands, the trailing space carries alias expansion on to any argument, and it
survives the `env -u` scrub `standalone` puts in front. `[agent] command` is for
the other case — an agent that is not what your shell calls `claude` at all.

**`capture-pane` reads cells, so anything that paints none is lost.** A hosted
pane is drawn by reading the grid back, and a grid is made of cells — so a
sequence that paints nothing is not in it and no amount of `-e` will put it
there. OSC 52 is the one that matters: an agent several terminals down that
copies something has no other way to reach the terminal a person is looking at.
It *does* arrive in control mode's `%output` (measured: tmux passes it to a
control-mode client whatever `set-clipboard` is set to), and it was being
decoded and thrown away — `onoutput` took only the pane id. It now takes the
bytes too, and `passthrough` relays OSC 52 and nothing else. Only that one,
because `%output` is the child's whole byte stream and echoing the rest would
write over a screen this program lays out itself. It is also why relaying from
the reader task is safe: the sequence paints nothing and moves no cursor, so
landing in the middle of a frame changes nothing about what the frame draws.

**A row index is only meaningful against the width it was measured at.** Keys
that index rows — `n`/`N`, the search, page down, the highlight — used to ask
`layout` how wide the detail pane would be. That is right in the browser and
wrong beside a hosted pane, which takes half the screen: at 170 columns the two
answers are 114 and 74, and the same comment wraps to eight rows or twelve
depending which you ask. `detail_pane` now records the width and page it was
actually drawn at, the same way it already recorded `hdr`, and the keys read
that. Only the thing that draws it knows how wide it got.

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
   schedules the work. Carry the last known value forward, but *not* past the
   end: a merged or closed pull request answers `UNKNOWN` for good, and carrying
   there pinned "conflicting" onto julia#62396 after it merged. `carried_mergeable`
   is where both halves live.
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

**Buildkite** (the endpoint shapes came from a `buildkite-logs` skill, which is
not in this repo - `skills/` is gone with `DASHBOARD.md`, which is what it read)
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

**A place replaces a place; a dialog stacks on one.** `isdialog` is the
distinction and `push_place!` enforces it. A place is somewhere you work — a
terminal, an agent, the worktree list — and going somewhere means leaving where
you were. A dialog answers a question and hands the keys back, which is the one
case that returns to what asked. Dialogs are the default, because a view that
has not thought about this is one that returns.

**The side without the focus gets no keys at all.** Which keys belong to which
side has to be answerable by looking at which side is lit, not by remembering a
list — so a hosted pane's reading side keeps exactly three (`tab` back to the
child, `esc`/`t`/`T` out to the list) and everything else is the browser's.
Through the prefix it runs the other way: `^]` already means "this one is not
the child's", so the six the pane layer names are its own and the rest are
forwarded.

**Key bindings: a capital reaches GitHub, lowercase does not.** `C`, `A` and `L`
post a comment, submit a review and set a label; everything lowercase stays on
this machine, `r` and `s` included — `read.json` and `state.toml` are local
files, and `e` only launches an editor. The line is *remote*, not *writes
something*, which is also why `z` below can offer to undo the lowercase set and
must never offer to undo the capitals.

## Outstanding work

Roughly in the order it is worth doing, and none of it is on the critical path
of "What is next" at the top. Nothing already shipped is listed; `git log` is
the record of that.

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

**The workaround has shipped** — `escape_source` escapes such an underscore
before `Markdown.parse` sees it, skipping fenced blocks, indented blocks and
inline code spans, where a backslash would print. (It is the same pass that
doubles braces for Term, since both are a markup layer eating characters that
were text.) So this repo is no longer waiting on the fix; what remains is filing
it, so that everyone else's rendered docstrings and READMEs stop losing
characters too.

**Written up in `fixme-julia-markdown.md`**, in this directory, to be moved into
a julia checkout. What it adds to the above is the acceptance test, which turns
out to be in the tree already: `stdlib/Markdown/test/` carries the CommonMark
spec with a `known_broken` set, so a fix makes the suite fail *on purpose* and
`regenerate_test_spec.jl` rewrites the generated runners. A fix of the shape it
describes flips **seventeen** spec examples from failing to passing and
regresses none — 294 failing before, 277 after, at `flavor = :common` — and all
seventeen are this bug, single and double underscore alike. Measured by copying
the module's source somewhere writable and `include`ing it, which loads
standalone as `Main.Markdown`: the whole loop runs without building Julia.

### The brace bug on Term.jl — filed as FedeClaudi/Term.jl#304
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

**Filed as #304**, "fix: keep literal braces in markdown, and stop printing them
doubled". Writing it up turned one bug into two ends of the same one: prose
braces are *deleted*, and a code span's are *doubled on screen* -
`highlight_syntax` escapes them (`src/highlight.jl:78`) and nothing collapses
the doubling, so `tprint("Tuple{{Int}}")` prints `Tuple{{Int}}`. The round trip
that `escape_brackets`/`unescape_brackets` describe was open at both ends, which
is why the PR touches the print path as well as the markdown one. Prior art
cited, both closed and both the same bug when the markup delimiter was `[...]`:
**#59** "escape style brackets", where the maintainer said the next version
would ignore doubled brackets, and **#84** "Term removes bracket `[...]`".
The report itself:

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

## Upstream

The three Term.jl bugs are filed, from the checkout beside this one:
`Term.jl/` is a clone (ignored here, and `fixme.md` in it is ignored there) with
each bug reproduced against v2.2.0, the cause located and the decision spelled
out. **#304**, **#305** and **#306** came out of it.

They stay on this list until each lands *and* a release carries it, because the
workarounds here are what to delete then - and deleting them is the point of
having filed.

- **Term.jl: a table inside a list or a block quote is a `MethodError`.**
  Filed as **#306**, "fix: accept a table nested inside another markdown
  element".
  `parse_md(::Markdown.Table)` takes `width` and nothing else, while Term's own
  recursion passes `inline` to whatever it finds nested. The fix is one
  `inline = false` in that signature. Worked around locally by `for_term`, which
  moves a nested table into a code block of its own source; a table at the top
  level is left alone, since Term renders it properly there.
- **Term.jl: an empty list item is a `BoundsError`.**
  Filed as **#305**, "fix: don't throw on a markdown list item with no
  content".
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
- **JuliaLang/julia: the intraword-emphasis bug** — see its own section above,
  and `fixme-julia-markdown.md`. Term was the first suspect and is innocent:
  the mangling is already in the AST that Julia's `Markdown` hands over, so this
  is the one on the list that is not Term's and the one still to file.
- **Term.jl: the brace bug** — filed as **#304**; see its own section above.
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

- **A nested tmux gets no mouse unless *it* has `mouse on`.** Measured against
  tmux 3.5a, and not this program's to fix. A tmux with `mouse on` sets button
  and SGR tracking on the pane it is drawn in, so the wheel is handed over and
  copy mode opens. With `mouse off` it sets nothing on its own behalf, only on
  behalf of whatever runs inside it — which is why the mouse works in an editor
  in there and does nothing in the tmux itself. `#{mouse_any_flag}` is the
  disjunction of the three tracking modes, so the gate on this side was never
  the problem. The keyboard half has the same shape: `^b[` reaches an inner
  tmux and `^b^b[` is one prefix too many, because `send-keys -H` writes into
  the pane's pty and the hosting session never sees those bytes as keys of its
  own — there is no outer prefix to escape.
- **`^]t`/`^]T` from a pane, and `t`/`T` from the reading side, disagree.** From
  the child's side the prefix forwards them, so `^]T` in a shell pane reaches
  the agent on the same item — which is the useful thing. From the reading side
  they leave for the list, which is the toggle that was asked for. Both are
  defensible on their own and nothing on screen says they differ. Left alone
  deliberately, after the read-through: forwarding them would no longer double
  the pane (`enter_session` refuses that now), but the key that opened the pane
  being the key that closes it is worth more than the symmetry.
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
- Which reading of "when" you actually reach for. Use answered the first half:
  every lane opens by when anything last happened, `touched` excepted, because
  that lane *is* the clock. `w` still reaches the other two - the clock, and the
  url. Whether `mine`, `second` or `unread` want one of their own is still a
  question only use can answer, and `LANE_SORT` is a one-line change when it
  does.
- `u`, end to end. It spawns `bin/refresh` as a child, and nothing here has run
  one: the token is read-only for writes but a refresh is thirty seconds of real
  requests against the user's own `data/`, so the pieces around it are tested
  and the run itself is not. What is unproven is the shape of the child's exit
  and the status line built from its last output line, not the refresh, which is
  the same one `wl refresh` has always run.
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

- **Auto-populating `[events].repos` from what you watch.** Done as far as it
  should go: `wl watching` reads `/user/subscriptions` and prints the untracked
  ones as quoted TOML lines, ready to paste into `[events].repos`, with the
  tracked ones commented out beside them. Deliberately not a live source — the
  file stays the user's, and a repo you stopped caring about does not come back
  because you never got round to unwatching it.
