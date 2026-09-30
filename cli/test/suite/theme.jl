# The colours, and the file they are read from. Three questions: whether a spec
# becomes the face it says, whether a bad line is reported rather than
# swallowed, and whether no theme really means no escapes - which is the one
# that would have been easy to get almost right.
#
# It puts the default theme back at the end. Every file after this one asserts
# on bold rows and cursor backgrounds, and a testset that left `THEME` empty
# behind it would make all of those pass by saying nothing.

# The theme the suite runs in, and what every testset here puts back. Not
# `themefile()`: that answers with whatever `config.toml` names, which may be
# nothing at all, and the files after this one need the colours they assert on.
const THEME_DEFAULT = joinpath(W.ROOT, "themes", "default-ansi.toml")

@testset "a theme value becomes a face" begin
    pf(x) = W.parse_face(x)
    c(x) = W.SimpleColor(x)
    @test pf("bold") == W.Face(weight = :bold)
    @test pf("dim") == W.Face(weight = :light)
    @test pf("red") == W.Face(foreground = c(:red))
    @test pf("bright red") == W.Face(foreground = c(:bright_red))
    @test pf("on yellow") == W.Face(background = c(:yellow))
    # 256 by index, in both positions: the RGB xterm gives it.
    @test pf("244") == W.Face(foreground = W.SimpleColor(0x80, 0x80, 0x80))
    @test pf("on 236") == W.Face(background = W.SimpleColor(0x30, 0x30, 0x30))
    @test pf("0") == W.Face(foreground = c(:black))
    # Combined, in either order.
    @test pf("bold white") == W.Face(weight = :bold, foreground = c(:white))
    @test pf("black on yellow") == pf("on yellow black") ==
          W.Face(foreground = c(:black), background = c(:yellow))
    @test pf("underline") == W.Face(underline = true) && pf("reverse") == W.Face(inverse = true)
    # No colour is a colour a theme may choose: the role is drawn plain, and
    # a face with nothing in it writes nothing.
    @test pf("") == W.Face() && pf("   ") == W.Face()
    @test ansi(W.faced("x", pf(""))) == "x"

    # Anything it cannot read is said, naming the word - a theme file is
    # hand-written and a misspelling that rendered as nothing would be a role
    # that had quietly stopped working.
    # `bold on red` is not here: it is legal, and means bold on a red ground.
    for bad in ("chartreuse", "256", "on bold", "on", "bright", "on on red",
                "bright 3", "-1")
        @test_throws ArgumentError W.parse_face(bad)
    end
end

@testset "the theme file, and what is wrong with it" begin
    dir = mktempdir()
    good = joinpath(dir, "t.toml")
    write(good, """
        dim = "244"
        settled = "bright green"
        cursor_bg = "on 17"
        """)
    try
        @test isempty(W.load_theme!(good))
        @test W.THEME.dim == W.parse_face("244")
        @test W.THEME.settled == W.parse_face("bright green")
        @test W.THEME.cursor_bg == W.parse_face("on 17")
        # A role the file does not name is not drawn, and a partial theme is
        # therefore a legal one.
        @test W.THEME.waiting == W.Face() && W.THEME.accent == W.Face()

        # Loading a second theme leaves nothing of the first behind: `settled`
        # is named here and `dim` is not, and both have to answer for this one.
        two = joinpath(dir, "two.toml")
        write(two, "settled = \"cyan\"\n")
        @test isempty(W.load_theme!(two))
        @test W.THEME.settled == W.parse_face("cyan") && W.THEME.dim == W.Face()

        # Every kind of bad line, each reported and none fatal.
        bad = joinpath(dir, "bad.toml")
        write(bad, """
            dim = "dim"
            blocke = "red"
            waiting = 3
            accent = "chartreuse"
            """)
        probs = W.load_theme!(bad)
        @test length(probs) == 3
        @test any(p -> occursin("blocke", p), probs)         # a misspelt role
        @test any(p -> occursin("wants a string", p), probs) # a number
        @test any(p -> occursin("chartreuse", p), probs)     # a misspelt colour
        @test W.THEME.dim == W.parse_face("dim")   # and the good line still took
        @test W.THEME.blocked == W.Face() && W.THEME.accent == W.Face()

        # A file that is not TOML at all is one problem, not a stack trace.
        broken = joinpath(dir, "broken.toml")
        write(broken, "dim = \n")
        @test length(W.load_theme!(broken)) == 1
    finally
        W.load_theme!(THEME_DEFAULT)
    end
