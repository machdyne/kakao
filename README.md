# Kakao

Kakao is a set of operating systems for Machdyne FPGA computers: each is a distribution or a port of a system to the Kakao SOC, a computer for the FPGA with CPUs of its own.

| System | CPU | Status |
| ------ | --- | ------ |
| **Kakao Linux (Buildroot)** | rv32 | Works. Released for the LiteX VexRiscv SOC (the boards listed below). On the Kakao SOC with kakao32 it runs on the Sergei ML2, with the monitor, keyboard and mouse, the SD card as its disk and the network; the other boards are built and not yet tried, and nothing is released there yet. |
| **Kakao Linux (Debian)** | rv64 | Boots on the Sergei ML2 with kakao64: Debian 13 (trixie) from Debian's own packages, with its own init (systemd, which takes minutes to come up on this CPU) or, on the same card, a busybox as init for a prompt in seconds; the SD card as its disk, the network, apt. Not released; speed is what is being worked on. See [soc/docs/debian.md](soc/docs/debian.md). |
| **Kakao Plan 9** | rv64 | In progress. |
| **Kakao NetBSD** | rv64 | Planned. |

## The Kakao SOC

The hardware all of them are for is in [soc/](soc/README.md). To software it looks like QEMU's RISC-V `virt` machine (CLINT, PLIC, 16550 consoles, virtio disk and network), so a system that runs there needs little or nothing changed to run here: the mainline Linux kernel is used as it is, and OpenSBI too but for one patch for kakao64's floating point.

  - **kakao32**: RV32IMA with M, S and U modes and Sv32. Runs Kakao Linux (Buildroot).
  - **kakao64**: RV64IMAC with Sv39 and, with the firmware's help, F and D: what Debian's riscv64 port is built for. For the boards with 512 MB of memory and an ECP5 45F or larger. Runs Kakao Linux (Debian).
  - An I/O processor beside the CPU is the text terminals on the monitor (with a USB keyboard and mouse) and the virtio devices: the SD card as a disk, Ethernet.

It is built for Sergei, Mozart, Lakritz, Konfekt and Klinge ([soc/boards](soc/boards/README.md)) and is not released yet.

# Kakao Linux (Buildroot, rv32)

Kakao Linux is essentially a buildroot configuration with extra packages that makes certain assumptions about the hardware and MicroSD card partition layout.

Its goal is to provide a minimal practical environment with access to useful timeless applications.

This repo contains everything necessary to build it from source, the steps described here can replace the buildroot steps from the individual board repos.

It can be configured to either:

  1. Keep a small rootfs (<8MB) in RAM and optionally mount additional filesystems later.
  2. Mount rootfs from an ext2 partition on the MicroSD card.

The rest of this README is about Kakao Linux on the LiteX VexRiscv SOC, which stays supported. On the Kakao SOC: [soc/README.md](soc/README.md).

