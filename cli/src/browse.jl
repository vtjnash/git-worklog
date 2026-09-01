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
    srcs::Vector{Tuple{Int,String}}  # per cached row: which display row of its
                                     # logical line it is, and that line's plain
                                     # text - together, what a yank rebuilds
    depth::Int              # nesting, drawn as indentation. The list is flat -
                            # a `<details>` block is a sibling that draws inset
                            # rather than a child, which is all the nesting the
                            # content here actually has
end
Node(h, raw, kind, open, depth = 0) =
    Node(h, raw, kind, open, String[], -1, String[], Dict{String,Any}(),
         Tuple{Int,String}[], depth)

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
    labels::Set{String}       # empty means every label
end
Filters() = Filters(:active, Set{String}(), Set{String}(), Set{String}())

"Does this item belong to one of the five exclusive states?"
function state_ok(state::Symbol, it::Item, unread::Set{String})
    state === :unread  && return it.url in unread
    state === :snoozed && return it.snoozed
    state === :backlog && return it.backlog
    state === :active  && return !(it.snoozed || it.backlog)
    true                                              # :all
end

"An empty tag set means 'no restriction', so a fresh filter shows everything."
function matches(f::Filters, it::Item, unread::Set{String})
    state_ok(f.state, it, unread) || return false
    isempty(f.buckets) || it.bucket in f.buckets || return false
    isempty(f.repos)   || it.repo in f.repos     || return false
    isempty(f.labels)  || any(in(f.labels), it.labels) || return false
    true
end

"""
    axis_counts(st) -> (states, buckets, repos, labels)

How many items each filter value would select, in one pass over the items.

Every count is against the *other* axes only - a category shows what selecting
it would add, not a total that ignores the rest of the filter - so there are
four different predicates over the same item, and computing them together is
what makes this one pass instead of one per row. It was a pass per row: 93 rows
over 2050 items came to 190,650 `matches` calls per build and two builds per
keystroke, which made the filter pane the only part of the UI with visible lag -
128ms a frame against 0.7ms for the item list.
"""
function axis_counts(st)
    f = st.filters
    states = Dict{Symbol,Int}()
    buckets = Dict{String,Int}()
    repos = Dict{String,Int}()
    labels = Dict{String,Int}()
    bump!(d, k) = d[k] = get(d, k, 0) + 1
    for it in st.all
        bok = isempty(f.buckets) || it.bucket in f.buckets
        rok = isempty(f.repos)   || it.repo in f.repos
        lok = isempty(f.labels)  || any(in(f.labels), it.labels)
        sok = state_ok(f.state, it, st.unread)
        if bok && rok && lok
            for (k, _) in STATES
                state_ok(k, it, st.unread) && bump!(states, k)
            end
        end
        sok && rok && lok && bump!(buckets, it.bucket)
        sok && bok && lok && bump!(repos, it.repo)
        if sok && bok && rok
            for l in it.labels
                bump!(labels, l)
            end
        end
    end
    (states, buckets, repos, labels)
end

apply_filters(f, all, unread) = [it for it in all if matches(f, it, unread)]

"""Rows for the filter pane: the radio group, then the two checkbox groups.

Counts are computed against the other axes only, so a category shows how many
items selecting it would actually add rather than a total that ignores the rest
of the filter.
"""
function filter_rows(st)
    f, rows = st.filters, Tuple{Symbol,String,String}[]
    (nstate, nbucket, nrepo, nlabel) = axis_counts(st)
    push!(rows, (:head, "", "state"))
    for (k, name) in STATES
        n = get(nstate, k, 0)
        push!(rows, (:state, string(k), string(f.state === k ? "(•) " : "( ) ",
                                              rpad(name, 10), n)))
    end
    for (axis, label, values, tally) in ((:bucket, "category", st.buckets, nbucket),
                                         (:repo, "repo", st.repos, nrepo),
                                         (:label, "label", st.labels, nlabel))
        push!(rows, (:head, "", ""))
        push!(rows, (:head, "", label))
        sel = axis === :bucket ? f.buckets : axis === :repo ? f.repos : f.labels
        for v in values
            n = get(tally, v, 0)
            # A label nothing here carries is noise - and there are hundreds of
            # them across this many repos. The zero-count skip is what keeps the
            # list to the ones worth seeing.
            n == 0 && !(v in sel) && continue
            push!(rows, (axis, v, string(v in sel ? "[x] " : "[ ] ",
                                         rpad(first(v, 22), 24), n)))
        end
    end
    rows
end

"""First selectable row of each group in the filter pane.

The groups are what you actually move between - state, category, repo, label -
and with a couple of hundred labels the last one is long enough that stepping
into it a row at a time is not stepping into it.
"""
function filter_groups(rows)
    starts, prev_head = Int[], true
    for (j, r) in enumerate(rows)
        ishead = r[1] === :head
        (!ishead && prev_head) && push!(starts, j)
        prev_head = ishead
    end
    starts
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
    elseif axis === :label
        val in st.filters.labels ? delete!(st.filters.labels, val) :
                                   push!(st.filters.labels, val)
    else
        return false
    end
    refilter!(st)
    true
end

"Does this item answer to `/query`? Title or ref, case-insensitively."
hits(it::Item, q::AbstractString) =
    occursin(lowercase(q), lowercase(it.title)) || occursin(lowercase(q), lowercase(it.ref))

function refilter!(st)
    keep = isempty(st.items) ? "" : st.items[st.sel].url
    st.items = apply_filters(st.filters, st.all, st.unread)
    # The text filter sits on top of the tag axes rather than inside `Filters`,
    # so the counts in the filter pane keep describing the tags alone - which is
    # what they are for.
    # Only a search started in the list narrows it. One begun in the thread is
    # about the thread, and should not quietly filter the list out from under
    # the cursor the next time anything rebuilds it.
    (isempty(st.search) || st.searchin !== :list) ||
        (st.items = [it for it in st.items if hits(it, st.search)])
    i = findfirst(x -> x.url == keep, st.items)
    st.sel = i === nothing ? 1 : i          # stay on the same item when possible
    st.top = 1
end

"One-line summary of what is applied, for the frame title."
function filter_summary(f)
    parts = [string(f.state)]
    isempty(f.buckets) || push!(parts, join(sort(collect(f.buckets)), "+"))
    isempty(f.repos) || push!(parts, join([last(split(r, '/')) for r in sort(collect(f.repos))], "+"))
    isempty(f.labels) || push!(parts, join(sort(collect(f.labels)), "+"))
    join(parts, " · ")
end

"""The browser's whole state.

Keyword-constructed, with defaults: it has thirty fields, and the positional
form is a place where two of them get transposed silently. `render` mutates the
scroll offsets and the two geometry readings (`hdr`, `nmeta`) that the mouse
needs, so it is pure in what it returns but not in what it touches.
"""
Base.@kwdef mutable struct BState <: View
    items::Vector{Item} = Item[]
    title::String
    sel::Int = 1
    top::Int = 1
    nodes::Vector{Node} = Node[]
    nrow::Int = 1          # cursor into the flattened rows, not into nodes:
                           # scrolling inside a long comment needs row
                           # granularity, and folding still works because every
                           # row knows which node it belongs to
    ntop::Int = 1
    focus::Symbol = :list           # :list | :detail
    mode::Symbol = :comments        # :comments | :diff | :checks
    loaded::String = ""
    status::String = ""
    pending::Union{Nothing,Task} = nothing   # in-flight fetch; the key loop
    pendkey::String = ""                     # never blocks
    all::Vector{Item}               # unfiltered
    unread::Set{String} = Set{String}()
    filters::Filters = Filters()
    buckets::Vector{String} = String[]
    repos::Vector{String} = String[]
    labels::Vector{String} = String[]
    lmode::Symbol = :items          # :items | :filters
    frow::Int = 2
    wake::Any = nothing             # set by the controller; called when a fetch lands
    hdr::Int = 0           # rows of item title above the nodes in the detail
                           # pane; the mouse needs it to turn a screen row into
                           # an `nrow`, and only `render` knows how tall it got
    nmeta::Int = 0         # metadata lines the pane last drew; it sizes to its
                           # content, so the heights depend on it
    meta::Any = nothing    # Events.itemmeta result for `metakey`, or nothing
    checks::Any = nothing  # check_contexts result, or nothing
    metakey::String = ""
    metapending::Union{Nothing,Task} = nothing
    anchor::Int = 0        # row a drag started on
    sela::Int = 0          # selected range in `nrow` coordinates; 0 for none
    selb::Int = 0
    mouse::Bool = true     # mirrors the controller, for the footer
    search::String = ""    # the live query; "" when no search is running
    searchin::Symbol = :list  # the pane it was started in, and belongs to
    typing::Bool = false   # is the query still being typed?
