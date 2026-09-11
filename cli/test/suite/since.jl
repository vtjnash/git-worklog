# Showing *what* changed, not just that something did: the read mark as a
# record of where you were, the rule the thread opens under, and the diff
# between the head you saw and the head now.

@testset "the read mark carries the head it was made at" begin
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        u = "https://github.com/o/r/pull/1"
        @test W.read_at(u) === nothing && W.read_head(u) === nothing

        W.set_read_mark(u, "2026-09-01T00:00:00Z", "abc123")
        @test W.read_at(u) == "2026-09-01T00:00:00Z"
        @test W.read_head(u) == "abc123"

        # `wl read` over the whole lane knows when you looked and nothing about
        # what at, so it leaves the sha standing rather than writing a wrong one.
        W.mark_read([u], W.utcnow())
        @test W.read_head(u) == "abc123" && W.read_at(u) > "2026-09-01"

        # An item with no head to record - an issue, a row the poll wrote -
        # records none rather than a blank key that `p` would try to diff.
        W.set_read_mark(u, "2026-09-02T00:00:00Z", "")
        @test W.read_at(u) == "2026-09-02T00:00:00Z" && W.read_head(u) === nothing

        # Going unread forgets both halves: you are no longer anywhere in it.
        W.set_read_mark(u, "2026-09-03T00:00:00Z", "def456")
        @test W.mark_unread([u]) == 1
        @test W.read_at(u) === nothing && W.read_head(u) === nothing
        @test W.mark_unread([u]) == 0       # and says so the second time
    finally
        W.LOCAL[] = keep
    end
end

@testset "r records the head, and z puts back exactly what was there" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    ctrl = W.Controller()
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        it = W.Item(url = "https://github.com/o/r/pull/7", ref = "r#7", repo = "o/r",
                    number = 7, title = "a pull request", head = "cafef00dcafef00d",
                    act = "2026-09-01T00:00:00Z", moved_at = "2026-09-01T00:00:00Z",
                    state = "OPEN")
        st = W.BState([it], "t", Set([it.url]))
        st.filters = W.everything(); W.refilter!(st)
        st.sel = findfirst(x -> x.url == it.url, st.items)
        # Both fetches suppressed: neither the thread nor the metadata of a
        # repository that does not exist is something to send `gh` after.
        st.loaded = string(it.url, ":", st.mode)
        st.metakey = it.url
        st.nodes = [W.Node("h", "b", :md, true)]
        st.nodes[1].meta["fetched"] = "2026-09-05T00:00:00Z"

        W.handle!(st, Int('r'), ctrl)
        @test W.read_at(it.url) == "2026-09-05T00:00:00Z"
        @test W.read_head(it.url) == "cafef00dcafef00d"

        # Unread clears the sha with the stamp, and undo puts both back.
        W.handle!(st, Int('r'), ctrl)
        @test W.read_at(it.url) === nothing && W.read_head(it.url) === nothing
        W.handle!(st, Int('z'), ctrl)
        @test W.read_head(it.url) == "cafef00dcafef00d"
        W.handle!(st, Int('z'), ctrl)
        @test W.read_at(it.url) === nothing && W.read_head(it.url) === nothing

        # An item the lanes never gave a sha to records none and is otherwise
        # exactly as it was.
        plain = W.Item(url = "https://github.com/o/r/issues/8", ref = "r#8",
                       repo = "o/r", number = 8, title = "an issue", is_pr = false,
                       act = "2026-09-01T00:00:00Z", state = "OPEN")
        st2 = W.BState([plain], "t", Set([plain.url]))
        st2.filters = W.everything(); W.refilter!(st2)
        st2.sel = findfirst(x -> x.url == plain.url, st2.items)
        st2.loaded = string(plain.url, ":", st2.mode)
        st2.metakey = plain.url
        W.handle!(st2, Int('r'), ctrl)
        @test W.read_at(plain.url) !== nothing && W.read_head(plain.url) === nothing
    finally
        W.LOCAL[] = keep
    end
