#!/usr/bin/env python3
"""
mkfont.py <font16.mem> <out.hex>

The text mode's font (rtl/k_text.v): 256 characters of 16 rows, a byte
a row, bit 7 the leftmost pixel, one byte a line in hex.

0x20..0x7f are Zeitlos's 8x16 font (sw/data/font/font16.mem: 96
characters from the space on, a row a line, eight 0s and 1s). The
boxes and blocks are drawn here, at the places the PC's character set
has them, which is what a terminal's line drawing maps to.

Latin-1 (U+00A0..U+00FF) is made here too, in the places the boxes
leave: the accented letters from the font's own letters and an accent
drawn over them, the rest drawn below. slot() says where: U+00A0..CF
at 0x80..0xaf, U+00D0..EF at 0xe0..0xff, U+00F0..FF at 0x10..0x1f, and
the euro sign at 0x01. fw/iop/term.c has the same rule.
"""
import sys

def slot(u):
    """where a character beyond ASCII is in the font"""
    if 0xa0 <= u <= 0xcf: return u - 0x20
    if 0xd0 <= u <= 0xef: return u + 0x10
    if 0xf0 <= u <= 0xff: return u - 0xe0
    if u == 0x20ac: return 0x01
    return None

def art(rows, top=0):
    """a glyph from rows of '#' and '.', the first at row top"""
    g = [0] * 16
    for i, r in enumerate(rows):
        g[top + i] = int(r.replace("#", "1").replace(".", "0").ljust(8, "0"), 2)
    return g

ACCENT = {
    "grave": ["..##....", "...##..."],
    "acute": ["....##..", "...##..."],
    "circ":  ["..###...", ".##.##.."],
    "tilde": [".###.##.", "##.###.."],
    "uml":   [".##..##.", ".##..##."],
    "ring":  ["..###...", "..#.#...", "..###..."],
}

