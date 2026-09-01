"""
    Worklog

Interactive navigator for the work dashboard.

The Python side stays the engine: it fetches, buckets and owns `state.toml`.
This is the front end - it reads `facts.json` and dispatches every mutation back
through `wl.py`, so the comment-preserving TOML writer and the GitHub quirks it
took a while to find (lazily-computed `mergeable`, the `is:issue` qualifier,
the 1000-result search cap) live in exactly one place.
"""
module Worklog

using JSON3, TOML, Dates
using REPL.TerminalMenus

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const PY = "python3"

# Lanes in the order they matter, matching refresh.py's SECTIONS.
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

# Cmd(::Vector) takes no keywords; the dir has to be applied to a Cmd.
cmd(args...) = Cmd(Cmd(String[PY, args...]); dir=ROOT)
py(args...) = run(pipeline(cmd(args...); stdout=devnull, stderr=devnull))
pyout(args...) = read(cmd(args...), String)

struct Item
    url::String; ref::String; repo::String; number::Int; title::String
    bucket::String; track::String; note::String; agent::String
    backlog::Bool; ci::String; unresolved::Int; mergeable::String
    age::Int; new::Bool; moved::Bool; snoozed::Bool
end

nz(x, d="") = x === nothing || x === missing ? d : x

function loaditems()
    f = joinpath(ROOT, "facts.json")
    isfile(f) || error("no facts.json — run `python3 refresh.py` first")
    raw = JSON3.read(read(f, String))
    now = Dates.now(Dates.UTC)
    out = Item[]
    for (_, r) in raw.items
        act = something(nz(get(r, :head_at, nothing), nothing),
                        nz(get(r, :last_comment_at, nothing), nothing), r.updated)
        # Dates.Day of a Millisecond period throws unless it divides exactly,
        # so do the arithmetic in milliseconds.
        age = try
            Int(Dates.value(now - Dates.DateTime(act[1:19])) ÷ 86_400_000)
        catch; 0 end
        push!(out, Item(
            r.url, string(split(r.repo, '/')[end], '#', r.number),
            r.repo, r.number, r.title,
            nz(get(r, :bucket, ""), ""), nz(get(r, :track, "normal"), "normal"),
            nz(get(r, :note, ""), ""), nz(get(r, :agent_task, ""), ""),
            nz(get(r, :backlog, false), false),
            nz(get(r, :ci, ""), ""), something(nz(get(r, :unresolved, 0), 0), 0),
            nz(get(r, :mergeable, ""), ""),
            age, nz(get(r, :new, false), false), nz(get(r, :moved, false), false),
            nz(get(r, :snoozed, false), false)))
    end
    out
end

loadunread() = JSON3.read(pyout("wl.py", "unread"))

"""Single-line row. TerminalMenus needs one line per entry, so pack the
signals into fixed columns and let colour carry the urgency."""
function row(it::Item; width=110)
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
    th = try JSON3.read(pyout("wl.py", "thread", it.ref, "8")) catch e
        println("\r  ", RED, "could not load thread", R); return
    end
    print("\r\e[K")
    body = strip(replace(nz(th.body, ""), r"\s+" => " "))
    isempty(body) || println("  ", first(body, 400), length(body) > 400 ? "..." : "")
    for c in th.comments
        txt = strip(replace(nz(c.body, ""), r"\s+" => " "))
        println("\n  ", B, nz(c.who, "?"), R, DIM, "  ", c.at[1:16], R)
        println("    ", first(txt, 500), length(txt) > 500 ? "..." : "")
    end
    println()
end

ask(prompt) = (print(prompt); strip(readline()))

"""Every mutation goes back through wl.py; nothing is written from here."""
function act(it::Item)
    opts = ["mark read", "snooze until it moves", "snooze until a date",
            "add a note", "queue for an agent", "set tracking level",
            "dismiss (retire from backlog)", "copy URL", "back"]
    c = request("action:", RadioMenu(opts; pagesize=9))
    c == -1 && return
    if     c == 1; py("wl.py", "read", it.ref)
    elseif c == 2; py("wl.py", "snooze", it.ref, "on-change")
    elseif c == 3; d = ask("date (YYYY-MM-DD): "); isempty(d) || py("wl.py", "snooze", it.ref, d)
    elseif c == 4; n = ask("note: "); isempty(n) || py("wl.py", "note", it.ref, n)
    elseif c == 5; t = ask("agent task: "); isempty(t) || py("wl.py", "agent", it.ref, t)
    elseif c == 6
        lv = ["close", "normal", "loose", "background"]
        k = request("track:", RadioMenu(lv))
        k == -1 || py("wl.py", "track", it.ref, lv[k])
    elseif c == 7; py("wl.py", "dismiss", it.ref)
    elseif c == 8; println("\n  ", it.url, "\n")
    else return end
    c in (1,2,3,4,5,6,7) && println(DIM, "  done — refresh to re-bucket", R)
end

function browselane(items, title)
    isempty(items) && (println("\n  nothing in ", title, "\n"); return)
    while true
        rows = [row(it) for it in items]
        push!(rows, string(DIM, "← back", R))
        c = request("$(B)$title$(R) ($(length(items)))", RadioMenu(rows; pagesize=20))
        (c == -1 || c > length(items)) && return
        detail(items[c])
        act(items[c])
    end
end

function main(args=String[])
    if "--refresh" in args
        println("refreshing...")
        run(cmd("refresh.py"))
    end
    items = loaditems()
    by = Dict(k => filter(i -> i.bucket == k && !i.snoozed, items) for (k, _) in LANES)
    unread = loadunread()
    idx = Dict(i.url => i for i in items)
    by["unread"] = [get(idx, String(u.url),
                        Item(String(u.url), string(split(String(u.repo), '/')[end], '#', u.number),
                             String(u.repo), u.number, String(u.title), "unread", "normal",
                             "", "", true, "", 0, "", 0, false, false, false))
                    for u in unread]

    while true
        labels = String[]; keys = String[]
        for (k, name) in LANES
            n = length(get(by, k, Item[]))
            n == 0 && continue
            push!(keys, k)
            push!(labels, string(rpad(name, 20), DIM, n, R))
        end
        push!(labels, string(rpad("refresh", 20), DIM, "re-fetch and re-bucket", R))
        push!(labels, string(DIM, "quit", R))
        c = request("$(B)worklog$(R)  $(DIM)$(length(items)) items$(R)",
                    RadioMenu(labels; pagesize=16))
        c == -1 && return 0
        if c == length(labels); return 0
        elseif c == length(labels) - 1
            run(cmd("refresh.py")); return main(String[])
        end
        browselane(by[keys[c]], LANES[findfirst(x -> x[1] == keys[c], LANES)][2])
    end
end

end # module
