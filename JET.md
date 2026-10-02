# JET over wl, TermInput and TermIFrame

What JET reports for the three packages, and why what it still reports cannot
be resolved by analysis. As of 2026-10-02.

## How it is run

JET 0.12.2 under Julia 1.13. JET's release build is empty stubs on the 1.14
nightly this is developed on, and its dev mode does not precompile there, so it
runs from a scratch environment:

    julia +1.13 --project=<scratch> -e 'using Pkg;
        Pkg.develop([PackageSpec(path = "TermInput.jl"),
                     PackageSpec(path = "TermIFrame.jl"),
                     PackageSpec(path = "cli")]);
        Pkg.add("JET")'

Two analyses, each with `target_modules = (M,)`:

- `report_package(M)` - calls that can fail, every method analysed at its
  declared signature.
- `report_opt` - runtime dispatch and captured (boxed) variables. For wl, from
  its entry points: `dispatch(::Vector{String}, ::DateTime)`, and `render` and
  `handle!` on `BState`, `PaneView`, `SideView` and `WorktreeView`. For the two
  packages, which have no single entry point, over every method whose declared
  signature is concrete (266 in TermInput, 80 in TermIFrame).

A dispatch site is counted once, at the innermost frame inside the module.

## Results

| | wl | TermInput | TermIFrame |
|---|---|---|---|
| `report_package` reports | 0 | 0 | 0 |
| captured (boxed) variables | 0 | 0 | 0 |
| dispatch sites | 225 | 17 | 10 |

`render(::BState)` is at 4 sites, `render(::PaneView)` at 3.

## What is left

Every remaining site is a value whose type exists only at run time. They are
counted below by the reason.

### wl (225)

- **Data read at run time - 110.** JSON from GitHub and Buildkite, the inbox,
  `fetched.json`, the cache, `config.toml` and the theme files, `local.toml`
  and `state.toml`, and a `Node`'s `meta`. All of these are
  `Dict{String,Any}`, and what is in one is known only when it is read.
  `jstr`, `jint`, `jlist` and the rest in `util.jl` turn a field into a typed
  value; the sites are inside those readers, in the `@nospecialize` JSON
  writer (`pyjson.jl`), and in code that walks a table whole: the inbox
  `expect` table in `events.jl` (43 of the 110), config views, agent
  settings and theme tables.
- **Writes to an abstract `IO` - 57.** `println` and `@printf` to `stdout`,
  whose type is whatever the process was started with, and `IOContext` over it.
- **Exceptions - 38.** `sprint(showerror, e)` and `logerror!(e, …)` on a
  caught `e`.
- **Views - 11.** `render`, `handle!`, `onwake!`, `viewtitle` and the rest on
  an element of `ctrl.stack`, or on a `SideView`'s `inner`. Calling the view on
  top is how the controller works.
- **Callbacks - 9.** A function held in a field and called: a source's `fetch`
  and `row`, `WorktreeView`'s `onitem`, `onadopt` and `source`, an undo's
  `undo` and `redo`, `settle_expectations!`'s `lastby`. `WorktreeView`'s
  answers are asserted where their type is promised, so for those only the
  call itself dispatches; a source's answer is JSON, and counted above.

### TermInput (17)

- **The stdlib Markdown tree - 11.** `block!` and `inlines` dispatch on the
  node type of `Markdown.MD`'s `content`, which is a `Vector{Any}`, and so is
  each list item's.
- **Writes to an abstract `IO` - 5.** `HeldTerminal`'s `in` and `out`, and
  `input_waiting(::IO)`.
- **Exceptions - 1.**

### TermIFrame (10)

- **The control client's pipes - 8.** `eachline`, `write`, `flush` and `close`
  on `Base.Process`'s `in` and `out`, which are declared `IO`; the `print` of
  a relay to the host's `out`.
- **Exceptions - 2.**

## Keeping it at zero

The patterns behind every report fixed so far. A new report is almost always
one of them.

- **A test of a field narrows nothing.** `f.client === nothing || g(f.client)`
  still passes `g` a `Union`. Copy the field to a local and test that. The
  same for a union of `NamedTuple`s: testing `r.path` narrows neither `r`
  nor the next `r.path`.
- **`isa` inside `&&` narrows nothing after it.** Make
  `(x isa T && c) || return` two lines: `x isa T || return`, then `c || return`.
- **A closure boxes what it captures if the variable is assigned again.**
  Bind a new name, take the value as a `do` block's return, or pass the state
  in as an argument.
- **`String(x)` of an `AbstractString` is not inferred to be a `String`,** and
  `"a" * x` with `x` untyped may be a `Regex` or `Missing`. Use
  `string("a", x)`, or assert `String(x)::String`.
- **A comprehension over an abstract or untyped iterator is not a `Vector`,**
  not even `String[f(t) for t in tags]`. Build it with a loop. A broadcast
  `tryparse.(Int, fs)` is no better. `collect(eachmatch(…))` is a
  `Vector{RegexMatch}` with no parameter: `collect(RegexMatch{String}, …)`.
- **A regex capture is `Union{Nothing,SubString}`.** Use `something(m[k])`
  for a group the pattern requires.
- **One function, several shapes.** An answer whose shape follows a tag, such
  as `compose_target`'s `(kind, target)` or `mux_feed!`'s `(kind, a, b)`, is
  asserted once, where it is taken apart.
- **A field, channel or container declared `Any`** loses everything read from
  it. Declare it: `PaneView.beside`, `MuxClient.replies` and `BState.failing`
  are typed for this reason.
- **A struct rebuilt from `fieldnames`** splats a tuple of unknown length.
  `with(it::Item; kw...)` merges a `NamedTuple` of the fields with `kw`.

## Limits

- JET runs only on released Julia, so a script beside `aqua.jl` would need an
  environment and manifest of its own for 1.13. Until then it is the scratch
  environment above.
- `report_package` analyses an untyped argument as `Any`, so a function only
  ever called with a `String` is reported as if anything could reach it. The
  fix is the type its callers pass, which often lets JET reach code behind it
  with findings of its own. Run it again after each round.
- `report_opt` sees only what its entry points reach. A field typed `Any` hides
  what is behind it, and typing it brings that code into view:
  `handle!(::PaneView)` reaches the browser's keys through `beside`, 158
  sites that are counted under `handle!(::BState)` as well.
