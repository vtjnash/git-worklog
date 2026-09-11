# TODO

## What is next

One thing is open, and it is an idea to design rather than a task to pick up.
The state axis that stood at the head of this list is **built**, and so is
"showing what changed" - see "THE STATE AXIS" and "Showing *what* changed" under
Outstanding work for what each settled and what each left open. The drag that
stood second here was the last thing waiting on a real terminal, and it is
answered: see "Unverified" at the foot of this file. Everything else that stood
here is done; `git log` is the record of it and this file is not.

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

Blocked, and still the largest thing on the list: **every write is
unexercised.** `post_comment`, `add_review_thread`, `submit_review`,
`discard_pending`, the label toggle and now `merge_pr` are written and none has
ever been sent, because the token here is read-only. It is the only part of the
program where a failure loses work — the draft-review machinery exists precisely
because five careful comments are easy to lose — and it needs a fine-grained PAT
with `issues: write` and `pull_requests: write` on the repositories being
reviewed. See Infrastructure.

`merge_pr` is the one of them that is not like the others, and the only key in
the program whose mistake lands in somebody else's repository: a comment, a
verdict and a label can each be answered with another write, and a merge cannot.
It is why `^s` there asks before it sends, which nothing else that writes does,
and why `expectedHeadOid` goes with it — the first thing to verify when the
token arrives is that a stale head is refused rather than merged over.

Waiting on other people rather than on us: **FedeClaudi/Term.jl#304**, **#305**
and **#306**, and **JuliaLang/julia#63081** - the four bugs this program works
around in `escape_source` and `for_term`. When each lands and a release carries
it, those workarounds are what to delete - see Upstream, below.

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
three panes: the item list, its metadata, and a detail pane that is the thread
(`o`), the diff (`d`), what has been pushed since you last looked (`p`) or the
checks (`c`).

Beyond GitHub it also knows about *local* work: a branch with no pull request
can be adopted and becomes an item like any other, and finished work is archived
rather than deleted.

It also hosts programs. A tmux session per worktree can be opened on an item
(`t` a shell, `T` an agent), drawn in a pane beside the thread and driven by
forwarding the bytes you type, so the browser needs no model of what is running
in it. `^]tab` - or `^][`, the same roll with the left hand never leaving
control - moves the keyboard between the child and the thread beside it, so
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
./cli/bin/wl next 10           # pull untriaged items from the pile
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
whole dashboard in the background, `w` cycles the three orders, `x` files it away,
`z` undoes the last local action. A click on a url copies it, whole even where
the wrapping cut it, a double click copies the word - or the item's url, in the
list - and the `⧉` at the end of every header copies that block whole. A drag
over the reading pane selects rows for `y` to copy and `c` to comment on, and
`shift-J`/`shift-K` or the shifted arrows do the same from the keyboard. The list opens newest first - by when anything last
happened, yours or GitHub's - and `w` reaches the other two orders: the
interaction clock, and the url (owner, project, number, descending). A row that
leaves the list under you - `r`, `x`, `s`, each of which takes it out of the
list the browser opens on - leaves the cursor where it was rather than at the
top, and coming back to an item lands on the line you were reading in it, per
item and per mode.

`'` is the named views - nine built in, more from `config.toml`, and its last
entry copies the current filter as the TOML that would name it. The first ten
are on `1`-`9` and `0`; `` ` `` goes back to the filter you were in before.

`f` opens the filter pane. Every axis there is a **set**, and an empty set
restricts nothing - except the first, **show**, which adds rather than narrows
and where empty is therefore no rows at all. Its five boxes are `unread, awake,
open` · `read` · `snoozed` · `filed away` · `closed or merged`, each bringing
its own kind of row beside the others; the first is on when nothing has been
asked, and unchecking it is how one of the other four is asked for alone. Then
**tag** (second look · touched · drafts), and category, repo, label and author -
each long one listing its head and offering the rest as a picker you type into.
`kind` is the one radio, being three values that exhaust each other. `c` clears
to the first box alone, which is where the browser opens; the corpus is all
five, and `'` has it by name.

There is no `active` and no `backlog`: they were one fact - which lane fetched
the row - wearing a state's clothes, and what takes something out of view now is
dismissing it, one item at a time, recorded and undoable.

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
hosted pane every key belongs to the child except the prefix `^]`: `^]tab` and
`^][` read the thread beside it, `^]q` leaves it running, `^]K` ends it, `^]a`
goes full screen, `^]r` re-reads, `^]]` sends a literal `^]`. A composer is
drawn in the same split - `c`, `A`'s body and `M` open beside the diff they are
about, with `tab` between them - which is why the merge composer cycles the
operation with `^x`: `tab` moves the keyboard and does nothing else, anywhere.

Use the `julia` on PATH (juliaup, 1.14-DEV). The in-tree
`/home/vtjnash/julia/usr/bin/julia` does **not** run in this sandbox — it is
linked against a newer glibc.

### Layout
| file | role |
|---|---|
| `cli/src/gh.jl` | GraphQL search lanes, shelled through `gh api graphql` |
| `cli/src/events.jl` | the incremental inbox and live thread fetch (submodule `Events`) |
| `cli/src/refresh.jl` | normalize, bucket, fingerprint, snooze, bulk cache, the snapshot diff |
| `cli/src/marks.jl` | what you have done to an item: seen, touched, snoozed, drafted — five keys in its `local.toml` block |
| `cli/src/fetched.jl` | the other half of `data/`: `fetched.json`, everything GitHub can answer again |
| `cli/src/state.jl` | the line-based `local.toml` editor - one block per item, repo or adopted branch - and the `next` queue |
| `cli/src/controller.jl` | the view controller that owns stdin; input decoding; the `View` protocol; `ChooseView` and `ConfirmView`, and the two thin wrappers that make `TermInput`'s widgets views |
| `cli/src/browse/` | the browser: filters, panes, folding, diffs, checks, writing (`Worklog.jl`'s include list is the index) |
| `cli/src/ci.jl` | check contexts and Buildkite drill-down |
| `cli/src/repos.jl` | repo → local checkout mapping, the worktree/branch survey, `git show` |
| `TermIFrame.jl/` | the tmux half, split out: sessions, the control-mode client, and the box a hosted program is drawn in (`bordered`, which used to be `pane`). Its own package and its own repository, MIT — `cli/Project.toml` `[sources]` points at the checkout beside this one until it is registered |
| `TermInput.jl/` | the composer half, split out: `TextBuffer` (the editing model, with no view attached), `TextArea`, `LineInput`, the key vocabulary they bind, the dialog box in Term's box characters, `CHROME` (the three weights a host draws that box in - this program sets it from the theme, and `TermIFrame` reads the same one), `suspend`, and the escape-aware text measuring under all of it (`awidth`/`afit`/`apad`/`amid`/`awrap`, which used to be `TermIFrame`'s). Same terms, same arrangement. `TermIFrame` depends on it for the measuring, so the dependency runs iframe → input and never the other way: a text field must not pull a tmux binary in to measure a string |
| `cli/src/paneview.jl` | a `TermIFrame` drawn beside the thread it is working on; the worktree list |
| `cli/src/theme.jl` | every colour the program prints: the roles, the spec language they are written in, and the file under `themes/` that `config.toml` names. Nothing else emits an SGR escape, and with no theme named nothing emits one at all - Term's output included, which is stripped rather than left speckled with its own resets. Also the two palettes that are Term's: `[term]` is `TERM_THEME[]` (markdown, and the box *characters*), `[code]` is `Term.CodeTheme` (the tree-sitter captures), both translated from our spec language into Term's |
| `themes/` | the theme files themselves, hand-edited and read-only to the program. `default-ansi.toml` is the sixteen ANSI colours plus the 256 cube, and reproduces byte-for-byte what was hard-coded before there was a theme; `github-light-256.toml` and `github-dark-256.toml` are GitHub's Primer palette snapped to the 256 cube, fixed colours that ignore the terminal's own scheme and therefore come as a pair, one per ground |
| `cli/src/cache.jl` | on-disk cache with TTL |
| `cli/test/runtests.jl` | everything testable without a terminal |
| `cli/test/latency.jl` | the three startup waits, measured; not part of the suite |

**The state lives in `data/`, which is its own git repository.** It stopped
being ephemeral — `local.toml` is the record of what you decided and what you
have done: the notes, snoozes and adoptions, and beside them what has been read,
acted on, drafted and armed — so it is worth a history, but not the code's:
mixed into this one it buried the diffs that matter and dirtied the tree on
every refresh. `datapath(name)` resolves it; `WORKLOG_DATA` points it elsewhere,
which is how a test gets a disposable one. `config.toml` stays beside the code,
being configuration rather than state.

**Careful: `git rev-parse --show-toplevel` from inside `data/` answers with the
data repo.** Run it from the code checkout, or keep an absolute path.

Owner rules still matter: `config.toml`, `themes/*.toml` and `data/local.toml`
are **yours** — nothing rewrites any of them, and every write to `local.toml` goes through a
line-based editor that changes the keys it names inside the block it names and
leaves every other line byte-identical. The rest of
`data/` is machine-owned, and `fetched.json`, `cache/` and
`errors.log` are gitignored inside it as re-fetchable or noise. `errors.log` is
written by the browser when something throws, and deleting it is how its
standing footer warning is dismissed.

