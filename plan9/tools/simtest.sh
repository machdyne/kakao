#!/bin/sh
# simtest.sh sim fw_jump.bin kernel dtb logfile - boot the kernel on the
# SOC itself, simulated (soc/sim's obj/simsoc64, kakao64 with the network
# and UART 0's pin), type tools/simtest.txt at its shell and check what
# comes back.  Some two thousand million clock cycles, forty seconds of
# the SOC's time, and the better part of an hour of this machine's.
#
# The simulation's other end of the cable is 10.0.0.1, which answers ARP
# and pings.
SIM=$1 FW=$2 KERNEL=$3 DTB=$4 LOG=$5
HERE=$(cd "$(dirname "$0")" && pwd)
(cd "$(dirname "$SIM")/.." && exec "$SIM" "+load=$FW@80000000" \
	"+load=$KERNEL@80200000" "+load=$DTB@87f00000" \
	"+type=$HERE/simtest.txt" +max=${SIMTEST_MAX:-6000000000}) > "$LOG.raw" 2>&1
tr -d '\r' < "$LOG.raw" > "$LOG"
rm -f "$LOG.raw"
fail=0
for want in 'Plan 9 for kk' 'clint timebase: 48 MHz' '^#l0: virtio: .* irq 13' \
	'Kakao Plan 9: a shell' '^hello kakao$' '^glenda$' 'glenda .* rc$' \
	'^2: rtt ' 'virtio-mmio .* own mac' '^CPU server: ' '^hello from cpu$' \
	'cycles, script done'; do
	if grep -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
[ $fail = 0 ] || { echo "see $LOG"; exit 1; }
