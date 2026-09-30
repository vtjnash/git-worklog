# Plan: the terminal's input helpers move into TermInput

Moving the key decoder and the terminal plumbing a loop needs out of `wl`'s
`cli/src/controller.jl` and into TermInput, so that the loop a host writes to
drive a widget is short enough to read at a glance. Written 2026-09-30,
against `wl` at `fabbc54` and TermInput at `41528fc`. Check items off as they
land; the ones marked **(host)** are in `wl`.

This file lives in `wl` and not in TermInput because it names `wl`'s code, and
nothing in TermInput names `wl`.

## Why

A loop that drives a TermInput widget needs, besides the widget:

- the terminal put into raw mode, bracketed paste, maybe the mouse, maybe the
  alternate screen, and all of it put back on the way out, however the way
  out happens;
- bytes turned into `Keys` codes, pastes and mouse reports;
- a way to be told the terminal changed size;
- a frame written so the terminal does not draw half of it;
- the terminal handed to `$EDITOR` and taken back (`suspend`, already here).

TermInput has the vocabulary (`Keys`), the mode strings (`mouse_reporting`,
`bracketed_paste`) and `suspend`. Everything else is in `wl`'s controller,
about 450 lines of it, so every other host writes it again, and what they
reach for instead - `REPL.TerminalMenus.readkey` - is wrong in the ways the
`Keys` docstring already lists: no mouse, and an unknown sequence dropped as
Escape with its tail arriving as keys, which is Shift-Tab reading as
Escape-then-`Z`.

### What the rule was, and what it becomes

"Nothing here reads stdin, holds raw mode, or runs a loop" was about the
*widgets*: `render` is a pure function of a widget and a size, `handle!` takes
one key code and answers an action, and nothing takes a callback. That stays
exactly as it is.

What changes is the reading of it that kept helpers out, stated in `5ee7b4b`
("producing the codes is the host's, and stays the host's"). The helpers move
in. Each is usable alone and none of them owns the loop: a host that already
has a decoder (a multiplexer that normalizes keys, a GUI) takes none of it, and
a host that has nothing composes them. The loop, its policy - what `↵` and
escape mean, when to redraw, what a wake is - and any stack of views stay the
host's.

Not owning the loop is also what leaves room for other decoders. A host that
speaks the kitty keyboard protocol, or reads keys from something that is not
a terminal at all, swaps `readevent` for its own and keeps everything else;
a loop that TermInput owned would have decided that for it.

### Done when

The README has a complete program driving a `Choice` full screen, written
only from TermInput's exports, about twenty lines, and a test runs it against
an `IOBuffer` instead of a tty. Roughly:

```julia
using TermInput
import TermInput: render, handle!, paste!

function pick(labels)
    c = Choice("Pick one", "", labels)
    t = enter_terminal(stdin, stdout; altscreen = true, paste = true)
    try
        while true
            h, w = displaysize(t)
            write(t, frame_bytes(render(c, w, h)))
            ev = readevent(t)
            ev isa PasteEvent && (paste!(c, ev.text); continue)
            ev isa KeyEvent || continue
            handle!(c, ev.code) === :unhandled || continue
            (i = picked(c, ev.code)) > 0 && return labels[i]
            ev.code in (27, C_G) && return nothing
        end
    finally
        leave_terminal(t)
    end
end
```

A resize is noticed at the next key here; a host that wants it sooner hears
SIGWINCH itself (see *What stays*).

## What moves

From `cli/src/controller.jl` unless said otherwise.

