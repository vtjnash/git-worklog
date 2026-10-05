module Trees

using InteractiveUtils
import Term

import Term: highlight, TERM_THEME, Theme, Row, row, rowcat, rowwidth, faced,
    reshape_rows, rows_to_width, joinrows

import ..Renderables: AbstractRenderable, RenderableText
import ..Style: apply_style, torow, face, styled
import ..Segments: Segment
import ..Measures: Measure
import ..Panels: Panel
import ..Consoles: console_width

export Tree

# ---------------------------------------------------------------------------- #
#                               TREE PROTOCOL                                  #
# ---------------------------------------------------------------------------- #
# Term walks trees with AbstractTrees; these are AbstractTrees' own definitions
# for what Term draws (MIT), so that a dict, a vector, a pair or an expression
# is a tree without the dependency. A type of somebody else's is a tree by a
# method of `Term.Trees.children` for it.

"""
    TreeCharSet(mid, terminator, skip, dash, trunc, pair)

The characters a tree's guides are drawn with, as AbstractTrees names them.
"""
struct TreeCharSet
    mid::String
    terminator::String
    skip::String
    dash::String
    trunc::String
    pair::String
end
TreeCharSet(a::AbstractString...) = TreeCharSet(String.(a)...)

"The children of a node: none, unless the node is a container."
children(node) = ()
children(x::AbstractArray) = x
children(x::Tuple) = x
children(x::Expr) = x.args
children(p::Pair) = (p[2],)
children(d::AbstractDict) = pairs(d)

shouldprintkeys(ch) = applicable(keys, ch)
shouldprintkeys(::AbstractVector) = false
shouldprintkeys(::Tuple) = false
shouldprintkeys(::Base.Generator) = false

# ---------------------------------------------------------------------------- #
#                                    GUIDES                                    #
# ---------------------------------------------------------------------------- #

treeguides = Dict(
    :standardtree => TreeCharSet("├", "└", "│", "─", "⋮", " ⇒ "),
    :roundedtree => TreeCharSet("├──", "╰─", "│", "─", "⋮", " ⇒ "),
    :boldtree => TreeCharSet("┣━━", "┗━━", "┃", "━", "⋮", " ⇒ "),
    :asciitree => TreeCharSet("+--", "`--", "|", "--", "...", " => "),
)

# ---------------------------------------------------------------------------- #
#                                   DRAWING                                    #
# ---------------------------------------------------------------------------- #

"""
    TreeStyle

What a tree is drawn in: a face for each kind of guide, the key and the pair
mark, from the theme. The pair mark of a `hidden` style is blank, which is what
Term means by it and what a face cannot say.
"""
struct TreeStyle
    guides::TreeCharSet
    mid::Row
    terminator::Row
    skip::Row
    dash::Row
    trunc::Row
    pair::Row          # the pair mark and the space after it, "⇒ "
    keys::String
end

function TreeStyle(g::TreeCharSet, theme::Theme)
    p = strip(g.pair)
    mark = occursin("hidden", theme.tree_pair) ? row(" "^textwidth(p)) :
        styled(p, theme.tree_pair)
    rsp = g.pair[nextind(g.pair, last(findfirst(p, g.pair))):end]
    return TreeStyle(g,
        styled(g.mid, theme.tree_mid),
        styled(g.terminator, theme.tree_terminator),
        styled(g.skip, theme.tree_skip),
        styled(g.dash, theme.tree_dash),
        styled(g.trunc, theme.tree_trunc),
        rowcat(mark, rsp),
        theme.tree_keys,
    )
end

"""
A line's prefix: the guides to its left, as a list of pieces - a skip line, or
spaces - so that it can be drawn in the guides' faces.
"""
const Prefix = Vector{Row}

const KEY_REGEX = r"^[\w.,\":\[\]\d]+$"

"""
    key_row(key, ts) -> Row

A child's key between the dash and the pair mark: a space and the key, the two
in the theme's key style when the key is a plain word (Term styles keys by
matching them in the drawn tree, so a key with markup or spaces in it is left
as it is).
"""
function key_row(k::Row, ts::TreeStyle)
    plain = occursin(KEY_REGEX, k.string)
    return plain ? styled(rowcat(" ", k, " "), ts.keys) : rowcat(" ", k, " ")
end

"""
    node_rows(printnode, io, node; kw...) -> Vector{Row}

What a node draws as, one row per line: Term's own node printer gives rows
directly; any other is called as Term calls it, and what it prints read into
rows.
"""
function node_rows(printnode, io, node; kw...)
    printnode === term_print_node && return term_node_rows(node)
    buf = IOBuffer()
    printnode(IOContext(buf, io), node; kw...)
    return Term.rowlines(torow(String(take!(buf))))
