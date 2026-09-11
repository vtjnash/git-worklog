# Every colour the program prints, and the one file it reads them from.
#
# Before this the escapes were written into the middle of the code that drew the
# row - a few through one-letter constants at the top of two files, most of them
# spelled out where they were used - so "what colour is a failing check" was a
# question answered by grep, and changing it was an edit in eight files.
#
# **Roles, not colours.** A field here is what a colour *means* to this
# program - `waiting`, `blocked`, `diff_add` - and the theme file says which
# colour that is. The code never names a colour, which is what makes a theme
# possible at all: a call site that said "green" could not be re-themed without
# being re-read, and a light-terminal theme wants a different green rather than
# a different meaning.
#
# **No theme named is no colour at all.** `config.toml`'s `theme` is the only
# thing that turns colour on. An empty value, a missing key or a file that is
# not there leaves every field `""` - including the resets, so that what is
# printed carries no escapes whatsoever rather than escapes that cancel colours
# nobody emitted. That is the plain-text mode, and it is reachable on purpose:
# `theme = ""` is how you ask for one.
#
# **ANSI and 256.** The eight named colours, their eight bright forms, and the
# 256-colour cube by index - which is what a terminal can be relied on to have.
# The spec language is in `parse_style`.

"""
    Theme

The escape that begins each role, filled from the theme file by `load_theme!`.

Three kinds of field, and the difference matters to whoever adds one:

  * **A role.** Named in the theme file, one word per field. `ROLES` is this
    list, derived from the struct rather than written twice.
  * **A closer, `<role>_off`.** Filled with the escape that ends *exactly* what
    its role began - `22` for a weight, `39` for a foreground, `49` for a
    background - derived from the role's own spec rather than assumed, so a
    theme that draws `dim` as a grey foreground closes it with `39` and not
    with `22`. Only the roles that are drawn *inside* other colour need one: a
    span that ends the row ends it with `reset`.
  * **The structural two**, `reset` and `no_bg`, which end colour rather than
    beginning it and so have nothing to choose. They are not the theme file's
    business; they are empty when no theme is loaded and standard when one is.
"""
Base.@kwdef mutable struct Theme
    reset::String = ""
    no_bg::String = ""
    # Weight and quiet, which most of the screen is.
    bold::String = ""
    dim::String = ""
    dim_off::String = ""
    focus::String = ""
    # The three verdicts, and a name or a place.
    settled::String = ""
    blocked::String = ""
    waiting::String = ""
    accent::String = ""
    # The diff, the one surface where the colour is the content.
    diff_add::String = ""
    diff_del::String = ""
    diff_hunk::String = ""
    diff_meta::String = ""
    code_bg::String = ""
    code_bg_off::String = ""
    # Where the cursor, the selection, a search hit and the insertion point are.
    cursor_bg::String = ""
    select_bg::String = ""
    match_bg::String = ""
    caret::String = ""
    caret_off::String = ""
    # Links.
    link::String = ""
    link_off::String = ""
    url::String = ""
end

"""The one theme the program draws in.

A `const` binding to a mutable struct, and not a `Ref` of an immutable one, for
the reason every call site is a bare field read: `THEME.dim` on a const global
of concrete type is as cheap as the constant it replaced, and it is reloadable,
which a `const` string was not - the theme is read at run time from the user's
file, and a constant would have baked in whatever was there when the package was
precompiled.
"""
const THEME = Theme()

"The roles a theme file may name. Derived, so the struct is the only list."
const ROLES = Tuple(f for f in fieldnames(Theme)
                    if !(f in (:reset, :no_bg)) && !endswith(String(f), "_off"))

"""The attributes, each with the code that ends it.

`bold` and `dim` share `22`, which is why a closer is a set and not a list:
`"bold dim"` must not print `22;22`.
"""
const ATTRS = ("bold" => (1, 22), "dim" => (2, 22), "italic" => (3, 23),
               "underline" => (4, 24), "reverse" => (7, 27))

"The eight, in the order the ANSI codes put them."
const ANSI_COLORS = ("black", "red", "green", "yellow", "blue", "magenta",
                     "cyan", "white")

"One SGR escape from the codes that go in it."
sgr(codes) = string("\e[", join(codes, ';'), "m")

