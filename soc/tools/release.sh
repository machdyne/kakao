#!/bin/sh
# release.sh [-o <dir>] [-t <tag>] [-s "<seeds>"] [-f] [-n] [-i <inputs>] [-D] [-S <MB>] [<board> ...]
#
# A release of Kakao for the Kakao SOC (soc/boards: make release; how
# to publish one: soc/docs/releases.md). For each board, all of them if
# none is named, with names that stay the same from one release to the
# next (the tag is the version):
#
#   kakao-linux-<board>.bit
#       Kakao Linux (Buildroot) on kakao32: the bitstream
#   kakao-linux-<board>-card.zip
#       ...and the card's files for it: sys/linux/ (OpenSBI, the kernel,
#       the root file system in memory, this board's device tree,
#       boot.json) and docs/kakao/
#   kakao-plan9-<board>.bit                     (boards with 512 MB
#       Kakao Plan 9 on kakao64, built INPUT=1 FB=1  and a 45F)
#       (rio on the monitor, with the USB keyboard and mouse)
#   kakao-plan9-<board>-card.zip
#       ...and its card's files: sys/plan9/ (the kernel, OpenSBI for
#       RV64, the device tree) and sys/linux/boot64.json, which kakao64's
#       kboot reads before boot.json, naming them. So one card holds
#       both: kakao32 boots Linux, kakao64 Plan 9.
#
# and, with -D, Kakao Linux (Debian) on kakao64 as before:
#   kakao-debian-<board>.zip                    the bitstream and sys/linux
#   kakao-debian-<board>.img.xz                 the whole card (as root only)
#
# and SHA256SUMS, MANIFEST.json, THIRD-PARTY.txt and SUMMARY.md (what
# each board got, how fast it placed, and whether it has been run on a
# board). Each bitstream is placed with each of the seeds and the fastest
# that meets 48 MHz kept. A build that does not fit or does not meet
# timing with any seed has no file, and the script ends with an error
# after doing the others.
#
#   -t   the tag, the version (otherwise git describe)
#   -i   where the files that are not built here are, if not in
#        images/soc of this repository, which has them prebuilt
#        (tools/mkimages.sh builds them from source):
#          rv32/fw_jump.bin    OpenSBI for RV32
#          rv32/Image          the kernel
#          rv64/fw_jump.bin    OpenSBI for RV64, with fw/opensbi's patch
#          rv64/Image          the kernel (Debian)
#          rv64/busybox        a static busybox for riscv64 (Debian)
#        and, if they are there, used in place of what is otherwise
#        taken:
#          rv32/rootfs.cpio    Kakao's root file system: otherwise
#                              images/rootfs.cpio, changed for the SOC by
#                              buildroot/board/kakao_soc/post-build.sh
#          rv64/rootfs.tar.gz  Debian's root file system: otherwise
#                              Debian's official one for riscv64
#          plan9/9kkcpu.bin    the Plan 9 kernel: otherwise built in
#                              plan9/ (make -C plan9)
#   -o   where to put the release (soc/boards/build/release)
#   -s   the seeds to try ("2 1 3 4 5 6 7 8")
#   -f   take the first seed that meets timing, and try no more
#   -n   place nothing: pack what soc/boards/build has from the last time
#   -D   Debian too
#   -S   the Debian card's size in MB (1900)
#
# Tools as for soc/boards/Makefile (YOSYS=, NEXTPNR=, ECPPACK= are
# passed on), zip, python3; plan9/'s for its kernel (docs/build.md
# there); and for Debian xz and mkdebian.sh's.

set -e
here=$(cd "$(dirname "$0")" && pwd)
boards_dir=$here/../boards
top=$(cd "$here/../.." && pwd)
out=$boards_dir/build/release
tag=$(cd "$top" && git describe --tags --always --dirty 2>/dev/null || echo untagged)
seeds="2 1 3 4 5 6 7 8"
in=$top/images/soc
first=
nobuild=
debian=
cardmb=1900

while getopts o:t:v:s:i:S:fnD f; do
	case $f in
	o) out=$OPTARG;; t|v) tag=$OPTARG;; s) seeds=$OPTARG;; i) in=$OPTARG;; S) cardmb=$OPTARG;;
	f) first=1;; n) nobuild=1;; D) debian=1;;
	*) sed -n '2,/^$/p' "$0"; exit 2;;
	esac
