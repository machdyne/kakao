# Kakao SOC

A Linux computer for Machdyne's ECP5 boards, built for Kakao: two CPUs
of its own, kakao32 and kakao64, and a small SOC around either that
looks like QEMU's RISC-V `virt` machine, so that mainline Linux runs on
it unpatched.

It is a second hardware option for Kakao beside the LiteX VexRiscv SOC,
which stays supported.

## Status

**Linux runs on the Sergei ML2**, from the SD card, on both CPUs.

- With kakao32, **Kakao Linux (Buildroot)**: logins on the serial port
  and on the monitor's terminals, a USB keyboard and mouse, the SD card
  as its disk, the network, reset; everything tried there worked.
- With kakao64, **Debian 13**: Debian's own packages and its own init
  (systemd), or on the same card a busybox as init for a prompt in
  seconds; the SD card as its disk, the Ethernet as its network, apt
  from Debian's archive. [docs/debian.md](docs/debian.md).

Development is on that board. No other board has been tried (Lakritz is
next), and nothing is released yet.

What there is:

- **kakao32**, the CPU: RV32IMA with M, S and U modes and Sv32, a
  hardware page-table walker, a branch target buffer, and optionally its
  multiplier in DSP blocks. [docs/kakao32.md](docs/kakao32.md).
- **kakao64**, its 64 bit copy, for the boards with 512 MB and a 45F:
  RV64IMAC with Sv39, the floating-point registers, loads, stores and
  compares; the floating-point arithmetic is done by the SBI firmware
  (a patch to OpenSBI, `fw/opensbi`), so that Linux and Debian see
  RV64GC. [docs/kakao64.md](docs/kakao64.md).
- **The SOC** (`rtl/kakao_soc.v`): the CPU, separate instruction and
  data caches (`k_cache`), a CLINT, a PLIC, 16550 consoles, and the bus
  to main memory and the board's own devices.
  [docs/design.md](docs/design.md).
