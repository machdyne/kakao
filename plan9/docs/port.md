# The port

## What is ported

The kernel is `9k`, Plan 9's 64 bit kernel, in its RISC-V form
(`/sys/src/9k/rv`) by Geoff Collyer, with Richard Miller's compilers
(`jc`, `jl`, `ja`). It is a CPU server kernel: no graphics. It runs on
several RISC-V boards and in tinyemu; `upstream/dist.9k-rv.tgz` is the
distribution, and `9k-riscv.pdf` beside it at
https://9p.io/sources/contrib/geoff/riscv/ is its paper.

It suits the Kakao SOC because both are built to the same conventions:

| | the 9k RISC-V kernel | the Kakao SOC with kakao64 |
|---|---|---|
| instructions | RV64GC | RV64IMAC, F and D with the firmware's help |
| paging | Sv39 | Sv39 |
| entered | in supervisor mode by SBI firmware (it finds out which mode it is in), memory at 0x8000_0000 | by OpenSBI, at 0x8020_0000 |
| interrupts | PLIC; the timer through SBI | PLIC at 0x0c00_0000; OpenSBI |
| console | 8250/16550 | 16550 register sets at 0x1000_0000 |

The SOC copies QEMU's `virt` machine, so the port is made and tested in
QEMU first; `kk` is the kernel's name for the machine, whichever of the
two it is.

## What is ours

All of it is in `overlay/sys/src/9k/rv` and `patches/kakao.patch`.

**`kk/defs`** (read into the kernel's mkfile):

- `PAUart0=0x10000000`.
- `PHYSMEM=0x80200000`, `KTZERO=0xffffffc080200000`: OpenSBI has the
  first 2 MB of memory; the kernel is loaded after it.
- `BANK0SIZE=510*MB`: one bank, for 512 MB of memory, when there is no
  device tree to say how much there is.
- `-DUARTREG8`: the 16550's registers are a byte apart. The driver
  (`uarti8250.c`) has them a word apart, as on the boards it knew; the
  patch makes that a choice.
- `-DNOETHEROK`: `devether.c` stops the machine when it finds no network
  interface, which a CPU server cannot do without. The patch lets it go
  on: a board may have no cable, and QEMU no device.
- `-DKKFDT`: read the device tree (below).
- `-DKERNMEMMIN=(24*MB)`: the least the kernel keeps for itself (below).
- the rule that builds `kk/boot.c`.

**`kkcpu`**, the configuration: the tinyemu one (`tecpu`) with real SBI
calls (`sbicall`, `sbiecall` in place of `fakesbi`), the PLIC at
0x0c00_0000 with the UART on source 10, one hart whose PLIC contexts are
M then S, the virtio network driver, and what is in `/boot`: `boot`,
`rc`, the few commands that unpack the root, and the root itself.

**`kk/boot.c`**, the first user program. Plan 9's own (`../boot`) asks
where the root file system is and connects to it. This one names an
owner for the machine (`glenda`), binds the first of the kernel's
devices and runs `/boot/kkinit` with `rc`.

**The root file system** is in the kernel, in two parts. The commands
built for RISC-V are files of `/boot`, as the kernel's configuration
lists them (the Makefile writes that list). Everything else is
`kk/kkroot.tar`, 60 KB, made by `make kernel` from `rootfs/` (the files
written for this machine) and three files of the system's (`rcmain`,
`/lib/ndb/common`, `kill`). `kkinit` starts a `ramfs` as `/srv/boot`,
which is where `/lib/namespace` looks for a root, unpacks the archive
into it, binds it as the root, and runs a shell on the console. So the
machine needs no disk and no file server, and forgets everything when
it is switched off.

`/bin` is the root's (empty) `/riscv64/bin`, then `/rc/bin`, then
`/boot`. `/boot` has no directories, so a command with one to its name
(`auth/factotum`) is an empty file in the root with the command bound
over it, one line each in `/lib/namespace.kkbin`, which the Makefile
writes and both `kkinit` and `/lib/namespace` read.

