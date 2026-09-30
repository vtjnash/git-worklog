# The browser: an item list with the metadata pane under it, and beside (or
# below) them a foldable detail pane showing either the comment thread, rendered
# as markdown, or the diff.
#
# Everything is drawn as rows of faces - `Styled`, TermInput's `Row` - and
# measured by their text, so no width here is left to anything but `rowwidth`.
#
# `render` is kept pure - state and a size in, rows out - so the whole UI
# can be snapshot tested without a TTY, which is the only way any of it got
# verified here.

"A foldable block - a comment, the issue body, or one file of a diff."
mutable struct Node
    header::Styled
    raw::String
    kind::Symbol            # :md | :diff | :plain
    open::Bool
    cache::Vector{Styled}   # rendered at `cw`; markdown is far too slow per frame
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
    Node(row(h), String(raw), kind, open, Styled[], -1, String[], Dict{String,Any}(),
         Tuple{Int,String}[], depth)

"""Is this node prose carrying on from the block above it?

Such a node is drawn without a header and cannot be folded on its own: it is the
comment above it continuing after a fenced block or a `<details>`, and a header
over it - it used to be `…` - reads as a thing of its own to open, which it is
not. It is still nested, so folding the comment takes it away with the rest.
"""
isbare(n::Node) = get(n.meta, "bare", false) === true

"""The node one level out from `i`, or 0 where there is none.

What a bare node folds when it is asked to: it has no header of its own to fold
at, and the thing it is part of is the one the reader means.
"""
function parentnode(ns::Vector{Node}, i::Int)
    d = ns[i].depth
    for j in (i - 1):-1:1
        ns[j].depth < d && return j
    end
    0
end
