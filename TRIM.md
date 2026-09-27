# What `--trim` would cost Worklog

2026-09-27. JuliaC 0.3.10, entry point a four-line script calling
`Worklog.main(args)` as `@main`, built against `cli/` at `b01cb16`. Tried
on the 1.14 nightly (1.14.0-DEV.3217, what the manifest is resolved with) and
on 1.13.0 (a scratch copy of `cli/` resolved afresh, since the manifest is a
1.14 one).

## The short answer

`wl` cannot be trimmed today, and the reason is partly in Base, but mostly
in `wl` itself.

- `--trim=safe` refuses to build: **2648 errors** on 1.14, **2461** on 1.13.
- `--trim=unsafe-warn` builds (a 25 MB executable in a 162-168 MB bundle),
  and **the binary dies before doing anything** on both:
  - on 1.14, at load: `InitError(:libevent_jll, MethodError(dlopen, ...libcrypto.so.3))`.
    This is a nightly regression: a four-line program doing only
    `using libevent_jll` dies the same way on 1.14 and runs on 1.13.
  - on 1.13, at the first line of `main`: `MethodError` on the keyword body
    of `seed_config!`. That call passes the global `stderr`, which is typed
    `IO`, so the body was never compiled for `IOStream`. Every command goes
    through it, `--help` included.

An `unsafe-warn` binary turns every one of those ~2500 sites into a
`MethodError` that appears only when the line runs. It is not a usable
middle ground for a program whose code paths are the command surface.

For comparison, today's `cli/bin/wl --help` warm is 1.7-2.0 s, loading a
161 MB package image.

## The plan

1434 errors under `--trim=safe` on the 1.14 nightly, 401 of them in `wl`'s
own code (2026-09-27, after the accessors below and the stored functions). The verifier counts each
method once, however many callers reach it, and **does not look inside a
call it cannot resolve** - so typing a call site makes its callee visible,
and a count can rise as code is fixed. What needs Julia itself is in TODO,
*Upstream*: the 1.14 `LazyLibrary` regression, subprocesses, and
`@nospecialize` on an argument with a default.

