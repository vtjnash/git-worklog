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
    moved_by::String = ""  # and the key of the wake table that moved it then -
                           # `their_head`, `review_at`, `ci_failed`... - or
                           # `new` on first sight. The last movement; the ones
                           # before it are read off the keys below against the
                           # done stamp (`moved_words`). Empty on a light row,
                           # and on a row from before the refresh kept it
    # The wake table's own keys, as the refresh left them: each is the time
    # somebody else last did the thing, or "" - `head_at` with `head_by`
    # saying whose the head is, since a push of yours after theirs dates the
    # head and is not news. What the pane lists as having moved since you
    # read, key by key, without a refresh to say so.
    head_at::String = ""
    head_by::String = ""
    their_comment_at::String = ""
    human_comment_at::String = ""
    review_at::String = ""
    review_requested_at::String = ""
    assigned_at::String = ""
    state_at::String = ""
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
    head_repo::String = "" # and the repository it is in - the project's, or
                           # a fork's - since the name joins by itself only
                           # when nobody else has a branch called that.
                           # Empty on a row from before the field existed
    base::String = ""      # the branch it is to be merged into. With `head`
                           # it is what makes "what was pushed since I looked"
                           # answerable: the merge base against it is what
                           # separates their commits from the base's own
    base_sha::String = ""  # and where that branch was at the refresh, so the
                           # merge base is a local question given both shas
    head::String = ""      # and the sha at the end of it. `act`/`moved_at` say
                           # a push happened; this says what it pushed, which is
                           # the other end of the range-diff `p` takes against
                           # the head the done mark was made at. Empty on an
                           # issue, and on a synthetic row that never saw a lane
    read_head::String = "" # the head as of the done mark or the floor, as the
                           # refresh saw it: what `p` measures from where `e`
                           # wrote no `done_head`; see `read_head`
    secondlook::String = "" # why this wants looking at again, empty when it does
                            # not. Derived every refresh and never stored: it is
                            # a fact about silence, and silence keeps changing
    reply::String = ""     # why a reply is owed, empty when none is. The same
                           # shape, and a fact about the thread rather than
                           # about its state: a closed one can owe one too
    mentioned::String = "" # how you were named on it, empty if you never were.
                           # A latch: set once, off a notification's reason or
                           # an `@you` in a thread you loaded, and kept after
                           # the reason has moved on - see `Events.mention_words`
    edits::String = ""     # why it wants edits - changes requested, threads,
                           # red CI, the label - empty when it does not
    ready::String = ""     # approved and green, empty otherwise
    review::String = ""    # why you owe a review: asked and not done, or they
                           # pushed after you did. Empty on your own
    merged_by::String = "" # who merged it, empty unless it is merged. The one
                           # thing that tells a merge you have to be told about
                           # from one you did yourself.
    draft::Bool = false
    web::String = ""       # where this is on github.com when `url` is not there:
                           # an adopted branch's `url` is its `local:` key, and
                           # this is its compare page, where the pull request
                           # gets opened. Empty for a row whose `url` is the link
    notice::String = ""    # the subject's type - `Release`, `Discussion`,
                           # `CheckSuite` - on a notice, a notification that
                           # is not an issue or pull request; empty on
                           # everything else. See `notice_item`
    reason::String = ""    # why GitHub notified: on a notice, which has no
                           # other way to say it. The corpus keeps its own
    fetched::String = ""   # when the bundle behind this row was asked for -
                           # GitHub's time, `fetched_at` on the row - and empty
                           # for a light row the poll or a thread made, which
                           # has no bundle at all. What `bundle_stale` reads.
end

"The last movement on record, off the row; see `moved_of` in `marks.jl`."
moved_of(it::Item) = moved_of(it.moved_at, it.updated)

"The day its source was named, or `nothing`; see `floor_of` in `marks.jl`."
floor_of(it::Item, sources::AbstractDict) = floor_of(it.lane, it.repo, sources)

