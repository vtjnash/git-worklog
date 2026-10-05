module Style

import Parameters: @with_kw
import StyledStrings
import StyledStrings: Face, SimpleColor

import Term:
    unspace_commas,
    NAMED_MODES,
    has_markup,
    OPEN_TAG_REGEX,
    replace_text,
    CODES,
    ANSICode,
    tview,
    do_by_line,
    ANSI_REGEX,
    NOCOLOR,
    Row,
    row,
    rowcat,
    faced

import ..Colors:
    AbstractColor,
    NamedColor,
    is_color,
    is_background,
    get_color,
    is_hex_color,
    hex2rgb,
    simplecolor

export apply_style

"""
Check if a string is a mode name
"""
is_mode(string) = string ∈ NAMED_MODES

# ---------------------------------------------------------------------------- #
#                                  MarkupStyle                                 #
# ---------------------------------------------------------------------------- #

"""
    MarkupStyle

Holds information about the style specification set out by a `MarkupTag`.
"""
@with_kw mutable struct MarkupStyle
    default::Bool = false
    bold::Bool = false
    dim::Bool = false
    italic::Bool = false
    underline::Bool = false
    blink::Bool = false
    inverse::Bool = false
    hidden::Bool = false
    striked::Bool = false
    color::Union{Nothing, AbstractColor} = nothing
    background::Union{Nothing, AbstractColor} = nothing
end

const MODE_ALIASES = Dict("b" => :bold, "i" => :italic, "u" => :underline)

"""
    MarkupStyle(markup)

Builds a MarkupStyle definition from the words of a markup tag.
"""
function MarkupStyle(markup)
    style = MarkupStyle()
    for code in split(unspace_commas(markup))
        if is_mode(code)
            setproperty!(style, get(MODE_ALIASES, code, Symbol(code)), true)
        elseif is_color(code)
            style.color = get_color(code)
        elseif is_background(code)
            style.background = get_color(code; bg = true)
        end
    end
    return style
end

"""
    get_style_codes(style::MarkupStyle)

The ANSI codes that open and close a `MarkupStyle`, as Term spells them.
"""
function get_style_codes(style::MarkupStyle)
    style_init, style_finish = "", ""
    for attr in fieldnames(MarkupStyle)
        value = getfield(style, attr)
        if attr ≡ :background
            code = isnothing(value) ? nothing : ANSICode(value; bg = true)
        elseif attr ≡ :color
            if !isnothing(value)
                try
                    code = ANSICode(value; bg = false)
                catch
                    continue
                end
            else
                code = nothing
            end
        elseif value == true
            code = CODES[attr]
        else
            continue
        end
        if !isnothing(code)
            style_init *= code.open
            style_finish *= code.close
        end
    end
    return style_init, style_finish
end

# ---------------------------------------------------------------------------- #
#                                 cell attributes                              #
# ---------------------------------------------------------------------------- #

"""
    Attrs

What a terminal cell is drawn in: the state an SGR stream leaves, and what a
stack of markup tags adds up to. A field that is `nothing` is unset, so one
layer laid over another changes only what it says.
"""
Base.@kwdef mutable struct Attrs
    fg::Union{Nothing, SimpleColor} = nothing
    bg::Union{Nothing, SimpleColor} = nothing
    bold::Union{Nothing, Bool} = nothing
    dim::Union{Nothing, Bool} = nothing
    italic::Union{Nothing, Bool} = nothing
    underline::Union{Nothing, Bool} = nothing
    blink::Union{Nothing, Bool} = nothing
    inverse::Union{Nothing, Bool} = nothing
    hidden::Union{Nothing, Bool} = nothing
    striked::Union{Nothing, Bool} = nothing
    link::Union{Nothing, String} = nothing
end

Base.copy(a::Attrs) = Attrs((getfield(a, f) for f in fieldnames(Attrs))...)
Base.:(==)(a::Attrs, b::Attrs) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(Attrs))

"Lay `top` over `a`: what `top` sets wins."
function overlay!(a::Attrs, top::Attrs)
    for f in fieldnames(Attrs)
        v = getfield(top, f)
        isnothing(v) || setfield!(a, f, v)
    end
    return a
end

