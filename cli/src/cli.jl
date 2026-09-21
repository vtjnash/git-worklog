# The command surface. One entry point, `wl`: the browser when given nothing,
# and the state editor when given a command.

const USAGE = """
Work dashboard.

  wl                                      the browser
  wl --refresh                            refresh first, then the browser

  wl refresh [--backlog] [--caught-up]    re-fetch, re-derive, re-render; --backlog imports
                                          the open lists of the polled repos, read;
                                          --caught-up stops waiting on late notifications
  wl import  <url> [<url>...]             follow items no lane returns, unread
  wl unread                               JSON of the unread list
  wl unread  julia#62891                  mark a thread unread again
  wl thread  julia#62891 [n]              JSON of a thread's recent comments
  wl done    julia#62891                  mark a thread done (or: done all)
  wl done    --consolidate [--dry-run]    raise every source's floor, drop the stamps it answers for
  wl show    julia#62891                  state + the thread's recent comments
  wl watching                             repos you watch, and which are tracked
  wl log                                  what the last refresh run from the browser said
  wl repos [--prune]                      pinned checkouts; --prune forgets gone ones
  wl track   julia#62452 loose           normal | loose - what counts as it moving
  wl dismiss julia#62452                  loose, and read: back only when it moves
  wl snooze  julia#62452 3d               or 2w, 6mo, a date; "off" clears it
  wl note    julia#62452 "rebase after #62396 lands"
  wl archive julia#62452                  file it away; again to take it back out
  wl adopted local:o/r#branch 2026-09-02  a local branch you are carrying
  wl deadline julia#62452 2026-09-30
  wl blocked julia#62452 JuliaLang/julia#62396
  wl clear   julia#62452

Anywhere a ref is taken, `-` means "read them from stdin, one per line" - so a
batch is one process rather than a loop of them:

  printf '%s\n' julia#62452 julia#62396 | wl snooze - 3d
  wl unread julia#62841 | wl import -
"""

"""Lines of stdin, blanks and `#` comments dropped, first word of each.

The raw half of `refs`: a url needs no resolving, and requiring one to be in
the fetched items first would refuse exactly what `import` exists for.

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

The bulk half of the browser's `I`. One batched request for the lot rather than
one each, `imported` written per url so a refresh keeps them, and an inbox entry
per item so they arrive in the unread lane - which is the difference from `I`,
where you are already looking at the thing.

A url that resolves to nothing is reported and skipped rather than written: a
line in `local.toml` that fetches nothing on every refresh forever is worse than
a typo that says so.
"""
function import_urls(urls::Vector{String}, at::DateTime)
    want = String[]
    for u in urls
        c = item_url(u)
        c === nothing ? println(stderr, "not an issue or pull request url: ", u) :
                        push!(want, c)
    end
    # The same url twice is one import. Cheap to say here, and it keeps the
    # batched request from carrying the same node twice.
    unique!(want)
    isempty(want) && return 1
    # What is already carried needs no request: an old issue in a tracked repo
    # or a pull request of yours somewhere else is usually fetched already
    # already, and importing it means "unread again", not "fetch it again".
    known = Dict(x.url => x for x in something(fetched_items(), Item[]))
    fresh = [u for u in want if !haskey(known, u)]
    nodes = isempty(fresh) ? Any[] : fetch_urls(fresh)
    got = Dict(String(n.url) => n for n in nodes)
    rows = OrderedDict{String,Any}[]
    for u in want
        it = get(known, u, nothing)
        if it !== nothing
            set_fields(u, ["imported" => string(Date(at))], at)
            push!(rows, inbox_row(it, at))
            println("already tracked, unread again ", u)
            continue
        end
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
    Events.inbox_add!(rows; overwrite = false)
    @printf(stderr, "%d imported, unread. `wl refresh` folds them into the dashboard.\n",
            length(rows))
    0
end

