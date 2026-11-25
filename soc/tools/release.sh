#!/bin/sh
# release.sh [-o <dir>] [-v <version>] [-s "<seeds>"] [-f] [-n] -i <inputs> [<board> ...]
#
# A release of Kakao for the Kakao SOC (soc/boards: make release
# RELEASE="-i <inputs>"). For each board, all of them if none is named:
#
#   kakao-linux-buildroot-<version>-<board>.zip
#       Kakao Linux (Buildroot) on kakao32: the bitstream, and the SD
#       card's /sys/linux complete
#   kakao-linux-debian-<version>-<board>.zip          (boards with 512 MB
#       Kakao Linux (Debian) on kakao64: the bitstream  and a 45F)
#       and the card's /sys/linux
#   kakao-linux-debian-<version>-<board>.img.xz
#       ...and its whole card, to be written with dd (tools/mkdebian.sh;
#       only when this runs as root, which the files' owners need)
#
# and SHA256SUMS, and SUMMARY.md: what each board got, how fast it
# placed, and whether it has been run on a board. Each bitstream is
# placed with each of the seeds and the fastest that meets 48 MHz kept.
# A build that does not fit or does not meet timing with any seed has
# no file, and the script ends with an error after doing the others.
#
#   -i   the files that are not built here (boards/README.md says how
#        each is made):
#          <inputs>/rv32/fw_jump.bin    OpenSBI for RV32
#          <inputs>/rv32/Image          the kernel
#          <inputs>/rv32/rootfs.cpio    Kakao's root file system
#          <inputs>/rv64/fw_jump.bin    OpenSBI for RV64, with fw/opensbi's patch
#          <inputs>/rv64/Image          the kernel
#          <inputs>/rv64/rootfs.tar.gz  Debian's official root file system
#          <inputs>/rv64/busybox        a static busybox for riscv64
#        Without rv32 or without rv64, that system is left out.
#   -o   where to put the release (soc/boards/build/release)
#   -v   the version in the names (the year and month: 2026.11)
#   -s   the seeds to try ("2 1 3 4 5 6 7 8")
#   -f   take the first seed that meets timing, and try no more
#   -n   place nothing: pack what soc/boards/build has from the last time
#   -S   the Debian card's size in MB (1900)
#
# Tools as for soc/boards/Makefile (YOSYS=, NEXTPNR=, ECPPACK= are
# passed on), zip and xz, and for the Debian card mkdebian.sh's.

set -e
here=$(cd "$(dirname "$0")" && pwd)
boards_dir=$here/../boards
out=$boards_dir/build/release
version=$(date +%Y.%m)
seeds="2 1 3 4 5 6 7 8"
in=
first=
nobuild=
cardmb=1900

while getopts o:v:s:i:S:fn f; do
	case $f in
	o) out=$OPTARG;; v) version=$OPTARG;; s) seeds=$OPTARG;; i) in=$OPTARG;; S) cardmb=$OPTARG;;
	f) first=1;; n) nobuild=1;;
	*) sed -n '2,/^$/p' "$0"; exit 2;;
	esac
done
shift $((OPTIND - 1))
[ -n "$in" ] && [ -d "$in" ] || { sed -n '2,/^$/p' "$0"; exit 2; }
in=$(cd "$in" && pwd)
all=$(make -s -C "$boards_dir" boards)
all64=$(make -s -C "$boards_dir" boards64)
tested=$(make -s -C "$boards_dir" tested)
boards=${*:-$all}

