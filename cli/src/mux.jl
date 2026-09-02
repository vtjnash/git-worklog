# A terminal multiplexer as a place to put a child program.
#
# The browser can already hand a checkout to VS Code, which is a fine thing to
# do and a dead end: the editor lands outside the terminal and nothing comes
# back. A multiplexer session is the opposite. It holds a program that outlives
# the view of it, it can be looked at again later, and - the part that matters
# for everything built on top of this - its screen can be read back as text
# without the reader having to understand a single escape sequence.
#
# This file is only the session bookkeeping: find the binary, name a session
# after an item, start one, attach to it. Reading a session back is the next
# stage and belongs to a control-mode client, not here.

"""The multiplexer binary, or `nothing` when there is none.

`WORKLOG_TMUX` wins over `PATH` so a specific build can be pointed at without
installing it - which is how this gets tested in a sandbox, where the only tmux
is an artifact in the Julia depot.
"""
function mux_bin()
    b = get(ENV, "WORKLOG_TMUX", "")
    isempty(b) || return isfile(b) ? b : nothing
    Sys.which("tmux")
end

"""
    mux_name(stem, branch, ref, kind) -> String

What to *call* a session: the worktree it is in, the branch that worktree is on,
and the item that was in view when it was opened. All three, because each
answers a different question - which copy of the repo, which state of it, and
what you were doing - and the list is unreadable without any one of them.

This is a label and not an identity. Two of the three change under a session
that has not moved, so what a session *is* lives in its options, not its name;
see `mux_tag!`.

tmux does not reject `.` or `:` in a session name, it silently rewrites them to
`_`, so `wl-Distributed.jl-198` is created and then cannot be found under the
name it was asked for. Doing the same substitution here means the name held on
this side is the name the server holds. `/` it leaves alone, which is what lets
a branch keep its owner prefix.
"""
function mux_name(stem::AbstractString, branch::AbstractString,
                  ref::AbstractString, kind::Symbol = :shell)
    clean(x) = replace(String(x), '.' => '_', ':' => '_')
    parts = ["wl", clean(stem)]
    isempty(branch) || push!(parts, clean(branch))
    isempty(ref) || push!(parts, clean(ref))
    kind === :shell || push!(parts, String(kind))
    join(parts, '-')
end


"""Run a multiplexer command, returning `(ok, output)`.

Never throws: every caller here is on a keystroke path where a missing binary
or a dead server has to become a status line, not a backtrace.
"""
function mux(args::AbstractString...)
    bin = mux_bin()
    bin === nothing && return (false, "no tmux on PATH")
    try
        out = read(pipeline(`$bin $(collect(args))`; stderr = devnull), String)
        (true, out)
    catch e
        (false, e isa ProcessFailedException ? "" : first(sprint(showerror, e), 80))
    end
end

"""Whether a session of exactly this name exists.

`-t=name` is the exact form. Plain `-t name` is a pattern, and a session named
for one item would otherwise answer for another whose name extends it.
"""
mux_alive(name::AbstractString) = first(mux("has-session", "-t=" * name))

"""Start a detached session running `cmd` in `dir`, unless it is already up.

Detached is what makes this reusable: the session exists whether or not anyone
is looking at it, so attaching is a separate decision made later, possibly
several times.
"""
function mux_start(name::AbstractString, dir::AbstractString, cmd::AbstractString)
    mux_alive(name) && return (true, "")
    # One trailing argument, so tmux hands the whole thing to a shell. Passing
    # it pre-split would make the caller quote for a shell it cannot see.
    ok, err = mux("new-session", "-d", "-s", name, "-c", dir, standalone(cmd))
    ok ? (true, "") : (false, isempty(err) ? "could not start session" : err)
end