done
shift $((OPTIND - 1))
[ -d "$in" ] || { echo "release.sh: no $in"; exit 2; }
in=$(cd "$in" && pwd)
# (Klinge has no display: not one of Machdyne's computers for a release)
all=$(make -s -C "$boards_dir" boards | tr ' ' '\n' | grep -v '^klinge$' | tr '\n' ' ')
all64=$(make -s -C "$boards_dir" boards64)
tested=$(make -s -C "$boards_dir" tested)
boards=${*:-$all}

has() { for f in $2; do [ -f "$in/$1/$f" ] || return 1; done; }
do32=; do64=; dodeb=
has rv32 "fw_jump.bin Image" && do32=1 || echo "release.sh: no $in/rv32 with fw_jump.bin, Image: no Kakao Linux"
has rv64 "fw_jump.bin" && do64=1 || echo "release.sh: no $in/rv64/fw_jump.bin: no Kakao Plan 9"
if [ -n "$debian" ]; then
	has rv64 "fw_jump.bin Image busybox" && dodeb=1 || echo "release.sh: no $in/rv64 with fw_jump.bin, Image, busybox: no Debian"
fi
[ -n "$do32$do64" ] || exit 1
card=
if [ -n "$dodeb" ]; then
	if [ "$(id -u)" = 0 ]; then card=1
	else echo "release.sh: not root: the Debian zips are made, the card images (.img.xz) are not"; fi
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)

# the root file system, and the Plan 9 kernel
cpio=$in/rv32/rootfs.cpio
if [ -n "$do32" ] && [ ! -f "$cpio" ]; then
	cpio=$boards_dir/build/rootfs.cpio
	mkdir -p "$boards_dir/build"
	sh "$top/buildroot/board/kakao_soc/post-build.sh" "$top/images/rootfs.cpio" "$cpio"
fi
p9k=$in/plan9/9kkcpu.bin
want64=
for b in $boards; do case " $all64 " in *" $b "*) want64=1;; esac; done
[ -n "$want64" ] || do64=
if [ -n "$do64" ] && [ ! -f "$p9k" ]; then
	p9k=$top/plan9/build/9kkcpu.bin
	if [ ! -f "$p9k" ]; then
		echo "== the Plan 9 kernel (make -C plan9: it fetches its sources the first time)"
		make -C "$top/plan9" > "$out/plan9-kernel.log" 2>&1 ||
			{ tail -5 "$out/plan9-kernel.log"; echo "release.sh: the Plan 9 kernel did not build: no Kakao Plan 9"; do64=; }
	fi
fi
deb=$in/rv64/rootfs.tar.gz
if [ -n "$card" ] && [ ! -f "$deb" ]; then
	deb=$boards_dir/build/debian/trixie/oci/blobs/rootfs.tar.gz
	if [ ! -f "$deb" ]; then
		echo "== fetching Debian's root file system"
		rm -rf "$boards_dir/build/debian"
		git clone -q --depth 1 -b dist-riscv64 https://github.com/debuerreotype/docker-debian-artifacts "$boards_dir/build/debian" ||
			{ echo "release.sh: could not fetch it: no card images (or name one with -i: rv64/rootfs.tar.gz)"; card=; }
	fi
fi

