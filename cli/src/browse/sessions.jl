# Programs, drawn in a pane: `$EDITOR` on a note, a shell, an agent. This file
# decides *what to run and where*; `paneview.jl` draws it and forwards the keys.

"""Open this item's checkout in VS Code - and, given `at = (file, line)`, that
file at that line in it: the diff of it under `d` or `p`, the file alone
elsewhere.

The checkout is [`item_checkout`](@ref)'s answer, the same one `t` reads, so
the two cannot disagree about where an item's work is.

**The file at a line** is `code --goto <folder> <file>:<line>`. The folder is
still on the command line: that opens the file in the window whose workspace
the folder is, making the window when there is none, where `--goto
<file>:<line>` alone would land it in whichever window was last active. Not
`--reuse-window`, for the same reason. A file the diff names that is not in
the checkout - deleted by the pull request, or a checkout behind its head -
opens the folder instead and says so, rather than an untitled buffer under
that name.

**The diff at a line** cannot be said on `code`'s command line: `--diff` takes
two files and drops the line `--goto` parsed, and there is no `--command`. So
it is a url to the `worklog` extension in `vscode/`, `--open-url
vscode://vtjnash.worklog/diff?...`, with the refs [`diff_refs`](@ref) picks -
when that extension is installed in the VS Code `code` reaches, which is
asked once per launch. Without it the file opens at the line, and the status
says what is missing.
"""
function open_editor(it::Item, at::Union{Nothing,Tuple{String,Int}} = nothing;
                     mode::Symbol = :comments, items = Item[])
    target, branch = item_checkout(it; items)
    target === nothing && return :needs_repo
    # The same `code` and the same socket a pane is handed, for the same
    # reason: this process's own are only as fresh as its launch, and a
    # reconnect since then left them pointing at nothing.
    fw = forwards!()
    "VS Code" in fw.gone && return "no live VS Code to open it in"
    code = joinpath(rundir(), "bin", "code")
    (islink(code) && !("code" in fw.gone)) || (code = something(Sys.which("code"), ""))
    isempty(code) && return "`code` is not on PATH"
    where = string(target, isempty(branch) ? "" : string(" (", branch, ")"))
    cmd, said = `$code $target`, string("opened ", where)
    if at !== nothing
        file, line = at
        full = joinpath(target, file)
        left, right = mode in (:diff, :pushed) && isfile(full) ?
                      diff_refs(it, target, mode) : ("", "")
        if !isempty(left) && has_worklog_ext(code, fw.env)
            q = ["root" => target, "path" => full, "line" => string(line), "left" => left]
            isempty(right) || push!(q, "right" => right)
            scheme, flag = code_kind(code)
            url = string(scheme, "://vtjnash.worklog/diff?",
                         join((string(k, "=", urlenc(v)) for (k, v) in q), "&"))
            cmd = `$code $flag $url`
            said = string("opened the diff of ", file, ":", line, " in ", where)
        elseif isfile(full)
            cmd = `$code --goto $target $(string(full, ":", line))`
            said = string("opened ", file, ":", line, " in ", where,
                          isempty(left) ? "" : " \u00b7 no worklog extension in VS Code, see vscode/")
        else
            said = string("opened ", where, " \u00b7 no ", file, " in it")
        end
    end
    try
        run(pipeline(addenv(cmd, fw.env...); stdout = devnull, stderr = devnull);
            wait = false)
    catch e
        return "could not launch code: " * first(sprint(showerror, e), 80)
    end
    said
end

"""The two sides of the diff `e` opens, as refs `git` in `target` resolves:
`(left, right)`, `right` empty for the working tree, `left` empty when there
is nothing to diff against.

Under `d` the left is what GitHub's diff is against, the merge base of the
pull request's base and its head - measured locally against `HEAD` when the
checkout is on the branch, against the head GitHub reports otherwise - or the
base ref itself when that cannot be measured. Under `p` it is the head you
last read, which `r` wrote and the pane just diffed from.

The right side is the working tree when the checkout is on the pull
request's branch, because that is the copy being edited. On any other
branch the working tree has the wrong file, so it is the head as GitHub has
it - fetched when the checkout lacks it, the one round trip here, since
without that commit there is no right side at all. *The pull request's*
branch, not the one [`item_checkout`](@ref) came back with: a session
tagged with the item answers with its own worktree's branch, which is the
main checkout on `master` as often as not.

The base is not fetched: a key press does not wait on the network for a
base that is only ever too old, which is what `base_ref` is for.
"""
function diff_refs(it::Item, target::AbstractString, mode::Symbol)
    branch = pr_branch(it)
    onbranch = !isempty(branch) &&
               any(w -> w.branch == branch && wtkey(w.path) == wtkey(target), worktrees(target))
    head = onbranch ? "HEAD" : head_sha(it)
    onbranch || isempty(head) ||
        ensure_commit!(target, head, it.number; remote = remote_for(target, it.repo))
    right = onbranch ? "" : head
    left = if mode === :diff
        ref = base_ref(target, it.repo, it.base)
        isempty(ref) || isempty(head) ? ref :
            let mb = merge_base(target, ref, head); isempty(mb) ? ref : mb end
    else
        something(read_head(it.url), "")
    end
    (left, isempty(left) ? "" : right)
end

"""Whether the VS Code `code` reaches has the `worklog` extension - asked once
per `code` per launch, since `--list-extensions` is a round trip through its
socket, and an install is a thing done once. By the binary the link resolves
to, since the link is re-pointed at every launch and the answer is the
binary's."""
const HAS_WORKLOG_EXT = Dict{String,Bool}()
function has_worklog_ext(code::AbstractString, env)
    get!(HAS_WORKLOG_EXT, code_real(code)) do
        out = try
            read(pipeline(addenv(`$code --list-extensions`, env...); stderr = devnull), String)
        catch
            ""
        end
        any(==("vtjnash.worklog"), lowercase.(strip.(split(out, '\n'))))
    end
