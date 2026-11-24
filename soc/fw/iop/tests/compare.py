#!/usr/bin/env python3
"""
compare.py <term_test> <file>...     compare on these texts
compare.py <term_test> --fuzz N [seed]   and on N made-up ones

The terminal (term.c, built for this machine as term_test) against
pyte, a terminal emulator in Python: the same bytes to both, then the
characters on the screen, their colours and the cursor must agree.
Cells where pyte has a character outside ASCII are compared only for
not being a space (the text mode has its own character set).
"""
import random
import subprocess
import sys

import pyte

COLS, ROWS = 80, 30
ANSI = ["black", "red", "green", "brown", "blue", "magenta", "cyan", "white"]
PC = [0, 4, 2, 6, 1, 5, 3, 7]


def colour(name, default):
    """pyte's colour name as the text mode's four bits (without bold)"""
    if name == "default":
        return default
    if name.startswith("bright"):
        return PC[ANSI.index(name[6:])] | 8
    if name in ANSI:
        return PC[ANSI.index(name)]
    return None        # 256-colour and RGB: not compared


class Screen(pyte.Screen):
    """pyte, put right where it differs from xterm and Linux's console
    (and so from the terminal): a move of the cursor ends "about to
    wrap"; up and down stop at the region's edge only coming from
    inside it; setting the region always homes the cursor; erasing
    ends "about to wrap" too (Linux's console); a restored cursor is
    not moved into the region."""

    def _unwrap(self):
        if self.cursor.x >= self.columns:
            self.cursor.x = self.columns - 1

    def cursor_up(self, count=None):
        top, _ = self.margins or pyte.screens.Margins(0, self.lines - 1)
        lim = top if self.cursor.y >= top else 0
        self.cursor.y = max(self.cursor.y - (count or 1), lim)
        self._unwrap()

    def cursor_down(self, count=None):
        _, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        lim = bottom if self.cursor.y <= bottom else self.lines - 1
        self.cursor.y = min(self.cursor.y + (count or 1), lim)
        self._unwrap()

    def cursor_to_line(self, line=None):
        super().cursor_to_line(line)
        self._unwrap()

    def index(self):
        self._unwrap()
        super().index()

    def reverse_index(self):
        self._unwrap()
        super().reverse_index()

    def erase_in_line(self, how=0, private=False):
        self._unwrap()
        super().erase_in_line(how, private)

    def erase_in_display(self, how=0, *args, **kwargs):
        self._unwrap()
        super().erase_in_display(how, *args, **kwargs)

    def erase_characters(self, count=None):
        self._unwrap()
        super().erase_characters(count)

    def insert_characters(self, count=None):
        self._unwrap()
        super().insert_characters(count)
        # (pyte keeps what was pushed off the edge, one column out)
        self.buffer[self.cursor.y].pop(self.columns, None)

    def delete_characters(self, count=None):
        self._unwrap()
        super().delete_characters(count)

    def delete_lines(self, count=None):
        # (pyte's own leaves a line in place when the one that should
        # replace it was never written)
        count = count or 1
        top, bottom = self.margins or pyte.screens.Margins(0, self.lines - 1)
        if top <= self.cursor.y <= bottom:
            for y in range(self.cursor.y, bottom + 1):
                if y + count <= bottom and (y + count) in self.buffer:
                    self.buffer[y] = self.buffer.pop(y + count)
                else:
                    self.buffer.pop(y, None)
            self.carriage_return()

    def restore_cursor(self):
        if not self.savepoints:
            return super().restore_cursor()
        margins, self.margins = self.margins, None
        super().restore_cursor()
        self.margins = margins

    def set_margins(self, top=None, bottom=None):
        if (top is None or top == 0) and bottom is None:
            self.margins = None
            self.cursor_position()
            return
        super().set_margins(top, bottom)


def want(data):
    screen = Screen(COLS, ROWS)
    stream = pyte.ByteStream(screen)
    stream.feed(data)
    text, attrs = [], []
    for y in range(ROWS):
        row, arow = "", []
        for x in range(COLS):
            ch = screen.buffer[y][x]
            c = ch.data if ch.data else " "
            row += c if 0x20 <= ord(c[0]) < 0x7f else "\x00"
            f, b = colour(ch.fg, 7), colour(ch.bg, 0)
            if f is None or b is None:
                arow.append(None)
                continue
            if ch.bold:
                f |= 8
            a = ((f & 7) << 4 | b) if ch.reverse else (b << 4 | f)
            arow.append(a)
        text.append(row)
        attrs.append(arow)
    return text, attrs, (screen.cursor.y, min(screen.cursor.x, COLS - 1))


def got(prog, data):
    out = subprocess.run([prog], input=data, capture_output=True).stdout.decode().split("\n")
    text = out[0:ROWS]
    attrs = [[int(l[2 * i:2 * i + 2], 16) for i in range(COLS)] for l in out[ROWS:2 * ROWS]]
    cur = out[2 * ROWS].split()
    return text, attrs, (int(cur[1]), int(cur[2])), out[2 * ROWS + 1]


