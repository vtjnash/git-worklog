# The filter and view model, and the pane that shows it: what each axis lists,
# what the counts mean, and the ways back out of a filter.

@testset "axis counts match the brute-force ones" begin
    st = mkstate()
    # What the counts used to be computed by: one full pass per value, with one
    # axis replaced. Slow, obviously correct, and the thing to check against.
    brute(f, axis, v) = begin
        p = W.Filters(f.state, copy(f.buckets), copy(f.repos), copy(f.labels), f.kind,
                      copy(f.authors))
        axis === :state  ? (p.state = v) :
        axis === :kind   ? (p.kind = v) :
        axis === :bucket ? (p.buckets = Set([v])) :
        axis === :repo   ? (p.repos = Set([v])) :
        axis === :author ? (p.authors = Set([v])) : (p.labels = Set([v]))
        # The same maps the counts are computed against, or the two sides are
        # answering about different lists: `archived` and `drafts` are
        # membership in a file, and an empty one here would make every count of
        # them zero and the comparison vacuous.
        count(it -> W.matches(p, it, st.unread, st.touched, st.archived, st.drafts),
              st.all)
    end
    configs = [W.Filters(),
               W.Filters(:all, Set{String}(), Set{String}(), Set{String}()),
               W.Filters(:backlog, Set{String}(), Set{String}(), Set{String}()),
               W.Filters(:all, Set(["needs-review"]), Set{String}(), Set{String}()),
               W.Filters(:active, Set{String}(), Set(["JuliaLang/julia"]), Set{String}()),
               W.Filters(:all, Set(["issue"]), Set(["JuliaLang/julia"]), Set(["docs"])),
               W.Filters(:all, Set{String}(), Set{String}(), Set{String}(), :issue),
               W.Filters(:active, Set{String}(), Set(["JuliaLang/julia"]),
                         Set{String}(), :pr),
               W.Filters(:all, Set{String}(), Set{String}(), Set{String}(), :both,
                         Set([W.AUTHOR_ME])),
               W.Filters(:all, Set{String}(), Set{String}(), Set{String}(), :both,
                         Set([W.AUTHOR_OTHERS, "Keno"]))]
    for f in configs
        st.filters = f
        (ns, nk, nb, nr, nl, na) = W.axis_counts(st)
        for (k, _) in W.STATES
            @test get(ns, k, 0) == brute(f, :state, k)
        end
        for (k, _) in W.KINDS
            @test get(nk, k, 0) == brute(f, :kind, k)
        end
        for v in st.buckets;  @test get(nb, v, 0) == brute(f, :bucket, v); end
        for v in first(st.repos, 12);  @test get(nr, v, 0) == brute(f, :repo, v); end
        for v in first(st.labels, 12); @test get(nl, v, 0) == brute(f, :label, v); end
        for v in first(st.authors, 12); @test get(na, v, 0) == brute(f, :author, v); end
    end

    # Three values and no fourth: both is the whole list, and the other two
    # partition it.
    st.filters = W.Filters(:all, Set{String}(), Set{String}(), Set{String}())
    both = length(W.apply_filters(st.filters, st.all, st.unread))
    st.filters.kind = :pr;    prs = length(W.apply_filters(st.filters, st.all, st.unread))
    st.filters.kind = :issue; iss = length(W.apply_filters(st.filters, st.all, st.unread))
    @test prs + iss == both && prs > 0 && iss > 0
    @test occursin("issues", W.filter_summary(st.filters))
    st.filters.kind = :pr
    @test occursin("pull requests", W.filter_summary(st.filters))
    st.filters.kind = :both
    @test !occursin("pull requests", W.filter_summary(st.filters))
end

