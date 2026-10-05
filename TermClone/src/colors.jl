module Colors

import Term: rint
import StyledStrings: SimpleColor

export NamedColor, BitColor, RGBColor, get_color

"""
    nospaces(text::AbstractString)

Remove all spaces from a string.
"""
nospaces(text::AbstractString) = replace(text, " " => "")

# ----------------------------- types definition ----------------------------- #
"""
    AbstractColor

Abstract color type.
"""
abstract type AbstractColor end

Base.show(io::IO, color::AbstractColor) = print(io, "$(typeof(color))")

struct NamedColor <: AbstractColor
    color::String
end

struct BitColor <: AbstractColor
    color::String
end

struct RGBColor <: AbstractColor
    r::Int
    g::Int
    b::Int
end

function RGBColor(s)
    to_number(x) = '.' ∈ x ? parse(Float64, x) : parse(Int, x)
    r, g, b = to_number.(match(RGB_REGEX, s).captures)
    if r < 1 || g < 1 || b < 1
        r *= 255
        g *= 255
        b *= 255
    end
    return RGBColor(rint(r), rint(g), rint(b))
end

# --------------------------------- is color? -------------------------------- #

RGB_REGEX = r"\(\s*([\d\.]{1,3})\s*,\s*([\d\.]{1,3})\s*,\s*([\d\.]{1,3})\s*\)"
HEX_REGEX = r"#(?:[0-9a-fA-F]{3}){1,2}$"

