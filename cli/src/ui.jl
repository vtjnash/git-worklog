# `Item`: one row of the dashboard, and the three lists they are loaded from -
# `facts.json`, the branches you have adopted, and the urls you have imported.
# `ui()` at the foot assembles all three and opens the browser on them.
#
# Every mutation goes through the same functions the `wl <command>` surface
# calls, so the comment-preserving TOML writer and the GitHub quirks live in
# exactly one place rather than two.

"""One row of the dashboard.

Keyword-constructed: it carries enough fields now - the metadata pane wants
labels, milestone, review decision and the rest - that a positional call is a
place to silently transpose two strings.
"""
Base.@kwdef struct Item
    url::String
    ref::String
    repo::String
    number::Int
    title::String
    lane::String = ""      # which search claimed it first - `mine`, `review`,
                           # `assigned`, `imported`, `carried`; `notifications`
                           # for a thread that named you, `activity` for a row
                           # only the poll saw, `local` for an adopted branch.
                           # A fact about how it got here, and the one axis
                           # that used to be a derived word (`bucket`) instead
    track::String = "normal"
    note::String = ""
    ci::String = ""
    unresolved::Int = 0
    created::String = ""   # when GitHub says it was opened, and when it last
    updated::String = ""   # changed by anything at all - a label edit counts,
                           # which is what makes `act` below a different fact
                           # and not a better-named one
    moved_at::String = ""  # when this program last saw a change at this item's
                           # tracking level - what the seen axis is measured
                           # against. Empty on an item no refresh has seen,
                           # where `updated` is the only answer anybody has
    act::String = ""       # when this last moved: the head commit, else the last
                           # comment, else `updated`. Stored as the timestamp
                           # and not as an age in days, because an age is only
                           # true at the instant it was worked out and this
                           # object outlives that instant by hours.
    new::Bool = false
    is_pr::Bool = true
    author::String = ""
    assignees::Vector{String} = String[]   # who GitHub says is on the hook for
                           # it. With `author` this is the whole of what makes
                           # an item yours: a review request or a mention makes
                           # it *unread*, which is a different question
    labels::Vector{String} = String[]
    milestone::String = ""
    milestone_due::String = ""
    review_decision::String = ""
    state::String = ""     # OPEN | CLOSED | MERGED, as the lanes reported it.
                           # Empty for a facts.json written before it was asked
                           # for, and for a synthetic item, which has no such
                           # thing to be.
    branch::String = ""    # the pull request's head branch, from the lanes:
                           # what joins an item to a local checkout
    base::String = ""      # the branch it is to be merged into. With `head`
                           # it is what makes "what was pushed since I looked"
                           # answerable: the merge base against it is what
                           # separates their commits from the base's own
    head::String = ""      # and the sha at the end of it. `act`/`moved_at` say
                           # a push happened; this says what it pushed, which is
                           # the other end of the range-diff `p` takes against
                           # the head the read mark was made at. Empty on an
                           # issue, and on a synthetic row that never saw a lane
    secondlook::String = "" # why this wants looking at again, empty when it does
                            # not. Derived every refresh and never stored: it is
                            # a fact about silence, and silence keeps changing
    reply::String = ""     # why a reply is owed, empty when none is. The same
                           # shape, and a fact about the thread rather than
                           # about its state: a closed one can owe one too
    edits::String = ""     # why it wants edits - changes requested, threads,
                           # red CI, the label - empty when it does not
    ready::String = ""     # approved and green, empty otherwise
    review::String = ""    # why you owe a review: asked and not done, or they
                           # pushed after you did. Empty on your own
    merged_by::String = "" # who merged it, empty unless it is merged. The one
                           # thing that tells a merge you have to be told about
                           # from one you did yourself.
    draft::Bool = false
    deadline::String = ""
    blocked_on::Vector{String} = String[]
    why::String = ""
    fetched::String = ""   # when the bundle behind this row was asked for -
                           # GitHub's time, `fetched_at` on the row - and empty
                           # for a light row the poll or a thread made, which
                           # has no bundle at all. What `bundle_stale` reads.
end

nz(x, d = "") = x === nothing || x === missing ? d : x

