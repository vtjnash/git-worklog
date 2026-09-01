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

"""Single-line row. TerminalMenus needs one line per entry, so pack the signals
into fixed columns and let colour carry the urgency."""
function row(it::Item; width = 110)
    flags = String[]
    it.new && push!(flags, "$(GRN)NEW$(R)")
    it.moved && push!(flags, "$(CYA)moved$(R)")
    it.track == "close" && push!(flags, "$(B)*$(R)")
    it.ci in ("FAILURE", "ERROR") && push!(flags, "$(RED)ci$(R)")
    it.unresolved > 0 && push!(flags, "$(YEL)$(it.unresolved)u$(R)")
    it.mergeable == "CONFLICTING" && push!(flags, "$(YEL)cf$(R)")
    tail = string(DIM, lpad(string(it.age, "d"), 6), R)
    f = isempty(flags) ? "" : " " * join(flags, " ")
    t = length(it.title) > width - 34 ? it.title[1:width-37] * "..." : it.title
    string(rpad(it.ref, 22), t, f, tail)
end

function detail(it::Item)
    println("\n", B, it.ref, "  ", it.title, R)
    println(DIM, it.url, R)
    bits = ["bucket=$(it.bucket)", "track=$(it.track)", "$(it.age)d"]
    isempty(it.ci) || push!(bits, "ci=$(lowercase(it.ci))")
    it.unresolved > 0 && push!(bits, "$(it.unresolved) unresolved")
    it.mergeable == "CONFLICTING" && push!(bits, "conflicts")
    it.snoozed && push!(bits, "snoozed")
    println(DIM, join(bits, " · "), R)
    isempty(it.note)  || println("\n  ", YEL, "note: ", it.note, R)
    isempty(it.agent) || println("  ", CYA, "agent: ", it.agent, R)
    print("\n  ", DIM, "loading thread...", R)
    local body, cs
    try
        body, cs = Events.thread(it.url; limit = 8)
    catch
        println("\r  ", RED, "could not load thread", R)
        return
    end
    print("\r\e[K")
    txt = strip(join(split(nz(get(body, "body", nothing), "")), " "))
    isempty(txt) || println("  ", first(txt, 400), length(txt) > 400 ? "..." : "")
    for c in cs
        t = strip(join(split(nz(get(c, "body", nothing), "")), " "))
        who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", nothing)
        println("\n  ", B, nz(who, "?"), R, DIM, "  ", first(c["created_at"], 16), R)
        println("    ", first(t, 500), length(t) > 500 ? "..." : "")
    end
    println()
end

ask(prompt) = (print(prompt); strip(readline()))

"Every mutation goes back through the same code the command surface uses."
function act(it::Item)
    opts = ["mark read", "snooze until it moves", "snooze until a date",
            "add a note", "queue for an agent", "set tracking level",
            "dismiss (retire from backlog)", "copy URL", "back"]
    c = request("action:", RadioMenu(opts; pagesize = 9))
    c == -1 && return
    if     c == 1; Events.mark_read([it.url])
    elseif c == 2; disarm(it.url); set_fields(it.url, ["snooze" => "on-change"])
    elseif c == 3; d = ask("date (YYYY-MM-DD): ")
                   isempty(d) || (disarm(it.url); set_fields(it.url, ["snooze" => String(d)]))
    elseif c == 4; n = ask("note: "); isempty(n) || set_fields(it.url, ["note" => String(n)])
    elseif c == 5; t = ask("agent task: "); isempty(t) || set_fields(it.url, ["agent_task" => String(t)])
    elseif c == 6
        lv = ["close", "normal", "loose", "background"]
        k = request("track:", RadioMenu(lv))
        k == -1 || (disarm(it.url); set_fields(it.url, ["track" => lv[k]]))
    elseif c == 7; disarm(it.url); set_fields(it.url, ["track" => "loose", "snooze" => "on-change"])
    elseif c == 8; println("\n  ", it.url, "\n")
    else return end
    c in (1, 2, 3, 4, 5, 6, 7) && println(DIM, "  done — refresh to re-bucket", R)
end

function browselane(items, title)
    isempty(items) && (println("\n  nothing in ", title, "\n"); return)
    while true
        rows = [row(it) for it in items]
        push!(rows, string(DIM, "← back", R))
        c = request("$(B)$title$(R) ($(length(items)))", RadioMenu(rows; pagesize = 20))
        (c == -1 || c > length(items)) && return
        detail(items[c])
        act(items[c])
    end
end

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
        browselane(by[ks[c]], LANES[findfirst(x -> x[1] == ks[c], LANES)][2])
    end
end
