#!/bin/sh
# cputest.sh 'qemu command' logfile - two machines on a network of their
# own.  The first becomes a CPU server and the authentication server of
# its domain (kknet, kkcpu); the second joins the domain and runs
# commands on the first with cpu.  It has the wrong password to begin
# with: that is refused, factotum asks on the console for another, and
# with the right one the commands run.
QEMU=$1 LOG=$2
PORT=${CPUTEST_PORT:-5701}
NET="-global virtio-mmio.force-legacy=false -device virtio-net-device,netdev=n0"

feed() {	# feed delay line...: type the lines, a few seconds apart
	sleep $1; shift
	for l; do
		printf '%s\n' "$l"
		sleep 5
	done
	sleep ${LINGER:-3}
}

LINGER=40 feed 8 'kknet 10.0.0.1 255.255.255.0' 'kkcpu kakaopass1' |
	timeout 70 $QEMU $NET,mac=52:54:00:00:00:01 \
	-netdev socket,id=n0,listen=127.0.0.1:$PORT > "$LOG.server.raw" 2>&1 &
sleep 2
feed 18 'kknet -n guest -a 10.0.0.1 10.0.0.2 255.255.255.0' \
	'kkkey wrongpass99' \
	"cpu -h 10.0.0.1 -c 'echo hello from the cpu server; cat /dev/sysname; echo; cat /mnt/term/dev/sysname; echo; ps | grep listen | sed 1q'" \
	'' 'kakaopass1' |
	timeout 60 $QEMU $NET,mac=52:54:00:00:00:02 \
	-netdev socket,id=n0,connect=127.0.0.1:$PORT > "$LOG.client.raw" 2>&1
wait
tr -d '\r' < "$LOG.server.raw" > "$LOG.server"
tr -d '\r' < "$LOG.client.raw" > "$LOG"
rm -f "$LOG.server.raw" "$LOG.client.raw"

fail=0
for want in 'authentication server 10.0.0.1$' '^!Adding key: proto=p9sk1 dom=kakao' \
	'^hello from the cpu server$' '^kakao$' '^guest$' ' listen$'; do
	if grep -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
# the output must come after the question, not before it
if sed -n '1,/^!Adding key/p' "$LOG" | grep -q '^hello from the cpu server$'; then
	echo "FAIL  the wrong password was accepted"
	fail=1
else
	echo "ok    the wrong password was refused"
fi
if grep -q '^CPU server: ' "$LOG.server"; then
	echo "ok    ^CPU server: "
else
	echo "FAIL  ^CPU server: "
	fail=1
fi
[ $fail = 0 ] || { echo "see $LOG and $LOG.server"; exit 1; }
