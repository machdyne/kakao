#!/bin/sh
# drawtermtest.sh 'qemu command' drawterm logfile - a machine that is not
# Plan 9 logs in: the kernel in QEMU becomes a CPU server, and drawterm
# on this machine runs a command on it.  QEMU forwards this machine's
# ports 17010 (cpu) and 567 (authentication) to it; 567 needs privilege.
QEMU=$1 DT=$2 LOG=$3
(sleep 9; printf 'kknet\n'; sleep 4; printf 'kkcpu kakaopass1\n'; sleep 40) |
	timeout 60 $QEMU -global virtio-mmio.force-legacy=false \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:17010-:17010,hostfwd=tcp:127.0.0.1:567-:567 \
	-device virtio-net-device,netdev=n0 > "$LOG.server" 2>&1 &
sleep 22
PASS=kakaopass1 timeout 25 "$DT" -G -O -h 127.0.0.1 -a 127.0.0.1 -u glenda \
	-c 'echo hello from drawterm; cat /dev/sysname; echo; cat /dev/user; echo' > "$LOG" 2>&1
PASS=wrongpass99 timeout 25 "$DT" -G -O -h 127.0.0.1 -a 127.0.0.1 -u glenda \
	-c 'echo should not happen' > "$LOG.wrong" 2>&1
for p in $(ps -eo pid,args | grep 'hostfwd=tcp:127.0.0.1:17010' | grep -v grep | awk '{print $1}'); do
	kill $p 2>/dev/null
done
wait
fail=0
for want in '^hello from drawterm$' '^kakao$' '^glenda$'; do
	if grep -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
if grep -q '^should not happen$' "$LOG.wrong"; then
	echo "FAIL  the wrong password was accepted"
	fail=1
else
	echo "ok    the wrong password was refused"
fi
[ $fail = 0 ] || { echo "see $LOG"; exit 1; }
