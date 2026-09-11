# Local checkouts: mapping GitHub repos to folders on disk, and reading file
# content out of them.
#
# Expanding the context around a hunk needs the whole file at the pull
# request's head commit. Asking GitHub for it is a request per expansion; a
# local clone already has the objects, or can fetch them once and keep them.
# So each repo is pinned to a checkout, and the mapping is asked for the first
# time it is needed rather than configured up front.
#
# The path the user gives may well be a worktree - resolving to the common git
# dir means one entry covers every worktree of the same repository.

# Kept as `repo:` blocks of `local.toml`, in the same flat namespace as the
# items: it is local, it is small, and it cannot be re-fetched - which is the
# only test this half of `data/` applies. `repos.toml` was a third file because
# it was written first, not because it is a different kind of thing.
const REPO_PREFIX = "repo:"

struct GitError <: Exception
    msg::String
end
Base.showerror(io::IO, e::GitError) = print(io, e.msg)

"""Run git in `dir`, returning stdout. Throws GitError with stderr on failure.

Under `LC_ALL=C`, because everything git says here is read by this program
rather than by a person: `%(upstream:track)` in particular comes back as
`[ahead 3, behind 1]` through gettext, and would be parsed wrong - silently,
as no divergence at all - in any locale that translates it.
"""
function git(dir::AbstractString, args...)
    out, err = IOBuffer(), IOBuffer()
    cmd = addenv(Cmd(`git $(collect(String, args))`; dir = String(dir)), "LC_ALL" => "C")
    try
        run(pipeline(cmd; stdout = out, stderr = err))
    catch
        throw(GitError(strip(String(take!(err)))))
    end
    String(take!(out))
end

"""A path as the user wrote it, with `~` meaning what they meant by it.

`register_repo!` expands on the way in, so anything this program wrote is
already absolute - but `repos.toml` says at the top of itself to edit it freely,
and a hand-written `~/src/julia` is exactly what somebody would put there. Read
raw it is not a directory, so the repo silently reads as unregistered and the
browser asks for the path again.

Not `abspath` as well: that would resolve a *relative* entry against whatever
directory `wl` happens to have been started in, which is a wrong answer that
looks like a right one. `~` is the one that has a meaning independent of where
you are standing.
"""
userpath(p::AbstractString) = isempty(p) ? String(p) : expanduser(String(p))

"Every pinned repo: `owner/name -> {gitdir, worktree, remotes}`."
function load_repos()
    isfile(localfile()) || return Dict{String,Any}()
    raw = try
        TOML.parsefile(localfile())
    catch
        return Dict{String,Any}()
    end
    Dict{String,Any}(k[length(REPO_PREFIX)+1:end] => v
                     for (k, v) in raw if startswith(k, REPO_PREFIX) && v isa AbstractDict)
end

"""Write one repo's entry, or with `nothing` forget it.

A block at a time through the line editor, so an entry edited by hand keeps its
comment and its spelling: this file says at the top of itself that it can be
edited freely, and a whole-file rewrite is what that rules out.
"""
function save_repo!(name::AbstractString, fields)
    set_blocks!([string(REPO_PREFIX, name) =>
                 (fields === nothing ?
                  ["gitdir" => nothing, "worktree" => nothing, "remotes" => nothing] :
                  [String(k) => v for (k, v) in sort(collect(fields); by = first)])])
    nothing
end

"""The directory holding the real object store.

For a worktree this is the main repository's .git, so one mapping serves every
worktree of it and objects fetched through any of them are visible to all.
"""
common_gitdir(path) = strip(git(path, "rev-parse", "--path-format=absolute",
                                "--git-common-dir"))

"`owner/name` for every remote, so a checkout can be matched to a repo."
function remote_names(path)
    out = String[]
    for l in split(git(path, "remote", "-v"), "\n")
        m = match(r"github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?\s", l * " ")
        m === nothing || push!(out, string(m[1], "/", m[2]))
    end
    unique(out)
end

