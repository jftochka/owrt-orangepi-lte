#!/bin/sh
# Bootstrap network access to the OrangePi over the serial console (socat), then verify ssh.
# Prerequisites: picocom closed, Ethernet cable from the OrangePi to the home LAN switch/router.
#
# What it does on the router: br-lan becomes a DHCP client on the home LAN, the Mac's ssh key is
# installed for root, the obtained IP is written to tools/router.env.

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/serial.sh"
# public keys to install for root: the Mac's key and the dedicated phone key
PUBKEY_FILES=${PUBKEY_FILES:-"$HOME/.ssh/id_ed25519.pub $HOME/.ssh/orangepi_phone_ed25519.pub"}
for k in $PUBKEY_FILES; do [ -f "$k" ] || { echo "no ssh public key at $k" >&2; exit 1; }; done

echo "== checking the console"
out=$("$S" run "echo console-ok; cat /etc/openwrt_release | head -1")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q console-ok || { echo "no answer from the console (is the board up, picocom closed?)" >&2; exit 1; }

echo "== link state"
"$S" run "ip link show eth0 | head -1; cat /sys/class/net/eth0/carrier 2>/dev/null"

echo "== switching br-lan to DHCP client"
"$S" run "uci set network.lan.proto='dhcp'; uci -q delete network.lan.ipaddr; uci -q delete network.lan.netmask; uci -q delete network.lan.ip6assign; uci commit network; echo net-committed"

echo "== installing ssh keys"
"$S" run "mkdir -p /etc/dropbear; touch /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; echo keys-ready"
for k in $PUBKEY_FILES; do
	PUB=$(cat "$k")
	"$S" run "grep -qF '$PUB' /etc/dropbear/authorized_keys || echo '$PUB' >> /etc/dropbear/authorized_keys; echo installed: $k"
done
"$S" run "wc -l /etc/dropbear/authorized_keys"

echo "== restarting network"
"$S" run -w 10 "/etc/init.d/network restart; sleep 6; ip -4 -o addr show br-lan" > "$HERE/.bootstrap.out" 2>&1
cat "$HERE/.bootstrap.out"

ip=$(sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' "$HERE/.bootstrap.out" | head -1)
if [ -z "$ip" ]; then
	sleep 5
	ip=$("$S" run "ip -4 -o addr show br-lan" | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
fi
[ -n "$ip" ] || { echo "br-lan got no IPv4 address; check the Ethernet cable / DHCP server" >&2; exit 1; }
echo "ROUTER_IP=$ip" > "$HERE/router.env"
echo "== router IP: $ip (saved to tools/router.env)"

echo "== ssh check"
"$HERE/rt" "cat /etc/openwrt_release | head -3; ip route | head -3; ping -c1 -W3 downloads.openwrt.org >/dev/null 2>&1 && echo internet-ok || echo internet-FAIL"
