# The command surface. One entry point, `wl`, which is the interactive
# navigator when given nothing and the state editor when given a command.

const USAGE = """
Work dashboard.

  wl                                      the interactive navigator
  wl --refresh                            refresh first, then the navigator

  wl refresh [--firehose]                 re-fetch, re-bucket, re-render
  wl unread                               JSON, for the navigator
  wl unread  julia#62891                  mark a thread unread again
  wl thread  julia#62891 [n]              JSON of a thread's recent comments
  wl read    julia#62891                  mark a thread seen (or: read all)
  wl show    julia#62891                  state + the thread's recent comments
  wl next    [n]                          pull the next untagged backlog items
  wl track   julia#62452 close            close | normal | loose | background
  wl dismiss julia#62452                  retire from the backlog until it moves
  wl snooze  julia#62452 on-change        or a date, or "off"
  wl note    julia#62452 "rebase after #62396 lands"
  wl deadline julia#62452 2026-09-30
  wl agent   julia#62452 "rebase + rerun Compiler tests"
  wl bucket  julia#62452 needs-agents
  wl blocked julia#62452 JuliaLang/julia#62396
  wl clear   julia#62452
"""

config() = TOML.parse(read(joinpath(ROOT, "config.toml"), String))

function dispatch(args::Vector{String})
    (isempty(args) || args == ["--refresh"]) && return ui(args)
    cmd = args[1]
    cmd in ("-h", "--help", "help") && (println(USAGE); return 0)
    cmd == "refresh" && return refresh(args[2:end])
    cmd == "next" && return next_batch(length(args) > 1 ? parse(Int, args[2]) : 10)
    if cmd == "unread"
        # With a ref it is the inverse of `read`; bare it is still the dump the
        # navigator reads.
        if length(args) > 1
            u = resolve(args[2])
            println(Events.mark_unread([u]) == 0 ? "was not marked read $u" :
                    "marked unread $u")
            return 0
        end
        cfg = config()
        print(json_dumps(Events.unread(cfg, cfg["login"]; verbose = false)))
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
            urls = [e["url"] for e in Events.unread(cfg, cfg["login"]; verbose = false)]
            println("marked $(Events.mark_read(urls)) threads read")
        else
            u = resolve(arg)
            Events.mark_read([u])
            println("marked read $u")
        end
        return 0
    end
    length(args) > 1 || die(USAGE)
    url = resolve(args[2])
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
        disarm(url)
        set_fields(url, ["track" => "loose", "snooze" => "on-change"])
        println("dismissed $url (returns only on a review, reply or close)")
        return 0
    end
    if cmd == "clear"
        disarm(url)
        println("$(set_fields(url, [k => nothing for k in FIELDS])) $url")
        return 0
    end
    cmd in FIELDS ||
        die("unknown field '$cmd'; one of: " * join(sort(FIELDS), ", ") * ", clear, show")
    length(args) > 2 || die("need a value")
    value = join(args[3:end], " ")
    if cmd == "track"
        value in TRACK || die("track must be one of: " * join(TRACK, ", "))
        disarm(url)          # a level change redefines "moved"; re-arm from now
    end
    if cmd == "snooze"
        disarm(url)
        value in ("off", "none", "") && (value = nothing)
    elseif cmd == "blocked_on"
        value = String.(split(value, ","))
    end
    println("$(set_fields(url, [cmd => value])) $cmd $url")
    0
end

function main(args = String[])
    _clock!()
    try
        return dispatch(collect(String, args))
    catch e
        e isa CliError || rethrow()
        println(stderr, e.msg)
        return 1
    end
end