"Path pinned to `name`, or nothing. Entries pointing at vanished folders are ignored."
function repo_path(name::AbstractString)
    d = get(load_repos(), String(name), nothing)
    d === nothing && return nothing
    p = userpath(get(d, "worktree", ""))
    isdir(p) ? p : nothing
end

"""Every pinned repo, with whether its checkout is still there.

`(name, path, there)`, sorted, and the path as it was written rather than as it
resolves - a `~` in a hand-edited entry is the user's text and worth showing
back to them unchanged.
"""
function pinned_repos()
    [(name = k, path = String(get(v, "worktree", "")),
      there = isdir(userpath(get(v, "worktree", ""))))
     for (k, v) in sort(collect(load_repos()); by = first)]
end

"""Forget the pinned repos whose checkouts are gone, and say which.

Never automatic, and that is the whole design: an entry can be missing because
the directory was deleted, or because an external disk is unplugged and will be
back this afternoon. `repo_path` already ignores what is not there, so nothing
is broken by leaving a stale entry - which means removing one can wait for
somebody to ask.
"""
function prune_repos!()
    gone = [name for (name, _, there) in pinned_repos() if !there]
    for name in gone
        save_repo!(name, nothing)
    end
    gone
end

"""Pin `name` to `path`, resolving worktrees and checking the remote matches.

The mismatch check is a warning rather than a refusal: forks, mirrors and
oddly-named remotes are all legitimate, and the user just said this is the one.
"""
function register_repo!(name::AbstractString, path::AbstractString)
    p = abspath(expanduser(String(path)))
    isdir(p) || throw(GitError("no such directory: $p"))
    gd = try
        common_gitdir(p)
    catch
        throw(GitError("not a git checkout: $p"))
    end
    rs = try remote_names(p) catch; String[] end
    save_repo!(name, Dict("worktree" => p, "gitdir" => gd,
                          "remotes" => join(rs, ",")))
    (path = p, gitdir = gd, matched = String(name) in rs)
end

"""Worktrees of this repo, skipping ones git calls prunable.

Each is `(path, branch, head, main)`. `branch` is empty on a detached head - a
real state for a worktree, and one the survey has to show rather than skip -
and `main` marks the primary checkout, which git always lists first.
"""
function worktrees(path::AbstractString)
    out = NamedTuple{(:path, :branch, :head, :main),Tuple{String,String,String,Bool}}[]
    cur, br, hd, prunable = "", "", "", false
    flush!() = (!isempty(cur) && !prunable &&
                push!(out, (path = cur, branch = br, head = hd, main = isempty(out))))
    for l in split(git(path, "worktree", "list", "--porcelain"), "\n")
        if startswith(l, "worktree ")
            flush!(); cur = String(l[10:end]); br = ""; hd = ""; prunable = false
        elseif startswith(l, "branch ")
            br = replace(String(l[8:end]), "refs/heads/" => "")
        elseif startswith(l, "HEAD ")
            hd = String(l[6:end])
        elseif startswith(l, "prunable")
            prunable = true
        end
    end
    flush!()
    out
end

"""The primary checkout of the repository `path` belongs to.

git lists the main worktree first and always, which is the only thing that
tells it apart from the linked ones. It matters because a new worktree wants to
be made beside the original rather than beside whichever copy the request came
from - a directory of siblings, not a chain of them.
"""
main_worktree(path::AbstractString) =
    (ws = worktrees(path); isempty(ws) ? String(path) : first(ws).path)

"""Where a worktree for `branch` would go, unless the user says otherwise.

Beside the main checkout and named after it, so `jn/fix` in `~/src/julia`
suggests `~/src/julia-jn-fix`. Slashes become dashes: a branch name is a path
of its own, and honouring that would put the checkout inside directories nobody
asked for and leave `julia-jn` behind when the branch is gone.
"""
function worktree_dest(path::AbstractString, branch::AbstractString)
    m = String(rstrip(main_worktree(path), '/'))
    joinpath(dirname(m), string(basename(m), "-", replace(branch, "/" => "-")))
end