end
function BState(all::Vector{Item}, title, unread = Set{String}())
    # Labels by how often they appear rather than alphabetically: there are
    # hundreds across this many repos, and the ones reached for constantly
    # should not be somewhere down past "upstream".
    lc = Dict{String,Int}()
    for it in all, l in it.labels
        lc[l] = get(lc, l, 0) + 1
    end
    st = BState(; all = collect(all), title = String(title), unread = unread,
                  buckets = sort(unique(it.bucket for it in all)),
                  repos = sort(unique(it.repo for it in all)),
                  labels = sort(collect(keys(lc)); by = l -> (-lc[l], l)))
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

"""OSC 8 hyperlink, underlined so it reads as one.

Zero width in a real terminal, so it is safe to apply after layout. The
underline is not decoration: terminals differ on whether they mark hyperlinks
themselves, and an unmarked link is one nobody discovers.

Note tmux only forwards OSC 8 from tmux 3.4; older versions strip it, and the
link silently becomes plain text.
"""
osc8(url, text) = string("\e]8;;", url, "\e\\\e[4m", text, "\e[24m\e]8;;\e\\")

"""Markdown to ANSI at one width.

Term is handed *markup*, not ANSI: `apply_style` here would bake in escape codes
that Term then counts toward the line width, wrapping content that already fits.
Its brace doubling is undone afterwards - `parse_md` escapes `{` as `{{` and
nothing downstream collapses it, so Julia type signatures reach the screen as
`Tuple{{Type{{S{{N, Tup}}}`. That is safe here only because `apply_style` has
already consumed the markup.

A bad comment must not take the pane down, but the reason has to be visible:
swallowing it once hid that markdown was not rendering at all, for want of an
`import Term`.
"""
function render_md(body::AbstractString, w::Int)
    try
        a = apply_style(string(Term.TermMarkdown.parse_md(
                Markdown.parse(body); width = max(20, w))))
        replace(a, "{{" => "{", "}}" => "}")
    catch e
        MD_WARN[] = first(sprint(showerror, e), 120)
        esc(body)
    end
end

"Wide enough that no paragraph wraps, narrow enough that a padded box is cheap."
const WIDE_MD = 2000

"""
    unwrap_map(narrow, wide) -> Vector{Tuple{Bool,String}}

For each display line, whether it starts a written line and what that line says.

Term wraps prose itself, at whatever width it is handed, so a paragraph is
already in pieces before `awrap` ever sees it - `awrap` only ever gets the lines
Term declined to wrap. Rendering a second time at a width nothing reaches gives
the unwrapped form, but that render cannot be shown: a code block or a table is
a box, and Term pads the box out to the full width.

So render twice and align the two. Each wide line is matched against as many
narrow lines as it takes to reproduce it, ignoring where the spaces fell. What
fails to match - the boxes, which are the same shape at both widths - stands for
itself, and the walk carries on in step.
"""
function unwrap_map(narrow::Vector{String}, wide::Vector{String})
    norm(s) = replace(strip(astrip(s)), r"\s+" => " ")
    plain(s) = rstrip(astrip(s))
    out = Vector{Tuple{Bool,String}}(undef, length(narrow))
    i, j = 1, 1
    while i <= length(narrow)
        if isempty(norm(narrow[i]))
            # A blank row stands for itself, and takes a blank on the wide side
            # with it: letting one be swallowed into the next paragraph's group
            # puts the two walks out of step for the rest of the comment.
            out[i] = (true, ""); i += 1
            j <= length(wide) && isempty(norm(wide[j])) && (j += 1)
            continue
        end
        if j > length(wide)
            out[i] = (true, plain(narrow[i])); i += 1; continue
        end
        target = norm(wide[j])
        if isempty(target)
            j += 1; continue
        end
        acc, k, hit = "", i, false
        while k <= length(narrow)
            piece = norm(narrow[k])
            isempty(piece) && break
            # Term breaks a long token - a URL, usually - with no space at the
            # break, so rejoining with one does not reproduce the wide line.
            # Try it both ways and take whichever the wide line agrees with.
            cand = if isempty(acc)
                piece
            elseif startswith(target, string(acc, " ", piece))
                string(acc, " ", piece)
            else
                string(acc, piece)
            end
            startswith(target, cand) || break
            acc = cand; k += 1
            acc == target && (hit = true; break)
        end
        if hit
            # The wide line is only worth having when it *joined* several narrow
            # ones - that is the unwrapping. Matched one-to-one they are the
            # same content, and the narrow one is the copy without the padding:
            # a code block is a box, and Term pads the box out to whatever width
            # it was given, so the wide side of a gdb log was handing a yank
            # nineteen hundred columns of spaces with a border on the end.
            src = k - i == 1 ? plain(narrow[i]) : plain(wide[j])
            for t in i:(k - 1)
                out[t] = (t == i, src)
            end
            i = k; j += 1
        else
            out[i] = (true, plain(narrow[i])); i += 1; j += 1
        end
    end
    out
end

"Render a node's body at width `w`, cached - markdown is too slow to redo per frame."
function nodelines(n::Node, w::Int)
    n.cw == w && return n.cache
    local txt::String
    srcline = Tuple{Bool,String}[]     # per line of txt: starts a written line?
    if n.kind === :md
        body, urls = delink(n.raw)
        n.urls = urls
        if isempty(strip(body))
            txt = ""
        else
            txt = render_md(body, w)
            srcline = unwrap_map(String.(split(txt, "\n")),
                                 String.(split(render_md(body, WIDE_MD), "\n")))
        end
    elseif n.kind === :diff
        txt = join((diffline(l) for l in split(n.raw, "\n")), "\n")
    else
        txt = esc(n.raw)
    end
    lines = isempty(txt) ? String[] : String.(split(txt, "\n"))
    # A diff or a plain block is already one line per line of its source, so
    # only markdown needs the alignment above.
    isempty(srcline) && (srcline = [(true, rstrip(astrip(l))) for l in lines])

    # Wrap here rather than trusting Term, which emitted 232 display columns for
    # a requested width of 90 on any line holding inline code.
    #
    # Every row records the written line behind it, and whether it is the first
    # row of it. Both wraps - Term's and ours - are ours to undo when copying;
    # neither is something the reader chose.
    out, srcs = String[], Tuple{Int,String}[]
    for (idx, l) in enumerate(lines)
        (first_of, src) = srcline[idx]
        ws = awidth(l) <= w ? [l] : awrap(l, w)
        for (j, x) in enumerate(ws)
            push!(out, x)
            push!(srcs, (first_of && j == 1 ? 0 : 1, src))
        end
    end
    if n.kind === :md && !isempty(n.urls)
        push!(out, ""); push!(srcs, (0, ""))
        for (i, u) in enumerate(n.urls)
            push!(out, string(AD, "[", i, "]", AR, " \e[34m",
                              shortlink(u, max(20, w - 8)), AR))
            # The whole URL, not the elided form on screen: a shortened link is
            # the one thing on the row that is useless once pasted.
            push!(srcs, (0, string("[", i, "] ", u)))
        end
    end
    n.cache = out
    n.srcs = srcs
    n.cw = w
    n.cache
end

"""One row of a pane.

`text` is what prints. `src` is the written line behind it with the escapes
removed, and `part` is 0 on the first display row of that line and 1 on every
continuation of it.

Those last two are the whole point of owning the mouse. The terminal only ever
saw the wrapped fragments and the pane borders, so a selection made with the
terminal's own copy gives you those. A selection made here is turned back into
the lines as they were written.
"""
struct Row
    node::Int
    header::Bool
    text::String
    src::String
    part::Int
end

"""Flatten open/closed nodes into rows, so selection and scrolling share one space.

Closing a node takes everything nested under it: the list is flat, so "nested"
means the run of nodes deeper than it that follows it. That is what makes a
folded `<details>` disappear with the comment it was written in, and the
outdated review comments disappear with the header that counts them.
"""
function rows(nodes::Vector{Node}, w::Int)
    out = Row[]
    hide = -1                 # while >= 0, skip anything deeper than this
    for (i, n) in enumerate(nodes)
        if hide >= 0
            n.depth > hide && continue
            hide = -1
        end
        pad = " "^(2 * n.depth)
        iw = max(20, w - 2 * n.depth)
        htxt = afit(string(n.open ? "▾ " : "▸ ", n.header), iw)
        u = get(n.meta, "url", "")
        core = string(AB, isempty(u) ? htxt : osc8(u, htxt), AR)
        # A rule out to the edge of the pane, so where one comment ends and the
        # next begins is visible at a glance rather than found by reading. Only
        # at the top level: a nested block should stay subordinate to the
        # comment it was written in, not compete with it.
        if n.depth == 0
            gap = iw - awidth(htxt) - 1
            gap > 2 && (core = string(core, " ", AD, "─"^gap, AR))
        end
        push!(out, Row(i, true, string(pad, core),
                       get(n.meta, "src", astrip(n.header)), 0))
        if !n.open
            hide = n.depth
            continue
        end
        ls = nodelines(n, iw)                # fills n.srcs alongside n.cache
        for (j, l) in enumerate(ls)
            (part, src) = n.srcs[j]
            push!(out, Row(i, false, string(pad, l), src, part))
        end
    end
    out
