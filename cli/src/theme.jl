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
    # The list while the keys are on the reading side, and an unread row in it.
    quiet::String = ""
    quiet_off::String = ""
    quiet_bold::String = ""
    # The three verdicts, and a name or a place.
    settled::String = ""
    blocked::String = ""
    waiting::String = ""
    accent::String = ""
    # An agent that rang with nobody looking: a row of the list, and the `T`
    # of its session, drawn as a badge. Louder than `waiting`, which is a
    # state; this is somebody waiting on you now.
    rang::String = ""
    rang_mark::String = ""
    # The diff, the one surface where the colour is the content.
    diff_add::String = ""
    diff_del::String = ""
    # What changed inside a changed line, drawn over the line's own colour.
    diff_add_word::String = ""
    diff_add_word_off::String = ""
    diff_del_word::String = ""
    diff_del_word_off::String = ""
    diff_hunk::String = ""
    diff_meta::String = ""
    # Behind a header row in the diff, which is drawn to the edge of the pane
    # and so can carry one: a hunk, a hunk of a file that is new, and a review
    # comment hanging off a line.
    diff_hunk_bg::String = ""
    diff_file_bg::String = ""
    diff_comment_bg::String = ""
    # Behind the header of each comment and review in the thread, as GitHub
    # boxes them: somebody's, and your own, which GitHub draws in blue.
    thread_bg::String = ""
    thread_mine_bg::String = ""
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
               "underline" => (4, 24), "reverse" => (7, 27), "strike" => (9, 29))

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
    # Bound once: the generator below captures `h`, and would box it if it
    # were assigned twice.
    d = SubString(word, 2)
    h = length(d) == 3 ? join(c^2 for c in d) : String(d)
    (length(h) == 6 && all(isxdigit, h)) ||
        throw(ArgumentError(string("`", word, "` is not #rgb or #rrggbb")))
    Tuple(parse(Int, h[i:(i + 1)]; base = 16) for i in (1, 3, 5))
end

"""
    parse_style(spec) -> (on, off)

One theme value becomes the escape that begins it and the escape that ends it.

The spec is words, in any order:

  * an attribute - `bold`, `dim`, `italic`, `underline`, `reverse`, `strike`
  * a colour - one of the eight ANSI names, `bright <name>` for the high eight,
    `0`-`255` for a 256-colour index, or `#rrggbb` / `#rgb` for a direct one
  * `on` in front of a colour, making it the background

So `"bold white"`, `"black on yellow"`, `"on 236"`, `"bright red"`, `"244"`,
`"#9FA8DA"`. The first three kinds are what a terminal can be relied on to
have, and what the shipped theme is written in; hex is here for a colour a
theme wants exactly, whatever the terminal's palette says - GitHub's own, or
the ones Term used to draw markdown in.
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
does this to a whole row, which is why it lives here with the escapes.

Answers with `s` untouched when there is nothing to re-arm, which is also what
keeps it safe with no theme loaded: `replace(s, "" => "")` inserts at every
position rather than doing nothing.
"""
function rearm(s::AbstractString, on::AbstractString,
               after = (THEME.reset,))
    (isempty(on) || all(isempty, after)) && return String(s)
    replace(s, (x => x * on for x in after if !isempty(x))...)
end

# --- markdown and code ------------------------------------------------------
#
# Every comment body is markdown, drawn by `TermInput.markdown_rows` in a
# `MarkdownStyle`: one `(on, off)` pair per thing it styles, and a highlighter's
# faces by name. The `[markdown]` table of a theme file is that style and the
# `[code]` table those faces, written in the same spec language as everything
# else, so a theme is one file. `MD_STYLE` is built from them on every load.
#
# A code *span* is the two roles `code_bg` and `dim` - its background, and its
# backticks - since those were roles before the tables were ours.
#
# Two keys are not colours and are taken as names from `TermInput.BOXES`: `box`
# is what every box is drawn with - the dialogs, the panes, `CHROME[].box` -
# and `md_table_box` is a table's.

