# ANSI-aware text measurement, truncation and wrapping.
#
# These exist because Term cannot be trusted to lay out its own markdown output.
# `parse_md` escapes braces by doubling them, which nothing downstream collapses
# - so Julia type signatures arrive on screen as `Tuple{{Type{{S{{N, Tup}}}` -
# and it does not wrap lines containing inline code, emitting 232 display
# columns for a requested width of 90. Handing that to `Panel`, which measures
# markup rather than what prints, compounded both.
#
# So Term is used only to turn markdown into ANSI, and the pane layout is done
# here against real display widths.

"Matches a CSI colour sequence or an OSC 8 hyperlink - the two we emit."
const ESCAPE = r"^(?:\e\[[0-9;]*[A-Za-z]|\e\][^\e]*\e\\)"

"Display width, ignoring escape sequences."
function awidth(s::AbstractString)
    w, i = 0, firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m === nothing
            w += textwidth(s[i]); i = nextind(s, i)
        else
            i += ncodeunits(m.match)
        end
    end
    w
end

"""Plain text: the same string with every escape sequence taken out.

What a yank has to produce. The screen carries colour and hyperlinks that are
invisible in the terminal but very visible in a paste buffer.
"""
function astrip(s::AbstractString)
    io, i = IOBuffer(), firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m === nothing
            write(io, s[i]); i = nextind(s, i)
        else
            i += ncodeunits(m.match)
        end
    end
    String(take!(io))
end

"Truncate to `w` display columns, keeping escapes, and reset style at the cut."
function afit(s::AbstractString, w::Int)
    w <= 0 && return ""
    awidth(s) <= w && return s
    io, acc, i = IOBuffer(), 0, firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            write(io, m.match); i += ncodeunits(m.match); continue
        end
        cw = textwidth(s[i])
        acc + cw > w - 1 && break
        write(io, s[i]); acc += cw; i = nextind(s, i)
    end
    String(take!(io)) * "…\e[0m"
end

"Pad to exactly `w` display columns."
apad(s::AbstractString, w::Int) = (d = w - awidth(s); d > 0 ? s * " "^d : afit(s, w))

"""Wrap to `w` display columns, preserving escapes and breaking at spaces.

Style carries across a break: the active SGR codes are replayed at the start of
each continuation line, or a colour opened before the break would stop at it.
"""
function awrap(s::AbstractString, w::Int)
    w <= 1 && return [s]
    out, io, acc, active, i = String[], IOBuffer(), 0, String[], firstindex(s)
    lastspace, sincespace = -1, IOBuffer()
    flush_line() = begin
        push!(out, String(take!(io)))
        acc = 0
        isempty(active) || write(io, join(active))
    end
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            e = String(m.match)
            write(io, e)
            if startswith(e, "\e[")
                e == "\e[0m" ? empty!(active) : push!(active, e)
            end
            i += ncodeunits(m.match); continue
        end
        c = s[i]
        cw = textwidth(c)
        if acc + cw > w
            flush_line()
        end
        write(io, c); acc += cw
        i = nextind(s, i)
    end
    push!(out, String(take!(io)))
    out
end
