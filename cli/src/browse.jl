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

import Term
using Term: Panel, apply_style
import REPL
import Markdown

"Last markdown failure, surfaced in the footer rather than swallowed."
const MD_WARN = Ref("")

"A foldable block - a comment, the issue body, or one file of a diff."
mutable struct Node
    header::String
    raw::String
    kind::Symbol            # :md | :diff | :plain
    open::Bool
    cache::Vector{String}   # rendered at `cw`; markdown is far too slow per frame
    cw::Int
    urls::Vector{String}    # link targets pulled out of the body
end
Node(h, raw, kind, open) = Node(h, raw, kind, open, String[], -1, String[])

mutable struct BState
    items::Vector{Item}
    title::String
    sel::Int
    top::Int
    nodes::Vector{Node}
    nrow::Int              # cursor into the flattened rows, not into nodes:
                           # scrolling inside a long comment needs row
                           # granularity, and folding still works because every
                           # row knows which node it belongs to
    ntop::Int
    focus::Symbol           # :list | :detail
    mode::Symbol            # :comments | :diff
    loaded::String
    status::String
    pending::Union{Nothing,Task}   # in-flight fetch; the key loop never blocks
    pendkey::String
end
BState(items, title) =
    BState(items, title, 1, 1, Node[], 1, 1, :list, :comments, "", "", nothing, "")

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

"""
    delink(md) -> (text, urls)

Pull the URLs out of markdown links, leaving `label [n]` behind.

Term renders a link as its label followed by the raw URL, so a single Godbolt
or CI permalink - routinely several hundred characters - crowds out the comment
it appears in. The URLs come back as footnotes instead, one short line each.

Scanned rather than matched with a regex: link targets nest parentheses, and
Godbolt in particular emits URLs full of them. A `[^)]+` target stops at the
first one and spills the rest of the URL into the prose as literal text.
"""
function delink(md::AbstractString)
    urls = String[]
    io = IOBuffer()
    i, n = firstindex(md), lastindex(md)
    while i <= n
        c = md[i]
        if c != '['
            write(io, c); i = nextind(md, i); continue
        end
        # label
        j = nextind(md, i); depth = 0; close = 0
        while j <= n
            md[j] == '[' && (depth += 1)
            if md[j] == ']'
                depth == 0 && (close = j; break)
                depth -= 1
            end
            j = nextind(md, j)
        end
        k = close == 0 ? 0 : nextind(md, close)
        if close == 0 || k > n || md[k] != '('
            write(io, c); i = nextind(md, i); continue
        end
        # target, with balanced parentheses
        d, m = 1, nextind(md, k)
        while m <= n && d > 0
            md[m] == '(' && (d += 1)
            md[m] == ')' && (d -= 1)
            d == 0 && break
            m = nextind(md, m)
        end
        if d != 0
            write(io, c); i = nextind(md, i); continue
        end
        label = strip(String(md[nextind(md, i):prevind(md, close)]))
        url = String(md[nextind(md, k):prevind(md, m)])
        if startswith(url, "http")
            push!(urls, url)
            write(io, isempty(label) ? "link" : label, " [", string(length(urls)), "]")
        else
            write(io, "[", label, "](", url, ")")
        end
        i = nextind(md, m)
    end
    (String(take!(io)), urls)
end

"Shorten for display; the full URL still rides along in the hyperlink."
function shortlink(u::AbstractString, w::Int = 58)
    length(u) <= w && return u
    u[1:prevind(u, w - 2)] * "…"
end

"OSC 8 hyperlink. Zero width in a real terminal, so it is applied after layout."
osc8(url, text) = string("\e]8;;", url, "\e\\", text, "\e]8;;\e\\")

