#!/usr/bin/env python3
"""kload: load a boot over the UART into kboot, start it, and stay on
as a terminal.

    kload.py PORT FILE@ADDRESS... [--baud 1000000] [--no-go]

    kload.py /dev/ttyUSB0 fw_jump.bin@81e00000 Image@80000000 \\
        rootfs.cpio@81000000 kakao.dtb@81f00000

Waits for kboot's "ready" (reset or reconfigure the board if it has
already said it; --now skips the wait), sends each file, checks the sum
kboot reports against the file's, then sends 'G': kboot starts what
was loaded first (OpenSBI) with the device tree at 81f00000. After that the keys
go to the board and what it prints comes here; Ctrl-] leaves.

Needs pyserial.
"""

import argparse
import sys
import time

import serial


def wait_for(port, text, timeout):
    """Print what arrives until `text` has; return what came after it."""
    seen = b""
    end = time.time() + timeout
    while time.time() < end:
        got = port.read(256)
        if got:
            sys.stdout.write(got.decode("latin-1"))
            sys.stdout.flush()
            seen += got
            at = seen.find(text)
            if at >= 0:
                return seen[at + len(text):]
    sys.exit("\nkload: no %r from the board in %d s" % (text.decode(), timeout))


def load(port, path, address):
    data = open(path, "rb").read()
    print("kload: %s, %d bytes at %08x" % (path, len(data), address))
    port.write(b"L" + address.to_bytes(4, "little") + len(data).to_bytes(4, "little"))
    start = time.time()
    step = 4096
    for at in range(0, len(data), step):
        port.write(data[at:at + step])
        if at % (64 * step) == 0:
            sys.stdout.write("\r  %3d%%" % (100 * at // max(len(data), 1)))
            sys.stdout.flush()
    port.flush()
    print("\r  sent in %.0f s; kboot is adding it up" % (time.time() - start))
    # kboot reads the whole of it back before it answers
    rest = wait_for(port, b"sum ", 30 + len(data) // 20000)
    while len(rest) < 8:
        rest += port.read(8 - len(rest))
    theirs = int(rest[:8], 16)
    ours = sum(data) & 0xffffffff
    print()
    if theirs != ours:
        sys.exit("kload: %s: the board's sum is %08x, the file's %08x" % (path, theirs, ours))


def terminal(port):
    import os
    import select
    import termios
    import tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        port.timeout = 0
        while True:
            ready, _, _ = select.select([fd, port.fileno()], [], [])
            if fd in ready:
                key = os.read(fd, 64)
                if b"\x1d" in key:
                    return
                port.write(key)
            if port.fileno() in ready:
                got = port.read(4096)
                if got:
                    os.write(sys.stdout.fileno(), got)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        print("\nkload: bye")


def main():
    ap = argparse.ArgumentParser(description="load a boot into kboot over the UART")
    ap.add_argument("port")
    ap.add_argument("files", nargs="*", metavar="FILE@ADDRESS")
    ap.add_argument("--baud", type=int, default=1000000)
    ap.add_argument("--no-go", action="store_true", help="load, but do not start it")
    ap.add_argument("--now", action="store_true", help="do not wait for kboot's \"ready\"")
    args = ap.parse_args()

    loads = []
    for f in args.files:
        path, _, adr = f.rpartition("@")
        if not path:
            sys.exit("kload: %s: FILE@ADDRESS (hex)" % f)
        loads.append((path, int(adr, 16)))
        open(path, "rb").close()

    port = serial.Serial(args.port, args.baud, timeout=0.1)
    if not args.now:
        print("kload: waiting for kboot (reset the board if it is already up)")
        wait_for(port, b"ready", 120)
    for path, adr in loads:
        load(port, path, adr)
    if loads and not args.no_go:
        port.write(b"G")
    terminal(port)


if __name__ == "__main__":
    main()
