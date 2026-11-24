# Kakao SOC

A Linux computer for Machdyne's ECP5 boards, built for Kakao: the
kakao32 CPU and a small SOC around it that looks like QEMU's RISC-V
`virt` machine, so that mainline Linux and OpenSBI run on it unpatched.

It is a second hardware option for Kakao beside the LiteX VexRiscv SOC,
which stays supported.

## Status

**Linux boots on the Sergei ML2**, from the SD card, on both CPUs: with
kakao32 to a login on the serial port and on a monitor, with a USB
keyboard; with kakao64 to Debian's base system, with the SD card as its
disk and the Ethernet as its network ([docs/kakao64.md](docs/kakao64.md)).
Development is on that board; nothing is released yet.

What there is:

- **kakao32**, the CPU: RV32IMA with M, S and U modes and Sv32, a
  hardware page-table walker, a branch target buffer, and optionally its
  multiplier in DSP blocks. [docs/kakao32.md](docs/kakao32.md).
- **The SOC** (`rtl/kakao_soc.v`): the CPU, separate instruction and
  data caches (`k_cache`), a CLINT, a PLIC, 16550 consoles, and the bus
  to main memory and the board's own devices.
  [docs/design.md](docs/design.md).
- **The terminals**: a second small processor (a picorv32, the "I/O
  processor") draws the console as 80 by 30 characters at 640x480 and
  takes a USB keyboard, on either host port and behind hubs. There are
  up to ten terminals (eight on the 45F boards, whose first has a
  scroll buffer: Super with Up, Down, Page Up, Page Down), each a console of its own for Linux with its own
  login; Super with a digit, or with Left or Right, changes between
  them. Its menus (a Super key pressed alone, or Scroll Lock) set the
  keyboard's layout, the colours and the cursor, and reset the machine.
  A USB mouse selects text; Super with C copies it and Super with V
  types it. The serial port is the first terminal's console too; on
  Lakritz, Konfekt and Klinge it is a USB serial port on the USB-C
  socket, as in Zeitlos.
- **The disk and the network**: the SD card and the board's Ethernet
  (RMII) are virtio devices for Linux, `/dev/vda` and `eth0`, as on
  QEMU. The I/O processor is both devices; it reaches Linux's memory
  through the CPU's data cache.
- **kboot**, the boot ROM: brings the memory up (trains the DDR3 where
  there is one), tests it, and boots from a FAT SD card
  (`/sys/linux/boot.json`, in LiteX's format) or loads over the UART
  (`tools/kload.py`).
- **The boards** ([boards/README.md](boards/README.md)): Sergei and
  Mozart with the Sechzig ML0, ML1 and ML2, Lakritz, Konfekt and
  Klinge, with 512 MB of DDR3 or 32 MB of SDRAM through Zeitlos's
  controllers.

It runs OpenSBI and Linux 6.6.18, both unmodified, and Kakao's root
file system (`../buildroot/board/kakao_soc` has the kernel's
configuration and what the root file system needs for the terminals).

Measured on the Sergei ML2 at 48 MHz: 27.98 DMIPS (0.58 DMIPS/MHz) and
98.4 CoreMark iterations a second (2.05 CoreMark/MHz).

How far each thing has been tested:

| | on a board | in simulation |
|---|---|---|
| DDR3, SD boot, Linux (the prebuilt 6.1 kernel), the picture | Sergei ML2 | yes |
| USB keyboard, the menus | Sergei ML2 | yes |
| Linux 6.6.18 on the 16550s and the PLIC | no | yes |
| several terminals | no | yes |
| the SDRAM boards | no (Lakritz is placed and meets timing) | yes |
| the SD card as Linux's disk | Sergei ML2, with kakao64 | yes: mount, read, write, the card's image checked |
| the network | Sergei ML2, with kakao64: DHCP, NTP, apt | yes: ARP and ping against a model of the cable's other end |
| reset (`reboot`, the menu) | no | yes |
| the mouse: selecting, copy and paste | no | yes, with a model of a USB mouse; plugged in at one particular moment it is not recognised (`sim/tb_iop_usb.v`) |

| a board without a monitor (Klinge): disk and network | no | yes |
| the console as a USB serial port | no | no: placed, and its register side tested, not the USB side |

| kakao64: Linux for RV64, floating point by the firmware | Sergei ML2: Debian's base system, a shell | yes |
| the first terminal's scroll buffer | no | its firmware's own test |

Not there yet: settings kept over a power cycle, SPI and USB Ethernet,
Debian's own init on kakao64.

## Layout

```
soc/
  rtl/cpu/kakao32/   the CPU, and its tests
  rtl/               kakao_soc (the SOC's core), k_cache, k_clint, k_plic,
                     k_uart, k_vcon (the terminals' consoles); k_text (the
                     text mode) and k_iop (the I/O processor); tests/
  fw/kboot/          the boot ROM: DDR3 training, SD boot, a loader on the UART
  fw/iop/            the I/O processor's program: the terminals, the USB
                     keyboard, the menus
  fw/firstlight/     the CPU's first-light test program
  fw/memtest/, fw/plictest/   programs for the simulations
  sim/               Linux on the CPU and on the SOC under Verilator; the
                     SOC on Zeitlos's DDR3 and SDRAM controllers; the I/O
                     processor with a USB keyboard
  tools/             kload.py (the host's end of kboot's loader), mkdts.py
                     (a board's device tree), mkfont.py (the terminal's
                     font), mkkbd.py (its keyboard layouts)
  boards/            the boards: one top, one Makefile (BOARD=)
  boards/sergei_ml2/ the first board's own: the CPU's first-light test
  docs/              design.md (the machine), kakao32.md (the CPU)
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
the SD card: it needs yosys, nextpnr-ecp5 and ecppack, a RISC-V gcc
(`riscv64-unknown-elf-`, no C library) and dtc.
[boards/README.md](boards/README.md) has the boards, the options, and
what goes on the SD card.

## Tests

All in simulation; each directory's Makefile says what it needs
(Verilator 5, a RISC-V gcc, and for some Icarus Verilog, dtc, or
Python with pyte or Pillow).

```
make -C soc/rtl/cpu/kakao32/tests     the CPU: riscv-tests and its own
make -C soc/rtl/tests                 the cache, the text mode, the consoles
make -C soc/fw/iop test               the terminal, against pyte
make -C soc/sim ddr3                  the SOC on the DDR3 controller
make -C soc/sim sdram                 the SOC on the SDRAM controller
make -C soc/sim rom                   the PLIC and the UART's interrupts
make -C soc/sim usb                   a USB keyboard, on a port and behind a hub
```

[sim/README.md](sim/README.md) has Linux booting under Verilator.

## Licence

The files forked from Zeitlos keep Zeitlos's licence header (Lone
Dynamics Corporation). The rest of this repository is BSD-2-Clause, as
[../LICENSE.md](../LICENSE.md) says. The keyboard layouts built into
the terminal are Zeitlos's, derived from xkeyboard-config
(`ext/zeitlos/sw/common/zkbd_layouts.LICENSE`).