end

function key_as_row(printkey, io, k)
    printkey === term_print_key && return torow(string(k))
    buf = IOBuffer()
    printkey(IOContext(buf, io), k)
    return torow(String(take!(buf)))
end

"""
    tree_rows!(out, printnode, printkey, io, node; ...)

The rows of `node` and its children, after AbstractTrees' `print_tree` (as
Term changed it): each node's lines, the first after its guide and key and the
rest under it, then its children, to `maxdepth`.
"""
function tree_rows!(
        out::Vector{Row},
        printnode, printkey, io, node, ts::TreeStyle;
        maxdepth::Integer = 5,
        indicate_truncation::Bool = true,
        printkeys::Union{Bool, Nothing} = nothing,
        depth::Integer = 0,
        prefix::Prefix = Row[],
        lead::Row = row(""),
        printnode_kw = (;),
    )
    g = ts.guides
    pre = isempty(prefix) ? row("") : rowcat(prefix...)
    for (i, line) in enumerate(node_rows(printnode, io, node; printnode_kw...))
        push!(out, i == 1 ? rowcat(lead, line) : rowcat(pre, line))
    end

    c = children(node)
    isempty(c) && return out

    if depth ≥ maxdepth
        if indicate_truncation
            push!(out, rowcat(pre, ts.trunc))
            push!(out, pre)
        end
        return out
    end

    this_printkeys = applicable(keys, c) && (isnothing(printkeys) ? shouldprintkeys(c) : printkeys)
    s = Iterators.Stateful(this_printkeys ? pairs(c) : c)
    while !isempty(s)
        child_prefix = copy(prefix)
        if this_printkeys
            child_key, child = popfirst!(s)
        else
            child = popfirst!(s)
            child_key = nothing
        end

        if isempty(s)
            guide = ts.terminator
            push!(child_prefix, row(" "^(textwidth(g.skip) + textwidth(g.dash) + 1)))
        else
            guide = ts.mid
            push!(child_prefix, ts.skip, row(" "^(textwidth(g.dash) + 1)))
        end

        lead = rowcat(pre, guide, ts.dash)
        if this_printkeys
            k = key_as_row(printkey, io, child_key)
            lead = rowcat(lead, key_row(k, ts), ts.pair)
            push!(child_prefix, row(" "^(rowwidth(k) + textwidth(g.pair))))
        else
            lead = rowcat(lead, " ")
        end

        tree_rows!(out, printnode, printkey, io, child, ts;
            maxdepth, indicate_truncation, printkeys, depth = depth + 1,
            prefix = child_prefix, lead, printnode_kw)
    end
    return out
end

# kept for Term's API: the tree drawn and written to `io` as text.
function term_print_tree(printnode::Function, print_child_key::Function, io::IO, node;
        charset::TreeCharSet = treeguides[:standardtree], prefix::AbstractString = "", kw...)
    ts = TreeStyle(charset, TERM_THEME[])
    rs = tree_rows!(Row[], printnode, print_child_key, io, node, ts;
        prefix = [row(prefix)], kw...)
    foreach(r -> println(io, Term.Style.ansi(r)), rs)
    return nothing
end

# ---------------------------------------------------------------------------- #
#                                     TREE                                     #
# ---------------------------------------------------------------------------- #

const _TREE_PRINTING_TITLE = Ref{Union{Nothing, String}}(nothing)

"""
    term_node_rows(node) -> Vector{Row}

A node as Term draws it: the tree's title in place of the first, and any other
highlighted and wrapped to the theme's leaf width.
"""
function term_node_rows(node)
    theme::Theme = TERM_THEME[]
    title = _TREE_PRINTING_TITLE[]
    _TREE_PRINTING_TITLE[] = nothing
    isnothing(title) || return Term.rowlines(styled(title, theme.tree_title))
    r = if node isa AbstractString
        styled(node, theme.string)
    else
        torow(highlight(string(node); theme))
    end
    return reshape_rows(r, theme.tree_max_leaf_width)
end

"""
    term_print_node(io, node; kw...)

Core function to enable fancy tree printing. Styles the leaf/key of each node.
"""
function term_print_node(io, node; kw...)
    print(io, Term.Style.ansi(joinrows(term_node_rows(node))))
    return nothing
end

"""
    term_print_key(io, k; kw...)

Print a tree's node's key.
"""
term_print_key(io, k; kw...) = print(io, string(k))

