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

"Every remote that points at GitHub, by name: `\"origin\" => \"owner/name\"`."
function remote_repos(path)
    out = Dict{String,String}()
    for l in split(git(path, "remote", "-v"), "\n")
        m = match(r"^(\S+)\s+\S*github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?\s", l * " ")
        m === nothing || (out[String(m[1])] = string(m[2], "/", m[3]))
    end
    out
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
unless the head is only detached for the length of a rebase or bisect, in which
case it is the branch that is coming back (`returning_branch`). `main` marks
the primary checkout, which git always lists first.
"""
function worktrees(path::AbstractString)
    out = NamedTuple{(:path, :branch, :head, :main),Tuple{String,String,String,Bool}}[]
    cur, br, hd, prunable = "", "", "", false
    flush!() = (!isempty(cur) && !prunable &&
                push!(out, (path = cur, branch = isempty(br) ? returning_branch(cur) : br,
                            head = hd, main = isempty(out))))
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

"""The branch a detached worktree is on its way back to, or `""`.

A rebase detaches HEAD and reattaches it when it is done, and a bisect does the
same, so for as long as either lasts `worktree list` shows a bare commit where
the branch was - and the pull request that branch carries drops off the row at
exactly the moment the work on it is hottest. git has not forgotten: the name is
in `rebase-merge/head-name` (`rebase-apply/` for `git am` and the old rebase)
and in `BISECT_START`, under the *worktree's* git directory, which for a linked
worktree is named by its `.git` file - read here rather than asked for, to keep
the survey at one `git` per repo. (`%(worktreepath)` does not help: git answers
it only for an attached head, so `branches` takes the answer from here.)

A `head-name` that is not a branch is the sha of an already-detached head being
rebased, which is no branch at all.
"""
function returning_branch(path::AbstractString)
    dot = joinpath(path, ".git")
    gd = if isdir(dot)
        dot
    elseif isfile(dot)
        m = match(r"^gitdir:\s*(.+?)\s*$"m, read(dot, String))
        m === nothing && return ""
        isabspath(m[1]) ? String(m[1]) : normpath(joinpath(path, m[1]))
    else
        return ""
    end
    for f in ("rebase-merge/head-name", "rebase-apply/head-name", "BISECT_START")
        p = joinpath(gd, f)
        isfile(p) || continue
        n = replace(strip(readline(p)), r"^refs/heads/" => "")
        (isempty(n) || occursin(r"^[0-9a-f]{40}$", n)) && return ""
        return n
    end
    ""
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

With `from`, the branch is not here yet and is made there, tracking `from` -
a remote-tracking ref, named in full. Said outright rather than left to git's
guess from the bare name, which makes a local branch off the one remote that
has it and refuses with `invalid reference` the moment two remotes do: a
checkout with `origin` on the fork and `upstream` on the project carries the
project's release branches on both.

The path is resolved on the way out rather than on the way in - `realpath`
wants the directory to exist, and a worktree is matched to its row and to its
sessions by the resolved form, so the unresolved one would fail to find what it
had just made.
"""
function add_worktree!(path::AbstractString, branch::AbstractString, at::AbstractString;
                       from::AbstractString = "")
    dest = abspath(expanduser(String(at)))
    if isempty(from)
        git(path, "worktree", "add", "--quiet", dest, String(branch))
    else
        git(path, "worktree", "add", "--quiet", "--track", "-b", String(branch), dest,
            String(from))
    end
    try realpath(dest) catch; dest end
end

have_commit(path, sha) =
    try; git(path, "cat-file", "-e", string(sha, "^{commit}")); true; catch; false; end

"""Check the pull request out in `path`, the way `gh pr checkout` does it.

`gh` rather than `git`, because the branch of a pull request from a fork is
on no remote this checkout has: `refs/pull/N/head` is on the project's
remote, and gh fetches it into a branch of the head's name and points that
branch's upstream at the fork, which is what `git push` from it needs. For a
branch of the project's own it is the tracking checkout git would have made.
The url and not the number, so which repository is not left to gh to infer
from the remotes - a checkout of somebody else's project has two.

`as` is the local branch to make, when the head's own name will not do. Left
to itself gh uses the head's name, and when a branch of that name is already
here it fetches `refs/pull/N/head` *into it*: a fork's pull request from its
`master` would fast-forward this checkout's `master` onto the fork's commits
when it could, and be refused when `master` is checked out somewhere, which
it always is. Neither is a checkout of the pull request.

Throws `GitError` with what gh said, since every way this fails - a changed
file the branch would overwrite, no network, no `gh` - is a thing to show in
its own words. Blocks for the fetch, as `ensure_base!` does for `p`.
"""
function checkout_pr!(path::AbstractString, url::AbstractString; as::AbstractString = "")
    out, err = IOBuffer(), IOBuffer()
    args = isempty(as) ? `gh pr checkout $url` : `gh pr checkout $url --branch $as`
    cmd = addenv(Cmd(args; dir = String(path)), "LC_ALL" => "C")
    try
        run(pipeline(cmd; stdout = out, stderr = err))
    catch e
        e isa Base.IOError && throw(GitError("could not run gh: " * e.msg))
        msg = strip(String(take!(err)))
        throw(GitError(isempty(msg) ? "gh pr checkout failed" : msg))
    end
    nothing