def compare(prog, data, name, quiet=False):
    wt, wa, wc = want(data)
    gt, ga, gc, _ = got(prog, data)
    bad = []
    for y in range(ROWS):
        for x in range(COLS):
            w, g = wt[y][x], gt[y][x]
            if w == "\x00":
                if g == " ":
                    bad.append((y, x, "a character", repr(g)))
                continue
            if w != g:
                bad.append((y, x, repr(w), repr(g)))
            elif wa[y][x] is not None and wa[y][x] != ga[y][x]:
                # erased cells: the terminal gives them the background
                # colour, as Linux's console does, and pyte does not
                if w == " ":
                    continue
                bad.append((y, x, "colour %02x" % wa[y][x], "%02x" % ga[y][x]))
    if wc != gc:
        bad.append((wc[0], wc[1], "the cursor", "at %d,%d" % gc))
    if bad and not quiet:
        print("%s: FAIL, %d differences" % (name, len(bad)))
        for y, x, w, g in bad[:8]:
            print("   row %d column %d: pyte has %s, the terminal %s" % (y, x, w, g))
    elif not quiet:
        print("%s: ok" % name)
    return not bad


def made_up(rng):
    """a stream of text and of the sequences both sides should agree on"""
    out = bytearray()
    words = [b"kakao", b"linux", b"root@kakao:~# ", b"ls -l", b"x", b"The quick brown fox", b"0123456789" * 3]
    for _ in range(rng.randrange(20, 400)):
        k = rng.randrange(100)
        n = rng.randrange(1, 12)
        if k < 40:
            out += rng.choice(words)
        elif k < 50:
            out += b"\r\n"
        elif k < 54:
            out += rng.choice([b"\r", b"\n", b"\b", b"\t"])
        elif k < 60:
            out += b"\x1b[%d;%dH" % (rng.randrange(1, ROWS + 1), rng.randrange(1, COLS + 1))
        elif k < 68:
            out += b"\x1b[%d%s" % (n, rng.choice([b"A", b"B", b"C", b"D", b"G", b"d", b"E", b"F"]))
        elif k < 72:
            out += b"\x1b[%dJ" % rng.randrange(3)
        elif k < 77:
            out += b"\x1b[%dK" % rng.randrange(3)
        elif k < 85:
            out += b"\x1b[%sm" % b";".join(rng.choice(
                [b"0", b"1", b"7", b"22", b"27", b"39", b"49",
                 b"%d" % rng.randrange(30, 38), b"%d" % rng.randrange(40, 48),
                 b"%d" % rng.randrange(90, 98), b"%d" % rng.randrange(100, 108)])
                for _ in range(rng.randrange(1, 4)))
        elif k < 88:
            c = rng.choice([b"L", b"M", b"P", b"@", b"X"])
            # (pyte returns the carriage after L and M; Linux's console does not)
            out += b"\x1b[%d%s" % (rng.randrange(1, 5), c) + (b"\r" if c in b"LM" else b"")
        elif k < 91:
            t = rng.randrange(1, ROWS - 1)
            out += b"\x1b[%d;%dr" % (t, rng.randrange(t + 1, ROWS + 1))
        elif k < 93:
            out += b"\x1b[r"
        elif k < 96:
            # (a restore only after a save: pyte keeps a stack of them)
            # (not ESC E: pyte leaves out its carriage return)
            c = rng.choice([b"\x1bM", b"\x1bD", b"\x1b7", b"\x1b8"])
            if c == b"\x1b8":
                c = b"\x1b7" + rng.choice(words) + b"\x1b[%d;%dH" % (rng.randrange(1, ROWS + 1), rng.randrange(1, COLS + 1)) + c
            out += c
        elif k < 98:
            out += b"\r\n" * rng.randrange(1, 40)
        else:
            out += "┌─┐│└┘".encode()
    return bytes(out)


def main():
    prog = sys.argv[1]
    ok = True
    if len(sys.argv) > 2 and sys.argv[2] == "--fuzz":
        n = int(sys.argv[3])
        seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
        fails = 0
        for i in range(n):
            data = made_up(random.Random(seed * 100000 + i))
            if not compare(prog, data, "made-up %d" % i, quiet=True):
                fails += 1
                if fails <= 3:
                    compare(prog, data, "made-up %d (seed %d)" % (i, seed))
                    open("/tmp/term-fail-%d.bin" % i, "wb").write(data)
        print("made-up: %d of %d agree" % (n - fails, n))
        ok = fails == 0
    else:
        for f in sys.argv[2:]:
            ok &= compare(prog, open(f, "rb").read(), f)
    sys.exit(0 if ok else 1)


main()
