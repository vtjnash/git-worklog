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
    meta::Dict{String,Any}  # hunk file and ranges, expansion counts
end
Node(h, raw, kind, open) =
    Node(h, raw, kind, open, String[], -1, String[], Dict{String,Any}())

# --- filters ---------------------------------------------------------------
#
# The lane menu forced one choice at a time and made you back out to change it.
# The same information reads better as tag sets applied to a single list: state
# is exclusive so it behaves as a radio group, while categories and repos are
# additive and behave as checkboxes.

const STATES = [(:active, "active"), (:unread, "unread"),
                (:snoozed, "snoozed"), (:backlog, "backlog"), (:all, "all")]

mutable struct Filters
    state::Symbol
    buckets::Set{String}      # empty means every category
    repos::Set{String}        # empty means every repo
end
Filters() = Filters(:active, Set{String}(), Set{String}())

"An empty tag set means 'no restriction', so a fresh filter shows everything."
function matches(f::Filters, it::Item, unread::Set{String})
    st = f.state
    st === :unread  && !(it.url in unread) && return false
    st === :snoozed && !it.snoozed && return false
    st === :backlog && !it.backlog && return false
    st === :active  && (it.snoozed || it.backlog) && return false
    isempty(f.buckets) || it.bucket in f.buckets || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    true
end

apply_filters(f, all, unread) = [it for it in all if matches(f, it, unread)]

"""Rows for the filter pane: the radio group, then the two checkbox groups.

Counts are computed against the other axes only, so a category shows how many
items selecting it would actually add rather than a total that ignores the rest
of the filter.
"""
function filter_rows(st)
    f, rows = st.filters, Tuple{Symbol,String,String}[]
    push!(rows, (:head, "", "state"))
    for (k, name) in STATES
        probe = Filters(k, f.buckets, f.repos)
        n = count(it -> matches(probe, it, st.unread), st.all)
        push!(rows, (:state, string(k), string(f.state === k ? "(•) " : "( ) ",
                                              rpad(name, 10), n)))
    end
    for (axis, label, values) in ((:bucket, "category", st.buckets),
                                  (:repo, "repo", st.repos))
        push!(rows, (:head, "", ""))
        push!(rows, (:head, "", label))
        sel = axis === :bucket ? f.buckets : f.repos
        for v in values
            probe = axis === :bucket ? Filters(f.state, Set([v]), f.repos) :
                                       Filters(f.state, f.buckets, Set([v]))
            n = count(it -> matches(probe, it, st.unread), st.all)
            n == 0 && !(v in sel) && continue
            push!(rows, (axis, v, string(v in sel ? "[x] " : "[ ] ",
                                         rpad(first(v, 22), 24), n)))
        end
    end
    rows
end

"Toggle whatever the filter cursor is on; radio rows replace, checkboxes flip."
function toggle_filter!(st)
    rows = filter_rows(st)
    st.frow = clamp(st.frow, 1, length(rows))
    (axis, val, _) = rows[st.frow]
    if axis === :state
        st.filters.state = Symbol(val)
    elseif axis === :bucket
        val in st.filters.buckets ? delete!(st.filters.buckets, val) :
                                    push!(st.filters.buckets, val)
    elseif axis === :repo
        val in st.filters.repos ? delete!(st.filters.repos, val) :
                                  push!(st.filters.repos, val)
    else
        return false
    end
    refilter!(st)
    true
end

function refilter!(st)
    keep = isempty(st.items) ? "" : st.items[st.sel].url
    st.items = apply_filters(st.filters, st.all, st.unread)
    i = findfirst(x -> x.url == keep, st.items)
    st.sel = i === nothing ? 1 : i          # stay on the same item when possible
    st.top = 1
end

"One-line summary of what is applied, for the frame title."
function filter_summary(f)
    parts = [string(f.state)]
    isempty(f.buckets) || push!(parts, join(sort(collect(f.buckets)), "+"))
    isempty(f.repos) || push!(parts, join([last(split(r, '/')) for r in sort(collect(f.repos))], "+"))
    join(parts, " · ")
end