"""What one item is done up to, off the file: its stamp, or where it has none the
floor of its source - the rule `seen_of` reads. `nothing` for an item that is
unread by what was said of it, an empty stamp, or by there being nothing to
say. Not `done_at`, which is the stamp alone: a plain `e` writes none where the
floor already answers (`folded`), so the stamp alone is missing on most of what
was ever read."""
function done_upto(it::Item)
    v = mark_at(it.url, "done")
    v === nothing ? floor_of(it, source_since()) : truthy(v) ? String(v) : nothing
end

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
            moved_by = String(nz(jget(r, :moved_by), "")),
            head_at = String(nz(jget(r, :head_at), "")),
            head_by = String(nz(jget(r, :head_by), "")),
            their_comment_at = String(nz(jget(r, :their_comment_at), "")),
            human_comment_at = String(nz(jget(r, :human_comment_at), "")),
            review_at = String(nz(jget(r, :review_at), "")),
            review_requested_at = String(nz(jget(r, :review_requested_at), "")),
            assigned_at = String(nz(jget(r, :assigned_at), "")),
            state_at = String(nz(jget(r, :state_at), "")),
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
            head_repo = nz(jget(r, :head_repo), ""),
            head = nz(jget(r, :head_sha), ""),
            read_head = nz(jget(r, :read_head), ""),
            base = nz(jget(r, :base), ""),
            base_sha = nz(jget(r, :base_sha), ""),
            merged_by = nz(jget(r, :merged_by), ""),
            secondlook = nz(jget(r, :second_look), ""),
            reply = nz(jget(r, :reply), ""),
            mentioned = nz(jget(r, :mentioned), ""),
            edits = nz(jget(r, :edits), ""),
            ready = nz(jget(r, :ready), ""),
            review = nz(jget(r, :review), ""),
            draft = nz(jget(r, :draft), false),
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
    ghitem(it) || return nothing
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
    truthy(reason) && (r["reason"] = String(reason))
    carry_mention!(r, get(Events.load_inbox()["items"], it.url, nothing))
    r["fetched_at"] = stamp(at)
    derive!(r, old, get(load_state(), it.url, Dict{String,Any}()), cfg, at)
    pop!(r, "slept", nothing); pop!(r, "woken", nothing)
    cache_put(bundle_key(it.url), r)
    item_of(JSON3.read(json_dumps(r)))
end

"""
    latch_mention!(url, why)

Write down that a thread read in the browser names you: `mentioned = why` on
the row in `fetched.json`'s `items`, on its inbox row, and on its cached
bundle - wherever the url has one, since those are the three rows `loaditems`
and `poll_item` read an `Item` off, and the refresh carries it from the first
two (`carry_mention!`, `mentioned_of`). Each is a re-read and one key written
where it is not set already,
the same read-modify-write `set_mark!` makes; once per item, since the caller
asks only while the item has none.

The one write the browser makes to `items`, against the rule in `fetch_bundle`
that it makes none. It can lose to a refresh that read the file before and
writes after, and the loss is harmless: the thread is scanned every time it
is shown, cached or not, so the next look writes it again.
"""
function latch_mention!(url::AbstractString, why::AbstractString)
    d = load_fetched()
    its = get(d, "items", nothing)
    if its !== nothing && haskey(its, Symbol(url)) &&
       isempty(String(nz(jget(its[Symbol(url)], :mentioned), "")))
        new = OrderedDict{String,Any}(String(k) => v for (k, v) in pairs(its))
        row = kept_row(its[Symbol(url)])
        row["mentioned"] = String(why)
        new[String(url)] = row
        d["items"] = new
        save_fetched(d)
    end
    ib = Events.load_inbox()
    e = get(ib["items"], String(url), nothing)
    if e !== nothing && isempty(String(nz(get(e, "mentioned", nothing), "")))
        e["mentioned"] = String(why)
        Events.save_inbox(ib)
    end
    b = bundle_of(url)
    if b !== nothing && isempty(String(nz(jget(b, :mentioned), "")))
        row = kept_row(b)
        row["mentioned"] = String(why)
        cache_put(bundle_key(url), row)
    end
    nothing
end

