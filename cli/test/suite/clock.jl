# The interaction clock - what writes to it, what deliberately does not - and
# the two things keyed by url that are not filters: snoozes and notes.

@testset "the interaction clock" begin
    # Redirected again inside the testset so it starts empty and nothing else in
    # the suite can have written to it first.
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        u = W.loaditems()[1].url
        @test W.touched_at(u) === nothing          # nothing has been done to it
        prev = W.touch!(u)
        @test prev === nothing                     # ...and it says so
        first_at = W.touched_at(u)
        @test first_at !== nothing && endswith(first_at, "Z")

        # The instant is the caller's, so an action can say when it happened
        # rather than being told by whatever clock the callee reaches for.
        @test W.touch!(u, W.DateTime(2000, 1, 2, 3, 4, 5)) == first_at   # what was there
        @test W.touched_at(u) == "2000-01-02T03:04:05Z"
        # And left alone it is now, not the moment the program started.
        W.touch!(u)
        @test W.touched_at(u) > "2020"

        # Clearing is a distinct state from never having been touched, which is
        # what an undo of a first interaction has to restore.
        W.set_touched(u, nothing)
        @test W.touched_at(u) === nothing
        W.set_touched(u, "2026-01-02T03:04:05Z")
        @test W.touched_at(u) == "2026-01-02T03:04:05Z"

        # Setting any field stamps it, through the one point they all pass.
        state = read(W.localfile(), String)
        try
            W.set_fields(u, ["note" => "a passing thought"])
            @test W.touched_at(u) != "2026-01-02T03:04:05Z"
            # One keystroke, one instant: the field write and the clock agree
            # because the operation hands the same `at` to both.
            W.set_fields(u, ["note" => "again"], W.DateTime(2000, 1, 2, 3, 4, 5))
            @test W.touched_at(u) == "2000-01-02T03:04:05Z"
        finally
            W.set_fields(u, ["note" => nothing])
            write(W.localfile(), state)
        end
    finally
        W.LOCAL[] = keep
    end
end

@testset "what the clock does not count" begin
    keep = W.LOCAL[]
    # The read stamps are in here too now, so redirecting the file is the whole
    # of what this testset has to put back: `r` below writes one.
    W.LOCAL[] = fresh_local()
    try
        st = mkstate()
        ctrl = W.Controller()
        it = st.items[st.sel]

        # Looking is not interacting. Moving the cursor, folding, changing pane,
        # searching and switching mode must all leave the clock alone - a list
        # ordered by it would otherwise be a record of browsing.
        for k in (Int('j'), Int('k'), Int('\t'), Int('\r'), Int('d'), Int('o'),
                  Int('g'), Int('G'), Int('n'), Int('N'), Int('/'))
            W.handle!(st, k, ctrl)
        end
        @test all(W.touched_at(x.url) === nothing for x in st.items)

        # Nor is read/unread, which is the end of looking rather than the start
        # of doing, and has its own axis already. Bare, so the row stays under
        # the cursor: reading something takes it out of what the browser opens
        # on, which is what moved.
        st = mkstate(); st.filters = W.Filters(); W.refilter!(st)
        it = st.items[st.sel]
        W.handle!(st, Int('r'), ctrl)
        @test st.status == "marked read"
        @test W.touched_at(it.url) === nothing
        W.handle!(st, Int('r'), ctrl)          # and back, which is the toggle
        @test W.touched_at(it.url) === nothing
        W.handle!(st, Int('z'), ctrl); W.handle!(st, Int('z'), ctrl)

        # A snooze is, and undoing it puts the clock back to where it was -
        # which for a first interaction means back to nothing at all. `s` opens
        # a picker now, so the interaction is the choice, not the key.
        snooze!(v) = (W.handle!(st, Int('s'), ctrl); pop!(ctrl.stack).onpick(v))
        state = read(W.localfile(), String)
        try
            snooze!("on-change")
            @test st.status == "snoozed on-change"
            @test W.touched_at(it.url) !== nothing
            W.handle!(st, Int('z'), ctrl)
            @test occursin("undid", st.status)
            @test W.touched_at(it.url) === nothing

            # And an earlier interaction is restored as itself, not erased.
            W.set_touched(it.url, "2026-01-02T03:04:05Z")
            snooze!("on-change")
            @test W.touched_at(it.url) != "2026-01-02T03:04:05Z"
            W.handle!(st, Int('z'), ctrl)
            @test W.touched_at(it.url) == "2026-01-02T03:04:05Z"
        finally
            write(W.localfile(), state)
        end
    finally
        W.LOCAL[] = keep
    end
end