end

"Vertical slice with the cursor's node kept in view."
function window(rs::Vector{Row}, cur, top, h)
    isempty(rs) && return (String[], 1)
    top = clamp(top, 1, max(1, length(rs)))
    if cur !== nothing
        cur < top && (top = cur)
        cur > top + h - 1 && (top = cur - h + 1)
    end
    top = clamp(top, 1, max(1, length(rs) - h + 1))
    ([r.text for r in rs[top:min(end, top + h - 1)]], top)
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

# --- the metadata pane ------------------------------------------------------

const REV_MARK = Dict("APPROVED" => ("\e[32m", "✓"),
                      "CHANGES_REQUESTED" => ("\e[31m", "✗"),
                      "COMMENTED" => ("\e[2m", "·"),
                      "DISMISSED" => ("\e[2m", "✗"),
                      "PENDING" => ("\e[33m", "…"))

"""
    load_meta!(st)

Fetch what the metadata pane needs for the selected item, off the key loop.

Separate from `load_nodes!` because it does not change with the mode: switching
between the thread, the diff and the checks re-reads the body three times, but
the reviewers and the labels are the same each time.
"""
function load_meta!(st::BState)
    isempty(st.items) && return
    it = st.items[st.sel]
    (st.metakey == it.url || (st.metapending !== nothing && st.metakey == it.url)) && return
    st.metakey = it.url
    st.meta = nothing
    st.checks = nothing
    st.metapending = @async begin
        r = try
            (meta = Events.itemmeta(it.url, it.is_pr),
             checks = it.is_pr ? check_contexts(it.repo, it.number) : nothing)
        catch e
            (meta = nothing, checks = nothing, err = first(sprint(showerror, e), 120))
        finally
            st.wake === nothing || st.wake()
        end
        r
    end
end

function collect_meta!(st::BState)
    st.metapending === nothing && return false
    istaskdone(st.metapending) || return false
    r = try
        fetch(st.metapending)
    catch
        (meta = nothing, checks = nothing)
    end
    st.meta = r.meta
    st.checks = r.checks
    st.metapending = nothing
    true
end

"""Lines for the metadata pane: what is true of this item, rather than what is
in it.

Everything cheap comes from `facts.json` and is on screen immediately; the two
that need a request - who has actually reviewed, and the per-check breakdown -
arrive when `load_meta!` lands and say so until then.
"""
function meta_lines(st::BState, it::Union{Nothing,Item}, w::Int)
    it === nothing && return String[]
    out = String[]
    head(t) = push!(out, string(AB, t, AR))
    kv(k, v) = isempty(string(v)) ? nothing :
               push!(out, string(AD, rpad(k, 10), AR, afit(string(v), max(4, w - 10))))
    wait_ = st.metakey == it.url && st.metapending !== nothing

    if it.is_pr
        dec = it.review_decision
        head(string("reviews", isempty(dec) ? "" :
                    string("  ", dec == "APPROVED" ? GRN :
                                 dec == "CHANGES_REQUESTED" ? RED : YEL,
                           lowercase(replace(dec, "_" => " ")), AR)))
        m = st.meta
        if m === nothing
            push!(out, string(AD, wait_ ? "  loading…" : "  —", AR))
        else
            for r in m.reviews
                (col, mark) = get(REV_MARK, r.state, (AD, "?"))
                push!(out, string("  ", col, mark, AR, " ",
                                  afit(rpad(r.login, 16), max(4, w - 6)),
                                  AD, first(r.at, 10), AR))
            end
            for who in vcat(m.requested, ["@" * t for t in m.teams])
                push!(out, string("  ", YEL, "○", AR, " ", afit(rpad(who, 16), max(4, w - 6)),
                                  AD, "requested", AR))
            end
            isempty(m.reviews) && isempty(m.requested) && isempty(m.teams) &&
                push!(out, string(AD, "  nobody yet", AR))
        end
        it.unresolved > 0 &&
            push!(out, string("  ", YEL, it.unresolved, " unresolved thread",
                              it.unresolved == 1 ? "" : "s", AR))
        push!(out, "")

        head("checks")
        c = st.checks
        if c === nothing
            push!(out, string("  ", isempty(it.ci) ? (wait_ ? "loading…" : "—") :
                              string(get(CI_COLOR, uppercase(it.ci), ""), lowercase(it.ci), AR)))
        else
            tally = Dict{String,Int}()
            for x in c.contexts
                k = uppercase(x.state)
                tally[k] = get(tally, k, 0) + 1
            end
            parts = [string(get(CI_COLOR, k, ""), get(Dict("SUCCESS" => "✓", "FAILURE" => "✗",
                            "ERROR" => "✗", "PENDING" => "…"), k, "·"), " ", n, AR)
                     for (k, n) in sort(collect(tally); by = first)]
            push!(out, string("  ", isempty(parts) ? string(AD, "none", AR) : join(parts, "  ")))
        end
        push!(out, "")
    end

    if !isempty(it.labels)
        head("labels")
        for l in awrap(join(it.labels, ", "), max(8, w - 2))
            push!(out, string("  ", CYA, l, AR))
        end
        push!(out, "")
    end

    kv("author", it.author)
    st.meta === nothing || isempty(st.meta.assignees) ||
        kv("assignee", join(st.meta.assignees, ", "))
    kv("milestone", string(it.milestone,
                           isempty(it.milestone_due) ? "" : string("  (", it.milestone_due, ")")))
    it.is_pr && kv("mergeable", it.mergeable == "CONFLICTING" ?
                                string(RED, "conflicting", AR) : lowercase(it.mergeable))
    it.draft && kv("state", "draft")
    push!(out, "")

    head("tracking")
    kv("bucket", it.bucket)
    kv("level", it.track)
    it.snoozed && kv("snoozed", "yes")
    kv("deadline", it.deadline)
    isempty(it.blocked_on) || kv("blocked", join(it.blocked_on, ", "))
    kv("why", it.why)
    if !isempty(it.note)
        push!(out, string(AD, "note", AR))
        for l in awrap(it.note, max(8, w - 2))
            push!(out, string("  ", l))
        end
    end
    if !isempty(it.agent)
        push!(out, string(AD, "agent", AR))
        for l in awrap(it.agent, max(8, w - 2))
            push!(out, string("  ", l))
        end
    end
    while !isempty(out) && isempty(strip(astrip(last(out))))
        pop!(out)
    end
    out
end

"""Left column width.

Split out because the metadata pane sizes itself to its content, so it has to be
rendered before the heights can be settled - and rendering it needs to know how
wide it will be.
"""
leftw(w::Int) = w >= 110 ? clamp(w ÷ 3, 34, 52) : w

"""
    layout(w, h) -> NamedTuple

Where the two panes sit, in screen coordinates.

Shared by `render_frame` and the mouse handler because the two must agree
exactly: a click only maps to the row under it if the geometry it is measured
against is the geometry that was drawn. This used to be worked out twice, and
the copies had drifted - the key handler measured the detail pane six columns
narrower than the renderer did, so long lines wrapped differently in the two and
`n`, `↵` and `[`/`]` acted on the wrong node once a thread ran past a screenful.

The metadata pane goes under the item list rather than beside the detail: ten
item numbers at a time is plenty, and the thing being read is the one that wants
the full height. `nmeta` is how many lines it has to show, so it takes what it
needs and the list keeps the rest.
"""
function layout(w::Int, h::Int, nmeta::Int = 0)
    side = w >= 110
    lw = leftw(w)
    rw = side ? w - lw : w
    # Row 1 is the title bar and the last two the footer; panes fill the rest.
    # The key help outgrew one line, and letting it truncate hid half of it.
    bodyh = max(6, h - 3)          # title bar, panes, then two rows of footer
    if side
        # The detail keeps the full height; the left column is split between the
        # list and the metadata, which takes what it needs and leaves the rest.
        mh = clamp(nmeta + 2, 3, max(3, bodyh - 5))
        lh, rh = bodyh - mh, bodyh
    else
        lh = clamp(bodyh ÷ 3, 3, 12)
        rest = bodyh - lh
        # Three stacked panes need the room to be three panes. Below that the
        # metadata goes rather than squeezing what is being read.
        mh = rest >= 9 ? clamp(nmeta + 2, 3, rest - 6) : 0
        rh = rest - mh
    end
    (side = side,
     lw = lw, lh = lh, lx = 1, ly = 2,
     mw = lw, mh = mh, mx = 1, my = 2 + lh,
     rw = rw, rh = rh, rx = side ? lw + 1 : 1, ry = side ? 2 : 2 + lh + mh,
     liw = lw - 4, miw = lw - 4, riw = rw - 4,   # inner: 1 border + 1 pad a side
     page = max(1, rh - 3), lpage = max(1, lh - 3))
