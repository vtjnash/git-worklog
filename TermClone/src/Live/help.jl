"""
The faces markdown is drawn in, in the help: Term's theme's emphasis for the
headings and code, bold and italic as they are.
"""
help_markdown_style() = MarkdownStyle(
    h1 = face("bold " * TERM_THEME[].emphasis),
    h2 = face("bold " * TERM_THEME[].emphasis),
    h3 = face("bold " * TERM_THEME[].emphasis),
    h4 = face("bold " * TERM_THEME[].emphasis),
    bold = face("bold"),
    italic = face("italic"),
    code = face(TERM_THEME[].code),
    codeblock = face(TERM_THEME[].code),
    note = face("blue"),
    tip = face("green"),
    warning = face("yellow"),
    danger = face("red"),
)

"""
    md_renderable(md, width) -> Renderable

A parsed markdown document as rows `width` wide - `TermInput.markdown_rows`,
which draws a docstring or a help message the way a widget is drawn.
"""
function md_renderable(md, width::Int)
    md isa Markdown.MD || (md = Markdown.parse(string(md)))
    rs = Row[r.text for r in markdown_rows(md, max(width, 1); style = help_markdown_style())]
    isempty(rs) && (rs = Row[row("")])
    return Renderable(rs)
end

"""
display/hide help tooltip
"""
function toggle_help(app, args...)
    internals = app.internals
    width = app.measure.w
    msg = if !isnothing(internals.help_message)
        md_renderable(Markdown.parse(app.internals.help_message), width - 6)
    else
        RenderableText("{dim} no help message shown{/dim}")
    end

    # get the docstring of the currently active widget
    active_widget = app.widgets[app.active]
    widget_msg = md_renderable(getdocs(active_widget), max(20, width - 6))

    # get the docstring of each control method
    col = TERM_THEME[].text_accent
    all_controls = [pairs(active_widget.controls)..., pairs(app.controls)...]
    already_added = []
    controls = []

    for (k, c) in all_controls
        (k ∈ already_added || k isa Symbol) && continue
        push!(
            controls,
            RenderableText("{bold $col} - $(k){/bold $col}: ") *
                md_renderable(getdocs(c), max(20, width - 20)),
        )
        push!(already_added, k)
    end
    # create content
    content = [
        msg,
        "",
        md_renderable(md"#### Active widget: $(typeof(active_widget))", width - 10),
        "",
        widget_msg,
        "",
        md_renderable(md"#### Controls", width - 10),
        controls...,
    ]

    # create full message
    help_message = Panel(
        content;
        width = width,
        title = "Help",
        title_style = "default bold blue",
        title_justify = :center,
        style = "dim",
    )

    # show/hide message
    if internals.help_shown
        # hide it
        internals.help_shown = false

        # go to the top of the error message and delete everything
        h = (
            console_height() -
                length(internals.prevcontentlines) -
                help_message.measure.h -
                1
        )
        move_to_line(stdout, h)
        cleartoend(stdout)

        # move cursor back to the top of the live to re-print it in the right position
        move_to_line(stdout, console_height() - length(internals.prevcontentlines))
    else
        # show it
        erase!(app)
        println(stdout, help_message)
        internals.help_shown = true
    end

    internals.prevcontent = nothing
    return internals.prevcontentlines = String[]
end
