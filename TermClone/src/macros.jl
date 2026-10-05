import .Style: face, ansi, torow

"""
    @style "text" style1 style2...

Applies a sequence of styles to a piece of text, such that

    println(@style "my text" bold green underline)

will print `my text` as bold, green and underlined
"""
macro style(text, styles...)
    markup = join(styles, " ")
    return quote
        local txt = $(esc(text))
        apply_style("{$($markup)}" * txt * "{/$($markup)}")
    end
end

# ------------------------- macros generating macros ------------------------- #
"""
Macro to create macros such as `@green` and `@bold`, which draw their text -
read as markup - in that face.
"""
macro make_style_macro(name)
    return quote
        macro $(esc(name))(text)
            style = $(string(name))
            return quote
                local txt = $(esc(text))
                ansi(faced(torow(txt), face($style)))
            end
        end
    end
end

@make_style_macro black
@make_style_macro red
@make_style_macro green
@make_style_macro yellow
@make_style_macro blue
@make_style_macro magenta
@make_style_macro cyan
@make_style_macro white
@make_style_macro default

@make_style_macro bold
@make_style_macro dim
@make_style_macro italic
@make_style_macro underline
