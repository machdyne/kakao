#!/bin/sh
# mkdebian.sh [-s <MB>] [-r <release>] [-p <password>] [-n]
#             [-t <rootfs.tar> -B <busybox>] [-d <root dir>] -b <boot dir> <card.img>
#
# An SD card image for the Kakao SOC with kakao64 (docs/debian.md):
#
#   partition 1, FAT32, 64 MB   /sys/linux: what kboot loads (the files
#                               in <boot dir>: boot.json, kakao.dtb,
#                               fw_jump.bin, Image, and
#                               kakao-busybox.dtb if it is there)
#   partition 2, ext4, the rest Debian for riscv64, as the kernel's root
#                               (root=/dev/vda2)
#
# Debian is made in one of three ways:
#
#   (neither -t nor -d)   all of it, from the network with mmdebstrap:
#        systemd, the network by DHCP on eth0 (ifupdown), apt, ssh's
#        client; and Debian's busybox-static as /opt/kakao/busybox for
#        the fast way to boot. Its packages are configured by running
#        their riscv64 programs here, so this wants, on a Debian or
#        Ubuntu machine, as root:
#          apt install mmdebstrap qemu-user-static binfmt-support \
#                      debian-archive-keyring e2fsprogs dosfstools mtools
#   -t <rootfs.tar[.gz|.xz]> -B <busybox>
#        Debian's base system alone, from the root file system of the
#        official "debian" image for riscv64 (the rootfs.tar.gz of
#        github.com/debuerreotype/docker-debian-artifacts, branch
#        dist-riscv64, trixie/oci/blobs), with <busybox>, a static
#        busybox for riscv64 (Debian's busybox-static has one, as
#        /bin/busybox; or built: make defconfig, CONFIG_STATIC=y), as
#        init. Nothing comes from the network. systemd is installed
#        later, on the machine, by /opt/kakao/install-systemd. As root.
#   -d <root dir>
#        this directory is the root file system, as it is.
#
#   -s   the image's size in MB (2048)
#   -r   the Debian release for mmdebstrap (trixie)
#   -p   root's password for mmdebstrap's system (kakao); there is no
#        other user
#   -n   the root file system without a journal
#
# Either Debian has /opt/kakao (tools/debian): the busybox, its
# inittab and what it runs. Which init a boot uses is the device tree's
# choice, and boot.json names the device tree: kakao.dtb for /sbin/init
# (systemd), kakao-busybox.dtb for the busybox. The image is made to
# boot the busybox way if -t, and systemd's otherwise.
#
# The machine has no clock that keeps time: under the busybox init the
# time comes from NTP when there is a cable, under systemd from
# systemd-timesyncd; else set the date (date -s "2026-11-25 12:00")
# before apt is asked for anything over https.
# Write the image to a card with dd (how is said at the end), or try it
# first on QEMU:
#
#   qemu-system-riscv64 -M virt -m 512 -nographic -bios fw_jump.bin \
#       -kernel Image -append "console=ttyS0 root=/dev/vda2 rw rootwait" \
#       -drive file=card.img,format=raw,if=none,id=d \
#       -device virtio-blk-device,drive=d \
#       -netdev user,id=n -device virtio-net-device,netdev=n
#   (the busybox way: add  init=/opt/kakao/busybox -- init  to -append)
#
# TESTED where this was written: -t and -d, on QEMU and on the simulated
# SOC; the -t image on the Sergei ML2, where systemd was then installed
# by hand. NOT TESTED: the mmdebstrap way, for that machine could not
# reach Debian's archive.

set -e
size=2048
release=trixie
pass=kakao
boot=
dir=
noj=
tar=
bb=
here=$(cd "$(dirname "$0")" && pwd)
while getopts s:r:p:b:d:t:B:n o; do
	case $o in
	s) size=$OPTARG ;;
	r) release=$OPTARG ;;
	p) pass=$OPTARG ;;
	b) boot=$OPTARG ;;
	d) dir=$OPTARG ;;
	t) tar=$OPTARG ;;
	B) bb=$OPTARG ;;
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
if [ -n "$tar" ]; then
	[ -f "$tar" ] && [ -f "$bb" ] || { echo "mkdebian.sh: -t <rootfs.tar> and -B <busybox>, both files"; exit 1; }