has() { for f in $2; do [ -f "$in/$1/$f" ] || return 1; done; }
do32=; do64=
has rv32 "fw_jump.bin Image rootfs.cpio" && do32=1 || echo "release.sh: no $in/rv32 with fw_jump.bin, Image, rootfs.cpio: no Kakao Linux (Buildroot)"
has rv64 "fw_jump.bin Image rootfs.tar.gz busybox" && do64=1 || echo "release.sh: no $in/rv64 with fw_jump.bin, Image, rootfs.tar.gz, busybox: no Kakao Linux (Debian)"
[ -n "$do32$do64" ] || exit 1
card=
if [ -n "$do64" ]; then
	if [ "$(id -u)" = 0 ]; then card=1
	else echo "release.sh: not root: the Debian zips are made, the card images (.img.xz) are not"; fi
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/kakao-linux-*.zip "$out"/kakao-linux-*.img.xz "$out/SHA256SUMS" "$out/SUMMARY.md"
{
	echo "# Kakao $version for the Kakao SOC"
	echo
	echo "Bitstreams are placed for 48 MHz at speed grade 6. \"Run on a board\": whether this board has been; the others are built and meet timing, and that is all that is known of them."
	echo
	echo "| board | system | CPU | as placed | seed | block RAM | terminals | run on a board | files |"
	echo "|---|---|---|---|---|---|---|---|---|"
} > "$out/SUMMARY.md"

failed=
# place <board> <suffix of its build directory> <make's arguments>: the
# bitstream (unless -n), and seed, mhz, bram, terms for what follows
place() {
	B=$boards_dir/build/$1$2
	log=$out/$1$2.log
	if [ -n "$nobuild" ]; then
		[ -f "$log" ] && grep -q "^seed .* it is" "$log" && [ -f "$B/kakao.bit" ] || return 1
		# (the card's files are quick, and may be newer than the bitstream)
		make -C "$boards_dir" BOARD="$1" $3 card > /dev/null 2>&1 || return 1
	else
		make -C "$boards_dir" BOARD="$1" $3 SEEDS="$seeds" FIRST="$first" seeds > "$log" 2>&1 || return 1
	fi
	line=$(grep "^seed .* it is" "$log" | tail -1)
	seed=${line#seed }; seed=${seed%% *}
	mhz=$(grep "^seed $seed:" "$log" | tail -1 | sed 's/^seed [0-9]*: \([0-9.]*\).*/\1/')
	bram=$(grep "DP16KD" "$B/pnr.s$seed.log" | head -1 | sed 's/.*: *\([0-9]*\)\/ *\([0-9]*\).*/\1 of \2/')
	terms=$(grep -c "ns16550" "$B/kakao.dts" || true)
}
ran() { case " $tested " in *" $1 "*) echo yes;; *) echo no;; esac; }
ranline() {
	case " $tested " in
	*" $1 "*) echo "This board has been run with it.";;
	*) echo "NOT YET RUN ON THIS BOARD: it is built and meets timing, no more is known.";;
	esac
}

for b in $boards; do
	# ---- Kakao Linux (Buildroot), kakao32 ----
	if [ -n "$do32" ]; then
		echo "== $b, kakao32 =="
		if place "$b" "" ""; then
			t=$(mktemp -d)
			mkdir -p "$t/sys/linux"
			cp "$B/kakao.bit" "$t/kakao32-$b.bit"
			cp "$B/boot.json" "$B/kakao.dtb" "$in/rv32/fw_jump.bin" "$in/rv32/Image" "$in/rv32/rootfs.cpio" "$t/sys/linux/"
			cat > "$t/README.txt" <<EOT
Kakao Linux (Buildroot) $version for $b, on the Kakao SOC with kakao32

kakao32-$b.bit
    The bitstream ($mhz MHz as placed, for 48 MHz at speed grade 6;
    $terms terminal(s)).
sys/
    Copy this directory to a FAT-formatted SD card (or the FAT
    partition of one). /sys/linux then holds OpenSBI (fw_jump.bin), the
    kernel (Image), the root file system (rootfs.cpio), this board's
    device tree (kakao.dtb) and boot.json, which says where each is
    loaded.

$(ranline "$b")