"""Check `branch` out in a new worktree at `at`, and say where it landed.

Only for a branch that is checked out nowhere: git refuses a second worktree on
the same branch, and that refusal is what lets the branch list claim a branch
either has a place or has none.

The path is resolved on the way out rather than on the way in - `realpath`
wants the directory to exist, and a worktree is matched to its row and to its
sessions by the resolved form, so the unresolved one would fail to find what it
had just made.
"""
function add_worktree!(path::AbstractString, branch::AbstractString, at::AbstractString)
    dest = abspath(expanduser(String(at)))
    git(path, "worktree", "add", "--quiet", dest, String(branch))
    try realpath(dest) catch; dest end
end

have_commit(path, sha) =
    try; git(path, "cat-file", "-e", string(sha, "^{commit}")); true; catch; false; end

"""Make `sha` available locally, fetching the pull request head if need be.

Fetched once and kept: the point of pinning a checkout is that expanding
context afterwards costs nothing.
"""
function ensure_commit!(path, sha, prnum::Integer)
    have_commit(path, sha) && return true
    for spec in ("pull/$prnum/head", string(sha))
        try
            git(path, "fetch", "--quiet", "origin", spec)
            have_commit(path, sha) && return true
        catch
        end
    end
    false
end

"Is `a` reachable from `b`? False rather than an error when either is missing."
is_ancestor(path, a, b) =
    try; git(path, "merge-base", "--is-ancestor", string(a), string(b)); true
    catch; false; end

"""What happened to a branch between two of its heads.

Two commands, because a branch moves in two ways and they want different
answers. When the old head is still reachable from the new one the push only
added to it, and the plain diff between the two trees is the change to read.
When it is not, the branch was rebased or amended - the commits are different
objects and a tree diff would report every line the base branch moved as well -
and `git range-diff` is the one command that pairs the old commits with the new
ones and shows what actually differs between them.

Returns `(kind, text)`, where `kind` is `:diff` or `:range`, so the caller knows
which of the two it is drawing.
"""
function branch_moved(path, old, new)
    is_ancestor(path, old, new) ?
        (:diff, git(path, "diff", string(old), string(new))) :
        (:range, git(path, "range-diff", "--no-color", string(old, "...", new)))
end

"How many commits `new` has that `old` does not."
function commits_ahead(path, old, new)
    try
        parse(Int, strip(git(path, "rev-list", "--count", string(old, "..", new))))
    catch
        0
    end
end

"File contents at a commit, as lines. `nothing` when the path is absent there."
function file_at(path, sha, file)
    try
        split(git(path, "show", string(sha, ":", file)), "\n")
    catch
        nothing
    end
end

# --- the local survey -------------------------------------------------------
#
# What is checked out, and what work exists without a place to be. Two lists
# built from three git invocations per repo plus one per worktree, because a
# list wants every repo at once and per-item shelling does not scale to that -
# it is the same reason `branch` now rides along in `facts.json` rather than
# being asked for one pull request at a time.

"""One local branch, whether or not anything is checked out on it.

`ahead`/`behind` are against its upstream and are both zero when it has none,
which `upstream` being empty is how to tell apart from being in sync. `gone`
is the upstream that was deleted underneath it - a merged pull request's branch
looks exactly like this, so it is the strongest hint the survey has that
something is finished.
"""
Base.@kwdef struct Branch
    repo::String
    name::String
    head::String = ""
    at::String = ""          # committer date of its tip, ISO 8601
    subject::String = ""     # its tip's summary line, which is the best title
                             # an unlanded branch has
    upstream::String = ""
    ahead::Int = 0
    behind::Int = 0
    gone::Bool = false
    worktree::String = ""    # the worktree that has it out, "" for none
end

"""One checked-out worktree.

`branch` is empty on a detached head. `ahead`/`behind`/`upstream` are its
branch's, joined from `branches`, so a detached worktree reports none.
"""
Base.@kwdef struct Worktree
    repo::String
    path::String
    branch::String = ""
    head::String = ""
    at::String = ""
    staged::Bool = false
    unstaged::Bool = false
    upstream::String = ""
    ahead::Int = 0
    behind::Int = 0
    main::Bool = false
end

