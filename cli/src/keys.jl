"""
    Worklog.Keys

The key vocabulary: one code per key, whether or not the key stands for a
character someone typed.

A submodule because this is the piece with the fewest ties to anything here.
Every view names these constants and nothing else about them is this program's;
`readevent` in `controller.jl` is what produces them, and it too is a pure
function of a byte stream. If the decoding ever goes upstream - see the note in
`TODO.md` - this is the half that goes with it, and the split is already made.
"""
module Keys

export K_BASE, K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
       K_PGDN, K_STAB, K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_EDIT,
       K_SUP, K_SDOWN, printable, keychar, keycode, unshift

"""Where the keys that are not characters start.

**A key code below this is the bytes that arrived, packed big-endian.** One byte
is `0x00`-`0xFF`, so `k == Int('j')`, `k == 13` and `k == 27` are what they have
always been. A multi-byte UTF-8 sequence is its bytes in order, which is always
above `0xFF` because the lead byte of one is at least `0xC0`. The widest a
sequence can be is four bytes, so everything at `1 << 32` and up is free.

It is *not* a codepoint, and that is the point. Decoding to one is a lossy step
in both directions. `Int(c)` on a malformed sequence either throws - a lone
`0x80` has no codepoint at all - or answers something that was never typed: `C0
80` becomes `0`, a NUL, and `F4 90 80 80` becomes `1114112`. With the key space
starting at `0x110000`, one past the last codepoint, that last one *was* `K_LEFT`
and `F4 90 80 82` was `K_UP`, so a paste of arbitrary bytes moved the cursor.

Rejecting malformed input would fix the collision and is still the wrong answer,
because Julia does not need us to. A `Char` is four bytes of UTF-8 held as they
came, and arbitrary binary survives a round trip through a `String` intact - it
is only `codepoint` that refuses. So nothing is decoded and nothing is thrown
away: the bytes are carried, [`keychar`](@ref) hands them back, and what a
terminal sends is what a comment gets.

The framing is Julia's own, so that a sequence put into a buffer comes back out
of it as the same one `Char`: `0xC0`-`0xF7` lead a sequence and take their
continuation bytes, while `0xF8` and above are not lead bytes at all and stand
alone, as does a continuation byte with no lead and a lead whose continuation
never arrived.
"""
const K_BASE  = 1 << 32
const K_LEFT  = K_BASE + 0
const K_RIGHT = K_BASE + 1
const K_UP    = K_BASE + 2
const K_DOWN  = K_BASE + 3
const K_DEL   = K_BASE + 4
const K_HOME  = K_BASE + 5
const K_END   = K_BASE + 6
const K_PGUP  = K_BASE + 7
const K_PGDN  = K_BASE + 8
const K_STAB  = K_BASE + 9     # Shift-Tab, CSI Z
const K_WORD_LEFT  = K_BASE + 10
const K_WORD_RIGHT = K_BASE + 11
const K_WORD_BACK  = K_BASE + 12    # delete the word before the cursor
const K_EDIT       = K_BASE + 13    # Alt-e, as the REPL binds it
const K_SUP        = K_BASE + 14    # Shift-Up and Shift-Down, which are the
const K_SDOWN      = K_BASE + 15    # arrows' own keys and not modifiers here:
                                    # only the detail pane does anything with
                                    # the shift, and a view that has no
                                    # selection to extend passes them through
                                    # `unshift`

"""A key that stands for something someone meant to type.

Anything below [`K_BASE`](@ref) that is not a control byte, which includes bytes
that are not a character on their own. That is deliberate: they are what was
typed or pasted, and [`keychar`](@ref) can hand every one of them back.
"""
printable(k::Int) = (k >= 32 && k != 127 && k < K_BASE)

"""The bytes of `k` as the `Char` they are, however malformed.

Their count is their magnitude - a two-byte sequence starts at `0xC080`, a three
at `0xE08080`, a four at `0xF0808080` - and a `Char` holds them left-aligned,
which is all this has to do. Nothing is validated, because nothing was decoded.
"""
function keychar(k::Int)
    n = k > 0xFFFFFF ? 0 : k > 0xFFFF ? 1 : k > 0xFF ? 2 : 3
    reinterpret(Char, UInt32(k) << (8 * n))
end

"""The key code for `c`: its bytes, packed. The inverse of [`keychar`](@ref),
for a caller with a character in hand and a key stream to put it into.
"""
keycode(c::Char) =
    Int(reinterpret(UInt32, c) >> (8 * (4 - ncodeunits(c))))

"""Shift-Up and Shift-Down for a view with no selection to extend: the plain
arrow. A key drawn on the arrow that does nothing at all reads as a terminal
that has stopped responding.
"""
unshift(k::Int) = k == K_SUP ? K_UP : k == K_SDOWN ? K_DOWN : k

end # module Keys
