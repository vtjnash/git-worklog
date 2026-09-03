# Which local checkout an item's work is in - the question `t`, `T` and `e`
# all have to answer, and the join between a pull request and a branch.


# --- editor -----------------------------------------------------------------

"""Where to work on this item: a checkout, its branch, and whether that was a
guess rather than an answer.

Three questions in order, and only the last one is a guess:

1. **A worktree already on the pull request's branch.** That is the copy the
   work is in, and no other answer can beat it.
2. **A session already tagged with this item.** `mux_list` rows carry the item
   they were opened on and the worktree they are in, so a session says where
   the work is happening whatever branch happens to be checked out there - and
   an *agent* left running in a scratch copy is exactly the case rule 1 cannot
   see. Kind does not matter: a shell should land where this item's agent is.
3. **Otherwise the main checkout**, which is where the work is *not* yet. That
   is the flag: the caller who can ask the user should, and the callers who
   cannot go there anyway.

The flag is the whole reason this is not two functions. `t` asks and `e` does
not, but they must not disagree about the same item - so both read the same
first two rules here, and answering one of them for `t` (by starting a session,
which tags it) answers it for `e` on the next press.

Returns `(nothing, "", false)` when the repo has never been registered.
"""
function item_worktree(it::Item)
    repo = repo_path(it.repo)
    repo === nothing && return (nothing, "", false)
    branch = pr_branch(it)
    ws = worktrees(repo)
    if !isempty(branch)
        for w in ws
            w.branch == branch && return (w.path, branch, false)
        end
    end
    if !isempty(it.ref)
        here = Dict(wtkey(w.path) => w for w in ws)
        for r in mux_list()
            (r.item == it.ref && !isempty(r.worktree)) || continue
            w = get(here, wtkey(r.worktree), nothing)
            w === nothing && continue
            return (w.path, w.branch, false)
        end
    end
    (repo, branch, true)
end

"""The checkout to work in for an item, and the branch it is for.

The same answer without the flag, for the callers that have nowhere to ask
from: an editor opens on the best guess rather than refusing to open.
"""
function item_checkout(it::Item)
    target, branch, _ = item_worktree(it)
    (target, branch)
end

"""This pull request's head branch, or `""` when it has none.

Comes off the item, which the search lanes now fill in - so the whole list of
them is known without a single request, which is what makes a worktree or
branch list possible at all. The `gh` call is only the fallback for a
`facts.json` written before the field existed; an issue has no branch and a
network hiccup should not stop a checkout from opening, so every failure is the
same empty answer.
"""
function pr_branch(it::Item)
    isempty(it.branch) || return it.branch
    it.is_pr || return ""
    try
        strip(read(`gh pr view $(it.number) --repo $(it.repo) --json headRefName -q .headRefName`,
                   String))
    catch
        ""
    end
end

"""Items by the branch they are the pull request for, as `(repo, branch)`.

The join the survey is for: `facts.json` carries `headRefName`, a local branch
knows its repo from the checkout it was found in, and between them a worktree
row can say which pull request is the work in it.

Keyed by both halves because branch names are not distinctive - every one of
these repos has a `master`, and several have the same topic branch name pushed
from different forks.
"""
function branch_index(items)
    d = Dict{Tuple{String,String},Item}()
    for it in items
        isempty(it.branch) && continue
        it.is_pr || islocal(it) || continue
        k = (it.repo, it.branch)
        prev = get(d, k, nothing)
        # A pull request wins over an adopted branch of the same name: a branch
        # adopted before it had one should show the pull request once it does.
        # Between two pull requests the newer wins, since a reused branch name
        # should not be shadowed by an older closed one.
        better = prev === nothing || (it.is_pr && !prev.is_pr) ||
                 (it.is_pr == prev.is_pr && it.number > prev.number)
        better && (d[k] = it)
    end
    d
end
