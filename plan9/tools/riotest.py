#!/usr/bin/env python3
# riotest.py qmp-socket prefix - drive QEMU's pointer and keyboard at rio
# and take pictures of the screen (prefix-a.ppm ...), then say what the
# pictures show.  Run by riotest.sh once rio is up.
#
#   a  rio with its first windows: grey background, a white shell window
#   b  button 3 held on the background: rio's menu under the pointer
#   c  "New" chosen and a window swept out with the pointer: white there
#   d  exit typed in the new window: the window is gone, grey again
import json, os, socket, sys, time

q = socket.socket(socket.AF_UNIX)
q.connect(sys.argv[1])
pre = os.path.abspath(sys.argv[2])
time.sleep(0.3)
q.recv(65536)

def qmp(c, **a):
    q.send((json.dumps({"execute": c, "arguments": a} if a else {"execute": c}) + "\n").encode())
    time.sleep(0.15)
    return q.recv(65536)

qmp("qmp_capabilities")

def move(x, y):         # a pixel of the 1024 by 768 screen
    qmp("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": x * 32767 // 1023}},
        {"type": "abs", "data": {"axis": "y", "value": y * 32767 // 767}}])

def button(b, down):
    qmp("input-send-event", events=[{"type": "btn", "data": {"button": b, "down": down}}])

def key(k):
    for down in (True, False):
        qmp("input-send-event", events=[
            {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": k}}}])

def shot(name):
    f = "%s-%s.ppm" % (pre, name)
    if os.path.exists(f):
        os.remove(f)
    qmp("screendump", filename=f)
    d = b""
    for i in range(50):         # QEMU writes it when it gets round to it
        time.sleep(0.3)
        if os.path.exists(f):
            n = len(d)
            d = open(f, "rb").read()
            if len(d) > 0 and len(d) == n:
                break
    # P6, width height, 255, then the pixels
    parts = d.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]

def pixel(pic, x, y):
    w, h, d = pic
    return tuple(d[3 * (y * w + x):3 * (y * w + x) + 3])

# riotest.py socket prefix repeat: before rio is started, a key held for
# a second and a half at the console and then Enter; riotest.sh looks
# in the console's log for the letter several times over
if len(sys.argv) > 3 and sys.argv[3] == "repeat":
    qmp("input-send-event", events=[
        {"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": "x"}}}])
    time.sleep(1.5)
    qmp("input-send-event", events=[
        {"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": "x"}}}])
    time.sleep(0.5)
    key("ret")
    sys.exit(0)

GREY, WHITE = (0x77, 0x77, 0x77), (0xff, 0xff, 0xff)
ok = True
def check(what, cond):
    global ok
    print("%s  %s" % ("ok  " if cond else "FAIL", what))
    ok = ok and cond

move(500, 620); time.sleep(0.5)
a = shot("a")
check("the screen is 1024 by 768", a[:2] == (1024, 768))
check("rio's background", pixel(a, 300, 640) == GREY)
check("a window with a shell in it", pixel(a, 300, 250) == WHITE)

button("right", True); time.sleep(1.0)
b = shot("b")
check("button 3 brings rio's menu", pixel(b, 475, 690) != GREY)

button("right", False); time.sleep(0.5)     # "New" was under the pointer
move(60, 540); time.sleep(0.3)
button("right", True); time.sleep(0.3)
for i in range(1, 11):
    move(60 + i * 50, 540 + i * 20); time.sleep(0.08)
button("right", False); time.sleep(3)
c = shot("c")
check("a window swept out with the pointer", pixel(c, 300, 640) == WHITE)

for k in ("e", "x", "i", "t", "ret"):
    key(k)
time.sleep(2)
d = shot("d")
check("exit typed on the keyboard closes it", pixel(d, 300, 640) == GREY)
sys.exit(0 if ok else 1)
