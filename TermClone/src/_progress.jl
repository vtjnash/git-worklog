import MyterialColors: orange_light, blue_light

"""
Definition of several type of columns for progress bars.
Used in progress.jl.

Each column draws its piece of a job's line as a row, [`cell`](@ref); Term's
`update!(col, color)` is that row written out as ANSI.
"""

# ---------------------------------------------------------------------------- #
#                                    columns                                   #
# ---------------------------------------------------------------------------- #
abstract type AbstractColumn <: AbstractRenderable end

setwidth!(col::AbstractColumn, width::Int) = nothing

"""
    cell(col::AbstractColumn, color::String)::Row

The column's piece of its job's line, as it is now; `color` is the job's colour.
"""
function cell end

update!(col::AbstractColumn, args...)::String = ansi(cell(col, args...))

# ---------------------------------------------------------------------------- #
#                                 TEXT COLUMNS                                 #
# ---------------------------------------------------------------------------- #
# ---------------------------- description column ---------------------------- #
mutable struct DescriptionColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    text::String

    function DescriptionColumn(job::ProgressJob; style::String = orange_light)
        seg = Segment(job.description, style)
        return new(job, [seg], seg.measure, seg.text)
    end
end

cell(col::DescriptionColumn, args...) = col.segments[1].row

mutable struct TextColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    text::String

    function TextColumn(job::ProgressJob; style::String = blue_light, text = "")
        seg = Segment(text, style)
        return new(job, [seg], seg.measure, seg.text)
    end
end

cell(col::TextColumn, args...) = col.segments[1].row

# ----------------------------- separator column ----------------------------- #
struct SeparatorColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    text::String

    function SeparatorColumn(job::ProgressJob)
        seg = Segment("●", TERM_THEME[].progress_accent)
        return new(job, [seg], Measure(1, 1), seg.text)
    end
end

cell(col::SeparatorColumn, args...) = col.segments[1].row

struct SpaceColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    text::String

    function SpaceColumn(job::ProgressJob; width = 1)
        seg = Segment(" "^width, TERM_THEME[].progress_accent)
        return new(job, [seg], seg.measure, seg.text)
    end
end

cell(col::SpaceColumn, args...) = col.segments[1].row

# ----------------------------- completed column ----------------------------- #
struct CompletedColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    text::String
    padwidth::Int
    style::String
    tail::Row   # "/N", drawn after the count

    function CompletedColumn(job::ProgressJob; style::String = TERM_THEME[].text_accent)
        if isnothing(job.N)
            seg = Segment(" "^10)
            return new(job, [seg], seg.measure, "", 0, style, row(""))
        else
            width = length(string(job.N)) * 2 + 1
            seg = Segment(" "^width)
            accent = TERM_THEME[].text_accent
            tail = rowcat(styled("/", style), styled(string(job.N), "$accent underline"))
            return new(job, [seg], seg.measure, ansi(tail), length(digits(job.N)), style, tail)
        end
    end
end

function cell(col::CompletedColumn, color::String, args...)
    isnothing(col.job.N) && return styled(string(col.job.i), col.style)
    # the count in the job's colour, under the tail's own faces
    return faced(rowcat(lpad(string(col.job.i), col.padwidth), col.tail), face(color * " bold"))
end

# ----------------------------- percentage column ---------------------------- #
struct PercentageColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure

    function PercentageColumn(job::ProgressJob)
        seg = Segment(" "^4) # "xxx %
        return new(job, [seg], seg.measure)
    end
end

function cell(col::PercentageColumn, args...)
    isnothing(col.job.N) && return row("")
    frac = rint(col.job.i / col.job.N * 100)
    p = string(frac)
    return styled((frac == 100 ? p : lpad(p, 3)) * "%", "dim")
end

# ----------------------------- downloaded column ---------------------------- #
struct DownloadedColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    tot_size::String

    function DownloadedColumn(job::ProgressJob)
        tot_size = get_file_format(job.N)
        seg = Segment(" "^(length(tot_size) * 2 + 1))
        return new(job, [seg], seg.measure, tot_size)
    end
end

function cell(col::DownloadedColumn, args...)
    isnothing(col.job.N) && return row("")
    completed = get_file_format(col.job.i)
    return pad_row(row(completed * "/" * col.tot_size), col.measure.w, :right)
end

# ---------------------------------------------------------------------------- #
#                                TIMING COLUMNS                                #
# ---------------------------------------------------------------------------- #

"A time in ms as Term writes it: ms under a second, s under a minute, min after."
function format_ms(ms; ms_digits = nothing)
    return if ms < 1000
        string(isnothing(ms_digits) ? ms : round(ms; digits = ms_digits), "ms")
    elseif ms < (60 * 1000)
        string(round(ms / 1000; digits = 2), "s")
    else
        string(round(ms / (60 * 1000); digits = 2), "min")
    end
end

# ------------------------------ elapsed column ------------------------------ #

struct ElapsedColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    style::String
    padwidth::Int

    ElapsedColumn(job::ProgressJob; style = TERM_THEME[].progress_elapsedcol_default) =
        new(job, [], Measure(1, 6 + 9), style, 6)
end

function cell(col::ElapsedColumn, args...)
    isnothing(col.job.startime) && return row(" "^(col.measure.w))
    elapsedtime = (now() - col.job.startime).value  # in ms
    msg = lpad(str_trunc(format_ms(elapsedtime), col.padwidth), col.padwidth)
    return styled("elapsed: $(msg)", col.style)
