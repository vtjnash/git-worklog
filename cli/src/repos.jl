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

"Run git in `dir`, returning stdout. Throws GitError with stderr on failure."
function git(dir::AbstractString, args...)
    out, err = IOBuffer(), IOBuffer()
    cmd = Cmd(`git $(collect(String, args))`; dir = String(dir))
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

"Worktrees of this repo as (path, branch), skipping ones git calls prunable."
function worktrees(path::AbstractString)
    out = Tuple{String,String}[]
    cur, br, prunable = "", "", false
    flush!() = (!isempty(cur) && !prunable && push!(out, (cur, br)))
    for l in split(git(path, "worktree", "list", "--porcelain"), "\n")
        if startswith(l, "worktree ")
            flush!(); cur = String(l[10:end]); br = ""; prunable = false
        elseif startswith(l, "branch ")
            br = replace(String(l[8:end]), "refs/heads/" => "")
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