@testset "the one lane GitHub cannot be asked for" begin
    # A pending review is visible to nobody but its author and from nowhere but
    # the pull request it is on: `reviews(states: PENDING, author: $me)` answers
    # for one item, no query answers for all of them, and `review:pending` is
    # not a search qualifier - it matches nothing, exactly as `review:banana`
    # does. So the lane is a file this program writes as it writes the comments.
    st = mkstate()
    it = st.items[st.sel]
    @test isempty(W.load_drafts())
    W.draft!(it.url)
    st.filters = W.Filters(:drafts, Set{String}(), Set{String}(), Set{String}())
    W.refilter!(st)
    @test [x.url for x in st.items] == [it.url]
    # Counted like every other value on the axis, and offered as a row.
    (nstate, _, _, _, _, _) = W.axis_counts(st)
    @test get(nstate, :drafts, 0) == 1
    @test any(r -> r[1] === :state && r[2] == "drafts", W.filter_rows(st))
    # Archived work stays in it. A draft on something you have put away is the
    # strongest reason there is to be shown it again: the two together mean the
    # work was filed and the words were never sent.
    @test W.state_ok(:drafts, it, Set{String}(), W.EMPTY_TOUCHED,
                     Dict(it.url => "2026-01-01"), Dict(it.url => "2026-01-01"))
    # Sent or thrown away, it leaves the lane.
    W.undraft!(it.url)
    W.refilter!(st)
    @test isempty(st.items) && isempty(W.load_drafts())
end

