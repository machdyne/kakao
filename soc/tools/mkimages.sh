#!/bin/sh
# mkimages.sh [-w <work dir>] [-o <out dir>] [-j <jobs>] [rv32] [rv64]
#
# Builds what a card for the Kakao SOC holds beside the board's own
# files, from source, as images/soc in this repository has it prebuilt
# (tools/release.sh takes it from there):
#
#   rv32/fw_jump.bin   OpenSBI, generic platform, for RV32
#   rv32/Image         Linux 6.6.18 with buildroot/board/kakao_soc/linux.config
#   rv32/rootfs.cpio   images/rootfs.cpio (Kakao's root file system, built
#                      with buildroot as the README says) made the SOC's
#                      by buildroot/board/kakao_soc/post-build.sh
#   rv64/fw_jump.bin   OpenSBI for RV64 with soc/fw/opensbi's patch
#   rv64/Image         Linux 6.6.18 with buildroot/board/kakao_soc/linux64.config
#   rv64/busybox       busybox 1.36.1, static, for Debian's fast way to boot
#
#   -w   where the sources are fetched to and built (soc/boards/build/src;
#        some 4 GB, and it is kept, so a second run is quick)
#   -o   where the results go (images/soc)
#   -j   make's jobs (the number of processors)
#
# Needs git, a RISC-V Linux gcc with its C library (Debian and Ubuntu:
# gcc-riscv64-linux-gnu libc6-dev-riscv64-cross) and what a kernel build
# needs (make flex bison bc libssl-dev libelf-dev). The sources come
# from GitHub: riscv-software-src/opensbi, gregkh/linux, mirror/busybox.

set -e
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
work=$here/../boards/build/src
out=$top/images/soc
jobs=$(nproc 2> /dev/null || echo 2)
while getopts w:o:j: f; do
	case $f in
	w) work=$OPTARG;; o) out=$OPTARG;; j) jobs=$OPTARG;;
	*) sed -n '2,/^$/p' "$0"; exit 2;;
	esac
done
shift $((OPTIND - 1))
what=${*:-rv32 rv64}
mkdir -p "$work" "$out/rv32" "$out/rv64"
work=$(cd "$work" && pwd); out=$(cd "$out" && pwd)
X=riscv64-linux-gnu-
command -v ${X}gcc > /dev/null || { echo "mkimages.sh: no ${X}gcc"; exit 1; }

OPENSBI=61f1973bd50338b36c52dc34006f76d464ca4f34	# OpenSBI 1.9
LINUX=v6.6.18
BUSYBOX=1_36_1

# fetch <dir> <url> <tag or commit>: that commit alone, once
fetch() {
	[ -d "$work/$1/.git" ] && return 0
	echo "== fetching $1 ($3)"
	git init -q "$work/$1"
	git -C "$work/$1" fetch -q --depth 1 "$2" "$3"
	git -C "$work/$1" checkout -q FETCH_HEAD
}

sbi() {	# <xlen> <build dir> <make's arguments...>
	x=$1; o=$work/$2; shift 2
	echo "== OpenSBI for RV$x"
	make -s -C "$work/opensbi" O="$o" PLATFORM=generic CROSS_COMPILE=$X FW_PAYLOAD=n -j"$jobs" "$@"
	cp "$o/platform/generic/firmware/fw_jump.bin" "$out/rv$x/fw_jump.bin"
}

kernel() {	# <xlen> <config>
	echo "== Linux $LINUX for RV$1"
	o=$work/linux-rv$1
	mkdir -p "$o"
	cp "$top/buildroot/board/kakao_soc/$2" "$o/.config"
	make -s -C "$work/linux" ARCH=riscv CROSS_COMPILE=$X O="$o" olddefconfig
	make -s -C "$work/linux" ARCH=riscv CROSS_COMPILE=$X O="$o" -j"$jobs" Image
	cp "$o/arch/riscv/boot/Image" "$out/rv$1/Image"
}

fetch opensbi https://github.com/riscv-software-src/opensbi $OPENSBI
fetch linux https://github.com/gregkh/linux $LINUX

for w in $what; do
	case $w in
	rv32)
		sbi 32 opensbi-rv32 PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
			FW_TEXT_START=0x81e00000 FW_JUMP_ADDR=0x80000000 FW_JUMP_FDT_ADDR=0x81f00000
		kernel 32 linux.config
		echo "== the root file system"
		sh "$top/buildroot/board/kakao_soc/post-build.sh" "$top/images/rootfs.cpio" "$out/rv32/rootfs.cpio"
		;;
	rv64)
		# (the patch on a copy: the other build is of OpenSBI as it is)
		if [ ! -d "$work/opensbi-fp" ]; then
			cp -r "$work/opensbi" "$work/opensbi-fp"
			git -C "$work/opensbi-fp" apply "$top/soc/fw/opensbi/0001-emulate-F-and-D-arithmetic.patch"
		fi
		echo "== OpenSBI for RV64, with the floating-point patch"
		make -s -C "$work/opensbi-fp" O="$work/opensbi-rv64" PLATFORM=generic CROSS_COMPILE=$X FW_PAYLOAD=n -j"$jobs" \
			FW_TEXT_START=0x80000000 FW_JUMP_ADDR=0x80200000 FW_JUMP_FDT_ADDR=0x87f00000
		cp "$work/opensbi-rv64/platform/generic/firmware/fw_jump.bin" "$out/rv64/fw_jump.bin"
		kernel 64 linux64.config
		fetch busybox https://github.com/mirror/busybox $BUSYBOX
		echo "== busybox"
		o=$work/busybox-rv64
		mkdir -p "$o"
		make -s -C "$work/busybox" O="$o" ARCH=riscv CROSS_COMPILE=$X defconfig > /dev/null
		# (static; and without tc, which does not build against newer kernel headers)
		sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
			-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' -e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' "$o/.config"
		make -s -C "$work/busybox" O="$o" ARCH=riscv CROSS_COMPILE=$X -j"$jobs" busybox > /dev/null
		cp "$o/busybox" "$out/rv64/busybox"
		;;
	*) echo "mkimages.sh: rv32 or rv64, not $w"; exit 2;;
	esac
done
ls -l "$out"/rv32 "$out"/rv64