## Supported Boards

  - [Schoko](https://machdyne.com/product/schoko-computer)
  - [Konfekt](https://machdyne.com/product/konfekt-computer)
  - [Noir](https://machdyne.com/product/noir-computer)
  - [Kopflos](https://machdyne.com/product/kopflos-computer)
  - [Minze](https://machdyne.com/product/minze-computer)
  - [Lakritz](https://machdyne.com/product/lakritz-computer)
  - [Vanille](https://machdyne.com/product/vanille-computer)
  - [Mozart](https://machdyne.com/product/mozart-motherboard)

Kakao may also work with other boards supported by [linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv).

## Applications

The ramdisk version of Kakao includes the following notable applications:

  - vi (text editor)
  - nano (text editor)
  - tinyscheme (lisp interpreter)
  - screen (text window manager + terminal emulator)
  - links (text-based web browser)
  - ark (a script for searching and reading offline information)
  - lesen (a script for reading books)
  - dropbear (ssh client + server)
  - busybox (ls, cp, grep, awk, sed, etc.)

While the sdroot version includes these plus additional apps.

## Installation

### Preparing a MicroSD card

At least a 8GB MicroSD card is recommended. It is also recommended to create all 4 partitions even if they're not going to be used immediately.

Example partition layout for a 32GB MicroSD card:

| Partition # | Size | Mount Point | Purpose | Type | Id |
| ------------| ---- | ----------- | ------- | ---- | -- |
| 1 | 512MB | - | boot partition | FAT32 (LBA) | 0x0c |
| 2 | 4GB | / | rootfs or additional applications | ext2 | 0x83 |
| 3 | 20GB | /home | user data | ext2 | 0x83 |
| 4 | 4GB | /opt/ark | read-only data | ext2 | 0x83 |

Note: The 4th partition is mounted read-only and intended for the [Ark](https://github.com/machdyne/ark) information distribution which contains public domain books and other useful data for offline computers.

#### Creating partitions

Determine the device for your MicroSD card and use it in place of /dev/sdX in the following instructions.

```
$ sudo fdisk -c /dev/sdX
```

Use the IDs in the above table when creating the partitions.

#### Formatting

```
$ sudo mkfs.msdos /dev/sdX1
$ sudo mkfs.ext2 /dev/sdX2
$ sudo mkfs.ext2 /dev/sdX3
$ sudo mkfs.ext2 /dev/sdX4
```

### Installing Kakao Linux

Copy the `Image` and `rootfs.cpio` files from this repo to the boot partition of the MicroSD card, in addition to the following files:

  - boot.json
  - opensbi.bin
  - the DTB file for your board (i.e. konfekt.dtb)

Those files can found be in the `images` directory of the repo for your board.

Finally, make sure the latest gateware is installed by following the instructions in the repo for your board.

### Optional: Building Kakao Linux

The latest Kakao images are provided in this repo, but if you want to build the system from source you can follow these steps:

```
$ git clone http://github.com/machdyne/kakao
$ git clone http://github.com/buildroot/buildroot
$ cd buildroot
# kakao may build with the latest buildroot, but it has been tested with:
$ git checkout 20d816651cc8b15f43bd4c95fbe8d8babe9e8dc9

# use the config for the minimal ramdisk rootfs:
$ make BR2_EXTERNAL=../kakao/buildroot/ kakao_defconfig

# or the config for sdcard rootfs:
$ make BR2_EXTERNAL=../kakao/buildroot/ kakao_sdroot_defconfig

# or the config for the supplemental chroot rootfs (experimental):
$ make BR2_EXTERNAL=../kakao/buildroot/ kakao_sup_defconfig

# or the config for QEMU:
$ make BR2_EXTERNAL=../kakao/buildroot/ kakao_qemu_defconfig

# and then:
$ make
```

This will produce the Linux kernel image and rootfs archive in the `output/images` directory.

### Optional: Mount rootfs from the MicroSD card instead of using a ramdisk.

This option is generally slower but it frees 8MB of RAM and allows you to install more applications on the rootfs.

This requires modifying the bootargs option and then recompiling the device tree source file which can be found in the GitHub repo for your board (i.e. images/linux/konfekt.dts):

```
bootargs = "console=liteuart earlycon=liteuart,0xf0001000 rootwait root=/dev/mmcblk0p2 fbcon=logo-pos:0"
```

Remove the following lines to free the memory used by the RAM disk:

```
linux,initrd-start = <0x41000000>;
linux,initrd-end   = <0x41800000>;
```

You can also remove the "root.cpio" entry from your boot.json file.

Compile the dts file to dtb:

```
$ dtc -O dtb -o konfekt.dtb konfekt.dts
```

And then copy the DTB file to the boot directory of the MicroSD card.

To extract the rootfs onto the MicroSD card, make sure the second partition is formatted as ext2 and then:

```
$ sudo mount /dev/sdX2 /mnt
$ cd /mnt
$ sudo tar -xvf /path/to/buildroot/output/images/rootfs.tar
$ eject /dev/sdX2
```

## Running Kakao on a VM

1. Follow [these instructions](https://risc-v-getting-started-guide.readthedocs.io/en/latest/linux-qemu.html) to build and install qemu-riscv32-softmmu.

2. Build Kakao Linux

See the "Building Kakao Linux" section above, and use the `kakao_qemu_defconfig` buildroot config.

3. Run Kakao with QEMU:

```
$ qemu-system-riscv32 -M virt -bios output/images/fw_jump.elf -kernel output/images/Image -append "rootwait root=/dev/vda ro" -drive file=output/images/rootfs.ext2,format=raw,id=hd0 -device virtio-blk-device,drive=hd0 -netdev user,id=net0 -device virtio-net-device,netdev=net0 -nographic -m 256m
```

To run in graphics mode, replace `-nographic` with `-vga std -L replace-with-your-path-to-qemu/qemu/pc-bios`.

## USB WiFi Guide

This has been tested with the TP-LINK TL-WN725N, for other devices you may need to build a different kernel module. The necessary packages are only supported in the sdroot configuration.

```
$ isnmod /lib/modules/6.1.0-rc2/extra/8188eu.ko
$ iw link set wlan0 up
$ wpa_passphrase "ssid" "password" > /etc/wpa_supplicant.conf
$ wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
$ udhcpc -i wlan0
```

# License

Kakao is a partial fork of [linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv) and this repo is released under the BSD 2-Clause License, with the following exception(s):

The Linux kernel is released under the GNU General Public License version 2 (GPL-2.0).

The tinyscheme buildroot package is from [buildroot-a13-olinuxino](https://github.com/m039/buildroot-a13-olinuxino) which uses the GPL-2.0 license. TinyScheme itself is licensed under a BSD-style license.

Individual buildroot packages are released under various licenses.