"""Every item in the last snapshot, as `Item`s.

`items` is a map keyed by url whose rows *also* carry `url`, which is the
same fact twice - deliberately, and left that way: the row is what `normalize`,
`apply_state!` and `snooze_active` are handed, and each of them asks it which
item it is. Threading the key through all of them to save a hundred bytes a row
would put the identity of an item somewhere other than in the item.
"""
function loaditems(its = fetched("items"))
    its === nothing && die("nothing fetched yet — run `wl refresh` first")
    [item_of(bundled(String(u), r)) for (u, r) in pairs(its)]
end

"""The corpus when one has been fetched, or `nothing`.

For the callers that have rows from somewhere else - the inbox, the checkouts,
an import - and can carry on without: `nothing fetched yet` is the answer for
a command that has nowhere else to look, not for a browser already open on a
list. And `nothing` rather than `Item[]`, because a corpus of no rows and no
corpus are not the same thing to a reload (`reload_data!`).
"""
function fetched_items()
    its = fetched("items")
    its === nothing ? nothing : loaditems(its)
end

"""The GitHub login from `data/config.toml`, read once.

Kept here rather than threaded down: the guard on adoption runs on a keystroke,
inside a view that has no other reason to be handed the whole config.
"""
const LOGIN = Ref("")
login() = isempty(LOGIN[]) ?
    (LOGIN[] = try
        String(get(config(), "login", ""))
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

"""Is this a GitHub issue or pull request - a url the by-url fetch, the
thread, the metadata and the prefetch can answer? Not an adopted branch,
whose `local:` url is a key, and not a notice, whose `notice:` url is one."""
ghitem(it::Item) = !(islocal(it) || isnotice(it))

"`(repo, branch)` from a local url, splitting at the first `#` - a repo has none."
function localparts(url::AbstractString)
    rest = String(url)[7:end]
    i = findfirst('#', rest)
    i === nothing ? (rest, "") : (rest[1:prevind(rest, i)], rest[nextind(rest, i):end])
end

"The link to follow or copy for `it`: its url, unless that is only a local key."
weblink(it::Item) = isempty(it.web) ? it.url : it.web

"""The compare page for `branch` on `repo`, which is where a pull request is
opened from - `?expand=1` is the form already open.

The base is the project's default branch, with its remote name taken off; the
head is named `owner:branch` when the branch was pushed to a fork, which is what
github.com wants across repositories, and bare when it went to the project or
has not been pushed at all - the page is a 404 until it is, but it is the right
page. Both facts are git's, so this costs two `git` runs per adopted branch,
which is a handful.
"""
function compare_link(path, repo::AbstractString, branch::AbstractString,
                      upstream::AbstractString)
    base = something(default_base(path), "master")
    rs = try remote_repos(path) catch; Dict{String,String}() end
    i = findfirst('/', base)
    (i !== nothing && haskey(rs, base[1:prevind(base, i)])) && (base = base[nextind(base, i):end])
    head = String(branch)
    j = findfirst('/', upstream)
    if j !== nothing
        r = get(rs, upstream[1:prevind(upstream, j)], "")
        (!isempty(r) && lowercase(r) != lowercase(repo)) &&
            (head = string(first(split(r, '/')), ":", upstream[nextind(upstream, j):end]))
    end
    string("https://github.com/", repo, "/compare/", base, "...", head, "?expand=1")
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
         act = b === nothing ? "" : b.at,
         # A branch whose commits are all in the base has landed, however it got
         # there. That is what makes it archivable - and, until the notice has
         # been read, what makes it news.
         state = landed ? "MERGED" : "",
         web = p === nothing ? "" :
               compare_link(p, repo, branch, b === nothing ? "" : b.upstream))
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

# --- notices ----------------------------------------------------------------
#
# A notification that is not an issue or pull request - a Release, a
# Discussion, a comment on a commit, a CI run, an alert, an invitation - has
# no bundle, no state, no wake table and no url the by-url fetch can answer,
# so it is neither a corpus row nor an inbox row: everything that reads those
# would ask GitHub about it. It is a block in `local.toml`, written whole by
# the poll (`Events.notice_row`), one per notice and gone when it is
# dismissed - the set that stays small, where the dismissed set would only
# grow. **Its presence is the seen bit**: unread while the block stands, and
# nothing is stamped.

isnotice(url::AbstractString) = startswith(url, "notice:")
isnotice(it::Item) = isnotice(it.url)