end

"""A new worktree at `at` with the pull request checked out in it, for a branch
this repository does not have - a fork's, before anything fetched it - or has
only the name of, in which case `as` is the name to make instead
(`checkout_pr!`).

`add_worktree!` wants a branch that is here. What is always here is `HEAD`, so
the worktree is made detached on it and `checkout_pr!` runs inside, which
makes the branch and moves onto it. When that fails the worktree is taken away
again, so a failure leaves git's complaint and no directory to explain.
"""
function add_worktree_pr!(path::AbstractString, url::AbstractString, at::AbstractString;
                          as::AbstractString = "")
    dest = abspath(expanduser(String(at)))
    git(path, "worktree", "add", "--quiet", "--detach", dest)
    try
        checkout_pr!(dest, url; as)
    catch
        try git(path, "worktree", "remove", "--force", dest) catch end
        rethrow()
    end
    try realpath(dest) catch; dest end
end

"""What `git status` says about `path`, short, for a question about switching
it: the changed files, up to `limit` of them and a count of the rest, or
`clean`. Untracked files are left out for `changes`'s reason - a build tree is
full of them - and a status that cannot be read is one row saying why.
"""
function status_preview(path::AbstractString; limit::Int = 8)
    out = try
        git(path, "--no-optional-locks", "status", "--short", "--untracked-files=no")
    catch e
        e isa GitError || rethrow()
        return [string("git status: ", oneline(e.msg))]
    end
    ls = String[String(l) for l in split(out, '\n'; keepempty = false)]
    isempty(ls) && return ["clean"]
    length(ls) <= limit && return ls
    vcat(ls[1:limit], [string("\u2026 and ", length(ls) - limit, " more")])
end


"""Which remote points at `repo`, or `origin` when none does.

A checkout of somebody else's project has two, and which one is called `origin`
is whichever way round the user cloned it: the Term.jl checkout beside this one
has `origin` on the fork and `upstream` on the project. That decides where the
fetch below can work at all - `refs/pull/N/head` exists only on the project, and
a fork does not carry one.
"""
function remote_for(path, repo::AbstractString)
    want = lowercase(String(repo))
    try
        for l in split(git(path, "remote", "-v"), "\n")
            m = match(r"^(\S+)\s+\S*github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?\s",
                      l * " ")
            m === nothing && continue
            lowercase(string(m[2], "/", m[3])) == want && return String(m[1])
        end
    catch
    end
    "origin"
end

"""Make `sha` available locally, fetching the pull request head if need be.

Fetched once and kept: the point of pinning a checkout is that expanding
context afterwards costs nothing.

**A head that was force-pushed away is still fetchable, and that was measured
rather than assumed.** The worry was that `read_head` names a commit reachable
from no ref once the branch has been rewritten over it, so there would be
nothing to diff against. GitHub serves it anyway: three orphaned heads taken
from `HeadRefForcePushedEvent` on FedeClaudi/Term.jl - from 2026-09-02,
2026-06-03 and 2025-07-25 - all came back from `git fetch <remote> <sha>` on
2026-09-11, the oldest of them fourteen months after it stopped being anybody's
head. That is why the bare sha is a real second try and not a formality.
"""
function ensure_commit!(path, sha, prnum::Integer; remote::AbstractString = "origin")
    have_commit(path, sha) && return true
    for spec in ("pull/$prnum/head", string(sha))
        try
            git(path, "fetch", "--quiet", remote, spec)
            have_commit(path, sha) && return true
        catch
        end
    end
    false
end

"What a branch name may look like before it is written into a refspec."
const REF_OK = r"^[A-Za-z0-9][A-Za-z0-9._/-]*$"

