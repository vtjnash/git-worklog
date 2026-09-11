# The filter and view model, and the pane that shows it: what each axis lists,
# what the counts mean, and the ways back out of a filter.

@testset "axis counts match the brute-force ones" begin
    st = mkstate()
    # What the counts used to be computed by: one full pass per value, with one
    # axis replaced. Slow, obviously correct, and the thing to check against.
    brute(f, axis, v) = begin
        p = deepcopy(f)
        axis === :tag    ? (p.tags = Set([v])) :
        axis === :kind   ? (p.kind = v) :
        axis === :bucket ? (p.buckets = Set([v])) :
        axis === :repo   ? (p.repos = Set([v])) :
        axis === :author ? (p.authors = Set([v])) : (p.labels = Set([v]))
        # The same marks the counts are computed against, or the two sides are
        # answering about different lists: `archived` and `drafts` are
        # membership in a file, and an empty one here would make every count of
        # them zero and the comparison vacuous.
        count(it -> W.matches(p, it, W.Marks(st)), st.all)
    end
    # The disposition boxes are not a tally of values but a delta: what each one
    # is holding in, or would bring in. So the slow way to say it is the two
    # filters either side of the box, counted whole.
    brute_show(f, v) = begin
        on, off = deepcopy(f), deepcopy(f)
        push!(on.show, v); delete!(off.show, v)
        count(it -> W.matches(on, it, W.Marks(st)) &&
                    !W.matches(off, it, W.Marks(st)), st.all)
    end
    configs = [W.Filters(),                      # the base box alone
               W.DEFAULT_FILTERS(),              # which is what it opens on
               W.everything(),                   # and all five boxes on
               W.Filters(show = Set{Symbol}()),  # and none of them: no rows
               W.Filters(show = Set([:base, :read])),
               W.Filters(show = Set([:read])),   # the read ones instead
               W.Filters(show = Set([:snoozed, :filed])),
               W.Filters(show = Set([:done])),
               W.Filters(tags = Set([:second])),
               W.Filters(tags = Set([:second, :touched, :drafts])),
               W.Filters(buckets = Set(["needs-review"])),
               W.Filters(repos = Set(["JuliaLang/julia"]), show = Set([:read])),
               W.Filters(buckets = Set(["issue"]), repos = Set(["JuliaLang/julia"]),
                         labels = Set(["docs"])),
               W.Filters(kind = :issue),
               W.Filters(repos = Set(["JuliaLang/julia"]), kind = :pr),
               W.Filters(authors = Set([W.AUTHOR_ME])),
               W.Filters(authors = Set([W.AUTHOR_OTHERS, "Keno"])),
               W.Filters(show = Set([:read, :done]), kind = :pr,
                         authors = Set([W.AUTHOR_ME]))]
    for f in configs
        st.filters = f
        n = W.axis_counts(st)
        for (k, _) in W.SHOW
            @test get(n.shows, k, 0) == brute_show(f, k)
        end
        for (k, _) in W.TAGS
            @test get(n.tags, k, 0) == brute(f, :tag, k)
        end
        for (k, _) in W.KINDS
            @test get(n.kinds, k, 0) == brute(f, :kind, k)
        end
        for v in st.buckets;  @test get(n.buckets, v, 0) == brute(f, :bucket, v); end
        for v in first(st.repos, 12);  @test get(n.repos, v, 0) == brute(f, :repo, v); end
        for v in first(st.labels, 12); @test get(n.labels, v, 0) == brute(f, :label, v); end
        for v in first(st.authors, 12); @test get(n.authors, v, 0) == brute(f, :author, v); end
    end

    # Three values and no fourth: both is the whole list, and the other two
    # partition it.
    st.filters = W.everything()
    both = length(W.apply_filters(st.filters, st.all))
    st.filters.kind = :pr;    prs = length(W.apply_filters(st.filters, st.all))
    st.filters.kind = :issue; iss = length(W.apply_filters(st.filters, st.all))
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
    st.filters = W.Filters(tags = Set([:drafts]))
    W.refilter!(st)
    @test [x.url for x in st.items] == [it.url]
    # Counted like every other value on the axis, and offered as a row.
    @test get(W.axis_counts(st).tags, :drafts, 0) == 1
    @test any(r -> r[1] === :tag && r[2] == "drafts", W.filter_rows(st))
    # Filed work carries it too, and that is the point: a draft on something you
    # have put away is the strongest reason there is to be shown it again - the
    # two together mean the work was filed and the words were never sent. The
    # tag is its own axis, so nothing about sleep can take it away.
    @test :drafts in W.tags_of(it, W.Marks(archived = Dict(it.url => "forever"),
                                           drafts = Dict(it.url => "2026-01-01")))
    # Sent or thrown away, it leaves the lane.
    W.undraft!(it.url)
    W.refilter!(st)
    @test isempty(st.items) && isempty(W.load_drafts())