"The eight colours, and the terminal's own, that a `NamedColor` names."
const NAMED_COLORS =
    ("default", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")

"""
    bitcolor(string) -> Union{Int, Nothing}

The index among the 256 that `string` names: by one of the names in
`COLORS_256`, or by the number itself, `"1"` to `"255"`.
"""
function bitcolor(string)
    n = get(COLORS_256, string, nothing)
    isnothing(n) || return n
    occursin(r"^[1-9][0-9]{0,2}$", string) || return nothing
    n = parse(Int, string)
    return n <= 255 ? n : nothing
end

"""
    is_named_color(string::String)::Bool

Check if a string represents a named color.
"""
is_named_color(string)::Bool = string ∈ NAMED_COLORS || !isnothing(bitcolor(string))

"""
    is_rgb_color(string::String)::Bool

Check if a string represents a RGB color.
"""
is_rgb_color(string)::Bool = !occursin("on_", string) && occursin(RGB_REGEX, string)

"""
    is_hex_color(string::String)::Bool

Check if a string represents a hex color.
"""
is_hex_color(string)::Bool = !occursin("on_", string) && occursin(HEX_REGEX, string)

"""
    is_color(string::String)::Bool

Check if a string represents color information, of any type.
"""
is_color(string)::Bool =
    is_named_color(string) || is_rgb_color(string) || is_hex_color(string)

"""
    is_background(string::String)::Bool

Check if a string represents background color information, of any type.
"""
function is_background(string)::Bool
    stripped = nospaces(string)
    length(stripped) < 3 && return false
    return stripped[1:3] == "on_" && is_color(stripped[4:end])
end

# --------------------------------- get color -------------------------------- #
"""
    hex2rgb(hex::String)

Converts a string hex color code to a RGB color
"""
function hex2rgb(hex)::RGBColor
    to_int(h) = parse(Int, h; base = 16)
    r, g, b = [to_int(hex[i:(i + 1)]) for i in (2, 4, 6)]
    return RGBColor(r, g, b)
end

"""
    get_color(string::String; bg=false)::AbstractColor

Extract a color type from a string with color information.
"""
function get_color(string; bg = false)::AbstractColor
    bg && (string = nospaces(string)[4:end])

    if is_named_color(string)
        return string ∈ NAMED_COLORS ? NamedColor(string) : BitColor(string)
    elseif is_rgb_color(string)
        return RGBColor(string)
    else
        # convert hex to rgb
        return hex2rgb(string)
    end
end


# ------------------------------ colors as faces ----------------------------- #
# A color named by Term becomes a StyledStrings `SimpleColor`: the sixteen by
# their names, which StyledStrings writes as the 30-37 / 90-97 codes, and every
# other one as RGB. StyledStrings has no way to say "index n of the 256", so a
# `BitColor` past 15 is the RGB xterm draws that index in.

const ANSI16 = (:black, :red, :green, :yellow, :blue, :magenta, :cyan, :white,
    :bright_black, :bright_red, :bright_green, :bright_yellow, :bright_blue,
    :bright_magenta, :bright_cyan, :bright_white)

"""
    xterm_rgb(n) -> (r, g, b)

The colour xterm draws index `n` of the 256 in.
"""
function xterm_rgb(n::Integer)
    if n < 16
        base = ((0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238),
            (205, 0, 205), (0, 205, 205), (229, 229, 229), (127, 127, 127), (255, 0, 0),
            (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255),
            (255, 255, 255))
        return base[n + 1]
    elseif n < 232
        i = n - 16
        lv(x) = x == 0 ? 0 : 55 + 40x
        return (lv(i ÷ 36), lv((i ÷ 6) % 6), lv(i % 6))
    else
        g = 8 + 10 * (n - 232)
        return (g, g, g)
    end
end

"""
    simplecolor(n::Integer) -> SimpleColor

Index `n` of the 256 as a StyledStrings colour: by name for the sixteen, as RGB
past them.
"""
simplecolor(n::Integer) =
    n < 16 ? SimpleColor(ANSI16[n + 1]) : SimpleColor(xterm_rgb(n)...)

simplecolor(c::NamedColor) = SimpleColor(Symbol(c.color))
simplecolor(c::BitColor) = simplecolor(something(bitcolor(c.color), 7))
simplecolor(c::RGBColor) = SimpleColor(c.r, c.g, c.b)
simplecolor(::Nothing) = nothing

# ------------------------------ the 256 by name ----------------------------- #
# Term's names for the indices of the 256 (MIT, see LICENSE.Term).
const COLORS_256 = Dict(
    "bright_black" => 8,
    "bright_red" => 9,
    "bright_green" => 10,
    "bright_yellow" => 11,
    "bright_blue" => 12,
    "bright_magenta" => 13,
    "bright_cyan" => 14,
    "bright_white" => 15,
    "grey0" => 16,
    "navy_blue" => 17,
    "dark_blue" => 18,
    "blue3" => 20,
    "blue1" => 21,
    "dark_green" => 22,
    "deep_sky_blue4" => 25,
    "dodger_blue3" => 26,
    "dodger_blue2" => 27,
    "green4" => 28,
    "spring_green4" => 29,
    "turquoise4" => 30,
    "deep_sky_blue3" => 32,
    "dodger_blue1" => 33,
    "green3" => 40,
    "spring_green3" => 41,
    "dark_cyan" => 36,
    "light_sea_green" => 37,
    "deep_sky_blue2" => 38,
    "deep_sky_blue1" => 39,
    "spring_green2" => 47,
    "cyan3" => 43,
    "dark_turquoise" => 44,
    "turquoise2" => 45,
    "green1" => 46,
    "spring_green1" => 48,
    "medium_spring_green" => 49,
    "cyan2" => 50,
    "cyan1" => 51,
    "dark_red" => 88,
    "deep_pink4" => 125,
    "purple4" => 55,
    "purple3" => 56,
    "blue_violet" => 57,
    "orange4" => 94,
    "grey37" => 59,
    "gray37" => 59,
    "medium_purple4" => 60,
    "slate_blue3" => 62,
    "royal_blue1" => 63,
    "chartreuse4" => 64,
    "dark_sea_green4" => 71,
    "pale_turquoise4" => 66,
    "steel_blue" => 67,
    "steel_blue3" => 68,
    "cornflower_blue" => 69,
    "chartreuse3" => 76,
    "cadet_blue" => 73,
    "sky_blue3" => 74,
    "steel_blue1" => 81,
    "pale_green3" => 114,
    "sea_green3" => 78,
    "aquamarine3" => 79,
    "medium_turquoise" => 80,
    "chartreuse2" => 112,
    "sea_green2" => 83,
    "sea_green1" => 85,
    "aquamarine1" => 122,
    "dark_slate_gray2" => 87,
    "dark_magenta" => 91,
    "dark_violet" => 128,
    "purple" => 129,
    "light_pink4" => 95,
    "plum4" => 96,
    "medium_purple3" => 98,
    "slate_blue1" => 99,
    "yellow4" => 106,
    "wheat4" => 101,
    "grey53" => 102,
    "gray53" => 102,
    "light_slate_grey" => 103,
    "light_slate_gray" => 103,
    "medium_purple" => 104,
    "light_slate_blue" => 105,
    "dark_olive_green3" => 149,
    "dark_sea_green" => 108,
    "light_sky_blue3" => 110,
    "sky_blue2" => 111,
    "dark_sea_green3" => 150,
    "dark_slate_gray3" => 116,
    "sky_blue1" => 117,
    "chartreuse1" => 118,
    "light_green" => 120,
    "pale_green1" => 156,
    "dark_slate_gray1" => 123,
    "red3" => 160,
    "medium_violet_red" => 126,
    "magenta3" => 164,
    "dark_orange3" => 166,
    "indian_red" => 167,
    "hot_pink3" => 168,
    "medium_orchid3" => 133,
    "medium_orchid" => 134,
    "medium_purple2" => 140,
    "dark_goldenrod" => 136,
    "light_salmon3" => 173,
    "rosy_brown" => 138,
    "grey63" => 139,
    "gray63" => 139,
    "medium_purple1" => 141,
    "gold3" => 178,
    "dark_khaki" => 143,
    "navajo_white3" => 144,
    "grey69" => 145,
    "gray69" => 145,
    "light_steel_blue3" => 146,
    "light_steel_blue" => 147,
    "yellow3" => 184,
    "dark_sea_green2" => 157,
    "light_cyan3" => 152,
    "light_sky_blue1" => 153,
    "green_yellow" => 154,
    "dark_olive_green2" => 155,
    "dark_sea_green1" => 193,
    "pale_turquoise1" => 159,
    "deep_pink3" => 162,
    "magenta2" => 200,
    "hot_pink2" => 169,
    "orchid" => 170,
    "medium_orchid1" => 207,
    "orange3" => 172,
    "light_pink3" => 174,
    "pink3" => 175,
    "plum3" => 176,
    "violet" => 177,
    "light_goldenrod3" => 179,
    "tan" => 180,
    "misty_rose3" => 181,
    "thistle3" => 182,
    "plum2" => 183,
    "khaki3" => 185,
    "light_goldenrod2" => 222,
    "light_yellow3" => 187,
    "grey84" => 188,
    "gray84" => 188,
    "light_steel_blue1" => 189,
    "yellow2" => 190,
    "dark_olive_green1" => 192,
    "honeydew2" => 194,
    "light_cyan1" => 195,
    "red1" => 196,
    "deep_pink2" => 197,
    "deep_pink1" => 199,
    "magenta1" => 201,
    "orange_red1" => 202,
    "indian_red1" => 204,
    "hot_pink" => 206,
    "dark_orange" => 208,
    "salmon1" => 209,
    "light_coral" => 210,
    "pale_violet_red1" => 211,
    "orchid2" => 212,
    "orchid1" => 213,
    "orange1" => 214,
    "sandy_brown" => 215,
    "light_salmon1" => 216,
    "light_pink1" => 217,
    "pink1" => 218,
    "plum1" => 219,
    "gold1" => 220,
    "navajo_white1" => 223,
    "misty_rose1" => 224,
    "thistle1" => 225,
    "yellow1" => 226,
    "light_goldenrod1" => 227,
    "khaki1" => 228,
    "wheat1" => 229,
    "cornsilk1" => 230,
    "grey100" => 231,
    "gray100" => 231,
    "grey3" => 232,
    "gray3" => 232,
    "grey7" => 233,
    "gray7" => 233,
    "grey11" => 234,
    "gray11" => 234,
    "grey15" => 235,
    "gray15" => 235,
    "grey19" => 236,
    "gray19" => 236,
    "grey23" => 237,
    "gray23" => 237,
    "grey27" => 238,
    "gray27" => 238,
    "grey30" => 239,
    "gray30" => 239,
    "grey35" => 240,
    "gray35" => 240,
    "grey39" => 241,
    "gray39" => 241,
    "grey42" => 242,
    "gray42" => 242,
    "grey46" => 243,
    "gray46" => 243,
    "grey50" => 244,
    "gray50" => 244,
    "grey54" => 245,
    "gray54" => 245,
    "grey58" => 246,
    "gray58" => 246,
    "grey62" => 247,
    "gray62" => 247,
    "grey66" => 248,
    "gray66" => 248,
    "grey70" => 249,
    "gray70" => 249,
    "grey74" => 250,
    "gray74" => 250,
    "grey78" => 251,
    "gray78" => 251,
    "grey82" => 252,
    "gray82" => 252,
    "grey85" => 253,
    "gray85" => 253,
    "grey89" => 254,
    "gray89" => 254,
    "grey93" => 255,
    "gray93" => 255,
)

end