"""GitHub's name for a type as words: `RepositoryAdvisory` is `repository
advisory`. What a type nobody has named here yet is called, rather than one
run-together word."""
type_words(kind::AbstractString) =
    lowercase(replace(String(kind), r"(?<=[a-z0-9])(?=[A-Z])" => " "))

"""The subject's type in a word, as the list and the kind axis say it; a
type not named here in `type_words`."""
notice_word(kind::AbstractString) =
    kind == "Release" ? "release" : kind == "Discussion" ? "discussion" :
    kind == "Commit" ? "commit" : kind in ("CheckSuite", "WorkflowRun") ? "CI" :
    kind in ("RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread") ? "alert" :
    kind == "RepositoryAdvisory" ? "advisory" :
    kind == "RepositoryInvitation" ? "invite" : isempty(kind) ? "notice" : type_words(kind)

"""Every notice's block, `key -> field -> value`, parsed: a title is
somebody else's text, and has the escapes a line scan would leave in it. A
file that does not parse has none to show."""
function notice_blocks()
    isfile(localfile()) || return Dict{String,Dict{String,String}}()
    raw = try
        parse_local()
    catch
        return Dict{String,Dict{String,String}}()
    end
    Dict{String,Dict{String,String}}(String(k) => Dict{String,String}(
        String(f) => string(v) for (f, v) in b)
        for (k, b) in raw if isnotice(String(k)) && b isa AbstractDict)
end

"""The keys of every notice standing, off the headers alone: what the
browser drops a dismissed one from its list by, once per `refilter!`."""
notice_keys() = Set{String}(String(m[1]) for l in load_lines()
                            for m in (match(r"^\[\"(notice:[^\"]*)\"\]\s*$", strip(l)),)
                            if m !== nothing)

"""One notice as an `Item`. `url` is the key - a key, as `local:` is - and
`web` the link; `lane` is `notifications`, the time is the thread's
throughout, and there is no author and no number."""
function notice_item(key::AbstractString, b::AbstractDict)
    kind, repo = get(b, "type", ""), get(b, "repo", "")
    at = get(b, "at", "")
    reason = get(b, "reason", "")
    Item(url = String(key), repo = repo, number = 0, is_pr = false,
         ref = string(isempty(repo) ? "github" : last(split(repo, '/')), " ", notice_word(kind)),
         title = get(b, "title", ""), lane = "notifications", notice = kind,
         reason = reason, web = get(b, "web", ""),
         created = at, updated = at, moved_at = at, act = at,
         mentioned = Events.mention_words(Dict{String,Any}("reason" => reason, "notified" => at)))
end

"Every notice standing, as items, newest first."
notice_items() = sort!([notice_item(k, b) for (k, b) in notice_blocks()];
                       by = it -> (it.moved_at, it.url), rev = true)

"""Dismiss these notices: their blocks go, whole. Answers the blocks as
they stood, `key => [field => value]`, which is what `restore_notices!`
writes back - `z`'s, and nothing else's."""
function dismiss_notices!(keys)
    have = notice_blocks()
    gone = Pair{String,Vector{Pair{String,Any}}}[]
    for k in unique(String(k) for k in keys)
        b = get(have, k, nothing)
        b === nothing && continue
        push!(gone, k => Pair{String,Any}[f => v for (f, v) in b])
    end
    isempty(gone) || set_blocks!([k => Pair{String,Any}[f => nothing for (f, _) in fs]
                                  for (k, fs) in gone])
    gone
end

"Put dismissed notices back, as `dismiss_notices!` answered them."
restore_notices!(gone) = (isempty(gone) || set_blocks!(collect(gone)); nothing)

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
against a done stamp. Anything else would either hide it at once or never let it
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
notifications source saw carries `lane = "notifications"`.