end

@testset "where an item stands, on three axes that do not overrule each other" begin
    # Built here rather than taken from the dashboard so that every branch is
    # reachable: the real corpus has nothing filed away today.
    mk(; kw...) = W.Item(; url = "https://github.com/o/r/pull/1", ref = "r#1",
                         repo = "o/r", number = 1, title = "t",
                         updated = "2026-09-02T00:00:00Z", kw...)
    it = mk()
    seen(at) = W.Marks(read = Dict(it.url => at))
    filed = W.Marks(archived = Dict(it.url => "forever"))

    # Seen: the stamp against `updated`. No stamp at all is unread - never
    # having looked and having looked before it moved are the same answer to
    # "have you seen what it says now".
    @test W.seen_of(it) === :unread
    @test W.seen_of(it, seen("2026-09-01T00:00:00Z")) === :unread
    @test W.seen_of(it, seen("2026-09-02T00:00:00Z")) === :read
    @test W.seen_of(it, seen("2026-09-09T00:00:00Z")) === :read
    # A synthetic item - an adopted branch, an import no refresh has caught up
    # with - has no `updated` at all, and a stamp on one is the only thing
    # anybody has said about whether it has been seen.
    @test W.seen_of(mk(updated = "")) === :unread
    @test W.seen_of(mk(updated = ""), seen("2026-09-01T00:00:00Z")) === :read

    # **Nothing overrides it.** A snooze and a filing are answers to "do I want
    # to see this"; they say nothing about whether it has changed, and this is
    # the correction the whole model turns on.
    @test W.seen_of(mk(snoozed = true)) === :unread
    @test W.seen_of(mk(snoozed = true), filed) === :unread
    @test W.seen_of(mk(snoozed = true), seen("2026-09-09T00:00:00Z")) === :read

    # Sleep: one decision, three readings, and filed is the snooze that never
    # wakes - so it wins over the snooze bit that is set alongside it.
    @test W.sleep_of(it) === :awake
    @test W.sleep_of(mk(snoozed = true)) === :snoozed
    @test W.sleep_of(mk(snoozed = true), filed) === :filed
    @test W.sleep_of(it, filed) === :filed

    # Over: GitHub's, and empty reads as open.
    @test W.over_of(it) === :open
    @test W.over_of(mk(state = "OPEN")) === :open
    @test W.over_of(mk(state = "MERGED")) === :done
    @test W.over_of(mk(state = "CLOSED")) === :done

    # Tags: several at once, or none, which is why they are not an axis of the
    # kind above.
    @test isempty(W.tags_of(it))
    @test W.tags_of(mk(secondlook = "quiet 3 days")) == [:second]
    @test Set(W.tags_of(mk(secondlook = "q"),
                        W.Marks(touched = Dict(it.url => "2026-01-01"),
                                drafts = Dict(it.url => "2026-01-01")))) ==
          Set([:second, :touched, :drafts])

    # The three readings still partition the corpus, which is what the merged
    # axis is built out of: one answer each, per row, however it is shown.
    st = mkstate()
    st.filters = W.everything(); W.refilter!(st)
    m = W.Marks(st)
    for reading in (x -> W.seen_of(x, m), x -> W.sleep_of(x, m), W.over_of)
        @test sum(count(x -> reading(x) === v, st.items)
                  for v in Set(reading(x) for x in st.items)) == length(st.items)
    end
    # And the five boxes cover the corpus between them: every row answers to at
    # least one, so all five on is everything and taking any one off can only
    # lose rows. Four of them can only ever lose rows the base did not have -
    # and the fifth *is* the base, which is the one that can drop below the list
    # the browser opens on, and drops to exactly the rest of the corpus.
    base = length(W.apply_filters(W.Filters(), st.all, m))
    @test 0 < base < length(st.all)
    @test length(W.apply_filters(W.everything(), st.all, m)) == length(st.all)
    for (k, _) in W.SHOW
        f = W.everything(); delete!(f.show, k)
        n = length(W.apply_filters(f, st.all, m))
        @test n <= length(st.all)
        @test k === :base ? n == length(st.all) - base : n >= base
    end
