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
    ("needs-agents",   "Needs agents"),
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

struct Item
    url::String; ref::String; repo::String; number::Int; title::String
    bucket::String; track::String; note::String; agent::String
    backlog::Bool; ci::String; unresolved::Int; mergeable::String
    age::Int; new::Bool; moved::Bool; snoozed::Bool
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
            r.url, string(split(r.repo, '/')[end], '#', r.number),
            r.repo, r.number, r.title,
            nz(jget(r, :bucket), ""), nz(jget(r, :track), "normal"),
            nz(jget(r, :note), ""), nz(jget(r, :agent_task), ""),
            nz(jget(r, :backlog), false),
            nz(jget(r, :ci), ""), nz(jget(r, :unresolved), 0),
            nz(jget(r, :mergeable), ""),
            age, nz(jget(r, :new), false), nz(jget(r, :moved), false),
            nz(jget(r, :snoozed), false)))
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
    extra = [Item(String(u["url"]), string(split(String(u["repo"]), '/')[end], '#', u["number"]),
                  String(u["repo"]), u["number"], String(u["title"]), "unread", "normal",
                  "", "", true, "", 0, "", 0, false, false, false)
             for u in unread if !haskey(idx, String(u["url"]))]
    urls = Set{String}(String(u["url"]) for u in unread)
    # Straight into the browser: what the lane menu used to choose is now a tag.
    browse(vcat(items, extra), "worklog", urls)
    0
end