Beside `inbox_row` because they are one conversion in two directions, and the
pair of them being apart is how the fields drifted the first time.
"""
poll_item(u) = Item(
    url = String(u["url"]), repo = String(u["repo"]), number = u["number"],
    ref = string(split(String(u["repo"]), '/')[end], '#', u["number"]),
    title = String(u["title"]), lane = String(nz(get(u, "lane", nothing), "activity")),
    author = String(nz(get(u, "author", nothing), "")),
    updated = String(nz(get(u, "updated", nothing), "")),
    act = String(nz(get(u, "updated", nothing), "")),
    # The poll has no fingerprint to compare, so what it saw *is* the movement.
    moved_at = String(nz(get(u, "updated", nothing), "")),
    # Yours, with no comment and no notification - GitHub notifies nobody of
    # their own acts - is the refresh's `opened` as near as the poll can say:
    # a request or an assignment since is the refresh's to find.
    moved_by = get(u, "author", nothing) == login() && get(u, "comments", 0) == 0 &&
               !truthy(get(u, "reason", nothing)) ? "opened" : "",
    labels = String[String(l) for l in get(u, "labels", ())],
    state = uppercase(String(nz(get(u, "state", nothing), "open"))),
    mentioned = String(nz(get(u, "mentioned", nothing), Events.mention_words(u))),
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
                # An exception, so a record: under the browser this ran from
                # `reload_data!`, and a line on stderr drew over the frame.
                logerror!(e, catch_backtrace(), "imported")
                Any[]
             end
        r = normalize(n, "imported", cfg["login"])
        derive!(r, nothing, get(state, String(r["url"]), Dict{String,Any}()), cfg, at)
        push!(out, item_of(JSON3.read(json_dumps(r))))
    end
    out
end

"""A GitHub table, with the alignment GitHub gives it: `Markdown`'s own
`github_table`, and then a column whose `---` has a colon at neither end is
`:l`. The stdlib reads such a column as `:r` (`default_align`), and its
`Table` has no way to say "none", so Term drew every plain column pushed to
the right, where GitHub draws it left. The row is read again from the source
the stock parser consumed - it is only dashes, colons and pipes - and left as
parsed if it does not split into the columns the table has."""
function gfm_table(stream::IO, md::Markdown.MD)
    start = position(stream)
    Markdown.github_table(stream, md) || return false
    stop = position(stream)
    t = md.content[end]
    seek(stream, start)
    rows = filter(l -> !isempty(strip(l)), split(String(read(stream, stop - start)), '\n'))
    seek(stream, stop)
    (t isa Markdown.Table && length(rows) >= 2) || return true
    cells = strip.(split(strip(strip(rows[2]), '|'), '|'))
    length(cells) == length(t.align) || return true
    for (j, c) in enumerate(cells)
        startswith(c, ':') || endswith(c, ':') || (t.align[j] = :l)
    end
    true
end

"""`Markdown`'s default flavor with `gfm_table` in place of its table parser:
what every comment body is parsed with. Copied, not built from a list, so a
Julia that adds a parser keeps it; one that renames `github_table` leaves this
the stock flavor."""
const GFM_FLAVOR = let c = deepcopy(Markdown.julia)
    replace!(f -> f === Markdown.github_table ? gfm_table : f, c.regular)
    replace!(f -> f === Markdown.github_table ? gfm_table : f, c.breaking)
    c
end

"A comment body, parsed as GitHub would: see `GFM_FLAVOR`."
parse_gfm(s::AbstractString) = Markdown.parse(String(s); flavor = GFM_FLAVOR)

"""Markdown to styled text at `width`, by Term: its markup consumed, and its
brace escape with it. `parse_md` escapes every `{` as `{{`, in prose and in
code, and only Term's own `print` collapses it; safe to do here only because
`apply_style` has already read the markup."""
term_md(md, width::Int) =
    replace(Term.apply_style(string(Term.TermMarkdown.parse_md(md; width))),
            "{{" => "{", "}}" => "}")

"""Print one markdown body: links lifted to numbered footnotes, the rest
rendered by Term, wrapped to the terminal."""
function show_md(raw)
    txt = strip(replace(String(raw), "\r\n" => "\n"))
    isempty(txt) && return
    w = max(40, min(displaysize(stdout)[2] - 4, 100))
    body, urls = delink(txt)
    out = try
        plain_term(term_md(for_term(parse_gfm(body)), w))
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
        refresh(String[]) == 0 && prefetch_behind()
        at = utcnow()
    end
    # From here on this process is the browser, and the browser reports
    # nothing: a line on stderr draws over the frame, and everything below -
    # the launch poll, a fetch's retries, an import - has the status row for
    # what just happened and `logerror!` for what must be kept.
    REPORT[] = Report(devnull)
    # The panes already running were handed links, not sockets; this login is
    # the newest, and what its links point at is what they should now see.
    try
        forwards!()
    catch e
        logerror!(e, catch_backtrace(), "forwards")
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
                               Events.poll(cfg, cfg["login"], at; verbose = false)))
    # And the notices the poll just wrote, beside the rows it came with.
    append!(items, notice_items())
    # Straight into the browser: what the lane menu used to choose is now a tag.
    browse(items, "worklog")
    0
end

"""Every unread row, as items, newest movement first: `seen_of` over the
corpus and the light rows, which is the one answer to "what is unread" -
`wl unread` prints it, `wl done all` marks it, and the browser's base list
is the same rows through the same `seen_of`, with the adopted branches and
the imports it fetched beside them. Less the filed ones, as the base list
is: a filed row that moved is unread in the `filed` box and nowhere else
(`show_ok`), and `wl done all` stamping it would read the one signal that
box keeps. Not the inbox listing: the inbox is a clock (`Events.poll`), and
a row it holds may be read. `rows` is the inbox, polled first by the
callers that want it fresh.