function dispatch(args::Vector{String}, at::DateTime = utcnow(); poll = Events.poll)
    cmd = isempty(args) ? "" : args[1]
    cmd in ("-h", "--help", "help") && (println(USAGE); return 0)
    # Everything below reads rows as yours or not by this name; with none,
    # every one of them would be wrong quietly.
    isempty(String(get(config(), "login", ""))) &&
        die("no `login` in $(userconfig()): set it to your GitHub login")
    (isempty(args) || args == ["--refresh"]) && return ui(args, at)
    if cmd == "refresh"
        # The word that the notifications are fine: stop waiting on the ones
        # the poll expected, and ask narrowly again. See `Events.expect!`.
        "--caught-up" in args &&
            println(stderr, "  notifications: ", Events.caught_up!(), " awaited, dropped; the ask is narrow again")
        return refresh(args[2:end])
    end
    if cmd == "import"
        length(args) > 1 || die(USAGE)
        return import_urls(args[2] == "-" ? stdin_lines() : args[2:end], at)
    end
    if cmd == "unread"
        # With a ref it is the inverse of `done`; bare it is the JSON dump,
        # which is how anything outside this program asks what is unread:
        # the clocks polled, then `seen_of` over the corpus and the light
        # rows - the one answer, the browser's too.
        if length(args) > 1
            for u in refs(args[2])
                println(mark_unread([u]) == 0 ? "was not done $u" :
                        "not done $u")
            end
            return 0
        end
        cfg = config()
        rows = poll(cfg, cfg["login"], at; verbose = false)
        m = unread_marks(at)
        print(json_dumps([item_json(it, m) for it in unread_items(at, rows)]))
        return 0
    end
    if cmd == "log"
        # The whole of the last `u`, kept where the status row could only show
        # its last line. Only the browser's: a refresh run from a terminal
        # printed on it.
        isfile(refreshlog()) || (println(stderr, "no refresh has been run from the browser yet"); return 1)
        print(read(refreshlog(), String))
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
        # Written as the TOML it is going to become, not as bare names: what is
        # wanted from this is a paste, and a list of names is a list of names
        # somebody then has to quote and comma one at a time.
        for r in subs
            c = covers(r)
            println(isempty(c) ? "  " : "# ", repr(r), ",",
                    isempty(c) ? "" : "   ($c)")
        end
        @printf(stderr, "\n%d watched, %d already tracked, %d not.\n",
                length(subs), length(subs) - length(untracked), length(untracked))
        isempty(untracked) ||
            println(stderr, "The uncommented lines go inside [events].repos ",
                    "in data/config.toml. `wl watching | grep -v '^#'` is just them.")
        return 0
    end
    if cmd == "repos"
        rs = pinned_repos()
        if isempty(rs)
            println(stderr, "No repos pinned yet. The browser asks for one the ",
                    "first time it needs file content.")
            return 0
        end
        prune = length(args) > 1 && args[2] == "--prune"
        gone = prune ? prune_repos!() : [r.name for r in rs if !r.there]
        w = maximum(length(r.name) for r in rs)
        for r in rs
            prune && !r.there && continue
            println("  ", rpad(r.name, w), "  ", r.path, r.there ? "" : "   (gone)")
        end
        if prune
            @printf(stderr, "\n%d forgotten.\n", length(gone))
        elseif isempty(gone)
            @printf(stderr, "\n%d pinned, all present.\n", length(rs))
        else
            @printf(stderr, "\n%d pinned, %d gone. `wl repos --prune` forgets those.\n",
                    length(rs), length(gone))
        end
        return 0
    end
    if cmd == "thread"
        length(args) > 1 || die(USAGE)
        body, cs, cms, sts = Events.thread(resolve(args[2]);
                                           limit = length(args) > 2 ? parse(Int, args[3]) : 12)
        # `comments` as it always was, and beside it the pushes and the
        # state changes the browser draws among them - as `activity`, the one
        # list in the order it happened, each entry saying which it is.
        who(c) = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", nothing)
        entry(e) = e.kind === :comment ?
            ["kind" => "comment", "at" => e.at, "who" => who(e.c),
             "body" => something(get(e.c, "body", nothing), "")] :
            e.kind === :push ?
            ["kind" => "push", "at" => e.at, "who" => get(e.c[end], "by", ""),
             "commits" => [["oid" => c["oid"], "at" => c["at"], "by" => get(c, "by", ""),
                            "headline" => c["headline"]] for c in e.c]] :
            ["kind" => "state", "at" => e.at, "who" => get(e.c, "by", ""),
             "state" => e.c["kind"],
             (String(k) => v for (k, v) in e.c if k in ("closer", "reason", "into", "oid"))...]
        print(json_dumps([
            "title" => body["title"],
            "body" => something(get(body, "body", nothing), ""),
            "state" => body["state"],
            "user" => who(body),
            "comments" => [["at" => c["created_at"], "who" => who(c),
                            "body" => something(get(c, "body", nothing), "")] for c in cs],
            "activity" => [entry(e) for e in activity_list(cs, cms, sts)]]))
        return 0
    end
    if cmd == "done"
        arg = length(args) > 1 ? args[2] : "all"
        if arg == "--consolidate"
            dry = "--dry-run" in args
            c = consolidate!(at; dry_run = dry)
            would = dry ? "would " : ""
            if c.since === nothing || (isempty(c.raised) && isempty(c.dropped))
                println("nothing to consolidate: every floor is where the stamps put it",
                        c.since === nothing ? "" : " ($(c.since))")
                return 0
            end
            for (l, s) in sort!(collect(c.raised))
                println(would, "raise  source:", l, "  since = ", s)
            end
            println(would, "drop   ", length(c.dropped), " done stamp",
                    length(c.dropped) == 1 ? "" : "s", " the floor answers for")
            dry && println("(dry run; nothing written)")
            return 0
        end
        if arg == "all"
            # The same list `wl unread` prints, so a second `done all` finds
            # nothing by construction: every row it stamps is stamped at the
            # movement `seen_of` compares against.
            cfg = config()
            rows = poll(cfg, cfg["login"], at; verbose = false)
            urls = [it.url for it in unread_items(at, rows)]
            println("done: $(mark_done_moved(urls, at; fold = true)) threads")
        else
            for u in refs(arg)
                mark_done_moved([u], at; fold = true)
                println("done $u")
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
        body, cs, cms, sts = try
            Events.thread(url)
        catch e
            die("could not fetch thread: " * sprint(showerror, e))
        end
        title = body["title"]
        print("\n$title\n", "-"^min(length(title), 78), "\n\n")
        # The same list the browser draws: the pushes and the state changes
        # among the comments, in the order it happened, worded as the pane's
        # headers are (`src`, what `y` copies off one).
        for e in activity_list(cs, cms, sts)
            if e.kind !== :comment
                nd = e.kind === :push ? push_node(e.c, url) : state_node(e.c, url)
                print("  ", nd.meta["src"], "\n")
                for l in split(nd.raw, '\n'; keepempty = false)
                    print("    ", l, "\n")
                end
                println()
                continue
            end
            c = e.c
            who = get(something(get(c, "user", nothing), Dict{String,Any}()), "login", nothing)
            print("  ", replace(first(c["created_at"], 16), "T" => " "), "  ", pyrepr(who), "\n")
            # Rendered, not cut at 600 characters: the same markdown path the
            # browser uses, with links lifted to footnotes.
            show_md(something(get(c, "body", nothing), ""))
            println()
        end
        return 0
    end
    if cmd == "archive"
        # A mark, the same one `x` writes, and a toggle the same way: filed
        # goes back out. It takes no date - the mark carries when it was
        # written, and that is the date.
        for u in urls
            if get_field(u, "archived") !== nothing
                set_archived(u, nothing)
                println("unarchived $u")
            else
                set_archived(u, stamp(at))
                set_touched(u, stamp(at))
                # Filing something is the end of looking at it, the same
                # courtesy a snooze pays. It goes unread again the moment it
                # moves, which is what the attention axis is for and is not
                # what this decides; the mark is what holds it out of view.
                mark_done_moved([u], at)
                println("archived $u")
            end
        end
        return 0
    end
    if cmd == "dismiss"
        # Retire an item from the pile: stop caring about churn, but do not go
        # blind to it. Loose tracking, and read - which is all "until it moves"
        # ever was - so it comes back only if something that actually matters
        # happens to it.
        for u in urls
            set_fields(u, ["track" => "loose"])
            mark_done_moved([u], at; fold = true)
            println("dismissed $u (returns only on a review, reply, push or close)")
        end
        return 0
    end
    if cmd == "clear"
        for u in urls
            set_archived(u, nothing)
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
    end
    if cmd == "snooze"
        value in ("off", "none", "") && (value = nothing)
        # Reject it here rather than writing it: a value nothing can parse is
        # not a snooze, and `wl snooze julia#1 3days` used to look like it
        # worked and quietly do nothing at all. Written *resolved* - a span
        # becomes the moment it ends - so the file says when, and nothing has
        # to remember when it was set.
        if value !== nothing
            value = wake_of(value, stamp(at))
            value === nothing &&
                die("bad snooze value '$value'. Use a span like 3d/2w/6mo/1y, " *
                    "or a date like 2026-09-15. \"Until it moves\" is `wl done`, " *
                    "and \"forever\" is `wl archive`.")
        end
    elseif cmd == "blocked_on"
        value = String.(split(value, ","))
    end
    for u in urls
        # A snooze is remembered beside itself, as `s` remembers it.
        ups = cmd == "snooze" && value !== nothing ? [cmd => value, "last_snooze" => value] :
              [cmd => value]
        println("$(set_fields(u, ups)) $cmd $u")
        # Putting something to sleep is the end of looking at it. It goes unread
        # again the moment it moves, or the moment the wake comes - which is
        # why this is a stamp and not a claim about wanting to see it.
        cmd == "snooze" && value !== nothing && mark_done_moved([u], at)
    end
    0