def latin1(font):
    def over(base, accent):
        g = list(font[ord(base)])
        a = ACCENT[accent]
        if base.isupper():
            top = 0                       # over a capital: the two top rows
            if accent == "ring": a = a[:2]
        else:
            top = 4 - len(a)              # over a small letter: above row 4
            if base == "i":               # (without its dot)
                g[2] = g[3] = 0
        for i, r in enumerate(a):
            g[top + i] |= int(r.replace("#", "1").replace(".", "0"), 2)
        return g

    def cedilla(base):
        g = list(font[ord(base)])
        g[12] |= 0b00011000; g[13] |= 0b00001100; g[14] |= 0b00111000
        return g

    def slash(base):
        g = list(font[ord(base)])
        rows = range(2, 12) if base.isupper() else range(5, 12)
        n = len(rows)
        for i, y in enumerate(rows):
            x = 6 - (i * 6) // (n - 1)
            g[y] |= 0x80 >> x
        return g

    names = ["grave", "acute", "circ", "tilde", "uml", "ring"]
    def put(u, g): font[slot(u)] = g
    # A..: grave acute circ tilde uml ring
    for u0, base, accs in (
        (0xc0, "A", names), (0xc8, "E", ["grave", "acute", "circ", "uml"]),
        (0xcc, "I", ["grave", "acute", "circ", "uml"]),
        (0xd2, "O", ["grave", "acute", "circ", "tilde", "uml"]),
        (0xd9, "U", ["grave", "acute", "circ", "uml"]),
        (0xe0, "a", names), (0xe8, "e", ["grave", "acute", "circ", "uml"]),
        (0xec, "i", ["grave", "acute", "circ", "uml"]),
        (0xf2, "o", ["grave", "acute", "circ", "tilde", "uml"]),
        (0xf9, "u", ["grave", "acute", "circ", "uml"]),
    ):
        for i, a in enumerate(accs): put(u0 + i, over(base, a))
    put(0xd1, over("N", "tilde")); put(0xf1, over("n", "tilde"))
    put(0xdd, over("Y", "acute")); put(0xfd, over("y", "acute")); put(0xff, over("y", "uml"))
    put(0xc7, cedilla("C")); put(0xe7, cedilla("c"))
    put(0xd8, slash("O")); put(0xf8, slash("o"))

    put(0xa0, [0] * 16)
    put(0xa1, art(["...##...", "...##...", "........", "...##...", "...##...", "..####..",
                   "..####..", "..####..", "...##..."], 4))                       # inverted !
    put(0xa2, art(["...##...", "...##...", ".#####..", "##...##.", "##......", "##......",
                   "##...##.", ".#####..", "...##...", "...##..."], 3))           # cent
    put(0xa3, art(["..###...", ".##.##..", ".##..#..", ".##.....", "####....", ".##.....",
                   ".##.....", ".##.....", "###..##.", "######.."], 2))           # pound
    put(0xa4, art(["##...##.", ".#####..", ".##.##..", ".##.##..", ".#####..", "##...##."], 5))
    put(0xa5, art([".##..##.", ".##..##.", "..####..", "...##...", ".######.", "...##...",
                   ".######.", "...##...", "...##...", "...##..."], 2))           # yen
    put(0xa6, art(["...##...", "...##...", "...##...", "...##...", "........", "........",
                   "...##...", "...##...", "...##...", "...##..."], 2))           # broken bar
    put(0xa7, art([".#####..", "##...##.", ".##.....", "..###...", ".##.##..", "##...##.",
                   "##...##.", ".##.##..", "..###...", "....##..", "##...##.", ".#####.."], 1))  # section
    put(0xa8, art([".##..##.", ".##..##."], 2))
    put(0xa9, art(["..####..", ".#....#.", "#..##..#", "#.#....#", "#.#....#", "#..##..#",
                   ".#....#.", "..####.."], 3))                                  # copyright
    put(0xaa, art(["..####..", ".##.##..", ".##.##..", "..#####.", "........", ".######."], 2))
    put(0xab, art(["..##.##.", ".##.##..", "##.##...", ".##.##..", "..##.##."], 6))
    put(0xac, art(["#######.", ".....##.", ".....##.", ".....##."], 7))          # not
    put(0xad, art([".######."], 8))
    put(0xae, art(["..####..", ".#....#.", "#.###..#", "#.#..#.#", "#.###..#", "#.#.#..#",
                   ".#....#.", "..####.."], 3))                                  # registered
    put(0xaf, art(["#######."], 1))
    put(0xb0, art(["..###...", ".##.##..", ".##.##..", "..###..."], 2))          # degree
    put(0xb1, art(["...##...", "...##...", ".######.", "...##...", "...##...", "........",
                   ".######."], 5))                                              # plus-minus
    put(0xb2, art([".###....", "##.##...", "..##....", ".##.....", "#####..."], 2))
    put(0xb3, art(["####....", "...##...", ".###....", "...##...", "####...."], 2))
    put(0xb4, art(["....##..", "...##...", "..##...."], 1))
    put(0xb5, art([".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.", ".##..##.",
                   ".#####..", ".##.....", ".##.....", "##......"], 5))           # micro
    put(0xb6, art([".#######", "##.##.##", "##.##.##", "##.##.##", ".####.##", "...##.##",
                   "...##.##", "...##.##", "...##.##", "...##.##"], 2))           # pilcrow
    put(0xb7, art(["...##...", "...##..."], 7))
    put(0xb8, art(["...##...", "....##..", "..###..."], 12))
    put(0xb9, art(["..##....", ".###....", "..##....", "..##....", ".####..."], 2))
    put(0xba, art(["..###...", ".##.##..", ".##.##..", "..###...", "........", ".#####.."], 2))
    put(0xbb, art(["##.##...", ".##.##..", "..##.##.", ".##.##..", "##.##..."], 6))
    quarter = ["##......", ".#...#..", ".#..#...", ".#.#....", "..#.....", ".#..#.#.", "#..##.#.",
               "..#.#.#.", "..#####.", "......#."]
    half    = ["##......", ".#...#..", ".#..#...", ".#.#....", "..#.....", ".#.###..", "#.#..##.",
               "....##..", "...##...", "..#####."]
    three   = ["###.....", "..#..#..", ".##.#...", "..##....", "###.#...", ".#..#.#.", "#..##.#.",
               "..#.#.#.", "..#####.", "......#."]
    put(0xbc, art(quarter, 2)); put(0xbd, art(half, 2)); put(0xbe, art(three, 2))
    put(0xbf, art(["..##....", "..##....", "........", "..##....", "..##....", ".##.....",
                   "##......", "##...##.", "##...##.", ".#####.."], 3))           # inverted ?
    put(0xc6, art(["..#####.", ".##.##..", "##..##..", "##..##..", "#######.", "##..##..",
                   "##..##..", "##..##..", "##..##..", "##..###."], 2))           # AE
    put(0xd0, art(["#####...", ".##.##..", ".##..##.", ".##..##.", "####.##.", ".##..##.",
                   ".##..##.", ".##..##.", ".##.##..", "#####..."], 2))           # Eth
    put(0xd7, art(["##...##.", ".##.##..", "..###...", ".##.##..", "##...##."], 6))  # times
    put(0xde, art(["####....", ".##.....", ".#####..", ".##..##.", ".##..##.", ".##..##.",
                   ".#####..", ".##.....", ".##.....", "####...."], 2))           # Thorn
    put(0xdf, art([".####...", "##..##..", "##..##..", "##.##...", "##..##..", "##...##.",
                   "##...##.", "##...##.", "##.###..", "##......"], 2))           # sharp s
    put(0xe6, art([".##.###.", "...##.##", ".######.", "##.##...", "##.##.##", ".###.##.", ".###.##."][0:6] + [], 5))  # ae
    put(0xf0, art([".##.#...", "..##....", ".#.##...", "....##..", ".#####..", "##...##.",
                   "##...##.", "##...##.", "##...##.", ".#####.."], 2))           # eth
    put(0xf7, art(["...##...", "...##...", "........", ".######.", "........", "...##...",
                   "...##..."], 5))                                              # divide
    put(0xfe, art(["###.....", ".##.....", ".##.....", ".#####..", ".##..##.", ".##..##.",
                   ".##..##.", ".##..##.", ".#####..", ".##.....", ".##.....", "####...."], 2))  # thorn
    font[0x01] = art(["..####..", ".##..##.", "##......", "#####...", "##......", "#####...",
                      "##......", ".##..##.", "..####.."], 3)                      # euro

