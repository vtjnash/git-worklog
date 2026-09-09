# `stdlib/Markdown`: an underscore inside a word opens emphasis

One bug, with a repro, a patch that fixes it, and an acceptance test that is
already in the tree. Found while rendering GitHub comment threads in a terminal
UI, where it eats characters out of nearly every comment that names a function.
It is worked around downstream, so nothing is waiting on the fix.

Verified against Julia `1.14.0-DEV.3040` (`08eef7536a`, 2026-08-22).

## What it does

```julia
julia> Markdown.parse("call deliver_result and connect_to_peer here").content[1].content
3-element Vector{Any}:
 "call deliver"
 Markdown.Italic(Any["result and connect"])
 "to_peer here"
```

Rendered, that is `call deliverresult and connectto_peer here` — the underscores
are *gone* and three words are italic. Every `snake_case` name written in prose
rather than in backticks loses characters, in docstrings, READMEs and anything
else that goes through this parser.

It takes **two** underscores to pair, so `deliver_result` on its own comes back
intact and a one-word test looks fine. That is what makes it easy to miss and
worth putting in the report: it needs a realistic sentence to show up.

All four flavors do it — `:julia`, `:common`, `:github` and the default.

## Why it is a bug and not a dialect

CommonMark forbids it, in the rules for emphasis:

> **Rule 2.** A single `_` character can open emphasis iff it is part of a
> left-flanking delimiter run and either (a) not part of a right-flanking
> delimiter run or (b) part of a right-flanking delimiter run preceded by
> punctuation.

and symmetrically for closing in rule 6. An underscore with a letter on each
side is both left- and right-flanking and is not preceded by punctuation, so it
can neither open nor close. `*` has no such restriction — `foo*bar*` **is**
emphasis — which is why the fix has to be per delimiter rather than for both.

GitHub renders `deliver_result` intact, so the disagreement is with the page the
text was copied from.

## Where it is

`stdlib/Markdown/src/Common/inline.jl` — `underscore_italic` (line 18) and
`underscore_bold` (line 34) both call `parse_inline_wrapper` with no constraint
on what surrounds the delimiter:

```julia
@trigger '_' ->
function underscore_italic(stream::IO, md::MD)
    result = parse_inline_wrapper(stream, "_")
    return result === nothing ? nothing : Italic(parseinline(result, md))
end
```

`stdlib/Markdown/src/parse/util.jl:170` — `parse_inline_wrapper` is shared by
`*`, `_`, `~` and the rest. What it checks today is:

* the previous byte is not itself a delimiter (so `__` does not fire the italic
  rule);
* the character after the opening run is not a space;
* a closing run must be preceded by a non-space, non-delimiter character.

That is the *flanking* half of the CommonMark rule and none of the intraword
half.

## The shape of the fix

`parse_inline_wrapper` is shared by every symmetrical delimiter, so the
constraint has to be per delimiter: an `intraword` keyword defaulting to `true`,
which the two underscore triggers pass as `false`. With it off:

* **opening** is refused when the character *before* the run is a word
  character, which is the whole of `foo_bar_`, `5_6_78` and `aa_"bb"_cc`;
* **closing** is refused when the character *after* the run is one — and the
  scan then *continues* rather than giving up, which is what makes
  `_foo_bar_baz_` emphasise across its inner underscores the way the spec says,
  instead of failing to close at all.

Two details that are easy to get wrong:

* Reading the character before the run has to step back over UTF-8 continuation
  bytes, or the Cyrillic examples below still fail. The pre-existing "previous
  byte isn't a delimiter" check a few lines down does `skip(stream, -1)` and
  `read(stream, Char)`, which reads from the middle of a multibyte character —
  harmless for its own purpose, and the same trap, so worth fixing in passing.
* "Word character" here means *neither unicode whitespace nor unicode
  punctuation*, per the spec. `isletter(c) || isnumeric(c)` agrees with it on
  everything the spec suite exercises, including the symbol classes (`$ + < = >
  ^ | ~` are `Sm`/`Sc`, which CommonMark does not count as punctuation for this
  rule), so either reading works; the category test is the exact one.

