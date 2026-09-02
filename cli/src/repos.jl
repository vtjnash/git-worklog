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

const REPOS_FILE = Ref("")
repos_file() = (isempty(REPOS_FILE[]) &&
                (REPOS_FILE[] = joinpath(ROOT, "repos.toml")); REPOS_FILE[])

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

load_repos() = isfile(repos_file()) ? TOML.parsefile(repos_file()) : Dict{String,Any}()

function save_repos(d)
    io = IOBuffer()
    println(io, "# GitHub repo -> local checkout. Written by the browser when it")
    println(io, "# first needs file content; edit or delete entries freely.")
    for (k, v) in sort(collect(d); by = first)
        println(io, "\n[\"", k, "\"]")
        for (kk, vv) in sort(collect(v); by = first)
            println(io, kk, " = ", repr(String(vv)))
        end
    end
    write(repos_file(), String(take!(io)))
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
    p = get(d, "worktree", "")
    isdir(p) ? String(p) : nothing
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
    catch e
        throw(GitError("not a git checkout: $p"))
    end
    rs = try remote_names(p) catch; String[] end
    d = load_repos()
    d[String(name)] = Dict("worktree" => p, "gitdir" => gd,
                           "remotes" => join(rs, ","))
    save_repos(d)
    (path = p, gitdir = gd, matched = String(name) in rs)
end

"""Worktrees of this repo, skipping ones git calls prunable.

Each is `(path, branch, head, main)`, which destructures as `(path, branch)` for
the callers that only want somewhere to work. `branch` is empty on a detached
head - a real state for a worktree, and one the survey has to be able to show
rather than skip. `main` marks the primary checkout, which git always lists
first.
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
        p = get(d, "worktree", "")
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
