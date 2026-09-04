# Programs, drawn in a pane: `$EDITOR` on a note, a shell, an agent. This file
# decides *what to run and where*; `paneview.jl` draws it and forwards the keys.

"""Open a checkout of this pull request's branch in VS Code.

Prefers a worktree already on that branch, since that is the copy the user is
most likely to have been working in; otherwise falls back to the main checkout.
"""
function open_editor(it::Item)
    repo = repo_path(it.repo)
    repo === nothing && return :needs_repo
    Sys.which("code") === nothing && return "`code` is not on PATH"
    branch = pr_branch(it)
    target = repo
    for w in worktrees(repo)
        if !isempty(branch) && w.branch == branch
            target = w.path
            break
        end
    end
    try
        run(pipeline(`code $target`; stdout = devnull, stderr = devnull); wait = false)
    catch e
        return "could not launch code: " * first(sprint(showerror, e), 80)
    end
    string("opened ", target, isempty(branch) ? "" : string(" (", branch, ")"))
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
accidentally rewrite `state.toml`, and an emptied one clears the note rather
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
        name = mux_name(basename(rstrip(String(target), '/')), "", string(it.number), :note)
        # Never resumed, unlike a shell: this one is bound to a temp file that
        # holds the note as it was when the key was pressed, so an editor left
        # over from a previous `v` would be writing into a stale copy.
        mux_kill(name)
        ok, err = mux_start(name, target, string(noteeditor(), " ", shquote(path)))
        ok || return err
        mux_tag!(name, target, :note, it.ref)
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
        return "editing the note — it is saved when the editor exits"
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
    # the next refresh rewrites `facts.json`. Found by url rather than by the
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
                       ref::AbstractString, num::AbstractString,
                       title::AbstractString, ctrl, kind::Symbol, mkcmd)
    mux_bin() === nothing && return "no tmux on PATH"
    found = mux_find(target, kind)
    # Already looking at it. `^]t` and `^]T` reach here from inside a pane -
    # which is how a shell gets to the agent on the same item and back - and the
    # press that names the kind already showing would otherwise open a second
    # view onto one session and leave two `^]q`s between here and the browser.
    # Asked before the rename below, because that is what makes the name on the
    # view and the name on the session the same string.
    if found !== nothing && !isempty(ctrl.stack) &&
       last(ctrl.stack) isa PaneView && last(ctrl.stack).name == found.name
        return string("already in ", found.name)
    end
    name = mux_name(basename(rstrip(String(target), '/')), branch, num, kind)
    if found === nothing
        ok, err = mux_start(name, target, mkcmd(target, branch))
        ok || return err
    else
        mux_rename(found.name, name)
    end
    mux_tag!(name, target, kind, ref)
    v = pane_view(name, title, ctrl)
    v === nothing && return "could not attach to " * name
    pane_sync!(v)
    push_place!(ctrl, v)
    if found === nothing
        string("started ", name)
    elseif !isempty(found.item) && !isempty(ref) && found.item != ref
        # Not a refusal - the session is yours to redirect - but the
        # conversation in it is about something else until you say otherwise.
        string("back in ", basename(rstrip(String(target), '/')),
               " \u00b7 was on ", found.item)
    else
        string("back in ", name)
    end
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
    mux_bin() === nothing && return "no tmux on PATH"
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
    r = enter_session(target, branch, it.ref, string(it.number),
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
row, so both are on it. The marks are the worktree list's own, so a reader who
has seen `"` already knows them.
"""
function checkout_option(w, rows)
    live = sort!(unique(String[string(r.kind) for r in rows
                              if !isempty(r.worktree) &&
                                 wtkey(r.worktree) == wtkey(w.path)]))
    string(apad(afit(basename(rstrip(String(w.path), '/')), 30), 30), "  ",
           apad(afit(isempty(w.branch) ? "(detached)" : w.branch, 26), 26), "  ",
           w.main ? "main" : "    ",
           isempty(live) ? "" : string("  · ", join(live, " + "), " running"))
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
    opts = Tuple{String,Any}[(checkout_option(w, rows), w.path) for w in ws]
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
        dest, length(dest) + 1,
        at -> say(make_checkout!(it, ctrl, kind, mkcmd, say, at))))
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

`config.toml` overrides the lot, and is the honest answer for anything this
cannot guess - a wrapper script, a different agent, flags. An alias is a
convenience for a person typing, and asking one program to read another
program's interactive configuration is a long way round.
"""
function agent_cmd()
    c = get(get(config(), "agent", Dict{String,Any}()), "command", "")
    isempty(c) || return String(c)
    string(shquote(get(ENV, "SHELL", "/bin/sh")), " -ic ", shquote("claude"))
end

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