mutable struct BState <: View
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
    all::Vector{Item}              # unfiltered
    unread::Set{String}
    filters::Filters
    buckets::Vector{String}
    repos::Vector{String}
    lmode::Symbol                  # :items | :filters
    frow::Int
    wake::Any                      # set by the controller; called when a fetch lands
end
function BState(all::Vector{Item}, title, unread = Set{String}())
    buckets = sort(unique(it.bucket for it in all))
    repos = sort(unique(it.repo for it in all))
    st = BState(Item[], String(title), 1, 1, Node[], 1, 1, :list, :comments, "", "",
                nothing, "", collect(all), unread, Filters(), buckets, repos, :items, 2,
                nothing)
    refilter!(st)
    st
end

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

const AB, AD, AR = "\e[1m", "\e[2m", "\e[0m"

function diffline(l)
    # File headers must be tested before the bare +/- cases, or `+++`/`---`
    # colour as additions and deletions.
    startswith(l, "@@") && return "\e[36m" * l * AR
    (startswith(l, "+++") || startswith(l, "---") || startswith(l, "index ")) &&
        return AD * l * AR
    startswith(l, "+") && return "\e[32m" * l * AR
    startswith(l, "-") && return "\e[31m" * l * AR
    String(l)
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
                # Term to ANSI, then undo its brace doubling: parse_md escapes
                # `{` as `{{` and nothing downstream collapses it, so Julia type
                # signatures reach the screen as `Tuple{{Type{{S{{N, Tup}}}`.
                # Safe here because apply_style has already consumed the markup.
                a = apply_style(string(Term.TermMarkdown.parse_md(
                        Markdown.parse(body); width = max(20, w))))
                replace(a, "{{" => "{", "}}" => "}")
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
    # Wrap here rather than trusting Term, which emitted 232 display columns for
    # a requested width of 90 on any line holding inline code.
    lines = String[]
    for l in (isempty(txt) ? String[] : split(txt, "\n"))
        append!(lines, awidth(l) <= w ? [String(l)] : awrap(String(l), w))
    end
    if n.kind === :md && !isempty(n.urls)
        push!(lines, "")
        for (i, u) in enumerate(n.urls)
            push!(lines, string(AD, "[", i, "]", AR, " \e[34m",
                                shortlink(u, max(20, w - 8)), AR))
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
        htxt = afit(string(n.open ? "▾ " : "▸ ", n.header), w)
        u = get(n.meta, "url", "")
        push!(out, (i, true, string(AB, isempty(u) ? htxt : osc8(u, htxt), AR)))
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
    pane(lines, w, h, title, focused) -> Vector{String}

Draw one bordered pane, every row exactly `w` display columns.

Done by hand rather than with Term.Panel, which measures markup instead of what
prints: escaped braces and embedded ANSI both inflated its width accounting, so
content that fit was wrapped and the pane then elided its own tail.
"""
function pane(lines::Vector{String}, w::Int, h::Int, title::AbstractString, focused::Bool)
    bw = focused ? "\e[1m" : "\e[2m"
    R = "\e[0m"
    inner = w - 4
    t = afit(String(title), max(0, inner - 4))
    # "╭─ " + title + " " + bar + "╮" must total w, so the filler is w-5-|title|.
    bar = "─"^max(0, w - 5 - awidth(t))
    out = [string(bw, "╭─ ", R, focused ? "\e[1m" : "\e[2m", t, R, bw, " ", bar, "╮", R)]
    for i in 1:(h - 2)
        c = i <= length(lines) ? lines[i] : ""
        push!(out, string(bw, "│", R, " ", apad(afit(c, inner), inner), " ", bw, "│", R))
    end
    push!(out, string(bw, "╰", "─"^(w - 2), "╯", R))
    out
end

"""
    render(st, w, h) -> String