end

@testset "no theme is no colour at all" begin
    try
        # A name that is not there is said - it is a typo in `config.toml` -
        # and a name that is empty is not: that is how colour is turned off.
        @test length(W.load_theme!(joinpath(mktempdir(), "nope.toml"))) == 1
        @test isempty(W.load_theme!(""))
        for f in fieldnames(W.Theme)
            @test getfield(W.THEME, f) == W.Face()
        end
        # The payoff, and the thing a per-role default would have got wrong:
        # not one SGR sequence reaches the screen. Nothing ends a face, so
        # there is nothing left cancelling colours nobody emitted.
        ENV["COLUMNS"], ENV["LINES"] = "150", "40"
        st = mkstate()
        # A markdown body, with what would be styled in it: with no theme
        # asked for, none of it is.
        st.nodes = [W.Node("alice  2026-08-01   first",
                           "# a heading\n\na paragraph, **bold**, `code`\n\n> quoted",
                           :md, true)]
        f = frame(st, 150, 40)
        # Not one SGR escape anywhere on the screen - not a colour, and not the
        # weight a border is drawn in either: the two widget packages take
        # those from `TermInput.CHROME`, which this sets too.
        @test !occursin(r"\e\[[0-9;]*m", f)
        @test TermInput.CHROME[] == (strong = W.Face(), quiet = W.Face(), focus = W.Face(),
                                     box = TermInput.BOXES.ROUNDED)
        # Still a frame, though: the geometry is not the theme's business.
        @test all(width(l) == 150 for l in split(f, "\n"))
        # Hyperlinks are not colour and stay - OSC 8 is how a url is followed,
        # not how it is decorated.
        @test occursin("\e]8;;", f)
        # And the row highlights, which are backgrounds rather than text, drop
        # out cleanly: an empty face laid over a row writes nothing.
        @test ansi(W.hlrow("plain", W.THEME.cursor_bg)) == "plain"
        @test ansi(W.hlspan("plain", [1:2], W.THEME.match_bg)) == "plain"
        # A bordered box is bare line art, which is what drawing plain means
        # for something drawn in characters rather than in words.
        @test ansi(TermIFrame.bordered(["x"], 20, 3, "t")[1]) == "╭─ t ──────────────╮"
    finally
        W.load_theme!(THEME_DEFAULT)
    end
end

@testset "the shipped theme names every role, and only roles" begin
    tbl = W.TOML.parsefile(THEME_DEFAULT)
    # Both directions. A role added to `Theme` with no line here would be drawn
    # as nothing by the theme the program ships with, and a line here that is
    # not a role is a typo that has been printing a warning at every startup.
    # The two tables are how markdown is drawn, and are checked in their own
    # testset below.
    roles = sort([k for k in keys(tbl) if !(tbl[k] isa AbstractDict)])
    @test roles == sort([String(r) for r in W.ROLES])
    @test isempty(W.load_theme!(THEME_DEFAULT))
    # And the other two shipped, the same both ways: a role the 256-colour
    # themes did not name would be drawn as nothing on the terminals that can
    # draw the most.
    for f in ("github-dark-256.toml", "github-light-256.toml")
        t = W.TOML.parsefile(joinpath(W.ROOT, "themes", f))
        @test sort([k for k in keys(t) if !(t[k] isa AbstractDict)]) == roles
        @test isempty(W.load_theme!(joinpath(W.ROOT, "themes", f)))
    end
    W.load_theme!(THEME_DEFAULT)
    # It is the ANSI theme: the sixteen colours and the 256 cube, and no
    # colour written as a hex a terminal has to have truecolour for.
    @test !any(v -> v isa String && occursin('#', v), values(tbl))