"""Bring the base branch up to date locally, and answer with the ref holding it.

The merge base is measured against this, so a stale copy is a wrong answer
rather than merely an old one: every commit the base has gained since this
checkout last heard of it falls *inside* the range and is reported as part of
what somebody pushed. One ref and one round trip - 0.26-0.52s against a current
checkout - which is the same order as the two head fetches beside it.

An explicit refspec, so what moves is the remote-tracking ref. `FETCH_HEAD`
would be fresher and is a single file shared by every worktree of the
repository, which two of these running at once would tear.
"""
function ensure_base!(path, repo::AbstractString, base::AbstractString)
    # No network, no such branch, no such remote: whatever is already here is
    # still worth measuring against - it is only ever too old, never wrong
    # about which commits are the base's.
    fetch_base!(path, repo, base)
    base_ref(path, repo, base)
end

"The round trip of [`ensure_base!`](@ref) alone: whether the base branch was brought up to date."
function fetch_base!(path, repo::AbstractString, base::AbstractString)
    (isempty(base) || match(REF_OK, base) === nothing) && return false
    r = remote_for(path, repo)
    try
        git(path, "fetch", "--quiet", r, "+refs/heads/$base:refs/remotes/$r/$base")
        true
    catch
        false
    end
end

"""The ref holding the base branch as this checkout last heard of it, or `""`.

The remote-tracking ref first, then a local branch of the name. What
[`ensure_base!`](@ref) answers with once it has fetched, and the answer on its
own for a caller that must not wait on the network - a key press that opens
an editor - and can live with a base that is only ever too old.
"""
function base_ref(path, repo::AbstractString, base::AbstractString)
    (isempty(base) || match(REF_OK, base) === nothing) && return ""
    r = remote_for(path, repo)
    for cand in ("refs/remotes/$r/$base", "refs/heads/$base")
        try
            git(path, "rev-parse", "--verify", "--quiet", cand)
            return cand
        catch
        end
    end
    ""
end

"The newest commit two revisions share, or empty when they share none."
merge_base(path, a, b) =
    try; String(strip(git(path, "merge-base", string(a), string(b)))); catch; ""; end

"""The pull request's diff as the checkout computes it, or `nothing` when the
checkout cannot: `git diff` from the merge base of the base branch and `head`
to `head`, which is the diff GitHub serves for it.

The head is fetched when it is not here - `refs/pull/N/head`, as `p` and
`]` do. The base is measured from `base_sha`, where the lanes saw the base
branch, and with both shas in the checkout the merge base is a local
question and nothing goes over the network: git is the cache, and there is
nothing to key a diff by. A base sha the checkout lacks is fetched by its
branch, once.

Without a base sha - a record from before the lanes carried one, or a base
the fetch did not bring - the base *branch* answers, and it has to be
fetched every time: a copy of it older than the fork point is the one thing
that makes this diff wrong rather than late, the base's own commits coming
out as the pull request's, and nothing local tells that copy apart from a
branch made off the current tip, since both have the base as an ancestor of
the head. When that fetch fails and the base is an ancestor, the checkout
says nothing and gh's copy is the better answer.

`-M` because GitHub detects renames; the prefixes said outright because
`diff.noprefix` in someone's config would take the `b/` that `hunk_nodes`
strips; `--no-ext-diff` and `--no-color` because a difftool or `color.ui`
would put something that is not a diff on the pipe.
"""
function pr_diff(path, repo::AbstractString, prnum::Integer, base::AbstractString,
                 base_sha::AbstractString, head::AbstractString)
    isempty(head) && return nothing
    ensure_commit!(path, head, prnum; remote = remote_for(path, repo)) || return nothing
    from = ""
    if !isempty(base_sha)
        have_commit(path, base_sha) || fetch_base!(path, repo, base)
        have_commit(path, base_sha) && (from = base_sha)
    end
    if isempty(from)
        fetched = fetch_base!(path, repo, base)
        from = base_ref(path, repo, base)
        isempty(from) && return nothing
        fetched || !is_ancestor(path, from, head) || return nothing
    end
    mb = merge_base(path, from, head)
    isempty(mb) && return nothing
    try
        git(path, "diff", "-M", "--no-color", "--no-ext-diff",
            "--src-prefix=a/", "--dst-prefix=b/", mb, head)
    catch
        nothing
    end
end

"Is `a` reachable from `b`? False rather than an error when either is missing."
is_ancestor(path, a, b) =
    try; git(path, "merge-base", "--is-ancestor", string(a), string(b)); true
    catch; false; end