"""`#rgb` or `#rrggbb` as the three numbers it stands for.

Throws on anything else, including the three-digit form's odd lengths, so that
`#12345` is a misspelling that is reported rather than a colour that is quietly
something else.
"""
function hex2rgb(word::AbstractString)
    h = SubString(word, 2)
    length(h) == 3 && (h = join(c^2 for c in h))
    (length(h) == 6 && all(isxdigit, h)) ||
        throw(ArgumentError(string("`", word, "` is not #rgb or #rrggbb")))
    Tuple(parse(Int, h[i:(i + 1)]; base = 16) for i in (1, 3, 5))
end

"""
    parse_style(spec) -> (on, off)

One theme value becomes the escape that begins it and the escape that ends it.

The spec is words, in any order:

  * an attribute - `bold`, `dim`, `italic`, `underline`, `reverse`
  * a colour - one of the eight ANSI names, `bright <name>` for the high eight,
    `0`-`255` for a 256-colour index, or `#rrggbb` / `#rgb` for a direct one
  * `on` in front of a colour, making it the background

So `"bold white"`, `"black on yellow"`, `"on 236"`, `"bright red"`, `"244"`,
`"#9FA8DA"`. The first three kinds are what a terminal can be relied on to
have, and what the shipped theme is written in; hex is here because Term's own
palette is written in it, and a theme that wants to keep Term's colours has to
be able to say them.
An empty spec is no colour, which is a theme's way of saying a role should not
be drawn at all.

Throws `ArgumentError` on anything it cannot read, naming the word: a theme file
is hand-written, and a misspelt colour that quietly rendered as nothing would be
a role that had silently stopped working.
"""
function parse_style(spec::AbstractString)
    on, off = Int[], Int[]
    bg = bright = false
    for word in split(lowercase(spec))
        if word == "on"
            bg && throw(ArgumentError("`on` twice"))
            bg = true
            continue
        elseif word == "bright"
            bright && throw(ArgumentError("`bright` twice"))
            bright = true
            continue
        end
        i = findfirst(a -> first(a) == word, ATTRS)
        if i !== nothing
            (bg || bright) &&
                throw(ArgumentError(string("`", word, "` is an attribute, not a colour")))
            code, done = last(ATTRS[i])
            push!(on, code)
            push!(off, done)
            continue
        end
        j = findfirst(==(word), ANSI_COLORS)
        if startswith(word, "#")
            bright && throw(ArgumentError("`bright` takes a colour name, not a hex"))
            append!(on, (bg ? 48 : 38, 2, hex2rgb(word)...))
        elseif j !== nothing
            push!(on, (bg ? 40 : 30) + (j - 1) + (bright ? 60 : 0))
        elseif all(isdigit, word) && 0 <= parse(Int, word) <= 255
            # 256 colour by index. `bright 3` would be two ways of saying the
            # same thing - 8-15 of the cube *are* the bright eight - so it is
            # refused rather than silently ignored.
            bright && throw(ArgumentError("`bright` takes a colour name, not an index"))
            append!(on, (bg ? 48 : 38, 5, parse(Int, word)))
        else
            throw(ArgumentError(string("no colour named `", word, "`")))
        end
        push!(off, bg ? 49 : 39)
        bg = bright = false
    end
    (bg || bright) && throw(ArgumentError("ends with no colour after it"))
    isempty(on) ? ("", "") : (sgr(on), sgr(unique(off)))
end

"""Re-arm `on` after everything in `after` that would have ended it.

A row carries colours of its own, and the escape that ends one of them - a
reset, or a background going back to the default - ends the background laid over
the top of it as well. So a highlight applied naively stops at the first styled
word on the line, and the cure is to put it back after each of them. `hlrow`
does this to a whole row and `style_code_spans` to the inside of one code span,
which is why it lives here with the escapes rather than in either of them.

Answers with `s` untouched when there is nothing to re-arm, which is also what
keeps it safe with no theme loaded: `replace(s, "" => "")` inserts at every
position rather than doing nothing.
"""
function rearm(s::AbstractString, on::AbstractString,
               after = (THEME.reset,))
    (isempty(on) || all(isempty, after)) && return String(s)
    replace(s, (x => x * on for x in after if !isempty(x))...)
end

