"""
    module Prompts

Defines functionality relative to prompts in the terminal. 
Typically a prompt is composed of a piece of text that gets displayed prompting
the user to provide an input and some machinery to parse/validate the user's inputs.
For example, some prompts may only accept as replies objects of a given type (e.g. an `Int`).
Additionally, some prompts will have "options" the user can choose between and the answer
has to be one of these options.
"""
module Prompts

import Term
import Term: highlight, TERM_THEME
import ..Style: apply_style, torow, ansi, face
import TermInput: rowcat, faced
import ..Tprint: tprint, tprintln
import ..Measures: width as get_width
import ..Consoles: console_width
import ..LiveWidgets: InlineView, draw!, erase!, widget_rows
import TermInput
import TermInput: LineInput, Choice, KeyEvent, PasteEvent, EndEvent, readevent,
    enter_terminal, leave_terminal, handle!, picked, submission, DIALOG_WIDTH
import TermInput.Keys: C_G
import ..Repr: @with_repr, termshow

export Prompt, TypePrompt, OptionsPrompt, DefaultPrompt, confirm, ask

"""
At a terminal, a prompt is asked with one of TermInput's widgets, drawn under
the cursor and redrawn there as keys arrive: a `LineInput` for an answer that is
typed, a `Choice` for one of some options. Anywhere else - stdin a pipe or a
file - it is printed and the answer read with `readline`, as Term does.
`ask(io, prompt; input, widget)` says where the keys come from and which of
the two it is, so the widget can be driven from an `IOBuffer` of key bytes.

Prompts in VSCODE require a bit of a hack:
https://discourse.julialang.org/t/vscode-errors-with-user-input-readline/75097/4?u=fedeclaudi

When the text is displayed, the user should input "space" and a new line before inputting the
actual reponse. This is not a Term.jl problem.
"""

# ------------------------------ abstract prompt ----------------------------- #

""" Prompt types """
abstract type AbstractPrompt end

_print_prompt_text(io::IO, prompt::AbstractPrompt) =
    tprintln(io, "{$(prompt.style)}{dim}❯❯❯ {/dim}" * prompt.prompt * "{/$(prompt.style)}")

"""
    Base.print(io::IO, prompt::AbstractPrompt)

Default prompt printing, just prints the message `prompt`
with a bit of style.
"""
Base.print(io::IO, prompt::AbstractPrompt) = _print_prompt_text(io, prompt)

"""
    ask

Ask does three things:
  1. displays a prompt
  2. accepts user input and validates it
  3. if the answer was accepted, returns the desired value.
"""
function ask end

""" 
    ask(io::IO, prompt::AbstractPrompt)

Default `ask` method for generic prompt objects.
"""
function ask(io::IO, prompt::AbstractPrompt; input::IO = stdin,
        widget::Bool = input isa Base.TTY)
    if widget
        ans = ask_widget(io, input, prompt)
        isnothing(ans) && return nothing
    else
        print(io, prompt)
        ans = readline(input)
    end
    return validate_answer(ans, prompt)
end

ask(prompt::AbstractPrompt; kwargs...) = ask(stdout, prompt; kwargs...)

"""
    validate_answer

Validate user's answer for a prompt type.
The validation mechanism depends on the type of prompt.
Validate answer will return the answer if it passed validation
or raise and error otherwise.
"""
function validate_answer end

# -------------------------- answer validation error ------------------------- #

"""
    AnswerValidationError <: Exception

Exception to handle cases in which the user's answer to a
prompt failed to pass validation.
"""
struct AnswerValidationError <: Exception
    answer_type
    expected_type
    err
end

Base.showerror(io::IO, e::AnswerValidationError) = print(
    io,
    highlight(
        "TypePrompt expected an answer of type: `$(e.expected_type)`, got `$(e.answer_type)` instead\nConversion to `$(e.expected_type)` failed because of: $(e.err)",
    ) |> apply_style,
)

# ---------------------------------------------------------------------------- #
#                                    PROMPT                                    #
# ---------------------------------------------------------------------------- #

"""
    struct Prompt{T} <: AbstractPrompt
        prompt::String
        style::String = TERM_THEME[].prompt_text
    end

Generic prompt, accepts any answer
"""
@with_repr struct Prompt <: AbstractPrompt
    prompt::String
    style::String
end
Prompt(prompt::String) = Prompt(prompt, TERM_THEME[].prompt_text)

validate_answer(ans, ::Prompt) = ans

# ---------------------------------------------------------------------------- #
#                                  TYPE PROMPT                                 #
# ---------------------------------------------------------------------------- #

