#!/bin/sh
# busybox udhcpc's script: the address, the route, the name servers
B=/opt/kakao/busybox
case "$1" in
deconfig)
	$B ip addr flush dev "$interface"
	;;
bound|renew)
	$B ip addr flush dev "$interface"
	$B ip addr add "$ip/${mask:-24}" dev "$interface"
	[ -n "$router" ] && $B ip route replace default via "${router%% *}" dev "$interface"
	: > /etc/resolv.conf
	for n in $dns; do echo "nameserver $n" >> /etc/resolv.conf; done
	;;
esac