end

"The binary behind the `code` link, or the path as given when it resolves to nothing."
code_real(code::AbstractString) = try realpath(code) catch; String(code) end

"""What the `code` behind the link is: `(scheme, flag)` - the url scheme its
VS Code answers to, and the option that hands it a url.

Both are in the path the link resolves to and nowhere cheaper. The product
names the scheme: `.vscode-server-insiders/` or `Code - Insiders.app` is
`vscode-insiders://`, `VSCodium` is `vscodium://`. And the *server's* CLI -
`bin/remote-cli/code`, the one a terminal under Remote-SSH has, which talks
to the window over `VSCODE_IPC_HOOK_CLI` - spells the option `--openExternal`
(`server.cli.ts`); the desktop's is `--open-url`, and each drops the other's
as unknown and would open a file named after the url.
"""
function code_kind(code::AbstractString)
    p = lowercase(code_real(code))
    scheme = occursin("insiders", p) ? "vscode-insiders" :
             occursin("codium", p) ? "vscodium" : "vscode"
    (scheme, occursin("remote-cli", p) ? "--openExternal" : "--open-url")
end

"""The editor to open a note in: `\$VISUAL`, then `\$EDITOR`, then `vi`.

The same order `less` resolves for its own `v`, which is where the key comes
from.
"""
noteeditor() = let e = get(ENV, "VISUAL", get(ENV, "EDITOR", ""))
    isempty(e) ? "vi" : e
end

"""Edit this item's note in a real editor, and keep whatever comes back.

The note is where a thought about an item goes - what to check, what to ask,
the prompt being drafted for an agent. It was reachable only by leaving the
browser and running `wl note`, which is enough friction that it went unused.

A file and `\$EDITOR`, rather than a text field of our own: notes run to
paragraphs, they are worth keeping in a form that can be pasted, and the
composer already showed that a homegrown editor is a lot of keybindings to
reinvent badly. `less` binds `v` for exactly this and this borrows the key.

An unchanged file writes nothing, so opening a note to read it cannot
accidentally rewrite `local.toml`, and an emptied one clears the note rather
than storing a blank.
"""
function edit_note(st::BState, it::Item, ctrl)
    path = joinpath(mktempdir(), string(replace(it.ref, '/' => '-', '#' => '-'), ".md"))
    before = it.note
    prevtouch = touched_at(it.url)
    write(path, isempty(before) ? "" : before)
    finish = () -> adopt_note!(st, it, path, before, prevtouch)

    # In a pane, beside the thread, the same as `t` and `T`. Taking the whole
    # screen for it was the odd one out: the note is nearly always *about* what
    # is on the other half, and writing it with the thread hidden meant leaving
    # the editor to check what it said.
    if mux_bin() !== nothing
        target = something(first(item_checkout(it)), ROOT)
        name = mux_name(basename(rstrip(String(target), '/')), "", string(it.number); kind = :note)
        # Never resumed, unlike a shell: this one is bound to a temp file that
        # holds the note as it was when the key was pressed, so an editor left
        # over from a previous `v` would be writing into a stale copy.
        mux_kill(name)
        fw = forwards!()
        ok, err = mux_start(name, target, string(noteeditor(), " ", shquote(path)); set = fw.env)
        ok || return err
        mux_tag!(name; worktree = target, kind = :note, item = it.ref, url = it.url)
        v = pane_view(name, string("note  ", it.ref), ctrl; onend = finish)
        if v === nothing
            # Still running means the attach really failed. Gone means the
            # editor finished before we got there - which an editor configured
            # to write and exit does every time - and the note is taken anyway
            # rather than thrown away for having been quick.
            mux_alive(name) || return finish()
            mux_kill(name)
            return "could not attach to " * name
        end
        pane_sync!(v)
        push_place!(ctrl, v)
        return "editing the note — it is saved when the editor exits" * gone_suffix(fw.gone)
    end

    # No multiplexer: hand over the whole terminal, which is what this did
    # before there was anywhere else to put it.
    ok = true
    suspend(ctrl) do
        try
            # Through a shell, and with the path as an argument rather than
            # interpolated: `$EDITOR` is a command line, not a program, and it
            # is routinely one with arguments and quotes in it - `code --wait`,
            # `emacsclient -a "" -c`. Splitting it on spaces mangles those.
            run(`sh -c $(string(noteeditor(), " \"\$1\"")) sh $path`)
        catch e
            logerror!(e, catch_backtrace(), "edit_note")
            ok = false
        end
    end
    ok || return string("could not run ", noteeditor())
    finish()
end

"""Single-quote for a shell, the only quoting that needs no other escaping.

A temp path has no spaces today, but `\$EDITOR` is handed to a shell either way
and a path that is not quoted is a path that is one `mktempdir` away from being
two arguments.
"""
shquote(s::AbstractString) = string("'", replace(String(s), "'" => "'\\''"), "'")

"""Take whatever the editor left in `path` and make it the item's note.

Shared by both routes into the editor, and the reason `v` can be asynchronous
at all: the pane calls this when the child exits, the full-screen path calls it
when the editor returns, and neither has to know which.
"""
function adopt_note!(st::BState, it::Item, path, before, prevtouch)
    after = try
        strip(read(path, String))
    catch
        return "the note could not be read back"
    end
    after == strip(before) && return "note unchanged"
    set_fields(it.url, ["note" => isempty(after) ? nothing : String(after)])
    # The pane reads the note off the item, so the item has to carry it before
    # the next refresh rewrites the item list. Found by url rather than by the
    # cursor: with the editor in a pane the selection can have moved on by the
    # time this runs. In both lists, since `st.items` is rebuilt out of `st.all`
    # by the next thing that refilters - and a note that survived until then
    # only to vanish is worse than one that never appeared.
    now = Item(; (f => getfield(it, f) for f in fieldnames(Item))..., note = String(after))
    for v in (st.items, st.all)
        i = findfirst(x -> x.url == it.url, v)
        i === nothing || (v[i] = now)
    end
    push!(st.undos, Undo(string("note ", it.ref), it.url, () -> begin
        set_fields(it.url, ["note" => isempty(before) ? nothing : before])
        set_touched(it.url, prevtouch)
    end))
    isempty(after) ? "note cleared" : "note saved"
