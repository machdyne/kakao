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
| 0x0010_1000 | 4 KB | real-time clock | `google,goldfish-rtc` | 11 | yes |
| 0x0200_0000 | 64 KB | CLINT: msip, mtimecmp, mtime | `sifive,clint0` | | yes |
| 0x0300_0100 | 256 B | the cache's registers | (firmware only) | | yes (not in QEMU's map) |
| 0x0300_0700 | 16 B | main memory's registers (DDR3 training) | (firmware only) | | yes (not in QEMU's map) |
| 0x0c00_0000 | 6 MB | PLIC | `sifive,plic-1.0.0` | | yes, 16 sources |
| 0x1000_0000 | 256 B | UART 0: console 0, the serial port and the first terminal | `ns16550` | 10 | yes |
| 0x1000_0100 .. 0x1000_0900 | 256 B each | consoles 1..9: the other terminals | `ns16550` | 1..9 | yes, as many as the board has terminals (not in QEMU's map) |
| 0x1000_1000 .. 0x1000_4000 | 4 KB each | virtio-mmio slots: the SD card as a disk, the network, two free | `virtio,mmio` | 12..15 (QEMU's 1..8 are the consoles' here) | yes, where there is an I/O processor |
| 0x1010_0000 | | fw-cfg | `qemu,fw-cfg-mmio` | | no |
| 0x2000_0000 | | flash | `cfi-flash` | | no |
| 0x3000_0000 | | PCI | `pci-host-ecam-generic` | | no |
| 0x8000_0000 | 32 MB .. 512 MB | main memory | | | SDRAM or DDR3 |

The consoles after the first and the framebuffer are the SOC's
additions; they are described in the board's device tree
(`tools/mkdts.py`) and use mainline drivers (`ns16550`,
`simple-framebuffer`).

## Who implements what

- **Gateware**: CLINT, PLIC, the 16550 register sets, the
  reset/power-off device, the virtio-mmio register slots, the text mode
  and the framebuffer scan-out, and the memory controller (from
  Zeitlos).
- **The I/O processor**, a second small RISC-V core (picorv32 or
  zeitlos32) on the 48 MHz clock with its own block RAM, running
  bare-metal firmware built from Zeitlos's drivers:
  - the terminal: UART 0's transmit side is drawn into the text mode,
    its receive side takes keys from the USB keyboard;
  - the virtio back ends: block (SD card, USB sticks), net (ESP32 WiFi,
    RMII, USB CDC-ECM adapters), input (USB keyboard and mouse, as raw
    events), console (extra terminals), rng (the TRNG);
  - the USB host stack: the I/O processor owns the USB ports, Linux
    does not see the controller;
  - the menu: on a hotkey over the text screen, and on the USB-C socket
    as a CDC serial device.
- **OpenSBI**, generic platform, in M-mode: the SBI timer, console and
  reset, and emulation of what the CPU traps (misaligned accesses).

## The cache

`rtl/k_cache.v`: an instruction cache and a data cache, each
direct-mapped with 16-byte lines (one DDR3 block), sizes `I_KB` and
`D_KB`. Stores stay in the data cache until the line is needed for
something else, and then go to memory as four stores to one block,
which Zeitlos's DDR3 controller writes as one (`WCOMBINE`). `fence.i`
empties the instruction cache; a line the data cache holds unwritten
is written back before it is fetched from memory as instructions. Bit 0
of 0x0300_0110 turns it on (off at reset; turning it on empties it).

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
beside the keyboard. (Plugged in at one particular moment the mouse is
not recognised: `sim/tb_iop_usb.v` says what is known, `make usb-late`
shows it.)

The USB controller needs a 48 MHz clock (four clocks a full-speed
bit). The SOC's clock is that today; when it is not, the I/O processor
and what hangs on it get a clock of their own.

The first terminal can have a scroll buffer: `HIST` screens more of
cells, which make its ring that much longer (nothing else in the
gateware changes), so that what scrolls off its top stays. Super with
Up or Down moves the picture a row, with Page Up or Page Down 25; a key
typed returns to the screen. The mouse's pointer is shown while the
mouse moves and for two seconds after.

Not there yet: the settings kept over a power cycle, choosing what the
machine boots from the menus, a console faster than a UART for the
first terminal (the terminal draws about 60,000 characters a second;
UART 0 at 1 Mbaud gives it 100,000 at most), the mouse as a device
Linux sees.

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

The network device offers no features: Linux gives the interface an
address of its own choosing at each boot (`ip link set eth0 address`
sets another), and frames go one buffer each.

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
then it starts OpenSBI at 0x8000_0000. Without a card it takes the
same files over the UART (`tools/kload.py`). `boards/README.md` has
what goes on the card.

## Later options

- A VGA/EGA register front on the text mode with a Linux fork (vgacon
  is not built for RISC-V in mainline), and with it a Linux driver for
  the Zeitlos USB host controller, so that Linux owns screen, keyboard
  and USB itself.
- An X server driver for the Zeitlos blitter.
- kakao64 (RV64GC, Sv39) for Debian: `docs/kakao64.md`. It runs; what
  is left is there.