- [ ] **The rest of the untyped reads.** Of the 401 left in `wl`'s code, 178
      are the three items below (`@printf` 81, `stdout`/`stderr` 56,
      `showerror` 41) and 12 are `sync!` calling a `Source`'s functions (the
      next item); nearly all the rest is a tail of one or two per function
      (`run!`, `load_theme!`, `merge_state`, `search`'s `take!`). Two
      stored values are typed `Any` so the suite can replace them: `_PAT`,
      the token, which a test sets to a string; and `Source`'s functions.
      The tabulation to recount with is under "Reproducing".
- [ ] **`Source.fetch` and `Source.row` as `Core.TypedCallable`s, once there
      is one.** `sync!`'s sources are the one real callback interface in
      `wl`: three kinds, and the tests' own. Their signatures are settled and
      written on `Source`; `SyncCtx` is the context's type. The same fits
      TermIFrame's `iframe` hooks (`onend`, `suspend`, `onerror`), which a
      library cannot type by its host's types. Waiting on
      JuliaLang/julia#62559 (draft, "Part 1/2", on #62245) and the trim
      support its description leaves to a second part; the RFC is #59774.
- [ ] **`mux_list`'s rows.** `Vector{NamedTuple}`, fields named by
      `MUX_TAGS` at run time, so every read of a row is dynamic, and
      `BState.sessions`/`taken` hold them as `NamedTuple`. Being looked at.
- [ ] **Decide what an unknown container is, on read.** `jget`, `jstr`,
      `jint` and `jlist` test the concrete containers the program holds, then
      fall back to the generic read through one dynamic call each (`_jget`,
      `_anylist`, `_anydict`, `_kept_row`, `_falsy`, `_same`, `_fmt`,
      `String`/`Int` of an abstract). That fallback is the only
      trim error left in them, and it is where a shape nobody listed goes -
      a fresh fetch's `Vector{String}`, a vector of `OrderedDict`s, a test's
      `Dict{String,String}`. Find what actually reaches it (count the
      fallback's types across a suite run and a traced session), then either
      list those or build them as `Dict{String,Any}`/`Vector{Any}` where they
      are made. Either way, a test per shape: nothing proves a fresh fetch and
      its cached copy read the same except the one for `_meta_shape`.
- [ ] **Decide what an unknown value is, on write.** `json_dumps`
      specialises while the static type is known and narrows an `Any` in
      `_jany`; anything unlisted falls back to a dynamic `_jvalue`. As a
      closed list it took eight rounds of the suite to find the types that
      reach it (`Dict{String,Vector{Any}}`, `Vector{Pair{String,String}}`,
      `Vector{Nothing}`, `Dict{String,Dict{String,String}}`, …), and a write
      that fails is silent: `cache_put` swallows it, and the cache stops
      working. At least `logerror!` it there; then settle which shapes the
      cache and `fetched.json` hold, as above.
- [ ] **`logerror!` without `showerror(io, e, bt)`.** 444 errors from that
      one call: printing an exception of unknown type, with its backtrace,
      is all of Base's error printing. The same for the dozen
      `sprint(showerror, e)` sites. Say `e.msg` for the exception types `wl`
      owns, and the type's name for the rest.
- [ ] **A concrete stream for `stderr` and `stdout`.** Both are `IO`-typed
      globals: 130 errors, the `@printf`s (53) among them, and the one that
      kills a trimmed build first - `seed_config!`'s `io = stderr`, a
      keyword call on every command.
- [ ] **`ROOT` from where the program is, not where it was built.**
      `@__DIR__` is fixed at build time, and JuliaC builds from a copy under
      `/tmp`. From the executable's path or `WORKLOG_DATA`'s parent, with
      `config.toml`, `themes/` and prefetch's `cli/bin/wl` under it.
- [ ] **GitHub.jl for the REST calls.** `Events.auth` alone is 60 errors
      (HTTP, MbedTLS, URIs), and it is the only reason HTTP is loaded. `gh
      api` serves the lanes already; it could serve these, once running a
      subprocess trims (*Upstream*).

## Where the errors come from

Classified by what the stack and the statement name. It is a heuristic: an
error lands in the first bucket that matches. The rows are 1.14; 1.13 has
the same shape (in the second column).

| | 1.14 | 1.13 |
|---|---|---|
| **`wl`'s own untyped values**, all kinds | **1632 (62%)** | **1610 (65%)** |
| … `Dict{String,Any}` rows and config, named in the statement | 341 | 433 |
| … `ActivityEntry.c::Any`, the `@nospecialize` thread readers | 92 | 98 |
| … `sort!`/`lt`, keyword calls, `Vector{NamedTuple}` | 77 | 77 |
| … other `::Any` locals (mostly downstream of the above) | 1122 | 1032 |
| **Printing a caught exception** (`showerror(io, e, bt)`) | 444 | 342 |
| **JSON3 `read`/`write`** | 182 | 172 |
| **Running a subprocess** (`read(::Cmd)`, `run`, `open`) | 133 | 84 |
| GitHub.jl / HTTP / MbedTLS | 78 | 60 |
| TermIFrame, TermInput | 70 | 64 |
| `Printf` into `stderr::IO` | 53 | 53 |
| REPL.LineEdit / Terminals, FileWatching, other | 59 | 49 |

The verifier reports each unresolved method once, however many callers reach
it, so a Base or dependency bucket counts the first path to it. The
subprocess and `showerror` rows are one chokepoint each.

The errors sit at 484 distinct lines in 134 functions. The top ten account
for over half:

| errors | function | why |
|---|---|---|
| 444 | `logerror!` (`controller.jl:656`) | `showerror(io, e, bt)` of an `e::Any` pulls in all of Base's error and backtrace printing |
| 286 | `refresh_` | `Dict{String,Any}` items and `fetched.json` rows |
| 166 | `dispatch` | the whole command surface, `pinned_repos()::Vector`, `@printf(stderr, …)` |
| 136 | `cache_put` | `JSON3.write` of an untyped value |
| 122 | `set_blocks!` | `local.toml` edits as `OrderedDict{String,Any}` |
| 78 | `import_urls` | REST rows |
| 74 | `push_node` | `run::Any` |
| 72 | `gh_run` | `read(::Cmd)` |
| 72 | `load_inbox` | inbox rows `Dict{String,Any}` |
| 60 | `Events.auth` | `GitHub.authenticate`: HTTP, MbedTLS, JSON |

## The parts `wl` cannot fix by itself

1. **Subprocesses.** `read(`echo hi`, String)` alone fails `--trim=safe`:
   30 errors on 1.13 and 44 on 1.14, all inside `process.jl`
   (`setup_stdios`, `close_stdio`, `rawhandle`, the `cancel` keyword).
   `wl` is a program that runs `gh`, `git` and `tmux`, through `gh_run`,
   `git`, `token`, `mux`, `_curl_json`, `head_sha`, `pr_branch` and prefetch.
   Nothing in its own code gets around this short of a Base fix or its own
   `posix_spawn` through `ccall`.
2. **JLL lazy libraries on 1.14.** Any JLL whose library depends on another
   lazily loaded one (here `tmux_jll` → `libevent_jll` → `libcrypto`) cannot
   start. Base's `LazyLibrary` `dlopen`s `string(ll.path::Any)`. This is a
   bug to report, not a design problem.
3. **`showerror` of an unknown exception.** Even `sprint(showerror, e)`
   with `e::Any` is 2 errors in a minimal program. `logerror!` also prints
   the backtrace, and that is where the 444 come from. `wl` catches and
   words errors in about a dozen places (`theme.jl`, `events.jl`,
   `prefetch.jl`, `meta.jl`, TermInput's `suspend`). Under trim, each would
   have to say `e.msg` for the exception types `wl` owns and a fixed
   string, or `typeof(e)`, for the rest.

## The parts that are `wl`'s design

These are the same things `JET.md` left as "by design", and trim would
not allow them.

- **`Dict{String,Any}`** as the currency for config, inbox rows, `local.toml`
  blocks, REST answers, normalised items and the cache. Every `get(d, k, x)`
  is `Any` and so is everything done with it. The `jstr`/`jint`/`jobj`
  wrappers help where they are used, but their argument is still `Any`, and
  under trim `jstr(::Any)` is itself a dynamic call (90 of the errors are
  calls to `jstr`, 22 to `jobj`). It would take concrete record types -
  structs for the config, an inbox row, an item and a cache entry - read
  once at the edge.
- **JSON3.** `JSON3.read` to an untyped `Object`/`Array` and `JSON3.write`
  of `Any` are both reflective. It would need typed reads into those
  structs, or a hand-written reader and writer for the few shapes the
  cache holds.
- **`ActivityEntry.c::Any` and the `@nospecialize` thread readers.** They
  exist to compile once over every shape of JSON thread. Under trim, "once
  over every shape" is not possible: each shape must be a type.
- **GitHub.jl** for REST: `authenticate` drags in HTTP, MbedTLS, URIs and
  JSON. `gh api` already serves the lanes and could serve these too, but
  that runs into (1).
- **`stdout`/`stderr` are `IO`-typed globals.** 130 errors name
  `stderr::IO` or `stdout::IO`. Each `println(stderr, …)`, `@printf`, and
  the `io = stderr` default of `seed_config!` - the crash above - needs a
  concrete stream.

## What it would take, in order

1. Upstream: report the 1.14 `LazyLibrary` regression; trim-safe
   `read(::Cmd)`/`run` in Base (or check whether a newer nightly already
   has it).
2. `logerror!` and the `sprint(showerror, e)` sites: word the exception
   types `wl` owns by their `msg`, and the rest by type alone.
3. Concrete streams for `stderr`/`stdout` at the few places that print.
4. Typed records for config, inbox rows, items and cache entries. This is
   the real cost: most of the 1600 errors in `wl`'s own code go with it. It
   also undoes the "`c` stays untyped" decision behind the thread readers.
5. JSON3 replaced at the cache and REST edges; GitHub.jl dropped.

Steps 2 and 3 are small and would help JET's dispatch counts regardless.
(As it went: step 5 is done, and step 4 was done without structs - one
`@nospecialize` accessor per kind of read, narrowed where the value is used;
see the two sections at the end, and "The plan" above for what is left.)
Step 4 is a rewrite of the data layer, which trim alone does not justify: a
trimmed `wl` would still need the `gh`, `git` and `tmux` it shells out to,
and a Julia with (1) fixed.

## Reproducing

```sh
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

A trimmed build also bakes `ROOT` (`@__DIR__/../..`) at build time. JuliaC
builds from a copy of the project in `/tmp/jl_XXXX`, so `ROOT` came out as
`/tmp/` and `config.toml`, `themes/` and `cli/bin/wl` (prefetch) were looked
for there. `ROOT` would have to come from the executable's location or the
environment.

## Afterwards: step 4 measured, JSON3 to JSON.jl

JSON.jl 1.8 is already in the manifest, through GitHub.jl. Small programs
built with `--trim=safe` on 1.14:

| | trim errors | runs |
|---|---|---|
| JSON3 untyped, with today's `jget`/`jstr` | 66 | - |
| JSON3 + StructTypes into structs | 20 | - |
| JSON.jl into structs (`JSON.parse(s, T)`) | 0 | yes |
| JSON.jl untyped, one `@nospecialize` method per accessor, narrowed by concrete `isa` | 0 | yes |
| `JSON.json` of `Any` values | 12-15 | - |
| `json_dumps` narrowed to concrete types | 0 | yes |

`JSON.parse` answers concrete containers (`JSON.Object{String,Any}`,
`Vector{Any}`), and its objects take `Symbol` keys and `o.a.b`, so it can
replace JSON3 almost unchanged.

Tried on `wl` itself, in a scratch worktree (`.worktrees/trim`, 18 files,
+139 -67). The suite passes:

- `jget`/`jstr`/`jint`/`jbool`/`jobj`/`jlist`/`jnodes`/`jpath`/`pget`: one
  `@nospecialize` method each, narrowed to `JSON.Object{String,Any}`,
  `Dict{String,Any}`, `OrderedDict{String,Any}`, `Dict{Symbol,Any}` and
  `Dict{String,String}`.
- JSON3 replaced by `JSON.parse` and `json_dumps` at every call site.
- `json_dumps` specialises while the static type is concrete, including
  NamedTuples through a `@generated` field walk, and narrows `Any` through a
  closed list (`_jany`).

As a closed list, that list was the cost. Eight container types had to be
added one run at a time before the suite passed - `Dict{String,Vector{Any}}`,
`Dict{String,Dict{String,String}}`, `Vector{Pair{String,String}}`,
`Vector{Nothing}` among them. A missing type failed the write, and
`cache_put` swallowed the error, so the cache silently stopped working. The
read side missed silently too, and in a case the suite did not cover: a
fresh `item_meta` fetch builds `requested` as a `Vector{String}`, which a
`Vector{Any}`-only `jlist` read as empty.

So what was committed tests the listed types first and then falls back to
the old generic read or write, through one dynamic call per accessor
(`_jget`, `_anylist`, `_jvalue` from `_jany`). Behaviour is what it was, the
listed shapes are trim-clean, and the fallback sites are what is left to
decide ("The plan"). A test now checks that a fresh fetch's metadata and
the cached copy read the same.

Result, with the closed lists: 2648 → 2275 errors. The JSON bucket goes from
182 to 0, and calls to the accessors from 150 unresolved to 0. Errors in
`wl`'s own code fall only from 1486 to 1293, and the lines with one from 468
to 403. What remains is code that reads `Dict{String,Any}` directly rather
than through the accessors: 179 `get(d, "k", …)` and 298 `d["k"]` sites, the
26 `config()` reads, and `ActivityEntry.c`. Each needs a `jstr`-style read,
or a concrete `isa`, at the point of use - mechanical, a few hundred sites.

## Afterwards: the accessors, read at the point of use

The first Trim item, done for the biggest sites. 2281 → 1498 errors in all,
and `wl`'s own 1299 → 456, with the suite and Aqua passing. Worth knowing
before the next round:

- **The count is not monotonic.** The verifier does not descend into a call
  it cannot resolve, so `derive!`, `event_at`, `sync!`, `poll_item` and
  `load_theme!` were never checked until their callers were typed; the first
  round went *up*, 2281 → 2376, before it came down.
- **`"k" => v` with `v::Any` is a dynamic call**, and so is storing `v` into an
  `OrderedDict{String,Any}` - OrderedCollections' `setindex!` specializes on
  the value; Base's `Dict{K,Any}` does not. Hence `Record = Dict{String,Any}`
  for the refresh's rows, filled key by key.
- **`@nospecialize(x) = nothing` does nothing**: an argument with a default
  loses the mark on every method (DESIGN, "Julia, read by `--trim`"; a bug
  to file, TODO *Upstream*).
- **`String(s)` of an `AbstractString` returns `Any`**; asserted `::String`,
  the one fallback call is the only error instead of everything downstream.

### Reproducing, continued

Building from this checkout needs the two path dependencies where JuliaC's
copy of `cli/` (`/tmp/jl_XXXX`) looks for them: `ln -s $PWD/TermIFrame.jl
$PWD/TermInput.jl /tmp/`. The errors by function, innermost frame in `wl`'s
own source:

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
