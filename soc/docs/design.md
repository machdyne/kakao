# The machine

The Kakao SOC copies QEMU's RISC-V `virt` machine: the same devices at
the same addresses. Linux on RISC-V finds its hardware through the
device tree, so a kernel needs no change as long as every device has a
mainline driver, and `virt`'s devices are the ones every RISC-V kernel
is built and tested with. The same kernel image boots in
`qemu-system-riscv32 -M virt` and on a board, which makes QEMU the
reference when something does not work.

[qemu-virt-rv32.dts](qemu-virt-rv32.dts) is the device tree QEMU 8.2.2
generates for `-M virt -m 256m` (dumped with `-machine dumpdtb=`). It is
the reference, not the board's device tree: a board's lists only what
the SOC has.

## Memory map

| Address | Size | Device | Compatible | IRQ | In the SOC |
|---|---|---|---|---|---|
| 0x0010_0000 | 4 KB | reset and power-off | `sifive,test1`, `syscon` | | yes: 0x7777 resets the whole machine (OpenSBI's reboot); 0x5555 does nothing on a board, which cannot turn itself off |
| 0x0010_1000 | 4 KB | real-time clock | `google,goldfish-rtc` | 11 | no: nothing on the boards keeps time; the time comes from the network |
| 0x0200_0000 | 64 KB | CLINT: msip, mtimecmp, mtime | `sifive,clint0` | | yes |
| 0x0300_0100 | 256 B | the cache's registers | (firmware only) | | yes (not in QEMU's map) |
| 0x0300_0700 | 16 B | main memory's registers (DDR3 training) | (firmware only) | | yes (not in QEMU's map) |
| 0x0300_1000 | 4 KB | the framebuffer's registers: depth, and 256 colours | `kakao,ctrl` of the framebuffer's node | | with `FB=1` (not in QEMU's map) |
| 0x0c00_0000 | 6 MB | PLIC | `sifive,plic-1.0.0` | | yes, 16 sources |
| 0x1000_0000 | 256 B | UART 0: console 0, the serial port and the first terminal | `ns16550` | 10 | yes |
| 0x1000_0100 .. 0x1000_0900 | 256 B each | consoles 1..9: the other terminals | `ns16550` | 1..9 | yes, as many as the board has terminals (not in QEMU's map) |
| 0x1000_1000 .. 0x1000_4000 | 4 KB each | virtio-mmio slots: the SD card as a disk, the network, two free | `virtio,mmio` | 12..15 (QEMU's 1..8 are the consoles' here) | yes, where there is an I/O processor |
| 0x1010_0000 | | fw-cfg | `qemu,fw-cfg-mmio` | | no |
| 0x2000_0000 | | flash | `cfi-flash` | | no |
| 0x3000_0000 | | PCI | `pci-host-ecam-generic` | | no |
| 0x8000_0000 | 32 MB .. 512 MB | main memory | | | SDRAM or DDR3 |
| the last 4 MB of main memory | 4 MB | the framebuffer, 640 by 480 | `simple-framebuffer` | | with `FB=1`: not the system's memory then |

The consoles after the first are the SOC's addition; they are
described in the board's device tree (`tools/mkdts.py`) and use a
mainline driver (`ns16550`). The picture is the text mode's, which the
host does not see; a build with `FB=1` has a framebuffer besides ("The
framebuffer", below).

## Who implements what

- **Gateware**: CLINT, PLIC, the 16550 register sets, the reset
  device, the virtio-mmio register slots, the text mode, and the
  memory controller (from Zeitlos).
- **The I/O processor**, a second small RISC-V core (a picorv32) on
  the 48 MHz clock with its own block RAM, running bare-metal firmware
  built from Zeitlos's drivers:
  - the terminals: each console's output is drawn into the text mode,
    and takes its keys from the USB keyboard;
  - the virtio back ends: block (the SD card) and net (the RMII
    Ethernet), and with `INPUT` the keyboard and the mouse (input).
    Thought of and not built: USB sticks, SPI and USB Ethernet, WiFi,
    a random number device;
  - the USB host stack: the I/O processor owns the USB ports, Linux
    does not see the controller;
  - the menus, on a key, over the text screen.
- **OpenSBI**, generic platform, in M-mode: the SBI timer, console and
  reset, emulation of what the CPU traps (misaligned accesses), and
  for kakao64, with a patch, floating-point arithmetic.

## The cache

`rtl/k_cache.v`: an instruction cache and a data cache, each
direct-mapped with 16-byte lines (one DDR3 block), sizes `I_KB` and
`D_KB`. Stores stay in the data cache until the line is needed for
something else, and then go to memory as four stores to one block,
which Zeitlos's DDR3 controller writes as one (`WCOMBINE`). `fence.i`
empties the instruction cache; a line the data cache holds unwritten
is written back before it is fetched from memory as instructions. Bit 0
of 0x0300_0110 turns it on (off at reset; turning it on empties it).

What it gives, how it was arrived at, and what was done for the clock
are at the end ("Notes on the cache").

## The terminal

With `TERMINAL`, `kakao_soc` has the hardware terminal, and with
`TERMS` more than one of them:

- `rtl/k_text.v`, the text mode: 80 x 30 characters of 8x16 in 16
  colours at 640x480. `TERMS` screens of 2400 cells each in one memory,
  of which one is shown: which is three registers, so changing
  terminals copies nothing. A screen's 30 rows are a ring, so a scroll
  is one row cleared and a register written. A cursor, a font ROM
  (`tools/mkfont.py`: ASCII, the boxes, Latin-1 and the euro sign), a
  table of the sixteen colours, and an overlay: a second screen of
  cells over the first (its first 25 rows), with colours of its own,
  for the menus. Where an overlay cell is 0 the terminal shows, so the
  terminal goes on underneath and nothing has to be saved or put back.
- `rtl/k_vcon.v`, the consoles after the first: `TERMS - 1` 16550s for
  the host of which only the registers exist. What Linux writes to one
  goes to the I/O processor with the console's number, and what is
  typed at that terminal comes back the same way. No pins, no rate, no
  FIFO: about 70 LUTs a console.
- `rtl/k_iop.v`, the I/O processor: a picorv32 (RV32IC: the compressed
  instructions make its program a quarter smaller, and its memory is
  block RAM) with 44 KB of its own memory, the text mode on its bus,
  the consoles' characters in a queue, and (`USB`) Zeitlos's USB host
  controller at the address Zeitlos's driver expects it.
- `fw/iop`, its program:
  - `term.c`, a VT100/Linux-console terminal, UTF-8 as far as the font
    goes; as many of them as there are consoles. `make test` there
    compares it with pyte, a terminal emulator in Python, on the Linux
    boot's console output and on made-up streams of text and
    sequences.
  - Zeitlos's USB host stack, as it is in `ext/zeitlos/sw/apps/usb`
    (`usbh.c`, the hub driver, the HID driver): keyboards on either
    port, behind hubs too. `usbglue.c` and `shim/` are what it needs
    from here; storage, serial and ethernet devices enumerate and are
    left alone.
  - `kbd.c`: the keyboards' reports become keys, the keys characters of
    the chosen layout (Zeitlos's `zkbd.c` and its tables from
    xkeyboard-config; `tools/mkkbd.py` takes the layouts named in
    `LAYOUTS`, as built `us gb de de-nodeadkeys`), the characters
    UTF-8, and the named keys the sequences xterm and Linux's console
    send, to the console of the terminal shown. Dead keys, AltGr, Caps
    and Num Lock with their lights, key repeat.
  - `hud.c`: the menus. A bar on the top line with menus dropping from
    it (System, Keyboard, Display, Help), lists for the layouts, the
    colour schemes and the menus' own themes, windows for what is only
    read, and a question before the machine is reset. `make hud_test`
    and `tests/hud.py` draw them on the host.
  - `mouse.c`: a USB mouse's pointer (a cell with its colours
    exchanged; the USB controller keeps its place), text selected with
    the left button held, Super with C to keep it and Super with V to
    type it into the terminal shown, in brackets where the host asked
    for them. The selection is the text mode's, two registers; what is
    kept is in the I/O processor's memory, a screenful at most. Linux
    does not see the mouse.

The keys that are the terminal's own: either Super (Windows) key
pressed and let go alone, or Scroll Lock, opens and closes the menus;
Super with a digit shows that terminal (1 the first, 0 the tenth), and
Super with Left or Right the one before or the next; Super with C and
with V copy and paste. A terminal has no
bytes to send for a Super key or for Scroll Lock, so nothing on the
host can be waiting for them, and nothing typed while Super is held is
passed on.

Console 0 is UART 0, tapped: each character the host sends is also
queued for the I/O processor (when the queue is full the consoles'
transmitters look busy, so nothing is lost), and what the terminal has
to say to the host (keys; a cursor report, while a keyboard is plugged
in) goes into the console's receiver as if it had come from a pin. So
the serial port and the first terminal are the same console. For Linux
every console is a `ns16550` (not an `a`: they have no FIFOs) with its
own interrupt at the PLIC, and each terminal gets a login
(`buildroot/board/kakao_soc`).

In `soc/sim`, `-GTERMINAL=1 -GTERMS=4 -GRXPIN=1` boots Linux with four
terminals and prints their screens at the end, and `make usb` runs the
I/O processor with Zeitlos's model of a USB device as a keyboard, on a
root port and behind its model of a hub, and as a mouse plugged in
beside the keyboard, in the middle of the keyboard's test and (`make
usb-late`) at its end.

The USB controller needs a 48 MHz clock (four clocks a full-speed
bit). The SOC's clock is that today; when it is not, the I/O processor
and what hangs on it get a clock of their own.

The first terminal can have a scroll buffer: `HIST` screens more of
cells, which make its ring that much longer (nothing else in the
gateware changes), so that what scrolls off its top stays. Super with
Up or Down moves the picture a row, with Page Up or Page Down 25; a key
typed returns to the screen. The mouse's pointer is shown while the
mouse moves and for two seconds after.

### The keyboard and the mouse as the host's own devices

Built with `INPUT=1` (`boards/Makefile`; off unless asked for), the
keyboard and the mouse are also two virtio input devices, in the third
and fourth virtio slots (`fw/iop/vinput.c`): what Linux's
`virtio_input` driver and Plan 9's `kkinput.c` take. They are for a
host that draws its own picture: with the framebuffer (`FB=1`, below)
they are what a window system needs.

Which of the two the keys and the mouse are is chosen at the keyboard.
Super with 0 is the graphics screen: from then on a key is an event of
the host's keyboard, down and up, with Linux's key code and no
repeats (the host makes its own), and the mouse is the host's pointer;
with `FB=1` the framebuffer is on the screen from then on.
Super with another digit, or with Left or Right, is a terminal again,
and what the host thought was held down is let go. (With ten terminals
the tenth is reached with Super and Left; Super with 0 is no longer
it.) The Super keys and Scroll Lock never reach the host, and the
menus open over the graphics screen as over a terminal and take the
keys while they are open.

The pointer is a place, not a movement: the USB controller keeps the
pointer's place itself, in pixels of the picture, so the host's device
is one with absolute axes, X from 0 to 639 and Y to 479, and the three
buttons. The keyboard's Num, Caps and Scroll Lock lights are the
host's to set while it has the keyboard.

A virtio input device's configuration is asked rather than read: the
driver writes what it wants to know and reads the answer. So a slot's
configuration can now be written (`virtio.c`: `cfg_read`,
`cfg_write`), with the byte lanes the host used, which `k_virtio.v`
already passed on.

It costs the I/O processor 1.7 KB of program and 0.3 KB of data, which
its 44 KB do not have to spare on the Sergei ML2 with kakao64 (and
there is no block RAM left there to make them more). So a build with
`INPUT=1` takes them from two places: the queue of characters typed
ahead for the hosts is 128 long, not 256, and the terminal's clipboard
holds 2112 bytes, 26 full lines, not a whole screen. What must be left
over is the stack, 1024 bytes of it (`fw/iop/link.ld`): it has been
seen 656 deep, finding USB devices and drawing "About this machine",
and when there were 512 it went into the data below it, the queue of
typed characters first, and the host was sent keys nobody had pressed.
`make input` watches how deep it goes. A build that still does not fit
can leave a keyboard layout out (`LAYOUTS=`), half a kilobyte each.

On the Sergei ML2 with kakao64 the two more virtio slots are about 120
more logic cells placed (29,272 against 29,150). One place-and-route of
each with the same seed, on an older nextpnr (0.6) than the boards are
built with, gave 45.0 MHz with `INPUT=1` and 46.9 MHz without: both
short of 48 MHz there, where the release's tools reach 49.6, so the
difference says little more than that this build has no slack to give
and wants its seeds tried (`make seeds`).

`make input` in `soc/sim` (`tb_iop_input.v`) is its test: the I/O
processor with Zeitlos's models of a USB keyboard and mouse, the virtio
slots, and a driver's side of them written out in the testbench.

### The framebuffer

Built with `FB=1` (`boards/Makefile`; off unless asked for; DDR3 boards
with the terminal and `k_cache`), the last 4 MB of main memory are a
framebuffer: 640 by 480 pixels from their first byte, a line after the
other, shown where a terminal would be when Super with 0 is pressed
(`INPUT=1`, above, goes with it: the keys and the mouse are the host's
on that screen). The device tree has it as a `simple-framebuffer` in
`r5g6b5`, and has that much less memory for the system.

- **Two depths.** 16 bits a pixel, `r5g6b5`, is how it starts, and what
  a `simple-framebuffer` driver finds. Bit 0 of the word at 0x0300_1000
  makes it 8 bits a pixel through 256 colours, which are the words from
  0x0300_1400 on (0x00rrggbb, write only): half the bytes to draw and
  to read out, and what Plan 9 uses. A line is 640 pixels either way,
  so 1280 or 640 bytes. Bits 31..16 of the same word count the blocks
  that came too late for the picture, which should stay 0.
- **Reading it out** (`rtl/k_fb.v`). The picture's blocks of 16 bytes
  are read from main memory as the screen is drawn, ahead of it, into
  a queue of eight between the SOC's clock and the pixel clock (in
  distributed RAM, as the colours are: the Sergei ML2 with kakao64 has
  no block RAM left). The frame's first block is asked for when the
  last line has been drawn, so the queue is full when the next frame
  begins. Nothing is read while a terminal is shown.
- **The memory's second port.** The scan-out does not go through the
  bus: main memory has a port for it (`fb_*`), on which a whole block
  is read at once and which is served before the bus. The DDR3
  controller with that port is the SOC's own copy of Zeitlos's
  (`rtl/mem/k_ddr3.v`, `k_ddr3_ctrl.v`; the PHY and the clocks are
  still Zeitlos's files), used by builds with `FB=1` only: every other
  build has Zeitlos's controller as before. A block read for the
  screen does not touch the controller's block register, so the bus's
  stores still combine, and what the register holds unwritten is on the
  screen when it is written, 8 idle cycles later at the most.
- **The cache out of the way** (`rtl/k_cache.v`: `FB`, `FB_AT`). What a
  write-back cache holds the screen does not show, so the 4 MB are not
  cached: an access to them is one of the memory's own, as a device's
  is. That makes the framebuffer slow to write and slower to read, and
  a host that draws a lot does better drawing in ordinary memory and
  writing what has changed, whole words and in order, which the
  controller's write combining turns into one write a block. Plan 9
  does (`plan9/docs/port.md`).
- **The text mode's part** (`rtl/k_text.v`). A register, GRAPHICS
  (0x20020 of the text mode's, the I/O processor's to write), puts the
  framebuffer's pixels where the terminal's would be, from a frame's
  beginning. The menus and the notes still open over it.

**What it costs.** At 640 by 480 and 16 bits the screen reads 80 blocks
a line, 38,400 a frame, each an ACTIVATE and a READ of its own: 13 of
the controller's cycles (10 to the data, and the row's closing), of
the 19 there are for a block while a line is drawn. So for as long as
the framebuffer is shown the memory is the screen's for about two
thirds of the time and the CPU's for the rest (8 bits a pixel: one
third); how much slower that makes a program depends on how
often it misses the caches. Reading a row's blocks in one burst, the
row left open, would cut that to a fraction, and is what a larger
picture needs first: 1024 by 768 at 16 bits does not fit as it is. The
size is `k_fb.v`'s parameters and the text mode's timing; 4 MB are room
for 1280 by 1024 at 16 bits.

`make ddr3fb` in `soc/sim` (`tb_ddr3_fb.v`) tests the controller's port
against Zeitlos's model of the DRAM, which checks the protocol's
timing: blocks read at the screen's rate while the bus reads and
writes, in the same rows and others. The simulated SOC has the port in
its model of main memory (`sim_soc.v`, `-GFB=1`), shows the
framebuffer from reset, and writes the picture to a file (`+frame=`).

Not there yet: the settings kept over a power cycle, choosing what the
machine boots from the menus, a console faster than a UART for the
first terminal (the terminal draws about 60,000 characters a second;
UART 0 at 1 Mbaud gives it 100,000 at most).

## The disk and the network

Linux's disk is the SD card and its network the board's Ethernet, both
as virtio devices, as on QEMU's `virt`: `virtio_blk` and `virtio_net`
are the drivers, and nothing in Linux knows the card or the MAC. The
devices are the I/O processor's programs.

- `rtl/k_virtio.v`, the slots: a register page for each device, of
  which the gateware answers only what a driver uses all the time (a
  queue's notification, the interrupt's status and its
  acknowledgement). Any other register the host reads or writes is
  held as a request, the host waits, and the I/O processor answers it:
  tens of microseconds, when a driver starts.
- `k_cache`'s second port: the I/O processor reads and writes the
  host's memory, at the host's own addresses, through the host's data
  cache. The queues and the buffers are in that memory, and the CPU's
  stores stay in its cache until their line is needed for something
  else; through the cache each side sees what the other wrote, and
  Linux needs to know nothing of it. While the I/O processor has the
  port the CPU waits. One access of the CPU's has to give way the
  other way round: a virtio register that waits for the I/O processor,
  which may be in the middle of looking into memory; the cache puts
  that access aside and makes it again afterwards.
- `fw/iop/virtio.c`: the registers (virtio over MMIO, version 2) and
  the queues. `vblk.c` and `sd.c`: the SD card as a block device, a
  sector at a time, so that the terminal and the keyboard go on while
  a long request is done; straight between the card and the host's
  memory. `vnet.c`: the network device, over `nic.h`'s five functions,
  of which `nic_rmii.c` (Zeitlos's RMII MAC, on the boards with a PHY)
  is the one implementation so far. An SPI Ethernet controller or a
  USB adapter is another file with the same five functions.
- The board's devices for the I/O processor are on a bus of its own
  (`iox_*`, its 0x4000_0000): the SD card's SPI master and the MAC.
  kboot boots from the card through the same SPI master on the CPU's
  bus; it becomes the I/O processor's when that first asks for it,
  which is when Linux first looks at its disk, and is the CPU's again
  after a reset.

The network device's Ethernet address is made from the SD card's own
number (its CID), marked as locally given (02:...): a card keeps its
address from boot to boot, which a DHCP server likes, and nothing has
to be stored for it. Without a card Linux gives the interface a random
address at each boot. `ip link set eth0 address` sets another either
way. Frames go one buffer each.

A machine without a terminal (Klinge, which has no monitor and no USB
host; `TERMINAL=0`) has an I/O processor all the same when it has
virtio slots: the same picorv32 with 8 KB, running the virtio devices
and nothing else (`fw/iop/headless.c`). With `VIRTIO=0` too it has
none.

### The console as a USB serial port

`k_uart` with `PIPE=1` has a byte pipe in place of its pins (valid,
data, ready each way), and the board's top puts Zeitlos's CDC-ACM
device on it. To the host it is the same 16550: the divisor is
accepted and means nothing, the transmitter is busy until the USB side
has taken the byte, and what arrives from USB goes into the receive
queue and waits at the USB side when that is full. A byte nobody takes
for ten seconds stops holding the machine up, and so does having no
host at all (no frame and no configuration two seconds after power
on). The USB device is not reset with the machine, so the host's port
stays through a reboot.

## Clocks

Everything but the picture is on one 48 MHz clock today: the board's
on an SDRAM board, the DDR3's on a DDR3 board. The plan is the CPU, its
cache and the memory controller on their own PLL output, as fast as
the board closes timing, with USB, SD and the I/O processor staying on
48 MHz behind a clock crossing. Video has its own clocks, as in
Zeitlos.

## Boot

machboot loads the bitstream. `fw/kboot`, in the CPU's boot memory,
brings the main memory up (on a DDR3 board with Zeitlos's trainer),
tests a little of it, and loads OpenSBI, the kernel, the device tree
and the root file system from `/sys/linux` on the SD card's FAT
partition, where `boot.json` (LiteX's format) says what goes where;
then it starts the file named first, which is OpenSBI. kboot for
kakao64 reads `boot64.json` where there is one, so a card can hold
both CPUs' systems. Without a card kboot takes the same files over the
UART (`tools/kload.py`), and a card it cannot boot from it describes.
`boards/README.md` has what goes on the card.

## Not built, thought of

- A VGA/EGA register front on the text mode with a Linux fork (vgacon
  is not built for RISC-V in mainline), and with it a Linux driver for
  the Zeitlos USB host controller, so that Linux owns screen, keyboard
  and USB itself.
- An X server driver for the Zeitlos blitter.
- kakao64 (RV64GC, Sv39) is no longer one: Debian boots on it
  ([kakao64.md](kakao64.md), [debian.md](debian.md)).

---

## Notes on the cache

Numbers, in simulation with a memory that answers as the DDR3
controller does (a new block after 10 cycles, each further word of it
after 2), for the Linux boot to a shell and five commands, about 250
million instructions:

| | cycles | per instruction |
|---|---|---|
| the CPU on an ideal memory (before FAST_XLATE) | 552,108,354 | 2.21 |
| Zeitlos's cache, 32 KB, stores written through | 1,635,594,379 | 6.57 |
| k_cache 16 + 16 KB | 1,256,831,423 | 4.99 |
| the same, the CPU with FAST_XLATE (from here on) | 1,167,668,906 | 4.61 |
| k_cache 64 + 16 KB | 976,824,502 | 3.87 |
| k_cache 64 + 32 KB | 949,939,059 | 3.73 |

(Before FAST_XLATE: 32 + 32 KB 4.43, 64 + 16 KB 4.26, 64 + 64 KB 3.99.)

Where the time goes with 16 + 16 KB: of 24.9 million line fills, 18.4
million are for instructions (5.9% of fetches miss), and a fill is
about 18 cycles of memory: 10 for the block and 2 for each further
word, a word at a time over the bus. Three of four fetches that miss
are of the line after the last one that missed: code run for the first
time, straight on. So:

- The instruction cache is where size pays, on boards with block RAM
  to spare (the Sergei ML2 build takes `I_KB`, `D_KB`).
- Fetching the next line ahead was built and works, and is on the
  branch `kakao32-prefetch`, not here: it turns 13.8 million misses
  into waits of 12.6 cycles on average, because the CPU is through a
  line long before the next one has arrived, and the boot gains 2%.
- What would help both is a line arriving sooner: the DDR3 controller
  handing over its 16-byte block at once (it has it in a register)
  would make a fill 11 cycles instead of 18; two blocks from one
  ACTIVATE would make 32-byte lines worth having.
- A fetch or load that misses is answered when its word arrives, not
  when the line is complete; that gains under 1%.
- The CPU's static branch prediction (`BTFN`) gains 0.7% here.

A request's registers are loaded whenever a request could be taken,
without waiting to know that the one before it hit: a fetch or load
that misses is put back and looked up again, two cycles on a miss.
That, and what else kakao64 needed between it and the cache (a port
that turns a doubleword into two accesses and holds two requests), is
in [kakao64.md](kakao64.md), "Timing"; kakao64's numbers are there
too.

### The cache and the clock

The SOC's longest path starts in the instruction cache's tag memory: a
block RAM's output is there 5.6 ns after the clock, the comparison
with the address follows, and its result decides in the same cycle
what the CPU does next. What was done about it:

- The tags are compared on the carry chain, not in a tree of LUTs.
- The answer to the CPU (`c_ack`, `c_rdy`) has one comparison for both
  caches: each of its bits takes the instruction cache's tag or the
  data cache's, as the request is a fetch or not. The caches' own two
  comparisons are still there for what is not in a hurry (a store into
  the cache, the miss).
- What decides nothing in that cycle does not wait for it: the bus's
  address and data registers load with every request.
- In the CPU the answer passes one LUT before the registers it enables
  (`docs/kakao32.md`).

The I/O processor had the next longest: its memory's and the text
mode's block RAM outputs went straight into picorv32's instruction
decoding. What it reads goes through a register now, and each of its
accesses takes a cycle more.
