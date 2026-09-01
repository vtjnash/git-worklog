# Two-pane browser: item list beside (or above) a foldable detail pane showing
# either the comment thread, rendered as markdown, or the diff.
#
# Panes and markdown come from Term.jl. Two things about it are worth knowing:
# `parse_md` emits Term's own {tag} markup rather than ANSI, so its output has
# to go through `apply_style` or the tags show up literally in the pane; and
# `Panel` measures styled content correctly, so content can carry colour without
# breaking the layout.
#
# `render` is kept pure - state and a size in, a string out - so the whole UI
# can be snapshot tested without a TTY, which is the only way any of it got
# verified here.

using Term: Panel, apply_style
import Markdown

"A foldable block - a comment, the issue body, or one file of a diff."
mutable struct Node
    header::String
    raw::String
    kind::Symbol            # :md | :diff | :plain
    open::Bool
    cache::Vector{String}   # rendered at `cw`; markdown is far too slow per frame
    cw::Int
end
Node(h, raw, kind, open) = Node(h, raw, kind, open, String[], -1)

mutable struct BState
    items::Vector{Item}
    title::String
    sel::Int
    top::Int
    nodes::Vector{Node}
    ncur::Int
    ntop::Int
    focus::Symbol           # :list | :detail
    mode::Symbol            # :comments | :diff
    loaded::String
    status::String
end
BState(items, title) = BState(items, title, 1, 1, Node[], 1, 1, :list, :comments, "", "")

"""Term reads `{...}` as markup, and comment text is not ours to trust - a
comment containing braces would otherwise be swallowed or mangled."""
esc(s) = replace(s, "{" => "{{", "}" => "}}")

"""Truncate to `w` display columns.

Term wraps content that overflows, which turns a list of items into a wall of
continuation lines and makes it unscannable. Rows that must stay one line per
entry are cut here first.
"""
function fit1(s::AbstractString, w::Int)
    w <= 1 && return ""
    textwidth(s) <= w && return s
    out, acc = IOBuffer(), 0
    for c in s
        acc + textwidth(c) > w - 1 && break
        print(out, c); acc += textwidth(c)
    end
    String(take!(out)) * "…"
end

function diffline(l)
    # File headers must be tested before the bare +/- cases, or `+++`/`---`
    # colour as additions and deletions.
    startswith(l, "@@") && return "{cyan}" * esc(l) * "{/cyan}"
    (startswith(l, "+++") || startswith(l, "---") || startswith(l, "index ")) &&
        return "{dim}" * esc(l) * "{/dim}"
    startswith(l, "+") && return "{green}" * esc(l) * "{/green}"
    startswith(l, "-") && return "{red}" * esc(l) * "{/red}"
    esc(l)
end

"Render a node's body at width `w`, cached - markdown is too slow to redo per frame."
function nodelines(n::Node, w::Int)
    n.cw == w && return n.cache
    txt = if n.kind === :md
        isempty(strip(n.raw)) ? "" :
            try
                # Hand Panel Term *markup*, not ANSI. apply_style here would
                # bake in escape codes that Panel then counts toward the line
                # width, wrapping content that already fits and overflowing the
                # pane height into "... content omitted ...".
                string(Term.TermMarkdown.parse_md(
                    Markdown.parse(n.raw); width = max(20, w - 2)))
            catch
                esc(n.raw)      # malformed markdown must not take the pane down
            end
    elseif n.kind === :diff
        join((diffline(l) for l in split(n.raw, "\n")), "\n")
    else
        esc(n.raw)
    end
    n.cache = isempty(txt) ? String[] : split(txt, "\n")
    n.cw = w
    n.cache
end

"Flatten open/closed nodes into rows, so selection and scrolling share one space."
function rows(nodes::Vector{Node}, w::Int)
    out = Tuple{Int,Bool,String}[]
    for (i, n) in enumerate(nodes)
        push!(out, (i, true, string("{bold}",
                    esc(fit1(string(n.open ? "▾ " : "▸ ", n.header), w)), "{/bold}")))
        n.open || continue
        for l in nodelines(n, w)
            push!(out, (i, false, l))
        end
    end
    out
end

"Vertical slice with the cursor's node kept in view."
function window(rs, cur, top, h)
    isempty(rs) && return (String[], 1)
    top = clamp(top, 1, max(1, length(rs)))
    if cur !== nothing
        cur < top && (top = cur)
        cur > top + h - 1 && (top = cur - h + 1)
    end
    top = clamp(top, 1, max(1, length(rs) - h + 1))
    ([r[3] for r in rs[top:min(end, top + h - 1)]], top)
end