"""
    struct TypePrompt{T}
        answer_type::Union{Union, DataType} = T
        prompt::String
    end

Asks for input given `prompt` and checks/converts the answer to type `T`
"""
struct TypePrompt{T} <: AbstractPrompt
    answer_type::T
    prompt::String
    style::String
end

TypePrompt(answer_type, prompt::String) =
    TypePrompt(answer_type, prompt, TERM_THEME[].prompt_text)

"""
    validate_answer(answer, prompt::TypePrompt)

For a TypePrompt an anwer is valid if it is of the correct type
or if a string containg the answer can be parsed as the correct type.
For example, `answer="1.0"` can be accepted for a TypePrompt
asking for a `Number`.
If validation fails, an error is raised.
"""
function validate_answer(answer, prompt::TypePrompt)
    answer isa prompt.answer_type && return answer

    err = nothing
    try
        return parse(prompt.answer_type, answer)
    catch err
    end
    throw(
        AnswerValidationError(typeof(answer), prompt.answer_type, apply_style(string(err))),
    )
end

# ---------------------------------------------------------------------------- #
#                                OPTIONS PROMPTS                               #
# ---------------------------------------------------------------------------- #
""" Prompt types where user can only choose among options """
abstract type AbstractOptionsPrompt <: AbstractPrompt end

"""
    struct OptionsPrompt <: AbstractOptionsPrompt
        options::Vector{String}
        prompt::String
        style::String 
        answers_style::String
    end

Just a simple prompt, giving some pre-defined options.
"""
@with_repr struct OptionsPrompt <: AbstractOptionsPrompt
    options::Vector{String}
    prompt::String
    style::String
    answers_style::String
end

OptionsPrompt(options, prompt::String) =
    OptionsPrompt(options, prompt, TERM_THEME[].prompt_text, TERM_THEME[].prompt_options)

"""
    Base.print(io::IO, prompt::AbstractOptionsPrompt)

Options prompts additionally print the available options. 
"""
function Base.print(io::IO, prompt::AbstractOptionsPrompt)
    _print_prompt_text(io, prompt)
    return tprint(
        io,
        " {$(prompt.answers_style)}" *
            join(prompt.options, " {$(prompt.style)}/{/$(prompt.style)} ") *
            "{/$(prompt.answers_style)}";
        highlight = false,
    )
end

"""
    validate_answer(answer, prompt::AbstractOptionsPrompt)

For an AbstractOptionsPrompt an answer is accepted if its one of the options.
Additionally, for an `AbstractDefaultPrompt`, if no answer is given that's
also accepted and the default option is returned.
"""
function validate_answer(answer, prompt::AbstractOptionsPrompt)
    (prompt isa AbstractDefaultPrompt && strip(answer) == "") &&
        return prompt.options[prompt.default]
    strip(answer) ∉ prompt.options && begin
        tprintln("{dim}Answer `$(answer)` is not valid.{/dim}")
        return nothing
    end
    return answer
end

"""
    ask(io::IO, prompt::AbstractOptionsPrompt)

In asking an `AbstractOptionsPrompt`, keep asking for input
until an accepted answer is provided.
"""
function ask(io::IO, prompt::AbstractOptionsPrompt; input::IO = stdin,
        widget::Bool = input isa Base.TTY)
    widget && return ask_widget(io, input, prompt)
    ans = nothing
    while isnothing(ans)
        println(io, prompt)
        ans = validate_answer(readline(input), prompt)
    end
    return ans
end

# ---------------------------------------------------------------------------- #
#                                DEFAULT PROMPT                                #
# ---------------------------------------------------------------------------- #

""" Options prompt types with a default answer """
abstract type AbstractDefaultPrompt <: AbstractOptionsPrompt end

"""

"""
@with_repr struct DefaultPrompt <: AbstractDefaultPrompt
    options::Vector{String}
    default::Int
    prompt::String
    style::String
    answers_style::String
    default_answer_style::String

    function DefaultPrompt(options::Vector, default::Int, prompt::String, args...)
        @assert default > 0 && default <= length(options) "Default answer number: $default not valid"
        new(options, default, prompt, args...)
    end
end

function DefaultPrompt(options::Vector, default::Int, prompt::String)
    return DefaultPrompt(
        options,
        default,
        prompt,
        TERM_THEME[].prompt_text,
        TERM_THEME[].prompt_options,
        TERM_THEME[].prompt_default_option,
    )
end

"""
    Base.print(io::IO, prompt::AbstractDefaultPrompt)

Print a prompt with style applied to the default option.
"""
function Base.print(io::IO, prompt::AbstractDefaultPrompt)
    n_options = length(prompt.options)
    _print_prompt_text(io, prompt)
    answer_styles = map(
        i -> i == prompt.default ? prompt.default_answer_style : prompt.answers_style,
        1:n_options,
    )
    options = join(
        (
            map(
                i -> "{$(answer_styles[i])}$(prompt.options[i]){/$(answer_styles[i])}",
                1:n_options,
            )
        ),
        ", ",
    )
    return tprint(io, " " * options)