"Render a node's body at width `w`, cached - markdown is too slow to redo per frame."
function nodelines(n::Node, w::Int)
    n.cw == w && return n.cache
    txt = if n.kind === :md
        body, urls = delink(n.raw)
        n.urls = urls
        isempty(strip(body)) ? "" :
            try
                # Hand Panel Term *markup*, not ANSI. apply_style here would
                # bake in escape codes that Panel then counts toward the line
                # width, wrapping content that already fits and overflowing the
                # pane height into "... content omitted ...".
                string(Term.TermMarkdown.parse_md(
                    Markdown.parse(body); width = max(20, w - 2)))
            catch e
                # A bad comment must not take the pane down, but the reason has
                # to be visible: swallowing it hid that markdown was not
                # rendering at all for want of an `import Term`.
                MD_WARN[] = first(sprint(showerror, e), 120)
                esc(body)
            end
    elseif n.kind === :diff
        join((diffline(l) for l in split(n.raw, "\n")), "\n")
    else
        esc(n.raw)
    end
    lines = isempty(txt) ? String[] : split(txt, "\n")
    if n.kind === :md && !isempty(n.urls)
        push!(lines, "")
        for (i, u) in enumerate(n.urls)
            push!(lines, string("{dim}[", i, "]{/dim} {blue}",
                                esc(shortlink(u, max(20, w - 8))), "{/blue}"))
        end
    end
    n.cache = lines
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
    st.nrow = clamp(st.nrow, 1, max(1, length(rrows)))
    if st.focus === :detail && !isempty(rrows)
        # Mark the cursor row so it is visible while paging through a body,
        # not only when it lands on a header.
        (ni, hdr, txt) = rrows[st.nrow]
        rrows[st.nrow] = (ni, hdr, string("{on_gray23}", txt, "{/on_gray23}"))
    end
    rvis, st.ntop = window(rrows, st.nrow, st.ntop, rh - 2)

    it = isempty(st.items) ? nothing : st.items[st.sel]
    ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    total = length(rows(st.nodes, inner(rw)))
    rtitle = string(st.mode === :comments ? "comments" : "diff",
                    it === nothing ? "" : string("  ", it.ref),
                    total > 0 ? string("  ", st.ntop, "-",
                                       min(total, st.ntop + rh - 3), "/", total) : "")

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

    links = Pair{String,String}[]
    for n in st.nodes, u in n.urls
        push!(links, shortlink(u, max(20, inner(rw) - 8)) => u)
    end

    keys = "j/k line · space/b page · n/N node · ↵ fold · tab pane · d diff · o comments · r read · s snooze · q"
    ftxt = !isempty(MD_WARN[]) ? "markdown: " * MD_WARN[] :
           isempty(st.status) ? keys : st.status
    foot = "{dim}" * esc(rpad(fit1(ftxt, w), w)) * "{/dim}"
    frame = string(side ? string(left * right) : string(left / right),
                   "\n", apply_style(foot))
    linkify(frame, links)
end

"""
    linkify(frame, links) -> String

Wrap each rendered short URL in an OSC 8 hyperlink pointing at the full one.

Done last, on the finished frame, because OSC 8 sequences are invisible to the
terminal but not to Term's width accounting - injecting them earlier would wrap
lines that fit. The display form is kept short enough that Term never splits it
across lines, which is what makes a plain textual replacement safe here.
"""
function linkify(frame::AbstractString, links)
    isempty(links) && return frame
    for (disp, full) in links
        (isempty(disp) || !occursin(disp, frame)) && continue
        frame = replace(frame, disp => osc8(full, disp))
    end
    frame
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

"""Start fetching the current item's detail, without waiting for it.

Both sources are slow enough to be felt - a thread is several REST calls and a
diff shells out to `gh` - so doing them inline froze the whole UI on every
cursor move. `@async` rather than a thread: the subprocess and HTTP reads both
yield, and keeping it on one thread means the state below needs no locking.
"""
function load_nodes!(st::BState)
    isempty(st.items) && return
    it = st.items[st.sel]
    mode = st.mode
    key = string(it.url, ":", mode)
    (st.loaded == key || st.pendkey == key) && return
    st.pending = @async (mode === :comments ? comment_nodes(it) : diff_nodes(it))
    st.pendkey = key
    st.nodes = Node[]
    st.nrow = 1; st.ntop = 1
    st.status = "loading " * it.ref * "…"
end

"Adopt a finished fetch. Returns true when the frame needs redrawing."
function collect_pending!(st::BState)
    st.pending === nothing && return false
    istaskdone(st.pending) || return false
    st.nodes = try
        fetch(st.pending)
    catch e
        [Node("load failed", first(sprint(showerror, e), 300), :plain, true)]
    end
    st.loaded = st.pendkey
    st.pending = nothing
    st.pendkey = ""
    st.nrow = 1; st.ntop = 1; st.status = ""
    true
end

# --- interaction -----------------------------------------------------------

"Node index owning the cursor row, so folding works from anywhere in a body."
function curnode(st::BState, w::Int)
    rs = rows(st.nodes, w)
    isempty(rs) && return 0
    rs[clamp(st.nrow, 1, length(rs))][1]
end