rm -f "$out"/kakao-*.zip "$out"/kakao-*.bit "$out"/kakao-*.img.xz "$out/SHA256SUMS" "$out/SUMMARY.md" "$out/MANIFEST.lines"
{
	echo "# Kakao $tag for the Kakao SOC"
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
# manifest <system> <board> <file>: a line for MANIFEST.json
manifest() {
	echo "$1 $2 $3 $seed $mhz $(ran "$2")" >> "$out/MANIFEST.lines"
}

for b in $boards; do
	# ---- Kakao Linux (Buildroot), kakao32 ----
	if [ -n "$do32" ]; then
		echo "== $b, kakao32: Kakao Linux =="
		if place "$b" "" ""; then
			cp "$B/kakao.bit" "$out/kakao-linux-$b.bit"
			t=$(mktemp -d)
			mkdir -p "$t/sys/linux" "$t/docs/kakao"
			cp "$B/boot.json" "$B/kakao.dtb" "$in/rv32/fw_jump.bin" "$in/rv32/Image" "$t/sys/linux/"
			cp "$cpio" "$t/sys/linux/rootfs.cpio"
			cat > "$t/docs/kakao/README.txt" <<EOT
Kakao Linux (Buildroot) $tag for $b, on the Kakao SOC with kakao32

The bitstream is kakao-linux-$b.bit in the release ($mhz MHz as placed,
for 48 MHz at speed grade 6; $terms terminal(s)).

/sys/linux holds OpenSBI (fw_jump.bin), the kernel (Image), the root
file system (rootfs.cpio), this board's device tree (kakao.dtb) and
boot.json, which says where each is loaded. kboot, in the bitstream,
reads it from the card's first FAT partition.

$(ranline "$b")

The root file system runs from memory: what is written is gone at the
next start. Linux has the SD card as /dev/vda and, on a board with
Ethernet, eth0. Log in as root.
https://github.com/machdyne/kakao : soc/README.md
EOT
			( cd "$t" && zip -q -r -X "$out/kakao-linux-$b-card.zip" sys docs )
			rm -rf "$t"
			echo "| $b | Kakao Linux (Buildroot) | kakao32 | $mhz MHz | $seed | $bram | $terms | $(ran "$b") | kakao-linux-$b.bit, kakao-linux-$b-card.zip |" >> "$out/SUMMARY.md"
			manifest linux "$b" "kakao-linux-$b.bit"
			echo "$b, kakao32: $mhz MHz with seed $seed"
		else
			tail -3 "$out/$b.log" 2> /dev/null || true
			echo "| $b | Kakao Linux (Buildroot) | kakao32 | **not built** (see $b.log) | | | | | |" >> "$out/SUMMARY.md"
			failed="$failed $b"
		fi
	fi
	case " $all64 " in *" $b "*) ;; *) continue;; esac
	# ---- Kakao Plan 9, kakao64 with the window system's options ----
	if [ -n "$do64" ]; then
		echo "== $b, kakao64: Kakao Plan 9 =="
		if place "$b" "-p9" "CPU64=1 INPUT=1 FB=1 SUF=-p9"; then
			cp "$B/kakao.bit" "$out/kakao-plan9-$b.bit"
			t=$(mktemp -d)
			mkdir -p "$t/sys/plan9" "$t/sys/linux" "$t/docs/kakao-plan9"
			cp "$p9k" "$t/sys/plan9/9kkcpu.bin"
			cp "$in/rv64/fw_jump.bin" "$t/sys/plan9/fw_jump.bin"
			cp "$B/kakao.dtb" "$t/sys/plan9/kakao.dtb"
			# kakao64's kboot reads /sys/linux/boot64.json before boot.json:
			# so the card's kakao32 Linux stays as it is
			sba=$(sed -n 's/.*"fw_jump.bin": "\(0x[0-9a-fA-F]*\)".*/\1/p' "$B/boot.json")
			dta=$(sed -n 's/.*"kakao.dtb": "\(0x[0-9a-fA-F]*\)".*/\1/p' "$B/boot.json")
			printf '{\n\t"/sys/plan9/fw_jump.bin": "%s",\n\t"/sys/plan9/9kkcpu.bin": "0x80200000",\n\t"/sys/plan9/kakao.dtb": "%s"\n}\n' \
				"${sba:-0x80000000}" "${dta:-0x87f00000}" > "$t/sys/linux/boot64.json"
			cat > "$t/docs/kakao-plan9/README.txt" <<EOT
Kakao Plan 9 $tag for $b, on the Kakao SOC with kakao64

The bitstream is kakao-plan9-$b.bit in the release ($mhz MHz as placed,
for 48 MHz at speed grade 6), built with the framebuffer and the USB
keyboard and mouse as the host's devices (INPUT=1 FB=1): rio runs on the
monitor (kkrio at the shell).

/sys/plan9 holds the kernel (9kkcpu.bin, with its root file system in
it), OpenSBI for RV64 and this board's device tree. /sys/linux/boot64.json
names them: kakao64's kboot reads it before boot.json, so a card with
Kakao Linux (kakao32) on it keeps that too.