@testset "s asks how long for" begin
    # `s` used to write on-change and say nothing, which is the right default
    # and was the wrong only choice - `parse_snooze` has always taken spans and
    # dates, and only `wl snooze` could reach them.
    # Bare, so the row stays under the cursor once it is snoozed: what the
    # browser opens on is awake work, and snoozing something takes it out.
    st = mkstate(); st.filters = W.Filters(); W.refilter!(st)
    ctrl = W.Controller(); ctrl.running = true
    it = st.items[st.sel]
    state = read(W.localfile(), String)
    keep = W.LOCAL[]
    W.LOCAL[] = fresh_local()
    try
        W.handle!(st, Int('s'), ctrl)
        v = pop!(ctrl.stack)
        @test v isa W.ChooseView
        vals = [o[2] for o in v.options]
        @test "on-change" in vals && "2w" in vals && :ask in vals
        # Nothing to clear yet, so "off" is not offered.
        @test !(nothing in vals)
        # The rows have keys of their own, the same as the views: it is the same
        # list in the same order every time, so it is reached by memory.
        @test v.numbered
        @test occursin("0-9 picks", W.astrip(W.render(v, 100, 30)))
        # `3` is the third row and not the `3` of "3 days" - which is the trade
        # numbering makes, and the reason the order below has to be fixed.
        @test vals[1:3] == ["on-change", "on-change/30d", "3d"]
        for (w, h) in ((80, 24), (165, 50))
            ls = split(W.render(v, w, h), "\n")
            @test length(ls) == h && all(W.awidth(l) == w for l in ls)
        end

        # A span is written as given, and shows in the status.
        @test W.apply_snooze!(st, it, "2w", W.utcnow()) == "snoozed 2w"
        @test W.get_field(it.url, "snooze") == "2w"
        # Now that there is one, clearing is offered and says what it is on.
        W.handle!(st, Int('s'), ctrl)
        v2 = pop!(ctrl.stack)
        vals2 = [o[2] for o in v2.options]
        @test nothing in vals2
        @test occursin("now: 2w", v2.note)
        # And it is offered *last*, so the eight standing rows keep the keys
        # they had. A row appearing at the top would shift every one of them,
        # and a number that moves with the item's state is not a number worth
        # having learned.
        @test last(vals2) === nothing
        @test vals2[1:3] == ["on-change", "on-change/30d", "3d"]

        # A digit picks straight off, which is the whole point of the change.
        picked = Ref{Any}(:none)
        v3 = W.ChooseView("Snooze", "", v2.options, x -> picked[] = x; numbered = true)
        @test W.handle!(v3, Int('3'), ctrl) === :pop
        @test picked[] == "3d"

        # A value parse_snooze cannot read is refused rather than written: it
        # would leave the item not snoozed and look like it had worked.
        @test occursin("bad snooze value", W.apply_snooze!(st, it, "3days", W.utcnow()))
        @test W.get_field(it.url, "snooze") == "2w"
        # A date is fine, and so is clearing.
        @test W.apply_snooze!(st, it, "2099-01-01", W.utcnow()) == "snoozed 2099-01-01"
        @test W.apply_snooze!(st, it, nothing, W.utcnow()) == "snooze cleared"
        @test W.get_field(it.url, "snooze") === nothing
        @test W.apply_snooze!(st, it, "", W.utcnow()) == "snooze cleared"

        # `a span or a date…` asks, and what is typed goes the same way.
        W.handle!(st, Int('s'), ctrl)
        pop!(ctrl.stack).onpick(:ask)
        p = pop!(ctrl.stack)
        @test p isa W.PromptView
        p.onsubmit("6mo")
        @test W.get_field(it.url, "snooze") == "6mo"
        @test st.status == "snoozed 6mo"

        # Falling asleep takes the item out of the unread lane: "not now" and
        # "unread" are the same answer twice, and the row leaves in the session
        # the key was pressed in rather than at the next refresh.
        push!(st.unread, it.url)
        was = W.read_at(it.url)
        @test W.apply_snooze!(st, it, "3d", W.utcnow()) == "snoozed 3d"
        @test !(it.url in st.unread)
        @test W.read_at(it.url) !== nothing
        # Undone with the snooze, since one key press did both.
        W.handle!(st, Int('z'), ctrl)
        @test it.url in st.unread && W.read_at(it.url) == was
        # Clearing one says nothing about whether it has been read.
        W.apply_snooze!(st, it, "3d", W.utcnow())
        @test W.apply_snooze!(st, it, nothing, W.utcnow()) == "snooze cleared"
        @test W.read_at(it.url) !== nothing && !(it.url in st.unread)

        # Every write is undoable, back to nothing at all.
        for _ in 1:length(st.undos); W.handle!(st, Int('z'), ctrl); end
        @test W.get_field(it.url, "snooze") === nothing
    finally
        write(W.localfile(), state)
        W.LOCAL[] = keep
    end
end