### The second look
Derived every refresh, never stored, and the opposite of a snooze: it needs no
asking for, because the failure it catches is work going quiet without anybody
deciding it should. It fires on two shapes of silence - the author spoke or
pushed and nobody answered, or somebody approved it and nothing happened after -
measured in *working* days, past a floor (`second_look_days`, 2) and with no
ceiling - there was one and it went, along with `stale`'s eviction, for the same
reason. Only for work you are carrying: the background pile is full of other
people's pull requests where the author spoke last.

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
- The suite pins the theme to `themes/default-ansi.toml` before anything runs.
  Without that, a `theme = ""` in `config.toml` would make every assertion about
  a bold row or a cursor background pass by saying nothing: `occursin("", x)`.
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
  testset that hid behind `archive.jl`.

  **Nothing has to be exported for them to run any more.** `TermIFrame` depends
  on `tmux_jll` and falls back to it, so a fresh sandbox with no tmux installed
  still drives a real server - `julia --project=cli cli/test/runtests.jl` and
  the whole session, pane and worktree half runs. It used to need
  `WORKLOG_TMUX` pointed at the artifact *and* a three-directory
  `LD_LIBRARY_PATH` (without which the binary died with `libutf8proc.so.3:
  cannot open shared object file` and every session test *failed* rather than
  skipping); `mux_cmd` builds the command from the JLL's own `Cmd`, which
  carries those paths, so there is nothing left to get wrong.

  `WORKLOG_TMUX` still wins over everything, which is how to test a particular
  build; `PATH` still beats the bundled one, so an existing tmux and the
  sessions in it are what a real run uses.
- **Every path the program writes through is redirected at the top of the run**
  — `LOCAL` and `FETCHED` seeded from the real files, `CACHE_DIR` started
  empty. The rule is that *all* of them go, not that each leak is fixed as it
  turns up: `local.toml` was found by an adoption testset whose `finally` did
  not run, and the read stamps by a test that pressed `r` and stamped a real
  item as read. A testset that points `LOCAL` at a temp file puts it back to
  `REPOS_SANDBOX`, never to `""`,
  which means the user's own file again. `errors.log` is the deliberate
  exception — the suite deletes the real one at startup and several tests assert
  on the footer warning it produces.
- **The suite runs against `Worklog` directly** (`--project=cli`), never through
  `cli/precompile`. That is the point of the wrapper being a separate package:
  the workload is `wl`'s tax and not the edit-test loop's.
  The protocol itself needs none of that: `mux_feed!` is a pure function of one
  line and the state before it, driven from a vector of strings the way
  `readevent` is driven from an `IOBuffer` — and it lives in `TermIFrame` now,
  with its own suite (`julia --project=TermIFrame.jl TermIFrame.jl/test/runtests.jl`,
  which honours `TERMIFRAME_TMUX` the way this one honours `WORKLOG_TMUX`).
  What is left in `cli/test/suite/mux.jl` is this program's use of it: the names
  it builds and the tags it files sessions under.
- **The composer has a third suite, and it needs nothing at all**:
  `julia --project=TermInput.jl TermInput.jl/test/runtests.jl`. Everything there
  is pure - the buffer, the wrapping, the cursor-to-row mapping, `render`,
  `handle!` - and the one thing that touches a terminal, `suspend`, is asserted
  on the escape sequences it writes to a redirected stdout. The `$EDITOR` path
  is driven through `InteractiveUtils.define_editor` rather than by installing
  an editor. What is left in `cli/test/suite/composer.jl` is this program's use
  of it: escape asking before it throws words away, `^s` reaching the callback
  that opened the composer, and `^r` dropping in the block the caller handed
  over.
- Time is an argument, so a test says when "now" is by passing it rather than
  by setting a global first: `snooze_active(url, st, fp, snz, at, cap)`,
  `comment_nodes(it, at)`, `handle!(st, key, ctrl, at)`. That is what makes
  "measured from when the operation started" assertable at all — a global could
  not tell that apart from a clock read halfway through the work.
- The suite deletes `errors.log` at startup. The standing warning takes the
  footer's second row, so a log left from a previous run fails every test that
  asserts what is written there.
- The events lane is an **incremental sync**, not a window: `fetched.json`'s
  `inbox` holds a cursor per source and everything it has seen. A source seen for the
  first time starts at *now*, so turning one on is inbox zero. The read stamp
  is still what decides an item leaves.
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

**The two package splits are the other kind, and the difference is the point.**
`TermIFrame` moved nothing either - `mux.jl` and the top of `paneview.jl` went
across as they were. `TermInput` deliberately did not: a composer that is a
`View` of this program's cannot be a package, so the editing model came out from
under the view, the callbacks became returned actions, and the keys this program
owns became `:unhandled`. That is a rewrite with a suite in front of it, not a
slice, and it is the only one of the four that is. The rule above is about
splitting a *file*; splitting a *package* is a design change or it is not worth
doing.

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
three waits, both projects, interleaved, best of three. **It had stopped
running**, and the numbers above predate that: the probe redirected
`Worklog.STATE` - a ref renamed `LOCAL` some time ago - so it threw an
`UndefVarError` before it measured anything, and behind that it also pointed
`FETCHED` at an empty temporary directory, where every probe would have died in
`loaditems` with "nothing fetched yet". The rule the docstring states is
*writes*, and a probe only reads; `LOCAL` and the cache are redirected and
`fetched.json` is left alone. With `Term` 2.2 and the real two thousand items it
now prints 1.36 / 1.46 / 1.73 against 1.32 / 4.79 / 5.13 - the wrapper saves 3.3s
on the list and 3.4s on the thread, and costs 0.05s on `--help`. It is not a
test and not part of the suite — a ceiling asserted on a shared machine would be flaky, and
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
Resolved fresh it is not — a fresh resolve is free to move versions the other
project has pinned, and the two images would then be built from different code.
The cure is to copy `cli/Manifest.toml` over, fix the two relative paths (the
copy sits one directory deeper, so `../TermIFrame.jl` becomes
`../../TermIFrame.jl`, and the same for `TermInput`), and `Pkg.resolve()`, which
keeps every version and adds only `WorklogPrecompile`. Check it with:

```bash
diff <(grep '^\[\[deps\.' cli/Manifest.toml | sort) \
     <(grep '^\[\[deps\.' cli/precompile/Manifest.toml | sort)
```

which should print exactly one line, for `WorklogPrecompile` itself.

**What `Term` 2.2 costs, and where it goes.** This used to warn against the
newer `Term` because of what it drags in; it is the pinned one now, taken for
its tree-sitter code renderer, and the warning is the price tag instead.
`Highlights` 0.6 depends on `TreeSitter` *and on `Pkg`*, and with `Pkg` come
`LibGit2`, `Downloads`, `Tar`, `LibCURL` and four jlls — 66 manifest entries to
83. Measured on this machine, `using Worklog` went **0.98s → 1.34s**, and
`using Pkg` alone is 0.345s: the whole of the regression is `Pkg`, on every
launch of a dashboard that never resolves a package. See Upstream for what
`Highlights` wants it for, which is one registry search on an error path.

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

**A whole refresh is a burst, and only some failures were worth retrying.**
Found by deleting `data/` and starting from nothing on 2026-09-10, which is the
one arrangement that had never been run: with the bulk cache gone there is no
previous copy behind any lane, so every one of them that failed came back empty
instead of stale. Five did, and the dashboard was 541 items instead of 2160.

Two classes were missing from the retry list, and neither is a 5xx:

  * **`You have exceeded a secondary rate limit`** - not the hourly quota, which
    was 5000 of 5000 while this was being returned. It is the burst limit, it
    clears in minutes rather than seconds, and it was fatal on the first
    attempt. It gets three tries at a minute, two and four; the 5xx schedule
    caps at thirty seconds and would spend every attempt inside the window.
  * **`unexpected end of JSON input`** - `gh` saying the body stopped early, so
    a truncated response and not a bad query: the lane it kept dying on
    succeeded on its own a minute later with the same string.

The second was invisible for two runs because the failure row spent 68 of its 80
characters re-printing the query it already names in its first column, so it
read `commented_pr FAILED ... : unexpected ` and stopped. **A failure line that
truncates has to truncate the part that is derivable, not the part that is
news.**

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
   at all — `TermIFrame.bordered` and `TermInput.dialogbox` draw the boxes, out
   of Term's box characters and against real display widths. Term is only a
   markdown→ANSI converter. The same rule bites the other way in a composer:
   a `{` somebody *typed* is not a tag, and markup measurement deletes it.
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
    through `escape_source` first.

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

**local.toml**
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