"""How many days ago this item last moved, as of `at`.

Computed on demand rather than stored. The browser holds its items for the
length of a session, so an age worked out when they were loaded is an age from
whenever `wl` was started - right for about a day and then quietly wrong. Ask
at the point of use and the answer is always the one being shown.
"""
age(it::Item, at::DateTime) = something(days_since(it.act, at), 0)

"""One item from one record, the way `facts.json` writes them.

Its own function because a refresh is no longer the only source of a record: an
import fetches one mid-session and has to become the same `Item` a lane would
have made. Two mappings would drift, and the first thing to drift would be
`act`, which every age and every order is worked out from.
"""
function item_of(r)
        act = something(jget(r, :head_at), jget(r, :last_comment_at), r.updated)
        Item(
            url = r.url, ref = string(split(r.repo, '/')[end], '#', r.number),
            repo = r.repo, number = r.number, title = r.title,
            lane = nz(jget(r, :lane), ""), track = nz(jget(r, :track), "normal"),
            note = nz(jget(r, :note), ""),
            ci = nz(jget(r, :ci), ""), unresolved = nz(jget(r, :unresolved), 0),
            act = String(nz(act, "")),
            moved_at = String(nz(jget(r, :moved_at), "")),
            created = String(nz(jget(r, :created), "")),
            updated = String(nz(jget(r, :updated), "")),
            new = nz(jget(r, :new), false),
            is_pr = nz(jget(r, :type), "PullRequest") == "PullRequest",
            author = nz(jget(r, :author), ""),
            assignees = String[String(a) for a in jget(r, :assignees, ())],
            labels = String[String(l) for l in jget(r, :labels, ())],
            milestone = nz(jget(r, :milestone), ""),
            milestone_due = first(String(nz(jget(r, :milestone_due), "")), 10),
            review_decision = nz(jget(r, :review_decision), ""),
            state = nz(jget(r, :state), ""),
            branch = nz(jget(r, :branch), ""),
            head = nz(jget(r, :head_sha), ""),
            base = nz(jget(r, :base), ""),
            merged_by = nz(jget(r, :merged_by), ""),
            secondlook = nz(jget(r, :second_look), ""),
            reply = nz(jget(r, :reply), ""),
            edits = nz(jget(r, :edits), ""),
            ready = nz(jget(r, :ready), ""),
            review = nz(jget(r, :review), ""),
            draft = nz(jget(r, :draft), false),
            deadline = nz(jget(r, :deadline), ""),
            blocked_on = String[String(b) for b in jget(r, :blocked_on, ())],
            why = nz(jget(r, :why), ""),
            fetched = String(nz(jget(r, :fetched_at), "")))
end

# --- the bundle for the row under the cursor ---------------------------------
#
# The refresh asks GitHub about the open work whole and about everything else
# only when a clock says it moved - see `refresh` - so a row that is neither
# has the bundle it was last fetched with, and its tags are as old as that. The
# row you are *looking at* is the one place that is not good enough, and this
# is where it is made exact: the same by-url fetch the refresh makes, the same
# `derive!`, for the one row, once it has been on screen a second and its
# bundle is older than `CACHE_FRESH`. A light row - one the poll or a thread
# made, with no bundle at all - is promoted the same way, and keeps its lane
# and its reason.
#
# **Kept in the cache, not written into `fetched.json`.** The refresh writes
# `items` whole at the end of a minute of network, and a read-modify-write of
# the same part from here would race it in both directions - the refresh's
# rows lost under a stale copy, or this row lost under the refresh's. So the
# row goes into `cache/` under `bundle:<url>`, and everything that reads
# `items` - `loaditems`, the poll's extras - takes the cached row over the
# file's when it is the newer of the two, by `fetched_at`. The refresh does not
# read them: it compares its new row to the file's old one, and `moved_stamp`
# dates a movement by the event and not by who noticed it first, so the two
# agree on when things moved whichever saw them first.

bundle_key(url::AbstractString) = string("bundle:", url)

"The cached bundle for `url`, or `nothing`."
function bundle_of(url::AbstractString)
    hit = cache_get(bundle_key(url), CACHE_KEEP[])
    hit === nothing ? nothing : hit[1]
end

"""The row to show for `url`: the cached bundle when it is newer than `r` -
which may be `nothing`, for a url the file does not have - and `r` otherwise."""
function bundled(url::AbstractString, r)
    b = bundle_of(url)
    b === nothing && return r
    r === nothing && return b
    String(nz(jget(b, :fetched_at), "")) > String(nz(jget(r, :fetched_at), "")) ? b : r
