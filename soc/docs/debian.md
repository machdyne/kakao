# Kakao Linux (Debian, rv64)

Debian 13 (trixie) for riscv64 on the Kakao SOC with kakao64: Debian's
own packages, unmodified, from Debian's archive, on our kernel (Linux
6.6.18 with `buildroot/board/kakao_soc/linux64.config`) and OpenSBI 1.9
with the patch that does floating-point arithmetic
(`fw/opensbi`). It runs on the Sergei ML2; [kakao64.md](kakao64.md) is
the CPU and how it got here.

## The card

| | | |
|---|---|---|
| partition 1 | FAT32, 64 MB | `/sys/linux`: what kboot loads (below) |
| partition 2 | ext4, the rest | Debian, the kernel's root (`root=/dev/vda2`) |

In `/sys/linux`:

| file | from | |
|---|---|---|
| `boot.json` | `make -C boards BOARD=sergei_ml2 CPU64=1 card` | what to load where; the file named first is started |
| `fw_jump.bin` | OpenSBI (`boards/README.md`) | at 0x80000000 |
| `Image` | the kernel | at 0x80200000 |
| `kakao.dtb` | `make ... card` | the device tree, at 0x87f00000 |
| `kakao-busybox.dtb` | `make ... card` | the same, with the busybox as init |

kboot for kakao64 reads `boot64.json` in place of `boot.json` when
there is one, so the same card can also hold kakao32's system
(`boards/README.md`, "One card for both CPUs"); below, `boot.json`
stands for whichever of the two the card has.

## Two ways to boot

Both are on one card, and `boot.json` chooses by the device tree it
names (its third entry: `"kakao.dtb"` or `"kakao-busybox.dtb"`; the
kernel takes its arguments from the device tree).

| | busybox as init (`kakao-busybox.dtb`) | systemd (`kakao.dtb`) |
|---|---|---|
| from the kernel's last line to a prompt | seconds | minutes (the first one tried: more than four) |
| what runs | one shell script (`/opt/kakao/rcS`: mounts, DHCP, NTP) and a root shell on the serial console, the first terminal and the second | Debian as its packages expect it: udev, the journal, logind, D-Bus, timers, a login |
| a package's service (ssh, a web server, cron) | does not start: there is nothing to start it; run its program by hand | starts at boot, `systemctl` controls it |
| logins | none: the shells are root's, no password | root with a password, users |
| apt, dpkg, everything in /usr | the same | the same |
| good for | work at a prompt: compiling, apt, trying the machine | a system that is to serve something, or to be Debian in every respect |

The busybox way is `init=/opt/kakao/busybox -- init` in the kernel's
arguments: a static busybox and its few files in `/opt/kakao`, which
nothing of Debian's touches. So a card with systemd installed still
boots the fast way, and back.

To change over on the running machine:

```
mount /dev/vda1 /mnt
vi /mnt/sys/linux/boot.json        # "kakao.dtb" or "kakao-busybox.dtb"
umount /mnt; sync; reboot
```

### What systemd needed

On the first boot (Sergei ML2, 25 Nov) systemd reached its targets, and
there was no login on the serial console: it waits ninety seconds for a
device to appear, and udev had not started by then
(`Timed out waiting for device dev-ttyS0.device`, and it does not try
again). The device tree's kernel arguments now say

```
systemd.default_device_timeout_sec=600 systemd.default_timeout_start_sec=600 systemd.unit=multi-user.target
```

and `/opt/kakao/install-systemd` writes the same into
`/etc/systemd/system.conf.d`, turns off the timers that would only use
the CPU and the card (apt's daily ones, fstrim, e2scrub, the dpkg
backup), keeps the journal in memory, and enables a login on the second
terminal (`serial-getty@ttyS1`; the serial console, which is also the
first terminal, gets its own). These settings have not yet been through
a boot on the board.

`systemd-logind` failed once and started at the second try, and
`bpf-restrict-fs` says the kernel has no BPF LSM; neither stops
anything.

## Making a card

`tools/mkdebian.sh` makes the image, on a PC, as root. The boot files
are the four (five) above in one directory.

**From Debian's official root file system** (tried on the board).
Nothing comes from the network while it runs:

```
git clone --depth 1 -b dist-riscv64 https://github.com/debuerreotype/docker-debian-artifacts
tools/mkdebian.sh -t docker-debian-artifacts/trixie/oci/blobs/rootfs.tar.gz \
                  -B busybox -b <boot dir> card.img
```

`busybox` is a static busybox for riscv64: `/bin/busybox` of Debian's
`busybox-static` package for riscv64, or built (`make defconfig`, with
`CONFIG_STATIC=y`, `CROSS_COMPILE=riscv64-linux-gnu-`). The image boots
the busybox way and holds Debian's base system alone: apt, dpkg, bash,
coreutils. On the machine, with a cable:

```
/opt/kakao/install-systemd
```

installs systemd and what a small system wants beside it and sets it
up (its steps are in it). Then name `kakao.dtb` in `boot.json`.

**With mmdebstrap** (not tried: where this was written Debian's archive
could not be reached). All of Debian in one go, systemd installed and
set up, and Debian's own `busybox-static` for the fast way:

```
apt install mmdebstrap qemu-user-static binfmt-support debian-archive-keyring e2fsprogs dosfstools mtools
tools/mkdebian.sh -b <boot dir> card.img
```

**Writing it**, and knowing that all of it is on the card:

```
dd if=card.img of=/dev/sdX bs=4M conv=fsync status=progress
cmp -n $(stat -c %s card.img) card.img /dev/sdX && echo written
```

(A card pulled before `dd` has finished holds the image's first part
and, after that, what it held before. That has looked like a journal
Linux could not read.)

On QEMU, for a look before the card is written: the command is in
`tools/mkdebian.sh`.

## On the machine

- **The clock.** There is none that keeps time. With a cable the time
  comes from NTP (busybox's `ntpd` in `rcS`; `systemd-timesyncd`).
  Without, set it (`date -s "2026-11-25 10:00"`) before apt is asked
  for anything: it refuses an archive from the future.
- **The network.** `eth0`, by DHCP. Its Ethernet address is made from
  the SD card's number, so it is the card's, wherever the card is.
- **The terminals.** Four on the monitor (Super with a digit); the
  first is the serial console, the others are `ttyS1` to `ttyS3`. More
  are `screen`'s to give.
- **Floating point** is slow: the CPU has the registers, loads, stores
  and compares, and the firmware does the arithmetic, some thousands of
  cycles for each instruction.
- **Speed.** About 4.5 cycles an instruction at 48 MHz in a simulated
  boot: think of ten million instructions a second, and a megabyte a
  second from the card at best.

## Not done

- Debian's own kernel (ours is 6.6.18 with a small configuration, no
  modules, no initrd).
- systemd's boot time: what of it can be turned off, and what the
  machine can be made faster at.
- A swap, a second user, ssh's server: Debian's to install.
