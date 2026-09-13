# The corpus the suite runs on, and the program that makes one.
#
#     julia --project=cli cli/test/fixture.jl
#
# **Why there is a fixture at all.** The suite used to run against
# `data/fetched.json` - the real dashboard, seeded into a temp copy at the top
# of the run - on the argument that a read-only testset is a test of whatever is
# actually in it. That argument covers one kind of testset and not the other,
# and nothing separated them: a sweep wants the real corpus and wants asserting
# over *every* row, while "`/` reaches a row the filter is hiding" wants *a row
# with a property*, and hunting the corpus for one makes an undeclared
# precondition out of a fact about somebody's inbox on the day it was written.
# Two testsets errored that way in two days when the last snooze was cleared,
# and `fetched.json` is untracked - megabytes, churned by every refresh - so on
# a fresh clone there was no corpus at all and the suite could not start.
#
# So the suite runs on this, and `suite/corpus.jl` is where the real dashboard
# is still swept - over every row, and skipped when there is no dashboard.
#
# **Written from real rows rather than invented**, which is the half of the old
# argument worth keeping: the husks the bulk lanes return, a `null` review
# decision, an item with no `state`, a title with a code span in it are all
# things that turn up here and that nobody would think to invent. Every row
# below is a real one, picked by the property some testset needs, with `WANTED`
# as the record of which property that was. Nothing is edited on the way through
# except the one row that is put to sleep, because being asleep is the refresh's
# answer and no refresh runs in a test.
#
# **Regenerating it is a deliberate act, not part of the run.** This reads the
# real dashboard, so it only works on a machine that has one; the output is
# committed and the suite reads that. Run it when a testset needs a shape the
# fixture has not got - and add the property to `WANTED` in the same breath, so
# the next regeneration keeps it.

using Worklog
const W = Worklog

me() = W.login()
act(r) = something(W.jget(r, :head_at), W.jget(r, :last_comment_at), W.jget(r, :updated), "")
labels(r) = W.jget(r, :labels, ())
assignees(r) = W.jget(r, :assignees, ())
mine(r) = W.jget(r, :author) == me() || me() in assignees(r)

# One row each, and the testset that wants it. A property nobody tests for does
# not belong here: this file is the declaration of what the suite needs to be
# true of its corpus, and a row that declares nothing is a row that can rot.
const WANTED = [
    "yours, open, with a branch and labels" =>
        r -> W.jget(r, :type) == "PullRequest" && W.jget(r, :author) == me() &&
             W.jget(r, :state) == "OPEN" && !isempty(W.nz(W.jget(r, :branch), "")) &&
             !isempty(W.nz(W.jget(r, :head_sha), "")) && !isempty(labels(r)),
    "somebody else's, open, awake" =>
        r -> W.jget(r, :type) == "PullRequest" && !mine(r) &&
             W.jget(r, :snoozed) !== true && W.jget(r, :state) == "OPEN",
    "an issue" => r -> W.jget(r, :type) == "Issue" && W.jget(r, :state) == "OPEN",
    "an issue GitHub put on you" =>
        r -> W.jget(r, :type) == "Issue" && me() in assignees(r) &&
             W.jget(r, :author) != me(),
    "merged" => r -> W.jget(r, :state) == "MERGED",
    "closed" => r -> W.jget(r, :state) == "CLOSED",
    "a number above 999, for the `/` jump" =>
        r -> W.jget(r, :number) > 999 && !isempty(labels(r)),
    "no labels at all" => r -> isempty(labels(r)),
    "waiting on somebody, with a reason" =>
        r -> !isempty(W.nz(W.jget(r, :second_look), "")),
    "unresolved review threads" => r -> W.nz(W.jget(r, :unresolved), 0) > 0,
    "red CI, and yours" =>
        r -> W.jget(r, :ci) == "FAILURE" && W.jget(r, :author) == me(),
    "approved by somebody" => r -> W.jget(r, :review_decision) == "APPROVED",
    "quiet since 2024" => r -> !isempty(act(r)) && act(r) < "2024-06-01",
    "quiet since the spring" =>
        r -> !isempty(act(r)) && "2026-01" < act(r) < "2026-09-02",
    "a bot spoke last" =>
        r -> occursin("bot", lowercase(W.nz(W.jget(r, :last_comment_by), ""))),
    "a draft" => r -> W.jget(r, :draft) === true,
    # Taken twice on purpose: the second one is put to sleep below, and a
    # testset that wants an *awake* pull request of somebody else's would get a
    # snoozed one if there were only the one row to be both.
    "somebody else's again, to be the one asleep" =>
        r -> W.jget(r, :type) == "PullRequest" && !mine(r) &&
             W.jget(r, :state) == "OPEN",
]