end

"Seconds since the bundle behind `it` was fetched; `Inf` for a row with none."
function bundle_age(it::Item, at::DateTime = utcnow())
    t = ts(it.fetched)
    t === nothing ? Inf : max(0.0, Dates.value(at - t) / 1000)
end

"""
    fetch_bundle(it) -> Item, or nothing

Ask GitHub about this one row and derive it the way the refresh would. `nothing`
when the url answers with nothing - deleted, or a repository you cannot see -
and the row on screen stays as it was.

`old` is the newest of the file's row and the cached bundle, so that what is
carried - `their_head`, the comment clocks, the mark - is carried from the
last thing this program knew rather than from the last refresh. The reason a
thread gave is carried too, off the old row or the inbox, since GitHub does not
repeat it on the item.
"""
function fetch_bundle(it::Item)
    islocal(it) && return nothing
    # The stamp is from before the request, for the same reason the refresh's
    # is: a row is at least as old as its stamp says, never newer.
    at = Events.server_now()
    n = try
        fetch_url(it.url)
    catch e
        e isa FetchError || rethrow()
        return nothing
    end
    # Answered under another url - the repository or the issue has moved -
    # is the refresh's to sort out, which puts the row under its new name;
    # a bundle under the old name with the new url inside it would be two
    # items with one url.
    String(n.url) == it.url || return nothing
    cfg = config()
    file = fetched("items")
    old = bundled(it.url, file === nothing ? nothing : jget(file, Symbol(it.url)))
    r = normalize(n, it.lane, cfg["login"])
    reason = nz(jget(old, :reason), nothing)
    if reason === nothing
        e = get(Events.load_inbox()["items"], it.url, nothing)
        reason = e === nothing ? nothing : get(e, "reason", nothing)
    end
    truthy(reason) && (r["reason"] = String(reason);
                       r["why"] = get(Events.THREAD_WHY, String(reason), String(reason)))
    r["fetched_at"] = stamp(at)
    derive!(r, old, get(load_state(), it.url, Dict{String,Any}()), cfg, at)
    pop!(r, "slept", nothing)
    cache_put(bundle_key(it.url), r)
    item_of(JSON3.read(json_dumps(r)))
end

"""Every item in the last snapshot, as `Item`s.

`items` is a map keyed by url whose rows *also* carry `url`, which is the
same fact twice - deliberately, and left that way: the row is what `normalize`,
`apply_state!` and `snooze_active` are handed, and each of them asks it which
item it is. Threading the key through all of them to save a hundred bytes a row
would put the identity of an item somewhere other than in the item.
"""
function loaditems()
    its = fetched("items")
    its === nothing && die("nothing fetched yet — run `wl refresh` first")
    [item_of(bundled(String(u), r)) for (u, r) in pairs(its)]
end

"""The GitHub login from `config.toml`, read once.

Kept here rather than threaded down: the guard on adoption runs on a keystroke,
inside a view that has no other reason to be handed the whole config.
"""
const LOGIN = Ref("")
login() = isempty(LOGIN[]) ?
    (LOGIN[] = try
        String(get(TOML.parse(read(joinpath(ROOT, "config.toml"), String)), "login", ""))
    catch
        ""
    end) : LOGIN[]

# --- work with no pull request ----------------------------------------------
#
# `git br` and `gh pr status` each show half of what is going on and neither can
# hold a note about it. A local branch is not an item, and everything here is
# keyed by url - so an adopted branch is given a synthetic one, and notes,
# snoozes, the interaction clock, the tags and the filters all begin working
# on unlanded work without a line of code each.
#
# The key is `local:<repo>#<branch>` and *not* the worktree the plan first
# named. A branch with no worktree is exactly the case adoption exists for -
# work that has no place yet - so a key naming a place cannot address it, and a
# branch that is moved to another checkout would lose whatever was written about
# it. Repo and branch are what `branch_index` already joins on.

localurl(repo, branch) = string("local:", repo, "#", branch)
localref(repo, branch) = string(last(split(String(repo), '/')), "#", branch)
islocal(url::AbstractString) = startswith(url, "local:")
islocal(it::Item) = islocal(it.url)

