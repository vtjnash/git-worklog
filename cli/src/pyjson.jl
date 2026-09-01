# A JSON writer that reproduces CPython's `json.dumps` byte for byte.
#
# Not gratuitous. Three of the files here are read back by this program and one
# of them (`snooze.json`) is committed, so the serialisation is part of the file
# format: `facts.json` and `snooze.json` are written with `indent=1,
# sort_keys=True` and the GraphQL request bodies with the default `", "` / `": "`
# separators. JSON3's writer emits none of those shapes, so it would have made
# every refresh show up as a whole-file diff and would have made the port
# impossible to check against the Python it replaces.
#
# Ordered objects are `Vector{Pair{String,Any}}` or `OrderedDict`; `sortkeys`
# reorders them by code point, which is what `sort_keys=True` does and what
# Julia's `isless` on `String` already gives us.

const JSONObj = Union{AbstractDict,Vector{<:Pair}}

_pairs(o::AbstractDict) = collect(o)
_pairs(o::Vector{<:Pair}) = o

function _jstring(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c < ' '
            print(io, "\\u", string(UInt32(c), base = 16, pad = 4))
        elseif c <= '\x7f'
            print(io, c)
        else
            # ensure_ascii=True is CPython's default: everything above ASCII
            # becomes \uXXXX, and astral planes become a surrogate pair.
            u = UInt32(c)
            if u > 0xffff
                u -= 0x10000
                print(io, "\\u", string(0xd800 + (u >> 10), base = 16, pad = 4))
                print(io, "\\u", string(0xdc00 + (u & 0x3ff), base = 16, pad = 4))
            else
                print(io, "\\u", string(u, base = 16, pad = 4))
            end
        end
    end
    print(io, '"')
end

function _jvalue(io::IO, v, indent, level, sortkeys)
    if v === nothing || v === missing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa Integer
        print(io, v)
    elseif v isa AbstractFloat
        print(io, v)
    elseif v isa AbstractString
        _jstring(io, v)
    elseif v isa JSONObj
        _jobject(io, v, indent, level, sortkeys)
    elseif v isa AbstractVector
        _jarray(io, v, indent, level, sortkeys)
    else
        _jstring(io, string(v))     # matches json.dumps(default=str)
    end
end

function _jopen(io, open, indent, level)
    print(io, open)
    indent === nothing || print(io, '\n', ' '^(indent * (level + 1)))
end
_jsep(io, indent, level) =
    indent === nothing ? print(io, ", ") : print(io, ",\n", ' '^(indent * (level + 1)))
function _jclose(io, close, indent, level)
    indent === nothing || print(io, '\n', ' '^(indent * level))
    print(io, close)
end

function _jobject(io::IO, o, indent, level, sortkeys)
    ps = _pairs(o)
    isempty(ps) && return print(io, "{}")
    sortkeys && (ps = sort(ps; by = p -> String(first(p))))
    _jopen(io, '{', indent, level)
    for (i, p) in enumerate(ps)
        i == 1 || _jsep(io, indent, level)
        _jstring(io, String(first(p)))
        print(io, ": ")
        _jvalue(io, last(p), indent, level + 1, sortkeys)
    end
    _jclose(io, '}', indent, level)
end

function _jarray(io::IO, a, indent, level, sortkeys)
    isempty(a) && return print(io, "[]")
    _jopen(io, '[', indent, level)
    for (i, v) in enumerate(a)
        i == 1 || _jsep(io, indent, level)
        _jvalue(io, v, indent, level + 1, sortkeys)
    end
    _jclose(io, ']', indent, level)
end

"""
    json_dumps(v; indent=nothing, sortkeys=false) -> String

`json.dumps(v, indent=indent, sort_keys=sortkeys, default=str)`.
"""
function json_dumps(v; indent = nothing, sortkeys = false)
    io = IOBuffer()
    _jvalue(io, v, indent, 0, sortkeys)
    String(take!(io))
end
