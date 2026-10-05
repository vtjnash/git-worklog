module Introspection

using InteractiveUtils
import OrderedCollections: OrderedDict
import MyterialColors: pink, pink_light, orange, grey_dark, light_green

import Term:
    highlight,
    escape_brackets,
    join_lines,
    unescape_brackets,
    split_lines,
    do_by_line,
    expr2string,
    default_width,
    TERM_THEME,
    highlight_syntax,
    load_code_and_highlight,
    str_trunc,
    reshape_text,
    reshape_rows,
    joinrows,
    code_row,
    Row,
    rowcat,
    faced

import ..Renderables: Renderable, RenderableText, rows
import ..Panels: Panel
import ..Dendograms: Dendogram
import ..Trees: Tree
import ..Layout: hLine, vLine, Spacer, rvstack, lvstack
import ..Tprint: tprintln
import ..Repr: termshow, type_fields
using ..LiveWidgets
import ..TermMarkdown: parse_md
import ..Consoles: console_width, console_height
import ..Style: apply_style, face, torow
import ..Compositors: Compositor
import ..Links: Link

include("_inspect.jl")

export inspect, typestree, expressiontree

# ---------------------------------------------------------------------------- #
#                                TYPES HIERARCHY                               #
# ---------------------------------------------------------------------------- #
"""
    typestree(T)
    typestree(io::IO, T)

Returns the type hierarchy for `T` in a pretty format. This is
done using colors, indentation and unicode for maximal readability.
The output included all supertypes, and one level of subtypes.

This function is not exported, so to use it you need to
use the `Term.typestree` syntax, or import it manually by
`import Term: typestree`

# Example
Below is an example showing the type tree for `Integer`. Note
that the colors of the output are not included in this docstring.
```
julia> Term.typestree(Integer)
╭─────────────────────────────────────── Types hierarchy ───╮
│  ┬                                                        │
│  ├─ Base.MultiplicativeInverses.MultiplicativeInverse ⇒   │
│  ├─ Complex ⇒                                             │
│  └─ Real ⇒ ┬                                              │
│            ├─ Rational ⇒                                  │
│            ├─ AbstractIrrational ⇒                        │
│            ├─ Integer ⇒ ┬                                 │
│            │            ├─ Signed ⇒                       │
│            │            ├─ Unsigned ⇒                     │
│            │            └─ Bool ⇒                         │
│            └─ AbstractFloat ⇒                             │
│                                                           │
╰───────────────────────────────────────────────────────────╯
```
"""
typestree(T::DataType; tree_kwargs = (;), kwargs...) = Panel(
    Tree(T; tree_kwargs...);
    title = "Types hierarchy",
    style = "$(TERM_THEME[].emphasis) dim",
    title_style = orange * " default",
    title_justify = :right,
    fit = true,
    kwargs...
)

function expressiontree(e::Expr; tree_kwargs = (;), kwargs...)
    _expr = expr2string(e)
    tree = Tree(e; tree_kwargs...)
    return Panel(
        tree;
        title = _expr,
        title_style = "$(TERM_THEME[].emphasis_light) default bold",
        title_justify = :center,
        style = grey_dark,
        fit = tree.measure.w > default_width(),
        width = max(tree.measure.w, default_width()),
        subtitle = "inspect",
        subtitle_justify = :right,
        justify = :center,
        kwargs...
    )
end
# ---------------------------------------------------------------------------- #
#                                EXPR. DENDOGRAM                               #
# ---------------------------------------------------------------------------- #

function inspect(expr::Expr; kwargs...)
    _expr = expr2string(expr)
    dendo = Dendogram(expr)

    return Panel(
        dendo;
        title = _expr,
        title_style = "$(TERM_THEME[].emphasis_light) default bold",
        title_justify = :center,
        style = TERM_THEME[].emphasis,
        fit = true,
        subtitle = "inspect",
        subtitle_justify = :right,
        justify = :center,
        kwargs...
    )
end
# ---------------------------------------------------------------------------- #
#                             INTROSPECT DATATYPES                             #
# ---------------------------------------------------------------------------- #

function style_methods(
        methods::Union{Vector{Base.Method}, Base.MethodList},
        docstrings::Vector,
        width::Int,
    )
    mets = []
    col = TERM_THEME[].inspect_highlight

    for (i, (m, docs)) in enumerate(zip(methods, docstrings))
        # method code, highlighted and wrapped as rows
        code = Renderable(reshape_rows(code_row(split(string(m), " in ")[1]), width))

        # get docstring
        docs = if !isnothing(docs)
            parse_md(something(docs, ""); width = width)
        else
            "{green}No docstring found{/green}"
        end
        docs = hLine(width, "DocString"; style = "green") / docs / ""

        # method source
        modul = rowcat(
            "Source: ",
            faced(string(m.module), face("bold $col")),
        )
        source = faced("$(m.file):$(m.line)", face("dim"))

        out = code / "" / docs
        push!(mets, out / hLine(width; style = "dim") / modul / source)
    end
    return mets
end

"""
    inspect(T::Union{Union, DataType})

Inspect a `DataType` to show info such as docstring, constructors and methods.
"""
function inspect(T::Union{Union, DataType})
    # get app size
    layout = :(A(4, 1.0) / B(30, 1.0))
    comp = Compositor(layout)
    widget_width = comp.elements[:B].w - 6

    # get fields
    theme = TERM_THEME[]

    # get each method as a Pager
    type_methods = style_methods(get_methods_with_docstrings(T)..., widget_width - 12)
    methods_pagers = map(
        m -> Pager(
            joinrows(rows(m[2]));
            title = "Method $(m[1]) of $(length(type_methods))",
            width = widget_width,
            page_lines = comp.elements[:B].h - 8,
        ),
        enumerate(type_methods),
    ) |> collect

    # create app
    menu = ButtonsMenu(
        ["Info", "Methods"];
        width = comp.elements[:A].w,
        height = comp.elements[:A].h - 1,
        layout = :horizontal,
    )

    # define widgets that go inside the top level Gallery: the pager is given
    # the rows themselves, joined, which are read as they are
    text = joinrows(
        rows(
            Panel(
                type_fields(T, theme);
                fit = false,
                width = widget_width - 10,
                justify = :center,
                title = "Fields",
                title_style = "bright_blue bold",
                style = "bright_blue dim",
            ) / hLine(widget_width - 10; style = "dim") / "" / Tree(T),
        ),
    )
    w, h = comp.elements[:B].w, comp.elements[:B].h
    gallery_widgets = [
        # first widget is a pager with struct info
        Pager(text; width = w - 1, page_lines = comp.elements[:B].h - 7),
        # inner gallery shows each method
        Gallery(methods_pagers; width = w - 1, height = comp.elements[:B].h - 2, show_panel = false),
    ]

    # make the app out of a menu and the top level gallery
    widgets = OrderedDict(
        :A => menu,
        :B => Gallery(
            gallery_widgets;
            controls = Dict(),
            width = w,
            height = h - 1,
            show_panel = false,
        ),
    )

    transition_rules = Dict(
        LiveWidgets.ArrowDown() => Dict(:A => :B),
        LiveWidgets.ArrowUp() => Dict(:B => :A),
    )

    cb(app) = app.widgets[:B].active = app.widgets[:A].active

    app = App(layout; widgets, transition_rules, on_draw = cb)
    play(app; transient = false)
    return nothing
end

function inspect(F::Function; documentation::Bool = true)
    hLine("inspecting: $F", style = "$(TERM_THEME[].text_accent)") |> print

    documentation && begin
        termshow(F)
        print("\n"^3)
    end
    return nothing
end

end
