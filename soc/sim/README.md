# Linux in simulation

Both CPUs and the whole SOC under Verilator: `sim_main.cpp` runs a
model, loads the binaries, prints the console and can type a script at
it.

| | |
|---|---|
| `make boot OPENSBI=...` | kakao32 alone on a memory that answers at once (`sim_top.v`), booting the image in `../../images` |
| `make boot SIM=simsoc ...` | the SOC (`sim_soc.v`: `rtl/kakao_soc.v` with a main memory that takes its time), with terminals, a disk and a network as asked for |
| `make sim64` | the SOC with kakao64 |
| `make ddr3`, `make sdram` | the SOC on Zeitlos's memory controllers and their models (Icarus) |
| `make rom` | the PLIC and the UART's interrupts |
| `make usb`, `make usb-late` | the I/O processor with a USB keyboard and a mouse |

A boot to a prompt is some five minutes for the CPU alone and about
twenty for the SOC.

## kakao32 alone

Needs Verilator, dtc and a RISC-V Linux gcc for OpenSBI
(`gcc-riscv64-linux-gnu` builds RV32 OpenSBI).

```
git clone https://github.com/riscv-software-src/opensbi
make -C opensbi PLATFORM=generic CROSS_COMPILE=riscv64-linux-gnu- \
    PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
    FW_TEXT_START=0x81e00000 FW_JUMP_ADDR=0x80000000 \
    FW_JUMP_FDT_ADDR=0x81f00000 FW_PAYLOAD=n

make boot OPENSBI=opensbi/build/platform/generic/firmware/fw_jump.bin
make boot OPENSBI=... TYPE=script.txt     # log in as root and run commands
```

Memory, as `make boot` loads it (64 MB at 0x8000_0000):

| Address | What |
|---|---|
| 0x8000_0000 | the kernel (`Image`) |
| 0x8100_0000 | the root file system (`rootfs.cpio`) |
| 0x81e0_0000 | OpenSBI (`fw_jump.bin`) |
| 0x81f0_0000 | the device tree (`kakao-sim.dts`) |

A script is typed a line at a time, each line when the console has
gone quiet at a prompt (`login: `, `# ` or `$ `); the simulation ends
after the last line's answer.

## Linux 6.6.18 and several terminals

The prebuilt kernel knows one console. The SOC's own kernel
(`../boards/README.md` says how it is built) has the 8250 driver and
the PLIC, and with it each terminal is a console with a login:

```
make obj/simsoc_t4 SOCBIN=simsoc_t4 \
    SOCG="-GKCACHE=1 -GI_KB=64 -GTERMINAL=1 -GTERMS=4 -GRXPIN=1"
python3 ../tools/mkdts.py --model sim --mem 64 --consoles 4 \
    --initrd 0x81000000 0x81800000 > obj/t4.dts
dtc -I dts -O dtb -o obj/t4.dtb obj/t4.dts
make boot SIM=simsoc_t4 OPENSBI=... IMAGE=<Image> INITRD=<rootfs.cpio> \
    DTB=obj/t4.dtb TYPE=script.txt
```

`RXPIN` types the script at UART 0's pin, where the 8250 driver
listens. At the end the screen of every terminal is printed: the
first's with what the script did, the others' with their logins.
With `-GMEM_MB=32` and `--mem 32` it is a board with 32 MB.

In a script, `\e` is ESC, and what follows it comes at once, as a
terminal sends a key (`\e[A` is the up arrow). With `SIMC=-DSIMKEYS` a
line `@2 ...` is typed at terminal 2 instead (put into its console's
receiver, as the I/O processor would).

## The disk and the network

`-GVIRTIO=2` adds the virtio slots with what the boards have behind
them: Zeitlos's SPI master with a model of an SD card (`sd_card.v`),
and its RMII MAC with a model of the cable's other end
(`rmii_peer.v`, and in `sim_main.cpp` a host at 10.0.0.1 that answers
ARP and pings).

```
make obj/simsoc_n SOCBIN=simsoc_n SIMC="-DSIMKEYS -DSIMSD -DSIMNET" \
    SOCG="-GKCACHE=1 -GI_KB=64 -GTERMINAL=1 -GTERMS=4 -GRXPIN=1 -GVIRTIO=2"
python3 ../tools/mkdts.py --model sim --mem 64 --consoles 4 --virtio 2 \
    --initrd 0x81000000 0x81800000 > obj/v.dts
dtc -I dts -O dtb -o obj/v.dtb obj/v.dts
obj/simsoc_n +load=<fw_jump.bin>@81e00000 +load=<Image>@80000000 \
    +load=<rootfs.cpio>@81000000 +load=obj/v.dtb@81f00000 \
    +type=script.txt +sd=card.img +sdout=after.img +linger=60000000
```

`+sd` is the card's contents (16 MB, `-GSD_MB=`; a partition table and
a FAT partition made with mtools will do) and `+sdout` what they are
at the end, to compare with what Linux said it wrote. `+linger` is how
long to go on after the script's last line: `reboot` there ends the
run with "the machine was RESET". A script for all of it:

```
root
ip link set eth0 address 02:00:00:00:00:02
ip addr add 10.0.0.2/24 dev eth0 && ip link set eth0 up
ping -c 3 10.0.0.1
mount /dev/vda1 /mnt && ls /mnt && umount /mnt
reboot
```

