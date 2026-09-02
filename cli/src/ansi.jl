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

Two things make this more than a chunking loop.

Style carries across a break: the active SGR codes are replayed at the start of
each continuation line, or a colour opened before the break would stop at it.
Escapes travel with the word they style, so that a word carried to the next line
takes its colour with it.

And a run wider than the pane has nowhere to break - a URL, a stack frame, a
type signature, all of which this is full of - so it falls back to breaking
mid-run rather than overflowing the pane.
"""
function awrap(s::AbstractString, w::Int)
    w <= 1 && return [s]
    out = String[]
    line, word = IOBuffer(), IOBuffer()   # committed; and the run since a space
    lw, ww = 0, 0                         # their display widths
    active = String[]                     # SGR codes in force right now
    wactive = String[]                    # ...and as of the start of `word`
    breakable = false                     # does `line` end at a space?
    emit!(codes) = begin
        push!(out, String(take!(line)))
        lw = 0
        isempty(codes) || write(line, join(codes))
    end
    commit!() = begin                     # fold the word into the line
        write(line, String(take!(word)))
        lw += ww; ww = 0
        wactive = copy(active)
    end
    carry!() = begin                      # move the word down to a new line
        before = copy(wactive)            # what was in force before the word
        emit!(before)                     # the word replays its own codes
        write(line, String(take!(word)))
        lw = ww; ww = 0
        wactive = copy(active)
        breakable = false
    end
    i = firstindex(s)
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            e = String(m.match)
            write(word, e)                # zero width, and belongs to the word
            if startswith(e, "\e[")
                e == "\e[0m" ? empty!(active) : push!(active, e)
            end
            i += ncodeunits(m.match)
            continue
        end
        c = s[i]
        cw = textwidth(c)
        # A loop rather than a branch: a word carried down can still be wider
        # than the pane on its own, and then has to be split anyway.
        while lw + ww + cw > w
            if breakable
                carry!()
            else
                commit!(); emit!(active)  # no space to break at; split the run
                breakable = false
            end
        end
        if isspace(c)
            commit!()
            write(line, c); lw += cw
            breakable = true
        else
            write(word, c); ww += cw
        end
        i = nextind(s, i)
    end
    write(line, String(take!(word)))
    push!(out, String(take!(line)))
    out
end

"""One line, whatever it was.

Anything that reaches a single-row field - the footer's message, a status - has
to *be* one row. `showerror` is the reason this exists: its output carries a
newline, so an error put straight into the footer made the frame one row taller
than the screen, scrolled it, and left every mouse click reporting a row that
was no longer under it.
"""
oneline(s::AbstractString) = replace(strip(s), r"\s*\n\s*" => " \u00b7 ")
