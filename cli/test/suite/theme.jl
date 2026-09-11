# The colours, and the file they are read from. Three questions: whether a spec
# becomes the escape it says, whether a bad line is reported rather than
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

@testset "a theme value becomes an escape, and its closer" begin
    ps(x) = W.parse_style(x)
    @test ps("bold") == ("\e[1m", "\e[22m")
    @test ps("dim") == ("\e[2m", "\e[22m")
    @test ps("red") == ("\e[31m", "\e[39m")
    @test ps("bright red") == ("\e[91m", "\e[39m")
    @test ps("on yellow") == ("\e[43m", "\e[49m")
    # 256 by index, in both positions.
    @test ps("244") == ("\e[38;5;244m", "\e[39m")
    @test ps("on 236") == ("\e[48;5;236m", "\e[49m")
    @test ps("0") == ("\e[38;5;0m", "\e[39m") && ps("255")[1] == "\e[38;5;255m"
    # Combined, in either order, and the closer ends exactly what was begun.
    @test ps("bold white") == ("\e[1;37m", "\e[22;39m")
    @test ps("black on yellow") == ("\e[30;43m", "\e[39;49m")
    @test ps("on 24 bright white") == ("\e[48;5;24;97m", "\e[49;39m")
    # `bold dim` shares a closer, and it is said once.
    @test ps("bold dim") == ("\e[1;2m", "\e[22m")
    @test ps("underline")[2] == "\e[24m" && ps("reverse")[2] == "\e[27m"
    # No colour is a colour a theme may choose: the role is drawn plain.
    @test ps("") == ("", "") && ps("   ") == ("", "")

    # Anything it cannot read is said, naming the word - a theme file is
    # hand-written and a misspelling that rendered as nothing would be a role
    # that had quietly stopped working.
    # `bold on red` is not here: it is legal, and means bold on a red ground.
    for bad in ("chartreuse", "256", "on bold", "on", "bright", "on on red",
                "bright 3", "-1")
        @test_throws ArgumentError W.parse_style(bad)
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
        @test W.THEME.dim == "\e[38;5;244m" && W.THEME.dim_off == "\e[39m"
        @test W.THEME.settled == "\e[92m" && W.THEME.cursor_bg == "\e[48;5;17m"
        # A role the file does not name is not drawn, and a partial theme is
        # therefore a legal one.
        @test isempty(W.THEME.waiting) && isempty(W.THEME.accent)
        # The two that are not the file's business, present because a theme is.
        @test W.THEME.reset == "\e[0m" && W.THEME.no_bg == "\e[49m"

        # Loading a second theme leaves nothing of the first behind: `settled`
        # is named here and `dim` is not, and both have to answer for this one.
        two = joinpath(dir, "two.toml")
        write(two, "settled = \"cyan\"\n")
        @test isempty(W.load_theme!(two))
        @test W.THEME.settled == "\e[36m" && isempty(W.THEME.dim)

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
        @test W.THEME.dim == "\e[2m"            # and the good line still took
        @test isempty(W.THEME.blocked) && isempty(W.THEME.accent)

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
            @test isempty(getfield(W.THEME, f))
        end
        # The payoff, and the thing a per-role default would have got wrong:
        # not one SGR sequence reaches the screen. The resets are empty too, so
        # there is nothing left cancelling colours nobody emitted.
        ENV["COLUMNS"], ENV["LINES"] = "150", "40"
        st = mkstate()
        # Plain nodes, because Term draws a markdown body and Term's escapes are
        # not this program's to turn off - the question here is about the frame.
        st.nodes = [W.Node("alice  2026-08-01   first", "a paragraph", :plain, true)]
        f = W.render(st, 150, 40)
        # Not one SGR escape anywhere on the screen - not a colour, and not the
        # weight a border is drawn in either: the two widget packages take
        # those from `TermInput.CHROME`, which this sets too.
        @test !occursin(r"\e\[[0-9;]*m", f)
        @test TermInput.CHROME[] == (strong = "", quiet = "", reset = "")
        # Still a frame, though: the geometry is not the theme's business.
        @test all(W.awidth(l) == 150 for l in split(f, "\n"))
        # Hyperlinks are not colour and stay - OSC 8 is how a url is followed,
        # not how it is decorated.
        @test occursin("\e]8;;", f)
        # And the row highlights, which are backgrounds rather than text, drop
        # out cleanly instead of re-arming an empty string at every position.
        @test W.hlrow("plain", W.THEME.cursor_bg) == "plain"
        @test W.hlspan("plain", [1:2], W.THEME.match_bg) == "plain"
        @test W.rearm("a\e[0mb", W.THEME.code_bg) == "a\e[0mb"
        # A bordered box is bare line art, which is what drawing plain means
        # for something drawn in characters rather than in words.
        @test TermIFrame.bordered(["x"], 20, 3, "t", true)[1] == "╭─ t ──────────────╮"
    finally
        W.load_theme!(THEME_DEFAULT)
    end
