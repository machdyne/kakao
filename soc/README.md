# Kakao SOC

A Linux computer for Machdyne's ECP5 boards: two CPUs of its own,
kakao32 and kakao64, and a small SOC around either that looks like
QEMU's RISC-V `virt` machine, so that mainline Linux runs on it
unpatched.

| | CPU | boards |
|---|---|---|
| **Kakao Linux (Buildroot)** | kakao32: RV32IMA, Sv32 | all |
| **Kakao Linux (Debian)**: Debian 13, its own packages | kakao64: RV64IMAC, Sv39, F and D with the firmware's help | those with 512 MB and a 45F: Sergei ML2, Mozart ML2 |

It is a second hardware option for Kakao beside the LiteX VexRiscv SOC,
which stays supported.

## What it has

- **Terminals on the monitor**: 80 by 30 characters at 640x480 over
  DDMI, with a USB keyboard on either host port or behind a hub. Up to
  eight of them, each a console of its own for Linux with its own
  login; the first is the serial port's console too, and has a scroll
  buffer on the larger boards. A USB mouse selects text to copy and
  paste. Menus set the keyboard's layout and the colours.
- **A disk and a network**: the SD card is `/dev/vda` and the board's
  Ethernet `eth0`, as virtio devices, as on QEMU.
- **Booting from the SD card**: a FAT partition with OpenSBI, the
  kernel, a device tree and a list of what to load.
- **A serial console** at 1 Mbaud on the Sergei and Mozart boards, and
  as a USB serial port on Lakritz, Konfekt and Klinge.

The keys that are the terminal's own:

```
Super with 1 to 9            that terminal
Super with Left or Right     the terminal before, the next
Super with Up, Down,         the first terminal's scroll buffer
  Page Up, Page Down
Super alone, or Scroll Lock  the menus
Mouse, left button held      select text
Super with C, Super with V   copy it, type it
```

## Using a release

A release has, for each board, a zip with the bitstream and the files
for the SD card, and for Debian the whole card as an image.

**Kakao Linux (Buildroot)**: copy the zip's `sys` directory to a
FAT-formatted SD card, load `kakao32-<board>.bit`, log in as root.

**Kakao Linux (Debian)**: write the card image and load
`kakao64-<board>.bit`:

```
xz -dk kakao-linux-debian-<version>-<board>.img.xz
dd if=kakao-linux-debian-<version>-<board>.img of=/dev/sdX bs=4M conv=fsync status=progress
```

It boots to a root shell in seconds, with a busybox as init;
`/opt/kakao/install-systemd` installs Debian's own.
[docs/debian.md](docs/debian.md) has the rest.

The bitstream is loaded as any other for the board (machboot, or
`openFPGALoader`). Each zip's README says whether that board has been
run: so far the Sergei ML2 has.

## Building

```
git submodule update --init soc/ext/zeitlos
make -C soc/boards BOARD=sergei_ml2 seeds             # kakao32
make -C soc/boards BOARD=sergei_ml2 CPU64=1 seeds     # kakao64
```

makes `build/sergei_ml2/kakao.bit` (with `CPU64=1`,
`build/sergei_ml2-64/`) and the card's `kakao.dtb` and `boot.json`. It
needs yosys, nextpnr-ecp5 and ecppack, a RISC-V gcc
(`riscv64-unknown-elf-`, no C library) and dtc.
[boards/README.md](boards/README.md) has the boards, the options, what
goes on the SD card and how a release is made.

## Documents

| | |
|---|---|
| [boards/README.md](boards/README.md) | the boards, building, the SD card, releases |
| [docs/debian.md](docs/debian.md) | Kakao Linux (Debian): the card, its two ways to boot |
| [docs/design.md](docs/design.md) | the machine: memory map, the cache, the terminals, the disk and the network |
| [docs/kakao32.md](docs/kakao32.md), [docs/kakao64.md](docs/kakao64.md) | the CPUs |
| [sim/README.md](sim/README.md) | Linux under Verilator |
| [docs/zeitlos-notes.md](docs/zeitlos-notes.md) | things found in Zeitlos |

