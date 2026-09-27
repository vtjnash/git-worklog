# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next

- [ ] upgrade tmux_jll to latest in Yggdrasil (check for open PR or make our own)
- [ ] **Run JET over `Worklog`.** A script like `aqua.jl`, or a testset if it
      is fast enough for the suite. `report_package` for the errors it can
      prove, and `report_opt` over the entry points (`dispatch`, `render`,
      `handle!`) for runtime dispatch - read knowing that the thread readers
      (`activity_list`, the node builders, `thread_seen`, `event_at`,
      `bk_failed`) are `@nospecialize` on purpose. Fix what is real; note
      what is deliberate where it is.
- [ ] Add a placeholder <refreshing> notice as the bottom node when opening an item history, in addition to the one in the margin, roughly where we expect new content to fill in (but only on open, not on explicit refresh)
- [ ] **A reader for a release or a commit comment.** A quick summary in the
      pane and the link to GitHub for the rest: notices are rare, so this is
      not a thread view. Today the pane is the block's own facts, no fetch.
      - Keep the subject's API url in the block: `sync!` writes an `api` key
        off `subject.url`, and `latest_comment_url` for a commit. A block
        from before has none, and stays as it is until its thread notifies
        again.
      - Fetch it in the task `comment_nodes` already runs for the pane, one
        request, cached with the thread's window; a failure leaves today's
        pane. `R` re-reads it rather than being refused.
      - A release: `GET /repos/o/r/releases/<id>` - the name, the tag, the
        first lines of the notes. Its `html_url` is the exact page, for the
        pane's link (not the block's), which answers LATER's release-link
        question at no cost to the poll.
      - A commit comment: `GET /repos/o/r/comments/<id>` - who, when, the
        file and line, the body. Not the commit's own message.
      - An advisory, a CI run, an invitation: nothing on the thread to ask
        about; unchanged.
      - Tests with the fetch passed in: each type's summary, a failed fetch,
        and no request until the notice is opened.
- [ ] **A reader for a discussion.** The same quick summary, and harder: REST
      has no endpoint for a repository's discussions, so it is GraphQL,
      `repository.discussion(number:)`, the number off `subject.url`.
      - The title, who opened it, when, the first lines of the body, how many
        comments; not the comments themselves - `o` is for those.
      - The query through `gh api graphql`, as the lanes' are, in the same
        task and cache as the item above, which should land first.

## Trim

`juliac --trim=safe` over `wl` (JuliaC 0.3, 1.14 nightly): 2281 errors
after the move to JSON.jl, from 2648. Built with an `@main` that calls
`Worklog.main`; each count below is the verifier's, which names a
method once, however many callers reach it. The Base items are under
*Upstream*.

- [ ] **Read `Dict{String,Any}` through the accessors.** 1299 errors, on
      407 lines in about 120 functions, are `wl`'s own code acting on a value
      typed `Any`: 179 `get(d, "k", …)` and 298 `d["k"]` sites, the 26
      `config()` reads, `String(…)` of a field (93), and `ActivityEntry.c`.
      Each becomes a `jstr`/`jint`/`jbool`/`jobj`/`jlist` read, or a
      concrete `isa`, at the point of use. Biggest first: `refresh_` (272),
      `dispatch` (164), `set_blocks!` (122, `local.toml` as
      `OrderedDict{String,Any}`), `push_node`, `pane_sync!`, `load_inbox`,
      `import_urls` (70-74 each), `activity_list`, `thread_entry`. Fewer
      dispatch sites for JET too.
- [ ] **Decide what an unknown container is, on read.** `jget`, `jstr`,
      `jint` and `jlist` test the concrete containers the program holds, then
      fall back to the generic read through one dynamic call each (`_jget`,
      `_anylist`, `String`/`Int` of an abstract). That fallback is the only
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

## Upstream

- [ ] **Report the 1.14 `LazyLibrary` regression.** A trimmed executable
      whose JLL loads a lazy dependency dies at load: `InitError(:libevent_jll,
      MethodError(dlopen, ("…/libcrypto.so.3", 0x44)))`. Four lines,
      `using libevent_jll` and an `@main`, with `--trim=unsafe-warn`: dies on
      the 1.14 nightly, runs on 1.13. `dlopen(string(ll.path::Any))` in
      `libdl.jl`.