Pure. Side by side when the terminal is wide enough, stacked otherwise, so a
narrow window degrades rather than truncating the detail into uselessness.
"""
function render_frame(st::BState, w::Int, h::Int)
    side = w >= 110
    lw = side ? clamp(w ÷ 3, 34, 52) : w
    rw = side ? w - lw : w
    # title bar + panes + footer must total h exactly, or the frame leaves a
              # dead row at the bottom of the terminal.
    bodyh = max(6, h - 2)
    lh = side ? bodyh : max(5, bodyh ÷ 3)
    rh = side ? bodyh : bodyh - lh

    inner(width) = width - 4      # our box: 1 border + 1 pad, each side
    st.sel = clamp(st.sel, 1, max(1, length(st.items)))
    if st.lmode === :filters
        frows = filter_rows(st)
        st.frow = clamp(st.frow, 1, max(1, length(frows)))
        lrows = Tuple{Int,Bool,String}[]
        for (j, (axis, _, text)) in enumerate(frows)
            on = j == st.frow && st.focus === :list && axis !== :head
            push!(lrows, (j, true, string(axis === :head ? AB : on ? "\e[1;37m" : AD,
                                          afit(text, inner(lw)), AR)))
        end
        lvis, st.top = window(lrows, st.frow, st.top, lh - 2)
        ltitle = "filters"
    else
    lrows = Tuple{Int,Bool,String}[]
    for i in 1:length(st.items)
        it_ = st.items[i]
        on = i == st.sel && st.focus === :list
        txt = afit(string(it_.track == "close" ? "*" : " ", it_.ref, " ", it_.title),
                   inner(lw))
        push!(lrows, (i, true, string(on ? "\e[1;37m" : AD, txt, AR)))
    end
    lvis, st.top = window(lrows, st.sel, st.top, lh - 2)
    ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    end

    rrows = rows(st.nodes, inner(rw))
    st.nrow = clamp(st.nrow, 1, max(1, length(rrows)))
    if st.focus === :detail && !isempty(rrows)
        # Mark the cursor row so it is visible while paging through a body,
        # not only when it lands on a header.
        (ni, hdr, txt) = rrows[st.nrow]
        rrows[st.nrow] = (ni, hdr, string("\e[48;5;236m", txt, AR))
    end
    rvis, st.ntop = window(rrows, st.nrow, st.ntop, rh - 2)

    it = isempty(st.items) ? nothing : st.items[st.sel]
    ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    total = length(rows(st.nodes, inner(rw)))
    rtitle = string(st.mode === :comments ? "comments" : "diff",
                    it === nothing ? "" : string("  ", it.ref),
                    total > 0 ? string("  ", st.ntop, "-",
                                       min(total, st.ntop + rh - 3), "/", total) : "")

    left = pane(lvis, lw, lh, ltitle, st.focus === :list)
    right = pane(rvis, rw, rh, rtitle, st.focus === :detail)

    links = Pair{String,String}[]
    for n in st.nodes, u in n.urls
        push!(links, shortlink(u, max(20, inner(rw) - 8)) => u)
    end

    keys = string("[", filter_summary(st.filters), "]  f filters · j/k line · space/b page · n/N node · ↵ fold · tab pane · d diff · o comments · r read · [/] context · e edit · s snooze · q")
    ftxt = !isempty(MD_WARN[]) ? "markdown: " * MD_WARN[] :
           isempty(st.status) ? keys : st.status
    foot = string(AD, afit(ftxt, w), AR)
    body = side ? [string(left[i], right[i]) for i in 1:min(length(left), length(right))] :
                  vcat(left, right)
    # Row 1 is a title bar so that selecting the top line in tmux - which
    # scrolls the pane to make room for its own status line - never lands on
    # content. Everything real starts at row 2.
    bar = if it === nothing
        string(" worklog  ", AD, length(st.items), " items", AR)
    else
        link = osc8(it.url, string(it.ref, "  ", it.title))
        string(" ", AB, link, AR, "  ", AD, "[", filter_summary(st.filters), "]", AR)
    end
    frame = join(vcat([apad(afit(bar, w), w)], body, [apad(foot, w)]), "\n")
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

"TTL for a cached thread or diff. Short: these are things people are actively
replying to, and a stale comment list is worse than a slow one."
const DETAIL_TTL = Ref(600.0)

function comment_nodes(it::Item)
    local body, cs
    try
        key = "thread:" * it.url
        hit = cache_get(key, DETAIL_TTL[])
        if hit === nothing
            body, cs = Events.thread(it.url; limit = 30)
            cache_put(key, (body = body, comments = cs))
        else
            body, cs = hit[1].body, hit[1].comments
        end
    catch e
        return [Node("could not load thread", first(sprint(showerror, e), 200), :plain, true)]
    end
    ns = Node[]
    who0 = get(something(get(body, "user", nothing), Dict{String,Any}()), "login", "?")
    btxt = strip(replace(nz(get(body, "body", nothing), ""), "\r\n" => "\n"))
    if !isempty(btxt)
        n0 = Node(string(nz(who0, "?"), " opened this"), btxt, :md, true)
        n0.meta["url"] = String(nz(get(body, "html_url", nothing), it.url))
        push!(ns, n0)
    end
    for c in cs
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
        at = first(String(c["created_at"]), 16)
        txt = strip(replace(nz(get(c, "body", nothing), ""), "\r\n" => "\n"))
        peek = strip(first(replace(txt, r"\s+" => " "), 58))
        nc = Node(string(nz(who, "?"), "  ", at, "   ", peek), txt, :md, true)
        # Anchored, so following it lands on this comment rather than the top.
        nc.meta["url"] = String(nz(get(c, "html_url", nothing), it.url))
        push!(ns, nc)
    end
    isempty(ns) ? [Node("no comments", "", :plain, true)] : ns
end

"""One node per hunk, not per file.