"The row `build` puts to sleep, named by the property it was taken for."
const ASLEEP = "somebody else's again, to be the one asleep"

"""Every lane there is, one row each.

The lane axis is built from the lanes the rows carry, and `filter_rows` is
asserted to list every one that would select something - uncapped, which is
the whole point of that testset and needs more than the eight the cap allowed.
"""
lane_rows(rows, taken) = begin
    out = Pair{String,Any}[]
    for b in sort(unique(String(W.nz(W.jget(r, :lane), "")) for r in rows))
        isempty(b) && continue
        i = findfirst(r -> W.jget(r, :lane) == b && !(W.jget(r, :number) in taken), rows)
        i === nothing && continue
        push!(taken, W.jget(rows[i], :number))
        push!(out, string("the ", b, " lane") => rows[i])
    end
    out
end

"Plain Julia all the way down, so `json_dumps` writes it the way a refresh does."
plain(v) = v isa AbstractDict ?
           Dict{String,Any}(String(k) => plain(x) for (k, x) in v) :
           (v isa AbstractVector ? Any[plain(x) for x in v] : v)

function build()
    its = W.fetched("items")
    its === nothing && error("no dashboard here to take a fixture from")
    rows = sort([r for (_, r) in its]; by = r -> String(W.jget(r, :url)))
    taken, out, why = Set{Any}(), Dict{String,Any}(), String[]
    urls = Dict{String,String}()
    take!(name, r) = begin
        push!(taken, W.jget(r, :number))
        urls[name] = String(W.jget(r, :url))
        out[String(W.jget(r, :url))] = plain(r)
        push!(why, string(rpad(String(W.jget(r, :repo)) * "#" * string(W.jget(r, :number)), 42), name))
    end
    for (name, pred) in WANTED
        i = findfirst(r -> !(W.jget(r, :number) in taken) && pred(r), rows)
        i === nothing ? push!(why, string(rpad("MISSING", 42), name)) : take!(name, rows[i])
    end
    for (name, r) in lane_rows(rows, taken)
        take!(name, r)
    end
    # **Numbers are unique across the fixture**, because `/` jumps by number and
    # a testset that means one row would otherwise get whichever came first.
    @assert length(unique(r["number"] for r in values(out))) == length(out)

    # The one edit. Being asleep is the refresh's answer carried on the row -
    # `sleep_of` reads `it.snoozed`, and only `filed` is a mark in `local.toml`
    # - so a corpus taken from a dashboard with nothing asleep in it has no
    # snoozed row, and that is exactly how `search.jl` came to error.
    asleep = out[urls[ASLEEP]]
    asleep["snoozed"] = true
    asleep["snooze_why"] = "until it moves"
    push!(why, string(rpad(asleep["repo"] * "#" * string(asleep["number"]), 42),
                      "put to sleep here: nothing on a live dashboard has to be"))

    for l in sort(why)
        println("  ", l)
    end
    println("  ", length(out), " rows")
    (out, urls)
end

# **The names go into the file beside the rows.** A testset that wants the row
# with a property asks for it by the name of the property - `fixture_item("an
# issue")` - so the thing it depends on is written where it depends on it, and a
# regeneration that could not find one fails by name instead of handing back
# `nothing` to be used as an index. Nothing in the program reads this key, and
# `put_fetched!` keeps it.
let (out, urls) = build()
    path = joinpath(@__DIR__, "fixture.json")
    W.write_atomic(path, W.json_dumps(Dict{String,Any}("items" => out,
                                                       "wanted" => urls),
                                      indent = 1, sortkeys = true))
    println("wrote ", path)
end