end

confirm(; kwargs...) = ask(DefaultPrompt(["yes", "no"], 1, "Confirm?"); kwargs...)

# ---------------------------------------------------------------------------- #
#                               ASKING AT A TERMINAL                           #
# ---------------------------------------------------------------------------- #

"The prompt's question, as the title of a widget: its words, without markup."
prompt_title(prompt::AbstractPrompt) = String(torow(prompt.prompt))

"""
    prompt_widget(prompt) -> widget

The TermInput widget a prompt is asked with.

  * `Prompt`, `TypePrompt`: a `LineInput`; a `TypePrompt` says the type it
    wants under the question.
  * `OptionsPrompt`: a `Choice` of the options. Typing narrows them, which is
    Term's "type one of the options" with the typing checked as it happens.
  * `DefaultPrompt`: a `Choice` with the cursor on the default, so that `↵`
    alone takes it - Term's empty answer. Not a `Confirm`: there only named
    keys answer and `↵` is no, which is the opposite of what a default means,
    and a `DefaultPrompt` may have more than two options.
"""
prompt_widget(prompt::Prompt) = LineInput(prompt_title(prompt), "";
    hint = "↵ answer · esc cancel")
prompt_widget(prompt::TypePrompt) = LineInput(prompt_title(prompt),
    "a $(prompt.answer_type)"; hint = "↵ answer · esc cancel")
prompt_widget(prompt::AbstractOptionsPrompt) = Choice(prompt_title(prompt), "",
    prompt.options; hint = "↑/↓ move · type to narrow · ↵ pick · esc cancel")
function prompt_widget(prompt::AbstractDefaultPrompt)
    c = Choice(prompt_title(prompt), "", prompt.options;
        hint = "↵ $(prompt.options[prompt.default]) · ↑/↓ move · type to narrow · esc cancel")
    c.sel = prompt.default
    return c
end

"""
    answer_for(prompt, widget, code) -> Union{Nothing, String}

What key `code` answers, once the widget has not taken it: the line on `↵` for
a typed answer - checked as `validate_answer` checks it, and refused with the
reason in the widget's status line rather than an exception - and the option
`↵` picks in a `Choice`. `nothing` for a key that answers nothing.
"""
function answer_for(prompt::AbstractPrompt, li::LineInput, code::Int)
    code in (13, 10) || return nothing
    ans = submission(li)
    try
        validate_answer(ans, prompt)
    catch err
        err isa AnswerValidationError || rethrow()
        li.status = "not a $(prompt.answer_type): $(repr(ans))"
        return nothing
    end
    return ans
end
function answer_for(prompt::AbstractOptionsPrompt, c::Choice, code::Int)
    i = picked(c, code)
    return i > 0 ? prompt.options[i] : nothing
end

"""
    ask_widget(io, input, prompt) -> Union{Nothing, String}

Ask `prompt` with its widget, drawn inline at `io`'s cursor, reading keys from
`input` with `readevent`. The answer as the text it is, or `nothing` when it is
given up - escape or `^g` - which Term's `readline` has no way to say. `^c`
interrupts.
"""
function ask_widget(io::IO, input::IO, prompt::AbstractPrompt)
    widget = prompt_widget(prompt)
    w = min(console_width(io), DIALOG_WIDTH + 4)
    view = InlineView(io)
    t = enter_terminal(input, io; paste = true)
    ans = nothing
    try
        while true
            draw!(view, widget_rows(widget, w)...)
            ev = readevent(t)
            if ev isa PasteEvent
                TermInput.paste!(widget, ev.text)
                continue
            end
            ev isa EndEvent && break
            ev isa KeyEvent || continue
            k = ev.code
            k == 3 && throw(InterruptException())
            handle!(widget, k) === :ok && continue
            k in (27, C_G) && break
            ans = answer_for(prompt, widget, k)
            isnothing(ans) || break
        end
    finally
        erase!(view)
        leave_terminal(t)
    end
    # what was asked and answered, as Term leaves it on the screen
    # - the answer as a row of its own, since a `{` typed in it is not markup
    asked = torow("{$(prompt.style)}{dim}❯❯❯ {/dim}" * prompt.prompt * "{/$(prompt.style)} ")
    said = isnothing(ans) ? faced("(cancelled)", face("dim")) :
        faced(ans, face(TERM_THEME[].prompt_options))
    println(io, ansi(rowcat(asked, said)))
    return ans
end

end
