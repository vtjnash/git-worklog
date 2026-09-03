# The command surface. One entry point, `wl`, which is the interactive
# navigator when given nothing and the state editor when given a command.

const USAGE = """
Work dashboard.

  wl                                      the interactive navigator
  wl --refresh                            refresh first, then the navigator

  wl refresh [--firehose]                 re-fetch, re-bucket, re-render
  wl import  <url> [<url>...]             follow items no lane returns, unread
  wl unread                               JSON, for the navigator
  wl unread  julia#62891                  mark a thread unread again
  wl thread  julia#62891 [n]              JSON of a thread's recent comments
  wl read    julia#62891                  mark a thread seen (or: read all)
  wl show    julia#62891                  state + the thread's recent comments
  wl next    [n]                          pull the next untagged backlog items
  wl watching                             repos you watch, and which are tracked
  wl track   julia#62452 close            close | normal | loose | background
  wl dismiss julia#62452                  retire from the backlog until it moves
  wl snooze  julia#62452 on-change        or a date, or "off"
  wl note    julia#62452 "rebase after #62396 lands"
  wl archive julia#62452 2026-09-02        or: wl adopted local:o/r#branch <date>
  wl deadline julia#62452 2026-09-30
  wl bucket  julia#62452 needs-review
  wl blocked julia#62452 JuliaLang/julia#62396
  wl clear   julia#62452

Anywhere a ref is taken, `-` means "read them from stdin, one per line" - so a
batch is one process rather than a loop of them:

  printf '%s\n' julia#62452 julia#62396 | wl snooze - 3d
  wl unread julia#62841 | wl import -
"""

config() = TOML.parse(read(joinpath(ROOT, "config.toml"), String))

"""Lines of stdin, blanks and `#` comments dropped, first word of each.

The raw half of `refs`: a url needs no resolving, and requiring one to be in
`facts.json` first would refuse exactly the items `import` exists for.

The stream is an argument for the same reason the clock is one: a test drives it
from an `IOBuffer`, the way `readevent` is driven, rather than by taking the
process's stdin away from the runner.
"""
function stdin_lines(io::IO = stdin)
    out = String[]
    for l in eachline(io)
        t = strip(l)
        (isempty(t) || startswith(t, "#")) && continue
        push!(out, String(first(split(t))))
    end
    out
end

"""The refs a command was given: the argument, or every line of stdin for `-`.

One mechanism for every command that takes a ref, and no new flag. `-` is the
usual spelling for it, a variadic ref list could not be told apart from the
value argument that follows one, and an agent handing over a batch should not
have to start a process per item.

Blank lines and `#` comments are skipped, so the output of something that
annotates its list can be piped in unedited.
"""
function refs(arg::AbstractString, io::IO = stdin)
    arg == "-" || return [resolve(arg)]
    out = [resolve(x) for x in stdin_lines(io)]
    isempty(out) && die("nothing on stdin to act on")
    out
end

"""Follow items that no lane returns, and land them unread.

The bulk half of the browser's `i`. One batched request for the lot rather than
one each, `imported` written per url so a refresh keeps them, and an inbox entry
per item so they arrive in the unread lane - which is the difference from `i`,
where you are already looking at the thing.

A url that resolves to nothing is reported and skipped rather than written: a
line in `state.toml` that fetches nothing on every refresh forever is worse than
a typo that says so.
"""
function import_urls(urls::Vector{String}, at::DateTime)
    want = String[]
    for u in urls
        c = item_url(u)
        c === nothing ? println(stderr, "not an issue or pull request url: ", u) :
                        push!(want, c)
    end
    isempty(want) && return 1
    nodes = fetch_urls(want)
    got = Dict(String(n.url) => n for n in nodes)
    rows = OrderedDict{String,Any}[]
    for u in want
        n = get(got, u, nothing)
        if n === nothing
            println(stderr, "nothing there: ", u)
            continue
        end
        set_fields(u, ["imported" => string(Date(at))], at)
        who = jget(jget(n, :author), :login)
        push!(rows, OrderedDict{String,Any}(
            "url" => u, "repo" => n.repository.nameWithOwner, "number" => n.number,
            "title" => n.title,
            "is_pr" => jget(n, :__typename, "PullRequest") == "PullRequest",
            "state" => lowercase(String(nz(jget(n, :state), "open"))),
            "author" => who, "updated" => n.updatedAt, "comments" => 0,
            "labels" => String[l.name for l in n.labels.nodes],
            "mine" => who == login()))
        println("imported ", u)
    end
    isempty(rows) && return 1
    Events.inbox_add!(rows)
    @printf(stderr, "%d imported, unread. `wl refresh` folds them into the dashboard.\n",
            length(rows))
    0
end