end

@testset "one axis that only adds, and a base you have to mean to take off" begin
    st = mkstate()
    st.filters = W.Filters(); W.refilter!(st)
    base = length(st.items)
    # Bare is the base box alone, which is also what the browser opens on:
    # unread, awake and open, with nothing narrowing it. `c` goes here too - the
    # list this program is for is what a filter says when it has been asked
    # nothing, rather than one of the things it can be asked for.
    @test W.isdefault(st.filters)
    @test W.isdefault(W.DEFAULT_FILTERS())
    @test st.filters.show == W.SHOW_BASE
    @test occursin("unread, awake, open", W.filter_summary(st.filters))
    @test all(x -> W.seen_of(x, W.Marks(st)) === :unread &&
                   W.sleep_of(x, W.Marks(st)) === :awake &&
                   W.over_of(x) === :open, st.items)

    # Each box brings its own kind of row beside the base, and no box can take
    # another one's rows away: that is the whole of what "only adds" means.
    counts = Dict{Symbol,Int}()
    for (k, _) in W.SHOW
        k === :base && continue
        st.filters = W.Filters(show = Set([:base, k])); W.refilter!(st)
        counts[k] = length(st.items) - base
        @test length(st.items) >= base
    end
    # Two of them is at least the union of what each brings, and more where a
    # row needed both - a closed item you have read is held out twice.
    st.filters = W.Filters(show = Set([:base, :read, :done])); W.refilter!(st)
    @test length(st.items) >= base + counts[:read] + counts[:done]
    # All five is the corpus, and the corpus is the only thing that is.
    st.filters = W.everything(); W.refilter!(st)
    @test length(st.items) == length(st.all)

    # Taking the base off is how one of the other four is asked for *alone* -
    # the closed ones instead of today's work rather than beside it. It is the
    # one question the axis could not be asked while the base was a floor, and
    # it takes a deliberate press to ask: nothing clears to here.
    #
    # A box alone holds exactly what it adds beside the base, which is the same
    # rows either way - the base is what it is *added to*, not a condition on
    # what it brings - and none of what it holds is base work.
    for (k, _) in W.SHOW
        k === :base && continue
        st.filters = W.Filters(show = Set([k])); W.refilter!(st)
        @test length(st.items) == counts[k]
        @test !any(x -> W.seen_of(x, W.Marks(st)) === :unread &&
                        W.sleep_of(x, W.Marks(st)) === :awake &&
                        W.over_of(x) === :open, st.items)
    end
    # The one of the four this dashboard has rows for today, said in full.
    st.filters = W.Filters(show = Set([:done])); W.refilter!(st)
    @test 0 < length(st.items) < length(st.all)
    @test all(x -> W.over_of(x) === :done, st.items)
    @test occursin("only closed or merged", W.filter_summary(st.filters))
    # The base box holds exactly the base list in, so taking it off the corpus
    # leaves the rest of the corpus and nothing else.
    nobase = W.everything(); delete!(nobase.show, :base)
    st.filters = nobase; W.refilter!(st)
    @test length(st.items) == length(st.all) - base
    # And every box off is an empty list. That is the honest reading of an axis
    # that adds rather than narrows, and not a case to special-case: an empty
    # set of things to show is no things.
    st.filters = W.Filters(show = Set{Symbol}()); W.refilter!(st)
    @test isempty(st.items)
    @test occursin("nothing shown", W.filter_summary(st.filters))

    # Toggled by the same key that toggles every other axis, and off again.
    st.filters = W.Filters(); W.refilter!(st)
    st.lmode = :filters
    rows = W.filter_rows(st)
    @test [r[2] for r in rows if r[1] === :show] == [String(k) for (k, _) in W.SHOW]
    # The base leads the axis as a row like the other four, checked, with the
    # number it is holding in beside it - which is what unchecking it would cost.
    brow = first(r for r in rows if r[1] === :show)
    @test brow[2] == "base"
    @test occursin("[x] ", brow[3]) && occursin(string(base), brow[3])
    st.frow = findfirst(r -> r[1] === :show && r[2] == "snoozed", rows)
    @test W.toggle_filter!(st)
    @test st.filters.show == Set([:base, :snoozed])
    @test length(st.items) == base + counts[:snoozed]
    @test occursin("[x] ", first(r[3] for r in W.filter_rows(st) if r[2] == "snoozed"))
    @test W.toggle_filter!(st)
    @test st.filters.show == W.SHOW_BASE && length(st.items) == base
    # Including the base itself, which is the one row here whose being checked
    # is a default rather than a choice - and `c` is what puts it back.
    st.frow = findfirst(r -> r[1] === :show && r[2] == "base", W.filter_rows(st))
    @test W.toggle_filter!(st)
    @test isempty(st.filters.show) && isempty(st.items) && !W.isdefault(st.filters)

    # What the browser opens on says itself, and what has been added to it says
    # that instead - the base is true of almost every screen there is, so naming
    # it on each one is a phrase the reader stops seeing. Off, it is the most
    # important thing on the screen and is said first.
    @test occursin("unread, awake, open", W.filter_summary(W.DEFAULT_FILTERS()))
    @test occursin("also read+snoozed",
                   W.filter_summary(W.Filters(show = Set([:base, :read, :snoozed]))))
    @test occursin("only filed away", W.filter_summary(W.Filters(show = Set([:filed]))))
    @test occursin("nothing shown", W.filter_summary(W.Filters(show = Set{Symbol}())))
    # And it writes itself as a view, in the axis's own order. The base is left
    # out of the TOML while it is on, because that is what a view naming no
    # `show` gets anyway - and `show = []` is written, because an empty axis is
    # a real filter here rather than an unasked question.
    @test occursin("show = [\"base\", \"read\", \"filed\"]",
                   W.view_toml(W.Filters(show = Set([:filed, :read, :base])), :latest, "x"))
    @test occursin("show = [\"read\", \"filed\"]",
                   W.view_toml(W.Filters(show = Set([:filed, :read])), :latest, "x"))
    @test occursin("show = []", W.view_toml(W.Filters(show = Set{Symbol}()), :latest, "x"))
    @test !occursin("show", W.view_toml(W.DEFAULT_FILTERS(), :latest, "x"))
    # A view names the axes, and a misspelt value is said rather than ignored.
    @test occursin("only read", W.apply_view!(st, Dict("show" => ["read"])))
    @test st.filters.show == Set([:read])
    # Named means named *whole*: a view that wants the base beside what it adds
    # says so, and one that names no `show` at all keeps the default.
    @test occursin("also read", W.apply_view!(st, Dict("show" => ["base", "read"])))
    @test st.filters.show == Set([:base, :read])
    @test W.apply_view!(st, Dict("kind" => "pr")) isa String
    @test st.filters.show == W.SHOW_BASE
    @test occursin("no show", W.apply_view!(st, Dict("show" => "raed")))
    @test occursin("no show", W.apply_view!(st, Dict("show" => ["read", "asleep"])))
    # So is an axis that is not one either, which the three keys this one
    # replaced would otherwise have become: a view still spelling `sleep` would
    # have gone on being applied and meant something else.
    @test occursin("no axis 'sleep'", W.apply_view!(st, Dict("sleep" => ["awake"])))
    @test occursin("no axis 'seen'", W.apply_view!(st, Dict("seen" => ["unread"])))
    @test W.isdefault(st.filters)