"`(repo, branch)` from a local url, splitting at the first `#` - a repo has none."
function localparts(url::AbstractString)
    rest = String(url)[7:end]
    i = findfirst('#', rest)
    i === nothing ? (rest, "") : (rest[1:prevind(rest, i)], rest[nextind(rest, i):end])
end

"Urls of every branch that has been adopted, whether or not it still exists."
adopted_urls() = sort!([u for u in keys(field_map("adopted")) if islocal(u)])

"""One synthetic item for an adopted branch.

`b` is what the survey found for it, or `nothing` when the branch has since been
deleted - which is shown rather than dropped, because a branch that is gone is
still something you wrote a note on and still something to be told about.
"""
function local_item(url::AbstractString, b = nothing)
    repo, branch = localparts(url)
    p = repo_path(repo)
    landed = p !== nothing && merged_here(p, branch)
    Item(url = String(url), ref = localref(repo, branch), repo = String(repo),
         number = 0, is_pr = false, branch = String(branch),
         # The tip's subject, which is the only title unlanded work has. The
         # branch name is the fallback, and it is what a bare ref would show.
         title = b === nothing ? branch :
                 isempty(b.subject) ? branch : b.subject,
         lane = "local",
         track = nz(get_field(url, "track"), "normal"),
         note = nz(get_field(url, "note"), ""),
         deadline = nz(get_field(url, "deadline"), ""),
         act = b === nothing ? "" : b.at,
         # A branch whose commits are all in the base has landed, however it got
         # there. That is what makes it archivable - and, until the notice has
         # been read, what makes it news.
         state = landed ? "MERGED" : "",
         why = b === nothing ? "adopted; the branch is gone" :
               landed ? "adopted; merged into the base" :
               isempty(b.worktree) ? "adopted; no worktree" :
               string("adopted; ", basename(rstrip(b.worktree, '/'))))
end

"""Every adopted branch, as items.

The survey is asked for once and only when something has been adopted, so a
dashboard with none of this pays nothing for it.
"""
function local_items()
    urls = adopted_urls()
    isempty(urls) && return Item[]
    bs = try
        last(survey(; withdirty = false))
    catch
        Branch[]
    end
    byk = Dict((b.repo, b.name) => b for b in bs)
    [local_item(u, get(byk, localparts(u), nothing)) for u in urls]
end

# --- work in a repo nobody is watching --------------------------------------
#
# Everything else arrives through a lane, so an issue in an untracked repo that
# does not mention you cannot be followed at all. An import is the manual
# answer: a url written into `local.toml`, and the item fetched by it from then
# on. Being keyed by url is the whole of what it takes to compose with notes,
# snoozes, the clock, the tags and archive - the same as adoption above, and
# archive is its exit too.

"Urls that have been imported. Not the local ones - those are adoptions."
imported_urls() = sort!([u for u in keys(field_map("imported")) if !islocal(u)])

"""One item fetched by url, as a lane would have delivered it.

The road is the one `facts.json` takes - `normalize`, then the `local.toml`
fields, then the record `item_of` reads - because an imported item has to *be*
an ordinary item rather than resemble one. Mapping a node straight to an `Item`
here would be a second road, and the two would disagree first about the facts.
"""
function item_by_url(url::AbstractString, at::DateTime = utcnow())
    cfg = config()
    r = normalize(fetch_url(url), "imported", cfg["login"])
    apply_state!(r, get(load_state(), String(r["url"]), Dict{String,Any}()), cfg, at)
    item_of(JSON3.read(json_dumps(r)))
end

"""The inbox entry for an item already known, in the shape a poll writes.

Importing something the dashboard already carries is the common case rather than
the odd one - an old issue in a repo that is tracked anyway, a pull request of
yours somewhere that is not - so there has to be a way to say "unread again"
without a request and without inventing a second row for it.

`act` is what the item last moved at, which is what the unread lane compares
against a read stamp. Anything else would either hide it at once or never let it
leave.
"""
inbox_row(it::Item, at::DateTime = utcnow()) = OrderedDict{String,Any}(
    "url" => it.url, "repo" => it.repo, "number" => it.number, "title" => it.title,
    "is_pr" => it.is_pr, "state" => lowercase(isempty(it.state) ? "open" : it.state),
    "author" => it.author, "updated" => isempty(it.act) ? stamp(at) : it.act,
    "comments" => 0, "labels" => it.labels, "mine" => it.author == login())