"The attributes a markup style sets."
function Attrs(ms::MarkupStyle)
    a = Attrs()
    ms.default && (a.bold = false; a.dim = false)
    ms.bold && (a.bold = true)
    ms.dim && (a.dim = true)
    ms.italic && (a.italic = true)
    ms.underline && (a.underline = true)
    ms.blink && (a.blink = true)
    ms.inverse && (a.inverse = true)
    ms.hidden && (a.hidden = true)
    ms.striked && (a.striked = true)
    a.fg = simplecolor(ms.color)
    a.bg = simplecolor(ms.background)
    return a
end

on(x) = x === true ? true : nothing

"""
    Face(a::Attrs) -> Face

The StyledStrings face for a cell's attributes. A face has one weight, so bold
and dim together are bold; and it has no blink and no concealment, so those
are not drawn at all.
"""
function StyledStrings.Face(a::Attrs)
    weight = a.bold === true ? :bold : a.dim === true ? :light : nothing
    Face(;
        foreground = a.fg,
        background = a.bg,
        weight,
        slant = a.italic === true ? :italic : nothing,
        underline = on(a.underline),
        strikethrough = on(a.striked),
        inverse = on(a.inverse),
    )
end

"A face for a style given as markup words, such as `\"bold red on_blue\"`."
face(style::AbstractString) = Face(Attrs(MarkupStyle(style)))
face(::Nothing) = Face()

"""
    sgr!(a::Attrs, params::AbstractString)

Apply one SGR sequence's parameters to `a`, as a terminal would.
"""
function sgr!(a::Attrs, params::AbstractString)
    ps = [isempty(p) ? 0 : something(tryparse(Int, p), 0) for p in split(params, ';')]
    i = 1
    while i <= length(ps)
        p = ps[i]
        if p == 0
            link = a.link
            for f in fieldnames(Attrs)
                setfield!(a, f, nothing)
            end
            a.link = link
        elseif p == 1
            a.bold = true
        elseif p == 2
            a.dim = true
        elseif p == 3
            a.italic = true
        elseif p == 4
            a.underline = true
        elseif p == 5
            a.blink = true
        elseif p == 7
            a.inverse = true
        elseif p == 8
            a.hidden = true
        elseif p == 9
            a.striked = true
        elseif p == 21 || p == 22
            a.bold = nothing
            a.dim = nothing
        elseif p == 23
            a.italic = nothing
        elseif p == 24
            a.underline = nothing
        elseif p == 25
            a.blink = nothing
        elseif p == 27
            a.inverse = nothing
        elseif p == 28
            a.hidden = nothing
        elseif p == 29
            a.striked = nothing
        elseif 30 <= p <= 37
            a.fg = simplecolor(p - 30)
        elseif 90 <= p <= 97
            a.fg = simplecolor(p - 90 + 8)
        elseif 40 <= p <= 47
            a.bg = simplecolor(p - 40)
        elseif 100 <= p <= 107
            a.bg = simplecolor(p - 100 + 8)
        elseif p == 39
            a.fg = nothing
        elseif p == 49
            a.bg = nothing
        elseif p == 38 || p == 48
            c = nothing
            if i + 2 <= length(ps) && ps[i + 1] == 5
                c = simplecolor(ps[i + 2])
                i += 2
            elseif i + 4 <= length(ps) && ps[i + 1] == 2
                c = SimpleColor(ps[i + 2], ps[i + 3], ps[i + 4])
                i += 4
            end
            p == 38 ? (a.fg = c) : (a.bg = c)
        end
        i += 1
    end
    return a
end

# ---------------------------------------------------------------------------- #
#                               reading into rows                              #
# ---------------------------------------------------------------------------- #

const Annot = @NamedTuple{region::UnitRange{Int}, label::Symbol, value::Any}

const TAG_AT = r"\G\{(/?)([a-zA-Z _0-9.,()#]*)\}"
const SGR_AT = r"\G\e\[([0-9;]*)m"
const OSC8_AT = r"\G\e\]8;[^;\e\a]*;([^\e\a]*)(?:\e\\|\a)"

