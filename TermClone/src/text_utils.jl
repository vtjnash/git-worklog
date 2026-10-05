# Plain-string helpers for Term's markup language, from Term.jl (MIT, see LICENSE.Term):
# they read and write strings, not rows, and are API in their own right.

"""
multiple strings replacement.
"""
replace_multi(text::AbstractString, pairs::Pair...)::String = replace(text, pairs...)

plural(word::AbstractString, n) = n <= 1 ? word : word * 's'

# ---------------------------------------------------------------------------- #
#                                     REGEX                                    #
# ---------------------------------------------------------------------------- #
# ---------------------------------- markup ---------------------------------- #

OPEN_TAG_REGEX = r"(?<!\{)\{(?!\{)[a-zA-Z _0-9. ,()#]*\}"
CLOSE_TAG_REGEX = r"\{\/[a-zA-Z _0-9. ,()#]+[^/\{]\}"
GENERIC_CLOSER_REGEX = r"(?<!\{)\{(?!\{)\/\}"

"""
    remove_markup(input_text::AbstractString)::AbstractString

Remove all markup tags from a string of text.
"""
function remove_markup(input_text; remove_orphan_tags = true)::String
    if remove_orphan_tags
        return replace_multi(
            input_text,
            OPEN_TAG_REGEX => "",
            GENERIC_CLOSER_REGEX => "",
            CLOSE_TAG_REGEX => "",
        )
    else
        # turn non-orphaned closing tags in opening tags before removing them
        for match in eachmatch(OPEN_TAG_REGEX, input_text)
            markup = match.match[2:(end - 1)]
            close = r"\{\/" * Regex(markup) * r"\}"
            input_text = replace(input_text, close => "{$markup}", count = 1)
        end
        return replace_multi(input_text, OPEN_TAG_REGEX => "", GENERIC_CLOSER_REGEX => "")
    end
end

"""
    has_markup(text::String)

Returns `true` if `text` includes a `MarkupTag`
"""
has_markup(text)::Bool = occursin(OPEN_TAG_REGEX, text)

# ----------------------------------- ansi ----------------------------------- #
const ANSI_REGEX = r"\e\[[0-9;]*m"

"""
    remove_ansi(input_text::AbstractString)::AbstractString

Remove all ANSI tags from a string of text
"""
remove_ansi(input_text)::String = replace(input_text, ANSI_REGEX => "")

"""
    has_ansi(text::String)

Returns `true` if `text` includes a `MarkupTag`
"""
has_ansi(text)::Bool = occursin(ANSI_REGEX, text)

"""
    lstrip_ansi(text)

Strip leading whitespace, preserving any ANSI codes interleaved in it.
"""
lstrip_ansi(text)::String =
    replace(text, r"^(?:\e\[[0-9;]*m|\s)*" => m -> replace(m, r"\s" => ""))

# --------------------------- clean text / text len -------------------------- #
"""
    cleantext(str::AbstractString)

Remove all style information from a string.
"""
cleantext(str)::String = (remove_ansi ∘ remove_markup)(str)

"""
    textlen(x::AbstractString)

Get length of text after all style information is removed.
"""
textlen(x; remove_orphan_tags = false)::Int =
    remove_markup(remove_ansi(x); remove_orphan_tags) |> textwidth

# --------------------------------- brackets --------------------------------- #
const brackets_regexes = [r"(?<!\{)\{(?!\{)", r"(?<!\})\}(?!\})"]

"""
    escape_brackets(text)::Stringremove_ansi(str)::String

Replace each curly bracket with a double copy of itself
"""
escape_brackets(text)::String =
    replace_multi(text, brackets_regexes[1] => "{{", brackets_regexes[2] => "}}")

"""
    unescape_brackets(text)::String

Replece every double squared parenthesis with a single copy of itself
"""
unescape_brackets(text)::String = replace_multi(text, "{{" => "{", "}}" => "}")

unescape_brackets_with_space(text)::String = replace_multi(text, "{{" => " {", "}}" => "} ")