"""Did the local `branch` ever contain `tip`, at any position its reflog
remembers?

`git push --force-if-includes`'s question, asked for the other direction. A
branch that is behind its upstream is one of two things ancestry cannot tell
apart: one that upstream moved away from while nobody here was looking, and
one that was rewound *from* a position that had those commits - a reset, a
rebase in progress, a commit dropped on purpose. The reflog can: if any past
position of the branch contains the tip, the tip was here and was moved away
from deliberately, and an offer to fast-forward would undo that. If none did,
upstream moved unseen.

One `rev-list` over every remembered position rather than an ancestry test
per entry: the count of commits reachable from `tip` and from none of them is
zero exactly when some position contains it. Capped at the newest 200 - the
reflog of a long-lived branch runs to thousands, and a rewind that far back
is not the case this is for. A branch with no reflog (expired at ninety days
by default, or `core.logAllRefUpdates` off) never included anything, which
errs towards the offer.
"""
function branch_included(path, branch::AbstractString, tip::AbstractString)
    (isempty(branch) || isempty(tip)) && return false
    log = try
        git(path, "reflog", "show", "-n", "200", "--format=%H", "refs/heads/" * branch)
    catch
        return false
    end
    hs = split(log, '\n'; keepempty = false)
    isempty(hs) && return false
    n = try
        strip(git(path, "rev-list", "--count", string(tip), "--not", String.(hs)...))
    catch
        return false
    end
    n == "0"
end

"""How the local `branch` stands to `tip`, as `(ahead, behind)`: commits on
the branch not reachable from the tip, and the reverse. `nothing` when either
is missing."""
function branch_lag(path, branch::AbstractString, tip::AbstractString)
    out = try
        git(path, "rev-list", "--left-right", "--count",
            string("refs/heads/", branch, "...", tip))
    catch
        return nothing
    end
    m = match(r"^(\d+)\s+(\d+)", strip(out))
    m === nothing ? nothing : (ahead = parse(Int, m[1]), behind = parse(Int, m[2]))
end

"""One line when `push.useForceIfIncludes` is off in this checkout - or `""`.

`--force-with-lease` on its own checks the remote against
`refs/remotes/<r>/<b>`, and any fetch moves that ref: gh's, when it checks a
pull request of the project's own out (`+refs/heads/<b>:refs/remotes/<r>/<b>`),
an editor's in the background, a `git fetch` of the user's own a minute
before. A lease refreshed that way passes for commits the user never saw.
`push.useForceIfIncludes` closes it - the push then also wants the lease's
tip in the branch's own history, which a fetch cannot put there.

This program fetches into `refs/worklog/` for that reason (`fetch_private!`),
but every place it could touch is not the point: the user runs `gh pr
checkout` by hand as often as through `y`, and the hole is the same. So the
line is about the setting and not about any one fetch, and it is said where a
branch is already the question - the checkout and fast-forward offers - so it
is read once, next to the branch it protects. Read through git in the
checkout, so a global setting counts.
"""
function lease_note(path, repo::AbstractString, branch::AbstractString)
    v = try
        strip(git(path, "config", "--type=bool", "--get", "push.useForceIfIncludes"))
    catch
        ""
    end
    v == "true" && return ""
    r = remote_for(path, repo)
    string("push.useForceIfIncludes is not set \u00b7 any fetch moves ", r, "/", branch,
           ", which is all --force-with-lease checks")
end

"""Fetch the project's `branch` into a ref of this program's own, and answer
with that ref - or `""` when it could not.

Not into `refs/remotes/<r>/<branch>`, though that is where a fetch of the
branch would go: that ref is the *lease* `git push --force-with-lease` checks
the remote against, and a program updating it from behind the user's back
makes the lease pass for commits the user never saw - the very hole
`--force-if-includes` was added to close. What this program learns about the
remote it keeps under `refs/worklog/`, where nothing of the user's reads it.

`--refmap=` with nothing after it is load-bearing: a fetch of a branch by
name also updates the configured remote-tracking ref for it as a courtesy
(the "opportunistic" update, since 1.8.4), whatever refspec was given - the
empty refmap is the one way to say not to.
"""
function fetch_private!(path, repo::AbstractString, branch::AbstractString)
    (isempty(branch) || match(REF_OK, branch) === nothing) && return ""
    r = remote_for(path, repo)
    ref = string("refs/worklog/", r, "/", branch)
    try
        git(path, "fetch", "--quiet", r, "--refmap=", string("+refs/heads/", branch, ":", ref))
        ref
    catch
        ""
    end
end