"""And the other direction: the row a poll wrote, as an `Item` to select.

The activity poll watches whole repos, so most of what it finds is in no lane
and in no `fetched.json` - 628 rows of it today - and a row nobody can put the
cursor on is a row nobody can read, snooze or file. This is everything the poll
knows, which is less than a lane returns: no CI, no review state, no branch.
`activity` is the lane, which is what the poll is - not `unread`, which is
what the *seen* axis says about a row and would be the same word twice on two
different axes in the same pane - unless the row says otherwise: a thread the
notifications source saw carries `lane = "notifications"`, and its `reason` in
words as `why`, which is otherwise empty on a row no bucket rule has judged.

Beside `inbox_row` because they are one conversion in two directions, and the
pair of them being apart is how the fields drifted the first time.
"""
poll_item(u) = Item(
    url = String(u["url"]), repo = String(u["repo"]), number = u["number"],
    ref = string(split(String(u["repo"]), '/')[end], '#', u["number"]),
    title = String(u["title"]), lane = String(nz(get(u, "lane", nothing), "activity")),
    why = String(nz(get(u, "why", nothing), "")),
    author = String(nz(get(u, "author", nothing), "")),
    updated = String(nz(get(u, "updated", nothing), "")),
    act = String(nz(get(u, "updated", nothing), "")),
    # The poll has no fingerprint to compare, so what it saw *is* the movement.
    moved_at = String(nz(get(u, "updated", nothing), "")),
    labels = String[String(l) for l in get(u, "labels", ())],
    state = uppercase(String(nz(get(u, "state", nothing), "open"))),
    is_pr = get(u, "is_pr", true))

"""Imports that `facts.json` has not caught up with, fetched now.

An import has to be tracked from the moment it is made rather than from the next
refresh, or quitting before one would lose it - and it is still in `local.toml`,
so it would come back later as a row that appeared out of nowhere. One request
covers all of them, and none at all when there is nothing missing. A url that
answers with nothing is reported and skipped: a repository that went private
should cost its own row and not the dashboard.
"""
function imported_items(have::Set{String}, at::DateTime = utcnow())
    missing_ = [u for u in imported_urls() if !(u in have)]
    isempty(missing_) && return Item[]
    cfg = config()
    state = load_state()
    out = Item[]
    for n in try
                fetch_urls(missing_)
             catch e
                println(stderr, "  imported: ", first(sprint(showerror, e), 120))
                Any[]
             end
        r = normalize(n, "imported", cfg["login"])
        derive!(r, nothing, get(state, String(r["url"]), Dict{String,Any}()), cfg, at)
        push!(out, item_of(JSON3.read(json_dumps(r))))
    end
    out
end

"""Print one markdown body: links lifted to numbered footnotes, the rest
rendered by Term, wrapped to the terminal."""
function show_md(raw)
    txt = strip(replace(String(raw), "\r\n" => "\n"))
    isempty(txt) && return
    w = max(40, min(displaysize(stdout)[2] - 4, 100))
    body, urls = delink(txt)
    out = try
        plain_term(Term.apply_style(string(Term.TermMarkdown.parse_md(
            Markdown.parse(body); width = w))))
    catch e
        @warn "markdown render failed, showing raw text" exception = e maxlog = 1
        body
    end
    for l in split(out, "\n")
        println("  ", l)
    end
    for (i, u) in enumerate(urls)
        println("  ", THEME.dim, "[", i, "]", THEME.reset, " ", osc8(u, u))
    end
end

ask(prompt) = (print(prompt); strip(readline()))

