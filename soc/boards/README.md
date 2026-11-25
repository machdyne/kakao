# The boards

One top for all of them, `kakao_top.v`, and one Makefile:

```
make BOARD=lakritz            build/lakritz/kakao.bit, kakao.dtb, boot.json
make BOARD=lakritz seeds      the same, placed with several seeds (SEEDS=)
                              and the fastest that meets 48 MHz kept
make BOARD=lakritz synth      only as far as what it takes of the FPGA
make boards                   the boards there are
make release                  every board's bitstream and card files,
                              zipped, with a summary (tools/release.sh)
```

| `BOARD=` | FPGA | main memory | monitor, keyboard | terminals | disk | network |
|---|---|---|---|---|---|---|
| `sergei_ml2`, `mozart_ml2` | 45F | 512 MB DDR3 | DDMI, 2 USB host ports | 8, and 60 rows of scroll buffer | SD card | RMII |
| `sergei_ml1`, `mozart_ml1` | 45F | 32 MB SDRAM | DDMI, 2 USB host ports | 8, and 60 rows of scroll buffer | SD card | RMII |
| `sergei_ml0`, `mozart_ml0` | 25F | 32 MB SDRAM | DDMI, 2 USB host ports | 1 | SD card | RMII |
| `lakritz` | 25F | 32 MB SDRAM | DDMI, 2 USB host ports | 2 | SD card | - |
| `konfekt` | 12F | 32 MB SDRAM | DDMI, 2 USB host ports | 2 | SD card | - |
| `klinge` | 25F | 512 MB DDR3 | none: the serial console only | - | SD card | RMII |

The disk and the network are the I/O processor's (virtio devices for
Linux: `../docs/design.md`). A board with no monitor, Klinge, has an
I/O processor for those two alone: 8 KB of memory and
`fw/iop/headless.c`, no terminal. On the Sergei boards and Klinge the
FPGA makes the Ethernet PHY's 50 MHz, on the Mozart boards the PHY
does.

The serial console is on the UART pins of the Sergei and Mozart boards.
On Lakritz, Konfekt and Klinge it is a USB serial port (CDC-ACM,
16d0:116d) on the USB-C socket, Zeitlos's `rtl/ext/usb_cdc` and the
pins Zeitlos uses for it (`CONSOLE = usb` in the Makefile): these
boards' pin files have no UART pins. As in Zeitlos, what is printed
waits up to ten seconds for a program on the host to read it, and is
dropped when no host is there at all. It has not run on a board.
Lakritz's Ethernet is a PMOD (Katze) and is not built in.

Sergei and Mozart are the boards the Sechzig modules (ML0, ML1, ML2)
plug into; a module's pins are the same on both but for what the board
adds, so each pair is one design with two pin files.

Every board has console 0 on its UART at 1 Mbaud 8N1, the SD card, and
`fw/kboot` in its boot memory. The pin files are Zeitlos's
(`ext/zeitlos/boards`), and so are the memory controllers, the DDMI
output and the USB host controller.

What is run on a board so far: **Sergei ML2 only**, with both CPUs.
With kakao32 everything tried worked: the terminals, the keyboard and
the mouse, the disk, the network, reset. With kakao64, Debian
(`../docs/debian.md`). Every board is built, placed and meets timing
(`make release`); the SOC on the SDRAM controller passes
`make -C ../sim sdram` against Zeitlos's model of the memory.

## kakao64

`CPU64=1` builds the SOC with kakao64 instead of kakao32, beside the
other as `build/<board>-64`, with kboot built for RV64, its own layout
of memory, device tree (`rv64imafdc`, `root=/dev/vda2`) and
`boot.json`:

```
make BOARD=sergei_ml2 CPU64=1
```

It is for the boards with 512 MB and a 45F. Its multiplier is four
16 by 16 DSP blocks used four times over, eight cycles a product
(`FAST_MUL=0`: 64 steps, no DSP blocks), its TLB 128 entries
(`TLB_BITS=`). It has four terminals and a data cache of 32 KB, where
kakao32's build has eight and 16 KB (`TERMS=8 D_KB=16` is that
division of the block RAM again; more terminals are `screen`'s to
give). `make BOARD=sergei_ml2 kakao64-bare` places the CPU alone, for
its size and clock.

Its card's `/sys/linux` holds:

