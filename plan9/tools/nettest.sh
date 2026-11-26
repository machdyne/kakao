#!/bin/sh
# nettest.sh 'qemu command' p9p-dir logfile - boot the kernel with a
# network device, configure it by DHCP, ping the host, then mount a 9P
# file server running on the host over TCP and read and write a file there.
#
# The file server is plan9port's ramfs, which the build has already made;
# QEMU's user network reaches the host's 127.0.0.1 as 10.0.2.2.
QEMU=$1 P9P=$2 LOG=$3
PORT=${NETTEST_PORT:-5640}
PLAN9=$P9P; export PLAN9
PATH=$PATH:$P9P/bin; export PATH	# ramfs runs 9pserve
NAMESPACE=$(mktemp -d /tmp/kk9ns.XXXXXX); export NAMESPACE
A="tcp!127.0.0.1!$PORT"

cleanup() {	# the servers put themselves in the background: find them
	for e in /proc/[0-9]*/environ; do
		if grep -qa "NAMESPACE=$NAMESPACE" $e 2>/dev/null; then
			p=${e#/proc/}; p=${p%/environ}
			[ $p != $$ ] && kill $p 2>/dev/null
		fi
	done
	rm -rf "$NAMESPACE"
}
trap cleanup EXIT

setsid $P9P/bin/ramfs -s ramfs </dev/null >/dev/null 2>&1 &
sleep 1
setsid $P9P/bin/9pserve -c "unix!$NAMESPACE/ramfs" "$A" </dev/null >/dev/null 2>&1 &
sleep 1
$P9P/bin/9p -a "$A" create greeting &&
	echo 'hello from the host' | $P9P/bin/9p -a "$A" write greeting ||
	{ echo "FAIL  could not start a 9P server on $A"; exit 1; }

# The file server gives a file's owner more rights than others, and takes
# the user's name on trust (mount -n: no authentication), so the Plan 9
# side takes the name of whoever runs this before it mounts.
ME=$(id -un)
type() {
	sleep 8
	while read -r l; do
		printf '%s\n' "$l"
		sleep 3
	done <<END
cat /net/ether0/addr; echo
kknet; cat /lib/ndb/local
ip/ping -n 3 10.0.2.2
echo -n $ME > /dev/hostowner; srv -n tcp!10.0.2.2!$PORT host
mount -nc /srv/host /n && ls /n && cat /n/greeting
echo hello from plan 9 > /n/reply; cat /net/ether0/ifstats
END
	sleep 3
}
type | timeout 50 $QEMU > "$LOG.raw" 2>&1
tr -d '\r' < "$LOG.raw" > "$LOG"
rm -f "$LOG.raw"
$P9P/bin/9p -a "$A" read reply > "$LOG.reply" 2>&1

fail=0
for want in '^#l0: virtio: ' 'ip=10.0.2.15 ' '^2: rtt ' '/n/greeting$' \
	'^hello from the host$' 'virtio-mmio '; do
	if grep -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
if grep -q '^hello from plan 9$' "$LOG.reply"; then
	echo "ok    the host read what Plan 9 wrote"
else
	echo "FAIL  the host read what Plan 9 wrote"
	fail=1
fi
[ $fail = 0 ] || { echo "see $LOG"; exit 1; }
