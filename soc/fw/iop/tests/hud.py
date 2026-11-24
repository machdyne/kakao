#!/usr/bin/env python3
"""
hud.py <hud_test> <k_font.hex> <out.png> <key> ...

The menus as the screen would show them: hud_test's overlay over a
screen of text, drawn with the font (needs Pillow). The keys are
hud_test's.
"""
import subprocess, sys
from PIL import Image

def pc(c):
    lo = 0x55 if c & 8 else 0
    return ((0xaa if c & 4 else 0) | lo, 0x55 if c == 6 else ((0xaa if c & 2 else 0) | lo), (0xaa if c & 1 else 0) | lo)

def main():
    exe, fontf, out, keys = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    font = [int(l, 16) for l in open(fontf).read().split()]
    lines = subprocess.run([exe] + keys, capture_output=True, text=True, check=True).stdout.split("\n")
    raw = [int(l, 16) for l in lines[1:33]]
    rgb = lambda p: ((p >> 16) & 255, (p >> 8) & 255, p & 255)
    # (what was never written is as after reset: the PC's)
    pal = [rgb(p) for p in raw[:16]] if any(raw[:16]) else [pc(i) for i in range(16)]
    themed = any(raw[16:])                                  # a theme writes these five
    opal = [rgb(raw[16 + i]) if themed and i in (6, 15, 14, 7, 0) else pc(i) for i in range(16)]
    ovl = [[int(w, 16) for w in l.split()] for l in lines[33:63]]
    under = ["root@kakao:~# ls -l /sys/linux", "-rwxr-xr-x  1 root root  5914624 Nov 22 21:14 Image",
             "-rwxr-xr-x  1 root root   534864 Nov 22 21:14 fw_jump.bin", "root@kakao:~# "]
    im = Image.new("RGB", (640, 480))
    px = im.load()
    for r in range(30):
        for c in range(80):
            o = ovl[r][c]
            if o:
                ch, fg, bg = o & 255, opal[(o >> 8) & 15], opal[(o >> 12) & 15]
            else:
                t = under[r % len(under)] if r < 29 else ""
                ch, fg, bg = (ord(t[c]) if c < len(t) else 32), pal[7], pal[0]
            for y in range(16):
                bits = font[ch * 16 + y]
                for x in range(8):
                    px[c * 8 + x, r * 16 + y] = fg if bits & (0x80 >> x) else bg
    im.resize((1280, 960), Image.NEAREST).save(out)

if __name__ == "__main__":
    main()