"""The `[markdown]` table's keys, and the `MarkdownStyle` field each sets.

The names are Term's where Term had one that said what it was - `md_h1`,
`md_quote`, the admonitions - and say the element where it had none."""
const MD_KEYS = Dict{String,Symbol}(
    "md_h1" => :h1, "md_h2" => :h2, "md_h3" => :h3,
    "md_h4" => :h4, "md_h5" => :h5, "md_h6" => :h6,
    "md_bold" => :bold, "md_italic" => :italic, "md_strike" => :strike,
    "md_codeblock" => :codeblock, "md_link" => :link, "md_quote" => :blockquote,
    "md_admonition_note" => :note, "md_admonition_tip" => :tip,
    "md_admonition_warning" => :warning, "md_admonition_danger" => :danger,
    "md_admonition_info" => :info,
    "md_table_header" => :table_head, "md_table_rule" => :table_rule,
    "md_rule" => :rule, "md_latex" => :latex, "md_footnote" => :footnote,
    "md_html" => :html)

"""The faces the `[code]` table may name: what Julia's highlighter paints with,
by name without its `julia_`. A face with no colour falls back as
`TermInput`'s `FACE_FALLBACK` says - `string_delim` to `string`, a bracket to
`parentheses` - so a theme names the few it cares about."""
const CODE_FACES = Set{String}(vcat(
    ["keyword", "funcdef", "funcall", "macro", "string", "string_delim", "char",
     "char_delim", "cmd", "cmd_delim", "regex", "backslash_literal", "symbol",
     "singleton_identifier", "number", "bool", "comment", "operator",
     "comparator", "assignment", "opassignment", "broadcast", "type", "typedec",
     "builtin", "label", "error", "parentheses", "unpaired_parentheses"],
    [string("rainbow_", k, "_", n) for k in ("paren", "bracket", "curly") for n in 1:6]))

"""What comment bodies are drawn in, built by `load_theme!` from the
`[markdown]` and `[code]` tables and the code-span roles. Empty with no theme,
which draws with no escapes at all."""
const MD_STYLE = Ref(TermInput.MarkdownStyle())

"The box the dialogs and panes are drawn with: the theme's `box`."
const BOX = Ref(TermInput.BOXES.ROUNDED)

"""A box by name, into `set`, or a sentence about why not: the names are
`TermInput.BOXES`', and an unknown one is reported rather than drawn as some
other box without a word."""
function theme_box!(set, value, key::AbstractString, probs::Vector{String},
                    where_::AbstractString)
    name = value isa AbstractString ? Symbol(uppercase(String(value))) : :_
    if haskey(TermInput.BOXES, name)
        set(TermInput.BOXES[name])
    else
        push!(probs, string(where_, ": no box `", value, "` for `", key, "` - they are ",
                            join(keys(TermInput.BOXES), ", ")))
    end
    nothing
end

"""Apply the `[markdown]` table into `fields`, and answer with what was wrong.

A key not in `MD_KEYS` is reported, which is also what a theme written for
Term hears about the names that went with it - `tb_style`, `emphasis`,
`text_accent`."""
function apply_markdown!(fields::Dict{Symbol,Any}, tbl::AbstractDict{String},
                         probs::Vector{String}, where_::AbstractString)
    for (key, value) in tbl
        if key == "box"
            theme_box!(b -> (BOX[] = b), value, key, probs, where_)
        elseif key == "md_table_box"
            theme_box!(b -> (fields[:box] = b), value, key, probs, where_)
        elseif !haskey(MD_KEYS, key)
            push!(probs, string(where_, ": no markdown style `", key, "`"))
        elseif !(value isa AbstractString)
            push!(probs, string(where_, ": `", key, "` wants a string"))
        else
            try
                fields[MD_KEYS[key]] = parse_style(value)
            catch e
                push!(probs, string(where_, ": `", key, " = \"", value, "\"` ",
                                    e isa ArgumentError ? e.msg :
                                    first(sprint(showerror, e), 120)))
            end
        end
    end
    probs
end

"""Apply the `[code]` table into `faces`: a face's name to its colour. A name
Julia's highlighter does not paint with is reported, as the tree-sitter
captures Term's highlighter took are."""
function apply_code!(faces::Dict{Symbol,Tuple{String,String}}, tbl::AbstractDict{String},
                     probs::Vector{String}, where_::AbstractString)
    for (key, value) in tbl
        if !(key in CODE_FACES)
            push!(probs, string(where_, ": no code face `", key, "`"))
        elseif !(value isa AbstractString)
            push!(probs, string(where_, ": `code.", key, "` wants a string"))
        else
            try
                faces[Symbol(key)] = parse_style(value)
            catch e
                push!(probs, string(where_, ": `code.", key, " = \"", value, "\"` ",
                                    e isa ArgumentError ? e.msg :
                                    first(sprint(showerror, e), 120)))
            end
        end
    end
    probs