"""Parse `%(upstream:track)`: `[ahead 3, behind 1]`, `[gone]`, or empty.

Read rather than recomputed, because `for-each-ref` already knows: asking for
the counts instead means a `rev-list` per branch, which is the per-row shelling
this whole file exists to avoid.
"""
function track_counts(s::AbstractString)
    occursin("gone", s) && return (0, 0, true)
    a = match(r"ahead (\d+)", s)
    b = match(r"behind (\d+)", s)
    (a === nothing ? 0 : parse(Int, a[1]), b === nothing ? 0 : parse(Int, b[1]), false)
end

"Every local branch of one checkout, in one `for-each-ref`."
function branches(repo::AbstractString, path::AbstractString)
    # %09 is a tab: a branch name cannot contain one, and neither can any of the
    # other fields, so nothing here needs escaping. Dates are ISO strict so they
    # sort as strings, and object names are full, to match what `worktree list`
    # reports - shortening is the display's job, not two different lengths here.
    fmt = join(("%(refname:short)", "%(objectname)", "%(committerdate:iso-strict)",
                "%(upstream:short)", "%(upstream:track)", "%(worktreepath)",
                "%(contents:subject)"), "%09")
    out = Branch[]
    for l in split(git(path, "for-each-ref", "--format=" * fmt, "refs/heads"), "\n")
        isempty(strip(l)) && continue
        f = split(l, '\t')
        length(f) < 6 && continue
        ahead, behind, gone = track_counts(f[5])
        push!(out, Branch(; repo = String(repo), name = String(f[1]), head = String(f[2]),
                            at = String(f[3]), upstream = String(f[4]),
                            ahead = ahead, behind = behind, gone = gone,
                            worktree = String(f[6]),
                            subject = length(f) >= 7 ? String(f[7]) : ""))
    end
    out
end

"""What is different from HEAD here: `(staged, unstaged)`.

Two bits rather than one, because a half-staged checkout is a state worth
seeing: it means something was in the middle of being committed, which is not
the same as having been edited and not the same as being clean.

They come straight out of the porcelain's two status columns - `XY` per file,
`X` the index and `Y` the working tree - so a file that is staged and then
edited again sets both, which is exactly what happened to it.

Untracked files do not count. A build tree is full of them and none of them is
work in progress, so counting them would report every checkout dirty forever.
`--no-optional-locks` keeps a read from taking the index lock out from under a
git command the user is running in the same checkout.
"""
function changes(path::AbstractString)
    staged = unstaged = false
    try
        for l in split(git(path, "--no-optional-locks", "status", "--porcelain",
                           "--untracked-files=no"), '\n')
            length(l) >= 2 || continue
            x, y = l[1], l[2]
            x in (' ', '?') || (staged = true)
            y in (' ', '?') || (unstaged = true)
        end
    catch
    end
    (staged, unstaged)
end

"Anything at all different from HEAD, staged or not."
dirty(path::AbstractString) = any(changes(path))

"""
    survey(; withdirty = true) -> (worktrees, branches)

Every registered repo at once. A repo whose folder has gone is skipped rather
than reported, matching `repo_path`; anything that throws inside one repo costs
that repo and not the survey.

`withdirty = false` skips the one `git status` per worktree, which is the only
part that walks a tree - on a checkout the size of julia that is the difference
between instant and noticeable, and a caller drawing a list before the user has
asked about any particular row may want the cheap version first.
"""
function survey(; withdirty::Bool = true)
    ws, bs = Worktree[], Branch[]
    for (name, d) in sort(collect(load_repos()); by = first)
        p = userpath(get(d, "worktree", ""))
        isdir(p) || continue
        try
            brs = branches(name, p)
            byname = Dict(b.name => b for b in brs)
            append!(bs, brs)
            for w in worktrees(p)
                b = get(byname, w.branch, nothing)
                st, un = withdirty ? changes(w.path) : (false, false)
                push!(ws, Worktree(; repo = String(name), path = w.path,
                                     branch = w.branch, head = w.head,
                                     at = b === nothing ? "" : b.at,
                                     staged = st, unstaged = un,
                                     upstream = b === nothing ? "" : b.upstream,
                                     ahead = b === nothing ? 0 : b.ahead,
                                     behind = b === nothing ? 0 : b.behind,
                                     main = w.main))
            end
        catch e
            e isa GitError || rethrow()
        end
    end
    (ws, bs)