end

"""
    hitpane(L, x, y) -> (pane, row, col) or nothing

Turn a screen position into a pane and a position inside its content area.
`row` is 1-based within the pane's content, so it indexes the window that pane
last drew; `col` likewise. Borders, the title bar and the footer return nothing.
"""
function hitpane(L, x::Int, y::Int)
    for (which, px, py, pw, ph, iw) in ((:list, L.lx, L.ly, L.lw, L.lh, L.liw),
                                        (:meta, L.mx, L.my, L.mw, L.mh, L.miw),
                                        (:detail, L.rx, L.ry, L.rw, L.rh, L.riw))
        (px <= x <= px + pw - 1 && py + 1 <= y <= py + ph - 2) || continue
        c = x - px - 1
        return 1 <= c <= iw ? (which, y - py, c) : nothing
    end
    nothing
end

"The selected rows in `nrow` coordinates, low to high, or nothing."
selrange(st::BState) = (st.sela == 0 || st.selb == 0) ? nothing :
                       (min(st.sela, st.selb), max(st.sela, st.selb))

clearsel!(st::BState) = (st.sela = 0; st.selb = 0; st.anchor = 0; nothing)

"""Rebuild the selected text from the nodes rather than from the screen.

One line out per *logical* line covered: a paragraph the pane wrapped across
five rows comes back as the single line it was written as, without the borders
between panes and without the colours. A selection that begins partway into a
wrapped line still takes the whole line, because the wrap point is ours.
"""
function selection_text(st::BState, w::Int)
    r = selrange(st)
    r === nothing && return ""
    rs = rows(st.nodes, w)
    isempty(rs) && return ""
    a, b = clamp(r[1], 1, length(rs)), clamp(r[2], 1, length(rs))
    out = String[]
    for i in a:b
        (i == a || rs[i].part == 0) && push!(out, rs[i].src)
    end
    join(out, "\n")
end

const CURBG = "\e[48;5;236m"
const SELBG = "\e[48;5;24m"

"""Lay a background over a whole row, re-arming it after every reset.

A row carries its own colours, and the `\\e[0m` that ends one of them ends the
background too - so a highlight applied naively stops at the first styled word
on the line.
"""
hlrow(s::AbstractString, bg::AbstractString) =
    string(bg, replace(replace(s, AR => AR * bg), NOBG => NOBG * bg), AR)

"Default background, which ends a span highlight without touching the colours."
const NOBG = "\e[49m"
const HITBG = "\e[43m\e[30m"     # a match, dark on yellow

"""Lay a background over given ranges of a row's *plain* characters.

The row carries escapes, so a character offset in the text it prints is not an
offset into the string. This walks it, counting only what would appear, and ends
each span with `\\e[49m` rather than a reset - so a match inside coloured text
keeps its colour, and `hlrow` can still lay the cursor's background over the top.
"""
function hlspan(s::AbstractString, ranges::Vector{UnitRange{Int}}, bg::AbstractString)
    isempty(ranges) && return s
    io, i, n, open_ = IOBuffer(), firstindex(s), 0, false
    while i <= lastindex(s)
        m = match(ESCAPE, SubString(s, i))
        if m !== nothing
            write(io, m.match); i += ncodeunits(m.match); continue
        end
        n += 1
        inspan = any(r -> n in r, ranges)
        inspan && !open_ && write(io, bg)
        !inspan && open_ && write(io, NOBG)
        open_ = inspan
        write(io, s[i]); i = nextind(s, i)
    end
    open_ && write(io, NOBG)
    String(take!(io))
end

"Every place `q` appears in `text`, as ranges of plain characters."
function findhits(text::AbstractString, q::AbstractString)
    out = UnitRange{Int}[]
    (isempty(q) || isempty(text)) && return out
    hay, needle = lowercase(text), lowercase(q)
    n = length(needle)
    start = 1
    cs = collect(hay)
    while start + n - 1 <= length(cs)
        if String(cs[start:(start + n - 1)]) == needle
            push!(out, start:(start + n - 1))
            start += n
        else
            start += 1
        end
    end
    out
end

"""
    render(st, w, h) -> String

Pure. Side by side when the terminal is wide enough, stacked otherwise, so a
narrow window degrades rather than truncating the detail into uselessness.
"""
function render_frame(st::BState, w::Int, h::Int)
    st.sel = clamp(st.sel, 1, max(1, length(st.items)))
    it = isempty(st.items) ? nothing : st.items[st.sel]
    # The pane sizes to its content, so it is rendered before the heights are
    # settled; only its width is known this early, and only its width is needed.
    mlines = meta_lines(st, it, leftw(w) - 4)
    st.nmeta = length(mlines)
    L = layout(w, h, st.nmeta)
    lw, rw, lh, rh, liw, riw = L.lw, L.rw, L.lh, L.rh, L.liw, L.riw
    if st.lmode === :filters
        frows = filter_rows(st)
        st.frow = clamp(st.frow, 1, max(1, length(frows)))
        lrows = Row[]
        for (j, (axis, _, text)) in enumerate(frows)
            on = j == st.frow && st.focus === :list && axis !== :head
            push!(lrows, Row(j, true, string(axis === :head ? AB : on ? "\e[1;37m" : AD,
                                             afit(text, liw), AR), text, 0))
        end
        lvis, st.top = window(lrows, st.frow, st.top, lh - 2)
        ltitle = "filters"
    else
        lrows = Row[]
        for i in 1:length(st.items)
            it_ = st.items[i]
            on = i == st.sel && st.focus === :list
            txt = afit(string(it_.track == "close" ? "*" : " ", it_.ref, " ", it_.title), liw)
            styled = string(on ? "\e[1;37m" : AD, txt, AR)
            (isempty(st.search) || st.searchin !== :list) ||
                (styled = hlspan(styled, findhits(astrip(styled), st.search), HITBG))
            push!(lrows, Row(i, true, styled,
                             string(it_.ref, " ", it_.title), 0))
        end
        lvis, st.top = window(lrows, st.sel, st.top, lh - 2)
        ltitle = string(st.title, " ", st.sel, "/", length(st.items))
    end

    # The item title again, above the detail. The title bar is a row away at the
    # top of the screen and easy to lose track of once you have scrolled into a
    # long thread.
    rrows = Row[]
    if it !== nothing
        htitle = osc8(it.url, string(AB, it.ref, AR, "  ", it.title))
        for l in awrap(htitle, riw)
            push!(rrows, Row(0, false, l, string(it.ref, "  ", it.title), 0))
        end
        push!(rrows, Row(0, false, string(AD, "─"^riw, AR), "", 0))
    end
    # The mouse turns a screen row into an `nrow` by subtracting this, and only
    # here is it known - the item title wraps to however many rows it wraps to.
    st.hdr = length(rrows)
    nrows = rows(st.nodes, riw)
    append!(rrows, nrows)
    st.nrow = clamp(st.nrow, 1, max(1, length(nrows)))
    sr = selrange(st)
    if !isempty(st.search) && st.searchin === :detail
        for i in 1:length(nrows)
            r = rrows[i + st.hdr]
            hs = findhits(astrip(r.text), st.search)
            isempty(hs) && continue
            rrows[i + st.hdr] = Row(r.node, r.header, hlspan(r.text, hs, HITBG),
                                    r.src, r.part)
        end
    end
    for i in 1:length(nrows)
        insel = sr !== nothing && sr[1] <= i <= sr[2]
        # Mark the cursor row so it is visible while paging through a body,
        # not only when it lands on a header. The selection outranks it.
        cur = st.focus === :detail && i == st.nrow
        (insel || cur) || continue
        r = rrows[i + st.hdr]
        rrows[i + st.hdr] = Row(r.node, r.header,
                                hlrow(apad(afit(r.text, riw), riw), insel ? SELBG : CURBG),
                                r.src, r.part)
    end
    rvis, st.ntop = window(rrows, st.nrow + st.hdr, st.ntop, rh - 2)

    total = length(nrows)
    rtitle = string(String(st.mode),
                    it === nothing ? "" : string("  ", it.ref),
                    total > 0 ? string("  ", st.ntop, "-",
                                       min(total, st.ntop + rh - 3), "/", total) : "",
                    sr === nothing ? "" : string("  ", AB, sr[2] - sr[1] + 1, " selected", AR))

    left = pane(lvis, lw, lh, ltitle, st.focus === :list)
    L.mh > 0 && append!(left, pane(first(mlines, L.mh - 2), lw, L.mh,
                                   it === nothing ? "meta" : string("meta  ", it.ref),
                                   false))
    right = pane(rvis, rw, rh, rtitle, st.focus === :detail)

    links = Pair{String,String}[]
    for n in st.nodes, u in n.urls
        push!(links, shortlink(u, max(20, riw - 8)) => u)
    end

    # Split the way the keys themselves divide: what shows you something, then
    # what changes something. The status keeps the bottom row, where it has
    # always been and where the eye already goes for it.
    keys1 = string("[", filter_summary(st.filters), "]  f filters \u00b7 j/k line \u00b7 ",
                   "space/b page \u00b7 n/N node \u00b7 \u21b5 fold \u00b7 tab pane \u00b7 ",
                   "d diff \u00b7 o comments \u00b7 c checks \u00b7 [/] context \u00b7 l log \u00b7 ",
                   "y copy \u00b7 / search \u00b7 q quit")
    keys2 = string("C comment \u00b7 A review \u00b7 L labels \u00b7 r read \u00b7 s snooze \u00b7 ",
                   "e edit \u00b7 m mouse ", st.mouse ? "on" : "off")
    msg = !isempty(MD_WARN[]) ? "markdown: " * MD_WARN[] : st.status
    foot1 = string(AD, afit(keys1, w), AR)
    foot2 = if st.typing
        # The query line, with a block for the cursor: this view draws its own,
        # the terminal's being hidden for the whole run.
        string(AB, "/", AR, st.search, "\e[7m \e[0m",
               AD, "   ↵ keep · esc drop", AR)
    elseif !isempty(st.search)
        nmatch = st.searchin === :detail ? length(match_rows(st, riw)) : length(st.items)
        string(AB, "/", st.search, AR, AD, "  ", nmatch,
               st.searchin === :detail ? " matches · n/N steps them · " : " items · ",
               "/ to search again", AR)
    else
        string(AD, afit(isempty(msg) ? keys2 : msg, w), AR)
    end
    foot2 = string(AD, afit(foot2, w), AR)
    body = L.side ? [string(left[i], right[i]) for i in 1:min(length(left), length(right))] :
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
    # Clamp to the terminal rather than trusting the arithmetic: on a very short
    # terminal the pane minimums add up to more than there is room for, and a
    # frame taller than the screen scrolls the title bar off the top.
    all_ = vcat([apad(afit(bar, w), w)], body, [apad(foot1, w), apad(foot2, w)])
    while length(all_) < h
        push!(all_, " "^w)
    end
    linkify(join(all_[1:h], "\n"), links)
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

