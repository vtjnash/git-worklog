# Summarize test/expected/*.toml: how each test file's snapshots compare with
# Term's. Snapshots not listed match Term's bytes; count those from txtfiles
# by name is not possible, so this counts only what the manifests list.
import TOML
dir = joinpath(@__DIR__, "expected")
total = Dict("cells" => 0, "reflow" => 0, "text" => 0, "none" => 0)
println(rpad("file", 26), lpad("cells", 7), lpad("reflow", 7), lpad("text", 7), lpad("none", 7))
for f in sort(readdir(dir))
    d = TOML.parsefile(joinpath(dir, f))
    c = Dict(l => count(==(l), values(d)) for l in keys(total))
    foreach(l -> total[l] += c[l], keys(total))
    println(rpad(splitext(f)[1], 26), lpad(c["cells"], 7), lpad(c["reflow"], 7), lpad(c["text"], 7), lpad(c["none"], 7))
end
println(rpad("total", 26), lpad(total["cells"], 7), lpad(total["reflow"], 7), lpad(total["text"], 7), lpad(total["none"], 7))