"How many commits `b` has that `a` does not, and 0 when git will not say."
function commits_ahead(path, a, b)
    try
        parse(Int, strip(git(path, "rev-list", "--count", string(a, "..", b))))
    catch
        0
    end
end

"""What happened to a branch between two of its heads, measured against the
branch it is to be merged into.

Answers `(kind, text, then, now, moved)`: `:diff` or `:range`, the text to draw,
how many commits the pull request had at each end, and how far the base moved
under it.

Two commands, because a branch moves in two ways and they want different
answers. When the old head is still in the new one's history and the base has
not moved, the push only added commits, and the plain diff between the two trees
is the change to read. Otherwise the commits are different objects - rebased,
amended, or carrying a merge of a base that moved - and `git range-diff` is the
one command that pairs the old commits with the new ones and shows what differs
between each pair.

**The base is what makes the second one readable.** `git range-diff old...new`
measures both sides from the merge base *of the two heads*, which after a rebase
is where the branch originally left the base - so every commit the base gained
in between falls inside the new range and is reported as newly added. Rebasing a
two-commit pull request over ten commits of master reported twelve commits, ten
of them somebody else's, with the one real change last. Measured from `base`
instead, each side is the pull request's own commits as they stood, and the ten
are where they belong: a number in the header.

With no base to measure against - an item no lane gave one, a checkout with no
remote for it, a branch the fetch could not find - the two merge bases collapse
to the merge base of the heads, which is exactly the `old...new` this did before
and the best guess there is.
"""
function branch_moved(path, old, new; base::AbstractString = "")
    ob = isempty(base) ? "" : merge_base(path, base, old)
    nb = isempty(base) ? "" : merge_base(path, base, new)
    (isempty(ob) || isempty(nb)) && (ob = nb = merge_base(path, old, new))
    if isempty(ob)
        # Unrelated histories, or a merge base git will not name. Ranges cannot
        # be built at all here - `..old` is not an empty left-hand side, it is
        # `HEAD..old` - so this hands git the two heads and lets it answer.
        return (kind = :range,
                text = git(path, "range-diff", "--no-color", string(old, "...", new)),
                then = 0, now = 0, moved = 0)
    end
    then_, now_ = commits_ahead(path, ob, old), commits_ahead(path, nb, new)
    if ob == nb && is_ancestor(path, old, new)
        return (kind = :diff, text = git(path, "diff", string(old), string(new)),
                then = then_, now = now_, moved = 0)
    end
    (kind = :range,
     text = git(path, "range-diff", "--no-color",
                string(ob, "..", old), string(nb, "..", new)),
     then = then_, now = now_, moved = commits_ahead(path, ob, nb))
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

"""Every local branch of one checkout, in one `for-each-ref`.

`worktree` is `%(worktreepath)`, which git answers only for a head that is
attached; a branch mid-rebase has a place too, and `ws` - the worktree list,
handed in by a caller that already has it - is where that answer lives.
"""
function branches(repo::AbstractString, path::AbstractString; ws = worktrees(path))
    wtof = Dict(w.branch => w.path for w in ws if !isempty(w.branch))
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
                            worktree = isempty(f[6]) ? get(wtof, String(f[1]), "") : String(f[6]),
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
            wts = worktrees(p)
            brs = branches(name, p; ws = wts)
            byname = Dict(b.name => b for b in brs)
            append!(bs, brs)
            for w in wts
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

"The branch `HEAD` is on in `path`, or `\"\"` when it is detached."
head_branch(path::AbstractString) =
    try; strip(git(path, "symbolic-ref", "--quiet", "--short", "HEAD")); catch; ""; end

"""The local `branch`'s upstream as `<remote>/<branch>`, or `\"\"` when it has
none - the branch's own word for which remote copy it is a copy of. The bare
name, since `@{u}` is a suffix for a branch name and not for a ref."""
upstream_of(path::AbstractString, branch::AbstractString) =
    try
        strip(git(path, "rev-parse", "--abbrev-ref", string(branch, "@{u}")))
    catch
        ""
    end

"""What a session is tagged with for the branch its copy is on: the branch,
the branch a rebase or bisect will return to when the head is detached for
one (`returning_branch`), and `@` for a head detached on purpose. The same
answer `worktrees` gives for the copy, with the one difference that a plain
detached head is a word and not an empty string - so that a tag that *is*
empty can mean what it did before there was one: nothing known.
"""
function place_branch(path::AbstractString)
    b = head_branch(path)
    isempty(b) || return b
    b = returning_branch(path)
    isempty(b) ? "@" : b
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
