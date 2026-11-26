#!/bin/sh
# qemutest.sh 'qemu command' logfile [pattern ...] - boot the kernel, type
# a few commands at its shell, and check what comes back; more patterns
# are more lines the log must have.
QEMU=$1 LOG=$2
shift 2
type() {
	sleep 8		# OpenSBI, the kernel, the shell's prompt
	for l in 'echo hello kakao' 'cat /dev/user; echo' 'ps' \
		'ls /boot | wc -l' 'echo slept; sleep 2; echo woke'; do
		printf '%s\n' "$l"
		sleep 1
	done
	# a terminal's Backspace (DEL) erases
	printf 'echo erasex\177d key\n'
	sleep 1
	sleep 4
}
type | timeout 30 $QEMU > "$LOG.raw" 2>&1
tr -d '\r' < "$LOG.raw" > "$LOG"	# the console sends CR LF
rm -f "$LOG.raw"
fail=0
for want in 'Plan 9 for kk' 'Kakao Plan 9: a shell' '^hello kakao$' '^glenda$' \
	'glenda .* rc$' 'glenda .* genrandom$' '^woke$' 'erased key$' "$@"; do
	if grep -q "$want" "$LOG"; then
		echo "ok    $want"
	else
		echo "FAIL  $want"
		fail=1
	fi
done
[ $fail = 0 ] || { echo "see $LOG"; exit 1; }