"""
    render(st, w, h) -> String

Pure. Side by side when the terminal is wide enough, stacked otherwise, so a
narrow window degrades rather than truncating the detail into uselessness.
"""
function render(st::BState, w::Int, h::Int)
    side = w >= 110
    lw = side ? clamp(w ÷ 3, 34, 52) : w
    rw = side ? w - lw : w
    bodyh = max(6, h - 2)
    lh = side ? bodyh : max(5, bodyh ÷ 3)
    rh = side ? bodyh : bodyh - lh

    inner(width) = width - 6      # Term.Panel: 2 border + 4 padding, measured
    st.sel = clamp(st.sel, 1, max(1, length(st.items)))
    lrows = Tuple{Int,Bool,String}[]
    for i in 1:length(st.items)
        it_ = st.items[i]
        on = i == st.sel && st.focus === :list
        txt = fit1(string(it_.track == "close" ? "*" : " ", it_.ref, " ", it_.title),
                   inner(lw))
        push!(lrows, (i, true, string(on ? "{bold white}" : "{dim}", esc(txt),
                                      on ? "{/bold white}" : "{/dim}")))
    end
    lvis, st.top = window(lrows, st.sel, st.top, lh - 2)

    rrows = rows(st.nodes, inner(rw))
    cur = findfirst(r -> r[1] == st.ncur && r[2], rrows)
    rvis, st.ntop = window(rrows, cur, st.ntop, rh - 2)

    it = isempty(st.items) ? nothing : st.items[st.sel]
    ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    rtitle = string(st.mode === :comments ? "comments" : "diff",
                    it === nothing ? "" : string("  ", it.ref))

    # Term measures markup, and escaped braces plus styling make a line's markup
    # longer than what it prints, so the exact number of content lines that fit
    # is not predictable from the text. Shrink until Term stops eliding.
    function panel(lines, width, height, title, style)
        for n in length(lines):-1:1
            p = Panel(join(lines[1:n], "\n"); width = width, height = height,
                      title = title, style = style, title_style = "bold")
            occursin("omitted", string(p)) || return p
        end
        Panel(""; width = width, height = height, title = title, style = style,
              title_style = "bold")
    end

    left = panel(lvis, lw, lh, ltitle, st.focus === :list ? "bold" : "dim")
    right = panel(rvis, rw, rh, rtitle, st.focus === :detail ? "bold blue" : "dim")

    keys = "j/k move · tab pane · ↵ fold · d diff · o comments · r read · s snooze · q back"
    ftxt = isempty(st.status) ? keys : st.status
    foot = "{dim}" * esc(rpad(fit1(ftxt, w), w)) * "{/dim}"
    string(side ? string(left * right) : string(left / right), "\n", apply_style(foot))
end

# --- content loading -------------------------------------------------------

function comment_nodes(it::Item)
    local body, cs
    try
        body, cs = Events.thread(it.url; limit = 30)
    catch e
        return [Node("could not load thread", first(sprint(showerror, e), 200), :plain, true)]
    end
    ns = Node[]
    who0 = get(something(get(body, "user", nothing), Dict{String,Any}()), "login", "?")
    btxt = strip(replace(nz(get(body, "body", nothing), ""), "\r\n" => "\n"))
    isempty(btxt) || push!(ns, Node(string(nz(who0, "?"), " opened this"), btxt, :md, true))
    for c in cs
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
        at = first(String(c["created_at"]), 16)
        txt = strip(replace(nz(get(c, "body", nothing), ""), "\r\n" => "\n"))
        peek = strip(first(replace(txt, r"\s+" => " "), 58))
        push!(ns, Node(string(nz(who, "?"), "  ", at, "   ", peek), txt, :md, false))
    end
    isempty(ns) ? [Node("no comments", "", :plain, true)] : ns
end

"One node per file, so a 600-line diff opens as a list of filenames."
function diff_nodes(it::Item)
    txt = try
        read(`gh pr diff $(it.number) --repo $(it.repo)`, String)
    catch e
        return [Node("no diff (not a PR, or gh failed)",
                     first(sprint(showerror, e), 200), :plain, true)]
    end
    ns, buf, name = Node[], String[], ""
    flush!() = if !isempty(name)
        body = join(buf, "\n")
        adds = count(l -> startswith(l, "+") && !startswith(l, "+++"), buf)
        dels = count(l -> startswith(l, "-") && !startswith(l, "---"), buf)
        push!(ns, Node(string(name, "  +", adds, " -", dels), body, :diff, false))
    end
    for l in split(txt, "\n")
        if startswith(l, "diff --git")
            flush!()
            name = replace(String(last(split(l, " "))), r"^b/" => "")
            buf = String[]
        elseif !isempty(name)
            push!(buf, String(l))
        end
    end
    flush!()
    isempty(ns) ? [Node("empty diff", "", :plain, true)] : ns
end

function load_nodes!(st::BState)
    isempty(st.items) && return
    it = st.items[st.sel]
    key = string(it.url, ":", st.mode)
    st.loaded == key && return
    st.nodes = st.mode === :comments ? comment_nodes(it) : diff_nodes(it)
    st.loaded = key; st.ncur = 1; st.ntop = 1
end
