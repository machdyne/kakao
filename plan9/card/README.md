# Plan 9 on a board's SD card

This is how it runs on a Sergei ML2 (kakao64): the shell, and with a
bitstream that has the options for it the window system ("rio on a
board", at the end).

kboot, the SOC's boot program, reads a list of files and addresses
from the card (`boot.json`), loads each file and starts the first. So
there is a `boot.json` for Plan 9 although Plan 9 knows nothing of it:
it is kboot's. The device tree (`kakao.dtb`) Plan 9 does read, as
OpenSBI does: the clock's rate, the size of memory and the virtio
devices come from it.

A card made for Linux on kakao64 (`soc/boards/README.md`) has in
`/sys/linux` of its first partition: `boot.json`, `fw_jump.bin`,
`kakao.dtb` and `Image`. Plan 9 uses the same `fw_jump.bin` and the same
`kakao.dtb`.

**With a bitstream built from this archive's `soc/fw/kboot`** (kboot is
in the bitstream), Plan 9 has a directory of its own and Linux's stays
as it is:

1. make `/sys/plan9` on the card and copy `build/9kkcpu.bin` and this
   directory's `boot.json` into it;
2. copy this directory's `boot.txt` to `/sys/boot.txt`. It holds one
   word, `plan9`: the directory of `/sys` kboot is to boot from.

To go back to Linux, remove `/sys/boot.txt` or put `linux` in it.

**With an older bitstream**, kboot knows `/sys/linux` only, and Plan 9
takes Linux's place there:

1. copy `build/9kkcpu.bin` to `/sys/linux/9kkcpu.bin`;
2. keep the card's `boot.json` as `boot.json.linux` and put this
   directory's `boot-old.json` in its place, as `boot.json`.

The kernel carries its root file system, so nothing else on the card is
read or written.

## What to expect on the console

OpenSBI's banner, then

```
Plan 9 for kk
...
clint timebase: 48 MHz
#l0: virtio: 100Mbps regs 0x10002000 irq 13: 024b4b......
5..M memory: ...

Kakao Plan 9: a shell.  kknet starts the network, kkcpu a CPU server.
%
```

The simulated SOC takes some ten seconds of its own time to get there,
and another twenty for `kknet`, `kkcpu` and a `cpu` login: it is not
quick. (`ip/ping` reports its first ping lost on the simulated SOC, and
the rest answered.)
The kernel has a window system now (`kkrio`), which a board cannot use
yet: there is no framebuffer for it. On a board `kkrio` says so.

If the board has no network device the `#l0` line is "no known ethernet
interfaces found", and the shell still comes.

## Things to try

```
ps
kknet                           # DHCP; or: kknet 192.168.1.50 255.255.255.0 192.168.1.1
ip/ping -n 3 192.168.1.1
kkcpu somepassword              # eight characters or more
```

Then, from Linux, with drawterm (https://github.com/9front/drawterm,
`CONF=unix make`):

```
PASS=somepassword ./drawterm -G -O -h <board> -a <board> -u glenda -c 'cat /dev/sysname; ps'
PASS=somepassword ./drawterm -O -h <board> -a <board> -u glenda     # a window with a shell on the board
```

`-O` is the cpu protocol of Plan 9's Fourth Edition, `-G` no window.
The first of these is what `make drawtermtest` runs against QEMU; the
second, with a window, has not been run.

If it stops before the shell, the console's last lines say where; send
them.

## rio on a board

rio needs two things of the bitstream that are off unless asked for: the
keyboard and the mouse as the host's devices, and a framebuffer.

```
cd soc/boards
make BOARD=sergei_ml2 CPU64=1 INPUT=1 FB=1 seeds
```

1. Program `build/sergei_ml2-64/kakao.bit`.
2. Copy `build/sergei_ml2-64/kakao.dtb` to the card as
   `/sys/linux/kakao.dtb` (Plan 9's `boot.json` loads that one). It has
   four virtio slots and the framebuffer, and gives the system 4 MB
   less memory. A kernel that knows nothing of the framebuffer is not
   troubled by it.
3. Copy `build/9kkcpu.bin` to `/sys/plan9`.

On the console the kernel should now say, before the shell:

```
screen: 640x480x8 at 0x...
input: virtio ...
input: virtio ...
```

The monitor still shows the terminal, and the terminal is still Plan
9's console. **Super with 0** shows the framebuffer, with the kernel's
console on it, and gives the keyboard and the mouse to Plan 9; Super
with 1 is the terminal again. On the framebuffer:

```
% kkrio
```

and rio should come up with a shell, the load and a clock. Button 3 on
the grey has its menu. The keys are a US keyboard's.

At the prompt on the terminal Backspace erases and ^C interrupts; ^P
restarts the machine (it is a CPU server's console).
