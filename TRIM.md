# `--trim` and Worklog

Where `juliac --trim` stands on `wl`, and what is left. Measured 2026-09-28
at `1f2dc55` with JuliaC 0.3.10, on the 1.14 nightly (1.14.0-DEV.3217,
`e94c392a22c`, what the manifest is resolved with) and on 1.13.0 (a copy of
`cli/` resolved afresh, since the manifest is a 1.14 one). How to repeat it
is under "Reproducing".

## Where it stands

- `--trim=safe` refuses to build: **1466 errors** on 1.14, **1369** on 1.13.
  **410** and **393** of them are in `wl`'s own code (the innermost frame is
  in `cli/src`). The rest are inside Base or a dependency, reached from a call
  of `wl`'s.
- `--trim=unsafe-warn` builds - a 27 MB executable in a 170 MB bundle (164 MB
  on 1.13) - and **dies before any command runs**:
  - on 1.14, at load, with `InitError(:libevent_jll, MethodError(dlopen,
    ("…/libcrypto.so.3", 0x44)))`. A four-line program doing only
    `using libevent_jll` dies the same way on 1.14 and runs on 1.13: a
    nightly regression (TODO, *Upstream*).
  - on 1.13, at the first line of `main`, with a `MethodError` on the keyword
    body of `seed_config!`: `io = stderr` passes a global typed `IO`, so that
    body was never compiled for an `IOStream`. Every command goes through it,
    `--help` included.
- Were all of that fixed, a trimmed `wl` still could not run a subprocess:
  `read(`echo hi`, String)` alone fails `--trim=safe` (30 errors on 1.13, 44
  on 1.14, all in `process.jl`), and everything `wl` does goes through `gh`,
  `git` or `tmux` (TODO, *Upstream*).

An `unsafe-warn` binary turns each unresolved call into a `MethodError` when
the line runs, so it is no middle ground for a program whose code paths are
its command surface.

**Reading the counts.** The verifier names each unresolved method once,
however many callers reach it, and it **does not look inside a call it
cannot resolve**. So typing a call site makes its callee visible, and a
count can rise as code is fixed. The buckets below follow the first path to
each method.

## The plan

- [ ] **The rest of the untyped reads.** Of the 410 in `wl`'s code, 171 are
      the two items on printing below (`@printf` 81, `stdout`/`stderr`/`stdin`
      typed `IO` 46, `sprint(showerror, e)` 44), 22 are `sync!` calling a
      `Source`'s functions (the next item), 16 are the accessors' own
      fallbacks (the two after that), and 13 are keyword calls. The other
      188 are a tail of one to six per function, besides `run!` (22: the
      terminal held as `ctrl.term::Any`, `stdin` for `input_waiting`):
      `load_theme!` (`apply_term!`/`apply_code!` as a union, `parse_style` of
      an `AbstractString`), `search`'s `take!` closure, `merge_state`,
      `mark_done_moved`, `watch_data!`, `merge_config`. Two stored values are
      typed `Any` so the suite can replace them: `_PAT`, the token, which a
      test sets to a string; and `Source`'s functions.
- [ ] **`Source.fetch` and `Source.row` as `Core.TypedCallable`s, once there
      is one.** `sync!`'s sources are the one real callback interface in
      `wl`: three kinds, and the tests' own. Their signatures are settled and
      written on `Source`; `SyncCtx` is the context's type. Waiting on
      JuliaLang/julia#62559 (a draft, "Part 1/2", on #62245, last touched
      2026-07-30) and the trim support its description leaves to a second
      part; the RFC is #59774.
- [ ] **Decide what an unknown container is, on read.** `jget`, `jstr`,
      `jint` and `jlist` test the concrete containers the program holds, then
      fall back to the generic read through one dynamic call each (`_jget`,
      `_anylist`, `_anydict`, `_kept_row`, `_falsy`, `_same`, `_fmt`,
      `String`/`Int` of an abstract). That fallback is where a shape nobody
      listed goes - a fresh fetch's `Vector{String}`, a vector of
      `OrderedDict`s, a test's `Dict{String,String}`. Find what actually
      reaches it (count the fallback's types across a suite run and a traced
      session), then either list those or build them as
      `Dict{String,Any}`/`Vector{Any}` where they are made. Either way, a
      test per shape: nothing proves a fresh fetch and its cached copy read
      the same except the one for `_meta_shape`.