end

"""The session for this worktree and kind, or `nothing`.

A session's identity is the tags it carries: the worktree, which is the resource
actually being shared, and the kind, since a shell and an agent in one checkout
are two different things. `kind` comes back from tmux as the string it was set
with.

Matched here rather than with a tmux filter expression: a path can contain the
characters a format string is made of, and a comma in a checkout's name would
otherwise quietly match nothing.
"""
function mux_find(worktree::AbstractString, kind::Symbol, rows = mux_list())
    want, k = String(worktree), String(kind)
    for r in rows
        r.worktree == want && r.kind == k && return r
    end
    nothing
end

"""Find or start the session of `kind` in `target`, and show it.

One path for both kinds, because a session of either is a *place*: the shell in
a checkout is the shell in that checkout whoever asked for it, and an agent can
be cleared and pointed at something else as easily as a shell can be `cd`-ed.
So both are renamed to whatever item was last opened on them, and both are
re-tagged with it.

Keyed on the worktree and not on the item, which is what lets the same session
be reached from a row in the item list and from a row in the worktree list -
`ref` and `num` only decide what it is *called* and what it is tagged with, and
a worktree that has no pull request simply passes neither.

What differs between the kinds is only what gets run when there is nothing
there yet.
"""
function enter_session(target::AbstractString, branch::AbstractString,
                       ref::AbstractString, num::AbstractString, url::AbstractString,
                       title::AbstractString, ctrl, kind::Symbol, mkcmd)
    mux_bin() === nothing && return no_mux()
    rows = mux_list()
    found = mux_find(target, kind, rows)
    # Already looking at it. `^]t` and `^]T` reach here from inside a pane -
    # which is how a shell gets to the agent on the same item and back - and the
    # press that names the kind already showing would otherwise open a second
    # view onto one session and leave two `^]q`s between here and the browser.
    # Asked before the rename below, because that is what makes the name on the
    # view and the name on the session the same string.
    if found !== nothing && !isempty(ctrl.stack) &&
       last(ctrl.stack) isa PaneView && last(ctrl.stack).child.name == found.name
        return string("already in ", found.name)
    end
    name = mux_name(basename(rstrip(String(target), '/')), branch, num; kind = kind)
    # Re-pointed whether the session is new or resumed: a resumed one was
    # handed the links at its start, and this is what puts a live socket under
    # them. What is handed over is for the new one.
    fw = forwards!()
    if found === nothing
        ok, err = mux_start(name, target, mkcmd(target, branch); set = fw.env)
        ok || return err
    else
        mux_rename(found.name, name)
    end
    # The url as well as the ref: the ref is what the pane says, the url is
    # what the marks are keyed by, and an agent's bell is read as one. The
    # branch is the copy's as of now, read off git and not off the caller
    # (`place_branch`: a caller's word for it is a row that may have gone
    # stale, or the branch it *asked* gh for when gh chose another name) -
    # re-tagged on every entry, so it is always the branch the last answer
    # was about, and a copy on some other branch next time is one that has
    # moved since (`item_worktree`, rule 2).
    on = place_branch(target)
    mux_tag!(name; worktree = target, kind = kind, item = ref, url = url, branch = on)
    # And on the item's other sessions here: the answer was about the place,
    # not the kind, so the agent left in this copy is told the branch the
    # shell was just put back on, or an old answer of its would say the copy
    # has moved when it is this entry that moved it back.
    for r in rows
        (!isempty(ref) && r.item == ref && wtkey(r.worktree) == wtkey(target) &&
         r.name != name && (found === nothing || r.name != found.name)) || continue
        mux_tag!(r.name; branch = on)
    end
    v = pane_view(name, title, ctrl)
    v === nothing && return "could not attach to " * name
    pane_sync!(v)
    push_place!(ctrl, v)
    said = if found === nothing
        string("started ", name)
    elseif !isempty(found.item) && !isempty(ref) && found.item != ref
        # Not a refusal - the session is yours to redirect - but the
        # conversation in it is about something else until you say otherwise.
        string("back in ", basename(rstrip(String(target), '/')),
               " \u00b7 was on ", found.item)
    else
        string("back in ", name)
    end
    # And what the pane will not find, said now rather than by `git push`.
    said * gone_suffix(fw.gone)
end

"""The same, for an item: its worktree is where its session lives.

`item_worktree` answers where when it can, and this goes there without a word.
When it cannot - no worktree on the branch and no session already on the item -
the answer is the user's, so a chooser is pushed and the session opens from its
callback. That is why `say` exists: the string this returns is only the answer
for the route that did not ask, and the asked route has to report much later,
after this call has already come back.

Asked once, not once per press: opening the session tags it with the item, and
that tag is rule 2 next time.

`items` is the list the browser has, for [`branch_owner`](@ref): what tells a
copy on another branch from a copy on another *item's* branch. What
`item_worktree` looked up on the way - the pull request's branch, the mux
rows - goes down with the answer, so one press is one look at each.
"""
function enter_session(it::Item, ctrl, kind::Symbol, mkcmd, say = _ -> nothing;
                       items = Item[])
    mux_bin() === nothing && return no_mux()
    r = item_worktree(it; items)
    r.path === nothing && return :needs_repo
    r.ask && return ask_checkout(it, ctrl, kind, mkcmd, say; items, pr = r.pr, rows = r.rows)
    item_session!(it, (path = r.path, branch = r.branch, main = r.main), r.pr,
                  ctrl, kind, mkcmd, say; items, rows = r.rows)
end

