# The real dashboard, swept - the one testset that still reads `data/`.
#
# The suite runs on `fixture.json`, because a testset that wants *a row with a
# property* wants a fixture whether or not it is written as one, and hunting the
# live corpus for one makes an undeclared precondition out of a fact about
# somebody's inbox that day. What the live corpus is still worth is the other
# thing entirely: **2000 rows nobody invented**. A husk the bulk lanes returned
# with no `state` and no `branch`, a `null` review decision, a deleted author, a
# title with a code span in it, a milestone with no due date - the shapes that
# break `nz` and `first` are the ones nobody would think to write down, which is
# the whole of the argument for the old arrangement and all that is left of it.
#
# So this asserts over **every row**, and never picks one out. A testset that
# needs a particular row belongs beside the others, on the fixture.
#
# **It skips itself when there is no dashboard here.** A fresh clone has no
# `data/` at all - `fetched.json` is untracked, being megabytes that churn on
# every refresh - and a corpus nobody has fetched is not a failure. Skip, never
# fail: a failure would take down every file after this one.

@testset "the real dashboard is survivable" begin
    if !isfile(REAL_FETCHED)
        @info "no data/fetched.json here, so the corpus sweep is skipped"
        @test_skip isfile(REAL_FETCHED)
    else
        keep = W.FETCHED[]
        W.FETCHED[] = REAL_FETCHED
        try
            all_ = W.loaditems()
            @test length(all_) > 100          # a dashboard, not a stub
            # Every row becomes an `Item` with the two fields everything else
            # indexes it by. `item_of` is total or this throws above.
            @test all(!isempty(it.url) && !isempty(it.ref) for it in all_)

            st = W.BState(all_, "corpus", Set{String}())
            m = W.Marks(st)
            # The axes are total: every row has an answer on each of them, and
            # no row is left out of the merged one when all four boxes are on.
            @test all(W.seen_of(it, m) in (:unread, :read) for it in all_)
            @test all(W.filed_of(it, m) isa Bool for it in all_)
            @test all(W.over_of(it) in (:open, :done) for it in all_)
            @test all(W.tags_of(it, m) ⊆ [:reply, :second, :touched, :drafts, :snoozed] for it in all_)
            st.filters = W.everything(); W.refilter!(st)
            @test length(st.items) == length(all_)

            # The list draws, at the three shapes the panes take, with the
            # cursor at each end of it and in the middle - which is what decides
            # which rows are on screen.
            for (w, h) in ((80, 24), (150, 40), (300, 60)),
                sel in (1, length(st.items) ÷ 2, length(st.items))
                st.sel = sel
                ls = split(W.render(st, w, h), "\n")
                @test length(ls) == h && all(W.awidth(l) == w for l in ls)
            end

            # And the metadata pane draws for **every** row, which is where a
            # husk tells: the fields it has not got are read here by name.
            st.sel = 1
            @test all(all(W.awidth(l) <= 60 for l in W.meta_lines(st, it, 60))
                      for it in all_)
        finally
            W.FETCHED[] = keep
        end
    end
end