@testset "an axis you can search, and whose it is" begin
    # The pane used to try to show what was available: ~140 repos, hundreds of
    # labels, and authors would have been worse than either. Showing the first
    # eight was a compromise that served neither purpose. Now the long axes are
    # a readout of what is *on*, and the picker row below is where choosing
    # happens - so the pane is as long as the answer, not as the question.
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true
    rows = W.filter_rows(st)
    axis_rows(a) = [r for r in rows if r[1] === a]
    @test isempty(axis_rows(:repo)) && isempty(axis_rows(:label))
    # Except the author axis's two controls, which are controls rather than
    # values and are always there.
    @test length(axis_rows(:author)) == 2
    # What is applied is listed, on every axis, and that is the whole of it.
    st.filters.repos = Set([first(st.repos)])
    st.filters.labels = Set([first(st.labels)]); W.refilter!(st)
    r2 = W.filter_rows(st)
    @test [r[2] for r in r2 if r[1] === :repo] == [first(st.repos)]
    @test [r[2] for r in r2 if r[1] === :label] == [first(st.labels)]
    st.filters = W.Filters(); W.refilter!(st)
    # Category is exempt: a dozen values, each a different kind of work, short
    # enough to read whole. It still drops the ones that would select nothing.
    (_, _, nb, _, _, _) = W.axis_counts(st)
    @test length(axis_rows(:bucket)) == count(b -> get(nb, b, 0) > 0, st.buckets)
    @test length(axis_rows(:bucket)) > 8                     # and so, uncapped
    @test isempty([r for r in rows if r[1] === :pick && r[2] == "bucket"])
    # A row per long axis that opens the rest, and it says how many there are.
    picks = [r[2] for r in rows if r[1] === :pick]
    @test picks == ["repo", "label", "author"]
    @test occursin(string(length(st.repos)), first(r[3] for r in rows if r[1] === :pick))

    # Alphabetical, on every axis. Ordering by weight put the busiest first,
    # which sounds useful and is not: nobody holds a model of which value would
    # select most, so the head of the list was in an order that could be neither
    # predicted nor looked up. A name can be found by knowing its name.
    @test issorted(st.repos) && issorted(st.labels)
    # Except the author axis's two controls, which lead it: neither is a name
    # anybody would think to type.
    @test st.authors[1] == W.AUTHOR_ME && st.authors[2] == W.AUTHOR_OTHERS
    @test issorted(st.authors[3:end])

    # And those two are listed whether or not they would select anything: that
    # they select nothing is the answer. Narrowed to a repo with none of your
    # work in it, the whole axis used to vanish - no rows at all, not even the
    # half of it that had items.
    quiet = mkstate()
    away = first(r for r in quiet.repos
                 if all(x.author != W.login() for x in quiet.all if x.repo == r))
    quiet.filters.repos = Set([away]); W.refilter!(quiet)
    arows = [r for r in W.filter_rows(quiet) if r[1] === :author]
    @test length(arows) == 2
    @test occursin("me (", arows[1][3]) && occursin("anyone else", arows[2][3])

    # `↵` on the picker row opens a ChooseView over every value the axis has,
    # minus what is already applied, and typing narrows it by `occursin`.
    st.lmode = :filters
    st.frow = findfirst(r -> r[1] === :pick && r[2] == "repo", rows)
    @test W.toggle_filter!(st, ctrl)
    cv = last(ctrl.stack)
    @test cv isa W.ChooseView && length(cv.options) == length(st.repos)
    cv.query = "libuv"
    @test !isempty(W.shown(cv)) && all(occursin("libuv", o[1]) for o in W.shown(cv))
    # Picking one applies it, and it is then a row of its own in the pane.
    cv.onpick("libuv/libuv")
    pop!(ctrl.stack)
    @test st.filters.repos == Set(["libuv/libuv"])
    @test all(x.repo == "libuv/libuv" for x in st.items)
    @test any(r -> r[1] === :repo && r[2] == "libuv/libuv" && occursin("[x]", r[3]),
              W.filter_rows(st))
    # And what is applied is listed however little it carries, so `↵` can take
    # it off again.
    st.frow = findfirst(r -> r[1] === :repo && r[2] == "libuv/libuv", W.filter_rows(st))
    @test W.toggle_filter!(st, ctrl)
    @test isempty(st.filters.repos)
    # A picker needs somewhere to push itself; without one the row does nothing.
    st.frow = findfirst(r -> r[1] === :pick, W.filter_rows(st))
    @test !W.toggle_filter!(st)

    # Whose it is. `mine` answered half the question - your own pull requests -
    # and the other half is the commoner one: somebody else's, in front of you.
    me = W.Item(url = "u1", ref = "a#1", repo = "a/b", number = 1, title = "t",
                author = W.login())
    them = W.Item(url = "u2", ref = "a#2", repo = "a/b", number = 2, title = "t",
                  author = "someone")
    # An adopted branch has no author and is yours: nobody else wrote it.
    local_ = W.Item(url = "local:a/b#x", ref = "b#x", repo = "a/b", number = 0,
                    title = "t", author = "")
    @test W.author_ok(Set{String}(), them)                    # empty restricts nothing
    @test W.author_ok(Set([W.AUTHOR_ME]), me)
    @test !W.author_ok(Set([W.AUTHOR_ME]), them)
    @test W.author_ok(Set([W.AUTHOR_ME]), local_)
    @test W.author_ok(Set([W.AUTHOR_OTHERS]), them)
    @test !W.author_ok(Set([W.AUTHOR_OTHERS]), me)
    @test !W.author_ok(Set([W.AUTHOR_OTHERS]), local_)
    @test W.author_ok(Set(["someone"]), them)                 # a login is a value too
    # OR within the axis, as on every other one.
    @test W.author_ok(Set([W.AUTHOR_ME, "someone"]), them)
    @test W.author_ok(Set([W.AUTHOR_ME, "someone"]), me)

    # The two predicates partition the list, and your own login is not a row of
    # its own - `@me` is that row, and it carries the adopted branches too.
    st2 = mkstate()
    st2.filters.state = :all; W.refilter!(st2)
    all_ = length(st2.items)
    st2.filters.authors = Set([W.AUTHOR_ME]); W.refilter!(st2)
    mine = length(st2.items)
    st2.filters.authors = Set([W.AUTHOR_OTHERS]); W.refilter!(st2)
    @test mine + length(st2.items) == all_
    @test !(W.login() in st2.authors)
    @test st2.authors[1] == W.AUTHOR_ME && st2.authors[2] == W.AUTHOR_OTHERS
    # And it says so where the filter says what it is.
    @test occursin("anyone else", W.filter_summary(st2.filters))
    st2.filters.authors = Set([W.AUTHOR_ME, "Keno"])
    @test occursin("Keno", W.filter_summary(st2.filters))
    # `c` clears every axis, this one included.
    st2.lmode = :filters
    W.handle!(st2, Int('c'), ctrl)
    @test isempty(st2.filters.authors) && st2.filters.state === :active
end