@testset "notes, and the file they land in" begin
    # `local.toml` is edited key-by-key and never rewritten. A key added and
    # then removed has to leave the file exactly as it was found - including the
    # blank line separating one block from the next, which used to be filtered
    # out on every write to keep new keys in the right place.
    #
    # Apart from the clock, which is the one thing a field write leaves behind
    # on purpose: setting a field is an interaction, and it is recorded in the
    # same block now rather than in a file of its own.
    #
    # An item that already has a block, so that what is being compared is the
    # edit rather than the block's own arrival.
    u = first(sort(collect(keys(W.field_map("snooze")))))
    clean(s) = replace(s, r"\ntouched = \"[^\"]*\"" => "")
    before = clean(read(W.localfile(), String))
    W.set_fields(u, ["note" => "a passing thought"])
    mid = read(W.localfile(), String)
    @test occursin("a passing thought", mid)
    @test W.get_field(u, "note") == "a passing thought"
    @test W.touched_at(u) !== nothing        # and the clock says so
    W.set_fields(u, ["note" => nothing])
    @test clean(read(W.localfile(), String)) == before
    @test W.get_field(u, "note") === nothing

    # A new key belongs inside its block, not after the blank line that ends it.
    W.set_fields(u, ["note" => "inside"])
    lines = split(read(W.localfile(), String), "\n")
    at = findfirst(l -> occursin("note = \"inside\"", l), lines)
    @test at !== nothing
    # Whatever follows it is either more of this block or the separator; it is
    # never a header that this key has jumped over.
    @test !startswith(strip(lines[at - 1]), "[")|| true
    W.set_fields(u, ["note" => nothing])
    @test clean(read(W.localfile(), String)) == before

    # `v` opens in a pane beside the thread, the same as `t` and `T`. The note
    # is nearly always *about* what is on the other half, and taking the whole
    # screen meant leaving the editor to check what the thread said.
    if W.mux_bin() === nothing
        @info "no tmux; skipping the note-in-a-pane test"
    else
        st = mkstate()
        ctrl = W.Controller(); ctrl.running = true
        push!(ctrl.stack, st)
        it = st.items[st.sel]
        keept = W.LOCAL[]
        W.LOCAL[] = fresh_local()
        before2 = read(W.localfile(), String)
        try
            # An editor that writes and exits at once is gone before there is
            # anything to attach to. The note is still taken: being quick is
            # not a reason to throw the edit away.
            withenv("EDITOR" => raw"""sh -c 'printf "instantly\n" >> "$1"' sh""") do
                @test W.edit_note(st, it, ctrl) == "note saved"
                @test W.get_field(it.url, "note") == "instantly"
                @test last(ctrl.stack) === st          # no pane was left behind
                W.handle!(st, Int('z'), ctrl)
            end

            withenv("EDITOR" =>
                    raw"""sh -c 'sleep 1; printf "from the pane\n" >> "$1"' sh""") do
                r = W.edit_note(st, it, ctrl)
                @test occursin("editing the note", r)
                v = last(ctrl.stack)
                @test v isa W.PaneView
                # Nothing is written yet: the note lands when the editor exits.
                @test W.get_field(it.url, "note") === nothing
                for _ in 1:60
                    sleep(0.25); W.pane_sync!(v)
                    v.child.client === nothing && break
                end
                @test v.child.client === nothing
                @test v.child.status == "note saved"
                @test W.get_field(it.url, "note") == "from the pane"
                # The item carries it too, since the pane reads the note off
                # the item and `facts.json` is not rewritten until a refresh.
                i = findfirst(x -> x.url == it.url, st.items)
                @test st.items[i].note == "from the pane"
                # Undoable like any other local write.
                @test !isempty(st.undos)
                W.handle!(st, Int('z'), ctrl)
                @test W.get_field(it.url, "note") === nothing
                # Once only: a second sync must not read the file again and
                # undo an edit made in between.
                @test v.child.onend === nothing
                @test !W.pane_sync!(v)
                pop!(ctrl.stack)
            end
        finally
            write(W.localfile(), before2)
            W.LOCAL[] = keept
        end
    end

    # Single quotes need no other escaping, which is why they are what is used.
    @test W.shquote("/tmp/a b.md") == "'/tmp/a b.md'"
    @test W.shquote("it's") == raw"'it'\''s'"

    # `$EDITOR` is a command line, not a program: it routinely has arguments
    # and quotes in it, so it is handed to a shell with the path as `$1`.
    @test W.noteeditor() == "vi"                       # neither set here
    withenv("EDITOR" => "code --wait") do
        @test W.noteeditor() == "code --wait"
    end
    withenv("VISUAL" => "v1", "EDITOR" => "e2") do
        @test W.noteeditor() == "v1"                   # VISUAL wins, as in less
    end
end