end

# --- whose work is this ------------------------------------------------------
#
# `gh pr checkout` leaves someone else's branch in your checkout, and a browser
# that adopted a branch because you opened a terminal in it would quietly claim
# their work. So automatic adoption asks one question first: is there a commit
# of yours on this branch?

"""Has every commit on `branch` already landed in its base?

The only signal a local branch has that its work is over. A pull request is told
by GitHub; a branch that was rebased and merged keeps no other trace of it, and
`--is-ancestor` is true however the work got there - merge, squash or rebase.
"""
function merged_here(path::AbstractString, branch::AbstractString; base = nothing)
    isempty(branch) && return false
    b = base === nothing ? default_base(path) : base
    b === nothing && return false
    try
        git(path, "merge-base", "--is-ancestor", branch, b)
        true
    catch
        false
    end
end

"Does `rev` name something in this repo?"
has_rev(path::AbstractString, rev::AbstractString) =
    try; git(path, "rev-parse", "--verify", "--quiet", string(rev, "^{commit}")); true
    catch; false; end

"""What a branch is measured against: the default branch, if one can be found.

`origin/HEAD` is the real answer and is often simply absent - it is only set by
`clone`, and a repo added as a second remote or fetched into never gets one -
so the usual names are tried after it. `nothing` when none of them exists, which
is a refusal to guess rather than a fallback to the whole history: with no base
every commit on the branch counts, and the guard would pass for anything.
"""
function default_base(path::AbstractString)
    try
        r = strip(git(path, "symbolic-ref", "--short", "--quiet", "refs/remotes/origin/HEAD"))
        isempty(r) || return String(r)
    catch
    end
    for c in ("origin/master", "origin/main", "master", "main")
        has_rev(path, c) && return c
    end
    nothing
end

"""The strings that mean *you* to git, for matching a commit's authorship.

Git identity is per checkout and has nothing to do with the GitHub login, so
both go in: `user.email` and `user.name` from the repo itself, plus the login
and the address GitHub hands out for it. The login is matched as a *substring*
of an email, which is what makes `1234567+login@users.noreply.github.com` count.
"""
function git_ids(path::AbstractString, login::AbstractString = "")
    ids = String[]
    for k in ("user.email", "user.name")
        try
            v = strip(git(path, "config", "--get", k))
            isempty(v) || push!(ids, String(v))
        catch
        end
    end
    isempty(login) || append!(ids, [String(login), string(login, "@users.noreply.github.com")])
    unique(lowercase.(ids))
end

"""Is any commit on `branch`, but not on its base, yours?

Authored or co-authored: a commit you wrote with someone else is still work you
did, and the trailer is the only record of that. Bounded at `limit` commits,
because this runs on a keystroke and a branch that far from its base is not one
you are about to be surprised to own.

False when the base cannot be found, when git fails, or when there is nothing on
the branch at all - every uncertainty refuses, because this only ever *grants*
adoption automatically and the explicit route is always still there.
"""
function mine_on_branch(path::AbstractString, branch::AbstractString, ids;
                        base = nothing, limit::Int = 200)
    (isempty(branch) || isempty(ids)) && return false
    b = base === nothing ? default_base(path) : base
    b === nothing && return false
    out = try
        git(path, "log", "-n", string(limit), "--format=%an%x1f%ae%x1f%b%x1e",
            string(b, "..", branch))
    catch
        return false
    end
    for rec in split(out, '\x1e'; keepempty = false)
        fs = split(rec, '\x1f')
        length(fs) >= 2 || continue
        name, email = lowercase(strip(fs[1])), lowercase(strip(fs[2]))
        any(i -> i == name || occursin(i, email), ids) && return true
        length(fs) >= 3 || continue
        for l in split(fs[3], '\n')
            startswith(lowercase(strip(l)), "co-authored-by:") || continue
            any(i -> occursin(i, lowercase(l)), ids) && return true
        end
    end
    false
end