```
boot.json           from build/<board>-64/
kakao.dtb           from build/<board>-64/: the device tree
kakao-busybox.dtb   from build/<board>-64/: the same, starting the busybox as init
fw_jump.bin         OpenSBI for RV64, with ../fw/opensbi's patch
Image               the kernel
```

and the root file system is the card's second partition
(`root=/dev/vda2`): Debian. `../tools/mkdebian.sh` makes the whole
card, and `../docs/debian.md` says how, and what the two device trees
are for. Loaded as on QEMU's `virt` for RV64: OpenSBI at 0x8000_0000,
the kernel at 0x8020_0000, the device tree at 0x87f0_0000.

- **OpenSBI** 1.9 with the patch:

  ```
  git -C opensbi am ../soc/fw/opensbi/0001-emulate-F-and-D-arithmetic.patch
  make -C opensbi PLATFORM=generic CROSS_COMPILE=riscv64-linux-gnu- \
      FW_TEXT_START=0x80000000 FW_JUMP_ADDR=0x80200000 \
      FW_JUMP_FDT_ADDR=0x87f00000 FW_PAYLOAD=n
  ```

- **The kernel**: Linux 6.6.18, unmodified, with
  `../../buildroot/board/kakao_soc/linux64.config`, built as kakao32's
  below.

### One card for both CPUs

kboot for kakao64 reads `/sys/linux/boot64.json` when there is one and
`boot.json` otherwise; kboot for kakao32 reads `boot.json`. So a card
can hold both systems, and the bitstream that is loaded chooses:

```
/sys/linux/boot.json       kakao32's list: fw_jump.bin, Image, rootfs.cpio, kakao.dtb
/sys/linux/boot64.json     kakao64's list, with names of its own for its files:
                           { "fw_jump64.bin": "0x80000000", "Image64": "0x80200000",
                             "kakao64.dtb": "0x87f00000" }
```

(The names in a list are free; only that two files cannot have one
name.) kakao32's root file system is loaded into memory, so it does
not mind what the card's second partition holds.

## What a board gets

