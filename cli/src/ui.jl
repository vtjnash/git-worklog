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
    by = Dict(k => filter(i -> i.bucket == k && !i.snoozed, items) for (k, _) in LANES)
    cfg = config()
    unread = Events.unread(cfg, cfg["login"]; verbose = false)
    idx = Dict(i.url => i for i in items)
    by["unread"] = [get(idx, u["url"],
                        Item(u["url"], string(split(u["repo"], '/')[end], '#', u["number"]),
                             u["repo"], u["number"], u["title"], "unread", "normal",
                             "", "", true, "", 0, "", 0, false, false, false))
                    for u in unread]

    while true
        labels = String[]; ks = String[]
        for (k, name) in LANES
            n = length(get(by, k, Item[]))
            n == 0 && continue
            push!(ks, k)
            push!(labels, string(rpad(name, 20), DIM, n, R))
        end
        push!(labels, string(rpad("refresh", 20), DIM, "re-fetch and re-bucket", R))
        push!(labels, string(DIM, "quit", R))
        c = request("$(B)worklog$(R)  $(DIM)$(length(items)) items$(R)",
                    RadioMenu(labels; pagesize = 16))
        c == -1 && return 0
        if c == length(labels)
            return 0
        elseif c == length(labels) - 1
            refresh(String[])
            return ui(String[])
        end
        browse(by[ks[c]], LANES[findfirst(x -> x[1] == ks[c], LANES)][2])
    end
end