end

@testset "the thread is one activity list with a rule in it" begin
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        u = "https://github.com/o/r/pull/9"
        it = W.Item(url = u, ref = "r#9", repo = "o/r", number = 9,
                    title = "a pull request", head = "9999999999", state = "OPEN")
        cmt(id, who, when, body) = Dict{String,Any}(
            "id" => id, "user" => Dict{String,Any}("login" => who),
            "created_at" => when, "body" => body,
            "html_url" => string(u, "#issuecomment-", id))
        # Two commits between the first and second comments, and one after the
        # second: a run and a lone push, which is the whole of the grouping.
        # In the thread's own cache entry, because that is where they live -
        # one age for the whole of what the pane draws.
        W.cache_put("thread:" * u, (
            body = Dict{String,Any}("user" => Dict{String,Any}("login" => "ann"),
                                    "body" => "why this is here",
                                    "html_url" => u),
            comments = [cmt(1, "ann", "2026-09-01T10:00:00Z", "first"),
                        cmt(2, "bob", "2026-09-03T10:00:00Z", "second"),
                        cmt(3, "cat", "2026-09-05T10:00:00Z", "third")],
            commits = [
                Dict{String,Any}("oid" => "aaaaaaa1", "at" => "2026-09-02T09:00:00Z",
                                 "headline" => "first commit", "by" => "ann"),
                Dict{String,Any}("oid" => "aaaaaaa2", "at" => "2026-09-02T09:30:00Z",
                                 "headline" => "second commit", "by" => "ann"),
                Dict{String,Any}("oid" => "bbbbbbb1", "at" => "2026-09-04T09:00:00Z",
                                 "headline" => "after the review", "by" => "ann")]))

        ns = W.comment_nodes(it, W.utcnow())
        heads = [W.astrip(n.header) for n in ns if n.depth == 0]
        # In the order they happened, pushes and comments alike.
        @test findfirst(h -> occursin("ann  2026-09-01", h), heads) <
              findfirst(h -> occursin("pushed 2 commits", h), heads) <
              findfirst(h -> occursin("bob  2026-09-03", h), heads) <
              findfirst(h -> occursin("pushed 1 commit", h), heads) <
              findfirst(h -> occursin("cat  2026-09-05", h), heads)
        # The run carries both shas, newest first, and nothing else does.
        pn = ns[findfirst(n -> occursin("pushed 2 commits", W.astrip(n.header)), ns)]
        @test occursin("aaaaaaa2", pn.raw) && occursin("aaaaaaa1", pn.raw)
        @test findfirst("aaaaaaa2", pn.raw) < findfirst("aaaaaaa1", pn.raw)
        # Never read, so there is no rule: the whole thread is new and a rule
        # above the first line of it says nothing.
        @test !any(n -> get(n.meta, "newmark", false) === true, ns)

        # Read up to the second comment, and the rule lands above what came
        # after it - the push included, which is the point of one list.
        W.set_read_mark(u, "2026-09-03T12:00:00Z", "9999999999")
        ns = W.comment_nodes(it, W.utcnow())
        i = findfirst(n -> get(n.meta, "newmark", false) === true, ns)
        @test i !== nothing
        @test occursin("new since you last looked", W.astrip(ns[i].header))
        @test occursin("2 entries", W.astrip(ns[i].header))
        before = [W.astrip(n.header) for n in ns[1:i-1]]
        after = [W.astrip(n.header) for n in ns[i+1:end]]
        @test any(h -> occursin("bob  2026-09-03", h), before)
        @test any(h -> occursin("pushed 1 commit", h), after)
        @test any(h -> occursin("cat  2026-09-05", h), after)
        @test !any(h -> occursin("bob  2026-09-03", h), after)

        # And a thread read past the end of it has no rule either.
        W.set_read_mark(u, "2026-09-09T00:00:00Z", "9999999999")
        @test !any(n -> get(n.meta, "newmark", false) === true,
                   W.comment_nodes(it, W.utcnow()))

        # An entry written before the pushes were drawn in here still shows the
        # conversation, rather than being dropped for a field that is new.
        W.cache_put("thread:" * u, (
            body = Dict{String,Any}("user" => Dict{String,Any}("login" => "ann"),
                                    "body" => "why this is here", "html_url" => u),
            comments = [cmt(1, "ann", "2026-09-01T10:00:00Z", "first")]))
        ns = W.comment_nodes(it, W.utcnow())
        @test any(n -> occursin("ann  2026-09-01", W.astrip(n.header)), ns)
        @test !any(n -> occursin("pushed", W.astrip(n.header)), ns)
    finally
        W.LOCAL[] = keep
    end
