#!/usr/bin/env python3
"""
mkkbd.py <zeitlos/sw/common> <out.c> <layout> [<layout> ...]

The I/O processor's keyboard layouts (fw/iop): Zeitlos's translation
(zkbd.c) with only the named layouts of its table (zkbd_layouts.c,
generated there from xkeyboard-config; zkbd_layouts.LICENSE) -- the
whole table is 12 KB and the I/O processor's memory is small. Layout 0
is the first named. Names are Zeitlos's: us, gb, de, de-nodeadkeys,
fr, ...
"""
import re, sys

def main():
    src, out, want = sys.argv[1], sys.argv[2], sys.argv[3:]
    code = open(src + "/zkbd.c").read()
    lay = open(src + "/zkbd_layouts.c").read()

    m = re.search(r"const z_kbd_layout_t z_kbd_layouts\[\] = \{\n(.*?)\n\};", lay, re.S)
    rows = {}
    for line in m.group(1).split("\n"):
        r = re.match(r'\s*\{ "([^"]+)", .*?, (kbd_\w+_keys), \d+ \},', line)
        if r: rows[r.group(1)] = (line, r.group(2))
    missing = [w for w in want if w not in rows]
    if missing:
        sys.exit("mkkbd: no layout %s (there are: %s)" % (", ".join(missing), " ".join(rows)))

    arrays = {}
    for a in re.finditer(r"(?://[^\n]*\n)?static const z_kbd_key_t (kbd_\w+_keys)\[\] = \{.*?\n\};\n", lay, re.S):
        arrays[a.group(1)] = a.group(0)
    used = []
    for w in want:
        if rows[w][1] not in used: used.append(rows[w][1])

    head = lay[:lay.index("// English (US)")]
    table = "const z_kbd_layout_t z_kbd_layouts[] = {\n" + "\n".join(rows[w][0] for w in want) + "\n};"
    tail = lay[m.end():]
    sub = head + "\n".join(arrays[u] for u in used) + "\n" + table + tail

    inc = '#include "zkbd_layouts.c"'
    assert inc in code
    with open(out, "w") as f:
        f.write("/* Made by tools/mkkbd.py from Zeitlos's zkbd.c and zkbd_layouts.c: %s */\n" % " ".join(want))
        f.write(code.replace(inc, sub))

if __name__ == "__main__":
    main()