end

"""Be called `wl` where the system asks the process its name.

libuv's `uv_set_process_title`, which is the one call that reaches everything:
on Linux it rewrites the argv area, which is `/proc/<pid>/cmdline` - `ps`'s
full line, and what tmux reads for its automatic window name - and sets the
comm name as well, which is htop's default column and `ps -o comm`; on macOS
and Windows it does whatever those have. Julia called `uv_setup_args` at
startup, which is what makes the argv area writable. `prctl(PR_SET_NAME)` was
the first attempt and reached only comm; `exec -a wl` in `bin/wl` reached
nothing, since juliaup's launcher execs the real binary under its own path.

With the arguments, so `wl refresh` in a process list is told apart from the
browser - and then, on Linux, the comm name set again to the bare name, because
libuv sets it to the whole title cut at fifteen bytes and `wl refresh --ba` is
not a name.
"""
function name_process!(args = String[]; name::AbstractString = "wl")
    title = join(vcat(String(name), String.(args)), " ")
    ok = ccall(:uv_set_process_title, Cint, (Cstring,), title) == 0
    if Sys.islinux()
        n = String(name)
        GC.@preserve n ccall(:prctl, Cint, (Cint, Ptr{UInt8}, Culong, Culong, Culong),
                             15 #= PR_SET_NAME =#, pointer(n), 0, 0, 0)
    end
    ok
end

function main(args = String[])
    name_process!(args)
    # The first `wl`: your file, from the template. The colours were loaded
    # at `__init__` off the shared file alone, and the file just written
    # names a theme of its own.
    seed_config!() && (empty!(THEME_NOTES); append!(THEME_NOTES, load_theme!()))
    # A command's channel is stderr; the browser's is its footer, and it says
    # these there (`standing_note`).
    (isempty(args) || args == ["--refresh"]) ||
        foreach(p -> println(stderr, "worklog: ", p), THEME_NOTES)
    try
        return dispatch(collect(String, args), utcnow())
    catch e
        e isa CliError || rethrow()
        println(stderr, e.msg)
        return 1
    end
end