A file-sized node makes n/N step over whole files, which is the wrong grain for
reading a change: hunks are the units you actually move between. The file name
stays in each hunk's header so the context is never lost.
"""
function diff_nodes(it::Item)
    # Issues have no diff, and asking gh for one fails with a GraphQL error
    # rather than an empty result. The assigned lane is full of them.
    it.is_pr || return [Node("no diff - this is an issue, not a pull request",
                             "", :plain, true)]
    txt = try
        key = string("diff:", it.repo, "#", it.number)
        hit = cache_get(key, DETAIL_TTL[])
        hit === nothing ?
            cache_put(key, read(`gh pr diff $(it.number) --repo $(it.repo)`, String)) :
            String(hit[1])
    catch e
        return [Node("no diff (not a PR, or gh failed)",
                     first(sprint(showerror, e), 200), :plain, true)]
    end
    ns, file, buf, hdr = Node[], "", String[], ""
    pending_range = (0, 0)
    flush!() = if !isempty(hdr)
        adds = count(l -> startswith(l, "+") && !startswith(l, "+++"), buf)
        dels = count(l -> startswith(l, "-") && !startswith(l, "---"), buf)
        n = Node(string(file, "  ", hdr, "  +", adds, " -", dels),
                 join(buf, "\n"), :diff, true)
        n.meta["file"] = file
        n.meta["start"] = pending_range[1]
        n.meta["count"] = pending_range[2]
        n.meta["body"] = join(buf, "\n")      # the hunk itself, without context
        n.meta["up"] = 0
        n.meta["down"] = 0
        n.meta["url"] = string(it.url, "/files")
        push!(ns, n)
    end
    for l in split(txt, "\n")
        if startswith(l, "diff --git")
            flush!(); hdr = ""; buf = String[]
            file = replace(String(last(split(l, " "))), r"^b/" => "")
        elseif startswith(l, "@@")
            flush!()
            m = match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", String(l))
            rng = m === nothing ? (0, 0) :
                  (parse(Int, m[3]), m[4] === nothing ? 1 : parse(Int, m[4]))
            hdr = string("@@ ", rng[1], ",", rng[2], " @@")
            pending_range = rng
            buf = String[]
        elseif !isempty(hdr)
            push!(buf, String(l))
        end
    end
    flush!()
    isempty(ns) ? [Node("empty diff", "", :plain, true)] : ns
end

function load_nodes!(st::BState)
    isempty(st.items) && return
    it = st.items[st.sel]
    mode = st.mode
    key = string(it.url, ":", mode)
    (st.loaded == key || st.pendkey == key) && return
    st.pending = @async begin
        r = try
            mode === :comments ? comment_nodes(it) : diff_nodes(it)
        finally
            st.wake === nothing || st.wake()   # redraw as soon as this lands
        end
        r
    end
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

render(st::BState, w::Int, h::Int) = render_frame(st, w, h)

"Adopt a finished fetch when the controller wakes us."
onwake!(st::BState) = collect_pending!(st)

"""
    browse(items, title, unread)

