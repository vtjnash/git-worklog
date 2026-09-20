# Which local checkout an item's work is in - the question `t`, `T` and `e`
# all have to answer, and the join between a pull request and a branch.


# --- editor -----------------------------------------------------------------

"""Where to work on this item: a checkout, its branch, and whether that was a
guess rather than an answer.

Three questions in order, and only the last one is a guess:

1. **A worktree already on the pull request's branch.** That is the copy the
   work is in, and no other answer can beat it - with the one refusal the
   worktree list makes too (`carrier_refused`): the main checkout on `master`
   is not a stranger's fork's `master`, whatever the name says, and taking
   it for one would put every `t` on their pull request in the project's own
   main checkout, on the project's own `master`, without a word.
2. **A session already tagged with this item.** `mux_list` rows carry the item
   they were opened on and the worktree they are in, so a session says where
   the work is happening whatever branch happens to be checked out there - and
   an *agent* left running in a scratch copy is exactly the case rule 1 cannot
   see. Kind does not matter: a shell should land where this item's agent is.
3. **Otherwise the main checkout**, which is where the work is *not* yet. That
   is the flag: the caller who can ask the user should, and the callers who
   cannot go there anyway.

Rule 2 has two exceptions, both a copy that has *moved* under the session
since the item was last put there, so that going back would open the shell
on the wrong branch without a word. Every session of the item's in a copy
carries the branch the copy was on when the item was last put there - the
answer is about the place, so it is written on all of them - and a copy on
some other branch now has moved: parked at `master`, detached, or checked
out on anything else, and whose the new branch is does not matter. And,
with `items` to see it, a copy that is on *another* item's branch
(`branch_owner`) is reused for them, whatever it was tagged with; that one
holds even for a session tagged before there was a branch to carry. Either
way the item has no place, and the rule falls through to the guess, which
asks. An item with no branch of its own keeps its session wherever it is:
the copy cannot be on the wrong branch when there is no right one.

The flag is the whole reason this is not two functions. `t` asks and `e` does
not, but they must not disagree about the same item - so both read the same
first two rules here, and answering one of them for `t` (by starting a session,
which tags it) answers it for `e` on the next press.

The answer is a named tuple, and the first three fields are the answer
proper: `path`, the `branch` that copy is on, and `ask`. Behind them is what
was looked up on the way and would otherwise be looked up again a key press
later ([`item_session!`](@ref) asks the same questions): whether the copy is
the `main` checkout, the pull request's own branch `pr` - a `gh` round trip
for a row from before the field existed - and the mux `rows`, or `nothing`
when they were not needed. `path` is `nothing` when the repo has never been
registered.
"""
function item_worktree(it::Item; items = Item[])
    repo = repo_path(it.repo)
    repo === nothing &&
        return (path = nothing, branch = "", ask = false, main = false, pr = "", rows = nothing)
    branch = pr_branch(it)
    ws = worktrees(repo)
    rows = nothing
    if !isempty(branch)
        for w in ws
            (w.branch == branch && !carrier_refused(it, w)) &&
                return (path = w.path, branch = branch, ask = false, main = w.main,
                        pr = branch, rows = rows)
        end
    end
    if !isempty(it.ref)
        here = Dict(wtkey(w.path) => w for w in ws)
        # Once, not once per session: the index is a pass over the whole list.
        ix = isempty(branch) ? nothing : branch_index(items)
        rows = mux_list()
        mine = [r for r in rows if r.item == it.ref && !isempty(r.worktree)]
        for r in mine
            w = get(here, wtkey(r.worktree), nothing)
            w === nothing && continue
            (ix !== nothing && branch_owner(it, w, ix) !== nothing) && continue
            # Moved if *any* session of the item's here was last entered on
            # some other branch: an answer is written on all of them, so one
            # that still disagrees is one from before the copy moved. The tag
            # is `place_branch`'s word, `@` for a detached head; one that is
            # empty is from before there was a tag, and knows nothing.
            want = isempty(w.branch) ? "@" : w.branch
            (!isempty(branch) &&
             any(x -> wtkey(x.worktree) == wtkey(w.path) && !isempty(x.branch) &&
                      x.branch != want, mine)) &&
                continue
            return (path = w.path, branch = w.branch, ask = false, main = w.main,
                    pr = branch, rows = rows)
        end
    end
    (path = repo, branch = branch, ask = true, main = true, pr = branch, rows = rows)
end

"""The checkout to work in for an item, and the branch it is for.

The same answer without the flag, for the callers that have nowhere to ask
from: an editor opens on the best guess rather than refusing to open.
"""
function item_checkout(it::Item; items = Item[])
    r = item_worktree(it; items)
    (r.path, r.branch)
end

"""The item whose branch a checkout `w` is on - a row of `worktrees`, or
anything with its `branch` and `main` - read off a [`branch_index`](@ref), or
`nothing`.

One refusal, and it is the same one wherever a checkout is matched to an item,
which is why it lives here and not in the pane that first needed it: a pull
request is matched to a checkout by branch name alone, which is all
`headRefName` gives - and on the *primary* checkout that is a collision
waiting to happen. It sits on `master`, and somebody's fork opens a pull
request from their own `master` about twice a week. Yours is at least
plausibly the work in there; a stranger's is not, and reading "the branch
carries its pull request" off it is simply wrong - the worktree list would
file the main checkout under their number, and rule 2 above would take it
for a copy *reused* for them, and ask about a place it had already been
answered for, on every press.
"""
function branch_carrier(ix, repo::AbstractString, w)
    it = get(ix, (String(repo), String(w.branch)), nothing)
    (it === nothing || carrier_refused(it, w)) ? nothing : it
end

"""The refusal itself: the main checkout is not a stranger's, by the name of
its branch alone. Shared by the list, rule 1 and rule 2, so no two of them
disagree about whose a copy is."""
carrier_refused(it::Item, w) = w.main && !author_ok(Set([AUTHOR_ME]), it)

"""The *other* item whose branch the checkout `w` is on, or `nothing`.

What says a checkout has been reused: the branch under a worktree is some
other pull request's, or an adopted branch's, in the same repository - with
[`branch_carrier`](@ref)'s refusal, so a stranger's `master` does not make
the main checkout theirs. Joined through a `branch_index` over the list the
browser has, which is why it is an argument - loading the corpus for one key
press is not the price of a look, and the index is built once by the caller
rather than once per session it looks at. An empty index sees nothing, which
is the old answer.
"""
function branch_owner(it::Item, w, ix)
    (isempty(w.branch) || isempty(ix)) && return nothing
    o = branch_carrier(ix, it.repo, w)
    (o === nothing || o.url == it.url) ? nothing : o
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