The root file system runs from memory. Linux has the SD card as
/dev/vda and, on a board with Ethernet, eth0. Log in as root.
https://github.com/machdyne/kakao : soc/README.md
EOT
			z=kakao-linux-buildroot-$version-$b.zip
			( cd "$t" && zip -q -r "$out/$z" . )
			rm -rf "$t"
			echo "| $b | Kakao Linux (Buildroot) | kakao32 | $mhz MHz | $seed | $bram | $terms | $(ran "$b") | $z |" >> "$out/SUMMARY.md"
			echo "$b, kakao32: $mhz MHz with seed $seed"
		else
			tail -3 "$out/$b.log" 2> /dev/null || true
			echo "| $b | Kakao Linux (Buildroot) | kakao32 | **not built** (see $b.log) | | | | | |" >> "$out/SUMMARY.md"
			failed="$failed $b"
		fi
	fi
	# ---- Kakao Linux (Debian), kakao64 ----
	case " $all64 " in *" $b "*) ;; *) continue;; esac
	[ -n "$do64" ] || continue
	echo "== $b, kakao64 =="
	if place "$b" "-64" "CPU64=1"; then
		t=$(mktemp -d)
		mkdir -p "$t/sys/linux"
		cp "$B/kakao.bit" "$t/kakao64-$b.bit"
		cp "$B/kakao.dtb" "$B/kakao-busybox.dtb" "$in/rv64/fw_jump.bin" "$in/rv64/Image" "$t/sys/linux/"
		# (the card boots the busybox way as it comes; both lists are there)
		cp "$B/boot.json" "$t/sys/linux/boot-systemd.json"
		sed 's/"kakao\.dtb"/"kakao-busybox.dtb"/' "$B/boot.json" > "$t/sys/linux/boot-busybox.json"
		cp "$t/sys/linux/boot-busybox.json" "$t/sys/linux/boot.json"
		img=kakao-linux-debian-$version-$b.img
		cat > "$t/README.txt" <<EOT
Kakao Linux (Debian) $version for $b, on the Kakao SOC with kakao64

kakao64-$b.bit
    The bitstream ($mhz MHz as placed, for 48 MHz at speed grade 6;
    $terms terminal(s)).
sys/
    What the card's FAT partition holds in /sys/linux, for a card that
    is made by hand or brought up to date. The whole card is
    $img.xz:
      xz -dk $img.xz
      dd if=$img of=/dev/sdX bs=4M conv=fsync status=progress

$(ranline "$b")

The card boots Debian 13 with a busybox as init: a root shell on the
serial console and the first two terminals, seconds after the kernel.
/opt/kakao/install-systemd installs Debian's own init; boot.json then
chooses (boot-systemd.json or boot-busybox.json copied over it).
https://github.com/machdyne/kakao : soc/docs/debian.md
EOT
		z=kakao-linux-debian-$version-$b.zip
		files=$z
		if [ -n "$card" ]; then
			c=$(mktemp -d)
			cp "$t"/sys/linux/* "$c/"
			if sh "$here/mkdebian.sh" -s "$cardmb" -t "$in/rv64/rootfs.tar.gz" -B "$in/rv64/busybox" -b "$c" "$out/$img" > "$out/$b-64.card.log" 2>&1; then
				# (mkdebian.sh takes the lists by the names it knows; the two spare ones go in as well)
				MTOOLS_SKIP_CHECK=1 mcopy -i "$out/$img@@1M" "$c/boot-systemd.json" "$c/boot-busybox.json" ::/sys/linux/
				xz -T0 -f "$out/$img"
				files="$z, $img.xz"
			else
				tail -3 "$out/$b-64.card.log"
				failed="$failed $b-card"
			fi
			rm -rf "$c"
		fi
		( cd "$t" && zip -q -r "$out/$z" . )
		rm -rf "$t"
		echo "| $b | Kakao Linux (Debian) | kakao64 | $mhz MHz | $seed | $bram | $terms | $(ran "$b") | $files |" >> "$out/SUMMARY.md"
		echo "$b, kakao64: $mhz MHz with seed $seed"
	else
		tail -3 "$out/$b-64.log" 2> /dev/null || true
		echo "| $b | Kakao Linux (Debian) | kakao64 | **not built** (see $b-64.log) | | | | | |" >> "$out/SUMMARY.md"
		failed="$failed $b-64"
	fi
done

( cd "$out" && sha256sum kakao-linux-* > SHA256SUMS 2> /dev/null || true )
echo
cat "$out/SUMMARY.md"
if [ -n "$failed" ]; then echo; echo "not built:$failed"; exit 1; fi