end

@testset "when a row leaves, the cursor stays where it was" begin
    # `r` in the base list takes the row it marks read out of it, and a
    # cursor thrown to the top by that turns reading an inbox into: r, scroll
    # back down, r, scroll back down. The url it was on is gone, so the fallback
    # is the row - whatever moved up into the place being read.
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        st = mkstate()
        st.filters = W.Filters()
        W.refilter!(st; keeprow = false)
        five = [it.url for it in first(st.items, 5)]
        # Everything else read, in one write: the axis is the stamp against
        # `updated`, so this is what having looked at the rest amounts to.
        W.mark_read([it.url for it in st.all if !(it.url in five)], W.utcnow())
        W.refilter!(st; keeprow = false)
        @test length(st.items) == 5 && st.sel == 1
        st.sel = 3
        gone = st.items[3].url
        W.mark_read([gone], W.utcnow())     # what `r` does before it refilters
        W.refilter!(st)
        @test length(st.items) == 4
        @test st.sel == 3 && st.items[3].url != gone
        # Clamped, so the last row of a selection leaving lands on the new last
        # row rather than off the end of it.
        st.sel = 4
        W.mark_read([st.items[4].url], W.utcnow())
        W.refilter!(st)
        @test st.sel == length(st.items) == 3
    finally
        W.LOCAL[] = keep
    end
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
    nb = W.axis_counts(st).buckets
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
    st2.filters = W.Filters(); W.refilter!(st2)
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
    @test isempty(st2.filters.authors) && W.isdefault(st2.filters)