"""Wrap `cmd` so its child starts as if from a plain terminal.

Run the browser from inside an agent and every child inherits that agent's
session: `CLAUDE_CODE_CHILD_SESSION`, which silently turns the child's
transcript saving off, and `CLAUDE_CODE_MESSAGING_SOCKET` and its token, which
are the parent's control channel. An agent started in a pane is meant to be its
own session, answerable to the person watching it and to nobody else, and a
shell has no more business holding another session's credentials.

The names are read from this process rather than listed, so whatever a future
version inherits is scrubbed too, and nothing is scrubbed that was not actually
there. `env -u` does it at exec, which is the only place that certainly
applies: the tmux *server* keeps the environment it was started with, and every
session it is asked for later would otherwise be handed a copy.
"""
function standalone(cmd::AbstractString)
    vars = sort!([k for k in keys(ENV) if startswith(k, "CLAUDE")])
    isempty(vars) && return String(cmd)
    string("env ", join(("-u " * v for v in vars), ' '), ' ', cmd)
end

mux_kill(name::AbstractString) = first(mux("kill-session", "-t=" * name))

"""Record what a session *is*, as against what it is called.

A name carries the branch and the item in view, and both of those change under
a session that has never moved - a branch gets renamed, a different item gets
opened on the same checkout. So the name is a label and these are the identity:
the worktree, which is the resource actually being shared, and the kind, since
a shell and an agent in one checkout are two different things.

`@wl_item` is neither. It is what the metadata pane matches on, so that an item
can be told a session exists for it without anything having to work out which
worktree it would land in - which costs a `git` call, and the pane redraws.
"""
function mux_tag!(name::AbstractString, worktree::AbstractString, kind::Symbol,
                  item::AbstractString)
    ok = first(mux("set", "-t", name, "@wl_worktree", String(worktree)))
    ok &= first(mux("set", "-t", name, "@wl_kind", String(kind)))
    ok &= first(mux("set", "-t", name, "@wl_item", String(item)))
    ok
end

mux_rename(old::AbstractString, new::AbstractString) =
    old == new || first(mux("rename-session", "-t=" * old, String(new)))

"""The session for this worktree and kind, or `nothing`.

Matched here rather than with a tmux filter expression: a path can contain the
characters a format string is made of, and a comma in a checkout's name would
otherwise quietly match nothing.
"""
function mux_find(worktree::AbstractString, kind::Symbol, rows = mux_list())
    want = String(worktree)
    for r in rows
        r.worktree == want && r.kind === kind && return r
    end
    nothing
end

"""Every session this program owns, oldest first."""
function mux_sessions()
    ok, out = mux("list-sessions", "-F", "#{session_name}")
    ok || return String[]
    filter(n -> startswith(n, "wl-"), split(strip(out), '\n'; keepempty = false))
end

# --- control mode -----------------------------------------------------------
#
# One `tmux -C attach` per session, over a pipe pair, is the whole transport.
# A command goes in as a line; its reply comes back framed between `%begin` and
# `%end` carrying the same id, or `%error` when it failed. Screen activity
# arrives unasked as `%output`, which is the signal to redraw - the same role a
# landed fetch plays through `wake!`.
#
# The alternative, a `tmux` process per keystroke and per frame, costs a fork
# each time (~5ms against ~1ms here) and has no way to be told that something
# changed; it can only ask.
#
# The line parser is split from the process on purpose. `mux_feed!` is a pure
# function of one line and the state before it, so the protocol is tested from
# a vector of strings, the way `readevent` is tested from an `IOBuffer`.

"""Parser state: whether a reply block is open, and what has arrived in it."""
mutable struct MuxProto
    inblock::Bool
    err::Bool
    lines::Vector{String}
end
MuxProto() = MuxProto(false, false, String[])