"""
    split_details(md) -> Vector{Tuple{Symbol,String,String}}

Break a comment body into prose and `<details>` blocks, in the order they
appear: `(:text, "", prose)` or `(:details, summary, contents)`.

`Markdown.parse` passes HTML straight through, so a codecov report or a pasted
build log arrives as several hundred lines of raw tags sitting in the middle of
the thread - which is the opposite of what the author meant by folding it away.

Scanned rather than matched with a regex, because these nest: a lazy `.*?` run
to the first `</details>` closes the outer block at the inner one's end and
spills the remainder into the prose.
"""
function split_details(md::AbstractString)
    OPEN, CLOSE = r"<details\b[^>]*>"i, r"</details\s*>"i
    out = Tuple{Symbol,String,String}[]
    pos = firstindex(md)
    while pos <= lastindex(md)
        m = findnext(OPEN, md, pos)
        m === nothing && break
        k, depth, closing = nextind(md, last(m)), 1, nothing
        while depth > 0
            o = findnext(OPEN, md, k)
            c = findnext(CLOSE, md, k)
            c === nothing && break
            if o !== nothing && first(o) < first(c)
                depth += 1; k = nextind(md, last(o))
            else
                depth -= 1; k = nextind(md, last(c))
                depth == 0 && (closing = c)
            end
        end
        # Unbalanced: leave the rest as prose rather than guessing where it ends.
        closing === nothing && break
        pre = md[pos:prevind(md, first(m))]
        isempty(strip(pre)) || push!(out, (:text, "", String(strip(pre))))
        inner = md[nextind(md, last(m)):prevind(md, first(closing))]
        smy = match(r"<summary[^>]*>(.*?)</summary\s*>"is, inner)
        summary = smy === nothing ? "details" :
                  strip(unescape_html(replace(smy[1], r"<[^>]+>" => "")))
        summary = replace(String(summary), r"\s+" => " ")
        content = smy === nothing ? inner : replace(inner, smy.match => "")
        push!(out, (:details, isempty(summary) ? "details" : summary,
                    String(strip(content))))
        pos = nextind(md, last(closing))
    end
    tail = pos > lastindex(md) ? "" : md[pos:end]
    isempty(strip(tail)) || push!(out, (:text, "", String(strip(tail))))
    out
end

"How far a `<details>` chain is followed before its contents are left as text."
const MAX_DEPTH = 3

"""Nodes for one body: its prose, then a folded node per `<details>` block.

The block becomes a sibling drawn inset and starting closed, rather than a child
- which is what a five-hundred-line generated table wants to be, and avoids
turning the flat node list into a tree for the one case that needs one.

Every piece of one body sits one level under that body's node, blocks and the
prose between them alike, so the whole comment folds as a unit. Putting the
trailing prose back at the parent's depth reads correctly but folds wrongly:
closing the comment left its own tail on screen as a stray `…`, and the block
after that tail hung off the tail rather than off the comment.
"""
function body_nodes!(ns::Vector{Node}, header, body, url, open::Bool, depth::Int = 0)
    segs = depth >= MAX_DEPTH ? [(:text, "", String(body))] : split_details(body)
    lead = (!isempty(segs) && segs[1][1] === :text) ? segs[1][3] : ""
    n = Node(String(header), lead, :md, open, depth)
    isempty(url) || (n.meta["url"] = url)
    push!(ns, n)
    for (k, (kind, summary, content)) in enumerate(segs)
        (k == 1 && kind === :text) && continue
        kind === :details ? body_nodes!(ns, summary, content, url, false, depth + 1) :
                            body_nodes!(ns, "…", content, url, true, depth + 1)
    end
    ns
end
body_nodes(header, body, url, open::Bool) = body_nodes!(Node[], header, body, url, open)

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
        body_nodes!(ns, string(nz(who0, "?"), " opened this"), btxt,
                    String(nz(get(body, "html_url", nothing), it.url)), true)
    end
    for c in cs
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
        at = first(String(c["created_at"]), 16)
        txt = strip(replace(nz(get(c, "body", nothing), ""), "\r\n" => "\n"))
        # Anchored, so following it lands on this comment rather than the top.
        url = String(nz(get(c, "html_url", nothing), it.url))
        # A review comment reads as a non-sequitur in a chronological list
        # without the line it was left on. The diff pane places it against the
        # code; here it at least says where it was pointing.
        loc = comment_loc(c)
        made = body_nodes(string(nz(who, "?"), "  ", at), txt, url, true)
        # The peek belongs to the prose. A comment that is nothing but a folded
        # block has none, so it borrows the summary - "<details><summary>" is
        # not a useful thing to read on the header line.
        lead = isempty(strip(made[1].raw)) && length(made) > 1 ?
               made[2].header : made[1].raw
        peek = strip(first(replace(lead, r"\s+" => " "), 58))
        made[1].header = string(nz(who, "?"), "  ", at, loc, "   ", peek)
        # The header's peek is cut mid-word; copy the byline instead, since the
        # body itself is on the rows underneath it.
        made[1].meta["src"] = string(nz(who, "?"), "  ", at, astrip(loc))
        # Only a review comment can be replied to in a thread; an issue comment
        # has no thread to reply into, so `c` there writes a new one.
        isempty(loc) || (made[1].meta["comment_id"] = get(c, "id", nothing))
        append!(ns, made)
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
    pending_range, pending_old = (0, 0), (0, 0)
    flush!() = if !isempty(hdr)
        adds = count(l -> startswith(l, "+") && !startswith(l, "+++"), buf)
        dels = count(l -> startswith(l, "-") && !startswith(l, "---"), buf)
        n = Node(string(file, "  ", hdr, "  +", adds, " -", dels),
                 join(buf, "\n"), :diff, true)
        n.meta["file"] = file
        n.meta["start"] = pending_range[1]
        n.meta["count"] = pending_range[2]
        # The old-side range as well, so a comment left on a deleted line - which
        # GitHub anchors to the LEFT side - can be placed too.
        n.meta["ostart"] = pending_old[1]
        n.meta["ocount"] = pending_old[2]
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
            old = m === nothing ? (0, 0) :
                  (parse(Int, m[1]), m[2] === nothing ? 1 : parse(Int, m[2]))
            hdr = string("@@ ", rng[1], ",", rng[2], " @@")
            pending_range, pending_old = rng, old
            buf = String[]
        elseif !isempty(hdr)
            push!(buf, String(l))
        end
    end
    flush!()
    isempty(ns) && return [Node("empty diff", "", :plain, true)]
    place_comments(ns, it)
