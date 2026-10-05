"""
Reshaping strings with Julia code requires particular care
"""
function reshape_code_string(code, width::Int)
    # highlight: Term's regexes, which leave text that is already in escapes alone
    code = apply_style(highlight(code; ignore_ansi = false); leave_orphan_tags = true)

    # reshape: each line wrapped as a row, its faces kept on whichever row
    return Style.ansi(joinrows(reshape_rows(Style.torow(code), width)))
end