function dispatch(args::Vector{String}, at::DateTime = utcnow())
    (isempty(args) || args == ["--refresh"]) && return ui(args, at)
    cmd = args[1]
    cmd in ("-h", "--help", "help") && (println(USAGE); return 0)
    cmd == "refresh" && return refresh(args[2:end], at)
    cmd == "next" && return next_batch(length(args) > 1 ? parse(Int, args[2]) : 10)
    if cmd == "import"
        length(args) > 1 || die(USAGE)
        return import_urls(args[2] == "-" ? stdin_lines() : args[2:end], at)
    end
    if cmd == "unread"
        # With a ref it is the inverse of `read`; bare it is still the dump the
        # navigator reads.
        if length(args) > 1
            for u in refs(args[2])
                println(Events.mark_unread([u]) == 0 ? "was not marked read $u" :
                        "marked unread $u")
            end
            return 0
        end
        cfg = config()
        print(json_dumps(Events.unread(cfg, cfg["login"], at; verbose = false)))
        return 0
    end
    if cmd == "watching"
        cfg = config()
        listed = get(get(cfg, "events", Dict{String,Any}()), "repos", String[])
        explicit, owners, _ = Events.event_sources(listed)
        subs = Events.subscriptions()
        covers(r) = r in explicit ? "listed" :
                    first(split(r, '/')) in owners ? "covered" : ""
        untracked = [r for r in subs if isempty(covers(r))]
        for r in subs
            c = covers(r)
            println(isempty(c) ? "  " : "# ", r, isempty(c) ? "" : "   ($c)")
        end
        @printf(stderr, "\n%d watched, %d already tracked, %d not.\n",
                length(subs), length(subs) - length(untracked), length(untracked))
        isempty(untracked) ||
            println(stderr, "The unprefixed lines are the ones to paste into ",
                    "[events].repos in config.toml.")
        return 0
    end
    if cmd == "thread"
        length(args) > 1 || die(USAGE)
        body, cs = Events.thread(resolve(args[2]);
                                 limit = length(args) > 2 ? parse(Int, args[3]) : 12)
        print(json_dumps([
            "title" => body["title"],
            "body" => something(get(body, "body", nothing), ""),
            "state" => body["state"],
            "user" => get(something(get(body, "user", nothing), Dict{String,Any}()), "login", nothing),
            "comments" => [["at" => c["created_at"],
                            "who" => get(something(get(c, "user", nothing), Dict{String,Any}()), "login", nothing),
                            "body" => something(get(c, "body", nothing), "")] for c in cs]]))
        return 0
    end
    if cmd == "read"
        arg = length(args) > 1 ? args[2] : "all"
        if arg == "all"
            cfg = config()
            urls = [e["url"] for e in Events.unread(cfg, cfg["login"], at; verbose = false)]
            println("marked $(Events.mark_read(urls, at)) threads read")
        else
            for u in refs(arg)
                Events.mark_read([u], at)
                println("marked read $u")
            end
        end
        return 0
    end
    length(args) > 1 || die(USAGE)
    urls = refs(args[2])
    url = first(urls)
    cmd = get(ALIAS, cmd, cmd)

    if cmd == "show"
        st = load_state()
        println(url)
        haskey(st, url) && println(json_dumps(st[url]; indent = 1, sortkeys = true))
        # Bodies are never stored; this is a live read of the thread, which is
        # the part the notification emails were carrying.
        body, cs = try
            Events.thread(url)
        catch e
            die("could not fetch thread: " * sprint(showerror, e))
        end
        title = body["title"]
        print("\n$title\n", "-"^min(length(title), 78), "\n\n")
        for c in cs
            who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", nothing)
            print("  ", replace(first(c["created_at"], 16), "T" => " "), "  ", pyrepr(who), "\n")
            # Rendered, not cut at 600 characters: the same markdown path the
            # browser uses, with links lifted to footnotes.
            show_md(something(get(c, "body", nothing), ""))
            println()
        end
        return 0
    end
    if cmd == "dismiss"
        # Retire a backlog item: stop caring about churn, but do not go blind to
        # it. Loose tracking plus an on-change snooze means it comes back only if
        # something that actually matters happens to it.
        for u in urls
            disarm(u)
            set_fields(u, ["track" => "loose", "snooze" => "on-change"])
            println("dismissed $u (returns only on a review, reply or close)")
        end
        return 0
    end
    if cmd == "clear"
        for u in urls
            disarm(u)
            println("$(set_fields(u, [k => nothing for k in FIELDS])) $u")
        end
        return 0
    end
    cmd in FIELDS ||
        die("unknown field '$cmd'; one of: " * join(sort(FIELDS), ", ") * ", clear, show")
    length(args) > 2 || die("need a value")
    value = join(args[3:end], " ")
    if cmd == "track"
        value in TRACK || die("track must be one of: " * join(TRACK, ", "))
        # A level change redefines "moved"; re-arm from now.
        foreach(disarm, urls)
    end
    if cmd == "snooze"
        foreach(disarm, urls)
        value in ("off", "none", "") && (value = nothing)
        # Reject it here rather than writing it. A value the refresh cannot parse
        # leaves the item *not* snoozed, and the reason goes into a field only
        # the snoozed section prints - so `wl snooze julia#1 3days` used to look
        # like it worked and quietly do nothing at all.
        value === nothing || parse_snooze(value) !== nothing ||
            die("bad snooze value '$value'. Use on-change, on-change/30d, " *
                "a span like 3d/2w/6mo/1y, or a date like 2026-09-15.")
    elseif cmd == "blocked_on"
        value = String.(split(value, ","))
    end
    for u in urls
        println("$(set_fields(u, [cmd => value])) $cmd $u")
    end
    0
end

function main(args = String[])
    try
        return dispatch(collect(String, args), utcnow())
    catch e
        e isa CliError || rethrow()
        println(stderr, e.msg)
        return 1
    end
end