- [ ] **Decide what an unknown value is, on write.** `json_dumps`
      specialises while the static type is known and narrows an `Any` in
      `_jany`; anything unlisted falls back to a dynamic `_jvalue`. The types
      that reach it are a long tail (`Dict{String,Vector{Any}}`,
      `Vector{Pair{String,String}}`, `Vector{Nothing}`,
      `Dict{String,Dict{String,String}}`, …), and a write that fails is
      silent: `cache_put` swallows it, and the cache stops working. At least
      `logerror!` it there; then settle which shapes the cache and
      `fetched.json` hold, as above.
- [ ] **`logerror!` without `showerror(io, e, bt)`.** 440 errors from that
      one call, the largest single source left: printing an exception of
      unknown type, with its backtrace, is all of Base's error printing. And
      44 in `wl`'s own code from the 32 `sprint(showerror, e)` sites. Say
      `e.msg` for the exception types `wl` owns, and the type's name for the
      rest.
- [ ] **A concrete stream for `stderr`, `stdout` and `stdin`.** All three are
      `IO`-typed globals: the 81 `@printf` errors and 46 more in `wl`'s code,
      32 more inside Base's `print`/`println`/`write` (most from `dispatch`),
      and the one that kills a trimmed build first - `seed_config!`'s
      `io = stderr`, a keyword call on every command.
- [ ] **`ROOT` from where the program is, not where it was built.**
      `@__DIR__` is fixed at build time, and JuliaC builds from a copy under
      `/tmp`, so `ROOT` comes out as `/tmp/`. From the executable's path or
      `WORKLOG_DATA`'s parent instead, with `config.toml`, `themes/` and
      prefetch's `cli/bin/wl` under it.
- [ ] **GitHub.jl for the REST calls.** 75 errors: `Events.auth` into
      GitHub.jl, JSON and URIs (60), and MbedTLS's own callbacks (15) -
      GitHub.jl's own dependency; HTTP.jl had none. HTTP.jl 2 trims, so the
      REST calls and `gh api` both move to it (TODO, *Trim*).
- [ ] **`sort!` with an untyped order.** 42 errors inside `Base.Sort`, from
      `thread` (20), `review_comments` (10), `poll` (6) and `activity_of`:
      a `by`/`lt` over rows typed `Any`. A key read with `jstr` first, or a
      sort over the concrete entry type.
- [ ] **TermIFrame and TermInput.** 96 errors in their own code -
      `mux_pane_state` (38), `iframe_sync!` (12), `mux` (12),
      `mux_sync_locked!`, `mux_read` - and 13 in `tmux_jll`'s wrapper from
      `mux_cmd`. The same work as here, in those repositories; and their
      subprocesses (`mux_spawn`, 88 of the subprocess errors) wait on Base
      like everything else.
- [ ] **Term's markup, reached through `show_md`.** 91 errors inside Term:
      `apply_style` (72, `Term.Colors` and `Term.Style` over untyped markup
      codes) and `parse_md` (14), from `term_md`. Term's to fix, not `wl`'s;
      worth a look at how much of it the program needs when trimmed.