# --- the other palette ------------------------------------------------------
#
# Term draws the markdown in every comment body, and it has a palette of its
# own: `Term.TERM_THEME[]` is a mutable global of seventy fields - the six
# heading levels, the block quote, the footnote, the table, the admonitions, and
# the ten token colours its tree-sitter highlighter paints a code span with.
# None of that was ever this program's to choose, so a dashboard themed down to
# the last dim timestamp went on drawing headings in Term's indigo.
#
# The `[term]` table in the theme file is that palette, written in the same
# spec language as everything else and translated on the way in - Term's
# language is the same vocabulary under different spelling, `on_red` for a
# background and `bright_red` for the high eight, so the translation is a word
# map rather than a conversion.
#
# Two fields are not colours and are taken as names: `box` and `tb_box` choose
# the box *characters*, which is also where the dialog and the pane borders get
# theirs - `TermInput.boxstyle()` follows `TERM_THEME[].box`.
#
# And one field is refused: `md_code` is the sentinel `style_code_spans` finds
# the code-span delimiters by. It is never on screen, and a theme that set it
# would not recolour a code span, it would stop one being drawn.

"The one field of Term's theme this program owns. See `MD_CODE_SENTINEL`."
const TERM_SENTINEL_FIELD = :md_code

"""The colour nothing else emits, which is how a code span is found again.

Term styles a code span's *delimiters* with `md_code`, and `style_code_spans`
turns them into a background - so it has to know what they were painted with.
Written once, here: it is set into Term's theme as this hex and matched in
Term's output as the escape Term makes of it, and the two being the same
literal in two files is how they would come apart.
"""
const MD_CODE_SENTINEL_HEX = "#ff00ff"

"""What Term's palette is set to when no theme is loaded.

`"default"` and not `""`: an empty style would be interpolated into Term's
markup as `{}`, which is not a tag. This is the other half of drawing plain -
without it a program with no theme would still print Term's colours through
every comment body it rendered.
"""
const TERM_PLAIN = "default"

"""One of our specs in Term's own style language.

The vocabulary is the same and the spelling is not: a background is `on_red`
rather than `on red`, and the high eight are `bright_red` rather than
`bright red`. A 256-colour index above 15 has no spelling at all in Term, so it
goes as the hex the xterm palette defines it as - exact for the colour cube and
the greys, which is where those indices are worth using.
"""
function term_style(spec::AbstractString)
    out = String[]
    bg = bright = false
    for word in split(lowercase(spec))
        if word == "on"
            bg = true
            continue
        elseif word == "bright"
            bright = true
            continue
        end
        if any(a -> first(a) == word, ATTRS)
            (bg || bright) &&
                throw(ArgumentError(string("`", word, "` is an attribute, not a colour")))
            push!(out, word)
            continue
        end
        colour = if word in ANSI_COLORS
            bright ? string("bright_", word) : word
        elseif startswith(word, "#")
            hex2rgb(word)   # thrown away, but it validates the spelling here too
            word
        elseif all(isdigit, word) && 0 <= parse(Int, word) <= 255
            bright && throw(ArgumentError("`bright` takes a colour name, not an index"))
            xterm_hex(parse(Int, word))
        else
            throw(ArgumentError(string("no colour named `", word, "`")))
        end
        push!(out, bg ? string("on_", colour) : colour)
        bg = bright = false
    end
    (bg || bright) && throw(ArgumentError("ends with no colour after it"))
    isempty(out) ? TERM_PLAIN : join(out, " ")
end

"""A 256-colour index as the hex the xterm palette defines it as.

The low sixteen are the terminal's own and are named rather than converted -
turning `red` into `#800000` is exactly the fighting-your-terminal this theme
exists not to do. Above them the palette is arithmetic: a 6×6×6 cube on the
levels 0, 95, 135, 175, 215, 255, and then 24 greys from 8 in steps of 10.
"""
function xterm_hex(i::Int)
    i < 8 && return ANSI_COLORS[i + 1]
    i < 16 && return string("bright_", ANSI_COLORS[i - 7])
    hex(r, g, b) = string("#", string(r; base = 16, pad = 2),
                          string(g; base = 16, pad = 2), string(b; base = 16, pad = 2))
    if i < 232
        n = i - 16
        level = (0, 95, 135, 175, 215, 255)
        return hex(level[n ÷ 36 + 1], level[(n ÷ 6) % 6 + 1], level[n % 6 + 1])
    end
    v = 8 + 10 * (i - 232)
    hex(v, v, v)
