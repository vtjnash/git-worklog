# What can be tested without a terminal.
#
# There is no TTY here, so the UI is verified by construction: `readevent` is a
# pure function of a byte stream, `render` is a pure function of state and a
# size, and `handle!`/`onmouse!` take an event and return an action. Between
# them that covers everything except whether a real terminal sends the bytes
# these tests feed it.
#
#     julia --project=cli cli/test/runtests.jl

using Test
using Worklog
const W = Worklog

@testset "input decoding" begin
    ev(s) = W.readevent(IOBuffer(s))
    @test ev("j") == W.KeyEvent(Int('j'))
    @test ev("\e") == W.KeyEvent(27)                 # bare escape
    @test ev("\e[A") == W.KeyEvent(W.K_UP)
    @test ev("\e[B") == W.KeyEvent(W.K_DOWN)
    @test ev("\eOA") == W.KeyEvent(W.K_UP)           # application cursor mode
    @test ev("\e[5~") == W.KeyEvent(W.K_PGUP)
    @test ev("\e[6~") == W.KeyEvent(W.K_PGDN)
    @test ev("\e[6;5~") == W.KeyEvent(W.K_PGDN)      # modified page-down
    @test ev("\e[Z") == W.KeyEvent(W.K_STAB)         # shift-tab
    @test ev("\e[3~") == W.KeyEvent(W.K_DEL)
    @test ev("\e[200~") == W.KeyEvent(-1)            # unknown, but consumed

    # A sequence must not leave its tail behind to arrive as keystrokes.
    io = IOBuffer("\e[Zq")
    @test W.readevent(io) == W.KeyEvent(W.K_STAB)
    @test W.readevent(io) == W.KeyEvent(Int('q'))

    m = ev("\e[<0;40;12M")
    @test m isa W.MouseEvent && m.kind === :press && m.x == 40 && m.y == 12
    @test ev("\e[<0;40;12m").kind === :release
    @test ev("\e[<32;40;12M").kind === :drag         # button 0 + motion
    @test ev("\e[<64;5;5M").kind === :wheelup
    @test ev("\e[<65;5;5M").kind === :wheeldown
    @test ev("\e[<16;5;5M").mods == 4                # ctrl-click
    @test ev("\e[<0;40M") == W.KeyEvent(-1)          # malformed
end

# The list pane is populated from the real snapshot: what matters here is the
# geometry, and a hand-built item list would not exercise the widths that
# actual titles do.
@testset "details blocks fold to their summary" begin
    seg(md) = [(k, sm) for (k, sm, _) in W.split_details(md)]
    @test seg("just prose") == [(:text, "")]
    @test seg("a<details><summary>S</summary>x</details>b") ==
          [(:text, ""), (:details, "S"), (:text, "")]
    # Nesting: a lazy regex would close the outer block at the inner one's end.
    outer = W.split_details("<details><summary>out</summary>p<details><summary>in</summary>q</details>r</details>")
    @test length(outer) == 1 && outer[1][2] == "out"
    @test occursin("<summary>in</summary>", outer[1][3])
    @test seg("<details>bare</details>") == [(:details, "details")]
    @test W.split_details("<details open><summary><b>A &amp; B</b></summary>x</details>")[1][2] == "A & B"
    # Unbalanced: leave it as prose rather than guess where it ends.
    @test seg("t <details><summary>never closed</summary> tail") == [(:text, "")]

    ns = W.body_nodes("alice", "before\n\n<details><summary>Impacted</summary>\nrows\n</details>\n\nafter",
                      "http://x", true)
    @test [(n.depth, n.open, n.header) for n in ns] ==
          [(0, true, "alice"), (1, false, "Impacted"), (0, true, "…")]
    @test ns[1].raw == "before" && ns[3].raw == "after"
    # A folded block costs one row until it is opened: three headers plus one
    # body row each for the prose either side of it.
    @test length(W.rows(ns, 80)) == 5
    ns[2].open = true
    @test length(W.rows(ns, 80)) > 5
end

items = W.loaditems()
mkstate() = begin
    st = W.BState(items, "worklog", Set{String}())
    st.nodes = [W.Node("alice  2026-08-01   first", "A paragraph long enough that it has to be wrapped across several rows of the detail pane, which is exactly the case a copy must undo.\n\nsecond para", :md, true),
                W.Node("bob  2026-08-02   second", "short", :md, true)]
    st.loaded = string(st.items[st.sel].url, ":", st.mode)   # suppress the fetch
    st
end

@testset "frame geometry" begin
    for (w, h) in ((80, 24), (110, 40), (160, 50), (100, 12), (200, 60), (72, 8))
        st = mkstate()
        f = W.render(st, w, h)
        ls = split(f, "\n")
        @test length(ls) == h
        @test all(W.awidth(l) == w for l in ls)
    end
end