- **The terminals**: a second small processor (a picorv32, the "I/O
  processor") draws the console as 80 by 30 characters at 640x480 and
  takes a USB keyboard, on either host port and behind hubs. There are
  up to ten terminals (eight on the 45F boards, four with kakao64, two
  on the 25F), each a console of its own for Linux with its own login;
  Super with a digit, or with Left or Right, changes between them. On
  the 45F boards the first has a scroll buffer (Super with Up, Down,
  Page Up, Page Down). Its menus (a Super key pressed alone, or Scroll Lock) set the
  keyboard's layout, the colours and the cursor, and reset the machine.
  A USB mouse selects text; Super with C copies it and Super with V
  types it. The serial port is the first terminal's console too; on
  Lakritz, Konfekt and Klinge it is a USB serial port on the USB-C
  socket, as in Zeitlos.
- **The disk and the network**: the SD card and the board's Ethernet
  (RMII) are virtio devices for Linux, `/dev/vda` and `eth0`, as on
  QEMU. The I/O processor is both devices; it reaches Linux's memory
  through the CPU's data cache. The Ethernet address is made from the
  SD card's number: a card keeps its address.
- **kboot**, the boot ROM: brings the memory up (trains the DDR3 where
  there is one), tests it, and boots from a FAT SD card
  (`/sys/linux/boot.json`, in LiteX's format; `boot64.json` first on
  kakao64, so one card serves both CPUs) or loads over the UART
  (`tools/kload.py`). It says what it found on a card it cannot boot
  from.
- **The boards** ([boards/README.md](boards/README.md)): Sergei and
  Mozart with the Sechzig ML0, ML1 and ML2, Lakritz, Konfekt and
  Klinge, with 512 MB of DDR3 or 32 MB of SDRAM through Zeitlos's
  controllers.

It runs OpenSBI 1.9 and Linux 6.6.18. With kakao32 both are unmodified,
under Kakao's root file system; with kakao64 OpenSBI has the
floating-point patch and Linux is unmodified, under Debian
(`../buildroot/board/kakao_soc` has the kernels' configurations and
what the Buildroot root file system needs for the terminals).

Measured on the Sergei ML2 at 48 MHz: 27.98 DMIPS (0.58 DMIPS/MHz) and
98.4 CoreMark iterations a second (2.05 CoreMark/MHz).

How far each thing has been tested:

| | on a board | in simulation |
|---|---|---|
| DDR3, SD boot, the picture | Sergei ML2 | yes |
| USB keyboard, the menus | Sergei ML2 | yes |
| Linux 6.6.18 on the 16550s and the PLIC, several terminals | Sergei ML2 | yes |
| the SD card as Linux's disk | Sergei ML2, with both CPUs | yes: mount, read, write, the card's image checked |
| the network | Sergei ML2, with both CPUs (kakao64: DHCP, NTP, apt) | yes: ARP and ping against a model of the cable's other end |
| reset (`reboot`, the menu) | Sergei ML2 | yes |
| the mouse: selecting, copy and paste | Sergei ML2 | yes, with a model of a USB mouse |
| kakao64: Linux for RV64, floating point by the firmware | Sergei ML2: Debian 13 with systemd, and with a busybox as init | Debian's base system with the busybox: the same output as on QEMU. systemd: no, it takes too long |
| the SDRAM boards | no (Lakritz is placed and meets timing) | yes |
| a board without a monitor (Klinge): disk and network | no | yes |
| the console as a USB serial port (Lakritz, Konfekt, Klinge) | no | no: placed, and its register side tested, not the USB side |
| the first terminal's scroll buffer | no | its firmware's own test |

(On the Sergei ML2 with kakao32 everything that was tried worked; the
rows say "Sergei ML2" for that.)

Not there yet: settings kept over a power cycle, SPI and USB Ethernet,
a clock that keeps time; for kakao64, speed (systemd takes minutes to
boot), Debian's own kernel, and access faults for addresses above
4 GB.

## Layout

```
soc/
  rtl/cpu/kakao32/   the 32 bit CPU, and its tests
  rtl/cpu/kakao64/   the 64 bit CPU, and its tests
  rtl/               kakao_soc (the SOC's core), k_cache, k_port64 (kakao64's
                     way to it), k_clint, k_plic, k_uart, k_vcon (the
                     terminals' consoles), k_virtio (the disk's and the
                     network's registers); k_text (the text mode) and
                     k_iop (the I/O processor); tests/
  fw/kboot/          the boot ROM: DDR3 training, SD boot, a loader on the UART
  fw/iop/            the I/O processor's program: the terminals, the USB
                     keyboard and mouse, the menus, the disk, the network
  fw/opensbi/        the patch to OpenSBI for kakao64's floating point
  fw/firstlight/     the CPU's first-light test program
  fw/memtest/, fw/plictest/   programs for the simulations
  sim/               Linux on the CPU and on the SOC under Verilator; the
                     SOC on Zeitlos's DDR3 and SDRAM controllers; the I/O
                     processor with a USB keyboard
  tools/             kload.py (the host's end of kboot's loader), mkdts.py
                     (a board's device tree), mkfont.py (the terminal's
                     font), mkkbd.py (its keyboard layouts), mkdebian.sh
                     and debian/ (a Debian card for kakao64), release.sh
  boards/            the boards: one top, one Makefile (BOARD=)
  boards/sergei_ml2/ the first board's own: the CPU's first-light test
  docs/              design.md (the machine), kakao32.md and kakao64.md (the
                     CPUs), debian.md (Debian on kakao64), zeitlos-notes.md
  ext/zeitlos/       Zeitlos, a submodule pinned to a release: what both
                     projects share (DDR3, DDMI, the USB host and its
                     driver, the keyboard layouts, SD, the fonts) and the
                     boards' pin files
  ext/riscv-tests/   the RISC-V ISA tests, a submodule
```

Nothing Linux-specific goes into Zeitlos, and nothing here is edited
inside `ext/zeitlos`: a fix to what is shared is made in Zeitlos and the
pin is moved.

```
git submodule update --init soc/ext/zeitlos
git submodule update --init --recursive soc/ext/riscv-tests
```

## Building

```
make -C soc/boards BOARD=sergei_ml2 seeds
```

makes `build/sergei_ml2/kakao.bit`, and `kakao.dtb` and `boot.json` for
the SD card, with kakao32; `CPU64=1` makes the same with kakao64 in
`build/sergei_ml2-64`. It needs yosys, nextpnr-ecp5 and ecppack, a RISC-V gcc
(`riscv64-unknown-elf-`, no C library) and dtc.
[boards/README.md](boards/README.md) has the boards, the options, and
what goes on the SD card.

## Tests

All in simulation; each directory's Makefile says what it needs
(Verilator 5, a RISC-V gcc, and for some Icarus Verilog, dtc, or
Python with pyte or Pillow).

```
make -C soc/rtl/cpu/kakao32/tests     the CPU: riscv-tests and its own
make -C soc/rtl/cpu/kakao64/tests run the 64 bit CPU: the same, 203 programs
make -C soc/rtl/tests                 the cache, the text mode, the consoles
make -C soc/fw/iop test               the terminal, against pyte
make -C soc/sim ddr3                  the SOC on the DDR3 controller
make -C soc/sim sdram                 the SOC on the SDRAM controller
make -C soc/sim rom                   the PLIC and the UART's interrupts
make -C soc/sim usb                   a USB keyboard, on a port and behind a hub, and a mouse
make -C soc/sim/fptest                the floating-point tests for the firmware (sim/README.md runs them)
make -C soc/fw/kboot hosttest         kboot's FAT code, on cards made on the PC
```

[sim/README.md](sim/README.md) has Linux booting under Verilator.

## Licence

The files forked from Zeitlos keep Zeitlos's licence header (Lone
Dynamics Corporation). The rest of this repository is BSD-2-Clause, as
[../LICENSE.md](../LICENSE.md) says. The keyboard layouts built into
the terminal are Zeitlos's, derived from xkeyboard-config
(`ext/zeitlos/sw/common/zkbd_layouts.LICENSE`).