## Tests

All in simulation; each directory's Makefile says what it needs
(Verilator 5, a RISC-V gcc, and for some Icarus Verilog, dtc, or
Python with pyte or Pillow).

```
make -C soc/rtl/cpu/kakao32/tests     kakao32: riscv-tests and its own
make -C soc/rtl/cpu/kakao64/tests run kakao64: the same, 203 programs
make -C soc/rtl/tests                 the cache, the text mode, the consoles
make -C soc/fw/iop test               the terminal, against pyte
make -C soc/fw/kboot hosttest         kboot's FAT code, on cards made on the PC
make -C soc/sim ddr3                  the SOC on the DDR3 controller
make -C soc/sim sdram                 the SOC on the SDRAM controller
make -C soc/sim rom                   the PLIC and the UART's interrupts
make -C soc/sim usb                   a USB keyboard, on a port and behind a hub, and a mouse
```

[sim/README.md](sim/README.md) has Linux booting under Verilator, on
both CPUs.

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
  fw/firstlight/     a CPU's first test on a new board
  fw/memtest/, fw/plictest/   programs for the simulations
  sim/               Linux on the CPUs and on the SOC under Verilator; the
                     SOC on Zeitlos's DDR3 and SDRAM controllers; the I/O
                     processor with a USB keyboard and mouse
  tools/             kload.py (the host's end of kboot's loader), mkdts.py
                     (a board's device tree), mkfont.py (the terminal's
                     font), mkkbd.py (its keyboard layouts), mkdebian.sh
                     and debian/ (a Debian card), release.sh (a
                     release), mkimages.sh (OpenSBI, the kernels and
                     the busybox of ../images/soc, from source)
  boards/            the boards: one top, one Makefile (BOARD=)
  docs/              the documents above
  ext/zeitlos/       Zeitlos, a submodule pinned to a release: what both
                     projects share (DDR3, DDMI, the USB host and its
                     driver, the keyboard layouts, SD, the fonts) and the
                     boards' pin files
  ext/riscv-tests/   the RISC-V ISA tests, a submodule (for the CPUs' tests:
                     git submodule update --init --recursive soc/ext/riscv-tests)
```

Nothing Linux-specific goes into Zeitlos, and nothing here is edited
inside `ext/zeitlos`: a fix to what is shared is made in Zeitlos and the
pin is moved.

## Status

Both systems run on the **Sergei ML2**. No other board has been tried
yet; all are built and meet timing.

| | on a board | in simulation |
|---|---|---|
| DDR3, SD boot, the picture | Sergei ML2 | yes |
| USB keyboard and mouse, the menus, copy and paste, the scroll buffer | Sergei ML2 | yes |
| Linux 6.6.18, several terminals | Sergei ML2 | yes |
| the SD card as Linux's disk | Sergei ML2, with both CPUs | yes |
| the network | Sergei ML2, with both CPUs | yes |
| reset (`reboot`, the menu) | Sergei ML2 | yes |
| Debian 13 on kakao64, with systemd and with a busybox as init | Sergei ML2 | with the busybox; systemd takes too long to simulate |
| the SDRAM boards | no | yes |
| a board without a monitor (Klinge) | no | yes |
| the console as a USB serial port (Lakritz, Konfekt, Klinge) | no | its register side only |

On the Sergei ML2 at 48 MHz kakao32 does 27.98 DMIPS and 98.4 CoreMark
iterations a second, kakao64 18.87 and 60.6.

Not there: a clock that keeps time (it comes from the network),
settings kept over a power cycle, SPI and USB Ethernet. For kakao64,
speed is what is being worked on: systemd takes minutes to boot.

## Licence

The files forked from Zeitlos keep Zeitlos's licence header (Lone
Dynamics Corporation). The rest of this repository is BSD-2-Clause, as
[../LICENSE.md](../LICENSE.md) says. The keyboard layouts built into
the terminal are Zeitlos's, derived from xkeyboard-config
(`ext/zeitlos/sw/common/zkbd_layouts.LICENSE`).