@testset "click maps to the row under it" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    W.render(st, 160, 50)
    L = W.layout(160, 50, st.nmeta)
    ctrl = W.Controller()

    # A click on the list pane's third content row selects the third item.
    press(x, y) = W.onmouse!(st, W.MouseEvent(:press, 0, x, y, 0), ctrl)
    press(L.lx + 3, L.ly + 3)
    @test st.focus === :list && st.sel == st.top + 2

    # Clicking the detail pane's first content row lands on the first title row,
    # which is header, not content - so nrow stays put and focus moves.
    st2 = mkstate()
    W.render(st2, 160, 50)
    L = W.layout(160, 50, st2.nmeta)
    press2(x, y) = W.onmouse!(st2, W.MouseEvent(:press, 0, x, y, 0), ctrl)
    press2(L.rx + 10, L.ry + 1 + st2.hdr)          # first node row (its header)
    @test st2.focus === :detail && st2.nrow == 1

    # Column 1-2 of a header row is the fold marker.
    @test st2.nodes[1].open
    press2(L.rx + 2, L.ry + 1 + st2.hdr)
    @test !st2.nodes[1].open
    press2(L.rx + 2, L.ry + 1 + st2.hdr)
    @test st2.nodes[1].open

    # Clicking past the end of the content, or on a border, changes nothing.
    W.render(st2, 160, 50)
    before = (st2.nrow, st2.sel, st2.focus)
    press2(L.rx + 10, L.ry + L.rh - 3)      # blank rows below the last node
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx, L.ry + 4)                  # the pane border
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx + 10, 1)                    # the title bar
    @test (st2.nrow, st2.sel, st2.focus) == before
    press2(L.rx + 10, 50)                   # the footer
    @test (st2.nrow, st2.sel, st2.focus) == before
end

@testset "drag selects, and the copy is unwrapped" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    W.render(st, 160, 50)
    L = W.layout(160, 50, st.nmeta)
    ctrl = W.Controller()
    y0 = L.ry + 1 + st.hdr
    W.onmouse!(st, W.MouseEvent(:press, 0, L.rx + 10, y0 + 1, 0), ctrl)
    W.onmouse!(st, W.MouseEvent(:drag, 0, L.rx + 10, y0 + 3, 0), ctrl)
    W.onmouse!(st, W.MouseEvent(:release, 0, L.rx + 10, y0 + 3, 0), ctrl)
    @test W.selrange(st) == (2, 4)

    txt = W.selection_text(st, L.riw)
    @test !isempty(txt)
    @test !occursin('\e', txt)                       # no escapes in the paste
    # The wrapped paragraph comes back as the one line it was written as.
    @test occursin("A paragraph long enough that it has to be wrapped across several rows", txt)
    @test length(split(txt, "\n")) < 4               # fewer lines out than rows in

    # The selection survives a redraw and shows in the pane title.
    f = W.render(st, 160, 50)
    @test occursin("3 selected", f)
    @test W.selrange(st) == (2, 4)

    # Moving the cursor drops it; y with nothing selected still copies a URL.
    W.handle!(st, Int('j'), ctrl)
    @test W.selrange(st) === nothing
end

@testset "the metadata pane" begin
    st = mkstate()
    it = st.items[st.sel]
    lines = W.meta_lines(st, it, 44)
    plain = W.astrip(join(lines, "\n"))
    # Everything cheap comes from facts.json and is there before any fetch.
    @test occursin("tracking", plain)
    @test occursin(it.track, plain)
    isempty(it.labels) || @test occursin(first(it.labels), plain)
    isempty(it.author) || @test occursin(it.author, plain)
    # Per-person review state needs a request; until it lands, it says so.
    @test st.meta === nothing
    it.is_pr && @test occursin("reviews", plain)
    @test all(W.awidth(l) <= 44 for l in lines)

    # It sits under the list, and the detail keeps the full height.
    L = W.layout(160, 50, length(lines))
    @test L.ly + L.lh == L.my              # meta directly under the list
    @test L.mw == L.lw                     # same column
    @test L.rh == L.lh + L.mh              # detail spans both
    @test L.ry == 2                        # ...starting at the top
    # It grows with its content, and the list gives way.
    wide = W.layout(160, 50, 30)
    @test wide.mh > L.mh && wide.lh < L.lh
    # Stacked, it is dropped rather than squeezing what is being read.
    @test W.layout(80, 14).mh == 0
end

@testset "arrow keys and shift-tab" begin
    ENV["COLUMNS"], ENV["LINES"] = "160", "50"
    st = mkstate()
    ctrl = W.Controller()
    st.focus = :list
    W.handle!(st, W.K_DOWN, ctrl)
    @test st.sel == 2
    W.handle!(st, W.K_UP, ctrl)
    @test st.sel == 1

    # Detail pane: shift-tab cycles focus, and the arrows move by row. Fresh
    # state, because moving the list selection above started a fetch that
    # cleared the nodes - which is exactly what it should do.
    st = mkstate()
    W.handle!(st, W.K_STAB, ctrl)
    @test st.focus === :detail
    W.handle!(st, W.K_DOWN, ctrl)
    @test st.nrow == 2
    W.handle!(st, W.K_PGDN, ctrl)
    @test st.nrow == length(W.rows(st.nodes, W.layout(160, 50, st.nmeta).riw))
    W.handle!(st, W.K_HOME, ctrl)
    @test st.nrow == 1
end
