# `Item`: one row of the dashboard, and the three lists they are loaded from -
# `facts.json`, the branches you have adopted, and the urls you have imported.
# `ui()` at the foot assembles all three and opens the browser on them.
#
# Every mutation goes through the same functions the `wl <command>` surface
# calls, so the comment-preserving TOML writer and the GitHub quirks live in
# exactly one place rather than two.

const DIM = "\e[2m"; const B = "\e[1m"; const R = "\e[0m"
const RED = "\e[31m"; const YEL = "\e[33m"; const GRN = "\e[32m"; const CYA = "\e[36m"

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
    bucket::String = ""
    track::String = "normal"
    note::String = ""
    backlog::Bool = false
    ci::String = ""
    unresolved::Int = 0
    mergeable::String = ""
    act::String = ""       # when this last moved: the head commit, else the last
                           # comment, else `updated`. Stored as the timestamp
                           # and not as an age in days, because an age is only
                           # true at the instant it was worked out and this
                           # object outlives that instant by hours.
    new::Bool = false
    moved::Bool = false
    snoozed::Bool = false
    snooze_why::String = ""   # what the snooze is waiting for, as the refresh
                              # that decided it put it: "until it moves",
                              # "for 2w, 9d left", "until 2026-09-15". Carried
                              # rather than re-derived, because deriving it here
                              # would be a second opinion about whether the item
                              # is still asleep - and the refresh's is the only
                              # one that may write `snooze.json`
    is_pr::Bool = true
    author::String = ""
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
    secondlook::String = "" # why this wants looking at again, empty when it does
                            # not. Derived every refresh and never stored: it is
                            # a fact about silence, and silence keeps changing
    merged_by::String = "" # who merged it, empty unless it is merged. The one
                           # thing that tells a merge you have to be told about
                           # from one you did yourself.
    draft::Bool = false
    deadline::String = ""
    blocked_on::Vector{String} = String[]
    why::String = ""
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
            bucket = nz(jget(r, :bucket), ""), track = nz(jget(r, :track), "normal"),
            note = nz(jget(r, :note), ""),
            backlog = nz(jget(r, :backlog), false),
            ci = nz(jget(r, :ci), ""), unresolved = nz(jget(r, :unresolved), 0),
            mergeable = nz(jget(r, :mergeable), ""),
            act = String(nz(act, "")),
            new = nz(jget(r, :new), false), moved = nz(jget(r, :moved), false),
            snoozed = nz(jget(r, :snoozed), false),
            snooze_why = String(nz(jget(r, :snooze_why), "")),
            is_pr = nz(jget(r, :type), "PullRequest") == "PullRequest",
            author = nz(jget(r, :author), ""),
            labels = String[String(l) for l in jget(r, :labels, ())],
            milestone = nz(jget(r, :milestone), ""),
            milestone_due = first(String(nz(jget(r, :milestone_due), "")), 10),
            review_decision = nz(jget(r, :review_decision), ""),
            state = nz(jget(r, :state), ""),
            branch = nz(jget(r, :branch), ""),
            merged_by = nz(jget(r, :merged_by), ""),
            secondlook = nz(jget(r, :second_look), ""),
            draft = nz(jget(r, :draft), false),
            deadline = nz(jget(r, :deadline), ""),
            blocked_on = String[String(b) for b in jget(r, :blocked_on, ())],
            why = nz(jget(r, :why), ""))
end

function loaditems()
    f = datapath("facts.json")
    isfile(f) || die("no facts.json — run `wl refresh` first")
    raw = JSON3.read(read(f, String))
    [item_of(r) for (_, r) in raw.items]
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
# snoozes, the interaction clock, the buckets and the filters all begin working
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
         bucket = nz(get_field(url, "bucket"), "local"),
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
# answer: a url written into `state.toml`, and the item fetched by it from then
# on. Being keyed by url is the whole of what it takes to compose with notes,
# snoozes, the clock, the buckets and archive - the same as adoption above, and
# archive is its exit too.

"Urls that have been imported. Not the local ones - those are adoptions."
imported_urls() = sort!([u for u in keys(field_map("imported")) if !islocal(u)])

"""One item fetched by url, as a lane would have delivered it.

The road is the one `facts.json` takes - `normalize`, then the `state.toml`
fields, then the record `item_of` reads - because an imported item has to *be*
an ordinary item rather than resemble one. Mapping a node straight to an `Item`
here would be a second road, and the two would disagree first about the bucket.
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

"""Imports that `facts.json` has not caught up with, fetched now.

An import has to be tracked from the moment it is made rather than from the next
refresh, or quitting before one would lose it - and it is still in `state.toml`,
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
        apply_state!(r, get(state, String(r["url"]), Dict{String,Any}()), cfg, at)
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
        Term.apply_style(string(Term.TermMarkdown.parse_md(
            Markdown.parse(body); width = w)))
    catch e
        @warn "markdown render failed, showing raw text" exception = e maxlog = 1
        body
    end
    for l in split(out, "\n")
        println("  ", l)
    end
    for (i, u) in enumerate(urls)
        println("  ", DIM, "[", i, "]", R, " ", osc8(u, u))
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
    # Adopted branches are items too, and everything keyed by url works on them
    # the moment they are: notes, snoozes, the clock, the buckets, the filters.
    items = vcat(loaditems(), local_items())
    # And anything imported since the last refresh, which is how an import is
    # tracked from the moment it is made rather than from the next one.
    append!(items, imported_items(Set(x.url for x in items), at))
    cfg = config()
    DETAIL_TTL[] = 60.0 * get(get(cfg, "cache", Dict{String,Any}()),
                              "detail_ttl_minutes", 10)
    unread = Events.unread(cfg, cfg["login"], at; verbose = false)
    idx = Dict(i.url => i for i in items)
    # Unread threads that are not otherwise tracked still need a row to select.
    extra = [Item(url = String(u["url"]), repo = String(u["repo"]), number = u["number"],
                  ref = string(split(String(u["repo"]), '/')[end], '#', u["number"]),
                  title = String(u["title"]), bucket = "unread", backlog = true,
                  author = String(nz(get(u, "author", nothing), "")),
                  labels = String[String(l) for l in get(u, "labels", ())],
                  is_pr = get(u, "is_pr", true))
             for u in unread if !haskey(idx, String(u["url"]))]
    urls = Set{String}(String(u["url"]) for u in unread)
    # Straight into the browser: what the lane menu used to choose is now a tag.
    browse(vcat(items, extra), "worklog", urls)
    0
end