"""
    mux_feed!(p, line) -> (kind, a, b)

One protocol line. `kind` is

  * `:reply`  — a block closed; `a` is whether it succeeded, `b` its lines
  * `:output` — `a` is the pane id, `b` the decoded bytes
  * `:notice` — any other `%` notification; `a` is its name, `b` the rest
  * `:more`   — a line inside an open block, kept for the reply

A line inside a block is *not* a notification even when it starts with `%`: a
`capture-pane` of a screen with a percent sign on it would otherwise be read as
protocol. Only `%end` and `%error` close a block.
"""
function mux_feed!(p::MuxProto, line::AbstractString)
    if p.inblock
        if startswith(line, "%end ") || startswith(line, "%error ")
            p.inblock = false
            out = (:reply, !startswith(line, "%error "), copy(p.lines))
            empty!(p.lines)
            return out
        end
        push!(p.lines, String(line))
        return (:more, nothing, nothing)
    end
    if startswith(line, "%begin ")
        p.inblock = true
        empty!(p.lines)
        return (:more, nothing, nothing)
    end
    if startswith(line, "%output ")
        rest = SubString(line, 9)
        sp = findfirst(' ', rest)
        sp === nothing && return (:output, String(rest), "")
        return (:output, String(SubString(rest, 1, sp - 1)),
                mux_unescape(SubString(rest, sp + 1)))
    end
    if startswith(line, "%")
        sp = findfirst(' ', line)
        sp === nothing && return (:notice, String(line)[2:end], "")
        return (:notice, String(SubString(line, 2, sp - 1)), String(SubString(line, sp + 1)))
    end
    (:more, nothing, nothing)          # a stray line outside any block
end

"""Undo the escaping tmux applies to `%output` data.

Only bytes below 0x20 and the backslash itself are escaped, as three octal
digits: a tab arrives as `\\011` and a backslash as `\\134`. Everything from
0x20 up passes through raw - DEL and UTF-8 continuation bytes included - so
this works on bytes rather than characters and leaves anything it does not
recognise exactly as it found it.
"""
function mux_unescape(s::AbstractString)
    occursin('\\', s) || return String(s)
    b = codeunits(s)
    out = IOBuffer()
    i = 1
    @inbounds while i <= length(b)
        c = b[i]
        if c == UInt8('\\') && i + 3 <= length(b) &&
           all(d -> UInt8('0') <= d <= UInt8('7'), (b[i+1], b[i+2], b[i+3]))
            write(out, UInt8((b[i+1] - 0x30) << 6 | (b[i+2] - 0x30) << 3 | (b[i+3] - 0x30)))
            i += 4
        else
            write(out, c)
            i += 1
        end
    end
    String(take!(out))
end

"""An attached control-mode client.

`onoutput` is called with the pane id whenever that pane changes. It runs on
the reader task, so it does the least possible: in the browser it is
`wake!(ctrl)`, which only pushes an event.
"""
mutable struct MuxClient
    name::String
    proc::Base.Process
    proto::MuxProto
    replies::Channel{Any}
    onoutput::Any
    reader::Union{Task,Nothing}
    dead::Bool
end

"""Attach to `name` in control mode.

The session must already exist; starting one is `mux_start`'s job, and keeping
the two separate is what lets a session outlive every client that has looked at
it.
"""
function mux_open(name::AbstractString; onoutput = nothing)
    bin = mux_bin()
    bin === nothing && return nothing
    mux_alive(name) || return nothing
    proc = try
        open(`$bin -C attach -t=$name`, "r+")
    catch
        return nothing
    end
    c = MuxClient(String(name), proc, MuxProto(), Channel{Any}(Inf), onoutput, nothing, false)
    c.reader = @async begin
        try
            for line in eachline(proc.out)
                kind, a, b = mux_feed!(c.proto, line)
                if kind === :reply
                    put!(c.replies, (a, b))
                elseif kind === :output
                    c.onoutput === nothing || c.onoutput(a)
                elseif kind === :notice && a == "exit"
                    break
                end
            end
        catch
        finally
            c.dead = true
            isopen(c.replies) && put!(c.replies, (false, ["client closed"]))
        end
    end
    mux_sync!(c) || (mux_close(c); return nothing)
    c