"""Commit `data/` once a day, the first time it is picked up. Says what it did.

The directory is a git repository of its own precisely so that the record of
what you have done has a history - the interaction clock, the read cursors, the
notes and the archive are none of them re-fetchable - and nothing ever committed
to it, so that history was whatever had been committed by hand.

The first run of a day is the moment, and what says the day has turned is the
last commit rather than a stamp of our own: a file recording when this last ran
would be one more thing in `data/` to write and to keep true, and `git log -1`
already knows. Local dates on both sides, because "this morning" is a thing that
happens where the person is.

Before the refresh rather than after, so that a day's work is committed as a day
and not folded into the fetch that follows it.

Nothing here is allowed to fail loudly. This runs ahead of whatever was actually
asked for, and a directory that is not a repository, a `user.email` that was
never set, or a hook that refuses is not a reason to fail to open the dashboard.
"""
function commit_data!(at::DateTime = utcnow())
    d = datadir()
    isdir(joinpath(d, ".git")) || return ""
    try
        isempty(strip(git(d, "status", "--porcelain"))) && return ""
        # A repository with no commits yet has no last day, and today is the
        # first one. That is the case `git log` fails on rather than answers.
        last = try
            strip(git(d, "log", "-1", "--format=%cd", "--date=format-local:%Y-%m-%d"))
        catch
            ""
        end
        today = Dates.format(Dates.today(), "yyyy-mm-dd")
        last == today && return ""
        git(d, "add", "-A")
        names = [basename(l) for l in split(strip(git(d, "diff", "--cached",
                                                      "--name-only")), '\n')
                 if !isempty(l)]
        isempty(names) && return ""       # everything staged was ignored anyway
        what = length(names) > 4 ?
               string(join(first(names, 4), ", "), " and ", length(names) - 4, " more") :
               join(names, ", ")
        git(d, "commit", "-q", "-m", string("data ", today, ": ", what))
        string("committed ", length(names), " file", length(names) == 1 ? "" : "s",
               " in data/ - first run since ", isempty(last) ? "it was made" : last)
    catch e
        # Reported, not raised, and not silent either: a commit that has been
        # failing every morning for a week is worth one line a day.
        string("could not commit data/: ", first(sprint(showerror, e), 120))
    end
end

function ui(args = String[], at::DateTime = utcnow())
    # First, before anything writes: what is in there is yesterday's.
    let said = commit_data!(at)
        isempty(said) || println(said)
    end
    if "--refresh" in args
        println("refreshing...")
        # Its own operation, and its own start: a refresh takes half a minute
        # and the browser that follows must not be measured against the moment
        # before it began.
        refresh(String[])
        at = utcnow()
    end
    cfg = config()
    cc = get(cfg, "cache", Dict{String,Any}())
    # `detail_ttl_minutes` is the older name for the same number, from when it
    # covered the thread and the diff and nothing else. Before `loaditems`,
    # which reads the bundle cache under `CACHE_KEEP`.
    CACHE_FRESH[] = 60.0 * get(cc, "fresh_minutes", get(cc, "detail_ttl_minutes", 2))
    CACHE_KEEP[] = 86_400.0 * get(cc, "keep_days", 30)
    MERGE_FRESH[] = 60.0 * get(cc, "merge_minutes", 10)
    # Adopted branches are items too, and everything keyed by url works on them
    # the moment they are: notes, snoozes, the clock, the tags, the filters.
    items = vcat(loaditems(), local_items())
    # And anything imported since the last refresh, which is how an import is
    # tracked from the moment it is made rather than from the next one.
    append!(items, imported_items(Set(x.url for x in items), at))
    append!(items, inbox_items(Set(x.url for x in items),
                               Events.unread(cfg, cfg["login"], at; verbose = false)))
    # Straight into the browser: what the lane menu used to choose is now a tag.
    browse(items, "worklog")
    0
end

"""The rows the clocks know and the corpus does not, as items to select.

A watched repository's traffic, and the poll's own rows: what the inbox holds
that no lane and no by-url fetch has made a corpus row for. A light row for
each - `poll_item` - unless it was looked at and the bundle for it is cached
and is not older than the inbox's clock for it: nothing but the cursor ever
re-fetches such a bundle, and one from before the last comment would show the
row read for as long as the bundle is kept.

`rows` is the inbox: at launch what `Events.unread` just polled, and on a
reload under the browser what the file holds - a refresh landing is what
reloads, and it polled on the way - so a reload rebuilds the same list launch
did rather than keeping the old light rows by hand off a set the poll wrote
once.
"""
function inbox_items(have::Set{String}, rows = values(Events.load_inbox()["items"]))
    [let b = bundle_of(String(u["url"]))
         b === nothing ||
         String(nz(jget(b, :fetched_at), "")) < String(nz(get(u, "updated", nothing), "")) ?
             poll_item(u) : item_of(b)
     end for u in rows if !(String(u["url"]) in have)]
end
