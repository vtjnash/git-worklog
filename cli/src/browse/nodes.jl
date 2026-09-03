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