end

@testset "consecutive pushes are one entry" begin
    p(at) = (kind = :push, at = at,
             c = Dict{String,Any}("oid" => "x", "at" => at, "headline" => "h", "by" => "a"))
    c(at) = (kind = :comment, at = at, c = Dict{String,Any}("created_at" => at))
    g = W.group_pushes([p("1"), p("2"), c("3"), p("4"), c("5"), c("6"), p("7"), p("8")])
    @test [e.kind for e in g] == [:push, :comment, :push, :comment, :comment, :push]
    @test [length(e.c) for e in g if e.kind === :push] == [2, 1, 2]
    # A run is stamped at its last commit, so a push that is half new still
    # lands below the rule rather than straddling it.
    @test g[1].at == "2" && g[end].at == "8"
    @test isempty(W.group_pushes([]))
end

@testset "a range-diff is one node per commit" begin
    txt = """
1:  8aee051 ! 1:  1565527 change two
    @@ f.txt
     @@
      one
     -two
    -+TWO
    ++TWOO
      three
      four
2:  7005033 < -:  ------- change four
-:  ------- > 2:  319d524 change four
-:  ------- > 3:  df0f13a change one
"""
    ns = W.rangediff_nodes(txt)
    @test length(ns) == 4
    @test [W.astrip(n.header) for n in ns] ==
          ["changed   1565527  change two", "gone      7005033  change four",
           "new       319d524  change four", "new       df0f13a  change one"]
    # A commit the rebase dropped keeps the sha it had, since the other column
    # is `-------`; everything the rebase touched opens.
    @test all(n -> n.open, ns)
    @test occursin("TWOO", ns[1].raw) && isempty(ns[2].raw)

    # The colour says which range a line is in, which is the whole question
    # here - the inner diff is a change both versions make.
    @test startswith(W.rangeline("    ++TWOO"), W.THEME.diff_add)
    @test startswith(W.rangeline("    -+TWO"), W.THEME.diff_del)
    @test W.rangeline("     -two") == "     -two"
    @test W.rangeline("   ") == "   "          # too short to have a marker
    @test W.astrip(W.rangeline("     @@")) == "     @@"

    # Past nine commits git right-aligns the numbers and every row gains a
    # leading space. Anchoring on the digit matched none of them.
    wide = W.rangediff_nodes(join([" -:  ------- >  $i:  abcdef$i commit $i" for i in 1:10],
                                  "\n") * "\n")
    @test length(wide) == 10
    @test W.astrip(wide[10].header) == "new       abcdef10  commit 10"

    # A diff whose own content looks like a range-diff header. Not a contrived
    # case: this file is full of such lines, so reviewing a change to it was
    # exactly what would break. git reported one pair; the parser read three,
    # and the real diff went under the second invented heading.
    trap = """
1:  bc0f10e ! 1:  b54f028 tweak
    @@ doc.md
      1:  8aee051 ! 1:  1565527 change two
      2:  7005033 < -:  ------- change four
     -VALUE
    -+OLDVALUE
    ++NEWVALUE
      more
"""
    tn = W.rangediff_nodes(trap)
    @test length(tn) == 1
    @test W.astrip(tn[1].header) == "changed   b54f028  tweak"
    # And the body it kept is all of it, the header-shaped rows included.
    @test occursin("1565527", W.astrip(tn[1].raw))
    @test occursin("NEWVALUE", W.astrip(tn[1].raw))
    # Four spaces is what says "body", so a header is never indented that far
    # and an inner diff line never is not.
    @test W.RANGE_PAIR !== nothing
    @test match(W.RANGE_PAIR, "      1:  aaaaaaa ! 1:  bbbbbbb x") === nothing
    @test match(W.RANGE_PAIR, " 1:  aaaaaaa ! 1:  bbbbbbb x") !== nothing

    # A run of `=` commits keeps its header and folds.
    eq = W.rangediff_nodes("1:  aaaaaaa = 1:  bbbbbbb same commit\n")
    @test length(eq) == 1 && !eq[1].open
    @test occursin("unchanged", W.astrip(eq[1].header))
    # Text that is not a range-diff at all yields nothing rather than one node
    # of noise.
    @test isempty(W.rangediff_nodes("fatal: not a git repository\n"))