"""
    Tree

Renderable tree.
"""
struct Tree <: AbstractRenderable
    segments::Vector{Segment}
    measure::Measure
end

"""
    Tree(
        tree;
        guides::Union{TreeCharSet,Symbol} = :standardtree,
        theme::Theme = TERM_THEME[],
        printkeys::Union{Nothing,Bool} = true,
        print_node_function::Function = term_print_node,
        print_key_function::Function = term_print_key,
        title::Union{String, Nothing}=nothing,
        prefix::String = "  ",
        kwargs...,
    )

A renderable tree out of anything with `children`: a dict, a vector, a pair, an
expression. Each line is a row of the guides, the key and the node, each in the
theme's style for it; the lines are padded to the widest, and wrapped where
wider than the console.

- `guides`: the name of a preset (`:standardtree`, `:roundedtree`, `:boldtree`,
  `:asciitree`) or a `TreeCharSet`
- `theme`: `Theme` used to set tree style.
- `printkeys`: If `true` print keys. If `false` don't print keys.
- `print_node_function`, `print_key_function`: what a node and a key print as.
- `title`: drawn in place of the root.
- `prefix`: what each line after the root starts with.
"""
function Tree(
        tree;
        guides::Union{TreeCharSet, Symbol} = :standardtree,
        theme::Theme = TERM_THEME[],
        printkeys::Union{Nothing, Bool} = true,
        print_node_function::Function = term_print_node,
        print_key_function::Function = term_print_key,
        title::Union{String, Nothing} = nothing,
        prefix::String = "  ",
        context = nothing,
        kwargs...,
    )
    _TREE_PRINTING_TITLE[] = title
    _theme = TERM_THEME[]
    TERM_THEME[] = theme
    rs = try
        guides = guides isa Symbol ? treeguides[guides] : guides
        io = context ≡ nothing ? IOBuffer() : IOContext(IOBuffer(), context)
        tree_rows!(Row[], print_node_function, print_key_function, io, tree,
            TreeStyle(guides, theme); printkeys, prefix = [row(prefix)], kwargs...)
    finally
        TERM_THEME[] = _theme
        _TREE_PRINTING_TITLE[] = nothing
    end
    push!(rs, row(""))   # Term's tree ends in a newline, and so in an empty line

    w = min(maximum(rowwidth, rs), console_width(stdout))
    lines = rows_to_width(joinrows(rs), w, :left)
    segments = Segment.(lines)
    return Tree(segments, Measure(segments))
end

# ---------------------------------------------------------------------------- #
#                                HIERARCHY TREE                                #
# ---------------------------------------------------------------------------- #
"""
Apply style for the type whose hierarchy Tree we are making
"""
style_T(T) = "{orange1 italic underline}$T{/orange1 italic underline}"

"""
    make_hierarchy_dict(x::Vector{DataType}, T::DataType, Tsubs::AbstractDict)::AbstractDict

Recursively create a dictionary with the types hierarchy for `T`.
`Tsubs` carries information about T's subtypes.
The AbstractDict is made backwards. From  the deepest levels up.
"""
function make_hierarchy_dict(x::NTuple, T::DataType, Tsubs::AbstractDict)::AbstractDict
    data = Dict()
    prev = ""
    for (n, y) in enumerate(x)
        if n == 1
            continue
        elseif n < length(x)
            subs = Dict()
            for s in subtypes(y)
                if s == T
                    subs[style_T(s)] = Tsubs
                else
                    subs[string(s)] = nothing
                end
            end

            if n == 2
                data = subs
            else
                subs[prev] = data
                data = subs
            end

            prev = string(y)
        end
    end
    return data
end

"""
    Tree(T::DataType; prefix = "", kwargs...)::Tree

Construct a `Tree` visualization of `T`'s types hierarchy
The key is in costructing the actual hierarchy tree recursively.
"""
function Tree(T::DataType; prefix = "", kwargs...)::Tree
    subs = Dict(string(s) => nothing for s in subtypes(T))
    data = make_hierarchy_dict(supertypes(T), T, subs)

    # a node is drawn only as the branch to its children
    s = TERM_THEME[].tree_mid
    term_print_node_datatype(io::IO, x) =
        print(io, length(children(x)) > 0 ? "{$s}┬{/$s}" : "")

    _old_style = TERM_THEME[].tree_pair
    TERM_THEME[].tree_pair = "hidden"
    _tree = try
        Tree(
            data;
            printkeys = true,
            print_node_function = term_print_node_datatype,
            print_key_function = term_print_key,
            prefix,
            kwargs...,
        )
    finally
        TERM_THEME[].tree_pair = _old_style
    end
    return _tree
end

end