A patch of that shape was tried against a copy of the module before this was
written — see the numbers below.

## The acceptance test is already in the tree

`stdlib/Markdown/test/` carries the CommonMark spec (`spec.json`, 652 examples)
and generated runners for it. Each records the examples Julia is known to fail
in a `known_broken` set, runs them anyway, and pushes into `now_passing` any that
unexpectedly pass — with `@test now_passing == Int[]` at the bottom. **So a fix
makes the suite fail on purpose**, and the response is to rerun
`stdlib/Markdown/test/regenerate_test_spec.jl` and commit the six regenerated
files.

Running the whole spec against a patched copy and against a stock one, at
`flavor = :common`: **294 failing before, 277 after — 17 newly passing, none
newly failing.** Every one of the 17 is this bug:

| # | input | expected |
|---|---|---|
| 359 | `a_"foo"_` | `<p>a_&quot;foo&quot;_</p>` |
| 360 | `foo_bar_` | `<p>foo_bar_</p>` |
| 361 | `5_6_78` | `<p>5_6_78</p>` |
| 362 | `пристаням_стремятся_` | `<p>пристаням_стремятся_</p>` |
| 363 | `aa_"bb"_cc` | `<p>aa_&quot;bb&quot;_cc</p>` |
| 372 | `_(_foo)` | `<p>_(_foo)</p>` |
| 374 | `_foo_bar` | `<p>_foo_bar</p>` |
| 375 | `_пристаням_стремятся` | `<p>_пристаням_стремятся</p>` |
| 376 | `_foo_bar_baz_` | `<p><em>foo_bar_baz</em></p>` |
| 385 | `a__"foo"__` | `<p>a__&quot;foo&quot;__</p>` |
| 386 | `foo__bar__` | `<p>foo__bar__</p>` |
| 387 | `5__6__78` | `<p>5__6__78</p>` |
| 388 | `пристаням__стремятся__` | `<p>пристаням__стремятся__</p>` |
| 398 | `__(__foo)` | `<p>__(__foo)</p>` |
| 400 | `__foo__bar` | `<p>__foo__bar</p>` |
| 401 | `__пристаням__стремятся` | `<p>__пристаням__стремятся</p>` |
| 402 | `__foo__bar__baz__` | `<p><strong>foo__bar__baz</strong></p>` |

A hand-written regression test belongs in `stdlib/Markdown/test/runtests.jl`
rather than in the spec files, which say at the top that they are generated and
must not be edited. The obvious one is the sentence at the top of this file:
`md"call deliver_result and connect_to_peer here"` should be one string.

## Iterating without rebuilding

`Markdown` is in the sysimage, so editing it in a checkout normally means a
`make`. To go faster, copy the module's source somewhere writable and include
it — it loads standalone as `Main.Markdown` and can be edited and re-included
freely:

```julia
cp -r <checkout>/stdlib/Markdown /tmp/MD
julia -e 'include("/tmp/MD/src/Markdown.jl"); println(Markdown.parse("a_b_c").content[1].content)'
```

The spec comparison above was run that way, against `/tmp/MD/test/spec.json`:

```julia
using JSON3
include(ARGS[1])
spec = JSON3.read(read("/tmp/MD/test/spec.json", String))
fails = Int[]
for ex in spec
    ok = try
        Markdown.html(Markdown.parse(String(ex.markdown); flavor = :common)) == String(ex.html)
    catch
        false
    end
    ok || push!(fails, ex.example)
end
println(length(fails), " failing: ", join(fails, ","))
```

Run it once with the stock copy and once with the patched one and diff the two
lists; that is where the 294 → 277 comes from. Do a real `make` before opening
the PR, since the sysimage is what the test suite actually runs against.

## Prior art

None found. Searched JuliaLang/julia issues for markdown + emphasis, underscore,
intraword and italic, and for `commonmark` in titles: nothing about this. The
nearest thing in the TODO that produced this file was **#57265**, which is
`@md_str` interpolation and closed as a duplicate of something else.