"""
    torow(text) -> Row

Read a string of Term markup and ANSI escapes into a row of faces: the text a
terminal would show, with a StyledStrings face over each run of it that is
drawn the same way, and a `:link` over each run inside an OSC 8 hyperlink.

A row is returned as it is. A `{{` or `}}` is an escaped brace and is kept as
it is, as Term keeps it. A tag that closes nothing is dropped, and one that is
never closed runs to the end.
"""
torow(r::Row) = r
torow(r::Base.AnnotatedString) = row(r)
torow(r::SubString{<:Base.AnnotatedString}) = row(r)
torow(c::AbstractChar) = torow(string(c))
function torow(text::AbstractString)::Row
    s = String(text)
    (occursin('{', s) || occursin('\e', s)) || return row(s)

    stack = Tuple{String, Attrs}[]
    sgr = Attrs()
    out = IOBuffer()
    runs = Tuple{UnitRange{Int}, Attrs}[]
    cur = Attrs()
    runstart = 1

    function effective()
        a = copy(sgr)
        for (_, l) in stack
            overlay!(a, l)
        end
        return a
    end
    function restyle!()
        a = effective()
        a == cur && return
        pos = position(out)
        pos >= runstart && push!(runs, (runstart:pos, cur))
        cur = a
        runstart = pos + 1
    end

    i, n = 1, ncodeunits(s)
    while i <= n
        c = s[i]
        if c == '{'
            if i < n && s[i + 1] == '{'
                write(out, "{{")
                i += 2
                continue
            end
            m = match(TAG_AT, s, i)
            if m !== nothing && !isempty(strip(m.captures[2]))
                spec = String(strip(m.captures[2]))
                if m.captures[1] == "/"
                    k = findlast(x -> x[1] == spec, stack)
                    isnothing(k) || deleteat!(stack, k)
                else
                    push!(stack, (spec, Attrs(MarkupStyle(spec))))
                end
                restyle!()
                i += ncodeunits(m.match)
                continue
            elseif m !== nothing && m.captures[1] == "/"   # `{/}` closes the last
                isempty(stack) || pop!(stack)
                restyle!()
                i += ncodeunits(m.match)
                continue
            end
        elseif c == '}' && i < n && s[i + 1] == '}'
            write(out, "}}")
            i += 2
            continue
        elseif c == '\e'
            m = match(SGR_AT, s, i)
            if m !== nothing
                sgr!(sgr, m.captures[1])
                restyle!()
                i += ncodeunits(m.match)
                continue
            end
            m = match(OSC8_AT, s, i)
            if m !== nothing
                url = m.captures[1]
                sgr.link = isempty(url) ? nothing : String(url)
                restyle!()
                i += ncodeunits(m.match)
                continue
            end
        end
        write(out, c)
        i = nextind(s, i)
    end
    pos = position(out)
    pos >= runstart && push!(runs, (runstart:pos, cur))
    str = String(take!(out))
    anns = Annot[]
    for (r, a) in runs
        isempty(r) && continue
        r = first(r):thisind(str, last(r))
        f = Face(a)
        f == Face() || push!(anns, Annot((r, :face, f)))
        isnothing(a.link) || push!(anns, Annot((r, :link, a.link)))
    end
    return Row(str, anns)
end

"""
    ansi(r) -> String

A row written as StyledStrings writes it to a terminal: its text, with the
escapes for its faces and links. Plain text when `NOCOLOR[]` is set.
"""
function ansi(r::Row)::String
    NOCOLOR[] && return r.string
    isempty(StyledStrings.annotations(r)) && return r.string
    io = IOBuffer()
    print(IOContext(io, :color => true), r)
    return String(take!(io))
end
ansi(s::AbstractString) = ansi(torow(s))

"""
    styled(text, style) -> Row

`text` read as markup, under the style given as markup words - `"bold red"` -
or not at all for `nothing`.
"""
styled(text, style::Union{Nothing, AbstractString}) = faced(torow(text), face(style))
styled(text) = torow(text)

# -------------------------------- apply style ------------------------------- #

"""
    apply_style(text::String, style::String)

Apply a style to each line of a piece of text.
"""
apply_style(text::String, style::String) =
if occursin('\n', text)
    do_by_line(ln -> apply_style(ln, style), text)
else
    apply_style("{" * style * "}" * text * "{/" * style * "}")
end

"""
    apply_style(text)

Turn markup into ANSI escapes: the text read into faces by `torow`, written back
out by StyledStrings. Text with no markup in it is returned as it is.
"""
function apply_style(text; leave_orphan_tags = false)::String
    has_markup(text) || return text
    return ansi(torow(text))
end

end