The commands were in the archive at first, 4.3 MB of it, and the
simulated SOC did not finish unpacking them in the 590 million cycles
it was given: copying through 9P into `ramfs` is about twenty
instructions a byte (the copies are a byte at a time, the 9P message's
data not being on a word), and on the simulated SOC that code ran at
8.6 cycles an instruction, most of them waiting for the data cache.
Real memory may do better or worse than the simulation's; either way,
copying megabytes is something to keep off this machine's boot.

**A CPU server.** Three scripts in `/rc/bin` (`rootfs/rc/bin`):

- `kknet [-n name] [-a authserver] [address mask [gateway]]`: DHCP, or
  the address given; writes `/lib/ndb/local` with this machine in the
  authentication domain `kakao`; starts `ndb/cs`.
- `kkkey [password]`: starts `factotum`, and with a password gives it
  glenda's key for the domain. Without one, `factotum` asks on the
  console when a key is first needed.
- `kkcpu password`: `kkkey`, then glenda's key where the authentication
  server looks for it, then `aux/listen` with two services: `tcp567`
  (`auth/authsrv`, the authentication server) and `tcp17010` (`cpu -R`).

After `kknet` and `kkcpu` the machine is the CPU server and the
authentication server of a Plan 9 network of one domain and one user.
Another machine in the domain (`kknet -a server ...`, `kkkey`) runs
`cpu -h server` and is asked for the password; the two authenticate with p9sk1 and the connection is
encrypted (rc4, sha1), as the Fourth Edition does it. `kkexport` serves
a directory over 9P to anyone, for looking in from a machine that is
not Plan 9.

What is not as a Plan 9 installation has it, and why:

- **The server's password is an argument** of `kkcpu`, typed on the
  console and readable there. `factotum -S` would ask for it and keep it in non-volatile
  memory, which this machine has not got.
- **Users' keys are plain files** in the ramfs (`/mnt/keys/glenda/key`,
  written by `auth/passtokey`, which is ours). `auth/keyfs` and
  `auth/changeuser`, which keep them encrypted and ask eight questions
  for each user, are built and in `/bin/auth`, and are the way once
  there is a disk.
- **One user**, glenda, who is also the machine's owner.
- **The clock starts in 1970.** Nothing reads the SOC's clock yet
  (goldfish RTC, 0x0010_1000). p9sk1 does not look at the time.

Two things found on the way. `factotum` mounts itself before everything
else on `/mnt`; the authentication server then looks for `/mnt/keys`
while `factotum` is waiting for its answer, has to ask `factotum`
whether it has such a file, and both wait for ever. `kkkey` mounts it
after, as `/lib/namespace` does. And an empty `/mnt/factotum` directory
in the root hides `factotum` from every service, so there is none.

**`kkfdt.c`, the device tree.** OpenSBI enters the kernel with the
tree's address in `a1`. `start.s` threw it away; the patch keeps it, and
`fdtconf` reads the tree where it lies, called first thing in `low.c`'s
`setstkmach0`: before paging, before bss is cleared (so what it sets has
initialisers and is in the data segment) and before the kernel has
worked out where its memory ends. It takes three things:

- `timebase-frequency`: 10 MHz in QEMU, 48 MHz on the SOC.
- the memory node the kernel is in, for `membanks[0].size`. If the
  firmware put the tree in the last 4 MB of memory, as QEMU and kboot
  both do, memory ends below the tree: the kernel keeps `Sys` in the
  last megabyte of its bank and clears it.
- every `virtio,mmio` node's address and interrupt. QEMU has eight slots
  on PLIC sources 1 to 8 and plugs the first device into the last; the
  SOC has its slots on sources 12 and up, the network in the second.

Without a tree the kernel is as it was compiled: QEMU with 512 MB. The
reboot trampoline's address is still compiled in (`RBKTZERO`, for
510 MB), so a kernel cannot load another kernel when memory is another
size; nothing here does that yet.