@testset "the row that clears every filter" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    st.lmode = :filters; st.focus = :list
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)

    # `c` has always done this and nothing on screen said so.
    @test W.isdefault(W.Filters())
    rows = W.filter_rows(st)
    @test rows[1][1] === :reset
    @test occursin("clear every filter", W.astrip(W.render(st, 160, 50)))
    # Nothing to clear, so the row says only what it is - and refuses, rather
    # than spending the one `\`` slot on a move that changed nothing.
    st.frow = 1
    @test W.toggle_filter!(st, ctrl) === false
    @test st.prev === nothing

    st.filters.labels = Set(["docs"]); st.filters.state = :all
    st.filters.kind = :issue; W.refilter!(st)
    @test !W.isdefault(st.filters)
    # Once there is something to clear, the row names the key that also does it.
    @test occursin("(c)", W.filter_rows(st)[1][3])
    st.frow = 1
    @test W.toggle_filter!(st, ctrl) === true
    @test W.isdefault(st.filters)
    # The same jump `c` makes, remembered the same way: `\`` from the item list
    # goes back to whatever was applied before, which is what makes clearing
    # safe to try.
    @test st.prev !== nothing
    @test st.prev.labels == Set(["docs"]) && st.prev.kind === :issue
    st.lmode = :items
    W.handle!(st, Int('`'), ctrl)
    @test st.filters.labels == Set(["docs"]) && st.filters.kind === :issue
end

@testset "n/N steps between filter groups" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    st.lmode = :filters; st.focus = :list
    ctrl = W.Controller()
    rows = W.filter_rows(st)
    g = W.filter_groups(rows)
    # reset, then state, kind, category, repo, label, author
    @test length(g) == 7
    @test rows[1][1] === :reset && g[1] == 1    # the way out leads the pane
    @test all(r -> rows[r][1] !== :head, g)     # each lands on something pickable

    st.frow = g[1]
    for want in g[2:end]
        W.handle!(st, Int('n'), ctrl)
        @test st.frow == want
    end
    W.handle!(st, Int('n'), ctrl)
    @test st.frow == g[end]                     # stops at the last group
    for want in reverse(g[1:end-1])
        W.handle!(st, Int('N'), ctrl)
        @test st.frow == want
    end

    # The ends and the page keys, which the filter list is long enough to need
    # and which used to stop at the item list.
    nf = length(rows)
    W.handle!(st, Int('G'), ctrl)
    @test st.frow == nf
    W.handle!(st, Int('g'), ctrl)
    @test st.frow == 1
    W.handle!(st, W.K_END, ctrl); @test st.frow == nf
    W.handle!(st, W.K_HOME, ctrl); @test st.frow == 1
    W.handle!(st, Int(' '), ctrl)
    paged = st.frow
    @test 1 < paged <= nf
    W.handle!(st, Int('b'), ctrl)
    @test st.frow == 1
    W.handle!(st, W.K_PGDN, ctrl); @test st.frow == paged
    W.handle!(st, W.K_PGUP, ctrl); @test st.frow == 1
    # And they stay inside the list at both ends.
    W.handle!(st, Int('b'), ctrl); @test st.frow == 1
    st.frow = nf
    W.handle!(st, Int(' '), ctrl); @test st.frow == nf
end

@testset "the key help says what is bound" begin
    st = mkstate()
    # `↵` does three different things, so the footer names the one it would do
    # from where the cursor is rather than the one it does somewhere else.
    hint(x) = (m = match(r"(\S+ \S+) \u00b7 n/N", W.astrip(W.render(x, 200, 40)));
               m === nothing ? "" : m[1])
    e = mkstate()
    @test hint(e) == "\u21b5 read"
    e.sel = 0
    @test hint(e) == "\u21b5 import"
    e.sel = 1; e.focus = :detail
    @test hint(e) == "\u21b5 fold"

    line = W.astrip(W.render(st, 200, 40))
    # Every key the list and the detail bind should be findable in the footer.
    for k in ("f filters", "d diff", "o comments", "c checks", "l log", "y copy",
              "/ search", "n/N node", "g/G top/bottom", "j/k line", "space/b page",
              "q quit", "tab pane", "C comment", "A review", "L labels",
              "r read/unread", "R reload", "s snooze", "z undo", "v note", "e edit",
              "t term", "T agent", "\" worktrees", "m mouse")
        @test occursin(k, line)
    end
    # Except `i`, which is the one key whose control is on screen already: the
    # import row leads the list, permanently, and says what it does. A second
    # copy of it in the footer costs the room a key with no such row needs -
    # which is what it cost when `R` arrived and the row was cut at 150 columns.
    @test !occursin("i import", line)
    @test occursin("import an item by url", W.astrip(W.render(st, 200, 40)))
    # The navigation runs at the end, so a narrow screen keeps what is worth
    # reading rather than cutting it first.
    @test findfirst("d diff", line)[1] < findfirst("j/k line", line)[1]
    @test findfirst("/ search", line)[1] < findfirst("space/b page", line)[1]
