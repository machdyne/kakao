#!/bin/sh
# fbtest.sh 'qemu command' dtb logfile - the kernel's side of the Kakao
# SOC's framebuffer (overlay/sys/src/9k/rv/screen.c: the screen drawn in
# a copy and written out, 8 bits a pixel), in QEMU, which has no such
# thing: the device tree says there is one, in memory QEMU has and the
# tree keeps from the system, with its registers in memory too. kkrio
# is started from the console, and fbtest.py reads the picture out of
# the machine's memory; it is left as logfile.ppm.
QEMU=$1 DTB=$2 LOG=$3
HERE=$(cd "$(dirname "$0")" && pwd)
SOCK=$(mktemp -u /tmp/kkqmp.XXXXXX)
(sleep 9; printf 'kkrio\n'; sleep 12; python3 "$HERE/fbtest.py" "$SOCK" "$LOG" > "$LOG.checks" 2>&1; sleep 1) |
	timeout 60 $QEMU -dtb "$DTB" -qmp "unix:$SOCK,server,nowait" > "$LOG.raw" 2>&1
tr -d '\r' < "$LOG.raw" > "$LOG"
rm -f "$LOG.raw" "$SOCK"
cat "$LOG.checks"
fail=0
for want in '^screen: 640x480x8'; do
	if grep -a -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
grep -q '^FAIL' "$LOG.checks" && fail=1
grep -q '^ok' "$LOG.checks" || fail=1
[ $fail = 0 ] || { echo "see $LOG"; exit 1; }