Neither `local_items` nor `imported_items`: the first walks the checkouts
and the second reaches GitHub, and an import that no refresh has caught up
with is in the inbox as a light row, said unread, until one has.
"""
function unread_items(at::DateTime, rows = values(Events.load_inbox()["items"]))
    items = corpus_items(rows)
    m = unread_marks(at)
    sort!([it for it in items if seen_of(it, m) === :unread && !filed_of(it, m)];
          by = it -> something(moved_of(it), ""), rev = true)
end

"The marks off `local.toml` as `wl unread` reads them, at `at`. (`Marks` is
the browser's, defined after this file; both callers are at run time.)"
unread_marks(at::DateTime) =
    Marks(done = load_done(), sources = source_since(), wake = wake_map(),
          archived = archived_map(), now = stamp(at), rang = rang_urls())

"The corpus, the light rows and the notices, as items: what the seen bit is asked over."
function corpus_items(rows = values(Events.load_inbox()["items"]))
    items = something(fetched_items(), Item[])
    append!(items, inbox_items(Set(x.url for x in items), rows))
    append!(items, notice_items())
end

"""
    consolidate!(at; dry_run) -> (; since, raised, dropped)

`wl done --consolidate`: raise every source's `since` to the newest point
the done stamps allow, and drop the stamps the floor then answers for - so
that `seen_of` answers the same for every row before and after, which is
the test, and `local.toml` says one line per source where it said one per
row. Over the corpus and the light rows:

`since` is the newest `moved_of` among the *read* rows - stamp at or past
the movement, and `seen_of` agreeing - that is below the oldest movement of
any unread row with *no* stamp, light rows included: such a row is unread
because it is past its floor, and raising the floor over it would read it.
A row unread against its own stamp bounds nothing and keeps it; `done = ""`
is a statement and does the same; a row with a `snooze` or an `archived`
mark is skipped, since a hand-typed span counts from the stamp (`wake_of`)
and the refresh reads either with no stamp as put away by hand and stamps
it at its own clock - over whatever moved since, which for a filed row is
the one thing the `filed` box is kept for (`held_by`); a row with no
movement on record - a synthetic one - has nothing to say, and nor has a
notice, whose seen bit is its block. Then every
`source:` block gets `max(since, since′)` - **together, and never lowered**,
so a row whose lane changes (a backlog issue that `assigned` claims) cannot
flip by falling under a different floor, and a source named later keeps its
later day - and `done` is dropped on every done row whose movement is at or
under its source's new floor. `done` only: `done_head` stays, since the head you last
saw is still the head you last saw and `p` reads it alone.

