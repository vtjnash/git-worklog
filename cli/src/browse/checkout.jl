# Which local checkout an item's work is in - the question `t`, `T` and `o`
# all have to answer, and the join between a pull request and a branch.


# --- editor -----------------------------------------------------------------

"""Where to work on this item: a checkout, its branch, and whether that was a
guess rather than an answer.

Three questions in order, and only the last one is a guess:

1. **A worktree already on the pull request's branch.** That is the copy the
   work is in, and no other answer can beat it. Whether a copy is on it is
   [`on_branch`](@ref)'s one answer, the worktree list's too: by name, with
   the refusal that the main checkout on `master` is not a stranger's fork's
   `master` ([`carrier_refused`](@ref)) - or by what git says the branch
   follows, since the pull request's branch is here as often under another
   name (`<owner>/master`, gh's; `pr<N>/<branch>`, ours) as under its own.
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

The flag is the whole reason this is not two functions. `t` asks and `o` does
not, but they must not disagree about the same item - so both read the same
first two rules here, and answering one of them for `t` (by starting a session,
which tags it) answers it for `o` on the next press.

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
    # What each branch here follows, read once for every worktree of the
    # repository: rule 1 and rule 2 both ask whose a copy's branch is, and
    # the name alone does not say (`on_branch`).
    tr = Tracking(repo)
    if !isempty(branch)
        for w in ws
            on_branch(it, w, tr) &&
                return (path = w.path, branch = w.branch, ask = false, main = w.main,
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
            (ix !== nothing && branch_owner(it, w, ix, tr) !== nothing) && continue
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

"""The copy `t` and `T` would open in without a question, or `""` when they
would ask: the first two rules of [`item_worktree`](@ref), for a caller that
wants to say what is running there before the key is pressed."""
function item_place(it::Item; items = Item[])
    r = item_worktree(it; items)
    (r.path === nothing || r.ask) ? "" : String(r.path)
end

"""The sessions in the copy at `place` that are other items' - the ones a
`t` or `T` on this item takes over, and re-points at it, so that theirs has
nothing running afterwards. Empty for no place. Not an untagged shell, which
is nobody's to take."""
taken_in(it::Item, place::AbstractString, rows) =
    isempty(place) ? NamedTuple[] :
    NamedTuple[r for r in rows if !isempty(r.item) && r.item != it.ref &&
               !isempty(r.worktree) && wtkey(r.worktree) == wtkey(place)]

"""The checkout to work in for an item, and the branch it is for.

The same answer without the flag, for the callers that have nowhere to ask
from: an editor opens on the best guess rather than refusing to open.
"""
function item_checkout(it::Item; items = Item[])
    r = item_worktree(it; items)
    (r.path, r.branch)
end

"""Items by the branch they are the pull request for, three ways.

The join the survey is for: `facts.json` carries `headRefName`, a local branch
knows its repo from the checkout it was found in, and between them a worktree
row can say which pull request is the work in it.

`byname` is `(repo, branch)`, keyed by both halves because branch names are
not distinctive - every one of these repos has a `master`, and several have
the same topic branch name pushed from different forks. `bynumber` is
`(repo, number)`, for a branch that tracks `refs/pull/N/head`; `byhead` is
`(repo, lowercase(head_repo), branch)`, for one that tracks a fork's copy of
a name that several forks have ([`branch_carrier`](@ref) reads both).
"""
struct BranchIndex
    byname::Dict{Tuple{String,String},Item}
    bynumber::Dict{Tuple{String,Int},Item}
    byhead::Dict{Tuple{String,String,String},Item}
end

Base.isempty(ix::BranchIndex) = isempty(ix.byname)

function branch_index(items)
    d = Dict{Tuple{String,String},Item}()
    n = Dict{Tuple{String,Int},Item}()
    h = Dict{Tuple{String,String,String},Item}()
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
        it.is_pr || continue
        n[(it.repo, it.number)] = it
        isempty(it.head_repo) && continue
        hk = (it.repo, lowercase(it.head_repo), it.branch)
        hp = get(h, hk, nothing)
        (hp === nothing || it.number > hp.number) && (h[hk] = it)
    end
    BranchIndex(d, n, h)
end

