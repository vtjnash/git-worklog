"""
    keyboard_input(widget::AbstractWidget, code::Int)

One key, as a `TermInput` key code (`readevent`'s), to `widget`: its control
for the key - Term's named keys and characters, see [`keyinput`](@ref) - or,
where it has none, the TermInput widget under it ([`on_key`](@ref)). Returns
what the control returned, or `[]`.
"""
function keyboard_input(widget::AbstractWidget, code::Int)
    controls = widget.controls
    c = keyinput(code)
    if !isnothing(c)
        # see if a control has been defined for this key
        haskey(controls, c) && return controls[c](widget, c)

        # see if we can just pass any character
        c isa Char && haskey(controls, Char) && return controls[Char](widget, c)
    end
    on_key(widget, code)
    return []
end

"""
    keyboard_input(widget::AbstractWidgetContainer, code::Int)

One key to the container's widgets, in order: a transition rule moves the focus,
and otherwise each active widget's control for the key runs - or, for the one
that has the keyboard and no control for it, its TermInput widget's handling.
"""
function keyboard_input(widget::AbstractWidgetContainer, code::Int)
    retvals = []
    c = keyinput(code)
    claimed = false

    # execute command on each subwidget
    for wdg in preorder(widget)
        retval = nothing
        controls = wdg.controls

        # see if key is an app control key
        if !isnothing(c) && haskey(controls, :setactive)
            control_exectued = controls[:setactive](wdg, c)
            control_exectued && return retval
        end

        # only apply to active widget(s)
        isactive(wdg) || continue

        if !isnothing(c)
            # see if a control has been defined for this key
            haskey(controls, c) && (retval = controls[c](wdg, c); claimed = true)

            # see if we can just pass any character
            c isa Char && haskey(controls, Char) &&
                (retval = controls[Char](wdg, c); claimed = true)
        end

        # if retval says so, stop looking at other widgets here
        retval == :stop && break
        isnothing(retval) || push!(retvals, retval)
    end

    # a key no control took goes to the focused leaf's TermInput widget
    if !claimed
        leaf = widget
        while !isnothing(get_active(leaf))
            leaf = get_active(leaf)
        end
        leaf === widget || on_key(leaf, code)
    end
    return retvals
end

"""
    keyboard_input(widget)

Term's polling form: a key if one is already waiting on the terminal an app is
playing on, `[]` otherwise.
"""
function keyboard_input(widget::AbstractWidget)
    t = ACTIVE_TERMINAL[]
    (isnothing(t) || !input_waiting(t)) && return []
    ev = readevent(t)
    ev isa KeyEvent || return []
    return keyboard_input(widget, ev.code)
end

"""
    paste_input(widget, text)

A bracketed paste: the text, to the focused widget if it has somewhere to put
it - an `InputBox`'s `TextArea` - and nowhere otherwise. Never keys, so a `q`
in it does not quit.
"""
function paste_input(widget::AbstractWidget, text::AbstractString)
    leaf = widget
    while !isnothing(get_active(leaf))
        leaf = get_active(leaf)
    end
    if leaf isa InputBox
        TermInput.paste!(leaf.textarea, text)
        leaf.typed = true
    end
    return nothing
end