**A colour is a role, never an escape.** Every SGR sequence in the program comes
from a field of `THEME` (`cli/src/theme.jl`), and a call site names what the
colour *means* - `THEME.blocked`, `THEME.diff_add` - rather than which colour it
is. The two palettes that belong to Term are set from the same file and are
where a surprise lives: **the colours of a highlighted code span are not in
Term's theme.** `Term.CodeTheme` is a `const` binding to a plain `Dict` of hex
strings keyed by tree-sitter capture, unreachable from `set_theme`, and the
theme fields that look like they do that job - `string`, `number`, `operator`,
`type` - drive Term's older regex highlighter, which the markdown path stopped
using in 2.2. The `Dict` being mutable is the only reason a theme can reach it. Two consequences worth knowing before adding one: a table of colours built
at the top level captures the theme *before* it is read, which is why
`rev_mark`, `ci_color` and `range_mark` are functions and not the `Dict`s they
were; and a role drawn inside other colour needs the `<role>_off` closer rather
than a reset, or it ends the background it was drawn on. Adding a role means a
field in `Theme` and a line in every theme file - the suite asserts both
directions of that.

**Key bindings: a capital reaches GitHub, lowercase does not.** `C`, `A` and `L`
post a comment, submit a review and set a label; everything lowercase stays on
this machine, `r` and `s` included — `local.toml` is a local file, and `e` only launches an editor. The line is *remote*, not *writes
something*, which is also why `z` below can offer to undo the lowercase set and
must never offer to undo the capitals.

## Outstanding work

Roughly in the order it is worth doing, and none of it is on the critical path
of "What is next" at the top. Nothing already shipped is listed; `git log` is
the record of that.

### "Waiting for a reviewer" is built, and the gap is the order

Asked for on 2026-09-10 as if it were new; it is not, and this is the note so it
does not get asked a third time. **`'` then `2`, "waiting on me"** is the view:
`state = second`, `kind = pr`, `author = @anyone-else`. Twelve rows on the
2026-09-10 dashboard. **`'` then `3`, "waiting on them"** is the same question
about your own pull requests - eight rows - and between them they are both
directions of "the author had the last word and nobody has answered".

Every part of the request is already in `second_look` (`refresh.jl`), which
derives `second_look` on every item every refresh and answers with the sentence
the metadata pane shows:

- **The last action was the author.** Three cases, checked in order: an approval
  that is the last thing to have happened, the author commenting with nobody
  answering (`last_comment_by == author`), or the author pushing with nobody
  saying anything since. Anything else answers `""` and the row is not in the
  lane - so a *reviewer* commenting takes it out on its own, without needing to
  be dismissed.
- **Older than a threshold in work days.** `second_look_days = 2` in
  `config.toml`, counted by `workdays_since`, which exists precisely because two
  days of silence over a weekend is a weekend and not silence.
- **And no ceiling.** `second_look_max_days` used to stop it at 20 work days;
  see below for why that went, and why `stale` went with it.

**Dismissing one is `s` then `1`, and yes, it is exactly the snooze.**
`on-change` records a fingerprint of the item at its tracking level and hides it
until that fingerprint changes; when it does, `snooze_active` writes `WOKE` and
*stays* awake rather than re-arming, so there is no single-refresh window in
which to notice. It comes back unread on its own - the read cursor was stamped
when it was snoozed and whatever moved it is newer than that - which is the
whole of the "reenters as unread" half. At `normal` track the fingerprint is
`head_at`, `review_decision`, `ci`, `unresolved`, `review_count` and
`last_comment_at`, so a new push wakes it and so does CI going green. Nothing
new to record: the snooze marks are already this.

**Newest first, and that is the policy rather than the default it looks like.**
`lane_sort` gives `:second` the ordinary `:latest`, and all of `SORTS` is
descending. Asked about on 2026-09-10 and answered: it is deliberate, and the
reason is what to do when the lane cannot be drained.

Serving it newest-first means new work is answered quickly and old work gets
older. Serving it oldest-first means everything is answered at the same
mediocre speed. The first is worth more: an answer while the author still has
the change in their head, against a diff that still applies, is a different
thing from the same answer three weeks later - and a pull request that has
already waited a fortnight is not rescued by being fourth in the queue instead
of fortieth. Uniform slowness is the outcome nobody wants and the one a fair
queue produces.

So: no fourth sort, and `w` still cycles three. If this comes up again, it is
this paragraph that is the answer.

**And the ceiling came off, for the same reason the order stays.**
`second_look_max_days = 20` had been the other half of this - past the cap the
quiet stopped being reported, on the grounds that a pull request nobody has
touched since last spring is a different problem. It is a different problem, and
a cap was the wrong way to say so twice over: the crowding it was solving is
what newest-first already solves, since an old row is at the bottom rather than
in the way; and a row leaving the lane because a number in `config.toml` was
exceeded leaves on a day nobody chose, with nothing written down and nothing to
undo.

`s` `1` is what takes one out now. That is a decision somebody made, it is in
`local.toml`, `z` undoes it, and it comes back on its own when the thing finally
moves. None of those is true of a threshold.

Worth thinking about separately, and not obviously worth doing: the lane is
called "second look" in the filter pane, which is what it does and not what it
is for. Nobody looking for "who is waiting on me" finds it by reading that.

### The modes — built, and what it left behind

**What the work actually is, in the user's own words:** two modes. Either
*wanting my own work - what I am editing as a (co)author* - or *reviewing what
came in from everyone else*. Not ten lanes; two, plus a pile. It turned out to
be three, the pile being one of them rather than a thing the other two subtract.

**The modes are done** (2026-09-10). They are views, not lanes, because each is
one axis answering one question: `'` `2` is "my work" (`@me` + open + awake, 155
rows), `'` `1` is "what moved" (the seen axis, 2157), and `'` `3` is "open
items" (the pile, awake, 2148). (`'` `1` is the "notification firehose" now, and
names no axis at all: the list it goes to is what is left when every filter is
off. See "The dispositions are one axis now".) The `mine` lane is gone - it said `author == login()` inside
the state axis, which is the author axis written twice in the place it does not
belong - and so is `active`, which was the *lane* axis written where a state
belonged.

`mine` could not go until `stale` stopped evicting, which happened the same day:
it was the only lane that did not subtract the pile, so it was the only place
your 44 quiet pull requests could be seen.

What follows is what that left open, with what has since happened to each.

Three things follow, and none of them is what the lanes do today:

- **`mentioned` and `reviewed` are query filters, not lanes.** They are what you
  reach for when *searching* for something. `mentioned` is 1098 rows and is the
  largest bucket there is - it is a corpus, and the corpus is not a to-do list.
- **GitHub's own state is the less trustworthy half.** Review-requested,
  mentions, the review decision: all of it is worth having and none of it is
  worth *believing* over the unread cursor and the snooze, which are this
  program's own and are the two things it was written to own. A lane built on
  what GitHub thinks is owed is a lane that keeps being wrong; one built on what
  you have read and what you have put off is not.
- **The firehose is a place to go on purpose, not a leak.** 901 open pull
  requests, browsed slowly, to promote (review it, merge it) or archive. That is
  a third mode and it already has a home; what it does not have is the two verbs
  as one keystroke each from inside it.

**A review request is a move, not a state, and `needs-review` treats it as one.**
Somebody asking you to review is an *event*: it moves the item, which makes it
unread, and from that point what happens is a local decision - act on it, or
snooze it. `needs-review` instead reads GitHub's standing `review-requested`,
which keeps saying the same thing for as long as the request is open however
many times you have looked at it and decided not yet.

**Done** (2026-09-11). The visibility half was already: a review request no
longer *puts* anything anywhere, because the lane it used to put it in is gone -
it is a bucket you can filter on and nothing more, and whether the row is in
front of you is the seen axis's answer. The event half is what landed now.
`reviewRequests(first: 20)` joins `PR_FIELDS`, `review_requested` joins all
three key sets, and a re-request makes the item unread.

It had to be fetched because nothing else moves when somebody asks you again:
`reviewDecision` stays where it was, `review_count` stays where it was, and the
re-request button posts no comment. A first request arrived as a new item and
was unread for that reason; every one after it was silent.

**In all three levels, which nothing else fetched per-lane is.** It is not a
property of the item that might interest you, it is somebody naming you - and
`loose` exists to ignore a stranger's CI and a bot's comment, which is the
opposite of that.

**True or absent, never `false`.** The value is hashed into the fingerprint, so
`false` written on every row would differ from the missing key on every row
already in `fetched.json`, and the first refresh after this shipped would stamp
the whole dashboard as moved. Checked against the real file: of 2159 stored
rows, **0** change fingerprint when the key arrives absent, and all 2159 change
when it arrives true - so the key is live at every level and inert for the rows
that do not carry it. What flips on the first run is the 46 items the `review`
lane returns, which go unread because you are in fact being asked about them.

**One point per page, measured.** The `review` lane costs 3 without the
connection and 4 with it, over 46 items. It is not in `FIREHOSE_QUERY`, for the
same reason `reviewThreads` and `reviews` are not - and it does not need to be,
because an active lane claims a requested item before the bulk sweep sees it.

**`requestedReviewer` can be null**, for a reviewer that is neither a User nor a
Team - a deleted account, or a type the selection does not spread.
JuliaLang/julia#62245 has one today, which is why the lookup goes through `jget`
rather than a field access.

What it does not reach: a request of a **team** you are in. `/user/teams` is 403
for this token, so there is nothing to match the slug against - see
Infrastructure, where the same wall stops `team:ORG/TEAM` being settled.

