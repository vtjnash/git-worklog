# TODO

What is open. Anything shipped is in `git log`; why things are shaped as they
are is in DESIGN.md.

## Blocked on a token that can write

**Every write is unexercised.** `post_comment`, `add_review_thread`,
`submit_review`, `discard_pending`, the label toggle and `merge_pr` are
written and none has ever been sent: the sandbox token is read-only. It is
the only part of the program where a failure loses work. The shapes are from
the docs and, for the four review mutations, introspected from the live
schema; the read half (`review_state`) has run against the real API.

`Events.pat()` already finds the `gho_` token with `repo` scope off the
sandbox, which covers `issues: write` and `pull_requests: write` everywhere.
**Route the writes through it**, then, in order:

- [ ] `merge_pr`: the first thing to verify is that `expectedHeadOid` refuses
      a stale head rather than merging over it. Then that the row rewritten as
      merged reads correctly beside the refresh's own version when one lands.
- [ ] a comment, a review comment on a range, a submitted and a discarded
      draft review, a label toggle.
- [ ] pushing this repository: `origin` is `vtjnash/git-worklog`, never pushed
      to; needs a fine-grained PAT with `Contents: read/write`.

## To design before starting

- [ ] **A comment box drawn inline, between the diff lines it is about.** The
      rest of that idea is done - threads hang off their hunk, the line is
      marked `💬`, `n`/`N` walks them. A hunk is one node whose body is the
      diff text, and cutting it at the commented line cuts the `start`,
      `count` and `body` that `hunk_line_at`, `[`/`]` and `C`-on-a-range all
      read off one node. Cheap version: a node per fragment sharing the
      parent's meta, and the arithmetic of four ranges in step. Honest version:
      rows that belong to a node without being its body, which changes what a
      `Row` is. Decide which before starting.
- [ ] **Undo in the composer.** `^_`/`^x^u` are unbound; the answer has been
      `⌥e`. Weak for the `^w` you did not mean. Needs a snapshot stack and a
      rule for what one step is.
- [ ] **`TermInput` and Term's `InputBox`** are not the same widget:
      `InputBox` appends keystrokes with no cursor, because `readkey` cannot
      tell Left from Escape-`[`-`D`. Unifying wants, in order: a decoder good
      enough to have a cursor behind it (`readevent`, still in
      `controller.jl` - it is a pure function of a byte stream and could go to
      the package; what should stay is who owns stdin), `TextBuffer` under
      `InputBox`, then the frame, where markup measurement is the open
      question.
- [ ] **Upstream the ANSI measuring to Term.** `awidth`/`afit`/`apad`/`awrap`
      measure what prints; `Panel` and `reshape_text` measure markup. Find
      out whether Term would take a path that does not strip markup, a
      "not markup" flag on `Panel`, and `awrap`'s escape replay (what #119 was
      closed without).
- [ ] **StyledStrings**, later. For text this program composes it would
      replace every `_off` closer. For text that arrives as escapes - Term's
      output, `capture-pane -e`, git's diff - nothing parses it back, so a
      migration is an ANSI parser at every boundary; and a `Face` cannot say
      `on 236`. The shape of later: the parser is the same work as the
      measuring question above, from the other end.

## Upstream - delete the workaround when a release carries the fix

| where | what | workaround here |
|---|---|---|
| FedeClaudi/Term.jl#304 | braces deleted in prose, doubled in code spans | `escape_source` doubles; `render_md` collapses |
| Term.jl#305 | empty list item is a `BoundsError` | `for_term` fills it |
| Term.jl#306 | table nested in a list is a `MethodError` | `for_term` moves it to a code block |
| Term.jl#309 | code span in a table header drawn as a block | header cells wrapped in a `Paragraph` |
| Term.jl#310 | `leftalign`/`vstack` re-wrap a table wider than the terminal | none needed - `render_md` is handed a pane width |
| JuliaLang/julia#63081 | intraword `_` opens emphasis (fix submitted) | the underscore half of `escape_source` |

Found and not filed:

- [ ] **`Highlights` 0.6 imports `Pkg` at load time** - 0.35s on every launch
      of everything that highlights anything - for one
      `Pkg.Registry.reachable_registries()` on an error path
      (`languages.jl:40`). File with the measurement.
- [ ] **Term's code palette is not part of its theme.** `Term.CodeTheme` is a
      hard-coded `Dict` that `set_theme` never touches; the `Theme` fields that
      look like they do that (`string`, `number`, `operator`, `type`…) drive
      only the old regex highlighter. Offer a patch from the `Term.jl/` clone.
- [ ] **`Term.Live.InputBox` throws on backspace after a multi-byte
      character**: `input_text[1:(end - 1)]` is a byte slice; `aée` gives
      `StringIndexError`.

