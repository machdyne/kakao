#!/usr/bin/env python3
# fbtest.py qmp-socket file - the Kakao SOC's framebuffer as fbtest.sh
# gives it to QEMU: 640 by 480 bytes of picture and the registers after
# it are read from the machine's memory, the picture is written to
# file.ppm with the colours the kernel set, and looked at: rio's grey,
# a window's white, and the 8 bit mode asked for.
import json, os, socket, struct, sys

FB, REGS = 0x8fc00000, 0x8ff00000

def main():
    s = socket.socket(socket.AF_UNIX)
    s.connect(sys.argv[1])
    f = s.makefile('rw')
    f.readline()
    def cmd(c, **a):
        f.write(json.dumps({"execute": c, "arguments": a}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if 'return' in r or 'error' in r:
                return r
    cmd("qmp_capabilities")
    out = sys.argv[2]
    cmd("pmemsave", val=FB, size=640 * 480, filename=out + ".fb")
    cmd("pmemsave", val=REGS, size=0x800, filename=out + ".regs")
    d = open(out + ".fb", "rb").read()
    r = open(out + ".regs", "rb").read()
    os.remove(out + ".fb")
    os.remove(out + ".regs")
    pal = [struct.unpack_from('<I', r, 0x400 + 4 * i)[0] for i in range(256)]
    with open(out + ".ppm", "wb") as p:
        p.write(b"P6\n640 480\n255\n")
        p.write(b"".join(bytes(((pal[b] >> 16) & 255, (pal[b] >> 8) & 255, pal[b] & 255)) for b in d))
    def check(what, ok):
        print("%s  %s" % ("ok   " if ok else "FAIL ", what))
    check("the screen is set to 8 bits a pixel", struct.unpack_from('<I', r, 0)[0] == 1)
    check("the colours are Plan 9's (black first, white last)", pal[0] == 0 and pal[255] == 0xffffff)
    grey = sum(1 for b in d if pal[b] == 0x777777)
    white = sum(1 for b in d if pal[b] == 0xffffff)
    check("rio's background is on the screen (%d pixels)" % grey, grey > 40000)
    check("a window is on the screen (%d white pixels)" % white, white > 100000)

main()