**One thing mode one could not express, half of which is now fetched.** `mine`
was `it.author == login()`. "What I am editing as a **(co)author**" is wider,
and **assignee is now in** - every lane asks for `assignees`, so an issue GitHub
put on you is yours however it was found. Still outside: a pull request somebody
else opened that you have pushed commits to, or that carries you in a
`Co-authored-by` trailer. GraphQL will answer the first
(`commits(...) { authors }`) and the second only by reading commit messages.
Neither is free, and neither has been costed.

### THE STATE AXIS — built, 2026-09-10 and -11

Designed and built in one long session, and written out here because the design
changed twice while it was being built and the reasons are worth keeping. The
whole of the build order below is done; what follows is what it settled, and
what the day after it settled about `track`.

**Three of the four axes have since merged into one that only adds** — see "The
dispositions are one axis now" at the end of this section. The three questions
below are all still asked of every row; what is gone is the ability to answer
them with *no*.

#### One radio was answering four questions

`state` was a single exclusive choice over ten values that were not alternatives
to each other: `unread` and `snoozed` and `active` and `backlog` answer
different questions, so asking one of them meant giving up the answers to the
rest. Four axes now, each a set, each empty-means-everything like the tag axes
beside them:

| axis | the question | values | from | what changes it |
|---|---|---|---|---|
| **seen** | has it changed since I looked? | unread · read | the read stamp against `moved_at` | `r`, and any movement *at this item's level* |
| **sleep** | do I want to see it? | awake · snoozed · filed | one `snooze` field | `s`, `x`, and a wake condition coming true |
| **state** | is it finished? | open · closed or merged | GitHub | GitHub |
| **tag** | anything else worth asking | second look · touched · drafts | derived, or a mark | the refresh, and what you do |

with **whose** (`@me` = author or assignee · `@anyone-else` · logins), **kind**
(a radio: pr · issue · both) and **category/repo/label** unchanged beside them.

The browser opens on `unread · awake` - what moved, minus what you have said you
do not want to see - and `c` clears to *nothing*, which is the whole corpus
including what you filed. Both are one keystroke from the other. (Both halves of
that changed when the three merged: `c` now lands where the browser opens, and
the corpus is a view by name.)

#### The three corrections that arrived mid-build

The first draft of this had one five-value enum (`unseen · unread · read ·
snoozed · archived`), a source axis, and `mine` meaning `author == login`. All
three were wrong, and the corrections are the model:

**1. Movement always makes an item unread. Nothing overrides it.** Not a snooze,
not a filing. Unread is not a claim about wanting to see something - it is a
claim about whether it has changed since you last looked - so attention and
decision are two axes, and fusing them into one enum with a precedence rule was
the mistake. It also killed `unseen`: with movement always unreading, "never
opened" is a refinement of unread rather than a value beside it, and what takes
something out of the pile is dismissing it rather than looking at it.

**2. Archive *is* a snooze with no wake condition.** Both say "I do not want to
see this" and differ only in whether anything brings it back. So `parse_snooze`
gained `forever`, `x` writes it, `archive!` is four lines over `apply_snooze!`,
and the `archive` field is gone. `snooze_why` already said which kind of sleep
it was.

**3. "Mine" is author *or assignee*, and a review request is neither.** Being
asked to review something, or being named in a thread, makes it **unread** -
which is the axis that answers "somebody wants something from me" - and does not
put it in your pile. Every lane asks for `assignees` now: 158 rows against 144,
at 52 rate-limit points on a six-hourly refetch and no extra requests.

**And the source axis is not wanted.** The draft proposed one - direct ·
participating · watching · pile - because today's `active` is exactly "a lane
asked for you" (141 rows + 20 promoted `needs-reply` + the local items = 162, of
which 158 awake). But those are GitHub's own filters, and GitHub is where to go
for them. What this program has that GitHub does not is the record of what *you*
decided, so what subtracts the pile is **dismissal**: one item at a time,
recorded, undoable. `active` and `backlog` are gone and nothing replaces them.

#### What `track` turned out to be (2026-09-11)

The axis was measured against GitHub's `updated`, and the question that found
the hole was "I want to know closely when my PRs get an approval or CI finishes,
but not anyone else's". **`updated` cannot answer either half.** It does not
move when a check run finishes - julia#62841 is stamped 20:55:52 and its three
suites completed at 20:56:04, :07 and :19, and it has not moved since - so CI
turning green had never once made anything unread. And it *does* move for a
label edit on a stranger's pull request.

The thing that did know is the fingerprint, which has `ci` in its key set - and
it only ever spoke when a snooze woke. So:

  * the refresh records **`moved_at`**: when it last saw a change at that item's
    tracking level. The old row is re-fingerprinted at *today's* level rather
    than read out of its stored `fp`, so changing `track` is not itself
    movement; first sight seeds from what GitHub says, so a rebuilt
    `fetched.json` does not read as everything moving at once. Unlike a snooze,
    which compares against the value armed when you said "not now", this is
    "since you last looked" - a red-green-red flap is two stamps.
  * **`track` asks whose it is**, which it never did: it defaulted by bucket, so
    your pull request and the one you were asked to review were both `normal`.
    Whose it is now decides, and *before* the lane rules - 66 items of your own
    reached through a mention lane were `background`, whose key set is empty, so
    a reply on your own issue could never have made it unread.
  * **two levels, not four.** `close` was `normal` plus `mergeable` and
    `labels`, a distinction nobody sets by hand; `background` was a dismissal
    you could not see or undo. What is left says itself: *your unfinished work
    is tracked normally, everything else loosely* - 156 and 2003. `all` is the
    key set `fp_full` hashes at, is not a level, and `wl track` will not take it.

So `track` is one knob for "what counts as movement", governing the unread bit
as well as the snooze wake, which is what it has always read like it did.

#### The three work modes, one selection each

  1. **mine** — `@me`, meaning author or assignee. 159 rows against the 77 that
     `active` + `@me` gave: the difference is your own issues and pull requests
     that arrived through a mention or comment lane and were filed in the pile
     for it, plus the 16 issues GitHub has assigned to you.
  2. **what moved** — the seen axis, and the "notification firehose" since the
     dispositions merged. Everything that has changed since you looked at it,
     whoever moved it and wherever it came from.
  3. **open items** — `open` + `awake`, which is the base box rather than a
     selection: the view checks that and `read` beside it. 2148 of 2160, and
     the way it goes down is `s` and `x`, not `r`.

All three are views, and `'` reaches any of them in one keystroke.

#### The files, which fell out of it

Two, and one line between them - **what GitHub can answer again, and what it
cannot**:

    fetched.json   {items, bulk, inbox}          re-fetchable, ~4MB, untracked
    local.toml     one block per item, repo or   yours, small, tracked
                   adopted branch

`fetched.json` was `facts.json` + `bulk.json` + `inbox.json`, split by which
part of the fetch wrote them rather than by what they are. `local.toml` was
`state.toml` + `marks.json` + `repos.toml` (and before that `read.json`,
`touched.json`, `snooze.json`, `drafts.json` and `queue.json`), split by which
key press wrote them. Your note and its read stamp are two lines of the same
block now.

The line editor grew `set_blocks!`: any number of blocks, one pass, one write,
nothing written when nothing changed. `wl read` stamping 852 items is 60ms.

No migration was written for any of it, and none was needed: everything in
`fetched.json` comes back from a refresh, and the four small files were
converted once by hand on the day.

#### What it left open, and what became of it

  * ~~`wl next` pools on `Item.backlog`.~~ **Done.** `in_pile(r)` is the
    predicate, asked by its two callers - `second_look` and `wl next` - and the
    field is gone from every row and from `Item`.
  * ~~`track = "background"` stays, being snooze sensitivity rather than a
    lane.~~ **Gone too**, with `close`: the levels are `normal` and `loose`, and
    `track` now decides whether an item is *unread* as well as whether a snooze
    on it wakes. See "How closely you track an item" in the README.
  * ~~The rows only the poll knows about are built in a second place from a
    second shape.~~ **Done.** `poll_item` is that conversion, beside
    `inbox_row`, which is the same conversion the other way. It carries
    `updated`, `act` and `state` now, which it did not: 634 rows that always
    read as open and always as unread can now be finished, and can be read.
    Their bucket is `activity` rather than `unread` - the poll is what they
    are, and `unread` was the same word on two axes in one pane.

#### The dispositions are one axis now (2026-09-11)

`seen`, `sleep` and `state` were three axes that could each be turned off, and
what they had in common is that **turning one off is never what anybody wants**.
`seen: read` alone hid everything that had moved; `sleep: snoozed` alone hid all
the work; a row could be filtered out of the dashboard by pressing return on the
wrong line and the way back was not obvious from the screen. The eight built-in
views each had to spell `sleep = ["awake"]` to avoid it, which is what a default
looks like when it has been written in the wrong place.

