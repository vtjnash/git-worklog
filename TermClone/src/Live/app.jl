# ---------------------------------------------------------------------------- #
#                                APP  INTERNALS                                #
# ---------------------------------------------------------------------------- #
"""
    AppInternals

`AppInternals` handles "under the hood" work for live widgets: what was drawn
at the last refresh (an [`InlineView`](@ref), which redraws only the lines that
changed), when, and the terminal while the app is playing - a
`TermInput.HeldTerminal` from `enter_terminal`, taken in `play` and given back
by `stop!`.
"""
@with_repr mutable struct AppInternals
    view::InlineView
    term::Union{Nothing, HeldTerminal}
    prevcontent::Union{Nothing, AbstractRenderable}
    prevcontentlines::Vector{String}
    last_update::Union{Nothing, Int}
    refresh_Δt::Int
    help_shown::Bool
    help_message::Union{Nothing, String}
    should_stop::Bool

    function AppInternals(;
            refresh_rate::Int = 60,
            help_message = nothing,
        )
        return new(
            InlineView(stdout),
            nothing,
            nothing,
            String[],
            nothing,
            (Int ∘ round)(1000 / refresh_rate),
            false,
            help_message,
            false,
        )
    end
end

# ---------------------------------------------------------------------------- #
#                                      APP                                     #
# ---------------------------------------------------------------------------- #

# ------------------------------- CONSTRUCTORS ------------------------------- #
"""
An `App` is a collection of widgets.

!!! tip
    Transition rules bind keys to "movement" in the app to change
    focus to a different widget
"""
@with_repr mutable struct App <: AbstractWidgetContainer
    internals::AppInternals
    measure::Measure
    controls::AbstractDict
    parent::Union{Nothing, AbstractWidget}
    compositor::Compositor
    layout::Expr
    width::Int
    height::Int
    expand::Bool
    widgets::AbstractDict
    transition_rules::AbstractDict
    active::Symbol
    on_draw::Union{Nothing, Function}
    on_stop::Union{Nothing, Function}
end

isactive(::App) = true

"""
Execute a transition rule to switch focus to another widget.
"""
function execute_transition_rule(app::App, key)::Bool
    haskey(app.transition_rules, key) || return false
    rulesset = app.transition_rules[key]
    haskey(rulesset, app.active) || return false
    app.active = rulesset[app.active]
    return true
end

function quit(app::App)
    app.internals.should_stop = true
    return nothing
end

app_controls = Dict(
    'q' => quit,
    Esc() => quit,
    'h' => toggle_help,
    :setactive => execute_transition_rule,
)

"""
    App(
        widget::AbstractWidget;
        controls::AbstractDict = app_controls,
        width=1.0,
        height=min(40, console_height()),
        kwargs...
    )

Convenience constructor for an `App` with a single widget.
"""
function App(
        widget::AbstractWidget;
        controls::AbstractDict = app_controls,
        width = 1.0,
        height = min(40, console_height()),
        kwargs...,
    )
    layout = :(A($height, $width))
    return App(
        layout;
        widgets = Dict{Symbol, AbstractWidget}(:A => widget),
        controls = controls,
        height = height,
        width = fint(width * console_width()),
        kwargs...,
    )
end

function App(
        layout::Expr;
        widgets::Union{Nothing, AbstractDict} = nothing,
        transition_rules::Union{Nothing, AbstractDict} = nothing,
        width = console_width(),
        height = min(40, console_height()),
        controls::AbstractDict = app_controls,
        on_draw::Union{Nothing, Function} = nothing,
        on_stop::Union{Nothing, Function} = nothing,
        expand::Bool = true,
        help_message::Union{Nothing, String} = nothing,
    )

    # parse the layout expression and get the compositor
    compositor = Compositor(
        layout;
        max_w = min(console_width(), width),
        max_h = min(console_height(), height),
    )
    measure = render(compositor).measure

    # if widgets are not provided, create empty widgets placeholders
    widgets = if isnothing(widgets)
        make_placeholders(compositor)
    else
        widgets
    end

    # check that the layout and the widgets match
    layout_keys = compositor.elements |> keys |> collect
    widgets_keys = widgets |> keys |> collect
    @assert issetequal(layout_keys, widgets_keys) "Mismatch between widget names and layout names: $layout_keys vs $widgets_keys"

    on_activated(widgets[first(widgets_keys)])

    # enforce the size of each widget
    widgets = enforce_app_size(compositor, widgets)

    transition_rules =
        isnothing(transition_rules) ? infer_transition_rules(layout) : transition_rules

    app = App(
        AppInternals(;
            help_message
        ),
        measure,
        controls,
        nothing,
        compositor,
        layout,
        width,
        height,
        expand,
        widgets,
        transition_rules,
        widgets_keys[1],
        on_draw,
        on_stop,
    )

    set_as_parent(app)
    return app