$(ranline "$b")

https://github.com/machdyne/kakao : plan9/README.md, plan9/card/README.md
EOT
			( cd "$t" && zip -q -r -X "$out/kakao-plan9-$b-card.zip" sys docs )
			rm -rf "$t"
			echo "| $b | Kakao Plan 9 | kakao64 | $mhz MHz | $seed | $bram | $terms | $(ran "$b") | kakao-plan9-$b.bit, kakao-plan9-$b-card.zip |" >> "$out/SUMMARY.md"
			manifest plan9 "$b" "kakao-plan9-$b.bit"
			echo "$b, kakao64 (Plan 9): $mhz MHz with seed $seed"
		else
			tail -3 "$out/$b-p9.log" 2> /dev/null || true
			echo "| $b | Kakao Plan 9 | kakao64 | **not built** (see $b-p9.log) | | | | | |" >> "$out/SUMMARY.md"
			failed="$failed $b-plan9"
		fi
	fi
	# ---- Kakao Linux (Debian), kakao64: only with -D ----
	[ -n "$dodeb" ] || continue
	echo "== $b, kakao64: Debian =="
	if place "$b" "-64" "CPU64=1"; then
		t=$(mktemp -d)
		mkdir -p "$t/sys/linux"
		cp "$B/kakao.bit" "$t/kakao64-$b.bit"
		cp "$B/kakao.dtb" "$B/kakao-busybox.dtb" "$in/rv64/fw_jump.bin" "$in/rv64/Image" "$t/sys/linux/"
		cp "$B/boot.json" "$t/sys/linux/boot-systemd.json"
		sed 's/"kakao\.dtb"/"kakao-busybox.dtb"/' "$B/boot.json" > "$t/sys/linux/boot-busybox.json"
		cp "$t/sys/linux/boot-busybox.json" "$t/sys/linux/boot.json"
		img=kakao-debian-$b.img
		cat > "$t/README.txt" <<EOT
Kakao Linux (Debian) $tag for $b, on the Kakao SOC with kakao64

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
		z=kakao-debian-$b.zip
		files=$z
		if [ -n "$card" ]; then
			c=$(mktemp -d)
			cp "$t"/sys/linux/* "$c/"
			if sh "$here/mkdebian.sh" -s "$cardmb" -t "$deb" -B "$in/rv64/busybox" -b "$c" "$out/$img" > "$out/$b-64.card.log" 2>&1; then
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
		manifest debian "$b" "$z"
		echo "$b, kakao64 (Debian): $mhz MHz with seed $seed"
	else
		tail -3 "$out/$b-64.log" 2> /dev/null || true
		echo "| $b | Kakao Linux (Debian) | kakao64 | **not built** (see $b-64.log) | | | | | |" >> "$out/SUMMARY.md"
		failed="$failed $b-64"
	fi
done

cp "$top/soc/docs/third-party.txt" "$out/THIRD-PARTY.txt"
python3 - "$out" "$tag" "$(cd "$top" && git rev-parse HEAD 2>/dev/null || echo unknown)" <<'EOF'
import datetime, json, os, sys
out, tag, commit = sys.argv[1:4]
systems = {}
path = os.path.join(out, "MANIFEST.lines")
for line in (open(path) if os.path.exists(path) else []):
    system, board, f, seed, mhz, ran = line.split()
    systems.setdefault(system, {})[board] = {
        "file": f, "seed": int(seed), "fmax_mhz": float(mhz), "target_mhz": 48.0,
        "run_on_board": ran == "yes"}
json.dump({"project": "kakao", "version": tag, "commit": commit,
           "date": datetime.date.today().isoformat(), "systems": systems},
          open(os.path.join(out, "MANIFEST.json"), "w"), indent=1)
EOF
rm -f "$out/MANIFEST.lines"
( cd "$out" && sha256sum kakao-* THIRD-PARTY.txt MANIFEST.json > SHA256SUMS 2> /dev/null || true )
echo
cat "$out/SUMMARY.md"
if [ -n "$failed" ]; then echo; echo "not built:$failed"; exit 1; fi
