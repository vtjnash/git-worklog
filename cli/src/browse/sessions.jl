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
                     mode::Symbol = :comments)
    target, branch = item_checkout(it)
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
    push!(st.undos, Undo(string("note ", it.ref), () -> begin
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
    found = mux_find(target, kind)
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
    # what the marks are keyed by, and an agent's bell is read as one.
    mux_tag!(name; worktree = target, kind = kind, item = ref, url = url)
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
"""
function enter_session(it::Item, ctrl, kind::Symbol, mkcmd, say = _ -> nothing)
    mux_bin() === nothing && return no_mux()
    target, branch, ask = item_worktree(it)
    target === nothing && return :needs_repo
    ask && return ask_checkout(it, ctrl, kind, mkcmd, say)
    item_session!(it, target, branch, ctrl, kind, mkcmd)
end

"""Open the item's session in a checkout that has already been settled on."""
function item_session!(it::Item, target::AbstractString, branch::AbstractString,
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
"""
function ask_checkout(it::Item, ctrl, kind::Symbol, mkcmd, say)
    repo = repo_path(it.repo)
    repo === nothing && return :needs_repo
    ws = worktrees(repo)
    rows = mux_list()
    opts = Tuple{String,Any}[(checkout_option(w, rows, it.repo), w.path) for w in ws]
    push!(opts, ("+ a new worktree …", ""))
    push_view!(ctrl, ChooseView(
        string(kind === :agent ? "Agent for " : "Shell for ", it.ref),
        "where to work · the last row makes a place",
        opts,
        p -> begin
            if isempty(String(p))
                say(ask_worktree_for(it, ctrl, kind, mkcmd, say))
            else
                i = findfirst(w -> w.path == p, ws)
                say(item_session!(it, String(p),
                                  i === nothing ? "" : ws[i].branch,
                                  ctrl, kind, mkcmd))
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
                          seed = "", note = "")
    repo = repo_path(it.repo)
    repo === nothing && return "no local checkout registered for " * it.repo
    branch = pr_branch(it)
    dest = !isempty(seed) ? String(seed) :
           isempty(branch) ? main_worktree(repo) : worktree_dest(repo, branch)
    push_view!(ctrl, PromptView(
        string("New worktree for ", it.ref),
        isempty(note) ? string("where to check ",
                               isempty(branch) ? "it" : branch,
                               " out · ", it.repo, " is at ", repo) : note,
        at -> say(make_checkout!(it, ctrl, kind, mkcmd, say, at)); initial = dest))
    ""
end

"""Make the place the prompt named, and open the session there.

Failure re-opens the prompt with what was typed still in it and git's own
complaint above it: every way this fails is a path that wants correcting - the
directory exists, its parent does not, the branch is checked out somewhere else.
"""
function make_checkout!(it::Item, ctrl, kind::Symbol, mkcmd, say, at::AbstractString)
    repo = repo_path(it.repo)
    repo === nothing && return "no local checkout registered for " * it.repo
    want = wtkey(abspath(expanduser(String(at))))
    for w in worktrees(repo)
        wtkey(w.path) == want &&
            return item_session!(it, w.path, w.branch, ctrl, kind, mkcmd)
    end
    branch = pr_branch(it)
    isempty(branch) &&
        return string(it.ref, " has no branch to check out · pick a worktree that exists")
    dest = try
        add_worktree!(repo, branch, at)
    catch e
        e isa GitError || rethrow()
        ask_worktree_for(it, ctrl, kind, mkcmd, say;
                         seed = at, note = oneline(first(sprint(showerror, e), 200)))
        return ""
    end
    r = item_session!(it, dest, branch, ctrl, kind, mkcmd)
    r isa String ? string("made ", dest, " · ", r) : r
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

`--settings` names [`AGENT_SETTINGS`](@ref), and it goes on the alias's line
rather than into the user's own settings: it is only wanted under a pane, and
`claude` run from a terminal is not to ring a bell into it every turn.

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
    string(shquote(get(ENV, "SHELL", "/bin/sh")), " -ic ",
           shquote(string("claude --settings ", shquote(AGENT_SETTINGS))))
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

A file and not an inline string, so what it says can be read; beside the code
and not in `data/`, because it names nobody and changes with the program.
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
function open_agent(it::Item, ctrl, say = _ -> nothing)
    enter_session(it, ctrl, :agent, (_, _) -> agent_cmd(), say)
end

"""Open a shell on this item's checkout, in its worktree's session, and show it.

Leaving the pane is not ending it: come back to the same checkout and the same
shell is still there, with whatever was half-typed still on the line.
"""
open_terminal(it::Item, ctrl, say = _ -> nothing) =
    enter_session(it, ctrl, :shell, (_, _) -> get(ENV, "SHELL", "/bin/sh"), say)