end

@testset "p says what it cannot show, and then shows it" begin
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    root = mktempdir()
    try
        # An issue has no branch, and says that rather than failing a git call.
        issue = W.Item(url = "https://github.com/o/r/issues/3", ref = "r#3",
                       repo = "o/r", number = 3, title = "t", is_pr = false)
        @test occursin("not a pull request", W.pushed_nodes(issue)[1].header)

        u = "https://github.com/o/r/pull/4"
        it = W.Item(url = u, ref = "r#4", repo = "o/r", number = 4, title = "t")
        # Never marked read, so there is no old head and the pane says which
        # key makes one.
        ns = W.pushed_nodes(it)
        @test occursin("nothing to compare", ns[1].header) && occursin("`r`", ns[1].raw)

        # A real branch, rebased onto a base that moved ten commits under it,
        # with the old head recorded. The file is long enough for
        # `git range-diff` to pair the two versions of the commit rather than
        # reporting one dropped and one added - which is its own answer to a
        # rewrite that kept nothing, and not the one being tested here.
        main = joinpath(root, "main"); mkpath(main)
        W.git(main, "init", "--quiet", "--initial-branch=master", ".")
        W.git(main, "config", "user.email", "t@e.com")
        W.git(main, "config", "user.name", "t")
        lines(x) = join(vcat(["line $i" for i in 1:20], [x], ["line $i" for i in 21:40]), "\n")
        write(joinpath(main, "f.txt"), lines("middle"))
        W.git(main, "add", "f.txt"); W.git(main, "commit", "--quiet", "-m", "base")
        base = strip(W.git(main, "rev-parse", "HEAD"))
        write(joinpath(main, "f.txt"), lines("TWO"))
        W.git(main, "commit", "--quiet", "-am", "change the middle")
        old = strip(W.git(main, "rev-parse", "HEAD"))
        # Ten commits of somebody else's work land on the base.
        W.git(main, "checkout", "--quiet", "master")
        W.git(main, "reset", "--quiet", "--hard", base)
        for i in 1:10
            write(joinpath(main, "m.txt"), string("master ", i))
            W.git(main, "add", "m.txt")
            W.git(main, "commit", "--quiet", "-m", "master work $i")
        end
        moved = strip(W.git(main, "rev-parse", "HEAD"))
        # And the branch is rebased onto it, with one line changed again.
        write(joinpath(main, "f.txt"), lines("TWOO"))
        W.git(main, "add", "f.txt")
        W.git(main, "commit", "--quiet", "-m", "change the middle")
        newh = strip(W.git(main, "rev-parse", "HEAD"))
        W.git(main, "reset", "--quiet", "--hard", moved)
        # The head it stands at now comes off the item, so nothing shells out.
        # `base` names the branch it is to be merged into, which is what keeps
        # the ten out of the answer.
        rebased = W.Item(url = u, ref = "r#4", repo = "o/r", number = 4, title = "t",
                         head = newh, base = "master")

        W.set_read_mark(u, "2026-09-01T00:00:00Z", old)
        # No checkout pinned yet: the pane names both commits and says how to
        # pin one, because nothing else in the program can answer this.
        ns = W.pushed_nodes(rebased)
        @test occursin("no checkout pinned", ns[1].header)
        @test occursin(first(old, 8), ns[1].raw) && occursin("wl repo add", ns[1].raw)

        W.save_repo!("o/r", ["worktree" => main])
        @test W.repo_path("o/r") == main

        # **The whole point of carrying the base.** Measured from it, the answer
        # is the one commit that changed; measured from where the two heads meet
        # - which is what `old...new` does and what an item with no base falls
        # back to - it is that commit plus all ten of somebody else's.
        ns = W.pushed_nodes(rebased)
        @test occursin("rebased", W.astrip(ns[1].header))
        @test occursin("onto 10 newer commits", W.astrip(ns[1].header))
        @test occursin(string(first(old, 8), " \u2192 ", first(newh, 8)),
                       W.astrip(ns[1].header))
        @test count(n -> n.kind === :plain && !isempty(n.raw), ns) == 1
        @test length(ns) == 2                      # the lead, and one commit
        @test any(n -> occursin("TWOO", n.raw), ns)
        @test !any(n -> occursin("master work", W.astrip(n.header)), ns)

        # Without it, the ten come back - as the rows this change exists to
        # remove, and as a pane that says so rather than pretending otherwise.
        nobase = W.Item(url = u, ref = "r#4", repo = "o/r", number = 4, title = "t",
                        head = newh)
        ns = W.pushed_nodes(nobase)
        @test occursin("rewritten", W.astrip(ns[1].header))   # no base, so no "onto"
        @test occursin("no base branch to measure from", ns[1].raw)
        @test count(n -> occursin("master work", W.astrip(n.header)), ns) == 10

        # A push that only added to the branch is a plain diff instead, and
        # counts what arrived.
        W.git(main, "checkout", "--quiet", "--detach", newh)
        write(joinpath(main, "f.txt"), string(lines("TWOO"), "\nTHREE"))
        W.git(main, "commit", "--quiet", "-am", "add a line")
        ahead = strip(W.git(main, "rev-parse", "HEAD"))
        W.set_read_mark(u, "2026-09-01T00:00:00Z", newh)
        ns = W.pushed_nodes(W.Item(url = u, ref = "r#4", repo = "o/r", number = 4,
                                   title = "t", head = ahead, base = "master"))
        @test occursin("1 commit added", W.astrip(ns[1].header))
        @test any(n -> n.kind === :diff && occursin("THREE", n.raw), ns)

        # Standing where you left it is a sentence too, and points at `o` for
        # the half of "what changed" that is not the branch.
        W.set_read_mark(u, "2026-09-01T00:00:00Z", ahead)
        ns = W.pushed_nodes(W.Item(url = u, ref = "r#4", repo = "o/r", number = 4,
                                   title = "t", head = ahead, base = "master"))
        @test occursin("nothing pushed", ns[1].header) && occursin("`o`", ns[1].raw)
    finally
        W.LOCAL[] = keep
    end
end

@testset "a thread opens on the rule, not at the top" begin
    ENV["COLUMNS"], ENV["LINES"] = "150", "40"
    st = mkstate()
    st.diw = 80
    st.nodes = [W.Node("ann  2026-09-01   first", "a", :md, true),
                W.Node("bob  2026-09-02   second", "b", :md, true),
                W.Node("new since you last looked", "", :plain, true),
                W.Node("cat  2026-09-03   third", "c", :md, true)]
    st.nodes[3].meta["newmark"] = true
    r, top = W.openrow(st)
    @test st.nodes[W.rows(st.nodes, st.diw)[r].node] === st.nodes[3]
    @test top == max(1, r - 1)
    # No rule, and it opens where it always did.
    delete!(st.nodes[3].meta, "newmark")
    @test W.openrow(st) == (1, 1)
end