| now in `wl` | in TermInput | notes |
|---|---|---|
| `KeyEvent`, `PasteEvent`, `MouseEvent`, `EndEvent` | the same | `EndEvent` goes with the reader (step 6) |
| `readevent`, `read_csi`, `read_osc`, `read_paste`, `decode_csi`, `decode_mouse` | `readevent` and its internals | moved as they are: the byte framing, the three spellings of Alt, the `ESC ESC [` arrow, the mouse report that ends only at `M`/`m`, the paste read to its end marker |
| `KeyEvent(-1)` for an unknown sequence | a named code, `K_NONE` | consumed and never bound, as now |
| `SchemeEvent`, `SCHEME_REPORT`, `BG_REPORT`, `BG_QUERY`, `scheme_reports` | the same | the reports have to be parsed inside `readevent` or they arrive as keys; what a host does with dark/light stays the host's |
| `pasteline` | folded into `paste!(::LineInput, s)` | it already makes the paste one line; the control characters `pasteline` also drops go there too, and `pasteline` is deleted |
| `input_waiting` | the same | the "do not redraw while a paste is still arriving" test |
| `frame_bytes` | the same | one write, synchronized output, cursor hidden first and shown last, each row's line deleted and rewritten (the xterm.js hyperlink markers - the reason is a terminal's, not `wl`'s) |
| `run!`'s setup and its guarded `finally`: raw mode, alternate screen, hidden cursor, title push/pop, mouse, bracketed paste | `enter_terminal(in, out; ...)` returning a value, and `leave_terminal(t)` | alternate screen and title optional, so an inline host can use it; `leave_terminal` guarded as the `finally` is; `suspend` takes the same value, so what it undoes and redoes is what was done. A do-block `with_terminal` can come later as sugar over the pair |
| the reader task and its `ready` token | `InputReader` | one event read per `arm!`, parked between them, which is what makes `suspend` safe; it `put!`s into a `Channel` the host owns, so the host's own wakes go on the same channel. No callback |

Tests move with them: `input.jl`'s "a key code is the bytes that arrived",
"input decoding", the paste half of "a paste goes where text goes", and "a
frame is one write"; the scheme-report parsing out of "the terminal says dark
or light".

## What stays in `wl`

- `Controller`, the `View` protocol, the stack, `run!`'s dispatch, wakes,
  `settle!`, the error log, `safe_render`/`safe_dispatch!`: the loop and its
  policy.
- The theme's response to a scheme report (`scheme!`, `terminal_bg!`).
- `readraw`, `RawEvent`, `scheme_in`, `REPORT_UNFINISHED`: forwarding
  undecoded input to a hosted child. That is TermIFrame's business if it
  moves anywhere, and it is not part of this plan.
- `mouse!`, which is one line over `mouse_reporting` and a flag.
- `watch_winch!` and `ResizeEvent`: hearing SIGWINCH means a libuv signal
  handle, an `AsyncCondition` and a task, which is a large piece to put in a
  widget package, and where it should live is not decided yet.
- `PromptView`, `ChooseView`, `ConfirmView`: they are `wl`'s wrappers.

## Steps

TermInput steps are commits in TermInput's style; each **(host)** step is a
`worklog:` commit that bumps the submodule to what it needs and deletes `wl`'s
copy in the same commit.

1. [x] **Events and the decoder.** `readevent`, the four event types and
       `SchemeEvent`, `K_NONE`, the tests. The `Keys` docstring's "producing
       them is the host's" becomes "`readevent` produces them; a host that
       reads keys some other way produces them itself". The module docstring
       and README say the no-loop rule is the widgets', and list the helpers.
2. [x] **(host)** `wl` imports them; its `KeyEvent` and friends go.
3. [x] **Paste.** `paste!(::LineInput)` drops control characters as well as
       line breaks, and so `Choice`'s does.
4. [x] **(host)** `pasteline` goes.
5. [x] **Terminal modes.** `enter_terminal` and `leave_terminal`, the
       latter guarded as `run!`'s `finally` is, since the commonest way out
       is a terminal that has gone away. `suspend` takes the value `enter`
       returns. Alternate screen and title optional.
6. [x] **The reader.** `InputReader` with `arm!` and `close`, and
       `EndEvent` on EOF or EIO. Tested with a pipe.
7. [x] **`frame_bytes` and `input_waiting`**, with the frame tests.
8. [x] **(host)** `run!` is written with steps 5-7; `Controller` keeps its
       stack, its channel and its SIGWINCH watch, and loses its reader.