end

"An expression and everything under it, parents first: AbstractTrees' walk of an `Expr`."
expr_preorder(ex) = ex isa Expr ? vcat(Any[ex], map(expr_preorder, ex.args)...) : Any[ex]

"""
    infer_transition_rules(layout::Expr)::Dict

If no transition rules are passed, infer them from the layout's
spatial relationships.
"""

function infer_transition_rules(layout::Expr)::Dict
    """ recursively get widgets in a  layout elements """
    function get_elements(elem::Expr)
        out = []
        for node in expr_preorder(elem)
            node isa Expr || continue
            node.args[1] ∉ (:*, :/) && push!(out, node.args[1])
        end
        return out
    end
    get_elements(x) = nothing

    transition_rules = Dict(
        ArrowRight() => Dict(),
        ArrowLeft() => Dict(),
        ArrowDown() => Dict(),
        ArrowUp() => Dict(),
    )

    for node in expr_preorder(layout)
        if node isa Expr
            op = node.args[1]
            op ∈ (:*, :/) || continue
            source = get_elements(node.args[2])
            dest = get_elements(node.args[3])

            # store commands to and from widgets
            first_key, second_key =
                op == :* ? (ArrowRight(), ArrowLeft()) : (ArrowDown(), ArrowUp())
            for w in source
                transition_rules[first_key][w] = dest[1]
            end
            for w in dest
                transition_rules[second_key][w] = source[1]
            end
        end
    end

    return transition_rules
end

"""
If no widget was passed, create placeholder widgets.
"""
function make_placeholders(compositor)
    elements = compositor.elements
    colors = if length(elements) > 1
        getfield.(Palette(blue, pink; N = length(elements)).colors, :string)
    else
        [pink]
    end

    ws = Dict()
    for (i, (name, elem)) in enumerate(pairs(elements))
        ws[name] = PlaceHolderWidget(elem.h, elem.w, string(name), colors[i])
    end
    return ws
end

"""
    enforce_app_size(compositor::Compositor, widgets::AbstractDict)

Called when an App is first created to set the size of all widgets.
"""
function enforce_app_size(compositor::Compositor, widgets::AbstractDict)
    _keys = widgets |> keys |> collect

    for k in _keys
        elem, wdg = compositor.elements[k], widgets[k]
        wdg.internals.measure = Measure(elem.h, elem.w)
        on_layout_change(wdg, wdg.internals.measure)
    end
    return widgets
end

"""
    enforce_app_size(app::App, measure::Measure)

Called when a console is resized to adjust the apps layout.
"""
function enforce_app_size(app::App, measure::Measure)
    compositor = Compositor(app.layout; max_w = measure.w, max_h = measure.h)
    _keys = app.widgets |> keys |> collect

    for k in _keys
        elem, wdg = compositor.elements[k], app.widgets[k]
        wdg.internals.measure = Measure(elem.h, elem.w)
        on_layout_change(wdg, wdg.internals.measure)
    end

    return app.compositor = compositor
end

# ----------------------------------- frame ---------------------------------- #

"""
    on_layout_change(app::App)

Called when the console is resized to adjust the apps layout.
"""
function on_layout_change(app::App)
    new_width = app.expand ? console_width() : min(app.width, console_width())
    new_width == app.measure.w && return

    # a terminal reflows what was drawn at the old width: clear it, where the
    # app draws, and only once it has drawn something
    if !isnothing(app.internals.prevcontent)
        erase!(app)
        clear(app.internals.view.io)
    end

    # the console is too small, re-design
    app.measure = Measure(app.measure.h, new_width)
    return enforce_app_size(app, app.measure)
end

"""
    frame(app::App)

Render the app and its content.
"""
function frame(app::App; kwargs...)
    isnothing(app.on_draw) || app.on_draw(app)

    # adjust size to changes in console
    on_layout_change(app)

    for (name, widget) in pairs(app.widgets)
        # toggle active
        if length(app.widgets) > 1
            app.active == name ? widget.internals.on_activated(widget) :
                widget.internals.on_deactivated(widget)
        end

        content = frame(widget)

        update!(app.compositor, name, content)
    end

    # reset the activation state of each widget
    for widget in values(app.widgets)
        # wasactive, willbeactive = widget.internals.active, isactive(widget)
        # !wasactive && willbeactive && widget.internals.on_activated(widget)

        widget.internals.active = isactive(widget)
    end

    return render(app.compositor)
