"""
Collection of small widgets
"""

# ---------------------------------------------------------------------------- #
#                                  TEXT WIDGET                                 #
# ---------------------------------------------------------------------------- #

# ------------------------------- constructors ------------------------------- #
"""
TextWidget just shows a piece of text.
"""
@with_repr mutable struct TextWidget <: AbstractWidget
    internals::WidgetInternals
    controls::AbstractDict
    text::String
    as_panel::Bool
    panel_kwargs
end

text_widget_controls = Dict('q' => quit, Esc() => quit)

TextWidget(
    text::String;
    as_panel = false,
    on_draw::Union{Nothing, Function} = nothing,
    on_activated::Function = on_activated,
    on_deactivated::Function = on_deactivated,
    controls = text_widget_controls,
    kwargs...,
) = TextWidget(
    WidgetInternals(
        Measure(Measure(text).h, console_width()),
        nothing,
        on_draw,
        on_activated,
        on_deactivated,
        false,
    ),
    controls,
    text,
    as_panel,
    Dict{Symbol, Any}(kwargs),
)

on_layout_change(t::TextWidget, m::Measure) = t.internals.measure = m

# ----------------------------------- frame ---------------------------------- #
function frame(tw::TextWidget; kwargs...)
    isnothing(tw.internals.on_draw) || tw.internals.on_draw(tw)
    measure = tw.internals.measure

    panel_kwargs = copy(tw.panel_kwargs)
    if :style ∈ keys(tw.panel_kwargs)
        panel_kwargs[:style] = panel_kwargs[:style] * (isactive(tw) ? " bold red" : " dim")
    else
        panel_kwargs[:style] = isactive(tw) ? " bold red" : "dim"
    end

    tw.as_panel && return Panel(
        tw.text;
        width = measure.w,
        height = measure.h,
        fit = false,
        panel_kwargs...,
    )

    # the text wrapped as rows; an active widget has a rule down its left
    txt = if !isactive(tw)
        joinrows(reshape_rows(tw.text, measure.w - 4))
    else
        rs = reshape_rows(tw.text, measure.w - 6)
        joinrows(rows(vLine(length(rs)) * Renderable(rs)))
    end

    return RenderableText(txt; width = measure.w - 4)
end

# ---------------------------------------------------------------------------- #
#                                   INPUT BOX                                  #
# ---------------------------------------------------------------------------- #

# ------------------------------- constructors ------------------------------- #
"""
InputBox collects and displays user input as text.

What is typed is held by a `TermInput.TextArea`: the cursor moves, and the
readline keys (`^a`/`^e`, `^w`, `⌥⌫`, `^k`, `^y`, the arrows - those an `App`
does not take to move between widgets) edit as they do there. `⌥e` hands the
text to `\$EDITOR`.
"""
@with_repr mutable struct InputBox <: AbstractWidget
    internals::WidgetInternals
    controls::AbstractDict
    textarea::TextArea
    typed::Bool
    blinker_update::Int
    blinker_status::Symbol
    panel_kwargs::Dict{Symbol, Any}
end

# Term's field: the text, or `nothing` until something has been typed.
function Base.getproperty(ib::InputBox, f::Symbol)
    f === :input_text &&
        return getfield(ib, :typed) ? TermInput.text(getfield(ib, :textarea)) : nothing
    return getfield(ib, f)
end
function Base.setproperty!(ib::InputBox, f::Symbol, v)
    if f === :input_text
        setfield!(ib, :typed, !isnothing(v))
        TermInput.settext!(getfield(ib, :textarea).buf, something(v, ""))
        return v
    end
    return setfield!(ib, f, convert(fieldtype(InputBox, f), v))
end
Base.propertynames(::InputBox) = (fieldnames(InputBox)..., :input_text)

"Hand one key to the box's `TextArea`, and say whether it was used."
function edit!(ib::InputBox, code::Int)
    t = ACTIVE_TERMINAL[]
    r = if isnothing(t)
        handle!(ib.textarea, code)
    else
        handle!(ib.textarea, code; suspend = f -> TermInput.suspend(f, t))
    end
    r === :ok && (ib.typed = true)
    return r
end

"""
new line
"""
newline(ib::InputBox, ::Enter) = (edit!(ib, 13); ib.input_text)

""" insert space """
addspace(ib::InputBox, ::SpaceBar) = (edit!(ib, 32); ib.input_text)

""" delete the character before the cursor """
del(ib::InputBox, ::Del) = (edit!(ib, 127); ib.input_text)