end

@testset "the shipped theme names every role, and only roles" begin
    tbl = W.TOML.parsefile(THEME_DEFAULT)
    # Both directions. A role added to `Theme` with no line here would be drawn
    # as nothing by the theme the program ships with, and a line here that is
    # not a role is a typo that has been printing a warning at every startup.
    # The two tables are the other palettes - Term's and the highlighter's -
    # and are checked in their own testset below.
    roles = sort([k for k in keys(tbl) if !(tbl[k] isa AbstractDict)])
    @test roles == sort([String(r) for r in W.ROLES])
    @test isempty(W.load_theme!(THEME_DEFAULT))
    # It is the ANSI theme: the sixteen colours and the 256 cube, and nothing
    # that assumes a terminal can do truecolour.
    @test !any(occursin("38;2", getfield(W.THEME, f)) for f in fieldnames(W.Theme))
end

@testset "the other two palettes are Term's, and the theme reaches them" begin
    t = Term.TERM_THEME[]
    try
        # Markdown, in Term's own language: same vocabulary, different spelling.
        @test W.term_style("bold white") == "bold white"
        @test W.term_style("black on yellow") == "black on_yellow"
        @test W.term_style("bright red") == "bright_red"
        @test W.term_style("#9FA8DA") == "#9fa8da"
        # A 256 index has no name in Term above the low sixteen, so it goes as
        # the hex the xterm palette defines it as - and the low sixteen stay
        # named, because turning `red` into a hex is exactly the fighting with
        # the terminal's palette this avoids.
        @test W.term_style("1") == "red" && W.term_style("9") == "bright_red"
        @test W.term_style("236") == "#303030"     # the greys: 8 + 10k
        @test W.term_style("196") == "#ff0000"     # the cube: 0 95 135 175 215 255
        @test W.term_style("on 236") == "on_#303030"
        # Nothing is `default` and not "", which would reach Term as `{}`.
        @test W.term_style("") == W.TERM_PLAIN == "default"

        @test isempty(W.load_theme!(THEME_DEFAULT))
        @test TermInput.CHROME[] == (strong = W.THEME.bold, quiet = W.THEME.dim,
                                     reset = W.THEME.reset)
        @test t.md_h1 == "bold blue" && t.md_quote == "blue"
        @test t.md_codeblock_bg == "#303030"      # Term reads it as on_<colour>
        @test t.box === :ROUNDED                   # a name, not a colour
        @test Term.CodeTheme["string"] == "green"
        # The sentinel is this program's, whatever the theme says.
        @test t.md_code == W.MD_CODE_SENTINEL_HEX

        # And what a bad line in either table looks like.
        dir = mktempdir()
        bad = joinpath(dir, "bad.toml")
        write(bad, """
            [term]
            md_code = "red"
            md_h1 = "chartreuse"
            md_codeblock_bg = "bold red"
            box = "TRAPEZOID"
            nosuchfield = "red"
            [code]
            string = "chartreuse"
            """)
        probs = W.load_theme!(bad)
        @test length(probs) == 6
        @test any(p -> occursin("sentinel", p), probs)
        @test any(p -> occursin("Term has no `nosuchfield`", p), probs)
        @test any(p -> occursin("Term has no box `TRAPEZOID`", p), probs)
        @test any(p -> occursin("one colour and no attributes", p), probs)
        @test any(p -> occursin("code.string", p), probs)
        # And with no theme both palettes go plain, the sentinel excepted.
        @test isempty(W.load_theme!(""))
        @test t.md_h1 == W.TERM_PLAIN && Term.CodeTheme["string"] == W.TERM_PLAIN
        @test t.md_code == W.MD_CODE_SENTINEL_HEX
        # Which is what makes a rendered comment body plain text: Term wraps
        # what it renders in a tag whatever the tag says, so the escapes it
        # prints anyway come back off.
        @test W.render_md("a `x` and **bold**", 60) == "a `x` and bold"
        @test !occursin('\e', W.render_md("# head\n\n- a `list`\n", 60))
    finally
        W.load_theme!(THEME_DEFAULT)
    end
end