Open the browser under a controller that owns stdin for the whole run.
"""
function browse(items::Vector{Item}, title::AbstractString, unread = Set{String}())
    isempty(items) && (println("\n  nothing in ", title, "\n"); return 0)
    st = BState(collect(items), String(title), unread)
    ctrl = Controller()
    st.wake = () -> wake!(ctrl)
    run!(ctrl, st)
end

"""
    handle!(st, k, ctrl) -> Symbol

One keystroke. Returns `:quit` to leave, `:ok` otherwise; the controller
redraws after every key.
"""
function handle!(st::BState, k::Int, ctrl::Controller)
    h, w = displaysize(stdout)
    load_nodes!(st)
    iw = (w >= 110 ? w - clamp(w ÷ 3, 34, 52) : w) - 6
    page = max(1, (w >= 110 ? h - 2 : (h - 2) - max(5, (h - 2) ÷ 3)) - 3)
    if k == Int('q')
        return :quit          # Escape no longer quits: it heads key sequences
    elseif k == Int('\t')
        st.focus = st.focus === :list ? :detail : :list
    elseif k == Int('f')
        st.lmode = st.lmode === :filters ? :items : :filters
        st.focus = :list
    elseif st.focus === :list && st.lmode === :filters
        nf = length(filter_rows(st))
        if k in (Int('j'), 66);         st.frow = min(nf, st.frow + 1)
        elseif k in (Int('k'), 65);     st.frow = max(1, st.frow - 1)
        elseif k in (Int(' '), 13, 10); toggle_filter!(st)
        elseif k == Int('c');           st.filters = Filters(); refilter!(st)
        end
    elseif st.focus === :list
        if k in (Int('j'), 66);     st.sel = min(length(st.items), st.sel + 1)
        elseif k in (Int('k'), 65); st.sel = max(1, st.sel - 1)
        elseif k in (Int(' '), 6);  st.sel = min(length(st.items), st.sel + page)
        elseif k in (Int('b'), 2);  st.sel = max(1, st.sel - page)
        elseif k == Int('g');       st.sel = 1
        elseif k == Int('G');       st.sel = length(st.items)
        elseif k in (13, 10);       st.focus = :detail
        end
        isempty(st.items) ||
            st.loaded == string(st.items[st.sel].url, ":", st.mode) || (st.nrow = 1)
    else
        n = length(rows(st.nodes, iw))
        if k in (Int('j'), 66);     st.nrow = min(n, st.nrow + 1)
        elseif k in (Int('k'), 65); st.nrow = max(1, st.nrow - 1)
        elseif k in (Int(' '), 6);  st.nrow = min(n, st.nrow + page)
        elseif k in (Int('b'), 2);  st.nrow = max(1, st.nrow - page)
        elseif k == Int('g');       st.nrow = 1
        elseif k == Int('G');       st.nrow = n
        elseif k == Int('n');       jumpnode(st, 1, iw)
        elseif k == Int('N');       jumpnode(st, -1, iw)
        elseif k in (13, 10)
            i = curnode(st, iw)
            if i > 0
                st.nodes[i].open = !st.nodes[i].open
                st.nrow = headerrow(st, i, iw)
            end
        end
    end
    (st.lmode === :filters || isempty(st.items)) && return :ok
    it = st.items[clamp(st.sel, 1, length(st.items))]

    # Context expansion and the editor both need a local checkout. Ask for it the
    # first time it is actually needed, rather than as up-front configuration.
    needs_repo(action) = push_view!(ctrl, PromptView(
        "Local checkout for $(it.repo)",
        "Path to a clone or worktree. It is resolved to the main .git, so any " *
        "worktree of the repository will do.",
        p -> begin
            try
                r = register_repo!(it.repo, p)
                st.status = string("pinned ", it.repo, " -> ", r.path,
                                   r.matched ? "" : "  (remote does not match)")
                action()
            catch e
                st.status = "could not pin: " * first(sprint(showerror, e), 80)
            end
        end))

    if k in (Int('['), Int(']')) && st.mode === :diff
        i = curnode(st, iw)
        if i > 0
            dir = k == Int('[') ? -1 : 1
            retry_expand = () -> begin
                rr = expand_hunk!(st.nodes[i], it, dir)
                st.status = rr isa String ? rr : ""
            end
            r = expand_hunk!(st.nodes[i], it, dir)
            r === :needs_repo ? needs_repo(retry_expand) :
                (st.status = r isa String ? r : "")
        end
        return :ok
    elseif k == Int('e')
        retry_edit = () -> (rr = open_editor(it); st.status = rr isa String ? rr : "")
        r = open_editor(it)
        r === :needs_repo ? needs_repo(retry_edit) : (st.status = r isa String ? r : "")
        return :ok
    end

    if k == Int('d');     st.mode = :diff
    elseif k == Int('o'); st.mode = :comments
    elseif k == Int('r'); Events.mark_read([it.url]); st.status = "marked read"
    elseif k == Int('s'); disarm(it.url); set_fields(it.url, ["snooze" => "on-change"])
                          st.status = "snoozed"
    end
    load_nodes!(st)
    :ok
end

# --- context expansion ------------------------------------------------------

"Head commit of a pull request, cached: expansion needs the file as it will be."
function head_sha(it::Item)
    key = string("headsha:", it.repo, "#", it.number)
    hit = cache_get(key, 86_400.0)
    hit === nothing || return String(hit[1])
    out = try
        strip(read(`gh pr view $(it.number) --repo $(it.repo) --json headRefOid -q .headRefOid`,
                   String))
    catch
        ""
    end
    cache_put(key, out)
    String(out)
end

"""
    expand_hunk!(node, it, dir, n) -> status