"""Open the item's session in a checkout that has been settled on - after two
looks at what is there.

The first is the branch: `w.branch` is the copy's, and when the item is a
pull request on another one the session is about to open on the wrong branch
([`checkout_offer`](@ref)). The second, when the branch is the right one, is
whether it is behind where the item is ([`update_offer`](@ref)). Both are
asked exactly when the place is new to the item: nothing of the item's
running there yet, or a copy `picked` by hand from the chooser or typed as a
path. Going back to a copy where the item already has a session is not - it
was looked at when that opened, and `n` there was an answer, not a thing to
say again on every `^]q`, or for the other kind. An answer is about the place
*as it was*, though: a copy that has since moved off the branch it was
answered on - parked at `master` or detached to mark it free, or checked out
on another item's branch - is not the item's place any more (rule 2's
exceptions), so the next `t` goes back through the chooser and both looks,
whatever was answered before. Things move between one session and the next,
and a question is cheaper than a shell on the wrong branch.

A question reports through `say`, long after this has returned `""`; the
route that had nothing to ask reports through the return value.

`w` is the copy - a row of `worktrees`, or anything with its `path`, `branch`
and `main` - and `pr` the pull request's own branch, both handed down from
whoever looked them up rather than asked again here; `rows`, the mux rows,
the same.
"""
function item_session!(it::Item, w, pr::AbstractString, ctrl, kind::Symbol, mkcmd,
                       say = _ -> nothing; picked::Bool = false, items = Item[], rows = nothing)
    q = checkout_offer(it, w, pr, ctrl, kind, mkcmd, say; picked, items, rows)
    q === nothing || return q
    q = update_offer(it, w, pr, ctrl, kind, mkcmd, say; picked, rows)
    q === nothing || return q
    session_in!(it, w.path, w.branch, ctrl, kind, mkcmd)
end

"""The other look before a session opens: the copy is on the item's branch,
and the branch here is behind where the item is. Ask whether to fast-forward
it - or `nothing`, when there is nothing to ask.

Where the item *is* is the head the lanes reported for a pull request, and
the branch's upstream for an adopted branch; a head not here yet is fetched
(`ensure_commit!`, off `refs/pull/N/head`, objects only).
Behind alone is not the question, though - `branch_included` is: a branch
that once had those commits and was rewound was moved on purpose, and gets
no offer; one that never had them was left behind by a push from somewhere
else, which is the case for a word. Two words, by whether the branch has
commits of its own: none, and `y` fast-forwards it (`git merge --ff-only`,
which a changed file in the way refuses - the session opens anyway, with
git's words first); some, and the branches have diverged unseen, which is
said on the status line and left to the shell, since a rebase is nobody's
to run but the user's. And [`lease_note`](@ref)'s line, when it has one: a
branch somebody else pushed to is the branch a lease is about.

Asked when the place is new to the item, which is the checkout question's
rule too ([`item_session!`](@ref) says when that is).

Only when `HEAD` is the branch itself. A copy detached for a rebase or a
bisect reports the branch it will return to, and a fast-forward there would
move the detached head under the rebase and leave the branch where it was.
"""
function update_offer(it::Item, w, pr::AbstractString, ctrl, kind::Symbol, mkcmd, say;
                      picked::Bool = false, rows = nothing)
    mux_bin() === nothing && return nothing
    (isempty(pr) || w.branch != pr) && return nothing
    if !picked && !isempty(it.ref)
        rows === nothing && (rows = mux_list())
        any(r -> r.item == it.ref && wtkey(r.worktree) == wtkey(w.path), rows) &&
            return nothing
    end
    target = String(w.path)
    head_branch(target) == pr || return nothing
    tip, at = if it.is_pr
        isempty(it.head) && return nothing
        have_commit(target, it.head) ||
            ensure_commit!(target, it.head, it.number; remote = remote_for(target, it.repo)) ||
            return nothing
        (it.head, string(it.ref, "'s head"))
    else
        at = upstream_of(target, pr)
        isempty(at) && return nothing
        u = try
            strip(git(target, "rev-parse", "--verify", "--quiet", string(pr, "@{u}")))
        catch
            return nothing
        end
        isempty(u) && return nothing
        (String(u), at)
    end
    is_ancestor(target, tip, "refs/heads/" * pr) && return nothing
    branch_included(target, pr, tip) && return nothing
    lag = branch_lag(target, pr, tip)
    lag === nothing && return nothing
    name = basename(rstrip(target, '/'))
    if lag.ahead > 0
        r = session_in!(it, target, pr, ctrl, kind, mkcmd)
        return string(pr, " has ", lag.ahead, " commit", lag.ahead == 1 ? "" : "s",
                      " not in ", at, ", and is ", lag.behind, " behind it",
                      r isa String && !isempty(r) ? string(" \u00b7 ", r) : "")
    end
    lease = lease_note(target, it.repo, pr)
    notes = vcat([string(pr, " is ", lag.behind, " commit", lag.behind == 1 ? "" : "s",
                         " behind ", at, ", pushed from somewhere else")],
                 status_preview(target),
                 [string("y runs git merge --ff-only there")],
                 isempty(lease) ? String[] : [lease])
    push_view!(ctrl, ConfirmView(
        string("Fast-forward ", pr, " in ", name, "?"), notes,
        ["yY" => () -> say(fastforward_session!(it, target, pr, tip, ctrl, kind, mkcmd)),
         "nN" => () -> say(session_in!(it, target, pr, ctrl, kind, mkcmd))];
        hint = "y fast-forwards \u00b7 n goes in as it is \u00b7 esc cancels"))
    ""
end

