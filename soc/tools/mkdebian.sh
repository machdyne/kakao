#!/bin/sh
# mkdebian.sh [-s <MB>] [-r <release>] [-p <password>] [-d <root dir>] [-n] -b <boot dir> <card.img>
#
# An SD card image for the Kakao SOC with kakao64 (docs/kakao64.md):
#
#   partition 1, FAT32, 64 MB   /sys/linux: what kboot loads (the files
#                               in <boot dir>: boot.json, kakao.dtb,
#                               fw_jump.bin, Image)
#   partition 2, ext4, the rest Debian for riscv64, as the kernel's root
#                               (root=/dev/vda2)
#
# Debian comes from the network with mmdebstrap, and its packages are
# configured by running their riscv64 programs here, so this wants, on a
# Debian or Ubuntu machine, as root:
#
#   apt install mmdebstrap qemu-user-static binfmt-support \
#               debian-archive-keyring e2fsprogs dosfstools mtools
#
#   -s   the image's size in MB (2048)
#   -r   the Debian release (trixie)
#   -p   root's password (kakao); there is no other user
#   -n   the root file system without a journal
#   -d   no Debian: this directory is the root file system (then nothing
#        comes from the network, and it need not be run as root if the
#        files' owners do not matter)
#
# The system is small: systemd, a login on the serial console (which is
# the first terminal) and on the second terminal, the network by DHCP on
# eth0 (ifupdown), apt, ssh's client. The machine has no clock that
# keeps time: set the date (date -s "2026-11-24 12:00") before apt is
# asked for anything over https.
# Write it to a card with dd, or try it first on QEMU:
#
#   qemu-system-riscv64 -M virt -m 512 -nographic -bios fw_jump.bin \
#       -kernel Image -append "console=ttyS0 root=/dev/vda2 rw rootwait" \
#       -drive file=card.img,format=raw,if=none,id=d \
#       -device virtio-blk-device,drive=d \
#       -netdev user,id=n -device virtio-net-device,netdev=n
#
# The Debian half was NOT TESTED where this was written: that machine
# could not reach Debian's archive. The image half (-d) was, with a
# busybox root, on QEMU and on the simulated SOC.

set -e
size=2048
release=trixie
pass=kakao
boot=
dir=
noj=
while getopts s:r:p:b:d:n o; do
	case $o in
	s) size=$OPTARG ;;
	r) release=$OPTARG ;;
	p) pass=$OPTARG ;;
	b) boot=$OPTARG ;;
	d) dir=$OPTARG ;;
	n) noj="-O ^has_journal" ;;
	*) sed -n '2,/^$/p' "$0"; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
img=$1
[ -n "$img" ] && [ -n "$boot" ] || { sed -n '2,/^$/p' "$0"; exit 2; }
[ -n "$dir" ] || [ "$(id -u)" = 0 ] || { echo "mkdebian.sh: run as root (the files in the image have owners)"; exit 1; }
for f in boot.json kakao.dtb fw_jump.bin Image; do
	[ -f "$boot/$f" ] || { echo "mkdebian.sh: no $boot/$f"; exit 1; }
done
for t in ${dir:+true} ${dir:-mmdebstrap} mke2fs mkfs.vfat mcopy; do
	command -v $t > /dev/null || { echo "mkdebian.sh: $t is not installed"; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/root

# ---- Debian ----
if [ -n "$dir" ]; then
	root=$dir
else
mmdebstrap --architectures=riscv64 --variant=minbase \
	--include=systemd-sysv,udev,dbus,kmod,iproute2,iputils-ping,netbase,ifupdown,dhcpcd-base,ca-certificates,openssh-client,less,vim-tiny,procps,util-linux,e2fsprogs,dosfstools,wget \
	--customize-hook='echo kakao64 > "$1/etc/hostname"' \
	--customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\tkakao64\n" > "$1/etc/hosts"' \
	--customize-hook='printf "/dev/vda2\t/\text4\terrors=remount-ro\t0 1\n/dev/vda1\t/boot/kakao\tvfat\tnoauto\t0 0\n" > "$1/etc/fstab"' \
	--customize-hook='mkdir -p "$1/boot/kakao"' \
	--customize-hook='printf "auto lo\niface lo inet loopback\n\nallow-hotplug eth0\niface eth0 inet dhcp\n" > "$1/etc/network/interfaces"' \
	--customize-hook='chroot "$1" systemctl enable serial-getty@ttyS1.service' \
	--customize-hook="echo root:$pass | chroot \"\$1\" chpasswd" \
	"$release" "$root"
# (a machine this slow: give units their time)
mkdir -p "$root/etc/systemd/system.conf.d"
printf '[Manager]\nDefaultTimeoutStartSec=600s\nDefaultTimeoutStopSec=120s\nDefaultDeviceTimeoutSec=600s\n' \
	> "$root/etc/systemd/system.conf.d/kakao.conf"
fi

# ---- the image: a partition table, FAT32 from 1 MB, ext4 from 65 MB ----
fat_mb=64
rm -f "$img"
truncate -s "${size}M" "$img"
# (the table written here: four numbers, and no tool to depend on)
le32() { printf "\\$(printf %03o $(($1 & 255)))\\$(printf %03o $(($1 >> 8 & 255)))\\$(printf %03o $(($1 >> 16 & 255)))\\$(printf %03o $(($1 >> 24 & 255)))"; }
part() { printf '\000\376\377\377'; printf "\\$(printf %03o $1)"; printf '\376\377\377'; le32 $2; le32 $3; }
{ part 12 2048 $((fat_mb * 2048)); part 131 $(((fat_mb + 1) * 2048)) $(((size - fat_mb - 1) * 2048)); } |
	dd of="$img" bs=1 seek=446 conv=notrunc status=none
printf '\125\252' | dd of="$img" bs=1 seek=510 conv=notrunc status=none

# (a sector a cluster, said outright: mkfs.vfat otherwise picks the
# cluster size by the whole image's size, and a FAT32 of 64 MB in 4 KB
# clusters has too few of them to be one -- kboot reads it as FAT16)
mkfs.vfat -F 32 -s 1 -S 512 -n KAKAO --offset 2048 "$img" $((fat_mb * 1024)) > /dev/null
mmd -i "$img@@1M" ::/sys ::/sys/linux
mcopy -i "$img@@1M" "$boot/boot.json" "$boot/kakao.dtb" "$boot/fw_jump.bin" "$boot/Image" ::/sys/linux/

ext_mb=$((size - fat_mb - 1))
mke2fs -q -t ext4 $noj -L kakao-root -d "$root" -E offset=$(((fat_mb + 1) * 1048576)) "$img" "${ext_mb}M"

if [ -n "$dir" ]; then echo "$img: ${size} MB, root file system from $dir"
else echo "$img: ${size} MB, Debian $release for riscv64; root's password is \"$pass\""; fi