end

"""Where a review comment was pointing: `file.jl:544`, or empty for a plain one.

Falls back to `original_line` when `line` is null, which is how an outdated
comment arrives - it is the wrong line in today's file, but it is the only
number the comment has, and printing nothing there reads as a bug.
"""
function comment_loc(c)
    p = String(nz(get(c, "path", nothing), ""))
    isempty(p) && return ""
    ln = something(get(c, "line", nothing), get(c, "original_line", nothing), "?")
    string("  ", CYA, last(split(p, '/')), ":", ln, AR)
end

"Header for one review comment: who, when, where it pointed, and a peek."
function comment_header(c)
    who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", "?")
    at = first(String(nz(get(c, "created_at", nothing), "")), 16)
    peek = strip(first(replace(String(nz(get(c, "body", nothing), "")), r"\s+" => " "), 48))
    (string(who, "  ", at, "   ", peek), string(who, "  ", at))
end

"""
    place_comments(hunks, it) -> Vector{Node}

Hang each review comment off the hunk it was left on.

A review comment carries the file and line it points at, so it belongs against
the code - not at the end of a chronological thread, which is where the `o`
pane necessarily puts it, several screens away from the change it is a question
about.

`line` is the position in the file as it now stands. On a comment left against
a line that has since changed it is null, and only `original_line` survives -
which is a position in a diff that no longer exists. Those are gathered under a
single folded header at the end rather than guessed at: placing one against
whatever now occupies that line number would attach the discussion to unrelated
code, which is worse than not placing it.

Replies are threaded by `in_reply_to_id`; the API returns them flat and in
creation order, and a reply carries the same anchor as its parent.
"""
function place_comments(hunks::Vector{Node}, it::Item)
    cs = try
        Events.review_comments(it.url)
    catch
        return hunks                # the diff is still worth reading without them
    end
    attach_comments(hunks, cs, it.url)
end

"The placement itself, given the comments - so it can be tested without GitHub."
function attach_comments(hunks::Vector{Node}, cs, url::AbstractString)
    isempty(cs) && return hunks
    replies = Dict{Any,Vector{Any}}()
    tops = Any[]
    for c in cs
        r = get(c, "in_reply_to_id", nothing)
        r === nothing ? push!(tops, c) : push!(get!(replies, r, Any[]), c)
    end

    "The hunk a comment points into, by file and by the side it was left on."
    function findhunk(c)
        path = String(nz(get(c, "path", nothing), ""))
        line = get(c, "line", nothing)
        line === nothing && return nothing        # outdated: nothing to point at
        right = String(nz(get(c, "side", nothing), "RIGHT")) != "LEFT"
        for (i, n) in enumerate(hunks)
            get(n.meta, "file", "") == path || continue
            st_ = right ? n.meta["start"] : n.meta["ostart"]
            ct = right ? n.meta["count"] : n.meta["ocount"]
            st_ <= line <= st_ + max(ct, 1) - 1 && return i
        end
        nothing
    end

    emit!(out, c, depth) = begin
        (hdr, src) = comment_header(c)
        made = body_nodes!(Node[], hdr, strip(replace(String(nz(get(c, "body", nothing), "")),
                                                      "\r\n" => "\n")),
                           String(nz(get(c, "html_url", nothing), url)), true, depth)
        made[1].meta["src"] = src
        made[1].meta["comment_id"] = get(c, "id", nothing)
        append!(out, made)
        for r in get(replies, get(c, "id", nothing), ())
            emit!(out, r, depth + 1)
        end
    end

    byhunk = Dict{Int,Vector{Any}}()
    orphans = Any[]
    for c in tops
        i = findhunk(c)
        i === nothing ? push!(orphans, c) : push!(get!(byhunk, i, Any[]), c)
    end

    out = Node[]
    for (i, n) in enumerate(hunks)
        haskey(byhunk, i) &&
            (n.header = string(n.header, "  ", CYA, "💬", length(byhunk[i]), AR))
        push!(out, n)
        for c in get(byhunk, i, ())
            emit!(out, c, n.depth + 1)
        end
    end
    if !isempty(orphans)
        # Folded, and folding now hides the run nested under it, so this really
        # does put them away.
        h = Node(string(AD, length(orphans), " comment",
                        length(orphans) == 1 ? "" : "s",
                        " on lines that have since changed", AR), "", :plain, false)
        push!(out, h)
        for c in orphans
            emit!(out, c, 1)
        end
    end
    out
end

mode_nodes(mode::Symbol, it::Item) =
    mode === :comments ? comment_nodes(it) :
    mode === :diff     ? diff_nodes(it) : check_nodes(it)

function load_nodes!(st::BState)
    isempty(st.items) && return
    it = st.items[st.sel]
    mode = st.mode
    key = string(it.url, ":", mode)
    (st.loaded == key || st.pendkey == key) && return
    st.pending = @async begin
        r = try
            mode_nodes(mode, it)
        finally
            st.wake === nothing || st.wake()   # redraw as soon as this lands
        end
        r
    end
    st.pendkey = key
    st.nodes = Node[]
    st.nrow = 1; st.ntop = 1
    clearsel!(st)          # it indexed rows that are about to be replaced
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
    st.nrow = 1; st.ntop = 1; clearsel!(st); st.status = ""
    true
end

# --- interaction -----------------------------------------------------------

"Node index owning the cursor row, so folding works from anywhere in a body."
function curnode(st::BState, w::Int)
    rs = rows(st.nodes, w)
    isempty(rs) && return 0
    rs[clamp(st.nrow, 1, length(rs))].node
end

"Row index of node `i`'s header - where the cursor lands after folding."
function headerrow(st::BState, i::Int, w::Int)
    rs = rows(st.nodes, w)
    j = findfirst(r -> r.node == i && r.header, rs)
    j === nothing ? 1 : j
end

"Move the cursor to the next (`+1`) or previous (`-1`) node header."
function jumpnode(st::BState, dir::Int, w::Int)
    rs = rows(st.nodes, w)
    isempty(rs) && return
    hdrs = [j for j in eachindex(rs) if rs[j].header]
    isempty(hdrs) && return
    st.nrow = if dir > 0
        something(findfirst(>(st.nrow), hdrs), length(hdrs)) |> i -> hdrs[i]
    else
        something(findlast(<(st.nrow), hdrs), 1) |> i -> hdrs[i]
    end
end

render(st::BState, w::Int, h::Int) = render_frame(st, w, h)