So the three are one axis, `show`, and it only ever **adds**: five boxes, each
bringing its own kind of row in beside the others and none of them able to take
another's rows away. `unread, awake, open` is the first, and it is what this
dashboard *is* - the box that is checked when nothing has been asked - and the
four beside it are the four things that list leaves out: `read`, `snoozed`,
`filed away`, `closed or merged`. All five is the corpus. What follows from
that:

  * **`c` and the opening filter are the same place.** Clearing every filter
    leaves the list the browser opens on, because "cleared" for this axis is
    the base box rather than the empty set. The corpus is reached by name
    instead - `'` `9`, "everything" - and by the two jumps that need it (a
    number typed into `/`, and `i` from the worktree list), which set all five
    boxes rather than clearing the pane.
  * **The base is the fifth box** (2026-09-11, the same day). It began as a
    floor with no control at all, on the argument that every way of turning it
    off was a way of emptying the screen. That argument was about *accidents*,
    and it bought safety by making one question unaskable: the filed rows
    *alone*, rather than beside today's work. So the base is a checkbox like
    the other four, checked whenever nothing has been asked - by `c`, by a
    fresh `Filters`, by a view that names no `show` - and unchecking it is a
    deliberate press that nothing in the program does on your behalf. Every box
    off is an empty list, which is the honest reading of an axis that adds
    rather than narrows.
  * **The counts became a delta.** A tally of values makes no sense on an axis
    whose values are not alternatives, so each number is what its box is
    holding in - what checking it would bring, or what unchecking it would take
    away. A closed pull request you read last week is held out twice and counted
    under neither until one of the two is on.
  * **`read` is asked of awake work only.** Putting something away stamps it
    read - a snooze and a filing both do - so a `snoozed` box that also wanted
    the unread stamp would have shown nothing at all. This is the one asymmetry
    in the axis and it is written down in `show_ok`.
  * **A view names `show`, and an unknown key is now reported.** `seen`, `sleep`
    and `state` were keys in `config.toml`; a view still naming one would have
    gone on being applied and meant something else, so `apply_view!` says "no
    axis 'sleep'" the way it has always said "no seen 'unred'". A view that
    names `show` names the whole of it, `base` included - which is what makes
    `show = ["filed"]` a nameable view - and one that names none of it keeps
    the base, which is what "cleared" means here.
  * **"what moved" is the "notification firehose".** It is the same view - the
    one that names no axis at all - under the name that says what it is: every
    item that has moved and that you have not put down, which is the thing an
    email notification stream would have been.

### Showing *what* changed, not just that something did — **built**

Raised 2026-09-11, after `moved_at` made "has this changed at the level I asked
about" a thing the program can answer, and built the same day. Four ideas were
written down; all four are in. What they were, and what each turned into:

1. **A marker in the comment list, so the next comment arrives below a rule.**
   Built, and *without* the key the item asked for. The proposal was to record
   which comment you had got to; the stamp already answers that, because `r`
   marks the thread read up to the moment it was **fetched** rather than to now
   - so every comment written before the stamp was on screen and every comment
   written after it was not. A `read_seen` key would have been a second copy of
   an answer `read` already gives, and the two can disagree. `newmark_node` is
   the rule, `openrow` is the pane opening on it, and `st.place` still wins for
   a thread visited in this session, because in-session you were *somewhere*
   rather than at a mark.

2. **A range-diff since you last marked it read.** Built, as the `p` pane. This
   is the one that genuinely needed the mark to stop being a timestamp: a rebase
   is invisible to a clock, and the question is a diff between two commits. So
   the mark carries `read_head`, and `r` is the only thing that writes it - a
   snooze, an archive and `wl read` all stamp `read` while knowing nothing about
   what you were looking at, so they leave the sha alone rather than writing a
   wrong one.
   The fetch carries the other end: `headRefOid` and `baseRefName` are scalars
   beside `headRefName` in both queries, so every row has both for nothing, and
   `head_sha` only shells out for the rows no lane covers.
   Two commands rather than one, because a branch moves two ways.
   `merge-base --is-ancestor` decides: still reachable and the base unmoved
   means they only added to it and the plain `git diff` between the two heads is
   what to read; anything else means the commits are different objects, and
   `git range-diff` is the only thing that pairs the old ones with the new.
   The pane says which it used.

   **And the base branch is what makes the second one readable** (2026-09-11,
   the same day, after the first cut shipped without it). `git range-diff
   old...new` measures both sides from the merge base *of the two heads*, which
   after a rebase is where the branch originally left the base - so every commit
   the base gained in between falls inside the new range and is reported as
   newly pushed. Measured in a scratch repository: a two-commit pull request
   rebased over ten commits of master reported **twelve** commits, ten of them
   somebody else's, with the one real change last. Measured from `base` instead
   - `merge-base base old` and `merge-base base new`, one range each - it
   reports the two, and the ten become a number in the header: "rebased onto 10
   newer commits". An item with no base falls back to the old behaviour, and the
   pane says that is what it did.
   The base ref is fetched before it is measured against, because a stale copy
   is a wrong answer rather than an old one: every commit the checkout has not
   heard about yet lands inside the range. One ref, 0.26-0.52s against a current
   checkout, and an explicit refspec so what moves is the remote-tracking ref
   rather than the `FETCH_HEAD` every worktree shares.

3. **Interleave the pushes with the comments in one activity list.** Built, and
   `timelineItems` was not needed. What the item wanted from it was the commits
   and their order; `commits(last: 30)` is one request and one rate-limit point
   for exactly the end anybody reads, where REST pages forward from the oldest.
   The order then comes from the timestamps, which is where it was always going
   to come from - `timelineItems` would have supplied a second connection to
   page and a second shape to normalise for a sort this already does.
   Consecutive commits with nothing said between them fold into one "pushed N
   commits" entry. That is not GitHub's push event and does not pretend to be:
   two pushes a minute apart read as one here, which is what somebody coming
   back to the thread wanted anyway.
   It costs one GraphQL request per thread, started *beside* the REST reads
   rather than after them, and it lives in the thread's own cache entry rather
   than in one of its own - so one age covers everything the pane draws, and a
   cached thread can never be a miss on half of itself.
   Measured against JuliaLang/julia on 2026-09-11: the commits query is
   0.35-0.40s and the REST half of the same thread is 3.0-5.3s, so the overlap
   hides it completely and the pane costs what it always did.

4. ~~Two tracking levels, not four.~~ **Done** - `close` and `background` are
   gone; see `TRACK_KEYS`.

What it left open:

* ~~A force-pushed head can be unfetchable.~~ **It is fetchable, and that was
  measured rather than feared** (2026-09-11). The worry was that `read_head`
  names a commit reachable from no ref once the branch has been rewritten over
  it. GitHub serves it anyway: three orphaned heads taken from
  `HeadRefForcePushedEvent` on FedeClaudi/Term.jl - 2026-09-02, 2026-06-03 and
  2025-07-25 - all came back from `git fetch <remote> <sha>`, the oldest of them
  fourteen months after it stopped being anybody's head. The whole `p` path then
  ran end to end against `Term.jl#302`, whose old head is one of those three:
  0.98s, and the range-diff correctly reports the patch as unchanged, which is a
  CompatHelper recommit and is exactly what it was.
  What that leaves is not "the commit is gone" but "this repository or this
  network is not answering", and the pane now says so.
* **Which remote is the project is a question, and `origin` was the wrong
  answer.** A checkout of somebody else's work has two remotes and which one is
  called `origin` is whichever way round it was cloned - the Term.jl checkout
  beside this one has `origin` on the fork. `refs/pull/N/head` exists only on
  the project, so `ensure_commit!` was fetching it from a repository that does
  not carry one. `remote_for` matches the url instead, and `expand_hunk!` gets
  the fix too.
* **`p` needs a pinned checkout and always will.** There is no GitHub endpoint
  that compares two heads of one pull request; `compare` is between refs, and
  the old head is not one. The pane names both shas and says how to pin, which
  is the whole of what it can do.
* **There is no porcelain mode for `git range-diff`, and the invariant to lean
  on is the indent.** Checked on 2.54.0: the options are `--no-dual-color`,
  `--creation-factor`, `--left-only`/`--right-only`, `--notes` and the ordinary
  diff-format ones - and those last apply to the *inner* diffs, so `--raw` or
  `-z` would destroy the patch text that is the whole point while leaving the
  pair header exactly as it is.
  Two bugs came from reading the header's shape instead. Past nine commits git
  right-aligns the numbers, so an anchored pattern matched no row of a
  ten-commit range-diff and the pane said "no textual change". Allowing leading
  whitespace then matched the *wrong* rows: a diff whose own content looks like
  a range-diff header - which `cli/test/suite/since.jl` is now full of, so
  reviewing a change to it was exactly what would break - was read as three
  commits where git reported one, with the real diff filed under an invented
  heading. Both are in the suite now.
  What holds is that every line of an inner diff is indented by exactly four
  spaces before its dual-color marker, and a pair header's leading spaces are
  number padding. So `RANGE_PAIR` refuses any line with four, and fails only for
  a range of ten thousand commits or more - where the pane shows one unfolded
  node rather than an invented structure, which is the right way round.
  `git range-diff -s` prints the pair headers and nothing else, so splitting the
  full output at exactly those lines would need no pattern at all. It is the
  escape hatch if this ever needs more, and it is not used because it pays for
  the whole cost matrix a second time.
* **`git range-diff` shows nothing for a commit it could not pair.** A rewrite
  that kept too little reads as one commit dropped and one added, with no diff
  under either. That is git's `--creation-factor` and is left at its default:
  tuning it would trade this case for wrongly pairing two unrelated commits,
  and the header still says which commits are which.