""" add character to input """
addchar(ib::InputBox, c::Char) = (edit!(ib, keycode(c)); ib.input_text)

on_key(ib::InputBox, code::Int) = edit!(ib, code)

input_box_controls = Dict(
    Enter() => newline,
    SpaceBar() => addspace,
    Del() => del,
    Esc() => quit,
    Char => addchar,
)

function InputBox(;
        controls::AbstractDict = input_box_controls,
        on_draw::Union{Nothing, Function} = nothing,
        on_activated::Function = on_activated,
        on_deactivated::Function = on_deactivated,
        kwargs...,
    )
    return InputBox(
        WidgetInternals(
            Measure(5, console_width()),
            nothing,
            on_draw,
            on_activated,
            on_deactivated,
            false,
        ),
        controls,
        TextArea(""),
        false,
        0,
        :off,
        Dict{Symbol, Any}(kwargs),
    )
end

on_layout_change(ib::InputBox, m::Measure) = ib.internals.measure = m

"""
    inputbox_rows(ib, w, blink) -> Row

The text as the `TextArea`'s buffer wraps it to `w` columns, with Term's
blinking block where the cursor is: a space after the text in its `on_white`
phase, or the character under a cursor moved back into it in reverse video.
"""
function inputbox_rows(ib::InputBox, w::Int, blink::Bool, active::Bool)
    strs, crow, ccol = TermInput.bufferrows(ib.textarea.buf, max(1, w))
    rs = Row[row(s) for s in strs]
    active || return joinrows(rs)
    r = rs[crow]
    if ccol > rowwidth(r)
        rs[crow] = blink ? drawcursor(r, ccol, face("on_white")) : rowcat(r, " ")
    elseif blink
        # over a character, reverse video: on_white would hide a white one
        rs[crow] = drawcursor(r, ccol)
    end
    return joinrows(rs)
end

# ----------------------------------- frame ---------------------------------- #
function frame(ib::InputBox; kwargs...)
    isnothing(ib.internals.on_draw) || ib.internals.on_draw(ib)

    # the block blinks: Term's timing
    currtime = Dates.value(now())
    if currtime - ib.blinker_update > 300
        ib.blinker_update = currtime
        ib.blinker_status = ib.blinker_status == :on ? :off : :on
    end

    panel_kwargs = copy(ib.panel_kwargs)
    panel_kwargs[:style] = get(ib.panel_kwargs, :style, "") * (isactive(ib) ? "" : " dim")
    measure = ib.internals.measure

    # get text to display
    text = if !ib.typed
        torow("{dim}start typing...{/dim}")
    else
        # what the panel leaves for its content: borders and padding (2, 2)
        inputbox_rows(ib, measure.w - 6, ib.blinker_status == :off, isactive(ib))
    end
    return Panel(text; width = measure.w, height = measure.h, panel_kwargs...)
end

# ---------------------------------------------------------------------------- #
#                                  PLACEHOLDER                                 #
# ---------------------------------------------------------------------------- #

"""
Widget with no content to be used as a placeholder for choosing app layout.
"""
mutable struct PlaceHolderWidget <: AbstractWidget
    internals::WidgetInternals
    controls::AbstractDict
    color::String
    style::String
    name::String
end

on_layout_change(ph::PlaceHolderWidget, m::Measure) = ph.internals.measure = m

function on_activated(ph::PlaceHolderWidget)
    ph.internals.active = true
    return ph.style = "bold"
end
function on_deactivated(ph::PlaceHolderWidget)
    ph.internals.active = false
    return ph.style = "dim"
end

function PlaceHolderWidget(
        h::Int,
        w::Int,
        name::String,
        color::String;
        on_draw::Union{Nothing, Function} = nothing,
        on_activated::Function = on_activated,
        on_deactivated::Function = on_deactivated,
    )
    internals = WidgetInternals(
        Measure(h, w),
        nothing,
        on_draw,
        on_activated,
        on_deactivated,
        false,
    )

    return PlaceHolderWidget(internals, text_widget_controls, color, "dim", name)
end

function frame(ph::PlaceHolderWidget; kwargs...)
    isnothing(ph.internals.on_draw) || ph.internals.on_draw(ph)
    m = ph.internals.measure
    return PlaceHolder(
        m.h,
        m.w;
        style = "$(ph.color) $(ph.style)",
        text = "$(ph.name) ($(m.h), $(m.w)",
    )
end