# ------------------------------- closing tags ------------------------------- #
const ansi_pairs = Dict(
    "\e[22m" => "\e[22m",
    "\e[1m" => "\e[22m",
    "\e[2m" => "\e[22m",
    "\e[3m" => "\e[23m",
    "\e[4m" => "\e[24m",
    "\e[5m" => "\e[25m",
    "\e[7m" => "\e[27m",
    "\e[8m" => "\e[28m",
    "\e[9m" => "\e[29m",
)

const ansi_pairs_keys = keys(ansi_pairs)

""" Given an ANSI tag, get the correct closer tag """
function get_closing_ansi_tag(tag::AbstractString)
    tag ∈ ansi_pairs_keys && return ansi_pairs[tag]

    # see en.wikipedia.org/wiki/ANSI_escape_code#Colors

    # deal with 3 and 4bit colors (en.wikipedia.org/wiki/ANSI_escape_code#3-bit_and_4-bit)
    occursin(r"\e\[(3|9)[0-7];(4|10)[0-7][m;]", tag) && return "\e[39;49m"  # mix
    occursin(r"\e\[(3|9)[0-7][m;]", tag) && return "\e[39m"  # foreground
    occursin(r"\e\[(4|10)[0-7][m;]", tag) && return "\e[49m"  # background

    # deal with 8bit (en.wikipedia.org/wiki/ANSI_escape_code#8-bit),
    # or 24bit (en.wikipedia.org/wiki/ANSI_escape_code#24-bit) colors
    occursin(r"\e\[38;(2|5)[m;]", tag) && return "\e[39m"  # foreground
    occursin(r"\e\[48;(2|5)[m;]", tag) && return "\e[49m"  # background

    return nothing
end

# ---------------------------------------------------------------------------- #
#                                     MISC                                   #
# ---------------------------------------------------------------------------- #
"""
    replace_text(text::AbstractString, start::Int, stop::Int, replace::AbstractString)

Replace a section of a `text` between `start` and `stop` with `replace`.
"""
function replace_text(text, start::Int, stop::Int, replace::String)::String
    if start == 0
        return replace * text[(stop + 1):end]
    end

    start = isvalid(text, start) ? start : max(prevind(text, start), 1)
    return if start == 1
        text[1] * replace * text[(stop + 1):end]
    elseif stop == ncodeunits(text)
        text[1:start] * replace
    else
        text[1:start] * replace * text[(stop + 1):end]
    end
end

"""
    replace_text(text::AbstractString, start::Int, stop::Int, char::Char='_')

Replace a section of a `text`  between `start` and `stop` with another string composed of repeats of a given character `char`.
"""
function replace_text(text, start::Int, stop::Int, char::Char = '_')::String
    replacement = char^(stop - start)
    return replace_text(text, start, stop, replacement)
end

"""
    ltrim_str(str, width)

Cut a chunk of width `width` form the left of a string
"""
function ltrim_str(str, width)
    edge = nextind(str, 0, width)
    return if edge ≥ ncodeunits(str)
        str
    else
        str[1:edge]
    end
end

"""
    unspace_commas(text::AbstractString)

Remove spaces after commas.
"""
unspace_commas(text)::String = replace_multi(text, ", " => ",", ". " => ".")

"""
Split a string into a vector of Chars.
"""
chars(text::AbstractString)::Vector{Char} = collect(text)

"""
    join_lines(lines)

Merge a vector of strings in a single string.
"""
join_lines(lines::Vector{String})::String = join(lines, "\n")

"""
    split_lines(text::AbstractString)

Split a string into its composing lines.
"""
split_lines(text::String)::Vector{String} = split(text, "\n")
split_lines(text::SubString)::Vector{String} = String.(split(text, "\n"))

"""
    do_by_line(fn::Function, text::String)

Apply `fn` to each line in the `text`.

The function `fn` should accept a single `::String` argument.
"""
do_by_line(fn::Function, text::AbstractString)::String = join(fn.(split_lines(text)), "\n")