`EXTRA=-DVDEBUG SOCD="-DK_IOP_LOG -DK_VIRTIO_LOG"` writes the disk's
requests and the virtio registers' traffic into the log.

## kakao64

`make sim64` builds `obj/simsoc64`: the SOC with kakao64, 256 MB, and a
boot stub that enters OpenSBI at 0x8000_0000 with the device tree at
0x87f0_0000 (`obj/boot64`). What it runs:

```
make -C fptest                # riscv-tests' rv64uf and rv64ud as one image
obj/simsoc64 +load=<fw_jump.bin>@80000000 +load=fptest/obj/fptest.bin@80200000 \
    +load=<dtb>@87f00000 +max=900000000
```

ends with a dot for each program and `ALL PASS`, the firmware
(`../fw/opensbi`) doing the arithmetic. `make -C fptest qemu
OPENSBI=<fw_jump.bin>` runs the same image on QEMU's `virt`, whose
floating point is its own.

Linux, as the Sergei ML2 build has it (run from this directory: the
boot memories' files are named from here):

```
make sim64 SIMC="-DSIMSD -DSIMNET" SOCD="-DSIM_SD_MB=96" \
    SOCG="-GVIRTIO=2 -GFAST_MUL=1 -GWC=1 -GI_KB=64 -GD_KB=32 -GTLB_BITS=7 -GRXPIN=1"
obj/simsoc64 +load=<fw_jump.bin>@80000000 +load=<Image>@80200000 \
    +load=<kakao.dtb>@87f00000 +sd=card.img +sdout=after.img +type=script.txt
```

The card's second partition is the root file system. `-GWC=1` is the
memory controller's write combining, which the boards have and the
simulation's memory leaves out unless told (without it the same boot
takes a fifth more cycles). `-GRXPIN=1` is needed for a script to be
typed at Linux. The end of the run says how many cycles and
instructions it was, and by what the CPU was waiting for. About 20
minutes for a boot to a prompt.

`SOCD=-DK_TRAPS` prints every trap kakao64 takes, and with `+kw` every
register it writes.

The card's size is `SOCD=-DSIM_SD_MB=<n>`, up to about 120: Verilator
will not have a larger memory. A larger card is two windows of it,
`-DSIM_SD_LOW_MB=`, `-DSIM_SD_HI_MB=` and `-DSIM_SD_HILEN_MB=`; the
rest reads as zeros (`sd_card.v`). `+sd=` is then the two windows one
after the other.

Debian's base system has been run this way (a 120 MB card made of
`tools/mkdebian.sh`'s root, without its documents), with the same
commands as on QEMU and the same output; systemd has not: its boot is
hours of simulation.

## The framebuffer

With the terminal and `-GFB=1` the simulated SOC has the framebuffer
(`docs/design.md`): the last 4 MB of its memory, shown from reset, and
a port for it on the simulation's model of main memory.

```
make sim64 INPUT=1 SIMC="-DSIMSD -DSIMNET" \
    SOCG="-GVIRTIO=4 -GRXPIN=1 -GTERMINAL=1 -GFB=1"
obj/simsoc64 +load=<picture>@8fc00000 +frame=out +max=3000000
```

`+frame=out` writes the screen as the video signal has it to
`out-0.ppm`, `out-1.ppm` and so on: the last whole frame before each
line of a script is typed, one every 250 million cycles after the last
line, and one at the end. The two lines above show a picture of 640 by
480 pixels, `r5g6b5`, without a system: the simulation has 256 MB, so
the framebuffer is at 0x8fc0_0000. A system needs a device tree made
with `tools/mkdts.py --fb`. `plan9/docs/port.md` has Plan 9 and its
window system run this way.

`make ddr3fb` tests the DDR3 controller's port for the framebuffer
against Zeitlos's model of the DRAM, and `make input` the keyboard and
the mouse as virtio input devices; both with Icarus Verilog.

---

# Notes

## The first numbers

`sim_top.v` is kakao32 with a memory, a CLINT, a 16550 and a LiteX
UART: enough of a machine for OpenSBI and Linux. It boots the Kakao
image in `../../images` as it is: OpenSBI 1.9 (unmodified, generic
platform), then the prebuilt Linux 6.1 kernel and root file system, to
the login prompt; logging in as root and running a few commands
(`uname -a`, `cat /proc/cpuinfo`, `free`, `ls /`, `echo 6*7 | bc`) ends
at 552 million clock cycles: 11.5 simulated seconds at 48 MHz. That is
249 million instructions at 2.21 cycles each, with a memory that
answers every request the next cycle.

The prebuilt kernel has only the LiteX UART for a console (no 8250, no
SBI console), which is why the simulated machine has one.

With Zeitlos's unified cache (`-GKCACHE=0`) and a main memory of 6
cycles for a read of a new 16-byte block, 1 for the rest of it and 10
for a write, the same boot, login and script:

| | cycles | cycles an instruction | at 48 MHz |
|---|---|---|---|
| CPU on an ideal memory (`obj/sim`) | 552 million | 2.21 | 11.5 s |
| SOC, 32 KB cache (`make CACHE_KB=32`) | 1,340 million | 5.39 | 28 s |
| SOC, 8 KB cache | 1,748 million | 7.07 | 36 s |

So the memory system, not the CPU, sets the speed, by a wide margin:
which is why the SOC has a cache of its own (`../docs/design.md`).