end

"""Line the reply stream up with the commands, and say whether it worked.

Attaching is itself a command as far as the server is concerned: it answers
with a `%begin`/`%end` block of its own before anything has been asked of it.
That block sits in the queue and every later reply is then one behind - the
first `capture-pane` comes back empty and the *next* command returns the
screen, which looks like a capture that failed rather than a stream that has
slipped.

Draining a fixed number of blocks would only work until a version emitted a
different number of them. A token nothing else could produce does not care:
throw replies away until the one that echoes it comes back.
"""
function mux_sync!(c::MuxClient; timeout::Real = 5.0)
    tok = string("wl-sync-", string(rand(UInt32); base = 16))
    try
        write(c.proc.in, "display-message -p ", tok, "\n")
        flush(c.proc.in)
    catch
        c.dead = true
        return false
    end
    deadline = time() + timeout
    while true
        left = deadline - time()
        left <= 0 && break
        late = Timer(_ -> (isopen(c.replies) && put!(c.replies, :timeout)), left)
        r = try
            take!(c.replies)
        finally
            close(late)
        end
        r === :timeout && break
        if r isa Tuple && length(r[2]) == 1 && strip(r[2][1]) == tok
            return true
        end
    end
    c.dead = true
    false
end

"""
    mux_ask(c, cmd; timeout) -> (ok, lines)

Send one command and wait for its reply.

Replies come back in the order the commands went out, so they are matched by
position rather than by parsing the id out of `%begin`. A timeout therefore
cannot be recovered from - the next reply would answer the wrong question - so
it kills the client instead of desynchronising it.
"""
function mux_ask(c::MuxClient, cmd::AbstractString; timeout::Real = 5.0)
    c.dead && return (false, ["client closed"])
    try
        write(c.proc.in, cmd, '\n')
        flush(c.proc.in)
    catch
        c.dead = true
        return (false, ["client closed"])
    end
    late = Timer(_ -> (isopen(c.replies) && put!(c.replies, :timeout)), timeout)
    try
        r = take!(c.replies)
        if r === :timeout
            c.dead = true
            return (false, ["timed out"])
        end
        return r
    finally
        close(late)
    end
end

"""The rendered screen of the session's active pane.

`-e` keeps the SGR escapes, and from tmux 3.4 the OSC 8 hyperlinks with them;
3.1c returns the link text with the URL dropped.

The target is `=name:` and not `=name`: the `=` exact form takes a session on
`has-session`, but `capture-pane` wants a pane, and `=name` there is read as a
pane called `name` and not found.

It is also written unquoted. Control mode does its own quote handling, and
`-t='=name:'` comes back *successful and empty* while `-t '=name:'` fails
outright looking for a session called `=name`. A session name is sanitised to
word characters and a hyphen by `mux_session`, so there is nothing here that
would need quoting anyway.
"""
function mux_capture(c::MuxClient; escapes::Bool = true)
    ok, lines = mux_ask(c, string("capture-pane -p", escapes ? " -e" : "", " -t =", c.name, ":"))
    ok ? lines : String[]
end

"""What the pane knows that its screen does not say: the cursor, and whether
the child has asked for mouse reporting.

Both in one round trip, because both are wanted on every redraw.

`(x, y)` are zero-based, as tmux counts them. The cursor has to be asked for
because `capture-pane` returns the grid and nothing else, and the real cursor is
hidden for the whole run.

`mouse` is whether the *child* turned mouse reporting on. It matters because a
mouse report forwarded to a program that never asked for one is printed as the
control characters it is.

The format is quoted and the target is not, which is the opposite way round
from everywhere else and is not a preference: `#` starts a comment in tmux's
command syntax, so an unquoted format is discarded and the default message
comes back instead - successfully, and about the session rather than the pane.
A quoted *target* meanwhile succeeds and matches nothing.
"""
function mux_pane_state(c::MuxClient)
    ok, lines = mux_ask(c, string("display-message -p -t =", c.name,
        ": '#{cursor_x},#{cursor_y},#{cursor_flag},#{mouse_any_flag}'"))
    (ok && !isempty(lines)) || return (0, 0, false, false)
    f = split(strip(lines[1]), ',')
    length(f) == 4 || return (0, 0, false, false)
    (something(tryparse(Int, f[1]), 0), something(tryparse(Int, f[2]), 0),
     f[3] == "1", f[4] == "1")