* **`c` on a line of the `p` pane writes on the item, not on the line.** The
  hunks there are real and `[`/`]` widens them, because both read the new side
  and the new side is the head either way. Anchoring a *comment* is the half
  that does not carry over: GitHub's `LEFT` means the pull request's base, and
  the left side of this diff is the head you last saw, so a remark on a deleted
  line would land somewhere nobody deleted anything. Restricting it to the right
  side would work and is the obvious next move; `d` is one key away meanwhile.
* **The rule is per item, not per pane.** `p` has no "new since" of its own
  because it *is* the new since. The diff pane does not have one either, and
  the honest version of that is the inline comment box in "What is next" rather
  than a second marker.

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

### The intraword-emphasis bug — filed as JuliaLang/julia#63081
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

There was no existing issue - searched JuliaLang/julia for markdown +
emphasis/underscore/intraword/italic, and the closest was #57265, which is
`@md_str` interpolation and closed as a duplicate of something else.

**#63081 implements the fix**, in `stdlib/Markdown`, where the parser lives.
`parse_inline_wrapper` is shared by `*`, `_`, `~` and `$`, so the rule belongs to
the delimiter rather than to it: an `intraword` keyword, default `true`, that
the two underscore triggers pass as `false`. A run touching a word character on
its outer side can then neither open nor close, and in the closing case the scan
*continues* rather than giving up, which is what keeps `_foo_bar_baz_`
emphasised across its inner underscores. Reading the character before a run also
had to learn to step back over UTF-8 continuation bytes - the pre-existing
"previous character isn't a delimiter" check needed that too and never had it,
which is why the Cyrillic spec examples failed.

The acceptance test was already in the tree, which is the part worth
remembering: `stdlib/Markdown/test/` carries the CommonMark spec with a
`known_broken` set and a standing `@test_broken`, so a fix makes the suite fail
*on purpose* and `regenerate_test_spec.jl` rewrites the generated runners.
Seventeen more examples pass in each flavor and none newly fail. The loop ran
without building Julia at all: the module's source loads standalone as
`Main.Markdown` if it is copied somewhere writable and `include`d, so a change
could be measured against all 652 examples in seconds.

It also fixes a docstring in **#42068**, where a stray trailing underscore
swallowed the rest of a sentence and an inline code span with it - found while
looking for something the change would visibly improve, and worth knowing that
such a thing was easy to find.

**The workaround stays until this lands and a release carries it.**
`escape_source` escapes such an underscore before `Markdown.parse` sees it,
skipping fenced blocks, indented blocks and inline code spans, where a backslash
would print. (It is the same pass that doubles braces for Term, since both are a
markup layer eating characters that were text.) When the fix ships, that half of
it is what to delete.

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

### The composer is a package now — `TermInput.jl`

Split out the way the tmux half was, into a repository of its own beside this
one, MIT, on the same terms. It is a Term plugin: the box is drawn with Term's
box characters and follows `TERM_THEME[].box`, so a composer opened over a
screen of `Panel`s is bordered the way they are.

**What untangling it actually meant**, since the list of what it would need was
written here before it was done and each item turned into a decision:

- **The editing model came out from under the view.** `TextBuffer` is lines, a
  cursor and the operations - `insert!`, `newline!`, `backspace!`,
  `deletechar!`, `deleteword!`, `killline!`, `move!`, `insertblock!` - with no
  screen attached at all. A program that wants the editing and not the box
  stops there.
- **A key it does not bind comes *back*.** `handle!` answers `:ok` or
  `:unhandled` and nothing else, which is what replaced the callback table this
  program would otherwise have had to register with. It is the same rule
  `TermIFrame` uses for `^]`: the widget claims what is its, and a host claims
  its own.
- **And "finished" is not one of the widget's answers.** It started with
  `:submit` and `:cancel` as well, which was this program's policy wearing a
  package's clothes - the tell was the error string, `"nothing to send"`, which
  is a *comment* being posted and means nothing to a text box, and the
  `allow_empty` flag beside it, which is "an approval needs no words". A text
  box holds text and knows how to change it; it does not know what finishing
  means, whether an empty one may be sent, or what escape costs. So `^s`, `↵`,
  escape and `^g` all come back like any other non-edit, and `EditorView` and
  `PromptView` bind them - which puts every question this program answers about
  a composer in the same sixty lines as the discard dialog and the `^r`
  suggestion block, rather than half here and half in a package.
- **The measuring went the other way round.** The note here said it should be
  rewritten against Term's own measurement and that `Panel` was the thing that
  could not be trusted. Writing it down settled it: `Panel` measures markup, and
  a buffer full of prose is not markup - a `{` somebody typed is read as a tag
  and *deleted*, which is worse than the wrapping bug, because what is lost is
  what was written. So `awidth`/`afit`/`apad`/`awrap` moved *into* `TermInput`,
  and `TermIFrame` now depends on it for them rather than owning them. That is
  the only sane direction: an iframe needs the measuring and a text field must
  not pull `tmux_jll` in to get it.
- **`suspend` went too**, as `suspend(f, term; mouse)`. Anything holding raw
  mode has the same problem and none of them has anywhere to put it. What is
  left here is one line: `suspend(f, ctrl) = suspend(f, ctrl.term; mouse = ctrl.mouse)`.

**Two bugs the extraction found**, neither of them the split's:

- **The cursor was drawn at a byte offset.** `EditorView`'s render indexed the
  wrapped row with `line[ccol]`, where `ccol` is a *display* column - three
  different counts through one integer. It only ever agreed for ASCII: a row
  with an accent in it throws `StringIndexError` on the character index, and a
  row with a CJK character in it draws the block a column to the left of where
  the terminal puts it. Never seen because the render tests all typed ASCII.
  `drawcursor` walks by width now, and the suite types 日本語 into a composer
  and renders it.
- **A width of zero divided by zero.** `bufferrows` takes `pre % w`, and a host
  mid-resize can ask for a box with no room in it. One column is a legal answer.

**The readline set is surveyed rather than sampled.** `TermInput`'s README has
the whole emacs-mode binding table with each key marked implemented, skipped or
not relevant, which is what turned "the readline keys people know" from a claim
into a checklist. Filling the gaps it found added `^y` and a one-slot kill
buffer that `^k`/`^u`/`^w`/`⌥⌫`/`⌥d` feed - a run of kills is one yank, and
backward kills go on the front so `^w^w` yanks back in the order it was typed -
plus `⌥d`, `^t`, `^g`, and `^b`/`^f`/`^p`/`^n` as the motion keys they are in
every emacs-mode line editor. `readevent` grew one case for `⌥d`.

**`^u` changed meaning here, deliberately.** It killed the whole line and now
kills back to the start of it, which is readline's `unix-line-discard` and not
zsh's `kill-whole-line`. The two only differ when the cursor is not at the end
of the line, which is exactly when somebody meant one of them in particular -
and with `^y` there now, what it took is not gone either way.

**Undo is the one deliberate omission worth revisiting.** `^_` and `^x^u` are
not bound: the answer has been that `⌥e` opens `$EDITOR`, where undo, search
and your own keymap already live. That is a good answer for a long edit and a
weak one for the `^w` you did not mean, which is the case that actually comes
up. It is not free - a snapshot stack, and a rule for what counts as one
undoable step - which is why it is written down here rather than added.

**What is left to decide is the InputBox question**, which is its own section
below.

### `TermInput` and Term's own `InputBox`

Term has a widget of its own - `Term.Live`'s `InputBox` - and the honest summary
is that they are not the same widget. **`InputBox` collects keystrokes; this
edits text.** It has no cursor at all: characters append at the end, `Del`
removes the last one, `Enter` appends a newline, and the arrows are not bound.
No word keys, no `^a`/`^e`/`^k`/`^u`, no wrapping and no mapping from an offset
to the row it draws on.

**The last difference is the one that causes the rest.** `InputBox` is driven by
`keyboard_input`, which polls `bytesavailable` and calls
`REPL.TerminalMenus.readkey` - and `readkey` cannot see a mouse report at all
and drops any sequence it does not recognise as a bare `Escape`, leaving the
tail to arrive as separate keystrokes. That is why it binds no arrows: they do
not reliably survive the trip. **A widget cannot have a cursor until something
can tell Left from Escape-then-`[`-then-`D`.**

So unifying them wants three things, in this order:

1. **A decoder good enough to have a cursor behind it** - which is the section
   below, and is still in `controller.jl` rather than in the package.
2. **`TextBuffer` under `InputBox`.** The editing is the same editing whether
   the frame is a `Panel` or these rows, and it is the part with no interface
   argument attached to it.
3. **The frame**, where the two disagree most and where markup measurement is
   the open question rather than a detail.

**And one bug to file whatever else happens.** `InputBox`'s `del` is
`input_text[1:(end - 1)]`, a *byte* slice: type `aée`, press backspace, and it
throws `StringIndexError: invalid index [3]`, because byte 3 is the second byte
of the `é`. `a😀` and `aé` happen to work, which is what makes it easy to miss -
`lastindex` is the *start* byte of the last character, so the slice only lands
on a continuation byte when the character before the last one is multi-byte.
Reproduced here on 2026-09-09; not filed yet.

### Idea: the input *decoding* could go to `TermInput` too