end

@testset "markdown and code are the theme's, in its own words" begin
    try
        @test isempty(W.load_theme!(THEME_DEFAULT))
        @test TermInput.CHROME[] == (strong = W.THEME.bold, quiet = W.THEME.dim,
                                     focus = W.THEME.focus, box = TermInput.BOXES.ROUNDED)
        st = W.MD_STYLE[]
        # The same spec language as every role, each a face.
        @test st.h1 == W.parse_face("bold blue") && st.blockquote == W.parse_face("blue")
        @test st.h1 == W.Face(weight = :bold, foreground = W.SimpleColor(:blue))
        # An index past the sixteen is the RGB xterm gives it, and the sixteen
        # are names, so the terminal's palette still has them.
        @test st.codeblock == W.Face(background = W.SimpleColor(0x30, 0x30, 0x30))
        @test W.parse_face("on 9") == W.parse_face("on bright red")
        @test W.parse_face("16") == W.Face(foreground = W.SimpleColor(0, 0, 0))
        @test W.parse_face("231") == W.Face(foreground = W.SimpleColor(255, 255, 255))
        @test W.parse_face("67") == W.Face(foreground = W.SimpleColor(95, 135, 175))
        @test W.parse_face("#9FA8DA") == W.Face(foreground = W.SimpleColor(0x9f, 0xa8, 0xda))
        @test st.strike == W.Face(strikethrough = true)
        @test st.box === TermInput.BOXES.ROUNDED              # a name, not a colour
        @test st.faces[:string] == W.parse_face("green")
        # A code span is the two roles it always was.
        t = W.TOML.parsefile(THEME_DEFAULT)
        @test st.code == W.parse_face(t["code_bg"]) && st.code_tick == W.parse_face(t["dim"])
        # And it reaches a comment body.
        rs = W.render_md("# head\n\n> said", 40)
        h1 = faceesc(st.h1)
        @test startswith(ansi(rs[1].text), h1[1] * "head" * h1[2])
        @test startswith(ansi(rs[3].text), faceesc(st.blockquote)[1] * "│ ")
        # Every shipped theme loads with nothing to say.
        for f in readdir(joinpath(W.ROOT, "themes"); join = true)
            @test isempty(W.load_theme!(f))
        end

        # And what a bad line in either table looks like - including the names
        # Term's palette had and this one does not.
        dir = mktempdir()
        bad = joinpath(dir, "bad.toml")
        write(bad, """
            [markdown]
            md_h1 = "chartreuse"
            box = "TRAPEZOID"
            tb_style = "blue"
            emphasis_light = "yellow"
            [code]
            string = "chartreuse"
            boolean = "magenta"
            """)
        probs = W.load_theme!(bad)
        @test length(probs) == 6
        @test any(p -> occursin("md_h1", p) && occursin("chartreuse", p), probs)
        @test any(p -> occursin("no box `TRAPEZOID`", p), probs)
        @test any(p -> occursin("no markdown style `tb_style`", p), probs)
        @test any(p -> occursin("no markdown style `emphasis_light`", p), probs)
        @test any(p -> occursin("code.string", p), probs)
        @test any(p -> occursin("no code face `boolean`", p), probs)
        # The box a bad name did not set is the default, not the last theme's.
        @test TermInput.CHROME[].box === TermInput.BOXES.ROUNDED
        # And with no theme all of it is empty.
        @test isempty(W.load_theme!(""))
        @test W.MD_STYLE[].h1 == W.Face() && isempty(W.MD_STYLE[].faces)
        # So a rendered comment body is plain text: no style asked for is no
        # escape written.
        md(s) = join((rstrip(ansi(r.text)) for r in W.render_md(s, 60)), "\n")
        @test md("a `x` and **bold**") == "a `x` and bold"
        @test !occursin('\e', md("# head\n\n- a `list`\n"))
    finally
        W.load_theme!(THEME_DEFAULT)
    end
end