- [ ] **Running a subprocess does not trim.** `read(`echo hi`, String)`
      alone is 30 errors on 1.13 and 44 on 1.14, all in `process.jl`
      (`setup_stdios`, `close_stdio`, `rawhandle`, the `cancel` keyword).
      Everything `wl` does goes through `gh`, `git` or `tmux`, so nothing
      else here makes a trimmed `wl` run until this does. Check the nightly
      first; report it if it is still so.

- [ ] **Take Term's header fix once it is released.** FedeClaudi/Term.jl#313
      (merged 2026-09-25, after v2.2.1) keeps a header's inline elements on
      one line; on 2.2.1 `## a `b` c` renders as three centred lines. Bump
      Term, and add the header case to the `render_md` tests.

- [ ] **Take Term's table fitting once it is released.**
      FedeClaudi/Term.jl#314 (open) makes `parse_md(::Markdown.Table)` fit
      the width it is handed, wrapping cells rather than truncating, and
      reads the table's box, style and row rules from the theme
      (`md_table_box`, `md_table_style`, `md_table_compact`). Bump Term; set
      `md_table_box = :MINIMAL_HEAVY_HEAD` and `md_table_compact = true`
      where `load_theme!` sets Term's theme, which is GitHub's look; add a
      test that JuliaLang/julia#63195's second table fits the pane at 60 and
      100 columns with every word of every cell present; and drop the table
      bullet from DESIGN's "Term.jl" section. Check whether a table nested in
      a list still needs `for_term`'s move to code once it is not padded to
      the width.

- [ ] **Drop `parse_gfm` once Julia aligns a plain column left.**
      JuliaLang/julia#63365 (open, RFC) makes `default_align` `:l`. When it
      is in the nightly this runs on, delete `gfm_table`, `GFM_FLAVOR` and
      `parse_gfm` (`ui.jl`), call `Markdown.parse` again, keep the alignment
      test in "a comment is drawn as GitHub draws a comment", and drop the
      bullet from DESIGN's "Julia's Markdown". If it lands as something else
      - a marker for no alignment - map that to `:l` in `for_term` instead.

- [ ] **Code spans before emphasis, once Julia has it.**
      JuliaLang/julia#63364 (open) matches code spans before emphasis, so
      `` *a `abc*` b* `` is italic around a code span. Nothing here works
      around it; when it is in the nightly, add that case to the `render_md`
      tests and drop the bullet from DESIGN's "Julia's Markdown".

- [ ] **File Highlights' `Pkg` import upstream.** `Highlights` 0.6 imports `Pkg`
      at load time for one `Pkg.Registry.reachable_registries()` in
      `available_language_jlls` (`languages.jl:40`), a discovery helper nothing
      calls on the way to highlighting. Measured with Highlights 0.6.2 under
      Term 2.2 on julia nightly, this sandbox: `import Pkg` alone is 0.28-0.30s;
      `import Term` is 0.91s cold and 0.56-0.67s with `Pkg` already loaded, so
      the import is 0.25-0.35s of every launch of everything that highlights
      anything. The fix upstream is `Base.require`-on-demand or an extension on
      `Pkg`. Still on master and still unfiled as of 2026-09-21
      (JuliaDocs/Highlights.jl has no issue on it). File it.

- [ ] **Offer Term a code palette that is part of its theme.** `Term.CodeTheme`
      is a hard-coded `Dict` that `set_theme` never touches; the `Theme` fields
      that look like they do that (`string`, `number`, `operator`, `type`…)
      drive only the old regex highlighter. `term_code_plain!` and the `[code]`
      table in `theme.jl` write into the `Dict` in place, which works only
      because the binding is `const` and the contents are anybody's. Offer a
      patch from the `Term.jl/` clone.

## Reading

- [ ] **A code span Term wrapped across two lines loses its background.** The
      second line gets a dim backtick and no background.

- [ ] **A search match on a url footnote is marked loosely.** The footnote row
      shows an elided form of the url, so the match is placed against text that
      is not what was searched.

- [ ] **A short fenced block reads as a labelled block.** *Decide: whether a
      short snippet should be part of the sentence instead.*
      A fenced block is a node with its own header and fold state, so a
      three-line snippet gets the same furniture as a file.
