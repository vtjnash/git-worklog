# What TermInput lacks that the Term clone had to work around, as tests.
#
#     julia --project=TermInput.jl TermClone/TermInput-TODO.jl
#
# Each testset is one gap: what is missing, the API that would fill it (a
# proposal - the tests pin the behaviour, the name is negotiable), and the
# workaround in TermClone to delete once it exists. Every test here is
# `@test_broken` against the proposed API, so the file runs clean today and
# reports an "Unexpected Pass" for each gap as it is filled: then flip that test
# to `@test` (or move it into TermInput's own suite), delete the workaround it
# names, and rerun TermClone's suite to see what moved.
#
# Gaps 1-7 and 9-13 are filled - a frame from a line or under the cursor,
# `writerow`, a widget at its own height, titles with faces, a `Choice` with no
# query or in a row or starting elsewhere, `drawcursor`, the `markdown_rows`
# options, `highlight`'s ranges, eight-line boxes and Term's names for them,
# `tablerows`, and `rowfit`'s mark, `rowrstrip` and `rowvpad` - their tests are
# in TermInput's own suite, and the clone's workarounds for them are gone.
# What is left is the one gap not to be filled there.

using Test
using TermInput

@testset "TermInput gaps found by the Term clone" begin

# ----------------------------------------------------------------------------
# 8. An `InputReader` that lets go mid-read -- DO NOT FIX in TermInput.jl
#
# `close(r)` while a read is pending marks the reader closed, but the read
# completes on the next key and that key is swallowed. A host that arms, then
# decides to stop (an app quit from a timer, a prompt cancelled by a signal)
# loses the user's next keystroke to it.
#
# Proposed: `close(r)` interrupts the pending read, and whatever it had read
# but not yet decoded stays readable from the stream.
#
# Remove: the "never re-arm after the quitting key" rule in `Term.LiveWidgets`'
# loop (src/Live/app.jl, src/Live/keyboard_input.jl), which is correct only for
# quits that come from a key.
@testset "8. close(::InputReader) while reading" begin
    p = Pipe()
    Base.link_pipe!(p)
    events = Channel{Any}(8)
    r = InputReader(p.out, events)
    arm!(r)
    sleep(0.1)
    close(r)
    write(p.in, "x")
    sleep(0.2)
    @test_broken bytesavailable(p.out) == 1
    close(p)
end

end

# Not TermInput's to fill, for the record: StyledStrings faces have no conceal
# and no blink, and one weight (so `bold dim` is bold); and what StyledStrings
# writes depends on the terminfo of the process (italic, dim, reverse,
# strikethrough) and on COLORTERM (24-bit colour). Term's `hidden` panels,
# `bold dim` dendograms and blinking text come out differently for that reason.