"Row index of node `i`'s header - where the cursor lands after folding."
function headerrow(st::BState, i::Int, w::Int)
    rs = rows(st.nodes, w)
    j = findfirst(r -> r[1] == i && r[2], rs)
    j === nothing ? 1 : j
end

"Move the cursor to the next (`+1`) or previous (`-1`) node header."
function jumpnode(st::BState, dir::Int, w::Int)
    rs = rows(st.nodes, w)
    isempty(rs) && return
    hdrs = [j for j in eachindex(rs) if rs[j][2]]
    isempty(hdrs) && return
    st.nrow = if dir > 0
        something(findfirst(>(st.nrow), hdrs), length(hdrs)) |> i -> hdrs[i]
    else
        something(findlast(<(st.nrow), hdrs), 1) |> i -> hdrs[i]
    end
end

"""
    browse(items, title)

Full-screen two-pane loop. Returns when the user backs out.

Runs on the alternate screen so the scrollback the user came from is still
there afterwards, and restores the terminal on any exit path - an exception
here would otherwise leave the shell in raw mode with no cursor.
"""
function browse(items::Vector{Item}, title::AbstractString)
    isempty(items) && (println("\n  nothing in ", title, "\n"); return)
    st = BState(collect(items), String(title))
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm"), stdin, stdout, stderr)
    print("\e[?1049h\e[?25l")                     # alt screen, hide cursor
    REPL.Terminals.raw!(term, true)
    try
        dirty = true
        while true
            h, w = displaysize(stdout)
            load_nodes!(st)
            if dirty
                print("\e[H", replace(render(st, w, h), "\n" => "\e[K\n"), "\e[J")
                dirty = false
            end
            # Poll rather than block in readkey, so a fetch finishing can redraw.
            # bytesavailable avoids a reader task, which would otherwise outlive
            # this loop still holding stdin and steal keys from the lane menu.
            if bytesavailable(stdin) == 0
                collect_pending!(st) ? (dirty = true) : sleep(0.02)
                continue
            end
            dirty = true
            k = REPL.TerminalMenus.readkey(stdin)
            iw = (w >= 110 ? w - clamp(w ÷ 3, 34, 52) : w) - 6
            page = max(1, (w >= 110 ? h - 2 : (h - 2) - max(5, (h - 2) ÷ 3)) - 3)
            if k in (Int('q'), 27)                # q, Esc
                return
            elseif k == Int('\t')
                st.focus = st.focus === :list ? :detail : :list
            elseif st.focus === :list
                if k in (Int('j'), 66);      st.sel = min(length(st.items), st.sel + 1)
                elseif k in (Int('k'), 65);  st.sel = max(1, st.sel - 1)
                elseif k in (Int(' '), 6);   st.sel = min(length(st.items), st.sel + page)
                elseif k in (Int('b'), 2);   st.sel = max(1, st.sel - page)
                elseif k == Int('g');        st.sel = 1
                elseif k == Int('G');        st.sel = length(st.items)
                elseif k in (13, 10);        st.focus = :detail
                end
                st.loaded == string(st.items[st.sel].url, ":", st.mode) || (st.nrow = 1)
            else
                n = length(rows(st.nodes, iw))
                if k in (Int('j'), 66);      st.nrow = min(n, st.nrow + 1)
                elseif k in (Int('k'), 65);  st.nrow = max(1, st.nrow - 1)
                elseif k in (Int(' '), 6);   st.nrow = min(n, st.nrow + page)
                elseif k in (Int('b'), 2);   st.nrow = max(1, st.nrow - page)
                elseif k == Int('g');        st.nrow = 1
                elseif k == Int('G');        st.nrow = n
                elseif k == Int('n');        jumpnode(st, 1, iw)
                elseif k == Int('N');        jumpnode(st, -1, iw)
                elseif k in (13, 10)
                    i = curnode(st, iw)
                    if i > 0
                        st.nodes[i].open = !st.nodes[i].open
                        st.nrow = headerrow(st, i, iw)
                    end
                end
            end
            it = st.items[st.sel]
            if k == Int('d');     st.mode = :diff
            elseif k == Int('o'); st.mode = :comments
            elseif k == Int('r'); Events.mark_read([it.url]); st.status = "marked read"
            elseif k == Int('s'); disarm(it.url); set_fields(it.url, ["snooze" => "on-change"]); st.status = "snoozed"
            end
        end
    finally
        REPL.Terminals.raw!(term, false)
        print("\e[?25h\e[?1049l")
    end
end