The vocabulary already did - `Keys` is a submodule of `TermInput` now, because
it is the widgets' binding table and they cannot be driven without it. What
stayed behind is `readevent` and the CSI parser in `controller.jl`, and the
reason is that they arrived as one question with two answers: a host has an
input loop already, and what a widget needs is a key code, not a reader.

That is still the right split for *this* program and the wrong one for anybody
starting from nothing. `readevent` is a pure function of a byte stream - bytes
in, one `KeyEvent`/`MouseEvent` out - so there is nothing tying it here; what
is left around it in `controller.jl` is the part that is genuinely a program's
own: who owns stdin, what a view is, when to redraw.

Term has nothing here, which is the gap `#131` was asking about: a package that
draws panels has no way to read a keystroke into one. `REPL.TerminalMenus.readkey`
is what people reach for and it is not adequate - it cannot see a mouse report
at all (`\e[<0;40;12M` is not a key), and it drops any sequence it does not
recognise as a bare `Escape`, leaving the tail to arrive as separate keystrokes.
That is what made Shift-Tab read as Escape-then-Z here.

What we would bring: the CSI parser including SGR mouse reports, the three
spellings of Alt-arrow that terminals actually send (Terminal.app's `ESC b`,
iTerm's `ESC ESC [ D`, everything's `ESC DEL`), and a decoder that *consumes*
what it cannot parse rather than leaving half a sequence in the buffer.

And one thing worth arriving with, because it is the kind of bug a shared
decoder should never have, and because the obvious fix for it is also wrong.

A key code has to be either a character or a key and never both. Ours began at
`0x110000`, one past the last codepoint, which is the tight answer — but a lead
byte of `0xF0` or above carries three bits and each continuation six, so a
malformed four-byte sequence assembles to `0x1FFFFF`, and `F4 90 80 80` arrived
as exactly `K_LEFT`. A paste of arbitrary bytes moved the cursor.

The obvious fix is to reject what is not a codepoint. That is wrong: **Julia
does not need a decoder to throw anything away.** A `Char` is four bytes of UTF-8
held as they came, and arbitrary binary survives a round trip through a `String`
intact — `codepoint` is the only thing that refuses, and there is no reason to
call it. So a key code is now *the bytes that arrived*, packed big-endian: one
byte is `0x00`–`0xFF`, so every binding is what it was; a sequence is its bytes,
always above `0xFF`; and `K_BASE` is `1 << 32`, above the widest of them. The
framing is Julia's own, so a sequence typed into a buffer comes back out of it as
the same one `Char` — including `F8`, which leads nothing and stands alone.

That is the shape to bring upstream, since a decoder shared by everybody is
exactly the wrong place to decide which of a user's bytes were worth keeping.

### Investigate upstreaming the ANSI measuring to Term itself

`awidth`, `astrip`, `afit`, `apad`, `amid` and `awrap` are `TermInput`'s, and
two packages already depend on them for the same reason: they measure what will
*print*, and Term measures markup. The right long-term home for that is Term,
not a package beside it - `Term.textlen` already removes ANSI before measuring,
so the gap is not that Term cannot see an escape sequence, it is that `Panel`
and `reshape_text` are built on measurement that also strips markup, and text
that is not markup goes through the same door.

What to find out, roughly in order: whether Term would take a measurement path
that does *not* remove markup (invariant 9 and #247 are the evidence it is
needed); whether `Panel` could take a "this content is not markup" flag rather
than needing a second box implementation; and whether `awrap`'s escape replay -
which is what #119 was closed without - is wanted in `reshape_text` or beside
it. Until that is answered, the copy lives in `TermInput` and `TermIFrame`
depends on it, which is one copy rather than two and is not the end state.

### StyledStrings, and why the escapes are still strings

Asked on 2026-09-11, while the theme was being built: would `StyledStrings`
remove the need for the `<role>_off` closers and the re-arming around them?

**For text this program composes, yes, and by exactly the mechanism those
imitate.** An `AnnotatedString` carries faces as *ranges* rather than as
escapes, so the renderer knows what each annotation turned on and closes only
that. Measured, not assumed:

```julia
row = styled"plain {red:coloured} more"
face!(row, 1:ncodeunits(row), Face(background = :blue))
# "\e[44mplain \e[31mcoloured\e[39m more\e[49m"
```

That `\e[39m` is the whole point: the inner colour ends without taking the
background with it. `hlrow`, `rearm`, `hlspan`'s `off` and every `_off` field
exist to produce that by hand. `textwidth` of an annotated string is the width
of what prints, so `awidth`/`astrip` would go the same way.

**For text that arrives as escapes, no, and that is most of a row.** A comment
body is Term's output, a hosted pane is `capture-pane -e`, a diff is `git`'s
own colours: all `String`s with SGR already in them, and nothing in the stdlib
parses those back into annotations - `textwidth("a \e[31mred\e[0m word")` is 17
rather than 10. So a migration is not "swap the strings": it is an ANSI parser
at every boundary where foreign text enters, and until that exists both models
run side by side, which is worse than either.

**And it cannot say `on 236`.** A `Face` colour is one of sixteen names or an
RGB triple; a 256-colour *index* is not expressible. It comes out right by
accident - `#303030` renders as `\e[38;5;236m` because the downgrade quantises
to the cube - but only on a terminal that declares 256 and not truecolour. The
theme here promises the index it was given, which is what makes a theme follow
the terminal's own palette rather than argue with it.

Version is *not* the obstacle, which is worth recording because it looks like
one: the registered `StyledStrings` package is compat `1.0 - 1.10` and the
stdlib takes over at 1.11, so `TermInput` could depend on it and keep its 1.10
floor.

So: not now, and the shape of "later" is written down. If the ANSI parser gets
written - it is the same work as the "measurement that does not strip markup"
question above, from the other end - then `theme.jl` becomes a table of `Face`s,
the closers go, and `TermInput`'s measuring becomes `textwidth`.

## Upstream

Five bugs, four of them filed. The Term.jl ones came out of the checkout beside
this one - `Term.jl/` is a clone (ignored here, and `fixme.md` in it is ignored
there) with each bug reproduced against v2.2.0, the cause located and the
decision spelled out - and are **#304**, **#305** and **#306**. One is not
Term's: **JuliaLang/julia#63081**, which is a fix and not only a report.

The fifth is the newest and is **not filed yet**: `parse_md(::Markdown.Table)`
passes `inline = true` when it parses the body rows and not when it parses the
header, so a code span in a header cell is drawn as a code *block* - a panel
three lines tall and `width - 12` across. The table sizes itself to that cell,
comes out far wider than the width it was handed, and has its borders wrapped
mid-line; at a 170-column console the table in JuliaLang/julia#63110 came out
356 columns wide. It is one `inline = true` on one more call, on the branch
`fix-markdown-table-header-inline` in the fork, with a test and bug 4 in
`fixme.md`. The workaround here wraps each header cell in a `Paragraph` -
the one container whose handler passes `inline` down - so the cell goes through
Term's own inline path rather than a copy of it.

They stay on this list until each lands *and* a release carries it, because the
workarounds here are what to delete then - and deleting them is the point of
having filed.

A sixth is found and not filed, and it is not Term's either:
**`Highlights` 0.6 imports `Pkg` at load time**, which costs every downstream
package 0.35s of startup - measured here when `Term` 2.2 made it a dependency of
this program (see "What `Term` 2.2 costs"). It is one `import Pkg` in
`src/Highlights.jl`, and the only use of it is `Pkg.Registry.reachable_registries()`
in `languages.jl:40`, reached when a grammar is *missing* so that the error can
suggest which `tree_sitter_<lang>_jll` to install. A lazy `Base.require` at that
point, or an extension, or simply naming the package in the message without
searching for it, would hand back a third of a second to everything that
renders a code span. Worth filing with the measurement, since the fix is small
and the cost is paid by every user of every package that highlights anything.

A seventh, found while wiring the theme up and worth offering as a patch rather
than a report: **Term 2.2's code palette is not part of its theme.**
`Term.CodeTheme` (`src/theme.jl`) is a hard-coded `Dict` of hex strings keyed by
tree-sitter capture name, it is what every highlighted code span in a markdown
body is painted with, and neither `Theme` nor `set_theme` touches it - so a
package that sets a theme gets Term's markdown colours and Term's code colours,
and can only change the first. The `Theme` fields that read as though they did
this (`string`, `number`, `operator`, `type`, `func`, `symbol`, `expression`,
`code`) now drive only the older regex `highlight`, which the markdown path no
longer calls. Making them the same palette - or giving `Theme` a `code::Dict`
field that `set_theme` swaps - is a small change with an obvious shape, and the
fork beside this one is where to make it.

An eighth is found and not filed: **`Term.Live`'s `InputBox` throws on backspace
after a multi-byte character** - `input_text[1:(end - 1)]` is a byte slice, so
`aée` gives `StringIndexError: invalid index [3]`. See the `InputBox` section
above, which is also where the question of whether these widgets should be one
widget is written down.

The last two entries below are offers rather than bugs, and each is a package
beside this one now rather than a paragraph describing one.

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
- **JuliaLang/julia: the intraword-emphasis bug** — filed *and* fixed as
  **#63081**; see its own section above. Term was the first suspect and is
  innocent: the mangling is already in the AST that Julia's `Markdown` hands
  over, which is why this is the one on the list that was never Term's.
