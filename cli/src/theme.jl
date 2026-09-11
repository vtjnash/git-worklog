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

"""
    parse_style(spec) -> (on, off)

One theme value becomes the escape that begins it and the escape that ends it.

The spec is words, in any order:

  * an attribute - `bold`, `dim`, `italic`, `underline`, `reverse`
  * a colour - one of the eight ANSI names, `bright <name>` for the high eight,
    or `0`-`255` for a 256-colour index
  * `on` in front of a colour, making it the background

So `"bold white"`, `"black on yellow"`, `"on 236"`, `"bright red"`, `"244"`.
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
        if j !== nothing
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
one's colours behind in the roles the second does not name.
"""
function load_theme!(path::AbstractString = themefile())
    probs = String[]
    for f in fieldnames(Theme)
        setfield!(THEME, f, "")
    end
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
        if !(role in ROLES)
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
    probs
end