"Adopt whichever finished fetch woke us - the body, the metadata, or both."
onwake!(st::BState) = collect_pending!(st) | collect_meta!(st)

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
    load_meta!(st)
    L = layout(w, h, st.nmeta)
    iw, page, lpage = L.riw, L.page, L.lpage
    # While the query is being typed it takes every key, so that `/julia` is a
    # search and not four commands. Enter keeps it, escape drops it.
    if st.typing
        if k in (13, 10)
            commit_search!(st, iw)
        elseif k == 27
            st.search = ""; st.typing = false
            st.searchin === :list && refilter!(st)
        elseif k in (127, 8)
            isempty(st.search) || (st.search = st.search[1:prevind(st.search, end)];
                                   research!(st, iw))
        elseif k == C_U
            st.search = ""; research!(st, iw)
        elseif k in (C_W, K_WORD_BACK)
            st.search = String(first(st.search,
                                     word_start(st.search, length(st.search) + 1) - 1))
            research!(st, iw)
        elseif printable(k)
            st.search *= Char(k); research!(st, iw)
        end
        return :ok
    end
    if k == Int('/')
        st.typing = true
        st.search = ""
        st.searchin = st.focus === :detail ? :detail : :list
        st.searchin === :list && refilter!(st)
        return :ok
    elseif k == Int('q')
        return :quit          # Escape no longer quits: it heads key sequences
    elseif k == Int('\t') || k == K_STAB
        st.focus = st.focus === :list ? :detail : :list
    elseif k == Int('f')
        st.lmode = st.lmode === :filters ? :items : :filters
        st.focus = :list
    elseif k == Int('m')
        # Handled up here rather than with the other actions so it still works
        # in the filter pane - a terminal that cannot report the mouse has to be
        # escapable from wherever you happen to be standing.
        st.mouse = mouse!(ctrl, !ctrl.mouse)
        clearsel!(st)
        st.status = st.mouse ? "mouse on — drag to select, y to copy" :
                               "mouse off — the terminal's own selection is back"
    elseif st.focus === :list && st.lmode === :filters
        frows = filter_rows(st)
        nf = length(frows)
        if k in (Int('j'), K_DOWN);     st.frow = min(nf, st.frow + 1)
        elseif k == Int(' ');           st.frow = min(nf, st.frow + lpage)
        elseif k in (Int('k'), K_UP);   st.frow = max(1, st.frow - 1)
        elseif k in (Int('n'), Int('N'))
            g = filter_groups(frows)
            if !isempty(g)
                st.frow = k == Int('n') ?
                          g[something(findfirst(>(st.frow), g), length(g))] :
                          g[something(findlast(<(st.frow), g), 1)]
            end
        elseif k in (13, 10);           toggle_filter!(st)
        elseif k == Int('c');           st.filters = Filters(); refilter!(st)
        end
    elseif st.focus === :list
        if k in (Int('j'), K_DOWN);          st.sel = min(length(st.items), st.sel + 1)
        elseif k in (Int('k'), K_UP);        st.sel = max(1, st.sel - 1)
        elseif k in (Int(' '), 6, K_PGDN);   st.sel = min(length(st.items), st.sel + lpage)
        elseif k in (Int('b'), 2, K_PGUP);   st.sel = max(1, st.sel - lpage)
        elseif k in (Int('g'), K_HOME);      st.sel = 1
        elseif k in (Int('G'), K_END);       st.sel = length(st.items)
        elseif k in (13, 10);                st.focus = :detail
        end
        isempty(st.items) ||
            st.loaded == string(st.items[st.sel].url, ":", st.mode) || (st.nrow = 1)
    else
        n = length(rows(st.nodes, iw))
        # Moving the cursor drops the selection. Listed rather than blanket, so
        # that `y` - which falls through this branch to the actions below - can
        # still see what is selected.
        k in (Int('j'), K_DOWN, Int('k'), K_UP, Int(' '), 6, K_PGDN, Int('b'), 2,
              K_PGUP, Int('g'), K_HOME, Int('G'), K_END, Int('n'), Int('N'),
              13, 10) && clearsel!(st)
        if k in (Int('j'), K_DOWN);          st.nrow = min(n, st.nrow + 1)
        elseif k in (Int('k'), K_UP);        st.nrow = max(1, st.nrow - 1)
        elseif k in (Int(' '), 6, K_PGDN);   st.nrow = min(n, st.nrow + page)
        elseif k in (Int('b'), 2, K_PGUP);   st.nrow = max(1, st.nrow - page)
        elseif k in (Int('g'), K_HOME);      st.nrow = 1
        elseif k in (Int('G'), K_END);       st.nrow = n
        elseif k == Int('n')
            (isempty(st.search) || st.searchin !== :detail) ? jumpnode(st, 1, iw) :
                                                              jumpmatch(st, 1, iw)
        elseif k == Int('N')
            (isempty(st.search) || st.searchin !== :detail) ? jumpnode(st, -1, iw) :
                                                              jumpmatch(st, -1, iw)
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

    # Lowercase shows you something, uppercase changes something. `c` was the
    # composer and `C` the checks pane, which had it exactly backwards.
    if k == Int('d');     st.mode = :diff
    elseif k == Int('o'); st.mode = :comments
    elseif k == Int('c'); st.mode = :checks
    elseif k == Int('y')
        # OSC 52, so the copy works over ssh and through tmux. Also shown in the
        # footer, since OSC 52 is disabled by default in some terminals.
        txt = selection_text(st, iw)
        note = if isempty(txt)
            i = curnode(st, iw)
            txt = i > 0 ? get(st.nodes[i].meta, "url", it.url) : it.url
        else
            string(count(==('\n'), txt) + 1, " lines")
        end
        print("\e]52;c;", Base64.base64encode(txt), "\a")
        st.status = string("copied ", note)
    elseif k == Int('l')
        i = curnode(st, iw)
        if i > 0 && haskey(st.nodes[i].meta, "bk")
            n = st.nodes[i]
            n.raw = bk_log(n.meta["bk"], n.meta["job"])
            n.cw = -1; n.open = true
            st.status = "log fetched"
        end
    elseif k == Int('C'); compose_action(st, ctrl, it, iw)
    elseif k == Int('A'); review_action(st, ctrl, it)
    elseif k == Int('L'); label_action(st, ctrl, it)
    elseif k == Int('r'); Events.mark_read([it.url]); st.status = "marked read"
    elseif k == Int('s'); disarm(it.url); set_fields(it.url, ["snooze" => "on-change"])
                          st.status = "snoozed"
    end
    load_nodes!(st)
    load_meta!(st)
    :ok
end

# --- mouse ------------------------------------------------------------------

"""
    onmouse!(st, ev, ctrl) -> Symbol

One mouse report, in the same shape as `handle!`.

Clicking anywhere moves the cursor there and focuses that pane, which is the
behaviour that makes a pointer worth having at all. Clicking a fold marker
toggles it. Dragging selects rows, which `y` then copies as the text they were
written as rather than as the wrapped fragments the terminal can see.

The wheel moves the cursor rather than only the viewport, because the viewport
does not survive: `window` pulls the pane back to wherever the cursor is on the
next redraw, so a scroll that left the cursor behind would spring back at the
next keystroke.
"""
function onmouse!(st::BState, ev::MouseEvent, ctrl::Controller)
    h, w = displaysize(stdout)
    L = layout(w, h, st.nmeta)
    p = hitpane(L, ev.x, ev.y)
    p === nothing && return :ok
    (which, row, col) = p
    which === :meta && return :ok      # a readout, not a control
    wheel = ev.kind === :wheelup || ev.kind === :wheeldown
    d = ev.kind === :wheelup ? -3 : 3

    if which === :list
        (wheel || ev.kind === :press) || return :ok
        st.focus = :list
        if st.lmode === :filters
            nf = length(filter_rows(st))
            st.frow = wheel ? clamp(st.frow + d, 1, nf) : clamp(st.top + row - 1, 1, nf)
            wheel || toggle_filter!(st)
        elseif !isempty(st.items)
            st.sel = wheel ? clamp(st.sel + d, 1, length(st.items)) :
                             clamp(st.top + row - 1, 1, length(st.items))
            load_nodes!(st)         # clears any selection with the old nodes
        end
        return :ok
    end

    rs = rows(st.nodes, L.riw)
    isempty(rs) && return :ok
    if wheel
        st.focus = :detail
        clearsel!(st)
        st.nrow = clamp(st.nrow + d, 1, length(rs))
        return :ok
    end
    # `ntop` indexes rows including the item-title block; `nrow` excludes it.
    idx = st.ntop + row - 1 - st.hdr
    1 <= idx <= length(rs) || return :ok
    if ev.kind === :press
        st.focus = :detail
        st.nrow = idx
        st.anchor = idx
        st.sela = 0; st.selb = 0
        if rs[idx].header && col <= 2          # the ▾/▸ marker and its space
            i = rs[idx].node
            st.nodes[i].open = !st.nodes[i].open
            st.nrow = headerrow(st, i, L.riw)
            st.anchor = 0
        end
    elseif ev.kind === :drag
        st.anchor == 0 && (st.anchor = idx)
        st.sela, st.selb = st.anchor, idx
        st.nrow = idx
    elseif ev.kind === :release
        r = selrange(st)
        r === nothing ||
            (st.status = string(r[2] - r[1] + 1, " rows selected — y to copy"))
    end
    :ok
end

# --- search -----------------------------------------------------------------

"Rows of the detail pane that contain the query, by what they actually print."
function match_rows(st::BState, w::Int)
    isempty(st.search) && return Int[]
    [j for (j, r) in enumerate(rows(st.nodes, w))
     if !isempty(findhits(astrip(r.text), st.search))]
end

"""Re-aim after the query changed.

In the list the query narrows; in the detail pane it moves the cursor to the
first hit at or after where it already is, so refining a search does not jump
back to the top of the thread.
"""
function research!(st::BState, w::Int)
    if st.searchin === :detail
        ms = match_rows(st, w)
        isempty(ms) && return
        st.nrow = something(findfirst(>=(st.nrow), ms), 1) |> i -> ms[i]
    else
        refilter!(st)
    end
