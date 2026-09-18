# --- ? -------------------------------------------------------------------------

"""The keys, on one screen, for the reader who has forgotten one.

The footer names every key and is over budget doing it - two rows cut below
160 columns, and each key added there has to take one away. This is where the
rest of the sentence goes: what a key does and what it does *not*, which a
footer of `s snooze` cannot say. It is the README's table, kept in step by hand
(`test/suite/frame.jl` reads both), and grouped the way the keys divide: what
looks, what changes this machine, what reaches GitHub.

A dialog, so it stacks on whatever was under it and hands the keys back when
it closes - which any key does, except the ones that scroll it on a short
screen. Not `q`: `q` here closes the help and not the program, since a key
that reads "quit" in a box about keys is exactly the one to press by accident.
"""
mutable struct HelpView <: View
    top::Int
end
HelpView() = HelpView(1)

"""`(keys, what)` rows, or a bare heading, in the order the box shows them."""
const HELP = Union{String,Tuple{String,String}}[
    "Lowercase keys look at things or change this machine; uppercase keys reach GitHub.",
    "",
    "moving",
    ("j/k  g/G", "line · top and bottom;  space/b  a page"),
    ("tab", "the keyboard between the list and the detail"),
    ("↵", "on an item: read it · in the detail: fold · on the row above the first item: import"),
    ("n/N", "next and previous node, or search match"),
    ("/", "search; a bare number in the list jumps to that item, past any filter"),
    "",
    "looking",
    ("o  d  p  c", "the thread · the diff · what was pushed since you last looked · the checks"),
    ("[  ]  l", "widen a hunk's context · fetch a failing Buildkite job's log"),
    ("f", "the filter pane; c there clears it, ↵ toggles a box, n/N jump a group"),
    ("'  1-9 0  `", "views · the first ten of them · back to the previous filter"),
    ("w", "cycle the order: when it moved · that or when you acted · when you acted · url"),
    ("y  ⇧j/⇧k  m", "copy the selection · extend it by rows · give the mouse back to the terminal"),
    "",
    "changing this machine",
    ("r", "read ↔ unread"),
    ("s", "snooze: 3d, 2w, 6mo, a date; wakes then, or when it moves, whichever is first"),
    ("x", "file it away, and back; a filed item that moves is unread again"),
    ("v  e", "edit the note in \$VISUAL/\$EDITOR · open the checkout in VS Code, at the diff line under the cursor"),
    ("i", "import an item by url; it lands unread"),
    ("z", "undo the last local action"),
    ("u  R", "refresh everything in the background · reload this item"),
    ("t  T  \"", "a shell · an agent on the item's worktree · the worktree list"),
    "",
    "reaching GitHub",
    ("C", "comment; on a selection in a diff, a review comment on that range"),
    ("A  L  M", "send the draft review · toggle a label · merge"),
    "",
    "in a hosted pane, ^] is the prefix",
    ("^]tab  ^][", "the thread beside it, and back"),
    ("^]q  ^]K  ^]a", "leave it running · end it · full screen;  ^]r re-reads, ^]] sends ^]"),
    "",
    ("q", "quit; asks first, and about an unsent draft review if there is one"),
    ("?", "this"),
]

"""The rows as drawn, wrapped to the box: a heading is bold, a key is in a
column of its own, and a description longer than the rest of the row continues
under itself rather than under the key."""
function help_rows(iw::Int)
    kw = 14                                         # the key column
    out = Tuple{String,String}[]                    # (text, style)
    for e in HELP
        if e isa String
            push!(out, isempty(e) ? ("", "") : (e, THEME.bold))
        else
            k, what = e
            lines = awrap(what, iw - kw - 2)
            isempty(lines) && (lines = [""])
            push!(out, (string(THEME.focus, apad(k, kw), THEME.reset, "  ", lines[1]), ""))
            for l in lines[2:end]
                push!(out, (string(" "^(kw + 2), l), ""))
            end
        end
    end
    out
end

"""How many rows fit inside the box on a screen `h` tall: the head, the foot
and the hint take three, and one row of air above and below is what says it
is a box on a screen rather than the screen."""
help_page(h::Int) = max(1, h - 5)

function render(v::HelpView, w::Int, h::Int)
    b = dialogbox(w; width = 96)
    rs = help_rows(b.iw)
    n = length(rs)
    page = min(n, help_page(h))
    v.top = clamp(v.top, 1, max(1, n - page + 1))
    out = [b.head("keys")]
    for i in v.top:(v.top + page - 1)
        t, s = rs[i]
        push!(out, b.row(t, s))
    end
    push!(out, b.foot())
    more = n > page
    push!(out, b.hint(more ? string("j/k scroll · ", v.top + page - 1, " of ", n,
                                    " · any other key closes") :
                             "any key closes"))
    centred(out, w, h)
end

function handle!(v::HelpView, k::Int, ctrl::Controller)
    h, w = displaysize(stdout)
    page = help_page(h)
    n = length(help_rows(dialogbox(w; width = 96).iw))
    k = unshift(k)
    if k in (Int('j'), K_DOWN);          v.top += 1
    elseif k in (Int('k'), K_UP);        v.top -= 1
    elseif k in (Int(' '), 6, K_PGDN);   v.top += page
    elseif k in (Int('b'), 2, K_PGUP);   v.top -= page
    elseif k in (Int('g'), K_HOME);      v.top = 1
    elseif k in (Int('G'), K_END);       v.top = n
    else
        return :pop
    end
    v.top = clamp(v.top, 1, max(1, n - min(n, page) + 1))
    :ok
end

"""The wheel scrolls it, as it scrolls every pane; a click anywhere closes it,
which is what a click outside a box means everywhere."""
function onmouse!(v::HelpView, ev::MouseEvent, ctrl::Controller)
    if ev.kind === :wheelup;       v.top -= 3
    elseif ev.kind === :wheeldown; v.top += 3
    elseif ev.kind === :press;     return :pop
    end
    :ok
end