Offers, once they have carried real use: `TermInput` to Term (#131 asked for
it; #119 and #247 bear on how much would be welcome), and `TermIFrame` as a
widget - only backend-shaped, since `psmux` and wezterm have the same two
primitives under other names and `tmux_jll` covers three platforms.

## Unverified - needs a real terminal

Written, compiled, state transitions driven through `handle!`; not exercised
through a TTY. Strike through rather than delete when one answers.

- [ ] Arrow, page and Shift-Tab bytes from this terminal; which spelling of
      Alt it sends (on a Mac, Option may compose instead).
- [ ] `^s` in the composer: raw mode should clear IXON.
- [ ] Raw mode restoration on abnormal exit.
- [ ] OSC 8 links and the OSC 52 copy end to end. The bundled client is
      3.5.1, but an older server already on the socket renders `capture-pane`
      (OSC 8 needs 3.4), and OSC 52 is opt-in in some terminals. Whether the
      title-bar row settles copy-mode scrolling.
- [ ] `⌥e`/`^o` launching `$EDITOR` from inside the browser; `e` (`code` is
      not on the sandbox's `PATH`).
- [ ] `u` end to end: the child's exit and the status line from its last
      output line.
- [ ] `p` against a rebase whose base moved, network and arithmetic at once:
      needs a checkout of a repository whose base moves.
- [ ] The `pull/N/head` refspec in `ensure_commit!` - the bare sha answered
      every time.
- [ ] Whether owning the mouse is the right trade, or `m` is reached for
      constantly. Whether 150 columns is the right split threshold.
- [ ] Whether any lane wants an order of its own (`lane_sort` is one line).

## Known gaps

Reviewing and writing:
- [ ] `C` on a line of the `p` pane comments on the item, not the line:
      GitHub's `LEFT` is the base, and the left side there is the head you
      last saw. Restricting to the right side would work.
- [ ] `C` refuses a comment on a deleted line - the old-side number is known,
      but it must be anchored against a commit the line existed in.
- [ ] `C` on an issue comment writes a new comment rather than replying
      (matches GitHub; surprises).
- [ ] The metadata pane is a readout: nothing in it can be clicked or acted
      on where it is shown - no assigning a reviewer, no opening the check
      under the eye.

The corpus:
- [ ] Discussions, releases, commit comments: the notifications source sees
      each arrive and skips it, counted. Nothing here can open one.
- [ ] A kept row under an old url that is never asked again is a duplicate
      with old facts until it is.
- [ ] The unread light rows of a watched repository's traffic that moved
      before the cursor are the one thing a lost `fetched.json` does not bring
      back.
- [ ] "Mine" is author or assignee. Not yet: a pull request somebody else
      opened that you pushed to, or that carries you in `Co-authored-by`.
      Neither costed.
- [ ] An adopted branch that landed is news until read: `merged_here` says
      the commits are in the base and not how; the merge commit's committer
      would say, only for a real merge.

Reading:
- [ ] Hunk context expands against the head, so context around a `-` line is
      the post-change file.
- [ ] A fenced block is a node with its own header and fold state; a short
      snippet reads as a labelled block rather than part of the sentence.
- [ ] A code span Term wrapped across two lines gets a dim backtick, no
      background.
- [ ] Nesting is depth, not structure: nothing can be moved or counted as a
      subtree; past `MAX_DEPTH` a body is raw text.
- [ ] A url footnote row shows an elided form, so a search match on it is
      marked loosely.
- [ ] Buildkite job lists and logs are the one read still on a plain TTL
      (`bk_jobs` 5 min, `bk_log` 15), so a failing job's expansion can pause
      where the tally above did not; the per-check counts are as old as that
      entry.

Panes:
- [ ] `^]t`/`^]T` from a pane forward to the pane; `t`/`T` from the reading
      side go to the list. Both defensible; nothing on screen says they
      differ. Left alone.
- [ ] The reading side forwards `f` (switches to the filter pane, invisibly)
      and `q` (quits the program from inside a pane).
- [ ] A pane once reported `session ended` with an empty frame (2026-09-02,
      scripted launch). The wake-channel theory was tested and is wrong (11
      of 64 slots). Not recurred.
- [ ] The second look is called "second look" in the filter pane, which is
      what it does and not what it is for; "who is waiting on me" does not
      find it by reading.

## Housekeeping

- [ ] `config.toml`: `nudge_days` and `stale_days` under `[thresholds]` are
      read by nothing. The `[events]` comment still says `inbox.json` holds
      the cursors; they are the `source:` blocks in `local.toml`.
- [ ] `bin/wl`'s header comment still names `wl next`. `TermIFrame.mux`'s
      failure string says "no tmux on PATH", and `PATH` is never consulted.
- [ ] `table_key_order` is untested against TOML shapes it does not parse
      (multi-line inline tables); it degrades to sorted order.