end

@testset "the row that clears every filter" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    st.lmode = :filters; st.focus = :list
    ctrl = W.Controller(); ctrl.running = true; push!(ctrl.stack, st)

    # `c` has always done this and nothing on screen said so.
    @test W.isdefault(W.Filters())
    # ...and it lands where the browser opens, which is the same place now: the
    # unread, awake and open list is what is left when every filter is off.
    @test W.isdefault(W.DEFAULT_FILTERS())
    # The corpus is a filter now rather than the absence of one, so `c` does not
    # reach it and the four boxes are the way there.
    @test !W.isdefault(W.everything())
    st.filters = W.Filters(); W.refilter!(st)
    rows = W.filter_rows(st)
    @test rows[1][1] === :reset
    @test occursin("clear every filter", W.astrip(W.render(st, 160, 50)))
    # Nothing to clear, so the row says only what it is - and refuses, rather
    # than spending the one `\`` slot on a move that changed nothing.
    st.frow = 1
    @test W.toggle_filter!(st, ctrl) === false
    @test st.prev === nothing

    st.filters.labels = Set(["docs"]); st.filters.kind = :issue
    W.refilter!(st)
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
    # reset, then show, tag, kind, category, repo, label, author
    @test length(g) == 8
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
              "q quit", "tab pane", "C comment", "A review", "M merge", "L labels",
              "r read/unread", "u update all", "R reload", "s snooze", "z undo",
              "v note", "e edit", "\u21e7j/k select",
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
    # Bare, so no other axis rejects the sample before the labels are read.
    f = W.Filters()
    it = st.all[findfirst(x -> !isempty(x.labels), st.all)]
    push!(f.labels, first(it.labels))
    @test W.matches(f, it)
    other = st.all[findfirst(x -> isempty(x.labels), st.all)]
    @test !W.matches(f, other)
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
    # Except the first, which is the way back to what the browser opens on and
    # leads for the same reason the import row leads the item list.
    @test occursin("notification firehose", first(names))
    # And the corpus has a name of its own, which is where it went when `c`
    # stopped reaching it.
    @test any(n -> occursin("everything", n), names)
    # config.toml adds to them, and replaces one of the same name rather than
    # listing it twice.
    cfg = Dict{String,Any}("views" => Dict{String,Any}(
        "mine, all of it" => Dict("author" => ["@me"]),
        "waiting on me" => Dict("show" => ["snoozed"])))
    vs = W.views(cfg)
    @test length(vs) == length(names) + 1
    @test Dict(vs)["waiting on me"]["show"] == ["snoozed"]

    # A view sets every axis it names and clears every axis it does not: half a
    # remembered filter is worse than none.
    st.filters.labels = Set(["docs"]); st.filters.kind = :issue
    W.apply_view!(st, Dict("bucket" => ["needs-review"]))
    @test st.filters.buckets == Set(["needs-review"])
    @test isempty(st.filters.labels) && st.filters.kind === :both
    # "Cleared" is what the axis says when it is asked nothing, which on `show`
    # is the base box rather than the empty set: a view that names no `show` is
    # a view of today's work, and an empty one would be a view of nothing.
    @test st.filters.show == W.SHOW_BASE
    # A single value is as good as a list of one, on every axis.
    W.apply_view!(st, Dict("repo" => "JuliaLang/julia", "show" => "read"))
    @test st.filters.repos == Set(["JuliaLang/julia"])
    @test st.filters.show == Set([:read])

    # The sort is an axis like the rest: a view that names one sets it, and a
    # view that names none puts it back to the order its lane opens in - newest
    # first, unless the lane defines its own. A name has to mean the same list
    # from wherever it is pressed, and an order carried over from the list you
    # were in is not that.
    W.apply_view!(st, Dict("sort" => "none"))
    @test st.sort === :none
    W.apply_view!(st, Dict("show" => ["read"]))
    @test st.sort === :latest
    W.apply_view!(st, Dict("tag" => ["touched"]))
    @test st.sort === :touched          # the selection that *is* the clock

    # And the first view is the whole of what the browser opens on, sort
    # included.
    st.sort = :touched; st.filters.labels = Set(["docs"])
    W.apply_view!(st, last(first(W.views(Dict{String,Any}()))))
    @test W.isdefault(st.filters)
    @test isempty(st.filters.labels) && st.sort === :latest

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
    v.onpick(Dict("show" => ["snoozed"], "kind" => "issue"))
    @test st.filters.show == Set([:snoozed]) && st.filters.kind === :issue
    @test occursin("view:", st.status)

    # The first ten are on keys of their own: the same ten in the same order
    # every time is a list reached by memory, and arrow-and-return is the slow
    # way to press something whose position you already know. `2` is the second
    # of them, `0` the tenth, and nothing else in the program numbers a picker.
    @test v.numbered
    box = W.astrip(W.render(v, 160, 50))
    @test occursin(string("1  ", v.options[1][1]), box)
    @test occursin(string("2  ", v.options[2][1]), box)
    @test occursin("0-9 picks", box)
    # Ten of them: `0` is the tenth, where a decade of terminals put it, and the
    # eleventh keeps the column without a key.
    ten = W.ChooseView("t", "", Tuple{String,Any}[(string("row ", i), i) for i in 1:11],
                       identity; numbered = true)
    tbox = W.astrip(W.render(ten, 160, 50))
    @test occursin("9  row 9", tbox) && occursin("0  row 10", tbox)
    @test occursin("   row 11", tbox)
    got = Ref(0); ten.onpick = x -> (got[] = x)
    @test W.handle!(ten, Int('0'), ctrl) === :pop && got[] == 10
    st.filters = W.Filters()
    W.handle!(st, Int('\''), ctrl)
    v2 = last(ctrl.stack)
    @test W.handle!(v2, Int('2'), ctrl) === :pop       # picks, and closes
    picked = W.filter_summary(st.filters, st.sort)
    W.apply_view!(st, v2.options[2][2])
    @test W.filter_summary(st.filters, st.sort) == picked
    pop!(ctrl.stack)
    # A digit past the end of the list picks nothing rather than the last row.
    v3 = W.ChooseView("t", "", Tuple{String,Any}[("one", 1)], identity; numbered = true)
    @test W.handle!(v3, Int('5'), ctrl) === :ok
    # And an unnumbered picker takes digits as a query, the way it always has.
    v4 = W.ChooseView("t", "", Tuple{String,Any}[("one", 1)], identity)
    W.handle!(v4, Int('5'), ctrl)
    @test v4.query == "5"

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
    @test st2.filters.show == st.filters.show && st2.filters.kind === st.filters.kind
    @test st2.filters.tags == st.filters.tags
    st.filters.repos = Set(["a/b", "c/d"]); st.filters.authors = Set([W.AUTHOR_ME])
    round2 = W.TOML.parse(W.view_toml(st.filters, st.sort, "x"))["views"]["x"]
    W.apply_view!(st2, round2)
    @test st2.filters.repos == Set(["a/b", "c/d"])
    @test st2.filters.authors == Set([W.AUTHOR_ME])