"""The item whose branch a checkout `w` is on - a row of `worktrees`, or
anything with its `path`, `branch` and `main` - or `nothing`.

The other direction of [`on_branch`](@ref), and it ends in it, so that the
list and the key never disagree about whose a copy is: the candidates come
off a [`branch_index`](@ref) - by the branch's name, and with `tr`, the
[`Tracking`](@ref) of its repository, by what the branch follows, a pull
request's `refs/pull/N/head` or a head `refs/heads/<name>` in whichever
repository it tracks - and the one that `on_branch` says yes to is the
answer. Without `tr` the name is all there is, as before.
"""
function branch_carrier(ix::BranchIndex, repo::AbstractString, w, tr = nothing)
    b = String(w.branch)
    isempty(b) && return nothing
    repo = String(repo)
    it = get(ix.byname, (repo, b), nothing)
    (it !== nothing && on_branch(it, w, tr)) && return it
    tr === nothing && return nothing
    r, ref = follows(tr, b)
    m = match(r"^refs/pull/(\d+)/head$", ref)
    it = if m !== nothing
        get(ix.bynumber, (repo, parse(Int, m[1])), nothing)
    else
        m = match(r"^refs/heads/(.+)$", ref)
        m === nothing && return nothing
        # The fork's copy of the name when the branch says whose it is, and
        # the name's best pull request when it does not, or the item has no
        # word on whose it wants (a row from before `head_repo`).
        head = String(m[1])
        o = isempty(r) ? nothing : get(ix.byhead, (repo, lowercase(r), head), nothing)
        o === nothing ? get(ix.byname, (repo, head), nothing) : o
    end
    (it !== nothing && on_branch(it, w, tr)) ? it : nothing
end

"""Whether the checkout `w` - a row of `worktrees`, or anything with its
`path`, `branch` and `main` - is on the item's branch.

Two ways to be, and one answer for every caller that asks - rule 1 of
[`item_worktree`](@ref), [`branch_carrier`](@ref) for the worktree list,
and the two looks before a session opens (`checkout_offer`, `update_offer`),
which used to compare the names and so offered `gh pr checkout master` in a
copy already on `<owner>/master`. By name first, with
[`carrier_refused`](@ref)'s refusal; and failing that by what git says the
branch follows ([`Tracking`](@ref)): `refs/pull/N/head` is this pull request
by number, and `refs/heads/<head>` in the head's repository is its branch
under another name - gh's `<owner>/master`, our `pr<N>/<branch>`, or one
made by hand with `--track`. A branch that tracks the project's copy of a
name is not a fork's pull request from that name, so the repository has to
agree when both sides say which; either side silent, the ref is enough. An
adopted branch is its name and nothing else - the name is its identity.
`tr` is the checkout's repository's record, or `nothing` for the name alone.
"""
function on_branch(it::Item, w, tr = nothing)
    b = String(w.branch)
    isempty(b) && return false
    b == it.branch && return !carrier_refused(it, w, tr)
    (tr === nothing || !it.is_pr) && return false
    r, ref = follows(tr, b)
    ref == string("refs/pull/", it.number, "/head") &&
        return isempty(r) || lowercase(r) == lowercase(it.repo)
    (isempty(it.branch) || ref != "refs/heads/" * it.branch) && return false
    isempty(r) || isempty(it.head_repo) || lowercase(r) == lowercase(it.head_repo)
end

"""The refusals in matching a checkout to an item by its branch: the main
checkout is not a stranger's, and a branch tracking one repository is not a
pull request from another.

A pull request is matched to a checkout by branch name, and a name is not
enough on its own. On the *primary* checkout it is a collision waiting to
happen: it sits on `master`, and somebody's fork opens a pull request from
their own `master` about twice a week. Yours is at least plausibly the work
in there; a stranger's is not. And any worktree on a branch that `gh pr
checkout` made for one fork's pull request is named after that fork's
branch, which is the name the next fork's is also under - two pull requests
from two forks' `master` were one worktree by the name, and `t` on the
second went into the first's without a word. Git knows whose the branch
is: `branch.<b>.remote` is the remote, or the fork's url, that gh set it to
track ([`branch_tracks`](@ref)); the item knows whose it wants (`head_repo`,
from the lanes). When both say and they differ, the copy is not this pull
request's. When either does not - a branch made by hand, a row from before
the field - the name is all there is, as before.

Shared by the worktree list, rule 1 and rule 2 of [`item_worktree`](@ref),
so no two of them disagree about whose a copy is - each place it was missing
from had its own wrong answer: the list filing the main checkout under their
number, rule 1 opening it for them without a word, rule 2 taking it for a
copy reused by them and asking on every press. `tr` is the repository's
[`Tracking`](@ref) when the caller has read it, and saves the two `git`
calls a lone `branch_tracks` costs.
"""
function carrier_refused(it::Item, w, tr = nothing)
    w.main && !author_ok(Set([AUTHOR_ME]), it) && return true
    (isempty(it.head_repo) || isempty(w.branch)) && return false
    tracks = tr === nothing ? branch_tracks(w.path, w.branch) : first(follows(tr, w.branch))
    !isempty(tracks) && lowercase(tracks) != lowercase(it.head_repo)
end

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
function branch_owner(it::Item, w, ix::BranchIndex, tr = nothing)
    (isempty(w.branch) || isempty(ix)) && return nothing
    o = branch_carrier(ix, it.repo, w, tr)
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