end

"""Set every colour in Term's palette to `TERM_PLAIN`, and the sentinel back.

Every field that holds a style string, which is all of them but the theme's own
name, the two box names and one width. Done before the `[term]` table is read
so that a table naming half the fields leaves the other half plain rather than
leaving Term's defaults showing through.
"""
function term_plain!()
    t = Term.TERM_THEME[]
    for f in fieldnames(typeof(t))
        f in (:name, TERM_SENTINEL_FIELD) && continue
        getfield(t, f) isa String && setfield!(t, f, TERM_PLAIN)
    end
    setfield!(t, TERM_SENTINEL_FIELD, MD_CODE_SENTINEL_HEX)
    nothing
end

"""Apply the `[term]` table, and answer with what was wrong with it.

A field that holds a `Symbol` - `box`, `tb_box` - takes the *name* of one of
Term's boxes rather than a colour, and an unknown one is reported rather than
left to throw the first time something is drawn in it.

A field whose name ends in `_bg` is interpolated by Term as `on_<value>`, so it
takes a bare colour and nothing else: `"236"`, not `"on 236"` and not
`"bold 236"`.
"""
function apply_term!(tbl, probs::Vector{String}, where_::AbstractString)
    t = Term.TERM_THEME[]
    for (key, value) in tbl
        field = Symbol(key)
        if field === TERM_SENTINEL_FIELD
            push!(probs, string(where_, ": `", key, "` is the code-span sentinel, ",
                                "not a colour - see MD_CODE_SENTINEL"))
        elseif !hasfield(typeof(t), field)
            push!(probs, string(where_, ": Term has no `", key, "`"))
        elseif !(value isa AbstractString)
            push!(probs, string(where_, ": `", key, "` wants a string"))
        elseif getfield(t, field) isa Symbol
            box = Symbol(uppercase(String(value)))
            haskey(Term.Boxes.BOXES, box) ?
                setfield!(t, field, box) :
                push!(probs, string(where_, ": Term has no box `", value, "` - ",
                                    "they are the names in `Term.Boxes.BOXES`"))
        elseif !(getfield(t, field) isa String)
            push!(probs, string(where_, ": `", key, "` is not a colour"))
        else
            try
                st = term_style(value)
                endswith(key, "_bg") && occursin(" ", st) &&
                    throw(ArgumentError("takes one colour and no attributes"))
                setfield!(t, field, st)
            catch e
                push!(probs, string(where_, ": `", key, " = \"", value, "\"` ",
                                    e isa ArgumentError ? e.msg :
                                    first(sprint(showerror, e), 120)))
            end
        end
    end
    probs
end

"""Set every colour in Term's code palette to `TERM_PLAIN`.

In place, because `Term.CodeTheme` is a `const` binding to a `Dict` - the
binding is Term's and the contents are anybody's, which is the only reason this
palette can be themed at all.
"""
term_code_plain!() =
    (for k in keys(Term.CodeTheme)
         Term.CodeTheme[k] = TERM_PLAIN
     end; nothing)

"""Apply the `[code]` table: tree-sitter capture names to colours.

The names are **not** validated, and cannot be: they are the grammar's captures
rather than a list Term owns, `code_style` walks them up the dotted hierarchy
(`keyword.return` falls back to `keyword`, and anything unmatched to `text`),
and a theme naming one Term does not ship is how a capture that currently falls
back gets a colour of its own. So a misspelling here is silent - the one place
in this file where that is true, and the theme file says so.
"""
function apply_code!(tbl, probs::Vector{String}, where_::AbstractString)
    for (key, value) in tbl
        if !(value isa AbstractString)
            push!(probs, string(where_, ": `code.", key, "` wants a string"))
            continue
        end
        try
            Term.CodeTheme[String(key)] = term_style(value)
        catch e
            push!(probs, string(where_, ": `code.", key, " = \"", value, "\"` ",
                                e isa ArgumentError ? e.msg :
                                first(sprint(showerror, e), 120)))
        end
    end
    probs
end

