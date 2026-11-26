# The boards

One top for all of them, `kakao_top.v`, and one Makefile.

| `BOARD=` | FPGA | main memory | monitor, keyboard | terminals | disk | network | CPUs |
|---|---|---|---|---|---|---|---|
| `sergei_ml2`, `mozart_ml2` | 45F | 512 MB DDR3 | DDMI, 2 USB host ports | 8 (4 with kakao64) | SD card | RMII | kakao32, kakao64 |
| `sergei_ml1`, `mozart_ml1` | 45F | 32 MB SDRAM | DDMI, 2 USB host ports | 8 | SD card | RMII | kakao32 |
| `sergei_ml0`, `mozart_ml0` | 25F | 32 MB SDRAM | DDMI, 2 USB host ports | 1 | SD card | RMII | kakao32 |
| `lakritz` | 25F | 32 MB SDRAM | DDMI, 2 USB host ports | 2 | SD card | - | kakao32 |
| `konfekt` | 12F | 32 MB SDRAM | DDMI, 2 USB host ports | 2 | SD card | - | kakao32 |
| `klinge` | 25F | 512 MB DDR3 | none: the serial console only | - | SD card | RMII | kakao32 |

Sergei and Mozart are the boards the Sechzig modules (ML0, ML1, ML2)
plug into. Run on a board so far: **the Sergei ML2**, with both CPUs.
The others are built and meet timing.

The serial console is on the UART pins of the Sergei and Mozart boards,
at 1 Mbaud 8N1. On Lakritz, Konfekt and Klinge it is a USB serial port
(CDC-ACM, 16d0:116d) on the USB-C socket.

## Building

```
make BOARD=lakritz            build/lakritz/kakao.bit, kakao.dtb, boot.json
make BOARD=lakritz seeds      the same, placed with several seeds (SEEDS=)
                              and the fastest that meets 48 MHz kept
make BOARD=lakritz synth      only as far as what it takes of the FPGA
make BOARD=sergei_ml2 CPU64=1 with kakao64, in build/sergei_ml2-64
make boards                   the boards there are
make release                         a release (below)
```

It needs yosys, nextpnr-ecp5 and ecppack, a RISC-V gcc
(`riscv64-unknown-elf-`, no C library) and dtc. All timing is for speed
grade 6. How fast a build is depends on the seed, so `make seeds` is
the one to use for a bitstream that is to be kept.

Options, on the command line:

| | | |
|---|---|---|
| `CPU64=1` | kakao64 instead of kakao32 | the boards with 512 MB and a 45F |
| `TERMS=` | terminals, 1 to 10 | 8 on the 45F (4 with kakao64), 2 on the 25F, 1 with Ethernet there |
| `HIST=` | screens of scroll buffer for the first terminal, 0 to 3 | 2 on the 45F, 0 on the 25F |
| `I_KB=`, `D_KB=` | the instruction and data caches | 64 and 16 on the 45F (32 with kakao64), 16 and 16 on the 25F |
| `TLB_BITS=` | the TLB has 2^n entries | 5; 7 with kakao64 |
| `FAST_MUL=0` | the multiplier in steps, not in DSP blocks | |
| `TERMINAL=0` | no picture and no keyboard: the serial console only | Klinge |
| `USB=0`, `VIRTIO=0` | no USB; no disk and no network | |
| `LAYOUTS="us gb de fr"` | the keyboard layouts built in, by Zeitlos's names | `us gb de de-nodeadkeys` |
| `KCACHE=0` | Zeitlos's cache instead of `k_cache` | |
| `INPUT=1` | the USB keyboard and mouse are virtio input devices too, the host's with Super and 0 | off |
| `FB=1` | a framebuffer in the last 4 MB of main memory, 640 by 480, on the screen with Super and 0 (`docs/design.md`, "The framebuffer"); for `INPUT=1` | off; DDR3 boards |

## The SD card: Kakao Linux (Buildroot), kakao32

A FAT partition (or a card that is one), and in `/sys/linux`:

```
boot.json       from build/<board>/: what kboot loads, and where
kakao.dtb       from build/<board>/: the device tree
fw_jump.bin     OpenSBI
Image           the kernel
rootfs.cpio     the root file system
```