end

"""
    add_debugging_info!(content::AbstractRenderable, app::App)::AbstractRenderable

Add debugging information to the top of the app.
"""
function add_debugging_info!(content::AbstractRenderable, app::App)::AbstractRenderable
    # print the app's layout as a TREE
    tree = sprint(print, app)

    debug_info = Panel(tree; width = content.measure.w)
    return debug_info / content
end

# ---------------------------------------------------------------------------- #
#                                   RENDERING                                  #
# ---------------------------------------------------------------------------- #

"""
    shouldupdate(app::App)::Bool

Check if a widget's display should be updated based on:
    1. enough time elapsed since last update
    2. the widget has not beed displayed het
"""
function shouldupdate(app::App)::Bool
    currtime = Dates.value(now())
    isnothing(app.internals.last_update) && begin
        app.internals.last_update = currtime
        return true
    end

    Δt = currtime - app.internals.last_update
    if Δt > app.internals.refresh_Δt
        app.internals.last_update = currtime
        return true
    end
    return false
end

"""
    refresh!(app::App)

Handle a key if one is waiting, and draw the app again if it is time to.

The content is `frame(app)`: rows, which the app's `InlineView` writes over
what it drew last, rewriting only the lines that changed, in one write.
"""
function refresh!(app::App)
    # check for keyboard inputs
    retval = keyboard_input(app)
    app.internals.should_stop && return something(retval, [])

    # check if its time to update
    shouldupdate(app) || return nothing
    redraw!(app)
    return nothing
end

"Draw the app where it was drawn last."
function redraw!(app::App)
    internals = app.internals
    content::AbstractRenderable = frame(app)

    LIVE_DEBUG[] == true && begin
        content = add_debugging_info!(content, app)
    end

    rs = rows(content)
    t = internals.term
    internals.view.io = isnothing(t) ? stdout : t.out
    draw!(internals.view, rs)
    internals.prevcontent = content
    internals.prevcontentlines = String[ansi(r) for r in rs]
    return nothing
end

"""
    erase!(app::App)

Erase a app from the terminal.
"""
function erase!(app::App)
    isnothing(app.internals.prevcontent) && return
    erase!(app.internals.view)
    return nothing
end

"""
    stop!(app::App)

Restore normal terminal behavior: what `enter_terminal` did, undone.
"""
function stop!(app::App)
    internals = app.internals
    isnothing(internals.term) || leave_terminal(internals.term)
    internals.term = nothing
    ACTIVE_TERMINAL[] = nothing
    return nothing
end

"""
    play(app::App; transient::Bool=true)

Keep refreshing a renderable, until the user interrupts it.

The loop waits on one channel: a `TermInput.InputReader` puts each key (and
paste) on it, and a timer a tick at the app's refresh rate - which is what
draws a blinking cursor or a widget whose `on_draw` changes it between keys.
"""
function play(app::App; transient::Bool = true, input::IO = stdin, output::IO = stdout)
    internals = app.internals
    t = enter_terminal(input, output; paste = true)
    internals.term = t
    ACTIVE_TERMINAL[] = t
    internals.should_stop = false
    internals.view = InlineView(output)

    events = Channel{Any}(64)
    reader = InputReader(t, events)
    arm!(reader)
    timer = Timer(0; interval = internals.refresh_Δt / 1000) do _
        isready(events) || put!(events, :tick)
    end

    retval = []
    try
        redraw!(app)
        while true
            ev = take!(events)
            if ev isa KeyEvent
                # raw mode makes ^c a key, and Term's apps bind nothing to it:
                # here it stops the app, as it would have stopped the program
                ev.code == 3 && break
                retval = keyboard_input(app, ev.code)
                internals.should_stop && break
                input_waiting(t) || redraw!(app)
                arm!(reader)
            elseif ev isa PasteEvent
                paste_input(app, ev.text)
                redraw!(app)
                arm!(reader)
            elseif ev isa EndEvent
                break
            elseif ev === :tick
                shouldupdate(app) && redraw!(app)
            else
                arm!(reader)
            end
        end
    finally
        close(timer)
        close(reader)
        if transient
            erase!(app)
        else
            leave!(internals.view)
        end
        stop!(app)
    end

    return length(retval) > 0 ? retval[1] : nothing
end