end

@testset "labels are a filter axis" begin
    st = mkstate()
    @test !isempty(st.labels)
    # :all, so the state axis does not reject the sample before labels are read.
    f = W.Filters(); f.state = :all
    it = st.all[findfirst(x -> !isempty(x.labels), st.all)]
    push!(f.labels, first(it.labels))
    @test W.matches(f, it, Set{String}())
    other = st.all[findfirst(x -> isempty(x.labels), st.all)]
    @test !W.matches(f, other, Set{String}())
    @test occursin(first(it.labels), W.filter_summary(f))
    # Every label row the pane offers actually selects something.
    st.filters = f
    rows = W.filter_rows(st)
    @test any(r -> r[1] === :label, rows)
    @test all(r -> r[1] !== :label || !isempty(r[2]), rows)
end

@testset "a filter worth a name, and the way back out" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller(); ctrl.running = true

    # The defaults are composites on purpose: a single bucket is already one `f`
    # away and needs no name.
    names = [n for (n, _) in W.views(Dict{String,Any}())]
    @test "waiting on me" in names && "ready to merge" in names
    # Except the first, which is the way back to nothing and leads for the same
    # reason the import row leads the item list.
    @test occursin("default", first(names))
    # config.toml adds to them, and replaces one of the same name rather than
    # listing it twice.
    cfg = Dict{String,Any}("views" => Dict{String,Any}(
        "mine, all of it" => Dict("state" => "mine"),
        "waiting on me" => Dict("state" => "unread")))
    vs = W.views(cfg)
    @test length(vs) == length(names) + 1
    @test Dict(vs)["waiting on me"]["state"] == "unread"

    # A view sets every axis it names and clears every axis it does not: half a
    # remembered filter is worse than none.
    st.filters.labels = Set(["docs"]); st.filters.kind = :issue
    W.apply_view!(st, Dict("state" => "all", "bucket" => ["needs-review"]))
    @test st.filters.state === :all && st.filters.buckets == Set(["needs-review"])
    @test isempty(st.filters.labels) && st.filters.kind === :both
    # A single value is as good as a list of one.
    W.apply_view!(st, Dict("state" => "all", "repo" => "JuliaLang/julia"))
    @test st.filters.repos == Set(["JuliaLang/julia"])

    # The sort is an axis like the rest: a view that names one sets it, and a
    # view that names none puts it back. A name has to mean the same list from
    # wherever it is pressed, and an order carried over from the list you were
    # in is not that.
    W.apply_view!(st, Dict("state" => "all", "sort" => "latest"))
    @test st.sort === :latest
    W.apply_view!(st, Dict("state" => "all"))
    @test st.sort === :none

    # And the first view is the whole default, sort included.
    st.sort = :touched; st.filters.labels = Set(["docs"])
    W.apply_view!(st, last(first(W.views(Dict{String,Any}()))))
    @test W.isdefault(st.filters) && st.sort === :none

    # `\`` is the way back out, and back in again: one slot, which is the depth
    # the move actually has.
    was = W.filter_summary(st.filters, st.sort)
    W.handle!(st, Int('`'), ctrl)
    @test W.filter_summary(st.filters, st.sort) != was
    @test occursin("back to", st.status)
    W.handle!(st, Int('`'), ctrl)
    @test W.filter_summary(st.filters, st.sort) == was
    # With nothing to go back to it says so rather than doing nothing.
    st.prev = nothing
    W.handle!(st, Int('`'), ctrl)
    @test occursin("no filter to go back to", st.status)

    # `\'` opens the list, and picking one applies it.
    @test occursin("' views", W.astrip(W.render(st, 160, 50)))
    W.handle!(st, Int('\''), ctrl)
    v = last(ctrl.stack)
    @test v isa W.ChooseView && v.title == "Views"
    @test any(o -> o[2] === :save, v.options)          # the way out of the list
    v.onpick(Dict("state" => "all", "kind" => "issue"))
    @test st.filters.state === :all && st.filters.kind === :issue
    @test occursin("view:", st.status)

    # Writing one down is a paste, not a write: config.toml is the user's file.
    # What it prints parses back into the filter it came from, which is the only
    # property worth having of it.
    v.onpick(:save)
    pv = last(ctrl.stack)
    @test pv isa W.PromptView
    pv.onsubmit("mine, quiet")
    @test occursin("paste it into config.toml", st.status)
    pop!(ctrl.stack)
    toml = W.view_toml(st.filters, st.sort, "issues, all of them")
    parsed = W.TOML.parse(toml)["views"]["issues, all of them"]
    st2 = mkstate()
    W.apply_view!(st2, parsed)
    @test st2.filters.state === st.filters.state && st2.filters.kind === st.filters.kind
    st.filters.repos = Set(["a/b", "c/d"]); st.filters.authors = Set([W.AUTHOR_ME])
    round2 = W.TOML.parse(W.view_toml(st.filters, st.sort, "x"))["views"]["x"]
    W.apply_view!(st2, round2)
    @test st2.filters.repos == Set(["a/b", "c/d"])
    @test st2.filters.authors == Set([W.AUTHOR_ME])
