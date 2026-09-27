# A JSON writer that reproduces CPython's `json.dumps` byte for byte.
#
# Not gratuitous. The state files are committed - `local.toml`, `fetched.json` -
# so their serialisation is part of the file format: those are written with
# `indent=1, sort_keys=True`, and the GraphQL request bodies with the default
# `", "` / `": "` separators. JSON3's writer emits neither shape, so every
# refresh would have shown up as a whole-file diff and the port would have been
# impossible to check against the Python it replaces.
#
# Ordered objects are `Vector{Pair{String,Any}}` or `OrderedDict`; `sortkeys`
# reorders them by code point, which is what `sort_keys=True` does and what
# Julia's `isless` on `String` already gives us.

# Written for `--trim`: `_jvalue` is called with a value whose static type is
# concrete, so each of its branches folds; a value typed `Any` - a field of a
# `Dict{String,Any}`, an element of a `Vector{Any}` - goes through `_jany`.
function _jstring(io::IO, s::AbstractString)
    print(io, '"')
    for c::Char in s
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
    elseif v isa Symbol
        _jstring(io, String(v))
    elseif v isa AbstractDict
        _jobject(io, v, indent, level, sortkeys)
    elseif v isa Vector{<:Pair}
        _jobject(io, v, indent, level, sortkeys)
    elseif v isa NamedTuple
        _jnt(io, v, indent, level)
    elseif v isa AbstractVector
        _jarray(io, v, indent, level, sortkeys)
    elseif v isa Tuple
        _jarray(io, v, indent, level, sortkeys)
    else
        _jstring(io, string(v))     # matches json.dumps(default=str)
    end
end

"""The value of a field typed `Any`: the shapes the program stores are tested
first, so writing them is a static call; anything else is written as it always
was, through one dynamic call."""
function _jany(io::IO, @nospecialize(v), indent, level, sortkeys)
    v === nothing ? print(io, "null") :
    v isa Bool ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Int ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Float64 ? _jvalue(io, v, indent, level, sortkeys) :
    v isa String ? _jvalue(io, v, indent, level, sortkeys) :
    v isa JSON.Object{String,Any} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Dict{String,Any} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa OrderedDict{String,Any} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Dict{String,String} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Vector{Any} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Vector{String} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Vector{Dict{String,Any}} ? _jvalue(io, v, indent, level, sortkeys) :
    v isa Vector{OrderedDict{String,Any}} ? _jvalue(io, v, indent, level, sortkeys) :
    _jvalue(io, v, indent, level, sortkeys)
end

@inline _jelem(io::IO, v, ::Type{T}, indent, level, sortkeys) where {T} =
    isconcretetype(T) ? _jvalue(io, v::T, indent, level, sortkeys) : _jany(io, v, indent, level, sortkeys)

@generated function _jnt(io::IO, nt::NamedTuple{K,V}, indent, level) where {K,V}
    body = Any[:(_jopen(io, '{', indent, level))]
    for (i, k) in enumerate(K)
        i == 1 || push!(body, :(_jsep(io, indent, level)))
        push!(body, :(_jstring(io, $(String(k)))), :(print(io, ": ")))
        push!(body, :(_jelem(io, getfield(nt, $i), $(fieldtype(V, i)), indent, level + 1, false)))
    end
    isempty(K) ? :(print(io, "{}")) : Expr(:block, body..., :(_jclose(io, '}', indent, level)))
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

_pairs(o::AbstractDict{K,V}) where {K,V} = collect(Pair{K,V}, o)
_pairs(o::Vector{<:Pair}) = o
_valtype(::Vector{Pair{K,V}}) where {K,V} = V
_valtype(::Vector{P}) where {P<:Pair} = Any

function _jobject(io::IO, o, indent, level, sortkeys)
    ps = _pairs(o)
    isempty(ps) && return print(io, "{}")
    sortkeys && (ps = sort(ps; by = p -> String(first(p))))
    V = _valtype(ps)
    _jopen(io, '{', indent, level)
    for (i, p) in enumerate(ps)
        i == 1 || _jsep(io, indent, level)
        _jstring(io, String(first(p)))
        print(io, ": ")
        _jelem(io, last(p), V, indent, level + 1, sortkeys)
    end
    _jclose(io, '}', indent, level)
end

function _jarray(io::IO, a, indent, level, sortkeys)
    isempty(a) && return print(io, "[]")
    _jopen(io, '[', indent, level)
    for (i, v) in enumerate(a)
        i == 1 || _jsep(io, indent, level)
        _jelem(io, v, eltype(a), indent, level + 1, sortkeys)
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
