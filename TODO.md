# TODO

What needs doing now. Shipped work is in `git log`; why things are shaped as
they are is in DESIGN.md; what is blocked or undecided is in LATER.md. An item
leaves by being done - or, under *Unverified*, by being run in a real terminal,
when its write-up goes to `cli/test/MANUAL.md` and the line here goes.

## Next

- [ ] after exiting Claude, it seems like the pane stays locked (needing ^]K to close), rather than any key as for bash (time to read the exit message is good, but somehow isn't seeing the session ended in the same way), even though ^]q closes it entirely too
- [ ] Can we design for adding unread entries corresponding to the 'notifications 2 not an issue or pull request, skipped" items (once read/archived they are simply deleted, and refused to be snoozed)
- [ ] a lot of features have been added since last updating the precompile list, so it may need to be regenerated
- [ ] upgrade tmux_jll to latest in Yggdrasil (check for open PR or make our own)
- [ ] does term.js expose whether to use a light or dark theme, which we could add as a keybinding to read and redraw if that code arrives (send the query on startup, but don't wait for reply)

## Upstream

- [ ] **Bump Term to v2.2.1 and take out the workarounds it retires.** v2.2.1
      (2026-09-17) carries FedeClaudi/Term.jl#304, #305, #306, #309 and #310;
      the Manifest pins 2.2.0. Bump, run the suite, then delete what each one
      stood in for:

      | fixed | workaround here |
      |---|---|
      | #304 braces deleted in prose, doubled in code spans | the brace half of `escape_source`, and `render_md`'s collapse |
      | #305 empty list item is a `BoundsError` | `for_term` fills it |
      | #306 table nested in a list is a `MethodError` | `for_term` moves it to a code block |
      | #309 code span in a table header drawn as a block | header cells wrapped in a `Paragraph` |

      #310 (`leftalign`/`vstack` re-wrapping a wide table) never needed one:
      `render_md` is handed a pane width. Keep the underscore half of
      `escape_source` - JuliaLang/julia#63081 is still open. Rewrite DESIGN's
      "Term.jl (v2.2, pinned)" section to match what is left.

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

## The list

- [ ] **Discussions, releases, commit comments.** *Decide: whether to open them
      at all.*
      The notifications source sees each arrive and skips it, counted. Nothing
      here can open one.

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
