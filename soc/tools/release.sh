#!/bin/sh
# release.sh [-o <dir>] [-v <version>] [-s "<seeds>"] [-f] [-n] [-c <dir>] [<board> ...]
#
# The Kakao SOC's release files: for each board (all of them if none is
# named) the bitstream, placed with each of the seeds and the fastest
# that meets 48 MHz kept, and what belongs on the SD card beside it,
# as kakao-soc-<version>-<board>.zip; SHA256SUMS; and SUMMARY.md, which
# says what each board got and how fast it is. A board that does not
# fit or does not meet timing with any seed has no zip, and the script
# ends with an error after doing the others.
#
#   -o   where to put them (soc/boards/build/release)
#   -v   the version in the names (git describe)
#   -s   the seeds to try ("1 2 3 4 5 6 7 8")
#   -f   take the first seed that meets timing, and try no more
#   -n   build nothing: pack what soc/boards/build has from the last time
#   -c   a directory with the card's common files (fw_jump.bin, Image,
#        rootfs.cpio: boards/README.md says how they are made): they go
#        into kakao-soc-<version>-sd-common.zip
#
# Tools as for soc/boards/Makefile (YOSYS=, NEXTPNR=, ECPPACK= are
# passed on), and zip.

set -e
here=$(cd "$(dirname "$0")" && pwd)
boards_dir=$here/../boards
out=$boards_dir/build/release
version=$(git -C "$here" describe --tags --always --dirty 2>/dev/null || echo unknown)
seeds="1 2 3 4 5 6 7 8"
common=
first=
nobuild=

while getopts o:v:s:c:fn f; do
	case $f in
	o) out=$OPTARG;; v) version=$OPTARG;; s) seeds=$OPTARG;; c) common=$OPTARG;; f) first=1;; n) nobuild=1;;
	*) sed -n '2,20p' "$0"; exit 2;;
	esac
done
shift $((OPTIND - 1))
boards=${*:-$(make -s -C "$boards_dir" boards)}

mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/kakao-soc-*.zip "$out/SHA256SUMS" "$out/SUMMARY.md"
{
	echo "# Kakao SOC $version"
	echo
	echo "| board | as placed, for 48 MHz at speed grade 6 | seed | block RAM | consoles | zip |"
	echo "|---|---|---|---|---|---|"
} > "$out/SUMMARY.md"

failed=
for b in $boards; do
	echo "== $b =="
	B=$boards_dir/build/$b
	if [ -n "$nobuild" ] && [ -f "$out/$b.log" ] && grep -q "^seed .* it is" "$out/$b.log" ||
	   { [ -z "$nobuild" ] && make -C "$boards_dir" BOARD="$b" SEEDS="$seeds" FIRST="$first" seeds > "$out/$b.log" 2>&1; }; then
		line=$(grep "^seed .* it is" "$out/$b.log" | tail -1)
		seed=${line#seed }; seed=${seed%% *}
		mhz=$(grep "^seed $seed:" "$out/$b.log" | tail -1 | sed 's/^seed [0-9]*: \([0-9.]*\).*/\1/')
		bram=$(grep "DP16KD" "$B/pnr.s$seed.log" | head -1 | sed 's/.*: *\([0-9]*\)\/ *\([0-9]*\).*/\1 of \2/')
		terms=$(grep -c "ns16550" "$B/kakao.dts" || true)
		t=$(mktemp -d)
		mkdir -p "$t/sys/linux"
		cp "$B/kakao.bit" "$t/kakao-$b.bit"
		cp "$B/boot.json" "$B/kakao.dtb" "$t/sys/linux/"
		cat > "$t/README.txt" <<EOT
Kakao SOC $version for $b

kakao-$b.bit       the bitstream ($mhz MHz as placed, for 48 MHz at speed
                   grade 6; $bram block RAMs; $terms console(s))
sys/linux/         for the SD card's FAT partition, beside the common
                   files (kakao-soc-$version-sd-common.zip: fw_jump.bin,
                   Image, rootfs.cpio): boot.json and this board's
                   device tree

With these Linux has the SD card as /dev/vda and, on a board with
Ethernet, eth0. soc/boards/README.md in the sources has the rest.
EOT
		z=kakao-soc-$version-$b.zip
		( cd "$t" && zip -q -r "$out/$z" . )
		rm -rf "$t"
		echo "| $b | $mhz MHz | $seed | $bram | $terms | $z |" >> "$out/SUMMARY.md"
		echo "$b: $mhz MHz with seed $seed"
	else
		tail -3 "$out/$b.log"
		echo "| $b | **not built** (see $b.log) | | | | |" >> "$out/SUMMARY.md"
		failed="$failed $b"
	fi
done

if [ -n "$common" ]; then
	t=$(mktemp -d)
	mkdir -p "$t/sys/linux"
	cp "$common/fw_jump.bin" "$common/Image" "$common/rootfs.cpio" "$t/sys/linux/"
	cat > "$t/README.txt" <<EOT
Kakao SOC $version: the SD card's common files

sys/linux/fw_jump.bin   OpenSBI
sys/linux/Image         Linux
sys/linux/rootfs.cpio   Kakao's root file system

The same for every board. Beside them go boot.json and kakao.dtb from
the board's own zip.
EOT
	( cd "$t" && zip -q -r "$out/kakao-soc-$version-sd-common.zip" . )
	rm -rf "$t"
fi

( cd "$out" && sha256sum kakao-soc-*.zip > SHA256SUMS 2>/dev/null || true )
echo
cat "$out/SUMMARY.md"
if [ -n "$failed" ]; then echo; echo "not built:$failed"; exit 1; fi