end

@testset "a selection brings its order with it" begin
    # Not a preference, a definition: the `touched` tag *is* the interaction
    # clock - carrying it is having acted on something - so arriving in it
    # sorted by anything else asks the reader to press `w` to see what they came
    # for. Every other selection reads as newest first, which is the order every
    # other inbox opens in and the answer use gave to the question this used to
    # leave open.
    @test W.lane_sort(W.Filters(tags = Set([:touched]))) === :touched
    @test W.lane_sort(W.Filters()) === :latest
    @test W.lane_sort(W.DEFAULT_FILTERS()) === :latest
    # The clock is the order of the clock *alone*: crossed with anything else it
    # is one axis of several and has no claim on how the list is read.
    @test W.lane_sort(W.Filters(tags = Set([:touched, :drafts]))) === :latest

    st = mkstate()
    pick(axis, name) = (st.frow = findfirst(r -> r[1] === axis && r[2] == name,
                                            W.filter_rows(st)); W.toggle_filter!(st))
    st.filters = W.Filters(); W.refilter!(st)
    @test st.sort === :latest
    pick(:tag, "touched"); @test st.sort === :touched
    pick(:tag, "touched"); @test st.sort === :latest      # and off again
    # `w` overrides, and the override lasts until the selection changes - which
    # is the only rule here that can be said in one sentence.
    st.sort = :none
    pick(:show, "read"); @test st.sort === :latest

    # A view naming the clock gets its order too, since it is clearing every
    # axis it does not name and the order is one of them.
    W.apply_view!(st, Dict("tag" => ["touched"]))
    @test st.sort === :touched
    # ...unless the view says otherwise, which is what makes the url order
    # nameable even where a selection would have implied an order.
    W.apply_view!(st, Dict("tag" => ["touched"], "sort" => "none"))
    @test st.sort === :none
    # And the summary names an order only when it is not the selection's own: the
    # default said on every screen is a phrase the reader stops seeing, and
    # three words the keys row would rather have.
    @test !occursin("by when", W.filter_summary(W.Filters(), :latest))
    @test occursin("by url", W.filter_summary(W.Filters(), :none))
    @test occursin("by when you acted", W.filter_summary(W.Filters(), :touched))
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
    # The keys row is still what shows with neither. Asserted on a key from the
    # middle of it rather than the end: both rows are longer than 150 columns
    # and `afit` cuts them, so what is at the end is a fact about this width
    # rather than about which row is being drawn.
    st.search = ""
    @test occursin("x archive", foot())
end