- **Term.jl: the brace bug** — filed as **#304**; see its own section above.
- **Term.jl: a composer and a line prompt.** Built here, split out as
  `TermInput.jl`, and in use: a `TextBuffer` with no view attached, a
  `TextArea` and a `LineInput` over it, the key vocabulary they bind, the box in
  Term's own box characters, and `suspend` for handing the terminal to
  `$EDITOR`. Term has been asked for this before - **FedeClaudi/Term.jl#131**,
  "How To Accept User Input?" (Jul 2022), somebody wanting to type into a
  `Panel`, closed without one and ending on the two approaches they could not
  choose between. So the appetite exists and the shape was the open question,
  which is a good position to arrive at with a working implementation. Worth
  reading first, since they bear on how much of ours would be welcome:
  **#119** "Style information is dropped on wrapped lines" (closed) is the bug
  `awrap`'s escape replay exists to avoid, and **#247** "TextBox line wrapping
  bug" (open, Mar 2024) is still open with the maintainer saying text wrapping
  "has been hard to fix". What to settle before offering it is what to do about
  `InputBox`, which is a section of its own above.
- **Term.jl: a tmux-backed pane as a widget.** Built here, split out as
  `TermIFrame.jl`, and in use: a session per worktree, a control-mode client over a pipe pair, a `View` whose render is
  the captured frame and whose wake is `%output`, and input forwarded as the
  bytes it arrived as. Offer it only after it has carried `vi` and an agent for
  a while, and only backend-shaped rather than tmux-shaped — on Windows `psmux`
  claims the same control mode (`-C`/`-CC`, `capture-pane`, `send-keys`) and
  wezterm has the same two primitives under other names (`wezterm cli get-text
  --escapes`, `send-text`, against a headless `wezterm-mux-server`). Neither is
  verified; there is no Windows in this sandbox. `tmux_jll` covers macos, linux
  and freebsd only, so the dependency would have to be optional in any case.

## Known gaps in what has shipped

- **The merge operation `M` opens on is this program's preference, not the
  repository's — because a repository has none.**
  `Repository.viewerDefaultMergeMethod` is the only field of that type in the
  whole GraphQL schema, and it is *viewer*-scoped: it reports what you last
  merged with there, falling back to the first allowed of merge, squash, rebase
  in a repository you have never merged in. Measured rather than assumed from
  the name:

  | repo | allows | it answers | your permission |
  |---|---|---|---|
  | `JuliaLang/julia` | merge, squash | `SQUASH` | admin |
  | `JuliaLang/Pkg.jl` | merge, squash | `SQUASH` | admin |
  | `JuliaCI/julia-buildkite` | merge, squash | `MERGE` | admin |
  | `FedeClaudi/Term.jl` | merge, squash, rebase | `MERGE` | read |
  | `JuliaData/FlatBuffers.jl` | squash, rebase | `SQUASH` | read |

  The identical allowed pair answering two ways across the three you can merge
  in, and the two you cannot each answering with the first flag they have, is
  history talking and not settings. So `M` does not ask it: it opens on squash
  where the repository allows it, then merge, then rebase, and the note above
  the message says that is ours. `^x` is the way to any of the others, and the
  message follows the operation because both come from the one query.

  The *text* has no such gap - `viewerMergeHeadlineText` and
  `viewerMergeBodyText` already honour the repository's squash-title and
  squash-message settings, so what the composer opens on is what the web UI
  would have prefilled. Rebase is the exception with no text at all: both come
  back empty even where rebasing is allowed, because the commits are replayed as
  they were written rather than joined into a new one.

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
  between two panes and nothing says so on screen. `p` is outside the question
  rather than a third answer to it: two `git` calls against a local checkout,
  with nothing cached and nothing to be stale.
- **Per-check counts come from the same cache the `C` pane uses.** So the
  rollup line is as stale as `check_contexts`' TTL (120s), and an item whose
  checks have never been fetched shows the one-word rollup from `fetched.json`
  until the lazy fetch lands.
- **A snooze cap is measured from when it was armed, not from when you set it.**
  `snooze_at` records the time the fingerprint was first taken, which is the
  next refresh after the value appears in `local.toml` — close enough for a
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
by driving `handle!` directly, but has not been exercised through an actual
TTY. An entry that gets used in one is struck through rather than deleted: what
a real terminal *did* is the answer the list existed to get, and the mouse one
below is the case for keeping it - the next move on a drag that would not
select would otherwise have been to go looking for a bug in `onmouse!`.

- **Merging.** `M` is driven end to end in the suite - the composer opens on
  the operation and the message, `^x` swaps both, `^s` reaches the question and
  `esc` gets back to the words - with the state put in the cache rather than
  fetched, so nothing in the suite sends a mutation. What has never run is
  `merge_pr` itself, and with it the two things only a real merge settles:
  whether `expectedHeadOid` refuses a stale head the way it should, and whether
  the row rewritten as merged reads correctly beside the refresh's own version
  of the same fact when one lands afterwards.
- Key handling end to end: arrow keys, page keys and Shift-Tab. The decoder
  that produces them is driven directly from an `IOBuffer` in the tests, so the
  byte-to-keycode step is covered; what is not is whether this terminal sends
  the bytes the tests feed it.
- ~~Click-to-row and drag-to-select in the *browser's* panes.~~ **Answered,
  2026-09-11: it works, and the implementation was right all along.** The
  drag that would not select was the terminal taking it first - VS Code's, or
  the tmux inside it - and in a terminal that forwards motion reports under
  `1002` the whole path behaves: `\e[<32;40;12M` arrives as a `:drag`,
  `onmouse!` maps it through `layout(w, h)` and `st.hdr` to real rows, and the
  frame draws them in the selection background. Nothing here needed changing,
  which is worth saying because the obvious next move would have been to go
  looking in `onmouse!` for a bug that was never in it. `m` is the escape
  hatch when the terminal wants the drag for itself, and that is now a known
  arrangement rather than a suspicion.
  The earlier half of this was already answered on 2026-09-03 from the
  nested-tmux report: the round trip goes out and comes back, survives the
  user's tmux, and `retarget_mouse` lands reports inside a hosted pane
  correctly enough for an editor two multiplexers down to respond.
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
- `⌥e`/`^o` in the composer, end to end. `suspend` is tested to run its body and
  put the alternate screen back, the reader is armed one event at a time so it
  is not on the tty while a child runs, and `TermInput`'s suite drives the whole
  `compose_external` path through `define_editor` - but no editor has actually
  been launched from inside the browser here.
- Which spelling of Alt this terminal actually sends. All three are decoded and
  each is tested from an `IOBuffer`, but which one arrives is a property of the
  terminal and its settings - and on a Mac, Option may be composing characters
  rather than sending Meta at all, in which case none of them arrive.
- `^s` in the composer. Ctrl-S is XOFF under terminal flow control; raw mode
  should be clearing IXON, which has not been confirmed against a real tty.
- **`p` against a rebase whose base moved.** Both halves are covered but in
  two places rather than one. The base-moved arithmetic is driven in the suite
  against a scratch repository - ten commits of master under a rebased branch,
  and the answer is the one commit that changed. The *network* half ran against
  the real FedeClaudi/Term.jl clone and real force-pushed heads, but every pull
  request there sat on an unmoved base, so it reported "rewritten" rather than
  "rebased onto N newer commits". The two have never been true at once in one
  run, which needs a checkout of a repo whose base moves - JuliaLang/julia, and
  the sandbox has no clone of it.
- `open_editor`: `code` is not on PATH in the sandbox, so the launch is
  untested. The worktree *selection* around it is tested against a real
  worktree list.
- ~~`ensure_commit!`'s fetch path.~~ Run on 2026-09-11, against three heads
  that a force-push had left reachable from no ref (FedeClaudi/Term.jl, the
  oldest from 2025-07-25). All three came back from `git fetch <remote> <sha>`.
  What is still unrun is the `pull/N/head` spec that is tried first, since the
  bare sha answered every time.
- ~~A hosted pane through a real terminal.~~ Answered on 2026-09-03: `^]` does
  arrive as `0x1d` and nothing between the terminal and here binds it first —
  the report that `^]tab` and `^]esc` behaved wrongly is a report from somebody
  whose prefix was reaching the pane. What is still unknown is only whether the
  *title-bar* row settles tmux copy-mode scrolling, which is listed above.
- Which reading of "when" you actually reach for. Use answered the first half:
  every lane opens by when anything last happened, `touched` excepted, because
  that lane *is* the clock. `w` still reaches the other two - the clock, and the
  url. Whether `mine`, `second` or `unread` want one of their own is still a
  question only use can answer, and `lane_sort` is a one-line change when it
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
  `[`, so the separator before the next block goes too, and `local.toml` grows
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
  `vtjnash/git-worklog` and is readable, but its `master` is 34 commits behind
  the local one as of 2026-09-11 - it is at `aaa2cec`, made on 2026-09-10.
  Pushing has never been attempted, and the sandbox's App token is read-only for
  contents everywhere, so it is expected to fail. That needs
  `Contents: read/write`. Writing a review needs a *different*
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
  is already covered by the checks in `fetched.json`.

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