end

"""Hand the widget packages the weights they draw their boxes in.

`TermInput.CHROME` is their one hook for it, and `TermIFrame` reads the same
one - the box a hosted program is drawn in and the box a composer is drawn in
are the same box as far as a theme is concerned. Four roles cover it: a title
and a focused border are `bold`, everything else about a border is `dim`, the
option under a picker's cursor is `focus`, and the reset is the reset - and
the box is `[markdown]`'s `box`. With no theme all four are empty, and the boxes come
out as bare characters, which is the whole of what "drawing plain" means for
something that is drawn in line-art.

Not their business and not set from here: the block that marks the cursor in a
composer. `TermInput` keeps that as reverse video whatever a theme says,
because it is the only thing on screen saying where typing will go.
"""
chrome!() = (TermInput.CHROME[] = (strong = THEME.bold, quiet = THEME.dim,
                                   focus = THEME.focus, reset = THEME.reset,
                                   box = BOX[]); nothing)

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
        jstr(config(), :theme, "")
    catch
        ""
    end
    isempty(name) ? "" :
        isabspath(name) ? name : joinpath(ROOT, "themes", name)
end

"""The file the colours were last loaded from, which is `themefile()` until the
terminal says its scheme is the other one - see `scheme_theme`."""
const LOADED_THEME = Ref("")

"""The theme to draw with on a terminal whose colours are `dark` (or light),
given the one `config.toml` names: that one where its name says it is for this
scheme or says neither - `default-ansi.toml` uses the terminal's own colours -
and otherwise its pair, the same name with `light` and `dark` swapped, when
there is a file of that name. Named rather than configured, so a pair is two
files and not a key that has to be kept in step with them."""
function scheme_theme(path::AbstractString, dark::Bool)
    want, other = dark ? ("dark", "light") : ("light", "dark")
    b = basename(path)
    (isempty(path) || occursin(want, b) || !occursin(other, b)) && return String(path)
    q = joinpath(dirname(path), replace(b, other => want))
    isfile(q) ? q : String(path)
end

"""What loading the theme had to say - a file that is not there, a colour that
is not one - kept for whichever channel the process has: stderr for a command,
the footer for the browser. Filled once, in `__init__`."""
const THEME_NOTES = String[]

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
what is built from it for the packages - the markdown style, and the weights
and the box the widget packages draw in - each of which is set from here on
every load, so that "the theme" means one file and not three globals that
drifted apart.
"""
function load_theme!(path::AbstractString = themefile())
    LOADED_THEME[] = String(path)
    probs = String[]
    for f in fieldnames(Theme)
        setfield!(THEME, f, "")
    end
    BOX[] = TermInput.BOXES.ROUNDED
    fields = Dict{Symbol,Any}()
    faces = Dict{Symbol,Tuple{String,String}}()
    read_theme!(probs, fields, faces, path)
    # A code span is two of the roles; everything else in markdown is the
    # `[markdown]` table's.
    MD_STYLE[] = TermInput.MarkdownStyle(; code = (THEME.code_bg, THEME.code_bg_off),
                                         code_tick = (THEME.dim, THEME.dim_off),
                                         fields..., faces)
    chrome!()
    probs
end

"The file itself, into `THEME` and the two tables; see `load_theme!`."
function read_theme!(probs::Vector{String}, fields::Dict{Symbol,Any},
                     faces::Dict{Symbol,Tuple{String,String}}, path::AbstractString)
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
        if role === :markdown || role === :code
            # Tables rather than roles: what markdown is drawn in.
            if !(value isa AbstractDict)
                push!(probs, string(basename(path), ": `", key, "` wants a table"))
            elseif role === :markdown
                apply_markdown!(fields, value, probs, basename(path))
            else
                apply_code!(faces, value, probs, basename(path))
            end
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
    probs
end