end

@testset "a lane brings its order with it" begin
    # Not a preference, a definition: the `touched` lane *is* the interaction
    # clock - membership in it is having acted on something - so arriving in it
    # sorted by anything else asks the reader to press `w` to see what they came
    # for. Every other lane is deliberately absent from the table, which reads
    # as "as fetched", because which order those want is a question use has to
    # answer rather than one to argue about.
    @test W.lane_sort(:touched) === :touched
    @test W.lane_sort(:active) === :none && W.lane_sort(:unread) === :none

    st = mkstate()
    pick(name) = (st.frow = findfirst(r -> r[1] === :state && r[2] == name,
                                      W.filter_rows(st)); W.toggle_filter!(st))
    @test st.sort === :none
    pick("touched"); @test st.sort === :touched
    pick("active");  @test st.sort === :none
    # `w` overrides, and the override lasts until the lane changes - which is
    # the only rule here that can be said in one sentence.
    st.sort = :latest
    pick("unread"); @test st.sort === :none

    # A view naming a state gets that lane's order too, since it is clearing
    # every axis it does not name and the order is one of them.
    W.apply_view!(st, Dict("state" => "touched"))
    @test st.sort === :touched
    # ...unless the view says otherwise, which is what makes "as fetched"
    # nameable even where a lane would have implied an order.
    W.apply_view!(st, Dict("state" => "touched", "sort" => "none"))
    @test st.sort === :none
end

@testset "an answer to a key press outranks a standing line" begin
    # A live search wrote its own summary over the status row, so the answer to
    # a key press - "`claude` is not on PATH" - never appeared, and the key
    # looked broken rather than refused. A search is standing information, and
    # is re-derived every frame; a message is something that just happened.
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    st.search = "the"; st.searchin = :list; W.refilter!(st)
    foot() = W.astrip(last(split(W.render(st, 150, 40), "\n")))
    @test occursin("/the", foot()) && occursin("to search again", foot())
    st.status = "`claude` is not on PATH"
    @test occursin("claude", foot())
    # And the search line comes back when there is nothing to say, rather than
    # being lost for the rest of the session.
    st.status = ""
    @test occursin("/the", foot())
    # The keys row is still what shows with neither.
    st.search = ""
    @test occursin("T agent", foot())
end
