# `/`, over the list and over the thread. It marks the source rather than the
# screen, which is what makes a match survive being cut by the wrap.

@testset "/ searches" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    ctrl = W.Controller()
    iw = W.layout(150, 40, 0).riw
    type!(v, x) = for c in x; W.handle!(v, Int(c), ctrl); end

    # In the list it narrows, and it can be kept or dropped.
    st = mkstate()
    n0 = length(st.items)
    W.handle!(st, Int('/'), ctrl)
    @test st.typing && st.searchin === :list
    type!(st, "libuv")
    @test 0 < length(st.items) < n0
    @test all(occursin("libuv", lowercase(i.title * i.ref)) for i in st.items)
    W.handle!(st, 13, ctrl)
    @test !st.typing && st.search == "libuv"          # kept
    W.handle!(st, Int('/'), ctrl); W.handle!(st, 27, ctrl)
    @test isempty(st.search) && length(st.items) == n0 # dropped

    # A bare number jumps, but only once it is finished being typed.
    st = mkstate()
    want = st.all[findfirst(i -> i.number > 999, st.all)]
    W.handle!(st, Int('/'), ctrl)
    type!(st, string(want.number))
    @test st.typing && !occursin("jumped", st.status)   # not until enter
    W.handle!(st, 13, ctrl)
    @test st.items[st.sel].ref == want.ref && occursin("jumped", st.status)
    # ...and it reaches an item the filter was hiding.
    st = mkstate()
    hidden = st.all[findfirst(i -> i.backlog, st.all)]
    @test !any(i -> i.url == hidden.url, st.items)
    W.handle!(st, Int('/'), ctrl); type!(st, string(hidden.number))
    W.handle!(st, 13, ctrl)
    @test st.items[st.sel].url == hidden.url
    # An archived one is hidden by the same `active` state, and the widen has to
    # be measured against the archive map the list itself was built with.
    st = mkstate()
    seen = Dict{Int,Int}()
    for i in st.all
        seen[i.number] = get(seen, i.number, 0) + 1
    end
    away = st.items[findfirst(i -> seen[i.number] == 1, st.items)]
    try
        W.archive!(st, away, W.utcnow())
        @test !any(i -> i.url == away.url, st.items)
        W.handle!(st, Int('/'), ctrl); type!(st, string(away.number))
        W.handle!(st, 13, ctrl)
        @test st.items[st.sel].url == away.url
    finally
        W.set_fields(away.url, ["archive" => nothing])
    end

    st = mkstate()
    W.handle!(st, Int('/'), ctrl); type!(st, "99999999"); W.handle!(st, 13, ctrl)
    @test occursin("no item numbered", st.status)

    # In the detail pane it moves the cursor, and n/N step the matches.
    st = mkstate()
    st.nodes = [W.Node("a", "the quick brown fox\njumps over\nthe lazy dog and the fox", :md, true),
                W.Node("b", "nothing here", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    W.handle!(st, Int('/'), ctrl)
    @test st.searchin === :detail
    type!(st, "fox")
    ms = W.match_rows(st, iw)
    @test length(ms) == 2 && st.nrow == ms[1]
    W.handle!(st, 13, ctrl)
    W.handle!(st, Int('n'), ctrl); @test st.nrow == ms[2]
    W.handle!(st, Int('n'), ctrl); @test st.nrow == ms[1]   # wraps
    W.handle!(st, Int('N'), ctrl); @test st.nrow == ms[2]
    # A search in the thread must not narrow the list out from under the cursor.
    before = length(st.items)
    W.refilter!(st)
    @test length(st.items) == before

    f = W.render(st, 150, 40)
    @test occursin(W.HITBG, f)                          # matches are marked
    @test occursin("2 matches", W.astrip(f))            # and counted
    @test all(W.awidth(l) == 150 for l in split(f, "\n"))

    # Typing takes every key: `/d` is a search, not a jump to the diff pane.
    st = mkstate()
    mode0 = st.mode
    W.handle!(st, Int('/'), ctrl); type!(st, "d")
    @test st.mode === mode0 && st.search == "d"
end

@testset "/ searches the source, not the screen" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    ctrl = W.Controller()
    type!(v, x) = for c in x; W.handle!(v, Int(c), ctrl); end

    # A phrase the pane wrapped in the middle is still found, on the first row
    # of the line it belongs to.
    st = mkstate()
    st.nodes = [W.Node("a", "the quick brown fox jumps over the lazy dog and keeps running", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    body = [r for r in W.rows(st.nodes, 30) if !r.header]
    @test length(body) > 1                         # it really is wrapped
    # ...one that genuinely spans the break, so no single row contains it.
    st.search = "fox jumps over the lazy"
    across = W.match_rows(st, 30)
    @test length(across) == 1
    @test !any(occursin(st.search, W.astrip(r.text)) for r in W.rows(st.nodes, 30))
    st.search = "fox"
    @test length(W.match_rows(st, 30)) == 1        # one per line, not per row
    st.search = "nowhere"
    @test isempty(W.match_rows(st, 30))

    # Inside a folded block: found, counted, and opened on enter.
    st = mkstate()
    st.nodes = W.body_nodes("alice", "prose here\n\n<details><summary>Impacted</summary>\n" *
                                     "a line holding zarquon inside\n</details>\n\ntail",
                            "http://x", true)
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    iw = W.layout(150, 40, 0).riw
    @test !st.nodes[2].open                        # the block starts folded
    W.handle!(st, Int('/'), ctrl)
    type!(st, "zarquon")
    @test isempty(W.match_rows(st, iw))            # no row shows it...
    @test st.hidden == 1                           # ...but it is known to be there
    @test occursin("+1 folded", W.astrip(W.render(st, 150, 40)))
    W.handle!(st, 13, ctrl)
    @test st.nodes[2].open && occursin("opened 1 folded block", st.status)
    @test length(W.match_rows(st, iw)) == 1 && st.hidden == 0

    # Opening reaches through more than one level of nesting.
    st = mkstate()
    ns = [W.Node("top", "", :md, false), W.Node("mid", "", :md, false, 1),
          W.Node("leaf", "zarquon lives here", :md, false, 2)]
    st.nodes = ns
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    @test W.ancestors_of(st, 3) == [3, 2, 1]
    W.handle!(st, Int('/'), ctrl); type!(st, "zarquon"); W.handle!(st, 13, ctrl)
    @test all(n.open for n in st.nodes)
    @test occursin("opened 3 folded blocks", st.status)

    # Typing must not spring folds open on its own.
    st = mkstate()
    st.nodes = [W.Node("top", "", :md, true), W.Node("folded", "zarquon", :md, false, 1)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)
    st.focus = :detail
    W.handle!(st, Int('/'), ctrl); type!(st, "zarq")
    @test !st.nodes[2].open && st.hidden == 1
end
