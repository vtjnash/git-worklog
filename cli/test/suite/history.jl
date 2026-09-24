@testset "` and ~ walk where the reader has been" begin
    st = mkstate()
    @test length(st.items) >= 4
    ref(i) = st.items[i].ref
    at(i) = (st.sel = i; st)
    W.note_place!(at(1), 0.0)
    @test isempty(st.back)
    # Passing a row on the way is not being somewhere: row 2 for a tenth of a
    # second is `j` held down, and only row 3, rested on, is kept on leaving.
    W.note_place!(at(2), 1.0)          # row 1, rested on
    W.note_place!(at(3), 1.1)          # row 2, passed
    W.note_place!(at(4), 2.0)          # row 3, rested on
    @test [s.url for s in st.back] == [st.items[1].url, st.items[3].url]

    # Back, back, and forward again, one spot at a time.
    @test W.step_place!(st, -1, 3.0) == string("back to ", ref(3))
    @test st.sel == 3
    @test W.step_place!(st, -1, 3.1) == string("back to ", ref(1))
    @test st.sel == 1
    @test W.step_place!(st, 1, 3.2) == string("forward to ", ref(3))
    @test st.sel == 3
    # Looking around the place `~` leaves from does not throw away the road
    # forward: `k` off the row `\`` went back to, and `~` still goes on.
    W.note_place!(at(2), 3.25)
    @test W.step_place!(st, 1, 3.3) == string("forward to ", ref(4))
    @test st.sel == 4
    @test W.step_place!(st, 1, 3.4) == "nowhere to go forward to"

    # A list is a place whatever row it was on, and going back to it brings
    # the filters, the order and the row back together.
    was = deepcopy(st.filters); row = st.items[st.sel].url
    st.filters.kind = st.items[st.sel].is_pr ? :issue : :pr
    W.refilter!(st; keeprow = false)
    W.note_place!(st, 3.41)            # at once: another list, kept anyway
    @test last(st.back).url == row
    r = W.step_place!(st, -1, 3.5)
    @test startswith(r, "back to ") && occursin(" in [", r)
    @test st.filters.kind === was.kind && st.items[st.sel].url == row
    # And a list asked for forks the road: nothing is forward of it.
    st.filters.kind = :pr; W.refilter!(st; keeprow = false)
    W.note_place!(st, 3.6)
    @test isempty(st.fwd)

    # A jump keeps the row it left however briefly it was on it, and the row
    # it went to - hidden by the filters, so the guest - comes back as the
    # guest when the filters still hide it.
    st = mkstate()
    st.filters.kind = :pr; W.refilter!(st; keeprow = false)
    hidden = findfirst(it -> !any(x -> x.url == it.url, st.items), st.all)
    @test hidden !== nothing
    W.note_place!(st, 0.0)
    from = st.items[st.sel].url
    @test W.select_item!(st, st.all[hidden]) == ""
    W.note_place!(st, 0.01)
    @test last(st.back).url == from
    W.note_place!(at(st.sel == 1 ? 2 : 1), 0.02)   # left at once; kept, a jump's
    @test last(st.back).url == st.all[hidden].url
    W.step_place!(st, -1, 0.03)
    @test st.items[st.sel].url == st.all[hidden].url && st.guest == st.all[hidden].url
    W.step_place!(st, -1, 0.04)
    @test st.items[st.sel].url == from && isempty(st.guest)

    # Each character typed into a search is a list, and none of them is kept:
    # the one worth going back to is the one before the query.
    st = mkstate()
    W.note_place!(st, 0.0)
    before = st.orderkey
    st.typing = true
    for q in ("a", "ab")
        st.search = q; W.refilter!(st; keeprow = false)
        W.note_place!(st, 1.0)
    end
    @test isempty(st.back)
    st.typing = false
    W.note_place!(st, 2.0)
    @test length(st.back) == 1 && last(st.back).key == before
    W.step_place!(st, -1, 3.0)
    @test isempty(st.search)

    # Through the keys, the same.
    ctrl = W.Controller()
    st = mkstate()
    @test (W.handle!(st, Int('`'), ctrl); st.status == "nowhere to go back to")
    @test (W.handle!(st, Int('~'), ctrl); st.status == "nowhere to go forward to")
end