fi
for t in ${dir:+true} ${tar:+true} $([ -n "$dir$tar" ] || echo mmdebstrap) mke2fs mkfs.vfat mcopy; do
	command -v $t > /dev/null || { echo "mkdebian.sh: $t is not installed"; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/root

# ---- Debian ----
# /opt/kakao: the busybox and what it needs to be init
kakao_files() {
	mkdir -p "$root/opt/kakao" "$root/usr/local/sbin"
	cp "$1" "$root/opt/kakao/busybox"
	chmod 755 "$root/opt/kakao/busybox"
	for f in rcS udhcpc.sh install-systemd README; do cp "$here/debian/$f" "$root/opt/kakao/$f"; done
	chmod 755 "$root/opt/kakao/rcS" "$root/opt/kakao/udhcpc.sh" "$root/opt/kakao/install-systemd"
	cp "$here/debian/inittab" "$root/etc/inittab"
	# (the tools the base system lacks, where they are not there already)
	for a in reboot poweroff halt ip ping vi less ifconfig route udhcpc ntpd wget nc free top ps; do
		[ -e "$root/usr/bin/$a" ] || [ -e "$root/usr/sbin/$a" ] || ln -sf /opt/kakao/busybox "$root/usr/local/sbin/$a"
	done
}
# (a machine this slow: give systemd's units their time; the device
# tree's kernel arguments say the same)
slow() {
	mkdir -p "$root/etc/systemd/system.conf.d"
	printf '[Manager]\nDefaultTimeoutStartSec=600s\nDefaultTimeoutStopSec=120s\nDefaultDeviceTimeoutSec=600s\n' \
		> "$root/etc/systemd/system.conf.d/kakao.conf"
}
fast=
if [ -n "$dir" ]; then
	root=$dir
elif [ -n "$tar" ]; then
	mkdir -p "$root"
	tar -xf "$tar" -C "$root"
	kakao_files "$bb"
	echo kakao64 > "$root/etc/hostname"
	# (until systemd-sysv brings its own: either device tree boots it)
	ln -sf /opt/kakao/busybox "$root/sbin/init"
	fast=1
else
mmdebstrap --architectures=riscv64 --variant=minbase \
	--include=systemd-sysv,systemd-timesyncd,udev,dbus,kmod,iproute2,iputils-ping,netbase,ifupdown,dhcpcd-base,ca-certificates,openssh-client,less,vim-tiny,procps,util-linux,e2fsprogs,dosfstools,wget,busybox-static \
	--customize-hook='echo kakao64 > "$1/etc/hostname"' \
	--customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\tkakao64\n" > "$1/etc/hosts"' \
	--customize-hook='printf "/dev/vda2\t/\text4\terrors=remount-ro\t0 1\n/dev/vda1\t/boot/kakao\tvfat\tnoauto\t0 0\n" > "$1/etc/fstab"' \
	--customize-hook='mkdir -p "$1/boot/kakao"' \
	--customize-hook='printf "auto lo\niface lo inet loopback\n\nallow-hotplug eth0\niface eth0 inet dhcp\n" > "$1/etc/network/interfaces"' \
	--customize-hook='chroot "$1" systemctl enable serial-getty@ttyS1.service' \
	--customize-hook='chroot "$1" systemctl set-default multi-user.target' \
	--customize-hook="echo root:$pass | chroot \"\$1\" chpasswd" \
	"$release" "$root"
slow
kakao_files "$root/bin/busybox"
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
export MTOOLS_SKIP_CHECK=1
mmd -i "$img@@1M" ::/sys ::/sys/linux
mcopy -i "$img@@1M" "$boot/boot.json" "$boot/kakao.dtb" "$boot/fw_jump.bin" "$boot/Image" ::/sys/linux/
# the busybox way's device tree, and boot.json naming it where the
# image has no other init yet
if [ -f "$boot/kakao-busybox.dtb" ]; then
	mcopy -i "$img@@1M" "$boot/kakao-busybox.dtb" ::/sys/linux/
	if [ -n "$fast" ]; then
		sed 's/"kakao\.dtb"/"kakao-busybox.dtb"/' "$boot/boot.json" > "$tmp/boot.json"
		mcopy -o -i "$img@@1M" "$tmp/boot.json" ::/sys/linux/boot.json
	fi
fi

# The root file system is made in a file of its own and copied into its
# place: mke2fs writing at an offset into the image is not trusted with
# what lies before the offset (the partition table, the FAT).
ext_mb=$((size - fat_mb - 1))
ext="$img.ext4"
rm -f "$ext"
mke2fs -q -t ext4 $noj -L kakao-root -d "$root" "$ext" "${ext_mb}M"
dd if="$ext" of="$img" bs=1M seek=$((fat_mb + 1)) conv=notrunc,sparse status=none
rm -f "$ext"

# ...and looked at once more, as kboot will: the table's first entry,
# the FAT's boot sector, the four files
sig=$(od -A n -t x1 -j 510 -N 2 "$img" | tr -d ' ')
p1=$(od -A n -t u4 -j 454 -N 4 "$img" | tr -d ' ')
[ "$sig" = 55aa ] && [ "$p1" = 2048 ] ||
	{ echo "mkdebian.sh: the partition table did not come out right (ends $sig, partition 1 at $p1)"; exit 1; }
for f in boot.json kakao.dtb fw_jump.bin Image; do
	mdir -i "$img@@1M" "::/sys/linux/$f" > /dev/null 2>&1 ||
		{ echo "mkdebian.sh: /sys/linux/$f is not on the FAT partition"; exit 1; }
done

if [ -n "$dir" ]; then echo "$img: ${size} MB, root file system from $dir"
elif [ -n "$tar" ]; then echo "$img: ${size} MB, Debian's base system from $tar, busybox as init; /opt/kakao/README"
else echo "$img: ${size} MB, Debian $release for riscv64; root's password is \"$pass\""; fi
cat <<EOT
To write it to a card, and to know that all of it is there (a card
pulled before the last of it is written has the image's first part,
and after that whatever it held before):
  dd if=$img of=/dev/sdX bs=4M conv=fsync status=progress
  cmp -n \$(stat -c %s $img) $img /dev/sdX && echo written
EOT