**`ethervirtio.c`, the network driver**: virtio-mmio version 2, written
from the specification. It looks through the slots the tree named for a
network device, resets it, acknowledges it, accepts `VERSION_1` and the
MAC address feature and nothing else (no offloads, no merged buffers),
checks `FEATURES_OK`, and at attach sets up two queues of up to 64
descriptors, one buffer to a descriptor. Which block belongs to which
descriptor is the driver's own table, and it takes what the device has
used in the order the device says. A kernel process does the work; the
interrupt only wakes it. When the device offers no MAC address (the
SOC's does not), the driver makes one up, as Linux does: 02:4b:4b and
three bytes from the clock as it stands when the driver starts. That
differs from one power-up to the next, so a board's address changes
when it is switched on again, and it is not much of a random number. (A
fixed 02:00:00:00:00:01 was tried first and is the address of the
simulation's other end of the cable.) A legacy (version 1) device is reported and left
alone: QEMU needs `-global virtio-mmio.force-legacy=false`.

One thing found on the way: the used ring's elements are declared as
plain words. An array of two-word structs is aligned to 8 bytes by this
compiler, and the ring starts 4 bytes in.

**The kernel's share of memory** (`memory.c`, in the patch). The kernel
takes a tenth of its bank for itself. As it starts it allocates
13.5 MB, whatever the bank's size, and with a bank of about 100 to
140 MB a tenth is less than that. (The Sergei ML2 has 512 MB with
kakao64, where a tenth is plenty; 128 MB is what the test with the
SOC's device tree uses.) The allocator does not notice: it
hands out memory past the end of its arena, which the array of `Page`
structs is then laid over, and the first `print` after that jumps
through an overwritten pointer. With `KERNMEMMIN` the kernel keeps at least
24 MB when the bank is 48 MB or more. Below that this kernel does not
start; what the 13.5 MB are has not been looked into, and the
allocator's missing check is still missing.

**A screen, a keyboard and a mouse: rio.** The 9k RISC-V port is of CPU
kernels; the draw and mouse devices are the Fourth Edition's
(`../9/port/devdraw.c`, `devmouse.c`), which the kernel's sources
already had links to. What the port adds:

- `screen.c`, `screen.h`: the Raspberry Pi port's (`../9/bcm`), a
  framebuffer in memory with a software cursor and the kernel's console
  on it, with the Pi's framebuffer replaced by ours. One is a
  `simple-framebuffer` node of the device tree (address, width, height,
  stride, and `r5g6b5` or `x8r8g8b8`), drawn in where it is. One is
  QEMU's `ramfb`, which is told through fw_cfg which memory to show:
  1024 by 768, 32 bits. And one is the Kakao SOC's (below). With none
  there is no screen and nothing else changes.
- **The SOC's framebuffer** (`soc/docs/design.md`, "The framebuffer";
  a bitstream built with `FB=1`) is a `simple-framebuffer` with one
  more property, `kakao,ctrl`, the address of its registers. It is main
  memory the data cache is kept out of, so every access to it is one of
  the memory's own: slow to write, slower to read. The kernel therefore
  draws in a copy in ordinary memory (the draw device's `softscreen`)
  and `flushmemscreen` writes the rectangle that changed to the real
  one, eight bytes at a store and in order, which the DDR3 controller
  turns into one write for every 16 bytes; it is never read. And it is
  put into its 8 bit mode with Plan 9's own 256 colours: half the bytes
  to draw, half to write out, half for the screen to read from memory
  the CPU is waiting for. (`KKFBDEPTH=16` when `screen.c` is compiled
  has the 16 bit mode.)
- The framebuffer is above the memory the device tree gives the system,
  and is reached through the kernel's own map of memory (`KADDR`), whose
  pages go past the end of what it was told. `vmap` is not used for it:
  for an address at or above main memory's it makes a new mapping, and
  takes the page tables for that the way the kernel does while it
  starts, which by then is memory `malloc` has given away. The first
  thing lost was the clock's timer, and the kernel stopped at
  `assert(t->tt == tt)` as soon as *init* ran. (The plain
  `simple-framebuffer` path had the same call and had never been run.)
- `kkinput.c`: virtio input devices (keyboards, mice, tablets), found in
  the virtio slots like the network. Keys are a US keyboard's and go to
  the console, and a key held repeats here (the devices leave that to
  the host). A pointer with a place (QEMU's tablet, the SOC's mouse)
  is asked how far its axes go, and its place becomes a movement of
  the pointer.
- `kkpool.c`: the image library takes its memory from a pool
  (`imagmem`), which the kernels with the pool allocator have and this
  one, with `qmalloc`, has not. Its two calls go to the kernel's
  allocator. Images are never compacted.
- `screen.h` also gives the two devices a `conf.monitor` to ask, the 9k
  kernels having no `conf`.

In the root: `rio`, `stats`, `clock`, `colors`, the fonts rio asks for
(`lucm`, `misc`, `pelm`), and `kkrio`, which starts rio with a shell,
the load and a clock (`kkriostart`). rio is started from the console,
in the foreground: a shell left reading the console takes half the
keys. `/lib/namespace` does not bind the screen: a service running as
`none` may not have it, and with those lines every service died as it
started.

`make qemu-rio` opens QEMU with a window. `tools/riotest.sh`, part of
`make test`, has no window: it moves QEMU's pointer and presses its
keys through QMP and looks at pictures of the screen: rio's menu on
button 3, a window swept out with the pointer, `exit` typed in it.

**Zeroing memory** (`archrv.c`, in the patch). The kernel takes the
cache-block instructions (Zicbom, Zicboz) to be there when they do not
trap. kakao64 decodes the whole MISC-MEM opcode as a fence, so they do
not trap and do nothing, and the kernel then cleared memory with
`cbo.zero`: nothing was cleared, and the first lock in allocated memory
was found already held ("ilock: no way out on uniprocessor"). The patch
has the kernel try `cbo.zero` on a line of 0xff and look. Zicbom is
still believed on kakao64 ("_Zicbom" in the kernel's first lines);
nothing here needs a cache flushed, so that costs nothing.

## Booting

In QEMU (`make qemu`):

```
qemu-system-riscv64 -M virt -m 512 -smp 1 -nographic -bios default -kernel build/9kkcpu.bin
```

`make qemu` adds a network device (`QNET` in the Makefile).

`9kkcpu.bin` is the kernel as a flat image: QEMU loads it at
0x8020_0000 and its OpenSBI enters it there in supervisor mode with the
hart's number in `a0` and the device tree's address in `a1`.

`make test` runs six things, 45 checks: the shell
(`tools/qemutest.sh`); two machines on a network of their own
(`tools/cputest.sh`: one becomes the CPU and authentication server, the
other joins its domain and runs commands on it with `cpu`; it has the
wrong password at first, is refused, and `factotum` asks for another);
the window system (`tools/riotest.sh`, above); the
network (`tools/nettest.sh`: DHCP from QEMU's user network, three pings
to the host, then plan9port's `ramfs` on the host mounted over TCP, a
file read from it and one written to it, which the host reads back);
and, when `../soc/tools/mkdts.py` and `dtc` are there, the shell again
with 128 MB and the device tree `mkdts.py` writes for a kakao64 board
of that size, which must give "clint timebase: 48 MHz" and "120M
memory". QEMU's network device is not where that tree says, so that run
has no network. With the same two there is also the SOC's
framebuffer as far as the kernel is concerned (`tools/fbtest.sh`):
QEMU has no such device, so the device tree says there is one in
memory QEMU has, registers and all; `kkrio` is started, and the
picture is read out of the machine's memory and looked at.

`make drawtermtest DRAWTERM=<drawterm>` (as root: it forwards port 567)
has a machine that is not Plan 9 log in: 9front's drawterm, built on
Linux, runs a command on the kernel in QEMU, and is refused with the
wrong password.

The test (`make test`) also passes with QEMU's CPU cut down towards
kakao64: `-cpu rv64,sstc=off,svadu=off,zba=off,zbb=off,zbc=off,zbs=off,
zicbom=off,zicboz=off,zawrs=off,zfa=off,zihintpause=off,v=off,h=off`.
Without `sstc` the timer goes through OpenSBI and the CLINT, as on the
SOC; without `svadu` the accessed and dirty bits are set by faults, as
kakao64 does it. What QEMU cannot show is floating point done by the
firmware.

On a board, the Sergei ML2 with kakao64, it boots from the SD card to
its shell, and with a bitstream built `INPUT=1 FB=1` rio runs on the
monitor with the USB keyboard and mouse. `card/README.md` says what to
put on the card and what to expect. kboot takes the directory to boot
from out of `/sys/boot.txt`, so Plan 9 has `/sys/plan9` and shares
Linux's firmware and device tree.

## On the simulated SOC

`soc/sim`'s `obj/simsoc64` is the SOC's own Verilog with kakao64 under
Verilator. The kernel boots on it to the shell, takes what is typed at
UART 0's pin (PLIC source 10), finds the network device in the second
virtio slot on source 13, pings the other end of the simulated cable,
becomes a CPU server and logs in to itself with `cpu` (the simulation
has one machine; the login still goes through the authentication
server, the listener and the encrypted connection):

```
cpu0: risc-v RV64GCSU ... hart 0 plic M context 0 at 48 MHz
clint timebase: 48 MHz
#l0: virtio: 100Mbps regs 0x10002000 irq 13: 024b4b05762d
249M memory: 3009K+30M kernel (7008K of Page structs), 219M user

Kakao Plan 9: a shell.  kknet starts the network, kkcpu a CPU server.
% kknet 10.0.0.2 255.255.255.0
kakao is 10.0.0.2, authentication server 10.0.0.2
% kkcpu kakaopass1
CPU server: cpu -h 10.0.0.2 -u glenda, from a machine in the domain kakao
% cpu -h kakao -c 'echo hello from cpu; cat /dev/user; echo'
hello from cpu
glenda
```

That run (boot, `kknet`, `kkcpu`, `cpu`) is 1402 million clock cycles:
29 seconds of the SOC's time, 233 million instructions at 6.0 cycles
each, 36 minutes here. An earlier kernel's run of a shell and three
pings was at 2.75 cycles an instruction; the difference is the data
cache, which the simulator's own counts put at 512 of the 1402 million
cycles.

How it is run (`make simtest SIM=... OPENSBI=...`, which types
`tools/simtest.txt` and checks 12 lines of the log; as a whole it has
not been run, its parts have, in two runs):

```
# the simulator, with the network and the typing at UART 0's pin
make -C ../soc/sim sim64 SIMC="-DSIMSD -DSIMNET" SOCG="-GVIRTIO=2 -GRXPIN=1"

# OpenSBI 1.9 for RV64 with the SOC's floating-point patch
git clone --depth 1 --branch v1.9 https://github.com/riscv-software-src/opensbi
(cd opensbi && git apply ../../soc/fw/opensbi/0001-emulate-F-and-D-arithmetic.patch &&
 make PLATFORM=generic CROSS_COMPILE=riscv64-linux-gnu- FW_TEXT_START=0x80000000 \
    FW_JUMP_ADDR=0x80200000 FW_JUMP_FDT_ADDR=0x87f00000 FW_PAYLOAD=n)

make simtest OPENSBI=opensbi/build/platform/generic/firmware/fw_jump.bin
```

(OpenSBI as `soc/boards/README.md` builds it, for the compiler's own
RV64GC. Built with `PLATFORM_RISCV_ISA=rv64imac...` it has the
floating-point patch compiled out, and nothing says so until a program
that computes in floating point, `stats` or `clock`, is killed by
"illegal instruction".)

**With the framebuffer** the simulator is built with the terminal and
`-GFB=1`, its device tree with `--fb`, and `+frame=` writes the screen
to files (the last whole frame before each line is typed, every 250
million cycles after the last line, and at the end):

```
make -C ../soc/sim sim64 INPUT=1 SIMC="-DSIMSD -DSIMNET" \
    SOCG="-GVIRTIO=4 -GRXPIN=1 -GTERMINAL=1 -GFB=1"
python3 ../soc/tools/mkdts.py --model "Kakao SOC, sim, kakao64" --mem 256 \
    --consoles 1 --virtio 4 --isa rv64imafdc --fb > simfb.dts
dtc -q -O dtb -o simfb.dtb simfb.dts
echo kkrio > rio.txt
cd ../soc/sim && obj/simsoc64 +load=<fw_jump.bin>@80000000 \
    +load=<9kkcpu.bin>@80200000 +load=<simfb.dtb>@87f00000 \
    +type=<rio.txt> +frame=rio +max=3400000000
```

The kernel says `screen: 640x480x8`, finds the I/O processor's two
input devices (`input: virtio regs 0x10003000 irq 14` and `0x10004000
irq 15: a pointer to 639, 479`) and puts its console on the
framebuffer; `rio-0.ppm` is that console at the prompt, and a thousand
million cycles after `kkrio` is typed (21 seconds of the machine's
time) rio's three windows are up. It is slow going: an hour and a half
of this machine's time for the run, and the simulated machine itself
takes its time, the framebuffer being on the screen from reset there
(a board shows a terminal until Super with 0, and the scan-out costs
nothing until then). No keys or pointer in this simulation: it has no
USB devices.

Those OpenSBI settings are this document's guess at what the boards'
`fw_jump.bin` is built with; the repository does not say. The
simulator needs `riscv64-unknown-elf-gcc` (with the Linux compiler the
boot stub and the I/O processor's firmware do not build).

(The simulator types a script's next line when the console stops at a
prompt, and knows Plan 9's `% ` as one.)

What the simulation showed, besides the bugs above:

- **The first ping is not counted**, every time (three runs). All the
  frames reach the driver and are passed on (`rcv 4` for an ARP reply
  and three echo replies), and the other end answers every ping, but
  `ping` reports the first lost. In QEMU all are counted. Not looked
  into.
- **A line from OpenSBI in the kernel's banner** ("system_opcode_insn:
  Invalid opcode for CSR read/write instruction"): the kernel tries a
  machine-mode register to find out which mode it is in. The SOC's
  OpenSBI does not delegate illegal instructions (it emulates floating
  point with them), so it sees the attempt first, says so, and passes
  the trap on. Harmless.
- **The CLINT can be read from supervisor mode** (there is no PMP), and
  the kernel notices and reads the time there instead of asking the
  firmware. The timer is still set through SBI.
- **The device tree is in the middle of memory** on a board with
  512 MB (0x87f0_0000 is 127 MB up). The kernel has read it before it
  hands that memory out, and does not keep it.

## The board

The kernel runs on the Sergei ML2 with kakao64 (512 MB of DDR3): the
shell from the SD card, and rio on the framebuffer with a USB keyboard
and mouse. Not tried there yet: the network past finding the device,
and so the CPU server.

- **The clock** and **memory** come from the device tree.
- **The console's rate.** The kernel writes a divisor to the 16550;
  `rtl/k_uart.v` keeps the divisor and ignores it ("the rate is fixed"),
  so the console stays at the rate the SOC was built for.

- **Backspace and the interrupt key.** The SOC's terminal is made for
  Unix: Backspace sends DEL, which is Plan 9's interrupt key, and ^C
  means nothing to Plan 9. On the serial console the kernel therefore
  takes DEL as ^H and ^C as DEL, and rubs an erased character out on
  the terminal (`KKCONSKEYS`, `patches/console.patch`). The keyboard
  the kernel reads itself (on the framebuffer) is Plan 9's as it is.
- **^P on the console restarts a CPU server.** That is Plan 9's, not a
  fault; it is how stray bytes on the console line show.

The I/O processor's virtio code only takes buffers below 0xa000_0000,
which is all of 512 MB.

## Questions from the plan, answered

1. *How the kernel expects to be loaded.* As a flat image at the address
   it is linked for, entered at its first instruction; U-Boot is not
   needed. It works out for itself whether it is in machine or
   supervisor mode, by trying a machine-mode register and catching the
   trap, which OpenSBI passes back as it should.
2. *Configuration.* Compiled in, from `kkcpu`, but for what the device
   tree now gives.
3. *virtio.* The distribution's `ethertemu.c` is written for tinyemu and
   is not a virtio driver as the specification has it: it does no status
   or feature negotiation, takes the queue's size from the wrong
   register, and marks its descriptors in use with a flag bit that
   means "indirect" to a device. QEMU's device and the SOC's would both
   refuse it or misread it. `ethervirtio.c` is the driver written
   instead.
4. *SBI.* The kernel asks OpenSBI for the timer, and probes for the hart
   and reset extensions; QEMU 8.2's OpenSBI answers all of it.
5. *Accessed and dirty bits.* Fine without hardware updates.
6. *Memory.* "504M memory: 1689K+64M kernel, 440M user" with 512 MB;
   "120M memory: 1689K+25M kernel, 95M user" with 128 MB.
7. *Joining a Plan 9 network.* Done in QEMU: the machine is a CPU
   server with its own authentication server; another Plan 9 machine
   and drawterm on Linux log in to it.
8. *Speed.* Not measured: QEMU is not the SOC.
9. *The licence.* MIT, Plan 9 Foundation 2021, in the distribution.

## Next

1. **The network on a board**, and with it the CPU server.
2. **Speed.** How fast rio is; the DDR3 controller reading a row's
   blocks for the screen in one burst; the fonts out of the root's
   archive, which is most of the time the kernel takes to its prompt.
   Then a larger picture, and Linux on the same framebuffer.
3. **A disk** (virtio block, the SD card's second partition): a root
   that stays, `auth/keyfs`, a password that is asked for once.
4. **The clock** (goldfish RTC).

Smaller things left open: the first ping on the simulated SOC; the
allocator's missing check and what the kernel allocates as it starts;
the reboot trampoline's compiled address; one network device only;
drawterm with a window, not tried; a keyboard other than a US one;
more of the system's programs (acme, a plumber, more fonts).

## What the SOC has for Plan 9

Plan 9 needed little of the SOC, and what it got is the SOC's, for any
system: `soc/docs/design.md` and `soc/boards/README.md` are where it is
described.

- **`/sys/boot.txt`** (kboot, `soc/fw/kboot/sdboot.c`): the directory
  of `/sys` to boot from, so a card can hold more than one system.
- **`INPUT=1`**: the USB keyboard and mouse as two virtio input devices
  (`soc/fw/iop/vinput.c`), the host's when Super with 0 is pressed.
- **`FB=1`**: a framebuffer in the last 4 MB of main memory, 640 by
  480, 16 bits a pixel or 8 through 256 colours (`soc/rtl/k_fb.v`; the
  DDR3 controller with a port for it, `soc/rtl/mem/`).
- **`cbo.*` is refused** by kakao32 and kakao64 (`is_fence` in their
  decoders is funct3 000 and 001 only). The whole MISC-MEM opcode ran
  as a no-op before, and this kernel took `cbo.zero` doing nothing for
  a hart with Zicboz. The kakao32 half compiles and has not been run.
- **The simulator** (`soc/sim`) knows `% ` as a prompt, has the
  framebuffer (`-GFB=1`) and writes its picture to files (`+frame=`).

Both options are off unless asked for. With both, the Sergei ML2 with
kakao64 uses all of its block RAM, as it did without, and the I/O
processor's 44 KB of memory to within a few dozen bytes of what its
stack needs: there the type-ahead queue and the terminal's clipboard
are smaller than in other builds (`soc/docs/design.md`).

Tests there: `make input` (the firmware's devices, and how deep its
stack goes), `make ddr3fb` (the controller's port against Zeitlos's
model of the DRAM), `make hosttest` in `soc/fw/kboot`. kakao32 with
`FB=1` synthesises and has not been simulated; Linux has not been
tried on the framebuffer.
