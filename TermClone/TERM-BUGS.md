# Bugs in Term.jl 2.2.0

Found while building an API-compatible clone of Term and matching its output
snapshot by snapshot. Every one below is reproduced against Term 2.2.0
(`b16ec5a5`) on Julia 1.14.0-DEV, with the output shown as observed; the source
references are to that commit. They are independent of each other, so they
can be filed together or one by one.

## Rendering

### 1. A style applied with `style=` is lost after the first tag inside it closes

```julia
julia> string(RenderableText("aa {bright_blue}bb{/bright_blue} cc"; style = "red"))
"\e[31maa \e[38;5;12mbb\e[39m cc\e[39m"
```

`cc` is drawn in the default colour, not red. `apply_style` restores an
enclosing colour only when it was opened by markup; `style=` is added as raw
ANSI (`get_style_codes`) around the already-styled text, so the `\e[39m` that
closes `bright_blue` ends it. The same happens to an `Annotation`'s message,
whose style is given the same way (`25_annotations.jl`, `annotations_5`: the
words after `{/bright_blue}` lose the annotation's red).

### 2. Crossing tags restore the wrong colour

```julia
julia> apply_style("{red}a{green}b{blue}c{/green}d{/blue}e{/red}")
"\e[31ma\e[32mb\e[34mc\e[39m\e[31md\e[39me\e[39m"
```

`d` is red although `{blue}` is still open, and `e` is the default colour
although `{red}` is still open. `apply_style` decides what to reopen from the
last colour tag before the one being closed (`previous_color`), not from the
tags still open at that point.

### 3. `reshape_text` overflows the width with wide characters

```julia
julia> [textwidth(l) for l in split(reshape_text("朗"^40, 33), '\n')]
[34, 34, 12]
```

The line is cut when `line_length + 1 > width`, counting the character just
added, so a two-column character that ends exactly past the edge is kept.
Every line of CJK text comes out one column wider than asked for when the
width is odd.

### 4. `reshape_text` splits a combining mark from its base character

```julia
julia> th = "ยาวีแพลนหงวนสคริปต์ แจ็กพ็อตต่อรองโทรโข่งยากูซ่ารุมบ้า บอมบ์เบอร์รีวีเจดีพาร์ทเมนท์";
julia> [first(l, 2) for l in split(reshape_text(th, 33), '\n')]
["ยา", "่ง"]
```

The second line begins with U+0E48 (a tone mark), orphaned from the `ข` it
belongs to at the end of the first line. `reshape_text` iterates `Char`s and
breaks between any two; it should break between graphemes
(`Base.Unicode.graphemes`).

### 5. A tree key wider than the console puts its children in the wrong place

```julia
julia> Term.Consoles.enable(Term.Consoles.Console(80));
julia> print(Term.remove_ansi(string(Tree(Dict("k"^76 => Dict("n1" => 1, "n2" => 2))))))
  └─ kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk
kk ⇒ Dict("n2" => 2, "n1" => 1)

          ├─ n2 ⇒ 2

          └─ n1 ⇒ 1
```

The tree is printed whole and then reflowed by `reshape_text`, which treats the
children's indentation as prose: it breaks the 84 spaces of indent at a space
near the edge, which leaves a blank line above each child and the child at
column 10, under neither its key nor anything else. Lines that are already laid
out should be cut where they overflow (or the indent computed against the
wrapped key), not reflowed at their spaces.

### 6. A `PlaceHolder`'s label moves with its style

```julia
julia> import Term.Layout: PlaceHolder
julia> for st in ("dim", "red", "#ff8800 dim", "bold #ff8800 underline")
           l = split(Term.remove_ansi(string(PlaceHolder(9, 40; style = st))), "\n")[5]
           println(rpad(repr(st), 26), l)
       end
"dim"                     ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲   (9 × 40)  ╲ ╲ ╲ ╲
"red"                     ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲    (9 × 40)   ╲ ╲ ╲ ╲
"#ff8800 dim"             ╲ ╲ ╲ ╲ ╲   (9 × 40)  ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲
"bold #ff8800 underline"  ╲ ╲ ╲ ╲    (9 × 40)   ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲ ╲
```

The label is never centred, and where it goes depends on the style.
`PlaceHolder` (`src/layout.jl`) finds the middle of the line as
`ncodeunits(lines[1].text) / f`: the *bytes* of the line with its escape codes,
three for each `╲`, divided by 2.5 or 3, and then cuts the styled line at that
many *characters*, escapes counted. A longer style is more escape bytes, which
moves the cut. Centring by display width -
`(w - textwidth(label)) ÷ 2` characters of the plain line on the left - puts
it in the same place whatever the style.

## Widgets

### 7. `Pager(...; line_numbers = true)` shows no line numbers

`reshape_pager_content` (`src/Live/pager.jl:72`) builds the numbered text in
`reshaped_content` and then overwrites it with
`reshape_code_string(content, width - 6)` - `content`, not
`reshaped_content` - so the numbers are thrown away.

### 8. A pressed button prints its background colour's name inside it

`make_button_panel` (`src/Live/buttons.jl:41`) passes `background` as a
positional argument after the keywords:

```julia
    return Panel(
        "{$text_color on_$(background)}$message{/$text_color on_$(background)}",
        style = style, width = w, height = h,
        justify = get(kwargs, :justify, :center),
        background,
        kwargs...,
    )
```

So `Panel` receives two contents, `vstack`s them, and an active button shows
its colour's name (e.g. `red`) on a line under its label. It should be
`background = background`.

## Logging and progress

### 9. Every log message is printed twice

```julia
julia> using Term; install_term_logger(); @info "hello once"
```

prints the message twice: `handle_message` (`src/logs.jl:328`) writes it to
`logger.io` (`stderr` by default) and then `print`s it again to `stdout`.

### 10. `with(f, pbar)` stops the bar twice, and its error path is dead code

`with` (`src/progress.jl:575`) calls `stop!(pbar)` after the loop and again
after the `try`, and on an error calls `stop!` before `rethrow()`, after which
`quit()` is unreachable. The second `stop!` redraws the final state again.

## Repr

### 11. `termshow(f)` lists blank methods, and never says how many it omitted

`style_function_methods` (`src/_repr.jl:178`) counts the lines of
`string(methods(f))` as methods, but since Julia 1.10 each method takes two
lines (`[1] cbrt(x::BigFloat)` and `@ mpfr.jl:819`). The location lines have
no `]`, so they become empty entries numbered `(2)`, `(4)`, …, and `N` is
twice the number of methods.

The "`m` methods omitted..." line is pushed onto `_methods` after `counts`
has been computed from it, and the `vstack` is over `1:length(counts)`, so the
omitted line is never drawn.

## The test suite

### 12. `10_test_introspection.jl` overwrites its own snapshots before comparing

Unless one of `CI`, `PKGEVAL` or `JULIA_PKGEVAL` is set, the test writes
`dendo_expr_*`, `tree_expr_*` and `exptree_expr_*` from the code under test and
then compares the same code's output with them, so those comparisons cannot
fail locally - and a local run leaves the repository's snapshots modified.

### 13. On Julia 1.14 the suite fails at file 10 and runs nothing after it

47 snapshots depend on orderings that differ on Julia 1.14: the order a
`Dict{String}` iterates (`tree_*_*_{1,2,3,4,5,10,11}`, `table_6`,
`markdown_3`) and the order of `subtypes` (`typestree_*`). On 1.14 the type
trees fail in `10_test_introspection.jl`, and because `runtests.jl` includes
each file at top level, the first failing file throws and files 11-99 never
run. Wrapping each `@runner` in a `@testset` lets every file report; building
the snapshots' inputs from `OrderedDict`s (and sorting `subtypes`) would make
them independent of the Julia version.
