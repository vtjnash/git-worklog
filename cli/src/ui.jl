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
    age::Int = 0
    new::Bool = false
    moved::Bool = false
    snoozed::Bool = false
    is_pr::Bool = true
    author::String = ""
    labels::Vector{String} = String[]
    milestone::String = ""
    milestone_due::String = ""
    review_decision::String = ""
    branch::String = ""    # the pull request's head branch, from the lanes:
                           # what joins an item to a local checkout
    draft::Bool = false
    deadline::String = ""
    blocked_on::Vector{String} = String[]
    why::String = ""
end

nz(x, d = "") = x === nothing || x === missing ? d : x

function loaditems()
    f = joinpath(ROOT, "facts.json")
    isfile(f) || die("no facts.json — run `wl refresh` first")
    raw = JSON3.read(read(f, String))
    out = Item[]
    for (_, r) in raw.items
        act = something(jget(r, :head_at), jget(r, :last_comment_at), r.updated)
        age = something(days_since(act), 0)
        push!(out, Item(
            url = r.url, ref = string(split(r.repo, '/')[end], '#', r.number),
            repo = r.repo, number = r.number, title = r.title,
            bucket = nz(jget(r, :bucket), ""), track = nz(jget(r, :track), "normal"),
            note = nz(jget(r, :note), ""),
            backlog = nz(jget(r, :backlog), false),
            ci = nz(jget(r, :ci), ""), unresolved = nz(jget(r, :unresolved), 0),
            mergeable = nz(jget(r, :mergeable), ""),
            age = age, new = nz(jget(r, :new), false), moved = nz(jget(r, :moved), false),
            snoozed = nz(jget(r, :snoozed), false),
            is_pr = nz(jget(r, :type), "PullRequest") == "PullRequest",
            author = nz(jget(r, :author), ""),
            labels = String[String(l) for l in jget(r, :labels, ())],
            milestone = nz(jget(r, :milestone), ""),
            milestone_due = first(String(nz(jget(r, :milestone_due), "")), 10),
            review_decision = nz(jget(r, :review_decision), ""),
            branch = nz(jget(r, :branch), ""),
            draft = nz(jget(r, :draft), false),
            deadline = nz(jget(r, :deadline), ""),
            blocked_on = String[String(b) for b in jget(r, :blocked_on, ())],
            why = nz(jget(r, :why), "")))
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

function ui(args = String[])
    if "--refresh" in args
        println("refreshing...")
        refresh(String[])
    end
    items = loaditems()
    cfg = config()
    DETAIL_TTL[] = 60.0 * get(get(cfg, "cache", Dict{String,Any}()),
                              "detail_ttl_minutes", 10)
    unread = Events.unread(cfg, cfg["login"]; verbose = false)
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