def main():
    src, out = sys.argv[1], sys.argv[2]
    rows = [l.split() for l in open(src) if l.strip() and l.strip()[0] in "01"]
    assert len(rows) == 96 * 16 and all(len(r) == 8 for r in rows), "not a 96-character 8x16 font"
    font = [[0] * 16 for _ in range(256)]
    for i in range(96):
        font[0x20 + i] = [int("".join(r), 2) for r in rows[i * 16:(i + 1) * 16]]

    # boxes: lines from the centre (column 3-4, row 7-8) up, down, left, right
    def box(up, down, left, right):
        g = [0] * 16
        for y in range(16):
            b = 0
            if (up and y <= 8) or (down and y >= 7):
                b |= 0x18
            if y in (7, 8):
                if left:
                    b |= 0xf8
                if right:
                    b |= 0x1f
            g[y] = b
        return g
    for code, udlr in {
        0xb3: (1, 1, 0, 0), 0xc4: (0, 0, 1, 1), 0xda: (0, 1, 0, 1), 0xbf: (0, 1, 1, 0),
        0xc0: (1, 0, 0, 1), 0xd9: (1, 0, 1, 0), 0xc3: (1, 1, 0, 1), 0xb4: (1, 1, 1, 0),
        0xc2: (0, 1, 1, 1), 0xc1: (1, 0, 1, 1), 0xc5: (1, 1, 1, 1),
    }.items():
        font[code] = box(*udlr)

    # blocks and shades
    font[0xdb] = [0xff] * 16
    font[0xdc] = [0] * 8 + [0xff] * 8
    font[0xdf] = [0xff] * 8 + [0] * 8
    font[0xdd] = [0xf0] * 16
    font[0xde] = [0x0f] * 16
    font[0xb0] = [0x88 if y % 2 == 0 else 0x22 for y in range(16)]
    font[0xb1] = [0xaa if y % 2 == 0 else 0x55 for y in range(16)]
    font[0xb2] = [0x77 if y % 2 == 0 else 0xdd for y in range(16)]
    # what is not there shows as a small box, not as nothing
    font[0x7f] = [0, 0, 0x7e, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x7e, 0, 0, 0, 0]

    latin1(font)

    with open(out, "w") as f:
        for g in font:
            for b in g:
                f.write("%02x\n" % b)

if __name__ == "__main__":
    main()