end

"""Finish a search. A bare number is a jump rather than a filter.

Only on Enter: done live, typing the `1` of `18004` would land on whatever
`#1` happens to be and take the rest of the digits as commands. The jump also
reaches past the filter that is hiding the item, by widening the state axis -
being unable to see it is exactly when you go looking for it by number.
"""
function commit_search!(st::BState, w::Int)
    st.typing = false
    st.searchin === :list || return
    n = tryparse(Int, strip(st.search))
    n === nothing && return
    k = findfirst(it -> it.number == n, st.all)
    if k === nothing
        st.status = string("no item numbered ", n)
        return
    end
    target, ref = st.all[k].url, st.all[k].ref
    st.search = ""
    any(it -> it.url == target, apply_filters(st.filters, st.all, st.unread)) ||
        (st.filters.state = :all)
    refilter!(st)
    j = findfirst(it -> it.url == target, st.items)
    j === nothing || (st.sel = j)
    st.status = string("jumped to ", ref)
end

"Step to the next (`+1`) or previous (`-1`) match in the detail pane."
function jumpmatch(st::BState, dir::Int, w::Int)
    ms = match_rows(st, w)
    isempty(ms) && return false
    st.nrow = dir > 0 ? ms[something(findfirst(>(st.nrow), ms), 1)] :
                        ms[something(findlast(<(st.nrow), ms), length(ms))]
    true
end

# --- writing ----------------------------------------------------------------

"""
    hunk_line_at(st, i, w) -> (line, side) or nothing

The source line under the cursor inside hunk node `i`.

The cursor is a display row and the hunk is diff lines, so the rows are counted
back to a logical line first - `part == 0` marks the first row of each - and the
hunk is then walked from its own top, which knows where it starts and how far
`[`/`]` has widened it.

The old-side number is only right while expansion has added pure context, which
is all it ever adds; a hunk expanded across a deletion would drift.
"""
function hunk_line_at(st::BState, i::Int, w::Int)
    n = st.nodes[i]
    haskey(n.meta, "start") || return nothing
    rs = rows(st.nodes, w)
    idx = 0
    for j in 1:min(st.nrow, length(rs))
        r = rs[j]
        (r.node == i && !r.header && r.part == 0) && (idx += 1)
    end
    idx == 0 && return nothing
    lines = split(n.raw, "\n")
    idx > length(lines) && return nothing
    up = get(n.meta, "up", 0)
    newno = n.meta["start"] - up
    oldno = get(n.meta, "ostart", n.meta["start"]) - up
    for (k, l) in enumerate(lines)
        del, add = startswith(l, "-"), startswith(l, "+")
        k == idx && return del ? (oldno, "LEFT") : (newno, "RIGHT")
        del ? (oldno += 1) : add ? (newno += 1) : (oldno += 1; newno += 1)
    end
    nothing
end

"""What `c` writes to, given where the cursor is standing.

One key rather than three, because the answer is never ambiguous: on a review
comment it is a reply, on a hunk it is that line, and anywhere else it is the
item itself.
"""
function compose_target(st::BState, iw::Int)
    i = curnode(st, iw)
    i == 0 && return (:item, nothing)
    n = st.nodes[i]
    cid = get(n.meta, "comment_id", nothing)
    cid === nothing || return (:reply, cid)
    if st.mode === :diff && haskey(n.meta, "file")
        r = hunk_line_at(st, i, iw)
        r === nothing || return (:line, (n.meta["file"], r[1], r[2]))
    end
    (:item, nothing)
end

"After a write lands, re-read the thread rather than showing the stale one."
function reread!(st::BState)
    st.loaded = ""; st.pendkey = ""
    st.metakey = ""
    load_nodes!(st); load_meta!(st)
end

"""Open the composer on whatever `c` is pointing at."""
function compose_action(st::BState, ctrl::Controller, it::Item, iw::Int)
    (kind, target) = compose_target(st, iw)
    if kind === :line && target[3] == "LEFT"
        st.status = "a comment on a deleted line has to go to the old side — not wired up"
        return
    end
    (title, note, submit) = if kind === :reply
        (string("Reply · ", it.ref), "goes into this review thread",
         b -> Events.reply_review_comment(it.url, target, b))
    elseif kind === :line
        sha = head_sha(it)
        (string("Comment on ", target[1], ":", target[2]),
         isempty(sha) ? "no head commit could be found — this will fail" :
                        string("against ", first(sha, 8), ", posted on its own"),
         b -> Events.post_review_comment(it.url, sha, target[1], target[2], target[3], b))
    else
        (string("Comment on ", it.ref), it.title, b -> Events.post_comment(it.url, b))
    end
    push_view!(ctrl, EditorView(title, note, b -> begin
        r = submit(b)
        st.status = isempty(r) ? "posted" : r
        isempty(r) && reread!(st)
    end))
end

"""Submit a review: pick the verdict, then write the body."""
function review_action(st::BState, ctrl::Controller, it::Item)
    it.is_pr || (st.status = "not a pull request"; return)
    opts = [("approve", "APPROVE"), ("request changes", "REQUEST_CHANGES"),
            ("comment", "COMMENT")]
    push_view!(ctrl, ChooseView(string("Review ", it.ref), it.title, opts, ev -> begin
        push_view!(ctrl, EditorView(
            string(replace(lowercase(ev), "_" => " "), " · ", it.ref),
            ev == "APPROVE" ? "a body is optional; ^s submits the approval" :
                              "GitHub requires a body for this",
            b -> begin
                r = Events.submit_review(it.url, ev, b)
                st.status = isempty(r) ? string("submitted: ", replace(lowercase(ev), "_" => " ")) : r
                isempty(r) && reread!(st)
            end; allow_empty = ev == "APPROVE"))
    end))
end

"""Toggle one label, chosen from this item's own plus every label seen."""
function label_action(st::BState, ctrl::Controller, it::Item)
    have = Set(it.labels)
    all_ = sort(unique(vcat(it.labels, st.labels)); by = l -> (!(l in have), l))
    opts = [(string(l in have ? "[x] " : "[ ] ", l), l) for l in all_]
    push_view!(ctrl, ChooseView(string("Labels · ", it.ref), "↵ toggles one", opts,
        l -> begin
            on = l in have
            r = Events.toggle_label(it.url, l, !on)
            # `Item` comes from facts.json and is not rewritten here, so the
            # metadata pane keeps showing the old set until the next refresh.
            st.status = isempty(r) ? string(on ? "removed " : "added ", l,
                                            " — shows here after `wl refresh`") : r
        end))
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

# --- CI checks --------------------------------------------------------------

const CI_COLOR = Dict("SUCCESS" => "\e[32m", "FAILURE" => "\e[31m", "ERROR" => "\e[31m",
                      "PENDING" => "\e[33m", "TIMED_OUT" => "\e[31m",
                      "CANCELLED" => "\e[2m", "SKIPPED" => "\e[2m", "NEUTRAL" => "\e[2m")

"""Checks for an item, with failing Buildkite jobs listed underneath.

A rollup of FAILURE says nothing about which of sixty jobs broke, so each
failing Buildkite build is expanded into its failed jobs, each of which can
pull its own log.
"""
function check_nodes(it::Item)
    it.is_pr || return [Node("no checks - this is an issue, not a pull request",
                             "", :plain, true)]
    c = check_contexts(it.repo, it.number)
    ns = Node[]
    seen_builds = Set{String}()
    for x in c.contexts
        col = get(CI_COLOR, uppercase(x.state), "")
        n = Node(string(col, rpad(x.state, 9), "\e[0m", x.name), "", :plain, false)
        isempty(x.url) || (n.meta["url"] = x.url)
        n.raw = isempty(x.url) ? "" : x.url
        push!(ns, n)

        b = bk_parse(x.url)
        b === nothing && continue
        k = string(b.pipeline, "/", b.build)
        k in seen_builds && continue
        push!(seen_builds, k)
        failed = bk_failed(bk_jobs(b))
        isempty(failed) && continue
        for j in failed
            jn = Node(string("\e[31m", rpad(j.state, 10), "\e[0m", j.name,
                             j.exit == "" ? "" : string("  (exit ", j.exit, ")")),
                      "press l to fetch this job's log", :plain, false, 1)
            jn.meta["bk"] = b
            jn.meta["job"] = j.id
            jn.meta["url"] = "https://buildkite.com/$(b.org)/$(b.pipeline)/builds/$(b.build)#$(j.id)"
            push!(ns, jn)
        end
    end
    isempty(ns) ? [Node("no checks reported", "", :plain, true)] : ns
end
