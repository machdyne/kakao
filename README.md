# Kakao Linux

Kakao is a Linux distribution for Machdyne / Lone Dynamics FPGA computers. At the moment it is essentially a buildroot configuration with extra packages that makes certain assumptions about the hardware and MicroSD card partition layout.

The goal of Kakao is to provide a minimal practical environment with access to useful timeless applications.

This repo contains everything necessary to build Kakao from source, the steps described here can replace the buildroot steps from the individual board repos.

Kakao can be configured to either:

  1. Keep a small rootfs (<8MB) in RAM and optionally mount additional filesystems later.
  2. Mount rootfs from an ext2 partition on the MicroSD card.

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
$ git checkout 575d971820dedf7a0c6e217deb57ecd4db1218f5

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
