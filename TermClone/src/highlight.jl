import OrderedCollections: OrderedDict


# ------------------------------- highlighting ------------------------------- #
highlight_regexes = OrderedDict(
    :number => (r"(?<group>(?<![a-zA-Z0-9_#])\d+(\.\d*)?+([eE][+-]?\d*)?)",),
    :operator => (
        r"(?<group>(?<!\{)\/)",
        r"(?<group>(?![\:\<])[\+\-\*\%\^\&\|\!\=\>\<\~\[\]×])",
    ),
    :string => (r"(?<group>[\'\"][\w\n]*[\'\"])",),
    :code => (r"(?<group>([\`]{3}|[\`]{1})(\n|.)*?([\`]{3}|[\`]{1}))",),
    :expression => (r"(?<group>\:\(+.+[\)])",),
    :symbol => (r"(?<group>(?<!\:)(?<!\:)\:\w+)",),
    # :emphasis_light => (r"(?<group>[\[\]\(\)])", r"(?<group>@\w+)"),
    :type => (r"(?<group>\:\:[\w\.]*)", r"(?<group>\<\:\w+)"),
)

"""
    highlight(text::AbstractString, theme::Theme)

Highlighs a text introducing markup to style semantically
relevant segments, colors specified by a theme object.
"""
function highlight(
        text::AbstractString;
        theme::Theme = TERM_THEME[],
        ignore_ansi::Bool = false,
    )
    (has_ansi(text) && !ignore_ansi) && return text

    # highlight with regexes
    for (symb, rxs) in pairs(highlight_regexes)
        markup = getfield(theme, symb)
        open, close = "{$markup}", "{/$markup}"
        for rx in rxs
            text = replace(text, rx => SubstitutionString(open * s"\g<0>" * close))
        end
    end

    return text
end

"""
    highlight(text::AbstractString, theme::Theme, like::Symbol)

Hilights an entire text as if it was a type of semantically
relevant text of type :like.
"""
highlight(text::AbstractString, like::Symbol; theme::Theme = TERM_THEME[]) =
    apply_style(text, getfield(theme, like))

# shorthand to highlight objects based on type
highlight(x; theme = TERM_THEME[]) = apply_style(string(x), theme(x)) # capture all other cases

"""
    highlight_row(text; theme) -> Row

`text` as `highlight` colours it, as a row: the text is kept as it is - braces
and all, never read as markup - and each match of the highlighting regexes has
its theme style laid over it, a later one over an earlier.
"""
function highlight_row(text::AbstractString; theme::Theme = TERM_THEME[])
    s = String(text)
    r = row(s)
    for (symb, rxs) in pairs(highlight_regexes)
        f = Style.face(getfield(theme, symb))
        for rx in rxs, m in eachmatch(rx, s)
            isempty(m.match) && continue
            r = overlaid(r, m.offset:(m.offset + ncodeunits(m.match) - 1), f)
        end
    end
    return r
end

# ------------------------------ Highlighters.jl ----------------------------- #

# Code is highlighted by TermInput's `highlight`, which answers byte ranges of
# the code and the name of the face each is in - JuliaSyntaxHighlighting's names,
# where the running Julia has it - and drawn by its `highlighted_lines`, a row to
# each line, in the faces of a `MarkdownStyle`. `CODE_FACES` says which of
# Term's code styles each name is drawn in; the names it leaves out fall back
# through TermInput's own table (`rainbow_paren_1` to `parentheses`, `assignment`
# to `operator`, ...).

const CODE_FACES = Dict(
    :keyword => "keyword",
    :funcall => "function",
    :funcdef => "function",
    :macro => "macro",
    :string => "string",
    :char => "character",
    :cmd => "string",
    :symbol => "string",
    :comment => "comment",
    :number => "number",
    :bool => "boolean",
    :typedec => "operator",
    :operator => "operator",
    :error => "operator",
    :parentheses => "punctuation",
    :brackets => "punctuation",
    :curlies => "punctuation",
)

"""
    code_style(capture)

The style of a highlighted piece of code: a face name from TermInput's
`highlight`, or a capture name as Term's `CodeTheme` spells it.
"""
code_style(capture::Symbol) = code_style(get(CODE_FACES, capture, "text"))
function code_style(capture::AbstractString)
    parts = split(capture, '.')
    while !isempty(parts)
        style = get(CodeTheme, join(parts, '.'), nothing)
        isnothing(style) || return style
        pop!(parts)
    end
    return CodeTheme["text"]
end

const CODE_MDSTYLE = Ref{Any}(nothing)

