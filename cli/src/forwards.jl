# What a pane is handed of the login that opened it: the ssh agent and VS Code's
# command line, at paths that do not move.
#
# tmux keeps the environment its server was started with and hands a copy to
# every session made later, with one exception: the `update-environment` list -
# `SSH_AUTH_SOCK`, `SSH_CONNECTION`, `DISPLAY` and a few more - is copied from
# the client asking for the session. So a pane opened tonight carries the agent
# socket of the login that opened it and the `PATH`, `SSH_CLIENT` and `VSCODE_*`
# of whichever login started the server, days ago (seen 2026-09-17, a real ssh
# session: `SSH_AUTH_SOCK` and `SSH_CONNECTION` from one login, `SSH_CLIENT` and
# `SSH_TTY` from another, no `VSCODE_*` at all; reproduced on the bundled tmux).
# Every one of those is a socket that dies with its login, so `git push` and
# `code <file>` fail in the pane where they work in the terminal beside it.
#
# Attaching refreshes the *session's* environment - a control-mode attach is an
# attach - but only the program in the pane could take that up, and only a shell
# with a hook in the user's rc file ever would; the agent in a `T` pane and the
# editor in a `v` pane never do. So the pane is handed paths that do not move,
# and every browser launch re-points them at what this login has, when it is
# live. What a pane was started with is then right for as long as the last
# login to run `wl` is - and the values come from that login's environment or
# not at all: nothing is searched for under `/run/user` or `/tmp`, because the
# newest socket there is some session's, and not necessarily this one's.

"""Where the links live: `\$XDG_RUNTIME_DIR/wl`, or `\$TMPDIR/wl-<uid>` where
there is no runtime directory.

The runtime directory is where the sockets these point at live too, so the
links share their lifetime: both are gone when the last login is. Not `data/`,
which is a record and a repository, and a socket link is neither.

A `Ref`, like every path this program writes through, so the suite can point
it somewhere disposable.
"""
const RUN_DIR = Ref("")
function rundir()
    isempty(RUN_DIR[]) || return RUN_DIR[]
    rt = get(ENV, "XDG_RUNTIME_DIR", "")
    RUN_DIR[] = isdir(rt) ? joinpath(rt, "wl") :
        joinpath(tempdir(), string("wl-", ccall(:getuid, Cuint, ())))
end

"""Make `d` ours alone, and say so - or throw, when it cannot be.

A link is a path to a socket that holds your keys, and its readers are whoever
can read the directory: a symlink's own mode is nothing on Linux, so `0700` on
the directory is where "600" lives, and it is set every time rather than only
when the directory is made, since anything could have made it. Under `/tmp` the
name is guessable, and a directory of that name that is somebody else's - or a
link to somewhere - is refused rather than written into, which is tmux's rule
for its own socket directory.
"""
function private_dir(d::AbstractString)
    ispath(d) || mkpath(d)
    st = lstat(d)
    (isdir(st) && !islink(st)) || error(string(d, " is not a directory"))
    st.uid == ccall(:getuid, Cuint, ()) || error(string(d, " is not ours"))
    chmod(d, 0o700)
    d
end

"""One thing a pane is to keep seeing.

`var` is what the pane is handed, `link` where under [`rundir`](@ref) the link
is. `own` is this process's value for it, `live` whether a value still
answers, and `what` is what to call it when nothing does.
"""
struct Forward
    var::String
    link::String
    own::Function
    live::Function
    what::String
end

"""Whether something is listening at `path` - a connection, closed at once.

The socket file outlives its listener: a forwarded agent's stays in
`/run/user` after the login that made it has gone, and `issocket` alone would
point every link at a corpse. Connecting is the only question with a true
answer, and to an agent or an IPC server a connection with nothing said on it
is nothing at all.
"""
function live_socket(path::AbstractString)
    issocket(path) || return false
    s = try
        Sockets.connect(path)
    catch
        return false
    end
    close(s)
    true