- [ ] **Pkg, loaded through Highlights.** 43 errors in Pkg's `REPLExt`
      `__init__` and REPL's keymaps, in no call of `wl`'s: Pkg is loaded
      because Highlights imports it (TODO, *Upstream*, "File Highlights'
      `Pkg` import upstream"), and its REPL extension comes with it.

## Where the errors are

On 1.14. The 1.13 rows are within a few of these: 393 in `wl`'s code, with
the same printing and `sync!` counts.

**In `wl`'s own code** - 410, on 91 functions:

| errors | what | plan item |
|---|---|---|
| 81 | `@printf` into a stream typed `IO` | a concrete stream |
| 46 | `stdout`/`stderr`/`stdin` typed `IO` (`println`, `displaysize`, `input_waiting`) | a concrete stream |
| 44 | `sprint(showerror, e)` of a caught exception | `logerror!` |
| 22 | `sync!` calling `Source.fetch` and `Source.row` | `Core.TypedCallable` |
| 16 | the accessors' and `_jany`'s fallbacks | unknown read, unknown write |
| 13 | keyword calls | the rest of the untyped reads |
| 188 | the tail: `run!` 22, then one to six per function | the rest of the untyped reads |

The biggest by function, innermost frame: `refresh_` 42, `run!` 38,
`sync!` 28, `dispatch` 22, `browse/fetch.jl` 13 (closures), and `load_theme!`,
`pane_sync!`, `open_list`, `show_md` 10 each.

**Inside Base and dependencies, by the call of `wl`'s that reaches them** -
1056:

| errors | where | reached from |
|---|---|---|
| 440 | Base's error and backtrace printing | `logerror!`'s `showerror(io, e, bt)` |
| 122 | running a subprocess (`process.jl`) | `mux_spawn` 88, `token` 26, `gh_run` 8 |
| 96 | TermIFrame, TermInput | `mux_pane_state`, `iframe_sync!`, `mux`, … |
| 91 | Term's markup | `show_md` → `term_md` |
| 75 | GitHub.jl, HTTP, MbedTLS | `Events.auth`, and MbedTLS's callbacks |
| 43 | Pkg's `REPLExt`, REPL's keymaps | nothing of `wl`'s: Pkg's `__init__` |
| 42 | `sort!` | `thread`, `review_comments`, `poll`, `activity_of` |
| 32 | `print`/`println`/`write` on a stream typed `IO` | `dispatch` 20, `delink`, `show_md` |
| 13 | `tmux_jll`'s wrapper | `mux_cmd` |
| 12 | `asyncmap` | `prefetch_items` |
| 4 | `LazyLibrary`'s `dlopen` | JLL loading |
| 16 | Base closures, no frame of `wl`'s | tasks, annotated strings |
| 70 | the tail, two to six each | `for_term`'s `collect`, `spot_of`'s `deepcopy`, `stamp`'s `Dates.format`, `OrderedDict{String,Any}` built from rows in `load_inbox` and `import_urls`, `http_date`'s `findfirst`, … |

## Reproducing

```sh
ln -s $PWD/TermIFrame.jl $PWD/TermInput.jl /tmp/
julia +1.14-nightly --project=<env with JuliaC> -e 'using JuliaC; JuliaC.main(ARGS)' -- \
    --output-exe wl --project cli --trim=safe --experimental --bundle build entry.jl
```

with `entry.jl`:

```julia
using Worklog
function (@main)(args::Vector{String})::Cint
    return Worklog.main(args)
end
```

The symlinks put the two path dependencies where JuliaC's copy of `cli/`
(`/tmp/jl_XXXX`) looks for them. For 1.13, build from a copy of `cli/` with
its `Manifest.toml` deleted and `Pkg.instantiate()`d under `+1.13`, the two
submodules beside it; 1.13's verifier writes `Verifier error #` where 1.14
writes `Error #`, and leaves no blank line before `Stacktrace:`.

To run an `unsafe-warn` build, `ROOT` is `/tmp/`: copy `config.toml`,
`config.user.toml` and `themes/` there, and point `WORKLOG_DATA` at a copy of
`data/`.

The errors by function, innermost frame in `wl`'s own source:

```python
import re, sys, collections
errs = re.split(r'\n(?=Error #\d+:)', open(sys.argv[1]).read())[1:]
by = collections.Counter()
for e in errs:
    m = re.search(r'Stacktrace:\n\s*\[1\] (.*?)\n\s+@ \S+ (\S+):(\d+)', e)
    if m and '/jl_' in m.group(2):
        by[(re.sub(r'\(.*', '', m.group(1)), m.group(2).split('/src/')[1])] += 1
for (fn, f), n in by.most_common(40):
    print(n, fn, f)
```

The other table comes from the same split: for an error whose innermost
frame is not `wl`'s, the first frame that is (or TermIFrame's or TermInput's),
and the frame just inside it, which is the call into Base or the dependency.