"""
    code_mdstyle() -> TermInput.MarkdownStyle

`CodeTheme` as the faces TermInput draws a highlighted block in: one per face
name in `CODE_FACES`, and the code block's background left empty.
"""
function code_mdstyle()
    st = CODE_MDSTYLE[]
    st === nothing || return st::TermInput.MarkdownStyle
    return CODE_MDSTYLE[] = TermInput.MarkdownStyle(
        faces = Dict{Symbol, Face}(k => Style.face(code_style(v)) for (k, v) in CODE_FACES),
    )
end

"""
    code_rows(code; lang = "julia") -> Vector{Row}

Code as rows, one to each line: TermInput's `highlighted_lines` in
`CodeTheme`'s faces, over the whole of each line in `CodeTheme["text"]`.
"""
function code_rows(code::AbstractString; lang::AbstractString = "julia")
    text = Style.face(CodeTheme["text"])
    lang = TermInput.codemime(lang) isa MIME"text/julia" ? "term-julia" : lang
    lines = TermInput.highlighted_lines(lang, code, code_mdstyle())
    return Row[faced(r, text) for r in lines]
end

"""
    TermInput.highlight(::MIME"text/term-julia", code)

Julia as Term's tree-sitter grammar paints it: TermInput's own Julia highlighter
(JuliaSyntaxHighlighting), and where the two disagree, Term's choice - a word
operator (`isa`, `in`, `where`) is a keyword, and the delimiters `,` `.` `:`
that JuliaSyntaxHighlighting leaves unpainted, and the `;` it paints as an
assignment, are punctuation. A highlighter of a language of Term's own, as
TermInput asks a host to add one, beside Julia's rather than over it.
"""
function TermInput.highlight(::MIME"text/term-julia", code::AbstractString)
    out = TermInput.highlight(MIME"text/julia"(), code)
    covered = falses(ncodeunits(code))
    for (k, (r, f)) in enumerate(out)
        covered[r] .= true
        f === :operator && code[r] in ("isa", "in", "where") &&
            (out[k] = (r, :keyword))
    end
    for (i, c) in pairs(code)
        if c == ';' || (c in (',', '.', ':') && !covered[i])
            push!(out, (i:i, :parentheses))
        end
    end
    return out
end

"""
    code_row(code) -> Row

Julia code as one row, its lines joined by newlines.
"""
code_row(code::AbstractString) = joinrows(code_rows(code))

"""
    highlight_syntax(code::AbstractString; style::Bool=true)

Highlight Julia code syntax in a string.
"""
highlight_syntax(code::AbstractString; style::Bool = true) =
    style ? Style.ansi(code_row(code)) : String(code)

# Stack traces revisit the same few files across frames, and parsing dominates the cost.
const HIGHLIGHTED_FILES = Dict{Tuple{String, Float64}, Vector{String}}()
const HIGHLIGHTED_FILES_CACHE_SIZE = 32

"""
    highlight_file_lines(path::AbstractString)::Vector{String}

Highlight `path`, returning its styled lines.
"""
function highlight_file_lines(path::AbstractString)::Vector{String}
    length(HIGHLIGHTED_FILES) ≥ HIGHLIGHTED_FILES_CACHE_SIZE && empty!(HIGHLIGHTED_FILES)
    return get!(HIGHLIGHTED_FILES, (String(path), mtime(path))) do
        [Style.ansi(r) for r in code_rows(join_lines(readlines(path)))]
    end
end
"""
    load_code_and_highlight(path::AbstractString, lineno::Int; δ::Int=3, width::INt=120)

Load a file, get the code and format it. Return styled text
"""
function load_code_and_highlight(path::AbstractString, lineno::Int; δ::Int = 3)::String
    η = countlines(path)
    @assert lineno > 0 "lineno must be ≥1"
    @assert lineno ≤ η "lineno $lineno too high for file with $(η) lines"

    linenos = max(lineno - δ, 1):min(lineno + δ, η)
    codelines = highlight_file_lines(path)[linenos]
    δ == 0 && (codelines = lstrip_ansi.(codelines))

    # format
    _len = textlen ∘ lstrip
    dedent = 100
    for ln in codelines
        if _len(ln) > 1
            dedent = min(dedent, textlen(ln) - _len(ln))
        end
    end
    dedent = dedent < 1 ? 1 : dedent

    cleaned_lines = []
    for (n, line) in zip(linenos, codelines)
        # style
        symb, color = if n == lineno
            "{red bold}❯{/red bold}", "white"
        else
            " ", "grey39"
        end

        line = textlen(line) > 1 ? lpad(line[dedent:end], 8) : line
        push!(cleaned_lines, symb * " {$color}$n{/$color} " * line)
    end

    return join(cleaned_lines, "\n")
end

"""
    load_code_and_highlight(path::AbstractString)::String

Load and highlight the syntax of an entire file
"""
load_code_and_highlight(path::AbstractString)::String =
    join_lines(highlight_file_lines(path))