"""`y` to the question above: fast-forward `branch` in `target` to `tip`, then
open the session there. A merge that fails - a changed file in the way - still
opens the session, with git's complaint ahead of the pane's own report, for
[`checkout_session!`](@ref)'s reason."""
function fastforward_session!(it::Item, target::AbstractString, branch::AbstractString,
                              tip::AbstractString, ctrl, kind::Symbol, mkcmd)
    try
        git(target, "merge", "--quiet", "--ff-only", tip)
    catch e
        e isa GitError || rethrow()
        r = session_in!(it, target, branch, ctrl, kind, mkcmd)
        return string("could not fast-forward ", branch, ": ", oneline(first(e.msg, 120)),
                      r isa String && !isempty(r) ? string(" \u00b7 ", r) : "")
    end
    r = session_in!(it, target, branch, ctrl, kind, mkcmd)
    r isa String ? string("fast-forwarded ", branch, " \u00b7 ", r) : r
end

"""Open the item's session in `target`, on whatever branch it is on, and touch
the item: the unconditional half of [`item_session!`](@ref), and what its
question's answers come back to."""
function session_in!(it::Item, target::AbstractString, branch::AbstractString,
                     ctrl, kind::Symbol, mkcmd)
    # What was on top before, and not how tall the stack was: a pane *replaces*
    # the place it was opened from, so the depth can be the same on both sides
    # of a session that opened perfectly well.
    was = isempty(ctrl.stack) ? nothing : last(ctrl.stack)
    r = enter_session(target, branch, it.ref, string(it.number), it.url,
                      string(kind === :agent ? "agent  " : "", it.ref,
                             isempty(branch) ? "" : string("  ", branch)),
                      ctrl, kind, mkcmd)
    # Only once there is something to work in - the pane being on the stack is
    # what says so, rather than the shape of the message. Opening a shell or an
    # agent on an item is the strongest signal of work there is, stronger than
    # any amount of reading it, which is why the clock has a hand in a view that
    # does no reading at all.
    (!isempty(ctrl.stack) && last(ctrl.stack) !== was) && touch!(it.url)
    r
end

"""Ask whether to check the pull request out where its session is about to
open, when the copy is on some other branch - or `nothing`, when there is
nothing to ask: no branch, the right branch already, or a place that is not
new to the item ([`item_session!`](@ref) says when that is).

The question shows what is checked out there before anything is done to it,
which is the look `t` used to skip: the branch the copy is on and, when it is
another item's, whose ([`branch_owner`](@ref)) - that is a copy that was
*reused*, and the thing to do is more often `w` than `y`; then `git status`
([`status_preview`](@ref)), since a changed file is what a checkout trips on
and what would be carried across. Three answers, each a key reached for on
purpose: `y` checks it out there and goes in ([`checkout_session!`](@ref)) -
`gh pr checkout` for a pull request, `git checkout` for an adopted branch,
which is here by definition and is nobody's to fetch; `n` goes in as it is,
which is the scratch copy an agent was left in; `w` opens the chooser, which
is where a reused copy is given up. Anything else is no shell at all. A last
line for a pull request when `push.useForceIfIncludes` is off
([`lease_note`](@ref)): `y`'s gh refreshes the lease `--force-with-lease`
reads, and so does the user's own gh, so the line is about the setting.

Blocks the browser for the fetch under `y`, the way `p` does for its base;
the pane opens when it lands.

`w`, `pr` and `rows` are [`item_session!`](@ref)'s, the rows listed here when
it had none - and only when there is something to look for: a copy `picked`
is asked whatever is running in it, and an item with no ref has no session
anywhere, whatever an untagged shell's empty tag says (rule 2 has the same
guard).
"""
function checkout_offer(it::Item, w, pr::AbstractString, ctrl, kind::Symbol, mkcmd, say;
                        picked::Bool, items, rows = nothing)
    mux_bin() === nothing && return nothing
    (isempty(pr) || w.branch == pr) && return nothing
    target, wbranch = String(w.path), String(w.branch)
    if !picked && !isempty(it.ref)
        rows === nothing && (rows = mux_list())
        any(r -> r.item == it.ref && wtkey(r.worktree) == wtkey(target), rows) &&
            return nothing
    end
    name = basename(rstrip(target, '/'))
    owner = branch_owner(it, w, branch_index(items))
    on = isempty(wbranch) ? string(name, " is detached") :
         string(name, " is on ", wbranch,
                owner === nothing ? "" : string(" \u00b7 ", owner.ref, "'s"))
    lease = it.is_pr ? lease_note(target, it.repo, pr) : ""
    notes = vcat([on], status_preview(target),
                 [string("y runs ", it.is_pr ? string("gh pr checkout ", it.number) :
                                              string("git checkout ", pr), " there")],
                 isempty(lease) ? String[] : [lease])
    push_view!(ctrl, ConfirmView(
        string("Check out ", pr, " in ", name, "?"), notes,
        ["yY" => () -> say(checkout_session!(it, target, wbranch, pr, ctrl, kind, mkcmd)),
         "nN" => () -> say(session_in!(it, target, wbranch, ctrl, kind, mkcmd)),
         "wW" => () -> say(ask_checkout(it, ctrl, kind, mkcmd, say; items, pr))];
        hint = "y checks it out \u00b7 n goes in as it is \u00b7 w another place \u00b7 esc cancels"))
    ""
end