9. [ ] **The README's program**, and the test that runs it.

## Decided

- **Exported, mostly.** The events, `readevent`, `frame_bytes`,
  `input_waiting`, `enter_terminal`/`leave_terminal` and `InputReader` are
  exported; a host that already has a `KeyEvent` of its own imports what it
  wants by name instead of `using`. `K_NONE` goes out with the other `Keys`.
- **An enter/leave pair, not a do-block.** A host's loop enters before it and
  leaves in a `finally` of its own, as `wl`'s `run!` does; the callback form
  is three lines of sugar over the pair and can be added when something
  wants it.
- **SIGWINCH stays in `wl`** until it is clear where a libuv signal watch
  belongs.
- **`K_NONE` is `-1`**, the code `wl` already used: below every other code
  and not bytes anybody could type, so `printable` is false for it without a
  case of its own.
- **`SchemeEvent` keeps `rest`**, always empty from `readevent`, so that
  `wl`'s `scheme_in` can go on building one from a raw read.
  `scheme_reports` is exported beside `mouse_reporting`; `BG_QUERY`,
  `SCHEME_REPORT` and `BG_REPORT` are public and not exported, since only a
  host reading raw input wants them. `TERM_DARK`, which tells a flip from
  the first answer, stays `wl`'s: it is policy about when to ask again.
- **`enter_terminal` returns a `HeldTerminal`**, public and not exported: a
  host rarely names the type. Its `mouse` is the one field a host sets,
  since the mouse is the one mode toggled during a run; `wl`'s `mouse!` sets
  it beside `ctrl.mouse`, which the views read and which a test's
  `Controller` has with no terminal held. Every mode defaults to off,
  raw mode and the hidden cursor aside, so an inline host asks for nothing.
  The `suspend(f, term; mouse, paste)` form stays beside `suspend(f, t)`, for
  a host that set the terminal up itself - and for `wl`'s tests, which
  suspend with no terminal held.
- **`arm!(r, read = readevent)`**: which read the next event gets is an
  argument, so `wl`'s `readraw` for a hosted pane is `arm!(r, readraw)` and
  the reader knows nothing about raw input. Called with `invokelatest`,
  because a host's read can be newer than the reader's task - which is how
  a test's closure first came back as an `EndEvent`.
- **`EndEvent` carries `why`**, the error that ended the read, since that
  test showed a failing read is otherwise indistinguishable from EOF.
- **`frame_bytes(frame, title = "", cursor = nothing; h = 0)`**, so the
  README's program writes `frame_bytes(render(c, w, h))`.
- **`wl` no longer depends on `REPL`**: raw mode was its last use.

## Not doing

- A decoder for anything `readevent` does not read today: no kitty keyboard
  protocol, no other mouse encodings. Where `wl` runs, tmux normalizes what
  terminals send; what moves is the decoder `wl` already has, as it is.
- Cell diffing or any frame format but `frame_bytes`'s.
- A loop, a view stack, or a `request` that owns input. The inline path for
  REPL users - a widget drawn at its natural height under the prompt,
  without the alternate screen, and a `request(widget)` over it - is the
  next plan, and builds on these helpers; it should find nothing left to
  write but the inline frame and the loop.

## For the agent doing this

- Read `AGENTS.md` and `DESIGN.md` first; *The terminal* under "Invariants
  found by debugging" is why several of these functions look the way they
  do, and the docstrings moving with them must keep that reasoning.
- **Nothing in TermInput names `wl`** - not code, docs, tests or commit
  messages. Where a docstring says why with a story from `wl` ("closed the
  browser", "a paste into a composer"), it says it about a host.
- Tests: `julia --project=. test/runtests.jl` in `TermInput.jl/`, and
  `julia --project=cli cli/test/runtests.jl` from `wl`. TermInput's compat is
  1.10; check steps 1, 5 and 6 on `julia +1.10`.
- Tick each box here as it lands and put what was decided along the way in
  this file. When every box is ticked, what is still true moves into
  TermInput's README and `wl`'s DESIGN.md, and this file is deleted.
