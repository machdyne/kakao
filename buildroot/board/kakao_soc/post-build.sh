#!/bin/sh
# For a root file system for the Kakao SOC (soc/): a login on each of
# its terminals. /sbin/kgettys (rootfs_overlay) starts one on every
# console after the first that the machine has; this puts it into
# inittab in place of the login on tty0, which the SOC does not have.
# The SD card is a virtio disk there (/dev/vda, not /dev/mmcblk0), so
# fstab is told; and the greeting names the machine.
#
#   post-build.sh <target directory>     (buildroot's BR2_ROOTFS_POST_BUILD_SCRIPT)
#   post-build.sh <rootfs.cpio> <out.cpio>   the same for a root file
#                                        system already made: the changed
#                                        files are added at its end

set -e
here=$(cd "$(dirname "$0")" && pwd)

fix() {	# <inittab>
	grep -q kgettys "$1" && return 0
	sed -i -e 's|^::respawn:/sbin/getty -L 115200 tty0.*|::once:/sbin/kgettys|' \
		-e 's| > /dev/tty0$||' "$1"
	grep -q kgettys "$1" || echo '::once:/sbin/kgettys' >> "$1"
}

fix_card() {	# <fstab> <motd>
	sed -i -e 's|^/dev/mmcblk0p|/dev/vda|' "$1"
	[ -f "$2" ] && sed -i -e 's|running on LiteX / VexRiscv-SMP with USB host support|running on the Kakao SOC (kakao32)|' "$2"
	return 0
}

if [ -d "$1" ]; then
	fix "$1/etc/inittab"
	fix_card "$1/etc/fstab" "$1/etc/motd"
	exit 0
fi

# an archive: take its inittab out, change it, and append
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/in" "$t/ov/etc" "$t/ov/sbin"
in=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
( cd "$t/in" && cpio -id --quiet etc/inittab etc/fstab etc/motd < "$in" )
cp "$t/in/etc/inittab" "$t/in/etc/fstab" "$t/ov/etc/"
[ -f "$t/in/etc/motd" ] && cp "$t/in/etc/motd" "$t/ov/etc/"
fix "$t/ov/etc/inittab"
fix_card "$t/ov/etc/fstab" "$t/ov/etc/motd"
cp "$here/rootfs_overlay/sbin/kgettys" "$t/ov/sbin/kgettys"
chmod 755 "$t/ov/sbin/kgettys"
( cd "$t/ov" && find . | cpio -o -H newc --quiet -R 0:0 ) > "$t/ov.cpio"
cat "$in" "$t/ov.cpio" > "$2"