end

"""Size the session to `w` by `h`.

A pane is a whole session because `new-window` has no `-x`/`-y` in any version,
so this is how a widget gives its child the size of the box it is drawn in.
"""
mux_resize(c::MuxClient, w::Integer, h::Integer) =
    first(mux_ask(c, string("refresh-client -C ", w, ",", h)))

"""Send bytes to the pane exactly as typed.

`send-keys -H` takes hex, which is the point: no key name is looked up and no
sequence is interpreted, so an arrow, a paste and a mouse report all go through
as themselves.
"""
function mux_keys(c::MuxClient, bytes::AbstractVector{UInt8})
    isempty(bytes) && return true
    hex = join((string(b; base = 16, pad = 2) for b in bytes), ' ')
    first(mux_ask(c, string("send-keys -H -t =", c.name, ": ", hex)))
end
mux_keys(c::MuxClient, s::AbstractString) = mux_keys(c, collect(codeunits(s)))

function mux_close(c::MuxClient)
    c.dead = true
    try; close(c.proc.in); catch; end
    try; kill(c.proc); catch; end
    nothing
end

"""Show `name` full screen, however this program is being run.

Two different things, because attaching depends on where we already are.

Outside tmux there is a terminal to give away, and `suspend` gives it: raw mode
off, alternate screen left, both put back when the child is done.

Inside tmux there is not. `tmux attach` refuses to nest, and would fail with
`sessions should be nested with care` even though the session is right there on
the same server. What is wanted is the client we are already running under
pointed at the other session, which is `switch-client`, and it returns at once
rather than blocking until the user is finished - tmux's own binding brings
them back, and this program is left running in the session it was always in.
"""
function mux_attach(name::AbstractString, ctrl)
    bin = mux_bin()
    bin === nothing && return false
    if !isempty(get(ENV, "TMUX", ""))
        first(mux("switch-client", "-t=" * name)) && return true
        # A session on another server cannot be switched to; fall through and
        # try to attach, which will at least say why.
    end
    suspend(ctrl) do
        try
            run(`$bin attach -t=$name`)
        catch
            # Ctrl-C in the child, or a server that went away while attached.
            # Neither is worth a backtrace over the restored screen.
        end
    end
    true
end

"""Every session this program owns, with what is running in each.

One call, and only the active pane of each session: the list is a summary, and
a session with three windows is still one line of it. The `wl-` prefix is what
makes these ours - a session someone started by hand is not this program's to
list or to kill.
"""
function mux_list()
    ok, out = mux("list-panes", "-a",
                  "-f", "#{&&:#{window_active},#{pane_active}}",
                  "-F", "#{session_name}\t#{pane_current_command}\t#{session_attached}\t" *
                        "#{@wl_worktree}\t#{@wl_kind}\t#{@wl_item}")
    ok || return NamedTuple[]
    rows = NamedTuple[]
    for line in split(out, '\n'; keepempty = false)
        f = split(line, '\t')
        length(f) == 6 || continue
        startswith(f[1], "wl-") || continue
        push!(rows, (name = String(f[1]), command = String(f[2]),
                     attached = f[3] != "0", worktree = String(f[4]),
                     kind = isempty(f[5]) ? :shell : Symbol(f[5]),
                     item = String(f[6])))
    end
    sort!(rows; by = r -> r.name)
    rows
end