Block RAM decides it: the 45F has 108 blocks, the 25F 56. (The 12F is
the 25F's die, and yosys and nextpnr use all of it.)

| | 45F | 25F, 12F |
|---|---|---|
| instruction + data cache | 64 + 16 KB | 16 + 16 KB |
| the I/O processor's memory | 44 KB (20 blocks) | 44 KB (20 blocks) |
| terminals | 8, and a scroll buffer of two screens for the first | 2; 1 with Ethernet (ML0) |
| the same with kakao64 (`CPU64=1`) | 64 + 32 KB, 4 terminals and the scroll buffer: all 108 blocks | - |
| block RAMs used, DDR3 board | 107 of 108 | 26 of 56 (Klinge: no I/O processor) |
| block RAMs used, SDRAM board | 103 of 108 | 54 of 56; 55 with Ethernet |

The 25F boards had four terminals before the disk, the network and the
mouse: the I/O processor's program grew from 36 to 44 KB with them.
`TERMS=`, `VIRTIO=0` (no disk, no network) and `I_KB=` trade them
against each other; an Ethernet MAC is three blocks (`ETH_RX_SLOTS=4`:
five).

All of it can be set on the command line: `I_KB=`, `D_KB=`,
`FAST_MUL=`, `TERMS=` (1 to 10), `HIST=` (screens of scroll buffer for
the first terminal, 0 to 3), `TLB_BITS=`, `TERMINAL=0` (no picture and
no keyboard: the serial console only, and the small I/O processor),
`USB=0`, `VIRTIO=0`, `KCACHE=0`
(Zeitlos's cache instead of `k_cache`), `LAYOUTS="us gb de fr"` (the
keyboard layouts built in, by Zeitlos's names).

A terminal costs a screen of cells in block RAM (2400 cells, a little
over two blocks) and a console for Linux, which is a 16550's registers
and nothing else (`rtl/k_vcon.v`): no pins, no rate. Console 0 is the
real UART and is also the first terminal.

## The SD card

(kakao32's; kakao64's is under "kakao64" above.)

A FAT partition (or a card that is one), and in `/sys/linux`:

```
boot.json       from build/<board>/: what kboot loads, and where
kakao.dtb       from build/<board>/: the device tree
fw_jump.bin     OpenSBI
Image           the kernel
rootfs.cpio     the root file system
```

`kakao.dtb` differs by board (its memory, how many consoles); the rest
is the same for all. Everything is loaded into the first 32 MB, which
every board has:

| Address | What |
|---|---|
| 0x8000_0000 | the kernel: at the bottom, since on RV32 Linux cannot use memory below its own image |
| 0x8100_0000 | the root file system |
| 0x81e0_0000 | OpenSBI, which kboot starts: the file `boot.json` names first |
| 0x81f0_0000 | the device tree |

- **OpenSBI**, generic platform, unmodified:

  ```
  make -C opensbi PLATFORM=generic CROSS_COMPILE=riscv64-linux-gnu- \
      PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
      FW_TEXT_START=0x81e00000 FW_JUMP_ADDR=0x80000000 \
      FW_JUMP_FDT_ADDR=0x81f00000 FW_PAYLOAD=n
  ```

- **The kernel**: Linux 6.6.18, unmodified, with
  `../../buildroot/board/kakao_soc/linux.config` (the 8250 driver for
  the consoles, the PLIC; RV32IMA without C or FPU, one hart):

  ```
  cp buildroot/board/kakao_soc/linux.config <build>/.config
  make -C linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=<build> olddefconfig
  make -C linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- O=<build> Image
  ```

  The prebuilt Kakao kernel in `../../images` (6.1, for the LiteX
  boards) is what the SOC ran first, with a device tree from
  `tools/mkdts.py --liteuart`: its only console driver is the LiteX
  UART's, which the SOC also answers as. It knows nothing of the
  terminals after the first.

- **The root file system**: Kakao's, with a login on every terminal
  the machine has. `../../buildroot/board/kakao_soc/post-build.sh` does
  that, as a buildroot post-build script or to a finished archive:

  ```
  buildroot/board/kakao_soc/post-build.sh images/rootfs.cpio rootfs.cpio
  ```

Without a card, or without `/sys/linux/boot.json` on it, kboot waits
for `tools/kload.py`, which sends the same files over the UART to the
same addresses, OpenSBI first: what was loaded first is what is
started.

When kboot cannot boot from a card it says what it found there (on the
DDR3 boards; the SDRAM boards' boot memory has no room for it): the
first partition's type and place when there is no FAT, and otherwise
the FAT's place and cluster size, how far towards `/sys/linux/boot.json`
it got and the names in the directory it stopped in.
`make -C fw/kboot hosttest` runs that code on the PC, and
`fw/kboot/build/hosttest/hosttest <image or /dev/sdX>` on a card of
your own.

A card written with `dd` is all there only once `dd` has been made to
wait for it: `dd if=card.img of=/dev/sdX bs=4M conv=fsync
status=progress`, and `cmp -n $(stat -c %s card.img) card.img /dev/sdX`
says whether it is. A card pulled early has the image's first part and,
after that, what it held before; that has looked like a journal that
cannot be read.

## The disk and the network

With `sys/linux/kakao.dtb` from this build, Linux finds the SD card as
`/dev/vda` (its partitions `vda1` and on; the root file system's
`fstab` is told by `post-build.sh`) and, on a board with Ethernet,
`eth0`. The card is kboot's until Linux first looks at it.

`reboot` resets the whole machine, as System, Reset in the terminal's
menus does (that one without asking Linux). `poweroff` stops Linux;
the board stays on.

## The terminal

With a monitor on DDMI and a USB keyboard on either host port (behind a
hub too), console 0 is on the screen as well as on the UART, and each
further terminal is a console of its own (`ttyS1` and on) with a login.

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

## Timing

The longest path is from the cache's tag memory through the comparison
to the CPU, and more than half of it is wires, so how fast a build is
depends on the seed: `make seeds` places with several and keeps the
fastest. The Sergei ML2 build, with everything in it and 107 of its 108
block RAMs used, placed at 49.9 to 53.4 MHz with six seeds of six,
Lakritz at 51.6 to 53.0 MHz with four of four, and every board met
48 MHz with the first seed tried. All timing is for speed grade 6.

With kakao64 the Sergei ML2 is 65% full and has less room: 49.61 MHz
with seed 2, which is the seed its builds have used, and other seeds
have given 45 to 50 (`../docs/kakao64.md`, "Timing").
