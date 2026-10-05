# From Term.jl's _compositor.jl (MIT, see LICENSE.Term): what `grid` needs of the
# Compositor's layout expressions - the elements named in one and their sizes,
# and the placeholder an unnamed element `_` is drawn as.

layout_symbols = (
    Symbol(/),
    Symbol(*),
    :vstack,
    :lvstack,
    :leftalign,
    :hstack,
    :center,
    :rightalign,
    :lvstack,
    :rvstack,
    :cvstack,
    :pad,
    :pad!,
    :vertical_pad,
    :vertical_pad!,
)

"""
    parse_single_element_layout(ex::Expr)

Parse an expression with a single layout element, like :(A(5, 25)) or :(A)
"""
function parse_single_element_layout(ex::Expr)
    if length(ex.args) == 3
        s, h, w = ex.args
    else
        s = ex.args[1]
        h, w = default_size()
    end
    return [:($s($h, $w))]
end

"""
    get_elements_and_sizes(ex::Expr)

Get elements names and sizes.
"""
function get_elements_and_sizes(ex::Expr; placeholder_size = nothing)
    elements = collect_elements(ex)
    elements = elements isa Expr ? parse_single_element_layout(elements) : elements
    min_h = min_w = typemax(Int)
    for e in elements
        e isa Symbol && continue

        h, w = e.args[2], e.args[3]
        h = h isa Int ? h : fint(console_height() * h)
        w = w isa Int ? w : fint(console_width() * w)
        min_h = min(min_h, h)
        min_w = min(min_w, w)
    end

    # fallback size
    h, w = something(placeholder_size, default_size())
    min_h == typemax(Int) && (min_h = h)
    min_w == typemax(Int) && (min_w = w)

    return [e isa Symbol ? :($e($min_h, $min_w)) : e for e in elements]
end

"""
    collect_elements(ex::Expr)

Collects elements (individual LayoutElements) that are
in a layout expresssion.
"""
function collect_elements(ex::Expr)
    if ex.args[1] ∉ layout_symbols
        return if length(ex.args) > 2
            s, h, w = ex.args
            :($s($h, $w))
        else
            nothing
        end
    else
        symbols = map(x -> x isa Symbol ? x : collect_elements(x), ex.args)
        symbols = filter(s -> s ∉ layout_symbols && !isnothing(s), symbols)
        return reduce(vcat, symbols)
    end
end

function clean_layout_expr(ex::Expr)
    if ex.args[1] ∉ layout_symbols
        return ex.args[1]
    else
        ex.args = map(a -> a isa Expr ? clean_layout_expr(a) : a, ex.args)
    end
    return ex
end

compositor_placeholder(s, h, w, c) = begin
    h = h isa Int ? h : fint(console_height() * h)
    w = w isa Int ? w : fint(console_width() * w)
    PlaceHolder(
        h,
        w;
        style = c,
        text = "{bold underline bright_blue}$s{/bold underline bright_blue} {white}($h × $w){/white}",
    )
end

