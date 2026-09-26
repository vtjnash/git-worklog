# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next

- [ ] **Notices: a notification that is not an issue or pull request is a
      row, unread until dismissed.** Today `sync!` counts them ("N not an
      issue or pull request, skipped") and nothing else sees them: a
      Discussion, a Release, a commit comment, a CheckSuite or WorkflowRun,
      a Dependabot alert, a repository invitation. The plan:

      - **Not the corpus, and not the inbox.** A notice has no bundle, no
        state, no wake table and no url the by-url fetch can answer, and
        everything that reads the inbox's `items` - `stale_by`, the
        refresh's `involved` ask, `expect!`, the drop - would try to ask
        GitHub about it. Nor `fetched.json` at all: once the cursor is past
        a thread nothing asks for it again, so an unread one kept there is
        lost with the file, which must stay safe to delete. **The unread
        ones are blocks in `local.toml`**, one per notice and gone when it
        is dismissed - the set that stays small, where the dismissed set
        would only grow:

            ["notice:1234567"]
            type = "Release"
            repo = "JuliaLang/julia"
            title = "v1.12.0"
            reason = "subscribed"
            at = "2026-09-26T10:00:00Z"
            web = "https://github.com/JuliaLang/julia/releases"

        Keyed by the thread's `id`, which is stable across a thread's
        re-notifications; a thread that notifies again while its block
        stands updates `title`, `reason` and `at`. `thread_row` stays as it
        is; `sync!` hands what it now skips to `notice_row(t)` and writes
        the blocks in one `set_blocks!`, and the report line becomes "N
        notices". No request per notice: everything in the block is on the
        thread. The refresh's promotion of marked rows reads `https://`
        keys only, so it never sees one.
      - **The row.** `url` is the block's key - a key, as `local:` is - and
        `web` the link: a Commit's from `subject.url`'s sha (and
        `#commitcomment-N` off `latest_comment_url`); a Release
        `/<repo>/releases`; CheckSuite and WorkflowRun `/<repo>/actions`;
        the alerts `/<repo>/security/dependabot`; an invitation
        `/<repo>/invitations`; a Discussion and anything else the
        repository. `lane = "notifications"`, `reason`, the `mentioned`
        latch off the reason, `moved_at` and `updated` from `at`, no
        author, `number = 0`. `notice_items()` makes `Item`s of the blocks,
        and `corpus_items` appends them, so `wl unread`, `wl done all` and
        the browser stay one list.
      - **Presence is the seen bit.** A notice is unread while its block
        stands and gone when it does not - `seen_of` says `:unread` for one
        before it looks at a stamp or a floor. `consolidate!` skips it, as
        it does a row with no movement: it has no stamp for the floor to
        answer for, and counted as a stampless unread row it would hold
        every `since` down for as long as one stood.
      - **`e` and `x` dismiss; `s` refuses.** Both remove the block and say
        `dismissed <ref>`; `z` writes it back and `Z` removes it again,
        with no `touched` stamp either way. There is no "not done" to
        toggle to, and no `filed` for it to be in. `s` says "a notice has
        no snooze - e dismisses it", and `wl snooze` / `wl archive` on a
        `notice:` key the same; `wl done <key>` and `wl done all` dismiss.
        What cannot apply is refused the way an adopted branch's is
        (`not_pr`): `C`, `A`, `M`, `L`, `;`, `R`; the `d`, `p` and `c`
        readings are empty. `o` and `y` take `web`.
      - **The cursor filters all but the overlap, and the poll remembers
        that.** `sync!` asks from five minutes behind the cursor, a day
        while `wide`, which is there for a thread made visible late; inside
        that window a dismissed thread read again and a late one read for
        the first time look the same. So the poll keeps what it has made
        into notices, `inbox.noticed[id] = updated_at`, and a thread at or
        under its entry is not a notice again; one that notifies again is
        past it and is back, unread, which is the point. Pruned by `sync!`
        once under `cursor - 1 day`, the widest ask. `sync!` is its one
        writer, and the browser writes only `local.toml`, where it only
        removes a block and the poll only adds one for an `(id, at)` it has
        not had - so the two cannot bring a dismissed notice back between
        them. Losing `fetched.json` costs at most one overlap's worth of
        dismissed notices shown again, which is what the overlap costs any
        row.
      - **The axes.** `kind` gains a fourth value, `notice`, beside `pr`
        and `issue` (`kind_ok` stops reading `!is_pr` as an issue). On
        `state` a notice is `closed or merged` (`over_of`): the question
        that axis answers is "is it open work", and a closed thing that
        moved is exactly what the firehose shows and the backlog leaves
        out. So a notice is in the firehose, and in neither my work (it has
        no author) nor the backlog. The pane's `state` row says the
        subject's type, not "closed". The list's kind column says the type
        in words: `release`, `discussion`, `commit`, `CI`, `alert`,
        `invite`.
      - **The pane is the notice's own facts**: type, reason, repository,
        when, the link - `notice_nodes`, beside `local_nodes`. No fetch, and
        no meta pane request; every `islocal` guard that means "not a
        GitHub issue or pull request" (`fetch_bundle`, `prefetch`,
        `meta.jl`, `content.jl`, `checkout.jl`, `writing.jl`) becomes one
        predicate that covers both.
      - **No history.** The cursor is already running, and only threads
        from it on arrive; switching this on is not a quarter of releases
        to dismiss.

      Tests, with raw threads as fixtures: each subject type makes the block
      and link above; `e`, `x` and `wl done all` remove it; `z` writes it
      back; a re-read inside the overlap stays gone and a later
      notification comes back; `noticed` is pruned under `cursor - 1 day`;
      a re-notify updates a standing block in place; `seen_of` is unread
      and `consolidate!` unmoved by one; the firehose has it, my work and
      the backlog do not; `s` refused. Docs: README for the rows and the
      keys, DESIGN "Marks" for presence as the seen bit and "Ownership" for
      the one kind of `local.toml` block the poll writes whole, the `kind` axis in
      `config.toml`'s comment. **Measure first**, with a person's token,
      what `subject.url` and `latest_comment_url` carry for each type - a
      Discussion's has been `null` - and whether a Discussion has any url
      better than its repository's discussions page. A reader for a
      Release body or a commit comment is later, and is one REST `GET`
      each.
- [ ] a lot of features have been added since last updating the precompile list, so it may need to be regenerated
- [ ] upgrade tmux_jll to latest in Yggdrasil (check for open PR or make our own)

## Upstream

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