end

# -------------------------------- ETA column -------------------------------- #

struct ETAColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    style::String
    padwidth::Int

    ETAColumn(job::ProgressJob; style = TERM_THEME[].progress_etacol_default) =
        new(job, [], Measure(1, 9 + 11), style, 9)
end

function cell(col::ETAColumn, args...)
    isnothing(col.job.startime) && return row(" "^(col.measure.w))
    isnothing(col.job.N) && return row(" "^(col.measure.w))

    # get remaining time in ms
    elapsed = (now() - col.job.startime).value  # in ms
    perc = col.job.i / col.job.N
    remaining = elapsed * (1 - perc) / perc

    msg = lpad(str_trunc(format_ms(remaining; ms_digits = 0), col.padwidth), col.padwidth)
    return styled("remaining: $(msg)", col.style)
end

# ---------------------------------------------------------------------------- #
#                               PROGRESS COLUMNS                               #
# ---------------------------------------------------------------------------- #

# ------------------------------ progress column ----------------------------- #
mutable struct ProgressColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    nsegs::Int
    completed_char::Char
    remaining_char::Char

    ProgressColumn(
        job::ProgressJob;
        completed_char::Char = '━',
        remaining_char::Char = ' ',
    ) = new(job, Vector{Segment}(), Measure(0, 0), 0, completed_char, remaining_char)
end

function setwidth!(col::ProgressColumn, width::Int)
    col.measure = Measure(1, width)
    return col.nsegs = width
end

function cell(col::ProgressColumn, color::String, args...)
    completed = clamp(rint(col.nsegs * col.job.i / col.job.N), 0, col.nsegs)
    remaining = col.nsegs - completed
    return rowcat(
        styled(col.completed_char^completed, color * " bold"),
        col.remaining_char^remaining,
    )
end

# ------------------------------ spinner columns ----------------------------- #

SPINNERS = Dict(
    :dot => Dict(
        "period" => 100,
        "frames" => [
            "( ●    )",
            "(  ●   )",
            "(   ●  )",
            "(    ● )",
            "(     ●)",
            "(    ● )",
            "(   ●  )",
            "(  ●   )",
            "( ●    )",
            "(●     )",
        ],
    ),
    :circle => Dict("period" => 125, "frames" => ["◐", "◓", "◑", "◒"]),
    :toggle => Dict("period" => 250, "frames" => ["⦾⦿", "⦿⦾"]),
    :toggle2 => Dict("period" => 250, "frames" => ["◯", "⬤"]),
    :bar => Dict(
        "period" => 100,
        "frames" => [
            "(=   )",
            "(==  )",
            "(=== )",
            "( ===)",
            "(  ==)",
            "(   =)",
            "(   =)",
            "(  ==)",
            "( ===)",
            "(====)",
            "(=== )",
            "(==  )",
            "(=   )",
        ],
    ),
    :greek => Dict("period" => 350, "frames" => ["ϴ", "Ω", "Φ", "Ο"]),
)

mutable struct SpinnerColumn <: AbstractColumn
    job::ProgressJob
    segments::Vector{Segment}
    measure::Measure
    frames::Vector{Row}
    Δt::Float64                 # how frequently to update display, in milliseconds
    frameidx::Int
    nframes::Int
    lastupdated::Int
    lasttext::Row

    function SpinnerColumn(
            job::ProgressJob;
            spinnertype::Symbol = :dot,
            style = TERM_THEME[].progress_spiner_default,
        )
        spinnerdata = SPINNERS[spinnertype]
        frames = Row[styled(frame, style) for frame in spinnerdata["frames"]]
        seg = Segment(frames[1])

        return new(
            job,
            [seg],
            seg.measure,
            frames,
            spinnerdata["period"],
            1,
            length(frames),
            0,
            frames[1],
        )
    end
end

function cell(col::SpinnerColumn, args...)
    col.job.started || return row(" "^(col.measure.w))
    col.job.finished && return styled("✔", TERM_THEME[].progress_spinnerdone_default)

    t = (now() - col.job.startime).value

    if t - col.lastupdated ≥ col.Δt
        col.lastupdated = t
        col.frameidx = col.frameidx == col.nframes ? 1 : col.frameidx + 1
        col.lasttext = col.frames[col.frameidx]
    end

    return col.lasttext
end

# ---------------------------------------------------------------------------- #
#                                COLUMNS PRESETS                               #
# ---------------------------------------------------------------------------- #

function get_columns(columnsset::Symbol)::Vector{DataType}
    return if columnsset ≡ :minimal
        [DescriptionColumn, ProgressColumn]
    elseif columnsset ≡ :default
        [
            DescriptionColumn,
            SeparatorColumn,
            ProgressColumn,
            SeparatorColumn,
            CompletedColumn,
            PercentageColumn,
        ]
    elseif columnsset ≡ :spinner
        [DescriptionColumn, SpaceColumn, SpinnerColumn, SpaceColumn, CompletedColumn]
    elseif columnsset ≡ :detailed
        # extensive
        [
            DescriptionColumn,
            SeparatorColumn,
            ProgressColumn,
            SeparatorColumn,
            CompletedColumn,
            PercentageColumn,
            SeparatorColumn,
            ElapsedColumn,
            ETAColumn,
        ]
    else
        @warn "Columns name not recognized: $columnsset"
        get_columns(:minimal)
    end
end