Explicit and dry-run first; the refresh can call it once it has been
watched. Answers what it did, or would do.
"""
function consolidate!(at::DateTime; dry_run::Bool = false,
                      rows = values(Events.load_inbox()["items"]))
    items = corpus_items(rows)
    raw = field_maps(("done", "snooze", "archived"))
    sources = source_since()
    m = Marks(done = load_done(), sources = sources, wake = wake_map(), now = stamp(at))
    oldest = nothing                    # of the stampless unread rows
    reads = Tuple{String,Item}[]        # the movement of every read, stamped row
    for it in items
        # A notice has no stamp for a floor to answer for, and as a stampless
        # unread row it would hold every `since` down while one stood.
        isnotice(it) && continue
        moved = moved_of(it)
        moved === nothing && continue
        r = get(raw, it.url, nothing)
        held_by(r) && continue
        stampraw = r === nothing ? nothing : get(r, "done", nothing)
        seen = seen_of(it, m)
        if stampraw === nothing
            seen === :unread && (oldest === nothing || moved < oldest) && (oldest = moved)
        elseif !isempty(stampraw) && seen === :done
            push!(reads, (moved, it))
        end
    end
    below = [mv for (mv, _) in reads if oldest === nothing || mv < oldest]
    since = isempty(below) ? nothing : maximum(below)
    raised = Dict{String,String}(l => since for (l, s) in sources
                                 if since !== nothing && since > s)
    after = merge(sources, raised)
    dropped = String[]
    for (mv, it) in reads
        f = floor_of(it, after)
        f !== nothing && mv <= f && push!(dropped, it.url)
    end
    if !dry_run
        isempty(raised) || set_blocks!([string("source:", l) => ["since" => s]
                                        for (l, s) in raised])
        isempty(dropped) || set_blocks!([u => ["done" => nothing] for u in dropped])
    end
    (; since, raised, dropped)
end

"""One item as `wl unread` prints it: what an outside reader can act on -
the url and the ref, what it is, whose, where it stands, when it last moved
and what has moved since it was read - `why`, the same words the pane's row
says, against the same marks (`moved_words`). The shape the inbox rows had,
with `moved_at` beside `updated`. A notice says its type, its reason and
its link as well, which it has no row elsewhere to say, and is `closed` as
it is on the state axis."""
item_json(it::Item, m) = OrderedDict{String,Any}(
    "url" => it.url, "ref" => it.ref, "repo" => it.repo, "number" => it.number,
    "title" => it.title, "is_pr" => it.is_pr,
    "state" => isnotice(it) ? "closed" : lowercase(isempty(it.state) ? "open" : it.state),
    "author" => it.author, "updated" => it.updated, "moved_at" => it.moved_at,
    "labels" => it.labels, "mine" => it.author == login(),
    "lane" => it.lane, "why" => moved_words(it, m),
    (isnotice(it) ? ["notice" => it.notice, "reason" => it.reason, "web" => it.web] : [])...)

"""The rows the clocks know and the corpus does not, as items to select.

A watched repository's traffic, and the poll's own rows: what the inbox holds
that no lane and no by-url fetch has made a corpus row for. A light row for
each - `poll_item` - unless it was looked at and the bundle for it is cached
and is not older than the inbox's clock for it: nothing but the cursor ever
re-fetches such a bundle, and one from before the last comment would show the
row read for as long as the bundle is kept.

`rows` is the inbox: at launch what `Events.poll` just polled, and on a
reload under the browser what the file holds - a refresh landing is what
reloads, and it polled on the way - so a reload rebuilds the same list launch
did rather than keeping the old light rows by hand off a set the poll wrote
once.
"""
function inbox_items(have::Set{String}, rows = values(Events.load_inbox()["items"]))
    [let b = bundle_of(String(u["url"]))
         b === nothing || before_inbox(b, u) ? poll_item(u) : item_of(b)
     end for u in rows if !(String(u["url"]) in have)]
end

"""Is the bundle `b` from before the inbox's clock for its row `u` - fetched
before the newest thing the poll saw? Then the inbox row is the newer of the
two, and the one a mark stamps by (`mark_done_moved`) as well as the one
shown (`inbox_items`), or `wl done all` would stamp under what `wl unread`
listed against."""
before_inbox(b, u) =
    String(nz(jget(b, :fetched_at), "")) < String(nz(get(u, "updated", nothing), ""))