"""`y` to the question above: check `branch` out in `target`, then open the
session there. `branch` is the question's, so it is not asked of GitHub a
second time for a row from before the field existed.

A pull request's branch is looked for here first ([`pr_branch_here`](@ref)),
the way a new worktree's is: a name this repository has that is *not* the
pull request's is handed to gh under a name of its own, `pr<N>/<branch>`,
since gh handed the taken name fetches the pull request into the branch
that is in the way. And the branch the copy is on afterwards is read off git,
not assumed: gh picks a name of its own for a fork's branch that collides
with the project's default, and the session's tag and the report are about
the branch that is there.

A checkout that fails still opens the session, on the branch the copy was on,
with git's or gh's complaint ahead of the pane's own report: a shell is where
the file in the way gets dealt with, and refusing the shell for it would leave
nowhere to. A `T` failing the same way is an agent told nothing about it - the
status line says, and the agent reads its branch off its own prompt.
"""
function checkout_session!(it::Item, target::AbstractString, wbranch::AbstractString,
                           branch::AbstractString, ctrl, kind::Symbol, mkcmd)
    try
        if it.is_pr
            as = pr_branch_here(target, it, branch) === :taken ?
                 string("pr", it.number, "/", branch) : ""
            checkout_pr!(target, it.url; as)
        else
            git(target, "checkout", "--quiet", branch)
        end
    catch e
        e isa GitError || rethrow()
        r = session_in!(it, target, wbranch, ctrl, kind, mkcmd)
        return string("could not check out ", branch, ": ", oneline(first(e.msg, 120)),
                      r isa String && !isempty(r) ? string(" \u00b7 ", r) : "")
    end
    now = head_branch(target)
    isempty(now) && (now = branch)
    r = session_in!(it, target, now, ctrl, kind, mkcmd)
    r isa String ? string("checked out ", now, " \u00b7 ", r) : r
end

"""One line for a checkout, in the list of places this item could be worked on.

The branch is what tells two copies of one repo apart, and a live session is
what says somebody is already in there - both of which are reasons to pick a
row, so both are on it. The sessions are the worktree list's marks, `tTv`, with
the item they were opened on beside them - `#62452` for one of this repository,
the whole ref for one of another - so a reader who has seen `"` already knows
them, and can see that the shell in this copy is on something else. Picking the
row re-points that session at this item, which is what `enter_session` does
with every session it resumes; the other item then has nothing running on it.

Second, and fixed width: the box is 72 columns inside, and a phrase hung off
the end of the row - "· agent + shell running" - was cut at "age" or "she" on
every row that had one, which is the one column the row was there to show.
"""
function checkout_option(w, rows, repo::AbstractString)
    here = [r for r in rows if !isempty(r.worktree) && wtkey(r.worktree) == wtkey(w.path)]
    live = [(kind = Symbol(isempty(r.kind) ? "shell" : r.kind),
             attached = r.attached, bell = r.bell) for r in here]
    stem = string(last(split(String(repo), '/')), '#')
    on = unique(String[startswith(r.item, stem) ? chop(r.item; head = length(stem) - 1, tail = 0) :
                       r.item for r in here if !isempty(r.item)])
    string(apad(afit(basename(rstrip(String(w.path), '/')), 24), 24), "  ",
           session_marks(live), " ", apad(afit(join(on, " "), 8), 8), "  ",
           apad(amid(isempty(w.branch) ? "(detached)" : w.branch, 26), 26), "  ",
           w.main ? "main" : "    ")
end

"""Ask which checkout to work in, then work in it.

Every worktree of the repo, main first as git lists them, and a last row that
makes a new place. Nothing is pre-selected on the user's behalf: this is only
reached when neither the branch nor a running session said where the work is,
and picking the main checkout by default is exactly the guess that made the
answer wrong often enough to be worth asking about.

`pr` is the pull request's branch and `rows` the mux rows, from a caller that
has them; each is looked up once here otherwise, and handed on from here.
"""
function ask_checkout(it::Item, ctrl, kind::Symbol, mkcmd, say; items = Item[],
                      pr::AbstractString = pr_branch(it), rows = nothing)
    repo = repo_path(it.repo)
    repo === nothing && return :needs_repo
    ws = worktrees(repo)
    rows === nothing && (rows = mux_list())
    opts = Tuple{String,Any}[(checkout_option(w, rows, it.repo), w.path) for w in ws]
    push!(opts, ("+ a new worktree …", ""))
    push_view!(ctrl, ChooseView(
        string(kind === :agent ? "Agent for " : "Shell for ", it.ref),
        "where to work · the last row makes a place",
        opts,
        p -> begin
            if isempty(String(p))
                say(ask_worktree_for(it, ctrl, kind, mkcmd, say; items, pr))
            else
                i = findfirst(w -> w.path == p, ws)
                w = i === nothing ? (path = String(p), branch = "", main = false) : ws[i]
                say(item_session!(it, w, pr, ctrl, kind, mkcmd, say;
                                  picked = true, items, rows))
            end
        end))
    ""
end

"""Ask where to put a new worktree for this item, and open the session in it.

The prefill is the same suggestion the branch list makes - beside the main
checkout, named for the branch - and the main checkout's own path when the item
has no branch to check out, since then the only thing "a new place" can honestly
offer is somewhere already on disk.

A path that is already a worktree of this repo is taken as a choice of that
worktree rather than an error, which is what makes typing a path a way of
reaching one that the list drew off the bottom.
"""
function ask_worktree_for(it::Item, ctrl, kind::Symbol, mkcmd, say;
                          seed = "", note = "", items = Item[],
                          pr::AbstractString = pr_branch(it))
    repo = repo_path(it.repo)
    repo === nothing && return "no local checkout registered for " * it.repo
    dest = !isempty(seed) ? String(seed) :
           isempty(pr) ? main_worktree(repo) : worktree_dest(repo, pr)
    push_view!(ctrl, PromptView(
        string("New worktree for ", it.ref),
        isempty(note) ? string("where to check ",
                               isempty(pr) ? "it" : pr,
                               " out · ", it.repo, " is at ", repo) : note,
        at -> say(make_checkout!(it, ctrl, kind, mkcmd, say, at; items, pr)); initial = dest))
    ""
end