end

"This process's `code`, or `\"\"`."
own_code() = something(Sys.which("code"), "")

const FORWARDS = [
    Forward("SSH_AUTH_SOCK", "agent.sock", () -> get(ENV, "SSH_AUTH_SOCK", ""),
            live_socket, "ssh agent"),
    Forward("VSCODE_IPC_HOOK_CLI", "vscode-ipc.sock", () -> get(ENV, "VSCODE_IPC_HOOK_CLI", ""),
            live_socket, "VS Code"),
    # On the pane's `PATH`, in front, and not a variable of its own.
    Forward("PATH", joinpath("bin", "code"), own_code,
            p -> isfile(p) && Sys.isexecutable(p), "code"),
]

"""Point `link` at this process's own value when that is live, and answer with
what the link points at that is live - `""` when nothing is.

Own first, even when the link already points somewhere live, because the login
that just ran `wl` is the one most likely to outlast the rest. What the link
holds is kept otherwise, live or not: its value is the path, and the next
launch with something live puts a socket back under it. Through `realpath`, so
a value that is itself a link - the classic `~/.ssh/agent.sock` in someone's rc
- is followed to the socket, and a value that is *this* link cannot make it
point at itself.
"""
function point!(link::AbstractString, f::Forward)
    cur = islink(link) ? (try realpath(link) catch; "" end) : ""
    own = try realpath(f.own()) catch; "" end
    if !isempty(own) && own != link && f.live(own)
        own == cur || relink(link, own)
        return own
    end
    !isempty(cur) && f.live(cur) ? cur : ""
end

"""Replace `link` with one to `target`, as one step: a `git push` in a pane at
that moment finds the old agent or the new one, never nothing."""
function relink(link::AbstractString, target::AbstractString)
    private_dir(dirname(link))
    tmp = string(link, ".", getpid())
    rm(tmp; force = true)
    symlink(target, tmp)
    Base.Filesystem.rename(tmp, link)
end

"""
    forwards!() -> (env, gone)

Re-point every link at this login's value where that is live, and answer with
what a pane is to be handed - `name => value` pairs for [`mux_start`](@ref)'s
`set` - and the names of the forwards that have nothing live behind them.

A link that was never made is not handed over: a machine with no agent and no
VS Code has nothing to forward, and a pane there keeps whatever its server
holds rather than a variable pointing at nothing. A link that exists is handed
over even when it dangles today - the value is the path, and the next login
with something live puts the socket back under it.

`PATH` is this process's with the link directory in front, not the pane's with
it in front: the shell tmux runs the command through is whichever the server
was started with, and `\$PATH` reads differently in `fish` than in `sh`. So a
pane's `PATH` is the login's that opened it - which was already true of every
variable on the `update-environment` list, and is fresher than the server's -
and `code` is found before any of it.
"""
function forwards!()
    env = Pair{String,String}[]
    gone = String[]
    # Nothing is handed over from a directory that is not ours alone: a pane
    # would be told to find its keys where anyone could put a socket.
    dir = try
        private_dir(rundir())
    catch e
        logerror!(e, catch_backtrace(), "forwards")
        return (env = env, gone = gone)
    end
    for f in FORWARDS
        link = joinpath(dir, f.link)
        target = try
            point!(link, f)
        catch e
            logerror!(e, catch_backtrace(), string("forwards ", f.what))
            ""
        end
        islink(link) || continue
        isempty(target) && push!(gone, f.what)
        push!(env, f.var => (f.var == "PATH" ?
              string(dirname(link), ":", get(ENV, "PATH", "")) : link))
    end
    (env = env, gone = gone)
end

"""What a pane key says after what it said, when a forward has gone dead:
appended to the status rather than replacing it, since the pane opened."""
gone_suffix(gone) = join((string(" \u00b7 no live ", g) for g in gone))