# ------------------------------- reshape text ------------------------------- #
"""
    fillin(text::String)::String

Ensure that each line in a multi-line text has the same width.
"""
function fillin(text; bg = nothing)::String
    lines = split_lines(text)
    length(lines) == 1 && return text

    w = map(textlen, lines) |> maximum
    return map(lines) do ln
        pad = " "^(w - textlen(ln))
        return ln * if isnothing(bg)
            pad
        else
            '{' * bg * '}' * pad * "{/" * bg * '}'
        end
    end |> join_lines
end

"""
    str_trunc(text::AbstractString, width::Int)

Shorten a string of text to a target width
"""
function str_trunc(
        text::AbstractString,
        width::Int;
        trailing_dots = "...",
        ignore_markup = false,
    )::String
    width < 0 && return text
    textlen(text) ≤ width && return text
    if contains(text, '\n')
        return do_by_line(
            l -> str_trunc(
                l,
                width;
                trailing_dots = trailing_dots,
                ignore_markup = ignore_markup,
            ),
            text,
        )
    end

    trunc =
        reshape_text(text, width - textwidth(trailing_dots); ignore_markup = ignore_markup)
    out = first(split_lines(trunc))
    textlen(out) == 0 && return out
    out[end] != ' ' && (out *= trailing_dots)
    return out
end

"""
    string_type(x)
Return the type of `x` if it's an AbstractString, else String
"""
string_type(x) = x isa AbstractString ? typeof(x) : String

rint(x) = (Int ∘ round)(x)
fint(x) = (Int ∘ floor)(x)
cint(x) = (Int ∘ ceil)(x)

is_last(v) = eachindex(v) .== lastindex(v)
is_first(v) = eachindex(v) .== firstindex(v)

"""
  loop_last(v)

  Returns an iterable yielding tuples (is_last, value).
"""
loop_last(v) = zip(is_last(v), v)

loop_firstlast(v) = zip(is_first(v), is_last(v), v)

"""
  get_lr_widths(width::Int)

To split something with `width` in 2, get the lengths
of the left/right widths.

When width is even that's easy, when it's odd we need to
be careful.
"""
function get_lr_widths(width::Int)::Tuple{Int, Int}
    iseven(width) && return (rint(width / 2), rint(width / 2))
    return (fint(width / 2), cint(width / 2))
end

"""
Get a clean string representation of an expression
"""
expr2string(e::Expr) = replace_multi(
    string(e),
    '\n' => "",
    ' ' => "",
    r"#=.*=#" => "",
    "begin" => "",
    "end" => "",
)

"""
  get_file_format(nbytes; suffix="B")

Return a string with formatted file size.
"""
function get_file_format(nbytes; suffix = "B")
    for unit in ("", "K", "M", "G", "T", "P", "E", "Z", "Y")
        nbytes < 1024 && return string(round(nbytes; digits = 2), ' ', unit, suffix)
        nbytes = nbytes / 1024
    end
    return
end

"""
    calc_nrows_ncols(n, aspect::Union{Nothing,Number,NTuple} = nothing)

Computes the number of rows and columns to fit a given number `n` of subplots in a figure with aspect `aspect`.
If `aspect` is `nothing`, chooses the best fir between a default and a unit aspect ratios.

Adapted from: stackoverflow.com/a/43366784
"""
function calc_nrows_ncols(n, aspect::Union{Nothing, Number, NTuple} = nothing)
    h, w = if isnothing(aspect)
        r1, c1 = calc_nrows_ncols(n, DEFAULT_ASPECT_RATIO[])
        r2, c2 = calc_nrows_ncols(n, 1)  # unit aspect - square
        return r1 * c1 < r2 * c2 ? (r1, c1) : (r2, c2)  # choose the best fit
    elseif aspect isa Number
        (one(aspect), aspect)
    else
        aspect
    end
    factor = √(n / (h * w))
    rows = floor(Int, h * factor)
    cols = floor(Int, w * factor)
    row_first = w < h
    while rows * cols < n
        if row_first
            rows += 1
        else
            cols += 1
        end
        row_first = !row_first
    end
    return rows, cols
end

"""
    get_bg_color(style::String)

Add "on_" to background style info.
"""
get_bg_color(style::String) = startswith(style, "on_") ? style : "on_" * style
get_bg_color(style::Nothing) = style