"""Make the place the prompt named, and open the session there.

A branch this repository has, when it is the pull request's
([`pr_branch_here`](@ref)), is checked out as a worktree of it
(`add_worktree!`) - made off the remote's copy when that is the only one
here, said by its full name so two remotes carrying it is not a refusal. One
it has not - a fork's, before anything fetched it - is made by `gh` in a
detached worktree (`add_worktree_pr!`), which is what a pull request from a
fork always needed and this used to refuse with `invalid reference`. One it
has only the *name* of - a fork's `master`, when this checkout has its own -
is gh's too, under a name of its own, `pr<N>/<branch>`, since gh handed the
head's name would fetch the pull request into the branch that is already
here. A worktree under that name is found by its session (rule 2) and not by
its branch (rule 1), which is the price of not touching `master`. An adopted
branch is here by definition, and is git's.

Failure re-opens the prompt with what was typed still in it and git's own
complaint above it: every way this fails is a path that wants correcting - the
directory exists, its parent does not, the branch is checked out somewhere else.
"""
function make_checkout!(it::Item, ctrl, kind::Symbol, mkcmd, say, at::AbstractString;
                        items = Item[], pr::AbstractString = pr_branch(it))
    repo = repo_path(it.repo)
    repo === nothing && return "no local checkout registered for " * it.repo
    want = wtkey(abspath(expanduser(String(at))))
    for w in worktrees(repo)
        wtkey(w.path) == want &&
            return item_session!(it, w, pr, ctrl, kind, mkcmd, say; picked = true, items)
    end
    isempty(pr) &&
        return string(it.ref, " has no branch to check out · pick a worktree that exists")
    branch = pr
    found = :none
    dest = try
        found = it.is_pr ? pr_branch_here(repo, it, pr) :
                has_rev(repo, "refs/heads/" * pr) ? :local : :none
        if found === :local
            add_worktree!(repo, pr, at)
        elseif found === :remote
            # Off the remote-tracking ref, which `pr_branch_here` has just
            # brought up to date when it had to; without one at all, gh's
            # checkout sets the tracking up as git would have.
            rem = string("refs/remotes/", remote_for(repo, it.repo), "/", pr)
            has_rev(repo, rem) ? add_worktree!(repo, pr, at; from = rem) :
                                 add_worktree_pr!(repo, it.url, at)
        elseif found === :taken
            branch = string("pr", it.number, "/", pr)
            add_worktree_pr!(repo, it.url, at; as = branch)
        elseif it.is_pr
            add_worktree_pr!(repo, it.url, at)
        else
            return string("no branch ", pr, " here to check out")
        end
    catch e
        e isa GitError || rethrow()
        ask_worktree_for(it, ctrl, kind, mkcmd, say;
                         seed = at, note = oneline(first(sprint(showerror, e), 200)), items, pr)
        return ""
    end
    # A worktree git made goes through the same look as any other landing,
    # and is offered the fast-forward when the branch is behind the pull
    # request. One gh just made is where the pull request is.
    r = found in (:local, :remote) ?
        item_session!(it, (path = dest, branch = branch, main = false), pr, ctrl, kind, mkcmd,
                      say; picked = true, items) :
        session_in!(it, dest, branch, ctrl, kind, mkcmd)
    r isa String && !isempty(r) ? string("made ", dest, " · ", r) : r
end

"""Where this repository has the pull request's `branch`, if it has it at all:
`:local`, `:remote` (on the project's remote only, which `git worktree add`
can make a local one from), `:taken` when it has a branch of that name that
is *not* the pull request's, and `:none`.

Names are not distinctive: a fork's pull request is from its `master` as
often as not, and checking the project's own `master` out under that name
would put a worktree on the wrong branch that rule 1 then swears by. The
head sha the lanes reported is what says: the branch here is the pull
request's when that commit is on it - ahead of it too, since unpushed work of
yours is still yours.

A local branch the head is *not* on is not yet a stranger's: it is as often
your own - rewound from the head on purpose, or pushed from another machine
since - and three things tell the two apart. The branch's own reflog first
(`branch_included`): a branch that once contained the head was moved off it
deliberately, and is yours without a word to the network. Its upstream next
(`upstream_of`): a branch set up to track the project's copy of the name is
a copy of it by its own declaration, which outlasts a head the lanes saw
before a force-push from elsewhere. Then the project's copy of the branch
itself, since a fork's `master` is on no branch of the project's: the
remote-tracking ref as it stands, and failing that brought up to date
(`fetch_base!`, one round trip; what that moves is [`lease_note`](@ref)'s
subject). A branch of your own that has moved is still `:local`, and a
worktree on it is where the fast-forward is offered ([`update_offer`](@ref));
only a name that the project's own copy disowns is `:taken`. A row with no
head sha (old, or made by a poll) is taken at its name, which is the old rule.
"""
function pr_branch_here(repo::AbstractString, it::Item, branch::AbstractString)
    r = remote_for(repo, it.repo)
    loc, rem = "refs/heads/" * branch, string("refs/remotes/", r, "/", branch)
    hasloc = has_rev(repo, loc)
    (hasloc || has_rev(repo, rem)) || return :none
    isempty(it.head) && return hasloc ? :local : :remote
    on(ref) = has_rev(repo, ref) && is_ancestor(repo, it.head, ref)
    hasloc && (on(loc) || branch_included(repo, branch, it.head)) && return :local
    # The branch's own word: one set up to track the project's copy of the
    # name is a copy of it by declaration, whatever a head the lanes last saw
    # says - a force-push from elsewhere since then is still yours.
    (hasloc && upstream_of(repo, branch) == string(r, "/", branch)) && return :local
    on(rem) && return hasloc ? :local : :remote
    (fetch_base!(repo, it.repo, branch) && on(rem)) && return hasloc ? :local : :remote
    :taken
end