"""Hand the widget packages the weights they draw their boxes in.

`TermInput.CHROME` is their one hook for it, and `TermIFrame` reads the same
one - the box a hosted program is drawn in and the box a composer is drawn in
are the same box as far as a theme is concerned. Three roles cover it: a title
and a focused border are `bold`, everything else about a border is `dim`, and
the reset is the reset. With no theme all three are empty, and the boxes come
out as bare characters, which is the whole of what "drawing plain" means for
something that is drawn in line-art.

Not their business and not set from here: the block that marks the cursor in a
composer. `TermInput` keeps that as reverse video whatever a theme says,
because it is the only thing on screen saying where typing will go.
"""
chrome!() = (TermInput.CHROME[] = (strong = THEME.bold, quiet = THEME.dim,
                                   reset = THEME.reset); nothing)

"""Term's output, with its escapes taken back off when there is no theme.

The last half-inch of drawing plain. Term always wraps what it renders in a
tag, and its plainest style - `TERM_PLAIN` - is a real style that prints
`\\e[22m`, so a palette set to nothing still leaves a body speckled with
attribute resets. With no theme that is noise in a pipe rather than restraint,
so it comes off.

Only in that case: with a theme loaded this is the identity, and the escapes it
would otherwise be stripping are the colours somebody asked for.
"""
plain_term(s::AbstractString) = isempty(THEME.reset) ? astrip(s) : String(s)

"""Which file the colours come from, or `""` for none.

Relative to `themes/` beside the code, because that is where the themes this
program ships live and a bare name is what `config.toml` should hold; an
absolute path is taken as it is, for a theme of your own kept elsewhere.
"""
function themefile()
    # Caught, because a `config.toml` that cannot be read is not a colour
    # problem and this is not where it should be reported. `login()` does the
    # same with the same file for the same reason.
    name = try
        String(get(config(), "theme", ""))
    catch
        ""
    end
    isempty(name) ? "" :
        isabspath(name) ? name : joinpath(ROOT, "themes", name)
end

"""
    load_theme!([path]) -> Vector{String}

Fill `THEME` from `path`, and answer with what was wrong with it.

Said rather than thrown, and rather than ignored. A bad line in a theme must not
stop the program - it is decoration, and a dashboard that will not start because
of a misspelt colour is worse than a dull one - but a role that has quietly
stopped being drawn is exactly the kind of failure nobody reports, so the
problems come back as sentences and `__init__` prints them.

Every field is cleared first: loading a second theme must not leave the first
one's colours behind in the roles the second does not name. The same goes for
the three palettes that are not ours - Term's, the highlighter's, and the
weights the widget packages draw their boxes in - each of which is set from
here on every load, so that "the theme" means one file and not four globals
that drifted apart.
"""
function load_theme!(path::AbstractString = themefile())
    probs = String[]
    for f in fieldnames(Theme)
        setfield!(THEME, f, "")
    end
    term_plain!()
    term_code_plain!()
    chrome!()
    isempty(path) && return probs
    if !isfile(path)
        push!(probs, string("no theme file at ", path, " - drawing without colour"))
        return probs
    end
    tbl = try
        TOML.parsefile(path)
    catch e
        push!(probs, string(basename(path), ": ", first(sprint(showerror, e), 200)))
        return probs
    end
    # Only now, with a file that parsed: these are what make the colours above
    # end, and they belong to a theme being loaded at all rather than to any
    # role in it.
    THEME.reset = "\e[0m"
    THEME.no_bg = "\e[49m"
    for (key, value) in tbl
        role = Symbol(key)
        if role === :term || role === :code
            # Term's two palettes, which are tables rather than roles.
            apply = role === :term ? apply_term! : apply_code!
            value isa AbstractDict ? apply(value, probs, basename(path)) :
                push!(probs, string(basename(path), ": `", key, "` wants a table"))
        elseif !(role in ROLES)
            push!(probs, string(basename(path), ": no colour role `", key, "`"))
        elseif !(value isa AbstractString)
            push!(probs, string(basename(path), ": `", key, "` wants a string"))
        else
            try
                on, off = parse_style(value)
                setfield!(THEME, role, on)
                # The closer, for the roles that have somewhere to put one.
                closer = Symbol(role, "_off")
                hasfield(Theme, closer) && setfield!(THEME, closer, off)
            catch e
                push!(probs, string(basename(path), ": `", key, " = \"", value, "\"` ",
                                    e isa ArgumentError ? e.msg :
                                    first(sprint(showerror, e), 120)))
            end
        end
    end
    chrome!()
    probs
end
