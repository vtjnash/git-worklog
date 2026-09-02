# Interactive navigator over the same data.
#
# Every mutation goes through the same functions the `wl <command>` surface
# calls, so the comment-preserving TOML writer and the GitHub quirks live in
# exactly one place rather than two.

# Lanes in the order they matter, matching SECTIONS in refresh.jl.
const LANES = [
    ("unread",         "Unread"),
    ("needs-reply",    "Needs a reply"),
    ("needs-edits",    "Needs edits"),
    ("needs-stacking", "Needs stacking"),
    ("needs-review",   "Needs review"),
    ("needs-merge",    "Ready to merge"),
    ("needs-nudge",    "Needs a nudge"),
    ("waiting",        "Waiting on others"),
    ("issue",          "Assigned issues"),
    ("draft",          "Drafts"),
    ("stale",          "Stale — decide"),
]

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

function loaditems()
    f = datapath("facts.json")
    isfile(f) || die("no facts.json — run `wl refresh` first")
    raw = JSON3.read(read(f, String))
    out = Item[]
    for (_, r) in raw.items
        act = something(jget(r, :head_at), jget(r, :last_comment_at), r.updated)
        push!(out, Item(
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
            is_pr = nz(jget(r, :type), "PullRequest") == "PullRequest",
            author = nz(jget(r, :author), ""),
            labels = String[String(l) for l in jget(r, :labels, ())],
            milestone = nz(jget(r, :milestone), ""),
            milestone_due = first(String(nz(jget(r, :milestone_due), "")), 10),
            review_decision = nz(jget(r, :review_decision), ""),
            state = nz(jget(r, :state), ""),
            branch = nz(jget(r, :branch), ""),
            draft = nz(jget(r, :draft), false),
            deadline = nz(jget(r, :deadline), ""),
            blocked_on = String[String(b) for b in jget(r, :blocked_on, ())],
            why = nz(jget(r, :why), "")))
    end
    out
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

function ui(args = String[], at::DateTime = utcnow())
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