"""What to run for `T`, as a shell command line.

Through the shell rather than as a bare name, because `claude` is more often a
shell alias or a function than a file on `PATH` - and a name looked up with
`Sys.which` was refused before it was ever tried.

Both halves of `-ic` are load-bearing, and each was got wrong once:

- **`-i`, or the alias is not even defined.** A non-interactive bash reads no
  `.bashrc` (only `\$BASH_ENV`), and - separately - has `expand_aliases` *off*,
  so setting `BASH_ENV` is not enough on its own either. Two reasons, and `-i`
  is the one thing that answers both. zsh is the same shape: `.zshrc` is read
  when it is interactive and not otherwise.
- **No `exec`, or the alias is defined and still not used.** Aliases are
  expanded in command position only, so in `exec claude` the command is `exec`
  and `claude` is its argument - never looked up. (The documented escape is an
  alias whose value ends in a space, which is why `alias sudo='sudo '` is a
  thing people write.) Dropping `exec` costs nothing here: tmux follows the
  foreground process group, so `#{pane_current_command}` still says `claude`
  and not `bash`.

`--settings` carries [`AGENT_SETTINGS`](@ref) - the JSON itself, not the path
([`agent_settings`](@ref)) - and it goes on the alias's line rather than into
the user's own settings: it is only wanted under a pane, and `claude` run from
a terminal is not to ring a bell into it every turn.

`[agent] command` in `data/config.toml` overrides the lot, and is the honest answer for anything this
cannot guess - a wrapper script, a different agent, flags. An alias is a
convenience for a person typing, and asking one program to read another
program's interactive configuration is a long way round. It overrides the
`--settings` too - the file is `claude`'s to read, and a different agent has no
use for it - so a command that is still `claude` names it itself.
"""
function agent_cmd()
    c = get(get(config(), "agent", Dict{String,Any}()), "command", "")
    isempty(c) || return String(c)
    j = agent_settings()
    string(shquote(get(ENV, "SHELL", "/bin/sh")), " -ic ",
           shquote(isempty(j) ? "claude" : string("claude --settings ", shquote(j))))
end

"""The hooks, as the one JSON string `--settings` is handed - or `""` when the
file cannot be read, and `T` runs `claude` bare rather than not at all.

Inline and not the path, because the path is not the same everywhere the
agent runs. `claude` is as often a sandbox as a binary: one that mounts the
item's worktree and its own config directory and nothing else, so this
checkout is not there, and `~/.claude` is `/root/.claude` inside and
`/home/you/.claude` outside - one name in two places, and `--settings` expands
no `~` (measured, 2.1.277: `Settings file not found: ~/...`). A copy under
`~/.claude/wl` would still be at two paths; a hard link would come apart at
the next checkout, which writes a new inode. The contents have no path.
Minified, so the command line and `ps` carry one line of it.
"""
function agent_settings()
    try
        JSON3.write(JSON3.read(read(AGENT_SETTINGS, String)))
    catch e
        logerror!(e, catch_backtrace(), "agent settings")
        ""
    end
end

"""What the agent in a pane is told to do at the end of every turn: ring.

A pane's screen is read back as text, and a program that has stopped and one
that is thinking look the same in it. `claude` has no flag that says which,
but it has hooks, and `--settings` takes a file of them for one launch: the
`Stop` hook fires as the turn ends, and a permission prompt is the other way a
turn stops on you. Each rings the terminal bell, which tmux keeps as the
window's bell flag until somebody attaches - a seen bit the server holds, that
[`mux_list`](@ref) reads back as `bell` and the worktree list draws. No socket,
no listener, nothing for the hook to find: the pane it is in is the whole of
the channel.

The hook runs under `/bin/sh` in a session of its own, with no controlling
terminal - `/dev/tty` is `No such device or address` (measured, 2.1.277) - so
it asks `ps` for its parent's, which is `claude`'s, which is the pane's.
`ps -o tty= -p` is the one spelling BSD and procps share; `pts/1` and
`ttys001` are both under `/dev`, and `?`/`??` for none is not a character
device, so a headless run rings nowhere and says nothing.

A file, so what it says can be read and diffed, handed over as a string
([`agent_settings`](@ref)); beside the code and not in `data/`, because it
names nobody and changes with the program.
"""
const AGENT_SETTINGS = joinpath(ROOT, "cli", "claude-settings.json")

"""The items whose agent rang with nobody looking - `bell` on an agent
session, by the url it was tagged with.

What `Marks.rang` is made of: the third reason a row is unread, beside the
wake table and a snooze that ran out, and the second that GitHub did not do.
Read once per `refilter!` the way the records are, and once by `wl unread`;
a listing is one process. A session from before the url was tagged reads
back an empty one and is nobody's bell until it is entered again, which
re-tags it.
"""
rang_urls(rows = mux_list()) =
    Set{String}(r.url for r in rows if r.kind == "agent" && r.bell && !isempty(r.url))

"""Silence the item's agent, as every mark that reads the item does.

The woken-snooze rule again: every mark stamps the last movement, and a bell
left standing beside the stamp would keep the row unread whatever was pressed.
So `r`, `s`, `x` and the shell's marks clear it, through `mux_seen!` - an
attach tmux counts as looking. Answers the sessions it silenced, which is what
`z` rings again.
"""
function agent_seen!(url::AbstractString, rows = mux_list())
    names = String[r.name for r in rows if r.kind == "agent" && r.bell && r.url == url]
    for n in names
        mux_seen!(n)
    end
    names
end

"Ring again what `agent_seen!` silenced: the undo of a mark."
agent_ring!(names) = foreach(mux_ring!, names)

"""Open an agent on this item's worktree, and watch it work.

Nothing has to be set up first, and nothing is said to it on the way in.
Starting one is immediate, and what it should do is said in the pane.

The checkout is not described to it either. An agent already reads its working
directory and the branch there from its own system prompt, so anything added
here would be a second, staler copy of what it can see - and a system prompt
survives `/clear`, so a stale copy would outlive every correction made from
inside.
"""
function open_agent(it::Item, ctrl, say = _ -> nothing; items = Item[])
    enter_session(it, ctrl, :agent, (_, _) -> agent_cmd(), say; items)
end

"""Open a shell on this item's checkout, in its worktree's session, and show it.

Leaving the pane is not ending it: come back to the same checkout and the same
shell is still there, with whatever was half-typed still on the line.
"""
open_terminal(it::Item, ctrl, say = _ -> nothing; items = Item[]) =
    enter_session(it, ctrl, :shell, (_, _) -> get(ENV, "SHELL", "/bin/sh"), say; items)
