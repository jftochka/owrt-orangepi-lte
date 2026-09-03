#!/bin/sh
# Runs ON THE ROUTER (tools/rt - < tools/04-tailscale.sh). Brings tailscale up with Tailscale SSH
# enabled and prints the login URL that the owner must open to add the node to their tailnet.
set -e
/etc/init.d/tailscale enable
/etc/init.d/tailscale start || true
sleep 3
if tailscale status >/dev/null 2>&1; then
	echo "already logged in:"; tailscale status; exit 0
fi
echo "== tailscale up (login URL follows)"
timeout 25 tailscale up --ssh --hostname=orangepi-lte --accept-dns=false --timeout=20s 2>&1 | grep -E 'https://|error|Error' || true
echo "== status"
tailscale status 2>&1 | head -5 || true
