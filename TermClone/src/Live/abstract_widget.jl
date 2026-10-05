# ---------------------------------------------------------------------------- #
#                                ABSTRACT WIDGET                               #
# ---------------------------------------------------------------------------- #

"""
    AbstractWidget

Abstract widgets must have three obligatory fields:
    measure::Measure
    controls:: Dict{Union{KeyInput, Char}, Function}
    parent::Union{Nothing, AbstractWidget}

and one optional one
    on_draw::Union{Nothing, Function} = nothing
"""
abstract type AbstractWidget end

"""
    WidgetInternals

This struct is used to store the internal state of a widget as well as
callbacks assigned to it.
"""
mutable struct WidgetInternals
    measure::Measure
    parent::Union{Nothing, AbstractWidget}
    on_draw::Union{Nothing, Function}
    on_activated::Function
    on_deactivated::Function
    active::Bool
end

# ------------------------------ tree structure ------------------------------ #
# Term walks an app's widgets with AbstractTrees; the walk is three functions,
# so it is here rather than a dependency.

"""
    widget_children(widget) -> Vector

The widgets a container holds, in its order (a `Dict`'s for an `App`).
"""
function widget_children(widget::AbstractWidget)
    hasfield(typeof(widget), :widgets) || return AbstractWidget[]
    widget.widgets isa AbstractDict && return collect(values(widget.widgets))
    return widget.widgets
end

"""
    widget_parent(widget) -> Union{Nothing, AbstractWidget}
"""
function widget_parent(widget::AbstractWidget)
    hasfield(typeof(widget), :parent) && return widget.parent
    return widget.internals.parent
end

"`widget` and everything under it, parents before children."
function preorder(widget::AbstractWidget)
    out = AbstractWidget[widget]
    for c in widget_children(widget)
        append!(out, preorder(c))
    end
    return out
end

# ----------------------------- widget functions ----------------------------- #
"""
    get_active(w::AbstractWidget)

Nothing: no children.
"""
get_active(::AbstractWidget) = nothing

"""
    isactive(w::AbstractWidget)

Returns true if the widget is active, i.e. if it is the active widget
"""
function isactive(widget::AbstractWidget)
    par = widget_parent(widget)
    isnothing(par) && return true
    return widget == get_active(par) && isactive(par)
end

"""
Default callback for a widget being activated
"""
on_activated(wdg::AbstractWidget) = wdg.internals.active = true

"""
Default callback for a widget being deactivated
"""
on_deactivated(wdg::AbstractWidget) = wdg.internals.active = false

"""
Quit the current app, potentially returning some value.
"""
function quit end
quit(::Nothing) = return
quit(widget::AbstractWidget, ::Any) = quit(widget_parent(widget))
quit(widget::AbstractWidget) = quit(widget_parent(widget))

"""
Get the current content of a widget
"""
frame(::AbstractWidget) = error("Not implemented")

"""
    on_key(widget, code) -> Symbol

A key no control of `widget` claimed, as its TermInput code: what a widget
built on a TermInput widget hands to that widget's `handle!`, so that the keys
Term never bound - the word motions, `^a`/`^e`, the pager's `j`/`k` - still do
what they do there. `:unhandled` for a widget with nothing under it.
"""
on_key(::AbstractWidget, ::Int) = :unhandled

# ------------------------------- printing ----------------------------------- #
"""
    print_node(io, x)

Print function to print a node (widget) in an application's hierarchy tree.
It prints the node's stated dimensions vs its content's (calling `frame`).
Used for debugging
"""
function print_node(io, x)
    color = isactive(x) ? "bright_blue" : "dim blue"
    style = isactive(x) ? "default" : "dim"
    content = frame(x)

    measure = hasfield(typeof(x), :measure) ? x.measure : x.internals.measure
    hx, wx = measure.h, measure.w
    hc, wc = content.measure.h, content.measure.w

    h_color = hx >= hc ? style : "red"
    w_color = wx >= wc ? style : "red"

    msg = """{$color}$(typeof(x)){/$color} {dim} ($hx, $wx){/dim}
    {$style}content: ({$h_color}$hc{/$h_color}, {$w_color}$wc{/$w_color}){/$style}"""
    return print(io, apply_style(msg))
end

"""
    print_tree(printnode, io, widget)

The widget tree drawn as AbstractTrees draws one: each child under its parent
behind `├─ ` (`└─ ` for the last), and the lines of a node after its first
behind `│  ` (`   `).
"""
function print_tree(printnode, io::IO, widget; prefix = "")
    lines = split(sprint(printnode, widget), '\n')
    println(io, lines[1])
    for l in lines[2:end]
        println(io, prefix, l)
    end
    cs = widget_children(widget)
    for (i, c) in enumerate(cs)
        last = i == length(cs)
        print(io, prefix, last ? "└─ " : "├─ ")
        print_tree(printnode, io, c; prefix = prefix * (last ? "   " : "│  "))
    end
    return nothing
end

Base.print(io::IO, widget::AbstractWidget) = print_tree(print_node, io, widget)
