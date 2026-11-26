#!/bin/sh
# riotest.sh 'qemu command' logfile - the window system: the kernel in
# QEMU with a framebuffer (ramfb), a keyboard and a tablet (virtio
# input); kkrio is started from the console, and riotest.py works the
# pointer and the keyboard and looks at pictures of the screen, which
# are left as logfile-a.ppm to -d.ppm. Before that a key is held down
# at the console, which has to repeat.
QEMU=$1 LOG=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SOCK=$(mktemp -u /tmp/kkqmp.XXXXXX)
(sleep 9; python3 "$HERE/riotest.py" "$SOCK" "$LOG" repeat; sleep 2; printf 'kkrio\n'; sleep 7; python3 "$HERE/riotest.py" "$SOCK" "$LOG" > "$LOG.checks" 2>&1; sleep 1) |
	timeout 100 $QEMU -global virtio-mmio.force-legacy=false -device ramfb \
	-device virtio-keyboard-device -device virtio-tablet-device \
	-qmp "unix:$SOCK,server,nowait" > "$LOG.raw" 2>&1
tr -d '\r' < "$LOG.raw" > "$LOG"
rm -f "$LOG.raw" "$SOCK"
cat "$LOG.checks"
fail=0
for want in '^screen: 1024x768x32' '^input: virtio ' 'xxxxxx.*file does not exist'; do
	if grep -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
grep -q '^FAIL' "$LOG.checks" && fail=1
grep -q '^ok' "$LOG.checks" || fail=1
[ $fail = 0 ] || { echo "see $LOG"; exit 1; }