Widen a hunk by `n` lines above (`dir < 0`) or below (`dir > 0`), reading the
file from the pinned local checkout rather than the API - the objects are
already there, so expanding repeatedly costs nothing after the first fetch.
"""
function expand_hunk!(node::Node, it::Item, dir::Int, n::Int = 10)
    node.kind === :diff && haskey(node.meta, "file") ||
        return "not a hunk"
    repo = repo_path(it.repo)
    repo === nothing && return :needs_repo
    sha = head_sha(it)
    isempty(sha) && return "could not determine the head commit"
    ensure_commit!(repo, sha, it.number) ||
        return "commit $(first(sha, 8)) is not in $repo and could not be fetched"
    lines = file_at(repo, sha, node.meta["file"])
    lines === nothing && return "$(node.meta["file"]) is absent at $(first(sha, 8))"

    start, count = node.meta["start"], node.meta["count"]
    up = node.meta["up"] + (dir < 0 ? n : 0)
    down = node.meta["down"] + (dir > 0 ? n : 0)
    lo = max(1, start - up)
    hi = min(length(lines), start + count - 1 + down)
    node.meta["up"] = start - lo
    node.meta["down"] = hi - (start + count - 1)

    pre = [string(" ", lines[i]) for i in lo:(start - 1)]
    post = [string(" ", lines[i]) for i in (start + count):hi]
    node.raw = join(vcat(pre, split(node.meta["body"], "\n"), post), "\n")
    node.cw = -1                                    # force a re-render
    node.header = string(node.meta["file"], "  @@ ", start, ",", count, " @@",
                         node.meta["up"] > 0 ? string("  ↑", node.meta["up"]) : "",
                         node.meta["down"] > 0 ? string("  ↓", node.meta["down"]) : "")
    ""
end

# --- editor -----------------------------------------------------------------

"""Open a checkout of this pull request's branch in VS Code.

Prefers a worktree already on that branch, since that is the copy the user is
most likely to have been working in; otherwise falls back to the main checkout.
"""
function open_editor(it::Item)
    repo = repo_path(it.repo)
    repo === nothing && return :needs_repo
    Sys.which("code") === nothing && return "`code` is not on PATH"
    branch = try
        strip(read(`gh pr view $(it.number) --repo $(it.repo) --json headRefName -q .headRefName`,
                   String))
    catch
        ""
    end
    target = repo
    for (path, br) in worktrees(repo)
        if !isempty(branch) && br == branch
            target = path
            break
        end
    end
    try
        run(pipeline(`code $target`; stdout = devnull, stderr = devnull); wait = false)
    catch e
        return "could not launch code: " * first(sprint(showerror, e), 80)
    end
    string("opened ", target, isempty(branch) ? "" : string(" (", branch, ")"))
end