`fw_jump.bin` and `Image` are in `images/soc/rv32` of this repository,
prebuilt (kakao64's in `images/soc/rv64`); how they are built follows,
and `../tools/mkimages.sh` does it.

`kakao.dtb` differs by board (its memory, how many terminals); the rest
is the same for all. The root file system runs from memory.

- **OpenSBI** 1.9, generic platform, unmodified:

  ```
  make -C opensbi PLATFORM=generic CROSS_COMPILE=riscv64-linux-gnu- \
      PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
      FW_TEXT_START=0x81e00000 FW_JUMP_ADDR=0x80000000 \
      FW_JUMP_FDT_ADDR=0x81f00000 FW_PAYLOAD=n
  ```

- **The kernel**: Linux 6.6.18, unmodified, with
  `../../buildroot/board/kakao_soc/linux.config`:

  ```
  cp buildroot/board/kakao_soc/linux.config <build>/.config
  make -C linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=<build> olddefconfig
  make -C linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=<build> Image
  ```

- **The root file system**: Kakao's, with a login on every terminal
  the machine has. `../../buildroot/board/kakao_soc/post-build.sh` does
  that, as a buildroot post-build script or to a finished archive:

  ```
  buildroot/board/kakao_soc/post-build.sh images/rootfs.cpio rootfs.cpio
  ```

## The SD card: Kakao Linux (Debian), kakao64

A FAT partition with, in `/sys/linux`:

```
boot.json           from build/<board>-64/
kakao.dtb           from build/<board>-64/: the device tree
kakao-busybox.dtb   from build/<board>-64/: the same, starting the busybox as init
fw_jump.bin         OpenSBI for RV64, with ../fw/opensbi's patch
Image               the kernel
```

and Debian as the card's second partition (`root=/dev/vda2`).
`../tools/mkdebian.sh` makes the whole card, and
[../docs/debian.md](../docs/debian.md) says how, and what the two
device trees are for.

- **OpenSBI** 1.9 with the patch:

  ```
  git -C opensbi am ../soc/fw/opensbi/0001-emulate-F-and-D-arithmetic.patch
  make -C opensbi PLATFORM=generic CROSS_COMPILE=riscv64-linux-gnu- \
      FW_TEXT_START=0x80000000 FW_JUMP_ADDR=0x80200000 \
      FW_JUMP_FDT_ADDR=0x87f00000 FW_PAYLOAD=n
  ```

- **The kernel**: Linux 6.6.18, unmodified, with
  `../../buildroot/board/kakao_soc/linux64.config`, built as above.

## One card for both CPUs

kboot for kakao64 reads `/sys/linux/boot64.json` when there is one and
`boot.json` otherwise; kboot for kakao32 reads `boot.json`. So a card
can hold both systems, and the bitstream that is loaded chooses:

```
/sys/linux/boot.json       kakao32's list: fw_jump.bin, Image, rootfs.cpio, kakao.dtb
/sys/linux/boot64.json     kakao64's list, with names of its own for its files:
                           { "fw_jump64.bin": "0x80000000", "Image64": "0x80200000",
                             "kakao64.dtb": "0x87f00000" }
```

The names in a list are free; only two files cannot have one name.

## One card for more than one system

`/sys/linux` is where kboot looks unless the card says otherwise: a
file `/sys/boot.txt`, whose first word is another directory of `/sys`.
With `plan9` in it kboot reads `/sys/plan9/boot.json` (or
`boot64.json`), and the names in that list are files of `/sys/plan9`.
A list can name another directory's file by its path, so what two
systems share is on the card once:

```
/sys/boot.txt              plan9
/sys/plan9/boot.json       { "/sys/linux/fw_jump.bin": "0x80000000",
                             "9kkcpu.bin": "0x80200000",
                             "/sys/linux/kakao.dtb": "0x87f00000" }
/sys/plan9/9kkcpu.bin
/sys/linux/...             as before
```

To boot the other system, change the word (or remove the file: Linux).
The word is at most fifteen letters. kboot is in the bitstream, so this
needs a bitstream built since it was added.

## Writing a card, and a card that does not boot

```
dd if=card.img of=/dev/sdX bs=4M conv=fsync status=progress
cmp -n $(stat -c %s card.img) card.img /dev/sdX && echo written
```

A card pulled before `dd` has finished has the image's first part and,
after that, what it held before.

When kboot cannot boot from a card it says what it found there (on the
DDR3 boards): the first partition's type and place when there is no
FAT, and otherwise the FAT's place and cluster size, how far towards
`boot.json` it got and the names in the directory it stopped in. `make -C ../fw/kboot hosttest` builds the same code for the PC, and
`../fw/kboot/build/hosttest/hosttest <image or /dev/sdX>` runs it on a
card of your own.

Without a card kboot waits for `../tools/kload.py`, which sends the
same files over the UART.

## On the machine

Linux finds the SD card as `/dev/vda` and, on a board with Ethernet,
`eth0`. The Ethernet address is made from the SD card's number: a card
keeps its address. `reboot` resets the whole machine, as System, Reset
in the terminal's menus does (that one without asking Linux).
`poweroff` stops Linux; the board stays on. There is no clock that
keeps time: it comes from the network.

With a monitor on DDMI and a USB keyboard on either host port (behind a
hub too), the serial console is on the screen as well, and each further
terminal is a console of its own (`ttyS1` and on) with a login.

```
Super with 1 to 9, or 0      that terminal (0 is the tenth)
Super with Left or Right     the terminal before, the next
Super with Up or Down        the first terminal's scroll buffer, a row
Super with Page Up or Down   ...25 rows (a key typed returns)
Super alone, or Scroll Lock  the terminal's menus: the keyboard's
                             layout, the colours, the cursor, reset
Mouse, left button held      select text
Super with C                 copy what is selected
Super with V                 type what was copied
```

None of these keys is passed on to Linux. When what is on the USB
ports changes, a note at the top right says what is there.

## A release

```
make release
sudo sh ../tools/release.sh -n
```

The first (`../tools/release.sh`) builds every board with kakao32, and
those it is for with kakao64, each placed with several seeds, and packs
for each the bitstream with its card's files, into `build/release`.
The second places nothing and packs again as root, which adds for
Debian the whole card as an image (the files in it have owners, so
that part needs root; the bitstreams do not). `SUMMARY.md` there lists
what was made, how fast each placed and which boards have been run.
`-v` names the version, which is otherwise the year and month, and
boards named after the options are the only ones done.

Nothing else has to be built or found first. OpenSBI, the kernels and
the busybox are in [`images/soc`](../../images/soc/README.md),
prebuilt, and they are the files that have been run on a board;
`../tools/mkimages.sh` builds them again from source, which is wanted
only after a change to a kernel configuration or to OpenSBI's patch.
Kakao's root file system is `images/rootfs.cpio`, and Debian's is
fetched from Debian's official images the first time, into
`build/debian`. `-i <directory>` takes other files than these.

Which boards kakao64 is for, and which have been run, are `BOARDS64`
and `TESTED` in the Makefile.

---

# Details

## What a board gets

Block RAM decides it: the 45F has 108 blocks, the 25F 56. (The 12F is
the 25F's die, and yosys and nextpnr use all of it.)

| | 45F | 25F, 12F |
|---|---|---|
| instruction + data cache | 64 + 16 KB | 16 + 16 KB |
| the I/O processor's memory | 44 KB (20 blocks) | 44 KB (20 blocks) |
| terminals | 8, and a scroll buffer of two screens for the first | 2; 1 with Ethernet (ML0) |
| the same with kakao64 | 64 + 32 KB, 4 terminals and the scroll buffer: all 108 blocks | - |
| block RAMs used, DDR3 board | 107 of 108 | 26 of 56 (Klinge: a small I/O processor) |
| block RAMs used, SDRAM board | 103 of 108 | 54 of 56; 55 with Ethernet |

A terminal costs a screen of cells in block RAM (2400 cells, a little
over two blocks) and a console for Linux, which is a 16550's registers
and nothing else: no pins, no rate. An Ethernet MAC is three blocks
(`ETH_RX_SLOTS=4`: five). `TERMS=`, `VIRTIO=0` and `I_KB=` trade them
against each other. kakao64 has its data cache's second 16 KB from
four terminals; `TERMS=8 D_KB=16` is the other division.

A board with no monitor, Klinge, has an I/O processor for the disk and
the network alone: 8 KB of memory and `fw/iop/headless.c`.

## Memory, as kboot loads it

kakao32, everything in the first 32 MB, which every board has:

| Address | What |
|---|---|
| 0x8000_0000 | the kernel: at the bottom, since on RV32 Linux cannot use memory below its own image |
| 0x8100_0000 | the root file system |
| 0x81e0_0000 | OpenSBI, which kboot starts: the file `boot.json` names first |
| 0x81f0_0000 | the device tree |

kakao64, as on QEMU's `virt` for RV64: OpenSBI at 0x8000_0000, the
kernel at 0x8020_0000, the device tree at 0x87f0_0000.

## The consoles' pins

On Lakritz, Konfekt and Klinge the console is Zeitlos's
`rtl/ext/usb_cdc` on the pins Zeitlos uses for it (`CONSOLE = usb` in
the Makefile): these boards' pin files have no UART pins. As in
Zeitlos, what is printed waits up to ten seconds for a program on the
host to read it, and is dropped when no host is there at all.
Lakritz's Ethernet is a PMOD (Katze) and is not built in. On the Sergei
boards and Klinge the FPGA makes the Ethernet PHY's 50 MHz, on the
Mozart boards the PHY does.

A module's pins are the same on Sergei and Mozart but for what the
board adds, so each pair is one design with two pin files. The pin
files are Zeitlos's (`ext/zeitlos/boards`), and so are the memory
controllers, the DDMI output and the USB host controller.

## Timing

The longest path is from the cache's tag memory through the comparison
to the CPU, and more than half of it is wires, so how fast a build is
depends on the seed. With kakao32 the Sergei ML2 placed at 49.9 to
53.4 MHz with six seeds of six, Lakritz at 51.6 to 53.0 MHz with four
of four, and every board met 48 MHz with the first seed tried.

With kakao64 the Sergei ML2 is 65% full and has less room: 49.61 MHz
with seed 2, and other seeds have given 45 to 50
([../docs/kakao64.md](../docs/kakao64.md)). `tools/release.sh` tries
seed 2 first.

`make BOARD=sergei_ml2 kakao64-bare` places kakao64 alone, for its size
and clock. `sergei_ml2/` has a CPU's first test on a board
(`make firstlight`) and kboot's test in simulation.
